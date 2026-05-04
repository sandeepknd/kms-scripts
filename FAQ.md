# Vault Deployer - Frequently Asked Questions

## Architecture & Design

### Q1: Why doesn't this use remotecommand for Vault initialization?

**A:** The implementation uses a **sidecar container approach** instead of remotecommand (pod exec from Go code).

**How it works:**
- A `vault-setup` sidecar container runs alongside the main Vault container in the same pod
- The sidecar executes a shell script (`setup.sh`) that handles all initialization
- The script creates a Kubernetes secret with the credentials via the K8s API
- Go code simply waits for the secret to appear and reads it

**Benefits:**
- No need for remotecommand/SPDY executor
- Follows declarative Kubernetes patterns
- All logic is in YAML manifests and shell scripts
- Matches the pattern used by `k8s_mock_kms_plugin_deployer.go`

---

### Q2: Why does the deployment need anyuid SCC?

**A:** The deployment sets `fsGroup: 1000` in the pod securityContext, which requires elevated permissions.

**Why it's needed:**
- OpenShift's default `restricted` SCC doesn't allow arbitrary fsGroup values
- The `anyuid` SCC allows setting fsGroup but is much less privileged than `privileged`
- The fsGroup ensures proper file permissions for Vault's data directory

**What we DON'T need:**
- ✅ Removed `IPC_LOCK` capability (not needed with `disable_mlock = true`)
- ✅ Don't use `privileged` SCC (too permissive)

---

### Q3: Why does vault_service.yaml originally have two ports?

**A:** Originally it had:
- **Port 8200 (http)** - Main Vault API endpoint for all operations
- **Port 8201 (https-internal)** - Vault cluster internal communication for HA

**Current implementation:**
- Port 8201 has been **removed** since we only deploy 1 replica
- Only port 8200 is needed for single-node test deployments

---

## Vault Installation & Configuration

### Q4: How is Vault installed?

**A:** Vault is **NOT installed by a command** - it comes **pre-installed in the Docker image**.

```go
WellKnownVaultImage = "docker.io/hashicorp/vault-enterprise:2.0.0-ent"
```

**How it works:**
- This is HashiCorp's official Vault Enterprise Docker image
- The `vault` binary is already built into the image at `/bin/vault`
- Both the main container and sidecar use the **same image**
- Main container runs: `vault server -config=/tmp/vault.hcl`
- Sidecar runs: `vault` CLI commands for configuration

**Verification:**
```bash
oc exec vault-xxx -c vault-setup -- which vault
# Output: /bin/vault

oc exec vault-xxx -c vault-setup -- vault version
# Output: Vault v2.0.0+ent
```

---

### Q5: How is the Vault license used during deployment?

**A:** The license is loaded via environment variable, not configuration file.

**Complete flow:**

1. **Provide license (user):**
   ```bash
   VAULT_LICENSE=$(cat vault.hclic) go test -v -run TestVaultDeployerIntegration
   ```

2. **Create Kubernetes Secret (Go code):**
   ```go
   license := os.Getenv("VAULT_LICENSE")
   secret := &corev1.Secret{
       Data: map[string][]byte{"license": []byte(license)},
   }
   ```

3. **Mount secret into pod:**
   ```yaml
   volumes:
     - name: license
       secret:
         secretName: vault-license
   volumeMounts:
     - name: license
       mountPath: /vault/license
   ```

4. **Point Vault to license file:**
   ```yaml
   env:
     - name: VAULT_LICENSE_PATH
       value: "/vault/license/license"
   ```

5. **Vault autoloads the license:**
   - When `vault server` starts, it checks `VAULT_LICENSE_PATH` env var
   - Automatically reads and loads the license from that file
   - This happens **before** reading vault.hcl

**Why not in vault.hcl?**
- The `VAULT_LICENSE_PATH` environment variable handles it automatically
- Keeps credentials (license) separate from config (HCL)
- More secure - license stays in a Secret, not a ConfigMap

---

## Vault Initialization & Authentication

### Q6: How does the setup script run Vault commands?

**A:** The script uses the `vault` CLI binary from the Docker image.

