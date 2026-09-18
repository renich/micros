Milestone 25: Pure Microkernel Storage Decoupling (storaged)
=============================================================

:Objective: Migrate PCIe NVMe 1.4 controller drivers, VirtIO-Blk split-virtqueues, GPT partition parsers, FAT32 ESP filesystem handlers, and the BLAKE3 CAS engine out of Ring 0 microkernel memory into an isolated userland storage daemon (``storaged``), enforcing secure DMA buffer pinning and fault recovery.
:Status: Completed
:Specification: SPEC-TECH-STORAGE-002
:Traced Stories: [US-REN-004], [US-REN-006], [US-REN-008], [US-GEM-001], [US-GEM-004], [US-GEM-010]

Milestones & Deliverables
-------------------------

* **M25.1: Userland Storage Daemon (storaged)**
   - Author ``src/userland/storaged/storaged.zig`` as an isolated Ring 3 service actor holding ``CapType.hardware_device`` for block storage.
   - Migrate PCIe NVMe 1.4 Admin and I/O submission/completion queue drivers, PRP list managers, and doorbell registers out of Ring 0.
   - Migrate VirtIO-Blk driver, GPT partitioner, 8.3 FAT32 ESP driver, and BLAKE3 CAS engine into userland.

* **M25.2: Kernel DMA Buffer Pinning (sys_dma_pin)**
   - Implement ``sys_dma_pin`` capability syscall in ``src/kernel/cap/cap_abi.zig``.
   - Validates caller-supplied virtual buffers, verifies physical page allocation, and pins frames to prevent swapping or re-allocation.
   - Restricts physical address access strictly to authorized DMA regions, preventing userland storage drivers from directing hardware DMA over kernel page tables or kernel text.

* **M25.3: Hardware Controller Reset & Crash Recovery**
   - Implement fail-safe hardware re-initialization protocol: upon driver crash, supervisor signals kernel to reset the controller (``CC.EN = 0`` -> wait for ``CSTS.RDY == 0``).
   - Abort in-flight I/O requests cleanly and re-allocate submission/completion queues before restarting ``storaged``.

* **M25.4: Storage IPC Protocol & Syscall Proxying**
   - Implement strongly typed MPSC IPC protocol for block I/O (``StorageReq.ReadSector``, ``StorageReq.WriteSector``, ``StorageReq.CasStore``, ``StorageReq.CasLoad``).
   - Proxy client syscalls (``sys_cas_read``, ``sys_cas_write``, ``sys_catalog_*``) transparently over IPC rings to ``storaged``.
