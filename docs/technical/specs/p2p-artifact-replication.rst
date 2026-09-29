====================================================
P2P Content-Addressed Artifact Replication Spec
====================================================

:Document ID: SPEC-TECH-P2P-002
:Status: Approved
:Traced Stories: [US-REN-006], [US-REN-010], [US-GEM-001], [US-GEM-009], [US-GEM-010]
:Parent Architecture: `SPEC-TECH-NET-003`, `SPEC-TECH-FS-001`
:Module Targets: ``src/userland/p2pd/p2p.zig``, ``src/userland/p2pd/p2p_abi.zig``, ``src/kernel/net.zig``

1. Architectural Axioms & Purpose
=================================
This specification defines the peer-to-peer (P2P) content-addressed artifact replication protocol for MicrOS (µOS), replacing centralized package managers and legacy transport bridges with a decentralized, cryptographically sovereign artifact mesh.

1.1 Cryptographic Sovereignty & Deterministic Framing
------------------------------------------------------
All cluster communication adheres to the MicrOS P2P Invariants:

* **Zero Ambient RPCs**: Unauthenticated RPCs are rejected at the wire boundary. Nodes authenticate using Ed25519 cryptographic identities.
* **Deterministic MAC Verification**: Wire payloads are sealed using keyed BLAKE3 Message Authentication Codes (MAC). Segments with invalid MACs are discarded as environmental noise without triggering CPU faults.
* **Replay & Sybil Defense**: Every packet contains a strictly monotonic 64-bit sequence counter. Stale or duplicate sequence numbers are dropped immediately.
* **Zero-Copy Routing**: Packets stream directly into isolated capability buffers, bypassing intermediate kernel copies.

1.2 Mesh Artifact Replication (G6)
----------------------------------
Instead of synchronizing filesystems or git trees, the P2P mesh replicates immutable Content-Addressed Storage (CAS) chunks:
* Nodes advertise chunk availability via lightweight bloom filters or manifest roots.
* Missing chunks are fetched concurrently across discovered mesh peers using deterministic hash queries.
* Received chunks are hashed with BLAKE3; only chunks matching the requested hash are committed to local persistent storage.

2. Wire Protocol Schema & Frame Layout
======================================

2.1 Protocol Framing
--------------------
Each P2P wire datagram conforms to the 72-byte binary header structure:

.. code-block:: zig

   pub const P2pFrameHeader = extern struct {
       magic: u32 = 0x554F5350,       // "µOSP" (MicroOS P2P)
       version: u16 = 2,
       msg_type: u16,                 // 1=Beacon, 2=HashQuery, 3=ChunkData, 4=Ack, 5=ArtifactPublish, 6=ArtifactPull, 7=ArtifactData, 8=ArtifactTombstone
       sender_node_id: [32]u8,        // Ed25519 Public Key
       sequence: u64,                 // Monotonic Sequence Number
       payload_len: u32,
       mac: [32]u8,                   // Keyed BLAKE3 MAC over (header[0..40] || payload)
   };

2.2 State Machine & Peer Discovery
----------------------------------
* **Discovery Beaconing**: Nodes broadcast UDP beacons (port 4242) periodically with their public identity and active catalog generation.
* **Neighbor Liveness**: Heartbeat timeouts drop unresponsive peers from the active routing table after 30 seconds.
* **Chunk Fetch Ladder**: When an actor requests a CAS artifact not present locally, ``p2pd`` dispatches `HashQuery` frames to active neighbors, reassembling streams into verified local chunks.

3. Replication Manager & Tombstones (Milestone 39)
==================================================
The P2P replication engine (`src/userland/p2pd/replication.zig`) coordinates cluster-wide artifact dissemination and lifecycle consistency:

3.1 Artifact Publishing & Pull
------------------------------
* **Publishing**: When an artifact is published via ``sys_mesh_publish`` / ``:mesh publish <hash>``, ``ReplicationManager`` serializes an `ArtifactPublish` frame containing the 32-byte BLAKE3 hash, artifact name, bytecode length, and author's Ed25519 signature.
* **Pulling**: Nodes issue `ArtifactPull` frames requesting specific hashes. Neighbors reply with verified `ArtifactData` streams committed directly to local CAS.

3.2 Signed Tombstone Invalidation
---------------------------------
* **Deterministic De-indexing**: Revoking or unpublishing an artifact via ``sys_mesh_unpublish`` / ``:mesh unpublish <name>`` generates an immutable `Tombstone` record signed with the author's private key.
* **Tombstone Structure**:
  - `artifact_hash`: 32-byte BLAKE3 hash of target.
  - `author_pubkey`: 32-byte Ed25519 public key.
  - `timestamp`: Monotonic generation counter.
  - `signature`: 64-byte Ed25519 signature over `(artifact_hash || timestamp)`.
* **Tamper Rejection**: Peers verify the signature against the registered author identity; invalid or unauthorized tombstones are discarded as environmental noise. Verified tombstones immediately de-index the artifact and suppress execution.

3.3 Capability Sandboxing & Daemon Isolation
--------------------------------------------
The P2P replication engine executes as an isolated userland daemon (``p2pd``):
* **Bounded CSpace**: Possesses only ``CapType.network_device`` and ``CapType.storage_device`` tokens.
* **Syscall ABI**: Exposed to guest actors via ``sys_mesh_publish``, ``sys_mesh_pull``, and ``sys_mesh_unpublish`` (`src/userland/p2pd/p2p_abi.zig`).

4. Verification & Traceability Matrix
=====================================
* ``[US-REN-006]``: Capability-bounded network device and storage operation.
* ``[US-REN-010]``: High-concurrency green-thread event scheduling over lock-free IPC rings.
* ``[US-GEM-001]``: Binary telemetry stream ingestion across cluster nodes.
* ``[US-GEM-009]``: Self-healing network resilience and connection recovery.
* ``[US-GEM-010]``: Context-window-optimized module boundaries (<= 1,000 lines, functions <= 40 lines).
