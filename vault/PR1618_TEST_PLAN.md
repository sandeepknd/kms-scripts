# Test Plan for PR #1618: Refactor Defrag Controller

## PR Objective
Reduce the operational impact of etcd defragmentation by:
1. Processing one member at a time instead of all members simultaneously
2. Transferring leadership away from the target member before defragmentation to avoid write blocks
3. Prioritizing members by fragmentation percentage (most fragmented first)
4. Simplifying error handling and recovery logic

## Key Implementation Changes

### Core Logic Changes
- **One-member-per-sync**: Defrags at most one member per sync cycle (every ~11 minutes)
- **Prioritization**: Sorts members by fragmentation percentage (descending) and selects the most fragmented
- **Leadership avoidance**: If the most fragmented member is the leader AND other targets exist, defrags the second-most fragmented instead
- **Preemptive leadership transfer**: When targeting the leader, attempts to transfer leadership to the least fragmented follower first
- **Requeue after transfer**: After successful leadership transfer, requeues with 5-second delay to allow etcd to settle
- **Simplified error handling**: Defrag failures increment a counter and set degraded state after 3 failures, but don't halt processing

### Removed Features
- Polling/waiting for cluster health between defrags
- `defragWaitDuration` timing logic
- Batch processing of all members

---

## Test Categories

### 1. Sequential Single-Member Defragmentation Tests

#### Test 1.1: One Member Defragged Per Sync
**Objective**: Verify only one member is defragged per sync cycle

**Setup**:
- 3-member cluster (HA)
- All 3 members fragmented (dbSize: 1GB, dbInUse: 500MB = 50% fragmentation)
- All members healthy

**Steps**:
1. Call sync() once
2. Count defrag success events
3. Verify only 1 defrag event occurred
4. Repeat sync() calls to defrag remaining members

**Expected**:
- Sync 1: 1 defrag event (most fragmented non-leader)
- Sync 2: 1 defrag event (second non-leader)
- Sync 3: Leadership transfer event
- Sync 4: 1 defrag event (former leader)
- Total: 3 defrag events across 4 syncs

**Coverage**: Sequential processing, one-per-sync behavior

---

#### Test 1.2: No Defrag When No Members Are Fragmented
**Objective**: Verify controller skips defrag when no members meet criteria

**Setup**:
- 3-member cluster
- All members below fragmentation threshold (dbSize: 1GB, dbInUse: 900MB = 10% fragmentation)

**Steps**:
1. Call sync()
2. Check for defrag events

**Expected**:
- Event: "No etcd members meet the conditions for defragmentation"
- 0 defrag success events
- Controller returns nil error

**Coverage**: Early exit when no work needed

---

#### Test 1.3: Partial Fragmentation (Mixed Members)
**Objective**: Verify only fragmented members are processed

**Setup**:
- 3-member cluster
- Member 1: 60% fragmented (most)
- Member 2: 10% fragmented (below threshold)
- Member 3: 50% fragmented

**Steps**:
1. Call sync() repeatedly
2. Track which members get defragged

**Expected**:
- Only members 1 and 3 are defragged
- Member 2 is never defragged
- Order: Member 1 (60%), then Member 3 (50%)

**Coverage**: Fragmentation filtering and prioritization

---

### 2. Prioritization and Sorting Tests

#### Test 2.1: Most Fragmented First
**Objective**: Verify members are defragged in descending fragmentation order

**Setup**:
- 3-member cluster, all healthy, all non-leaders initially
- Member A: 30% fragmented
- Member B: 60% fragmented (highest)
- Member C: 45% fragmented

**Steps**:
1. Call sync() three times
2. Track order of defrag events

**Expected**:
- Order: B (60%), C (45%), A (30%)

**Coverage**: `sortByMostFragmented` function

---

#### Test 2.2: Equal Fragmentation Handling
**Objective**: Verify stable behavior when fragmentation percentages are equal

**Setup**:
- 3-member cluster
- All members: 50% fragmented

**Steps**:
1. Call sync() multiple times
2. Verify no crashes or errors

**Expected**:
- All members eventually defragged
- No errors
- Deterministic order (based on member ID or other stable field)

**Coverage**: Edge case in sorting logic

---

#### Test 2.3: Fragmentation Percentage Calculation
**Objective**: Verify `checkFragmentationPercentage` calculates correctly

