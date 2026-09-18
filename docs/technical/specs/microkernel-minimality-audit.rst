========================================================
Formal Microkernel Minimality Audit & Silicon Validation
========================================================

:Document ID: SPEC-TECH-MIN-001
:Status: Approved
:Traced Stories: [US-REN-004], [US-REN-006], [US-REN-007], [US-REN-008], [US-GEM-001], [US-GEM-007], [US-GEM-010]

1. Architectural Axioms & Minimality Criterion
==============================================
This specification formalizes the architectural purity audit and bare-metal hardware validation for MicrOS (µOS), establishing that the Ring 0 microkernel core has achieved true seL4-class minimality following the complete excision of device drivers, filesystems, and display rendering into isolated Ring 3 userland service actors.

1.1 The seL4 Minimality Axiom: Mechanism vs Policy
--------------------------------------------------
A true microkernel implements only mechanism, never policy. In MicrOS:

* **Ring 0 Microkernel Core**: Implements strictly 5 fundamental mechanisms:
  1. **Physical Memory Management (PMM)**: Bitmap-backed allocation and freeing of 4096-byte physical page frames.
  2. **Virtual Memory Management (VMM)**: Per-actor 4-level CR3 page table directory creation, mapping, unmapping, and TLB invalidation.
  3. **Capability Space (CSpace)**: Token-based access control, attenuation, and unforgeable authority verification with zero ambient authority.
  4. **Preemptive SMP Scheduling**: Local APIC 1000Hz timer preemption, per-core runqueues, and lock-free work-stealing across multicore CPUs.
  5. **Hardware Trap & IPC Redirection**: Interrupt Descriptor Table (IDT) fault containment and lock-free SPSC / MPSC ring buffer signaling.

* **Ring 3 Isolated Userland Daemons**: All complex subsystems operate outside supervisor privilege in isolated virtual address spaces:
  - ``netd`` (``src/userland/netd/netd.zig``): VirtIO-Net 1.0 packet management, ARP, IPv4, DHCP, and Fast-Path TCP.
  - ``aid`` (``src/userland/aid/aid.zig``): Post-quantum TLS 1.3, HTTP/1.1 REST client framing, and cognitive LLM prompt synthesis.
  - ``gopd`` (``src/userland/gopd/gopd.zig``): GOP framebuffer canvas rasterization, double-buffering, AABB dirty rectangle damage tracking, and PS/2 input decoding.
  - ``storaged`` (``src/userland/storaged/storaged.zig``): PCIe NVMe 1.4, VirtIO-Blk split-virtqueues, GPT partition parsing, FAT32 ESP handling, and BLAKE3 CAS.

1.2 Quantitative Purity Boundaries
----------------------------------
To mathematically prevent codebase rot and maintain auditable security:
1. **File Size Limit**: No file in the repository shall exceed 1,000 lines of code.
2. **Function Complexity Limit**: No function shall exceed 40 lines of executable logic.
3. **Nesting Depth Limit**: Maximum control-flow nesting depth is 3 levels.
4. **Zero Libc**: The substrate layer and kernel must never import, link against, or depend on libc.
5. **Zero Ambient Authority**: Direct access to hardware, MMIO, or physical frames requires explicit CSpace capability tokens.

2. Capability Security Gate & Attenuation Audit
===============================================

2.1 Capability Verification Properties
--------------------------------------
Every access to a physical resource must pass an unforgeable capability check:

* **Monotonic Attenuation**: When capability handles are granted or transferred between actors, rights bitmasks must only monotonically decrease (``child_rights = parent_rights & mask``). An actor can never elevate its rights.
* **Revocation Hygiene**: Unmapping a memory capability immediately executes a TLB invalidation (``invlpg``) and verifies DMA quiescence before physical page frames may be reallocated.
* **DMA Boundary Gating**: Userland DMA requests (``sys_dma_pin``) verify that target virtual memory resides strictly within the caller's lower-half address space (``< 0x0000_7FFF_FFFF_FFFF``), preventing userland drivers from directing hardware DMA over kernel page tables or kernel text.

2.2 Formal Attenuation Matrix
-----------------------------

+---------------------+-------------------+------------------------------------------+
| Resource Domain     | Capability Type   | Validated Rights Mask                    |
+=====================+===================+==========================================+
| Physical Memory     | `memory_extent`   | `READ`, `WRITE`, `EXECUTE`, `GRANT`      |
+---------------------+-------------------+------------------------------------------+
| Ring Buffers        | `ipc_ring`        | `READ`, `WRITE`, `ALL`                   |
+---------------------+-------------------+------------------------------------------+
| Hardware Interrupts | `irq_endpoint`    | `WRITE` (signal & ack)                   |
+---------------------+-------------------+------------------------------------------+
| Display Hardware    | `framebuffer`     | `READ`, `WRITE`                          |
+---------------------+-------------------+------------------------------------------+
| Network Hardware    | `network_device`  | `ALL`                                    |
+---------------------+-------------------+------------------------------------------+
| Storage Hardware    | `storage_device`  | `READ`, `WRITE`, `ALL`                   |
+---------------------+-------------------+------------------------------------------+
| Process Supervision | `actor_control`   | `WRITE` (spawn, kill, suspend)           |
+---------------------+-------------------+------------------------------------------+

3. Bare-Metal Silicon Hardware Validation
=========================================

3.1 Automated UEFI Boot Artifact Generation
-------------------------------------------
The build system declaratively emits standard UEFI boot artifacts:

* **ESP Staging**: Creates FAT32 EFI System Partition containing ``EFI/BOOT/BOOTX64.EFI`` (compiled PE32+ executable).
* **Direct Kernel Execution**: The UEFI bootloader initializes GOP video modes, validates physical memory map, prepares ``BootInfo`` structures, and jumps directly to 64-bit Long Mode ``kmain``.
* **Zero QEMU Crutches**: The kernel relies strictly on standard UEFI 2.x interfaces, PCIe configuration space enumeration, and architectural x86_64 CPUID/MSR features, guaranteeing 100% portability to physical bare-metal silicon.

3.2 Bare-Metal Test Targets
---------------------------
Physical silicon qualification validates execution across diverse microarchitectures:

1. **Intel Architecture**: Intel Core 10th-14th Generation (Comet Lake, Raptor Lake) and Xeon Scalable processors.
2. **AMD Architecture**: AMD Ryzen 3000-9000 Series (Zen 2 through Zen 5) and EPYC server platforms.
3. **Multicore APIC Verification**: Verification of secondary core bringup via APIC INIT-SIPI-SIPI sequencing and work-stealing preemption across physical cores.
4. **Physical Controller Validation**: Validation of physical NVMe 1.4 SSD controllers and VirtIO-Blk devices with DMA frame pinning.

4. Mathematical Invariants & Release Sign-Off
=============================================
1. **100% Bidirectional Specification Traceability**: Verified via ``./tools/micros-spec-trace --check`` across all business user stories, technical blueprints, and implementation modules.
2. **AST Linting Compliance**: Verified via ``./tools/micros-lint src/`` with zero rule violations.
3. **Deterministic Unit Testing**: 100% pass rate across the full test suite with explicit allocators and zero memory leaks.
4. **Live Boot Sentinel Proof**: Verified live execution to the interactive MicroShell prompt under QEMU and bare-metal UEFI harnesses.
