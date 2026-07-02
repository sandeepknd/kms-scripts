#!/bin/bash
set -euo pipefail

# =========================================
# CONFIGURATION VARIABLES
# =========================================
# These can be overridden by environment variables

# Vault version and repository
export VAULT_VERSION="${VAULT_VERSION:-2.0.0-ent}"
export VAULT_CHART_VERSION="${VAULT_CHART_VERSION:-0.28.1}"
export VAULT_IMAGE_REPOSITORY="${VAULT_IMAGE_REPOSITORY:-docker.io/hashicorp/vault-enterprise}"

# Kubernetes namespace for Vault
export VAULT_NAMESPACE="${VAULT_NAMESPACE:-vault-kms}"

# Vault Enterprise namespace (different from Kubernetes namespace)
export VAULT_ENTERPRISE_NS="${VAULT_ENTERPRISE_NS:-admin}"

# Transit key name
export VAULT_KMS_KEY_NAME="${VAULT_KMS_KEY_NAME:-kms-key}"

# Kubeconfig location
export SHARED_DIR="${SHARED_DIR:-${HOME}/.kube}"

echo "========================================="
echo "Vault Enterprise Setup for KMS"
echo "========================================="
echo "Version: ${VAULT_VERSION}"
echo "Helm Chart Version: ${VAULT_CHART_VERSION}"
echo "Image Repository: ${VAULT_IMAGE_REPOSITORY}"
echo "Kubernetes Namespace: ${VAULT_NAMESPACE}"
echo "Vault Enterprise Namespace: ${VAULT_ENTERPRISE_NS}"
echo "Transit Key: ${VAULT_KMS_KEY_NAME}"
echo ""

#export KUBECONFIG="${SHARED_DIR}/kubeconfig"

# Vault license secret name
VAULT_LICENSE_SECRET_NAME="vault-license"

# =========================================
# PART 1: VAULT INSTALLATION
# =========================================

echo "========================================="
echo "Part 1: Vault Enterprise Installation"
echo "========================================="
echo ""

# Install Helm if not present
if ! command -v helm &> /dev/null; then
  echo "Installing Helm..."
  HELM_VERSION="3.14.0"
  curl -fsSL "https://get.helm.sh/helm-v${HELM_VERSION}-linux-amd64.tar.gz" -o /tmp/helm.tar.gz
  tar -xzf /tmp/helm.tar.gz -C /tmp
  mkdir -p /tmp/bin
  mv /tmp/linux-amd64/helm /tmp/bin/helm
  chmod +x /tmp/bin/helm
  export PATH="/tmp/bin:$PATH"
  rm -rf /tmp/helm.tar.gz /tmp/linux-amd64
  echo "Helm installed: $(helm version --short)"
else
  echo "Helm already installed: $(helm version --short)"
fi

echo ""

# Create namespace
echo "Creating namespace ${VAULT_NAMESPACE}..."
oc create namespace "${VAULT_NAMESPACE}"

# Add restricted SCC for Vault service account
echo "Adding restricted SCC for Vault service account..."
oc adm policy add-scc-to-user restricted -z vault -n "${VAULT_NAMESPACE}"

# Create Vault license secret from mounted credential
echo "Creating Vault license secret from mounted credential..."
oc create secret generic "${VAULT_LICENSE_SECRET_NAME}" \
  --from-file=license=/home/skundu/Downloads/vault.hclic \
  -n "${VAULT_NAMESPACE}"

# Add HashiCorp Helm repository
echo "Adding HashiCorp Helm repository..."
helm repo add hashicorp https://helm.releases.hashicorp.com
helm repo update

echo ""