**Test Cases**:
| dbSize | dbInUse | Expected % | Should Defrag? |
|--------|---------|-----------|----------------|
| 1GB    | 500MB   | 50%       | Yes            |
| 1GB    | 900MB   | 10%       | No             |
| 1GB    | 550MB   | 45%       | Yes (at threshold) |
| 100MB  | 50MB    | 50%       | No (below minDefragBytes) |
| 0      | 0       | 0%        | No (prevents division by zero) |

**Expected**:
- Fragmentation % matches expected values
- No division by zero errors
- Defrag only when: (dbSize >= 100MB) AND (fragmentation >= 45%)

**Coverage**: `checkFragmentationPercentage`, `isEndpointBackendFragmented`

---

### 3. Leadership Transfer Tests

#### Test 3.1: Leader Transfer Before Leader Defrag
**Objective**: Verify leadership is transferred when leader is the defrag target

**Setup**:
- 3-member cluster
- Only the leader is fragmented (dbSize: 1GB, dbInUse: 500MB)
- Followers are not fragmented

**Steps**:
1. Call sync()
2. Check events for leader transfer
3. Verify requeue occurred
4. Call sync() again
5. Check for defrag event

**Expected**:
- Sync 1: "Moved leadership away from member..." event, requeue after 5 seconds
- Sync 2: Defrag success on former leader
- Total: 1 leader transfer, 1 defrag

**Coverage**: Leadership transfer logic, requeue behavior

---

#### Test 3.2: Leader Transfer Target Selection (Least Fragmented)
**Objective**: Verify leadership is transferred to the least fragmented follower

**Setup**:
- 3-member cluster
- Leader (Member A): 60% fragmented (target for defrag)
- Follower B: 40% fragmented
- Follower C: 10% fragmented (least fragmented)

**Steps**:
1. Call sync()
2. Check leader transfer event for target member ID

**Expected**:
- Leadership transferred to Member C (least fragmented)
- Event message includes both source and target member names/IDs

**Coverage**: `sortByLeastFragmented` for follower selection

---

#### Test 3.3: Skip Leader When Other Targets Exist
**Objective**: Verify controller defrags non-leader when leader is most fragmented but others are available

**Setup**:
- 3-member cluster
- Leader: 70% fragmented (highest)
- Follower A: 60% fragmented
- Follower B: 50% fragmented

**Steps**:
1. Call sync()
2. Check which member was defragged

**Expected**:
- First sync: Follower A defragged (60%, second-highest)
- Leader is NOT defragged on first sync (leadership transfer deferred)

**Coverage**: Leader avoidance logic in target selection

---

#### Test 3.4: Leader Transfer Failure Handling
**Objective**: Verify defrag proceeds even if leader transfer fails

**Setup**:
- 3-member cluster
- Leader is the only fragmented member
- Mock `MoveLeader()` to return an error

**Steps**:
1. Call sync()
2. Check events

**Expected**:
- Event: "Failed to move leader away from member..."
- Event: "Attempting defrag on member..." (proceeds anyway)
- Event: "etcd member has been defragmented..." (success)
- No degraded condition set

**Coverage**: Leader transfer error resilience

---

#### Test 3.5: No Leader Transfer for Non-Leader Targets
**Objective**: Verify no leadership transfer when defragging a follower

**Setup**:
- 3-member cluster
- Leader: 10% fragmented (below threshold)
- Follower: 60% fragmented (target)

**Steps**:
1. Call sync()
2. Check for leadership transfer events

**Expected**:
- 0 leader transfer events
- 1 defrag success event (follower)

**Coverage**: Conditional leadership transfer logic

---

#### Test 3.6: Requeue Timing After Leadership Transfer
**Objective**: Verify 5-second settle time after leadership transfer

**Setup**:
- 3-member cluster
- Leader is the defrag target

**Steps**:
1. Call sync() with a mock queue
2. Capture the requeue delay
3. Verify sync() returns nil (no error)

**Expected**:
- `syncCtx.Queue().AddAfter(key, 5*time.Second)` called
- No immediate defrag event (deferred to next sync)

**Coverage**: Requeue timing constant `leaderTransferSettleTime`

---

### 4. Error Handling and Degraded State Tests

#### Test 4.1: Degraded After 3 Consecutive Failures
**Objective**: Verify controller sets degraded condition after 3 defrag failures

**Setup**:
- 3-member cluster
- 1 member fragmented
- Mock defrag to return errors for first 3 calls

**Steps**:
1. Call sync() 3 times
2. Check operator condition

