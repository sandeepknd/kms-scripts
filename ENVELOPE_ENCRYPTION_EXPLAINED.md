# Envelope Encryption in OpenShift KMS

## Table of Contents
- [What is Envelope Encryption?](#what-is-envelope-encryption)
- [The Problem it Solves](#the-problem-it-solves)
- [How Envelope Encryption Works](#how-envelope-encryption-works)
- [OpenShift KMS Implementation](#openshift-kms-implementation)
- [Complete Flow with Examples](#complete-flow-with-examples)
- [Key Rotation](#key-rotation)
- [Security Benefits](#security-benefits)
- [Comparison with Other Methods](#comparison-with-other-methods)

---

## What is Envelope Encryption?

**Envelope encryption** is a cryptographic practice where you encrypt data with a **Data Encryption Key (DEK)**, and then encrypt that DEK with a **Key Encryption Key (KEK)**.

### The Envelope Metaphor

Think of it like a secure mailing system:

```
┌─────────────────────────────────────────────────────────┐
│  Envelope Encryption = "Letter in an Envelope"          │
└─────────────────────────────────────────────────────────┘

1. Write a secret letter (your data)
   ↓
2. Put it in an envelope (encrypt with DEK)
   ↓
3. Lock the envelope with a key (the DEK)
   ↓
4. Put the key in a master safe (encrypt DEK with KEK)
   ↓
5. Mail the locked envelope (store encrypted data)

To open:
1. Get the key from the master safe (decrypt DEK with KEK)
2. Unlock the envelope (decrypt data with DEK)
3. Read the letter (access plaintext data)
```

### Two-Layer Encryption

```
┌──────────────────────────────────────────────────────────┐
│                  Layer 1: Data Encryption                │
│                                                          │
│  Plaintext Data  ─────[DEK]────>  Encrypted Data        │
│  "password123"                    "x7k#9$mL@q2pR..."    │
└──────────────────────────────────────────────────────────┘
                          ↓
┌──────────────────────────────────────────────────────────┐
│                  Layer 2: Key Encryption                 │
│                                                          │
│  DEK (plaintext) ─────[KEK]────>  Encrypted DEK         │
│  32 random bytes                  "vault:v1:DHVdt..."   │
└──────────────────────────────────────────────────────────┘

Result: Both data and key are encrypted!
```

---

## The Problem it Solves

### Problem 1: Key Distribution and Storage

**Without Envelope Encryption:**

```
┌────────────────────────────────────────────────────────┐
│  Direct Encryption (Single Key)                        │
└────────────────────────────────────────────────────────┘

Secret ───[Master Key]───> Encrypted Secret ───> Store in etcd

Problem:
├─ Master key must be available to kube-apiserver
├─ Key stored on disk or in memory
├─ Key stored alongside encrypted data
└─ If master key is compromised, ALL secrets are exposed
```

**With Envelope Encryption:**

```
┌────────────────────────────────────────────────────────┐
│  Envelope Encryption (Two Keys)                        │
└────────────────────────────────────────────────────────┘

Secret ───[DEK]───> Encrypted Secret ───> Store in etcd
                         ↓
DEK ───[KEK in Vault]───> Encrypted DEK ───> Store in etcd

Benefits:
├─ KEK never leaves Vault (secure key management system)
├─ DEK is unique per secret (isolation)
├─ Compromised etcd alone cannot decrypt secrets
└─ Need BOTH encrypted data AND access to Vault
```

### Problem 2: Key Rotation Overhead

**Without Envelope Encryption:**

```
Rotate Master Key:
├─ Read ALL secrets from etcd (1000s of secrets)
├─ Decrypt each with OLD master key
├─ Encrypt each with NEW master key
├─ Write back ALL secrets
└─ Downtime or complex migration required
```

**With Envelope Encryption:**

```
Rotate KEK:
├─ Read all ENCRYPTED DEKs (small, fast)
├─ Decrypt each with OLD KEK
├─ Re-encrypt each with NEW KEK
├─ Write back encrypted DEKs
└─ Secret data itself NEVER needs to be re-encrypted!
```

### Problem 3: Performance and Scalability

**Without Envelope Encryption:**

```
Every secret operation requires:
├─ Call to external KMS
├─ Network latency
└─ KMS rate limits become bottleneck
```

**With Envelope Encryption:**

```
Only DEK operations require KMS:
├─ Encrypt/decrypt small DEK (32 bytes) via KMS
├─ Encrypt/decrypt actual data locally with DEK
└─ Much better performance
```

---

## How Envelope Encryption Works

### Core Components

```
┌─────────────────────────────────────────────────────────┐
│  Three Key Components                                   │
└─────────────────────────────────────────────────────────┘

1. DEK (Data Encryption Key)
   ├─ Type: Symmetric key (AES-256-GCM)
   ├─ Size: 32 bytes (256 bits)
   ├─ Purpose: Encrypt actual secret data
   ├─ Scope: One DEK per secret (or group of secrets)
   ├─ Lifetime: Generated on-demand, exists in memory only
   └─ Storage: NEVER stored in plaintext

2. KEK (Key Encryption Key)
   ├─ Type: Symmetric or asymmetric key
   ├─ Purpose: Encrypt/decrypt DEKs
   ├─ Location: External KMS (Vault, AWS KMS, etc.)
   ├─ Scope: One KEK for all secrets
   └─ Storage: Never leaves KMS

3. Encrypted Data + Encrypted DEK
   ├─ Storage: Both stored together in etcd
   ├─ Format: Protobuf structure
   └─ Security: Useless without KEK from KMS
```

### The Encryption Process

```
┌──────────────────────────────────────────────────────────┐
│  Step-by-Step: Encrypting a Secret                      │
└──────────────────────────────────────────────────────────┘

Step 1: Generate DEK
────────────────────
kube-apiserver generates random 32-byte key
DEK = random_bytes(32)
Example: 0x3a7f2c9e1b4d8f6a... (32 bytes)

Step 2: Encrypt Secret Data with DEK
─────────────────────────────────────
Algorithm: AES-256-GCM
Input: "password=SuperSecret123"
Key: DEK (32 bytes)
Output: Encrypted_Data = AES_Encrypt(secret, DEK)
Result: �x7#K$m@2pR... (binary ciphertext)

Step 3: Send DEK to KMS for Encryption
───────────────────────────────────────
kube-apiserver → KMS Plugin → Vault
Request: "Please encrypt this DEK"
DEK (plaintext): 0x3a7f2c9e1b4d8f6a...

Step 4: KMS Encrypts DEK with KEK
──────────────────────────────────
Vault uses transit key "kms-key" (KEK)
Algorithm: AES-256-GCM in Vault
Input: DEK (32 bytes)
Key: KEK (in Vault, never exported)
Output: Encrypted_DEK
Result: vault:v1:DHVdt1MYU4AwbPrlvzQUi...

Step 5: Store in etcd
──────────────────────
Store together:
├─ Encrypted secret data
├─ Encrypted DEK
├─ KMS metadata (Vault URL, key name)
└─ All in one protobuf message

Step 6: Discard DEK from Memory
────────────────────────────────
Plaintext DEK is NEVER persisted
Immediately removed from kube-apiserver memory
```

### The Decryption Process

```
┌──────────────────────────────────────────────────────────┐
│  Step-by-Step: Decrypting a Secret                      │
└──────────────────────────────────────────────────────────┘

Step 1: Read from etcd
──────────────────────
Retrieve:
├─ Encrypted secret data
└─ Encrypted DEK

Step 2: Send Encrypted DEK to KMS
──────────────────────────────────
kube-apiserver → KMS Plugin → Vault
Request: "Please decrypt this DEK"
Encrypted_DEK: vault:v1:DHVdt1MYU4AwbPrlvzQUi...

Step 3: KMS Decrypts DEK with KEK
──────────────────────────────────
Vault uses KEK "kms-key"
Input: Encrypted_DEK
Key: KEK (in Vault)
Output: DEK (plaintext, 32 bytes)
Returns: 0x3a7f2c9e1b4d8f6a...

Step 4: Decrypt Secret Data with DEK
─────────────────────────────────────
Algorithm: AES-256-GCM
Input: Encrypted_Data (�x7#K$m@2pR...)
Key: DEK (32 bytes)
Output: Plaintext = AES_Decrypt(encrypted_data, DEK)
Result: "password=SuperSecret123"

Step 5: Return to User
──────────────────────
kube-apiserver returns decrypted secret

Step 6: Discard DEK from Memory
────────────────────────────────
Plaintext DEK removed from memory
```

---

## OpenShift KMS Implementation

### Architecture

```
┌────────────────────────────────────────────────────────────────┐
│               OpenShift Envelope Encryption                    │
└────────────────────────────────────────────────────────────────┘

                    ┌──────────────────┐
                    │  User/Application│
                    └────────┬─────────┘
                             │ oc create secret
                             ↓
                    ┌──────────────────┐
                    │  kube-apiserver  │
                    │                  │
                    │  1. Gen DEK      │
                    │  2. Encrypt data │
                    │     with DEK     │
                    └────┬─────────┬───┘
                         │         │
      ┌──────────────────┘         └───────────────┐
      │ Encrypted Data                   DEK       │
      ↓                                     ↓       │
┌──────────┐                    ┌─────────────────┐│
│   etcd   │<───────────────────│   KMS Plugin    ││
│          │  Encrypted DEK     │  (static pod)   ││
│  Stores: │                    └────────┬────────┘│
│  • Data  │                             │         │
│  • DEK   │                             ↓         │
└──────────┘                    ┌─────────────────┐│
                                │  Vault Transit  ││
                                │                 ││
                                │  KEK: kms-key   ││
                                │  (never leaves) ││
                                └─────────────────┘│
                                         ↑          │
                                         └──────────┘
                                      Encrypt DEK
```

### Components in Detail

#### 1. kube-apiserver (DEK Manager)

```
Role: Generate and use DEKs
─────────────────────────────
• Generates random DEK for each write operation
• Encrypts secret data with DEK (local, fast)
• Sends DEK to KMS plugin for encryption
• Stores encrypted data + encrypted DEK in etcd
• On read: retrieves encrypted DEK, sends to KMS for decryption
• Decrypts data with decrypted DEK (local, fast)
• Never persists plaintext DEK

Configuration:
─────────────
/etc/kubernetes/manifests/kube-apiserver-pod.yaml
--encryption-provider-config=/path/to/encryption-config.yaml
```

#### 2. KMS Plugin (Translation Layer)

```
Role: Translate between kube-apiserver and Vault
─────────────────────────────────────────────────
• Runs as static pod on each master node
• Communicates with kube-apiserver via Unix socket
• Translates Kubernetes KMS API to Vault API
• Handles authentication to Vault
• No key storage, pure translation

Location:
─────────
Namespace: openshift-kms-plugin
Pod: vault-kube-kms-<node-name>
Socket: /var/run/kmsplugin/kms.sock

Logs show:
──────────
{"msg":"encrypt","msg":"Success","key_id_hash":"555afb..."}
{"msg":"decrypt","msg":"Success","key_id_hash":"555afb..."}
```

#### 3. HashiCorp Vault (KEK Custodian)

```
Role: Secure key management
───────────────────────────
• Stores KEK (kms-key) in transit engine
• Encrypts DEKs with KEK
• Decrypts DEKs with KEK
• KEK NEVER leaves Vault
• Audit logs all operations
• Supports key rotation

Configuration:
──────────────
Mount: transit
Key: kms-key
URL: https://vault-...cloud:8200
Authentication: Token or AppRole
```

#### 4. etcd (Encrypted Storage)

```
Role: Persistent storage
────────────────────────
Stores in key: /kubernetes.io/secrets/<namespace>/<name>

Value structure (KMS v2):
─────────────────────────
k8s:enc:kms:v2:1_secrets:
├─ Encrypted secret data (large, variable size)
├─ KMS metadata (Vault URL, key name, mount)
└─ Encrypted DEK (89 bytes for Vault)

Security:
─────────
• Data is encrypted
• DEK is encrypted
• BUT: Cannot decrypt without KEK from Vault
```

### Data Flow Diagram

```
┌───────────────────────────────────────────────────────────────┐
│  Write Secret: oc create secret generic db-pass              │
│                --from-literal=password=Secret123              │
└───────────────────────────────────────────────────────────────┘

(1) User Request
    │
    ↓
┌─────────────────────┐
│  kube-apiserver     │
│                     │
│  Generate DEK       │ ← Random 32 bytes
│  0x3a7f2c9e...      │
└──────┬──────────────┘
       │
       ├────────────────────────────────────────────┐
       │                                            │
       │ (2) Encrypt data locally                   │
       │     AES-256-GCM                            │
       │     Input: "password=Secret123"            │
       │     Key: DEK                               │
       │     Output: �x7#K$m@...                    │
       │                                            │
       │                                            │ (3) Encrypt DEK
       │                                            ↓
       │                                ┌────────────────────┐
       │                                │  KMS Plugin        │
       │                                │  /var/run/...sock  │
       │                                └─────────┬──────────┘
       │                                          │ gRPC
       │                                          ↓
       │                                ┌────────────────────┐
       │                                │  Vault Transit     │
       │                                │                    │
       │                                │  Encrypt DEK       │
       │                                │  with KEK          │
       │                                │  (kms-key)         │
       │                                │                    │
       │                                │  Output:           │
       │                                │  vault:v1:DHVd...  │
       │                                └─────────┬──────────┘
       │                                          │
       │                                          │ (4) Return
       │                                          │ Encrypted DEK
       ↓                                          ↓
┌──────────────────────────────────────────────────────────────┐
│  etcd                                                        │
│  /kubernetes.io/secrets/default/db-pass                     │
│                                                              │
│  k8s:enc:kms:v2:1_secrets:                                  │
│  ├─ Encrypted Data: �x7#K$m@...                            │
│  ├─ Metadata: vault URL, transit, kms-key                   │
│  └─ Encrypted DEK: vault:v1:DHVd...                        │
└──────────────────────────────────────────────────────────────┘
```

---

## Complete Flow with Examples

### Example 1: Create and Store a Secret

Let's encrypt a database password.

```bash
# User command
oc create secret generic db-credentials \
  --from-literal=username=admin \
  --from-literal=password=ProductionDB123
```

**Behind the Scenes:**

```
┌────────────────────────────────────────────────────────────┐
│  Phase 1: DEK Generation                                   │
└────────────────────────────────────────────────────────────┘

kube-apiserver:
  - Receives secret creation request
  - Generates random DEK: 0xa7c3f29b8e4d... (32 bytes)
  - DEK exists only in memory

┌────────────────────────────────────────────────────────────┐
│  Phase 2: Encrypt Secret Data with DEK                    │
└────────────────────────────────────────────────────────────┘

kube-apiserver:
  Algorithm: AES-256-GCM
  Input:
    username: admin
    password: ProductionDB123
  Key: DEK (0xa7c3f29b8e4d...)
  Output: Binary encrypted payload
    �x7#K$m@2pR�nT9...

┌────────────────────────────────────────────────────────────┐
│  Phase 3: Encrypt DEK with KEK (Envelope!)                │
└────────────────────────────────────────────────────────────┘

kube-apiserver → KMS Plugin:
  gRPC call: Encrypt(DEK)
  Socket: /var/run/kmsplugin/kms.sock

KMS Plugin → Vault:
  POST /v1/transit/encrypt/kms-key
  Body: {"plaintext": "base64(DEK)"}

Vault:
  - Uses KEK (kms-key) stored in transit engine
  - Encrypts DEK with AES-256-GCM
  - Returns: vault:v1:DHVdt1MYU4AwbPrlvzQUiSCap...

Vault → KMS Plugin → kube-apiserver:
  Returns encrypted DEK

┌────────────────────────────────────────────────────────────┐
│  Phase 4: Store in etcd                                   │
└────────────────────────────────────────────────────────────┘

kube-apiserver → etcd:
  Key: /kubernetes.io/secrets/default/db-credentials
  Value:
    k8s:enc:kms:v2:1_secrets:
    [Protobuf Field 1: Encrypted data (�x7#K$m@...)]
    [Protobuf Field 2: Metadata (Vault URL, key name)]
    [Protobuf Field 3: Encrypted DEK (vault:v1:DHVd...)]

┌────────────────────────────────────────────────────────────┐
│  Phase 5: Cleanup                                         │
└────────────────────────────────────────────────────────────┘

kube-apiserver:
  - Erases plaintext DEK from memory
  - DEK no longer exists anywhere in plaintext
```

### Example 2: Read and Decrypt a Secret

```bash
# User command
oc get secret db-credentials -o yaml
```

**Behind the Scenes:**

```
┌────────────────────────────────────────────────────────────┐
│  Phase 1: Read from etcd                                  │
└────────────────────────────────────────────────────────────┘

kube-apiserver → etcd:
  GET /kubernetes.io/secrets/default/db-credentials

etcd → kube-apiserver:
  Returns:
    - Encrypted data: �x7#K$m@...
    - Encrypted DEK: vault:v1:DHVdt1MYU4Awb...
    - Metadata: vault URL, key name

┌────────────────────────────────────────────────────────────┐
│  Phase 2: Decrypt DEK with KEK (Unwrap Envelope!)        │
└────────────────────────────────────────────────────────────┘

kube-apiserver → KMS Plugin:
  gRPC call: Decrypt(encrypted_DEK)
  Input: vault:v1:DHVdt1MYU4Awb...

KMS Plugin → Vault:
  POST /v1/transit/decrypt/kms-key
  Body: {"ciphertext": "vault:v1:DHVdt..."}

Vault:
  - Uses KEK (kms-key)
  - Decrypts to get plaintext DEK
  - Returns: base64(DEK)

Vault → KMS Plugin → kube-apiserver:
  Returns plaintext DEK: 0xa7c3f29b8e4d...

┌────────────────────────────────────────────────────────────┐
│  Phase 3: Decrypt Secret Data with DEK                   │
└────────────────────────────────────────────────────────────┘

kube-apiserver:
  Algorithm: AES-256-GCM
  Input: �x7#K$m@2pR�nT9...
  Key: DEK (0xa7c3f29b8e4d...)
  Output:
    username: admin
    password: ProductionDB123

┌────────────────────────────────────────────────────────────┐
│  Phase 4: Return to User                                  │
└────────────────────────────────────────────────────────────┘

kube-apiserver → User:
  apiVersion: v1
  kind: Secret
  data:
    username: YWRtaW4=         (base64: admin)
    password: UHJvZHVjdGlvbkRCMTIz  (base64: ProductionDB123)

┌────────────────────────────────────────────────────────────┐
│  Phase 5: Cleanup                                         │
└────────────────────────────────────────────────────────────┘

kube-apiserver:
  - Erases plaintext DEK from memory
  - DEK no longer needed
```

### Example 3: View Encrypted Data in etcd

```bash
# Access etcd pod
oc rsh -n openshift-etcd etcd-ip-10-0-57-1.us-east-2.compute.internal

# Read secret from etcd
etcdctl get /kubernetes.io/secrets/default/db-credentials --print-value-only | xxd | head -40
```

**What You'll See:**

```
00000000: 6b38 733a 656e 633a 6b6d 733a 7632 3a31  k8s:enc:kms:v2:1
00000010: 5f73 6563 7265 7473 3a0a                 _secrets:.
          ↑
          Header identifying KMS v2 encryption

00000020: ad02 3963 80cf 937e 4a09 9a8e 7ecf 5a9c  ..9c...~J...~.Z.
00000030: 5b1b fef6 9e9d 2bd2 59ab a6d3 6d8d 3015  [.....+.Y...m.0.
          ↑
          Encrypted secret data (encrypted with DEK)

...

000001f0: 4c57 746c 6553 6742 1a59 7661 756c 743a  LWtleSgB.Yvault:
00000200: 7631 3a44 4856 6474 314d 5955 3441 7762  v1:DHVdt1MYU4Awb
00000210: 5072 6c76 7a51 5569 5343 6170 4763 615a  PrlvzQUiSCapGcaZ
          ↑
          Encrypted DEK (encrypted with KEK in Vault)
          This is the "envelope" that protects the key!
```

**Key Observation:**
- You can see the encrypted data
- You can see the encrypted DEK (vault:v1:...)
- But you CANNOT decrypt either without the KEK in Vault!

---

## Key Rotation

One of the biggest advantages of envelope encryption is efficient key rotation.

### KEK Rotation (Master Key)

```
┌────────────────────────────────────────────────────────────┐
│  Rotating the KEK in Vault                                 │
└────────────────────────────────────────────────────────────┘

Step 1: Rotate KEK in Vault
───────────────────────────
$ vault write -f transit/keys/kms-key/rotate

Vault:
  - Generates new key version
  - Old version: v1
  - New version: v2
  - Both versions available

Step 2: Configure OpenShift to Use New Key Version
───────────────────────────────────────────────────
Vault automatically uses latest version for encryption
Old versions still available for decryption

Step 3: Re-encrypt DEKs (NOT Secret Data!)
───────────────────────────────────────────
For each secret:
  1. Read encrypted DEK
  2. Decrypt with KEK v1
  3. Re-encrypt with KEK v2
  4. Store new encrypted DEK
  5. Secret data NEVER touched!

Performance:
────────────
✓ Only re-encrypt small DEKs (89 bytes each)
✓ Don't re-encrypt large secret data
✓ Much faster than re-encrypting all secrets
✓ Can be done gradually (rolling re-encryption)
```

### DEK Rotation (Data Keys)

```
┌────────────────────────────────────────────────────────────┐
│  Rotating DEKs                                             │
└────────────────────────────────────────────────────────────┘

Trigger:
────────
Each time a secret is UPDATED, new DEK is generated

Process:
────────
1. User updates secret
2. kube-apiserver generates NEW DEK
3. Encrypts secret data with NEW DEK
4. Sends NEW DEK to Vault for encryption
5. Stores encrypted data + new encrypted DEK
6. Old DEK is discarded

Result:
───────
Secrets get new DEKs automatically on update
No manual rotation needed
```

### Comparison: With vs Without Envelope Encryption

```
┌────────────────────────────────────────────────────────────┐
│  WITHOUT Envelope Encryption (Direct Encryption)          │
└────────────────────────────────────────────────────────────┘

Rotate Master Key:
──────────────────
For 10,000 secrets:
  - Decrypt 10,000 secrets with old key
  - Re-encrypt 10,000 secrets with new key
  - Network calls: 20,000 (decrypt + encrypt)
  - Data transferred: GBs of secret data
  - Time: Hours or days
  - Risk: High (touching all secrets)

┌────────────────────────────────────────────────────────────┐
│  WITH Envelope Encryption                                  │
└────────────────────────────────────────────────────────────┘

Rotate KEK:
───────────
For 10,000 secrets:
  - Decrypt 10,000 DEKs with old KEK
  - Re-encrypt 10,000 DEKs with new KEK
  - Network calls: 20,000 (but for tiny DEKs)
  - Data transferred: MBs (only DEKs)
  - Time: Minutes
  - Risk: Low (secret data untouched)
  - Secret data NEVER decrypted or re-encrypted!
```

---

## Security Benefits

### 1. Separation of Concerns

```
┌────────────────────────────────────────────────────────────┐
│  Different Systems Handle Different Responsibilities      │
└────────────────────────────────────────────────────────────┘

etcd:
  Responsibility: Store encrypted data
  Has: Encrypted data + Encrypted DEK
  Cannot: Decrypt anything (no KEK)
  Risk if compromised: Data is safe

kube-apiserver:
  Responsibility: Manage DEKs, encrypt/decrypt data
  Has: Temporary DEK in memory
  Cannot: Access KEK directly
  Risk if compromised: Only current operations affected

KMS Plugin:
  Responsibility: Translate API calls
  Has: Vault credentials
  Cannot: Store or decrypt keys
  Risk if compromised: Must also compromise Vault

Vault:
  Responsibility: Protect KEK
  Has: KEK (never exported)
  Cannot: Access etcd data
  Risk if compromised: Serious, but requires network access
```

### 2. Defense in Depth

```
Attack Scenario Analysis:
─────────────────────────

Scenario 1: Attacker steals etcd disk
──────────────────────────────────────
Has:
  ✓ Encrypted secret data
  ✓ Encrypted DEK

Needs to decrypt:
  ✗ KEK from Vault (not on disk)

Result: ATTACK FAILS ✓


Scenario 2: Attacker gains read access to etcd
───────────────────────────────────────────────
Has:
  ✓ Encrypted secret data
  ✓ Encrypted DEK

Needs to decrypt:
  ✗ KEK from Vault
  ✗ Network access to Vault
  ✗ Vault authentication

Result: ATTACK FAILS ✓


Scenario 3: Attacker compromises kube-apiserver
────────────────────────────────────────────────
Has:
  ✓ Can trigger decrypt operations
  ✓ Access to Vault via KMS plugin

Can do:
  ✓ Decrypt secrets currently in use
  ✗ Cannot decrypt offline (needs running system)
  ✗ Cannot bulk export (rate limited, audited)

Result: PARTIAL ATTACK, LIMITED DAMAGE
Mitigation: Monitor Vault audit logs


Scenario 4: Attacker needs ALL secrets offline
───────────────────────────────────────────────
Needs:
  ✓ etcd data (encrypted)
  AND ✓ KEK from Vault
  AND ✓ Vault network access
  AND ✓ Vault authentication credentials

Result: REQUIRES MULTIPLE BREACHES
Defense in depth working! ✓
```

### 3. Key Isolation

```
┌────────────────────────────────────────────────────────────┐
│  KEK Never Leaves Vault                                   │
└────────────────────────────────────────────────────────────┘

KEK Location:
  - Stored in Vault's encrypted storage
  - Never transmitted over network
  - Never appears in logs
  - Never in kube-apiserver memory
  - Never in etcd

All operations:
  - Happen INSIDE Vault
  - DEK sent TO Vault
  - Encrypted/decrypted DEK sent BACK
  - KEK stays put

Even Vault admin cannot export KEK:
  - Vault policy prevents export
  - Sealed storage encryption
  - HSM integration possible
```

### 4. Audit Trail

```
┌────────────────────────────────────────────────────────────┐
│  Complete Audit Visibility                                │
└────────────────────────────────────────────────────────────┘

Vault Audit Logs show:
──────────────────────
- Every DEK encryption request
- Every DEK decryption request
- Timestamp of each operation
- Source IP/identity
- Success/failure
- Key version used

Example:
────────
{
  "time": "2026-04-02T10:30:45Z",
  "type": "response",
  "auth": {...},
  "request": {
    "operation": "update",
    "path": "transit/decrypt/kms-key"
  },
  "response": {
    "data": {"plaintext": "..."}
  }
}

Detect anomalies:
─────────────────
- Unusual decrypt volume
- Access from unexpected IPs
- Failed authentication attempts
- Off-hours access
```

### 5. Reduced Blast Radius

```
┌────────────────────────────────────────────────────────────┐
│  Each Secret Has Unique DEK                               │
└────────────────────────────────────────────────────────────┘

Traditional single-key encryption:
──────────────────────────────────
1 master key encrypts ALL secrets
If key leaked → ALL secrets compromised

Envelope encryption:
────────────────────
1000 secrets = 1000 different DEKs
Each DEK encrypted with same KEK
If 1 DEK leaked → Only 1 secret compromised
KEK still safe → Other 999 secrets safe

Benefits:
─────────
✓ Limited impact per DEK compromise
✓ Can rotate individual DEKs
✓ Isolation between secrets
```

---

## Comparison with Other Methods

### Method 1: No Encryption

```
Storage: Plaintext or base64 encoded

Pros:
  ✓ Simple
  ✓ Fast
  ✓ No key management

Cons:
  ✗ Anyone with etcd access can read secrets
  ✗ Disk theft exposes all secrets
  ✗ No compliance support

Security: ⭐☆☆☆☆ (Very Poor)
```

### Method 2: Direct Encryption (Single Key)

```
Storage: Secrets encrypted with one master key

Pros:
  ✓ Data encrypted at rest
  ✓ Simple model

Cons:
  ✗ Master key stored alongside data (typically)
  ✗ Key rotation requires re-encrypting all data
  ✗ Single point of failure
  ✗ Performance bottleneck (all operations hit KMS)

Security: ⭐⭐⭐☆☆ (Medium)
```

### Method 3: Envelope Encryption (What We Use)

```
Storage: Data encrypted with DEK, DEK encrypted with KEK

Pros:
  ✓ Strong security (two layers)
  ✓ KEK isolated in external KMS
  ✓ Fast key rotation (only DEKs)
  ✓ Good performance (local data encryption)
  ✓ Defense in depth
  ✓ Audit trail
  ✓ Compliance friendly

Cons:
  ✗ More complex
  ✗ Requires external KMS
  ✗ Network dependency for DEK operations

Security: ⭐⭐⭐⭐⭐ (Excellent)
```

### Performance Comparison

```
Operation: Create 1 secret with 1KB data
────────────────────────────────────────

No Encryption:
  - Store 1KB in etcd
  - Time: ~5ms
  - Network calls: 1 (to etcd)

Direct Encryption:
  - Send 1KB to KMS for encryption
  - Store encrypted 1KB in etcd
  - Time: ~50ms (network latency to KMS)
  - Network calls: 2 (KMS + etcd)

Envelope Encryption:
  - Encrypt 1KB locally with DEK: ~1ms
  - Send 32-byte DEK to KMS: ~20ms
  - Store encrypted 1KB + encrypted DEK in etcd: ~5ms
  - Total time: ~26ms
  - Network calls: 2 (KMS for DEK + etcd)

For 1000 secrets with 1KB each:
───────────────────────────────
Direct: ~50 seconds (all data through KMS)
Envelope: ~26 seconds (only DEKs through KMS)
```

---

## Summary

### What is Envelope Encryption?

```
Envelope Encryption = Two-layer encryption approach

Layer 1: Encrypt data with DEK (fast, local)
Layer 2: Encrypt DEK with KEK (secure, external KMS)

Result: Data and key both encrypted and separated
```

### Why OpenShift Uses It

```
1. Security
   - KEK never leaves Vault
   - Defense in depth
   - Reduced blast radius

2. Performance
   - Local data encryption (fast)
   - Only DEKs go to KMS (small, fast)

3. Operational
   - Easy key rotation
   - Audit trail
   - Compliance support
```

### The Envelope Analogy

```
Your Secret = Letter
DEK = Envelope lock
KEK = Master safe key

Process:
1. Write letter (your data)
2. Put in locked envelope (encrypt with DEK)
3. Put envelope key in master safe (encrypt DEK with KEK)
4. Mail locked envelope (store encrypted data)
5. Keep master safe key secure (KEK in Vault)

To read:
1. Get envelope key from safe (decrypt DEK with KEK)
2. Unlock envelope (decrypt data with DEK)
3. Read letter
4. Return key to safe (discard DEK)
```

### Key Takeaways

1. **Envelope encryption protects your data with two layers of encryption**
2. **DEK encrypts data (fast, local, unique per secret)**
3. **KEK encrypts DEK (secure, in Vault, shared)**
4. **Both data and DEK are encrypted in etcd**
5. **KEK never leaves Vault - ultimate security**
6. **Enables fast key rotation without re-encrypting data**
7. **Provides defense in depth and audit trail**

This is the foundation of how OpenShift/Kubernetes secures secrets at rest with KMS!
