# etcd Operator Deep Dive - Complete Understanding

**Author:** Technical Analysis  
**Date:** 2026-05-29  
**Repository:** cluster-etcd-operator  

---

## Table of Contents

1. [Overview](#overview)
2. [Architecture](#architecture)
3. [Member Addition Flow](#member-addition-flow)
4. [Member Removal Flow](#member-removal-flow)
5. [Code Deep Dive](#code-deep-dive)
6. [gRPC API Details](#grpc-api-details)
7. [Ports and Endpoints](#ports-and-endpoints)
8. [Debugging Guide](#debugging-guide)
9. [Manual Operations](#manual-operations)

---

## Overview

The **cluster-etcd-operator** (CEO) manages the etcd cluster lifecycle in OpenShift. It does NOT handle storing Kubernetes objects in etcd (that's the API server's job). Instead, it:

- ✅ Manages etcd cluster membership (add/remove members)
- ✅ Handles TLS certificates for etcd
- ✅ Manages scaling during cluster operations
- ✅ Performs automatic defragmentation
- ✅ Maintains quorum safety

### What the Operator Does NOT Do

- ❌ Intercept object creation/deletion
- ❌ Directly write Kubernetes objects to etcd
- ❌ Handle etcdctl commands from admins (those go directly to etcd)

---

## Architecture

### Component Stack

```
┌─────────────────────────────────────────────────────────┐
│              Admin / Machine API                         │
│         (Creates/Deletes Machines/Nodes)                │
└────────────────────┬────────────────────────────────────┘
                     ↓
┌─────────────────────────────────────────────────────────┐
│         Cluster Etcd Operator (CEO)                     │
│         Namespace: openshift-etcd-operator              │
│                                                          │
│  Controllers:                                           │
│  • ClusterMemberController (Addition)                   │
│  • ClusterMemberRemovalController (Deletion)            │
│  • DefragController (Defragmentation)                   │
│  • EtcdEndpointsController (ConfigMap sync)             │
│  • EtcdMembersController (Status reporting)             │
└────────────────────┬────────────────────────────────────┘
                     ↓
┌─────────────────────────────────────────────────────────┐
│              etcdcli Package                            │
│     (Go wrapper around etcd client library)             │
│                                                          │
│  Methods:                                               │
│  • MemberAddAsLearner(peerURL)                         │
│  • MemberPromote(memberID)                             │
│  • MemberRemove(memberID)                              │
│  • Status(endpoint)                                     │
│  • MemberList()                                         │
└────────────────────┬────────────────────────────────────┘
                     ↓
┌─────────────────────────────────────────────────────────┐
│         etcd Go Client Library (clientv3)               │
│         Package: go.etcd.io/etcd/client/v3              │
└────────────────────┬────────────────────────────────────┘
                     ↓ (gRPC over TLS)
┌─────────────────────────────────────────────────────────┐
│              etcd Server (Raft)                         │
│         Namespace: openshift-etcd                       │
│                                                          │
│  Pods:                                                  │
│  • etcd-ip-10-0-47-131 (Member 1)                      │
│  • etcd-ip-10-0-66-147 (Member 2)                      │
│  • etcd-ip-10-0-7-132  (Member 3)                      │
│                                                          │
│  Ports:                                                 │
│  • 2379 - Client API (gRPC)                            │
│  • 2380 - Peer API (Raft)                              │
│  • 9979 - Metrics                                       │
└─────────────────────────────────────────────────────────┘
```

---

## Member Addition Flow

### Trigger

A new control plane node is created (via Machine API or manual addition).

### Complete Flow

```
┌─────────────────────────────────────────────────────────┐
│ Step 1: New Machine/Node Created                       │
└────────────────────┬────────────────────────────────────┘
                     ↓
         Machine API creates machine
         Node joins cluster
         etcd pod starts (Running, NOT Ready)
                     ↓
┌─────────────────────────────────────────────────────────┐
│ Step 2: ClusterMemberController Detects New Node       │
│ File: pkg/operator/clustermembercontroller/            │
│       clustermembercontroller.go                        │
└────────────────────┬────────────────────────────────────┘
                     ↓
┌──────────────────────────────────────────────────────────┐
│ Function: reconcileMembers (Line 108-150)               │
│                                                          │
│ 1. Check unhealthy members                              │
│    unhealthyMembers, err := c.etcdClient.UnhealthyMembers()│
│    if len(unhealthyMembers) > 0:                        │
│        return nil  // Don't add if cluster unhealthy    │
│                                                          │
│ 2. Find peer to add                                     │
│    peerURL, err := c.getEtcdPeerURLToAdd(ctx)          │
│    // Returns: https://10.0.7.132:2380                  │
│                                                          │
│ 3. Add as LEARNER (non-voting)                         │
│    err = c.etcdClient.MemberAddAsLearner(ctx, peerURL) │
│                                                          │
│ 4. Promote learner to voting                            │
│    err := c.ensureEtcdLearnerPromotion(ctx, recorder)  │
└──────────────────────────────────────────────────────────┘
                     ↓
┌──────────────────────────────────────────────────────────┐
│ Function: getEtcdPeerURLToAdd (Line 154-262)            │
│                                                          │
│ Checks:                                                  │
│ 1. Node not pending deletion                            │
│ 2. Machine has PreDrain deletion hook                   │
│ 3. etcd pod is "running but not ready"                  │
│ 4. PeerURL not already in cluster                       │
│                                                          │
│ Returns: peerURL = "https://10.0.7.132:2380"           │
└──────────────────────────────────────────────────────────┘
                     ↓
┌──────────────────────────────────────────────────────────┐
│ Step 3: Add Member as Learner                           │
│ File: pkg/etcdcli/etcdcli.go:158-190                   │
│                                                          │
│ func MemberAddAsLearner(ctx, peerURL) error {           │
│     cli, _ := g.clientPool.Get()                        │
│     defer g.clientPool.Return(cli)                      │
│                                                          │
│     // Check if already exists                          │
│     membersResp, _ := cli.MemberList(ctx)              │
│     for _, member := range membersResp.Members {        │
│         if slices.Contains(member.PeerURLs, peerURL) {  │
│             return nil  // Already added                │
│         }                                                │
│     }                                                    │
│                                                          │
│     // Add as learner (non-voting)                      │
│     _, err = cli.MemberAddAsLearner(ctx, []string{peerURL})│
│     // ↓ gRPC: /etcdserverpb.Cluster/MemberAdd         │
│     // ↓ Request: {peerURLs: [peerURL], isLearner: true}│
│     return err                                           │
│ }                                                        │
└──────────────────────────────────────────────────────────┘
                     ↓
┌──────────────────────────────────────────────────────────┐
│ Step 4: Wait for Learner to Sync                        │
│                                                          │
│ Learner replicates leader's log                         │
│ Status: IsLearner = true                                │
│ Waiting for: Log to catch up with leader                │
└──────────────────────────────────────────────────────────┘
                     ↓
┌──────────────────────────────────────────────────────────┐
│ Step 5: Promote Learner to Voting Member                │
│ File: pkg/operator/clustermembercontroller/             │
│       clustermembercontroller.go:266-316                │
│                                                          │
│ func ensureEtcdLearnerPromotion(ctx, recorder) error {  │
│     members, _ := c.etcdClient.MemberList(ctx)         │
│                                                          │
│     for _, member := range members {                    │
│         if !member.IsLearner {                          │
│             continue  // Only promote learners          │
│         }                                                │
│                                                          │
│         promote, _ := c.shouldPromote(member)          │
│         if !promote {                                   │
│             continue                                     │
│         }                                                │
│                                                          │
│         err = c.etcdClient.MemberPromote(ctx, member)  │
│         // ↓ gRPC: /etcdserverpb.Cluster/MemberPromote │
│         // ↓ Request: {ID: member.ID}                   │
│                                                          │
│         if err == ErrLearnerNotReady {                  │
│             // Learner hasn't synced yet, try later     │
│             continue                                     │
│         }                                                │
│     }                                                    │
│     return nil                                           │
│ }                                                        │
└──────────────────────────────────────────────────────────┘
                     ↓
┌──────────────────────────────────────────────────────────┐
│ Result: New Voting Member Added                         │
│                                                          │
│ Before: 3 voting members                                │
│ After:  4 voting members (temporarily during replacement)│
└──────────────────────────────────────────────────────────┘
```

### Key Safety Checks

1. **Unhealthy cluster** → Don't add new members
2. **Machine pending deletion** → Don't add
3. **No PreDrain hook** → Wait for hook
4. **Pod not running** → Wait for pod
5. **Learner not synced** → Wait before promoting

---

## Member Removal Flow

### Trigger

A control plane machine is deleted (manual or ControlPlaneMachineSet).

### Complete Flow

```
┌─────────────────────────────────────────────────────────┐
│ Step 1: Machine Gets DeletionTimestamp                 │
└────────────────────┬────────────────────────────────────┘
                     ↓
         Machine deletion initiated
         DeletionTimestamp set
         PreDrain hook BLOCKS actual deletion
                     ↓
┌─────────────────────────────────────────────────────────┐
│ Step 2: ClusterMemberRemovalController Sync            │
│ File: pkg/operator/clustermemberremovalcontroller/     │
│       clustermemberremovalcontroller.go:108-184         │
└────────────────────┬────────────────────────────────────┘
                     ↓
┌──────────────────────────────────────────────────────────┐
│ Function: sync (Entry Point)                             │
│                                                          │
│ Pre-checks (all must pass):                             │
│ 1. Bootstrap complete?                                   │
│    if !bootstrapComplete: return nil                     │
│                                                          │
│ 2. Revision stable? (not upgrading)                     │
│    if !revisionStable: return nil                       │
│                                                          │
│ 3. etcd-endpoints ConfigMap updated?                    │
│    if !etcdEndpointsUpdated: return nil                 │
│                                                          │
│ 4. Machine API functional?                              │
│    if !isFunctional: return nil                         │
│                                                          │
│ Removal attempts (in order):                            │
│ 1. removeMemberWithoutMachine()    // Orphaned members  │
│ 2. attemptToRemoveLearningMember() // Learners          │
│ 3. attemptToScaleDown()            // Voting members    │
└──────────────────────────────────────────────────────────┘
                     ↓
┌──────────────────────────────────────────────────────────┐
│ Step 3: attemptToScaleDown (Line 188-323)               │
│                                                          │
│ A. Get current state                                     │
│    desiredReplicas = 3                                   │
│    liveVotingMembers = [member1, member2, member3]      │
│                                                          │
│ B. Check if members < desired                           │
│    if len(liveVotingMembers) < desiredReplicas:        │
│        return nil  // Don't remove                      │
│                                                          │
│ C. Find machines pending deletion                       │
│    machinesPendingDeletion = [machine-0]                │
│    if len(machinesPendingDeletion) == 0:               │
│        return nil  // Nothing to remove                 │
│                                                          │
│ D. Get healthy members                                   │
│    healthyMembers = [member1, member2, member3]         │
│    minQuorum = (3/2)+1 = 2                              │
│                                                          │
│ E. Quorum check                                          │
│    if len(healthyMembers) < minQuorum:                  │
│        return nil  // Would lose quorum!                │
│                                                          │
│ F. ⭐ CRITICAL DECISION POINT ⭐                         │
│    allHealthy = (liveMembers == healthyMembers)         │
│    notExceeded = (len(healthyMembers) <= desired)       │
│                                                          │
│    if allHealthy && notExceeded:                        │
│        // ALL 3 members healthy AND size = 3            │
│        klog.Infof("skip scale down: waiting for         │
│                    replacement to be added")             │
│        return nil  ← EXIT HERE (WAIT FOR 4TH MEMBER)    │
│                                                          │
│    // If we reach here: 4th member was added!          │
│    // Now: 4 healthy members, desired = 3               │
│    // Proceed with removal...                           │
│                                                          │
│ G. Remove ONE member                                     │
│    for _, machine := range machinesPendingDeletion {    │
│        removed, _ := attemptToRemoveMemberFor(...)     │
│        if removed:                                       │
│            break  // Only remove ONE at a time          │
│    }                                                     │
└──────────────────────────────────────────────────────────┘
                     ↓
┌──────────────────────────────────────────────────────────┐
│ Step 4: attemptToRemoveMemberFor (Line 534-555)         │
│                                                          │
│ func attemptToRemoveMemberFor(ctx, members,              │
│                               machinePendingDeletion,    │
│                               recorder) (bool, []error) {│
│                                                          │
│     // Find member matching the machine's IP            │
│     for _, member := range members {                    │
│         memberIP, _ := MemberToNodeInternalIP(member)  │
│                                                          │
│         if hasInternalIP(machinePendingDeletion, memberIP) {│
│             // Found the match!                         │
│             memberLocator := fmt.Sprintf(               │
│                 "[ url: %v, name: %v, id: %v ]",       │
│                 memberIP, member.Name, member.ID)       │
│                                                          │
│             // ⭐ REMOVE FROM ETCD CLUSTER ⭐           │
│             err := c.etcdClient.MemberRemove(ctx, member.ID)│
│             // ↓                                         │
│             // ↓ Calls: pkg/etcdcli/etcdcli.go:249-264 │
│             // ↓                                         │
│                                                          │
│             if err != nil {                             │
│                 return false, []error{err}              │
│             }                                            │
│                                                          │
│             recorder.Eventf("ScaleDown",                │
│                 "successfully removed member: %v", ...)  │
│             return true, nil  // SUCCESS!               │
│         }                                                │
│     }                                                    │
│     return false, nil  // No match found                │
│ }                                                        │
└──────────────────────────────────────────────────────────┘
                     ↓
┌──────────────────────────────────────────────────────────┐
│ Step 5: MemberRemove Implementation                     │
│ File: pkg/etcdcli/etcdcli.go:249-264                   │
│                                                          │
│ func MemberRemove(ctx, memberID) error {                │
│     // Get client from pool                             │
│     cli, _ := g.clientPool.Get()                        │
│     defer g.clientPool.Return(cli)                      │
│                                                          │
│     // Set 30-second timeout                            │
│     ctx, cancel := context.WithTimeout(ctx, 30*time.Second)│
│     defer cancel()                                       │
│                                                          │
│     // Call etcd client library                         │
│     _, err = cli.MemberRemove(ctx, memberID)           │
│     // ↓                                                 │
│     // ↓ clientv3 library (go.etcd.io/etcd/client/v3)  │
│     // ↓ Creates gRPC request                           │
│     // ↓                                                 │
│                                                          │
│     if err == nil {                                     │
│         g.eventRecorder.Eventf("MemberRemove",          │
│             "removed member with ID: [%x]", memberID)   │
│     }                                                    │
│     return err                                           │
│ }                                                        │
└──────────────────────────────────────────────────────────┘
                     ↓
┌──────────────────────────────────────────────────────────┐
│ Step 6: gRPC Request to etcd Server                     │
│                                                          │
│ gRPC Method: /etcdserverpb.Cluster/MemberRemove         │
│ Request Body (protobuf):                                │
│   {                                                      │
│     "ID": 14006264466728655126  // 0xc2603f52f9899916  │
│   }                                                      │
│                                                          │
│ Connection Details:                                      │
│ • Endpoint: https://10.0.47.131:2379                    │
│ • Protocol: gRPC over TLS (HTTP/2)                      │
│ • Auth: mTLS (client certificates)                      │
│   - Cert: /var/run/secrets/etcd-client/tls.crt         │
│   - Key:  /var/run/secrets/etcd-client/tls.key         │
│   - CA:   /var/run/configmaps/etcd-ca/ca-bundle.crt    │
└──────────────────────────────────────────────────────────┘
                     ↓
┌──────────────────────────────────────────────────────────┐
│ Step 7: etcd Server Processing                          │
│                                                          │
│ 1. Validates mTLS certificate                           │
│ 2. Decodes protobuf request                             │
│ 3. Creates Raft proposal: "remove member ID=..."       │
│ 4. Leader sends to followers                            │
│ 5. Waits for quorum (2/3) to acknowledge                │
│ 6. Commits the change                                    │
│ 7. Updates cluster membership                           │
│ 8. Responds with success                                 │
│                                                          │
│ Response (protobuf):                                     │
│   {                                                      │
│     "header": {                                          │
│       "cluster_id": ...,                                 │
│       "member_id": ...,                                  │
│       "revision": ...                                    │
│     },                                                   │
│     "members": [                                         │
│       // Remaining 3 members                            │
│     ]                                                    │
│   }                                                      │
└──────────────────────────────────────────────────────────┘
                     ↓
┌──────────────────────────────────────────────────────────┐
│ Result: Member Removed from etcd Cluster                │
│                                                          │
│ Before: 4 members                                        │
│ After:  3 members                                        │
│                                                          │
│ The removed member is NO LONGER:                        │
│ • In Raft cluster configuration                         │
│ • Participating in leader elections                     │
│ • Part of quorum calculations                           │
│ • Receiving log replication                             │
└──────────────────────────────────────────────────────────┘
```

### The "Add Before Remove" Pattern

**Key Insight:** The operator implements safe replacement:

```
Initial state:  [Member1, Member2, Member3]  (3 members)
                                ↓
Machine-0 deleted, Machine-4 created
                                ↓
Add Member4:    [Member1, Member2, Member3, Member4]  (4 members)
                                ↓
Check: All healthy? Yes. Count > desired? Yes (4 > 3)
                                ↓
Remove Member1: [Member2, Member3, Member4]  (3 members)
```

**Why?** To maintain quorum throughout the replacement process!

---

## Code Deep Dive

### File: clustermemberremovalcontroller.go

#### Location of "skip scale down" Log

**File:** `pkg/operator/clustermemberremovalcontroller/clustermemberremovalcontroller.go`  
**Line:** 300-302

```go
if membersEqual(liveVotingMembers, healthyLiveVotingMembers) && 
   len(healthyLiveVotingMembers) <= desiredControlPlaneReplicasCount {
    klog.V(2).Infof("skip scale down: all voting, non-bootstrap members are healthy and membership does not exceed the desired cluster size of %v", desiredControlPlaneReplicasCount)
    return nil
}
```

#### Breakdown of the Condition

```go
// Part 1: All members are healthy
allHealthy := membersEqual(liveVotingMembers, healthyLiveVotingMembers)
// Compares by member IDs
// liveVotingMembers:    [ID1, ID2, ID3]
// healthyLiveVotingMembers: [ID1, ID2, ID3]
// Result: true (all 3 members are healthy)

// Part 2: Membership at or below desired size
notExceeded := len(healthyLiveVotingMembers) <= desiredControlPlaneReplicasCount
// len(healthyLiveVotingMembers): 3
// desiredControlPlaneReplicasCount: 3
// Result: true (3 <= 3)

// Final decision
if allHealthy && notExceeded {
    // Both conditions true → SKIP removal
    // Wait for replacement to be added first
    return nil
}
```

### Function Call Chain for MemberRemove

```
clustermemberremovalcontroller.go:544
    c.etcdClient.MemberRemove(ctx, member.ID)
        ↓
pkg/etcdcli/etcdcli.go:249
    func (g *etcdClientGetter) MemberRemove(ctx, memberID) error
        ↓
pkg/etcdcli/etcdcli.go:259
    _, err = cli.MemberRemove(ctx, memberID)
        ↓
clientv3.Client.MemberRemove() [etcd Go client library]
    // Package: go.etcd.io/etcd/client/v3
        ↓
gRPC Request Construction
    Method: POST /etcdserverpb.Cluster/MemberRemove
    Body: MemberRemoveRequest{ID: memberID}
        ↓
TLS Connection to etcd (port 2379)
        ↓
etcd Server Raft Consensus
        ↓
Member Removed
```

---

## gRPC API Details

### etcd gRPC Services

etcd exposes multiple gRPC services on port **2379**:

```protobuf
// Cluster service - Member management
service Cluster {
  rpc MemberAdd(MemberAddRequest) returns (MemberAddResponse);
  rpc MemberRemove(MemberRemoveRequest) returns (MemberRemoveResponse);
  rpc MemberUpdate(MemberUpdateRequest) returns (MemberUpdateResponse);
  rpc MemberList(MemberListRequest) returns (MemberListResponse);
  rpc MemberPromote(MemberPromoteRequest) returns (MemberPromoteResponse);
}

// Maintenance service - Status, defrag, snapshot
service Maintenance {
  rpc Status(StatusRequest) returns (StatusResponse);
  rpc Defragment(DefragmentRequest) returns (DefragmentResponse);
  rpc Snapshot(SnapshotRequest) returns (stream SnapshotResponse);
  rpc Hash(HashRequest) returns (HashResponse);
}

// KV service - Key-value operations (used by API server, not operator)
service KV {
  rpc Range(RangeRequest) returns (RangeResponse);
  rpc Put(PutRequest) returns (PutResponse);
  rpc DeleteRange(DeleteRangeRequest) returns (DeleteRangeResponse);
  rpc Txn(TxnRequest) returns (TxnResponse);
  rpc Compact(CompactionRequest) returns (CompactionResponse);
}
```

### MemberRemove gRPC Details

**Method:** `/etcdserverpb.Cluster/MemberRemove`

**Request:**
```protobuf
message MemberRemoveRequest {
  uint64 ID = 1;  // Member ID to remove
}
```

**Response:**
```protobuf
message MemberRemoveResponse {
  ResponseHeader header = 1;
  repeated Member members = 2;  // Remaining members
}

message Member {
  uint64 ID = 1;
  string name = 2;
  repeated string peerURLs = 3;
  repeated string clientURLs = 4;
  bool isLearner = 5;
}
```

**Example Request (JSON representation):**
```json
{
  "ID": 14006264466728655126
}
```

**Example Response:**
```json
{
  "header": {
    "cluster_id": 12345678901234567890,
    "member_id": 2064704656232095922,
    "revision": 123456,
    "raft_term": 45
  },
  "members": [
    {
      "ID": 2064704656232095922,
      "name": "ip-10-0-47-131.us-east-2.compute.internal",
      "peerURLs": ["https://10.0.47.131:2380"],
      "clientURLs": ["https://10.0.47.131:2379"],
      "isLearner": false
    },
    {
      "ID": 10955950548562151047,
      "name": "ip-10-0-66-147.us-east-2.compute.internal",
      "peerURLs": ["https://10.0.66.147:2380"],
      "clientURLs": ["https://10.0.66.147:2379"],
      "isLearner": false
    }
  ]
}
```

### Wire Format

The actual gRPC call over the wire:

```
HTTP/2 POST /etcdserverpb.Cluster/MemberRemove
Headers:
  :method: POST
  :scheme: https
  :path: /etcdserverpb.Cluster/MemberRemove
  :authority: 10.0.47.131:2379
  content-type: application/grpc
  te: trailers

Body (protobuf binary):
  [0x08, 0x96, 0x99, 0xf8, 0x52, 0x3f, 0x60, 0xc2, 0x00]
  (encodes: ID=14006264466728655126 / 0xc2603f52f9899916)
```

---

## Ports and Endpoints

### etcd Port Layout

| Port | Purpose | Protocol | Used By |
|------|---------|----------|---------|
| **2379** | Client API | gRPC/TLS | Operator, API Server, etcdctl |
| **2380** | Peer API | gRPC/TLS | etcd members (Raft) |
| 2381 | HTTP Client API | HTTP/TLS | Legacy (deprecated) |
| 9978 | gRPC Proxy | gRPC | Internal |
| 9979 | Metrics | HTTP | Prometheus |
| 9980 | Readyz Sidecar | HTTP | Liveness probes |

### etcd Endpoints

From the cluster:

```bash
# All etcd endpoints (from environment)
ALL_ETCD_ENDPOINTS=https://10.0.47.131:2379,https://10.0.66.147:2379,https://10.0.7.132:2379

# Client endpoints (what etcdctl uses)
ETCDCTL_ENDPOINTS=https://10.0.47.131:2379,https://10.0.66.147:2379,https://10.0.7.132:2379
```

### Service Endpoints

```bash
# Kubernetes Service (load-balanced across all members)
ETCD_SERVICE_HOST=172.30.107.222
ETCD_SERVICE_PORT=2379

# Full endpoint
https://172.30.107.222:2379
```

### Certificate Locations

**In etcd pods:**
```bash
# Client certificates
/etc/kubernetes/static-pod-certs/secrets/etcd-all-certs/
  ├── etcd-peer-<node>.crt
  ├── etcd-peer-<node>.key
  ├── etcd-serving-<node>.crt
  └── etcd-serving-<node>.key

# CA bundles
/etc/kubernetes/static-pod-certs/configmaps/etcd-all-bundles/
  ├── server-ca-bundle.crt
  ├── trusted-ca-bundle.crt
  └── ...

# Environment variables for etcdctl
ETCDCTL_CERT=/etc/kubernetes/static-pod-certs/secrets/etcd-all-certs/etcd-peer-<node>.crt
ETCDCTL_KEY=/etc/kubernetes/static-pod-certs/secrets/etcd-all-certs/etcd-peer-<node>.key
ETCDCTL_CACERT=/etc/kubernetes/static-pod-certs/configmaps/etcd-all-bundles/server-ca-bundle.crt
```

**In operator pod:**
```bash
# Client certificates (mounted as secrets)
/var/run/secrets/etcd-client/
  ├── tls.crt
  └── tls.key

# CA bundle (mounted as configmap)
/var/run/configmaps/etcd-ca/
  └── ca-bundle.crt
```

---

## Debugging Guide

### 1. Check Cluster State

```bash
# Get etcd pods
oc get pods -n openshift-etcd -l app=etcd

# Check etcd member list
oc exec -n openshift-etcd etcd-<pod-name> -c etcdctl -- \
  etcdctl member list -w table

# Check endpoint status
oc exec -n openshift-etcd etcd-<pod-name> -c etcdctl -- \
  etcdctl endpoint status -w table

# Check endpoint health
oc exec -n openshift-etcd etcd-<pod-name> -c etcdctl -- \
  etcdctl endpoint health -w table
```

### 2. Check Machines Pending Deletion

```bash
# Find machines pending deletion
oc get machines -n openshift-machine-api \
  -l machine.openshift.io/cluster-api-machine-role=master \
  -o json | jq -r '.items[] | select(.metadata.deletionTimestamp != null) | 
  {name: .metadata.name, deletion: .metadata.deletionTimestamp, 
   ip: .status.addresses[] | select(.type=="InternalIP") | .address}'

# Check PreDrain hooks
oc get machines -n openshift-machine-api \
  -l machine.openshift.io/cluster-api-machine-role=master \
  -o custom-columns=NAME:.metadata.name,DELETION:.metadata.deletionTimestamp,HOOKS:.spec.lifecycleHooks.preDrain[*].name
```

### 3. Check Operator Logs

```bash
# Get operator pod
oc get pods -n openshift-etcd-operator

# Watch operator logs
oc logs -n openshift-etcd-operator -l name=etcd-operator -f

# Filter for scale down decisions
oc logs -n openshift-etcd-operator -l name=etcd-operator --tail=100 | \
  grep -E "skip scale down|SCALEDOWN|member.*removed"

# With debug builds (if you added debug prints)
oc logs -n openshift-etcd-operator -l name=etcd-operator -f | \
  grep DEBUG-SCALEDOWN
```

### 4. Check Operator Status

```bash
# Check cluster operator status
oc get clusteroperator etcd

# Get detailed status
oc get clusteroperator etcd -o yaml

# Check operator conditions
oc get clusteroperator etcd -o jsonpath='{.status.conditions}' | jq
```

### 5. Trace gRPC Calls with etcdctl Debug Mode

```bash
# Enable debug output to see gRPC calls
oc exec -n openshift-etcd etcd-<pod-name> -c etcdctl -- \
  sh -c 'ETCDCTL_DEBUG=true etcdctl member list 2>&1'

# This shows:
# - Connection establishment
# - gRPC method called
# - Request/response details
```

### 6. Monitor Active Connections

```bash
# Watch active connections to port 2379
oc exec -n openshift-etcd etcd-<pod-name> -c etcd -- \
  watch -n 1 'ss -tnp "sport = :2379 or dport = :2379"'

# Or snapshot
oc exec -n openshift-etcd etcd-<pod-name> -c etcd -- \
  ss -tnp 'sport = :2379 or dport = :2379'
```

### 7. Check Network Traffic with tcpdump

```bash
# Capture traffic on port 2379
oc debug node/<node-name>
chroot /host
tcpdump -i any -nn -s0 -w /tmp/etcd-2379.pcap 'port 2379'

# Download and analyze with Wireshark to see:
# - TLS handshakes
# - HTTP/2 frames
# - gRPC calls
```

### 8. Verify Quorum

```bash
# Check quorum status
oc exec -n openshift-etcd etcd-<pod-name> -c etcdctl -- \
  etcdctl endpoint status -w json | \
  jq -r '.[] | "\(.Endpoint): Leader=\(.Status.leader==.Status.header.member_id), Raft Term=\(.Status.raftTerm)"'

# Count healthy members
oc exec -n openshift-etcd etcd-<pod-name> -c etcdctl -- \
  etcdctl endpoint health -w json | jq '.[] | select(.health==true)' | jq -s 'length'
```

---

## Manual Operations

### Using etcdctl

**etcdctl** is the official CLI for etcd and uses the exact same gRPC APIs as the operator.

#### List Members

```bash
oc exec -n openshift-etcd etcd-ip-10-0-47-131.us-east-2.compute.internal \
  -c etcdctl -- etcdctl member list -w table

# Output:
# +------------------+---------+------------------------+------------------------+
# |        ID        | STATUS  |          NAME          |       PEER ADDRS       |
# +------------------+---------+------------------------+------------------------+
# | 1ca74df210cf20b2 | started | ip-10-0-47-131...      | https://10.0.47.131:2380|
# | 980b5afa0fcb0687 | started | ip-10-0-66-147...      | https://10.0.66.147:2380|
# | c2603f52f9899916 | started | ip-10-0-7-132...       | https://10.0.7.132:2380 |
# +------------------+---------+------------------------+------------------------+
```

**gRPC API Used:** `/etcdserverpb.Cluster/MemberList`

#### Get Endpoint Status

```bash
oc exec -n openshift-etcd etcd-ip-10-0-47-131.us-east-2.compute.internal \
  -c etcdctl -- etcdctl endpoint status -w table

# Output shows:
# - Endpoint
# - Member ID
# - Raft Term
# - DB Size
# - Is Leader
```

**gRPC API Used:** `/etcdserverpb.Maintenance/Status`

#### Check Endpoint Health

```bash
oc exec -n openshift-etcd etcd-ip-10-0-47-131.us-east-2.compute.internal \
  -c etcdctl -- etcdctl endpoint health -w table
```

**gRPC API Used:** `/etcdserverpb.Maintenance/Status` (checks if response succeeds)

#### Add Member (Manual)

```bash
# ⚠️ WARNING: Only use if you know what you're doing!
oc exec -n openshift-etcd etcd-ip-10-0-47-131.us-east-2.compute.internal \
  -c etcdctl -- etcdctl member add <member-name> \
  --peer-urls=https://<ip>:2380 \
  --learner
```

**gRPC API Used:** `/etcdserverpb.Cluster/MemberAdd`

#### Remove Member (Manual)

```bash
# ⚠️ WARNING: This will remove a member from the cluster!
# First get the member ID
oc exec -n openshift-etcd etcd-ip-10-0-47-131.us-east-2.compute.internal \
  -c etcdctl -- etcdctl member list -w json | jq -r '.members[] | "\(.ID) \(.name)"'

# Remove by ID (in hex)
oc exec -n openshift-etcd etcd-ip-10-0-47-131.us-east-2.compute.internal \
  -c etcdctl -- etcdctl member remove <member-id-hex>

# Example:
# etcdctl member remove c2603f52f9899916
```

**gRPC API Used:** `/etcdserverpb.Cluster/MemberRemove`

#### Promote Learner

```bash
# Promote a learner to voting member
oc exec -n openshift-etcd etcd-ip-10-0-47-131.us-east-2.compute.internal \
  -c etcdctl -- etcdctl member promote <learner-id-hex>
```

**gRPC API Used:** `/etcdserverpb.Cluster/MemberPromote`

### Direct etcdctl with All Parameters

If the environment variables aren't set, you can specify everything:

```bash
oc exec -n openshift-etcd etcd-ip-10-0-47-131.us-east-2.compute.internal \
  -c etcd -- etcdctl \
  --endpoints=https://10.0.47.131:2379,https://10.0.66.147:2379,https://10.0.7.132:2379 \
  --cacert=/etc/kubernetes/static-pod-certs/configmaps/etcd-all-bundles/server-ca-bundle.crt \
  --cert=/etc/kubernetes/static-pod-certs/secrets/etcd-all-certs/etcd-peer-ip-10-0-47-131.us-east-2.compute.internal.crt \
  --key=/etc/kubernetes/static-pod-certs/secrets/etcd-all-certs/etcd-peer-ip-10-0-47-131.us-east-2.compute.internal.key \
  member list -w table
```

### Mapping etcdctl Commands to gRPC Methods

| etcdctl Command | gRPC Service | gRPC Method | Used By |
|----------------|--------------|-------------|---------|
| `member list` | Cluster | MemberList | Operator, Admin |
| `member add` | Cluster | MemberAdd | Operator |
| `member remove` | Cluster | MemberRemove | Operator |
| `member promote` | Cluster | MemberPromote | Operator |
| `member update` | Cluster | MemberUpdate | Operator (rare) |
| `endpoint status` | Maintenance | Status | Operator, Admin |
| `endpoint health` | Maintenance | Status | Operator, Admin |
| `defrag` | Maintenance | Defragment | Operator (DefragController) |
| `snapshot save` | Maintenance | Snapshot | Backup jobs |
| `get` | KV | Range | API Server |
| `put` | KV | Put | API Server |
| `del` | KV | DeleteRange | API Server |

---

## Quick Reference

### Key Concepts

1. **Learner Pattern**: New members are added as non-voting learners first, then promoted after syncing
2. **Add Before Remove**: Replacement members are added before old ones are removed (maintains quorum)
3. **One at a Time**: Only one member is removed per sync cycle
4. **Quorum Protection**: Removal is blocked if it would violate quorum
5. **PreDrain Hooks**: Machines can't be drained until member is removed from etcd

### Important File Locations

```
cluster-etcd-operator/
├── pkg/
│   ├── etcdcli/
│   │   ├── etcdcli.go                 # etcd client wrapper
│   │   └── interfaces.go              # Client interfaces
│   └── operator/
│       ├── clustermembercontroller/
│       │   └── clustermembercontroller.go      # Member addition
│       └── clustermemberremovalcontroller/
│           └── clustermemberremovalcontroller.go  # Member removal (Line 300-302)
```

### Decision Logic Summary

**For Member Addition:**
- ✅ All existing members healthy
- ✅ New node has etcd pod running (but not ready)
- ✅ Machine has PreDrain deletion hook
- ✅ Machine not pending deletion

**For Member Removal:**
- ✅ Bootstrap complete
- ✅ Revision stable (not upgrading)
- ✅ etcd-endpoints ConfigMap updated
- ✅ Machine API functional
- ✅ Quorum maintained after removal
- ✅ **Replacement member already added** (count > desired)

---

## Conclusion

The cluster-etcd-operator automates etcd membership management while maintaining strict safety guarantees:

1. **Never loses quorum** - All changes go through Raft consensus
2. **Add before remove** - Replacements added before removals
3. **One at a time** - Gradual changes prevent disruption
4. **Health checks** - Only operates on healthy clusters
5. **Coordinated with Machine API** - PreDrain hooks prevent premature node deletion

Understanding this flow is crucial for:
- Debugging etcd scaling issues
- Understanding operator behavior during upgrades
- Safely performing manual etcd operations
- Troubleshooting stuck member additions/removals

---

**Last Updated:** 2026-05-29  
**Repository:** https://github.com/openshift/cluster-etcd-operator
