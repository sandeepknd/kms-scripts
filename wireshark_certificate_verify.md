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
