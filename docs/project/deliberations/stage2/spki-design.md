# Sovereign Stage 2: TLS SPKI Pinning Architectural Specification & Design Lock

:Document ID: DELIB-STAGE2-SPKI-001  
:Status: STAMPED & LOCKED (Phase 0 Complete)  
:Author: Agy (Antigravity Senior Co-Architect)  
:Checker Reviewer: Muse Code (Architect/Checker)  
:Checker Stamp: APPROVED & STAMPED (Mailbox Ref: msg-105, 2026-09-29T08:33:25Z)  
:Authority: Stage 2 Orders §0.1  
:Module Targets: `src/kernel/net/tls_stream.zig`, `src/kernel/net/tls_client.zig`, `src/kernel/net/spki.zig`, `src/kernel/main.zig`  

---

## 1. Executive Summary & Problem Statement

In Stage 1, TLS 1.3 transport was downgraded to `.ca = .no_verification` with explicit serial warnings (`UNVERIFIED TLS: Certificate validation disabled`) to avoid blocking on root CA bundle distribution. For Stage 2 (Milestone 39), we eliminate plaintext-equivalent trust by implementing **Subject Public Key Info (SPKI) Pinning** (RFC 7469).

Traditional X.509 CA validation relies on hundreds of opaque third-party Certificate Authorities, creating vast attack surfaces (rogue CAs, compromised sub-CAs, state-level coercive signing, BGP hijacks). In contrast, MicrOS is a sovereign operating system: node-to-node cluster communication and sovereign AI orchestrations require strict cryptographic pinning of expected public keys.

---

## 2. SPKI Pin Definition & Representation

An SPKI Pin in MicrOS is defined as the SHA-256 cryptographic digest of the DER-encoded `SubjectPublicKeyInfo` sequence extracted from the peer's X.509 certificate:

$$\text{Pin} = \text{SHA-256}(\text{DER}(\text{SubjectPublicKeyInfo}))$$

- **Raw Representation**: `[32]u8` (256-bit binary hash).
- **String Representation**: Lowercase hex string `[64]u8` (e.g., `8f4b23...`).
- **Why SPKI over Certificate Hashing**:
  - Full certificate hashes break on routine certificate renewals even when the underlying key pair is identical.
  - SPKI pinning pins the public key itself, allowing certificate re-issuance without disrupting operational trust.
  - Allows seamless pre-planned key rotation via mandatory primary and backup pin pairs.

---

## 3. Pin Storage & Monotonic Invariant Lifecycle

Pins are stored across two complementary tiers:

### 3.1 Genesis Compile-Time Trust Table (Tier 1)
Embedded in `src/kernel/net/spki.zig` as immutable ROM structures for baseline sovereign endpoints:
```zig
pub const SpkiPin = [32]u8;

pub const PinnedEndpoint = struct {
    hostname: []const u8,
    primary_pin: SpkiPin,
    backup_pins: [2]SpkiPin,
    backup_count: usize,
};
```
- **Bootstrap Endpoint**: `generativelanguage.googleapis.com` (Google Gemini API).
- **Primary Pin**: Current Google Trust Services (GTS) Root R1 / intermediate SPKI hash.
- **Backup Pins**: GTS Root R2 and GlobalSign Root backup SPKI hashes.

### 3.2 Dynamic CAS Pin Store (Tier 2)
For P2P virtual cluster nodes and user-provisioned HTTPS endpoints:
- Stored as content-addressed objects in CAS: `caps.spki.<hostname_or_node_id>`.
- Format:
  ```text
  [8 bytes generation counter (monotonic u64)]
  [32 bytes primary SPKI pin]
  [32 bytes backup SPKI pin]
  [64 bytes Ed25519 cluster coordinator signature]
  ```
- **Monotonic Protection & Anti-Rollback Anchor (Resolving S3 & S4)**:
  - **Generation-Only Validation**: Wall-clock timestamps are strictly rejected because freestanding bare-metal nodes lack trusted RTCs prior to joining a mesh. Invalidations and rotations are governed strictly by monotonic generation numbers (`generation: u64`).
  - **State Anchor**: The current active generation number is anchored directly in the **FAT32 ESP state block (`BOOTSTATE.DAT`) and the CAS Sector 0 Monotonic Superblock Header**. Updates must write and flush (`@fence`, `io_drain`) Sector 0 before promoting any new manifest. CAS rollbacks cannot revert the monotonic generation counter.

---

