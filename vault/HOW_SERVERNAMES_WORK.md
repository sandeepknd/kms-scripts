# How ServerNames (SANs) Work in TLS Certificates

## What is a ServerName?

**ServerName** is the hostname that a client uses when connecting to a TLS server. It's also called **SNI (Server Name Indication)**.

When a client connects to a server using TLS:
1. Client sends the ServerName it wants to connect to (e.g., "vault.vault-kms.svc")
2. Server presents its certificate
3. Client verifies the certificate includes that ServerName in its **Subject Alternative Names (SANs)**
4. If the ServerName matches a SAN, connection proceeds
5. If not, connection fails with a hostname mismatch error

## Where Do ServerNames Come From?

### 1. **They are configured during certificate generation**

In our Vault setup, the SANs are specified in the Helm install command:

```bash
helm upgrade --install vault hashicorp/vault \
  --set "server.extraArgs=-dev-tls -dev-tls-cert-dir=/var/run/tls -dev-tls-san=vault -dev-tls-san=vault.${VAULT_NAMESPACE}.svc" \
  ...
```

**Key parameters**:
- `-dev-tls` - Enable TLS in dev mode
- `-dev-tls-cert-dir=/var/run/tls` - Where to store generated certs
- `-dev-tls-san=vault` - Add "vault" as a SAN
- `-dev-tls-san=vault.${VAULT_NAMESPACE}.svc` - Add full service name as a SAN

### 2. **Vault auto-generates additional SANs in dev mode**

When Vault starts with `-dev-tls`, it automatically adds:
- `localhost`, `localhost4`, `localhost6`, `localhost.localdomain` (for local access)
- Pod hostname (e.g., `vault-0`)
- IP addresses: `127.0.0.1` and `::` (IPv6 loopback)

### 3. **Final list of SANs in the certificate**

```
DNS:localhost
DNS:localhost4
DNS:localhost6
DNS:localhost.localdomain
DNS:vault-0              ← Auto-generated (pod name)
DNS:vault                ← From -dev-tls-san=vault
DNS:vault.vault-kms.svc  ← From -dev-tls-san=vault.vault-kms.svc
IP:127.0.0.1
IP:::
```

## How to View ServerNames in a Certificate

### Method 1: Using openssl x509

```bash
# View all certificate details
openssl x509 -in /tmp/vault-certs/vault-cert.pem -text -noout

# View only SANs
openssl x509 -in /tmp/vault-certs/vault-cert.pem -text -noout | \
  grep -A1 "Subject Alternative Name"
```

**Output:**
```
X509v3 Subject Alternative Name: 
    DNS:localhost, DNS:localhost4, DNS:localhost6, DNS:localhost.localdomain, 
    DNS:vault-0, DNS:vault, DNS:vault.vault-kms.svc, 
    IP Address:127.0.0.1, IP Address:0:0:0:0:0:0:0:0
```

### Method 2: Using openssl s_client

```bash
# Connect and view server certificate
echo | openssl s_client -connect vault.vault-kms.svc:8200 2>/dev/null | \
  openssl x509 -text -noout | grep -A1 "Subject Alternative Name"
```

### Method 3: Programmatically (from certificate file)

```bash
# Extract just the DNS SANs
openssl x509 -in /tmp/vault-certs/vault-cert.pem -text -noout | \
  grep -oP 'DNS:\K[^,]+' | sort
```

**Output:**
```
localhost
localhost.localdomain
localhost4
localhost6
vault
vault-0
vault.vault-kms.svc
```

## How ServerName Matching Works

### Example 1: Client connects to `https://vault.vault-kms.svc:8200`

```
1. Client extracts hostname from URL: "vault.vault-kms.svc"
2. Client uses this as ServerName in TLS handshake
3. Server presents certificate with SANs including "vault.vault-kms.svc"
4. ✓ MATCH - Connection succeeds
```

### Example 2: Client connects to `https://vault:8200`

```
1. Client extracts hostname: "vault"
2. Client uses "vault" as ServerName
3. Server presents certificate with SANs including "vault"
4. ✓ MATCH - Connection succeeds
```

### Example 3: Client connects to `https://vault.invalid-name.svc:8200`

```
1. Client extracts hostname: "vault.invalid-name.svc"
2. Client uses "vault.invalid-name.svc" as ServerName
3. Server presents certificate with SANs (see list above)
4. ✗ NO MATCH - Connection fails with hostname mismatch
```

## How to Test Different ServerNames

### Using curl

```bash
# The ServerName comes from the URL hostname automatically
curl --cacert /tmp/vault-certs/vault-ca.pem https://vault.vault-kms.svc:8200/v1/sys/health

# To override ServerName, use --resolve to map a different name
curl --cacert /tmp/vault-certs/vault-ca.pem \
     --resolve vault-custom:8200:172.30.100.175 \
     https://vault-custom:8200/v1/sys/health
# This will FAIL because "vault-custom" is not in the SANs
```

### Using openssl s_client

```bash
# Explicit ServerName with -servername flag
echo | openssl s_client \
  -connect vault.vault-kms.svc:8200 \
  -servername vault \
  -CAfile /tmp/vault-certs/vault-ca.pem
```

