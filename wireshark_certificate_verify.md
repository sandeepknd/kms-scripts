# How to See Certificate Verify Message in Wireshark

## Why You Can't See It (The TLS 1.3 Problem)

**The issue:** Modern Kubernetes/OpenShift clusters use **TLS 1.3**, which encrypts the Certificate Verify message. In your Wireshark capture, you see:

```
Packet 1: Client Hello            [Unencrypted - Visible]
Packet 2: Server Hello            [Unencrypted - Visible]  
Packet 3: Change Cipher Spec      [Unencrypted - Visible]
Packet 4: Application Data        [ENCRYPTED - Contains Certificate]
Packet 5: Application Data        [ENCRYPTED - Contains Certificate Verify] ← HERE!
Packet 6: Application Data        [ENCRYPTED - Contains Finished]
```

**What you're looking for** is inside the encrypted "Application Data" packets!

---

## Solution 1: Decrypt TLS 1.3 Traffic in Wireshark

### Complete Step-by-Step Process

#### Step 1: Enable SSL Key Logging

```bash
# Set environment variable to log TLS session keys
export SSLKEYLOGFILE=/tmp/tls-keys.log

# Verify it's set
echo $SSLKEYLOGFILE
```

#### Step 2: Start Packet Capture (Terminal 1)

```bash
# Get API server hostname
API_HOST=$(oc whoami --show-server | sed 's|https://||' | cut -d: -f1)

# Start tcpdump
sudo tcpdump -i any -s 0 -w /tmp/tls-decrypted.pcap \
    "host $API_HOST and port 6443"
```

Leave this running...

#### Step 3: Make API Request (Terminal 2)

```bash
# Ensure SSLKEYLOGFILE is still set
export SSLKEYLOGFILE=/tmp/tls-keys.log

# Extract certificates (if not already done)
grep "client-certificate-data:" ~/Downloads/kubeconfig | awk '{print $2}' | base64 -d > /tmp/client-cert.pem
grep "client-key-data:" ~/Downloads/kubeconfig | awk '{print $2}' | base64 -d > /tmp/client-key.pem
grep "certificate-authority-data:" ~/Downloads/kubeconfig | awk '{print $2}' | base64 -d > /tmp/server-ca.crt

# Make the API call
curl -v \
    --cert /tmp/client-cert.pem \
    --key /tmp/client-key.pem \
    --cacert /tmp/server-ca.crt \
    "$(oc whoami --show-server)/api/v1/namespaces?limit=1"
```

#### Step 4: Stop Capture

Go back to Terminal 1 and press **Ctrl+C** to stop tcpdump.

#### Step 5: Verify Key Log File

```bash
# Check the key file was created and has content
cat /tmp/tls-keys.log
```

**Expected content:**
```
CLIENT_HANDSHAKE_TRAFFIC_SECRET 1234567890abcdef... 9876543210fedcba...
SERVER_HANDSHAKE_TRAFFIC_SECRET 1234567890abcdef... 9876543210fedcba...
CLIENT_TRAFFIC_SECRET_0 1234567890abcdef... 9876543210fedcba...
...
```

#### Step 6: Configure Wireshark for Decryption

**Option A: Via GUI**
1. Open Wireshark
2. Go to: **Edit → Preferences**
3. Expand: **Protocols**
4. Select: **TLS** (or **SSL** in older versions)
5. Find field: **(Pre)-Master-Secret log filename**
6. Click **Browse** and select: `/tmp/tls-keys.log`
7. Click **OK**

**Option B: Via Command Line**
```bash
# Set it permanently in Wireshark config
mkdir -p ~/.config/wireshark
echo "tls.keylog_file: /tmp/tls-keys.log" >> ~/.config/wireshark/preferences
```

#### Step 7: Open Capture and Apply Filters

```bash
wireshark /tmp/tls-decrypted.pcap
```

**Filters to try:**

1. **See all handshake messages:**
   ```
   tls.handshake.type
   ```

2. **See only Certificate Verify (type 15):**
   ```
   tls.handshake.type == 15
   ```

3. **See client-sent handshake messages:**
   ```
   tls.handshake && ip.src == YOUR_CLIENT_IP
   ```

4. **See the complete TLS conversation:**
   ```
   tcp.stream eq 0
   ```

### What You Should See

With decryption enabled, you should see packets like:

```
[Packet Details]
Frame 5: TLSv1.3 Record Layer: Handshake Protocol: Certificate Verify
    TLSv1.3 Record Layer: Handshake Protocol: Certificate Verify
        Content Type: Handshake (22)
        Version: TLS 1.2 (0x0303)  [compatibility]
        Length: 292
        Handshake Protocol: Certificate Verify
            Handshake Type: Certificate Verify (15)
            Length: 264
            Signature Algorithm: rsa_pss_rsae_sha256 (0x0804)
                Signature Hash Algorithm Hash: SHA256 (4)
                Signature Hash Algorithm Signature: rsa_pss_rsae (8)
            Signature Length: 256
            Signature: a6dc403f22f8eba8edf3e4491bbd33b0d2cfb405...
```

**This signature is the proof that your private key was used!**

---
<img width="1905" height="1066" alt="image" src="https://github.com/user-attachments/assets/6a53934d-3f34-49d4-b206-01281217ec7e" />

## Solution 2: Using curl --trace (No Wireshark Needed)

This is easier and shows you the Certificate Verify message directly.

### Command

```bash
curl --trace-ascii /tmp/curl-trace.txt \
    --cert /tmp/client-cert.pem \
    --key /tmp/client-key.pem \
    --cacert /tmp/server-ca.crt \
    "$(oc whoami --show-server)/api/v1/namespaces?limit=1" \
    > /dev/null 2>&1

# Search for Certificate Verify
grep -i "certificate" /tmp/curl-trace.txt | head -20
```

