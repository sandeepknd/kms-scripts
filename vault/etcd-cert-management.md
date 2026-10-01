# etcd Certificate Management System

## Overview

The cluster-etcd-operator manages TLS certificates for all etcd communication through the `EtcdCertSignerController`. The system maintains **two independent CA hierarchies**, issues per-node leaf certificates, aggregates them into single secrets/configmaps for atomic static pod rollouts, and coordinates CA rotation with the revision rollout system.

All certificates are stored as Kubernetes Secrets and ConfigMaps in the `openshift-etcd` namespace. The `ResourceSyncController` distributes copies to `openshift-etcd-operator` and `openshift-config` namespaces.

---

## 1. Two CA Hierarchies

The system operates two completely separate CA chains defined in `pkg/operator/etcdcertsigner/etcdcertsignercontroller.go` (lines 46-61, `certConfig` struct):

### etcd-signer (Server/Peer CA)

| Resource | Type | Name |
|----------|------|------|
| CA Secret | `Secret` | `etcd-signer` |
| CA Bundle | `ConfigMap` | `etcd-ca-bundle` |

**Signs**: peer certs, serving certs, `etcd-client` cert

### etcd-metric-signer (Metrics CA)

| Resource | Type | Name |
|----------|------|------|
| CA Secret | `Secret` | `etcd-metric-signer` |
| CA Bundle | `ConfigMap` | `etcd-metrics-ca-bundle` |

**Signs**: metrics-serving certs, `etcd-metric-client` cert

### Why Two Hierarchies?

Server/peer certs and metrics certs can rotate independently. A metrics CA rotation (triggered by monitoring changes) doesn't force re-rolling all etcd peers. Conversely, a peer CA rotation doesn't break Prometheus scraping during the rollout window.

---

## 2. Validity Periods

Defined in `pkg/tlshelpers/tlshelpers.go` (lines 32-35):

```go
EtcdCertValidity          = 3 * 365 * 24 * time.Hour   // 3 years (DEFINED but NOT USED)
EtcdCertValidityRefresh   = 2.2 * 365 * 24 * time.Hour // ~2.2 years (DEFINED but NOT USED)
EtcdCaCertValidity        = 5 * 365 * 24 * time.Hour   // 5 years
EtcdCaCertValidityRefresh = 4.2 * 365 * 24 * time.Hour // ~4.2 years (refresh trigger)
```

**Critical detail**: Despite these four constants being defined, the `EtcdCertSignerController` uses **only** `EtcdCaCertValidity`/`EtcdCaCertValidityRefresh` for **both** CA and leaf certificates (`etcdcertsignercontroller.go:147-154`):

```go
certValidity := tlshelpers.CertValidity{
    Validity:  tlshelpers.EtcdCaCertValidity,       // 5 years — used for LEAF certs
    RefreshAt: tlshelpers.EtcdCaCertValidityRefresh, // 4.2 years
}
signerValidity := tlshelpers.CertValidity{
    Validity:  tlshelpers.EtcdCaCertValidity,        // 5 years — used for CA certs
    RefreshAt: tlshelpers.EtcdCaCertValidityRefresh,  // 4.2 years
}
```

| Certificate Type | Validity | Refresh At | Rationale |
|------------------|----------|------------|-----------|
| CA (signer) | 5 years | 4.2 years | Long-lived; clusters may hibernate up to ~9 months |
| Leaf (all types) | 5 years | 4.2 years | Same as CA; `EtcdCertValidity` (3yr) exists but is unused |

The `EtcdCertValidity` (3yr) and `EtcdCertValidityRefresh` (2.2yr) constants appear to be vestigial — they are defined but never referenced by any controller code.

### Short Rotation (Feature Gate)

When `FeatureShortCertRotation` is enabled (`etcdcertsignercontroller.go:159-168`):

| Certificate Type | Validity | Refresh At |
|------------------|----------|------------|
| CA | 4 hours | 3 hours |
| Leaf | 2 hours | 90 minutes |

