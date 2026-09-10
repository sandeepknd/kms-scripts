#!/bin/bash
set -euo pipefail

# Configuration — override via environment variables
REGISTRY=${REGISTRY:-"quay.io/rhn_support_skundu"}
OPERATOR_IMAGE=${OPERATOR_IMAGE:-"${REGISTRY}/jobset-operator:latest"}
BUNDLE_IMAGE=${BUNDLE_IMAGE:-"${REGISTRY}/jobset-operator-bundle:latest"}
NAMESPACE=${NAMESPACE:-"openshift-jobset-operator"}
CONTAINER_CMD=${CONTAINER_CMD:-"docker"}
TIMEOUT=${TIMEOUT:-"10m"}
SKIP_BUILD=${SKIP_BUILD:-"false"}
CERT_MANAGER_VERSION=${CERT_MANAGER_VERSION:-"v1.17.0"}
ACTION=${1:-"deploy"}

usage() {
    cat <<'EOF'
Usage: ./deploy-olm-js.sh [ACTION]

Deploy or clean up the JobSet Operator via OLM on an OpenShift cluster.

Actions:
  (none)      Build, push, and deploy the operator (default)
  --cleanup   Remove the operator, OLM resources, and namespace
  --help      Show this help message

Environment variables:
  REGISTRY              Container registry         (default: quay.io/rhn_support_skundu)
  OPERATOR_IMAGE        Operator image reference    (default: ${REGISTRY}/jobset-operator:latest)
  BUNDLE_IMAGE          Bundle image reference      (default: ${REGISTRY}/jobset-operator-bundle:latest)
  NAMESPACE             Target namespace            (default: openshift-jobset-operator)
  CONTAINER_CMD         Container build tool        (default: docker)
  TIMEOUT               OLM bundle install timeout  (default: 10m)
  SKIP_BUILD            Skip image build and push   (default: false)
  CERT_MANAGER_VERSION  cert-manager version        (default: v1.17.0)

Examples:
  # Full build and deploy (build images, push, install cert-manager, deploy via OLM)
  ./deploy-olm-js.sh

  # Deploy with images already pushed (skip build)
  SKIP_BUILD=true ./deploy-olm-js.sh

  # Deploy using podman instead of docker
  CONTAINER_CMD=podman ./deploy-olm-js.sh

  # Deploy to a custom registry
  REGISTRY=quay.io/myuser ./deploy-olm-js.sh

  # Deploy with a custom operator image tag
  OPERATOR_IMAGE=quay.io/rhn_support_skundu/jobset-operator:test \
  BUNDLE_IMAGE=quay.io/rhn_support_skundu/jobset-operator-bundle:test \
  ./deploy-olm-js.sh

  # Deploy with a different cert-manager version
  CERT_MANAGER_VERSION=v1.16.0 ./deploy-olm-js.sh

  # Clean up everything (operator CR, OLM resources, namespace)
  ./deploy-olm-js.sh --cleanup

  # Clean up a custom namespace
  NAMESPACE=my-test-ns ./deploy-olm-js.sh --cleanup

Prerequisites:
  - oc (logged into an OpenShift cluster)
  - operator-sdk
  - docker or podman
EOF
    exit 0
}

# Help mode
if [[ "${ACTION}" == "--help" || "${ACTION}" == "-h" ]]; then
    usage
fi

# Cleanup mode
if [[ "${ACTION}" == "--cleanup" ]]; then
    echo "=== JobSet Operator OLM Cleanup ==="
    echo "Namespace: ${NAMESPACE}"
    echo ""

    echo "=== Deleting JobSetOperator CR ==="
    oc delete jobsetoperator cluster --ignore-not-found

    echo "=== Cleaning up OLM resources ==="
    operator-sdk cleanup job-set -n "${NAMESPACE}" 2>/dev/null || true
    sleep 5

    echo "=== Deleting namespace ==="
    oc delete namespace "${NAMESPACE}" --ignore-not-found

    echo ""
    echo "=== Cleanup complete ==="
    echo "NOTE: cert-manager and ImageContentSourcePolicy were left in place."
    echo "To remove them manually:"
    echo "  oc delete -f https://github.com/cert-manager/cert-manager/releases/download/${CERT_MANAGER_VERSION}/cert-manager.yaml"
    echo "  oc delete imagecontentsourcepolicy mirror-set-412"
    exit 0