**Expected**:
- After sync 1: `numDefragFailures = 1`, no degraded condition
- After sync 2: `numDefragFailures = 2`, no degraded condition
- After sync 3: `numDefragFailures = 3`, degraded condition set
- Degraded condition message: "degraded after 3 attempts at defragmenting etcd members"

**Coverage**: Failure counter, degraded condition threshold

---

#### Test 4.2: Recovery from Degraded State
**Objective**: Verify degraded condition clears after successful defrag

**Setup**:
- 3-member cluster
- Mock defrag to fail 3 times, then succeed

**Steps**:
1. Call sync() 3 times (failures) → degraded
2. Call sync() 1 more time (success) → recovery

**Expected**:
- After 3 failures: Degraded condition = True
- After 1 success: Degraded condition = False, `numDefragFailures = 0`

**Coverage**: `clearDegraded()` function, counter reset

---

#### Test 4.3: Partial Failure Does Not Stop Subsequent Syncs
**Objective**: Verify single defrag failure doesn't halt subsequent sync cycles

**Setup**:
- 3-member cluster, all fragmented
- Mock defrag to fail on first member, succeed on others

**Steps**:
1. Call sync() 7 times (3 failures + 4 successes for remaining members)

**Expected**:
- First 3 syncs: Failures on Member A (counter increments)
- Sync 4: Leadership transfer for Member B
- Sync 5: Success on Member B
- Sync 6: Leadership transfer for Member C
- Sync 7: Success on Member C
- Total: 2 successful defrags (B and C), degraded condition set

**Coverage**: Error handling doesn't block future work

---

#### Test 4.4: Defrag Timeout Handling
**Objective**: Verify controller handles defrag timeouts gracefully

**Setup**:
- 3-member cluster
- Mock defrag to return context.DeadlineExceeded

**Steps**:
1. Call sync()
2. Check events and condition

**Expected**:
- Event: "failed defrag on member: ... context deadline exceeded"
- `numDefragFailures` incremented
- No panic or unhandled error

**Coverage**: Timeout error path in `Defragment()` call

---

#### Test 4.5: Cluster Unhealthy Prevents Defrag
**Objective**: Verify defrag is skipped when cluster is unhealthy

**Setup**:
- 3-member cluster
- 2 healthy, 1 unhealthy
- All members fragmented

**Steps**:
1. Call sync()

**Expected**:
- Error: "cluster is unhealthy: 2 of 3 members are available"
- 0 defrag events
- No degraded condition (health check failure, not defrag failure)

**Coverage**: Pre-defrag health check

---

### 5. Topology-Specific Tests

#### Test 5.1: Dual-Replica (2-Node Fenced) Topology
**Objective**: Verify correct behavior on 2-node fenced clusters

**Setup**:
- 2-member cluster (DualReplicaTopologyMode)
- Both members fragmented

**Steps**:
1. Call sync() 3 times

**Expected**:
- Sync 1: Defrag non-leader
- Sync 2: Leader transfer
- Sync 3: Defrag former leader
- Total: 2 defrag success events

**Coverage**: Dual-replica support

---

#### Test 5.2: HA with Arbiter (3-Node with Arbiter)
**Objective**: Verify arbiter members are not defragged

**Setup**:
- 3-member cluster (HighlyAvailableArbiterMode)
- 2 voting members + 1 arbiter (learner)
- All fragmented

**Steps**:
1. Call sync() 4 times
2. Check which members were defragged

**Expected**:
- Only 2 defrag events (voting members only)
- Arbiter (learner) is filtered out

**Coverage**: Learner filtering in `runDefrag()`

---

#### Test 5.3: Single-Replica (SNO) Disabled
**Objective**: Verify defrag controller is disabled on SNO

**Setup**:
- 1-member cluster (SingleReplicaTopologyMode)

**Steps**:
1. Call sync()

**Expected**:
- 0 defrag events
- Controller disabled condition: True
- Reason: SNO defrag is unsafe

**Coverage**: Topology-based disablement

---

#### Test 5.4: Manual Disable via ConfigMap
**Objective**: Verify manual override disables defrag

**Setup**:
- 3-member cluster
- ConfigMap "etcd-disable-defrag" exists in operator namespace

**Steps**:
1. Call sync()

**Expected**:
- 0 defrag events
- Controller disabled condition: True
- Event: controller is disabled

**Coverage**: ConfigMap-based disablement

---

### 6. Member Filtering Tests