**Connection:**
```bash
VAULT_ADDR="http://127.0.0.1:8200"
```
- Sidecar runs in the **same pod** as the main Vault container
- They share the network namespace (localhost)
- No network authentication needed for local communication

**Commands that DON'T need authentication:**
- `vault status` - Anyone can check status
- `vault operator init` - Initialization is open to first caller
- `vault operator unseal` - Only needs the unseal key

**Commands that DO need authentication:**
- After initialization, the script gets the root token:
  ```bash
  INIT_OUTPUT=$(vault operator init -format=json)
  ROOT_TOKEN=$(echo "$INIT_OUTPUT" | ... parse json ...)
  export VAULT_TOKEN="$ROOT_TOKEN"
  ```
- All subsequent commands automatically use `VAULT_TOKEN` env var

---

### Q7: What exact command is executed for "vault secrets enable"?

**A:** The exact command is:
```bash
vault secrets enable -path=transit transit
```

**Command breakdown:**
- `vault` - Vault CLI binary
- `secrets enable` - Subcommand to enable a secrets engine
- `-path=transit` - Mount path (creates `/transit` endpoint)
- `transit` - Type of secrets engine (encryption-as-a-service)

**Authentication:**
The `vault` CLI automatically looks for authentication in this order:
1. `VAULT_TOKEN` environment variable (✅ what we use)
2. `~/.vault-token` file
3. Token passed via `-token` flag

Since we set `export VAULT_TOKEN="$ROOT_TOKEN"` earlier, the command is equivalent to:
```bash
vault secrets enable -path=transit transit -token="hvs.xxxxx..."
```

**Other commands that use VAULT_TOKEN:**
```bash
vault write -f transit/keys/kubernetes-encryption-key
vault auth enable approle
vault policy write kms-policy -
vault read -field=role_id auth/approle/role/kms-plugin/role-id
```

---

### Q8: How is setup.sh mounted at /vault/config/setup.sh?

**A:** ConfigMap keys automatically become files when mounted as a volume.

**Step 1 - Define in ConfigMap:**
```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: vault-config
data:
  vault.hcl: |
    ui = true
    ...
  setup.sh: |          # <-- Second key
    #!/bin/sh
    ...
```

**Step 2 - Create volume from ConfigMap:**
```yaml
volumes:
  - name: config
    configMap:
      name: vault-config
```

**Step 3 - Mount volume into container:**
```yaml
volumeMounts:
  - name: config
    mountPath: /vault/config
```

**Step 4 - Keys become files:**
```
ConfigMap key    →    File in container
──────────────────────────────────────
vault.hcl       →    /vault/config/vault.hcl
setup.sh        →    /vault/config/setup.sh
```

**Step 5 - Execute the script:**
```yaml
command: ["/bin/sh", "/vault/config/setup.sh"]
```

**Key insight:** Each key in ConfigMap.data becomes a separate file in the mounted directory!

---

## Code Design

### Q9: Why were GetVaultAddress() and GetAppRoleCredentials() removed?

**A:** These getter functions were only used in tests for logging/verification, not for actual functionality.

**Why they were removed:**
- Not needed for deployment functionality
- Only used for verification/logging in integration test
- The information is either:
  - In the `vault-credentials` Kubernetes Secret (AppRole credentials)
  - Easily constructed from namespace (Vault address: `http://vault.{namespace}.svc:8200`)
- Simplifies the API surface
- Follows reviewer feedback to remove unnecessary functionality

---

### Q10: Why was the Cleanup() function removed from the deployer?

**A:** The mock KMS plugin deployer pattern doesn't include cleanup, and it's simpler to handle manually.

**What changed:**
- **Before:** `deployer.Cleanup(ctx)` function that deleted the namespace
- **After:** `TestVaultCleanup` directly calls `kubeClient.CoreV1().Namespaces().Delete()`

**Benefits:**
- Follows the simpler pattern of `k8s_mock_kms_plugin_deployer.go`
- Cleanup can be done manually with `kubectl delete namespace <namespace>`
- Reduces code complexity
- Test cleanup is more explicit and clear

---

## Troubleshooting

### Q11: The integration test fails with "unable to create vault pods" - what's wrong?

