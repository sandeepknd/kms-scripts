# OpenShift Test Extension (OTE) Component Testing Guide

## Overview

This guide explains how to run OpenShift Test Extension (OTE) component test binaries using `openshift-tests` with local binary overrides. This allows you to test your locally built component test binaries through the full `openshift-tests` orchestration framework without needing to build and push container images.

## Table of Contents

- [Prerequisites](#prerequisites)
- [How the Override Mechanism Works](#how-the-override-mechanism-works)
- [Step-by-Step Guide](#step-by-step-guide)
  - [Step 1: Ensure Component is Registered](#step-1-ensure-component-is-registered)
  - [Step 2: Build Your Component Test Binary](#step-2-build-your-component-test-binary)
  - [Step 3: Rebuild openshift-tests](#step-3-rebuild-openshift-tests)
  - [Step 4: Set Environment Variables](#step-4-set-environment-variables)
  - [Step 5: Run Tests](#step-5-run-tests)
- [Verification](#verification)
- [Troubleshooting](#troubleshooting)
- [Examples](#examples)

---

## Prerequisites

1. **OpenShift Cluster**: Access to a running OpenShift cluster
2. **KUBECONFIG**: Valid kubeconfig file pointing to your cluster
3. **Component Test Binary**: Locally built OTE-compliant test binary
4. **openshift-tests Binary**: Built from the origin repository

---

## How the Override Mechanism Works

The override mechanism allows you to substitute a locally built test binary in place of one that would normally be extracted from the OpenShift release payload.

### Normal Flow (Without Override)
```
openshift-tests → Connects to cluster → Gets release image
                → Extracts test binaries from release payload
                → Runs tests
```

### Override Flow (With Override)
```
openshift-tests → Checks for EXTENSION_BINARY_OVERRIDE_* env var
                → Uses your local binary instead of extracting
                → Runs tests with your local build
```

### Environment Variable Naming Convention

The override environment variable follows this pattern:

```
EXTENSION_BINARY_OVERRIDE_<NORMALIZED_IMAGE_TAG>
```

Where `<NORMALIZED_IMAGE_TAG>` is the image tag with:
- All `/`, `-`, `.`, `:` characters replaced with `_`
- Converted to UPPERCASE

**Example:**
- Image tag: `cluster-kube-descheduler-operator`
- Environment variable: `EXTENSION_BINARY_OVERRIDE_CLUSTER_KUBE_DESCHEDULER_OPERATOR`

---

## Step-by-Step Guide

### Step 1: Ensure Component is Registered

First, verify that your component is registered in the `extensionBinaries` list in `openshift-tests`.

1. Open `pkg/test/extensions/binary.go` in the origin repository

2. Check if your component is listed in the `extensionBinaries` array:

```go
var extensionBinaries = []TestBinary{
    // ... other entries ...
    {
        imageTag:   "cluster-kube-descheduler-operator",
        binaryPath: "/usr/bin/cluster-kube-descheduler-operator-tests-ext.gz",
    },
    // ... more entries ...
}
```

3. If your component is **NOT** listed, add it:

```go
{
    imageTag:   "your-component-name",           // Image tag from release payload
    binaryPath: "/usr/bin/your-binary-name.gz",  // Path inside the container image
},
```

**Important Notes:**
- `imageTag`: The name of the image in the OpenShift release payload
- `binaryPath`: The path to the binary **inside the container image** (not your local path)
- The binary path typically includes `.gz` extension as release images contain compressed binaries

### Step 2: Build Your Component Test Binary

Build your component's test binary using the OTE framework:

```bash
cd /path/to/your/component/repo

# Build the test binary
make build-tests
# OR
go build -o component-tests-ext ./cmd/tests
```

**Verify the binary:**
```bash
# Check the binary exists and is executable
ls -lh ./component-tests-ext

# Verify it's an OTE-compliant binary
./component-tests-ext info
```

The `info` command should return JSON with component metadata and test suites.

### Step 3: Rebuild openshift-tests

After adding your component to `extensionBinaries` (if needed), rebuild `openshift-tests`:

```bash
cd /path/to/origin

# Rebuild openshift-tests binary
make build WHAT=cmd/openshift-tests

# Verify the build
ls -lh ./openshift-tests
```

### Step 4: Set Environment Variables

Set the required environment variables:

```bash
# Required: Point to your cluster
export KUBECONFIG=/path/to/your/kubeconfig

# Required: Override with your local binary
export EXTENSION_BINARY_OVERRIDE_<NORMALIZED_TAG>=/path/to/your/local/binary

# Example for cluster-kube-descheduler-operator:
export EXTENSION_BINARY_OVERRIDE_CLUSTER_KUBE_DESCHEDULER_OPERATOR=/home/user/cluster-kube-descheduler-operator/cluster-kube-descheduler-operator-tests-ext
```

**Important:**
- Use the **absolute path** to your local binary
- Use the **uncompressed** binary (no `.gz` extension in the local path)
- The environment variable name must exactly match the normalized image tag

### Step 5: Run Tests

Run your test suite through `openshift-tests`:

```bash
cd /path/to/origin

# List available suites to verify yours is registered
./openshift-tests run --help

# Dry-run to verify tests are discovered
./openshift-tests run openshift/your-component/suite-name --dry-run

# Run the actual tests
./openshift-tests run openshift/your-component/suite-name --junit-dir /tmp/junit
```

**Example:**
```bash
./openshift-tests run openshift/cluster-kube-descheduler-operator/operator/serial --junit-dir /tmp/junit
```

---

## Verification

### Verify Override is Active

Run a dry-run and check for the override message:

```bash
export KUBECONFIG=/path/to/kubeconfig
export EXTENSION_BINARY_OVERRIDE_YOUR_COMPONENT=/path/to/your/binary

./openshift-tests run openshift/your-component/suite --dry-run 2>&1 | grep -i "Found override"
```

**Expected output:**
```
time="..." level=info msg="Found override for this extension" 
    binary=/usr/bin/your-binary.gz 
    override=/path/to/your/local/binary 
    tag=your-component
```

If you see this message, the override is working correctly!

### Verify Tests are Listed

```bash
./openshift-tests run openshift/your-component/suite --dry-run 2>&1 | grep "your-test-pattern"
```

This should list all the tests from your suite.

---

## Troubleshooting

### Issue: "suite does not exist"

**Symptoms:**
```
error: error converting to options: suite "openshift/your-component/suite" does not exist
```

**Solutions:**
1. Ensure your component is registered in `pkg/test/extensions/binary.go`
2. Rebuild `openshift-tests` after adding the entry
3. Verify the suite name matches what your component binary reports in `info` output

### Issue: Override not being picked up

**Symptoms:**
- openshift-tests extracts binary from release image instead of using local binary
- No "Found override" message in logs

**Solutions:**
1. Verify environment variable name matches the normalized image tag:
   ```bash
   # Check your image tag in binary.go
   grep "your-component" pkg/test/extensions/binary.go
   
   # Ensure env var name matches (replace -, ., :, / with _)
   echo $EXTENSION_BINARY_OVERRIDE_YOUR_NORMALIZED_TAG
   ```

2. Check the environment variable is set in the current shell:
   ```bash
   env | grep EXTENSION_BINARY_OVERRIDE
   ```

3. Use `&&` to chain commands on one line:
   ```bash
   export KUBECONFIG=/path/to/kubeconfig && \
   export EXTENSION_BINARY_OVERRIDE_YOUR_COMPONENT=/path/to/binary && \
   ./openshift-tests run ... --dry-run
   ```

### Issue: Binary not executable

**Symptoms:**
```
failed running '/path/to/binary info': permission denied
```

**Solution:**
```bash
chmod +x /path/to/your/binary
```

### Issue: "unauthorized: access to the requested resource is not authorized"

**Symptoms:**
```
error: unauthorized: access to the requested resource is not authorized
```

**Cause:** Missing or incorrect KUBECONFIG

**Solution:**
```bash
# Ensure KUBECONFIG is set and valid
export KUBECONFIG=/path/to/valid/kubeconfig

# Verify cluster access
oc get nodes
```

### Issue: Tests fail with "Conflict" or "object has been modified"

**Symptoms:**
```
Operation cannot be fulfilled: the object has been modified; please apply your changes to the latest version
```

**Cause:** These are actual test failures (race conditions, conflicts), not infrastructure issues

**Solution:**
- Review the test logic
- Check for timing issues in your test code
- These failures indicate the test ran successfully, but the test itself encountered an issue

---

## Examples

### Example 1: Testing cluster-kube-descheduler-operator

```bash
# 1. Build your test binary
cd /home/user/cluster-kube-descheduler-operator
make build-tests

# 2. Verify the binary
ls -lh ./cluster-kube-descheduler-operator-tests-ext
./cluster-kube-descheduler-operator-tests-ext info

# 3. Set environment variables
export KUBECONFIG=/home/user/kubeconfig
export EXTENSION_BINARY_OVERRIDE_CLUSTER_KUBE_DESCHEDULER_OPERATOR=/home/user/cluster-kube-descheduler-operator/cluster-kube-descheduler-operator-tests-ext

# 4. Run tests
cd /home/user/origin
./openshift-tests run openshift/cluster-kube-descheduler-operator/operator/serial --junit-dir /tmp/junit
```

### Example 2: Dry-run verification

```bash
# Set env vars
export KUBECONFIG=/home/user/kubeconfig
export EXTENSION_BINARY_OVERRIDE_CLUSTER_KUBE_DESCHEDULER_OPERATOR=/home/user/cluster-kube-descheduler-operator/cluster-kube-descheduler-operator-tests-ext

# Verify override is working
./openshift-tests run openshift/cluster-kube-descheduler-operator/operator/serial --dry-run 2>&1 | grep -i "Found override"

# List tests that will run
./openshift-tests run openshift/cluster-kube-descheduler-operator/operator/serial --dry-run 2>&1 | grep "Descheduler"
```

### Example 3: All-in-one command

```bash
export KUBECONFIG=/home/user/kubeconfig && \
export EXTENSION_BINARY_OVERRIDE_CLUSTER_KUBE_DESCHEDULER_OPERATOR=/home/user/cluster-kube-descheduler-operator/cluster-kube-descheduler-operator-tests-ext && \
cd /home/user/origin && \
./openshift-tests run openshift/cluster-kube-descheduler-operator/operator/serial --junit-dir /tmp/junit
```

---

## Reference: Environment Variable Normalization

| Image Tag | Normalized Env Var |
|-----------|-------------------|
| `cluster-kube-descheduler-operator` | `EXTENSION_BINARY_OVERRIDE_CLUSTER_KUBE_DESCHEDULER_OPERATOR` |
| `cluster-kube-apiserver-operator` | `EXTENSION_BINARY_OVERRIDE_CLUSTER_KUBE_APISERVER_OPERATOR` |
| `machine-api-operator` | `EXTENSION_BINARY_OVERRIDE_MACHINE_API_OPERATOR` |
| `cli` | `EXTENSION_BINARY_OVERRIDE_CLI` |
| `hyperkube` | `EXTENSION_BINARY_OVERRIDE_HYPERKUBE` |

---

## Additional Resources

- [OpenShift Test Extension Documentation](https://github.com/openshift-eng/openshift-tests-extension)
- [Origin Test Guide](https://github.com/openshift/origin/blob/master/test/extended/README.md)
- [OTE Flow Guide](https://github.com/sandeepknd/kms-scripts/blob/main/test_ext_flow.md)

---

## Summary

The key steps are:

1. ✅ Register your component in `pkg/test/extensions/binary.go`
2. ✅ Build `openshift-tests` binary
3. ✅ Build your component test binary
4. ✅ Set `KUBECONFIG` environment variable
5. ✅ Set `EXTENSION_BINARY_OVERRIDE_<NORMALIZED_TAG>` environment variable
6. ✅ Run tests through `./openshift-tests`

The override mechanism allows you to iterate quickly on test development without needing to rebuild and push container images to test your changes!
