======================================================
Pure Microkernel Storage Decoupling & DMA Pinning Spec
======================================================

:Document ID: SPEC-TECH-STORAGE-002
:Status: Approved
:Traced Stories: [US-REN-004], [US-REN-006], [US-REN-008], [US-GEM-001], [US-GEM-004], [US-GEM-010]

1. Architectural Axioms & Purpose
=================================
This specification formalizes the architectural excision of block storage drivers (PCIe NVMe 1.4, VirtIO-Blk split-virtqueues), partition parsers (GPT), filesystem readers (FAT32 ESP), and the cryptographic Content-Addressed Storage (CAS) engine from the Ring 0 microkernel into an isolated userland service actor: the Storage Service Daemon (``storaged``) in ``src/userland/storaged/storaged.zig``.

1.1 Microkernel Minimality & Mechanism vs Policy
------------------------------------------------
In monolithic operating systems, storage drivers, disk caches, and file systems execute with unrestricted kernel supervisor privileges. A hardware timeout, faulty disk firmware, or malformed partition table dereference causes an unrecoverable kernel panic.

Under the MicrOS pure microkernel architecture:

* **Ring 0 Mechanism**: The microkernel core retains strictly zero knowledge of sector layouts, partition schemes, filesystems, CAS chunking, or BLAKE3 hashing. Ring 0 provides only physical memory frame management, interrupt line notification tokens, and capability-gated DMA buffer pinning (``sys_dma_pin``).
* **Ring 3 Storage Policy**: The ``storaged`` actor executes in hardware Ring 3 within an isolated 4-level CR3 virtual address space. It holds an explicit ``CapType.storage_device`` capability token granting permission to issue block I/O requests.
* **Fault Containment & Automatic Recovery**: If ``storaged`` faults, panics, or encounters a hardware stall, the supervisor actor isolates the crash, signals a hardware controller reset, and restarts the daemon with zero data loss or host machine reboot.

2. Storage Service Actor (storaged) Architecture
================================================

2.1 Lifecycle State Machine
---------------------------
The ``StorageDaemon`` actor in ``src/userland/storaged/storaged.zig`` operates a deterministic state machine:

.. code-block:: zig

   pub const DaemonState = enum(u8) {
       uninitialized = 0,
       probing = 1,
       ready = 2,
       busy = 3,
       recovering = 4,
       faulted = 5,
   };

Transitions occur deterministically:
1. ``uninitialized`` -> ``probing``: Struct allocation and block device discovery (VirtIO-Blk / NVMe).
2. ``probing`` -> ``ready``: Capability verification, block cache allocation, CAS initialization, and partition table validation.
3. ``ready`` -> ``busy``: Processing active sector read/write transactions or CAS object transfers.
4. ``busy`` -> ``ready``: Transaction completion, descriptor retirement, and client response emission.
5. Any state -> ``recovering``: Controller timeout or transport stall detected; hardware reset initiated.
6. ``recovering`` -> ``ready``: Hardware queues re-established, in-flight commands replayed or aborted cleanly.
7. ``recovering`` -> ``faulted``: Unrecoverable hardware bus failure; supervisor alerted.

2.2 Hardware Capability Delegation
----------------------------------
Access to persistent storage media requires explicit CSpace capability tokens:

* **Storage Capability**: ``CapType.storage_device`` with ``Rights.READ | Rights.WRITE``.
* **DMA Capability**: ``CapType.memory_extent`` with ``Rights.ALL`` identifying page-aligned memory spans authorized for DMA data transfers.
* **IRQ Capability**: ``CapType.irq_endpoint`` with ``Rights.WRITE`` granting authority to receive and acknowledge storage controller interrupts via ``sys_irq_ack``.

3. Kernel DMA Buffer Pinning Substrate (sys_dma_pin)
====================================================

3.1 Security Invariants of Userland DMA
---------------------------------------
Allowing userland storage drivers to configure Direct Memory Access (DMA) physical addresses presents a critical security vulnerability: a malicious or compromised storage actor could direct the disk controller to DMA data over kernel page tables (CR3), the Interrupt Descriptor Table (IDT), or kernel code.

To prevent this exploit vector, the microkernel implements the ``sys_dma_pin`` capability syscall in ``src/kernel/cap/cap_abi.zig``:

.. code-block:: zig

   pub fn sys_dma_pin(
       caller_actor: *Actor,
       virt_addr: usize,
       len_bytes: usize,
       out_phys_addr: *u64,
   ) anyerror!void

