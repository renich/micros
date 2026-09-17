================================================
Sovereign Cord-Cutting & Silicon Deployment Spec
================================================

:Document ID: SPEC-TECH-SILICON-001
:Status: Approved
:Traced Stories: [US-REN-003], [US-REN-004], [US-REN-007], [US-GEM-007], [US-GEM-010]
:Roadmap Target: Milestone 18 (docs/project/roadmaps/milestone-18-sovereign-cord-cutting.rst)

1. Architectural Axioms & Purpose
=================================
The foundational mission of MicrOS is absolute computational sovereignty: the operating system must not remain an ephemeral guest inside host operating systems (Linux/Fedora), virtualized emulators (QEMU/KVM), or host build toolchains (Zig, GNU Make, GCC, Clang/LLVM).

Milestone 18 severs the umbilical cord to external hosts. It transitions MicrOS to a self-sufficient, bare-metal operating system capable of:
1. Communicating directly with physical PCIe NVMe solid-state storage via memory-mapped I/O (MMIO) and direct memory access (DMA).
2. Partitioning raw physical disks with standard GUID Partition Tables (GPT).
3. Formatting minimal FAT32 EFI System Partitions (ESP) to satisfy physical firmware requirements without POSIX filesystem bloat.
4. Synthesizing valid 64-bit UEFI PE32+ executables (``BOOTX64.EFI``) entirely within the running system without external linkers.
5. Deploying itself onto bare metal through an interactive and AI-autonomous Macros installer (``lib/macros/installer.mx``).
6. Staging cryptographically verified kernel images into ESP and managing fail-safe generational rollbacks via Content-Addressed Storage (CAS) superblocks.

2. The Mechanism vs. Policy Boundary
====================================
Adhering strictly to microkernel principles, MicrOS enforces an absolute architectural separation between low-level Ring 0 mechanisms and high-level userspace policies:

.. code-block:: text

   +-------------------------------------------------------------------------+
   | Userspace Policy Layer (lib/macros/installer.mx & Resident AI)          |
   | - Interactive & AI-Autonomous Installation Wizards                      |
   | - Partition Sizing Decisions, Formatting Workflows                      |
   | - PE/COFF Binary Synthesis & Genesis Bundle Staging                     |
   +------------------------------------+------------------------------------+
                                        | System ABI & Capabilities
                                        v
   +-------------------------------------------------------------------------+
   | Microkernel Mechanism Layer (Ring 0/Freestanding Zig Substrate)         |
   | - Polymorphic BlockDevice Interface (src/kernel/drivers/block.zig)      |
   | - PartitionBlockDevice Slice Isolation (Decouples CAS from LBA 0)       |
   | - Polled PCIe NVMe 1.4 Driver (src/kernel/drivers/nvme.zig)             |
   | - GPT Header & Array Parser/Writer (src/kernel/drivers/gpt.zig)         |
   | - Minimal 8.3 ESP FAT32 Emitter (src/kernel/storage/fat32.zig)          |
   +-------------------------------------------------------------------------+

Under this model:
* **Ring 0 Microkernel**: Implements raw hardware drivers, memory-safe queue operations, block device slices, and cryptographic CAS validation.
* **Macros Userspace**: Implements the deployment workflow, user prompts, disk selection algorithms, and system verification logic.

3. Storage Substrate & Partitioning Architecture (M18.1)
========================================================

3.1 Generic BlockDevice Interface
---------------------------------
To decouple storage engines from specific hardware implementations, all storage devices implement a consumer-side ``BlockDevice`` abstraction in ``src/kernel/drivers/block.zig``:

.. code-block:: zig

   pub const SECTOR_SIZE: usize = 512;
   pub const PAGE_SIZE: usize = 4096;

   pub const BlockDevice = struct {
       ptr: *anyopaque,
       vtable: *const VTable,
       total_sectors: u64,
       sector_size: u32 = SECTOR_SIZE,
       name: [32]u8 = [_]u8{0} ** 32,

       pub const VTable = struct {
           readSector: *const fn (ctx: *anyopaque, lba: u64, buf: *[SECTOR_SIZE]u8) anyerror!void,
           writeSector: *const fn (ctx: *anyopaque, lba: u64, buf: *const [SECTOR_SIZE]u8) anyerror!void,
           readSectors: *const fn (ctx: *anyopaque, lba: u64, count: usize, buf: []u8) anyerror!void,
           writeSectors: *const fn (ctx: *anyopaque, lba: u64, count: usize, buf: []const u8) anyerror!void,
           flush: *const fn (ctx: *anyopaque) anyerror!void,
       };
   };

