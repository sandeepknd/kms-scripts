# KMS Plugin Deployment Script - Documentation

This document provides a comprehensive guide for deploying the KMS (Key Management Service) plugin with HashiCorp Vault on OpenShift.

## Table of Contents

### Part 1: Script Usage Guide
- [Overview](#overview)
- [Prerequisites](#prerequisites)
- [Script Modes](#script-modes)
- [Command-Line Options](#command-line-options)
- [Usage Examples](#usage-examples)
- [Environment Variables](#environment-variables)
- [Quick Start](#quick-start)

### Part 2: Manual Command Reference
- [Common Commands (Both Modes)](#common-commands-both-modes)
- [Local Mode Commands](#local-mode-commands---local)
- [Cloud Mode Commands](#cloud-mode-commands---cloud)
- [Deployment Type Variations](#deployment-type-variations)
- [Post-Deployment Commands](#post-deployment-commands)
- [Command Execution Flow](#command-summary-by-execution-order)
- [Troubleshooting](#troubleshooting-commands)

---

# Part 1: Script Usage Guide

## Overview

The `deploy-kms-plugin.sh` script automates the deployment of a KMS plugin for OpenShift that integrates with HashiCorp Vault for etcd encryption at rest.

### Supported Modes

The script supports two deployment modes:

| Mode | Description | Default Deployment Type | Use Case |
|------|-------------|------------------------|----------|
| **`--local`** | Installs Vault locally using Helm | Static Pod | Development, testing, or isolated environments |
| **`--cloud`** | Uses existing cloud/external Vault | DaemonSet | Production with HashiCorp Cloud Platform (HCP) or self-hosted Vault |

### Deployment Types

Both modes support two deployment types:

| Type | Description | Pros | Cons |
|------|-------------|------|------|
| **`--static-pod`** | Deploys KMS plugin directly to control plane nodes via static pod manifests | No dependency on kube-apiserver, survives cluster issues | Manual node-by-node deployment |
| **`--daemonset`** | Deploys KMS plugin as a DaemonSet | Easier management, automatic scaling | Requires functional kube-apiserver |

---

## Prerequisites

### Required Tools

The script requires the following tools to be installed:

```bash
# OpenShift CLI
oc version

# JSON processor
jq --version

# HTTP client
curl --version

# Helm (required for --local mode only)
helm version
```

### Required Access

- OpenShift cluster admin access
- For cloud mode: Access to existing Vault instance with admin credentials
- For local mode: Cluster storage provisioner (for persistent Vault storage)

### Required Files

Ensure these files exist in the same directory as the script:
- `namespace.yaml` - KMS plugin namespace definition
- `serviceaccount.yaml` - Service account for DaemonSet deployment
- `daemonset.yaml` - DaemonSet deployment manifest

---

## Script Modes

### Local Mode (`--local`)

Automatically installs and configures Vault in your OpenShift cluster.

**What it does:**
1. Installs HashiCorp Vault using Helm chart
2. Deploys Vault to control plane nodes
3. Initializes and unseals Vault
4. Stores Vault keys in OpenShift secrets
5. Configures Transit encryption engine
6. Sets up AppRole authentication
7. Deploys KMS plugin

**Default configuration:**
- Namespace: `vault-system`
- Image: `docker.io/hashicorp/vault:1.15.4`
- Storage: 2Gi persistent volume
- Deployment: Static pod

### Cloud Mode (`--cloud`)

Connects to an existing Vault instance (HCP or self-hosted).

**What it does:**
1. Validates connectivity to Vault
2. Authenticates using token or username/password
3. Configures Transit encryption engine
4. Sets up AppRole authentication
5. Deploys KMS plugin

**Supported Vault types:**
- HashiCorp Cloud Platform (HCP)
- Self-hosted Vault Enterprise
- Self-hosted Vault Community Edition

---

## Command-Line Options

### Mode Selection (Required)

```bash
--cloud          # Use existing cloud/external Vault
--local          # Install Vault locally using Helm
```

### Deployment Type (Optional)

```bash
--static-pod     # Deploy KMS plugin as static pod on control plane nodes
--daemonset      # Deploy KMS plugin as DaemonSet
```

If not specified:
- `--local` defaults to `--static-pod`
- `--cloud` prompts for selection (default: `--daemonset`)

### Cloud Mode Options

```bash
--vault-addr <url>              # Vault server address (e.g., https://vault.example.com:8200)
--vault-namespace <namespace>   # Vault namespace (for Enterprise/HCP)
--token <token>                 # Vault authentication token
--username <user>               # Vault username (for userpass auth)
--password <pass>               # Vault password (for userpass auth)
--skip-tls-verify               # Skip TLS certificate verification (insecure)
```

### Help

```bash
--help, -h      # Display help message
```

---

## Usage Examples

### Example 1: Local Vault with Static Pod (Quickest for testing)

```bash
./deploy-kms-plugin.sh --local
```

**Interactive prompts:**
- Enable KMS FeatureGate? [Y/n]
- Enable KMS encryption on etcd now? [y/N]

### Example 2: Cloud Vault with DaemonSet

```bash
./deploy-kms-plugin.sh --cloud \
  --vault-addr "https://vault-cluster-public.hashicorp.cloud:8200" \
  --vault-namespace "admin" \
  --username "admin-user" \
  --password "your-password"
```

### Example 3: Cloud Vault with Static Pod (HCP)

```bash
./deploy-kms-plugin.sh --cloud --static-pod \
  --vault-addr "https://vault-cluster-public.hashicorp.cloud:8200" \
  --vault-namespace "admin" \
  --token "hvs.CAESIxxx..."
```

### Example 4: Local Vault with DaemonSet

```bash
./deploy-kms-plugin.sh --local --daemonset
```

### Example 5: Using Environment Variables

```bash
export VAULT_ADDR="https://vault.example.com:8200"
export VAULT_NAMESPACE="admin"
export VAULT_USERNAME="admin-user"
export VAULT_PASSWORD="password"

./deploy-kms-plugin.sh --cloud
```

### Example 6: Using Private Container Image

```bash
export QUAY_USERNAME="robot-account+kms"
export QUAY_PASSWORD="your-robot-token"

./deploy-kms-plugin.sh --local
```

### Example 7: Skip TLS Verification (Testing only)

```bash
./deploy-kms-plugin.sh --cloud --skip-tls-verify \
  --vault-addr "https://vault-dev.internal:8200" \
  --token "hvs.xxx"
```

---

## Environment Variables

The script supports the following environment variables:

| Variable | Description | Used in Mode |
|----------|-------------|--------------|
| `VAULT_ADDR` | Vault server address | Cloud |
| `VAULT_NAMESPACE` | Vault namespace | Cloud |
| `VAULT_TOKEN` | Vault authentication token | Cloud |
| `VAULT_USERNAME` | Vault username | Cloud |
| `VAULT_PASSWORD` | Vault password | Cloud |
| `QUAY_USERNAME` | Quay.io registry username | Both |
| `QUAY_PASSWORD` | Quay.io registry password/token | Both |

**Priority:** Command-line options override environment variables.

---

## Quick Start

### For Development/Testing (Local Vault)

```bash
# 1. Ensure prerequisites are installed
oc version && jq --version && helm version

# 2. Run the script
./deploy-kms-plugin.sh --local

# 3. Answer prompts
#    - Enable KMS FeatureGate? Y
#    - Enable KMS encryption on etcd now? Y

# 4. Wait for deployment (10-20 minutes)

# 5. Verify
oc get pods -n openshift-kms-plugin
oc get pods -n vault-system
```

### For Production (Cloud Vault / HCP)

```bash
# 1. Gather Vault information from HCP console
#    - Public Address (e.g., https://vault-xxx.hashicorp.cloud:8200)
#    - Namespace (usually "admin")
#    - Admin credentials

# 2. Run the script
./deploy-kms-plugin.sh --cloud \
  --vault-addr "https://your-vault.hashicorp.cloud:8200" \
  --vault-namespace "admin" \
  --username "admin" \
  --password "your-password"

# 3. Choose deployment type when prompted
#    - Enter choice [1/2] (default: 1): 1  # for DaemonSet

# 4. Answer prompts
#    - Enable KMS FeatureGate? Y
#    - Enable KMS encryption on etcd now? Y

# 5. Wait for deployment (10-20 minutes)

# 6. Verify
oc get pods -n openshift-kms-plugin
oc get clusteroperator kube-apiserver
```

---

## Important Notes

### FeatureGate Warning
- Setting `featureSet=CustomNoUpgrade` prevents minor version upgrades
- This is required for KMS encryption support
- Plan your upgrade strategy accordingly

### Rollout Time
- kube-apiserver rollout takes 10-20 minutes
- Each control plane node is updated sequentially
- Cluster remains available during rollout

### Static Pod Behavior
- Static pods appear with node name suffix (e.g., `vault-kube-kms-master-0`)
- Manifests are stored at `/etc/kubernetes/manifests/` on each node
- kubelet automatically manages static pod lifecycle

### Image Pull Considerations
- For private images with static pods, global pull secret must be updated
- Nodes may take 2-5 minutes to pick up new credentials
- Consider using public images for simpler deployment

### Vault Addresses
- **Local mode**: KMS plugin uses internal cluster IP `http://<vault-svc-ip>:8200`
- **Cloud mode**: KMS plugin uses external Vault address

---

# Part 2: Manual Command Reference

This section lists all commands executed by the script for both modes and deployment types. Use this for manual deployment or troubleshooting.

---

## Prerequisites Check

### Required Tools Verification
```bash
command -v oc >/dev/null 2>&1 || { echo "Error: oc is required"; exit 1; }
command -v jq >/dev/null 2>&1 || { echo "Error: jq is required"; exit 1; }
command -v curl >/dev/null 2>&1 || { echo "Error: curl is required"; exit 1; }
command -v helm >/dev/null 2>&1 || { echo "Error: helm is required"; exit 1; }  # For --local mode only
```

---

## Common Commands (Both Modes)

These commands are executed regardless of the mode selected:

### 1. Configure Vault for KMS

#### Enable Transit Secrets Engine
**Local mode:**
```bash
oc exec -n vault-system vault-0 -- sh -c "VAULT_TOKEN=$VAULT_TOKEN vault secrets enable transit"
```

**Cloud mode:**
```bash
curl -s --noproxy "*" \
  --header "X-Vault-Token: $VAULT_TOKEN" \
  --header "X-Vault-Namespace: $VAULT_NAMESPACE" \
  --request POST \
  --data '{"type": "transit"}' \
  "$VAULT_ADDR/v1/sys/mounts/transit"
```

#### Create KMS Key
**Local mode:**
```bash
oc exec -n vault-system vault-0 -- sh -c "VAULT_TOKEN=$VAULT_TOKEN vault write -f transit/keys/kms-key type=aes256-gcm96"
```

**Cloud mode:**
```bash
curl -s --noproxy "*" \
  --header "X-Vault-Token: $VAULT_TOKEN" \
  --header "X-Vault-Namespace: $VAULT_NAMESPACE" \
  --request POST \
  --data '{"type": "aes256-gcm96"}' \
  "$VAULT_ADDR/v1/transit/keys/kms-key"
```

#### Enable AppRole Authentication
**Local mode:**
```bash
oc exec -n vault-system vault-0 -- sh -c "VAULT_TOKEN=$VAULT_TOKEN vault auth enable approle"
oc exec -n vault-system vault-0 -- sh -c "VAULT_TOKEN=$VAULT_TOKEN vault auth list"
```

**Cloud mode:**
```bash
curl -s --noproxy "*" \
  --header "X-Vault-Token: $VAULT_TOKEN" \
  --header "X-Vault-Namespace: $VAULT_NAMESPACE" \
  --request POST \
  --data '{"type": "approle"}' \
  "$VAULT_ADDR/v1/sys/auth/approle"

curl -s --noproxy "*" \
  --header "X-Vault-Token: $VAULT_TOKEN" \
  --header "X-Vault-Namespace: $VAULT_NAMESPACE" \
  "$VAULT_ADDR/v1/sys/auth"
```

#### Create KMS Policy
**Local mode:**
```bash
oc exec -n vault-system vault-0 -- sh -c 'VAULT_TOKEN=$VAULT_TOKEN vault policy write kms-plugin-policy - <<EOF
path "transit/encrypt/kms-key" {
  capabilities = ["update"]
}
path "transit/decrypt/kms-key" {
  capabilities = ["update"]
}
path "transit/keys/kms-key" {
  capabilities = ["read"]
}
path "sys/license/status" {
  capabilities = ["read"]
}
EOF'
```

**Cloud mode:**
```bash
curl -s --noproxy "*" \
  --header "X-Vault-Token: $VAULT_TOKEN" \
  --header "X-Vault-Namespace: $VAULT_NAMESPACE" \
  --request PUT \
  --data '{
    "policy": "path \"transit/encrypt/kms-key\" { capabilities = [\"update\"] }\npath \"transit/decrypt/kms-key\" { capabilities = [\"update\"] }\npath \"transit/keys/kms-key\" { capabilities = [\"read\"] }\npath \"sys/license/status\" { capabilities = [\"read\"] }"
  }' \
  "$VAULT_ADDR/v1/sys/policies/acl/kms-plugin-policy"
```

#### Create AppRole Role
**Local mode:**
```bash
oc exec -n vault-system vault-0 -- sh -c "VAULT_TOKEN=$VAULT_TOKEN vault write auth/approle/role/kms-plugin \
  policies=\"kms-plugin-policy\" \
  token_ttl=1h \
  token_max_ttl=24h"
```

**Cloud mode:**
```bash
curl -s --noproxy "*" \
  --header "X-Vault-Token: $VAULT_TOKEN" \
  --header "X-Vault-Namespace: $VAULT_NAMESPACE" \
  --request POST \
  --data '{"policies": ["kms-plugin-policy"], "token_ttl": "1h", "token_max_ttl": "24h"}' \
  "$VAULT_ADDR/v1/auth/approle/role/kms-plugin"
```

#### Get AppRole Credentials
**Local mode:**
```bash
# Get Role ID
oc exec -n vault-system vault-0 -- sh -c "VAULT_TOKEN=$VAULT_TOKEN vault read auth/approle/role/kms-plugin/role-id -format=json"

# Get Secret ID
oc exec -n vault-system vault-0 -- sh -c "VAULT_TOKEN=$VAULT_TOKEN vault write -f auth/approle/role/kms-plugin/secret-id -format=json"
```

**Cloud mode:**
```bash
# Get Role ID
curl -s --noproxy "*" \
  --header "X-Vault-Token: $VAULT_TOKEN" \
  --header "X-Vault-Namespace: $VAULT_NAMESPACE" \
  "$VAULT_ADDR/v1/auth/approle/role/kms-plugin/role-id"

# Get Secret ID
curl -s --noproxy "*" \
  --header "X-Vault-Token: $VAULT_TOKEN" \
  --header "X-Vault-Namespace: $VAULT_NAMESPACE" \
  --request POST \
  "$VAULT_ADDR/v1/auth/approle/role/kms-plugin/secret-id"
```

### 2. Deploy KMS Plugin Namespace
```bash
oc apply -f namespace.yaml
```

### 3. Enable KMS Encryption FeatureGate
```bash
oc patch featuregate/cluster --type=merge -p '{
  "spec": {
    "featureSet": "CustomNoUpgrade",
    "customNoUpgrade": {
      "enabled": ["KMSEncryption"]
    }
  }
}'

# Wait for kube-apiserver rollout
oc wait clusteroperator kube-apiserver \
  --for=condition=Progressing=False \
  --timeout=1200s

# Check status
oc get clusteroperator kube-apiserver
```

---

## Local Mode Commands (`--local`)

### 1. Install Vault with Helm

#### Add Helm Repository
```bash
helm repo add hashicorp https://helm.releases.hashicorp.com
helm repo update
```

#### Create Namespace
```bash
oc create namespace vault-system
oc label namespace vault-system \
  pod-security.kubernetes.io/enforce=privileged \
  pod-security.kubernetes.io/audit=privileged \
  --overwrite
```

#### Install Vault
```bash
helm upgrade --install vault hashicorp/vault \
  --namespace vault-system \
  --values /tmp/vault-values.yaml \
  --disable-openapi-validation \
  --wait --timeout 5m
```

The Helm values file includes:
- Docker Hub image: `docker.io/hashicorp/vault:1.15.4`
- Persistent storage: 2Gi
- Node selector: `node-role.kubernetes.io/control-plane: ""`
- Standalone mode with file storage

#### Wait for Vault Pod
```bash
# Check pod status
oc get pod vault-0 -n vault-system -o jsonpath='{.status.phase}'

# Check vault status
oc exec -n vault-system vault-0 -- vault status
```

### 2. Initialize Vault

#### Check Initialization Status
```bash
oc exec -n vault-system vault-0 -- vault status -format=json
```

#### Initialize Vault (if not initialized)
```bash
oc exec -n vault-system vault-0 -- vault operator init -key-shares=1 -key-threshold=1 -format=json
```

#### Save Keys to Secret
```bash
oc create secret generic vault-init-keys \
  --namespace=vault-system \
  --from-literal=unseal-key="$UNSEAL_KEY" \
  --from-literal=root-token="$VAULT_TOKEN" \
  --dry-run=client -o yaml | oc apply -f -
```

#### Retrieve Existing Keys
```bash
# Check if secret exists
oc get secret vault-init-keys -n vault-system

# Get unseal key
oc get secret vault-init-keys -n vault-system -o jsonpath='{.data.unseal-key}' | base64 -d

# Get root token
oc get secret vault-init-keys -n vault-system -o jsonpath='{.data.root-token}' | base64 -d
```

### 3. Unseal Vault

#### Check Seal Status
```bash
oc exec -n vault-system vault-0 -- vault status -format=json
```

#### Unseal (if sealed)
```bash
oc exec -n vault-system vault-0 -- vault operator unseal "$UNSEAL_KEY"
```

### 4. Get Vault Service IP
```bash
oc get svc vault -n vault-system -o jsonpath='{.spec.clusterIP}'
```

---

## Cloud Mode Commands (`--cloud`)

### 1. DNS Resolution Check
```bash
# Extract hostname from VAULT_ADDR
vault_hostname=$(echo "$VAULT_ADDR" | sed -E 's|^https?://([^:/]+).*|\1|')

# Check DNS
nslookup "$vault_hostname"
# or
host "$vault_hostname"
```

### 2. Authenticate to Vault

#### Using Username/Password
```bash
curl -s --noproxy "*" \
  --header "X-Vault-Namespace: $VAULT_NAMESPACE" \
  --request POST \
  --data "{\"password\": \"$VAULT_PASSWORD\"}" \
  "$VAULT_ADDR/v1/auth/userpass/login/$VAULT_USERNAME"
```

#### Verify Connectivity
```bash
# Health check
curl -s --noproxy "*" --max-time 10 \
  "$VAULT_ADDR/v1/sys/health"

# Token lookup
curl -s --noproxy "*" \
  --header "X-Vault-Token: $VAULT_TOKEN" \
  --header "X-Vault-Namespace: $VAULT_NAMESPACE" \
  --max-time 10 \
  "$VAULT_ADDR/v1/auth/token/lookup-self"
```

---

## Deployment Type Variations

### DaemonSet Deployment (Default for Cloud Mode)

#### Create Service Account
```bash
oc apply -f serviceaccount.yaml
```

#### Create Quay Pull Secret (if using private image)
```bash
oc create secret docker-registry quay-pull-secret \
  --namespace=openshift-kms-plugin \
  --docker-server=quay.io \
  --docker-username="$QUAY_USERNAME" \
  --docker-password="$QUAY_PASSWORD" \
  --dry-run=client -o yaml | oc apply -f -

# Link to service account
oc secrets link vault-kms-plugin quay-pull-secret --for=pull -n openshift-kms-plugin
```

#### Create Vault Credentials Secret
```bash
cat <<EOF | oc apply -f -
apiVersion: v1
kind: Secret
metadata:
  name: vault-kms-credentials
  namespace: openshift-kms-plugin
type: Opaque
stringData:
  VAULT_ADDR: "$VAULT_ADDR"
  VAULT_NAMESPACE: "$VAULT_NAMESPACE"
  VAULT_ROLE_ID: "$ROLE_ID"
  VAULT_SECRET_ID: "$SECRET_ID"
  VAULT_KEY_NAME: "kms-key"
EOF
```

#### Deploy DaemonSet
```bash
oc apply -f daemonset.yaml

# Wait for pods to be ready
oc wait --for=condition=Ready pod -l app=vault-kube-kms \
  -n openshift-kms-plugin --timeout=120s

# Check pod status
oc get pods -n openshift-kms-plugin
```

### Static Pod Deployment (Default for Local Mode)

#### Update Global Pull Secret (if using private image)
```bash
# Get existing pull secret
oc get secret pull-secret -n openshift-config -o jsonpath='{.data.\.dockerconfigjson}' | base64 -d > /tmp/global-pull-secret.json

# Create Quay auth string
QUAY_AUTH=$(echo -n "$QUAY_USERNAME:$QUAY_PASSWORD" | base64 -w 0)

# Merge with existing pull secret
jq ".auths += {\"quay.io\": {\"auth\": \"$QUAY_AUTH\"}}" /tmp/global-pull-secret.json > /tmp/merged-pull-secret.json

# Update global pull secret
oc set data secret/pull-secret -n openshift-config --from-file=.dockerconfigjson=/tmp/merged-pull-secret.json

# Cleanup
rm -f /tmp/global-pull-secret.json /tmp/merged-pull-secret.json
```

#### Get Control Plane Nodes
```bash
oc get nodes -l node-role.kubernetes.io/control-plane -o jsonpath='{.items[*].metadata.name}'
```

#### Deploy Static Pod to Each Control Plane Node
```bash
# For each control plane node:
for node in $CONTROL_PLANE_NODES; do
  # Create manifest directory and copy static pod YAML
  oc debug node/$node -q -- chroot /host bash -c "
    mkdir -p /etc/kubernetes/manifests
    echo '$MANIFEST_B64' | base64 -d > /etc/kubernetes/manifests/vault-kube-kms.yaml
    chmod 644 /etc/kubernetes/manifests/vault-kube-kms.yaml
  "

  # Verify file was created
  oc debug node/$node -q -- chroot /host stat -c %s /etc/kubernetes/manifests/vault-kube-kms.yaml
done
```

#### Check Static Pod Status
```bash
# List all static pods in the namespace
oc get pods -n openshift-kms-plugin -o wide

# Check specific static pod logs
oc logs -n openshift-kms-plugin vault-kube-kms-<node-name>
```

#### Remove Static Pod (if needed)
```bash
oc debug node/<node-name> -- chroot /host rm /etc/kubernetes/manifests/vault-kube-kms.yaml
```

---

## Post-Deployment Commands

### Enable KMS Encryption on etcd
```bash
oc patch apiserver cluster --type=merge -p '{"spec":{"encryption":{"type":"KMS"}}}'
```

### Monitor KMS Encryption Progress
```bash
# Check kube-apiserver operator status
oc get clusteroperator kube-apiserver

# Check encryption status
oc get kubeapiserver cluster -o jsonpath='{.status.conditions}' | jq '.[] | select(.type | contains("Encrypt"))'
```

### Verify KMS Plugin Pods
```bash
# For DaemonSet
oc get pods -n openshift-kms-plugin -l app=vault-kube-kms

# For Static Pods
oc get pods -n openshift-kms-plugin -o wide

# Check logs
oc logs -n openshift-kms-plugin <pod-name>
```

### Check Control Plane Nodes
```bash
oc get nodes -l node-role.kubernetes.io/master
```

---

---

## Command Summary by Execution Order

This section provides a high-level overview of the command execution sequence for both modes.

### Local Mode Flow
1. Check prerequisites (oc, jq, curl, helm)
2. Add Helm repository
3. Create vault-system namespace
4. Install Vault with Helm
5. Wait for Vault pod to be running
6. Initialize Vault (if needed)
7. Save keys to secret
8. Unseal Vault
9. Get Vault service IP
10. Configure Vault (enable transit, create key, enable approle, create policy, create role)
11. Get AppRole credentials
12. Enable KMS FeatureGate
13. Deploy KMS plugin (static-pod or daemonset)
14. Enable KMS encryption on etcd

### Cloud Mode Flow
1. Check prerequisites (oc, jq, curl)
2. Check DNS resolution
3. Authenticate to Vault (userpass or token)
4. Verify Vault connectivity
5. Configure Vault (enable transit, create key, enable approle, create policy, create role)
6. Get AppRole credentials
7. Enable KMS FeatureGate
8. Deploy KMS plugin (daemonset or static-pod)
9. Enable KMS encryption on etcd

---

## Troubleshooting Commands

### Check Vault Status (Local Mode)
```bash
oc exec -n vault-system vault-0 -- vault status
oc get secret vault-init-keys -n vault-system
oc logs -n vault-system vault-0
```

### Check KMS Plugin Status
```bash
oc get pods -n openshift-kms-plugin -o wide
oc describe pod <pod-name> -n openshift-kms-plugin
oc logs <pod-name> -n openshift-kms-plugin
```

### Check FeatureGate Status
```bash
oc get featuregate cluster -o yaml
```

### Check Encryption Status
```bash
oc get apiserver cluster -o yaml
oc get kubeapiserver cluster -o jsonpath='{.status.conditions}' | jq '.'
```

### Check Node Status
```bash
oc get nodes
oc get mcp
oc debug node/<node-name>
```

---

## Additional Resources

### Related Documentation
- [HashiCorp Vault Documentation](https://www.vaultproject.io/docs)
- [OpenShift KMS Encryption](https://docs.openshift.com/container-platform/latest/security/encrypting-etcd.html)
- [Vault Transit Secrets Engine](https://www.vaultproject.io/docs/secrets/transit)
- [Vault AppRole Authentication](https://www.vaultproject.io/docs/auth/approle)

### Common Issues and Solutions

**Issue: DNS resolution fails for HCP Vault**
```bash
# Verify the Vault address is correct
# Check HCP console: https://portal.cloud.hashicorp.com/
# Ensure cluster is running and get the correct Public Address
```

**Issue: Static pods not appearing**
```bash
# Static pods take 30-60 seconds to appear
# Check kubelet logs on the control plane node
oc debug node/<node-name> -- chroot /host journalctl -u kubelet -f
```

**Issue: Image pull errors with private images**
```bash
# For static pods, global pull secret must be updated
# Nodes need 2-5 minutes to pick up new credentials
# Manually restart kubelet if needed
oc debug node/<node-name> -- chroot /host systemctl restart kubelet
```

**Issue: Vault is sealed after restart**
```bash
# Unseal Vault using stored key
UNSEAL_KEY=$(oc get secret vault-init-keys -n vault-system -o jsonpath='{.data.unseal-key}' | base64 -d)
oc exec -n vault-system vault-0 -- vault operator unseal "$UNSEAL_KEY"
```

---

## Summary

This documentation covers:

1. **Part 1: Script Usage Guide** - How to run `deploy-kms-plugin.sh` with various options and configurations
2. **Part 2: Manual Command Reference** - Detailed list of all commands executed for manual deployment or troubleshooting

For quick deployment, see the [Quick Start](#quick-start) section.
For step-by-step manual deployment, refer to [Part 2: Manual Command Reference](#part-2-manual-command-reference).
