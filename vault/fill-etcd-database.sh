#!/bin/bash

set -euo pipefail

# Script to fill etcd database with test data for defragmentation testing
# This script creates a large etcd database (~3GB) by writing large values
# and then deletes half of them to create fragmentation

# Configuration
PAYLOAD_SIZE=524288   # 512KB per key (safe for argument limits)
NUM_KEYS=6000         # Number of keys to create (6000 × 512KB = 3GB total)
DELETE_PERCENTAGE=35  # Percentage of keys to delete to create fragmentation (below 47% auto-defrag threshold)

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Function to print colored messages
print_header() {
    echo -e "${BLUE}=========================================${NC}"
    echo -e "${BLUE}  $1${NC}"
    echo -e "${BLUE}=========================================${NC}"
    echo ""
}

print_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

print_warning() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

print_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# Get etcd pod
print_info "Detecting etcd pod..."
ETCD_POD=$(oc get pods -n openshift-etcd -l app=etcd -o name 2>/dev/null | head -1 | cut -d/ -f2)

if [ -z "$ETCD_POD" ]; then
    print_error "No etcd pod found. Ensure you have access to the OpenShift cluster."
    exit 1
fi

print_info "Using etcd pod: $ETCD_POD"
echo ""

# Display configuration
print_header "Configuration"
echo "Payload size per key: $(numfmt --to=iec $PAYLOAD_SIZE 2>/dev/null || echo '512KB')"
echo "Number of keys: $NUM_KEYS"
echo "Total data to write: $(numfmt --to=iec $((NUM_KEYS * PAYLOAD_SIZE)) 2>/dev/null || echo '~3GB')"
echo "Delete percentage: ${DELETE_PERCENTAGE}%"
echo "Start time: $(date +'%Y-%m-%d %H:%M:%S')"
echo ""

# Show current database size
print_header "Current Database Size"
oc exec -n openshift-etcd $ETCD_POD -c etcd -- ls -lh /var/lib/etcd/member/snap/db
echo ""

# Write large keys to etcd
print_header "Writing $NUM_KEYS × 512KB keys to etcd"
print_info "This will take several minutes..."
echo ""

START_WRITE=$(date +%s)

oc exec -n openshift-etcd $ETCD_POD -c etcd -- sh -c "
  for i in \$(seq 1 $NUM_KEYS); do
    # Generate random data and pipe directly to etcdctl to avoid argument length limits
    head -c $PAYLOAD_SIZE /dev/urandom | base64 -w 0 | etcdctl put /test/large-data-\$i >/dev/null 2>&1

    if [ \$((\$i % 600)) -eq 0 ]; then
      echo \"  Written \$i / $NUM_KEYS keys... (\$(date +'%H:%M:%S'))\"
    fi
  done

  echo \"All keys written successfully!\"
"

END_WRITE=$(date +%s)
WRITE_DURATION=$((END_WRITE - START_WRITE))

print_info "Write completed in ${WRITE_DURATION} seconds"
echo ""

# Wait for etcd to flush writes
print_info "Waiting for etcd to flush writes to disk..."
sleep 10

# Show new database size
print_header "Database Size After Writes"
oc exec -n openshift-etcd $ETCD_POD -c etcd -- ls -lh /var/lib/etcd/member/snap/db

DB_SIZE=$(oc exec -n openshift-etcd $ETCD_POD -c etcd -- stat -c%s /var/lib/etcd/member/snap/db 2>/dev/null || echo 0)
if [ $DB_SIZE -gt 0 ]; then
  print_info "Database size: $(numfmt --to=iec $DB_SIZE 2>/dev/null || echo "$DB_SIZE bytes")"
fi
echo ""

# Verify data was written
print_header "Verifying Data"
oc exec -n openshift-etcd $ETCD_POD -c etcd -- sh -c '
  KEY_COUNT=$(etcdctl get /test/ --prefix --keys-only | grep -v "^$" | wc -l)
  echo "Total keys under /test/: $KEY_COUNT"

  SAMPLE_SIZE=$(etcdctl get /test/large-data-1 --print-value-only 2>/dev/null | wc -c)
  if [ $SAMPLE_SIZE -gt 0 ]; then
    echo "Sample key size: $(numfmt --to=iec $SAMPLE_SIZE 2>/dev/null || echo "$SAMPLE_SIZE bytes")"
  fi
'
echo ""

# Create fragmentation by deleting keys
print_header "Creating Fragmentation"
DELETE_COUNT=$((NUM_KEYS * DELETE_PERCENTAGE / 100))
print_info "Deleting ${DELETE_COUNT} keys (${DELETE_PERCENTAGE}%) to create reclaimable space..."
echo ""

START_DELETE=$(date +%s)

oc exec -n openshift-etcd $ETCD_POD -c etcd -- sh -c "
  for i in \$(seq 1 $DELETE_COUNT); do
    etcdctl del /test/large-data-\$i >/dev/null 2>&1

    if [ \$((\$i % 600)) -eq 0 ]; then
      echo \"  Deleted \$i / $DELETE_COUNT keys... (\$(date +'%H:%M:%S'))\"
    fi
  done

  echo \"Deletions complete!\"
"

END_DELETE=$(date +%s)
DELETE_DURATION=$((END_DELETE - START_DELETE))

print_info "Delete completed in ${DELETE_DURATION} seconds"
sleep 5
echo ""

# Final summary
print_header "Setup Complete!"

echo "Results:"
echo "  - Keys created: $NUM_KEYS"
echo "  - Keys deleted (fragmentation): $DELETE_COUNT"
echo "  - Keys remaining: $((NUM_KEYS - DELETE_COUNT))"
echo "  - Write duration: ${WRITE_DURATION} seconds"
echo "  - Delete duration: ${DELETE_DURATION} seconds"
echo ""
echo "⚠️  IMPORTANT: Do NOT run defrag yet!"
echo "   Fragmentation has been created and is ready for testing."
echo ""


# Show final database size
print_header "Final Database Status"
oc exec -n openshift-etcd $ETCD_POD -c etcd -- ls -lh /var/lib/etcd/member/snap/db
echo ""
oc exec -n openshift-etcd $ETCD_POD -c etcd -- etcdctl endpoint status --write-out=table

echo ""
print_header "Database Ready for Write Availability Testing!"
echo ""
print_info "Next steps:"
echo "  1. Run continuous writes: /tmp/etcd-continuous-writes.sh"
echo "  2. Trigger defrag while writes are running"
echo "  3. Measure write success rate (should be >95% with PR #378)"
echo ""