This is the only case where CA and leaf validity differ. It is used for testing certificate rotation logic in CI environments.

---

## 3. Certificate Inventory

### Cluster-Wide Certificates

| Secret Name | Signed By | Type | UserInfo | Purpose |
|-------------|-----------|------|----------|---------|
| `etcd-client` | `etcd-signer` | `ClientRotation` | Name: `etcd-client`, Groups: `[system:etcd, etcd-client]` | apiserver, operator, etcdctl → etcd |
| `etcd-metric-client` | `etcd-metric-signer` | `ClientRotation` | Name: `etcd-metric`, Groups: `[system:etcd, etcd-metric]` | Prometheus → etcd metrics endpoint |

Defined in `pkg/tlshelpers/tlshelpers.go` (lines 277-345).

### Per-Node Certificates

For each control-plane node, three certificates are created using `PeerRotation` (both client and server `ExtKeyUsage`):

| Secret Name Pattern | Signed By | CertificateName | Purpose |
|---------------------|-----------|-----------------|---------|
| `etcd-peer-<nodeName>` | `etcd-signer` | `etcd.etcd-peer` | Raft consensus (peer-to-peer) |
| `etcd-serving-<nodeName>` | `etcd-signer` | `etcd.etcd-serving` | Client-facing gRPC endpoint |
| `etcd-serving-metrics-<nodeName>` | `etcd-metric-signer` | `etcd.etcd-serving-metrics` | Metrics/health endpoint |

Naming functions are in `pkg/tlshelpers/tlshelpers.go` (lines 53-61). The cert creation functions `CreatePeerCertificate`, `CreateServingCertificate`, `CreateMetricsServingCertificate` (lines 190-227) all delegate to `createCertForNode` (line 229).

### Subject Alternative Names (SANs)

Every per-node certificate includes the same SAN list, defined in `getServerHostNames()` (`tlshelpers.go:63-74`):

```
localhost
etcd.kube-system.svc
etcd.kube-system.svc.cluster.local
etcd.openshift-etcd.svc
etcd.openshift-etcd.svc.cluster.local
127.0.0.1
::1
<node-internal-IP(s)>
```

The hostnames are sorted lexically (`slices.Sort` at line 246), and the first entry becomes the Subject CN. This matches library-go's `MakeServerCertForDuration`, which also sorts via `sets.List` before selecting the CN.

### Why PeerRotation for All Per-Node Certs?

`PeerRotation` grants both `ExtKeyUsageClientAuth` and `ExtKeyUsageServerAuth`. etcd members simultaneously serve requests and connect to peers, so every per-node cert needs both usages. Even the serving cert needs client auth because etcd uses mutual TLS.

---

## 4. Aggregation Secrets and ConfigMaps

To avoid multiple revision rollouts when several certs change simultaneously, individual certs are aggregated into two composite resources:

### etcd-all-certs (Secret)

Created in `syncLeafCertificates()` (`etcdcertsignercontroller.go:440-453`).

Contains `tls.crt` and `tls.key` data from every per-node cert (peer, serving, metrics-serving), keyed by `<secretName>/tls.crt` and `<secretName>/tls.key`.

The static pod controller watches this single secret. A cert change (node addition, rotation) triggers at most one revision rollout regardless of how many individual certs changed.

### etcd-all-bundles (ConfigMap)

Created in `ensureBundles()` (`etcdcertsignercontroller.go:490-502`).

```yaml
data:
  server-ca-bundle.crt:  <PEM-encoded etcd-signer CA bundle>
  metrics-ca-bundle.crt: <PEM-encoded etcd-metric-signer CA bundle>
```

This ConfigMap is the canonical source for CA trust. If it's missing, the static pod installer pod fails to install, potentially deadlocking the revision rollout (lines 259-276 handle this emergency case).

---

## 5. Sync Flow

