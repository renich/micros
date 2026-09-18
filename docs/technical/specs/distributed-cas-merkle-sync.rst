============================================================
Distributed CAS & Workspace Merkle Sync (SPEC-TECH-P2P-002)
============================================================

:Document ID: SPEC-TECH-P2P-002
:Status: Approved
:Traced Stories: [US-REN-004], [US-REN-006], [US-REN-010], [US-GEM-001], [US-GEM-010]

1. Architectural Axioms & Purpose
=================================
This specification formalizes the **Distributed Content-Addressed Storage (CAS) Replication and Workspace Merkle Synchronization Protocol** for MicrOS (µOS). Operating within the sovereign P2P networking substrate (``p2pd``), this protocol enables zero-configuration, cryptographic synchronization of workspace manifests, actor source code, and binary objects across distributed cluster nodes without centralized servers, cloud intermediaries, or opaque metadata registries.

1.1 Content-Addressed Cryptographic Integrity
---------------------------------------------
All shared state in MicrOS is immutable and addressed by its 256-bit BLAKE3 cryptographic hash:
* **Zero-Trust Replication**: Chunks received over untrusted network streams are hashed immediately upon arrival. Chunks whose BLAKE3 digest does not match the requested hash are atomically discarded before touching persistent storage.
* **Deterministic Merkle Trees**: Workspaces are represented as balanced Merkle trees over sorted object manifests. Two nodes with identical workspace contents compute identical 256-bit root hashes.
* **Offline-First Optimistic Concurrency Control (OCC)**: Workspaces maintain monotonic 64-bit generation counters. Concurrent offline edits are reconciled deterministically using structural Merkle difference detection and deterministic conflict resolution without data corruption.

2. Binary Protocol Layout
=========================

2.1 Message Types
-----------------
The P2P wire framing subsystem extends the binary ``MessageType`` enum with synchronization primitives:

.. code-block:: zig

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
       merkle_sync_request = 10,
       merkle_sync_response = 11,
   };

2.2 Chunk Request & Response Payloads
-------------------------------------
Chunk replication operates via compact binary envelopes:

* **ChunkRequest**:
  - ``hash``: 32 bytes (256-bit BLAKE3 hash of requested object).
* **ChunkResponse**:
  - ``hash``: 32 bytes (256-bit BLAKE3 hash).
  - ``chunk_type``: 4 bytes (u32 enum: raw_blob, actor_source, bytecode_chunk, merkle_node, etc.).
  - ``payload_len``: 4 bytes (u32, up to 64 KiB per frame).
  - ``payload``: Bounded byte array of chunk data.

2.3 Merkle Node & Workspace Manifest Layout
-------------------------------------------
Workspace synchronization organizes objects into discrete Merkle entries:

.. code-block:: zig

   pub const MerkleEntry = extern struct {
       path_len: u16 align(1),
       path: [64]u8 align(1),
       size: u64 align(1),
       hash: [32]u8 align(1),
   };

   pub const MerkleTree = struct {
       generation: u64,
       root_hash: [32]u8,
       entry_count: usize,
       entries: [MAX_MERKLE_ENTRIES]MerkleEntry,
   };

3. Merkle Difference Detection & Reconciliation
===============================================

3.1 Difference Detection Algorithm
----------------------------------
When node A initiates synchronization with node B:
1. Node A sends ``merkle_sync_request`` containing its current ``root_hash`` and ``generation``.
2. If ``remote.root_hash == local.root_hash``, the workspaces are identical; synchronization terminates in ``O(1)`` time.
3. If root hashes differ, the nodes exchange entry lists and compute the structural set difference:
   - **Missing Hashes**: Items present in remote manifest but absent in local CAS.
   - **Local Additions**: Items present locally but absent in remote manifest.
   - **Modified Entries**: Items sharing path names but differing in content hashes.

3.2 Offline-First OCC Conflict Resolution
-----------------------------------------
When concurrent edits occur across disconnected partitions:
* **Monotonic Generation Supersession**: If one node's generation strictly dominates (``gen_A > gen_B``) and includes an unbroken causal ancestor chain, the newer manifest supersedes.
* **Deterministic Lexicographical Tie-Breaking**: When conflicting edits exist at identical generation depths, conflicts resolve deterministically:
  - If entries share a path but differ in hash, the entry with the lexicographically higher 256-bit BLAKE3 hash is accepted as canonical.
  - A conflict entry is preserved with the suffix ``.conflict.<short_node_id>`` ensuring zero silent data loss.
* **Monotonic Advance**: The reconciled workspace root is assigned ``max(gen_A, gen_B) + 1``.

4. Verification & Traceability Matrix
=====================================

.. list-table::
   :widths: 20 25 55
   :header-rows: 1

   * - Requirement ID
     - Traced Story
     - Verification Method
   * - REQ-CAS-001
     - [US-REN-004]
     - Freestanding BLAKE3 chunk streaming and verification with zero libc linkage.
   * - REQ-CAS-002
     - [US-REN-006]
     - Capability-bounded CAS replication rejecting corrupt or unauthorized objects.
   * - REQ-CAS-003
     - [US-REN-010]
     - Non-blocking Merkle difference exchange in cooperative green-thread fibers.
   * - REQ-CAS-004
     - [US-GEM-001]
     - Real-time Merkle replication telemetry emitted over 64-byte binary rings.
   * - REQ-CAS-005
     - [US-GEM-010]
     - Modular architecture under 1,000 LOC per file with bounded function complexity.