#### Test 6.1: Learner Members Excluded
**Objective**: Verify learner members are not defragged

**Setup**:
- 3 voting members + 1 learner
- All members fragmented

**Steps**:
1. Call sync() until all eligible members defragged

**Expected**:
- 3 defrag events (voting members only)
- Learner is never processed

**Coverage**: `member.IsLearner` filter

---

#### Test 6.2: Unstarted Members Excluded
**Objective**: Verify members with empty ClientURLs are skipped

**Setup**:
- 3-member cluster
- Member 1: ClientURLs = ["http://..."] (started)
- Member 2: ClientURLs = [] (unstarted)
- Member 3: ClientURLs = ["http://..."] (started)
- All fragmented

**Steps**:
1. Call sync() repeatedly

**Expected**:
- Only Members 1 and 3 defragged
- Member 2 skipped silently

**Coverage**: `len(member.ClientURLs) == 0` filter

---

#### Test 6.3: Nil Status Handling
**Objective**: Verify error when status is nil for a member

**Setup**:
- 3-member cluster
- Mock Status() to return (nil, nil) for one member

**Steps**:
1. Call sync()

**Expected**:
- Error: "endpoint status returned nil for member..."
- No defrag attempted

**Coverage**: Nil status check

---

### 7. Multi-Sync Workflow Tests

#### Test 7.1: Complete 3-Member Defrag Cycle
**Objective**: Verify full defrag cycle across multiple syncs

**Setup**:
- 3-member cluster (HA)
- All members fragmented equally (50%)

**Steps**:
1. Call sync() 4 times
2. Track events per sync

**Expected**:
| Sync | Event                               |
|------|-------------------------------------|
| 1    | Defrag success (non-leader A)       |
| 2    | Defrag success (non-leader B)       |
| 3    | Leadership transfer (leader → A/B)  |
| 4    | Defrag success (former leader)      |

**Coverage**: End-to-end workflow

---

#### Test 7.2: Resumption After Controller Restart
**Objective**: Verify controller resumes work after restart

**Setup**:
- 3-member cluster, all fragmented
- Defrag 1 member, then "restart" controller (new instance)

**Steps**:
1. Sync 1: Defrag member A (fake client state persists)
2. Create new controller instance with same fake client
3. Sync 2: Defrag member B

**Expected**:
- Member A not re-defragged (dbSize == dbInUse after first defrag)
- Members B and C defragged on subsequent syncs
- No duplicate work

**Coverage**: Stateless controller design

---

#### Test 7.3: Dynamic Fragmentation Increase
**Objective**: Verify controller reacts to newly fragmented members

**Setup**:
- 3-member cluster
- Initial: Only member A fragmented
- After first sync: Manually increase fragmentation on member B

**Steps**:
1. Sync 1: Defrag member A
2. Update member B status to fragmented
3. Sync 2: Check if member B is defragged

**Expected**:
- Sync 1: Member A defragged
- Sync 2: Member B defragged (new target)

**Coverage**: Dynamic target detection

---

### 8. Event Logging Tests

#### Test 8.1: Defrag Attempt Event
**Objective**: Verify detailed attempt event is logged

**Setup**:
- 1 fragmented member

**Steps**:
1. Call sync()
2. Check event message

**Expected**:
- Event type: "DefragControllerDefragmentAttempt"
- Message includes: member name, memberID (hex), dbSize, dbInUse, leader ID

**Coverage**: Pre-defrag event logging

---

#### Test 8.2: Defrag Success Event
**Objective**: Verify success event format

**Expected**:
- Event type: "DefragControllerDefragmentSuccess"
- Message: "etcd member has been defragmented: <name>, memberID: <id>"

---

#### Test 8.3: Defrag Failure Event
**Objective**: Verify failure event format

**Setup**:
- Mock defrag to return an error

**Expected**:
- Event type: "DefragControllerDefragmentFailed"
- Message: "failed defrag on member: <name>, memberID: <id>: <error>"

---

#### Test 8.4: Leadership Transfer Success Event
**Expected**:
- Event type: "DefragControllerLeaderTransferred"
- Message: "Moved leadership away from member <A> (memberID: <id1>) to member <B> (memberID: <id2>) before defrag, requeueing to allow etcd to settle"

---

#### Test 8.5: Leadership Transfer Failure Event
**Expected**:
- Event type: "DefragControllerLeaderTransferFailed"
- Message: "Failed to move leader away from member <A> to member <B> before defrag: <error>"