**Key parameters**:
- `-connect` - IP:port to connect to
- `-servername` - The hostname to verify (can be different from connect address)
- `-CAfile` - CA bundle for verification

### Using the test script

```bash
# Test with "vault"
./test-servername.sh vault

# Test with full service name
./test-servername.sh vault.vault-kms.svc

# Test with pod name
./test-servername.sh vault-0

# Test with invalid name (will fail)
./test-servername.sh invalid-hostname
```

## Common Scenarios in Kubernetes/OpenShift

### Scenario 1: Pod in Same Namespace

**URL**: `https://vault:8200`
**ServerName**: `vault`
**Works**: ✓ Yes (DNS resolves and SAN matches)

```bash
# From a pod in vault-kms namespace
curl --cacert /ca/vault-ca.pem https://vault:8200/v1/sys/health
```

### Scenario 2: Pod in Different Namespace

**URL**: `https://vault.vault-kms.svc:8200`
**ServerName**: `vault.vault-kms.svc`
**Works**: ✓ Yes (full DNS name in SANs)

```bash
# From a pod in different namespace
curl --cacert /ca/vault-ca.pem https://vault.vault-kms.svc:8200/v1/sys/health
```

### Scenario 3: Using ClusterIP Directly

**URL**: `https://172.30.100.175:8200`
**ServerName**: `172.30.100.175`
**Works**: ✗ No (IP address must match exactly, and only 127.0.0.1 is in SANs)

**Solution**: Use DNS name instead of IP, or use --resolve:
```bash
# Use DNS name that's in SANs
curl --cacert /ca/vault-ca.pem https://vault.vault-kms.svc:8200/v1/sys/health

# Or override ServerName
echo | openssl s_client \
  -connect 172.30.100.175:8200 \
  -servername vault.vault-kms.svc \
  -CAfile /ca/vault-ca.pem
```

### Scenario 4: FQDN with Cluster Domain

**URL**: `https://vault.vault-kms.svc.cluster.local:8200`
**ServerName**: `vault.vault-kms.svc.cluster.local`
**Works**: ✗ No (full FQDN not in SANs, only `vault.vault-kms.svc`)

**Solution**: Either:
1. Use `vault.vault-kms.svc` instead
2. Or add the FQDN during Vault installation:
```bash
--set "server.extraArgs=... -dev-tls-san=vault.vault-kms.svc.cluster.local"
```

## How to Add Custom ServerNames

To add your own custom ServerNames, modify the Helm install in `etcd-encryption-vault-setup.sh`:

### Current configuration:
```bash
--set "server.extraArgs=-dev-tls -dev-tls-cert-dir=/var/run/tls -dev-tls-san=vault -dev-tls-san=vault.${VAULT_NAMESPACE}.svc"
```

### Add more SANs:
```bash
--set "server.extraArgs=-dev-tls -dev-tls-cert-dir=/var/run/tls \
  -dev-tls-san=vault \
  -dev-tls-san=vault.${VAULT_NAMESPACE}.svc \
  -dev-tls-san=vault.${VAULT_NAMESPACE}.svc.cluster.local \
  -dev-tls-san=my-custom-vault-name \
  -dev-tls-san=vault.example.com"
```

Then redeploy Vault to generate new certificates with the additional SANs.

## Debugging ServerName Issues

### Error: "certificate verify failed" or "hostname mismatch"

**Cause**: The ServerName you're using is not in the certificate's SANs.

**Solution**:
1. Check what SANs are in the certificate:
```bash
openssl x509 -in /tmp/vault-certs/vault-cert.pem -text -noout | \
  grep -A1 "Subject Alternative Name"
```

2. Use one of the valid ServerNames:
```bash
# ✓ Valid
curl --cacert ca.pem https://vault.vault-kms.svc:8200/...

# ✗ Invalid
curl --cacert ca.pem https://vault.wrong-namespace.svc:8200/...
```

3. Or add your desired name to the SANs and redeploy

### Error: "unable to get local issuer certificate"

**Cause**: CA bundle is missing or incorrect.

**Solution**: Ensure CA bundle is provided via `--cacert` or `VAULT_CACERT` environment variable.

## Quick Reference

| What | Command |
|------|---------|
| View SANs | `openssl x509 -in cert.pem -text -noout \| grep -A1 "Subject Alternative Name"` |
| Test ServerName | `./test-servername.sh <hostname>` |
| Valid names | vault, vault.vault-kms.svc, vault-0, localhost |
| Add SANs | Modify `-dev-tls-san=` in Helm install command |
| Extract DNS SANs | `openssl x509 -in cert.pem -text -noout \| grep -oP 'DNS:\K[^,]+'` |

## Summary

**ServerNames (SANs) are**:
- ✓ Configured during certificate generation
- ✓ Stored in the certificate's Subject Alternative Names field
- ✓ Used by TLS clients to verify they're connecting to the right server
- ✓ Must match the hostname in the connection URL

**To check ServerNames**:
1. Extract certificate: `oc exec vault-0 -n vault-kms -- cat /var/run/tls/vault-cert.pem > cert.pem`
2. View SANs: `openssl x509 -in cert.pem -text -noout | grep -A1 "Subject Alternative Name"`
3. Use one of the listed DNS names when connecting
