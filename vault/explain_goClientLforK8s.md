# OLM Test Library - Design Decisions and Architecture

## Table of Contents
1. [Why Unstructured Objects?](#why-unstructured-objects)
2. [The Shared Library Problem](#the-shared-library-problem)
3. [Typed vs Unstructured Comparison](#typed-vs-unstructured-comparison)
4. [Why Conversion is Necessary](#why-conversion-is-necessary)
5. [Why Some Representation is Mandatory](#why-some-representation-is-mandatory)
6. [Library Functions Value Proposition](#library-functions-value-proposition)
7. [Design Principles](#design-principles)

---

## Why Unstructured Objects?

This library uses `*unstructured.Unstructured` instead of typed OLM objects (e.g., `*operatorsv1.OperatorGroup`) to avoid vendoring `operator-framework/api` dependencies in library-go.

### The Key Decision

**Question:** Why not use typed objects in library-go?

**Answer:** library-go is a **shared library** used by 50+ OpenShift operator repositories. Only some of these operators use OLM. Using typed objects would force **all** operators to vendor OLM types, even if they never use OLM functionality.

---

## The Shared Library Problem

### Scenario: library-go is Used Everywhere

library-go is imported by many OpenShift operator repositories:
- `cluster-kube-descheduler-operator` (uses OLM)
- `cluster-network-operator` (uses OLM)
- `cluster-authentication-operator` (does NOT use OLM)
- `machine-config-operator` (does NOT use OLM)
- ... and 50+ more

### Option 1: Use Typed Objects (Original PR #2336)

```go
// In library-go:
import operatorsv1 "github.com/operator-framework/api/pkg/operators/v1"

func CreateOperatorGroup(ctx context.Context, client dynamic.Interface, og *operatorsv1.OperatorGroup) error {
    unstructuredOG, _ := runtime.DefaultUnstructuredConverter.ToUnstructured(og)
    // ...
}
```

**This requires library-go to vendor operator-framework/api:**
```
vendor/
  github.com/operator-framework/api/
    pkg/operators/v1/
    pkg/operators/v1alpha1/
    ... 5,600+ lines of code
```

**Impact:**
- ✅ Type-safe API in library-go
- ❌ **ALL** operators using library-go now vendor OLM types (even if they don't use OLM!)
- ❌ Larger binary sizes for everyone
- ❌ Dependency bloat
- ❌ Potential version conflicts

**Example - Operator that doesn't use OLM:**
```
cluster-authentication-operator/
  ├── Does NOT use OLM
  └── vendor/
      ├── github.com/openshift/library-go/  ← Uses library-go
      └── github.com/operator-framework/api/ ← FORCED to vendor this! ❌
```

### Option 2: Use Unstructured Objects (Current Approach)

```go
// In library-go:
func CreateOperatorGroup(ctx context.Context, client dynamic.Interface, og *unstructured.Unstructured) error {
    // No OLM type imports needed!
}
```

**library-go vendors NO OLM types:**
```
vendor/
  # No operator-framework/api!
  # Only standard k8s libraries (already present)
```

**Impact:**
- ✅ **ZERO** OLM dependencies in library-go
- ✅ Operators that don't use OLM = no OLM code in their binaries
- ✅ Operators that DO use OLM = vendor only what they need
- ⚠️ Less type safety in library-go (but still type-safe in operator repos!)

**Example - Operator that doesn't use OLM:**
```
cluster-authentication-operator/
  ├── Does NOT use OLM
  └── vendor/
      └── github.com/openshift/library-go/  ← Clean! No OLM types! ✅
```

**Example - Operator that DOES use OLM:**
```
cluster-kube-descheduler-operator/
  ├── Uses OLM
  └── vendor/
      ├── github.com/openshift/library-go/
      └── github.com/operator-framework/api/  ← Only THIS operator vendors it ✅
```

---

## Typed vs Unstructured Comparison

### How Operators Use This Library

**In operator repos that use OLM:**

```go
import (
    operatorsv1 "github.com/operator-framework/api/pkg/operators/v1"
    "github.com/openshift/library-go/test/library/olm"
    "k8s.io/apimachinery/pkg/runtime"
    "k8s.io/apimachinery/pkg/apis/meta/v1/unstructured"
)

// 1. Build with type safety (typed API)
og := &operatorsv1.OperatorGroup{
    ObjectMeta: metav1.ObjectMeta{
        Name:      "my-group",
        Namespace: "my-namespace",
    },
    Spec: operatorsv1.OperatorGroupSpec{
        TargetNamespaces: []string{"my-namespace"},
    },
}

// 2. Convert to unstructured (one-time conversion)
unstructuredOG, err := runtime.DefaultUnstructuredConverter.ToUnstructured(og)
if err != nil {
    return err
}

// 3. Pass to library-go helper
err = olm.CreateOperatorGroup(ctx, client, &unstructured.Unstructured{Object: unstructuredOG})
```

**Benefits:**
- ✅ Full type safety during construction (IDE autocomplete, compile-time validation)
- ✅ Only vendor OLM types in repos that need them
- ✅ library-go stays lightweight
- ⚠️ One-line conversion required

### What is `unstructured.Unstructured`?

It's a generic map-based representation:

```go
type Unstructured struct {
    Object map[string]interface{}
}
```

**Example:**
```go
&unstructured.Unstructured{
    Object: map[string]interface{}{
        "apiVersion": "operators.coreos.com/v1",
        "kind":       "OperatorGroup",
        "metadata": map[string]interface{}{
            "name":      "my-og",
            "namespace": "my-ns",
        },
        "spec": map[string]interface{}{
            "targetNamespaces": []string{"my-ns"},
        },
    },
}
```

**Why it works:**
- Part of `k8s.io/apimachinery` (library-go already vendors this!)
- Works with dynamic client (what we're using)
- No OLM-specific types needed

---

## Why Conversion is Necessary

### The Root Cause: Dynamic Client API

The library functions use the **dynamic client**:

```go
func CreateOperatorGroup(ctx context.Context, dynamicClient dynamic.Interface, og *unstructured.Unstructured) error {
    dynamicClient.Resource(OperatorGroupGVR()).Namespace(og.GetNamespace()).Create(ctx, og, metav1.CreateOptions{})
    //                                                                            ^^^
    //                                                                     Must be unstructured!
}
```

**The dynamic client's Create method ONLY accepts `*unstructured.Unstructured`:**
```go
Create(ctx context.Context, obj *unstructured.Unstructured, ...) (*unstructured.Unstructured, error)
//                                ^^^^^^^^^^^^^^^^^^^^^^^^
//                                ONLY accepts unstructured!
```

### Why Not Use a Typed OLM Client?

A typed OLM client exists:

```go
import olmclient "github.com/operator-lifecycle-manager/operator-lifecycle-manager/pkg/api/client/clientset/versioned"

olmClient := olmclient.NewForConfig(config)
og := &operatorsv1.OperatorGroup{...}

// No conversion needed! ✅
_, err := olmClient.OperatorsV1().OperatorGroups(ns).Create(ctx, og, metav1.CreateOptions{})
```

**This would be ideal, but it has massive dependencies:**

```
vendor/
  github.com/operator-lifecycle-manager/
    operator-lifecycle-manager/
      pkg/api/client/...
      pkg/controller-runtime/...
      pkg/lib/...
      ... 100+ MB of code!
```

It pulls in:
- All OLM controllers
- Entire controller-runtime framework
- Operator SDK libraries
- OLM reconciliation logic

**For a test helper library, this is overkill.**

### Why Use Dynamic Client?

The dynamic client is **lightweight**:

```go
import "k8s.io/client-go/dynamic"
```

- ✅ Part of standard Kubernetes client-go library
- ✅ Every operator already has it
- ✅ Zero extra dependencies
- ✅ Works with ANY Kubernetes resource
- ❌ Only accepts unstructured objects

### Where Does the Conversion Happen?

**The conversion MUST happen somewhere** because:
- Developers write: typed objects (with IDE help, validation)
- Dynamic client needs: unstructured objects

**Choice A: Convert in library-go** (bloats library-go with OLM types)
**Choice B: Convert in operator repo** (keeps library-go lightweight) ✅

We chose **Option B**.

---

## Why Some Representation is Mandatory

### The Fundamental Question

**Q:** Can we avoid both typed and unstructured representations?

**A:** No. When you do CRUD operations, you're **sending/receiving data** to/from the Kubernetes API server. That data needs to be **represented in your Go code somehow**.

### Your Only Choices

All Kubernetes client libraries require one of these representations:

#### **Option 1: Typed Objects**
```go
og := &operatorsv1.OperatorGroup{
    ObjectMeta: metav1.ObjectMeta{
        Name: "my-og",
        Namespace: "my-ns",
    },
    Spec: operatorsv1.OperatorGroupSpec{
        TargetNamespaces: []string{"my-ns"},
    },
}
// Typed struct in memory
```

#### **Option 2: Unstructured Objects**
```go
og := &unstructured.Unstructured{
    Object: map[string]interface{}{
        "apiVersion": "operators.coreos.com/v1",
        "kind": "OperatorGroup",
        "metadata": map[string]interface{}{
            "name": "my-og",
            "namespace": "my-ns",
        },
        "spec": map[string]interface{}{
            "targetNamespaces": []string{"my-ns"},
        },
    },
}
// Map in memory
```

#### **Option 3: Raw JSON/YAML**
```go
jsonBytes := []byte(`{
    "apiVersion": "operators.coreos.com/v1",
    "kind": "OperatorGroup",
    "metadata": {
        "name": "my-og",
        "namespace": "my-ns"
    },
    "spec": {
        "targetNamespaces": ["my-ns"]
    }
}`)
// Raw bytes in memory
```

### What Kubernetes Client Libraries Accept

#### **Typed Client (clientset)**
```go
import corev1client "k8s.io/client-go/kubernetes/typed/core/v1"

client := corev1client.NewForConfig(config)
pod := &corev1.Pod{...}  // ← MUST be typed struct

client.Pods(ns).Create(ctx, pod, metav1.CreateOptions{})
```

#### **Dynamic Client**
```go
import "k8s.io/client-go/dynamic"

client := dynamic.NewForConfig(config)
obj := &unstructured.Unstructured{...}  // ← MUST be unstructured

client.Resource(gvr).Namespace(ns).Create(ctx, obj, metav1.CreateOptions{})
```

#### **REST Client (raw HTTP)**
```go
import "k8s.io/client-go/rest"

client := rest.NewRESTClient(...)
jsonBytes := []byte(`{...}`)  // ← Raw JSON bytes

result := client.Post().
    Resource("operatorgroups").
    Namespace(ns).
    Body(jsonBytes).
    Do(ctx)
```

### Why Is This Mandatory?

The Kubernetes API server expects:
1. **Structured data** (JSON/YAML with specific fields)
2. **With metadata** (apiVersion, kind, metadata, spec, etc.)

You **must** construct this data somehow in your Go code. The question is just **which representation** you choose.

### Analogy

Think of it like sending a letter:

- **Typed objects** = Fill out a pre-printed form (fields are defined, compiler validates)
- **Unstructured objects** = Blank paper (you write JSON structure yourself, runtime validates)
- **Raw bytes** = Write the raw envelope bytes (you handle everything manually)

But you **must choose one**. You can't just say "send this concept of an OperatorGroup" without representing it somehow.

---

## Library Functions Value Proposition

### Why Use These Helpers?

This is a **test library** (`test/library/olm/`). These helpers are designed for **common test setup/teardown** across multiple operator repositories.

### Value by Function Category

#### **1. Simple CRUD Helpers - MINIMAL but Useful**

**Functions:** `CreateOperatorGroup`, `CreateSubscription`

What they provide:
- ✅ Pre-defined GVRs (don't hardcode strings)
- ✅ Standard error wrapping
- ✅ Consistency across test suites

**Without library:**
```go
_, err := dynamicClient.Resource(schema.GroupVersionResource{
    Group: "operators.coreos.com", 
    Version: "v1", 
    Resource: "operatorgroups",
}).Namespace(ns).Create(ctx, og, metav1.CreateOptions{})
```

**With library:**
```go
err := olm.CreateOperatorGroup(ctx, dynamicClient, og)
```

**Verdict:** Useful for consistency and convenience.

#### **2. Delete Helpers - HIGH Value**

**Functions:** `DeleteOperatorGroup`, `DeleteSubscription`

What they provide:
- ✅ NotFound handling (idempotent deletes)
- ✅ **Polling until deletion completes** ← Critical for tests!

**Why this matters:**

Kubernetes deletions are asynchronous. The Delete API call returns immediately, but the resource might not be fully removed yet (finalizers, garbage collection). Tests need to wait for actual deletion to prevent flaky tests.

**Without library:**
```go
// Delete
err := client.Resource(gvr).Namespace(ns).Delete(ctx, name, metav1.DeleteOptions{})
if err != nil && !apierrors.IsNotFound(err) {
    return err
}

// Manually poll for deletion
err = wait.PollUntilContextCancel(ctx, 1*time.Second, true, func(ctx context.Context) (bool, error) {
    _, err := client.Resource(gvr).Namespace(ns).Get(ctx, name, metav1.GetOptions{})
    if apierrors.IsNotFound(err) {
        return true, nil
    }
    if err != nil {
        return false, err
    }
    return false, nil
})
```

**With library:**
```go
err := olm.DeleteOperatorGroup(ctx, dynamicClient, og)
// Automatically polls until fully deleted!
```

**Verdict:** High value - prevents boilerplate and test flakiness.

#### **3. Complex Helpers - VERY HIGH Value**

**Function:** `BuildSubscriptionFromPackageManifest`

- 70+ lines of complex logic
- Extracts catalogSource, defaultChannel, currentCSV from PackageManifest
- Handles edge cases and validation
- Builds a valid Subscription object

**Function:** `GetTheLatestCSVName`

- Semver version comparison across multiple CSVs
- Fallback logic when versions are invalid
- Selects highest version

**Verdict:** Definitely use these - you don't want to reimplement this logic in every operator.

#### **4. Utility Helpers - MODERATE Value**

**Function:** `CatalogSourceExists`

- Simple validation check
- Provides clear error messages

**Function:** `GetCSVRelatedImages`

- Extracts related images from CSV
- Handles missing relatedImages gracefully

**Verdict:** Useful for common test scenarios.

### Overall Value: Common Test Setup

**Typical test pattern:**
```go
func TestOperatorInstallation(t *testing.T) {
    // Setup
    olm.CreateOperatorGroup(ctx, client, og)
    olm.CreateSubscription(ctx, client, sub)
    
    // Wait for CSV
    csvName, err := olm.GetTheLatestCSVName(ctx, client, ns, labelSelector)
    // ... poll CSV to Succeeded state (custom logic)
    
    // Test logic...
    
    // Cleanup
    olm.DeleteSubscription(ctx, client, sub)  // ← Polls until deleted!
    olm.DeleteOperatorGroup(ctx, client, og)  // ← Polls until deleted!
}
```

**Benefits:**
- ✅ Standard setup/teardown patterns across all operator tests
- ✅ Clean test code (less boilerplate)
- ✅ Reliable cleanup (delete polling prevents flaky tests)
- ✅ Shared complex logic (no reimplementation)
- ✅ Consistency across 50+ operator repos

---

## Design Principles

### 1. **Lightweight Dependencies**

library-go should not impose heavy dependencies on all consumers.

- ✅ Use standard k8s libraries (client-go, apimachinery)
- ❌ Avoid vendoring OLM-specific types
- ❌ Avoid vendoring heavy OLM clients

### 2. **Type Safety Where It Matters**

Operator repositories (where business logic lives) should have full type safety.

- ✅ Operators use typed OLM objects during construction
- ✅ IDE autocomplete and compile-time validation
- ⚠️ Library helpers use unstructured (acceptable tradeoff)

### 3. **Separation of Concerns**

Each repository manages its own dependencies.

- ✅ Operators that use OLM vendor OLM types
- ✅ Operators that don't use OLM = zero OLM dependencies
- ✅ library-go provides building blocks, not full solutions

### 4. **Test-Focused Design**

This is a test library - optimized for test clarity and reliability.

- ✅ Reliable cleanup (delete polling)
- ✅ Clear error messages
- ✅ Reduced boilerplate
- ✅ Shared complex logic

### 5. **Caller Control**

Library provides helpers, not constraints.

- ✅ Callers control timeouts via context
- ✅ No hardcoded polling intervals or timeouts
- ✅ Callers can skip helpers and use dynamic client directly

---

## Summary

**Why unstructured objects?**
- To avoid vendoring OLM types in library-go, keeping it lightweight for all consumers.

**Why is conversion necessary?**
- The dynamic client API only accepts unstructured objects.

**Why not use a typed OLM client?**
- It has 100+ MB of dependencies we don't want in a test library.

**Why use these library functions?**
- Common test setup/teardown across 50+ operator repositories.
- Delete polling prevents flaky tests.
- Shared complex logic (BuildSubscriptionFromPackageManifest, GetTheLatestCSVName).

**The tradeoff:**
- One-line conversion in operator repos → Lightweight shared library for everyone.

This design maximizes value for the OpenShift operator ecosystem while keeping library-go lean and focused.