### What You'll See

In the trace file:

```
<= Recv SSL data, 5 bytes (0x5)
0000: 16 03 03 00 42                                  ....B
<= Recv SSL data, 66 bytes (0x42)
...
== Info: TLSv1.3 (IN), TLS handshake, Certificate (11):
<= Recv data, 2389 bytes (0x955)
...
== Info: TLSv1.3 (OUT), TLS handshake, Certificate (11):
=> Send data, 1497 bytes (0x5d9)
...
== Info: TLSv1.3 (OUT), TLS handshake, CERT verify (15):  ← HERE!
=> Send data, 288 bytes (0x120)
0000: 0f 00 01 08 08 04 01 00 a6 dc 40 3f 22 f8 eb a8  ..........@?"...
0010: ed f3 e4 49 1b bd 33 b0 d2 cf b4 05 f9 7f 92 cd  ...I..3.........
...
```

**The key line:** `TLSv1.3 (OUT), TLS handshake, CERT verify (15)`

This proves the Certificate Verify message was sent with your private key signature!

---

## Solution 3: Force TLS 1.2 (For Educational Purposes Only)

**WARNING:** This is for demonstration only. Don't use in production!

TLS 1.2 doesn't encrypt the Certificate Verify message, making it visible.

### Force TLS 1.2 Connection

```bash
# Try connecting with TLS 1.2 maximum
curl -v \
    --tls-max 1.2 \
    --cert /tmp/client-cert.pem \
    --key /tmp/client-key.pem \
    --cacert /tmp/server-ca.crt \
    "$(oc whoami --show-server)/api/v1/namespaces?limit=1"
```

**Note:** Modern Kubernetes clusters may reject TLS 1.2 connections.

If it works, the Wireshark capture will show Certificate Verify **unencrypted** without needing SSLKEYLOGFILE.

---

## Troubleshooting Wireshark

### Problem: Still See "Application Data"

**Cause:** Wireshark hasn't loaded the key file properly.

**Solution:**
1. Close and reopen Wireshark
2. Verify path in **Edit → Preferences → Protocols → TLS**
3. Check `/tmp/tls-keys.log` has content
4. Ensure the capture was taken AFTER setting SSLKEYLOGFILE

### Problem: No Key Log File Created

**Cause:** curl/openssl didn't export keys.

**Solution:**
```bash
# Verify environment variable is set
echo $SSLKEYLOGFILE

# Re-export and try again
export SSLKEYLOGFILE=/tmp/tls-keys.log

# Make sure the file is writable
touch /tmp/tls-keys.log
chmod 644 /tmp/tls-keys.log
```

### Problem: "Permission Denied" on tcpdump

**Cause:** Need root privileges to capture packets.

**Solution:**
```bash
# Use sudo
sudo tcpdump -i any -s 0 -w /tmp/capture.pcap "port 6443"

# Or grant capabilities (Linux only)
sudo setcap cap_net_raw,cap_net_admin=eip $(which tcpdump)
```

---

## Alternative: Analyze Without Seeing the Message

Even if you can't decrypt TLS 1.3, you can **prove** the Certificate Verify message exists:

### Method 1: Byte Count Analysis

```bash
echo "Q" | openssl s_client \
    -connect "$(oc whoami --show-server | sed 's|https://||')" \
    -cert /tmp/client-cert.pem \
    -key /tmp/client-key.pem \
    -CAfile /tmp/server-ca.crt 2>&1 | \
    grep "SSL handshake"
```

**Expected output:**
```
SSL handshake has read 4044 bytes and written 3672 bytes
```

**Analysis:**
- **Written bytes (3672)** include:
  - Client Hello: ~512 bytes
  - Client Certificate: ~1200 bytes
  - **Certificate Verify: ~290 bytes** ← This proves it was sent!
  - Finished: ~50 bytes
  - Application data: remaining

### Method 2: Comparative Test

**Test A: With Private Key**
```bash
curl -s --cert /tmp/client-cert.pem --key /tmp/client-key.pem \
    --cacert /tmp/server-ca.crt \
    "$(oc whoami --show-server)/api/v1/namespaces?limit=1" | \
    jq -r '.kind'
```
**Result:** `NamespaceList` ✅

**Test B: Without Private Key**
```bash
curl -s --cert /tmp/client-cert.pem \
    --cacert /tmp/server-ca.crt \
    "$(oc whoami --show-server)/api/v1/namespaces" 2>&1 | \
    grep -i error
```
**Result:** `unable to set private key file` ❌

**Conclusion:** The private key is required, which means Certificate Verify is mandatory and was sent.

---

## Understanding TLS 1.3 Encryption Timeline

```
┌──────────────────────────────────────────────────────────────┐
│ TLS 1.3 Handshake (Client perspective)                      │
└──────────────────────────────────────────────────────────────┘

UNENCRYPTED PHASE:
─────────────────────────────────────────────────────────────
→ Client Hello
    - Supported ciphers
    - Key exchange parameters
    
← Server Hello
    - Selected cipher
    - Key exchange parameters
    
← Change Cipher Spec (compatibility marker)


ENCRYPTED PHASE (from here on):
─────────────────────────────────────────────────────────────
← Encrypted Extensions
← Certificate Request         ← Server asks for client cert
← Server Certificate
← Certificate Verify          ← Server proves ownership
← Finished

→ Client Certificate          ← You send your cert
→ Certificate Verify          ← YOU PROVE OWNERSHIP! 
→ Finished                       (signed with private key)

← New Session Ticket
→ Application Data (HTTP request)
← Application Data (HTTP response)
```

**Key insight:** Everything after "Change Cipher Spec" is encrypted in TLS 1.3, including the Certificate Verify message you're looking for!

---

## Complete Working Example Script

