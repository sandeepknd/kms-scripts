#!/bin/bash
set -euo pipefail

NAMESPACE=${NAMESPACE:-"openshift-jobset-operator"}
OPERAND_DEPLOYMENT=${OPERAND_DEPLOYMENT:-"jobset-controller-manager"}
WAIT_SECONDS=${WAIT_SECONDS:-"12"}

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

PASS_COUNT=0
FAIL_COUNT=0

usage() {
    cat <<'EOF'
Usage: ./test-netpol.sh [OPTIONS]

Run NetworkPolicy traffic tests against the jobset-controller-manager operand.

Options:
  --help      Show this help message

Environment variables:
  NAMESPACE             Operator namespace          (default: openshift-jobset-operator)
  OPERAND_DEPLOYMENT    Operand deployment name     (default: jobset-controller-manager)
  WAIT_SECONDS          Seconds to wait for test pod completion (default: 12)

Examples:
  # Run all tests
  ./test-netpol.sh

  # Run against a custom namespace
  NAMESPACE=my-ns ./test-netpol.sh

Prerequisites:
  - oc (logged into an OpenShift cluster)
  - Operator and operand deployed in the target namespace
  - NetworkPolicy jobset-allow-operand applied
EOF
    exit 0
}

if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
    usage
fi

get_operand_pod_ip() {
    oc get pods -n "${NAMESPACE}" -l "app.kubernetes.io/name=jobset,control-plane=controller-manager" \
        -o jsonpath='{.items[0].status.podIP}' 2>/dev/null
}

get_operand_node() {
    oc get pods -n "${NAMESPACE}" -l "app.kubernetes.io/name=jobset,control-plane=controller-manager" \
        -o jsonpath='{.items[0].spec.nodeName}' 2>/dev/null
}

cleanup_test_pod() {
    local ns=$1
    oc delete pod netpol-test -n "${ns}" --ignore-not-found --wait=false >/dev/null 2>&1 || true
}

run_curl_test() {
    local ns=$1
    local url=$2

    cleanup_test_pod "${ns}"
    sleep 2

    oc run netpol-test --image=curlimages/curl -n "${ns}" --restart=Never \
        --overrides='{
            "spec": {
                "securityContext": {"runAsNonRoot": true, "runAsUser": 1000, "seccompProfile": {"type": "RuntimeDefault"}},
                "containers": [{
                    "name": "netpol-test",
                    "image": "curlimages/curl",
                    "command": ["curl", "-sk", "--connect-timeout", "5", "-o", "/dev/null", "-w", "%{http_code}", "'"${url}"'"],
                    "securityContext": {"allowPrivilegeEscalation": false, "capabilities": {"drop": ["ALL"]}}
                }]
            }
        }' >/dev/null 2>&1

    sleep "${WAIT_SECONDS}"
    oc logs netpol-test -n "${ns}" 2>/dev/null || echo "NO_LOGS"
    cleanup_test_pod "${ns}"
}

report() {
    local test_num=$1
    local test_name=$2
    local expected=$3
    local actual=$4

    if [[ "${actual}" == "${expected}" ]]; then
        echo -e "  [${GREEN}PASS${NC}] Test ${test_num}: ${test_name} (expected=${expected}, got=${actual})"
        PASS_COUNT=$((PASS_COUNT + 1))
    else
        echo -e "  [${RED}FAIL${NC}] Test ${test_num}: ${test_name} (expected=${expected}, got=${actual})"
        FAIL_COUNT=$((FAIL_COUNT + 1))
    fi
}

echo "=== JobSet Operand NetworkPolicy Traffic Tests ==="
echo ""

POD_IP=$(get_operand_pod_ip)
NODE_NAME=$(get_operand_node)

if [[ -z "${POD_IP}" ]]; then
    echo "ERROR: Could not find operand pod in namespace ${NAMESPACE}"
    exit 1
fi

echo "Operand pod IP:   ${POD_IP}"
echo "Operand node:     ${NODE_NAME}"
echo "Namespace:        ${NAMESPACE}"
echo ""

echo "--- Verifying NetworkPolicy ---"
oc get netpol -n "${NAMESPACE}"
echo ""

echo "--- Running traffic tests ---"
echo ""

# Test 1: Webhook (9443) from same namespace — SHOULD SUCCEED
echo -n "  Running Test 1: Webhook (9443) from same namespace..."
RESULT=$(run_curl_test "${NAMESPACE}" "https://${POD_IP}:9443")
echo ""
report 1 "Webhook (9443) from same namespace" "404" "${RESULT}"

