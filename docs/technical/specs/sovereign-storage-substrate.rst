==========================================================
Sovereign Storage Substrate & Content-Addressed Store Spec
==========================================================

:Document ID: SPEC-TECH-STORAGE-001
:Status: Approved
:Traced Stories: [US-REN-004], [US-REN-006], [US-REN-008], [US-GEM-001], [US-GEM-002], [US-GEM-004], [US-GEM-010]

1. Architectural Axioms & Purpose
=================================
This specification defines the persistent storage architecture for MicrOS (µOS), replacing legacy POSIX filesystem hierarchies with a mathematically verifiable Content-Addressed Storage (CAS) engine operating directly over VirtIO-Blk hardware.

1.1 Eradication of POSIX Storage Debt
-------------------------------------
MicrOS (µOS) rejects the 50-year-old UNIX filesystem model (hierarchical paths, mutable inodes, file descriptors, permission masks, and directory traversal locks). Instead:

* **Pure Content Addressing**: Every piece of data, actor source code, bytecode chunk, and system manifest is identified uniquely and immutably by its 256-bit BLAKE3 cryptographic digest.
* **Mathematical Integrity & Bitrot Immunity**: Reading a chunk re-verifies its cryptographic hash. Tampered or corrupted sectors are detected deterministically and trigger supervisor self-healing.
* **Zero Ambient Authority**: Access to persistent storage requires explicit capability tokens (`Rights.STORAGE_READ` or `Rights.STORAGE_WRITE`) inside the calling Actor's CSpace.
* **Atomic State Evolution**: System roots and actor registry checkpoints advance atomically via monotonically sequenced generation counters in Sector 0 (Superblock).

1.2 Mechanism vs Policy
-----------------------
* **Microkernel Mechanism**: Raw PCI bus enumeration for VirtIO-Blk controllers, page-aligned DMA virtqueue ring descriptors, polled sector read/write transactions, and a bounded 64-page (256 KiB) LRU block cache.
* **Harness & AI Policy**: The Macros language and Sovereign Genesis Harness define object serialization, human-readable name-to-hash mappings, checkpointing frequencies, and actor persistence lifecycles.

2. Hardware VirtIO-Blk Driver ABI
=================================
The microkernel discovers VirtIO block devices via the PCI configuration space (`src/kernel/drivers/pci.zig`), looking for Vendor ID `0x1AF4` and Device ID `0x1001` (Legacy) or `0x1042` (Modern VirtIO 1.0).

2.1 VirtIO Block Request Envelope
---------------------------------
All sector transactions are formatted as 16-byte request headers:

.. code-block:: zig

   pub const VIRTIO_BLK_T_IN: u32 = 0; // Read from disk
   pub const VIRTIO_BLK_T_OUT: u32 = 1; // Write to disk
   pub const VIRTIO_BLK_T_FLUSH: u32 = 4; // Cache barrier flush

   pub const VirtioBlkOutHdr = extern struct {
       type: u32,
       ioprio: u32 = 0,
       sector: u64,
   };

   pub const VirtioBlkStatus = enum(u8) {
       ok = 0,
       io_err = 1,
       unsupp = 2,
       pending = 0xFF,
   };

2.2 Split Virtqueue Mechanics
-----------------------------
* Queue index 0 is configured with 256 descriptors.
* Physical memory for the descriptor table, available ring, and used ring is allocated from the Physical Memory Manager (PMM) and strictly aligned to 4096-byte boundaries.
* Each transaction uses a 3-descriptor chain:
  1. Header descriptor (Device-readable, 16 bytes: `VirtioBlkOutHdr`).
  2. Data buffer descriptor (Device-readable for write, Device-writable for read; 512-byte sector-aligned, supporting up to 8 sectors / 4096 bytes batched DMA).
  3. Status byte descriptor (Device-writable, 1 byte: `VirtioBlkStatus`).
* Polled completion uses CPU `pause` instructions (`PAUSE_SPIN_LIMIT = 5_000_000`) with zero port 0x80 VM exit traps.
* Block cache page frame loads and flushes execute as a single batched 4096-byte DMA transfer (8 sectors), reducing doorbell kicks and descriptor processing by 87.5%.