Save this as `/tmp/capture_cert_verify.sh`:

```bash
#!/bin/bash

set -e

echo "╔══════════════════════════════════════════════════════════════════╗"
echo "║  Capture and Decrypt TLS 1.3 to See Certificate Verify          ║"
echo "╚══════════════════════════════════════════════════════════════════╝"
echo

# Setup
API_SERVER=$(oc whoami --show-server)
API_HOST=$(echo "$API_SERVER" | sed 's|https://||' | cut -d: -f1)

echo "API Server: $API_SERVER"
echo "Hostname: $API_HOST"
echo

# Extract credentials
grep "client-certificate-data:" ~/Downloads/kubeconfig | awk '{print $2}' | base64 -d > /tmp/client-cert.pem
grep "client-key-data:" ~/Downloads/kubeconfig | awk '{print $2}' | base64 -d > /tmp/client-key.pem
grep "certificate-authority-data:" ~/Downloads/kubeconfig | awk '{print $2}' | base64 -d > /tmp/server-ca.crt

echo "✓ Credentials extracted"
echo

# Enable key logging
export SSLKEYLOGFILE=/tmp/tls-keys.log
rm -f /tmp/tls-keys.log
touch /tmp/tls-keys.log

echo "✓ SSL key logging enabled: $SSLKEYLOGFILE"
echo

# Start capture in background
echo "Starting packet capture (requires sudo)..."
sudo tcpdump -i any -s 0 -w /tmp/cert-verify.pcap \
    "host $API_HOST and port 6443" &
TCPDUMP_PID=$!

echo "✓ tcpdump started (PID: $TCPDUMP_PID)"
echo

# Wait for tcpdump to initialize
sleep 2

# Make API request
echo "Making API request..."
curl -s \
    --cert /tmp/client-cert.pem \
    --key /tmp/client-key.pem \
    --cacert /tmp/server-ca.crt \
    "$API_SERVER/api/v1/namespaces?limit=1" | \
    jq -r '.kind' || echo "Request failed"

echo "✓ Request completed"
echo

# Stop capture
sleep 1
sudo kill $TCPDUMP_PID 2>/dev/null || true
wait $TCPDUMP_PID 2>/dev/null || true

echo "✓ Packet capture stopped"
echo

# Verify key file
if [ -s /tmp/tls-keys.log ]; then
    echo "✓ TLS keys logged ($(wc -l < /tmp/tls-keys.log) keys)"
else
    echo "⚠ Warning: Key log file is empty"
fi

echo
echo "═══════════════════════════════════════════════════════════════"
echo " Files Created:"
echo "═══════════════════════════════════════════════════════════════"
echo "  Packet capture: /tmp/cert-verify.pcap"
echo "  TLS keys:       /tmp/tls-keys.log"
echo

echo "═══════════════════════════════════════════════════════════════"
echo " Next Steps:"
echo "═══════════════════════════════════════════════════════════════"
echo "1. Open Wireshark"
echo "2. Edit → Preferences → Protocols → TLS"
echo "3. Set '(Pre)-Master-Secret log filename' to:"
echo "   /tmp/tls-keys.log"
echo "4. Open: /tmp/cert-verify.pcap"
echo "5. Filter: tls.handshake.type == 15"
echo
echo "You should now see the decrypted Certificate Verify message!"
echo
```

**Run it:**
```bash
chmod +x /tmp/capture_cert_verify.sh
/tmp/capture_cert_verify.sh
```

---

## Summary

### Why You Couldn't See It

- ✅ You did everything correctly
- ❌ TLS 1.3 encrypts Certificate Verify by default
- ❌ Wireshark can't decrypt without session keys

### How to See It

**Option 1: Use SSLKEYLOGFILE (Best)**
- Export TLS session keys
- Configure Wireshark to use them
- See the decrypted Certificate Verify message

**Option 2: Use curl --trace (Easiest)**
- Shows Certificate Verify in text trace
- No Wireshark needed
- Proves the message was sent

**Option 3: Prove it indirectly**
- Byte count analysis
- Comparative tests (with/without private key)
- Logical deduction from successful authentication

### Key Takeaway

**The Certificate Verify message is always sent in mutual TLS**, even if you can't see it in Wireshark. TLS 1.3's encryption makes it invisible without decryption keys, but:

1. `curl --trace` shows it being sent
2. Byte counts prove it's included
3. Successful authentication proves it was verified
4. SSLKEYLOGFILE + Wireshark can decrypt and show it

The encryption doesn't mean it's not there—it means your connection is secure!

---

**Document Version:** 1.0  
**Last Updated:** 2026-05-30  
**Purpose:** Troubleshooting guide for seeing Certificate Verify in TLS 1.3

---

# Part 3: Understanding the Code Behind TLS Certificate Verify

Now that you've successfully seen the Certificate Verify message in Wireshark, let's dive into the actual code that creates and verifies this cryptographic signature.

---

# TLS Certificate Verify Code Flow: Client Signature Creation and Server Verification

This document traces the complete code flow showing how the client's private key is used to create the Certificate Verify signature and how the server verifies it using the public key.

## Table of Contents

