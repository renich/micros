===========================================
MicrOS (µOS) Master Engineering Roadmap
===========================================

:Status: Approved
:Architecture Authority: Lead Architect & Measured Adversary (Crucible Adjudicated)
:Target Horizon: Sovereign In-System Self-Hosting & Distributed P2P Federation
:Date: 2026-09-18

Executive Summary
=================
This master roadmap defines the multi-phase engineering trajectory for **MicrOS (µOS)** and the **Macros** programming language. Starting from direct-syscall Linux userspace sandboxing and transitioning through bare-metal UEFI initialization, language bootstrap, reactive windowing, in-system PE32+ kernel synthesis, and microkernel decoupling, the system systematically severs dependencies on legacy operating systems, runtime wrappers, and centralized registries.

Every phase and milestone enforces strict mathematical invariants:
- **The 14 Sovereign Commandments of Code Quality** (< 1,000 LOC per file, < 40 LOC per function, max nesting depth 3, zero libc, explicit allocators).
- **Object-Capability Discipline (CSpace)**: Zero ambient authority across memory, hardware MMIO, DMA buffers, and inter-process communication.
- **Pure Microkernel Minimality**: Ring 0 restricted exclusively to CPU scheduling, 4-level virtual memory, capability enforcement, and interrupt/IPC routing. All device drivers, filesystems, and network stacks reside in isolated Ring 3 service actors.
- **Bit-for-Bit Cryptographic Reproducibility**: 256-bit BLAKE3 content addressing for all code artifacts, chunks, manifests, and compiled modules.

Master Macro-Timeline & Architecture Graph
==========================================

.. image:: /diagrams/roadmaps/master-roadmap.svg
   :alt: MicrOS Master Engineering Roadmap Architecture
   :align: center

Phase Progression & Document Index
==================================

.. toctree::
   :maxdepth: 2
   :caption: Roadmap Phases

   roadmaps/phase-0-userspace-sandbox
   roadmaps/phase-1-bare-metal-substrate
   roadmaps/phase-2-language-factory
   roadmaps/phase-3-subsystems-compositor
   roadmaps/phase-4-sovereign-cord-cutting
   roadmaps/phase-5-ecosystem-decoupling
   roadmaps/phase-6-microkernel-preemption-smp
   roadmaps/phase-7-declarative-hypermedia-ui
   roadmaps/phase-8-p2p-federation-cas
   roadmaps/phase-9-self-hosting-silicon

Completed Foundations (Phases 0 through 5)
==========================================

* **Phase 0: Userspace Sandbox on Fedora Launchpad** [COMPLETE & VERIFIED]
  - Established direct Linux x86_64 syscall harness without libc, ``micros-init`` (PID 1), ``msh`` interactive shell, and single-binary Unified Kernel Image (UKI) delivery under QEMU.
* **Phase 1: The Bare-Metal Substrate (UEFI & Microkernel)** [COMPLETE & VERIFIED]
  - Severed host kernel dependency. Booted directly from UEFI firmware (``boot.efi``), 4-level paging VMM, physical memory bitmap PMM, IDT exceptions, APIC/TSC timers, and VirtIO PCI drivers.
* **Phase 2: Language & Runtime Factory (Macros)** [COMPLETE & VERIFIED]
  - Implemented Macros language AST, lexer, parser, compiler, 32 KiB block Immix mark-region GC, cooperative green-thread fibers, x86_64 JIT codegen, and pure Macros Stage 1 self-hosting compiler.
* **Phase 3: Subsystems & Reactive Vector Compositor** [COMPLETE & VERIFIED]
  - Implemented VirtIO-Blk & CAS storage, VirtIO-Net, TLS 1.3, resident AI integration, 4-layer process hierarchy (kernel -> init -> msh -> harness), and double-buffered GOP vector compositor with AABB damage tracking.
