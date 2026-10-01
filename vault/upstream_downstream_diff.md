# Upstream etcd vs OpenShift etcd: A Complete Comparison

**Date:** 2026-10-01
**Purpose:** Comprehensive reference documenting every difference between upstream `etcd-io/etcd` and the OpenShift downstream fork `openshift/etcd`, plus how the `cluster-etcd-operator` (CEO) wraps it.

---

## Table of Contents

1. [Overview](#overview)
2. [Repository Relationship](#repository-relationship)
3. [Downstream Carry Patches](#downstream-carry-patches)
4. [Extra Binary: discover-etcd-initial-cluster](#extra-binary-discover-etcd-initial-cluster)
5. [bbolt Fork](#bbolt-fork)
6. [Build and Image Differences](#build-and-image-differences)
7. [Rebase Process](#rebase-process)
8. [Deployment Model](#deployment-model)
9. [The cluster-etcd-operator (CEO)](#the-cluster-etcd-operator-ceo)
10. [Certificate Management](#certificate-management)
11. [Health Monitoring and Defragmentation](#health-monitoring-and-defragmentation)
12. [Backup and Disaster Recovery](#backup-and-disaster-recovery)
13. [Raft Consensus: What's Identical](#raft-consensus-whats-identical)
14. [Operational Differences](#operational-differences)
15. [Static Pod Architecture](#static-pod-architecture)
16. [Viewing Raft State on a Live Cluster](#viewing-raft-state-on-a-live-cluster)
17. [Key Files Reference](#key-files-reference)
18. [Summary Table](#summary-table)

---

## Overview

OpenShift ships a **fork** of upstream etcd, not a rewrite. The core distributed key-value store — Raft consensus, MVCC storage, WAL, gRPC API — is identical to upstream `etcd-io/etcd`. What OpenShift adds falls into two categories:

1. **In the etcd binary itself** (`openshift/etcd`): A handful of carry patches and one extra binary (`discover-etcd-initial-cluster`).
2. **Around the etcd binary** (`openshift/cluster-etcd-operator`): ~20 controllers that automate everything upstream leaves as manual admin tasks — member management, certificate rotation, health monitoring, defrag, backup, and static pod lifecycle.

The fundamental design principle: **etcd is treated as a black box**. All operational intelligence lives in the operator, not in etcd itself.

---

## Repository Relationship

```text
upstream etcd-io/etcd
        │
        │  openshift-hack/rebase.sh (periodic merge)
        │  Carry patches re-applied on each rebase
        ▼
openshift/etcd (downstream fork)
  ├── 99% upstream etcd code (untouched)
  ├── Carry patches (UPSTREAM: <carry>, DOWNSTREAM: <carry>)
  ├── openshift-tools/ (discover-etcd-initial-cluster)
  ├── openshift-hack/ (rebase automation)
  ├── Dockerfile.rhel, Dockerfile.installer (OpenShift builds)
  │
  │  produces container image with:
  │    /usr/bin/etcd
  │    /usr/bin/etcdctl
  │    /usr/bin/etcdutl
  │    /usr/bin/discover-etcd-initial-cluster   ← OpenShift-only
  │
  └──── consumed by ────►  openshift/cluster-etcd-operator (CEO)
                              ├── ~20 controllers
                              ├── Static pod lifecycle management
                              ├── Certificate rotation
                              ├── Member management
                              ├── Health monitoring & defrag
                              ├── Backup/restore automation
                              └── Operator binary runs as sidecars
                                  inside the etcd static pod
```

---

## Downstream Carry Patches

The `openshift/etcd` fork maintains a minimal set of patches on top of upstream. These are identified by commit message prefixes:

| Prefix | Meaning | Example |
|---|---|---|
| `UPSTREAM: <carry>` | Temporary carry, intended to be upstreamed | Non-blocking defrag |
| `UPSTREAM: <drop>` | One-time rebase housekeeping, discarded on next rebase | Conflict resolution, Go version adjustments |
| `DOWNSTREAM: <carry>` | Permanent OpenShift-specific code | discover-etcd-initial-cluster |

### Current Significant Carries

#### 1. Non-Blocking Defrag

Upstream etcd's defrag blocks the entire gRPC server, causing brief client outages. OpenShift carries a refactored defrag that minimizes gRPC disruption.

**Related flags** (visible in etcd startup):
```text
--feature-gates=StopGRPCServiceOnDefrag=true,NonBlockingDefrag=true
```

**Commits:**
```text
UPSTREAM: <carry>: implement not-as-blocking defrag
UPSTREAM: <carry>: refactor defrag in preparation for non-blocking defrag
```

#### 2. force-new-cluster Revision Bumping / Cluster ID in WAL

Ensures that after a `--force-new-cluster` restore, the cluster ID embedded in the WAL is updated correctly, preventing stale cluster identity issues.

**Tracking:** ETCD-696

#### 3. Quorum-Restore Data Dir Archiving

When a member detects a mismatching cluster ID (post-restore scenario), the `discover-etcd-initial-cluster` binary archives the old data directory instead of failing permanently.

**Tracking:** ETCD-656

#### 4. Protobuf Dependency Bumps

Security/compatibility bumps to `google.golang.org/protobuf` carried downstream when upstream hasn't yet released with them.

**Commits:**
```text
UPSTREAM: <carry>: OCPBUGS-114428: Bump google.golang.org/protobuf to v1.36.12
```

#### 5. Memory Fix Backports

Selective backports of upstream fixes, such as reverting "Reuse events between sync loops" (upstream #21443) to fix memory issues.

---

## Extra Binary: discover-etcd-initial-cluster

**Location:** `openshift-tools/discover-etcd-initial-cluster/`

This is the single most important downstream addition. Upstream etcd expects `ETCD_INITIAL_CLUSTER` as a static string passed at startup. In OpenShift, nodes come and go dynamically, so this binary computes the value at runtime.

### What It Does

Runs inside the etcd container **before** the etcd process starts:

```bash
ETCD_INITIAL_CLUSTER=$(discover-etcd-initial-cluster \
  --cacert=/path/to/server-ca-bundle.crt \
  --cert=/path/to/etcd-peer-NODE_NAME.crt \
  --key=/path/to/etcd-peer-NODE_NAME.key \
  --endpoints=${ALL_ETCD_ENDPOINTS} \
  --data-dir=/var/lib/etcd \
  --target-peer-url-host=${NODE_ETCD_URL_HOST} \
  --target-name=NODE_NAME)
```

### How It Works

1. Connects to existing etcd members using mTLS peer certificates
2. Calls `NonLinearizeableMemberList` to get current membership
3. Matches itself by peer URL
4. Reads local cluster ID from `revision.json` or WAL (fallback)
5. Handles 6 distinct state combinations:

| Member Found? | DataDir Exists? | Cluster ID Match? | Action |
|---|---|---|---|
| Yes, unstarted | No | — | Normal join: output `ETCD_INITIAL_CLUSTER` with all peers |
| Yes, unstarted | Yes | — | Stale data: **archive** old dataDir, restart container |
| Yes, started | Yes | — | Existing member restart: output empty (etcd uses existing data) |
| Yes, started | No | — | DataDir destroyed: **error**, member must be removed |
| No | Yes | Mismatch | Restore scenario: archive dataDir, signal fresh start |
| No | Yes | Match | Scaling issue: error, manual intervention needed |
| No | No | — | Not yet scaled up: **retry** (up to 135 attempts, 1s apart) |

### Why It's Needed

In upstream Kubernetes, you'd manually run:
```bash
etcdctl member add newmember --peer-urls=https://...
# Then start etcd with a hand-crafted --initial-cluster string
```

In OpenShift, the `ClusterMemberController` calls `MemberAddAsLearner`, and `discover-etcd-initial-cluster` automatically computes the right `ETCD_INITIAL_CLUSTER` when the etcd container starts. This bridges the gap between the operator (which knows the membership) and the etcd process (which needs peer info at startup).

---

## bbolt Fork

**What:** `go.mod` contains a `replace` directive:
```go
replace go.etcd.io/bbolt => github.com/openshift/bbolt v...
```

**Why:** The upstream bbolt calls `madvise(MADV_RANDOM)` on memory-mapped database files. On RHEL 10 with transparent huge pages, this causes a page-cache regression where the kernel thrashes pages instead of keeping hot data cached.

**Fix:** The OpenShift bbolt fork removes the `MADV_RANDOM` call.

**Tracking:** OCPBUGS-103516

**Critical Rule:** Never remove this `replace` directive during rebases.

---

## Build and Image Differences

### Binaries Built

| Binary | Upstream | OpenShift | Notes |
|---|---|---|---|
| `etcd` | Yes | Yes | Identical source (plus carry patches) |
| `etcdctl` | Yes | Yes | Identical |
| `etcdutl` | Yes | Yes | Identical |
| `discover-etcd-initial-cluster` | No | Yes | OpenShift-only, from `openshift-tools/` |

### Dockerfiles

| File | Purpose |
|---|---|
| `Dockerfile` | Upstream default |
| `Dockerfile.rhel` | **Production image** — RHEL 9 base, FIPS-compliant Go, includes `jq`, all 4 binaries |
| `Dockerfile.installer` | **Cross-compilation image** for OpenShift installer — builds etcd for linux/amd64, linux/arm64, darwin/amd64, darwin/arm64 (etcd is embedded in the installer for bootstrap) |
| `Dockerfile.art-cachi2` | ART (Automated Release Tooling) variant with dependency caching for disconnected builds |

### Build Command

**Upstream:**
```bash
make build    # builds etcd, etcdctl, etcdutl
```

**OpenShift:**
```bash
./build.sh    # builds etcd, etcdctl, etcdutl, AND discover-etcd-initial-cluster
```

The `build.sh` script includes an extra build step:
```bash
cd ./openshift-tools/discover-etcd-initial-cluster
go build -o="../../bin/discover-etcd-initial-cluster" .
```

---

## Rebase Process

OpenShift periodically merges new upstream etcd releases into the fork using `openshift-hack/rebase.sh`:

```bash
openshift-hack/rebase.sh \
  --etcd-tag=v3.6.13 \
  --openshift-release=openshift-5.0 \
  --jira-id=666
```

### How It Works

1. Creates a JIRA ticket (e.g., OCPBUGS-XXX) for tracking
2. Merges the upstream tag into the OpenShift branch
3. Re-applies carry patches (`UPSTREAM: <carry>`, `DOWNSTREAM: <carry>`)
4. Drops one-time patches (`UPSTREAM: <drop>`)
5. Pauses for manual conflict resolution when needed
6. Pushes a `rebase-$VERSION` branch to the contributor's fork
7. Optionally creates a PR via `gh`

### Post-Rebase Validation

```bash
make build     # Verify compilation
make test      # Unit tests
# Then on the PR:
/payload 4.x nightly informing    # Full OpenShift payload test
/payload 4.x nightly blocking     # Blocking test suite
```

Performance testing is done by the upstream community and OpenShift scalability team, not during every rebase.

---

## Deployment Model

### Upstream etcd

- Binary started directly with command-line flags
- Admin manages configuration, certs, membership manually
- Typically runs as a systemd service or Kubernetes static pod
- No automation around lifecycle management

### OpenShift etcd

- Runs as a **static pod** managed by the `cluster-etcd-operator`
- One etcd pod per control plane node (typically 3)
- Pod definition is rendered by the operator's `TargetConfigController`
- Configuration changes trigger **revision rollouts** through the static pod lifecycle
- The etcd container image is specified by the operator; admins don't choose it

### The etcd Static Pod (7 Containers)

The etcd pod is not just etcd — it includes sidecar containers running the **operator's own binary**:

| Container | Image Source | Purpose |
|---|---|---|
| `setup` | etcd | Init: creates log/backup directories |
| `etcd-ensure-env-vars` | **operator** | Init: validates env vars match node IP before etcd starts |
| `etcd-resources-copy` | etcd | Init: copies scripts to `/usr/local/bin` |
| `etcd` | etcd | The actual etcd process |
| `etcdctl` | etcd | Debug shell (`oc rsh` target, sleeps forever) |
| `etcd-metrics` | etcd | grpc-proxy: exposes metrics on port 9979 with separate metrics certs |
| `etcd-readyz` | **operator** | Health proxy on port 9980 (kubelet probes point here) |
| `etcd-rev` | **operator** | Revision tracking |

### Process Priority

OpenShift runs etcd with maximum scheduling priority:
```bash
nice -n -19 ionice -c2 -n0 etcd
```

### Key Startup Flags (OpenShift-specific)

```text
--feature-gates=InitialCorruptCheck=true,StopGRPCServiceOnDefrag=true,NonBlockingDefrag=true
--snapshot-count=5000
--election-timeout=1000ms
--heartbeat-interval=100ms
--initial-cluster-state=existing    # Always "existing", never "new" after bootstrap
--quota-backend-bytes=8589934592    # 8 GiB (upstream default is 2 GiB)
--max-learners=3
```

---

## The cluster-etcd-operator (CEO)

The operator runs ~20 concurrent controllers, each following the library-go factory pattern. They are organized into categories:

### Cluster Membership Controllers

| Controller | What It Does |
|---|---|
| `ClusterMemberController` | Adds new nodes as learners (`MemberAddAsLearner`), promotes to voters when healthy and deletion hooks are set |
| `ClusterMemberRemovalController` | Removes members for machines pending deletion (one at a time, unhealthy first), after verifying quorum safety and revision stability |
| `BootstrapTeardownController` | Removes the temporary `etcd-bootstrap` member once enough healthy non-bootstrap members exist |
| `MachineDeletionHooksController` | Adds `PreDrain` lifecycle hooks so node deletion blocks until a replacement etcd member is promoted |

### Certificate Controllers

| Controller | What It Does |
|---|---|
| `EtcdCertSignerController` | Manages two CA hierarchies (`etcd-signer`, `etcd-metric-signer`), generates per-node leaf certs, aggregates into `etcd-all-certs` and `etcd-all-bundles` |
| `EtcdCertCleanerController` | Garbage-collects per-node TLS secrets for removed nodes (72h grace period) |

### Configuration Controllers

| Controller | What It Does |
|---|---|
| `TargetConfigController` | Renders the `etcd-pod` ConfigMap (static pod manifest) from templates and cluster state |
| `ConfigObserver` | Watches cluster config (APIServers, Networks, Infrastructure), writes to `Spec.ObservedConfig` |
| `EnvVarController` | Computes etcd process env vars from nodes, endpoints, infrastructure |
| `ScriptController` | Maintains `etcd-scripts` ConfigMap with backup/restore shell scripts |

### Endpoints and Health Controllers

| Controller | What It Does |
|---|---|
| `EtcdEndpointsController` | **Critical:** Maintains `etcd-endpoints` ConfigMap with member IPs. **Must never depend on DNS** (circular dependency) |
| `EtcdMembersController` | Reports member health as operator status conditions |
| `FSyncController` | Monitors WAL fsync latency via Prometheus; sets Degraded if p99 > 3s |
| `DefragController` | Rolling online defrag every 10 min when fragmentation > 45% and DB > 100MB |

### Static Pod Lifecycle Controllers (library-go)

| Controller | What It Does |
|---|---|
| `RevisionController` | Watches `etcd-pod`, `etcd-endpoints`, `etcd-all-bundles`, `etcd-all-certs`; creates numbered revision snapshots on change |
| `InstallerController` | Launches installer pods to write revision resources to each node's filesystem |
| `PruneController` | Retains last 5 successful + 5 failed revisions |
| `GuardController` | PodDisruptionBudget to prevent simultaneous etcd pod eviction |

### Backup Controllers (feature-gated: `AutomatedEtcdBackup`)

| Controller | What It Does |
|---|---|
| `PeriodicBackupController` | Reconciles CronJobs from `Backup` CRs |
| `BackupController` | Creates Jobs for on-demand backups from `EtcdBackup` CRs |
| `BackupRemovalController` | GC of orphaned `EtcdBackup` CRs |

---

## Certificate Management

### Upstream

- Admin manually generates certs using `cfssl`, `openssl`, or similar
- No automatic rotation
- No CA hierarchy enforcement
- Manual cert distribution to each node

### OpenShift (CEO-Managed)

Two independent CA hierarchies:

| CA | Purpose | Validity | Leaf Cert Validity |
|---|---|---|---|
| `etcd-signer` | Client, peer, and serving TLS | 5 years | 5 years (auto-rotate at ~4.2 years) |
| `etcd-metric-signer` | Metrics endpoint TLS | 5 years | 5 years (auto-rotate at ~4.2 years) |

**Two-Phase Rotation (4.17+):**
1. **Revision N**: New CA added to trust bundle (`etcd-all-bundles`), rolled out to all nodes
2. **Revision N+1**: Leaf certs re-signed with new CA

This prevents TLS failures when a peer starts with new certs before other peers have the new CA bundle. Gated by the `openshift.io/ceo-bundle-rollout-revision` annotation.

**Aggregation Pattern:**
- `etcd-all-certs` (Secret): All per-node certs in one resource
- `etcd-all-bundles` (ConfigMap): All CA bundles in one resource
- One resource change = one revision rollout = atomic update

---

## Health Monitoring and Defragmentation

### Upstream

```bash
# Manual health check
etcdctl endpoint health

# Manual defrag
etcdctl defrag
```

### OpenShift

**Health Monitoring** — Automated by `EtcdMembersController`:
- Linearizable reads for voting members (proves Raft participation)
- Serializable reads for learners (local-only)
- Parallel health checks with independent timeouts
- Results feed into operator status conditions and gate all scaling/removal operations

**Defragmentation** — Automated by `DefragController`:
- Runs every 10 minutes (matches etcd compaction interval)
- Triggers when fragmentation > 45% AND DB > 100MB
- Rolling defrag: one member at a time, **leader last**
- Uses 60s dial timeout (4x normal) since defrag stalls the member
- Disabled via `etcd-disable-defrag` ConfigMap
- Sets `DefragControllerDegraded` after 3 consecutive failures

**FSync Monitoring** — `FSyncController`:
- Queries Prometheus for WAL fsync durations
- Detects excessive leader changes (≥ 2 in 5 minutes)
- Sets Degraded if any member's p99 WAL fsync exceeds 3 seconds

---

## Backup and Disaster Recovery

### Upstream

```bash
# Manual snapshot
etcdctl snapshot save /path/to/backup.db

# Manual restore
etcdutl snapshot restore backup.db --data-dir=/new/data/dir
```

### OpenShift

**Automated Backup** (feature-gated: `AutomatedEtcdBackup`):
- `Backup` CRs drive CronJob-based periodic backups
- `EtcdBackup` CRs trigger on-demand backup Jobs
- Serial execution enforced — one backup at a time

**Disaster Recovery:**
- `cluster-backup.sh` and `cluster-restore.sh` scripts maintained in `etcd-scripts` ConfigMap
- `discover-etcd-initial-cluster` handles post-restore cluster identity (archives stale data dir on cluster ID mismatch)
- Operator coordinates member removal, re-addition, and learner promotion during recovery

---

## Raft Consensus: What's Identical

The following are **completely unchanged** between upstream and OpenShift:

| Component | Notes |
|---|---|
| Raft algorithm | Same implementation in `server/etcdserver/raft.go` |
| Leader election | Same randomized timeout, same `MsgVote`/`MsgVoteResp` protocol |
| Log replication | Same `AppendEntries` RPC, same quorum commit rules |
| Learner (non-voting) members | Same protocol; OpenShift automates the `MemberAddAsLearner` → `MemberPromote` flow |
| WAL (write-ahead log) | Same format, same fsync guarantees |
| Snapshots | Same snapshot format and compaction trigger |
| BoltDB storage | Same (with bbolt fork for RHEL page-cache fix) |
| MVCC | Same revision semantics, same key index structure |
| gRPC API | Same `KV`, `Watch`, `Lease`, `Cluster`, `Maintenance` services |
| Client library (`client/v3`) | Same |
| `etcdctl` commands | Same |
| Auth/RBAC | Same |
| Transaction model | Same |
| Watch mechanism | Same |
| Lease system | Same |

**In short:** If you're debugging Raft behavior, log replication, storage, or the client API, the upstream etcd documentation applies directly. OpenShift changes nothing about how etcd works internally.

---

## Operational Differences

| Operation | Upstream | OpenShift |
|---|---|---|
| **Start etcd** | `etcd --name=... --initial-cluster=...` | kubelet reads static pod manifest written by InstallerController |
| **Add member** | `etcdctl member add --learner` + manual start | ClusterMemberController calls `MemberAddAsLearner`, discover-etcd-initial-cluster computes peers |
| **Remove member** | `etcdctl member remove <id>` | ClusterMemberRemovalController with quorum safety, Machine API hooks |
| **Rotate certs** | Manual: generate new certs, distribute, restart | EtcdCertSignerController: two-phase rotation, aggregated bundles, automatic revision rollout |
| **Defrag** | `etcdctl defrag` on each member | DefragController: rolling, leader-last, threshold-based |
| **Backup** | `etcdctl snapshot save` | BackupController: Job-based, CronJob-based periodic |
| **Restore** | `etcdutl snapshot restore` + manual restart | cluster-restore.sh + operator-managed re-scaling |
| **Health check** | `etcdctl endpoint health` | EtcdMembersController: continuous, feeds status conditions |
| **Move leader** | `etcdctl move-leader <id>` | Operator does this before defrag of the leader |
| **Update config** | Edit flags, restart process | TargetConfigController renders new config → RevisionController → InstallerController → kubelet restarts |
| **Monitor performance** | Manual Prometheus/Grafana setup | FSyncController queries Prometheus, operator exposes metrics |
| **Scale cluster** | Manual member add/remove | Automated via Machine API integration with quorum safety |

---

## Static Pod Architecture

### Revision Rollout Flow

When any configuration changes (certs, endpoints, env vars, pod template):

```text
1. TargetConfigController renders new etcd-pod ConfigMap
2. RevisionController detects change, creates revision N
   (copies ConfigMaps/Secrets with -N suffix)
   ├── Gated by QuorumChecker.IsSafeToUpdateRevision()
   └── Gated by bundle-rollout annotation (cert rotation)
3. InstallerController launches installer pod on each node
4. Installer pod writes to /etc/kubernetes/static-pod-resources/etcd-pod-N/
5. Installer updates /etc/kubernetes/manifests/etcd-pod.yaml
6. kubelet detects inotify change, restarts etcd static pod
7. PruneController retains last 5 successful + 5 failed revisions
```

### On-Disk Layout (per control plane node)

```text
/etc/kubernetes/
├── manifests/
│   └── etcd-pod.yaml                    ← kubelet watches this
├── static-pod-resources/
│   ├── etcd-pod-7/                      ← current revision
│   │   ├── etcd-pod.yaml
│   │   ├── configmaps/
│   │   │   ├── etcd-endpoints/
│   │   │   ├── etcd-all-bundles/
│   │   │   └── etcd-pod/
│   │   └── secrets/
│   │       └── etcd-all-certs/
│   ├── etcd-pod-6/                      ← previous revision
│   └── etcd-certs/                      ← unrevisioned cert copy
└── /var/lib/etcd/
    └── member/
        ├── wal/                         ← Raft write-ahead log
        │   ├── 0000000000000000-0000000000000000.wal
        │   ├── 0000000000000001-0000000000006dc4.wal
        │   └── 1.tmp                    ← pre-allocated next segment
        └── snap/                        ← Raft snapshots
            ├── 0000000000000007-000000000000a4c2.snap
            └── db                       ← BoltDB database file
```

---

## Viewing Raft State on a Live Cluster

Since the Raft engine is identical, the same commands work. The difference is **how you access** etcd:

### Upstream
```bash
etcdctl endpoint status --write-out=table
```

### OpenShift (via etcdctl sidecar)
```bash
# The etcdctl container has ETCDCTL_* env vars pre-configured
oc -n openshift-etcd rsh -c etcdctl <etcd-pod-name> \
  etcdctl endpoint status --cluster --write-out=table
```

### Key Commands

```bash
# Raft term, index, leader, DB size
etcdctl endpoint status --cluster --write-out=table

# Member list with learner status
etcdctl member list --write-out=table

# Health check (linearizable read)
etcdctl endpoint health --cluster --write-out=table
```

### Example Output (from a live OpenShift cluster)

```text
+---------------------------+------------------+---------+---------+-----------+------------+-----------+
|         ENDPOINT          |        ID        | VERSION | DB SIZE | IS LEADER | RAFT TERM  | RAFT INDEX|
+---------------------------+------------------+---------+---------+-----------+------------+-----------+
| https://10.0.52.133:2379  | 178161e5aa2d6035 |  3.6.13 |   90 MB |      true |          7 |     53869 |
|   https://10.0.0.85:2379  | 1ffb246d653aaaf7 |  3.6.13 |   90 MB |     false |          7 |     53869 |
| https://10.0.80.117:2379  | ed6650fc9cf93637 |  3.6.13 |   90 MB |     false |          7 |     53869 |
+---------------------------+------------------+---------+---------+-----------+------------+-----------+
```

**Reading this:**
- **RAFT TERM = 7**: 7 leader elections since cluster creation
- **RAFT INDEX = 53869**: 53,869 committed Raft entries
- All nodes at the same term and index = perfectly in sync
- **IS LEADER = true** for 10.0.52.133: this node coordinates all writes

### Raft Metrics (via Prometheus)

```bash
# From inside the etcd container
curl -sk --cert <cert> --key <key> https://localhost:9978/metrics | \
  grep -E "^(etcd_server_leader_changes|etcd_server_proposals|raft_term)"
```

| Metric | What It Shows |
|---|---|
| `etcd_server_leader_changes_seen_total` | Number of leader elections |
| `etcd_server_proposals_committed_total` | Raft entries committed through consensus |
| `etcd_server_proposals_applied_total` | Entries applied to BoltDB (should match committed) |
| `etcd_server_proposals_pending` | Entries waiting for quorum (should be ~0) |
| `etcd_server_proposals_failed_total` | Failed proposals (quorum issues) |

### Raft Logs (etcd server logs)

```bash
oc -n openshift-etcd logs <etcd-pod> -c etcd | grep -iE "raft|elect|leader|vote"
```

Shows leader elections, vote requests/responses, and term changes:
```text
raft: 178161e5 became leader at term 7
raft: 178161e5 received MsgVoteResp from ed6650fc at term 7
raft: 178161e5 has received 2 MsgVoteResp votes and 0 vote rejections
```

---

## Key Files Reference

### openshift/etcd (Operand)

| File | Purpose |
|---|---|
| `openshift-tools/pkg/discover-etcd-initial-cluster/initial-cluster.go` | Bootstrap logic — computes ETCD_INITIAL_CLUSTER |
| `openshift-tools/pkg/discover-etcd-initial-cluster/walutil.go` | Reads cluster ID from WAL (fallback) |
| `openshift-hack/rebase.sh` | Rebase automation |
| `REBASE.openshift.md` | Rebase and bbolt-fork procedures |
| `build.sh` | Builds all binaries including downstream helpers |
| `Dockerfile.rhel` | Production container image |
| `Dockerfile.installer` | Cross-platform installer image |
| `go.mod` | Module wiring, **bbolt replace directive** |
| `server/etcdserver/server.go` | Core etcd server (upstream) |
| `server/etcdserver/raft.go` | Raft node implementation (upstream) |
| `server/storage/mvcc/` | MVCC storage (upstream) |
| `server/storage/wal/` | Write-ahead log (upstream) |
| `api/etcdserverpb/rpc.proto` | gRPC API definition (upstream) |
| `AGENTS.md` | AI agent guide for the fork |
| `ARCHITECTURE.md` | Comprehensive etcd internals documentation |

### openshift/cluster-etcd-operator (Operator)

| File | Purpose |
|---|---|
| `pkg/operator/starter.go` | All controller initialization and wiring |
| `pkg/operator/clustermembercontroller/` | Learner add + promotion |
| `pkg/operator/clustermemberremovalcontroller/` | Member removal with quorum safety |
| `pkg/operator/etcdcertsigner/` | Certificate lifecycle management |
| `pkg/operator/targetconfigcontroller/` | Static pod manifest rendering |
| `pkg/operator/etcdendpointscontroller/` | DNS-independent IP tracking |
| `pkg/operator/defragcontroller/` | Rolling defrag |
| `pkg/operator/etcdmemberscontroller/` | Health monitoring |
| `pkg/etcdcli/etcdcli.go` | etcd client wrapper |
| `pkg/etcdcli/etcdcli_pool.go` | Connection pooling (max 10 cached, 20 total) |
| `pkg/etcdenvvar/etcd_env.go` | Environment variable computation |
| `bindata/etcd/pod.gotpl.yaml` | Static pod template |
| `bindata/etcd/cluster-backup.sh` | Backup script |
| `bindata/etcd/cluster-restore.sh` | Restore script |
| `AGENTS.md` | AI agent guide for the operator |
| `ARCHITECTURE.md` | Operator architecture documentation |

---

## Summary Table

| Aspect | Upstream etcd | OpenShift etcd |
|---|---|---|
| **Core etcd binary** | `etcd-io/etcd` | Fork with ~5 carry patches |
| **Raft consensus** | Identical | Identical |
| **Storage (MVCC, BoltDB, WAL)** | Identical | Identical (bbolt fork for RHEL page-cache) |
| **gRPC API** | Identical | Identical |
| **Extra binary** | None | `discover-etcd-initial-cluster` |
| **Defrag behavior** | Blocks gRPC server | Non-blocking (carry patch) |
| **Deployment** | Manual binary / systemd | Static pod managed by operator |
| **Member management** | Manual `etcdctl member add/remove` | Automated by CEO controllers |
| **Certificate management** | Manual generation and distribution | Automated: 2 CA hierarchies, two-phase rotation |
| **Health monitoring** | Manual `etcdctl endpoint health` | Continuous, feeds operator status conditions |
| **Defragmentation** | Manual `etcdctl defrag` | Automated: rolling, threshold-based, leader-last |
| **Backup** | Manual `etcdctl snapshot save` | Automated via CronJobs (feature-gated) |
| **Disaster recovery** | Manual restore procedure | Semi-automated with operator coordination |
| **Configuration changes** | Edit flags, restart process | Revision rollout: render → snapshot → install → kubelet restart |
| **Scaling** | Manual, no safety gates | Automated with quorum safety, Machine API hooks |
| **Container image** | Generic | RHEL 9 base, FIPS-compliant, includes `jq` |
| **Build system** | Standard `make` | ART (Automated Release Tooling) with dependency caching |
| **Update process** | Download new binary | Operator-driven OTA via CVO |
| **Quota** | 2 GiB default | 8 GiB |
| **Snapshot count** | 10,000 (default) | 5,000 |
| **Process priority** | Normal | `nice -n -19 ionice -c2 -n0` |

---

**The fundamental difference:** Upstream etcd is a **database**. OpenShift wraps it in an **operations platform** — the cluster-etcd-operator automates everything that upstream leaves as manual admin work, while keeping the etcd binary itself nearly identical.

---

**Document Version:** 1.0
**Last Updated:** 2026-10-01
**Source Repos:** `openshift/etcd`, `openshift/cluster-etcd-operator`