The `sync()` function (`etcdcertsignercontroller.go:244-329`) runs every minute (`ResyncEvery(time.Minute)` at line 236) and follows this decision tree:

### Phase 1: Bootstrap Check (lines 245-257)

```
Is bootstrap complete?
  NO  → syncAllMasterCertificates(forceSkipRollout=true) → return
  YES → continue
```

During bootstrap, all certs sync freely without revision gating. This avoids contention with the initial static pod rollout.

### Phase 2: Missing Bundle Check (lines 265-276)

```
Is etcd-all-bundles ConfigMap missing?
  YES → syncAllMasterCertificates(forceSkipRollout=true) → return
  NO  → continue
```

Emergency path: if the aggregated bundle ConfigMap is missing, the installer pod can't proceed. Forces a full sync to regenerate it.

### Phase 3: Node Diff Check (lines 278-290)

```
Do secrets exist for nodes that don't exist, or vice versa?
  YES → forcedSyncLeafCertificates() → return
  NO  → continue
```

`forcedSyncLeafCertificates()` (lines 367-389) is a **read-only** path for the CA:
- Reads existing CA secrets and bundles without calling `EnsureSigningCertKeyPair` (which could regenerate an expired CA)
- Then calls `syncLeafCertificates()` to create/remove per-node certs

**Why read-only?** During node scale-up, if the CA happens to be past its refresh threshold, calling `Ensure` would rotate it. That CA rotation triggers a full cluster rollout across all nodes, potentially bricking the cluster during scale-up. By reading only, the scale-up gets its leaf certs without side effects.

### Phase 4: Revision-Gated Full Sync (lines 292-328)

```
Get current revision and last rotation revision
  → syncAllMasterCertificates(forceSkipRollout=false, rotationRevision, currentRevision)
```

This is the normal steady-state path with full revision gating.

---

## 6. syncAllMasterCertificates Flow

`syncAllMasterCertificates()` (`etcdcertsignercontroller.go:331-363`) orchestrates the full cert lifecycle:

### Step 1: Ensure Signers (lines 333-343)

```go
signerCaPair, _, err := c.certConfig.signerCert.EnsureSigningCertKeyPair(ctx)
metricsSignerCaPair, _, err := c.certConfig.metricsSignerCert.EnsureSigningCertKeyPair(ctx)
```

`EnsureSigningCertKeyPair` (from library-go) checks if the CA secret exists and is valid. If missing or past its refresh threshold, it generates a new CA keypair. Reports expiration metrics for monitoring.

### Step 2: Ensure Bundles (lines 345-348)

Calls `ensureBundles()` which:
1. Calls `EnsureConfigMapCABundle()` for both server and metrics bundles — this appends the new CA cert to the bundle if a rotation happened (old CAs remain in the bundle for trust continuity)
2. Creates the `etcd-all-bundles` ConfigMap with `server-ca-bundle.crt` and `metrics-ca-bundle.crt` keys
3. If the bundle data changed, tags the ConfigMap with `BundleRolloutRevisionAnnotation` set to the current revision number (`etcdcertsignercontroller.go:520`)
4. Returns `rolloutTriggered=true` if `resourceapply.ApplyConfigMap` detected a change

### Step 3: Revision Gate (lines 350-360)

```go
if rolloutTriggered {
    return nil  // Skip leaf generation — wait for rollout to complete
}

if currentRevision <= lastRotationRevision {
    return nil  // Rollout from the bundle change hasn't finished yet
}
```

**This is the bundle-before-leaves invariant**: after a CA rotation, new bundles must roll out to all nodes before new leaf certs are issued. If leaf certs were issued immediately, nodes still running the old revision wouldn't have the new CA in their trust bundle and would reject the new leaf certs.

### Step 4: Sync Leaf Certificates (line 362)

Only reached when the revision gate passes. Calls `syncLeafCertificates()`.

---

## 7. syncLeafCertificates Flow

`syncLeafCertificates()` (`etcdcertsignercontroller.go:391-454`):

