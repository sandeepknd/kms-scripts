# Encryption at Rest - Complete Guide

## Table of Contents
- [What is Encryption at Rest?](#what-is-encryption-at-rest)
- [Three States of Data](#three-states-of-data)
- [Why Encryption at Rest Matters](#why-encryption-at-rest-matters)
- [How It Works](#how-it-works)
- [Encryption at Rest in OpenShift/Kubernetes](#encryption-at-rest-in-openshiftkubernetes)
- [Real-World Examples](#real-world-examples)
- [Implementation Methods](#implementation-methods)
- [Comparison Table](#comparison-table)

---

## What is Encryption at Rest?

**Encryption at rest** refers to encrypting data when it is stored on disk or any persistent storage medium, as opposed to when it's being transmitted over a network or being processed in memory.

### Simple Definition

> "Encryption at rest protects your data when it's sitting still - stored on disks, databases, backups, or any storage device."

### Real-World Analogy

Think of it like storing valuables in a safe:

```
┌─────────────────────────────────────────────────────┐
│  Your House = Server/Storage System                 │
│                                                      │
│  ┌──────────────┐         ┌──────────────┐         │
│  │ Documents in │         │ Documents in │         │
│  │   a Drawer   │         │   a Safe     │         │
│  │              │         │              │         │
│  │ (Unencrypted)│         │  (Encrypted) │         │
│  └──────────────┘         └──────────────┘         │
│         ↓                         ↓                 │
│  If thief breaks in:     If thief breaks in:       │
│  Can read everything     Cannot read (needs key)    │
└─────────────────────────────────────────────────────┘
```

Even if someone physically steals the storage device or gains unauthorized access to the file system, they cannot read the data without the encryption key.

---

## Three States of Data

Data exists in three states, each requiring different protection strategies:

### 1. Data at Rest (Stored)

**Location**: Hard drives, SSDs, databases, backups, USB drives, cloud storage

**Example**:
- Secret stored in etcd database
- Files on a laptop hard drive
- Database backup on tape
- S3 bucket objects

**Protection**: Encryption at rest

```
┌─────────────────┐
│  Storage Disk   │
│                 │
│  ┌───────────┐  │
│  │ Encrypted │  │
│  │   Data    │  │  ← Data sitting on disk
│  └───────────┘  │
└─────────────────┘
```

### 2. Data in Transit (Moving)

**Location**: Network cables, WiFi, internet, internal network

**Example**:
- HTTPS web traffic
- Email being sent
- API calls between services
- Data replication between data centers

**Protection**: Encryption in transit (TLS/SSL)

```
Client ──────[Encrypted Tunnel]──────> Server
       (HTTPS, TLS, VPN, etc.)
```

### 3. Data in Use (Processing)

**Location**: RAM, CPU cache, processor registers

**Example**:
- Data being processed by an application
- Query results in memory
- Variables in running programs

**Protection**: Memory encryption, secure enclaves (like Intel SGX)

```
┌─────────────────┐
│   CPU/Memory    │
│                 │
│  Processing...  │  ← Data in RAM while being used
│                 │
└─────────────────┘
```

### Complete Data Lifecycle

```
┌──────────────────────────────────────────────────────────┐
│                    Data Lifecycle                        │
└──────────────────────────────────────────────────────────┘

  [Storage/Disk]  ─────>  [Network]  ─────>  [Memory/CPU]
   (At Rest)            (In Transit)         (In Use)
       │                     │                    │
       ↓                     ↓                    ↓
  Encryption             TLS/SSL            Memory
   at Rest              Encryption         Encryption
```

---

## Why Encryption at Rest Matters

### Threat Scenarios Protected Against

#### 1. Physical Theft

```
Scenario: Laptop stolen from coffee shop
─────────────────────────────────────────
Without Encryption at Rest:
  Thief can mount the hard drive and read all files

With Encryption at Rest:
  Thief sees only encrypted gibberish
  Data remains protected
```

#### 2. Unauthorized Access to Storage

```
Scenario: Hacker gains access to database server
──────────────────────────────────────────────────
Without Encryption at Rest:
  Hacker can read database files directly
  Can copy sensitive data

With Encryption at Rest:
  Database files are encrypted
  Cannot read without encryption keys
  Keys stored separately from data
```

#### 3. Backup Media Exposure

```
Scenario: Backup tape lost during transport
───────────────────────────────────────────
Without Encryption at Rest:
  Anyone who finds the tape can restore and read data

With Encryption at Rest:
  Backup is encrypted
  Cannot restore without encryption key
```

#### 4. Cloud Provider Access

```
Scenario: Cloud storage provider employee access
─────────────────────────────────────────────────
Without Encryption at Rest:
  Provider can potentially read your data

With Encryption at Rest (your own keys):
  Even cloud provider cannot decrypt your data
  You control the encryption keys
```

#### 5. Decommissioned Hardware

```
Scenario: Old server sold or recycled
──────────────────────────────────────
Without Encryption at Rest:
  Data recovery tools can retrieve deleted files

With Encryption at Rest:
  Even recovered files are encrypted
  Data is protected
```

### What It Does NOT Protect Against

Encryption at rest does **NOT** protect against:

1. **Attacks while system is running**: If attacker has access to running system with decrypted data in memory
2. **Application-level vulnerabilities**: SQL injection, code execution, etc.
3. **Compromised encryption keys**: If keys are stolen or exposed
4. **Authorized user misuse**: Users with legitimate access can still read data
5. **Data in transit**: Needs separate TLS/SSL protection

---

## How It Works

### Basic Encryption at Rest Flow

```
┌────────────────────────────────────────────────────────────┐
│                    WRITE OPERATION                         │
└────────────────────────────────────────────────────────────┘

1. Application wants to save data
   Plain text: "password=SuperSecret123"
            ↓
2. Encryption layer intercepts
            ↓
3. Encrypts with encryption key
            ↓
4. Encrypted data written to disk
   Cipher text: "x7k#9$mL@q2pR..."

┌────────────────────────────────────────────────────────────┐
│                    READ OPERATION                          │
└────────────────────────────────────────────────────────────┘

1. Application wants to read data
            ↓
2. Encrypted data read from disk
   Cipher text: "x7k#9$mL@q2pR..."
            ↓
3. Decryption layer intercepts
            ↓
4. Decrypts with encryption key
            ↓
5. Application receives plain text
   Plain text: "password=SuperSecret123"
```

### Where Encryption Happens

There are different layers where encryption at rest can be implemented:

```
┌───────────────────────────────────────────────────────────┐
│                  Application Layer                        │
│  Application encrypts data before saving                  │
│  Example: Application encrypts credit cards               │
└──────────────────┬────────────────────────────────────────┘
                   ↓
┌───────────────────────────────────────────────────────────┐
│                  Database Layer                           │
│  Database handles encryption transparently                │
│  Example: PostgreSQL pgcrypto, MySQL encryption           │
└──────────────────┬────────────────────────────────────────┘
                   ↓
┌───────────────────────────────────────────────────────────┐
│                  File System Layer                        │
│  OS encrypts files automatically                          │
│  Example: LUKS, eCryptfs, EncFS                          │
└──────────────────┬────────────────────────────────────────┘
                   ↓
┌───────────────────────────────────────────────────────────┐
│                  Block/Disk Layer                         │
│  Storage device encrypts sectors                          │
│  Example: Self-encrypting drives, dm-crypt                │
└───────────────────────────────────────────────────────────┘
```

---

## Encryption at Rest in OpenShift/Kubernetes

In the context of what we've been working with, **encryption at rest** specifically refers to encrypting Kubernetes secrets, configmaps, and other resources in the **etcd database**.

### Without Encryption at Rest

```
┌──────────────────────────────────────────────────────────┐
│  Kubernetes Secret                                       │
│  apiVersion: v1                                          │
│  kind: Secret                                            │
│  data:                                                   │
│    password: c3VwZXJzZWNyZXQxMjM=                       │
│              (base64: "supersecret123")                  │
└────────────────────────┬─────────────────────────────────┘
                         ↓
                   Stored in etcd
                         ↓
┌──────────────────────────────────────────────────────────┐
│  etcd database file on disk:                             │
│                                                          │
│  ...supersecret123...                                    │
│                                                          │
│  ⚠️  Anyone with access to etcd disk can read secrets!  │
└──────────────────────────────────────────────────────────┘
```

**Problem**: Base64 is NOT encryption! It's just encoding. Anyone who accesses the etcd disk can decode and read secrets.

### With Encryption at Rest (KMS)

```
┌──────────────────────────────────────────────────────────┐
│  Kubernetes Secret                                       │
│  apiVersion: v1                                          │
│  kind: Secret                                            │
│  data:                                                   │
│    password: c3VwZXJzZWNyZXQxMjM=                       │
└────────────────────────┬─────────────────────────────────┘
                         ↓
              kube-apiserver encrypts
                         ↓
┌──────────────────────────────────────────────────────────┐
│  etcd database file on disk:                             │
│                                                          │
│  k8s:enc:kms:v2:1_secrets:                              │
│  �9c��~J��~�Z�[����+�Y���m�0po�ђ�P�"���R,�...        │
│                                                          │
│  vault:v1:DHVdt1MYU4AwbPrlvzQUiSCapGcaZW2I...           │
│                                                          │
│  ✓ Encrypted! Cannot read without KMS key in Vault      │
└──────────────────────────────────────────────────────────┘
```

### What Gets Encrypted in OpenShift

When you enable KMS encryption at rest, these resources are encrypted in etcd:

| Resource | Encrypted? | Why |
|----------|-----------|-----|
| Secrets | ✓ Yes | Contains passwords, tokens, keys |
| ConfigMaps | ✓ Yes | May contain sensitive configuration |
| Routes (OpenShift) | ✓ Yes | May contain sensitive routing info |
| Other resources | ✗ No | Generally not sensitive |

### Verification: Is My Data Encrypted at Rest?

```bash
# 1. Create a test secret
oc create secret generic test-secret -n default --from-literal=password=MySuperSecret

# 2. Read directly from etcd (requires etcd access)
oc rsh -n openshift-etcd etcd-<master-node> \
  etcdctl get /kubernetes.io/secrets/default/test-secret --print-value-only

# WITHOUT encryption at rest:
# You'll see: MySuperSecret (readable!)

# WITH encryption at rest:
# You'll see: k8s:enc:kms:v2:... (encrypted binary data!)
```

---

## Real-World Examples

### Example 1: Laptop Full-Disk Encryption

**Scenario**: Corporate laptop with BitLocker/FileVault

```
┌────────────────────────────────────────────┐
│  MacBook with FileVault (macOS)            │
│                                            │
│  Entire disk encrypted with AES-256        │
│                                            │
│  ┌──────────────────────────────────┐     │
│  │  /Users/john/documents/secret.pdf│     │
│  │  Encrypted on disk               │     │
│  └──────────────────────────────────┘     │
│                                            │
│  If stolen:                                │
│  ✓ Cannot boot without password            │
│  ✓ Cannot mount disk and read files        │
│  ✓ Data is protected                       │
└────────────────────────────────────────────┘
```

### Example 2: AWS S3 Bucket Encryption

**Scenario**: Customer data in S3

```
Without Encryption at Rest:
────────────────────────────
Upload file → Stored as-is on AWS disks
Problem: AWS employees or attackers could potentially read files

With S3 Server-Side Encryption (SSE-S3):
─────────────────────────────────────────
Upload file → AWS encrypts → Stored encrypted on disks
Benefit: Files encrypted on disk, AWS manages keys

With S3 Server-Side Encryption with KMS (SSE-KMS):
───────────────────────────────────────────────────
Upload file → AWS encrypts with your KMS key → Stored encrypted
Benefit: You control key rotation, access logs, key policies
```

### Example 3: MySQL Database Encryption

**Scenario**: E-commerce database with customer data

```
┌────────────────────────────────────────────────────────┐
│  MySQL Server                                          │
│                                                        │
│  Database: ecommerce                                   │
│  Table: customers                                      │
│  ┌──────────┬─────────────┬──────────────┐           │
│  │  user_id │    name     │ credit_card  │           │
│  ├──────────┼─────────────┼──────────────┤           │
│  │   1001   │  John Doe   │ 4111-1111... │           │
│  └──────────┴─────────────┴──────────────┘           │
│                                                        │
│  On disk (without encryption at rest):                │
│  /var/lib/mysql/ecommerce/customers.ibd               │
│  Contains: "John Doe", "4111-1111..." (readable!)     │
│                                                        │
│  On disk (with encryption at rest):                   │
│  /var/lib/mysql/ecommerce/customers.ibd               │
│  Contains: �x7#K$m@2pR... (encrypted!)                │
└────────────────────────────────────────────────────────┘
```

### Example 4: Kubernetes etcd (What We've Been Working With)

**Scenario**: OpenShift cluster secrets

```
Secret Created:
───────────────
$ oc create secret generic db-password \
  --from-literal=password=ProductionDB123

Journey to Storage:
───────────────────
1. kubectl/oc sends secret to kube-apiserver
2. kube-apiserver generates random 32-byte DEK
3. Encrypts secret data with DEK
4. Sends DEK to KMS plugin (Vault)
5. Vault encrypts DEK with master key
6. Stores in etcd:
   - Encrypted secret data
   - Encrypted DEK

On etcd disk:
─────────────
/var/lib/etcd/member/snap/db
Contains: k8s:enc:kms:v2:... (encrypted!)

If someone steals the etcd disk:
─────────────────────────────────
✗ Cannot read the secret
✗ Cannot decrypt without Vault KEK
✓ Data is protected
```

---

## Implementation Methods

### 1. Application-Level Encryption

**Who does it**: Your application code

**Pros**:
- Full control over encryption
- Can encrypt specific fields
- Works with any storage backend

**Cons**:
- Application must handle key management
- Can't search encrypted data
- More complex code

**Example**:
```python
from cryptography.fernet import Fernet

# Application encrypts before saving
key = Fernet.generate_key()
f = Fernet(key)

credit_card = "4111-1111-1111-1111"
encrypted = f.encrypt(credit_card.encode())

# Save encrypted value to database
db.save(user_id=123, cc=encrypted)
```

### 2. Database-Level Encryption (Transparent Data Encryption - TDE)

**Who does it**: Database management system

**Pros**:
- Transparent to applications
- Database handles encryption/decryption
- Can encrypt entire database or specific tables

**Cons**:
- Database-specific implementation
- Keys must be managed

**Examples**:
- Oracle TDE
- SQL Server TDE
- PostgreSQL pgcrypto
- MongoDB encryption at rest

### 3. Filesystem-Level Encryption

**Who does it**: Operating system

**Pros**:
- Transparent to applications
- Encrypts all files in filesystem
- Easy to implement

**Cons**:
- OS must support it
- Performance overhead

**Examples**:
- Linux: LUKS, dm-crypt, eCryptfs
- macOS: FileVault
- Windows: BitLocker

### 4. Block/Disk-Level Encryption

**Who does it**: Storage layer or hardware

**Pros**:
- Very transparent
- Good performance (hardware acceleration)
- Encrypts everything

**Cons**:
- Less granular control
- Key management critical

**Examples**:
- Self-encrypting drives (SEDs)
- Cloud provider disk encryption (AWS EBS, Azure Disk)
- dm-crypt/LUKS

### 5. Envelope Encryption (KMS)

**Who does it**: External key management service

**Pros**:
- Separation of keys from data
- Centralized key management
- Audit trail
- Key rotation without re-encrypting data

**Cons**:
- Requires external service
- Network dependency for key operations

**Examples**:
- AWS KMS
- Azure Key Vault
- HashiCorp Vault
- Google Cloud KMS

**This is what we use in OpenShift!**

---

## Comparison Table

### Encryption at Rest vs Other Security Measures

| Security Measure | Protects Against | Does NOT Protect Against |
|-----------------|------------------|--------------------------|
| **Encryption at Rest** | Disk theft, unauthorized disk access, backup exposure | Running system attacks, memory dumps, app vulnerabilities |
| **Encryption in Transit (TLS)** | Network eavesdropping, man-in-the-middle | Endpoints being compromised, data at rest |
| **Access Control (RBAC)** | Unauthorized users | Privileged user misuse, disk theft |
| **Firewalls** | Network attacks | Internal threats, stolen disks |
| **Backups** | Data loss | Data theft (unless backups encrypted) |
| **Full Stack** | Most threats | Nothing - comprehensive security |

### Different Encryption at Rest Methods

| Method | Granularity | Transparency | Key Management | Performance |
|--------|-------------|--------------|----------------|-------------|
| **Application-Level** | Per-field | Low (app aware) | Application | Good |
| **Database TDE** | Per-table/DB | High | DB/External | Good |
| **Filesystem** | Per-file/folder | High | OS/External | Medium |
| **Disk-Level** | Entire disk | Very High | Hardware/OS | Excellent |
| **Envelope (KMS)** | Per-object | Medium | External KMS | Good |

---

## OpenShift/Kubernetes Encryption at Rest Summary

### What We've Been Working With

```
┌───────────────────────────────────────────────────────────┐
│  OpenShift Encryption at Rest Architecture                │
└───────────────────────────────────────────────────────────┘

Secret → kube-apiserver → Encrypt with DEK → etcd disk
                ↓
         KMS Plugin (Vault)
                ↓
         Encrypt DEK with KEK
                ↓
         Store encrypted DEK in etcd

Result in etcd:
───────────────
✓ Encrypted secret data (using DEK)
✓ Encrypted DEK (using KEK in Vault)
✓ KEK never leaves Vault

Protection:
───────────
✓ etcd disk theft → cannot decrypt
✓ etcd backup stolen → cannot decrypt
✓ Unauthorized etcd access → cannot decrypt
✓ Need both: encrypted data AND Vault KEK
```

### Key Takeaways

1. **Encryption at Rest = Data encrypted on storage**
2. **Different from encryption in transit (TLS)**
3. **Protects against physical theft and unauthorized disk access**
4. **In Kubernetes: encrypts secrets/configmaps in etcd**
5. **Uses envelope encryption: DEK encrypts data, KEK encrypts DEK**
6. **KEK stored in external KMS (Vault) for better security**

---

## Quick Reference

### When You Need Encryption at Rest

✓ Storing sensitive data (passwords, keys, PII)
✓ Compliance requirements (HIPAA, PCI-DSS, GDPR)
✓ Portable devices (laptops, USB drives)
✓ Cloud storage (don't trust provider fully)
✓ Backups (tape, cloud backup)
✓ Database files with customer data

### When You Might Not Need It

✗ Public data (already publicly available)
✗ Temporary data (cache, session data)
✗ Development/test environments (non-sensitive data)
✗ Performance-critical with non-sensitive data

### Common Encryption at Rest Technologies

**Linux**:
- LUKS (Linux Unified Key Setup)
- dm-crypt
- eCryptfs

**Windows**:
- BitLocker
- EFS (Encrypting File System)

**macOS**:
- FileVault

**Cloud**:
- AWS: EBS encryption, S3 SSE, RDS encryption
- Azure: Disk encryption, Storage Service Encryption
- GCP: Disk encryption, Cloud Storage encryption

**Kubernetes**:
- KMS provider (Vault, AWS KMS, Azure Key Vault)
- EncryptionConfiguration

**Databases**:
- PostgreSQL: pgcrypto, TDE
- MySQL: TDE, encryption at rest
- MongoDB: Encryption at rest
- Oracle: TDE

---

## Conclusion

**Encryption at rest** is a critical security control that protects your data when it's stored on disk. In the context of OpenShift/Kubernetes, it ensures that even if someone gains access to the etcd database disk or backups, they cannot read your secrets without the encryption keys stored in Vault.

Think of it as the last line of defense - even if all other security controls fail, encrypted data remains protected.

```
Defense in Depth:
─────────────────
Firewall → Network Security → Access Control → Encryption in Transit → Encryption at Rest
                                                                              ↑
                                                                    YOU ARE HERE
                                                                    (Last line of defense)
```
