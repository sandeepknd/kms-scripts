# Etcd Static Pod Revision Rollout Flow

This document traces the complete lifecycle of a revision rollout in the cluster-etcd-operator — from an admin patching the `Etcd` CR to the new etcd static pod running on each control plane node.

## Table of Contents

- [Overview](#overview)
- [Why Revisions? Why Static Pods?](#why-revisions-why-static-pods)
- [Phase 1: Admin Patches the Etcd CR](#phase-1-admin-patches-the-etcd-cr)
- [Phase 2: TargetConfigController Renders the Desired State](#phase-2-targetconfigcontroller-renders-the-desired-state)
- [Phase 3: RevisionController Creates an Immutable Snapshot](#phase-3-revisioncontroller-creates-an-immutable-snapshot)
- [Phase 4: InstallerController Rolls Out One Node at a Time](#phase-4-installercontroller-rolls-out-one-node-at-a-time)
- [Phase 5: Installer Pod Writes to the Node Filesystem](#phase-5-installer-pod-writes-to-the-node-filesystem)
- [Phase 6: InstallerController Verifies and Advances](#phase-6-installercontroller-verifies-and-advances)
- [Phase 7: Supporting Controllers](#phase-7-supporting-controllers)
- [End-to-End Data Flow Diagram](#end-to-end-data-flow-diagram)
- [Key Design Decisions](#key-design-decisions)
- [Failure Handling](#failure-handling)
- [Key Code References](#key-code-references)

---

## Overview

Etcd runs as a **static pod** on each control plane node. Unlike Deployment-based operands, static pods are managed by the kubelet directly from YAML manifests at `/etc/kubernetes/manifests/`. The operator cannot simply update a Deployment object — it must physically write files to each node's filesystem.

To do this safely (etcd is the cluster's source of truth and must maintain quorum), the operator uses a **revision-based rollout** system provided by OpenShift's library-go. Each configuration change produces a numbered, immutable revision. That revision is installed on one control plane node at a time, verified healthy, and then rolled to the next.

---

## Why Revisions? Why Static Pods?

**Why static pods instead of a Deployment?**

Etcd must be running for the Kubernetes API server to function. But a Deployment requires the API server to schedule pods. This creates a chicken-and-egg problem — if etcd is down, the API server is down, and no controller can restart etcd. Static pods solve this: the kubelet reads manifests directly from disk (`/etc/kubernetes/manifests/`) and manages them independently of the API server.

**Why a revision system instead of just overwriting the manifest?**

1. **Atomicity** — a revision captures the complete desired state (pod spec, certificates, endpoints, CA bundles) as a single numbered unit. There is no window where some resources are updated and others are not.
2. **Rollback safety** — if a revision fails on one node, the previous revision's files are still on disk. The operator can reason about "node X is on revision 7, node Y is on revision 8."
3. **Auditability** — every configuration change produces a numbered ConfigMap (`revision-status-N`) that records what changed and when.
4. **Quorum protection** — the revision system gates rollouts behind a quorum check, preventing the operator from creating a new revision when etcd is already unhealthy.

---

## Phase 1: Admin Patches the Etcd CR

An administrator changes the etcd configuration:

```bash
oc patch etcd cluster --type merge -p '{"spec":{"logLevel":"Debug"}}'
```

This is a standard Kubernetes API write. The request hits the API server, which validates and persists the change to the etcd datastore. There is no admission webhook or special routing involved — it is an ordinary resource update.

### How the Operator Detects the Change

In `pkg/operator/starter.go`, the operator creates a `StaticPodOperatorClient` that sets up an **informer** watching the `Etcd` resource:

```go
operatorClient, dynamicInformers, err := genericoperatorclient.NewStaticPodOperatorClient(
    controllerContext.Clock, controllerContext.KubeConfig,
    operatorv1.GroupVersion.WithResource("etcds"),
    operatorv1.GroupVersion.WithKind("Etcd"),
    ExtractStaticPodOperatorSpec, ExtractStaticPodOperatorStatus)
```

When the Etcd CR is modified, the informer's cache updates. Every controller that registered `operatorClient.Informer()` as an input informer gets enqueued for a sync. This is the standard library-go pattern — no polling, no watches with raw clients.

---

## Phase 2: TargetConfigController Renders the Desired State

**File:** `pkg/operator/targetconfigcontroller/targetconfigcontroller.go`

The TargetConfigController watches multiple informers:
- The `Etcd` operator CR
- Endpoints, ConfigMaps, Secrets in the `openshift-etcd` namespace
- Nodes, Infrastructure, and Network cluster resources

When any of these change, `sync()` calls `createTargetConfig()`, which:

1. **Reads environment variables** from the `envVarGetter` (type `etcdenvvar.EnvVar`) — these are computed from live cluster state (node IPs, etcd member endpoints, certificate paths, etc.)

2. **Renders the etcd static pod template** using Go templates:
   ```go
   ceohelpers.RenderTemplate("etcd/pod.gotpl.yaml", ...)
   ```
   The template substitutes the etcd image, operator image, log level, and all computed environment variables.

3. **Creates or updates the `etcd-pod` ConfigMap** in the `openshift-etcd` namespace:
   ```go
   resourceapply.ApplyConfigMap(ctx, kubeClient.CoreV1(), eventRecorder, configMap)
   ```
   This ConfigMap contains the fully rendered `pod.yaml` — the complete static pod manifest that should be running on each node.

This ConfigMap is the **canonical source of truth** for what the etcd pod should look like. The `resourceapply.ApplyConfigMap` call is idempotent — it only writes if the content has actually changed. A no-op patch to the Etcd CR that doesn't change the rendered output won't trigger anything downstream.

The controller also manages `restore-etcd-pod` (recovery pod manifests) via `manageRecoveryPods()`.

---

## Phase 3: RevisionController Creates an Immutable Snapshot

**File:** `vendor/github.com/openshift/library-go/pkg/operator/revisioncontroller/revision_controller.go`

The RevisionController watches ConfigMaps and Secrets in the `openshift-etcd` namespace. The set of resources it tracks for revisions is defined in `starter.go`:

```go
var RevisionConfigMaps = []revision.RevisionResource{
    {Name: "etcd-pod"},          // the static pod manifest
    {Name: "etcd-endpoints"},    // etcd member endpoints
    {Name: "etcd-all-bundles"},  // CA bundles
}
var RevisionSecrets = []revision.RevisionResource{
    {Name: "etcd-all-certs"},    // TLS certificates
}
```

### The sync() Flow

1. **Find the latest revision** — scans existing `revision-status-N` ConfigMaps to determine the highest existing revision number.

2. **Quorum precondition check** — before creating any new revision, the controller calls `quorumChecker.IsSafeToUpdateRevision()` (defined in `starter.go`). This verifies that the etcd cluster has a healthy quorum. If quorum is at risk, no revision is created and the controller re-queues.

3. **Compare source resources against their latest revision copies** via `isLatestRevisionCurrent()`:
   - Compares `etcd-pod` (the source) against `etcd-pod-7` (the latest revision copy)
   - Compares `etcd-endpoints` against `etcd-endpoints-7`
   - Compares `etcd-all-bundles` against `etcd-all-bundles-7`
   - Compares `etcd-all-certs` against `etcd-all-certs-7`
   - If any differ, a new revision is needed. The change reason is recorded (e.g., `"configmap/etcd-pod has changed"`).

4. **Create revision N+1** — if a change is detected:

   a. Creates a `revision-status-8` ConfigMap with annotation `"operator.openshift.io/revision-ready": "false"`

   b. **Copies each tracked resource to an immutable, revision-suffixed copy**:
   - `etcd-pod` → `etcd-pod-8`
   - `etcd-endpoints` → `etcd-endpoints-8`
   - `etcd-all-bundles` → `etcd-all-bundles-8`
   - `etcd-all-certs` → `etcd-all-certs-8`

   These copies are **frozen snapshots**. Even if the source `etcd-pod` ConfigMap changes again immediately (triggering revision 9), revision 8's copies remain untouched.

   c. Marks the revision ready: sets `"operator.openshift.io/revision-ready": "true"` on `revision-status-8`

   d. **Updates the Etcd CR**: sets `status.LatestAvailableRevision = 8`

This status update is what triggers the InstallerController.

---

## Phase 4: InstallerController Rolls Out One Node at a Time

**File:** `vendor/github.com/openshift/library-go/pkg/operator/staticpod/controller/installer/installer_controller.go`

The InstallerController watches the operator informer, pods, ConfigMaps, and Secrets. When `LatestAvailableRevision` advances past any node's `CurrentRevision`, it drives the rollout.

### Node Selection

The `nodeToStartRevisionWith()` function picks which node to update first, using this priority:

1. Nodes already in transition (finish what you started — minimize disruption)
2. Nodes with failed revisions (retry failures)
3. Nodes that aren't ready (oldest first)
4. Nodes with the wrong revision (oldest current revision first)

This ensures the rollout is sequential and predictable.

### Creating the Installer Pod

For each selected node, the controller:

1. Sets `NodeStatus.TargetRevision = 8` on the Etcd CR
2. Calls `ensureRequiredResourcesExist()` — verifies all revision-suffixed ConfigMaps and Secrets (`etcd-pod-8`, `etcd-endpoints-8`, etc.) exist before proceeding
3. Creates an **installer pod** scheduled to that specific node:

```go
pod.Namespace = "openshift-etcd"
pod.Name = "installer-8-master-0"
pod.Spec.NodeName = "master-0"
pod.Spec.Containers[0].Image = os.Getenv("OPERATOR_IMAGE")
pod.Spec.Containers[0].Command = []string{"cluster-etcd-operator", "installer"}
```

The installer pod uses the **same binary** as the operator itself, just invoked with the `installer` subcommand. It runs as **privileged** with a hostPath volume mount to `/etc/kubernetes/`, giving it write access to the node's static pod manifest directory.

Its arguments include:
- `--revision=8`
- `--namespace=openshift-etcd`
- `--pod=etcd-pod` (the ConfigMap containing the static pod manifest)
- `--resource-dir=/etc/kubernetes/static-pod-resources`
- `--pod-manifest-dir=/etc/kubernetes/manifests`
- `--configmaps=etcd-pod,etcd-endpoints,etcd-all-bundles`
- `--secrets=etcd-all-certs`

---

## Phase 5: Installer Pod Writes to the Node Filesystem

**File:** `vendor/github.com/openshift/library-go/pkg/operator/staticpod/installerpod/cmd.go`

The `cluster-etcd-operator installer` subcommand runs `InstallOptions.Run()` inside the privileged pod on the target node. Here is what happens:

### Step 1: Wait for Other Installers

`waitForOtherInstallerRevisionsToSettle()` polls for other installer pods running on the same node. If a previous installer is still in progress, it waits. It also checks whether a newer revision has appeared — if revision 9 is already available, this revision 8 installer exits early (no point installing a stale revision).

### Step 2: Create the Revision Directory

```
/etc/kubernetes/static-pod-resources/etcd-pod-8/
```

### Step 3: Fetch and Write Revision Resources

The installer pod reads the revision-suffixed ConfigMaps and Secrets from the API server and writes them to disk:

```
/etc/kubernetes/static-pod-resources/etcd-pod-8/
├── configmaps/
│   ├── etcd-pod/
│   │   └── pod.yaml
│   ├── etcd-endpoints/
│   │   └── ...
│   └── etcd-all-bundles/
│       └── ...
└── secrets/
    └── etcd-all-certs/
        └── ...
```

Uses `atomicdir.Sync()` for atomic directory replacement — the directory either fully exists with all files or doesn't exist at all. No partial state.

During the copy, it substitutes `REVISION` → `8`, `NODE_NAME` → the actual node name, and `NODE_ENVVAR_NAME` → the node name with `-` and `.` replaced by `_` (safe for use as environment variable names) in all content.

### Step 4: Copy Unversioned Certificate Resources

Copies shared cert resources to `/etc/kubernetes/static-pod-resources/etcd-certs/` — these include `etcd-all-bundles`, `etcd-all-certs`, `etcd-scripts`, and `restore-etcd-pod`.

### Step 5: Write the Static Pod Manifest

This is the critical step:

1. Writes a backup copy to `/etc/kubernetes/static-pod-resources/etcd-pod-8/etcd-pod.yaml`
2. If the startup monitor is enabled (`withStartupMonitorSupport`), acquires a file lock (`/var/lock/etcd-installer.lock`) to coordinate with the startup monitor. The lock is only used when startup monitor support is active.
3. **Removes** `/etc/kubernetes/manifests/etcd-pod.yaml` — the kubelet detects this via inotify and terminates the running etcd pod
4. **Writes** the new manifest to `/etc/kubernetes/manifests/etcd-pod.yaml` — the kubelet detects the new file via inotify and starts the new etcd pod with the revision 8 configuration

The remove-then-write sequence ensures the kubelet sees a clean transition rather than an in-place edit.

---

## Phase 6: InstallerController Verifies and Advances

Back in the operator process, the InstallerController's `Sync()` loop monitors the result via `newNodeStateForInstallInProgress()`:

1. **Checks the installer pod status:**
   - If `PodSucceeded` → proceeds to verify the static pod
   - If `PodFailed` → records failure (see [Failure Handling](#failure-handling))
   - If still running → re-queues and waits

2. **Verifies the static pod** via `getStaticPodState()`:
   - Gets the **mirror pod** `etcd-master-0` from the API server (the kubelet creates a mirror pod in the API for every static pod)
   - Checks the pod's `revision` label matches the target revision (8)
   - Checks if the pod is `Ready` (all containers running, readiness probes passing)

3. **On success (without startup monitor):**
   - Sets `CurrentRevision = 8`, `TargetRevision = 0` on the node's status
   - The node rollout is complete

4. **On success (with startup monitor):**
   - The InstallerController does **not** set `CurrentRevision`/`TargetRevision` itself
   - Instead, it defers status advancement to the **startup-monitor pod**, which independently verifies etcd is healthy before marking the revision current
   - This provides an additional layer of safety for etcd's critical startup sequence

5. **Moves to the next node** — the InstallerController only proceeds to the next control plane node after the current node's etcd pod is fully healthy. This is critical for quorum safety.

### Static Pod Fallback State

If the static pod enters a `staticPodStateFallback` state (e.g., the startup monitor times out), a separate **fallback backoff** applies: 10-minute base, 2x multiplier, capped at 2 hours. This is much more conservative than the installer pod failure backoff, reflecting the severity of a static pod that won't start.

### Status Conditions

The InstallerController computes these conditions:

| Condition | Meaning |
|---|---|
| `StaticPodsAvailable` | At least one node has a running etcd pod |
| `NodeInstallerProgressing` | Any node is not yet at `LatestAvailableRevision` |
| `NodeInstallerDegraded` | Any installer pod has failed |
| `InstallerControllerDegraded` | The InstallerController itself encountered an error (distinct from node-level failures) |

---

## Phase 7: Supporting Controllers

### NodeController

**File:** `vendor/github.com/openshift/library-go/pkg/operator/staticpod/controller/node/node_controller.go`

Watches cluster-scoped nodes with the label `node-role.kubernetes.io/master=` and:
- Adds new master nodes to `status.NodeStatuses` in the Etcd CR
- Removes entries for deleted nodes
- Reports `NodeControllerDegraded` if any master node is `NotReady`

This ensures the InstallerController has an accurate, up-to-date list of nodes to roll out to.

### StaticPodStateController

**File:** `vendor/github.com/openshift/library-go/pkg/operator/staticpod/controller/staticpodstate/staticpodstate_controller.go`

Watches etcd pods in the `openshift-etcd` namespace and:
- Checks for containers in `Waiting` state (excluding `PodInitializing`), containers that are `Running` but not `Ready` past the expected startup duration, and `Terminated` containers with non-zero exit codes
- When all pods run the same image matching `OPERAND_IMAGE`, records the operand version via `versionRecorder.SetVersion()`
- Sets `StaticPodsDegraded` condition if any container is in a failing state

---

## End-to-End Data Flow Diagram

```
Admin: oc patch etcd cluster --type merge -p '{"spec":{"logLevel":"Debug"}}'
  │
  ▼
┌─────────────────────────────────────────────────────────┐
│                     API Server                          │
│  Validates and persists change to Etcd CR               │
└──────────────────────────┬──────────────────────────────┘
                           │ informer event
                           ▼
┌─────────────────────────────────────────────────────────┐
│              TargetConfigController                      │
│  Reads cluster state (nodes, endpoints, certs)          │
│  Renders etcd/pod.gotpl.yaml template                   │
│  Creates/updates ConfigMap "etcd-pod" in openshift-etcd │
└──────────────────────────┬──────────────────────────────┘
                           │ ConfigMap change detected
                           ▼
┌─────────────────────────────────────────────────────────┐
│                RevisionController                        │
│  Compares "etcd-pod" vs "etcd-pod-N" (latest revision)  │
│  Detects diff → runs quorum safety check                │
│  Creates immutable copies:                               │
│    etcd-pod → etcd-pod-(N+1)                            │
│    etcd-endpoints → etcd-endpoints-(N+1)                │
│    etcd-all-bundles → etcd-all-bundles-(N+1)            │
│    etcd-all-certs → etcd-all-certs-(N+1)               │
│  Creates revision-status-(N+1) ConfigMap                │
│  Updates Etcd CR: LatestAvailableRevision = N+1         │
└──────────────────────────┬──────────────────────────────┘
                           │ LatestAvailableRevision > CurrentRevision
                           ▼
┌─────────────────────────────────────────────────────────┐
│              InstallerController                         │
│  Picks node to update (priority-based selection)        │
│  Sets NodeStatus.TargetRevision = N+1                   │
│  Creates installer pod: installer-(N+1)-<nodename>      │
└──────────────────────────┬──────────────────────────────┘
                           │ pod scheduled to target node
                           ▼
┌─────────────────────────────────────────────────────────┐
│    Installer Pod (privileged, on control plane node)     │
│  Runs: cluster-etcd-operator installer                  │
│                                                          │
│  1. Fetch etcd-pod-(N+1), etcd-endpoints-(N+1),        │
│     etcd-all-bundles-(N+1), etcd-all-certs-(N+1)       │
│     from API server                                      │
│                                                          │
│  2. Write to node filesystem:                            │
│     /etc/kubernetes/static-pod-resources/etcd-pod-(N+1)/│
│     ├── configmaps/                                      │
│     │   ├── etcd-pod/pod.yaml                           │
│     │   ├── etcd-endpoints/                              │
│     │   └── etcd-all-bundles/                            │
│     └── secrets/                                         │
│         └── etcd-all-certs/                              │
│                                                          │
│  3. Remove /etc/kubernetes/manifests/etcd-pod.yaml      │
│  4. Write new /etc/kubernetes/manifests/etcd-pod.yaml   │
└──────────────────────────┬──────────────────────────────┘
                           │ kubelet inotify
                           ▼
┌─────────────────────────────────────────────────────────┐
│                       Kubelet                            │
│  Detects manifest change                                 │
│  Terminates old etcd pod                                 │
│  Starts new etcd pod with revision N+1 config           │
│  Creates mirror pod in API server                        │
└──────────────────────────┬──────────────────────────────┘
                           │ mirror pod Ready
                           ▼
┌─────────────────────────────────────────────────────────┐
│              InstallerController                         │
│  Monitors mirror pod: etcd-<nodename>                   │
│  Verifies revision label = N+1 and pod Ready            │
│  Sets CurrentRevision = N+1, TargetRevision = 0         │
│  ──► Moves to next control plane node                   │
│  ──► Repeats until all nodes are at revision N+1        │
└─────────────────────────────────────────────────────────┘
```

---

## Key Design Decisions

### One Node at a Time

Etcd requires a majority of members (quorum) to function. In a 3-node cluster, losing 2 members simultaneously means total cluster outage. The InstallerController enforces sequential rollout — it never starts a second node until the first node's etcd is confirmed healthy.

### Quorum Precondition Gate

The RevisionController won't even create a new revision if the etcd cluster doesn't have a healthy quorum. This prevents cascading failures — if one member is already unhealthy, the operator won't trigger a rollout that could take another member offline.

### Immutable Revision Snapshots

Once `etcd-pod-8` is created, its contents never change. If the admin patches the Etcd CR again while revision 8 is rolling out across nodes, the RevisionController creates revision 9 with the new state. Nodes that already received revision 8 will eventually get revision 9 in a subsequent rollout. This eliminates mid-rollout configuration drift.

### Same Binary for Operator and Installer

The `cluster-etcd-operator` binary serves dual duty:
- As the operator (the long-running controller process)
- As the installer (invoked with the `installer` subcommand inside privileged pods)

This simplifies the build and ensures version alignment — the installer logic always matches the operator version.

### Atomic Directory Writes

The installer pod uses `atomicdir.Sync()` to write revision directories. The directory either fully exists with all files or doesn't exist at all. This prevents the kubelet from reading a partially-written manifest.

### Remove-Then-Write Manifest Update

The installer deletes the old manifest before writing the new one. This gives the kubelet two distinct inotify events (delete, create) rather than a single modify event, ensuring a clean pod transition.

---

## Failure Handling

### Installer Pod Failure

When an installer pod fails, the InstallerController:
1. Records `LastFailedRevision` and increments `LastFailedCount` on the node's status
2. Applies **exponential backoff**: 10s base, 1.5x multiplier, capped at 10 minutes
3. Sets `NodeInstallerDegraded` condition
4. Retries by creating a new installer pod after the backoff period

### Static Pod Crash-Loop

The StaticPodStateController detects crash-looping etcd containers and sets `StaticPodsDegraded`. The InstallerController will not proceed to the next node while the current node's pod is unhealthy.

### Stale Installer Detection

If a newer revision becomes available while an installer pod is running, the installer pod detects this (it checks for newer revisions during startup) and exits early. The InstallerController will then create a new installer pod for the newer revision.

### Node Replacement

The InstallerController checks for stale node UIDs. If a control plane node is being replaced (same name but different UID), the controller skips it until the replacement is fully registered.

---

## Key Code References

| Component | File | Key Function |
|---|---|---|
| Operator startup | `pkg/operator/starter.go` | `RunOperator()` |
| Operator client setup | `pkg/operator/starter.go:208` | `NewStaticPodOperatorClient()` |
| Revision resources | `pkg/operator/starter.go:686-695` | `RevisionConfigMaps`, `RevisionSecrets` |
| Quorum precondition | `pkg/operator/starter.go:321-323` | `quorumChecker.IsSafeToUpdateRevision()` |
| Target config rendering | `pkg/operator/targetconfigcontroller/targetconfigcontroller.go` | `createTargetConfig()` |
| Pod template rendering | `pkg/operator/targetconfigcontroller/targetconfigcontroller.go` | `manageStandardPod()` |
| Revision creation | `vendor/.../library-go/.../revisioncontroller/revision_controller.go` | `createRevisionIfNeeded()` |
| Revision comparison | `vendor/.../library-go/.../revisioncontroller/revision_controller.go` | `isLatestRevisionCurrent()` |
| Installer controller | `vendor/.../library-go/.../installer/installer_controller.go` | `manageInstallationPods()` |
| Node selection | `vendor/.../library-go/.../installer/installer_controller.go` | `nodeToStartRevisionWith()` |
| Installer pod creation | `vendor/.../library-go/.../installer/installer_controller.go` | `ensureInstallerPod()` |
| Installer pod logic | `vendor/.../library-go/.../installerpod/cmd.go` | `InstallOptions.Run()` |
| Static pod state | `vendor/.../library-go/.../staticpodstate/staticpodstate_controller.go` | `Sync()` |
| Node tracking | `vendor/.../library-go/.../node/node_controller.go` | `Sync()` |

---

## Comparison with Deployment-Based Operators

For context, here is how this revision-based rollout differs from Deployment-based operators (like the jobset-operator):

| Aspect | Static Pod (etcd) | Deployment (jobset) |
|---|---|---|
| Who manages the pod? | Kubelet reads from disk | kube-controller-manager via ReplicaSet |
| How is it updated? | Installer pod writes YAML to node filesystem | Operator updates the Deployment object |
| Rollout granularity | Per-node, sequential | Per-pod, managed by Deployment controller |
| Revision tracking | Explicit numbered revisions with ConfigMap copies | Deployment's ReplicaSet history |
| Quorum safety | Operator-enforced preconditions | Not applicable |
| Works without API server? | Yes (kubelet reads from disk) | No (requires API server for scheduling) |
| Complexity | High (revision controller + installer pods + node tracking) | Low (single `resourceapply.ApplyDeployment` call) |