# Test 2: Webhook (9443) from different namespace — SHOULD SUCCEED
echo -n "  Running Test 2: Webhook (9443) from default namespace..."
RESULT=$(run_curl_test "default" "https://${POD_IP}:9443")
echo ""
report 2 "Webhook (9443) from default namespace" "404" "${RESULT}"

# Test 3: Webhook via kube-apiserver (create JobSet) — SHOULD SUCCEED
echo -n "  Running Test 3: Webhook via kube-apiserver (create JobSet)..."
CREATE_OUTPUT=$(oc apply -f - 2>&1 <<'EOF'
apiVersion: jobset.x-k8s.io/v1alpha2
kind: JobSet
metadata:
  name: netpol-test-webhook
  namespace: default
spec:
  replicatedJobs:
  - name: test-job
    replicas: 1
    template:
      spec:
        parallelism: 1
        completions: 1
        template:
          spec:
            containers:
            - name: test
              image: registry.access.redhat.com/ubi9/ubi-minimal:latest
              command: ["sleep", "10"]
            restartPolicy: Never
EOF
)
echo ""
if echo "${CREATE_OUTPUT}" | grep -q "created\|configured\|unchanged"; then
    report 3 "Webhook via kube-apiserver (create JobSet)" "created" "created"
else
    report 3 "Webhook via kube-apiserver (create JobSet)" "created" "failed"
fi
oc delete jobset netpol-test-webhook -n default --ignore-not-found >/dev/null 2>&1 || true

# Test 4: Webhook (9443) from host network (node) — SHOULD SUCCEED
echo -n "  Running Test 4: Webhook (9443) from host network (node)..."
HOST_RESULT=$(oc debug "node/${NODE_NAME}" -- chroot /host curl -sk --connect-timeout 5 -o /dev/null -w '%{http_code}' "https://${POD_IP}:9443" 2>/dev/null | tail -1)
echo ""
report 4 "Webhook (9443) from host network" "404" "${HOST_RESULT}"

# Test 5: Metrics (8443) from monitoring namespace — SHOULD SUCCEED
echo -n "  Running Test 5: Metrics (8443) from openshift-monitoring..."
RESULT=$(run_curl_test "openshift-monitoring" "https://${POD_IP}:8443")
echo ""
report 5 "Metrics (8443) from openshift-monitoring" "404" "${RESULT}"

# Test 6: Metrics (8443) from random namespace — SHOULD BE BLOCKED
echo -n "  Running Test 6: Metrics (8443) from random namespace..."
oc create namespace test-netpol-block >/dev/null 2>&1 || true
RESULT=$(run_curl_test "test-netpol-block" "https://${POD_IP}:8443")
oc delete namespace test-netpol-block --ignore-not-found >/dev/null 2>&1 &
echo ""
report 6 "Metrics (8443) from random namespace [BLOCKED]" "000" "${RESULT}"

# Test 7: Unlisted port (8080) from same namespace — SHOULD BE BLOCKED
echo -n "  Running Test 7: Unlisted port (8080) from same namespace..."
RESULT=$(run_curl_test "${NAMESPACE}" "https://${POD_IP}:8080")
echo ""
report 7 "Unlisted port (8080) from same namespace [BLOCKED]" "000" "${RESULT}"

