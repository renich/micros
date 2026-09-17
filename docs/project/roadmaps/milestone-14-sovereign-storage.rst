Milestone 14: Persistent Sovereign Storage Substrate
===================================================

:Objective: Eliminate operating system ephemerality. Implement a freestanding zero-libc VirtIO-Blk driver, a bounded page-aligned LRU block cache, and a cryptographic Content-Addressed Storage (CAS) engine using BLAKE3 hashing. Enable actor persistence, system state snapshotting, and byte-for-byte reboot survival on bare-metal silicon and QEMU.
:Status: Completed & Verified
:Specification: SPEC-TECH-STORAGE-001

Milestones & Deliverables
-------------------------

* **M14.1: PCI VirtIO-Blk Discovery & Split Virtqueue Driver**
  - Implement ``src/kernel/drivers/virtio_blk.zig`` adhering to VirtIO 1.0 specifications.
  - Expand ``src/kernel/drivers/pci.zig`` to detect VirtIO block devices (Vendor ``0x1AF4``, Device ``0x1001`` / ``0x1042``).
  - Configure split virtqueue 0 with mathematically enforced 4096-byte page alignment.
  - Implement polled sector read (``readSector``) and sector write (``writeSector``) using 3-descriptor request chains.

* **M14.2: Page-Aligned Bounded Block Cache (LRU)**
  - Implement ``src/kernel/storage/block_cache.zig`` managing a bounded pool of 64 page frames (256 KiB RAM).
  - Enforce mathematical page alignment on all cache buffers (Commandment 9).
  - Implement strict Least-Recently-Used (LRU) queue with write-back dirty page tracking.
  - Implement ``flush()`` to synchronize dirty cached sectors to physical media.

* **M14.3: Sovereign Content-Addressed Storage (CAS) Engine**
  - Implement ``src/kernel/storage/cas.zig`` and ``src/kernel/storage/chunk.zig``.
  - Freestanding BLAKE3 hashing via ``std.crypto.hash.Blake3`` with zero libc dependencies.
  - Append-only sector allocation for immutable chunks with 64-byte ``CasChunkHeader``.
  - Sector 0 Superblock management with monotonic generation counter and active Merkle root hash.
  - Content integrity verification on read, rejecting corrupt or tampered blocks with explicit errors.

* **M14.4: Capability-Governed Harness Bindings & Interactive REPL Commands**
  - Implement native VM bindings in ``src/kernel/harness_bindings.zig``:
    - ``sys_cas_put(data)`` -> returns 64-character hex BLAKE3 string.
    - ``sys_cas_get(hash)`` -> returns stored chunk content string.
    - ``sys_actor_persist(id)`` -> snapshots active actor source code and manifest to CAS.
    - ``sys_actor_spawn_cas(hash)`` -> retrieves chunk, compiles, and spawns isolated child actor.
  - Enforce CSpace capability security (``Rights.STORAGE_READ``, ``Rights.STORAGE_WRITE``).
  - Extend ``lib/macros/harness.mx`` with REPL commands: ``store``, ``fetch``, ``persist``, ``spawn_cas``.

* **M14.5: End-to-End Headless Verification & Reboot Persistence**
  - Update ``tools/micros-runner.bash`` with VirtIO-Blk disk image provisioning (``-device virtio-blk-pci,drive=disk0``).
  - Implement automated **Two-Stage Reboot Regression**:
    1. *Stage 1*: Boot QEMU, store actor script into CAS via REPL, record emitted hash, halt VM cleanly.
    2. *Stage 2*: Boot fresh QEMU instance with the same persistent disk image, invoke ``spawn_cas <hash>``, and assert identical execution on hardware without host or network assistance.
  - Enforce zero Ten Commandments infractions (``micros-lint``) and 100% specification traceability (``micros-spec-trace.bash``).