3.2 Partition Slice Abstraction (Decoupling CAS from LBA 0)
-----------------------------------------------------------
In the legacy implementation, CAS hardcoded ``SECTOR_SUPERBLOCK = 0`` and ``SECTOR_FIRST_CHUNK = 1``. On raw silicon, writing to physical LBA 0 destroys the Protective MBR and Primary GPT Header, corrupting the disk and rendering it unbootable by UEFI firmware.

To mathematically eliminate this collision, ``src/kernel/drivers/block.zig`` introduces ``PartitionBlockDevice``:

.. code-block:: zig

   pub const PartitionBlockDevice = struct {
       parent: *BlockDevice,
       start_lba: u64,
       sector_count: u64,
       device: BlockDevice,

       pub fn init(parent: *BlockDevice, start_lba: u64, sector_count: u64) PartitionBlockDevice { ... }
   };

* Physical LBA 0 through 2047 (1 MiB alignment) are permanently reserved for Protective MBR and GPT headers.
* The EFI System Partition (ESP) occupies LBA 2048 through 616447 (300 MiB).
* The MicrOS CAS partition occupies the remainder of the disk.
* The CAS engine operates strictly on a ``PartitionBlockDevice`` slice, mapping CAS sector 0 to physical LBA 616448. Physical LBA 0 is untouched by CAS operations.

3.3 Bare-Metal PCIe NVMe Controller Driver
------------------------------------------
``src/kernel/drivers/nvme.zig`` implements a freestanding NVMe 1.4 controller driver communicating directly over PCI Express MMIO and DMA:

1. **64-bit BAR0 MMIO Discovery**: Enforces 64-bit base address calculation in ``src/kernel/drivers/pci.zig`` to support controllers mapped above the 4 GiB physical threshold.
2. **Uncacheable Page Attributes**: Maps NVMe MMIO pages in the page tables with Uncacheable (``PCD=1, PWT=1``) attributes, preventing doorbell register writes from buffering in L1/L2 cache.
3. **Queue Architecture**:
   - Implements Admin Queue pair (ASQ/ACQ, Queue ID 0) for controller configuration.
   - Implements I/O Queue pair (IOSQ/IOCQ, Queue ID 1) for block read/write operations.
   - DMA rings are 4096-byte page-aligned (``align(4096)``) in physical memory.
4. **Polled Completion & Phase Tagging**:
   - Polls completion queue entry (CQE) phase bits using CPU ``pause`` instructions.
   - Issues memory barrier (``asm volatile ("lfence" ::: "memory")``) prior to status inspection.
5. **PRP Transfer Chaining**:
   - Single-sector and 4 KiB transfers use ``PRP1``.
   - 8 KiB transfers use ``PRP1`` and ``PRP2``.
   - Large multi-page transfers (> 8 KiB) allocate an 8-byte aligned physical PRP List page.
6. **Geometry & Sector Sizing**:
   - Issues ``Identify Namespace 1`` (Admin Opcode ``0x06``) to read ``FLBAS`` and discover native sector geometry.
   - Automatically configures sector shift for 512-byte emulation (``512e``, shift 9) or 4096-byte native (``4Kn``, shift 12).
7. **Timeout Calibration**:
   - Calibrates controller initialization against ``CAP.TO`` (specified in 500 millisecond units), supporting real-world hardware drives that require up to 30 seconds for ready status (``CSTS.RDY == 1``).

3.4 GUID Partition Table (GPT) Substrate
----------------------------------------
``src/kernel/drivers/gpt.zig`` provides declarative GPT manipulation:
* **Protective MBR**: Emitted at LBA 0 with a single partition entry of type ``0xEE`` spanning the disk.
* **Primary GPT Header**: Emitted at LBA 1 with magic ``0x5452415020494645`` (``"EFI PART"``), revision ``0x00010000``, header size 92 bytes, and IEEE 802.3 CRC32 checksums.
* **Partition Array**: 128 partition entries (128 bytes each) spanning LBA 2 through 33:
  - ESP GUID: ``C12A7328-F81F-11D2-BA4B-00A0C93EC93B``
  - MicrOS CAS GUID: ``4D494352-4F53-4341-5300-000000000001``
* **Backup GPT**: Replicated at the final 33 sectors of the disk for fault recovery.

3.5 Minimal FAT32 ESP Driver
----------------------------
``src/kernel/storage/fat32.zig`` implements a specialized, minimal FAT32 filesystem engine tailored specifically for UEFI firmware boot delivery:
1. **The 65,525 Cluster Threshold**:
   - UEFI firmware identifies FAT type strictly by cluster count:
     :math:`\text{CountOfClusters} \ge 65525 \implies \text{FAT32}`.
   - To guarantee FAT32 identification with 4 KiB clusters, the ESP partition must be formatted to at least 260 MiB. MicrOS standardizes on a 300 MiB ESP (76,800 clusters).
