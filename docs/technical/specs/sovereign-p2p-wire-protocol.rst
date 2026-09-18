============================================================
Sovereign P2P Mutual TLS & Noise Wire Protocol (SPEC-TECH-P2P-001)
============================================================

:Document ID: SPEC-TECH-P2P-001
:Status: Approved
:Traced Stories: [US-REN-004], [US-REN-006], [US-REN-010], [US-GEM-001], [US-GEM-010]

1. Architectural Axioms & Purpose
=================================
This specification formalizes the **Sovereign Peer-to-Peer (P2P) Mutual Wire Protocol** for MicrOS (µOS). Operating within userland network service daemons (``netd`` / ``p2pd``), this subsystem establishes a decentralized, trustless, encrypted compute and storage mesh between independent MicrOS nodes. It strictly eliminates reliance on centralized cloud providers, domain name registrars, certificate authorities (CAs), or centralized broker hubs.

1.1 Decentralized Cryptographic Sovereignty
-------------------------------------------
Traditional networking requires centralized DNS and X.509 PKI hierarchies. In MicrOS:
* **Cryptographic Node Identity**: Every node generates an Ed25519 keypair. The node's canonical address (``NodeId``) is the 256-bit BLAKE3 hash of its Ed25519 public key.
* **Mutual Cryptographic Handshake**: Node-to-node sessions over TCP port 8080 execute an authenticated Noise/mTLS handshake where both initiator and responder prove possession of their respective Ed25519 private keys.
* **Freestanding & Zero-libc**: Cryptographic primitives (Ed25519 signature verification, ChaCha20-Poly1305 AEAD, BLAKE3) leverage freestanding compiler intrinsics and the native microkernel network stack with zero libc linkage.

2. Binary Wire Protocol Specification
=====================================

2.1 Frame Header Layout
-----------------------
All P2P messages transmitted over the TCP stream begin with a fixed 48-byte binary frame header:

.. code-block:: zig

   pub const P2P_MAGIC: u32 = 0x50325031; // 'P2P1'

   pub const MessageType = enum(u16) {
       handshake_init = 1,
       handshake_resp = 2,
       peer_ping = 3,
       peer_pong = 4,
       discovery_beacon = 5,
       chunk_request = 6,
       chunk_response = 7,
       actor_dispatch = 8,
       actor_result = 9,
   };

   pub const FrameHeader = extern struct {
       magic: u32 align(1),
       version: u16 align(1),
       msg_type: MessageType align(1),
       payload_len: u32 align(1),
       source_id: [32]u8 align(1),
       sequence: u32 align(1),
       checksum: u32 align(1),
   };

2.2 Handshake Sequence
----------------------
1. **Initiator -> Responder (HandshakeInit)**:
   Transmits 32-byte ephemeral public key, 32-byte static Ed25519 public key, and a 64-byte signature over a 32-byte random challenge nonce.
2. **Responder -> Initiator (HandshakeResp)**:
   Verifies initiator signature against ``source_id = BLAKE3(pubkey)``. Returns responder's Ed25519 public key, response nonce, and signature.
3. **Session Key Derivation**:
   Both peers derive symmetric 256-bit ChaCha20-Poly1305 encryption keys. Subsequent frame payloads are encrypted in-place.

3. Local Mesh Discovery & Peer Table
====================================

3.1 Zero-Configuration UDP Beacon
---------------------------------
Nodes periodically broadcast a 72-byte discovery beacon over UDP port 8081 on the local subnet (``255.255.255.255``):
* Magic (4 bytes): ``0x50325042`` (``P2PB``)
* NodeId (32 bytes): BLAKE3 hash of Ed25519 public key
* ListenPort (2 bytes): TCP port (default 8080)
* CapabilityMask (2 bytes): Advertised services (CAS storage, remote actor execution)
* Ed25519 Public Key (32 bytes)

3.2 Bounded Peer Table Management
---------------------------------
The P2P daemon maintains an in-memory table of up to 64 active peers with LRU decay. Stale peers missing 3 consecutive heartbeat pings are pruned without heap fragmentation.

4. Verification & Traceability Matrix
=====================================

.. list-table::
   :widths: 20 25 55
   :header-rows: 1

   * - Requirement ID
     - Traced Story
     - Verification Method
   * - REQ-P2P-001
     - [US-REN-004]
     - Freestanding binary frame serialization and zero-libc crypto roundtrip.
   * - REQ-P2P-002
     - [US-REN-006]
     - Node identity verification rejecting unauthenticated or spoofed node IDs.
   * - REQ-P2P-003
     - [US-REN-010]
     - Non-blocking network streaming and handshake in green-thread fibers.
   * - REQ-P2P-004
     - [US-GEM-001]
     - Real-time P2P peer count and mesh telemetry emission over shared rings.
   * - REQ-P2P-005
     - [US-GEM-010]
     - Module code size strictly under 1,000 LOC with bounded function complexity.
