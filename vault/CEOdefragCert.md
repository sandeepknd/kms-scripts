# CEO Defrag Controller: Complete Analysis

## Table of Contents

- [1. Defragmentation Trigger Conditions](#1-defragmentation-trigger-conditions)
  - [1.1 Gate 1: Is Defrag Enabled?](#11-gate-1-is-defrag-enabled)
  - [1.2 Gate 2: Cluster Health](#12-gate-2-cluster-health)
  - [1.3 Gate 3: Fragmentation Threshold](#13-gate-3-fragmentation-threshold)
  - [1.4 Decision Flowchart](#14-decision-flowchart)
- [2. Defrag Execution Path](#2-defrag-execution-path)
  - [2.1 Cycle Management](#21-cycle-management)
  - [2.2 Defrag Ordering Strategy](#22-defrag-ordering-strategy)
  - [2.3 Leader Transfer Before Defrag](#23-leader-transfer-before-defrag)
  - [2.4 Defrag Execution](#24-defrag-execution)
  - [2.5 Failure Handling and Degraded Condition](#25-failure-handling-and-degraded-condition)
  - [2.6 Timing Parameters](#26-timing-parameters)
  - [2.7 Concrete Example: 3-Member HA Cluster](#27-concrete-example-3-member-ha-cluster)
- [3. Communication Channels](#3-communication-channels)
  - [3.1 Direct etcd gRPC Channel](#31-direct-etcd-grpc-channel)
  - [3.2 Kubernetes API Channel (via kube-apiserver)](#32-kubernetes-api-channel-via-kube-apiserver)
- [4. Authentication Deep Dive](#4-authentication-deep-dive)
  - [4.1 etcd Authentication: Mutual TLS (mTLS)](#41-etcd-authentication-mutual-tls-mtls)
  - [4.2 kube-apiserver Authentication: Bearer Token (JWT)](#42-kube-apiserver-authentication-bearer-token-jwt)
  - [4.3 ServiceAccount Purpose](#43-serviceaccount-purpose)
  - [4.4 mTLS vs Bearer Token Comparison](#44-mtls-vs-bearer-token-comparison)
- [5. kubeconfig and Authentication Methods](#5-kubeconfig-and-authentication-methods)
  - [5.1 kubeconfig Structure](#51-kubeconfig-structure)
  - [5.2 Authentication Variants in kubeconfig](#52-authentication-variants-in-kubeconfig)
  - [5.3 Kubernetes/OpenShift Authentication Methods Overview](#53-kubernetesopenshift-authentication-methods-overview)
- [6. Verifying Defrag State on a Live Cluster](#6-verifying-defrag-state-on-a-live-cluster)
- [7. Static Pod Revision Rollout Flow](#7-static-pod-revision-rollout-flow)
  - [7.1 The Five Controllers in the Pipeline](#71-the-five-controllers-in-the-pipeline)
  - [7.2 Step 1: Config Change Detection — ConfigObserver](#72-step-1-config-change-detection--configobserver)
  - [7.3 Step 2: Pod Template Rendering — TargetConfigController](#73-step-2-pod-template-rendering--targetconfigcontroller)
  - [7.4 Step 3: Revision Creation — RevisionController](#74-step-3-revision-creation--revisioncontroller)
  - [7.5 Step 4: Node Installation — InstallerController](#75-step-4-node-installation--installercontroller)
  - [7.6 Step 5: Status Reporting](#76-step-5-status-reporting)
  - [7.7 Failure Handling](#77-failure-handling)
  - [7.8 End-to-End Timeline Example](#78-end-to-end-timeline-example)
  - [7.9 Monitoring Revision Rollout](#79-monitoring-revision-rollout)
- [8. Config Reconciliation Mechanism](#8-config-reconciliation-mechanism)
  - [8.1 The ConfigObserver as Config Reconciler](#81-the-configobserver-as-config-reconciler)
  - [8.2 What Triggers Reconciliation](#82-what-triggers-reconciliation)
  - [8.3 Observer Functions](#83-observer-functions)
  - [8.4 Cascading Reconciliation Chain](#84-cascading-reconciliation-chain)
  - [8.5 Self-Healing Properties](#85-self-healing-properties)
- [9. Design Patterns](#9-design-patterns)
  - [9.1 Builder Pattern](#91-builder-pattern-primary-architectural-pattern)
  - [9.2 Factory Method Pattern](#92-factory-method-pattern)
  - [9.3 Strategy Pattern](#93-strategy-pattern)
  - [9.4 Observer / Listener Pattern](#94-observer--listener-pattern)
  - [9.5 Decorator / Wrapper Pattern](#95-decorator--wrapper-pattern)
  - [9.6 Interface Segregation](#96-interface-segregation-fine-grained-interfaces)
  - [9.7 Singleton Pattern](#97-singleton-pattern)
  - [9.8 Chain of Responsibility / Pipeline Pattern](#98-chain-of-responsibility--pipeline-pattern)
  - [9.9 Pattern Summary](#99-pattern-summary)

---

## 1. Defragmentation Trigger Conditions

The defrag controller's `sync` method is invoked on a periodic resync (~11 minutes). Three layers of gates must pass before any defragmentation happens.

### 1.1 Gate 1: Is Defrag Enabled?

Checked in `checkDefragEnabled()` (`defragcontroller.go:107`).

#### 1.1a Manual Disable ConfigMap

If a ConfigMap named `etcd-disable-defrag` exists in the `openshift-etcd-operator` namespace, defrag is unconditionally disabled:

```go
// defragcontroller.go:108-116
disableConfigMap, err := c.configmapLister.ConfigMaps(operatorclient.OperatorNamespace).Get(defragDisableConfigmapName)
if disableConfigMap != nil {
    klog.V(4).Infof("Defrag controller disabled manually via configmap: %s/%s", ...)
    return false, c.ensureControllerDisabledCondition(ctx, operatorv1.ConditionTrue, recorder)
}
```

#### 1.1b Topology Check

Defrag is only allowed on multi-node topologies:

```go
// defragcontroller.go:124-126
if !(controlPlaneTopology == configv1.HighlyAvailableTopologyMode ||
    controlPlaneTopology == configv1.HighlyAvailableArbiterMode ||
    controlPlaneTopology == configv1.DualReplicaTopologyMode) {
    return false, c.ensureControllerDisabledCondition(ctx, operatorv1.ConditionTrue, recorder)
}
```

| Allowed Topology | Meaning |
|---|---|
| `HighlyAvailableTopologyMode` | Standard 3+ control-plane nodes |
| `HighlyAvailableArbiterMode` | HA with arbiter node |
| `DualReplicaTopologyMode` | Two-node with fencing |

Single-node (SNO) and external topologies are excluded.

### 1.2 Gate 2: Cluster Health

Before evaluating fragmentation, the controller checks that **every** etcd member is healthy:

```go
// defragcontroller.go:150-156
memberHealth, err := c.memberLister.MemberHealth(ctx)
if !etcdcli.IsClusterHealthy(memberHealth) {
    return fmt.Errorf("cluster is unhealthy: %s", memberHealth.Status())
}
```

`IsClusterHealthy` returns `false` if **any** member is unhealthy. Even a single unhealthy member blocks defrag for the entire cluster.

Additionally, **learner members** and **unstarted members** (no `ClientURLs`) are filtered out:

```go
// defragcontroller.go:170-172
if member.IsLearner || len(member.ClientURLs) == 0 {
    continue
}
```

### 1.3 Gate 3: Fragmentation Threshold

Each member must meet **both** criteria simultaneously:

```go
// defragcontroller.go:332-338
func isEndpointBackendFragmented(member *etcdserverpb.Member, endpointStatus *clientv3.StatusResponse) bool {
    fragmentedPercentage := checkFragmentationPercentage(endpointStatus.DbSize, endpointStatus.DbSizeInUse)
    return fragmentedPercentage >= maxFragmentedPercentage && endpointStatus.DbSize >= minDefragBytes
}
```

| Condition | Threshold | Constant |
|---|---|---|
| Fragmentation ≥ **45%** | `(DbSize - DbSizeInUse) / DbSize × 100` | `maxFragmentedPercentage = 45` |
| Database size ≥ **100 MB** | `DbSize ≥ 100 * 1024 * 1024` | `minDefragBytes = 100 * 1024 * 1024` |

The fragmentation formula:

```go
// defragcontroller.go:340-343
func checkFragmentationPercentage(ondisk, inuse int64) float64 {
    diff := float64(ondisk - inuse)
    fragmentedPercentage := (diff / float64(ondisk)) * 100
    return math.Round(fragmentedPercentage*100) / 100
}
```

A member with 80% fragmentation but only 50 MB on disk **will not** be defragged. Similarly, a 500 MB database with only 10% fragmentation will be skipped.

### 1.4 Decision Flowchart

```
sync()
 │
 ├─ ConfigMap "etcd-disable-defrag" exists? ──→ SKIP (disabled)
 │
 ├─ Topology ∉ {HA, HA-Arbiter, DualReplica}? ──→ SKIP (disabled)
 │
 ├─ Any etcd member unhealthy? ──→ SKIP (return error)
 │
 ├─ For each member (excluding learners/unstarted):
 │    fragmentation ≥ 45% AND dbSize ≥ 100MB? ──→ Add to defragTargets
 │
 ├─ No targets? ──→ SKIP (nothing to do)
 │
 ├─ Sort: followers-most-fragmented-first, leader last
 │
 ├─ If target is leader → move leadership to least-fragmented follower, requeue
 │
 └─ Defragment first target → requeue after 10s settle time
```

---

## 2. Defrag Execution Path

Once all gates pass, execution enters `runDefrag()`.

### 2.1 Cycle Management

The controller maintains a **defrag cycle** using `c.defragTargets` — it only defrags **one member per sync**:

- **New cycle** (`len(c.defragTargets) == 0`): All members are evaluated via `isEndpointBackendFragmented` and qualifying members are added to `defragTargets`.
- **In-progress cycle**: Existing targets are re-validated — any target whose fragmentation has dropped below the threshold is removed from the list. This prevents unnecessary work if compaction naturally reclaimed space between syncs.

```go
// defragcontroller.go:193-203
if !isNewCycle {
    c.defragTargets = slices.DeleteFunc(c.defragTargets, func(targetID uint64) bool {
        statusMember, has := statusMembers[targetID]
        if !has {
            return true
        }
        return !isEndpointBackendFragmented(statusMember.Member, statusMember.Status)
    })
}
```

### 2.2 Defrag Ordering Strategy

When multiple members need defrag, they are sorted:

```go
// defragcontroller.go:218-226
slices.SortFunc(c.defragTargets, func(a, b uint64) int {
    aIsLeader, bIsLeader := statusMembers[a].IsLeader(), statusMembers[b].IsLeader()
    if aIsLeader && !bIsLeader {
        return 1
    } else if !aIsLeader && bIsLeader {
        return -1
    }
    return sortByMostFragmented(statusMembers[a], statusMembers[b])
})
```

1. **Followers first**, sorted by most fragmented first.
2. **Leader last** — when the leader is the target, the controller proactively moves leadership before defragging.

### 2.3 Leader Transfer Before Defrag

When the defrag target is the leader, the controller moves leadership to minimize churn:

```go
// defragcontroller.go:235-257
if defragTarget.IsLeader() && len(statusMembers) > 1 {
    // Collect followers, sort by least fragmented
    slices.SortFunc(followers, sortByLeastFragmented)

    // Try each follower as new leader candidate
    for _, newLeader := range followers {
        err := c.leaderMover.MoveLeader(ctx, defragTargetMember, newLeader.Member.ID)
        if err != nil {
            recorder.Warningf("DefragControllerLeaderTransferAttemptFailed", ...)
            continue
        }
        // On success: requeue after settle time, defrag on next sync
        syncCtx.Queue().AddAfter(syncCtx.QueueKey(), c.defragSettleTime)
        return nil
    }
    // If all transfers fail: proceed with in-place leader defrag
}
```

The `MoveLeader` call is a **direct gRPC call** to etcd's `MoveLeader` RPC:

```go
// etcdcli.go:253-267
func (g *etcdClientGetter) MoveLeader(ctx context.Context, leader *etcdserverpb.Member, toMember uint64) error {
    cli, err := newEtcdClientWithClientOpts([]string{leader.ClientURLs[0]}, false)
    // ...
    _, err = cli.MoveLeader(ctx, toMember)
    return err
}
```

The MoveLeader API requires the request to be sent to the current leader. A dedicated client is created to the leader's URL to ensure correctness.

### 2.4 Defrag Execution

The actual defragmentation creates a **fresh, dedicated etcd client** to the target member:

```go
// etcdcli.go:489-508
func (g *etcdClientGetter) Defragment(ctx context.Context, member *etcdserverpb.Member) (*clientv3.DefragmentResponse, error) {
    cli, err := newEtcdClientWithClientOpts([]string{member.ClientURLs[0]}, false, WithDialTimeout(DefragDialTimeout))
    // ...
    resp, err := cli.Defragment(ctx, member.ClientURLs[0])
    return resp, nil
}
```

On success:
1. Reset `numDefragFailures` to 0.
2. Clear `DefragControllerDegraded` condition.
3. Remove the completed member from `defragTargets`.
4. Requeue after 10s settle time for the next target.

```go
// defragcontroller.go:272-279
recorder.Eventf("DefragControllerDefragmentSuccess", ...)
c.numDefragFailures = 0
c.clearDegraded(ctx, recorder)
c.defragTargets = c.defragTargets[1:]
syncCtx.Queue().AddAfter(syncCtx.QueueKey(), c.defragSettleTime)
```

### 2.5 Failure Handling and Degraded Condition

On defrag failure:

```go
// defragcontroller.go:261-270
if _, err := c.defragClient.Defragment(ctx, defragTargetMember); err != nil {
    c.numDefragFailures++
    if c.numDefragFailures >= maxDefragFailuresBeforeDegrade {
        c.setDegraded(ctx, recorder)
    }
    syncCtx.Queue().AddAfter(syncCtx.QueueKey(), c.defragSettleTime)
    return nil
}
```

If defrag fails **3 or more times** consecutively (`maxDefragFailuresBeforeDegrade = 3`), the controller sets `DefragControllerDegraded` to `True`. A single success resets the counter and clears the condition.

### 2.6 Timing Parameters

| Parameter | Value | Purpose |
|---|---|---|
| `compactionInterval` | 10 min | etcd's own compaction interval |
| Resync period | **11 min** (`compactionInterval + 1 min`) | Sync just after compaction for maximum benefit |
| `defragSettleTime` | **10 sec** | Delay after leader transfer or defrag before next action |
| Liveness check timeout | **31 min** (`3 × compactionInterval + 1 min`) | Controller marked dead if no sync for ~31 min |
| `maxDefragFailuresBeforeDegrade` | **3** | Consecutive failures before setting Degraded |

### 2.7 Concrete Example: 3-Member HA Cluster

Imagine all 3 members are ≥45% fragmented and ≥100MB:

| Sync # | What happens |
|---|---|
| **Sync 1** | New cycle. All 3 added to `defragTargets`. Sorted: `[follower-A(55%), follower-B(50%), leader-C(48%)]`. Defrag **follower-A**. Requeue in 10s. |
| **Sync 2** | Mid-cycle. Re-validate targets (B and C still qualify). Defrag **follower-B**. Requeue in 10s. |
| **Sync 3** | Mid-cycle. Only leader-C remains. **Move leadership** from C to A (least fragmented). Requeue in 10s. |
| **Sync 4** | C is now a follower. Defrag **C**. Requeue in 10s. |
| **Sync 5** | `defragTargets` is empty → new cycle evaluation. Nobody qualifies → "Defrag skipped". |

---

## 3. Communication Channels

The cluster-etcd-operator uses **two distinct communication channels**: a direct gRPC connection to etcd and the Kubernetes API via kube-apiserver.

```
┌─────────────────────────────────┐
│  cluster-etcd-operator          │
│                                 │
│  Uses TWO communication         │
│  channels:                      │
└──────┬──────────┬───────────────┘
       │          │
       │          │  ② Direct gRPC (port 2379)
       │          │     - MoveLeader
       │          │     - Defragment
       │          │     - MemberList / MemberHealth
       │          │     - Status
       │          │     (mTLS via etcd client certs)
       │          │
       │          ▼
       │     ┌──────────┐
       │     │   etcd   │  (the operand)
       │     │ :2379    │
       │     └──────────┘
       │          ▲
       │          │  (etcd storage backend)
       │          │
       ▼          │
  ┌──────────────────┐
  │ kube-apiserver   │
  │ :6443            │
  └──────────────────┘
  ① Kubernetes API
     - Read/write ConfigMaps, Secrets
     - Watch Nodes, Infrastructure CR
     - Update operator status conditions
     (ServiceAccount token auth)
```

### 3.1 Direct etcd gRPC Channel

The etcd client is constructed with direct etcd endpoints (member IPs on port 2379):

```go
// etcdcli.go:107-111
tlsInfo := transport.TLSInfo{
    CertFile:      "/var/run/secrets/etcd-client/tls.crt",
    KeyFile:       "/var/run/secrets/etcd-client/tls.key",
    TrustedCAFile: "/var/run/configmaps/etcd-ca/ca-bundle.crt",
}
```

```go
// etcdcli.go:124-131
cfg := &clientv3.Config{
    DialOptions: dialOptions,
    Endpoints:   endpoints,   // e.g., https://10.0.0.5:2379
    DialTimeout: clientOpts.dialTimeout,
    TLS:         tlsConfig,
}
```

Operations that use this channel:
- `MoveLeader` — transfer etcd leadership
- `Defragment` — compact the backend database
- `MemberList` — list all etcd cluster members
- `MemberHealth` — health check all members
- `Status` — get DbSize, DbSizeInUse, leader ID

### 3.2 Kubernetes API Channel (via kube-apiserver)

Four types of interactions go through kube-apiserver:

#### 3.2a ConfigMap Read (cached via informer)

```go
// defragcontroller.go:108
disableConfigMap, err := c.configmapLister.ConfigMaps(operatorclient.OperatorNamespace).Get(defragDisableConfigmapName)
```

Backed by a shared informer performing `LIST + WATCH`:
```
GET /api/v1/namespaces/openshift-etcd-operator/configmaps         (initial LIST)
GET /api/v1/namespaces/openshift-etcd-operator/configmaps?watch=1 (ongoing WATCH)
```

The `Get()` call reads from the **local in-memory cache** — no API call per sync.

#### 3.2b Infrastructure CR Read (cached via informer)

```go
// ceohelpers/control_plane_topology.go:16-27
func GetControlPlaneTopology(infraLister configv1listers.InfrastructureLister) (configv1.TopologyMode, error) {
    infraData, err := infraLister.Get(InfrastructureClusterName)
    return infraData.Status.ControlPlaneTopology, nil
}
```

Also cached via informer:
```
GET /apis/config.openshift.io/v1/infrastructures         (initial LIST)
GET /apis/config.openshift.io/v1/infrastructures?watch=1 (ongoing WATCH)
```

#### 3.2c Operator Status Updates (live API calls)

Three status update sites:

- `ensureControllerDisabledCondition` — sets `DefragControllerDisabled` to True/False
- `setDegraded` — sets `DefragControllerDegraded` to True after ≥3 failures
- `clearDegraded` — sets `DefragControllerDegraded` to False on success

All use `v1helpers.UpdateStatus`, which performs a **read-modify-write** cycle:
```
GET  /apis/operator.openshift.io/v1/etcds/cluster          (read current state)
PUT  /apis/operator.openshift.io/v1/etcds/cluster/status    (write updated conditions)
```

These are **live API calls** on every invocation (not cached).

#### 3.2d Event Recording (live API calls)

9 event recording sites in the controller (`recorder.Eventf`, `recorder.Warningf`):
```
POST /api/v1/namespaces/openshift-etcd-operator/events
```

#### Summary of kube-apiserver interactions

| Interaction | API Resource | Verb | Frequency |
|---|---|---|---|
| ConfigMap check | `configmaps` in `openshift-etcd-operator` | **Cached** (WATCH) | Every sync (~11m), read from cache |
| Topology check | `infrastructures.config.openshift.io/cluster` | **Cached** (WATCH) | Every sync (~11m), read from cache |
| Status condition update | `etcds.operator.openshift.io/cluster/status` | **Live** GET+PUT | Only when condition changes |
| Event recording | `events` in `openshift-etcd-operator` | **Live** POST/PATCH | On each defrag action or error |

Reads are cheap (served from local informer cache). Writes are targeted (only when actual state changes or events occur).

---

## 4. Authentication Deep Dive

### 4.1 etcd Authentication: Mutual TLS (mTLS)

The operator uses **mutual TLS** to authenticate with etcd. This is the classic 3-cert model:

| Component | File Path in Pod | Purpose |
|---|---|---|
| **CA cert** | `/var/run/configmaps/etcd-ca/ca-bundle.crt` | Verify etcd server's certificate |
| **Client cert** (public key) | `/var/run/secrets/etcd-client/tls.crt` | Operator's identity presented to etcd |
| **Client private key** | `/var/run/secrets/etcd-client/tls.key` | Proves operator owns the client cert |

The mTLS handshake:

```
Operator ──── ClientHello ────────────────────→ etcd
         ←─── ServerHello + server cert ─────── 
         (operator verifies server cert against ca-bundle.crt)
         ──── client cert (tls.crt) ──────────→
         (etcd verifies client cert against its own CA)
         ──── proves ownership via tls.key ───→
         ←─── TLS session established ────────
         ──── gRPC: MoveLeader / Defragment ──→
```

etcd has no RBAC system — its only access control is "is this client certificate signed by my trusted CA?" If yes, the client gets full access.

### 4.2 kube-apiserver Authentication: Bearer Token (JWT)

The operator authenticates to kube-apiserver using a **ServiceAccount JWT token**, not mTLS.

#### How the token is obtained

The operator pod is deployed with `serviceAccountName: etcd-operator` (in `manifests/0000_20_etcd-operator_06_deployment.yaml`). Kubernetes auto-mounts a projected token:

```
/var/run/secrets/kubernetes.io/serviceaccount/token    ← JWT bearer token
/var/run/secrets/kubernetes.io/serviceaccount/ca.crt   ← kube-apiserver CA certificate
```

#### How the token is used

The library-go framework picks it up via `rest.InClusterConfig()`:

```go
// vendor/k8s.io/client-go/rest/config.go:543-573
func InClusterConfig() (*Config, error) {
    const (
        tokenFile  = "/var/run/secrets/kubernetes.io/serviceaccount/token"
        rootCAFile = "/var/run/secrets/kubernetes.io/serviceaccount/ca.crt"
    )
    host, port := os.Getenv("KUBERNETES_SERVICE_HOST"), os.Getenv("KUBERNETES_SERVICE_PORT")

    token, err := os.ReadFile(tokenFile)

    return &Config{
        Host:            "https://" + net.JoinHostPort(host, port),
        TLSClientConfig: tlsClientConfig,
        BearerToken:     string(token),
        BearerTokenFile: tokenFile,
    }, nil
}
```

Every HTTP request includes:
```
Authorization: Bearer eyJhbGciOiJSUzI1NiIsImtpZCI6...
```

#### What the JWT contains

The ServiceAccount token is a signed JWT with three parts: header, payload, signature.

**Header:**
```json
{
  "alg": "RS256",
  "kid": "<key-id>"
}
```

**Payload:**
```json
{
  "aud": ["https://kubernetes.default.svc"],
  "iss": "https://kubernetes.default.svc",
  "sub": "system:serviceaccount:openshift-etcd-operator:etcd-operator",
  "kubernetes.io": {
    "namespace": "openshift-etcd-operator",
    "serviceaccount": {
      "name": "etcd-operator",
      "uid": "<uid>"
    }
  },
  "exp": <expiration>,
  "iat": <issued-at>
}
```

kube-apiserver verifies the JWT signature using its own public key, extracts the identity, and applies RBAC.

#### RBAC: cluster-admin

The `etcd-operator` ServiceAccount is bound to `cluster-admin`:

```yaml
# manifests/0000_20_etcd-operator_04_clusterrolebinding.yaml
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: system:openshift:operator:etcd-operator
roleRef:
  kind: ClusterRole
  name: cluster-admin
subjects:
- kind: ServiceAccount
  namespace: openshift-etcd-operator
  name: etcd-operator
```

#### Complete authentication flow

```
┌─────────────────────────────────────────────────────────┐
│  Operator Pod (namespace: openshift-etcd-operator)      │
│                                                         │
│  ServiceAccount: etcd-operator                          │
│                                                         │
│  Auto-mounted:                                          │
│   /var/run/secrets/kubernetes.io/serviceaccount/token    │
│   /var/run/secrets/kubernetes.io/serviceaccount/ca.crt   │
│                                                         │
│  rest.InClusterConfig() reads these ──┐                 │
│                                       │                 │
│  Every API call:                      ▼                 │
│   Authorization: Bearer <SA token>                      │
└───────────────────────┬─────────────────────────────────┘
                        │  HTTPS (port 443/6443)
                        ▼
┌─────────────────────────────────────────────────────────┐
│  kube-apiserver                                         │
│                                                         │
│  1. Validates JWT token signature                       │
│  2. Resolves identity:                                  │
│     system:serviceaccount:openshift-etcd-operator:      │
│       etcd-operator                                     │
│  3. RBAC check via ClusterRoleBinding:                  │
│     etcd-operator → cluster-admin  ✅                    │
│  4. Request authorized                                  │
└─────────────────────────────────────────────────────────┘
```

### 4.3 ServiceAccount Purpose

A **ServiceAccount** is a Kubernetes-native identity for processes running inside pods (as opposed to human users).

| Function | How |
|---|---|
| **Identity** | The pod gets a distinct identity like `system:serviceaccount:openshift-etcd-operator:etcd-operator` |
| **Authentication** | A signed JWT token is auto-mounted into the pod |
| **Authorization** | RBAC rules bind to the ServiceAccount (e.g., `etcd-operator` → `cluster-admin`) |
| **Scoping** | Each SA is namespaced — two different namespaces can have an SA with the same name but different permissions |
| **Image pull secrets** | SAs can have `imagePullSecrets` for pulling container images from private registries |

Every namespace has a `default` ServiceAccount. If you don't specify `serviceAccountName` in a pod spec, it uses `default`, which typically has no permissions beyond basic discovery.

### 4.4 mTLS vs Bearer Token Comparison

| Aspect | Bearer Token (JWT) | Mutual TLS (mTLS) |
|---|---|---|
| **What proves identity** | A signed JSON token (something you *have*) | A private key + certificate (cryptographic proof) |
| **Stolen credential impact** | Anyone with the token can impersonate the client until it expires | Attacker needs the private key file — harder to exfiltrate |
| **On the wire** | Token sent in every HTTP request as `Authorization: Bearer <token>` | Identity proven during TLS handshake — never sent in application layer |
| **Replay attack** | If intercepted, token can be reused | Private key never leaves the client — nothing to replay |
| **Expiration/rotation** | Token expires (projected tokens auto-rotate ~1hr) | Certificates expire (CEO rotates etcd certs periodically) |
| **Revocation** | kube-apiserver can reject tokens if the SA is deleted | Must revoke the CA or use CRLs (harder) |
| **Complexity** | Simple — just a string in a header | Complex — requires PKI infrastructure (CA, cert signing, distribution) |

#### Why Kubernetes uses JWT for pods

- **Simplicity at scale** — managing per-pod client certificates would be a massive PKI burden.
- **Automatic rotation** — projected tokens are rotated by the kubelet automatically.
- **Fine-grained identity** — JWT payload contains structured claims (namespace, SA name, UID, audience).
- **Easy revocation** — delete the ServiceAccount and all its tokens become invalid.

#### Why etcd uses mTLS

- **etcd has no RBAC system** — its only access control is certificate validation.
- **Security criticality** — etcd stores all cluster state including Secrets.
- **etcd predates Kubernetes** — mTLS was the standard approach for distributed KV stores.

#### Side-by-side in the operator pod

```
┌─────────────────────────────────────────────────────────┐
│              cluster-etcd-operator pod                   │
├─────────────────────────┬───────────────────────────────┤
│  → kube-apiserver       │  → etcd (direct gRPC)        │
│                         │                               │
│  Auth: Bearer Token     │  Auth: Mutual TLS (mTLS)     │
│  (JWT in HTTP header)   │  (3 certs in TLS handshake)  │
│                         │                               │
│  Token:                 │  CA:   /var/run/configmaps/   │
│   /var/run/secrets/     │         etcd-ca/ca-bundle.crt │
│    kubernetes.io/       │  Cert: /var/run/secrets/      │
│    serviceaccount/token │         etcd-client/tls.crt   │
│                         │  Key:  /var/run/secrets/      │
│  CA (server verify):    │         etcd-client/tls.key   │
│   /var/run/secrets/     │                               │
│    kubernetes.io/       │                               │
│    serviceaccount/ca.crt│                               │
└─────────────────────────┴───────────────────────────────┘
```

---

## 5. kubeconfig and Authentication Methods

### 5.1 kubeconfig Structure

A kubeconfig is a YAML file with three sections:

```
kubeconfig
├── clusters[]      → WHERE to connect (server URL + how to trust it)
├── users[]         → WHO you are (credentials)
└── contexts[]      → Binds a cluster + user + default namespace together
    current-context → Which context is active
```

Example from a typical OpenShift cluster (mTLS variant):

```yaml
clusters:
- cluster:
    certificate-authority-data: <base64 CA cert>  # verifies apiserver TLS
    server: https://api.mycluster.example.com:6443
  name: mycluster

users:
- name: admin
  user:
    client-certificate-data: <base64 cert>   # CN=system:admin, O=system:masters
    client-key-data: <base64 key>            # private key

contexts:
- context:
    cluster: mycluster
    user: admin
    namespace: default
  name: admin

current-context: admin
```

The client certificate identity is extracted by kube-apiserver:
- `CN` (Common Name) → Username (e.g., `system:admin`)
- `O` (Organization) → Groups (e.g., `system:masters`)

### 5.2 Authentication Variants in kubeconfig

A kubeconfig `users[]` section can carry different credential types:

#### Variant 1: mTLS (X.509 client cert)
```yaml
users:
- name: admin
  user:
    client-certificate-data: <base64 cert>
    client-key-data: <base64 key>
```

#### Variant 2: Bearer token (OAuth/JWT)
```yaml
users:
- name: developer
  user:
    token: sha256~aBcDeFgHiJkLmNoPqRsTuVwXyZ...
```
Created by `oc login -u developer -p password`.

#### Variant 3: Exec plugin (cloud providers)
```yaml
users:
- name: cloud-user
  user:
    exec:
      apiVersion: client.authentication.k8s.io/v1
      command: aws-iam-authenticator
      args: ["token", "-i", "my-cluster"]
```
Used by AWS EKS, GCP GKE. The CLI runs the external program which returns a token.

#### Variant 4: Both cert + token (rare)
```yaml
users:
- name: hybrid
  user:
    client-certificate-data: <cert>
    client-key-data: <key>
    token: <token>
```
If both are present, both are sent — kube-apiserver uses whichever authenticator accepts first.

### 5.3 Kubernetes/OpenShift Authentication Methods Overview

Kubernetes authentication is pluggable — the API server uses multiple authenticators simultaneously. A request is authenticated if **any one** succeeds.

| # | Method | Identity | Used By |
|---|---|---|---|
| 1 | **X.509 Client Certificates (mTLS)** | `CN` → username, `O` → groups | Admin kubeconfigs, kubelet, controller-manager, scheduler |
| 2 | **ServiceAccount Tokens (JWT)** | `system:serviceaccount:<ns>:<name>` | All pods communicating with kube-apiserver |
| 3 | **OpenID Connect (OIDC)** | JWT claims from external IdP | Human users via SSO (Google, Azure AD, Keycloak) |
| 4 | **Webhook Token Auth** | Whatever the webhook returns | Custom enterprise auth integrations |
| 5 | **Authenticating Proxy** | `X-Remote-User` header | OpenShift OAuth server, enterprise SSO gateways |
| 6 | **Bootstrap Tokens** | `system:bootstrap:<token-id>` | `kubeadm` node join process |
| 7 | **Static Token File** (deprecated) | From CSV file | Testing only — no expiry, no rotation |
| 8 | **Anonymous** | `system:anonymous` | Health checks (`/healthz`, `/readyz`), discovery API |

#### OpenShift-specific additions

| # | Method | Details |
|---|---|---|
| 9 | **OAuth Tokens** | Issued by OpenShift OAuth server via `oc login`. Stored as `OAuthAccessToken` CRs. Default 24hr lifetime. |
| 10 | **Identity Providers** (backends for OAuth) | HTPasswd, LDAP, OIDC, GitHub, GitLab, Request Header, Keystone |

---

## 6. Verifying Defrag State on a Live Cluster

### Check if the disable ConfigMap exists

```bash
oc get configmap etcd-disable-defrag -n openshift-etcd-operator
```
Expected: `Error from server (NotFound)` if defrag is enabled.

### Check control plane topology

```bash
oc get infrastructure cluster -o jsonpath='{.status.controlPlaneTopology}'
```
Expected: `HighlyAvailable`, `HighlyAvailableArbiter`, or `DualReplica` for defrag to be enabled.

### Check defrag controller conditions

```bash
oc get etcd cluster -o jsonpath='{range .status.conditions[*]}{.type}{"\t"}{.status}{"\t"}{.reason}{"\t"}{.message}{"\n"}{end}' | grep -i defrag
```

Expected output when defrag is enabled and healthy:
```
DefragControllerDisabled    False   AsExpected
DefragControllerDegraded    False   AsExpected
```

### Check defrag events

```bash
oc get events -n openshift-etcd-operator --field-selector reason=DefragControllerDefragmentSuccess
oc get events -n openshift-etcd-operator --field-selector reason=DefragControllerDefragmentFailed
```

---

## 7. Static Pod Revision Rollout Flow

This section traces how the cluster-etcd-operator rolls out a new revision when a config change is applied — from informer detection through to static pod deployment on nodes.

### 7.1 The Five Controllers in the Pipeline

The revision rollout is a pipeline of 5 controllers, each reacting to changes made by the one before it. They are all wired up in `starter.go` via `staticpod.NewBuilder`:

```
User changes config
       │
       ▼
 ┌──────────────────┐     ┌──────────────────┐     ┌──────────────────┐
 │ 1. ConfigObserver │────→│ 2. TargetConfig  │────→│ 3. Revision      │
 │    Controller     │     │    Controller    │     │    Controller    │
 │                   │     │                  │     │                  │
 │ Watches: APIServer│     │ Renders etcd pod │     │ Compares current │
 │ Nodes, ConfigMaps │     │ template with    │     │ ConfigMaps/      │
 │                   │     │ new env vars     │     │ Secrets against  │
 │ Writes:           │     │                  │     │ last snapshot    │
 │ observedConfig on │     │ Writes:          │     │                  │
 │ Etcd CR spec      │     │ ConfigMap        │     │ Creates revision │
 └──────────────────┘     │ "etcd-pod" in    │     │ N+1 snapshots    │
                           │ openshift-etcd   │     │ Sets             │
                           └──────────────────┘     │ LatestAvailable  │
                                                     │ Revision         │
                                                     └────────┬─────────┘
                                                              │
       ┌──────────────────────────────────────────────────────┘
       ▼
 ┌──────────────────┐     ┌──────────────────┐
 │ 4. Installer     │────→│ 5. StaticPod     │
 │    Controller    │     │    State / Status │
 │                  │     │    Controller     │
 │ For each node:   │     │                  │
 │ Spawns installer │     │ Reports progress │
 │ pod on the node  │     │ conditions back  │
 │                  │     │ to the Etcd CR   │
 │ Installer pod    │     │                  │
 │ copies resources │     │ Sets Available,  │
 │ to node disk and │     │ Progressing,     │
 │ writes static    │     │ Degraded         │
 │ pod manifest     │     │ conditions       │
 └──────────────────┘     └──────────────────┘
```

### 7.2 Step 1: Config Change Detection — ConfigObserver

When a user changes configuration (e.g., TLS cipher suites via `APIServer` CR), the **ConfigObserver** detects it through informers watching:

- `APIServer` CR (TLS profiles, cipher suites)
- ConfigMaps in `openshift-etcd`, `openshift-config`, `openshift-config-managed`, `kube-system`
- Endpoints and Pods in `openshift-etcd`
- Master nodes

The controller runs observer functions (`ObserveTLSSecurityProfile`, `ObserveControlPlaneReplicas`) which compute the new desired config.

The library-go `ConfigObserver` sync logic:

1. **Decodes** the current `spec.observedConfig` from the Etcd CR
2. **Runs all observer functions** in random order to compute desired state
3. **Merges** all observer outputs into a single config
4. **Determinism check** — merges in reverse order and compares (catches conflicting outputs)
5. **Diffs** merged config against existing — only writes if there's a change

If the config changed, it writes back:
```
PUT /apis/operator.openshift.io/v1/etcds/cluster
  spec.observedConfig = { ... new TLS settings, replica count, etc ... }
```

The ConfigObserver also resyncs every 1 minute as a safety net, ensuring drift is always corrected.

### 7.3 Step 2: Pod Template Rendering — TargetConfigController

The **TargetConfigController** watches the operator CR and re-renders the etcd pod template whenever `observedConfig` changes. It is also directly notified by the **EnvVarController** via the listener pattern:

```go
// targetconfigcontroller.go:80
envVarGetter.AddListener(c)
```

When synced, it:
1. Gets env vars from the `EnvVarController` (IP addresses, cipher suites, etc.)
2. Renders the etcd pod template from `bindata/etcd/pod.gotpl.yaml` with substitutions (`${IMAGE}`, `${COMPUTED_ENV_VARS}`, etc.)
3. **Writes** the rendered pod YAML into the `etcd-pod` ConfigMap in `openshift-etcd`:

```go
// targetconfigcontroller.go:227-240
podConfigMap.Data["pod.yaml"] = renderedTemplate
podConfigMap.Data["forceRedeploymentReason"] = operatorSpec.ForceRedeploymentReason
podConfigMap.Data["version"] = version.Get().String()
resourceapply.ApplyConfigMap(ctx, client, recorder, podConfigMap)
```

This writes to kube-apiserver:
```
PUT /api/v1/namespaces/openshift-etcd/configmaps/etcd-pod
```

### 7.4 Step 3: Revision Creation — RevisionController

The **RevisionController** watches the ConfigMaps and Secrets that make up a revision and compares current resources against their last snapshotted revision copies.

The resources it tracks (defined in `starter.go`):

| Revisioned ConfigMaps | Revisioned Secrets |
|---|---|
| `etcd-pod` | `etcd-all-certs` |
| `etcd-endpoints` | |
| `etcd-all-bundles` | |

**Change detection** (`isLatestRevisionCurrent`): For each resource, it compares the **current** resource against the **revision-N snapshot**:

```go
// revision_controller.go:158-194
required, _ := c.configMapGetter.ConfigMaps(c.targetNamespace).Get(ctx, cm.Name, ...)        // "etcd-pod"
existing, _ := c.configMapGetter.ConfigMaps(c.targetNamespace).Get(ctx, nameFor(cm.Name, revision), ...) // "etcd-pod-7"

if !equality.Semantic.DeepEqual(existingData, requiredData) {
    configChanges = append(configChanges, fmt.Sprintf("required configmap/%s has changed", cm.Name))
}
```

**Quorum precondition check** — before creating a revision, the controller verifies etcd cluster safety:

```go
// starter.go:321-322
quorumSafe := func(ctx context.Context) (bool, error) {
    return quorumChecker.IsSafeToUpdateRevision()
}
```

This calls `CheckSafeToScaleCluster` which verifies enough healthy members exist to maintain quorum during the rollout.

**When a new revision is created** (e.g., revision 8):

1. Creates `revision-status-8` ConfigMap (marked `revision-ready: false`)
2. Copies `etcd-pod` → `etcd-pod-8` (snapshot)
3. Copies `etcd-endpoints` → `etcd-endpoints-8`
4. Copies `etcd-all-bundles` → `etcd-all-bundles-8`
5. Copies `etcd-all-certs` → `etcd-all-certs-8`
6. Marks `revision-status-8` as `revision-ready: true`
7. Updates `LatestAvailableRevision = 8` on the Etcd CR status

### 7.5 Step 4: Node Installation — InstallerController

The **InstallerController** watches `LatestAvailableRevision` and the per-node `NodeStatuses`. When a node's `CurrentRevision` < `LatestAvailableRevision`, it starts rolling out **one node at a time**.

**Node selection order** (`nodeToStartRevisionWith`):

1. Any node already in transition (has `TargetRevision` set)
2. Any node with a failed last revision
3. Any node with a not-ready static pod (oldest first)
4. Any node with wrong revision (oldest first)
5. Any node with the oldest `CurrentRevision`

**For each node, it creates an installer pod:**

```go
// installer_controller.go:933-1013
pod.Namespace = "openshift-etcd"
pod.Name = "installer-8-master-0"          // installer-<revision>-<nodeName>
pod.Spec.NodeName = ns.NodeName            // pinned to the target node
pod.Spec.Containers[0].Command = ["cluster-etcd-operator", "installer"]
pod.Spec.Containers[0].Args = [
    "--revision=8",
    "--namespace=openshift-etcd",
    "--pod=etcd-pod",
    "--resource-dir=/etc/kubernetes/static-pod-resources",
    "--pod-manifest-dir=/etc/kubernetes/manifests",
    "--configmaps=etcd-pod",
    "--configmaps=etcd-endpoints",
    "--configmaps=etcd-all-bundles",
    "--secrets=etcd-all-certs",
    "--cert-configmaps=...",
    "--cert-secrets=...",
]
```

The installer pod is a **privileged pod** with host filesystem access (`/etc/kubernetes/`). It:

1. Reads `etcd-pod-8`, `etcd-endpoints-8`, `etcd-all-bundles-8`, `etcd-all-certs-8` from the API
2. Writes them to disk at `/etc/kubernetes/static-pod-resources/etcd-pod-8/`
3. Writes the static pod manifest to `/etc/kubernetes/manifests/etcd-pod.yaml`

The **kubelet** on that node watches `/etc/kubernetes/manifests/` and automatically detects the updated manifest, stops the old etcd pod and starts the new one.

### 7.6 Step 5: Status Reporting

After the installer pod succeeds, the InstallerController monitors the **mirror pod** to verify the new static pod is running:

```go
// installer_controller.go:261-300
pod, _ := c.podsGetter.Pods(c.targetNamespace).Get(ctx, "etcd-master-0", ...)
// Check pod.Status.Phase and PodReady condition
```

Static pod states:
- `staticPodStatePending` — installed but not yet ready
- `staticPodStateReady` — running and ready
- `staticPodStateFailed` — pod has failed
- `staticPodStateFallback` — startup-monitor fell back to last-known-good revision

When Ready, the node's status is updated:
```go
ret.CurrentRevision = 8  // now at the new revision
ret.TargetRevision = 0   // no longer in transition
```

The controller generates **status conditions** that report overall cluster progress:

| Condition | Meaning |
|---|---|
| `NodeInstallerProgressing: True` | "2 nodes are at revision 7; 1 node is at revision 8" |
| `StaticPodsAvailable: True` | At least one pod is at the current revision |
| `NodeInstallerDegraded: True` | One or more nodes have failed installation |

These are written back to the Etcd CR status, visible to the cluster admin.

### 7.7 Failure Handling

| Failure | Recovery |
|---|---|
| Installer pod fails | Retried with exponential backoff (10s base, 1.5x factor, 10min max) |
| Static pod fails | If startup-monitor enabled: falls back to last-known-good revision. Retried with backoff (10min base, 2x factor, 2hr max) |
| Quorum unsafe | RevisionController blocks — no new revision is created until quorum is safe |
| Required resources missing | InstallerController waits and retries until all ConfigMaps/Secrets exist |

### 7.8 End-to-End Timeline Example

Imagine a user changes the TLS profile on the `APIServer` CR:

| Time | What happens | Controller |
|---|---|---|
| T+0s | User runs `oc edit apiserver cluster` | — |
| T+1s | APIServer informer fires | **ConfigObserver** |
| T+2s | Computes new cipher config, writes `observedConfig` | **ConfigObserver** |
| T+3s | Operator CR informer fires, EnvVarController notifies | **TargetConfigController** |
| T+4s | Re-renders pod template, writes `etcd-pod` ConfigMap | **TargetConfigController** |
| T+5s | Detects `etcd-pod` differs from `etcd-pod-7` | **RevisionController** |
| T+5s | Quorum precondition check passes | **RevisionController** |
| T+6s | Creates revision 8 snapshots, sets `LatestAvailableRevision=8` | **RevisionController** |
| T+8s | Sees master-0 needs revision 8, sets `targetRevision=8` | **InstallerController** |
| T+9s | Creates `installer-8-master-0` pod | **InstallerController** |
| T+10s | Installer pod copies resources to node disk | **installer binary** |
| T+15s | Kubelet detects new manifest, restarts etcd | **kubelet** |
| T+30s | New etcd pod is Ready | **InstallerController** |
| T+31s | master-0: `currentRevision=8, targetRevision=0` | **InstallerController** |
| T+32s | Moves to master-1, repeats | **InstallerController** |
| ... | Repeat for master-2 | |
| T+~90s | All 3 nodes at revision 8, `NodeInstallerProgressing: False` | **InstallerController** |

### 7.9 Monitoring Revision Rollout

```bash
# Watch revision progress per node
oc get etcd cluster -o jsonpath='{range .status.nodeStatuses[*]}{.nodeName}{"\t"}current={.currentRevision}{"\t"}target={.targetRevision}{"\n"}{end}'

# Watch installer pods
oc get pods -n openshift-etcd -l app=installer --watch

# Watch progressing condition
oc get etcd cluster -o jsonpath='{range .status.conditions[*]}{.type}{"\t"}{.status}{"\t"}{.message}{"\n"}{end}' | grep -i progress

# Check latest available revision
oc get etcd cluster -o jsonpath='{.status.latestAvailableRevision}'
```

---

## 8. Config Reconciliation Mechanism

The cluster-etcd-operator uses a **level-triggered reconciliation** pattern — rather than reacting to events (edge-triggered), each controller continuously compares "what is" against "what should be" and corrects the diff.

### 8.1 The ConfigObserver as Config Reconciler

The library-go `ConfigObserver` is the reconciliation engine. It continuously reconciles the observed cluster state into the operator CR's `spec.observedConfig` field.

The reconciliation loop:

1. **Decode** current `observedConfig` from the Etcd CR
2. **Run** all observer functions in random order to compute desired state from the cluster
3. **Merge** all observer outputs into a single config
4. **Determinism check** — merge in reverse order and compare (catches conflicting observer outputs)
5. **Diff and write** — only write if config actually changed

```go
// config_observer_controller.go:202-209
if !equality.Semantic.DeepEqual(existingConfig, mergedObservedConfig) {
    syncCtx.Recorder().Eventf("ObservedConfigChanged", "Writing updated observed config: %v",
        diff.Diff(existingConfig, mergedObservedConfig))
    return c.updateConfig(ctx, syncCtx, mergedObservedConfig, v1helpers.UpdateObservedConfigFn)
}
return nil  // no change → no write
```

### 8.2 What Triggers Reconciliation

| Trigger | Mechanism |
|---|---|
| Any watched resource changes | Informer event handler enqueues sync |
| Every 1 minute | Periodic resync (`ResyncEvery(time.Minute)`) |

### 8.3 Observer Functions

For the CEO, two observer functions are registered:

| Observer | What it reconciles | Source of truth |
|---|---|---|
| `ObserveTLSSecurityProfile` | TLS cipher suites and min TLS version | `APIServer` CR |
| `ObserveControlPlaneReplicas` | Control plane replica count | `cluster-config-v1` ConfigMap in `kube-system` |

### 8.4 Cascading Reconciliation Chain

Each controller in the pipeline is itself a reconciler:

```
Cluster State (source of truth)
       │ informer events + 1min resync
       ▼
ConfigObserver ──→ reconciles spec.observedConfig
       │ informer event on Etcd CR
       ▼
TargetConfigController ──→ reconciles ConfigMap "etcd-pod"
       │ informer event on ConfigMap
       ▼
RevisionController ──→ reconciles revision snapshots + LatestAvailableRevision
       │ informer event on Etcd CR status
       ▼
InstallerController ──→ reconciles node state (installer pods, CurrentRevision)
```

### 8.5 Self-Healing Properties

The reconciliation design provides self-healing:

| Failure scenario | Recovery |
|---|---|
| Someone manually edits `observedConfig` | ConfigObserver overwrites it on next sync (within 1 minute) |
| `etcd-pod` ConfigMap is deleted | TargetConfigController recreates it on next sync |
| A revision snapshot ConfigMap is deleted | RevisionController detects the diff and creates a new revision |
| An installer pod fails | InstallerController retries with exponential backoff |
| Static pod crashes | Kubelet restarts it; if persistently failing, InstallerController reports `NodeInstallerDegraded` |

Each controller is **idempotent** — if it runs again without any underlying change, it does nothing. If any controller's output is lost or corrupted, the next sync re-derives and re-writes it.

---

## 9. Design Patterns

The cluster-etcd-operator uses multiple design patterns, not just one. It is primarily a **Builder + Factory** architecture, with several other patterns deeply embedded throughout the codebase.

### 9.1 Builder Pattern (Primary Architectural Pattern)

The **Builder** is the most prominent pattern — used to construct both individual controllers and the entire static pod controller suite.

**Controller Factory Builder** — every controller is built with fluent method chaining:

```go
// defragcontroller.go:89-91
return factory.New().
    ResyncEvery(compactionInterval+1*time.Minute).
    WithBareInformers(operatorClient.Informer()).
    WithSync(syncer.Sync).
    ToController("DefragController", eventRecorder.WithComponentSuffix("defrag-controller"))
```

**Static Pod Builder** — the entire static pod controller suite is assembled via `staticpod.NewBuilder`:

```go
// starter.go:325-351
staticPodBuilderControllers := staticpod.NewBuilder(operatorClient, kubeClient, ...).
    WithEvents(controllerContext.EventRecorder).
    WithInstaller([]string{"cluster-etcd-operator", "installer"}).
    WithPruning([]string{"cluster-etcd-operator", "prune"}, "etcd-pod").
    WithRevisionedResources("openshift-etcd", "etcd", RevisionConfigMaps, RevisionSecrets).
    WithUnrevisionedCerts("etcd-certs", CertConfigMaps, CertSecrets).
    WithVersioning("etcd", versionRecorder).
    WithPodDisruptionBudgetGuard(...).
    WithRevisionControllerPrecondition(quorumSafe).
    WithOperandPodLabelSelector(labels.Set{"etcd": "true"}.AsSelector())
```

The `ToControllers()` method then creates the RevisionController, InstallerController, PruneController, NodeController, etc. all at once. This is the classic **Builder** — construct a complex object step-by-step, then finalize with a build/create call.

### 9.2 Factory Method Pattern

The `factory.New()` call itself is a **Factory Method** — it creates a generic controller from configurable parts without the caller needing to know the internal controller implementation:

```go
// factory.go:87-89
func New() *Factory {
    return &Factory{}
}

// factory.go:256
func (f *Factory) ToController(name string, eventRecorder events.Recorder) Controller {
    // creates the concrete controller implementation
}
```

The caller never instantiates the internal `baseController` directly — it always goes through the factory. Different configurations produce controllers with different behaviors (different informers, sync functions, resync intervals), but all return the same `Controller` interface.

### 9.3 Strategy Pattern

**Bootstrap scaling strategies** — different algorithm families for the same operation, selected at runtime:

- `HAScalingStrategy`
- `DelayedHAScalingStrategy`
- `TwoNodeScalingStrategy`
- `BootstrapInPlaceStrategy`
- `UnsafeScalingStrategy`

**Observer functions** in ConfigObserver — each `ObserveConfigFunc` is a strategy for observing a specific config aspect:

```go
// observe_config_controller.go:47
type ObserveConfigFunc func(listers Listers, recorder events.Recorder, existingConfig map[string]interface{}) (map[string]interface{}, []error)
```

The ConfigObserver doesn't care which observers are plugged in — it runs them all and merges results. The CEO plugs in `ObserveTLSSecurityProfile` and `ObserveControlPlaneReplicas` as interchangeable strategies.

### 9.4 Observer / Listener Pattern

The **EnvVarController** uses a classic Observer/Listener pattern to notify dependent controllers of env var changes:

```go
// envvarcontroller.go:67-69
type Enqueueable interface {
    Enqueue()
}

// envvarcontroller.go:128-130
func (c *EnvVarController) AddListener(listener Enqueueable) {
    c.listeners = append(c.listeners, listener)
}

// After computing new env vars:
for _, listener := range c.listeners {
    listener.Enqueue()
}
```

The TargetConfigController registers as a listener:

```go
// targetconfigcontroller.go:80
envVarGetter.AddListener(c)
```

When env vars change, the EnvVarController notifies all listeners, which re-enqueue their sync. This is **publish-subscribe** — the publisher (EnvVarController) doesn't know or care what the subscribers do.

### 9.5 Decorator / Wrapper Pattern

The **CheckingSyncWrapper** wraps a controller's sync function with liveness checking:

```go
// health/checking_sync_wrapper.go:12-19
type CheckingSyncWrapper struct {
    syncFunc          factory.SyncFunc      // the wrapped function
    livenessThreshold time.Duration
    lastSuccessfulRun int64
}

func (r *CheckingSyncWrapper) Sync(ctx context.Context, controllerContext factory.SyncContext) error {
    err := r.syncFunc(ctx, controllerContext)   // delegate to wrapped function
    if err == nil {
        atomic.StoreInt64(&r.lastSuccessfulRun, time.Now().UnixMilli())
    }
    return err
}
```

Used in every controller:

```go
// defragcontroller.go:86-87
syncer := health.NewCheckingSyncWrapper(c.sync, 3*compactionInterval+1*time.Minute)
livenessChecker.Add("DefragController", syncer)
```

The sync function is **decorated** with liveness tracking without modifying the original logic.

### 9.6 Interface Segregation (Fine-Grained Interfaces)

The etcd client uses **interface segregation** — many small, focused interfaces instead of one large one:

```go
// etcdcli/interfaces.go
type Defragment interface {
    Defragment(ctx context.Context, member *etcdserverpb.Member) (*clientv3.DefragmentResponse, error)
}
type Status interface {
    Status(ctx context.Context, target string) (*clientv3.StatusResponse, error)
}
type LeaderMover interface {
    MoveLeader(ctx context.Context, leader *etcdserverpb.Member, toMember uint64) error
}
type MemberLister interface {
    MemberList(ctx context.Context) ([]*etcdserverpb.Member, error)
    VotingMemberList(ctx context.Context) ([]*etcdserverpb.Member, error)
}
```

The `EtcdClient` interface composes them all:

```go
type EtcdClient interface {
    Defragment
    MemberAdder
    MemberPromoter
    MemberHealth
    MemberLister
    LeaderMover
    Status
    // ...
}
```

But controllers accept **only the interfaces they need**. The DefragController takes narrow interfaces:

```go
// defragcontroller.go:50-53
memberLister  etcdcli.AllMemberLister
defragClient  etcdcli.Defragment
statusClient  etcdcli.Status
leaderMover   etcdcli.LeaderMover
```

This enables testability — the `fakeEtcdClient` in tests only needs to implement the methods actually called.

### 9.7 Singleton Pattern

The **operator itself** runs as a singleton — enforced via **leader election** in library-go's `ControllerCommandConfig`. The Kubernetes Deployment runs one replica, and leader election provides fencing to ensure only one instance is active.

The **`AlivenessChecker`** is also effectively a singleton — one global instance shared across all controllers:

```go
// starter.go
var AlivenessChecker = &health.MultiAlivenessChecker{}
```

### 9.8 Chain of Responsibility / Pipeline Pattern

The entire revision rollout is a **pipeline** where each controller hands off to the next:

```
ConfigObserver → TargetConfigController → RevisionController → InstallerController → Status
```

Each controller watches the **output** of the previous one (via informers on the resources the previous controller writes). No controller calls the next directly — they communicate through the Kubernetes API (ConfigMaps, CR status fields). This is a **loosely-coupled chain of responsibility** mediated by the API server.

### 9.9 Pattern Summary

| Pattern | Where | Purpose |
|---|---|---|
| **Builder** | `factory.New().With...().ToController()`, `staticpod.NewBuilder()` | Construct complex controllers step-by-step |
| **Factory Method** | `factory.New()` → `ToController()` | Create controller instances without exposing internals |
| **Strategy** | Bootstrap scaling strategies, `ObserveConfigFunc` | Swap algorithms at runtime |
| **Observer/Listener** | `EnvVarController.AddListener()` | Notify dependents of changes |
| **Decorator/Wrapper** | `CheckingSyncWrapper` wrapping sync functions | Add liveness tracking transparently |
| **Interface Segregation** | Narrow etcd client interfaces (`Defragment`, `Status`, `LeaderMover`) | Accept only what you need, enable testing |
| **Singleton** | Leader election, global `AlivenessChecker` | One active operator instance |
| **Pipeline / Chain of Responsibility** | ConfigObserver → TargetConfig → Revision → Installer | Loosely-coupled multi-stage processing |
