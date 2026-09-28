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
   roadmaps/phase-10-hardening-cluster-mesh

Completed Foundations (Phases 0 through 9)
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
* **Phase 6: Pure Microkernel Hardware Excision & Preemptive Multiprocessing (SMP)** [COMPLETE & VERIFIED]
   - Delivered 64-bit Task State Segment (TSS) with per-core ``RSP0`` stacks, fast ``syscall``/``sysretq`` MSR configuration, per-actor CR3 virtual address spaces, Local APIC timer interrupts (1000Hz quantum), secondary CPU core AP bringup, MPSC IPC rings, ``gopd`` display server, ``storaged`` NVMe/CAS storage daemon, and microkernel minimality audit (< 2,000 LOC Ring 0).
* **Phase 7: Declarative Hypermedia UI & Vector Graphics Substrate** [COMPLETE & VERIFIED]
   - Delivered binary component tree streaming protocol (µHTML / HyperTree) over shared-memory IPC rings, 16.16 fixed-point SDF vector rasterizer with glyph atlas caching, and pure Macros sovereign desktop environment (``desk.mx``).
* **Phase 8: Autonomous Peer-to-Peer Federation & Distributed CAS** [COMPLETE & VERIFIED]
   - Delivered mutual TLS 1.3 / Noise wire handshake over TCP port 8080, Ed25519 node identities, decentralized BLAKE3 CAS chunk replication, Merkle tree sync with OCC reconciliation, and attenuated 192-byte capability tokens for remote actor compute.
* **Phase 9: In-System Self-Hosting & Complete Silicon Independence** [COMPLETE & VERIFIED]
   - Delivered pure in-system native machine code 64-bit ELF object synthesizer (``ElfEmitter``), sovereign package federation registry (``pkgd``) with Ed25519 cryptographic signing, and enterprise Intel e1000e/igb Gigabit Ethernet and USB 3.0 xHCI host controller drivers.

Active Operational Frontier: Phase 10 (Hardening, Daemon Handoff & Virtual Cluster Mesh)
========================================================================================

The current operational frontier focuses on hardening, full userland service handoff, and virtual multi-node orchestration under QEMU:

1. **Milestone 36: Full Userland Service Daemon Integration & Startup Handoff** [COMPLETE & VERIFIED]:
   - Integrated the full fleet of 6 userland daemons (``gopd``, ``storaged``, ``netd``, ``aid``, ``p2pd``, ``pkgd``) into unified kernel boot sequencing and CSpace table initialization.
   - Mediated all frame rendering, disk transfers, packet frames, AI inferences, P2P messages, and package queries strictly across zero-copy IPC rings.
   - Exposed live daemon telemetry and peer discovery status via ``msh`` and ``harness`` shell interfaces.
2. **Milestone 37: Virtual Multi-Node P2P Cluster Mesh Wire Discovery** [COMPLETE & VERIFIED]:
   - Implemented automated dual-node QEMU cluster harness (``tools/micros-cluster.bash``, ``make qemu-cluster-verify``) linking independent instances over a private point-to-point TCP stream interconnect.
   - Verified zero-configuration 74-byte UDP broadcast beacon discovery on port 8081 with Ed25519 node identities and capability-gated microkernel syscalls (``sys_peer_count``, ``sys_peer_info``, ``sys_p2p_status``).
   - Integrated dynamic ``peers`` and ``status`` cluster inspection in ``lib/macros/msh.mx``.
3. **Milestone 38: Distributed Content-Addressed Storage (CAS) Wire Replication** [ACTIVE TARGET]:
   - Wire ``ChunkRequest`` (``0x0006``) and ``ChunkEnvelope`` (``0x0007``) protocols over TCP port 8080.
   - Transparently replicate missing 256-bit BLAKE3 chunks across nodes upon local CAS miss.
   - Validate live cross-node object replication across the dual-node QEMU cluster harness.
4. **Milestone 39: Cryptographic Capability Delegation & Remote Actor Execution** [PLANNED]:
   - Deploy 192-byte signed capability tokens with rights attenuation and gas bounds.
   - Remote actor dispatch and result streaming over the cluster mesh.
5. **Milestone 40: Zero-Trust System Hardening, Self-Healing & Polish** [PLANNED]:
   - Audit IPC ring bounds, wire decoders, and capability checks against malformed packet streams.
   - Verify supervisory self-healing in ``init.mx`` with automatic recovery upon actor fault.
   - Polish interactive UX, conversational prompt ergonomics, and terminal ANSI rendering in ``harness.mx``.
