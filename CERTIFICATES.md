# Vault TLS Certificate Architecture

This document explains the certificate setup for Vault Enterprise running in dev mode with TLS enabled.

## Table of Contents
- [Certificate Types](#certificate-types)
- [What Vault Creates](#what-vault-creates)
- [ConfigMap Contents](#configmap-contents)
- [TLS Handshake Flow](#tls-handshake-flow)
- [File Locations](#file-locations)
- [Trust Model](#trust-model)
- [Common Questions](#common-questions)

## Certificate Types

### Self-Signed Certificate
A certificate where the **issuer equals the subject** (it signs itself):

```
Subject: CN=my-server
Issuer:  CN=my-server   ← Same as subject = self-signed
```

**Use case:** Quick testing, but browsers/clients won't trust it by default.

### CA (Certificate Authority) Certificate
A certificate that **signs other certificates** to establish trust.

Types:
- **Public CA:** DigiCert, Let's Encrypt, VeriSign (trusted by browsers/OS)
- **Private CA:** Your own internal CA (must be distributed to clients)

**Key insight:** A CA certificate can also be self-signed! This is called a **"self-signed root CA"**:

```
Subject: CN=My Root CA
Issuer:  CN=My Root CA   ← Self-signed CA!
```

This is exactly what Vault creates in dev mode.

### Server Certificate
A certificate that proves a server's identity during TLS connections.

```
Subject: CN=vault.vault-kms.svc
Issuer:  CN=Vault CA   ← Signed by a CA
```

**Use case:** Presented by servers (HTTPS websites, Vault API) during TLS handshake.

### Client Certificate
A certificate that proves a client's identity (mutual TLS).

**Use case:** Advanced scenarios where the server also verifies the client's identity.

**Note:** This Vault setup does NOT use client certificates - only server-side TLS.

## What Vault Creates

When you install Vault with these flags:
```bash
--set global.tlsDisable=false
--set "server.extraArgs=-dev-tls -dev-tls-cert-dir=/var/run/tls -dev-tls-san=vault -dev-tls-san=vault.${VAULT_NAMESPACE}.svc"
```

Vault automatically generates **three files** in `/var/run/tls/`:

### 1. CA Certificate (`vault-ca.pem`)
```
Type:     Certificate Authority (CA)
Subject:  CN=Vault CA
Issuer:   CN=Vault CA   ← Self-signed!
Purpose:  Sign the server certificate
Lifetime: Typically 10 years for dev mode
```

**This is a self-signed root CA** - it signs itself AND signs the server certificate.

### 2. Server Certificate (`vault-cert.pem`)
```
Type:     Server Certificate
Subject:  CN=vault
Issuer:   CN=Vault CA   ← Signed by the CA above
SANs:     DNS:vault, DNS:vault.vault-kms.svc
Purpose:  Prove Vault server's identity during TLS
Lifetime: Typically 1 year
```

**This is CA-signed** (not self-signed) - signed by `vault-ca.pem`.

### 3. Server Private Key (`vault-key.pem`)
```
Type:     Private Key (RSA/ECDSA)
Purpose:  Prove ownership of the server certificate
Security: NEVER share this - stays in Vault pod only
```

**Certificate Chain:**
```
vault-ca.pem (self-signed root CA)
    └── vault-cert.pem (server cert signed by CA)
            └── vault-key.pem (private key for server cert)
```

## ConfigMap Contents

### What Gets Stored in `vault-ca-bundle` ConfigMap?

**Only the CA certificate** (`vault-ca.pem`):

```bash
# Extract CA from Vault pod
oc exec vault-0 -n vault-kms -- cat /var/run/tls/vault-ca.pem > /tmp/vault-ca.pem

# Store in ConfigMap in openshift-config namespace
oc create configmap vault-ca-bundle \
  --from-file=ca-bundle.crt=/tmp/vault-ca.pem \
  -n openshift-config
```

### Why Only the CA Certificate?

| Certificate | Stored in ConfigMap? | Why? |
|-------------|---------------------|------|
| `vault-ca.pem` (CA cert) | ✅ **YES** | Clients need this to verify Vault's server certificate |
| `vault-cert.pem` (Server cert) | ❌ **NO** | Vault sends this during TLS handshake - clients receive it automatically |
| `vault-key.pem` (Private key) | ❌ **NO** | Security risk! Must stay private in Vault pod only |

**The ConfigMap is for client-side trust distribution**, not for storing Vault's credentials.

## TLS Handshake Flow

Here's what happens when a client (like the KMS plugin) connects to Vault:

### Step 1: Client Initiates HTTPS Connection
```
┌─────────────────┐                    ┌──────────────────┐
│  KMS Plugin     │                    │   Vault Server   │
│                 │                    │                  │
│ "I want HTTPS"  │ ───────────────>   │                  │
└─────────────────┘                    └──────────────────┘
```

### Step 2: Vault Sends Server Certificate
```
┌─────────────────┐                    ┌──────────────────┐
│  KMS Plugin     │                    │   Vault Server   │
│                 │                    │                  │
│                 │ <── vault-cert.pem │ "Here's my cert" │
└─────────────────┘                    └──────────────────┘
```

### Step 3: Client Verifies Certificate
```
┌─────────────────────────────────────┐
│  KMS Plugin                         │
│                                     │
│  1. Read CA cert from ConfigMap     │
│  2. Check: Was vault-cert.pem       │
│     signed by this CA?              │
│                                     │
│  openssl verify -CAfile             │
│    /ca/ca-bundle.crt                │
│    <vault-cert.pem from handshake>  │
│                                     │
│  Result: ✓ Valid!                   │
└─────────────────────────────────────┘
```

### Step 4: Encrypted Connection Established
```
┌─────────────────┐                    ┌──────────────────┐
│  KMS Plugin     │ ═══ Encrypted ═══> │   Vault Server   │
│                 │ <══ Connection ═══ │                  │
└─────────────────┘                    └──────────────────┘
```

**Key Point:** The client (KMS plugin) doesn't need the server certificate in advance because:
1. Vault **sends** it during the handshake (Step 2)
2. Client **verifies** it using the CA from ConfigMap (Step 3)

## File Locations

### In Vault Pod (`vault-0`)

```
/var/run/tls/
├── vault-ca.pem     # CA certificate (self-signed root CA)
├── vault-cert.pem   # Server certificate (signed by CA)
└── vault-key.pem    # Server private key
```

Created automatically by Vault when using `-dev-tls` flag.

### In OpenShift ConfigMap

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: vault-ca-bundle
  namespace: openshift-config
data:
  ca-bundle.crt: |
    -----BEGIN CERTIFICATE-----
    <vault-ca.pem contents - CA certificate only>
    -----END CERTIFICATE-----
```

### In Client Pods (e.g., KMS Plugin)

```yaml
volumeMounts:
- name: vault-ca
  mountPath: /etc/kubernetes/vault-ca
  readOnly: true
volumes:
- name: vault-ca
  configMap:
    name: vault-ca-bundle
```

Client reads CA cert from `/etc/kubernetes/vault-ca/ca-bundle.crt`.

## Trust Model

### Standard TLS Trust Chain

```
┌──────────────────────────────────────┐
│  Self-Signed Root CA (vault-ca.pem)  │  ← Trust anchor
└──────────────┬───────────────────────┘
               │ signs
               ▼
┌──────────────────────────────────────┐
│  Server Certificate (vault-cert.pem) │  ← Vault presents this
└──────────────────────────────────────┘
               │
               │ proven by
               ▼
┌──────────────────────────────────────┐
│  Private Key (vault-key.pem)         │  ← Secret, stays in Vault
└──────────────────────────────────────┘
```

### How Trust is Established

1. **Administrator Action:**
   - Extracts CA cert from Vault pod
   - Stores in ConfigMap `vault-ca-bundle`
   - Distribution: ConfigMap is mounted by client pods

2. **Client Action (automatic):**
   - Reads CA cert from ConfigMap
   - Uses it to verify Vault's server cert during TLS handshake
   - Trusts any server cert signed by this CA

3. **Security Guarantee:**
   - If someone creates a fake Vault server, they can't create a valid server cert
   - Only the real Vault has the CA private key to sign certificates
   - Client will reject the fake server

## Common Questions

### Q: Is the CA certificate self-signed?
**A:** Yes! It's a **self-signed root CA**:
- Subject: `CN=Vault CA`
- Issuer: `CN=Vault CA` (same = self-signed)

### Q: Is the server certificate self-signed?
**A:** No! It's **signed by the CA**:
- Subject: `CN=vault`
- Issuer: `CN=Vault CA` (different = CA-signed)

### Q: Why not use a public CA like Let's Encrypt?
**A:** For dev/test environments:
- Vault pod is internal (no public DNS)
- Self-signed CA is faster and simpler
- No internet dependency
- Full control over certificate lifecycle

For production, you might use:
- Company's internal PKI
- cert-manager with a proper CA
- HashiCorp Vault's PKI secrets engine

### Q: Why is the CA in a ConfigMap if it's "secret"?
**A:** CA certificate is **public information**, not secret!

| Component | Public? | Why? |
|-----------|---------|------|
| CA cert | ✅ Public | Clients need it to verify servers |
| Server cert | ✅ Public | Servers send this during TLS handshake |
| Private key | ❌ **Secret!** | Proves ownership - must stay private |

ConfigMaps are fine for public certificates. Secrets are for private keys.

### Q: What if the CA cert in ConfigMap doesn't match the one in Vault?
**A:** TLS verification will **fail**!

The verification script checks this:
```bash
# Step 3A: Verify CA consistency
CA_FROM_CONFIGMAP=$(kubectl get configmap vault-ca-bundle -n openshift-config ...)
CA_FROM_POD=$(kubectl exec vault-0 -n vault-kms -- cat /var/run/tls/vault-ca.pem ...)

# Compare SHA256 hashes - must match!
```

### Q: How long are the certificates valid?
**A:** In Vault dev mode:
- **CA certificate:** ~10 years (long lifetime for root CA)
- **Server certificate:** ~1 year (shorter for security)

The verification script checks expiration:
```bash
# Warns if certificate expires in < 30 days
# Fails if certificate is already expired
```

### Q: Can I use this CA to sign other certificates?
**A:** Technically yes, but **don't** for production:
- Vault dev mode CA is for testing only
- No CRL (Certificate Revocation List)
- No OCSP (Online Certificate Status Protocol)
- CA private key might be rotated on pod restart

For production certificate signing, use proper PKI infrastructure.

### Q: Do clients need client certificates?
**A:** No! This setup uses **server-side TLS only**:
- Vault proves its identity (server cert)
- Clients verify Vault's identity (CA cert)
- Clients authenticate via **Vault tokens**, not certificates

Mutual TLS (mTLS) with client certificates is a separate, advanced setup.

## Verification Commands

### Verify CA is Self-Signed
```bash
kubectl exec vault-0 -n vault-kms -- \
  openssl x509 -in /var/run/tls/vault-ca.pem -noout -subject -issuer

# Output should show subject == issuer:
# subject=CN=Vault CA
# issuer=CN=Vault CA
```

### Verify Server Cert is CA-Signed
```bash
kubectl exec vault-0 -n vault-kms -- \
  openssl x509 -in /var/run/tls/vault-cert.pem -noout -subject -issuer

# Output should show different subject vs issuer:
# subject=CN=vault
# issuer=CN=Vault CA
```

### Verify Certificate Chain
```bash
kubectl exec vault-0 -n vault-kms -- \
  openssl verify -CAfile /var/run/tls/vault-ca.pem /var/run/tls/vault-cert.pem

# Output should be:
# /var/run/tls/vault-cert.pem: OK
```

### View Certificate SANs
```bash
kubectl exec vault-0 -n vault-kms -- \
  openssl x509 -in /var/run/tls/vault-cert.pem -noout -text | \
  grep -A 1 "Subject Alternative Name"

# Output shows DNS names the cert is valid for:
# DNS:vault, DNS:vault.vault-kms.svc
```

### Test HTTPS Connection with CA
```bash
# From test pod with CA mounted at /ca/ca-bundle.crt
curl --cacert /ca/ca-bundle.crt https://vault.vault-kms.svc:8200/v1/sys/health

# Should succeed with JSON response
```

### Test HTTPS Connection WITHOUT CA (should fail)
```bash
curl https://vault.vault-kms.svc:8200/v1/sys/health

# Should fail with:
# SSL certificate problem: unable to get local issuer certificate
```

## Summary

| Aspect | Details |
|--------|---------|
| **CA Certificate** | Self-signed root CA created by Vault |
| **Server Certificate** | Signed by the CA, presented during TLS |
| **ConfigMap Contents** | CA certificate only |
| **Security Model** | Clients trust the CA → trust servers signed by CA |
| **Distribution** | CA cert in ConfigMap → mounted by client pods |
| **Private Keys** | Stay in Vault pod, never distributed |
| **Verification** | `openssl verify -CAfile ca.pem server-cert.pem` |

For more details, see:
- `etcd-encryption-vault-install-commands.sh` - Creates Vault with TLS
- `verify-vault-tls.sh` - Comprehensive TLS verification script