# Install Vault via Helm with dev mode and TLS enabled
echo "Installing Vault Enterprise v${VAULT_VERSION} in dev mode with TLS..."
helm upgrade --install vault hashicorp/vault \
  --namespace "${VAULT_NAMESPACE}" \
  --version "${VAULT_CHART_VERSION}" \
  --set global.enabled=true \
  --set global.openshift=true \
  --set global.tlsDisable=false \
  --set server.dev.enabled=true \
  --set server.image.repository="${VAULT_IMAGE_REPOSITORY}" \
  --set server.image.tag="${VAULT_VERSION}" \
  --set injector.enabled=false \
  --set 'server.extraEnvironmentVars.VAULT_DISABLE_USER_LOCKOUT=true' \
  --set 'server.extraEnvironmentVars.VAULT_CACERT=/var/run/tls/vault-ca.pem' \
  --set "server.enterpriseLicense.secretName=${VAULT_LICENSE_SECRET_NAME}" \
  --set "server.enterpriseLicense.secretKey=license" \
  --set "server.extraArgs=-dev-tls -dev-tls-cert-dir=/var/run/tls -dev-tls-san=vault -dev-tls-san=vault.${VAULT_NAMESPACE}.svc" \
  --set 'server.volumes[0].name=tls' \
  --set-json 'server.volumes[0].emptyDir={}' \
  --set 'server.volumeMounts[0].name=tls' \
  --set 'server.volumeMounts[0].mountPath=/var/run/tls' \
  --wait \
  --timeout 10m

# Helm wait passes even when vault pod is 0/1 Running, so wait for ready condition
echo "Waiting for Vault pod to be ready..."
oc wait --for=condition=ready pod/vault-0 -n "${VAULT_NAMESPACE}" --timeout=5m

# Extract CA certificate from Vault pod
echo ""
echo "Extracting CA certificate from Vault pod..."
CA_CERT_TMP="/tmp/vault-ca-${VAULT_NAMESPACE}.pem"
oc exec vault-0 -n "${VAULT_NAMESPACE}" -- cat /var/run/tls/vault-ca.pem > "${CA_CERT_TMP}"
echo "  ✓ CA certificate extracted"

# Create or update ConfigMap with CA certificate in openshift-config
echo ""
echo "Creating ConfigMap vault-ca-bundle in openshift-config..."
oc create configmap vault-ca-bundle \
  --from-file=ca-bundle.crt="${CA_CERT_TMP}" \
  -n openshift-config \
  --dry-run=client -o yaml | oc apply -f -
echo "  ✓ ConfigMap vault-ca-bundle created/updated"

# Clean up temporary CA file
rm -f "${CA_CERT_TMP}"

echo ""
echo "Vault Enterprise Installation Complete"
echo "  - Namespace: ${VAULT_NAMESPACE}"
echo "  - Version: ${VAULT_VERSION}"
echo "  - Service: https://vault.${VAULT_NAMESPACE}.svc:8200"
echo "  - Pod: vault-0 (Ready)"
echo "  - TLS: Enabled (dev mode with auto-generated certificates)"
echo "  - TLS CA: /var/run/tls/vault-ca.pem (inside pod)"
echo "  - CA ConfigMap: vault-ca-bundle (openshift-config namespace)"
echo ""

# =========================================
# PART 2: VAULT CONFIGURATION
# =========================================

echo "========================================="
echo "Part 2: Vault Configuration for KMS"
echo "========================================="
echo ""

# In dev mode, Vault is already initialized and unsealed with root token "root"
ROOT_TOKEN="root"

echo "Configuring Vault for KMS..."
echo ""

# Create Vault Enterprise namespace
echo "Creating Vault Enterprise namespace '${VAULT_ENTERPRISE_NS}'..."
oc exec vault-0 -n "${VAULT_NAMESPACE}" -- \
  env VAULT_TOKEN="${ROOT_TOKEN}" vault namespace create "${VAULT_ENTERPRISE_NS}"

# Enable transit secret engine in the Enterprise namespace
echo "Enabling transit secret engine in namespace '${VAULT_ENTERPRISE_NS}'..."
oc exec vault-0 -n "${VAULT_NAMESPACE}" -- \
  env VAULT_TOKEN="${ROOT_TOKEN}" vault secrets enable -namespace="${VAULT_ENTERPRISE_NS}" -path=transit transit

# Create encryption key in the Enterprise namespace
echo "Creating transit encryption key in namespace '${VAULT_ENTERPRISE_NS}'..."
oc exec vault-0 -n "${VAULT_NAMESPACE}" -- \
  env VAULT_TOKEN="${ROOT_TOKEN}" vault write -namespace="${VAULT_ENTERPRISE_NS}" -f transit/keys/${VAULT_KMS_KEY_NAME}

