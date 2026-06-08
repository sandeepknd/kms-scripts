# Manual Testing Procedures for etcd Defragmentation on OpenShift Cluster

## Overview

This document provides manual testing procedures to verify the architectural improvements in PR #378 for non-blocking etcd defragmentation on an existing OpenShift cluster **using direct etcdctl commands**.

**PR #378 Key Improvements:**
- Reduces write blocking time from O(db_size) to O(concurrent_writes)
- Implements three-phase defragmentation with write journaling
- Maintains ~99%+ write availability during defragmentation

**Testing Approach:**
- Uses **direct etcdctl writes** to bypass API server overhead
- Writes to `/test/` prefix in etcd (NOT Kubernetes resources)
- Creates 3GB database to achieve realistic 10-30 second defrag times
- Measures write success rate during defragmentation

---

## Table of Contents

1. [Prerequisites](#prerequisites)
2. [Test Procedure Summary](#test-procedure-summary)
3. [Detailed Test Steps](#detailed-test-steps)
4. [Cleanup](#cleanup)
5. [Expected Results](#expected-results)
6. [Troubleshooting](#troubleshooting)

---

## Prerequisites

### Verify cluster access

```bash
# Check cluster access
oc whoami
oc get nodes

# Check etcd pods
oc get pods -n openshift-etcd -l app=etcd

# Get etcd pod name
ETCD_POD=$(oc get pods -n openshift-etcd -l app=etcd -o name | head -1 | cut -d/ -f2)
echo "Using etcd pod: $ETCD_POD"
```

### Check current database size

```bash
ETCD_POD=$(oc get pods -n openshift-etcd -l app=etcd -o name | head -1 | cut -d/ -f2)

# Check database file size
oc exec -n openshift-etcd $ETCD_POD -c etcd -- ls -lh /var/lib/etcd/member/snap/db

# Check etcd status
oc exec -n openshift-etcd $ETCD_POD -c etcd -- etcdctl endpoint status --write-out=table
```

---

## Test Procedure Summary

The test consists of 4 main steps:

1. **Setup**: Create 3GB database using `/tmp/create-large-etcd-db.sh`
2. **Terminal 1**: Start continuous writes in background
3. **Terminal 2**: Trigger defrag while writes are running
4. **Terminal 1**: Stop writes and analyze success rate

All steps use **direct etcdctl commands** - no ConfigMaps, no API server overhead.

---

## Detailed Test Steps

### Step 1: Create Large Database Setup Script

Create the script that will populate etcd with 3GB of data:

```bash
cat > /tmp/create-large-etcd-db.sh << 'EOF'
#!/bin/bash

ETCD_POD=$(oc get pods -n openshift-etcd -l app=etcd -o name | head -1 | cut -d/ -f2)

# Configuration
PAYLOAD_SIZE=524288   # 512KB per key (safer for argument limits)
NUM_KEYS=6000         # Number of keys to create (6000 × 512KB = 3GB total)

echo "========================================="
echo "  Creating Large etcd Database for Testing"
echo "========================================="
echo ""

echo "=== Configuration ==="
echo "Payload size per key: $(numfmt --to=iec $PAYLOAD_SIZE 2>/dev/null || echo '512KB')"
echo "Number of keys: $NUM_KEYS"
echo "Total data to write: $(numfmt --to=iec $((NUM_KEYS * PAYLOAD_SIZE)) 2>/dev/null || echo '3GB')"
echo "Start time: $(date +'%H:%M:%S')"
echo ""

echo "=== Current Database Size ==="
oc exec -n openshift-etcd $ETCD_POD -c etcd -- ls -lh /var/lib/etcd/member/snap/db
echo ""

echo "=== Writing $NUM_KEYS × 512KB keys to etcd ==="
echo "This will take several minutes..."

oc exec -n openshift-etcd $ETCD_POD -c etcd -- sh -c "
  for i in \$(seq 1 $NUM_KEYS); do
    # Generate data and pipe directly to etcdctl (avoids argument length limit)
    head -c $PAYLOAD_SIZE /dev/urandom | base64 -w 0 | etcdctl put /test/large-data-\$i >/dev/null

    if [ \$((\$i % 600)) -eq 0 ]; then
      echo \"  Written \$i / $NUM_KEYS keys... (\$(date +'%H:%M:%S'))\"
    fi
  done

  echo \"All keys written!\"
"

echo "Completed at: $(date +'%H:%M:%S')"
echo ""

# Wait for etcd to flush
echo "Waiting for etcd to flush writes..."
sleep 10

echo "=== New Database Size ==="
oc exec -n openshift-etcd $ETCD_POD -c etcd -- ls -lh /var/lib/etcd/member/snap/db
DB_SIZE=$(oc exec -n openshift-etcd $ETCD_POD -c etcd -- stat -c%s /var/lib/etcd/member/snap/db 2>/dev/null || echo 0)
if [ $DB_SIZE -gt 0 ]; then
  echo "Database size: $(numfmt --to=iec $DB_SIZE 2>/dev/null || echo "$DB_SIZE bytes")"
fi
echo ""

# Verify data was written
echo "=== Verifying Data ==="
oc exec -n openshift-etcd $ETCD_POD -c etcd -- sh -c '
  KEY_COUNT=$(etcdctl get /test/ --prefix --keys-only | wc -l)
  echo "Total keys under /test/: $KEY_COUNT"

  SAMPLE_SIZE=$(etcdctl get /test/large-data-1 --print-value-only 2>/dev/null | wc -c)
  if [ $SAMPLE_SIZE -gt 0 ]; then
    echo "Sample key size: $(numfmt --to=iec $SAMPLE_SIZE 2>/dev/null || echo "$SAMPLE_SIZE bytes")"
  fi
'

echo ""
echo "=== Creating Fragmentation ==="
echo "Deleting 50% of keys to create space to reclaim..."

DELETE_COUNT=$((NUM_KEYS / 2))
oc exec -n openshift-etcd $ETCD_POD -c etcd -- sh -c "
  for i in \$(seq 1 $DELETE_COUNT); do
    etcdctl del /test/large-data-\$i >/dev/null

    if [ \$((\$i % 600)) -eq 0 ]; then
      echo \"  Deleted \$i / $DELETE_COUNT keys...\"
    fi
  done

  echo \"Deletions complete!\"
"

sleep 5
echo ""

echo "=== Testing Defrag Duration ==="
START=$(date +%s)
oc exec -n openshift-etcd $ETCD_POD -c etcd -- etcdctl defrag
END=$(date +%s)
DURATION=$((END - START))

echo ""
echo "========================================="
echo "  Setup Complete!"
echo "========================================="
echo ""
echo "Results:"
echo "  - Keys created: $NUM_KEYS"
echo "  - Keys deleted (fragmentation): $DELETE_COUNT"
echo "  - Keys remaining: $((NUM_KEYS - DELETE_COUNT))"
echo "  - Defrag duration: ${DURATION} seconds"

if [ $DURATION -lt 5 ]; then
  echo "  ⚠ Defrag still fast (<5s) - consider increasing NUM_KEYS to 12000"
elif [ $DURATION -lt 15 ]; then
  echo "  ✓ Good defrag window (5-15s) for testing"
  echo "    Expected write attempts during defrag: ~$((DURATION * 10))"
elif [ $DURATION -lt 60 ]; then
  echo "  ✓ Excellent defrag window (15-60s) for comprehensive testing"
  echo "    Expected write attempts during defrag: ~$((DURATION * 10))"
else
  echo "  ✓ Very large defrag window (${DURATION}s) for thorough testing"
  echo "    Expected write attempts during defrag: ~$((DURATION * 10))"
fi

echo ""
echo "=== Final Database Size ==="
oc exec -n openshift-etcd $ETCD_POD -c etcd -- ls -lh /var/lib/etcd/member/snap/db
oc exec -n openshift-etcd $ETCD_POD -c etcd -- etcdctl endpoint status --write-out=table

echo ""
echo "========================================="
echo "  Database Ready for Write Availability Testing!"
echo "========================================="
echo ""
echo "Next: Run /tmp/etcd-continuous-writes.sh to test write availability"
echo ""
EOF

chmod +x /tmp/create-large-etcd-db.sh
```

### Step 2: Create Continuous Write Test Script

Create the script that continuously writes to etcd:

```bash
cat > /tmp/etcd-continuous-writes.sh << 'EOF'
#!/bin/bash

ETCD_POD=$(oc get pods -n openshift-etcd -l app=etcd -o name | head -1 | cut -d/ -f2)

counter=0
success=0
failures=0

echo "Starting continuous etcd writes at $(date)"
echo "Writing directly to etcd using etcdctl put..."
echo ""

while [ $counter -lt 1000 ]; do
  timestamp=$(date +%s%N)

  # Write directly to etcd (small value for speed)
  if oc exec -n openshift-etcd $ETCD_POD -c etcd -- \
    etcdctl put /test/write-test-$timestamp "value-$counter" \
    >/dev/null 2>&1; then

    echo "$(date +'%H:%M:%S.%N') - Write $counter: SUCCESS"
    ((success++))
  else
    echo "$(date +'%H:%M:%S.%N') - Write $counter: BLOCKED/FAILED" >&2
    ((failures++))
  fi

  ((counter++))
  sleep 0.1
done

echo ""
echo "========================================="
echo "  Continuous Write Test Results"
echo "========================================="
echo "Total writes: $counter"
echo "Successful: $success"
echo "Failed: $failures"
if [ $counter -gt 0 ]; then
  success_rate=$(awk "BEGIN {printf \"%.2f\", ($success/$counter)*100}")
  echo "Success rate: ${success_rate}%"
fi
EOF

chmod +x /tmp/etcd-continuous-writes.sh
```

### Step 3: Run Database Setup

Execute the setup script to create 3GB database:

```bash
/tmp/create-large-etcd-db.sh
```

**Important:** Note the "Defrag duration" from the output. This tells you how long the write availability test window will be.

Example output:
```
Defrag duration: 25 seconds
Expected write attempts during defrag: ~250
```

### Step 4: Test Write Availability During Defrag

Now run the actual test with two terminals:

#### Terminal 1: Start Continuous Writes

```bash
# Run continuous writes in background
/tmp/etcd-continuous-writes.sh > /tmp/write-results.log 2>&1 &
WRITE_PID=$!
echo "Continuous writes started (PID: $WRITE_PID)"

# Optional: Watch progress in real-time
tail -f /tmp/write-results.log
```

#### Terminal 2: Trigger Defrag (While Writes Are Running)

```bash
# Wait for writes to start
sleep 5

# Get etcd pod
ETCD_POD=$(oc get pods -n openshift-etcd -l app=etcd -o name | head -1 | cut -d/ -f2)

echo "Triggering defragmentation at: $(date +'%H:%M:%S')"
DEFRAG_START=$(date +%s)

# Execute defrag (writes are happening in Terminal 1)
oc exec -n openshift-etcd $ETCD_POD -c etcd -- etcdctl defrag

DEFRAG_END=$(date +%s)
DEFRAG_DURATION=$((DEFRAG_END - DEFRAG_START))

echo "Defragmentation completed at: $(date +'%H:%M:%S')"
echo "Duration: ${DEFRAG_DURATION} seconds"
```

#### Terminal 1: Stop Writes and Analyze Results

```bash
# Wait a few more seconds after defrag completes
sleep 5

# Stop continuous writes
# If watching with tail -f, press Ctrl+C first, then:
kill $WRITE_PID

# Analyze results
echo ""
echo "=== Write Availability Test Results ==="

# Count results
TOTAL=$(grep -c "Write" /tmp/write-results.log)
FAILURES=$(grep -c "BLOCKED/FAILED" /tmp/write-results.log)
SUCCESS=$((TOTAL - FAILURES))

echo "Total writes attempted: $TOTAL"
echo "Successful: $SUCCESS"
echo "Failed/Blocked: $FAILURES"

if [ ${TOTAL:-0} -gt 0 ]; then
  SUCCESS_RATE=$(awk "BEGIN {printf \"%.2f\", ($SUCCESS/$TOTAL)*100}")
  echo "Success rate: ${SUCCESS_RATE}%"
  
  # Expected: >95% success rate with PR #378 changes
  if [ $FAILURES -lt $((TOTAL / 20)) ]; then
    echo ""
    echo "✓ SUCCESS: High write availability during defrag (>95%)"
    echo "  This indicates non-blocking defrag is working!"
  else
    echo ""
    echo "⚠ WARNING: Significant write blocking detected"
    echo "  PR #378 may not be deployed or database too small"
  fi
else
  echo "⚠ WARNING: No write data found in log file"
fi

# Show last few log entries
echo ""
echo "Last 10 write attempts:"
tail -10 /tmp/write-results.log
```

---

## Cleanup

After testing, remove all test data from etcd:

```bash
ETCD_POD=$(oc get pods -n openshift-etcd -l app=etcd -o name | head -1 | cut -d/ -f2)

echo "=== Cleaning up test data from etcd ==="

# Delete all keys under /test/ prefix
oc exec -n openshift-etcd $ETCD_POD -c etcd -- etcdctl del /test/ --prefix

echo "Test data deleted from etcd"

# Optionally defrag to reclaim space
echo "Running defrag to reclaim space..."
oc exec -n openshift-etcd $ETCD_POD -c etcd -- etcdctl defrag

echo ""
echo "Cleanup complete!"
echo ""

# Verify cleanup
echo "=== Final Database Size ==="
oc exec -n openshift-etcd $ETCD_POD -c etcd -- ls -lh /var/lib/etcd/member/snap/db
```

---

## Expected Results

### With PR #378 (Non-Blocking Defrag)

**Database:** ~3-4GB  
**Defrag duration:** 10-30 seconds  
**Write attempts:** 100-300  
**Expected failures:** 0-5 writes (only during brief lock phases)  
**Success rate:** **99%+** ✅

**Why:** The three-phase defrag keeps the database unlocked during the copy phase (Phase 2), which is the longest phase. Only brief locking during journal drain and switchover.

### Without PR #378 (Old Blocking Defrag)

**Database:** ~3-4GB  
**Defrag duration:** 10-30 seconds  
**Write attempts:** 100-300  
**Expected failures:** 50-200 writes (blocked during entire copy)  
**Success rate:** **50-80%** ❌

**Why:** The old approach locks the database for the entire duration of defragmentation, blocking all writes.

---

## Troubleshooting

### Issue: "Argument list too long" Error

**Cause:** Payload size too large for command-line argument  
**Solution:** The script already uses stdin piping. If still failing, reduce `PAYLOAD_SIZE` to `262144` (256KB)

### Issue: Defrag still only takes 300-500ms

**Cause:** Database not large enough  
**Solution:** 
- Increase `NUM_KEYS` to 12000 or 20000
- Or increase `PAYLOAD_SIZE` to 1048576 (1MB) and reduce `NUM_KEYS` to 5000

### Issue: Cannot find etcd pod

**Cause:** Different pod naming or not enough permissions  
**Solution:**
```bash
# List all etcd pods
oc get pods -n openshift-etcd

# Use specific pod name
ETCD_POD=etcd-<your-node-name>
```

### Issue: etcdctl command not found

**Cause:** etcdctl not in PATH inside pod  
**Solution:** It should be available by default in OpenShift etcd pods. Verify:
```bash
oc exec -n openshift-etcd $ETCD_POD -c etcd -- which etcdctl
```

---

## Summary Checklist

After completing the test, verify:

- [ ] Database created successfully (~3-4GB)
- [ ] Defrag duration is 10-30 seconds (not milliseconds)
- [ ] Continuous writes script ran during defrag
- [ ] Write success rate measured
- [ ] Success rate is >95% (indicates non-blocking defrag working)
- [ ] Test data cleaned up from etcd

---

## Report Template

```
# etcd Defragmentation Test Report

**Date:** YYYY-MM-DD
**Cluster:** <cluster-name>
**etcd Version:** <version>
**PR #378 Applied:** Yes/No

## Test Results

### Database Setup
- Initial DB size: XXX MB
- After adding data: XXX GB
- After fragmentation: XXX GB

### Defrag Performance
- Defrag duration: XX seconds
- Database size after defrag: XXX GB

### Write Availability
- Total write attempts: XXX
- Successful writes: XXX
- Failed writes: XXX
- Success rate: XX.XX%

### Conclusion
- [ ] PASS: Success rate >95%
- [ ] FAIL: Success rate <95%

**Notes:**
<Your observations here>
```

---

**Document Version:** 2.0 (Updated with direct etcdctl approach)  
**Created:** 2026-06-09  
**Testing Approach:** Direct etcd writes via etcdctl  
**Target:** OpenShift etcd defragmentation verification