# Test 8: Egress from operand (API server) — SHOULD SUCCEED
echo -n "  Running Test 8: Egress from operand to API server..."
EGRESS_RESULT=$(oc exec -n "${NAMESPACE}" "deployment/${OPERAND_DEPLOYMENT}" -- curl -sk --connect-timeout 5 -o /dev/null -w '%{http_code}' https://kubernetes.default.svc.cluster.local/healthz 2>/dev/null)
echo ""
report 8 "Egress from operand to API server" "200" "${EGRESS_RESULT}"

echo ""
echo "--- Running policy reconciliation (mutation) tests ---"
echo ""

NETPOL_NAME="jobset-allow-operand"

wait_for_reconcile() {
    local field=$1
    local expected=$2
    local max_attempts=${3:-10}
    for i in $(seq 1 "${max_attempts}"); do
        CURRENT=$(oc get netpol "${NETPOL_NAME}" -n "${NAMESPACE}" -o jsonpath="${field}" 2>/dev/null)
        if [[ "${CURRENT}" == "${expected}" ]]; then
            return 0
        fi
        sleep 1
    done
    return 1
}

# Test 9: Patch webhook port — operator should revert
echo -n "  Running Test 9: Patch webhook port 9443 -> 1234..."
oc patch netpol "${NETPOL_NAME}" -n "${NAMESPACE}" --type='json' \
    -p='[{"op": "replace", "path": "/spec/ingress/0/ports/0/port", "value": 1234}]' >/dev/null 2>&1
sleep 3
REVERTED_PORT=$(oc get netpol "${NETPOL_NAME}" -n "${NAMESPACE}" -o jsonpath='{.spec.ingress[0].ports[0].port}' 2>/dev/null)
echo ""
report 9 "Patch webhook port reverted to 9443" "9443" "${REVERTED_PORT}"

# Test 10: Remove webhook ingress rule — operator should restore
echo -n "  Running Test 10: Remove webhook ingress rule..."
oc patch netpol "${NETPOL_NAME}" -n "${NAMESPACE}" --type='json' \
    -p='[{"op": "remove", "path": "/spec/ingress/0"}]' >/dev/null 2>&1
sleep 3
RULE_COUNT=$(oc get netpol "${NETPOL_NAME}" -n "${NAMESPACE}" -o jsonpath='{.spec.ingress}' 2>/dev/null | python3 -c "import sys,json; print(len(json.load(sys.stdin)))" 2>/dev/null || echo "0")
echo ""
if [[ "${RULE_COUNT}" -ge 2 ]]; then
    report 10 "Webhook ingress rule restored" "restored" "restored"
else
    report 10 "Webhook ingress rule restored" "restored" "missing(${RULE_COUNT})"
fi

# Test 11: Tamper monitoring namespace selector — operator should revert
echo -n "  Running Test 11: Tamper monitoring namespace selector..."
oc patch netpol "${NETPOL_NAME}" -n "${NAMESPACE}" --type='json' \
    -p='[{"op": "replace", "path": "/spec/ingress/1/from/0/namespaceSelector/matchLabels", "value": {"kubernetes.io/metadata.name": "fake-namespace"}}]' >/dev/null 2>&1
sleep 3
SELECTOR=$(oc get netpol "${NETPOL_NAME}" -n "${NAMESPACE}" -o jsonpath='{.spec.ingress[1].from[0].namespaceSelector.matchLabels}' 2>/dev/null)
echo ""
if echo "${SELECTOR}" | grep -q "cluster-monitoring"; then
    report 11 "Monitoring selector reverted" "reverted" "reverted"
else
    report 11 "Monitoring selector reverted" "reverted" "tampered"
fi

# Test 12: Remove all egress rules — operator should restore
echo -n "  Running Test 12: Remove egress rules..."
oc patch netpol "${NETPOL_NAME}" -n "${NAMESPACE}" --type='json' \
    -p='[{"op": "replace", "path": "/spec/egress", "value": []}]' >/dev/null 2>&1
sleep 3
EGRESS=$(oc get netpol "${NETPOL_NAME}" -n "${NAMESPACE}" -o jsonpath='{.spec.egress}' 2>/dev/null)
echo ""
if [[ "${EGRESS}" == "[{}]" || "${EGRESS}" == '[{"ports":[],"to":[]}]' ]]; then
    report 12 "Egress rules restored" "restored" "restored"
elif echo "${EGRESS}" | grep -q '{'; then
    report 12 "Egress rules restored" "restored" "restored"
else
    report 12 "Egress rules restored" "restored" "empty"
fi

# Test 13: Delete entire NetworkPolicy — operator should recreate
echo -n "  Running Test 13: Delete NetworkPolicy entirely..."
oc delete netpol "${NETPOL_NAME}" -n "${NAMESPACE}" >/dev/null 2>&1
RECREATED="false"
for i in $(seq 1 15); do
    if oc get netpol "${NETPOL_NAME}" -n "${NAMESPACE}" >/dev/null 2>&1; then
        RECREATED="true"
        break
    fi
    sleep 1
done
echo ""
report 13 "NetworkPolicy recreated after deletion" "true" "${RECREATED}"

# Summary
echo ""
echo "=== Results ==="
TOTAL=$((PASS_COUNT + FAIL_COUNT))
echo -e "  Total: ${TOTAL}  ${GREEN}Passed: ${PASS_COUNT}${NC}  ${RED}Failed: ${FAIL_COUNT}${NC}"
echo ""

if [[ ${FAIL_COUNT} -gt 0 ]]; then
    echo -e "${RED}Some tests failed.${NC}"
    exit 1
else
    echo -e "${GREEN}All tests passed.${NC}"
    exit 0
fi
