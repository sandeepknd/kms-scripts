# Testing Conforma NetworkPolicy RBAC Policy Locally

## Overview

The Conforma policy `olm.required_network_policy_rbac_for_operands` requires operator bundles to declare RBAC permissions for `networking.k8s.io/networkpolicies` with verbs `create`, `delete`, and either `update` or `patch` in their ClusterServiceVersion (CSV).

This guide describes how to test this policy locally against the CSV in this repository.

## Prerequisites

- **Conforma CLI (`ec`)**: Download from [github.com/conforma/cli/releases](https://github.com/conforma/cli/releases)

  ```bash
  curl -L -o ec https://github.com/conforma/cli/releases/latest/download/ec_linux_amd64
  chmod +x ec
  ```

- **Python 3** with `pyyaml`:

  ```bash
  pip install pyyaml
  ```

## Step 1: Generate the Policy Input JSON

The Conforma OLM policy expects input structured as an OCI bundle image (with `input.image.config.Labels` and `input.image.files`), not a raw YAML file. Running `ec validate input` directly against the CSV will not evaluate the OLM rules.

Use the following script to generate the correctly structured input:

```bash
python3 -c "
import yaml, json, sys

with open('manifests/cluster-kube-descheduler-operator.clusterserviceversion.yaml') as f:
    csv = yaml.safe_load(f)

input_data = {
    'image': {
        'config': {
            'Labels': {
                'operators.operatorframework.io.bundle.mediatype.v1': 'registry+v1',
                'operators.operatorframework.io.bundle.manifests.v1': 'manifests/',
                'operators.operatorframework.io.bundle.metadata.v1': 'metadata/',
                'operators.operatorframework.io.bundle.package.v1': 'cluster-kube-descheduler-operator',
                'operators.operatorframework.io.bundle.channels.v1': 'stable',
                'operators.operatorframework.io.bundle.channel.default.v1': 'stable'
            }
        },
        'files': {
            'manifests/cluster-kube-descheduler-operator.clusterserviceversion.yaml': csv
        }
    }
}

json.dump(input_data, sys.stdout, indent=2)
" > /tmp/bundle-input.json
```

## Step 2: Run the Conforma Check

```bash
ec validate input /tmp/bundle-input.json \
  --policy '{sources: [{name: "olm-check", policy: ["git::https://github.com/conforma/policy//policy"], config: {include: ["olm.required_network_policy_rbac_for_operands"]}}]}' \
  --effective-time 2026-08-07 \
  --output yaml \
  --show-successes \
  --info
```

Key flags:

| Flag | Purpose |
|------|---------|
| `config: {include: ["olm.required_network_policy_rbac_for_operands"]}` | Scope to only the NetworkPolicy RBAC rule |
| `--effective-time 2026-08-07` | Simulate the enforcement date (the policy is warning-only until this date) |
| `--show-successes` | Show passing rules in the output (without this, only failures appear) |
| `--info` | Include rule descriptions and solution text |

To run all OLM policies instead of just the NetworkPolicy one, change the include filter:

```bash
config: {include: ["olm.*"]}
```

## Interpreting Results

### Passing (RBAC is present)

```yaml
success-count: 1
successes:
- metadata:
    code: olm.required_network_policy_rbac_for_operands
    title: NetworkPolicy RBAC present in OLM bundle
  msg: Pass
violations: []
warnings: []
```

### Warning (RBAC is missing)

```yaml
success-count: 0
warnings:
- metadata:
    code: olm.required_network_policy_rbac_for_operands
    title: NetworkPolicy RBAC present in OLM bundle
  msg: Operator "cluster-kube-descheduler-operator" version "5.4.0" is missing required
    NetworkPolicy RBAC (networking.k8s.io/networkpolicies with create, delete, and
    update/patch)
```

## Notes

- **Why not validate the raw CSV directly?** The Rego policy (`_csv_manifests` in `olm.rego`) reads from `input.image.config.Labels` and `input.image.files`, which are populated from an OCI bundle image structure. A raw YAML file does not provide this structure, so the rule evaluates vacuously as passing.

- **Effective date**: The policy's enforcement date is `2026-08-07`. Before that date, missing RBAC produces a warning, not a failure. Use `--effective-time` to simulate post-enforcement behavior.

- **Testing against a published bundle image**: If you have access to `registry.redhat.io`, you can test against the actual published bundle image:

  ```bash
  ec validate image \
    --image registry.redhat.io/kube-descheduler-operator/kube-descheduler-operator-bundle@sha256:<digest> \
    --policy '{sources: [{name: "olm-check", policy: ["git::https://github.com/conforma/policy//policy"], config: {include: ["olm.required_network_policy_rbac_for_operands"]}}]}' \
    --effective-time 2026-08-07 \
    --output yaml \
    --show-successes \
    --info
  ```

  This requires authentication: `podman login registry.redhat.io`.