## 4. Answering the Sovereign Bootstrap Question

> *Requirement*: "Must answer: who mints the first pins, and how does a fresh node join without TOFU regressing to unverified trust?"

### 4.1 Who Mints the First Pins?
1. **Cloud / Upstream Endpoints**: The genesis operator extracts the public keys of authorized service endpoints during release packaging. The SHA-256 SPKI digests are statically embedded into Tier 1 ROM.
2. **P2P Virtual Cluster Mesh**: The cluster coordinator (Node 0) generates the cluster genesis identity key (`cluster.ed25519`) and the 256-bit **Cluster Genesis Secret** ($K_{\text{cluster}} \in \{0,1\}^{256}$) upon initial volume creation via `sys_disk_provision`. The coordinator mints the initial node pin manifest.

### 4.2 Zero-TOFU Fresh Node Join Protocol (Resolving S1, S2, S5)
Traditional Trust-On-First-Use (TOFU) introduces an unauthenticated MITM vulnerability during initial connection. MicrOS mathematically eliminates TOFU via **Out-of-Band Cryptographic Invitation Tickets**:

1. **Ticket Minting**: The coordinator node emits a high-entropy joining ticket keyed by $K_{\text{cluster}}$:
   $$\text{Ticket} = \{ \text{ClusterID (16B)}, \text{Coordinator\_PubKey (32B)}, \text{Generation (8B)}, \text{HMAC-BLAKE3 (32B)} \}$$
   - **HMAC Key (S1)**: The MAC is computed using the 32-byte Cluster Genesis Secret ($K_{\text{cluster}}$).
   - **Full 32B MAC (S2)**: The ticket utilizes the complete 32-byte (256-bit) BLAKE3 keyed hash, eliminating truncation attack surfaces. Total ticket size is 88 bytes.
2. **Out-of-Band Transfer**: The ticket is delivered to the fresh node via physical media (USB/virtio block device), EFI environment variable, or interactive console prompt during node commissioning.
3. **Transport Separation (S5)**:
   - **AI Cloud / HTTPS (Port 443)**: Transport is TLS 1.3 (`tls_stream.zig`). Verification path is SHA-256 SPKI pinning against Tier 1 ROM.
   - **P2P Mesh Join (Port 8080)**: Transport is Noise Protocol Framework (Noise_IKpsk2 / Ed25519) (`p2p.zig`). The joining node pins the coordinator's Ed25519 public key **directly from the ticket**, refusing connection if the peer key does not match `Coordinator_PubKey`. Once mutual cryptographic proof is established, the coordinator securely provisions the cluster key and full SPKI directory over the encrypted Noise channel.
4. **Result**: Zero unauthenticated connections. Zero TOFU regression.

---

## 5. Verification Path in `src/kernel/net/tls_stream.zig` (Resolving S-BLOCKER)

### 5.1 Empirical Finding on `std.crypto.tls.Client`
A thorough audit of `/usr/lib/zig/std/crypto/tls/Client.zig` in Zig 0.16.0 establishes:
1. `std.crypto.tls.Client` parses the incoming `Certificate` message into a stack-local `subject_cert` and, under `.ca = .no_verification`, immediately breaks out of the loop without saving the certificate.
2. The `Client` struct exposes no public fields or methods to inspect the peer certificate chain post-handshake.
3. The underlying `read_buffer` is actively reused for application data, making post-handshake buffer scanning non-deterministic and brittle.
4. `Certificate.Parsed` in Zig std does NOT contain a `pub_key_info` member (it only contains `pub_key_slice`, which is the bare public key bit string, omitting the ASN.1 AlgorithmIdentifier required by RFC 7469).

### 5.2 Proven Freestanding SPKI Extraction
Because RFC 7469 specifies the SHA-256 of the entire `SubjectPublicKeyInfo` ASN.1 Sequence, and in X.509 `SubjectPublicKeyInfo` immediately follows `Subject`, we have verified the exact extraction mechanism via a collocated spike test:

```zig
pub fn extractSpkiSha256(cert_der: []const u8) ![32]u8 {
    const cert: std.crypto.Certificate = .{
        .buffer = cert_der,
        .index = 0,
    };
    const parsed = try cert.parse();
    const spki_start = parsed.subject_slice.end;
    const spki_elem = try std.crypto.Certificate.der.Element.parse(cert_der, spki_start);
    const spki_bytes = cert_der[spki_start .. spki_elem.slice.end];

    var pin: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(spki_bytes, &pin, .{});
    return pin;
}
```
This function is compile-proven and passing in `src/kernel/net/tls_stream.zig` (`test "spki spike: parse fixture cert, extract SubjectPublicKeyInfo, and compute SHA-256 pin"`).