3.2 Pinning & Validation Rules
------------------------------
1. **Capability Gate**: The caller must present an authorized ``CapType.storage_device`` token with ``Rights.WRITE``.
2. **Boundary Validation**: The virtual address range ``[virt_addr, virt_addr + len_bytes)`` must reside strictly within the caller's lower-half userland virtual address space (``< 0x0000_7FFF_FFFF_FFFF``). Any pointer pointing into the higher-half kernel space (``>= 0xFFFF_8000_0000_0000``) is rejected immediately with ``error.PermissionDenied``.
3. **Alignment Validation**: ``virt_addr`` must be aligned to 4096-byte page boundaries (``virt_addr % 4096 == 0``). ``len_bytes`` must be a positive multiple of 512 bytes (sector alignment).
4. **Physical Frame Verification**: The kernel walks the caller's 4-level page table to retrieve the physical page frame backing ``virt_addr``. It verifies that the underlying physical page is allocated to the caller and marks the frame as pinned in the PMM, mathematically preventing swapping, unmapping, or re-allocation while DMA is active.

4. Hardware Controller Reset & Crash Recovery
=============================================

4.1 NVMe Controller Reset Sequence
----------------------------------
When an NVMe submission queue stalls, times out (> 5000ms), or ``storaged`` crashes, the recovery protocol executes:

1. **Disable Controller**: Write ``CC.EN = 0`` (bits 0 of Controller Configuration).
2. **Poll for Ready De-assertion**: Poll Controller Status (``CSTS.RDY``) with a bounded WCET loop until ``CSTS.RDY == 0``.
3. **Queue Re-allocation**: Reset Admin Submission Queue (ASQ) and Admin Completion Queue (ACQ) head/tail doorbell pointers to 0.
4. **Re-enable Controller**: Write ``CC.EN = 1`` with configured page sizes and command sets.
5. **Poll for Ready Assertion**: Poll ``CSTS.RDY == 1`` with bounded iterations.
6. **Re-create I/O Queues**: Issue NVMe Admin commands to recreate I/O Submission and Completion queues.

4.2 VirtIO-Blk Controller Reset Sequence
----------------------------------------
1. **Device Reset**: Write ``0x00`` to the Device Status register.
2. **Acknowledge & Driver**: Write ``VIRTIO_STATUS_ACKNOWLEDGE | VIRTIO_STATUS_DRIVER`` to Device Status.
3. **Virtqueue Reset**: Clear all split-virtqueue descriptor rings, reset ``last_used_idx = 0`` and available ring flags.
4. **Driver Ready**: Write ``VIRTIO_STATUS_DRIVER_OK`` to resume transaction processing.

5. Storage IPC Protocol & Ring Buffer Dispatch
==============================================

5.1 Request & Response Envelopes
--------------------------------
Communication between client actors (such as MicroShell, compiler, or AI daemon) and ``storaged`` occurs exclusively over lock-free SPSC / MPSC ring buffers using strongly typed binary commands:

.. code-block:: zig

   pub const StorageIpcCommand = enum(u8) {
       none = 0,
       read_sector = 1,
       write_sector = 2,
       flush = 3,
       cas_store = 4,
       cas_load = 5,
       manifest_commit = 6,
       status = 7,
   };

   pub const StorageIpcResponse = enum(u8) {
       ok = 0,
       io_error = 1,
       corrupted_hash = 2,
       device_fault = 3,
       busy = 4,
   };

5.2 Syscall Transparent Proxying
--------------------------------
The existing in-kernel CAS and Workspace Catalog syscalls:
* ``sys_cas_put``
* ``sys_cas_get``
* ``sys_catalog_write``
* ``sys_catalog_read``
* ``sys_catalog_commit``

are routed through the storage broker ABI. When ``storaged`` is active, these syscalls dispatch command envelopes to ``storaged``'s input IPC ring and await completion, maintaining 100% binary compatibility with existing userland actors while executing block I/O entirely outside Ring 0.

6. Verification & Mathematical Invariants
=========================================
1. **Sector Alignment Invariant**: All disk transfer buffers and cache frames must mathematically enforce 512-byte sector and 4096-byte page alignment (``align(512)``, ``align(4096)``).
2. **Cryptographic Verification**: Every CAS chunk read must be hashed with BLAKE3 and compared against the requested 256-bit hash. Any mismatch returns ``error.CorruptedChunk``.
3. **Monotonic Superblock Updates**: The storage superblock must only advance monotonically via generation counter upon verified flush.
4. **Bounded WCET**: Hardware polling loops in controller reset sequences must enforce a strict upper bound of 100,000 iterations before aborting with ``error.DeviceTimeout``.