2. **Strict 8.3 Short Filename Support**:
   - Mandates short 8.3 uppercase filenames (``/EFI/BOOT/BOOTX64.EFI``), eliminating hundreds of lines of complex Long File Name (LFN/VFAT) logic, UCS-2 conversions, and directory checksum sequences.
3. **Cluster Allocation Math**:
   - Clusters 0 and 1 are reserved; first usable data cluster is Cluster 2.
   - Sector address: :math:`\text{LBA} = \text{FirstDataSector} + ((C - 2) \times \text{SectorsPerCluster})`.

4. Pure Freestanding PE/COFF 64-Bit Synthesizer (M18.2)
=======================================================
``src/boot/pe_emitter.zig`` implements an in-memory PE32+ executable synthesizer capable of generating bootable ``BOOTX64.EFI`` binaries without external linkers (``lld``, ``gnu-ld``):

.. code-block:: text

   +-------------------------------------------------------------+
   | MS-DOS 2.0 Compatible Stub (64-byte Header, e_lfanew = 0x80)|
   +-------------------------------------------------------------+
   | PE Signature: "PE\0\0" (0x00004550)                         |
   +-------------------------------------------------------------+
   | COFF File Header: Machine = 0x8664 (AMD64), 4 Sections      |
   +-------------------------------------------------------------+
   | PE32+ Optional Header (240 bytes):                          |
   | - Magic = 0x020B (PE32+)                                    |
   | - Subsystem = 10 (IMAGE_SUBSYSTEM_EFI_APPLICATION)          |
   | - SectionAlignment = 4096 (0x1000)                          |
   | - FileAlignment    = 512  (0x200)                           |
   +-------------------------------------------------------------+
   | Section Table:                                              |
   | - .text   (RX,  Characteristics = 0x60000020)               |
   | - .rodata (R,   Characteristics = 0x40000040)               |
   | - .data   (RW,  Characteristics = 0xC0000040)               |
   | - .reloc  (R,   Characteristics = 0x42000040)               |
   +-------------------------------------------------------------+
   | Section Payloads & Relocation Blocks (IMAGE_REL_BASED_DIR64)|
   +-------------------------------------------------------------+

Key Synthesizer Invariants:
* **W^X Hardware Memory Protection**: Sections strictly segregate executable code from writable data, complying with modern UEFI firmware NX/DEP hardware security policies.
* **Base Relocation Table (ASLR)**: Emits ``IMAGE_BASE_RELOCATION`` blocks with Type 10 (``IMAGE_REL_BASED_DIR64``) entries, ensuring UEFI firmware can load the binary at arbitrary physical base addresses without crashing on RIP-relative or absolute pointers.

5. Sovereign Standalone System Installer (M18.3)
================================================
``lib/macros/installer.mx`` provides an interactive and autonomous bare-metal installation wizard executing within Genesis Actor 0:

1. **Hardware Enumeration**: Scans attached block devices via native capability bindings (``sys_block_dev_list``).
2. **Drive Selection**:
   - In interactive mode: Prompts user with disk models, serial numbers, capacities, and sector sizes.
   - In autonomous AI mode: Evaluates disk health telemetry and selects the optimal unpartitioned silicon target.
3. **Partition & Seed Pipeline**:
   - Writes Protective MBR and GPT headers to target silicon.
   - Formats 300 MiB FAT32 ESP partition.
   - Synthesizes and writes ``/EFI/BOOT/BOOTX64.EFI``.
   - Formats CAS partition and stages the active Genesis bundle chunks (``genesis.mcb``) and core libraries.
   - Commits initial CAS superblock generation (generation 1) and verifies cold boot readiness.

6. Autonomous Rebuild & Rollback Engine (M18.4)
==============================================

6.1 Eradicating the In-Kernel Zig Compiler Illusion
---------------------------------------------------
A fatal pitfall identified during architectural review was the proposal to "recompile kernel Zig source code inside the microkernel." The MicrOS microkernel is written in Zig; Macros does not possess a native Zig compiler or optimizing LLVM backend. Embedding a Zig compiler in Ring 0 would introduce over 500,000 lines of code, completely violating the Ten Commandments and destroying microkernel isolation.

6.2 Sovereign Rebuilding Architecture
-------------------------------------
Sovereign rebuilding in MicrOS is defined deterministically as:
1. **Source & Bytecode Autonomy**: Stage 1 and Stage 2 Macros compiler sources are maintained and recompiled entirely within Macros, producing bit-for-bit reproducible bytecode chunks verified via BLAKE3 hashes.
2. **Kernel Binary Staging**: Pre-verified, immutable kernel binary chunks stored in CAS are staged into the ESP partition (``/EFI/BOOT/BOOTX64.EFI``) upon verified system manifest changes.
3. **Cryptographic System Manifest**: Every deployed system is defined by a 448-byte ``SystemManifest`` (magic ``0x4D49434D``) stored as a 512-byte sector chunk in CAS, linking:
   - Microkernel binary BLAKE3 hash
   - Genesis bundle BLAKE3 hash
   - Root configuration manifest hash
   - Monotonic generation sequence counter