# Enable AppRole auth in the Enterprise namespace
echo "Enabling AppRole authentication in namespace '${VAULT_ENTERPRISE_NS}'..."
oc exec vault-0 -n "${VAULT_NAMESPACE}" -- \
  env VAULT_TOKEN="${ROOT_TOKEN}" vault auth enable -namespace="${VAULT_ENTERPRISE_NS}" approle

# Create KMS policy in the Enterprise namespace
echo "Creating KMS policy in namespace '${VAULT_ENTERPRISE_NS}'..."
oc exec vault-0 -n "${VAULT_NAMESPACE}" -- \
  sh -c "VAULT_TOKEN=${ROOT_TOKEN} vault policy write -namespace=${VAULT_ENTERPRISE_NS} kms-policy - <<POLICY
path \"transit/encrypt/${VAULT_KMS_KEY_NAME}\" {
  capabilities = [\"update\"]
}
path \"transit/decrypt/${VAULT_KMS_KEY_NAME}\" {
  capabilities = [\"update\"]
}
path \"transit/keys/${VAULT_KMS_KEY_NAME}\" {
  capabilities = [\"read\"]
}
path \"sys/license/status\" {
  capabilities = [\"read\"]
}
POLICY"

# Create AppRole role in the Enterprise namespace
echo "Creating AppRole role in namespace '${VAULT_ENTERPRISE_NS}'..."
oc exec vault-0 -n "${VAULT_NAMESPACE}" -- \
  env VAULT_TOKEN="${ROOT_TOKEN}" vault write -namespace="${VAULT_ENTERPRISE_NS}" auth/approle/role/kms-plugin \
    token_policies=kms-policy \
    token_ttl=1h \
    token_max_ttl=4h

# Get AppRole credentials from the Enterprise namespace
echo "Retrieving AppRole credentials from namespace '${VAULT_ENTERPRISE_NS}'..."
ROLE_ID=$(oc exec vault-0 -n "${VAULT_NAMESPACE}" -- \
  env VAULT_TOKEN="${ROOT_TOKEN}" vault read -namespace="${VAULT_ENTERPRISE_NS}" -field=role_id auth/approle/role/kms-plugin/role-id)
SECRET_ID=$(oc exec vault-0 -n "${VAULT_NAMESPACE}" -- \
  env VAULT_TOKEN="${ROOT_TOKEN}" vault write -namespace="${VAULT_ENTERPRISE_NS}" -field=secret_id -f auth/approle/role/kms-plugin/secret-id)

# Create vault-credentials secret
echo "Creating vault-credentials secret..."
oc create secret generic vault-credentials \
  --from-literal=role-id="${ROLE_ID}" \
  --from-literal=secret-id="${SECRET_ID}" \
  --from-literal=root-token="${ROOT_TOKEN}" \
  -n "${VAULT_NAMESPACE}"

echo "Vault credentials saved to vault-credentials secret"

echo ""
echo "========================================="
echo "Vault Setup Complete"
echo "========================================="
echo ""
echo "Summary:"
echo "  - Vault Service: vault.${VAULT_NAMESPACE}.svc:8200"
echo "  - Kubernetes Namespace: ${VAULT_NAMESPACE}"
echo "  - Vault Enterprise Namespace: ${VAULT_ENTERPRISE_NS}"
echo "  - Version: ${VAULT_VERSION}"
echo "  - Transit Key: ${VAULT_KMS_KEY_NAME}"
echo "  - Credentials Secret: vault-credentials"
echo "  - ROLE_ID: ${ROLE_ID}"
echo ""
echo "Vault is now ready for KMS integration"
echo ""

# Create vault-approle-secret in openshift-config namespace
echo "Creating vault-approle-secret in openshift-config namespace..."
oc create secret generic vault-approle-secret \
  -n openshift-config \
  --from-literal=role-id=$(oc get secret vault-credentials -n vault-kms -o jsonpath='{.data.role-id}' | base64 -d) \
  --from-literal=secret-id=$(oc get secret vault-credentials -n vault-kms -o jsonpath='{.data.secret-id}' | base64 -d)
echo "  ✓ vault-approle-secret created in openshift-config"
echo ""