1. **Ensure cluster-wide client certs** (lines 400-407):
   - `etcd-client` (signed by `etcd-signer`)
   - `etcd-metric-client` (signed by `etcd-metric-signer`)

2. **Create node cert configs** (line 409): calls `createNodeCertConfigs()` (lines 531-582) which iterates all control-plane nodes and creates `PeerCertificate`, `ServingCertificate`, and `MetricsServingCertificate` for each

3. **Ensure per-node certs** (lines 415-433): for each node:
   - `peerCert.EnsureTargetCertKeyPair(ctx, signerCaPair, signerBundle)` — uses `CARotatingTargetCertCreator` which checks AKI/SKI to detect signer change
   - `servingCert.EnsureTargetCertKeyPair(ctx, signerCaPair, signerBundle)`
   - `metricsCert.EnsureTargetCertKeyPair(ctx, metricsSignerCaPair, metricsSignerBundle)`

4. **Write aggregated secret** (lines 440-453): all per-node cert data is collected into the `etcd-all-certs` secret via `resourceapply.ApplySecret`

---

## 8. CARotatingTargetCertCreator: Signer-Change Detection

Defined in `pkg/tlshelpers/target_cert_creator.go` (lines 17-74).

This wraps library-go's `TargetCertCreator` to add signer-rotation awareness. The standard library-go creator only checks cert expiry and bundle changes. The etcd-specific wrapper adds:

### AKI/SKI Comparison (lines 53-54)

```go
if !bytes.Equal(currentCert.AuthorityKeyId, signer.Config.Certs[0].SubjectKeyId) {
    return "signer subject key does not match cert authority key anymore"
}
```

Compares the leaf cert's **Authority Key Identifier** (AKI — who signed me?) with the current signer's **Subject Key Identifier** (SKI — who am I?). If they differ, the signer has rotated and the leaf must be regenerated.

### Fallback: Full x509.Verify (lines 59-70)

If AKI/SKI fields are not present (older or non-standard certs), falls back to a full certificate chain verification against the current signer.

### Why This Matters