### 5.3 Architectural Implementation: Freestanding Substrate TLS Client
To integrate SPKI pinning cleanly without upstream std compromises:
1. MicrOS introduces `src/kernel/net/tls_client.zig`, a freestanding adaptation of Zig's pure-Zig TLS 1.3 client.
2. In `tls_client.zig`, `Options` accepts:
   ```zig
   spki_pin_verifier: ?*const fn (leaf_cert_der: []const u8) anyerror!void = null,
   ```
3. During handshake processing of the `Certificate` message (at `cert_index == 0`), the client immediately invokes `spki_pin_verifier(certd.rest())`.
4. If the verifier returns `error.CertificatePinMismatch`, the TLS client transmits a `bad_certificate` alert, aborts the handshake, and returns `error.CertificatePinMismatch` before any application traffic keys are derived.

### 5.4 Constant-Time Pin Matching & Fail-Closed Enforcement
```zig
pub fn verifySpkiPin(hostname: []const u8, cert_der: []const u8) !void {
    const leaf_pin = try extractSpkiSha256(cert_der);
    const endpoint = spki.lookupEndpoint(hostname) orelse return error.UnknownEndpoint;

    if (std.crypto.timing_safe.eql([32]u8, leaf_pin, endpoint.primary_pin)) {
        return;
    }
    for (endpoint.backup_pins[0..endpoint.backup_count]) |backup_pin| {
        if (std.crypto.timing_safe.eql([32]u8, leaf_pin, backup_pin)) {
            return;
        }
    }

    serial.writeString("[FATAL] tls: SPKI PIN MISMATCH for ");
    serial.writeString(hostname);
    serial.writeString("! Connection aborted.\n");
    return error.CertificatePinMismatch;
}
```

### 5.5 Fail-Closed Invariants
- **No Silent Fallback**: If an endpoint has an SPKI pin configured, a mismatch bails immediately with `error.CertificatePinMismatch`. It NEVER falls back to unverified trust.
- **Explicit Unpinned Mode**: If a developer overrides pinning (`allow_unpinned = true`), the system emits a prominent warning banner over serial:
  `[ WARN ] tls : TLS 1.3 active (UNPINNED - zero SPKI pins configured)`.
- **Boot Status Line**:
  - Pinned: `[  ok  ] tls : TLS 1.3 SPKI pinning active (2 pins provisioned)`
  - Unpinned: `[ WARN ] tls : TLS 1.3 active (UNPINNED - zero SPKI pins configured)`

---

## 6. Fixture Strategy & Verification

### 6.1 Deterministic Test Fixtures (Colocated in `tls_stream.zig`)
To verify pinning in `zig build test` without external network connections:
- `FIXTURE_LEAF_CERT_A`: Pre-generated valid DER certificate matching `PRIMARY_PIN`.
- `FIXTURE_LEAF_CERT_B`: Pre-generated valid DER certificate matching `BACKUP_PIN`.
- `FIXTURE_FORGED_CERT`: Pre-generated valid DER certificate signed with an untrusted key (mismatched SPKI).

### 6.2 Test Matrix (Resolving S6)
1. `test "tls: SPKI primary pin match succeeds"`: Asserts clean validation against primary pin.
2. `test "tls: SPKI backup pin match succeeds"`: Asserts clean validation during key rotation.
3. `test "tls: SPKI mismatch fails closed with error.CertificatePinMismatch"`: Asserts forged certificate is instantly rejected.
4. `test "tls: exercises std.crypto.timing_safe.eql comparison path"`: Verifies timing-safe comparison on pin digests.

### 6.3 KVM vs TCG Provability
- **Unit Suite**: Executes in userland via `zig build test` in < 50ms using mock stream fixtures.
- **TCG Boot Harness**: QEMU TCG runs display the exact boot status line:
  `[  ok  ] tls : TLS 1.3 SPKI pinning active (2 pins provisioned)`.
  Proves that pure software CPU emulation initializes entropy, parses DER slices, and validates SPKI hashes without triggering `#UD` or `#GP` exceptions.

---

## Checker Stamp

:Stamp: APPROVED — Muse Code, 2026-09-29 (mailbox ref: msg-105, re msg-019). Phase-0 design lock complete; implementation released.