* **Phase 4: Sovereign Cord-Cutting & Bit-for-Bit Self-Rebuilding Pipeline** [COMPLETE & VERIFIED]
  - Delivered in-system MCB synthesizer, PE32+ kernel synthesizer, fail-safe dual-slot A/B staging, polled PCIe NVMe 1.4 driver, GPT partitioning, FAT32 ESP driver, and proven bit-for-bit rebuild reproducibility.
* **Phase 5: Sovereign Networking, Workspace & Pure Microkernel Decoupling** [COMPLETE & VERIFIED]
  - Delivered fast-path TCP server, Git smart HTTP transport & packfile CAS ingestion, Merkle workspace catalog, ``vedit`` visual editor, content-addressed module system, and decoupled ``netd`` and ``aid`` into userland actors over SPSC IPC rings.

Active Target: Phase 6 (Pure Microkernel & Preemptive SMP)
==========================================================

The current active operational frontier addresses the hardware privilege, preemption, and driver isolation boundaries:

1. **Milestone 23a: Hardware Ring 3 & Syscall Substrate**:
   - Establish 64-bit Task State Segment (TSS) with per-core ``RSP0`` stacks; execute ``ltr``.
   - Configure MSRs (``EFER.SCE``, ``STAR``, ``LSTAR``, ``SFMASK``) for fast userland ``syscall``/``sysret`` transitions.
   - Implement per-actor CR3 virtual address spaces with strict user/supervisor bit protection.
2. **Milestone 23b: Preemptive Symmetric Multiprocessing (SMP) & APIC Timer Substrate**:
   - Initialize Local APIC timer interrupts (1000Hz quantum) via IDT vector ``0x20`` for hardware preemption.
   - Bootstrap secondary CPU cores (APs) via APIC INIT-SIPI-SIPI into 64-bit Long Mode.
   - Implement Multi-Producer Single-Consumer (MPSC) lock-free IPC rings and per-core work-stealing scheduling.
3. **Milestone 24: Pure Microkernel Compositor & Input Decoupling (gopd)**:
   - Migrate GOP linear framebuffer mapping, AABB dirty-rect clipping, and window manager into userland actor ``gopd``.
   - Integrate PS/2 mouse and baseline xHCI USB HID pointer/keyboard decoding into ``gopd`` input ingress.
4. **Milestone 25: Pure Microkernel Storage Decoupling (storaged)**:
   - Migrate PCIe NVMe 1.4, VirtIO-Blk, GPT, FAT32, and CAS into userland actor ``storaged``.
   - Implement ``sys_dma_pin`` capability syscall for physical frame validation and PRP list construction.
   - Implement hardware controller reset and request replay on driver fault recovery.
5. **Milestone 26: Formal Microkernel Minimality Audit & Silicon Validation**:
   - Verify functional purity: Zero drivers, zero network stacks, zero filesystems in Ring 0 (< 2,000 LOC ceiling).
   - Validate live boot, SMP execution, and driver stability on physical x86_64 bare-metal test hardware.

Future Horizons (Phases 7 through 9)
====================================

* **Phase 7: Declarative Hypermedia UI & Vector Graphics Substrate**:
  - Binary component tree streaming protocol (µHTML / HyperTree) over shared-memory IPC rings.
  - AABB-bounded Signed Distance Field (SDF) vector rasterizer with glyph atlas caching and scalable typography.
  - Sovereign Desktop Environment (``desk.mx`` glass desktop with full multi-window pointer interaction).
* **Phase 8: Autonomous Peer-to-Peer Federation & Distributed CAS**:
  - Mutual TLS 1.3 / Noise wire protocol peering across nodes over TCP port 8080.
  - Decentralized BLAKE3 CAS chunk replication and Merkle workspace synchronization with offline-first OCC.
  - Cryptographic capability delegation tokens (Macaroons / Ed25519) for secure remote actor execution.
* **Phase 9: In-System Self-Hosting & Complete Silicon Independence**:
  - Pure in-system native machine code compiler backend compiling Zig/Macros directly on raw silicon.
  - Sovereign package and module federation registry with Ed25519 cryptographic signing.
  - Enterprise bare-metal hardware validation across diverse physical server boards and network controllers.