Standard library-go rotation only checks if the cert is past its refresh threshold. But after a CA rotation, existing leaf certs are technically still valid (they haven't expired), yet they were signed by the old CA. The AKI/SKI check forces regeneration under the new CA, which is essential for maintaining the trust chain.

---

## 9. CA Rotation Sequence

When a CA (e.g., `etcd-signer`) reaches its refresh threshold (4.2 years), the following sequence occurs across multiple sync loops:

### Sync Loop N: CA Rotation + Bundle Update

1. `EnsureSigningCertKeyPair()` detects the CA is past refresh, generates new CA keypair
2. `EnsureConfigMapCABundle()` appends the new CA cert to `etcd-ca-bundle` (old cert stays for trust continuity)
3. `ensureBundles()` updates `etcd-all-bundles` ConfigMap with the new bundle content
4. Tags `etcd-all-bundles` with `BundleRolloutRevisionAnnotation = currentRevision`
5. `resourceapply.ApplyConfigMap` detects the change → `rolloutTriggered = true`
6. **Leaf generation is skipped** — `sync` returns early

### Sync Loops N+1...N+K: Waiting for Rollout

7. The static pod revision controller detects the `etcd-all-bundles` change and creates a new revision
8. The installer controller rolls out the new revision node-by-node
9. Each node's static pod now has the new CA bundle in its trust store
10. `currentRevision` advances as each node completes
11. `sync()` checks: `currentRevision <= lastRotationRevision` → true → skip leaf generation

### Sync Loop N+K+1: Leaf Regeneration

12. `currentRevision > lastRotationRevision` → revision gate passes
13. `syncLeafCertificates()` runs for all nodes
14. `CARotatingTargetCertCreator.NeedNewTargetCertKeyPair()` detects AKI/SKI mismatch on each cert
15. New leaf certs are generated, signed by the new CA
16. `etcd-all-certs` secret is updated → triggers another revision rollout
17. Nodes roll out with the new leaf certs, which are now trusted because they already have the new CA bundle

### Safety Properties

- **Bundle-before-leaves**: nodes always trust the new CA before receiving certs signed by it
- **Old CA in bundle**: during the rollout window, both old and new CAs are in the bundle, so both old and new leaf certs are trusted
- **No split-brain**: the `etcd-all-certs` aggregation ensures all per-node certs update atomically in a single revision

---

## 10. Bootstrap Certificates

During cluster bootstrap, CAs need to exist in `openshift-config` before the `openshift-etcd` namespace exists:

- `CreateBootstrapSignerCert()` (`tlshelpers.go:142-151`): creates `etcd-signer` in `openshift-config`
- `CreateBootstrapMetricsSignerCert()` (`tlshelpers.go:179-188`): creates `etcd-metric-signer` in `openshift-config`

These are identical to the regular signers but target `GlobalUserSpecifiedConfigNamespace` (`openshift-config`). Once bootstrap completes, the `ResourceSyncController` handles distribution.

---

## 11. Cross-Namespace Distribution (ResourceSyncController)

The `ResourceSyncController` (`pkg/operator/resourcesynccontroller/resourcesynccontroller.go`) copies cert resources from `openshift-etcd` to other namespaces where consumers need them:

### ConfigMap Syncs

| Destination | Source | Condition |
|-------------|--------|-----------|
| `openshift-etcd-operator/etcd-ca-bundle` | `openshift-etcd/etcd-ca-bundle` | Source exists |
| `openshift-config/etcd-ca-bundle` | `openshift-etcd/etcd-ca-bundle` | Source exists |
| `openshift-config/etcd-serving-ca` | `openshift-etcd/etcd-ca-bundle` | Source exists (legacy name) |
| `openshift-etcd-operator/etcd-metric-serving-ca` | `openshift-etcd/etcd-metrics-ca-bundle` | Source exists |
| `openshift-etcd/cluster-config-v1` | `kube-system/cluster-config-v1` | Unconditional |

### Secret Syncs

| Destination | Source | Condition |
|-------------|--------|-----------|
| `openshift-etcd-operator/etcd-metric-client` | `openshift-etcd/etcd-metric-client` | Source exists |
| `openshift-etcd-operator/etcd-client` | `openshift-etcd/etcd-client` | Source exists |
| `openshift-config/etcd-client` | `openshift-etcd/etcd-client` | Source exists |

All conditional syncs use a precondition check: the sync only happens if the source resource already exists in `openshift-etcd`. This prevents the destination from being deleted if the source is temporarily missing (e.g., during namespace switching or accidental deletion).

The legacy name `etcd-serving-ca` (line 62-69 in resourcesynccontroller.go) exists because other control-plane operators and tests across the OpenShift org reference this name.

---

## 12. EtcdCertCleanerController

Defined in `pkg/operator/etcdcertcleaner/etcd_cert_cleaner_controller.go`.

When control-plane nodes are removed (e.g., scale-down, node replacement), their per-node cert secrets become orphaned. The cleaner removes them with a grace period:

### Constants

```go
DeletionGracePeriodAnnotation = "openshift.io/ceo-delete-grace-start"
DeletionGracePeriod = 24 * 3 * time.Hour  // 72 hours
```

### Sync Cadence

- Runs every 1 hour (`ResyncEvery(1 * time.Hour)` at line 77)
- Health threshold: 6 hours (line 75) — if it hasn't run successfully in 6 hours, the liveness checker flags it

### Deletion Flow

1. **List all node-based secrets** (prefixes: `etcd-peer-`, `etcd-serving-`, `etcd-serving-metrics-`)
2. **Match against current control-plane nodes**:
   - Secret matches a current node → **untag** (remove `DeletionGracePeriodAnnotation` if present)
   - Secret has no matching node → **orphaned**
3. **For orphaned secrets**:
   - No annotation yet → **tag** with `DeletionGracePeriodAnnotation = now()`
   - Annotation exists and 72 hours have passed → **delete**
   - Annotation exists but <72 hours → **skip** (still in grace period)

### Safety: Automatic Undelete

If a node comes back (or was temporarily unavailable), the annotation is removed. The cert is never deleted while a matching node exists. In the worst case, the cert is regenerated by `EtcdCertSignerController`.

---

## 13. Certificate Resource Map

Complete map of all cert-related resources managed by the operator:

```
openshift-etcd/ (TargetNamespace)
├── Secrets (CAs)
│   ├── etcd-signer              ← server/peer CA keypair
│   └── etcd-metric-signer       ← metrics CA keypair
├── ConfigMaps (Bundles)
│   ├── etcd-ca-bundle            ← server/peer CA bundle (may contain multiple CAs during rotation)
│   └── etcd-metrics-ca-bundle    ← metrics CA bundle
├── Secrets (Cluster-wide Clients)
│   ├── etcd-client               ← apiserver/operator → etcd client cert
│   └── etcd-metric-client        ← Prometheus → etcd metrics client cert
├── Secrets (Per-Node, ×N control-plane nodes)
│   ├── etcd-peer-<nodeName>              ← Raft peer communication
│   ├── etcd-serving-<nodeName>           ← gRPC client-facing endpoint
│   └── etcd-serving-metrics-<nodeName>   ← Metrics/health endpoint
├── Secret (Aggregated)
│   └── etcd-all-certs            ← all per-node certs merged (watched by static pod controller)
└── ConfigMap (Aggregated)
    └── etcd-all-bundles          ← both CA bundles merged (watched by static pod controller)

openshift-etcd-operator/ (OperatorNamespace)
├── etcd-ca-bundle               ← synced from openshift-etcd
├── etcd-metric-serving-ca       ← synced from openshift-etcd/etcd-metrics-ca-bundle
├── etcd-client                  ← synced from openshift-etcd
└── etcd-metric-client           ← synced from openshift-etcd

openshift-config/ (GlobalUserSpecifiedConfigNamespace)
├── etcd-signer                  ← bootstrap signer (created during install)
├── etcd-metric-signer           ← bootstrap metrics signer
├── etcd-ca-bundle               ← synced from openshift-etcd
├── etcd-serving-ca              ← synced from openshift-etcd/etcd-ca-bundle (legacy name)
└── etcd-client                  ← synced from openshift-etcd
```

---

## 14. Monitoring and Metrics

The `EtcdCertSignerController` reports certificate expiration metrics after each signer ensure:

```go
c.reportExpirationMetric(signerCaPair, "signer-ca")
c.reportExpirationMetric(metricsSignerCaPair, "metrics-signer-ca")
```

These metrics feed into OpenShift's certificate expiration alerting, which fires alerts before certs expire.

The `EtcdCertCleanerController` uses a `health.CheckingSyncWrapper` with a 6-hour threshold — if the controller hasn't synced successfully in 6 hours, the `MultiAlivenessChecker` marks it unhealthy.

---

## Source File Reference

| File | Purpose |
|------|---------|
| `pkg/operator/etcdcertsigner/etcdcertsignercontroller.go` | Main cert signer controller (sync flow, aggregation, revision gating) |
| `pkg/tlshelpers/tlshelpers.go` | Cert name constants, validity periods, SAN generation, cert creation functions |
| `pkg/tlshelpers/target_cert_creator.go` | `CARotatingTargetCertCreator` with AKI/SKI signer-change detection |
| `pkg/operator/etcdcertcleaner/etcd_cert_cleaner_controller.go` | Orphaned cert cleanup with 72-hour grace period |
| `pkg/operator/resourcesynccontroller/resourcesynccontroller.go` | Cross-namespace cert distribution |
| `pkg/operator/operatorclient/interfaces.go` | Namespace constants (`openshift-etcd`, `openshift-etcd-operator`, `openshift-config`) |