1. [Overview](#overview)
2. [The Critical Distinction](#the-critical-distinction)
3. [Client Side: Creating the Signature](#client-side-creating-the-signature)
4. [Server Side: Verifying the Signature](#server-side-verifying-the-signature)
5. [Complete Code Path](#complete-code-path)
6. [Source Code Locations](#source-code-locations)
7. [The Cryptographic Mathematics](#the-cryptographic-mathematics)

---

## Overview

When you connect to a Kubernetes API server with client certificate authentication, the TLS handshake involves:

1. **Client Side**: Uses **private key** to CREATE a signature
2. **Server Side**: Uses **public key** to VERIFY the signature

**Critical Point:** The private key NEVER leaves the client machine. Only the signature is transmitted.

```
┌─────────────────────────────────────────────────────────────────┐
│ YOUR MACHINE (curl/oc)                                          │
├─────────────────────────────────────────────────────────────────┤
│ Private Key (client-key-data) → Sign handshake hash            │
│                                → Create 256-byte signature      │
│                                → Send in Certificate Verify     │
└────────────────────────┬────────────────────────────────────────┘
                         │
                         │ Network: Signature transmitted (NOT private key)
                         ▼
┌─────────────────────────────────────────────────────────────────┐
│ KUBE-APISERVER                                                  │
├─────────────────────────────────────────────────────────────────┤
│ Public Key (from client cert) → Verify signature               │
│                                → Compare with expected hash     │
│                                → If match: Authentication ✅    │
└─────────────────────────────────────────────────────────────────┘
```

---

## The Critical Distinction

### What the Private Key Does

**Location:** Client machine (your laptop/terminal)

**Purpose:** Creates a cryptographic signature

**Operation:**
```
Hash = SHA256(ClientHello + ServerHello + ... + ClientCert)
Signature = RSA_Sign(Hash, PrivateKey)
```

The signature proves: "I have the private key that matches the public key in my certificate"

### What the Public Key Does

**Location:** Server (kube-apiserver)

**Purpose:** Verifies the cryptographic signature

**Operation:**
```
PublicKey = ExtractFrom(ClientCertificate)
ComputedHash = RSA_Verify(Signature, PublicKey)
If ComputedHash == ExpectedHash: Success!
```

The verification confirms: "The signature was created by the private key matching this public key"

---

## Client Side: Creating the Signature

### Layer 1: Loading the Private Key

**Repository:** `golang/go`  
**File:** `src/crypto/tls/tls.go`  
**Function:** `LoadX509KeyPair()`

```go
// Loads certificate and private key from files
func LoadX509KeyPair(certFile, keyFile string) (Certificate, error) {
    // Read certificate file
    certPEMBlock, err := os.ReadFile(certFile)
    if err != nil {
        return Certificate{}, err
    }
    
    // Read private key file
    // This is YOUR client-key-data from kubeconfig
    keyPEMBlock, err := os.ReadFile(keyFile)
    if err != nil {
        return Certificate{}, err
    }
    
    return X509KeyPair(certPEMBlock, keyPEMBlock)
}

func X509KeyPair(certPEMBlock, keyPEMBlock []byte) (Certificate, error) {
    // Parse the certificate
    var cert Certificate
    for {
        var certDERBlock *pem.Block
        certDERBlock, certPEMBlock = pem.Decode(certPEMBlock)
        if certDERBlock == nil {
            break
        }
        cert.Certificate = append(cert.Certificate, certDERBlock.Bytes)
    }
    
    // Parse the private key (converts PEM to *rsa.PrivateKey)
    var keyDERBlock *pem.Block
    for {
        keyDERBlock, keyPEMBlock = pem.Decode(keyPEMBlock)
        if keyDERBlock == nil {
            return Certificate{}, errors.New("failed to find any PEM data in key")
        }
        if keyDERBlock.Type == "PRIVATE KEY" || 
           strings.HasSuffix(keyDERBlock.Type, " PRIVATE KEY") {
            break
        }
    }
    
    // Parse the actual private key structure
    key, err := parsePrivateKey(keyDERBlock.Bytes)
    if err != nil {
        return Certificate{}, err
    }
    
    // Store the private key in the certificate structure
    cert.PrivateKey = key  // ← YOUR PRIVATE KEY IS HERE
    
    return cert, nil
}
```

**What happens:**
- Reads your `client-key-data` from kubeconfig
- Converts PEM format → `*rsa.PrivateKey` structure
- Stores in `Certificate.PrivateKey` field

---

### Layer 2: Creating the Signature

**Repository:** `golang/go`  
**File:** `src/crypto/tls/handshake_client_tls13.go`  
**Function:** `sendClientCertificate()`

```go
func (hs *clientHandshakeStateTLS13) sendClientCertificate() error {
    c := hs.c

    // Send the Client Certificate message
    certMsg := &certificateMsg{
        certificate: *c.config.Certificates[0],
    }
    hs.transcript.Write(certMsg.marshal())
    if _, err := c.writeRecord(recordTypeHandshake, certMsg.marshal()); err != nil {
        return err
    }

    // ═══════════════════════════════════════════════════════════════
    // CREATE CERTIFICATE VERIFY MESSAGE
    // ═══════════════════════════════════════════════════════════════
    
    certVerifyMsg := new(certificateVerifyMsg)
    certVerifyMsg.hasSignatureAlgorithm = true

    // Choose the signature algorithm (e.g., rsa_pss_rsae_sha256)
    certVerifyMsg.signatureAlgorithm = supportedSignatureAlgorithm

    // Build the message to sign
    // This includes all handshake messages exchanged so far
    signed := signedMessage(hs.transcript.Sum(nil), clientSignatureContext)
    
    // Get the signature algorithm's hash function
    signOpts := crypto.SignerOpts(signatureAlgorithm.Hash())
    
    // ═══════════════════════════════════════════════════════════════
    // THIS IS WHERE YOUR PRIVATE KEY IS USED!
    // ═══════════════════════════════════════════════════════════════
    
    // Get the private key from the certificate
    // This is the key loaded from client-key-data
    privateKey := c.config.Certificates[0].PrivateKey.(crypto.Signer)
    
    // CRITICAL LINE: Sign the handshake hash with YOUR PRIVATE KEY
    // This creates the 256-byte signature you saw in Wireshark
    sig, err := privateKey.Sign(c.config.rand(), signed, signOpts)
    //          ^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^
    //          Calls SignPSS() which uses your private exponent
    
    if err != nil {
        c.sendAlert(alertInternalError)
        return fmt.Errorf("tls: failed to sign handshake: %w", err)
    }

    // Put the signature in the Certificate Verify message
    certVerifyMsg.signature = sig

    // Marshal and send the Certificate Verify message
    hs.transcript.Write(certVerifyMsg.marshal())
    if _, err := c.writeRecord(recordTypeHandshake, certVerifyMsg.marshal()); err != nil {
        return err
    }

    return nil
}
```

**What happens:**
1. Hash all previous handshake messages (ClientHello, ServerHello, certificates, etc.)
2. Extract your private key from the certificate
3. Call `privateKey.Sign()` which triggers RSA-PSS signing
4. Get back a 256-byte signature
5. Send it in the Certificate Verify message

---

### Layer 3: RSA-PSS Signature Creation

**Repository:** `golang/go`  
**File:** `src/crypto/rsa/pss.go`  
**Function:** `SignPSS()`

```go
// SignPSS calculates the signature of digest using PSS.
func SignPSS(
    rand io.Reader,
    priv *PrivateKey,      // ← YOUR PRIVATE KEY
    hash crypto.Hash,
    digest []byte,         // ← Hash of handshake messages
    opts *PSSOptions,
) ([]byte, error) {
    
    // Validate the hash algorithm
    if err := checkHash(hash); err != nil {
        return nil, err
    }

    // Get salt length for PSS padding
    saltLength := opts.saltLengthOrDefault()
    if saltLength < 0 {
        return nil, errors.New("crypto/rsa: salt length too large")
    }

    // Generate random salt
    salt := make([]byte, saltLength)
    if _, err := io.ReadFull(rand, salt); err != nil {
        return nil, err
    }

    // Calculate the number of bits in the modulus
    emBits := priv.N.BitLen() - 1

    // Apply PSS padding to the digest
    em, err := emsaPSSEncode(digest, emBits, salt, hash.New())
    if err != nil {
        return nil, err
    }

    // ═══════════════════════════════════════════════════════════════
    // ACTUAL RSA SIGNATURE OPERATION
    // ═══════════════════════════════════════════════════════════════
    
    // Convert the padded message to a big integer
    m := new(big.Int).SetBytes(em)
    
    // Perform RSA signature: s = m^d mod n
    // This uses YOUR PRIVATE EXPONENT (d)
    c, err := decryptAndCheck(rand, priv, m)
    //                              ^^^^
    //                              YOUR PRIVATE KEY STRUCTURE
    if err != nil {
        return nil, err
    }

    // Convert the signature back to bytes
    s := c.Bytes()
    
    // Pad to the correct length (256 bytes for RSA-2048)
    return leftPad(s, priv.Size()), nil
}
```

**What happens:**
1. Apply PSS padding to the hash
2. Convert to a big integer
3. Call `decryptAndCheck()` which performs the RSA operation
4. Return 256-byte signature

---

### Layer 4: The Actual Mathematical Operation

**Repository:** `golang/go`  
**File:** `src/crypto/rsa/rsa.go`  
**Function:** `decrypt()`

```go
// decrypt performs an RSA decryption using the private key.
// For signing, this is the "decryption" of the padded hash.
func decrypt(priv *PrivateKey, c *big.Int) (m *big.Int, err error) {
    // Check if we have precomputed values (CRT optimization)
    if priv.Precomputed.Dp == nil {
        // ═══════════════════════════════════════════════════════════
        // STANDARD RSA SIGNATURE: m = c^d mod n
        // ═══════════════════════════════════════════════════════════
        
        m = new(big.Int).Exp(c, priv.D, priv.N)
        //                       ^^^^^^  ^^^^^^
        //                       YOUR     YOUR
        //                       PRIVATE  MODULUS
        //                       EXPONENT
        //                       (SECRET!)
        
    } else {
        // ═══════════════════════════════════════════════════════════
        // OPTIMIZED RSA USING CHINESE REMAINDER THEOREM (CRT)
        // Faster computation using private primes p and q
        // ═══════════════════════════════════════════════════════════
        
        // m1 = c^dp mod p
        m := new(big.Int).Exp(c, priv.Precomputed.Dp, priv.Primes[0])
        //                        ^^^^^^^^^^^^^^^^^^^^  ^^^^^^^^^^^^^^
        //                        d mod (p-1)           Prime p (secret!)
        
        // m2 = c^dq mod q
        m2 := new(big.Int).Exp(c, priv.Precomputed.Dq, priv.Primes[1])
        //                         ^^^^^^^^^^^^^^^^^^^^  ^^^^^^^^^^^^^^
        //                         d mod (q-1)           Prime q (secret!)
        
        // Combine using CRT
        m.Sub(m, m2)
        m.Mul(m, priv.Precomputed.Qinv)
        m.Mod(m, priv.Primes[0])
        m.Mul(m, priv.Primes[1])
        m.Add(m, m2)
    }
    
    return m, nil
}
```

**What happens:**

This is the **actual RSA mathematical operation**:

**Standard RSA:**
```
signature = message^d mod n
```
Where:
- `message` = padded hash of handshake
- `d` = your **private exponent** (the secret!)
- `n` = your modulus (public)
- `signature` = the 256 bytes sent to server

**Optimized RSA (CRT):**
Uses your private primes `p` and `q` for faster computation.

This is the **secret operation** that only you can perform because only you have `d`, `p`, and `q`!

---

## Server Side: Verifying the Signature

### Layer 1: Receiving the Certificate Verify Message

**Repository:** `golang/go`  
**File:** `src/crypto/tls/handshake_server_tls13.go`  
**Function:** `readClientCertificate()`

```go
func (hs *serverHandshakeStateTLS13) readClientCertificate() error {
    c := hs.c

    // Read the client's Certificate message
    certMsg, err := c.readHandshake()
    if err != nil {
        return err
    }
    
    // Parse the certificates
    if len(certMsg.certificates) == 0 {
        return errors.New("tls: client didn't provide a certificate")
    }
    
    // Store the peer (client) certificates
    c.peerCertificates = certMsg.certificates

    // ═══════════════════════════════════════════════════════════════
    // READ CERTIFICATE VERIFY MESSAGE
    // ═══════════════════════════════════════════════════════════════
    
    certVerifyMsg, err := c.readHandshake()
    if err != nil {
        return err
    }
    
    certVerify, ok := certVerifyMsg.(*certificateVerifyMsg)
    if !ok {
        c.sendAlert(alertUnexpectedMessage)
        return unexpectedMessageError(certVerify, certVerifyMsg)
    }

    // ═══════════════════════════════════════════════════════════════
    // EXTRACT PUBLIC KEY FROM CLIENT CERTIFICATE
    // ═══════════════════════════════════════════════════════════════
    
    // Get the client's public key from their certificate
    // NOT the private key - we don't have it!
    pubKey := c.peerCertificates[0].PublicKey

    // Build the signed message (same as client did)
    signed := signedMessage(hs.transcript.Sum(nil), clientSignatureContext)

    // ═══════════════════════════════════════════════════════════════
    // VERIFY THE SIGNATURE USING THE PUBLIC KEY
    // ═══════════════════════════════════════════════════════════════
    
    err = verifyHandshakeSignature(
        certVerify.signatureAlgorithm,
        pubKey,                    // ← PUBLIC KEY from certificate
        crypto.Hash(0),
        signed,                    // ← Hash we expect
        certVerify.signature,      // ← Signature from Certificate Verify
    )
    
    if err != nil {
        c.sendAlert(alertDecryptError)
        return errors.New("tls: invalid signature by the client certificate")
    }

    // ═══════════════════════════════════════════════════════════════
    // VERIFY CERTIFICATE CHAIN AGAINST CA BUNDLE
    // ═══════════════════════════════════════════════════════════════
    
    opts := x509.VerifyOptions{
        Roots:         c.config.ClientCAs,  // ← The CA bundle from client-ca-file
        CurrentTime:   c.config.time(),
        Intermediates: x509.NewCertPool(),
        KeyUsages:     []x509.ExtKeyUsage{x509.ExtKeyUsageClientAuth},
    }
    
    chains, err := c.peerCertificates[0].Verify(opts)
    if err != nil {
        c.sendAlert(alertBadCertificate)
        return &CertificateVerificationError{
            UnverifiedCertificates: c.peerCertificates,
            Err: err,
        }
    }
    
    c.verifiedChains = chains

    // SUCCESS! Both checks passed:
    // 1. Signature is valid (proves client owns the private key)
    // 2. Certificate is trusted (signed by a CA in our bundle)
    return nil
}
```

**What happens:**
1. Receive Certificate Verify message with signature
2. Extract **public key** from client certificate
3. Verify signature using the public key
4. Verify certificate was signed by trusted CA
5. If both pass → Authentication succeeds!

---

### Layer 2: Signature Verification Dispatcher

**Repository:** `golang/go`  
**File:** `src/crypto/tls/auth.go`  
**Function:** `verifyHandshakeSignature()`

```go
func verifyHandshakeSignature(
    sigType uint8,
    pubkey crypto.PublicKey,
    hashFunc crypto.Hash,
    signed, sig []byte,
) error {
    switch sigType {
    case signatureRSAPSS, signaturePKCS1v15:
        // RSA signature verification
        rsaKey, ok := pubkey.(*rsa.PublicKey)
        if !ok {
            return errors.New("tls: certificate private key does not implement crypto.Signer")
        }
        
        if sigType == signatureRSAPSS {
            // ═══════════════════════════════════════════════════════
            // RSA-PSS VERIFICATION
            // ═══════════════════════════════════════════════════════
            return rsa.VerifyPSS(
                rsaKey,       // ← PUBLIC KEY
                hashFunc,
                signed,       // ← Expected hash
                sig,          // ← Signature from client
                &rsa.PSSOptions{SaltLength: rsa.PSSSaltLengthEqualsHash},
            )
        } else {
            // RSA PKCS#1 v1.5 verification
            return rsa.VerifyPKCS1v15(rsaKey, hashFunc, signed, sig)
        }
        
    case signatureECDSA:
        // ECDSA signature verification
        ecdsaKey, ok := pubkey.(*ecdsa.PublicKey)
        if !ok {
            return errors.New("tls: ECDSA signing requires a ECDSA public key")
        }
        if !ecdsa.VerifyASN1(ecdsaKey, signed, sig) {
            return errors.New("tls: ECDSA verification failure")
        }
        
    case signatureEd25519:
        // Ed25519 signature verification
        ed25519Key, ok := pubkey.(ed25519.PublicKey)
        if !ok {
            return errors.New("tls: Ed25519 signing requires a Ed25519 public key")
        }
        if !ed25519.Verify(ed25519Key, signed, sig) {
            return errors.New("tls: Ed25519 verification failure")
        }
        
    default:
        return errors.New("tls: internal error: unsupported signature type")
    }
    
    return nil
}
```

**What happens:**
- Dispatches to the correct verification function based on algorithm
- For RSA-PSS (most common), calls `rsa.VerifyPSS()`

---

### Layer 3: RSA-PSS Verification

**Repository:** `golang/go`  
**File:** `src/crypto/rsa/pss.go`  
**Function:** `VerifyPSS()`

```go
// VerifyPSS verifies a PSS signature.
func VerifyPSS(
    pub *PublicKey,        // ← PUBLIC KEY (not private!)
    hash crypto.Hash,
    digest []byte,         // ← Expected hash
    sig []byte,            // ← Signature to verify
    opts *PSSOptions,
) error {
    
    // Validate inputs
    if err := checkHash(hash); err != nil {
        return err
    }
    
    // Check signature length matches key size
    if len(sig) != pub.Size() {
        return ErrVerification
    }

    // ═══════════════════════════════════════════════════════════════
    // ACTUAL RSA VERIFICATION OPERATION
    // ═══════════════════════════════════════════════════════════════
    
    // Convert signature bytes to big integer
    s := new(big.Int).SetBytes(sig)
    
    // Perform RSA verification: m = s^e mod n
    // This uses ONLY the PUBLIC KEY
    m := new(big.Int).Exp(s, big.NewInt(int64(pub.E)), pub.N)
    //                        ^^^^^^^^^^^^^^^^^^^^^^^^  ^^^^^^
    //                        PUBLIC EXPONENT           PUBLIC
    //                        (usually 65537)           MODULUS
    
    // Convert back to bytes
    emLen := pub.Size() - 1
    emBits := pub.N.BitLen() - 1
    em := leftPad(m.Bytes(), emLen)

    // ═══════════════════════════════════════════════════════════════
    // VERIFY PSS PADDING AND COMPARE HASH
    // ═══════════════════════════════════════════════════════════════
    
    // Verify the PSS padding structure
    err := emsaPSSVerify(digest, em, emBits, opts.saltLengthOrDefault(), hash.New())
    if err != nil {
        return ErrVerification
    }

    return nil
}
```

**What happens:**

This is the **actual RSA mathematical verification**:

```
decrypted_hash = signature^e mod n
```

Where:
- `signature` = the 256 bytes from Certificate Verify message
- `e` = public exponent (typically 65537)
- `n` = public modulus
- `decrypted_hash` = should match the expected hash

**Key Point:** This uses ONLY public values (`e` and `n`). No secrets needed!

If the decrypted hash matches the expected hash → The signature was created by the corresponding private key!

---

## Complete Code Path

### Client Side (Creating Signature)

```
1. User runs: curl --cert client-cert.pem --key client-key.pem https://...

2. crypto/tls/tls.go: LoadX509KeyPair()
   └─> Reads client-key.pem
   └─> Parses PEM format
   └─> Returns *rsa.PrivateKey structure
       ├─> N (modulus)
       ├─> D (private exponent) ← SECRET!
       ├─> Primes[0] (p) ← SECRET!
       └─> Primes[1] (q) ← SECRET!

3. crypto/tls/handshake_client_tls13.go: sendClientCertificate()
   └─> Hash all handshake messages
   └─> Call privateKey.Sign(hash, opts)

4. crypto/rsa/pss.go: SignPSS()
   └─> Apply PSS padding
   └─> Call decryptAndCheck(priv, paddedHash)

5. crypto/rsa/rsa.go: decrypt()
   └─> Perform: signature = paddedHash^d mod n
       Uses priv.D (private exponent)
   └─> Return 256-byte signature

6. crypto/tls/handshake_client_tls13.go: sendClientCertificate()
   └─> Put signature in Certificate Verify message
   └─> Send to server

         │
         │ Network
         ▼
```

### Server Side (Verifying Signature)

```
         │
         │ Network
         ▼

1. crypto/tls/handshake_server_tls13.go: readClientCertificate()
   └─> Receive Certificate Verify message
   └─> Extract signature from message
   └─> Extract PUBLIC KEY from client certificate
       ├─> N (modulus)
       └─> E (public exponent) - usually 65537

2. crypto/tls/auth.go: verifyHandshakeSignature()
   └─> Dispatch to rsa.VerifyPSS()

3. crypto/rsa/pss.go: VerifyPSS()
   └─> Perform: hash = signature^e mod n
       Uses pub.E (public exponent)
       Uses pub.N (public modulus)
   └─> Verify PSS padding
   └─> Compare computed hash with expected hash

4. crypto/tls/handshake_server_tls13.go: readClientCertificate()
   └─> If verification succeeds:
       ✅ Client owns the private key
   └─> Verify certificate against CA bundle
       
5. If both checks pass:
   ✅ Authentication succeeds
   ✅ Connection established
```

---

## Source Code Locations

### Client Side Code

| Layer | Repository | File | Function | Line |
|-------|-----------|------|----------|------|
| **Load Private Key** | golang/go | `src/crypto/tls/tls.go` | `LoadX509KeyPair()` | ~240 |
| **Parse Private Key** | golang/go | `src/crypto/tls/tls.go` | `X509KeyPair()` | ~260 |
| **Sign Handshake** | golang/go | `src/crypto/tls/handshake_client_tls13.go` | `sendClientCertificate()` | ~650 |
| **RSA-PSS Sign** | golang/go | `src/crypto/rsa/pss.go` | `SignPSS()` | ~250 |
| **RSA Math** | golang/go | `src/crypto/rsa/rsa.go` | `decrypt()` | ~390 |

### Server Side Code

| Layer | Repository | File | Function | Line |
|-------|-----------|------|----------|------|
| **Read Cert Verify** | golang/go | `src/crypto/tls/handshake_server_tls13.go` | `readClientCertificate()` | ~600 |
| **Verify Dispatch** | golang/go | `src/crypto/tls/auth.go` | `verifyHandshakeSignature()` | ~140 |
| **RSA-PSS Verify** | golang/go | `src/crypto/rsa/pss.go` | `VerifyPSS()` | ~310 |

### GitHub Links

**Go TLS Library:**
- Repository: https://github.com/golang/go
- Client handshake: `src/crypto/tls/handshake_client_tls13.go`
- Server handshake: `src/crypto/tls/handshake_server_tls13.go`
- RSA operations: `src/crypto/rsa/rsa.go`
- RSA-PSS: `src/crypto/rsa/pss.go`

---

## The Cryptographic Mathematics

### RSA Key Pair Structure

```go
// Private Key (client side)
type PrivateKey struct {
    PublicKey            // Embedded public key
    D         *big.Int   // Private exponent (SECRET!)
    Primes    []*big.Int // Prime factors (SECRET!)
    
    Precomputed struct {
        Dp   *big.Int     // D mod (P-1) for CRT (SECRET!)
        Dq   *big.Int     // D mod (Q-1) for CRT (SECRET!)
        Qinv *big.Int     // Q^-1 mod P for CRT (SECRET!)
    }
}

// Public Key (server side)
type PublicKey struct {
    N *big.Int // Modulus (PUBLIC)
    E int      // Public exponent (PUBLIC, usually 65537)
}
```

### The Mathematical Operations

**Client (Signing):**
```
Given:
  - message (padded hash of handshake)
  - d (private exponent)
  - n (modulus)

Compute:
  signature = message^d mod n

This is the RSA "decryption" operation
Only possible with knowledge of d (the private exponent)
```

**Server (Verifying):**
```
Given:
  - signature (from Certificate Verify message)
  - e (public exponent, typically 65537)
  - n (modulus)

Compute:
  recovered_message = signature^e mod n

Compare:
  If recovered_message == expected_message:
    ✅ Signature is valid
    ✅ Signer has the private key
```

### Why This Works

The mathematical relationship:
```
(message^d)^e ≡ message (mod n)
```

This is the RSA trapdoor function:
- **Easy** to compute with private key: `message^d mod n`
- **Easy** to verify with public key: `signature^e mod n`
- **Hard** to forge signature without private key (requires factoring n)

The security relies on the difficulty of factoring the modulus `n` into its prime factors `p` and `q`.

---

## Summary Diagram

```
┌──────────────────────────────────────────────────────────────────┐
│ CLIENT MACHINE                                                   │
└──────────────────────────────────────────────────────────────────┘

  kubeconfig
  ├─ client-certificate-data (Your certificate with PUBLIC key)
  └─ client-key-data (Your PRIVATE key)
      │
      │ Loaded by: crypto/tls/tls.go: LoadX509KeyPair()
      ▼
  *rsa.PrivateKey {
      N: <modulus>
      D: <private exponent> ← YOUR SECRET!
      Primes: [p, q] ← YOUR SECRET!
  }
      │
      │ TLS Handshake begins
      ▼
  crypto/tls/handshake_client_tls13.go
      │
      │ Hash = SHA256(handshake messages)
      │ privateKey.Sign(Hash)
      ▼
  crypto/rsa/pss.go: SignPSS()
      │
      │ Apply PSS padding
      ▼
  crypto/rsa/rsa.go: decrypt()
      │
      │ signature = Hash^d mod n
      │             Uses D (private exponent)
      ▼
  256-byte signature
      │
      │ Embedded in Certificate Verify message
      │
      ├─────────────────────────────────────────────────────┐
      │                                                      │
      │ NETWORK: Only signature transmitted, NOT private key│
      │                                                      │
      └─────────────────────────────────────────────────────┘
                                │
                                ▼

┌──────────────────────────────────────────────────────────────────┐
│ KUBE-APISERVER                                                   │
└──────────────────────────────────────────────────────────────────┘

  Receive Certificate Verify message
      │
      ▼
  crypto/tls/handshake_server_tls13.go: readClientCertificate()
      │
      │ Extract signature from message
      │ Extract PUBLIC KEY from client certificate
      ▼
  *rsa.PublicKey {
      N: <modulus> (same as client)
      E: 65537 (public exponent)
  }
      │
      │ verifyHandshakeSignature()
      ▼
  crypto/rsa/pss.go: VerifyPSS()
      │
      │ recovered_hash = signature^e mod n
      │                  Uses E (public exponent)
      ▼
  Compare: recovered_hash == expected_hash?
      │
      ├─ YES → ✅ Signature valid
      │         ✅ Client owns private key
      │         ✅ Authentication succeeds
      │
      └─ NO  → ❌ Signature invalid
                ❌ Authentication fails
                ❌ Connection rejected
```

---

## Key Insights

1. **Private Key Never Transmitted**
   - Stays on client machine
   - Used only to create signature
   - Signature proves ownership without revealing the key

2. **Public Key is Sufficient for Verification**
   - Extracted from client certificate
   - Used to verify the signature
   - No secrets required on server side

3. **Asymmetric Cryptography Magic**
   - Private key can sign (hard to do without the key)
   - Public key can verify (easy with just the public key)
   - Cannot forge signature without private key

4. **Two Independent Checks**
   - Certificate Verify: Proves client owns the private key
   - CA Verification: Proves certificate is trusted
   - Both must pass for authentication to succeed

5. **The Code is Readable**
   - Go's crypto library is well-documented
   - Each layer has a clear responsibility
   - The flow is straightforward once you know where to look

---

## Conclusion

The TLS Certificate Verify mechanism is a beautiful example of asymmetric cryptography in action:

- **Client** uses private key to create a signature (proof of ownership)
- **Server** uses public key to verify the signature (proof verification)
- **Private key** never leaves the client
- **Signature** is transmitted (safe to send over the network)
- **Mathematics** ensures signature cannot be forged

The code path spans three layers:
1. **Configuration** - Setting up the TLS parameters
2. **TLS Library** - Managing the handshake protocol
3. **Crypto Library** - Performing the mathematical operations

You've now traced the complete journey from your kubeconfig file all the way down to the modular exponentiation operations that prove your identity to the cluster!

---

**Document Version:** 1.0  
**Last Updated:** 2026-05-30  
**Author:** Complete TLS Certificate Verify code flow analysis
