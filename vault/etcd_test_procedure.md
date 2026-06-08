# Manual Testing Procedures for etcd Defragmentation on OpenShift Cluster

## Overview

This document provides manual testing procedures to verify the architectural improvements in PR #378 for non-blocking etcd defragmentation on an existing OpenShift cluster.

**PR #378 Key Improvements:**
- Reduces write blocking time from O(db_size) to O(concurrent_writes)
- Implements three-phase defragmentation with write journaling
- Maintains ~99%+ write availability during defragmentation

---

## Table of Contents

1. [Prerequisites](#prerequisites)
2. [Manual Test 1: Write Availability During Defrag](#manual-test-1-write-availability-during-defrag)
3. [Manual Test 2: Database Size Reduction](#manual-test-2-database-size-reduction)
4. [Manual Test 3: Data Consistency Verification](#manual-test-3-data-consistency-verification)
5. [Manual Test 4: Performance Impact Monitoring](#manual-test-4-performance-impact-monitoring)
6. [Manual Test 5: Journal Activity Logs](#manual-test-5-journal-activity-logs)
7. [Quick Start Test](#quick-start-simple-test)
8. [Important Notes](#important-notes)
9. [Summary Checklist](#summary-checklist)

---

## Prerequisites

### Step 1: Verify cluster access

```bash
# Check cluster access
oc whoami
oc get nodes

# Check if you have access to etcd namespace
oc get pods -n openshift-etcd

# Check etcd pods
oc get pods -n openshift-etcd -l app=etcd
```

### Step 2: Identify control plane nodes

```bash
# List control plane nodes
oc get nodes -l node-role.kubernetes.io/master

# Check etcd pod distribution
oc get pods -n openshift-etcd -o wide | grep etcd-
```

### Step 3: Check etcd version

```bash
# Get etcd version running in cluster
oc exec -n openshift-etcd $(oc get pods -n openshift-etcd -l app=etcd -o name | head -1) -- etcd --version

# Check the etcd image being used
oc get pods -n openshift-etcd -o jsonpath='{.items[0].spec.containers[?(@.name=="etcd")].image}' | head -1
```

**Important:** If your cluster doesn't have PR #378 changes, you'll need to build and deploy a custom etcd image with these changes.

---

## Manual Test 1: Write Availability During Defrag

### Objective
Verify that writes continue during defragmentation and measure write blocking time.

### Expected Result
- >95% write success rate during defrag
- Only brief blocking during journal drain and switchover phases
- Most writes succeed even during the copy phase

### Procedure

#### Terminal 1 - Continuous Write Monitor

```bash
# Start continuous writes to etcd via Kubernetes API
cat > /tmp/continuous-writes.sh << 'EOF'
#!/bin/bash

counter=0
success=0
failures=0

echo "Starting continuous writes at $(date)"

while [ $counter -lt 1000 ]; do
  timestamp=$(date +%s%N)
  
  # Create a ConfigMap (uses etcd underneath)
  if oc create configmap test-write-$timestamp \
    --from-literal=key=value-$counter \
    -n default \
    --dry-run=client -o yaml | oc apply -f - >/dev/null 2>&1; then
    
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
echo "Total writes: $counter"
echo "Successful: $success"
echo "Failed: $failures"
echo "Success rate: $(awk "BEGIN {printf \"%.2f\", ($success/$counter)*100}")%"
EOF

chmod +x /tmp/continuous-writes.sh

# Run in background
/tmp/continuous-writes.sh > /tmp/write-results.log 2>&1 &
WRITE_PID=$!
echo "Continuous writes started (PID: $WRITE_PID)"
```

#### Terminal 2 - Monitor etcd Logs

```bash
# Watch etcd logs for defrag activity
ETCD_POD=$(oc get pods -n openshift-etcd -l app=etcd -o name | head -1)

oc logs -n openshift-etcd $ETCD_POD -c etcd --follow | grep -i "defrag"
```

#### Terminal 3 - Trigger Defrag

```bash
# Wait a bit for writes to start
sleep 5

# Get etcd pod
ETCD_POD=$(oc get pods -n openshift-etcd -l app=etcd -o name | head -1 | cut -d/ -f2)

echo "Triggering defragmentation at: $(date +'%H:%M:%S')"
DEFRAG_START=$(date +%s)

# Execute defrag inside the etcd pod
oc exec -n openshift-etcd $ETCD_POD -c etcd -- sh -c '
  export ETCDCTL_API=3
  export ETCDCTL_CACERT=/etc/kubernetes/static-pod-certs/configmaps/etcd-serving-ca/ca-bundle.crt
  export ETCDCTL_CERT=/etc/kubernetes/static-pod-certs/secrets/etcd-all-certs/etcd-peer-${HOSTNAME}.crt
  export ETCDCTL_KEY=/etc/kubernetes/static-pod-certs/secrets/etcd-all-certs/etcd-peer-${HOSTNAME}.key
  export ETCDCTL_ENDPOINTS=https://localhost:2379
  
  etcdctl defrag
'

DEFRAG_END=$(date +%s)
DEFRAG_DURATION=$((DEFRAG_END - DEFRAG_START))

echo "Defragmentation completed at: $(date +'%H:%M:%S')"
echo "Duration: ${DEFRAG_DURATION} seconds"
```

#### Back in Terminal 1 - Analyze Results

```bash
# Stop writes
kill $WRITE_PID

# Analyze results
cat /tmp/write-results.log | tail -20

# Count failures
TOTAL=$(grep -c "Write" /tmp/write-results.log)
FAILURES=$(grep -c "BLOCKED/FAILED" /tmp/write-results.log || echo 0)
SUCCESS=$((TOTAL - FAILURES))

echo ""
echo "=== Write Availability Analysis ==="
echo "Total writes attempted: $TOTAL"
echo "Successful: $SUCCESS"
echo "Failed/Blocked: $FAILURES"
echo "Success rate: $(awk "BEGIN {printf \"%.2f\", ($SUCCESS/$TOTAL)*100}")%"

# Expected: >95% success rate with PR changes
if [ $FAILURES -lt $((TOTAL / 20)) ]; then
  echo "✓ SUCCESS: High write availability during defrag"
else
  echo "⚠ WARNING: Significant write blocking detected"
fi

# Cleanup test configmaps
oc delete configmap -n default -l test-write 2>/dev/null
```

---

## Manual Test 2: Database Size Reduction

### Objective
Verify defragmentation reduces database size and reclaims space.

### Expected Result
- Database size decreases after defragmentation
- Space is reclaimed from deleted/updated keys
- Defrag completes successfully

### Procedure

#### Step 1: Check current database size (BEFORE)

```bash
# Get etcd pod
ETCD_POD=$(oc get pods -n openshift-etcd -l app=etcd -o name | head -1 | cut -d/ -f2)

# Check database size BEFORE defrag
echo "=== Database Status BEFORE Defrag ==="

oc exec -n openshift-etcd $ETCD_POD -c etcd -- sh -c '
  export ETCDCTL_API=3
  export ETCDCTL_CACERT=/etc/kubernetes/static-pod-certs/configmaps/etcd-serving-ca/ca-bundle.crt
  export ETCDCTL_CERT=/etc/kubernetes/static-pod-certs/secrets/etcd-all-certs/etcd-peer-${HOSTNAME}.crt
  export ETCDCTL_KEY=/etc/kubernetes/static-pod-certs/secrets/etcd-all-certs/etcd-peer-${HOSTNAME}.key
  export ETCDCTL_ENDPOINTS=https://localhost:2379
  
  etcdctl endpoint status --write-out=table
'

# Save the size
DB_SIZE_BEFORE=$(oc exec -n openshift-etcd $ETCD_POD -c etcd -- sh -c '
  export ETCDCTL_API=3
  export ETCDCTL_CACERT=/etc/kubernetes/static-pod-certs/configmaps/etcd-serving-ca/ca-bundle.crt
  export ETCDCTL_CERT=/etc/kubernetes/static-pod-certs/secrets/etcd-all-certs/etcd-peer-${HOSTNAME}.crt
  export ETCDCTL_KEY=/etc/kubernetes/static-pod-certs/secrets/etcd-all-certs/etcd-peer-${HOSTNAME}.key
  export ETCDCTL_ENDPOINTS=https://localhost:2379
  
  etcdctl endpoint status --write-out=json
' | grep -o '"dbSize":[0-9]*' | cut -d: -f2)

echo "Database size: $DB_SIZE_BEFORE bytes ($(numfmt --to=iec $DB_SIZE_BEFORE))"
```

#### Step 2: Create fragmentation (optional)

```bash
# Create and delete some resources to cause fragmentation
echo "Creating test resources..."
for i in {1..100}; do
  oc create configmap test-frag-$i --from-literal=data="$(head -c 10240 /dev/urandom | base64)" -n default
done

echo "Deleting half of them to create fragmentation..."
for i in {1..50}; do
  oc delete configmap test-frag-$i -n default
done

echo "Fragmentation created"
sleep 5
```

#### Step 3: Perform defragmentation

```bash
echo "=== Triggering Defragmentation ==="

oc exec -n openshift-etcd $ETCD_POD -c etcd -- sh -c '
  export ETCDCTL_API=3
  export ETCDCTL_CACERT=/etc/kubernetes/static-pod-certs/configmaps/etcd-serving-ca/ca-bundle.crt
  export ETCDCTL_CERT=/etc/kubernetes/static-pod-certs/secrets/etcd-all-certs/etcd-peer-${HOSTNAME}.crt
  export ETCDCTL_KEY=/etc/kubernetes/static-pod-certs/secrets/etcd-all-certs/etcd-peer-${HOSTNAME}.key
  export ETCDCTL_ENDPOINTS=https://localhost:2379
  
  echo "Starting defrag..."
  time etcdctl defrag
  echo "Defrag completed"
'
```

#### Step 4: Check database size (AFTER)

```bash
echo ""
echo "=== Database Status AFTER Defrag ==="

oc exec -n openshift-etcd $ETCD_POD -c etcd -- sh -c '
  export ETCDCTL_API=3
  export ETCDCTL_CACERT=/etc/kubernetes/static-pod-certs/configmaps/etcd-serving-ca/ca-bundle.crt
  export ETCDCTL_CERT=/etc/kubernetes/static-pod-certs/secrets/etcd-all-certs/etcd-peer-${HOSTNAME}.crt
  export ETCDCTL_KEY=/etc/kubernetes/static-pod-certs/secrets/etcd-all-certs/etcd-peer-${HOSTNAME}.key
  export ETCDCTL_ENDPOINTS=https://localhost:2379
  
  etcdctl endpoint status --write-out=table
'

DB_SIZE_AFTER=$(oc exec -n openshift-etcd $ETCD_POD -c etcd -- sh -c '
  export ETCDCTL_API=3
  export ETCDCTL_CACERT=/etc/kubernetes/static-pod-certs/configmaps/etcd-serving-ca/ca-bundle.crt
  export ETCDCTL_CERT=/etc/kubernetes/static-pod-certs/secrets/etcd-all-certs/etcd-peer-${HOSTNAME}.crt
  export ETCDCTL_KEY=/etc/kubernetes/static-pod-certs/secrets/etcd-all-certs/etcd-peer-${HOSTNAME}.key
  export ETCDCTL_ENDPOINTS=https://localhost:2379
  
  etcdctl endpoint status --write-out=json
' | grep -o '"dbSize":[0-9]*' | cut -d: -f2)

echo ""
echo "=== Defrag Results ==="
echo "Database size before: $DB_SIZE_BEFORE bytes ($(numfmt --to=iec $DB_SIZE_BEFORE))"
echo "Database size after:  $DB_SIZE_AFTER bytes ($(numfmt --to=iec $DB_SIZE_AFTER))"
echo "Space reclaimed: $((DB_SIZE_BEFORE - DB_SIZE_AFTER)) bytes ($(numfmt --to=iec $((DB_SIZE_BEFORE - DB_SIZE_AFTER))))"
echo "Reduction: $(awk "BEGIN {printf \"%.2f\", (($DB_SIZE_BEFORE - $DB_SIZE_AFTER) / $DB_SIZE_BEFORE) * 100}")%"

# Cleanup
oc delete configmap -n default test-frag-{51..100} 2>/dev/null
```

---

## Manual Test 3: Data Consistency Verification

### Objective
Ensure no data loss occurs during defragmentation with concurrent writes.

### Expected Result
- All baseline data remains intact
- All concurrent writes during defrag are persisted
- Data checksums match before and after

### Procedure

#### Step 1: Create baseline dataset

```bash
echo "=== Creating Baseline Dataset ==="

# Create known ConfigMaps
for i in {1..50}; do
  oc create configmap defrag-test-baseline-$i \
    --from-literal=index=$i \
    --from-literal=value="baseline-value-$i" \
    -n default
done

# Store baseline checksum
oc get configmap -n default -o json | \
  jq -S '.items | map(select(.metadata.name | startswith("defrag-test-baseline"))) | sort_by(.metadata.name) | .[].data' > /tmp/baseline-data.json

md5sum /tmp/baseline-data.json
BASELINE_CHECKSUM=$(md5sum /tmp/baseline-data.json | cut -d' ' -f1)
echo "Baseline checksum: $BASELINE_CHECKSUM"
```

#### Step 2: Start concurrent operations

```bash
# Start creating/updating resources during defrag
cat > /tmp/concurrent-ops.sh << 'EOF'
#!/bin/bash
for i in {1..30}; do
  oc create configmap defrag-test-concurrent-$i \
    --from-literal=timestamp=$(date +%s) \
    --from-literal=value="created-during-defrag-$i" \
    -n default \
    2>/dev/null || echo "Failed to create concurrent-$i"
  sleep 0.2
done
echo "Concurrent operations completed"
EOF

chmod +x /tmp/concurrent-ops.sh

# Start concurrent ops in background
/tmp/concurrent-ops.sh &
CONCURRENT_PID=$!

# Let some operations start
sleep 1
```

#### Step 3: Trigger defrag during concurrent operations

```bash
ETCD_POD=$(oc get pods -n openshift-etcd -l app=etcd -o name | head -1 | cut -d/ -f2)

echo "Triggering defrag with concurrent operations..."

oc exec -n openshift-etcd $ETCD_POD -c etcd -- sh -c '
  export ETCDCTL_API=3
  export ETCDCTL_CACERT=/etc/kubernetes/static-pod-certs/configmaps/etcd-serving-ca/ca-bundle.crt
  export ETCDCTL_CERT=/etc/kubernetes/static-pod-certs/secrets/etcd-all-certs/etcd-peer-${HOSTNAME}.crt
  export ETCDCTL_KEY=/etc/kubernetes/static-pod-certs/secrets/etcd-all-certs/etcd-peer-${HOSTNAME}.key
  export ETCDCTL_ENDPOINTS=https://localhost:2379
  
  etcdctl defrag
'

# Wait for concurrent operations to finish
wait $CONCURRENT_PID
```

#### Step 4: Verify data integrity

```bash
echo ""
echo "=== Data Consistency Verification ==="

# Check baseline data still exists
echo "Checking baseline data..."
MISSING_BASELINE=0
for i in {1..50}; do
  if ! oc get configmap defrag-test-baseline-$i -n default >/dev/null 2>&1; then
    echo "Missing: defrag-test-baseline-$i"
    ((MISSING_BASELINE++))
  fi
done

echo "Missing baseline ConfigMaps: $MISSING_BASELINE"

# Check concurrent data was persisted
echo "Checking concurrent data..."
MISSING_CONCURRENT=0
for i in {1..30}; do
  if ! oc get configmap defrag-test-concurrent-$i -n default >/dev/null 2>&1; then
    echo "Missing: defrag-test-concurrent-$i"
    ((MISSING_CONCURRENT++))
  fi
done

echo "Missing concurrent ConfigMaps: $MISSING_CONCURRENT"

# Verify baseline checksum (should be unchanged)
oc get configmap -n default -o json | \
  jq -S '.items | map(select(.metadata.name | startswith("defrag-test-baseline"))) | sort_by(.metadata.name) | .[].data' > /tmp/after-defrag-data.json

AFTER_CHECKSUM=$(md5sum /tmp/after-defrag-data.json | cut -d' ' -f1)

echo ""
echo "Baseline checksum before: $BASELINE_CHECKSUM"
echo "Baseline checksum after:  $AFTER_CHECKSUM"

if [ "$BASELINE_CHECKSUM" = "$AFTER_CHECKSUM" ] && [ $MISSING_BASELINE -eq 0 ] && [ $MISSING_CONCURRENT -lt 5 ]; then
  echo "✓ SUCCESS: Data consistency maintained during defrag"
else
  echo "✗ FAILURE: Data inconsistency detected"
fi

# Cleanup
oc delete configmap -n default defrag-test-baseline-{1..50} 2>/dev/null
oc delete configmap -n default defrag-test-concurrent-{1..30} 2>/dev/null
```

---

## Manual Test 4: Performance Impact Monitoring

### Objective
Observe cluster performance and API responsiveness during defragmentation.

### Expected Result
- Minimal API latency increase during defrag
- No significant performance degradation
- Cluster remains healthy throughout

### Procedure

#### Step 1: Monitor API server response times

```bash
# In one terminal, monitor API response times
cat > /tmp/monitor-api.sh << 'EOF'
#!/bin/bash
echo "Monitoring API response times..."
echo "Time,ResponseMS" > /tmp/api-response-times.csv

while true; do
  start=$(date +%s%N)
  oc get nodes >/dev/null 2>&1
  end=$(date +%s%N)
  duration=$(( (end - start) / 1000000 ))  # Convert to milliseconds
  
  timestamp=$(date +'%H:%M:%S')
  echo "$timestamp,$duration" >> /tmp/api-response-times.csv
  echo "$timestamp - API response: ${duration}ms"
  sleep 1
done
EOF

chmod +x /tmp/monitor-api.sh
/tmp/monitor-api.sh &
API_MONITOR_PID=$!

echo "API monitoring started (PID: $API_MONITOR_PID)"
```

#### Step 2: Check etcd metrics before defrag

```bash
ETCD_POD=$(oc get pods -n openshift-etcd -l app=etcd -o name | head -1 | cut -d/ -f2)

echo "=== Etcd Metrics BEFORE Defrag ==="
oc exec -n openshift-etcd $ETCD_POD -c etcd -- sh -c '
  export ETCDCTL_API=3
  export ETCDCTL_CACERT=/etc/kubernetes/static-pod-certs/configmaps/etcd-serving-ca/ca-bundle.crt
  export ETCDCTL_CERT=/etc/kubernetes/static-pod-certs/secrets/etcd-all-certs/etcd-peer-${HOSTNAME}.crt
  export ETCDCTL_KEY=/etc/kubernetes/static-pod-certs/secrets/etcd-all-certs/etcd-peer-${HOSTNAME}.key
  export ETCDCTL_ENDPOINTS=https://localhost:2379
  
  echo "Endpoint health:"
  etcdctl endpoint health
  
  echo ""
  echo "Endpoint status:"
  etcdctl endpoint status --write-out=table
'
```

#### Step 3: Trigger defrag

```bash
echo ""
echo "Triggering defrag at $(date)..."

oc exec -n openshift-etcd $ETCD_POD -c etcd -- sh -c '
  export ETCDCTL_API=3
  export ETCDCTL_CACERT=/etc/kubernetes/static-pod-certs/configmaps/etcd-serving-ca/ca-bundle.crt
  export ETCDCTL_CERT=/etc/kubernetes/static-pod-certs/secrets/etcd-all-certs/etcd-peer-${HOSTNAME}.crt
  export ETCDCTL_KEY=/etc/kubernetes/static-pod-certs/secrets/etcd-all-certs/etcd-peer-${HOSTNAME}.key
  export ETCDCTL_ENDPOINTS=https://localhost:2379
  
  time etcdctl defrag
'

echo "Defrag completed at $(date)"
```

#### Step 4: Check metrics after defrag

```bash
sleep 5

echo ""
echo "=== Etcd Metrics AFTER Defrag ==="
oc exec -n openshift-etcd $ETCD_POD -c etcd -- sh -c '
  export ETCDCTL_API=3
  export ETCDCTL_CACERT=/etc/kubernetes/static-pod-certs/configmaps/etcd-serving-ca/ca-bundle.crt
  export ETCDCTL_CERT=/etc/kubernetes/static-pod-certs/secrets/etcd-all-certs/etcd-peer-${HOSTNAME}.crt
  export ETCDCTL_KEY=/etc/kubernetes/static-pod-certs/secrets/etcd-all-certs/etcd-peer-${HOSTNAME}.key
  export ETCDCTL_ENDPOINTS=https://localhost:2379
  
  echo "Endpoint health:"
  etcdctl endpoint health
  
  echo ""
  echo "Endpoint status:"
  etcdctl endpoint status --write-out=table
'

# Stop API monitoring
kill $API_MONITOR_PID

# Show API response time analysis
echo ""
echo "=== API Response Time Analysis ==="
echo "Minimum: $(awk -F',' 'NR>1 {print $2}' /tmp/api-response-times.csv | sort -n | head -1)ms"
echo "Maximum: $(awk -F',' 'NR>1 {print $2}' /tmp/api-response-times.csv | sort -n | tail -1)ms"
echo "Average: $(awk -F',' 'NR>1 {sum+=$2; count++} END {printf "%.0f", sum/count}' /tmp/api-response-times.csv)ms"

echo ""
echo "Response times saved to: /tmp/api-response-times.csv"
```

---

## Manual Test 5: Journal Activity Logs

### Objective
Look for evidence of journal behavior and three-phase defragmentation in logs.

### Expected Result
- Log entries showing defrag phases
- Journal operations being captured and replayed
- No errors or panics during defrag

### Procedure

```bash
ETCD_POD=$(oc get pods -n openshift-etcd -l app=etcd -o name | head -1 | cut -d/ -f2)

echo "=== Searching for Journal/Defrag Activity in Logs ==="

# Get recent logs before defrag
echo "Logs before defrag:"
oc logs -n openshift-etcd $ETCD_POD -c etcd --tail=100 | grep -i -E "defrag|journal" | tail -10

# Trigger defrag
echo ""
echo "Triggering defrag..."
oc exec -n openshift-etcd $ETCD_POD -c etcd -- sh -c '
  export ETCDCTL_API=3
  export ETCDCTL_CACERT=/etc/kubernetes/static-pod-certs/configmaps/etcd-serving-ca/ca-bundle.crt
  export ETCDCTL_CERT=/etc/kubernetes/static-pod-certs/secrets/etcd-all-certs/etcd-peer-${HOSTNAME}.crt
  export ETCDCTL_KEY=/etc/kubernetes/static-pod-certs/secrets/etcd-all-certs/etcd-peer-${HOSTNAME}.key
  export ETCDCTL_ENDPOINTS=https://localhost:2379
  
  etcdctl defrag
'

sleep 2

# Check logs after defrag
echo ""
echo "=== Defrag logs after operation ==="
oc logs -n openshift-etcd $ETCD_POD -c etcd --tail=200 | grep -i -E "defrag|journal|phase|snapshot|switchover" | tail -30

# Look for specific patterns
echo ""
echo "=== Searching for key patterns ==="
echo "Phase 1 (snapshot):"
oc logs -n openshift-etcd $ETCD_POD -c etcd --tail=200 | grep -i "snapshot" | tail -5

echo ""
echo "Phase 2 (journal/replay):"
oc logs -n openshift-etcd $ETCD_POD -c etcd --tail=200 | grep -i "journal\|replay" | tail -5

echo ""
echo "Phase 3 (switchover):"
oc logs -n openshift-etcd $ETCD_POD -c etcd --tail=200 | grep -i "switchover\|rename" | tail -5

echo ""
echo "Errors/Warnings:"
oc logs -n openshift-etcd $ETCD_POD -c etcd --tail=200 | grep -i -E "error|warn|panic" | tail -5
```

---

## Quick Start: Simple Test

If you just want a quick verification of basic defragmentation functionality:

```bash
#!/bin/bash

# Get etcd pod
ETCD_POD=$(oc get pods -n openshift-etcd -l app=etcd -o name | head -1 | cut -d/ -f2)

echo "Running quick defrag test on pod: $ETCD_POD"
echo ""

# Run defrag with before/after status
oc exec -n openshift-etcd $ETCD_POD -c etcd -- sh -c '
  export ETCDCTL_API=3
  export ETCDCTL_CACERT=/etc/kubernetes/static-pod-certs/configmaps/etcd-serving-ca/ca-bundle.crt
  export ETCDCTL_CERT=/etc/kubernetes/static-pod-certs/secrets/etcd-all-certs/etcd-peer-${HOSTNAME}.crt
  export ETCDCTL_KEY=/etc/kubernetes/static-pod-certs/secrets/etcd-all-certs/etcd-peer-${HOSTNAME}.key
  export ETCDCTL_ENDPOINTS=https://localhost:2379
  
  echo "=== BEFORE DEFRAG ==="
  etcdctl endpoint status --write-out=table
  
  echo ""
  echo "=== RUNNING DEFRAG ==="
  time etcdctl defrag
  
  echo ""
  echo "=== AFTER DEFRAG ==="
  etcdctl endpoint status --write-out=table
'

echo ""
echo "Quick test completed!"
```

Save this as `/tmp/quick-defrag-test.sh` and run:
```bash
chmod +x /tmp/quick-defrag-test.sh
/tmp/quick-defrag-test.sh
```

---

## Important Notes

### ⚠️ Before Running Tests

1. **Backup etcd** (if this is a critical cluster):
   ```bash
   ETCD_POD=$(oc get pods -n openshift-etcd -l app=etcd -o name | head -1 | cut -d/ -f2)
   
   # Take etcd backup
   oc exec -n openshift-etcd $ETCD_POD -c etcd -- sh -c '
     export ETCDCTL_API=3
     export ETCDCTL_CACERT=/etc/kubernetes/static-pod-certs/configmaps/etcd-serving-ca/ca-bundle.crt
     export ETCDCTL_CERT=/etc/kubernetes/static-pod-certs/secrets/etcd-all-certs/etcd-peer-${HOSTNAME}.crt
     export ETCDCTL_KEY=/etc/kubernetes/static-pod-certs/secrets/etcd-all-certs/etcd-peer-${HOSTNAME}.key
     export ETCDCTL_ENDPOINTS=https://localhost:2379
     
     etcdctl snapshot save /tmp/etcd-backup-$(date +%Y%m%d-%H%M%S).db
   '
   
   # Copy backup out of pod
   oc cp -n openshift-etcd $ETCD_POD:/tmp/etcd-backup-*.db /tmp/
   ```

2. **Verify PR changes are deployed**
   - Check if your cluster's etcd image contains the PR #378 changes
   - Look for the new journal implementation files
   - Verify the three-phase defrag logic is present

3. **Use test cluster preferably**
   - Run on non-production clusters first
   - Validate results before production deployment

4. **Monitor cluster health**
   - Watch for any alerts or degradation
   - Check etcd member health throughout testing

### Environment Variables Used

All test scripts use the following etcd credentials (standard for OpenShift):
- `ETCDCTL_API=3`
- `ETCDCTL_CACERT=/etc/kubernetes/static-pod-certs/configmaps/etcd-serving-ca/ca-bundle.crt`
- `ETCDCTL_CERT=/etc/kubernetes/static-pod-certs/secrets/etcd-all-certs/etcd-peer-${HOSTNAME}.crt`
- `ETCDCTL_KEY=/etc/kubernetes/static-pod-certs/secrets/etcd-all-certs/etcd-peer-${HOSTNAME}.key`
- `ETCDCTL_ENDPOINTS=https://localhost:2379`

### Required Tools

Ensure these tools are available:
- `oc` - OpenShift CLI
- `etcdctl` - etcd client (inside etcd pod)
- `jq` - JSON processor (for some tests)
- `numfmt` - Number formatter (optional, for human-readable sizes)

---

## Summary Checklist

After running the manual tests, verify these outcomes:

### ✓ Test 1: Write Availability
- [ ] Writes continue during defragmentation
- [ ] Success rate > 95% (ideally >99%)
- [ ] Only brief blocking observed during journal drain/switchover
- [ ] Database size reduced after defrag

### ✓ Test 2: Database Size Reduction
- [ ] Database size shows reduction after defrag
- [ ] Space is reclaimed from deleted/fragmented data
- [ ] Defrag command completes successfully
- [ ] No errors in etcd logs

### ✓ Test 3: Data Consistency
- [ ] All baseline keys intact after defrag
- [ ] All concurrent writes preserved (or <5% lost during brief lock)
- [ ] Data checksums match before/after for baseline data
- [ ] No data corruption detected

### ✓ Test 4: Performance Monitoring
- [ ] API response times remain acceptable during defrag
- [ ] No significant latency spikes observed
- [ ] Cluster health checks pass throughout
- [ ] etcd endpoint status shows healthy after defrag

### ✓ Test 5: Journal Verification
- [ ] Log entries show defrag activity
- [ ] Evidence of journal operations (if PR changes present)
- [ ] No panic or error messages during defrag
- [ ] Three-phase behavior observable (if PR changes present)

---

## Expected Results Summary

### With PR #378 Changes (Non-Blocking Defrag)
- **Write availability:** >99% during defrag
- **Blocking time:** O(concurrent_writes) + O(1) for switchover
- **Log evidence:** Journal snapshot, replay, and switchover phases
- **Performance:** Minimal impact on API latency

### Without PR #378 Changes (Baseline)
- **Write availability:** Significantly lower, potential blocking
- **Blocking time:** O(database_size) - entire copy phase blocks
- **Log evidence:** Simple defrag operation
- **Performance:** Noticeable API latency during defrag

---

## Troubleshooting

### Issue: Cannot exec into etcd pod
**Solution:** Check RBAC permissions, ensure you're cluster-admin or have appropriate roles

### Issue: etcdctl command not found
**Solution:** etcdctl is inside the etcd container, use `oc exec ... -c etcd`

### Issue: Permission denied on certificates
**Solution:** Verify the certificate paths match your OpenShift version

### Issue: Defrag takes too long
**Solution:** Normal for large databases; with PR changes should not block writes

### Issue: Write failures during test
**Solution:** Expected during brief lock phases; >95% success rate is good

---

## Additional Resources

- **PR #378:** https://github.com/openshift/etcd/pull/378
- **etcd Defrag Documentation:** https://etcd.io/docs/latest/op-guide/maintenance/
- **OpenShift etcd Operator:** https://docs.openshift.com/container-platform/latest/backup_and_restore/control_plane_backup_and_restore/backing-up-etcd.html

---

## Report Template

After completing tests, document your findings:

```
# etcd Defragmentation Test Report

**Date:** YYYY-MM-DD
**Cluster:** <cluster-name>
**etcd Version:** <version>
**PR #378 Applied:** Yes/No

## Test Results

### Test 1: Write Availability
- Total writes: XXX
- Successful: XXX (XX%)
- Failed: XXX (XX%)
- Result: PASS/FAIL

### Test 2: Database Size
- Size before: XXX MB
- Size after: XXX MB
- Reduction: XX%
- Result: PASS/FAIL

### Test 3: Data Consistency
- Baseline data: INTACT/CORRUPTED
- Concurrent writes: XXX preserved
- Checksums: MATCH/MISMATCH
- Result: PASS/FAIL

### Test 4: Performance
- Max API latency: XXX ms
- Average latency: XXX ms
- Cluster health: HEALTHY/DEGRADED
- Result: PASS/FAIL

### Test 5: Logs
- Journal activity: OBSERVED/NOT OBSERVED
- Errors: YES/NO
- Result: PASS/FAIL

## Overall Assessment
<Your summary here>

## Recommendations
<Your recommendations here>
```

---

**Document Version:** 1.0  
**Created:** 2026-06-08  
**Author:** Manual Testing Procedures for etcd PR #378  
**Target:** OpenShift etcd defragmentation verification
