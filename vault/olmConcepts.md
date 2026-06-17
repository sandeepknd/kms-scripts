# OLM Concepts - Descheduler Operator

This document explains Operator Lifecycle Manager (OLM) concepts in the context of the cluster-kube-descheduler-operator.

## Table of Contents

- [Overview](#overview)
- [Core OLM Components](#core-olm-components)
- [Operator vs Operand](#operator-vs-operand)
- [Installation Flow](#installation-flow)
- [Real Examples from Codebase](#real-examples-from-codebase)
- [Component Relationships](#component-relationships)
- [OLM vs Direct Installation](#olm-vs-direct-installation)

---

## Overview

**OLM (Operator Lifecycle Manager)** is a Kubernetes extension that manages the lifecycle of operators:
- Installation
- Upgrades
- Dependency resolution
- RBAC management
- Multi-tenancy

For the descheduler operator, OLM provides production-ready deployment with automatic upgrades via subscription channels.

---

## Core OLM Components

### 1. CatalogSource

**What it is:** A repository of operator bundles (metadata + images)

**Location:** `openshift-marketplace` namespace

**Purpose:** Provides the source of operator metadata and images

```yaml
# Example: redhat-operators catalog
apiVersion: operators.coreos.com/v1alpha1
kind: CatalogSource
metadata:
  name: redhat-operators
  namespace: openshift-marketplace
spec:
  sourceType: grpc
  image: registry.redhat.io/redhat/redhat-operator-index:v4.16
  displayName: Red Hat Operators
  publisher: Red Hat
```

**For custom catalog (from README.md:84-91):**
```yaml
apiVersion: operators.coreos.com/v1alpha1
kind: CatalogSource
metadata:
  name: cluster-kube-descheduler-operator
  namespace: openshift-marketplace
spec:
  sourceType: grpc
  image: quay.io/${QUAY_USER}/cluster-kube-descheduler-operator-index:${IMAGE_TAG}
```

**In test code:** `descheduler_utils.go:199-216`
```go
func (sub *subscription) skipMissingCatalogsources(ctx context.Context, dynamicClient dynamic.Interface) error {
    // Checks if catalog source exists before creating subscription
    _, err := dynamicClient.Resource(csGVR).Namespace("openshift-marketplace").Get(ctx, sub.sourceName, metav1.GetOptions{})
    if err != nil {
        return fmt.Errorf("catalog source %s not found in openshift-marketplace: %w", sub.sourceName, err)
    }
    return nil
}
```

---

### 2. OperatorGroup

**What it is:** Defines which namespaces an operator should watch

**API:** `operators.coreos.com/v1`

**Purpose:** Scopes operator permissions and multi-tenancy

```yaml
# From descheduler_utils.go:52-89
apiVersion: operators.coreos.com/v1
kind: OperatorGroup
metadata:
  name: cluster-kube-descheduler-operator
  namespace: openshift-kube-descheduler-operator
spec:
  targetNamespaces:
    - openshift-kube-descheduler-operator
```

**Install modes (from CSV:140-148):**
```yaml
installModes:
  - supported: true
    type: OwnNamespace        # Watches own namespace only
  - supported: true
    type: SingleNamespace     # Watches one specific namespace
  - supported: false
    type: MultiNamespace      # Watches multiple namespaces
  - supported: false
    type: AllNamespaces       # Cluster-wide watch
```

**Key points:**
- Required for operator installation
- Controls RBAC scope
- Descheduler uses `OwnNamespace` mode
- Created in `BeforeAll` setup (test/e2e/otp_suite_test.go)

---

### 3. Subscription

**What it is:** Declares intent to install and auto-update an operator

**API:** `operators.coreos.com/v1alpha1`

**Purpose:** Links CatalogSource to operator installation, manages updates

```yaml
# From descheduler_utils.go:120-168
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: cluster-kube-descheduler-operator
  namespace: openshift-kube-descheduler-operator
spec:
  channel: stable                      # Update channel (stable, fast, candidate)
  installPlanApproval: Automatic       # Auto-approve updates
  name: cluster-kube-descheduler-operator
  source: redhat-operators             # References CatalogSource
  sourceNamespace: openshift-marketplace
  startingCSV: clusterkubedescheduleroperator.v5.4.0  # Optional: pin version
```

**Dynamic discovery (descheduler_utils.go:531-595):**
```go
func packagemanifestKDO(ctx context.Context, dynamicClient dynamic.Interface, packageName, namespace string, catalogNames []string) (*subscription, error) {
    // Fetches channel, source, startingCSV from packagemanifest
    pm, err := dynamicClient.Resource(pmGVR).Namespace(namespace).Get(ctx, packageName, metav1.GetOptions{})
    
    catalogSource, _, _ := unstructured.NestedString(pm.Object, "status", "catalogSource")
    defaultChannel, _, _ := unstructured.NestedString(pm.Object, "status", "defaultChannel")
    
    return &subscription{
        name:        packageName,
        namespace:   namespace,
        channelName: defaultChannel,   // e.g., "stable"
        sourceName:  catalogSource,    // e.g., "redhat-operators"
        startingCSV: startingCSV,      // e.g., "clusterkubedescheduleroperator.v5.4.0"
    }, nil
}
```

---

### 4. InstallPlan

**What it is:** Auto-generated execution plan for operator installation

**API:** `operators.coreos.com/v1alpha1`

**Purpose:** Lists resources to install (CSV, CRDs, deployments)

**NOT created manually** - OLM generates it after processing Subscription

```yaml
# Example InstallPlan (auto-generated by OLM)
apiVersion: operators.coreos.com/v1alpha1
kind: InstallPlan
metadata:
  name: install-abc123
  namespace: openshift-kube-descheduler-operator
spec:
  approval: Automatic  # From Subscription.spec.installPlanApproval
  approved: true
  clusterServiceVersionNames:
    - clusterkubedescheduleroperator.v5.4.0
status:
  phase: Complete  # Installing -> Complete
  plan:
    - resolving: clusterkubedescheduleroperator.v5.4.0
      resource:
        kind: ClusterServiceVersion
        manifest: |
          apiVersion: operators.coreos.com/v1alpha1
          kind: ClusterServiceVersion
          ...
```

**Approval modes:**
- `Automatic`: OLM auto-approves and installs (used in descheduler)
- `Manual`: Requires human approval via `oc patch installplan`

---

### 5. ClusterServiceVersion (CSV)

**What it is:** Metadata manifest describing the operator

**API:** `operators.coreos.com/v1alpha1`

**Location:** `manifests/cluster-kube-descheduler-operator.clusterserviceversion.yaml`

**Purpose:** The "package.json" for operators - describes everything OLM needs to know

```yaml
# From cluster-kube-descheduler-operator.clusterserviceversion.yaml
apiVersion: operators.coreos.com/v1alpha1
kind: ClusterServiceVersion
metadata:
  name: clusterkubedescheduleroperator.v5.4.0
  namespace: openshift-kube-descheduler-operator
  annotations:
    # Example CR shown in OperatorHub UI
    alm-examples: |
      [
        {
          "apiVersion": "operator.openshift.io/v1",
          "kind": "KubeDescheduler",
          "metadata": {
            "name": "cluster",
            "namespace": "openshift-kube-descheduler-operator"
          },
          "spec": {
            "mode": "Predictive",
            "profiles": ["AffinityAndTaints"]
          }
        }
      ]
    # Upgrade skip range
    olm.skipRange: ">=5.3.0 <5.4.0"
spec:
  # Upgrade path
  replaces: clusterkubedescheduleroperator.v5.3.0
  skips:
    - clusterkubedescheduleroperator.v5.2.0
    - clusterkubedescheduleroperator.v5.3.0
  
  # Version info
  version: 5.4.0
  minKubeVersion: 1.35.0
  
  # Owned CRDs
  customresourcedefinitions:
    owned:
      - kind: KubeDescheduler
        name: kubedeschedulers.operator.openshift.io
        version: v1
  
  # Container images (for disconnected installs)
  relatedImages:
    - name: descheduler-operand
      image: registry-proxy.engineering.redhat.com/rh-osbs/descheduler-rhel-9:latest
    - name: descheduler-operator
      image: registry-proxy.engineering.redhat.com/rh-osbs/kube-descheduler-operator-rhel-9:latest
  
  # Installation spec
  install:
    spec:
      # RBAC permissions
      clusterPermissions:
        - serviceAccountName: openshift-descheduler
          rules:
            - apiGroups: [""]
              resources: ["pods/eviction"]
              verbs: ["create"]
      
      # Operator deployment
      deployments:
        - name: cluster-kube-descheduler-operator
          spec:
            replicas: 1
            template:
              spec:
                containers:
                  - name: cluster-kube-descheduler-operator
                    image: registry-proxy.engineering.redhat.com/rh-osbs/kube-descheduler-operator-rhel-9:latest
                    env:
                      - name: OPERAND_IMAGE
                        value: registry-proxy.engineering.redhat.com/rh-osbs/descheduler-rhel-9:latest
```

**CSV testing (descheduler_utils.go:420-489):**
```go
// Get CSV name
func getCSVName(ctx context.Context, dynamicClient dynamic.Interface, namespace, labelSelector string) (string, error) {
    csvList, err := dynamicClient.Resource(csvGVR).Namespace(namespace).List(ctx, metav1.ListOptions{
        LabelSelector: labelSelector,
    })
    csvName := csvList.Items[0].GetName()
    return csvName, nil
}

// Get relatedImages from CSV
func getCSVRelatedImages(ctx context.Context, dynamicClient dynamic.Interface, namespace, csvName string) ([]RelatedImage, error) {
    csvUnstructured, err := dynamicClient.Resource(csvGVR).Namespace(namespace).Get(ctx, csvName, metav1.GetOptions{})
    
    relatedImages, found, err := unstructured.NestedSlice(csvUnstructured.Object, "spec", "relatedImages")
    if !found {
        return nil, fmt.Errorf("relatedImages not found in CSV spec")
    }
    
    return images, nil
}

// Wait for CSV to succeed
func waitForCSVSucceeded(ctx context.Context, dynamicClient dynamic.Interface, namespace, csvName string) error {
    return wait.PollUntilContextTimeout(ctx, 10*time.Second, 3*time.Minute, true, func(ctx context.Context) (bool, error) {
        csv, err := dynamicClient.Resource(csvGVR).Namespace(namespace).Get(ctx, csvName, metav1.GetOptions{})
        phase, _, _ := unstructured.NestedString(csv.Object, "status", "phase")
        
        if phase == "Succeeded" {
            return true, nil
        }
        return false, nil
    })
}
```

**CSV phases:**
- `Pending`: Initial state
- `InstallReady`: InstallPlan approved
- `Installing`: Creating resources
- `Succeeded`: Operator running
- `Failed`: Installation error

---

## Operator vs Operand

### The Two-Level Architecture

```
┌─────────────────────────────────────────────────────────────┐
│                         User                                 │
│                           ↓                                  │
│              Creates KubeDescheduler CR                      │
└─────────────────────────────────────────────────────────────┘
                            ↓
┌─────────────────────────────────────────────────────────────┐
│                    OPERATOR (Controller)                     │
│                                                              │
│  Name: cluster-kube-descheduler-operator                    │
│  Image: kube-descheduler-operator-rhel-9:latest             │
│  Location: deploy/05_deployment.yaml                        │
│                                                              │
│  Responsibilities:                                           │
│  - Watch KubeDescheduler CR                                 │
│  - Create/update operand deployment                         │
│  - Manage ConfigMaps, Secrets, RBAC                         │
│  - Report status back to CR                                 │
└─────────────────────────────────────────────────────────────┘
                            ↓
          Creates and manages operand deployment
                            ↓
┌─────────────────────────────────────────────────────────────┐
│                    OPERAND (Workload)                        │
│                                                              │
│  Name: descheduler                                          │
│  Image: descheduler-rhel-9:latest                           │
│  Location: bindata/assets/kube-descheduler/deployment.yaml  │
│                                                              │
│  Responsibilities:                                           │
│  - Evict pods based on policies                             │
│  - Run descheduling strategies                              │
│  - Execute the actual descheduling logic                    │
└─────────────────────────────────────────────────────────────┘
```

### Comparison Table

| Aspect | Operator | Operand |
|--------|----------|---------|
| **What** | Controller/Manager | Actual workload |
| **Image** | `kube-descheduler-operator-rhel-9:latest` | `descheduler-rhel-9:latest` |
| **Deployment** | `deploy/05_deployment.yaml` | `bindata/assets/kube-descheduler/deployment.yaml` |
| **Container** | `cluster-kube-descheduler-operator` | `openshift-descheduler` |
| **Command** | `cluster-kube-descheduler-operator` | `/bin/descheduler` |
| **Watches** | `KubeDescheduler` CR | Nothing (runs descheduling loop) |
| **ServiceAccount** | `openshift-descheduler` | `openshift-descheduler-operand` |
| **Purpose** | Manage lifecycle | Do the work |

### Code Examples

**Operator deployment (deploy/05_deployment.yaml):**
```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: cluster-kube-descheduler-operator
  namespace: openshift-kube-descheduler-operator
spec:
  replicas: 1
  template:
    spec:
      containers:
        - name: cluster-kube-descheduler-operator
          image: quay.io/openshift/origin-cluster-kube-descheduler-operator:latest
          command:
            - cluster-kube-descheduler-operator
            - operator
          env:
            - name: OPERAND_IMAGE
              value: quay.io/openshift/origin-descheduler:latest
```

**Operand deployment (bindata/assets/kube-descheduler/deployment.yaml):**
```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: descheduler
  namespace: openshift-kube-descheduler-operator
spec:
  replicas: 1
  template:
    spec:
      containers:
        - name: openshift-descheduler
          image: ${OPERAND_IMAGE}  # Injected by operator
          command: ["/bin/descheduler"]
          args:
            - --policy-config-file=/policy-dir/policy.yaml
          volumeMounts:
            - mountPath: "/policy-dir"
              name: "policy-volume"
      serviceAccountName: "openshift-descheduler-operand"
```

**Operand RBAC resources:**
- `bindata/assets/kube-descheduler/operandserviceaccount.yaml`
- `bindata/assets/kube-descheduler/operandclusterrole.yaml`
- `bindata/assets/kube-descheduler/operandclusterrolebinding.yaml`

**Operator creates operand (pkg/operator/target_config_reconciler.go):**
```go
// Create operand ServiceAccount
required := resourceread.ReadServiceAccountV1OrDie(bindata.MustAsset("assets/kube-descheduler/operandserviceaccount.yaml"))

// Create operand ClusterRole
required := resourceread.ReadClusterRoleV1OrDie(bindata.MustAsset("assets/kube-descheduler/operandclusterrole.yaml"))

// Create operand ClusterRoleBinding
required := resourceread.ReadClusterRoleBindingV1OrDie(bindata.MustAsset("assets/kube-descheduler/operandclusterrolebinding.yaml"))
```

---

## Installation Flow

### Timeline with OLM (from OLM_VS_DIRECT_INSTALLATION.md)

```
Step 1: Create OperatorGroup
├─ Action: kubectl apply -f operatorgroup.yaml
├─ Time: 5-10 seconds
└─ Result: openshift-kube-descheduler-operator namespace scoped

Step 2: Create Subscription
├─ Action: kubectl apply -f subscription.yaml
├─ Time: 5-10 seconds
└─ Result: Subscription references redhat-operators catalog

Step 3: OLM Processes Subscription
├─ Action: OLM fetches CSV from CatalogSource
├─ Time: 30-60 seconds
├─ Tasks:
│  ├─ Query PackageManifest
│  ├─ Resolve dependencies
│  └─ Pull operator metadata
└─ Result: InstallPlan created

Step 4: InstallPlan Approval
├─ Action: Auto-approved (installPlanApproval: Automatic)
├─ Time: 5-10 seconds
└─ Result: InstallPlan.status.approved = true

Step 5: Deploy Operator
├─ Action: OLM creates resources from CSV
├─ Time: 30-60 seconds
├─ Resources created:
│  ├─ CustomResourceDefinition (kubedeschedulers.operator.openshift.io)
│  ├─ ServiceAccount (openshift-descheduler)
│  ├─ ClusterRole + ClusterRoleBinding
│  └─ Deployment (cluster-kube-descheduler-operator)
└─ Result: Operator pod running

Step 6: CSV Reaches Succeeded
├─ Action: OLM monitors deployment health
├─ Time: 10-20 seconds
├─ Checks:
│  ├─ Deployment ready
│  ├─ CRD established
│  └─ Webhook ready (if any)
└─ Result: CSV.status.phase = "Succeeded"

Step 7: Operator Creates CR
├─ Action: User creates KubeDescheduler CR
├─ Time: 10-20 seconds
└─ Result: Operator reconciles and creates operand

Step 8: Operand Deployment Ready
├─ Action: Operator creates descheduler deployment
├─ Time: 30-60 seconds
├─ Resources created:
│  ├─ ConfigMap (policy.yaml)
│  ├─ ServiceAccount (openshift-descheduler-operand)
│  ├─ ClusterRole + ClusterRoleBinding (operand RBAC)
│  └─ Deployment (descheduler)
└─ Result: Descheduler pod running and evicting pods

───────────────────────────────────────────────
Total: ~2-5 minutes (varies by cluster/network)
```

### Code Flow (test/e2e/otp_suite_test.go)

```go
BeforeAll(func() {
    ctx := context.Background()
    
    // 1. Create namespace
    ns := &corev1.Namespace{
        ObjectMeta: metav1.ObjectMeta{
            Name: operatorNamespace,
        },
    }
    _, err := kubeClient.CoreV1().Namespaces().Create(ctx, ns, metav1.CreateOptions{})
    
    // 2. Create OperatorGroup
    og := &operatorgroup{
        name:      "cluster-kube-descheduler-operator",
        namespace: operatorNamespace,
    }
    err = og.createOperatorGroup(ctx, dynamicClient)
    
    // 3. Get package manifest (dynamic discovery)
    sub, err := packagemanifestKDO(ctx, dynamicClient, packageName, operatorNamespace, catalogNames)
    
    // 4. Create Subscription
    err = sub.createSubscription(ctx, dynamicClient)
    
    // 5. Wait for operator deployment
    err = waitForDeploymentReady(ctx, kubeClient, operatorNamespace, operatorDeploymentName, "1")
    
    // 6. Wait for CSV to succeed
    csvName, err := getCSVName(ctx, dynamicClient, operatorNamespace, csvLabelSelector)
    err = waitForCSVSucceeded(ctx, dynamicClient, operatorNamespace, csvName)
    
    // 7. Wait for operand deployment (descheduler)
    err = waitForDeploymentReady(ctx, kubeClient, operatorNamespace, deschedulerDeploymentName, "1")
})
```

---

## Real Examples from Codebase

### Test Suite Structure (test/e2e/otp_suite_test.go)

```go
var _ = Describe("[OTP][Descheduler] OLM Installation Tests", func() {
    var (
        ctx                     context.Context
        kubeClient             *k8sclient.Clientset
        dynamicClient          dynamic.Interface
        deschClient            *deschclient.Clientset
        operatorNamespace      = "openshift-kube-descheduler-operator"
        packageName            = "cluster-kube-descheduler-operator"
        catalogNames           = []string{"redhat-operators"}
    )
    
    BeforeAll(func() {
        // Install via OLM (OperatorGroup + Subscription)
        // See installation flow above
    })
    
    AfterAll(func() {
        // Cleanup OLM resources
        sub.deleteSubscription(ctx, dynamicClient)
        og.deleteOperatorGroup(ctx, dynamicClient)
        
        // Delete CSV (cascade deletes operator deployment)
        csvName, _ := getCSVName(ctx, dynamicClient, operatorNamespace, csvLabelSelector)
        dynamicClient.Resource(getCSVGVR()).Namespace(operatorNamespace).Delete(ctx, csvName, metav1.DeleteOptions{})
    })
    
    It("OCP-83032 should have relatedImages defined in CSV", func() {
        csvName, err := getCSVName(ctx, dynamicClient, operatorNamespace, csvLabelSelector)
        Expect(err).NotTo(HaveOccurred())
        
        relatedImages, err := getCSVRelatedImages(ctx, dynamicClient, operatorNamespace, csvName)
        Expect(err).NotTo(HaveOccurred())
        Expect(relatedImages).NotTo(BeEmpty())
        
        // Verify operand image exists
        foundOperand := false
        for _, img := range relatedImages {
            if img.Name == "descheduler-operand" {
                foundOperand = true
                Expect(img.Image).To(ContainSubstring("descheduler"))
            }
        }
        Expect(foundOperand).To(BeTrue())
    })
})
```

### Image Sources

**Production (OLM install):**
```yaml
# From CSV relatedImages
descheduler-operand: registry-proxy.engineering.redhat.com/rh-osbs/descheduler-rhel-9:latest
descheduler-operator: registry-proxy.engineering.redhat.com/rh-osbs/kube-descheduler-operator-rhel-9:latest
```

**Development (direct install from test/e2e/operator.go:246-258):**
```go
if os.Getenv("OPERATOR_IMAGE") != "" {
    operator_image = os.Getenv("OPERATOR_IMAGE")
} else {
    // CI build path
    registry := strings.Split(os.Getenv("RELEASE_IMAGE_LATEST"), "/")[0]
    operator_image = registry + "/" + os.Getenv("NAMESPACE") + "/pipeline:cluster-kube-descheduler-operator"
}

if os.Getenv("OPERAND_IMAGE") != "" {
    operand_image = os.Getenv("OPERAND_IMAGE")
} else {
    operand_image = "quay.io/jchaloup/descheduler:v5.3.2-0"  // Default fallback
}
```

---

## Component Relationships

### Dependency Graph

```
CatalogSource (openshift-marketplace)
    │
    ├─ Contains: PackageManifest
    │      │
    │      └─ Defines: Channels, CSVs, Upgrade paths
    │
    └─ Referenced by: Subscription
              │
              ├─ Creates: InstallPlan (auto-generated)
              │      │
              │      └─ Executes: CSV installation
              │             │
              │             ├─ Creates: CRD (KubeDescheduler)
              │             ├─ Creates: RBAC (ServiceAccount, ClusterRole, ClusterRoleBinding)
              │             └─ Creates: Deployment (operator)
              │                    │
              │                    └─ Operator watches: KubeDescheduler CR
              │                           │
              │                           └─ Creates: Operand deployment
              │                                  │
              │                                  └─ Runs: Descheduler workload
              │
              └─ Scoped by: OperatorGroup
                     │
                     └─ Defines: Target namespaces
```

### Namespace Scoping

```
openshift-marketplace
├─ CatalogSource (redhat-operators)
└─ PackageManifest (cluster-kube-descheduler-operator)

openshift-kube-descheduler-operator
├─ OperatorGroup (cluster-kube-descheduler-operator)
├─ Subscription (cluster-kube-descheduler-operator)
├─ InstallPlan (install-xyz123)
├─ ClusterServiceVersion (clusterkubedescheduleroperator.v5.4.0)
├─ Deployment (cluster-kube-descheduler-operator)  ← Operator
├─ Deployment (descheduler)                         ← Operand
├─ KubeDescheduler CR (cluster)
├─ ConfigMap (descheduler policy)
├─ ServiceAccount (openshift-descheduler)          ← Operator SA
└─ ServiceAccount (openshift-descheduler-operand)  ← Operand SA

Cluster-scoped resources
├─ CustomResourceDefinition (kubedeschedulers.operator.openshift.io)
├─ ClusterRole (openshift-descheduler)
├─ ClusterRole (openshift-descheduler-operand)
├─ ClusterRoleBinding (openshift-descheduler)
└─ ClusterRoleBinding (openshift-descheduler-operand)
```

---

## OLM vs Direct Installation

### Comparison Table (from OLM_VS_DIRECT_INSTALLATION.md)

| Aspect | OLM Installation | Direct Installation |
|--------|------------------|---------------------|
| **Time** | 2-5 minutes | 30-60 seconds |
| **Components** | OperatorGroup, Subscription, CSV, InstallPlan, CatalogSource | CRD, Namespace, SA, Deployment |
| **Dependencies** | Requires catalog source (redhat-operators) | Only requires KUBECONFIG |
| **Cleanup** | Delete Subscription, CSV, OperatorGroup | Delete namespace/deployment |
| **Image Source** | From OLM catalog (production images) | From env vars or CI build |
| **Upgrade Path** | Automatic via Subscription channels | Manual (rebuild & redeploy) |
| **RBAC** | Managed by CSV | Manual YAML manifests |
| **Air-gapped** | Supported (relatedImages) | Manual image mirroring |
| **Use Case** | Production, OTP tests | Development, CI |

### When to Use OLM

**Use OLM when:**
- Testing production deployment flow
- Validating CSV metadata (relatedImages, RBAC)
- Testing operator upgrades
- Running OTP (OpenShift Testing Platform) tests
- Simulating customer installation

**Example: OTP test requires OLM**
```go
// test/e2e/otp_suite_test.go
It("OCP-83032 should have relatedImages defined in CSV", func() {
    // This test REQUIRES OLM installation because:
    // 1. CSV only exists with OLM
    // 2. Direct install has no CSV to validate
    // 3. OTP tests validate production behavior
    
    csvName, err := getCSVName(ctx, dynamicClient, operatorNamespace, csvLabelSelector)
    relatedImages, err := getCSVRelatedImages(ctx, dynamicClient, operatorNamespace, csvName)
    Expect(relatedImages).NotTo(BeEmpty())
})
```

### When to Use Direct Installation

**Use direct installation when:**
- Developing operator code locally
- Running unit tests
- CI builds before OLM bundle is ready
- Quick iteration cycles
- Custom operator images needed

**Example: Direct install (test/e2e/operator.go)**
```go
func setupOperator() {
    // 1. Apply CRD
    exec.Command("kubectl", "apply", "-f", "manifests/kube-descheduler-operator.crd.yaml").Run()
    
    // 2. Apply operator deployment with custom images
    operatorYAML := strings.ReplaceAll(deploymentTemplate, "${OPERATOR_IMAGE}", os.Getenv("OPERATOR_IMAGE"))
    operatorYAML = strings.ReplaceAll(operatorYAML, "${OPERAND_IMAGE}", os.Getenv("OPERAND_IMAGE"))
    
    // 3. Apply RBAC
    exec.Command("kubectl", "apply", "-f", "deploy/").Run()
    
    // Total: ~30-60 seconds
}
```

---

## Summary

### OLM Components Quick Reference

| Component | API Group | Namespace | Purpose | Created By |
|-----------|-----------|-----------|---------|------------|
| CatalogSource | `operators.coreos.com/v1alpha1` | `openshift-marketplace` | Operator registry | Admin |
| OperatorGroup | `operators.coreos.com/v1` | Operator namespace | Namespace scoping | User/Test |
| Subscription | `operators.coreos.com/v1alpha1` | Operator namespace | Install request | User/Test |
| InstallPlan | `operators.coreos.com/v1alpha1` | Operator namespace | Execution plan | OLM |
| ClusterServiceVersion | `operators.coreos.com/v1alpha1` | Operator namespace | Operator metadata | OLM |

### Key Takeaways

1. **OLM provides lifecycle management**: Install, upgrade, RBAC, dependencies
2. **CSV is the metadata manifest**: Describes operator, owned CRDs, RBAC, images
3. **Operator manages operand**: Two-level architecture (controller + workload)
4. **Subscription enables auto-updates**: Links to CatalogSource channel
5. **InstallPlan is auto-generated**: No manual creation needed
6. **OLM has overhead**: 2-5 min vs 30-60 sec for direct install
7. **OTP tests require OLM**: Production deployment validation

### Further Reading

- [Operator SDK OLM Integration](https://sdk.operatorframework.io/docs/olm-integration/)
- [OLM Architecture](https://olm.operatorframework.io/docs/concepts/olm-architecture/)
- [CSV Spec](https://olm.operatorframework.io/docs/concepts/crds/clusterserviceversion/)
- [Operator Maturity Model](https://sdk.operatorframework.io/docs/overview/operator-capabilities/)