3. Page-Aligned Bounded Block Cache (LRU)
=========================================
To preserve sub-millisecond execution determinism and protect physical storage media from excessive write cycles, the kernel maintains an in-memory block cache:

* **Capacity**: Bounded strictly to 64 page frames (256 KiB RAM), guaranteeing zero unbounded memory growth.
* **Alignment**: All cache frame pointers enforce `@intFromPtr(frame) % 4096 == 0` mathematically.
* **Eviction Policy**: Strict Least-Recently-Used (LRU) queue.
* **Write Policy**: Write-back with dirty tracking. Evicted dirty pages are automatically flushed to VirtIO-Blk before reuse.
* **Barrier Flush**: `sys_storage_sync()` forces all dirty cached sectors to non-volatile disk.

4. Sovereign Content-Addressed Storage (CAS)
============================================

4.1 Superblock ABI (Sector 0)
-----------------------------
Sector 0 (512 bytes) stores the Sovereign CAS Superblock:

.. code-block:: zig

   pub const CAS_SUPERBLOCK_MAGIC: u32 = 0x4D494352; // "MICR"
   pub const CAS_SUPERBLOCK_VERSION: u32 = 1;

   pub const CasSuperblock = extern struct {
       magic: u32,
       version: u32,
       generation: u64,
       root_hash: [32]u8,
       block_count: u64,
       next_free_sector: u64,
       checksum: [32]u8,
       padding: [416]u8 = [_]u8{0} ** 416,
   };

4.2 Chunk Envelope Structure
----------------------------
Chunks are written sequentially to the append-only high-water mark starting at Sector 1:

.. code-block:: zig

   pub const ChunkType = enum(u32) {
       raw_blob = 1,
       actor_source = 2,
       bytecode_chunk = 3,
       merkle_node = 4,
       system_manifest = 5,
   };

   pub const CasChunkHeader = extern struct {
       hash: [32]u8,
       length: u32,
       chunk_type: ChunkType,
       padding: [24]u8 = [_]u8{0} ** 24,
   };

* The header is fixed at 64 bytes.
* The total sector allocation for a chunk is `(sizeof(CasChunkHeader) + length + 511) / 512` sectors.
* Upon read, the kernel computes `std.crypto.hash.Blake3.hash(payload)` and compares against `header.hash`. Any mismatch returns `error.CorruptChunk`.

5. Capability-Governed Native VM Bindings
=========================================
The microkernel exposes storage primitives to Actor 0 and authorized child actors via native C-ABI bindings:

.. code-block:: zig

   pub fn sys_cas_put(data_str: []const u8) []const u8
   pub fn sys_cas_get(hash_str: []const u8) []const u8
   pub fn sys_cas_set_root(name_str: []const u8, hash_str: []const u8) bool
   pub fn sys_cas_get_root(name_str: []const u8) []const u8
   pub fn sys_actor_persist(actor_id: i64) []const u8
   pub fn sys_actor_spawn_cas(hash_str: []const u8) i64

* `sys_cas_put`: Requires `Rights.STORAGE_WRITE`. Computes BLAKE3 hash, persists chunk, updates high-water mark, and returns 64-character hex string.
* `sys_cas_get`: Requires `Rights.STORAGE_READ`. Fetches chunk by hash, verifies cryptographic integrity, and returns data string.
* `sys_actor_persist`: Serializes active actor code and state into CAS, returning its permanent hash.
* `sys_actor_spawn_cas`: Retrieves chunk from CAS, compiles source, and spawns isolated child actor on hardware.

6. Verification & Quality Gates
===============================
1. **Unit Test Gate**: 100% pass rate in `zig build test` for VirtIO-Blk request generation, sector caching, and BLAKE3 chunk hashing.
2. **Ten Commandments Compliance**: File sizes <= 1,000 lines, function lengths <= 40 lines, nesting depth <= 3, zero libc, explicit allocators, 4096-byte page alignment.
3. **Two-Stage Reboot Persistence Gate**:
   * *Stage 1*: Boot QEMU, store actor script to CAS via REPL, record emitted hash, halt VM.
   * *Stage 2*: Boot fresh QEMU with the same persistent disk image, run `spawn_cas <hash>`, asserting live execution on hardware without host or network interaction.
4. **Specification Traceability**: Full bidirectional traceability verified by `tools/micros-spec-trace.bash`.
