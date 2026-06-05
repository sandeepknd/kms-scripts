# OpenShift Test Extension (OTE) Flow

**Last Updated:** 2026-06-06  
**Author:** Documentation based on openshift/origin and openshift/release analysis

---

## Table of Contents

1. [Overview](#overview)
2. [Architecture](#architecture)
3. [Test Types](#test-types)
4. [Discovery and Execution Flow](#discovery-and-execution-flow)
5. [Command Reference](#command-reference)
6. [CI Configuration](#ci-configuration)
7. [Development Workflows](#development-workflows)
8. [Troubleshooting](#troubleshooting)

---

## Overview

OpenShift uses a unified test framework called **OpenShift Test Extension (OTE)** that allows:
- **Centralized test execution** via the `openshift-tests` binary
- **Decentralized test ownership** where component teams own their tests
- **Consistent interface** across all test types using Ginkgo v2

### Key Concepts

- **`openshift-tests`**: Main test orchestrator binary (from openshift/origin repo)
- **Extension Binary**: Component-specific test binary (e.g., `cluster-kube-apiserver-operator-tests-tests-ext`)
- **Test Suite**: Named collection of tests (e.g., `openshift/conformance`, `openshift/cluster-kube-apiserver-operator/operator/serial`)
- **Qualifiers**: CEL expressions that filter which tests belong to a suite
- **OTE Interface**: Standard commands all test binaries must implement: `info`, `list`, `run-test`

---

## Architecture

```
┌─────────────────────────────────────────────────────────────────────┐
│                          CI Job Configuration                        │
│  (release/ci-operator/config/.../component-repo-branch.yaml)        │
└─────────────────────────────────────────────────────────────────────┘
                                    │
                                    │ env: TEST_SUITE=openshift/component/suite
                                    ▼
┌─────────────────────────────────────────────────────────────────────┐
│                         openshift-tests run                          │
│                      (Main Test Orchestrator)                        │
└─────────────────────────────────────────────────────────────────────┘
                                    │
                    ┌───────────────┴────────────────┐
                    │                                │
                    ▼                                ▼
        ┌──────────────────────┐        ┌──────────────────────────┐
        │   Built-in Tests     │        │   Extension Binaries     │
        │  (test/extended)     │        │  (from release payload)  │
        │                      │        │                          │
        │  Source: origin repo │        │  Source: component repos │
        └──────────────────────┘        └──────────────────────────┘
                    │                                │
                    │                                │
                    ▼                                ▼
        ┌──────────────────────┐        ┌──────────────────────────┐
        │  openshift-tests     │        │  component-tests-ext     │
        │  (self-invocation)   │        │  (external binary)       │
        └──────────────────────┘        └──────────────────────────┘
                    │                                │
                    └────────────┬───────────────────┘
                                 │
                                 ▼
                    ┌────────────────────────┐
                    │  Ginkgo Test Execution │
                    │  (JSONL output)        │
                    └────────────────────────┘
                                 │
                                 ▼
                    ┌────────────────────────┐
                    │   JUnit XML Reports    │
                    │   ($ARTIFACT_DIR)      │
                    └────────────────────────┘
```

---

## Test Types

### 1. Built-in Tests (Origin Repo)

**Location:** `openshift/origin/test/extended/`

**Characteristics:**
- Compiled directly into `openshift-tests` binary
- Cross-component integration tests
- Generic OpenShift functionality tests
- Examples: conformance, networking, authentication, builds

**Test Count:** ~1,226 tests (after filtering out upstream k8s tests)

**Example Suites:**
- `openshift/conformance` - Core OpenShift functionality
- `openshift/conformance/parallel` - Parallel-safe conformance tests
- `openshift/conformance/serial` - Serial-only conformance tests
- `openshift/network/stress` - Network stress testing
- `openshift/build` - Build functionality tests

### 2. Component Extension Tests

**Location:** Individual component repositories (e.g., `cluster-kube-apiserver-operator/test/`)

**Characteristics:**
- Each component builds its own test binary
- Binary packaged in release payload as container image
- Component teams own and maintain their tests
- Extracted and invoked by `openshift-tests` at runtime

**Example Components:**
- `cluster-kube-apiserver-operator-tests-tests-ext`
- `cluster-etcd-operator-tests-tests-ext`
- `cluster-authentication-operator-tests-tests-ext`
- `hyperkube` (contains k8s upstream tests)

**Example Suites:**
- `openshift/cluster-kube-apiserver-operator/operator/serial`
- `openshift/cluster-kube-apiserver-operator/encryption-kms`
- `openshift/etcd/recovery`

---

## Discovery and Execution Flow

### Phase 1: Suite Configuration (CI Config)

**File:** `release/ci-operator/config/openshift/cluster-kube-apiserver-operator/openshift-cluster-kube-apiserver-operator-main.yaml`

```yaml
- as: e2e-gcp-operator-serial-ote
  steps:
    cluster_profile: openshift-org-gcp
    env:
      TEST_SUITE: openshift/cluster-kube-apiserver-operator/operator/serial
    test:
    - ref: openshift-e2e-test
    workflow: ipi-gcp
```

### Phase 2: Test Discovery

#### Step 1: Extract Extension Binaries

```bash
# openshift-tests connects to cluster and reads release payload
# For each test extension image in the payload:

# Example: cluster-kube-apiserver-operator-tests
oc image extract \
  quay.io/openshift-release-dev/ocp-v4.0-art-dev@sha256:abc123... \
  --path /usr/bin/cluster-kube-apiserver-operator-tests-tests-ext:/tmp/extracted/ \
  --confirm

# Binary cached at: /tmp/openshift-tests-extension-binaries/<hash>/cluster-kube-apiserver-operator-tests-tests-ext
```

#### Step 2: Query Binary Info

```bash
# Get metadata from extension binary
cluster-kube-apiserver-operator-tests-tests-ext info

# Output (JSON):
{
  "apiVersion": "v1.1",
  "component": {
    "product": "openshift",
    "type": "operator",
    "name": "cluster-kube-apiserver-operator"
  },
  "suites": [
    {"name": "openshift/cluster-kube-apiserver-operator/operator/serial"},
    {"name": "openshift/cluster-kube-apiserver-operator/encryption-kms"}
  ]
}
```

#### Step 3: List Available Tests

```bash
# Get all tests from the binary
cluster-kube-apiserver-operator-tests-tests-ext list -o jsonl

# Output (JSONL - one test per line):
{"name":"[sig-kube-apiserver] API server should validate requests","suite":"openshift/cluster-kube-apiserver-operator/operator/serial",...}
{"name":"[sig-kube-apiserver] Encryption should work with KMS","suite":"openshift/cluster-kube-apiserver-operator/encryption-kms",...}
```

#### Step 4: Filter by Suite Qualifiers

```bash
# openshift-tests applies suite qualifiers (CEL expressions) to filter tests
# For suite "openshift/cluster-kube-apiserver-operator/operator/serial":
# Qualifier: name.contains("[Suite:openshift/cluster-kube-apiserver-operator/operator/serial]")

# Result: Only tests with matching [Suite:...] tags are selected
```

### Phase 3: Test Execution

#### For Extension Tests

```bash
# For each selected test, openshift-tests invokes:
cluster-kube-apiserver-operator-tests-tests-ext run-test \
  -n "[sig-kube-apiserver] test case 1 [Suite:openshift/cluster-kube-apiserver-operator/operator/serial]" \
  -n "[sig-kube-apiserver] test case 2 [Suite:openshift/cluster-kube-apiserver-operator/operator/serial]" \
  -o jsonl

# Environment variables passed:
# - KUBECONFIG=/path/to/kubeconfig
# - EXTENSION_ARTIFACT_DIR=$ARTIFACT_DIR/openshift/operator/cluster-kube-apiserver-operator
# - TEST_PROVIDER={"ProviderName":"gcp",...}
```

#### For Built-in Tests

```bash
# openshift-tests invokes ITSELF for built-in tests:
openshift-tests run-test \
  -n "[sig-arch][Early] Managed cluster should start all core operators [Suite:openshift/conformance/parallel]" \
  -n "[sig-cli] oc can run inside of a busybox container [Suite:openshift/conformance/parallel]" \
  -o jsonl
```

### Phase 4: Result Collection

```bash
# Each test returns JSONL output:
{"name":"test1","result":"passed","duration":12.5,"startTime":"2026-06-06T10:00:00Z","endTime":"2026-06-06T10:00:12Z"}
{"name":"test2","result":"failed","duration":5.3,"error":"assertion failed: expected foo, got bar"}

# openshift-tests:
# 1. Parses JSONL output
# 2. Aggregates results
# 3. Generates JUnit XML
# 4. Writes to $ARTIFACT_DIR/junit/
```

---

## Command Reference

### `openshift-tests` Commands

#### Run a Test Suite

```bash
# Run a predefined suite
openshift-tests run <suite-name> [flags]

# Examples:
openshift-tests run openshift/conformance
openshift-tests run openshift/cluster-kube-apiserver-operator/operator/serial
openshift-tests run openshift/etcd/recovery

# Common flags:
#   --dry-run              - List tests without running
#   --junit-dir DIR        - Write JUnit XML to DIR
#   --max-parallel-tests N - Set parallelism
#   --provider PROVIDER    - Set cloud provider (auto-detected)
#   -o FILE                - Write output to FILE
```

#### List Available Suites

```bash
openshift-tests list suites

# Output:
# openshift/conformance - Tests that ensure an OpenShift cluster...
# openshift/conformance/parallel - Only the portion that runs in parallel
# openshift/conformance/serial - Only the portion that runs serially
# ...
```

#### List Tests in a Suite

```bash
# Dry-run to see which tests would run
openshift-tests run openshift/conformance --dry-run

# Output: One test name per line
# [sig-arch][Early] Managed cluster should start all core operators [Suite:openshift/conformance/parallel]
# [sig-cli] oc can run inside of a busybox container [Suite:openshift/conformance/parallel]
# ...
```

#### Get Extension Info

```bash
# Get metadata about openshift-tests itself
openshift-tests info

# Output (JSON):
{
  "apiVersion": "v1.1",
  "component": {
    "product": "openshift",
    "type": "payload",
    "name": "origin"
  }
}
```

#### Run Specific Tests by Name

```bash
# Run specific tests (OTE interface)
openshift-tests run-test \
  -n "[sig-arch] test name 1" \
  -n "[sig-network] test name 2" \
  -o jsonl

# Useful for:
# - Running a subset of tests
# - Reproducing specific test failures
# - Integration with custom test runners
```

### Extension Binary Commands

Every extension binary (including `openshift-tests` itself) implements these commands:

#### Info Command

```bash
cluster-kube-apiserver-operator-tests-tests-ext info

# Returns: Component metadata and available suites (JSON)
```

#### List Command

```bash
cluster-kube-apiserver-operator-tests-tests-ext list -o jsonl

# Returns: All available tests (JSONL, one per line)
# Each line contains: name, suite, labels, code locations, etc.
```

#### Run-Test Command

```bash
cluster-kube-apiserver-operator-tests-tests-ext run-test \
  -n "test name 1" \
  -n "test name 2" \
  -o jsonl

# Flags:
#   -n, --names        - Test name (can be repeated)
#   -o, --output       - Output format (json, jsonl)
#   -c, --max-concurrency - Parallelism within binary

# Returns: Test results (JSONL)
# {"name":"test1","result":"passed","duration":12.5,...}
```

---

## CI Configuration

### Job Definition Structure

**Location:** `release/ci-operator/config/openshift/<repo>/openshift-<repo>-<branch>.yaml`

```yaml
tests:
- as: e2e-gcp-operator-serial-ote          # Job name
  steps:
    cluster_profile: openshift-org-gcp      # Cloud profile for cluster
    env:
      TEST_SUITE: openshift/cluster-kube-apiserver-operator/operator/serial  # Suite to run
    test:
    - ref: openshift-e2e-test                # Step registry reference
    workflow: ipi-gcp                        # Cluster provisioning workflow
```

### Suite Definition

**Location:** `openshift/origin/pkg/testsuites/standard_suites.go`

```go
var staticSuites = []ginkgo.TestSuite{
    {
        Name: "openshift/conformance/parallel",
        Description: "Only the portion of the openshift/conformance test suite that run in parallel.",
        Qualifiers: []string{
            "name.contains('[Suite:openshift/conformance/parallel')",
        },
        Parallelism:          30,
        MaximumAllowedFlakes: 15,
    },
    // ...
}
```

### Step Registry Reference

**Location:** `release/ci-operator/step-registry/openshift/e2e/test/openshift-e2e-test-ref.yaml`

```yaml
ref:
  as: openshift-e2e-test
  commands: openshift-e2e-test-commands.sh
  from: tests
  resources:
    requests:
      cpu: 1000m
      memory: 600Mi
```

**Command Script:** `openshift-e2e-test-commands.sh`

```bash
#!/bin/bash
openshift-tests run "${TEST_SUITE}" \
  --provider "${TEST_PROVIDER:-}" \
  -o "${ARTIFACT_DIR}/e2e.log" \
  --junit-dir "${ARTIFACT_DIR}/junit"
```

### Translation Flow

```
CI Job Config (YAML)
    ↓
env: TEST_SUITE=openshift/component/suite
    ↓
Step Registry (Bash Script)
    ↓
openshift-tests run "${TEST_SUITE}"
    ↓
Test Execution (Ginkgo via OTE)
    ↓
JUnit Results ($ARTIFACT_DIR/junit/)
```

---

## Development Workflows

### Option 1: CI/Production Testing

**Use Case:** Normal CI execution or testing against a released cluster

```bash
# Set cluster context
export KUBECONFIG=/path/to/kubeconfig

# Run suite - binaries auto-extracted from release payload
openshift-tests run openshift/cluster-kube-apiserver-operator/operator/serial \
  --junit-dir /tmp/junit
```

**What Happens:**
1. Connects to cluster
2. Reads release payload version
3. Extracts extension binaries from payload images
4. Runs tests
5. Generates JUnit reports

---

### Option 2: Direct Binary Invocation

**Use Case:** Quick local testing, debugging a specific test

```bash
# Build your component test binary
cd /path/to/cluster-kube-apiserver-operator
make build-tests
# Creates: _output/cluster-kube-apiserver-operator-tests-tests-ext

# Set environment
export KUBECONFIG=/path/to/kubeconfig
export EXTENSION_ARTIFACT_DIR=/tmp/artifacts

# List available tests
./_output/cluster-kube-apiserver-operator-tests-tests-ext list -o jsonl | jq -r .name

# Run specific test directly
./_output/cluster-kube-apiserver-operator-tests-tests-ext run-test \
  -n "[sig-kube-apiserver] should validate admission webhooks" \
  -o jsonl
```

**Advantages:**
- Fast iteration cycle
- No need for `openshift-tests` orchestration
- Easy to debug with IDE/debugger

**Disadvantages:**
- Missing monitoring/analytics from `openshift-tests`
- No suite filtering
- Manual test name management

---

### Option 3: Local Binary with openshift-tests Orchestration

**Use Case:** Testing new test code before merging, validating suite membership

```bash
# 1. Build local test binary
cd /path/to/cluster-kube-apiserver-operator
make build-tests
# Creates: _output/cluster-kube-apiserver-operator-tests-tests-ext

# 2. Set override environment variable
export KUBECONFIG=/path/to/kubeconfig

# Image tag format: Replace special chars (/, -, ., :) with underscores, uppercase
# For "cluster-kube-apiserver-operator-tests" → "CLUSTER_KUBE_APISERVER_OPERATOR_TESTS"
export EXTENSION_BINARY_OVERRIDE_CLUSTER_KUBE_APISERVER_OPERATOR_TESTS=/path/to/cluster-kube-apiserver-operator/_output/cluster-kube-apiserver-operator-tests-tests-ext

# 3. Run using openshift-tests (uses your local binary)
cd /path/to/origin
./openshift-tests run openshift/cluster-kube-apiserver-operator/operator/serial \
  --junit-dir /tmp/junit

# openshift-tests will:
# - See the override
# - Use your local binary instead of extracting from payload
# - Invoke: /path/to/.../tests-ext run-test -n "test1" -n "test2" -o jsonl
```

**Environment Variable Pattern:**

```bash
# General format:
EXTENSION_BINARY_OVERRIDE_<IMAGE_TAG_NORMALIZED>=/path/to/binary

# Normalization rules:
# - Replace / with _
# - Replace - with _  
# - Replace . with _
# - Replace : with _
# - Convert to UPPERCASE

# Examples:
export EXTENSION_BINARY_OVERRIDE_CLUSTER_KUBE_APISERVER_OPERATOR_TESTS=/path/to/binary
export EXTENSION_BINARY_OVERRIDE_HYPERKUBE=/path/to/k8s-tests-ext
export EXTENSION_BINARY_OVERRIDE_SOME_IMAGE_V1_2_3=/path/to/binary
```

**Specific Binary Path Override:**

```bash
# For images with multiple binaries:
# EXTENSION_BINARY_OVERRIDE_<IMAGE_TAG>_<BINARY_PATH>

export EXTENSION_BINARY_OVERRIDE_CLUSTER_KUBE_APISERVER_OPERATOR_TESTS_USR_BIN_TESTS_EXT=/path/to/binary
```

**Advantages:**
- Full `openshift-tests` orchestration (monitoring, retries, analytics)
- Suite filtering and qualifiers work correctly
- Tests your changes in realistic CI-like environment
- Can verify suite membership

**Disadvantages:**
- Requires both `openshift-tests` binary and component binary
- More complex setup

---

### Option 4: Testing Built-in Tests (Origin Repo)

**Use Case:** Developing tests in `openshift/origin/test/extended/`

```bash
# 1. Make changes to origin tests
cd /path/to/origin
vim test/extended/operators/my_new_test.go

# 2. Rebuild openshift-tests binary
make build

# 3. Run suite containing your test
export KUBECONFIG=/path/to/kubeconfig
./openshift-tests run openshift/conformance/parallel --dry-run | grep "my new test"

# 4. If found, run the suite
./openshift-tests run openshift/conformance/parallel \
  --junit-dir /tmp/junit
```

**Tag Your Test Correctly:**

```go
var _ = g.Describe("[sig-operator] My Component [Suite:openshift/conformance/parallel]", func() {
    g.It("should do something [apigroup:example.com]", func() {
        // Test code
    })
})
```

---

## Troubleshooting

### Test Not Found in Suite

**Problem:** Test exists but `--dry-run` doesn't show it

**Causes:**
1. Missing `[Suite:...]` tag in test description
2. Wrong suite name in tag
3. Suite qualifiers don't match test name

**Solution:**

```bash
# Check test tags
grep -r "Describe\|It" test/extended/myarea/ | grep -i "my test"

# Verify suite qualifiers
openshift-tests list suites | grep -A5 "myarea"

# Check if test appears in ALL tests
./component-tests-ext list -o jsonl | jq -r .name | grep "my test"

# If found, check suite field
./component-tests-ext list -o jsonl | jq 'select(.name | contains("my test"))'
```

### Binary Extraction Fails

**Problem:** `openshift-tests` can't extract extension binary

**Error:**
```
failed to extract test binaries: couldn't determine release image
```

**Causes:**
1. Not connected to cluster
2. ClusterVersion resource missing
3. Release payload not available

**Solution:**

```bash
# Verify cluster connection
oc get clusterversion

# Check release payload
oc get clusterversion version -o jsonpath='{.status.desired.image}'

# Manually extract to test
oc image extract <release-image> \
  --path /usr/bin/cluster-kube-apiserver-operator-tests-tests-ext:/tmp/test/ \
  --confirm
```

### Environment Variable Override Not Working

**Problem:** `openshift-tests` still extracts from payload despite override

**Debugging:**

```bash
# 1. Check image tag normalization
# Find actual image tag:
oc get is -n openshift tests -o yaml | grep cluster-kube-apiserver-operator

# 2. Normalize correctly (example: "cluster-kube-apiserver-operator-tests")
# Correct: CLUSTER_KUBE_APISERVER_OPERATOR_TESTS
# Wrong: CLUSTER-KUBE-APISERVER-OPERATOR-TESTS (hyphens not replaced)

# 3. Verify variable is set
echo $EXTENSION_BINARY_OVERRIDE_CLUSTER_KUBE_APISERVER_OPERATOR_TESTS

# 4. Check binary is executable
ls -la /path/to/binary
chmod +x /path/to/binary

# 5. Test binary directly first
/path/to/binary info
/path/to/binary list -o jsonl | head -5
```

### Test Timeout

**Problem:** Test exceeds timeout and is killed

**Default Timeouts:**
- Default: 10 minutes
- Suite-specific: Defined in suite configuration
- Test-specific: `[Timeout:30m]` tag in test name

**Solution:**

```bash
# 1. Check suite timeout
openshift-tests list suites | grep -A10 "suite-name"

# 2. Override with flag
openshift-tests run suite-name --timeout 30m

# 3. Or tag specific test
g.It("long running test [Timeout:1h]", func() {
    // Test that needs > 10 minutes
})
```

### Framework Initialization Failed

**Problem:** All tests fail with "FRAMEWORK INITIALIZATION FAILED"

**Causes:**
1. Invalid KUBECONFIG
2. Cluster unreachable
3. Missing cluster credentials
4. TEST_PROVIDER environment variable issues

**Solution:**

```bash
# Verify cluster access
oc whoami
oc get nodes

# Check TEST_PROVIDER (auto-detected but can override)
export TEST_PROVIDER='{"ProviderName":"gcp"}'

# Enable verbose logging
openshift-tests run suite-name -v=4
```

### Binary Architecture Mismatch

**Problem:** Binary fails with "exec format error"

**Cause:** Binary compiled for different architecture (e.g., ARM vs x86_64)

**Solution:**

```bash
# Check binary architecture
file /path/to/binary
# Should match: ELF 64-bit LSB executable, x86-64

# Rebuild for correct architecture
GOOS=linux GOARCH=amd64 make build-tests

# For Apple Silicon development:
# - Run in Linux VM or container
# - Use amd64 release payload
# - Enable x86 emulation
```

---

## Additional Resources

### Key Files and Locations

| Path | Description |
|------|-------------|
| `openshift/origin/test/extended/` | Built-in test source code |
| `openshift/origin/pkg/testsuites/standard_suites.go` | Suite definitions |
| `openshift/origin/pkg/test/extensions/` | OTE framework implementation |
| `openshift/release/ci-operator/config/` | CI job configurations |
| `openshift/release/ci-operator/step-registry/` | Reusable CI steps |

### Important Environment Variables

| Variable | Description | Example |
|----------|-------------|---------|
| `KUBECONFIG` | Cluster connection config | `/path/to/kubeconfig` |
| `TEST_SUITE` | Suite name to run | `openshift/conformance` |
| `TEST_PROVIDER` | Cloud provider config (JSON) | `{"ProviderName":"gcp"}` |
| `ARTIFACT_DIR` | Output directory for logs/junit | `/tmp/artifacts` |
| `EXTENSION_ARTIFACT_DIR` | Per-extension artifact dir | `$ARTIFACT_DIR/openshift/operator/name` |
| `EXTENSION_BINARY_OVERRIDE_*` | Override binary path | See development workflows |
| `OPENSHIFT_SKIP_EXTERNAL_TESTS` | Use only built-in tests | `true` |

### Test Naming Conventions

Tests use bracket tags for categorization and filtering:

```
[sig-AREA] Test description [Feature:NAME] [Qualifier] [Suite:PATH]

Examples:
[sig-kube-apiserver] API server should validate requests [Suite:openshift/conformance/parallel]
[sig-etcd][Feature:EtcdRecovery] Cluster should recover from quorum loss [Disruptive] [Suite:openshift/etcd/recovery]
[sig-network][Feature:NetworkPolicy] Should enforce ingress policy [Suite:openshift/network/stress]
```

**Common Tags:**
- `[sig-AREA]` - Special Interest Group (SIG) ownership
- `[Feature:NAME]` - Feature category
- `[Suite:PATH]` - Suite membership (critical for filtering)
- `[Early]` - Run before main tests
- `[Late]` - Run after main tests
- `[Serial]` - Cannot run in parallel
- `[Disruptive]` - Causes cluster disruption
- `[Skipped]` - Always skipped
- `[Timeout:DURATION]` - Test-specific timeout
- `[apigroup:GROUP]` - API group tested

### Building Test Binaries

**Component Repo:**

```bash
# cluster-kube-apiserver-operator example
cd /path/to/cluster-kube-apiserver-operator

# Build test binary
make build-tests

# Output typically at:
# _output/cluster-kube-apiserver-operator-tests-tests-ext
```

**Origin Repo:**

```bash
cd /path/to/origin

# Build openshift-tests
make build

# Output:
# openshift-tests (in repo root)
```

---

## Appendix: Complete Example Walkthrough

### Scenario: Add New Test to Component Repo

**Goal:** Add a new test to `cluster-kube-apiserver-operator` and verify it runs in the correct suite.

#### Step 1: Write Test

```go
// File: cluster-kube-apiserver-operator/test/e2e/operator_serial_test.go
package e2e

import (
    g "github.com/onsi/ginkgo/v2"
    o "github.com/onsi/gomega"
)

var _ = g.Describe("[sig-kube-apiserver] API Server Configuration [Suite:openshift/cluster-kube-apiserver-operator/operator/serial]", func() {
    g.It("should validate custom admission webhooks", func() {
        // Test implementation
        o.Expect(true).To(o.BeTrue())
    })
})
```

#### Step 2: Build Local Binary

```bash
cd /path/to/cluster-kube-apiserver-operator
make build-tests
```

#### Step 3: Verify Test Discovery

```bash
# List tests to verify it appears
./_output/cluster-kube-apiserver-operator-tests-tests-ext list -o jsonl | \
  jq -r '.name' | \
  grep "validate custom admission webhooks"

# Output should show:
# [sig-kube-apiserver] API Server Configuration should validate custom admission webhooks [Suite:openshift/cluster-kube-apiserver-operator/operator/serial]
```

#### Step 4: Test Directly

```bash
export KUBECONFIG=/path/to/kubeconfig
export EXTENSION_ARTIFACT_DIR=/tmp/artifacts

./_output/cluster-kube-apiserver-operator-tests-tests-ext run-test \
  -n "[sig-kube-apiserver] API Server Configuration should validate custom admission webhooks [Suite:openshift/cluster-kube-apiserver-operator/operator/serial]" \
  -o jsonl

# Verify output shows test passed
```

#### Step 5: Test with openshift-tests Orchestration

```bash
export KUBECONFIG=/path/to/kubeconfig
export EXTENSION_BINARY_OVERRIDE_CLUSTER_KUBE_APISERVER_OPERATOR_TESTS=/path/to/cluster-kube-apiserver-operator/_output/cluster-kube-apiserver-operator-tests-tests-ext

cd /path/to/origin

# Dry-run to verify suite membership
./openshift-tests run openshift/cluster-kube-apiserver-operator/operator/serial --dry-run | \
  grep "validate custom admission webhooks"

# Run the full suite
./openshift-tests run openshift/cluster-kube-apiserver-operator/operator/serial \
  --junit-dir /tmp/junit
```

#### Step 6: Commit and Create PR

```bash
cd /path/to/cluster-kube-apiserver-operator
git add test/e2e/operator_serial_test.go
git commit -m "Add test for custom admission webhook validation"
git push origin my-feature-branch

# CI will automatically:
# 1. Build the test binary
# 2. Include it in the release payload
# 3. Run the suite in e2e-gcp-operator-serial-ote job
```

---

**End of Document**