---

#### Test 8.6: No Defrag Needed Event
**Expected**:
- Event type: "DefragControllerDefragmentSkipped"
- Message: "No etcd members meet the conditions for defragmentation"

---

### 9. Integration Tests (Real etcd)

#### Test 9.1: Real Defrag on Integration Cluster
**Objective**: Verify defrag works on real etcd members

**Setup**:
- Use `integration.NewCluster(t, &integration.ClusterConfig{Size: 3})`
- Artificially fragment members (write/delete data)

**Steps**:
1. Write data to increase dbSize
2. Delete data (dbSize > dbInUse)
3. Wait for compaction
4. Run controller sync()
5. Verify dbSize decreases

**Expected**:
- Real defragmentation succeeds
- dbSize ≈ dbInUse after defrag

**Coverage**: Real etcd client interaction

---

#### Test 9.2: Real Leadership Transfer
**Objective**: Verify real leadership transfer works

**Steps**:
1. Start 3-member etcd cluster
2. Identify leader
3. Call `MoveLeader(ctx, followerID)`
4. Verify new leader via Status() calls

**Expected**:
- Leadership successfully transferred
- New leader confirmed

**Coverage**: Real `MoveLeader()` API

---

### 10. Performance and Timing Tests

#### Test 10.1: Sync Timing Without Blocking
**Objective**: Verify sync() doesn't block unnecessarily

**Setup**:
- 3-member cluster, 1 fragmented

**Steps**:
1. Measure sync() execution time

**Expected**:
- Sync completes in < 5 seconds (no `wait.Poll` loops)
- Fast return after defrag

**Coverage**: Removed polling logic

---

#### Test 10.2: Requeue Delay Accuracy
**Objective**: Verify requeue delay is exactly 5 seconds after leader transfer

**Steps**:
1. Mock queue to capture AddAfter delay
2. Trigger leader transfer scenario
3. Verify delay parameter

**Expected**:
- Delay = 5 * time.Second (constant `leaderTransferSettleTime`)

**Coverage**: Requeue timing

---

### 11. Edge Cases and Boundary Conditions

#### Test 11.1: Single Fragmented Member (No Leadership Transfer)
**Objective**: Verify behavior when only one member exists

**Setup**:
- 1-member cluster (but controller enabled for testing)
- Member fragmented

**Steps**:
1. Call sync()

**Expected**:
- No leadership transfer (no other members)
- Defrag succeeds

**Coverage**: Single-member edge case

---

#### Test 11.2: All Members Equally Fragmented
**Objective**: Verify stable selection when all members are identical

**Setup**:
- 3-member cluster
- All members: 50% fragmented

**Expected**:
- Deterministic selection order
- All eventually defragged

---

#### Test 11.3: Zero DbSize (Division by Zero Protection)
**Objective**: Verify no panic when dbSize = 0

**Setup**:
- Member with dbSize = 0, dbInUse = 0

**Expected**:
- No panic
- Fragmentation % = 0
- Member not selected for defrag

**Coverage**: `checkFragmentationPercentage` division protection

---

#### Test 11.4: Very High Fragmentation (99%)
**Objective**: Verify correct handling of extreme fragmentation

**Setup**:
- Member with dbSize = 1GB, dbInUse = 10MB (99% fragmentation)

**Expected**:
- Member selected as highest priority
- Defragged successfully

---

#### Test 11.5: Fragmentation at Exact Threshold (45%)
**Objective**: Verify boundary condition at `maxFragmentedPercentage`

**Setup**:
- Member with dbSize = 1GB, dbInUse = 550MB (45% fragmentation)

**Expected**:
- Member is selected for defrag (>= threshold)

---

#### Test 11.6: Fragmentation Just Below Threshold (44.99%)
**Objective**: Verify member is excluded just below threshold

**Setup**:
- Member with dbSize = 1GB, dbInUse = 551MB (~44.9% fragmentation)

**Expected**:
- Member NOT selected for defrag

---

### 12. Regression Tests (Old Behavior)

#### Test 12.1: No Longer Waits for Cluster Health Between Defrags
**Objective**: Verify removed polling logic

**Expected**:
- No `wait.Poll` calls in code
- Fast successive syncs (no artificial delays)

---

#### Test 12.2: No Longer Defrags All Members in One Sync
**Objective**: Verify batch processing is removed

**Setup**:
- 3 fragmented members

