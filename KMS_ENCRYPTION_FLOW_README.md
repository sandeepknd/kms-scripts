# Understanding KMS Encryption Flow in OpenShift

## Table of Contents
- [Overview](#overview)
- [Encryption Architecture](#encryption-architecture)
- [Encryption Flow](#encryption-flow)
- [Data Structure in etcd](#data-structure-in-etcd)
- [Finding the Encrypted DEK](#finding-the-encrypted-dek)
- [Practical Examples](#practical-examples)
- [Security Considerations](#security-considerations)

---

## Overview

OpenShift/Kubernetes uses **envelope encryption** with KMS (Key Management Service) to secure secrets at rest in etcd. This involves two layers of encryption:

1. **Data Encryption Key (DEK)**: Encrypts the actual secret data
2. **Key Encryption Key (KEK)**: Encrypts the DEK (stored in external KMS like Vault)

This approach provides enhanced security by separating data encryption from key management.

---

## Encryption Architecture

```
┌─────────────────────────────────────────────────────────────────┐
│                      Envelope Encryption                        │
└─────────────────────────────────────────────────────────────────┘

   Secret Data                    DEK                    KEK
       │                           │                      │
       │                           │                      │
       v                           v                      v
   ┌────────┐                 ┌────────┐            ┌──────────┐
   │  user  │                 │ Random │            │  Vault   │
   │  data  │                 │32 bytes│            │kms-key   │
   └────────┘                 │ AES-256│            │(transit) │
       │                      └────────┘            └──────────┘
       │                           │                      │
       │                           │                      │
       v                           v                      v
   [Encrypt with DEK]         [Encrypt with KEK]    [Never leaves
       │                           │                  Vault]
       │                           │                      │
       v                           v                      │
┌──────────────┐           ┌──────────────┐              │
│  Encrypted   │           │  Encrypted   │              │
│    Data      │    +      │     DEK      │ ────────────┘
└──────────────┘           └──────────────┘
       │                           │
       └────────────┬──────────────┘
                    │
                    v
            ┌───────────────┐
            │  Stored in    │
            │     etcd      │
            └───────────────┘
```

---

## Encryption Flow

### During Encryption (Write Operation)

When you create a secret in OpenShift:

```
1. User creates secret
      ↓
2. kube-apiserver generates random DEK (32 bytes)
      ↓
3. kube-apiserver encrypts secret data with DEK (AES-256-GCM)
      ↓
4. kube-apiserver sends DEK to KMS plugin via gRPC
      ↓
5. KMS plugin forwards DEK to Vault Transit API
      ↓
6. Vault encrypts DEK with KEK (kms-key)
      ↓
7. Vault returns encrypted DEK (format: vault:v1:...)
      ↓
8. KMS plugin returns encrypted DEK to kube-apiserver
      ↓
9. kube-apiserver stores in etcd:
   - Encrypted secret data
   - Encrypted DEK
   - KMS metadata (annotations)
      ↓
10. DEK is discarded from memory (never persisted in plaintext)
```

### During Decryption (Read Operation)

When you read a secret from OpenShift:

```
1. User requests secret
      ↓
2. kube-apiserver reads encrypted data from etcd
      ↓
3. kube-apiserver extracts encrypted DEK
      ↓
4. kube-apiserver sends encrypted DEK to KMS plugin
      ↓
5. KMS plugin forwards to Vault Transit API
      ↓
6. Vault decrypts DEK with KEK (kms-key)
      ↓
7. Vault returns plaintext DEK
      ↓
8. KMS plugin returns plaintext DEK to kube-apiserver
      ↓
9. kube-apiserver decrypts secret data with DEK
      ↓
10. kube-apiserver returns secret to user
      ↓
11. DEK is discarded from memory
```

### Key Points

- **DEK Lifetime**: Exists only in memory during encryption/decryption operations
- **KEK Location**: Never leaves the Vault server
- **Storage**: Only encrypted DEK is stored in etcd
- **Rotation**: KEK rotation doesn't require re-encrypting all secrets (only DEKs need re-encryption)

---

## Data Structure in etcd

### KMS v2 Encrypted Secret Format

The data stored in etcd for a KMS-encrypted secret follows this structure:

```
┌─────────────────────────────────────────────────────────┐
│  k8s:enc:kms:v2:1_secrets:                              │  ← Header
├─────────────────────────────────────────────────────────┤
│  [Protobuf Field 1: Encrypted Secret Payload]          │
│  - Length: Variable (depends on secret size)            │
│  - Format: Binary encrypted data                        │
├─────────────────────────────────────────────────────────┤
│  [Protobuf Field 2: Annotations/Metadata]               │
│  - Base64 encoded                                       │
│  - Contains:                                            │
│    * KMS provider info (admin)                          │
│    * Vault endpoint URL                                 │
│    * Transit mount path                                 │
│    * Key name (kms-key)                                 │
├─────────────────────────────────────────────────────────┤
│  [Protobuf Field 3: Encrypted DEK]                      │
│  - Length: 89 bytes (for Vault)                         │
│  - Format: vault:v1:<base64-ciphertext>                 │
└─────────────────────────────────────────────────────────┘
```

### Protobuf Wire Format

The data uses Protocol Buffers encoding:

```
Byte Offset   Value    Meaning
───────────────────────────────────────────────────
0x0000        k8s:enc:kms:v2:1_secrets:  (Header string)
0x0019        0x0a     Protobuf field 1 (wire type 2: length-delimited)
0x001a        0xad02   Length of encrypted payload (429 bytes)
...           ...      Encrypted secret data
0x014c        0x12     Protobuf field 2 (annotations)
...           ...      Base64 encoded metadata
0x01f8        0x1a     Protobuf field 3 (encrypted DEK)
0x01f9        0x59     Length = 89 bytes
0x01fa        vault:v1:DHVdt1MYU4Awb...  (Encrypted DEK)
```

### Example Encrypted DEK

```
vault:v1:DHVdt1MYU4AwbPrlvzQUiSCapGcaZW2Izvv7mqGFNuX2DEpeAfyPSOFvRFceXWhvPzBUj+brSNXv/3/M
│      │  │
│      │  └─ Base64-encoded ciphertext (DEK encrypted by Vault)
│      └──── Vault transit encryption version
└─────────── Vault identifier
```

---

## Finding the Encrypted DEK

### Prerequisites

- Access to OpenShift cluster
- KMS encryption enabled
- A test secret created

### Step 1: Create a Test Secret

```bash
oc create namespace test
oc create secret generic mysecret1 -n test --from-literal=password=supersecret
```

### Step 2: Access etcd

Get a shell into an etcd pod:

```bash
oc rsh -n openshift-etcd etcd-<master-node-name>
```

### Step 3: Read Encrypted Secret from etcd

```bash
etcdctl get /kubernetes.io/secrets/test/mysecret1 --print-value-only > /tmp/secret.bin
```

### Step 4: Analyze the Binary Structure

View the hex dump:

```bash
xxd /tmp/secret.bin | head -30
```

Expected output:
```
00000000: 6b38 733a 656e 633a 6b6d 733a 7632 3a31  k8s:enc:kms:v2:1
00000010: 5f73 6563 7265 7473 3a0a ad02 3963 80cf  _secrets:...9c..
...
```

### Step 5: Search for Vault Marker

```bash
grep -abo "vault:" /tmp/secret.bin
```

Output:
```
506:vault:
```

This tells you the encrypted DEK starts at byte offset 506.

### Step 6: Extract the Encrypted DEK

```bash
# Extract from offset 506, take 89 bytes
tail -c +507 /tmp/secret.bin | head -c 89
```

Output:
```
vault:v1:DHVdt1MYU4AwbPrlvzQUiSCapGcaZW2Izvv7mqGFNuX2DEpeAfyPSOFvRFceXWhvPzBUj+brSNXv/3/M
```

### Step 7: View the Complete Structure

```bash
# View entire encrypted secret in hex
xxd /tmp/secret.bin

# Extract readable strings
strings /tmp/secret.bin

# Decode base64 annotations
cat /tmp/secret.bin | strings | grep "^AnYx" | base64 -d | strings
```

---

## Practical Examples

### Example 1: Complete Extraction Script

Create a script to extract and analyze encrypted secrets:

```bash
#!/bin/bash
# extract_encrypted_dek.sh

SECRET_NAMESPACE="test"
SECRET_NAME="mysecret1"
MASTER_NODE="ip-10-0-57-1.us-east-2.compute.internal"

echo "=== Extracting Encrypted DEK ==="

# Get encrypted secret from etcd
oc rsh -n openshift-etcd etcd-${MASTER_NODE} \
  etcdctl get /kubernetes.io/secrets/${SECRET_NAMESPACE}/${SECRET_NAME} \
  --print-value-only > /tmp/encrypted_secret.bin 2>/dev/null

# Find vault: marker offset
OFFSET=$(grep -abo "vault:" /tmp/encrypted_secret.bin | cut -d: -f1)
echo "Encrypted DEK found at offset: $OFFSET"

# Extract encrypted DEK (89 bytes)
ENCRYPTED_DEK=$(tail -c +$((OFFSET+1)) /tmp/encrypted_secret.bin | head -c 89)
echo ""
echo "Encrypted DEK:"
echo "$ENCRYPTED_DEK"
echo ""

# Show hex dump around the DEK
echo "Hex dump of encrypted DEK region:"
xxd /tmp/encrypted_secret.bin | grep -A 5 "vault"

# Extract metadata
echo ""
echo "KMS Metadata:"
strings /tmp/encrypted_secret.bin | grep -E "(https://|transit|kms-key|admin)"
```

### Example 2: Verify KMS Encryption Status

```bash
#!/bin/bash
# verify_kms_encryption.sh

echo "=== KMS Encryption Status ==="

# Check API server encryption type
echo "1. API Server Encryption Type:"
oc get apiserver cluster -o jsonpath='{.spec.encryption.type}'
echo ""

# Check encryption status
echo "2. Encryption Status:"
oc get kubeapiserver -o json | \
  jq -r '.items[0].status.conditions[] | select(.type | contains("Encrypt"))'

# Check KMS plugin pods
echo ""
echo "3. KMS Plugin Pods:"
oc get pods -n openshift-kms-plugin -o wide

# Check recent KMS plugin activity
echo ""
echo "4. Recent KMS Plugin Activity:"
oc logs -n openshift-kms-plugin --tail=10 \
  $(oc get pods -n openshift-kms-plugin -o name | head -1)
```

### Example 3: Analyze Multiple Secrets

```bash
#!/bin/bash
# analyze_multiple_secrets.sh

NAMESPACE="test"

echo "=== Analyzing All Secrets in Namespace: $NAMESPACE ==="

for SECRET in $(oc get secrets -n $NAMESPACE -o name | cut -d/ -f2); do
  echo ""
  echo "Secret: $SECRET"

  # Check if KMS encrypted
  ENCRYPTED=$(oc rsh -n openshift-etcd \
    etcd-ip-10-0-57-1.us-east-2.compute.internal \
    etcdctl get /kubernetes.io/secrets/${NAMESPACE}/${SECRET} \
    --print-value-only 2>/dev/null | grep -c "k8s:enc:kms:v2")

  if [ "$ENCRYPTED" -eq 1 ]; then
    echo "  ✓ KMS Encrypted"
  else
    echo "  ✗ Not KMS Encrypted"
  fi
done
```

---

## Security Considerations

### Best Practices

1. **DEK Security**
   - DEKs are never stored in plaintext
   - DEKs exist only in memory during operations
   - Each secret can have a unique DEK

2. **KEK Security**
   - KEK (kms-key) never leaves Vault
   - All encryption/decryption happens in Vault
   - Vault audit logs track all DEK operations

3. **Network Security**
   - KMS plugin communicates with Vault over TLS
   - Unix socket used for kube-apiserver to KMS plugin communication
   - Socket path: `/var/run/kmsplugin/kms.sock`

4. **Key Rotation**
   - KEK rotation: Update Vault transit key version
   - DEK rotation: Re-encrypt secrets with new DEKs
   - No downtime required during rotation

### Security Architecture

```
┌──────────────────┐
│  kube-apiserver  │
│   (master node)  │
└────────┬─────────┘
         │ Unix Socket
         │ /var/run/kmsplugin/kms.sock
         v
┌──────────────────┐
│   KMS Plugin     │
│  (static pod)    │
└────────┬─────────┘
         │ TLS (port 8200)
         │ mTLS authentication
         v
┌──────────────────┐
│  HashiCorp Vault │
│  Transit Engine  │
│   (kms-key)      │
└──────────────────┘
```

### What's Stored Where

| Component | Stores | In Plaintext? |
|-----------|--------|---------------|
| etcd | Encrypted secret data | No |
| etcd | Encrypted DEK | No |
| etcd | KMS metadata | Yes (URLs, key names) |
| kube-apiserver memory | DEK (temporary) | Yes (during operation) |
| Vault | KEK (kms-key) | Yes (but never exported) |
| KMS plugin | Nothing persistent | N/A |

### Threat Model

**Protected Against:**
- etcd data breach (data is encrypted)
- etcd backup theft (backups are encrypted)
- Offline attacks on etcd data
- Unauthorized access to secrets via etcd

**Requires Additional Protection:**
- kube-apiserver memory dumps (DEK exists in memory)
- Vault compromise (KEK stored in Vault)
- Network traffic interception (use TLS)
- KMS plugin compromise (has Vault credentials)

---

## Verification Commands

### Verify Encryption End-to-End

```bash
# 1. Create test secret
oc create secret generic test-kms -n test --from-literal=data=sensitive

# 2. Verify it's in OpenShift
oc get secret test-kms -n test -o yaml

# 3. Check etcd storage (should see encrypted data)
oc rsh -n openshift-etcd etcd-<master-node> \
  etcdctl get /kubernetes.io/secrets/test/test-kms --print-value-only | \
  head -c 100

# Should show: k8s:enc:kms:v2:1_secrets: followed by binary data

# 4. Check KMS plugin logs
oc logs -n openshift-kms-plugin --tail=5 <kms-pod-name> | grep -i encrypt

# Should show: "level":"info","msg":"encrypt","msg":"Success"
```

### Verify DEK is Never in Plaintext

```bash
# Search etcd for any plaintext occurrence
oc rsh -n openshift-etcd etcd-<master-node> \
  etcdctl get /kubernetes.io/secrets/test/test-kms --print-value-only | \
  strings | grep -i "sensitive"

# Should return nothing (your secret value should not appear)
```

---

## Troubleshooting

### Common Issues

**Issue 1: Encrypted DEK not found**
```bash
# Check if KMS encryption is actually enabled
oc get apiserver cluster -o jsonpath='{.spec.encryption.type}'
# Should return: KMS
```

**Issue 2: Cannot decrypt secrets**
```bash
# Check KMS plugin connectivity
oc logs -n openshift-kms-plugin <pod-name> | grep -i error

# Check Vault connectivity
oc rsh -n openshift-kms-plugin <pod-name>
curl -k https://<vault-url>:8200/v1/sys/health
```

**Issue 3: Partial encryption (some secrets not encrypted)**
```bash
# Check encryption migration status
oc get kubeapiserver -o json | \
  jq '.items[0].status.conditions[] | select(.type=="Encrypted")'
```

---

## References

- [Kubernetes KMS Encryption](https://kubernetes.io/docs/tasks/administer-cluster/kms-provider/)
- [OpenShift Encryption at Rest](https://docs.openshift.com/container-platform/latest/security/encrypting-etcd.html)
- [HashiCorp Vault Transit Secrets Engine](https://developer.hashicorp.com/vault/docs/secrets/transit)
- [Protocol Buffers Encoding](https://protobuf.dev/programming-guides/encoding/)

---

## Summary

KMS encryption in OpenShift provides strong security through envelope encryption:

1. **Two-layer encryption**: DEK encrypts data, KEK encrypts DEK
2. **External key management**: KEK stored in Vault, never in cluster
3. **Ephemeral DEKs**: DEKs exist only in memory during operations
4. **Transparent operation**: Applications don't need to change
5. **Auditable**: All key operations logged in Vault

The encrypted DEK stored in etcd is the critical link that requires both the encrypted data (in etcd) AND access to Vault (for KEK) to decrypt secrets, providing defense in depth.