6.3 Fail-Safe Generational Rollback State Machine
-------------------------------------------------
To protect bare-metal silicon from unbootable kernel updates, ``src/kernel/storage/rebuild.zig`` implements an atomic A/B generational rollback protocol:

.. code-block:: text

   [Stable Gen N] ---> Stage New Kernel ---> [Trial Gen N+1 (Canary Bit = 1)]
                                                          |
                               +--------------------------+--------------------------+
                               |                                                     |
                               v (Boot Success)                                      v (Boot Failure/Fault)
                    [Stable Gen N+1 (Canary = 0)]                          [Rollback to Gen N]
                    (Canary cleared by init.mx)                            (Reverted by Bootloader)

* When staging an update, the superblock advances to Generation :math:`N+1` with the ``trial`` canary bit set.
* Upon booting, ``lib/macros/init.mx`` executes supervisor hardware checks. Once Actor 0 and MicroShell are confirmed online, it invokes ``sys_cas_confirm_boot`` to clear the canary bit and mark Generation :math:`N+1` as ``stable``.
* If a hardware trap, panic, or watchdog reset occurs before confirmation, the UEFI bootloader detects the unconfirmed canary bit and automatically reboots into Generation :math:`N`.

7. Ten Commandments & Code Quality Defense
==========================================
All code implemented for Milestone 18 complies strictly with ``AGENTS.md``:

1. **File Size Limit**: No file exceeds 1,000 lines of code:
   - ``src/kernel/drivers/block.zig``: ~250 lines
   - ``src/kernel/drivers/gpt.zig``: ~450 lines
   - ``src/kernel/drivers/nvme.zig``: ~650 lines
   - ``src/kernel/storage/fat32.zig``: ~450 lines
   - ``src/boot/pe_emitter.zig``: ~600 lines
   - ``src/kernel/storage/rebuild.zig``: ~350 lines
2. **Function Size Limit**: Maximum 40 lines per function. Hardware command dispatch and parsing functions are decomposed into atomic, single-responsibility helpers.
3. **Nesting Depth**: Maximum 3 levels of indentation. All hardware status polling loops use early guard clauses and flat control flow.
4. **Formatting**: Never use spaces around forward slashes (``word/word``, not ``word / word``).
5. **No Magic Numbers**: All constants, opcodes, and bitmasks are defined in ``UPPER_SNAKE_CASE`` (e.g., ``SYSTEM_MANIFEST_MAGIC = 0x4D49434D``, ``NVME_ADMIN_IDENTIFY = 0x06``).
6. **Explicit Errors**: All errors bubble up through explicit Zig error unions. Zero ``catch unreachable`` outside tests.
7. **Zero Libc**: Freestanding Zig substrate and raw PCIe MMIO only.
8. **Memory Safety**: Explicit ``Allocator`` parameters for all dynamic operations.
9. **Page Alignment**: Strict compile-time and runtime mathematical enforcement of 4096-byte page alignment for DMA buffers and 512-byte sector alignment for disk transfers.
10. **Test Colocation**: Unit tests colocated within every module running in ``zig build test``.

8. Acceptance Criteria & Definition of Done
===========================================
- [ ] ``BlockDevice`` abstraction and ``PartitionBlockDevice`` slice implemented with 100% test coverage.
- [ ] NVMe 1.4 driver initializes PCIe controller, sets up Admin and I/O queues, and executes polled DMA sector read/write.
- [ ] GPT driver creates valid Protective MBR and GPT headers passing CRC32 verification.
- [ ] Minimal FAT32 driver formats 300 MiB ESP partition with cluster count :math:`\ge 65,525` and creates ``/EFI/BOOT/BOOTX64.EFI``.
- [ ] PE/COFF synthesizer emits valid 64-bit UEFI application with base relocations and W^X section flags.
- [ ] Installer wizard in ``lib/macros/installer.mx`` deploys MicrOS to a secondary disk drive inside QEMU.
- [ ] Generational rollback protocol restores previous CAS generation upon canary boot failure.
- [ ] QEMU NVMe bare-metal execution passes cleanly in ``tools/micros-runner.bash``.
- [ ] AST linter (``tools/micros-lint``) reports zero Ten Commandments violations.
- [ ] Specification traceability auditor (``tools/micros-spec-trace``) reports 100% bidirectional coverage.