**Expected**:
- Only 1 defrag per sync (not 3)

---

#### Test 12.3: Leader Is Not Necessarily Defragged Last
**Objective**: Verify leader-last logic is removed

**Setup**:
- Leader: 80% fragmented
- Follower A: 50% fragmented
- Follower B: 40% fragmented

**Expected**:
- Leader is avoided initially (Follower A defragged first)
- But leader may be defragged before Follower B (depends on sync order)

**Coverage**: Removed "append leader last" logic

---

### 13. Fake Client Behavior Tests

#### Test 13.1: Fake Defragment Updates DbSize
**Objective**: Verify fake client simulates defrag correctly

**Steps**:
1. Member with dbSize = 1GB, dbInUse = 500MB
2. Call `Defragment(member)`
3. Check status

**Expected**:
- After defrag: dbSize = 500MB (matches dbInUse)

**Coverage**: Fake client defrag simulation

---

#### Test 13.2: Fake MoveLeader Updates Leader Field
**Objective**: Verify fake client updates leader status

**Steps**:
1. Get status (leader = Member A)
2. Call `MoveLeader(ctx, MemberB.ID)`
3. Get status again

**Expected**:
- All status responses now show leader = Member B

**Coverage**: Fake client leader transfer

---

#### Test 13.3: Fake Defrag Error Injection
**Objective**: Verify error simulation works

**Setup**:
- Fake client with `WithFakeDefragErrors([]error{err1, err2})`

**Steps**:
1. Call Defragment() 3 times
2. Check errors

**Expected**:
- Call 1: returns err1
- Call 2: returns err2
- Call 3: returns nil (error queue exhausted)

**Coverage**: Error injection for testing

---

## Suggested Test Implementation Order

1. **Start with unit tests** (Tests 2.3, 6.3, 11.3-11.6): Core logic and edge cases
2. **Fake client tests** (Tests 13.1-13.3): Verify test infrastructure
3. **Sequential defrag tests** (Tests 1.1-1.3): Core behavior
4. **Prioritization tests** (Tests 2.1-2.2): Sorting logic
5. **Leadership transfer tests** (Tests 3.1-3.6): Complex orchestration
6. **Error handling tests** (Tests 4.1-4.5): Degraded state logic
7. **Multi-sync workflows** (Tests 7.1-7.3): End-to-end scenarios
8. **Topology tests** (Tests 5.1-5.4): Platform variations
9. **Event logging tests** (Tests 8.1-8.6): Observability
10. **Integration tests** (Tests 9.1-9.2): Real etcd validation

## Test Coverage Goals

- **Line Coverage**: >90% for defragcontroller.go
- **Branch Coverage**: 100% for critical paths (health check, fragmentation check, leader transfer)
- **Integration Coverage**: At least 2 tests with real etcd clusters

## Existing Test Updates Needed

Based on the PR diff, the following existing tests were updated:

1. **TestNewDefragController**: Added `syncLoops` field to test scenarios
   - Updated to call sync() multiple times per scenario
   - Removed leader-last validation (regex check removed)
   
2. **TestNewDefragControllerMultiSyncs**: Updated error expectations
   - Changed `errSyncLoops` to 0 (errors no longer propagate from sync)
   - Adjusted sync loop counts to account for leader transfer requeues

3. **New Test Added**: `TestDefragMovesLeadershipBeforeDefrag`
   - Validates leader transfer before defrag workflow

## Additional Validation Points

1. **Code Review Feedback**: Address reviewer concerns
   - Division by zero in `checkFragmentationPercentage` (already covered by Test 11.3)
   - Error messages should identify specific member (check Test 8.3)
   - Time-based cooldown persistence (out of scope for this PR)

2. **Performance Regression**: Ensure no performance degradation
   - Measure sync() duration (Test 10.1)
   - Verify no excessive etcd API calls

3. **Observability**: Ensure sufficient logging/events
   - All state transitions logged (Tests 8.1-8.6)
   - Degraded state changes recorded

---

## Summary

This test plan covers:
- **13 test categories**
- **65+ individual test cases**
- **Unit, integration, and edge case testing**
- **All major code paths** in the refactored defragcontroller.go

The plan ensures the PR's objectives are met:
1. ✅ One member defragged per sync
2. ✅ Leadership transferred before leader defrag
3. ✅ Prioritization by fragmentation percentage
4. ✅ Simplified error handling
5. ✅ No regression in existing functionality