fi

echo "=== JobSet Operator OLM Deployment ==="
echo "Registry:       ${REGISTRY}"
echo "Operator image: ${OPERATOR_IMAGE}"
echo "Bundle image:   ${BUNDLE_IMAGE}"
echo "Namespace:      ${NAMESPACE}"
echo "Container tool: ${CONTAINER_CMD}"
echo ""

# Check prerequisites
for cmd in oc operator-sdk "${CONTAINER_CMD}"; do
    if ! command -v "${cmd}" &>/dev/null; then
        echo "ERROR: ${cmd} is not installed"
        exit 1
    fi
done

if ! oc whoami &>/dev/null; then
    echo "ERROR: Not logged into an OpenShift cluster. Run 'oc login' first."
    exit 1
fi

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "${REPO_DIR}"

if [[ "${SKIP_BUILD}" != "true" ]]; then
    # Generate Dockerfile.local if not present
    if [[ ! -f Dockerfile.local ]]; then
        echo "=== Generating Dockerfile.local ==="
        cat > Dockerfile.local <<'OPERATOR_DOCKERFILE'
FROM golang:1.26 AS builder
WORKDIR /build
COPY . .
RUN make build --warn-undefined-variables

FROM registry.access.redhat.com/ubi9/ubi-minimal:latest
COPY --from=builder /build/jobset-operator /usr/bin/
COPY --from=builder /build/LICENSE /licenses/
USER 1001
OPERATOR_DOCKERFILE
    fi

    # Generate bundle.Dockerfile.local if not present
    if [[ ! -f bundle.Dockerfile.local ]]; then
        echo "=== Generating bundle.Dockerfile.local ==="
        cat > bundle.Dockerfile.local <<'BUNDLE_DOCKERFILE'
FROM registry.access.redhat.com/ubi9/ubi-minimal:latest AS builder

ARG OPERATOR_IMAGE=quay.io/rhn_support_skundu/jobset-operator:latest
ARG OPERAND_IMAGE=registry.redhat.io/job-set/jobset-rhel9@sha256:2f448ef8b7a2018bfbd5273cfa43a76063d4a4fd7efd620ae2de1f918a6c044b

COPY manifests /manifests-src
COPY metadata /metadata

RUN microdnf install -y findutils sed && microdnf clean all \
    && cp -r /manifests-src /manifests \
    && find /manifests/ -type f -exec sed -i "s|\${OPERAND_IMAGE}|${OPERAND_IMAGE}|g" {} \; \
    && find /manifests/ -type f -exec sed -i "s|\${OPERATOR_IMAGE}|${OPERATOR_IMAGE}|g" {} \;

FROM registry.access.redhat.com/ubi9/ubi-minimal:latest

COPY --from=builder /manifests /manifests
COPY --from=builder /metadata /metadata
COPY LICENSE /licenses/

LABEL operators.operatorframework.io.bundle.mediatype.v1=registry+v1
LABEL operators.operatorframework.io.bundle.manifests.v1=manifests/
LABEL operators.operatorframework.io.bundle.metadata.v1=metadata/
LABEL operators.operatorframework.io.bundle.package.v1=job-set
LABEL operators.operatorframework.io.bundle.channels.v1=stable
LABEL operators.operatorframework.io.bundle.channel.default.v1=stable

USER 1001
BUNDLE_DOCKERFILE
    fi

    # Step 1: Build operator image
    echo "=== Building operator image ==="
    ${CONTAINER_CMD} build -f Dockerfile.local -t "${OPERATOR_IMAGE}" .

    # Step 2: Push operator image
    echo "=== Pushing operator image ==="
    ${CONTAINER_CMD} push "${OPERATOR_IMAGE}"

    # Step 3: Build bundle image
    echo "=== Building bundle image ==="
    ${CONTAINER_CMD} build -f bundle.Dockerfile.local \
        --build-arg OPERATOR_IMAGE="${OPERATOR_IMAGE}" \
        -t "${BUNDLE_IMAGE}" .

    # Step 4: Push bundle image
    echo "=== Pushing bundle image ==="
    ${CONTAINER_CMD} push "${BUNDLE_IMAGE}"