**A:** This is usually a Security Context Constraints (SCC) issue.

**Check:**
1. Ensure `vault_scc_rolebinding.yaml` exists and is in the manifest list
2. Verify it grants `anyuid` SCC (not `restricted`, not `privileged`)
3. The deployment needs `anyuid` because of `fsGroup: 1000` in securityContext

**Current configuration:**
```yaml
# vault_scc_rolebinding.yaml
roleRef:
  kind: ClusterRole
  name: system:openshift:scc:anyuid  # <-- Must be anyuid
```

---

### Q12: How do I verify the Vault deployment is working?

**A:** Run the integration test:

```bash
INTEGRATION_TEST=true VAULT_LICENSE=$(cat vault.hclic) go test -v -run TestVaultDeployerIntegration
```

**What the test verifies:**
1. ✅ Vault namespace created
2. ✅ Vault deployment becomes ready
3. ✅ vault-setup sidecar initializes and unseals Vault
4. ✅ Transit secret engine enabled
5. ✅ AppRole credentials created
6. ✅ `vault-credentials` secret exists with role-id and secret-id

**Manual verification:**
```bash
# Check pods
oc get pods -n <vault-namespace>

# Should show: vault-xxx  2/2  Running

# Check vault-setup logs
oc logs <vault-pod> -c vault-setup

# Should end with: "Vault setup complete. Sidecar sleeping."

# Check credentials secret
oc get secret vault-credentials -n <vault-namespace> -o yaml
```

---

## File Structure

### Q13: Why are there unused YAML files in the assets directory?

**A:** `vault_init_configmap.yaml` and `vault_init_rolebinding.yaml` are leftover files from an earlier implementation.

**Files currently used:**
- ✅ `vault_namespace.yaml`
- ✅ `vault_serviceaccount.yaml`
- ✅ `vault_scc_rolebinding.yaml`
- ✅ `vault_role.yaml`
- ✅ `vault_role_binding.yaml`
- ✅ `vault_configmap.yaml` (contains both vault.hcl AND setup.sh)
- ✅ `vault_service.yaml`
- ✅ `vault_deployment.yaml`

**Unused files (can be deleted):**
- ❌ `vault_init_configmap.yaml` (setup.sh is now in vault_configmap.yaml)
- ❌ `vault_init_rolebinding.yaml` (unused)
- ❌ `vault_init_script.sh` (standalone copy, unused)

---

## Testing

### Q14: What environment variables are needed to run the integration test?

**A:** Only two:

```bash
INTEGRATION_TEST=true \
VAULT_LICENSE=$(cat vault.hclic) \
go test -v -run TestVaultDeployerIntegration -timeout 10m
```

**Details:**
- `INTEGRATION_TEST=true` - Enables integration tests (they skip otherwise)
- `VAULT_LICENSE` - Content of the Vault Enterprise license file
- `-timeout 10m` - Gives enough time for deployment (typically completes in ~20s)

**Optional:**
- `KUBECONFIG` - Path to kubeconfig (defaults to `~/.kube/config`)

---

### Q15: Why are there no unit tests?

**A:** Per reviewer feedback, unit tests for testing functionality were removed.

**What remains:**
- `TestVaultDeployerIntegration` - Integration test that deploys Vault to a real cluster
- `TestVaultCleanup` - Integration test that cleans up the namespace

**Removed:**
- ❌ `TestVaultDeployerDefaults`
- ❌ `TestVaultDeployerCustomConfig`
- ❌ `TestVaultGetters`
- ❌ `TestVaultManifestTemplates`

**Rationale:** Integration tests verify actual functionality in a real cluster, which is more valuable than unit tests for a deployer.

---

## Summary

This Vault deployer provides a **test fixture** for integration testing Kubernetes KMS encryption with HashiCorp Vault. Key design principles:

1. **Declarative** - Uses Kubernetes manifests and sidecar patterns
2. **Simple** - No remotecommand, minimal Go code
3. **Self-contained** - Sidecar handles all initialization
4. **Secure** - License and credentials in Secrets, minimal privileges (anyuid SCC)
5. **Pattern-following** - Matches `k8s_mock_kms_plugin_deployer.go` design
