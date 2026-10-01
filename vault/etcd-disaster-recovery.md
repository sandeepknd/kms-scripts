# Etcd Disaster Recovery and Member Replacement Flow

This document traces the complete lifecycle of etcd member replacement in the cluster-etcd-operator — from detecting an unhealthy member, through the Raft learner protocol, to full cluster restoration after a total loss.

Companion to [etcd-rollout-flow.md](./etcd-rollout-flow.md), which covers revision-based configuration rollouts.

## Table of Contents

- [Overview](#overview)
- [Controllers Involved](#controllers-involved)
- [Phase 1: Detecting the Unhealthy Member](#phase-1-detecting-the-unhealthy-member)
- [Phase 2: Machine API Coordination — The PreDrain Hook](#phase-2-machine-api-coordination--the-predrain-hook)
- [Phase 3: New Node Comes Up](#phase-3-new-node-comes-up)
- [Phase 4: Adding the New Member as a Learner](#phase-4-adding-the-new-member-as-a-learner)
- [Phase 5: Raft Log Replication — The Learner Catching Up](#phase-5-raft-log-replication--the-learner-catching-up)
- [Phase 6: Learner Promotion — Becoming a Voting Member](#phase-6-learner-promotion--becoming-a-voting-member)
- [Phase 7: Removing the Old Member](#phase-7-removing-the-old-member)
- [Phase 8: Cleanup and Revision Rollout](#phase-8-cleanup-and-revision-rollout)
- [End-to-End Timeline](#end-to-end-timeline)
- [Raft Consensus Deep Dive](#raft-consensus-deep-dive)
- [Quorum Safety Invariants](#quorum-safety-invariants)
- [Defragmentation During Recovery](#defragmentation-during-recovery)
- [Full Cluster Restore (Total Loss)](#full-cluster-restore-total-loss)
- [Failure Handling](#failure-handling)
- [Key Code References](#key-code-references)

---

## Overview

Member replacement is fundamentally different from a revision rollout. A revision rollout updates the configuration of existing etcd pods. Member replacement changes the **cluster topology** — removing a member from the Raft consensus group and adding a new one.

Etcd uses the **Raft distributed consensus algorithm** to replicate data across members. In a 3-member cluster, quorum requires 2 members. Losing quorum means the cluster cannot accept writes. The operator must orchestrate member replacement carefully to never lose quorum, even transiently.

The key mechanism is etcd's **learner (non-voting) member** role. A new member joins as a learner first — it receives the Raft log from the leader but does not vote and does not count toward quorum. Only after it has caught up with the leader's log is it promoted to a full voting member. This prevents a slow new member from destabilizing the cluster.

---

## Controllers Involved

Six controllers work in concert for member replacement. This is separate from the three-controller pipeline (TargetConfigController → RevisionController → InstallerController) used for revision rollouts.

| Controller | File | Role |
|---|---|---|
| **EtcdMembersController** | `pkg/operator/etcdmemberscontroller/etcdmemberscontroller.go` | Health monitoring — detects unhealthy members, reports status conditions |
| **MachineDeletionHooksController** | `pkg/operator/machinedeletionhooks/machinedeletionhooks.go` | Coordinates with Machine API via PreDrain lifecycle hooks |
| **ClusterMemberController** | `pkg/operator/clustermembercontroller/clustermembercontroller.go` | Adds new member as learner, promotes learner to voter |
| **ClusterMemberRemovalController** | `pkg/operator/clustermemberremovalcontroller/clustermemberremovalcontroller.go` | Removes old member from etcd cluster |
| **EtcdEndpointsController** | `pkg/operator/etcdendpointscontroller/etcdendpointscontroller.go` | Maintains `etcd-endpoints` ConfigMap with voting member IPs |
| **TargetConfigController** | `pkg/operator/targetconfigcontroller/targetconfigcontroller.go` | Renders etcd pod ConfigMap, triggers revision rollout with updated membership |

All are registered in `pkg/operator/starter.go` — the `TargetConfigController` at line 299, and the remaining five between lines 442-619.

---

## Phase 1: Detecting the Unhealthy Member

**File:** `pkg/operator/etcdmemberscontroller/etcdmemberscontroller.go`

The EtcdMembersController syncs every 1 minute (`ResyncEvery(time.Minute)`) and calls `reportEtcdMembers()`.

### Health Check Mechanism

The health check (`pkg/etcdcli/health.go:44`, `GetMemberHealth()`) runs **parallel goroutines** for every member simultaneously, each with an independent 30-second timeout:

**For voting members** — a **linearized** read:
```go
resp, err = cli.Get(ctx, "health")
```
A linearizable read requires Raft consensus. If the member is partitioned from the leader, has crashed, or is too slow to participate in consensus, this times out. This proves the member is actively participating in the Raft group.

**For learner members** — a **serializable** (local) read:
```go
resp, err = cli.Get(ctx, "health", clientv3.WithSerializable())
```
Learners cannot participate in consensus, so a serializable read goes directly to the member's local store. This verifies the process is running and responsive, though not that it is up-to-date.

**For unstarted members** (no `ClientURLs`) — immediately classified as `NotStarted`. These are members that have been added to the cluster configuration but whose etcd process hasn't connected yet.

**File:** `pkg/etcdcli/health.go:96-120` (`checkSingleMemberHealth()`)

### Raft Term Tracking

Each health check response includes the Raft term (`resp.Header.RaftTerm`). The controller records this as the `etcd_debugging_raft_terms_total` Prometheus metric. Each leader election increments the term — a rising term indicates election churn, which is a sign of instability.

### Status Conditions Set

| Condition | When Set |
|---|---|
| `EtcdMembersDegraded=True` | Any member fails the health check (reason: `UnhealthyMembers`) |
| `EtcdMembersProgressing=True` | Any member has `NotStarted` status (reason: `MembersNotStarted`) |
| `EtcdMembersAvailable=False` | Healthy members ≤ `total/2` (quorum lost). Exception: Two Node OpenShift with Fencing clusters that have completed the transition to external etcd (Pacemaker-managed) bypass this check via `hasExternalEtcdCompletedTransition`. |

### Member Status Categories

Defined in `pkg/etcdcli/interfaces.go:10-14`:

| Status | Meaning |
|---|---|
| `EtcdMemberStatusAvailable` | Health check succeeded |
| `EtcdMemberStatusNotStarted` | No ClientURLs and no Name — never connected |
| `EtcdMemberStatusUnhealthy` | Health check failed (timeout, connection refused, etc.) |
| `EtcdMemberStatusUnknown` | Cannot create etcd client to this member |

---

## Phase 2: Machine API Coordination — The PreDrain Hook

**File:** `pkg/operator/machinedeletionhooks/machinedeletionhooks.go`

The Machine API manages the lifecycle of the underlying infrastructure (VMs, bare metal). When a machine is deleted, the Machine API drains workloads and terminates the VM. Without coordination, this would kill etcd before the operator can safely remove the member — potentially losing quorum.

### How the Hook Works

The MachineDeletionHooksController continuously ensures every master Machine has a **PreDrain lifecycle hook**:

```go
// pkg/operator/ceohelpers/common.go:28-32
const MachineDeletionHookName = "EtcdQuorumOperator"
const MachineDeletionHookOwner = "clusteroperator/etcd"
```

`addDeletionHookToMasterMachines()` (line 236) adds this hook to `Machine.Spec.LifecycleHooks.PreDrain`. The Machine API **will not drain the node** as long as this hook exists.

### The Coordination Sequence

```
Admin/CPMS deletes Machine → Machine gets DeletionTimestamp
  │
  ├─ PreDrain hook "EtcdQuorumOperator" BLOCKS drain
  │  (Machine API waits)
  │
  ├─ CPMS creates replacement Machine → new node boots
  │
  ├─ New etcd member joins via learner protocol (Phases 4-6)
  │
  ├─ Old etcd member removed from cluster (Phase 7)
  │
  ├─ attemptToDeleteMachineDeletionHook() (line 112):
  │  Old member's IP no longer in etcd membership
  │  → removes "EtcdQuorumOperator" hook from Machine
  │
  ├─ attemptToDeleteQuorumGuard() (line 174):
  │  After hook removed and node cordoned
  │  → deletes quorum guard pod to unblock PDB
  │
  └─ Machine API proceeds: drains workloads, terminates VM
```

---

## Phase 3: New Node Comes Up

When the replacement Machine is provisioned and the new node boots:

1. **Kubelet starts** on the new node
2. Kubelet reads `/etc/kubernetes/manifests/etcd-pod.yaml` (placed by the InstallerController during the initial cluster setup or a previous revision rollout)
3. The etcd container starts, but before etcd itself runs, the **`discover-etcd-initial-cluster`** binary executes

### The discover-etcd-initial-cluster Process

**File:** `bindata/etcd/pod.gotpl.yaml` (line 147)

```bash
ETCD_INITIAL_CLUSTER=$(discover-etcd-initial-cluster \
  --cacert=/etc/kubernetes/static-pod-certs/configmaps/etcd-all-bundles/... \
  --cert=/etc/kubernetes/static-pod-certs/secrets/etcd-all-certs/... \
  --key=/etc/kubernetes/static-pod-certs/secrets/etcd-all-certs/... \
  --endpoints=${ALL_ETCD_ENDPOINTS} \
  --data-dir=/var/lib/etcd \
  --target-peer-url-host=${NODE_NODE_ENVVAR_NAME_ETCD_URL_HOST} \
  --target-name=NODE_NAME)
export ETCD_INITIAL_CLUSTER
```

This process:
1. Connects to existing etcd members using `ALL_ETCD_ENDPOINTS` (all voting members' client URLs)
2. Calls `MemberList` to get the current cluster membership
3. Looks for itself in the member list (matched by peer URL / target name)
4. **If not found**: waits and retries — the `ClusterMemberController` hasn't added it yet
5. **If found**: constructs the `ETCD_INITIAL_CLUSTER` string (`name1=https://ip1:2380,name2=https://ip2:2380,...`) and returns

During this wait, the pod is **Running but NOT Ready**. This is the signal the `ClusterMemberController` looks for in the next phase.

### Critical Environment Variable

```go
// pkg/etcdenvvar/etcd_env.go:49-56
var FixedEtcdEnvVars = map[string]string{
    "ETCD_INITIAL_CLUSTER_STATE": "existing",
    // ...
}
```

`ETCD_INITIAL_CLUSTER_STATE` is **hardcoded to `"existing"`** — every etcd member joins as an addition to an existing cluster. The value `"new"` is only used during the initial cluster bootstrap at install time and never again.

---

## Phase 4: Adding the New Member as a Learner

**File:** `pkg/operator/clustermembercontroller/clustermembercontroller.go`

The `ClusterMemberController.reconcileMembers()` (line 108) orchestrates both learner addition and promotion.

### Pre-checks Before Adding

**All existing members must be healthy** (line 109-117):
```go
unhealthyMembers, err := c.etcdClient.UnhealthyMembers(ctx)
if len(unhealthyMembers) > 0 {
    return nil  // don't add members when cluster is unhealthy
}
```

Adding a member to an unhealthy cluster risks further destabilization. The operator waits until the cluster is stable before proceeding.

**DualReplica/Pacemaker skip** (lines 119-129): For Two Node OpenShift with Fencing clusters that have completed the transition to external etcd (Pacemaker-managed), member management is skipped entirely via `ShouldSkipMemberManagementForDualReplica()` — Pacemaker handles etcd membership in this topology.

### Finding the Right Node

`getEtcdPeerURLToAdd()` (line 154) identifies which node needs an etcd member:

1. Lists all master nodes, finds those whose IPs are NOT in the current voting member set (`allNodesMapToVotingMembers()`, line 398)

2. For each candidate node, verifies:
   - Node is not pending deletion (line 178)
   - Node's peer URL doesn't already map to any member, including learners (line 190)
   - If Machine API is functional: Machine exists, is not pending deletion, and has the `EtcdQuorumOperator` PreDrain hook (lines 216-241)

3. **Waits for the etcd container to be Running but Not Ready** — `isEtcdContainerRunningNotReady()` (line 365-394):
   ```go
   isEtcdContainerRunning = containerStatus.State.Running != nil
   isEtcdContainerReady = containerStatus.Ready
   if !isEtcdContainerRunning || isEtcdContainerReady {
       return false, nil  // not ready to be added
   }
   ```
   This confirms `discover-etcd-initial-cluster` is waiting inside the container for membership.

### Only One at a Time

The code explicitly adds only one member per sync cycle (lines 246-248). The reason: "If multiple new nodes are added as members in parallel they will fail with a discovery error (`error validating peerURLs: member count is unequal`) because the unstarted members won't include each other in their `ETCD_INITIAL_CLUSTER` env."

### The Learner Add Call

```go
err = c.etcdClient.MemberAddAsLearner(ctx, peerURL)
```

**File:** `pkg/etcdcli/etcdcli.go:158-190`

The implementation first checks idempotency (is this peer URL already a member?) before calling etcd's `MemberAddAsLearner` API:

```go
func (g *etcdClientGetter) MemberAddAsLearner(ctx context.Context, peerURL string) error {
    // Check if already a member (idempotency)
    for _, member := range membersResp.Members {
        if slices.Contains(member.PeerURLs, peerURL) {
            g.eventRecorder.Warningf("MemberAlreadyAdded", ...)
            return nil
        }
    }
    // Add as learner
    _, err = cli.MemberAddAsLearner(ctx, []string{peerURL})
}
```

### What Happens After the Add

1. The etcd leader adds a `ConfChange` entry to the Raft log, registering the new member as a learner
2. `discover-etcd-initial-cluster` (still running inside the new pod) calls `MemberList` again and now finds itself
3. It returns the `ETCD_INITIAL_CLUSTER` string
4. Etcd starts on the new node with `--initial-cluster-state=existing`
5. The learner connects to the leader via port 2380 (peer port) and begins receiving the Raft log

### ETCD_MAX_LEARNERS

**File:** `pkg/etcdenvvar/etcd_env.go:379-406`

Set to the control-plane replica count (typically 3). This allows up to N learners during surge (e.g., during vertical scaling when all nodes are being replaced).

---

## Phase 5: Raft Log Replication — The Learner Catching Up

Once etcd starts on the new node as a learner, the Raft protocol handles data replication. This phase is managed entirely by etcd's internal Raft implementation — the operator does not directly participate.

### How Raft Log Replication Works

1. **The leader identifies the learner's log position.** The learner starts with an empty log (or a log from a previous snapshot, if one was transferred).

2. **The leader sends a snapshot if needed.** If the learner is too far behind (the leader has already compacted the log entries the learner needs), the leader sends a full **snapshot** of the current state. This is a point-in-time copy of the entire key-value store.

3. **The leader streams `MsgApp` (AppendEntries) RPCs** to the learner via port 2380. Each `MsgApp` contains:
   - The leader's term and leader ID
   - The log entries to replicate (each entry = a client write operation)
   - The leader's commit index (how far the cluster has committed)

4. **The learner applies entries to its local state machine** (the BoltDB/bbolt database). It replays log entries sequentially, reconstructing the current state.

5. **The learner tracks its progress** via two indexes:
   - **Applied index**: how many entries the learner has applied to its local store
   - The leader's **committed index**: how far the cluster has committed globally
   
   The gap between these two represents how far behind the learner is.

### What the Learner Cannot Do

During this phase, the learner:
- **Cannot vote** in leader elections
- **Does not count** toward quorum (adding a learner cannot reduce fault tolerance)
- **Cannot serve linearizable reads** (those require consensus, which the learner can't participate in)
- **Can serve serializable reads** (reads from local store, may be stale)

### Duration

Depends on:
- The size of the etcd database (typically 2-8 GB in production OpenShift clusters)
- Network bandwidth between leader and learner
- Write rate to the cluster during catch-up (new entries keep arriving)

For typical OpenShift clusters, this takes **seconds to minutes**. For very large clusters with high write rates, it could take longer.

---

## Phase 6: Learner Promotion — Becoming a Voting Member

**File:** `pkg/operator/clustermembercontroller/clustermembercontroller.go:264-316`

`ensureEtcdLearnerPromotion()` runs in the same `reconcileMembers()` sync loop, after the learner add attempt.

### Promotion Eligibility

`shouldPromote()` (line 320-362) checks:
- `member.IsLearner == true`
- If Machine API is functional: the learner's Machine must have the `EtcdQuorumOperator` PreDrain hook AND must not be pending deletion (prevents promoting a member on a node that's about to be removed)
- If Machine API is not functional (UPI/bare-metal clusters): always eligible for promotion

### The Promotion Call

```go
err = c.etcdClient.MemberPromote(ctx, member)
```

**File:** `pkg/etcdcli/etcdcli.go:192-217`

```go
func (g *etcdClientGetter) MemberPromote(ctx context.Context, member *etcdserverpb.Member) error {
    _, err = cli.MemberPromote(ctx, member.ID)
    return err
}
```

### Handling ErrLearnerNotReady

If the learner's log hasn't caught up to the leader's committed index, etcd returns `ErrLearnerNotReady`. The operator handles this gracefully (line 306-309):

```go
if err.Error() == errors.ErrLearnerNotReady.Error() {
    klog.V(2).Infof("Not ready for promotion: etcd learner member (%s) is not yet in sync with leader's log",
        member.PeerURLs[0])
    continue  // retry on next sync (every 1 minute)
}
```

The operator does **not** directly inspect Raft log indexes. It delegates the catch-up decision to etcd's server — etcd internally checks whether the learner's applied index is within an acceptable distance of the leader's committed index.

### What Happens in Raft When Promotion Succeeds

1. The leader verifies the learner's log is sufficiently caught up
2. The leader proposes a `ConfChange` entry to transition the member from learner to voter
3. The existing voting members reach consensus on this `ConfChange` (the learner does not vote on its own promotion)
4. Once committed, the member becomes a **full voting member**:
   - Can vote in leader elections
   - Counts toward quorum
   - Can serve linearizable reads
   - Can be elected as leader
5. **Quorum is recalculated**: for a 3-member cluster (2 voters + 1 learner → 3 voters), quorum remains 2, but the cluster regains its full fault tolerance (can lose 1 member and still have quorum)

---

## Phase 7: Removing the Old Member

**File:** `pkg/operator/clustermemberremovalcontroller/clustermemberremovalcontroller.go`

The ClusterMemberRemovalController's `sync()` (line 108) enforces **five top-level safety gates** before attempting any removal:

| Gate | Check | Why |
|---|---|---|
| Bootstrap complete | `IsBootstrapComplete()` (line 110) | Don't remove members during initial cluster formation |
| DualReplica/Pacemaker skip | `ShouldSkipMemberManagementForDualReplica()` (line 121) | Pacemaker manages membership in Two Node Fencing topology |
| Revision stable | `IsRevisionStable()` (line 145) | All nodes at `LatestAvailableRevision` — pods may appear temporarily unhealthy during rollout |
| Endpoints current | `isEtcdEndpointsUpdated()` (line 157) | Live membership matches `etcd-endpoints` ConfigMap — prevents removing multiple members before endpoints propagate |
| Machine API functional | (line 166) | Can verify machine states for IPI clusters |

**Note:** The quorum invariant check (`healthyVotingMembers >= MinimumTolerableQuorum`) is NOT a top-level gate — it is enforced inside `attemptToScaleDown()` (line 254). The `removeMemberWithoutMachine()` path does NOT check quorum explicitly, because by the time it runs, both the Machine and Node are already gone and there is no choice but to remove the stale member.

### Three Removal Paths

After all top-level gates pass, the controller attempts removal via three paths in order:

**Path A: Catastrophic node loss** — `removeMemberWithoutMachine()` (line 326)

For when both the Machine AND Node are gone (e.g., hardware failure, cloud VM disappeared). Iterates the `etcd-endpoints` ConfigMap, checks if each member's IP has a corresponding machine and node. If neither exists and the member is unhealthy, removes it. This is the most aggressive path — no quorum check, because the member is already unreachable.

**Path B: Learner cleanup** — `attemptToRemoveLearningMember()` (line 390)

Removes learner members whose machines are pending deletion. Since learners don't affect quorum, this path has fewer safety constraints.

**Path C: Controlled scale-down** — `attemptToScaleDown()` (line 188)

The main path for planned member replacement. This path has its own additional safety checks:

1. Gets desired control plane replica count
2. Only proceeds when `len(liveVotingMembers) > desiredControlPlaneReplicasCount` — the replacement has already joined as a voter, so the cluster has one member more than needed
3. **Quorum invariant** (line 254): verifies `healthyVotingMembers >= MinimumTolerableQuorum` before removing
4. Finds machines with deletion hooks that are pending deletion
5. **Sorts by failure domain** — prefers removing a member whose failure domain has duplicates, keeping etcd spread across availability zones (line 235-240)
6. Removes only **one member per sync cycle** (`break` at line 316)

### The Removal Call

```go
etcdClient.MemberRemove(ctx, member.ID)
```

**File:** `pkg/etcdcli/etcdcli.go:270-285`

A single etcd API call that removes the member from the cluster configuration.

### What Happens in Raft When a Member Is Removed

1. The leader proposes a `ConfChange` to remove the member
2. Once committed by the remaining quorum, the member is no longer part of the cluster
3. **If the removed member was the leader**: etcd triggers an immediate leader election
   - Remaining voters participate in the election
   - The member with the highest committed index is preferred
   - Election timeout: 1000ms (standard) or 2500ms (slower platforms like Azure)
   - Heartbeat interval: 100ms (standard) or 500ms (slower platforms)
4. The removed member's etcd process will discover it's no longer in the cluster and stop accepting requests

---

## Phase 8: Cleanup and Revision Rollout

After the old member is removed and the new member is a voter:

### Endpoint Update

**EtcdEndpointsController** (`pkg/operator/etcdendpointscontroller/etcdendpointscontroller.go:90-155`):

- Calls `etcdClient.MemberList(ctx)` to get live membership
- **Excludes learners** from the endpoint list (line 128-130) — learners reject linearizable requests, so the API server must not send traffic to them
- Excludes the `etcd-bootstrap` member
- Writes member IPs to the `etcd-endpoints` ConfigMap keyed by member ID hex

### Revision Rollout

The ConfigMap change triggers the revision rollout pipeline documented in [etcd-rollout-flow.md](./etcd-rollout-flow.md):

1. **TargetConfigController** renders a new `etcd-pod` ConfigMap with updated `ALL_ETCD_ENDPOINTS`
2. **RevisionController** detects the change, creates a new revision
3. **InstallerController** rolls out to all nodes one at a time

All etcd pods get updated with the new membership information.

### Machine Cleanup

**MachineDeletionHooksController** (line 112, `attemptToDeleteMachineDeletionHook()`):
- Checks if the old Machine's IP is still in the etcd member list
- If the member is gone → removes the `EtcdQuorumOperator` PreDrain hook

**Then** (line 174, `attemptToDeleteQuorumGuard()`):
- After the hook is removed, verifies the node is cordoned (`Unschedulable=true`) — if not yet cordoned, the guard pod would just be recreated
- Deletes the quorum guard pod to unblock the PDB
- Machine API can now drain remaining workloads and terminate the VM

---

## End-to-End Timeline

```
                        UNHEALTHY MEMBER DETECTED
                               │
 ┌─────────────────────────────┴──────────────────────────────┐
 │  EtcdMembersController (syncs every 1 min)                 │
 │  Linearized Get("health") fails for member on node-2       │
 │  (30s timeout per member, parallel checks)                 │
 │  → EtcdMembersDegraded=True, reason=UnhealthyMembers       │
 └────────────────────────────────────────────────────────────┘
                               │
                     MACHINE REPLACEMENT BEGINS
                               │
 ┌─────────────────────────────┴──────────────────────────────┐
 │  CPMS/Admin deletes Machine for node-2                     │
 │  Machine gets DeletionTimestamp                             │
 │  PreDrain hook "EtcdQuorumOperator" BLOCKS drain           │
 │  CPMS creates replacement Machine → node-3 boots           │
 └────────────────────────────────────────────────────────────┘
                               │
                     NEW NODE COMES UP
                               │
 ┌─────────────────────────────┴──────────────────────────────┐
 │  Kubelet on node-3 starts etcd static pod                  │
 │  discover-etcd-initial-cluster runs inside container        │
 │  Queries MemberList, doesn't find itself → waits           │
 │  Pod is Running but NOT Ready                              │
 └────────────────────────────────────────────────────────────┘
                               │
                     ADD AS LEARNER (Phase 4)
                               │
 ┌─────────────────────────────┴──────────────────────────────┐
 │  ClusterMemberController.reconcileMembers():               │
 │    ✓ All existing members healthy                          │
 │    ✓ node-3 has no voting member                           │
 │    ✓ Machine exists, has PreDrain hook, not deleting       │
 │    ✓ etcd container Running but Not Ready                  │
 │  → MemberAddAsLearner(https://node-3-ip:2380)             │
 │                                                            │
 │  Raft: leader adds ConfChange, begins streaming log        │
 │  discover-etcd-initial-cluster finds itself → returns      │
 │  etcd starts with --initial-cluster-state=existing         │
 └────────────────────────────────────────────────────────────┘
                               │
                     RAFT LOG REPLICATION (Phase 5)
                               │
 ┌─────────────────────────────┴──────────────────────────────┐
 │  Leader → Learner: MsgApp RPCs on port 2380 (peer port)    │
 │  Learner applies entries to local BoltDB                   │
 │  Learner does NOT vote, does NOT count toward quorum       │
 │  Duration: seconds to minutes (depends on data size)       │
 └────────────────────────────────────────────────────────────┘
                               │
                     PROMOTE TO VOTER (Phase 6)
                               │
 ┌─────────────────────────────┴──────────────────────────────┐
 │  ClusterMemberController.ensureEtcdLearnerPromotion():     │
 │  → MemberPromote(node-3-member)                            │
 │                                                            │
 │  If ErrLearnerNotReady: log not yet caught up              │
 │    → retry next sync (1 min interval)                      │
 │  If success:                                               │
 │    Raft: ConfChange committed (learner → voter)            │
 │    node-3 can now vote in elections                         │
 │    Quorum recalculated → full fault tolerance restored     │
 └────────────────────────────────────────────────────────────┘
                               │
                     REMOVE OLD MEMBER (Phase 7)
                               │
 ┌─────────────────────────────┴──────────────────────────────┐
 │  ClusterMemberRemovalController.attemptToScaleDown():      │
 │    ✓ Bootstrap complete                                    │
 │    ✓ Revision stable (no rollout in progress)              │
 │    ✓ Endpoints match ConfigMap                             │
 │    ✓ votingMembers (4) > desired (3)                       │
 │    ✓ healthyVoters >= quorum                               │
 │  → MemberRemove(node-2-member-ID)                          │
 │                                                            │
 │  If node-2 was leader: Raft election among remaining       │
 │  voters, member with highest committed index preferred     │
 └────────────────────────────────────────────────────────────┘
                               │
                     CLEANUP (Phase 8)
                               │
 ┌─────────────────────────────┴──────────────────────────────┐
 │  EtcdEndpointsController: updates etcd-endpoints ConfigMap │
 │    → adds node-3 IP, removes node-2 IP                    │
 │    → excludes learners from endpoints                      │
 │                                                            │
 │  Triggers revision rollout:                                │
 │    TargetConfigController → RevisionController →           │
 │    InstallerController (one node at a time)                │
 │                                                            │
 │  MachineDeletionHooksController:                           │
 │    node-2 IP not in membership                             │
 │    → removes PreDrain hook from old Machine                │
 │    → deletes quorum guard pod                              │
 │    → Machine API drains and deletes node-2                 │
 └────────────────────────────────────────────────────────────┘
```

---

## Raft Consensus Deep Dive

### The Raft Algorithm in Context

Etcd implements Raft for distributed consensus. Understanding Raft is essential to understanding why the operator makes specific safety decisions.

### Leader Election

- Every Raft cluster has exactly **one leader** at any time
- The leader sends **heartbeats** to followers at `ETCD_HEARTBEAT_INTERVAL` (100ms standard, 500ms on slower platforms)
- If a follower doesn't receive a heartbeat within `ETCD_ELECTION_TIMEOUT` (1000ms standard, 2500ms on slower platforms), it starts an election
- Elections use **randomized timeouts** to avoid split votes
- A candidate needs votes from a **majority** (quorum) to become leader
- The member with the most up-to-date log (highest term, then highest index) wins

Hardware-specific tuning is handled by `hwspeedhelpers` in the operator — slower platforms (Azure, certain disk types) get longer timeouts to avoid false elections.

### Log Replication

- All writes go through the leader
- The leader appends the entry to its log and sends `MsgApp` (AppendEntries) RPCs to all followers (and learners)
- Once a **majority** acknowledges the entry, it is **committed**
- The leader then applies the entry to its state machine and responds to the client
- Followers apply committed entries to their state machines in order

### The Learner Role

Introduced in etcd 3.4, the learner role solves a specific problem: when a new member joins, it has no data and needs time to catch up. During catch-up, if it counted as a voter, it would reduce the cluster's effective fault tolerance (the new member would always vote but its vote might be based on stale state).

As a learner:
- Receives `MsgApp` RPCs from the leader (gets all log entries)
- Applies entries to its local state machine
- Does **not** vote in elections
- Does **not** count toward quorum
- Cannot be elected as leader
- Cannot serve linearizable reads (only serializable/stale)

The cluster's quorum calculation excludes learners entirely. A 3-member cluster (2 voters + 1 learner) has quorum = 2, same as a 2-member cluster. The learner's presence doesn't weaken the cluster.

### Quorum Formula

```go
// pkg/etcdcli/health.go:326-331
func MinimumTolerableQuorum(members int) (int, error) {
    return (members / 2) + 1, nil
}
```

| Voting Members | Quorum | Fault Tolerance |
|---|---|---|
| 1 | 1 | 0 (any failure = outage) |
| 2 | 2 | 0 (any failure = outage) |
| 3 | 2 | 1 member can fail |
| 4 | 3 | 1 member can fail |
| 5 | 3 | 2 members can fail |

Note: 4-member clusters have the same fault tolerance as 3-member clusters. This is why the operator maintains exactly 3 (or the configured count) voting members and adds/removes members one at a time.

---

## Quorum Safety Invariants

The operator enforces several safety invariants to protect quorum:

### 1. Never Add Members to an Unhealthy Cluster

**File:** `pkg/operator/clustermembercontroller/clustermembercontroller.go:109-117`

If any existing member is unhealthy, `reconcileMembers()` returns without adding. Adding a voter to a degraded cluster could worsen the situation; adding a learner to a degraded cluster wastes resources when the priority should be fixing the existing member.

### 2. Quorum Precondition for Revisions

**File:** `pkg/operator/ceohelpers/quorum_check.go:35`

`QuorumCheck.IsSafeToUpdateRevision()` calls `CheckSafeToScaleCluster()` (`pkg/operator/ceohelpers/bootstrap.go:137`), which verifies:

1. **Revision stability check** (line 143): If a revision rollout is already in progress (`IsRevisionStable()` returns false), scaling is considered safe — returns nil immediately. This is because the cluster has already committed to the change during the current rollout.
2. Checks the scaling strategy for the topology:
   - `HAScalingStrategy` / `DelayedHAScalingStrategy` → requires 3 healthy members
   - `TwoNodeScalingStrategy` / `DelayedTwoNodeScalingStrategy` → requires 2 (fault tolerance check is bypassed for 2-member TNF clusters since Pacemaker manages etcd)
   - `UnsafeScalingStrategy` (single-node) → always safe
3. Verifies `healthyMembers >= minimum`
4. Verifies **fault tolerance** via `IsQuorumFaultTolerant()` (line 188), which checks **two** conditions:
   - **Structural**: `totalMembers - quorum >= 1` — even if all members are healthy, the cluster must have enough members structurally to tolerate a loss
   - **Health-based**: `healthyMembers - quorum >= 1` — enough healthy members that losing one still maintains quorum
   
   Both must pass. The structural check catches cases like a 2-member cluster where `quorum = 2` — even if both are healthy, losing one breaks quorum.

### 3. One Member Change at a Time

Both `ClusterMemberController` (addition) and `ClusterMemberRemovalController` (removal) process only one member per sync cycle. This is a Raft best practice — multiple simultaneous membership changes can cause split-brain scenarios in certain edge cases.

### 4. Revision Must Be Stable Before Removal

`IsRevisionStable()` (`pkg/operator/ceohelpers/bootstrap.go:221`) verifies all nodes are at `LatestAvailableRevision`. During a rollout, pods may appear temporarily unhealthy (they're restarting). Removing a member during a rollout could combine a planned restart with an unplanned removal, exceeding fault tolerance.

**Note:** This gate is used differently by different controllers. The `ClusterMemberRemovalController` requires a stable revision before removing members. But `CheckSafeToScaleCluster()` (used for revision preconditions) treats an *unstable* revision as safe — because if a rollout is already in progress, the cluster has already committed to the change.

### 5. Membership > Desired Before Scale-Down

`attemptToScaleDown()` only removes a member when `len(liveVotingMembers) > desiredControlPlaneReplicasCount`. This means the replacement must have already joined as a voter. The cluster transiently has 4 members (2-of-4 quorum, can lose 1) before going back to 3 (2-of-3 quorum, can lose 1). At no point does fault tolerance drop below 1.

---

## Defragmentation During Recovery

**File:** `pkg/operator/defragcontroller/defragcontroller.go`

Defragmentation is a maintenance operation, not part of the recovery path itself, but it interacts with recovery by maintaining cluster health.

### When Defrag Runs

The DefragController syncs periodically (every ~11 minutes: `compactionInterval + 1min`). It defrags a member when:
- Fragmentation ≥ 45% (`maxFragmentedPercentage`)
- Database size ≥ 100MB (`minDefragBytes`)

### Defrag Order

1. Most fragmented member first
2. **Leader is always defragged last** — to avoid unnecessary leadership churn

### Leader Movement

If the defrag target is the current leader (line 235-258):
1. Picks the **least-fragmented follower** as the new leader
2. Issues a `MoveLeader` RPC to explicitly transfer leadership
3. Waits `defragSettleTime` (10 seconds) for the cluster to stabilize — implemented by re-queuing the sync via `syncCtx.Queue().AddAfter()` rather than blocking with `time.Sleep`
4. Defrags the now-follower member

The `MoveLeader` RPC (`pkg/etcdcli/etcdcli.go:253-267`) must be sent directly to the current leader:
```go
func (g *etcdClientGetter) MoveLeader(ctx context.Context, member *etcdserverpb.Member, lead uint64) error {
    // Creates a direct client to the leader
    cfg.Endpoints = member.ClientURLs
    cli, err := clientv3.New(cfg)
    _, err = cli.MoveLeader(ctx, lead)
}
```

### Defrag and Recovery Interaction

- Learner and unstarted members are **skipped** during defrag (line 168-170)
- After `maxDefragFailuresBeforeDegrade` (3) consecutive failures, the controller sets `DefragControllerDegraded`
- Defrag temporarily makes a member unavailable — the operator accounts for this by defragging one member at a time and checking cluster health between iterations

---

## Full Cluster Restore (Total Loss)

When ALL etcd members are lost (e.g., all control plane nodes failed simultaneously), the single-member replacement flow above does not apply. The operator provides a **full cluster restore** mechanism from a backup.

### Backup — What Gets Saved

**File:** `pkg/cmd/backuprestore/backuputils.go`

The `cluster-backup` subcommand saves:

1. **Etcd snapshot** — a point-in-time copy of the entire key-value store, taken via etcd's snapshot API
2. **Static pod resources** — tarballs of the latest revision directories for:
   - `kube-apiserver-pod`
   - `kube-controller-manager-pod`
   - `kube-scheduler-pod`
   - `etcd-pod`
   
   From `/etc/kubernetes/static-pod-resources/`

### Periodic Automated Backups

**File:** `pkg/operator/periodicbackupcontroller/periodicbackupcontroller.go`

Uses the `Backup` CRD (`v1alpha1`) to schedule automated backups as Kubernetes Jobs.

### Restore — Rebuilding from Scratch

**File:** `pkg/cmd/backuprestore/restoreutils.go`

The `cluster-restore` subcommand runs **on a control plane node** and:

1. **Stops all static pods**: Moves `etcd-pod.yaml`, `kube-apiserver-pod.yaml`, `kube-controller-manager-pod.yaml`, `kube-scheduler-pod.yaml` from `/etc/kubernetes/manifests/` to `/etc/kubernetes/assets/manifests-stopped/`. The kubelet detects the removal and terminates the pods.

2. **Waits for static pods to stop**: Polls CRI-O via the container runtime API until all static pod containers are fully terminated.

3. **Backs up existing etcd data**: Renames `/var/lib/etcd/member` → `/var/lib/etcd-backup/member`. This preserves the (potentially corrupted) data for forensic analysis.

4. **Restores static pod resources**: Extracts the tarball back to `/etc/kubernetes/static-pod-resources/`.

5. **Writes the restore pod manifest**: Copies `restore-etcd-pod/pod.yaml` to `/etc/kubernetes/manifests/etcd-pod.yaml`. This is a **special recovery pod** — not the normal etcd pod. It runs `etcdctl snapshot restore` to:
   - Rebuild the etcd data directory from the snapshot
   - Bootstrap a **single-member cluster** from the restored data
   - Configure the member with the correct name and peer URLs

6. **Restores remaining control plane pods**: Extracts API server, controller manager, and scheduler manifests back to `/etc/kubernetes/manifests/`.

### After Restore

The cluster is running with a **single etcd member** bootstrapped from the snapshot. The data reflects the state at the time the backup was taken — any writes after the backup are lost.

To rebuild a full 3-member cluster:
1. The other control plane nodes boot and their etcd pods enter the "Running but Not Ready" state
2. The `ClusterMemberController` adds them as learners one at a time
3. They catch up via Raft log replication
4. They are promoted to voters
5. The cluster regains full fault tolerance

This follows the same learner flow documented in Phases 4-6 above.

---

## Failure Handling

### Member Add Fails

If `MemberAddAsLearner` fails (e.g., etcd cluster is unhealthy, network issue):
- The controller logs the error and returns
- The `discover-etcd-initial-cluster` process on the new node continues waiting
- The controller retries on the next sync (1 minute)

### Learner Promotion Returns ErrLearnerNotReady

The learner hasn't caught up with the leader's log:
- The controller logs at V(2) and continues to the next learner
- Retries every sync cycle (1 minute)
- No backoff — promotion attempts are cheap (a single RPC)

### Member Remove Fails

If `MemberRemove` fails:
- The controller returns the error
- The PreDrain hook remains in place, blocking Machine API from deleting the old node
- Retries on the next sync

### Catastrophic Node Loss (No Machine, No Node)

`removeMemberWithoutMachine()` handles this case:
- The member is unhealthy and both its Machine and Node objects are gone
- The controller removes the member directly, without waiting for Machine API coordination
- This is the most aggressive removal path, used only when there's no infrastructure to coordinate with

### Quorum Guard Pod

The quorum guard is a static pod that enforces a `PodDisruptionBudget` on etcd members. It prevents `oc adm drain` from evicting etcd pods when doing so would break quorum. The `MachineDeletionHooksController` deletes the quorum guard pod only after the etcd member has been safely removed from the cluster.

---

## Key Code References

### Health Monitoring

| Component | File | Key Function |
|---|---|---|
| Health check entry point | `pkg/etcdcli/health.go:44` | `GetMemberHealth()` |
| Single member health check | `pkg/etcdcli/health.go:96` | `checkSingleMemberHealth()` — linearizable for voters, serializable for learners |
| Quorum calculation | `pkg/etcdcli/health.go:326` | `MinimumTolerableQuorum()` — `(members/2) + 1` |
| Fault tolerance check | `pkg/etcdcli/health.go:226` | `IsQuorumFaultTolerant()` |
| Raft term tracking | `pkg/etcdcli/health.go:21-33` | `raftTermsCollector` Prometheus metric |
| Member status categories | `pkg/etcdcli/interfaces.go:10-14` | `Available`, `NotStarted`, `Unhealthy`, `Unknown` |
| EtcdMembers health reporting | `pkg/operator/etcdmemberscontroller/etcdmemberscontroller.go:80` | `reportEtcdMembers()` |

### Etcd Client Operations

| Component | File | Key Function |
|---|---|---|
| MemberAddAsLearner | `pkg/etcdcli/etcdcli.go:158` | Adds member as non-voting learner |
| MemberPromote | `pkg/etcdcli/etcdcli.go:192` | Promotes learner to voter, handles `ErrLearnerNotReady` |
| MemberRemove | `pkg/etcdcli/etcdcli.go:270` | Removes member from cluster configuration |
| MemberUpdatePeerURL | `pkg/etcdcli/etcdcli.go:219` | Updates a member's peer URLs |
| MoveLeader | `pkg/etcdcli/etcdcli.go:253` | Transfers leadership — direct client to current leader |
| Defragment | `pkg/etcdcli/etcdcli.go:489` | Defrags a member — fresh client with 60s dial timeout |

### Member Lifecycle Controllers

| Component | File | Key Function |
|---|---|---|
| Add learner | `pkg/operator/clustermembercontroller/clustermembercontroller.go:108` | `reconcileMembers()` |
| Find node to add | `pkg/operator/clustermembercontroller/clustermembercontroller.go:154` | `getEtcdPeerURLToAdd()` |
| Running-not-ready check | `pkg/operator/clustermembercontroller/clustermembercontroller.go:365` | `isEtcdContainerRunningNotReady()` |
| Promote learner | `pkg/operator/clustermembercontroller/clustermembercontroller.go:264` | `ensureEtcdLearnerPromotion()` |
| Promotion eligibility | `pkg/operator/clustermembercontroller/clustermembercontroller.go:320` | `shouldPromote()` |
| Removal main loop | `pkg/operator/clustermemberremovalcontroller/clustermemberremovalcontroller.go:108` | `sync()` |
| Remove without machine | `pkg/operator/clustermemberremovalcontroller/clustermemberremovalcontroller.go:326` | `removeMemberWithoutMachine()` |
| Scale down with quorum protection | `pkg/operator/clustermemberremovalcontroller/clustermemberremovalcontroller.go:188` | `attemptToScaleDown()` |
| Remove learner | `pkg/operator/clustermemberremovalcontroller/clustermemberremovalcontroller.go:390` | `attemptToRemoveLearningMember()` |

### Machine API Integration

| Component | File | Key Function |
|---|---|---|
| Add PreDrain hook | `pkg/operator/machinedeletionhooks/machinedeletionhooks.go:236` | `addDeletionHookToMasterMachines()` |
| Remove hook after member gone | `pkg/operator/machinedeletionhooks/machinedeletionhooks.go:112` | `attemptToDeleteMachineDeletionHook()` |
| Remove quorum guard | `pkg/operator/machinedeletionhooks/machinedeletionhooks.go:174` | `attemptToDeleteQuorumGuard()` |
| Hook name/owner constants | `pkg/operator/ceohelpers/common.go:28-32` | `MachineDeletionHookName`, `MachineDeletionHookOwner` |

### Quorum and Safety

| Component | File | Key Function |
|---|---|---|
| Quorum safety for revisions | `pkg/operator/ceohelpers/quorum_check.go:35` | `QuorumCheck.IsSafeToUpdateRevision()` |
| Scaling safety invariants | `pkg/operator/ceohelpers/bootstrap.go:137` | `CheckSafeToScaleCluster()` |
| Revision stability check | `pkg/operator/ceohelpers/bootstrap.go:220` | `IsRevisionStable()` |

### Environment and Configuration

| Component | File | Key Function |
|---|---|---|
| INITIAL_CLUSTER_STATE=existing | `pkg/etcdenvvar/etcd_env.go:51` | `FixedEtcdEnvVars` |
| ALL_ETCD_ENDPOINTS env var | `pkg/etcdenvvar/etcd_env.go:141` | `getAllEtcdEndpoints()` |
| ETCD_MAX_LEARNERS | `pkg/etcdenvvar/etcd_env.go:379` | Set to control-plane replica count |
| Endpoints ConfigMap (voters only) | `pkg/operator/etcdendpointscontroller/etcdendpointscontroller.go:124-130` | Excludes learners |
| Etcd pod template | `bindata/etcd/pod.gotpl.yaml:147` | `discover-etcd-initial-cluster` invocation |

### Defragmentation

| Component | File | Key Function |
|---|---|---|
| Defrag controller | `pkg/operator/defragcontroller/defragcontroller.go` | Rolling defrag, leader last |
| Fragmentation threshold | `pkg/operator/defragcontroller/defragcontroller.go` | 45% fragmentation, 100MB min |
| Leader movement before defrag | `pkg/operator/defragcontroller/defragcontroller.go:235` | `MoveLeader` to least-fragmented follower |

### Backup and Restore

| Component | File | Key Function |
|---|---|---|
| Backup utilities | `pkg/cmd/backuprestore/backuputils.go` | Snapshot + static pod resource tarball |
| Restore utilities | `pkg/cmd/backuprestore/restoreutils.go` | Stop pods → restore snapshot → bootstrap single member |
| Periodic backup controller | `pkg/operator/periodicbackupcontroller/periodicbackupcontroller.go` | `Backup` CRD-driven automated backups |
