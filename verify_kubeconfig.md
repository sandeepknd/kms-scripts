# Complete Guide: Verify kubeconfig Against Cluster CA Bundle

This document provides step-by-step instructions to extract the kube-apiserver CA bundle from an OpenShift/Kubernetes cluster and verify your kubeconfig client certificate against it.

## Table of Contents

1. [Prerequisites](#prerequisites)
2. [Overview](#overview)
3. [Step 1: Extract the CA Bundle from the Cluster](#step-1-extract-the-ca-bundle-from-the-cluster)
4. [Step 2: Extract Client Certificate from kubeconfig](#step-2-extract-client-certificate-from-kubeconfig)
5. [Step 3: Verify Certificate Against CA Bundle](#step-3-verify-certificate-against-ca-bundle)
6. [Step 4: Decode and Analyze Certificates](#step-4-decode-and-analyze-certificates)
7. [Step 5: Identify Which CA Signed Your Certificate](#step-5-identify-which-ca-signed-your-certificate)
8. [Complete Verification Script](#complete-verification-script)
9. [Understanding the Results](#understanding-the-results)
10. [Troubleshooting](#troubleshooting)

---

## Prerequisites

**Required Tools:**
- `oc` or `kubectl` CLI (authenticated to your cluster)
- `openssl` (for certificate manipulation)
- `base64` (for decoding base64-encoded data)
- `jq` (optional, for JSON parsing)

**Required Access:**
- Access to the cluster with permissions to read ConfigMaps in `openshift-kube-apiserver` namespace
- Your kubeconfig file (typically `~/.kube/config` or custom path)

---

## Overview

The verification process involves:

1. **Extracting the CA bundle** that the kube-apiserver uses to trust client certificates
2. **Extracting your client certificate** from your kubeconfig file
3. **Verifying** that your certificate was signed by one of the CAs in the bundle
4. **Analyzing** the certificate details to understand your identity and permissions

```
┌─────────────────┐
│  Your kubeconfig │
│  (client cert)   │
└────────┬─────────┘
         │
         │ Signed by?
         ▼
┌─────────────────────────┐
│  Cluster CA Bundle      │
│  (7 trusted CAs)        │
│  - admin-kubeconfig-CA  │ ← Match!
│  - kubelet-CA           │
│  - control-plane-CA     │
│  - ...                  │
└─────────────────────────┘
```

---

## Step 1: Extract the CA Bundle from the Cluster

The kube-apiserver stores its trusted CA bundle in a ConfigMap.

### 1.1: View the ConfigMap

```bash
oc get configmap -n openshift-kube-apiserver client-ca -o yaml
```

**Expected output:**
```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: client-ca
  namespace: openshift-kube-apiserver
data:
  ca-bundle.crt: |
    -----BEGIN CERTIFICATE-----
    MIIDMDCCAhigAwIBAgII...
    -----END CERTIFICATE-----
    -----BEGIN CERTIFICATE-----
    MIIDODCCAiCgAwIBAgII...
    -----END CERTIFICATE-----
    ...
```

### 1.2: Extract Just the CA Bundle

```bash
oc get configmap -n openshift-kube-apiserver client-ca \
  -o jsonpath='{.data.ca-bundle\.crt}' > /tmp/ca-bundle.crt
```

**Verify the extraction:**
```bash
cat /tmp/ca-bundle.crt
```

### 1.3: Count the Number of CAs in the Bundle

```bash
grep -c "BEGIN CERTIFICATE" /tmp/ca-bundle.crt
```

**Expected output:** `7` (or similar number)

### 1.4: View Summary of All CAs

```bash
awk '/BEGIN CERT/,/END CERT/ {print} /END CERT/ {print "---SEPARATOR---"}' /tmp/ca-bundle.crt | \
csplit -s -z - '/---SEPARATOR---/' '{*}' && \
for i in xx*; do 
  echo "=== CA Certificate $(basename $i) ===" 
  openssl x509 -in $i -noout -subject -issuer -dates
  echo
done
rm -f xx*
```

**Expected output:**
```
=== CA Certificate xx00 ===
subject=OU=openshift, CN=admin-kubeconfig-signer
issuer=OU=openshift, CN=admin-kubeconfig-signer
notBefore=May 29 08:37:47 2026 GMT
notAfter=May 26 08:37:47 2036 GMT

=== CA Certificate xx01 ===
subject=CN=kube-csr-signer_@1780044761
issuer=OU=openshift, CN=kubelet-signer
notBefore=May 29 08:52:41 2026 GMT
notAfter=May 30 08:37:49 2026 GMT

...
```

---

## Step 2: Extract Client Certificate from kubeconfig

### 2.1: Locate Your kubeconfig File

```bash
# Default location
ls -la ~/.kube/config

# Or custom location
ls -la ~/Downloads/kubeconfig
```

### 2.2: View kubeconfig Structure

```bash
# Using default kubeconfig
oc config view --raw

# Or for a specific file
cat ~/Downloads/kubeconfig
```

**Key sections:**
```yaml
users:
- name: admin
  user:
    client-certificate-data: LS0tLS1CRUdJTi...  # Base64 encoded certificate
    client-key-data: LS0tLS1CRUdJTiBSU0E...     # Base64 encoded private key
```

### 2.3: Extract and Decode Client Certificate

**For default kubeconfig:**
```bash
oc config view --raw -o jsonpath='{.users[0].user.client-certificate-data}' | \
  base64 -d > /tmp/client-cert.pem
```

**For custom kubeconfig:**
```bash
grep "client-certificate-data:" ~/Downloads/kubeconfig | \
  awk '{print $2}' | \
  base64 -d > /tmp/client-cert.pem
```

### 2.4: Verify the Certificate File

```bash
cat /tmp/client-cert.pem
```

**Expected output:**
```
-----BEGIN CERTIFICATE-----
MIIDZzCCAk+gAwIBAgIIbX+mFEfsmxYwDQYJKoZIhvcNAQELBQAwNjESMBAGA1UE
...
-----END CERTIFICATE-----
```

### 2.5: View Basic Certificate Information

```bash
openssl x509 -in /tmp/client-cert.pem -noout -subject -issuer -dates
```

**Expected output:**
```
subject=O=system:masters, CN=system:admin
issuer=OU=openshift, CN=admin-kubeconfig-signer
notBefore=May 29 08:37:47 2026 GMT
notAfter=May 26 08:37:47 2036 GMT
```

**Key information:**
- **Subject CN (Common Name)**: Your username (e.g., `system:admin`)
- **Subject O (Organization)**: Your group(s) (e.g., `system:masters`)
- **Issuer**: The CA that signed this certificate
- **Validity**: When the certificate expires

---

## Step 3: Verify Certificate Against CA Bundle

This is the critical step that proves your certificate is trusted.

### 3.1: Perform OpenSSL Verification

```bash
openssl verify -CAfile /tmp/ca-bundle.crt /tmp/client-cert.pem
```

**Expected output (SUCCESS):**
```
/tmp/client-cert.pem: OK
```

**Expected output (FAILURE):**
```
/tmp/client-cert.pem: CN = system:admin
error 20 at 0 depth lookup:unable to get local issuer certificate
```

### 3.2: Verbose Verification

For more details on the verification process:

```bash
openssl verify -CAfile /tmp/ca-bundle.crt -verbose /tmp/client-cert.pem
```

### 3.3: Check Certificate Chain

```bash
openssl verify -CAfile /tmp/ca-bundle.crt -show_chain /tmp/client-cert.pem
```

**Expected output:**
```
/tmp/client-cert.pem: OK
Chain:
depth=0: O = system:masters, CN = system:admin (untrusted)
depth=1: OU = openshift, CN = admin-kubeconfig-signer
```

---

## Step 4: Decode and Analyze Certificates

### 4.1: View Complete Client Certificate Details

```bash
openssl x509 -in /tmp/client-cert.pem -text -noout
```

**Expected output:**
```
Certificate:
    Data:
        Version: 3 (0x2)
        Serial Number: 7890207678212643606 (0x6d7fa61447ec9b16)
    Signature Algorithm: sha256WithRSAEncryption
        Issuer: OU=openshift, CN=admin-kubeconfig-signer
        Validity
            Not Before: May 29 08:37:47 2026 GMT
            Not After : May 26 08:37:47 2036 GMT
        Subject: O=system:masters, CN=system:admin
        Subject Public Key Info:
            Public Key Algorithm: rsaEncryption
                RSA Public-Key: (2048 bit)
        X509v3 extensions:
            X509v3 Key Usage: critical
                Digital Signature, Key Encipherment
            X509v3 Extended Key Usage: 
                TLS Web Server Authentication, TLS Web Client Authentication
            X509v3 Basic Constraints: critical
                CA:FALSE
...
```

### 4.2: Extract Specific Certificate Fields

**Get Subject (Your Identity):**
```bash
openssl x509 -in /tmp/client-cert.pem -noout -subject
```

**Get Issuer (Which CA Signed It):**
```bash
openssl x509 -in /tmp/client-cert.pem -noout -issuer
```

**Get Serial Number:**
```bash
openssl x509 -in /tmp/client-cert.pem -noout -serial
```

**Get Fingerprint:**
```bash
openssl x509 -in /tmp/client-cert.pem -noout -fingerprint -sha256
```

**Get Public Key:**
```bash
openssl x509 -in /tmp/client-cert.pem -noout -pubkey
```

### 4.3: Check Certificate Expiration

**Human-readable format:**
```bash
openssl x509 -in /tmp/client-cert.pem -noout -enddate
```

**Check if certificate is currently valid:**
```bash
openssl x509 -in /tmp/client-cert.pem -noout -checkend 0 && \
  echo "Certificate is valid" || echo "Certificate has expired"
```

**Check if certificate will expire in 30 days:**
```bash
openssl x509 -in /tmp/client-cert.pem -noout -checkend $((30*24*60*60)) && \
  echo "Certificate is valid for at least 30 days" || \
  echo "Certificate will expire within 30 days"
```

### 4.4: Analyze All CA Certificates in Bundle

**Create a detailed report of all CAs:**
```bash
cat > /tmp/analyze_cas.sh << 'EOF'
#!/bin/bash

CA_BUNDLE="/tmp/ca-bundle.crt"
COUNTER=1

echo "========================================"
echo "CA Bundle Analysis"
echo "========================================"
echo

awk '/BEGIN CERT/,/END CERT/ {print} /END CERT/ {print "---SEPARATOR---"}' "$CA_BUNDLE" | \
csplit -s -z - '/---SEPARATOR---/' '{*}'

for cert_file in xx*; do
    echo "----------------------------------------"
    echo "CA Certificate #$COUNTER"
    echo "----------------------------------------"
    
    SUBJECT=$(openssl x509 -in "$cert_file" -noout -subject | sed 's/subject=//')
    ISSUER=$(openssl x509 -in "$cert_file" -noout -issuer | sed 's/issuer=//')
    NOT_BEFORE=$(openssl x509 -in "$cert_file" -noout -startdate | sed 's/notBefore=//')
    NOT_AFTER=$(openssl x509 -in "$cert_file" -noout -enddate | sed 's/notAfter=//')
    
    echo "Subject:    $SUBJECT"
    echo "Issuer:     $ISSUER"
    echo "Valid From: $NOT_BEFORE"
    echo "Valid To:   $NOT_AFTER"
    
    # Check if self-signed
    if [ "$SUBJECT" == "$ISSUER" ]; then
        echo "Type:       Self-signed CA"
    else
        echo "Type:       Intermediate CA"
    fi
    
    echo
    COUNTER=$((COUNTER + 1))
done

rm -f xx*

echo "========================================"
echo "Total CAs in bundle: $((COUNTER - 1))"
echo "========================================"
EOF

chmod +x /tmp/analyze_cas.sh
/tmp/analyze_cas.sh
```

---

## Step 5: Identify Which CA Signed Your Certificate

### 5.1: Method 1 - Using Issuer Hash

```bash
# Get the issuer hash from your client certificate
CLIENT_ISSUER_HASH=$(openssl x509 -in /tmp/client-cert.pem -noout -issuer_hash)

echo "Client certificate issuer hash: $CLIENT_ISSUER_HASH"
echo

# Find matching CA in the bundle
COUNTER=1
awk '/BEGIN CERT/,/END CERT/ {print} /END CERT/ {print "---SEPARATOR---"}' /tmp/ca-bundle.crt | \
csplit -s -z - '/---SEPARATOR---/' '{*}'

for cert_file in xx*; do
    CA_HASH=$(openssl x509 -in "$cert_file" -noout -subject_hash)
    
    if [ "$CA_HASH" == "$CLIENT_ISSUER_HASH" ]; then
        echo "✅ MATCH FOUND! CA Certificate #$COUNTER"
        echo
        echo "CA Details:"
        openssl x509 -in "$cert_file" -noout -subject -issuer -dates
        echo
        echo "Full CA Certificate:"
        cat "$cert_file"
        break
    fi
    
    COUNTER=$((COUNTER + 1))
done

rm -f xx*
```

### 5.2: Method 2 - Using Issuer DN (Distinguished Name)

```bash
# Get issuer from client certificate
CLIENT_ISSUER=$(openssl x509 -in /tmp/client-cert.pem -noout -issuer)

echo "Looking for CA with issuer: $CLIENT_ISSUER"
echo

# Search all CAs
COUNTER=1
awk '/BEGIN CERT/,/END CERT/ {print} /END CERT/ {print "---SEPARATOR---"}' /tmp/ca-bundle.crt | \
csplit -s -z - '/---SEPARATOR---/' '{*}'

for cert_file in xx*; do
    CA_SUBJECT=$(openssl x509 -in "$cert_file" -noout -subject)
    
    # Compare issuer of client cert with subject of CA cert
    CLIENT_ISSUER_CLEAN=$(echo "$CLIENT_ISSUER" | sed 's/issuer=//')
    CA_SUBJECT_CLEAN=$(echo "$CA_SUBJECT" | sed 's/subject=//')
    
    if [ "$CLIENT_ISSUER_CLEAN" == "$CA_SUBJECT_CLEAN" ]; then
        echo "✅ MATCH FOUND! CA Certificate #$COUNTER"
        echo
        echo "This CA signed your client certificate:"
        openssl x509 -in "$cert_file" -noout -subject -dates
        break
    fi
    
    COUNTER=$((COUNTER + 1))
done

rm -f xx*
```

### 5.3: Visual Verification Report

```bash
cat > /tmp/verification_report.sh << 'EOF'
#!/bin/bash

echo "╔══════════════════════════════════════════════════════════════════╗"
echo "║          CERTIFICATE VERIFICATION REPORT                         ║"
echo "╚══════════════════════════════════════════════════════════════════╝"
echo

# Client Certificate Info
echo "┌─────────────────────────────────────────────────────────────────┐"
echo "│ YOUR CLIENT CERTIFICATE                                         │"
echo "└─────────────────────────────────────────────────────────────────┘"
echo
openssl x509 -in /tmp/client-cert.pem -noout -subject -issuer -dates
echo

# Verification Result
echo "┌─────────────────────────────────────────────────────────────────┐"
echo "│ VERIFICATION RESULT                                             │"
echo "└─────────────────────────────────────────────────────────────────┘"
echo
VERIFY_RESULT=$(openssl verify -CAfile /tmp/ca-bundle.crt /tmp/client-cert.pem 2>&1)
echo "$VERIFY_RESULT"
echo

if echo "$VERIFY_RESULT" | grep -q "OK"; then
    echo "✅ CERTIFICATE IS TRUSTED"
    echo
    
    # Find which CA
    echo "┌─────────────────────────────────────────────────────────────────┐"
    echo "│ SIGNING CA DETAILS                                              │"
    echo "└─────────────────────────────────────────────────────────────────┘"
    echo
    
    CLIENT_ISSUER_HASH=$(openssl x509 -in /tmp/client-cert.pem -noout -issuer_hash)
    
    COUNTER=1
    awk '/BEGIN CERT/,/END CERT/ {print} /END CERT/ {print "---SEPARATOR---"}' /tmp/ca-bundle.crt | \
    csplit -s -z - '/---SEPARATOR---/' '{*}'
    
    for cert_file in xx*; do
        CA_HASH=$(openssl x509 -in "$cert_file" -noout -subject_hash)
        
        if [ "$CA_HASH" == "$CLIENT_ISSUER_HASH" ]; then
            echo "Certificate #$COUNTER in the CA bundle"
            echo
            openssl x509 -in "$cert_file" -noout -subject -issuer -dates
            break
        fi
        
        COUNTER=$((COUNTER + 1))
    done
    
    rm -f xx*
else
    echo "❌ CERTIFICATE IS NOT TRUSTED"
    echo
    echo "Possible reasons:"
    echo "- Certificate was not signed by any CA in the bundle"
    echo "- Certificate has expired"
    echo "- CA that signed it has been removed from the bundle"
fi

echo
echo "╚══════════════════════════════════════════════════════════════════╝"
EOF

chmod +x /tmp/verification_report.sh
/tmp/verification_report.sh
```

---

## Complete Verification Script

Here's a single script that performs the entire verification process:

```bash
#!/bin/bash

# ============================================================================
# Complete kubeconfig Verification Script
# ============================================================================

set -e  # Exit on error

# Color codes for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Configuration
KUBECONFIG_PATH="${1:-$HOME/Downloads/kubeconfig}"
CA_BUNDLE_FILE="/tmp/ca-bundle.crt"
CLIENT_CERT_FILE="/tmp/client-cert.pem"

echo "╔══════════════════════════════════════════════════════════════════╗"
echo "║          KUBECONFIG VERIFICATION TOOL                            ║"
echo "╚══════════════════════════════════════════════════════════════════╝"
echo

# ============================================================================
# STEP 1: Extract CA Bundle from Cluster
# ============================================================================

echo -e "${BLUE}[STEP 1]${NC} Extracting CA bundle from cluster..."
echo

if ! command -v oc &> /dev/null; then
    echo -e "${RED}Error: 'oc' command not found${NC}"
    echo "Please install OpenShift CLI or ensure it's in your PATH"
    exit 1
fi

oc get configmap -n openshift-kube-apiserver client-ca \
    -o jsonpath='{.data.ca-bundle\.crt}' > "$CA_BUNDLE_FILE" 2>/dev/null

if [ ! -s "$CA_BUNDLE_FILE" ]; then
    echo -e "${RED}Failed to extract CA bundle from cluster${NC}"
    echo "Please check:"
    echo "  - You are logged into the cluster"
    echo "  - You have permissions to read ConfigMaps in openshift-kube-apiserver namespace"
    exit 1
fi

CA_COUNT=$(grep -c "BEGIN CERTIFICATE" "$CA_BUNDLE_FILE")
echo -e "${GREEN}✓${NC} CA bundle extracted successfully"
echo "  Location: $CA_BUNDLE_FILE"
echo "  Number of CAs: $CA_COUNT"
echo

# ============================================================================
# STEP 2: Extract Client Certificate from kubeconfig
# ============================================================================

echo -e "${BLUE}[STEP 2]${NC} Extracting client certificate from kubeconfig..."
echo

if [ ! -f "$KUBECONFIG_PATH" ]; then
    echo -e "${RED}Error: kubeconfig file not found at $KUBECONFIG_PATH${NC}"
    exit 1
fi

# Try to extract client-certificate-data
if grep -q "client-certificate-data:" "$KUBECONFIG_PATH"; then
    grep "client-certificate-data:" "$KUBECONFIG_PATH" | \
        awk '{print $2}' | \
        base64 -d > "$CLIENT_CERT_FILE" 2>/dev/null
else
    echo -e "${RED}Error: client-certificate-data not found in kubeconfig${NC}"
    exit 1
fi

if [ ! -s "$CLIENT_CERT_FILE" ]; then
    echo -e "${RED}Failed to extract client certificate${NC}"
    exit 1
fi

echo -e "${GREEN}✓${NC} Client certificate extracted successfully"
echo "  Location: $CLIENT_CERT_FILE"
echo

# ============================================================================
# STEP 3: Display Certificate Information
# ============================================================================

echo -e "${BLUE}[STEP 3]${NC} Client Certificate Details"
echo
echo "┌─────────────────────────────────────────────────────────────────┐"

SUBJECT=$(openssl x509 -in "$CLIENT_CERT_FILE" -noout -subject | sed 's/subject=//')
ISSUER=$(openssl x509 -in "$CLIENT_CERT_FILE" -noout -issuer | sed 's/issuer=//')
NOT_BEFORE=$(openssl x509 -in "$CLIENT_CERT_FILE" -noout -startdate | sed 's/notBefore=//')
NOT_AFTER=$(openssl x509 -in "$CLIENT_CERT_FILE" -noout -enddate | sed 's/notAfter=//')
SERIAL=$(openssl x509 -in "$CLIENT_CERT_FILE" -noout -serial | sed 's/serial=//')

echo "│ Subject:    $SUBJECT"
echo "│ Issuer:     $ISSUER"
echo "│ Valid From: $NOT_BEFORE"
echo "│ Valid To:   $NOT_AFTER"
echo "│ Serial:     $SERIAL"
echo "└─────────────────────────────────────────────────────────────────┘"
echo

# Extract username and groups from subject
USERNAME=$(echo "$SUBJECT" | grep -oP 'CN\s*=\s*\K[^,]+' || echo "N/A")
GROUPS=$(echo "$SUBJECT" | grep -oP 'O\s*=\s*\K[^,]+' || echo "N/A")

echo "Identity Information:"
echo "  Username: $USERNAME"
echo "  Group(s): $GROUPS"
echo

# ============================================================================
# STEP 4: Verify Certificate Against CA Bundle
# ============================================================================

echo -e "${BLUE}[STEP 4]${NC} Verifying certificate against CA bundle..."
echo

VERIFY_OUTPUT=$(openssl verify -CAfile "$CA_BUNDLE_FILE" "$CLIENT_CERT_FILE" 2>&1)

if echo "$VERIFY_OUTPUT" | grep -q "OK"; then
    echo -e "${GREEN}✅ VERIFICATION SUCCESSFUL${NC}"
    echo "$VERIFY_OUTPUT"
    echo
    
    # ========================================================================
    # STEP 5: Find Which CA Signed the Certificate
    # ========================================================================
    
    echo -e "${BLUE}[STEP 5]${NC} Identifying signing CA..."
    echo
    
    CLIENT_ISSUER_HASH=$(openssl x509 -in "$CLIENT_CERT_FILE" -noout -issuer_hash)
    
    COUNTER=1
    FOUND=0
    
    awk '/BEGIN CERT/,/END CERT/ {print} /END CERT/ {print "---SEPARATOR---"}' "$CA_BUNDLE_FILE" | \
    csplit -s -z - '/---SEPARATOR---/' '{*}'
    
    for cert_file in xx*; do
        CA_HASH=$(openssl x509 -in "$cert_file" -noout -subject_hash 2>/dev/null)
        
        if [ "$CA_HASH" == "$CLIENT_ISSUER_HASH" ]; then
            echo -e "${GREEN}✓${NC} Found signing CA: Certificate #$COUNTER in the bundle"
            echo
            echo "┌─────────────────────────────────────────────────────────────────┐"
            
            CA_SUBJECT=$(openssl x509 -in "$cert_file" -noout -subject | sed 's/subject=//')
            CA_NOT_BEFORE=$(openssl x509 -in "$cert_file" -noout -startdate | sed 's/notBefore=//')
            CA_NOT_AFTER=$(openssl x509 -in "$cert_file" -noout -enddate | sed 's/notAfter=//')
            
            echo "│ CA Subject:    $CA_SUBJECT"
            echo "│ CA Valid From: $CA_NOT_BEFORE"
            echo "│ CA Valid To:   $CA_NOT_AFTER"
            echo "└─────────────────────────────────────────────────────────────────┘"
            
            FOUND=1
            break
        fi
        
        COUNTER=$((COUNTER + 1))
    done
    
    rm -f xx*
    
    if [ $FOUND -eq 0 ]; then
        echo -e "${YELLOW}Warning: Could not identify which CA signed the certificate${NC}"
    fi
    
else
    echo -e "${RED}❌ VERIFICATION FAILED${NC}"
    echo "$VERIFY_OUTPUT"
    echo
    echo "Possible reasons:"
    echo "  - Certificate was not signed by any CA in the cluster's trust bundle"
    echo "  - Certificate has expired"
    echo "  - The CA that signed this certificate has been removed from the bundle"
    exit 1
fi

# ============================================================================
# STEP 6: Additional Security Checks
# ============================================================================

echo
echo -e "${BLUE}[STEP 6]${NC} Security Checks"
echo

# Check if certificate is expired
if openssl x509 -in "$CLIENT_CERT_FILE" -noout -checkend 0 &>/dev/null; then
    echo -e "${GREEN}✓${NC} Certificate is currently valid (not expired)"
else
    echo -e "${RED}✗${NC} Certificate has EXPIRED"
fi

# Check if certificate will expire soon (30 days)
if openssl x509 -in "$CLIENT_CERT_FILE" -noout -checkend $((30*24*60*60)) &>/dev/null; then
    echo -e "${GREEN}✓${NC} Certificate is valid for at least 30 days"
else
    echo -e "${YELLOW}⚠${NC} Certificate will expire within 30 days"
fi

# Check key usage
KEY_USAGE=$(openssl x509 -in "$CLIENT_CERT_FILE" -noout -text | grep -A1 "X509v3 Key Usage" | tail -1 | xargs)
echo "  Key Usage: $KEY_USAGE"

# Check extended key usage
EXT_KEY_USAGE=$(openssl x509 -in "$CLIENT_CERT_FILE" -noout -text | grep -A1 "X509v3 Extended Key Usage" | tail -1 | xargs)
if [ ! -z "$EXT_KEY_USAGE" ]; then
    echo "  Extended Key Usage: $EXT_KEY_USAGE"
fi

echo

# ============================================================================
# STEP 7: RBAC Permission Check (if oc is available)
# ============================================================================

echo -e "${BLUE}[STEP 7]${NC} Checking cluster permissions..."
echo

if command -v oc &> /dev/null; then
    # Test if we can use this kubeconfig
    CURRENT_USER=$(oc whoami 2>/dev/null || echo "N/A")
    
    if [ "$CURRENT_USER" != "N/A" ]; then
        echo "  Current user: $CURRENT_USER"
        
        CURRENT_GROUPS=$(oc whoami --show-groups 2>/dev/null | tr '\n' ', ' | sed 's/,$//')
        echo "  Groups: $CURRENT_GROUPS"
        
        # Check if user has cluster-admin
        if oc auth can-i '*' '*' --all-namespaces &>/dev/null; then
            echo -e "  ${GREEN}✓${NC} Has cluster-admin privileges"
        else
            echo "  Limited privileges (not cluster-admin)"
        fi
    else
        echo "  Unable to check permissions (not currently using this kubeconfig)"
    fi
else
    echo "  Skipped (oc command not available)"
fi

echo

# ============================================================================
# Summary
# ============================================================================

echo "╔══════════════════════════════════════════════════════════════════╗"
echo "║                         SUMMARY                                  ║"
echo "╠══════════════════════════════════════════════════════════════════╣"
echo "║                                                                   ║"
echo "║  ✅ Certificate verification: SUCCESSFUL                         ║"
echo "║                                                                   ║"
echo "║  Identity:   $USERNAME"
echo "║  Groups:     $GROUPS"
echo "║                                                                   ║"
echo "║  🔐 Your kubeconfig is trusted by the cluster                    ║"
echo "║                                                                   ║"
echo "╚══════════════════════════════════════════════════════════════════╝"
echo

# Cleanup option
read -p "Remove temporary files? (y/n) " -n 1 -r
echo
if [[ $REPLY =~ ^[Yy]$ ]]; then
    rm -f "$CA_BUNDLE_FILE" "$CLIENT_CERT_FILE"
    echo "Temporary files removed"
else
    echo "Temporary files kept:"
    echo "  CA Bundle: $CA_BUNDLE_FILE"
    echo "  Client Cert: $CLIENT_CERT_FILE"
fi
```

**Save this script as `/tmp/verify_kubeconfig.sh` and run:**

```bash
chmod +x /tmp/verify_kubeconfig.sh
/tmp/verify_kubeconfig.sh ~/Downloads/kubeconfig
```

---

## Understanding the Results

### Successful Verification

When verification succeeds, you'll see:
```
/tmp/client-cert.pem: OK
✅ VERIFICATION SUCCESSFUL
```

This means:
1. Your certificate was signed by one of the CAs in the cluster's trust bundle
2. The certificate is cryptographically valid
3. The certificate has not expired
4. The cluster will authenticate you when you use this kubeconfig

### Identity Information

From the certificate subject:
- **CN (Common Name)**: Your Kubernetes username (e.g., `system:admin`)
- **O (Organization)**: Your group memberships (e.g., `system:masters`)

Example:
```
Subject: O=system:masters, CN=system:admin

Username: system:admin
Groups:   system:masters
```

The group `system:masters` typically gets `cluster-admin` privileges via this ClusterRoleBinding:
```yaml
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: cluster-admin
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: cluster-admin
subjects:
- apiGroup: rbac.authorization.k8s.io
  kind: Group
  name: system:masters
```

### Understanding the CA Bundle

The CA bundle typically contains 7 certificates:

| # | CA Name | Purpose | Lifetime |
|---|---------|---------|----------|
| 1 | admin-kubeconfig-signer | Admin user certificates | 10 years |
| 2 | kube-csr-signer | Kubelet certificates (CSR-approved) | 1 day |
| 3 | kubelet-signer | Kubelet signer root CA | 1 day |
| 4 | kube-apiserver-to-kubelet-signer | API server → kubelet auth | 1 year |
| 5 | kube-control-plane-signer | Control plane components | 1 year |
| 6 | kubelet-bootstrap-kubeconfig-signer | Node bootstrap | 10 years |
| 7 | node-system-admin-signer | Node system admin kubeconfigs | 3 years |

Your admin kubeconfig is typically signed by **CA #1** (`admin-kubeconfig-signer`).

---

## Troubleshooting

### Error: "unable to get local issuer certificate"

**Symptom:**
```
/tmp/client-cert.pem: CN = system:admin
error 20 at 0 depth lookup:unable to get local issuer certificate
```

**Cause:** The CA that signed your certificate is not in the cluster's CA bundle.

**Solutions:**
1. Verify you extracted the CA bundle from the correct cluster
2. Check if the CA was recently rotated
3. Ensure your kubeconfig is for this cluster

### Error: "certificate has expired"

**Symptom:**
```
error 10 at 0 depth lookup:certificate has expired
```

**Cause:** Your client certificate validity period has passed.

**Solutions:**
1. Check expiration: `openssl x509 -in /tmp/client-cert.pem -noout -dates`
2. Request a new certificate from cluster administrator
3. For admin certs, regenerate using cluster installer credentials

### Error: ConfigMap not found

**Symptom:**
```
Error from server (NotFound): configmaps "client-ca" not found
```

**Solutions:**
1. Check namespace: `oc get cm -n openshift-kube-apiserver`
2. Verify cluster type (OpenShift vs vanilla Kubernetes)
3. For vanilla Kubernetes, the CA is typically in a secret in `kube-system` namespace

### Kubernetes (non-OpenShift) Variations

For vanilla Kubernetes, the CA location may differ:

```bash
# Try these alternatives:
kubectl get cm -n kube-system kube-root-ca.crt -o jsonpath='{.data.ca\.crt}'
kubectl get cm -n kube-public cluster-info -o jsonpath='{.data.kubeconfig}'
```

### Verify Connection to Cluster

```bash
# Test cluster connectivity
oc whoami
oc cluster-info

# Test with verbose output
oc get nodes -v=8
```

### Certificate Chain Issues

If you have an intermediate CA:

```bash
# Verify with intermediate chain
openssl verify -CAfile /tmp/ca-bundle.crt -untrusted /tmp/intermediate.crt /tmp/client-cert.pem
```

---

## Additional Commands Reference

### Working with kubeconfig

**List all users in kubeconfig:**
```bash
oc config view -o jsonpath='{.users[*].name}'
```

**Get current context:**
```bash
oc config current-context
```

**Switch context:**
```bash
oc config use-context <context-name>
```

**View specific user's certificate:**
```bash
oc config view --raw -o jsonpath='{.users[?(@.name=="admin")].user.client-certificate-data}' | \
  base64 -d | openssl x509 -text -noout
```

### Certificate Comparison

**Compare two certificates:**
```bash
# Get fingerprints
openssl x509 -in cert1.pem -noout -fingerprint -sha256
openssl x509 -in cert2.pem -noout -fingerprint -sha256
```

**Check if two certs are the same:**
```bash
diff <(openssl x509 -in cert1.pem -noout -modulus) \
     <(openssl x509 -in cert2.pem -noout -modulus)
```

### Extract Private Key

**Warning:** Only do this if you need to backup/migrate credentials

```bash
# Extract private key from kubeconfig
grep "client-key-data:" ~/Downloads/kubeconfig | \
  awk '{print $2}' | \
  base64 -d > /tmp/client-key.pem

# Verify it matches the certificate
openssl rsa -in /tmp/client-key.pem -check
```

### Test Authentication

**Directly test API server authentication:**
```bash
# Get API server URL
API_SERVER=$(oc whoami --show-server)

# Test with certificate
curl --cert /tmp/client-cert.pem \
     --key /tmp/client-key.pem \
     --cacert /tmp/ca-bundle.crt \
     $API_SERVER/api/v1/namespaces
```

---

## Security Best Practices

1. **Protect your kubeconfig file:**
   ```bash
   chmod 600 ~/Downloads/kubeconfig
   ```

2. **Never commit kubeconfig to version control:**
   ```bash
   echo "*.kubeconfig" >> .gitignore
   echo "kubeconfig*" >> .gitignore
   ```

3. **Regularly rotate certificates:**
   - Admin certificates: Rotate when admins change
   - Service account tokens: Use short-lived tokens when possible

4. **Monitor certificate expiration:**
   ```bash
   # Add to cron for alerts
   0 0 * * * openssl x509 -in ~/.kube/config -noout -checkend $((30*24*60*60)) || \
     echo "Certificate expiring soon!" | mail -s "Cert Alert" admin@example.com
   ```

5. **Use RBAC least privilege:**
   - Don't share cluster-admin kubeconfigs
   - Create service-account specific credentials for applications

6. **Audit kubeconfig usage:**
   ```bash
   # Check who is using your identity
   oc get events --field-selector involvedObject.name=system:admin
   ```

---

## Appendix: File Locations

### OpenShift/Kubernetes

| File/Resource | Location | Purpose |
|---------------|----------|---------|
| CA Bundle ConfigMap | `openshift-kube-apiserver/client-ca` | Trust bundle for client certs |
| kube-apiserver pod | `openshift-kube-apiserver` namespace | API server pods |
| CA mount path | `/etc/kubernetes/static-pod-certs/configmaps/client-ca/ca-bundle.crt` | Inside API server pod |
| Default kubeconfig | `~/.kube/config` | User credentials |
| Admin kubeconfig | `/etc/kubernetes/admin.conf` (on control plane) | Cluster admin access |

### Certificate Components

```
kubeconfig file
├── client-certificate-data  (base64 encoded X.509 certificate)
│   ├── Subject (CN, O)       → Your identity
│   ├── Issuer                → Which CA signed it
│   ├── Validity              → Expiration dates
│   └── Public Key            → For TLS
└── client-key-data          (base64 encoded private key)
    └── Private Key           → For TLS (KEEP SECRET!)
```

---

## Conclusion

This guide provides comprehensive steps to:
1. Extract the cluster's CA trust bundle
2. Extract your client certificate from kubeconfig
3. Verify the certificate is trusted
4. Understand your identity and permissions

**Key Takeaway:** The verification proves that your kubeconfig certificate was signed by a CA that the cluster trusts, enabling you to authenticate to the Kubernetes API server.

For questions or issues, consult:
- OpenShift documentation: https://docs.openshift.com
- Kubernetes documentation: https://kubernetes.io/docs
- OpenSSL documentation: https://www.openssl.org/docs

---

**Document Version:** 1.0  
**Last Updated:** 2026-05-30  
**Author:** Generated from cluster analysis