else
    echo "=== Skipping build (SKIP_BUILD=true) ==="
fi

# Step 5: Ensure image registry mirroring is configured for operand image pull
echo "=== Ensuring image registry mirroring is configured ==="
if oc get imagecontentsourcepolicy mirror-set-412 &>/dev/null; then
    echo "ImageContentSourcePolicy mirror-set-412 already exists, skipping"
else
    echo "Applying ImageContentSourcePolicy for registry mirroring"
    oc apply -f - <<'ICSP_EOF'
apiVersion: operator.openshift.io/v1alpha1
kind: ImageContentSourcePolicy
metadata:
  name: mirror-set-412
spec:
  repositoryDigestMirrors:
  - mirrors:
    - registry.stage.redhat.io
    source: registry.redhat.io
  - mirrors:
    - brew.registry.redhat.io
    source: registry.stage.redhat.io
  - mirrors:
    - brew.registry.redhat.io
    source: registry-proxy.engineering.redhat.com
ICSP_EOF
    echo "NOTE: ImageContentSourcePolicy may trigger node restarts. Waiting for nodes to be ready..."
    oc wait machineconfigpool/worker --for=condition=Updated --timeout=10m 2>/dev/null || true
fi

# Step 6: Install cert-manager if not present
echo "=== Ensuring cert-manager is installed ==="
if oc get crd issuers.cert-manager.io &>/dev/null; then
    echo "cert-manager already installed, skipping"
else
    echo "Installing cert-manager ${CERT_MANAGER_VERSION}"
    oc apply -f "https://github.com/cert-manager/cert-manager/releases/download/${CERT_MANAGER_VERSION}/cert-manager.yaml"
    echo "Waiting for cert-manager pods to be ready..."
    oc -n cert-manager wait --for=condition=Ready pod -l app.kubernetes.io/instance=cert-manager --timeout=2m
fi

# Step 7: Create namespace if it doesn't exist
echo "=== Creating namespace ==="
oc get namespace "${NAMESPACE}" &>/dev/null || \
    oc create namespace "${NAMESPACE}"

# Step 8: Clean up any previous installation
echo "=== Cleaning up previous installation (if any) ==="
operator-sdk cleanup job-set -n "${NAMESPACE}" 2>/dev/null || true
# Wait for cleanup to finish
sleep 5

# Step 9: Deploy via operator-sdk run bundle
echo "=== Deploying operator bundle via OLM ==="
operator-sdk run bundle "${BUNDLE_IMAGE}" \
    --timeout="${TIMEOUT}" \
    --security-context-config=restricted \
    -n "${NAMESPACE}"

# Step 10: Create the operator CR
echo "=== Creating JobSetOperator CR ==="
oc apply -f deploy/11_jobset-operator.cr.yaml

# Step 11: Wait for operand to be ready
echo "=== Waiting for operand deployment ==="
for i in $(seq 1 30); do
    if oc get deployment jobset-controller-manager -n "${NAMESPACE}" &>/dev/null; then
        oc rollout status deployment/jobset-controller-manager -n "${NAMESPACE}" --timeout=120s && break
    fi
    echo "Waiting for operand deployment to appear... (${i}/30)"
    sleep 5
done

# Step 12: Verify
echo ""
echo "=== Verification ==="
echo "--- Pods ---"
oc get pods -n "${NAMESPACE}"
echo ""
echo "--- CSV ---"
oc get csv -n "${NAMESPACE}"
echo ""
echo "--- NetworkPolicy ---"
oc get networkpolicy -n "${NAMESPACE}"
echo ""
echo "--- Operator Status ---"
oc get jobsetoperator cluster -o jsonpath='{.status.conditions}' | jq . 2>/dev/null || \
    oc get jobsetoperator cluster -o yaml | grep -A 5 'conditions:'
echo ""
echo "=== Deployment complete ==="
echo ""
echo "To clean up: ./deploy-olm-js.sh --cleanup"
