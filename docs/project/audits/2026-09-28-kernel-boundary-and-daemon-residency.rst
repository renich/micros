====================================================================
Architecture Decision Record: Kernel Boundary & Daemon Residency
====================================================================

:Date: 2026-09-28
:Status: Approved
:Context: Phase 7 Architectural Integrity Audit (MicrOS Substrate)
:Authors: Rénich Bon Ćirić & Antigravity Lead Architect

1. Context & Problem Statement
==============================
Initial architectural specifications and project marketing materials established an aspirational target of a pure seL4-class microkernel (< 2,000 LOC in Ring 0) with all hardware drivers, network protocol stacks, filesystems, and display compositing completely excised into isolated Ring 3 userland service daemons. Additionally, top-level documentation (``README.rst``) claimed a Ring 0 footprint of "< 15,000 LOC".

An empirical forensic LOC measurement executed during Phase 1 revealed:

- **Total Freestanding Ring 0 Kernel LOC**: **21,103 lines of code**.
- **Kernel-Resident Subsystems**: Hardware device drivers (VirtIO-Net, VirtIO-Blk, NVMe 1.4), full IPv4/TCP/UDP/DHCP/DNS/TLS network stacks, BLAKE3 Content-Addressed Storage (CAS), FAT32, GPT partitioning, GOP window compositor, and Gemini AI clients are currently compiled directly into supervisor space (Ring 0).
- **Userland Daemons**: Corresponding userland modules exist in ``src/userland/`` (``netd``, ``storaged``, ``gopd``, ``p2pd``, ``pkgd``, ``aid``), but physical device manipulation and core engines remain kernel-resident globals.

This document formally records the architectural rationale for this design, reconciles documentation with codebase reality, codifies a strict containment rule, and establishes the migration path toward true microkernel minimality.

2. Empirical Ring 0 Composition Table
======================================
The following table provides the authoritative subsystem breakdown of Ring 0 (``src/kernel/``) as of Milestone 26:

.. table:: Ring 0 Subsystem Footprint (21,103 LOC Total)
   :widths: 25 15 15 45

   +-----------------------+------------+------------+----------------------------------------------------+
   | Subsystem             | LOC        | Share (%)  | Primary Components                                 |
   +=======================+============+============+====================================================+
   | ``net/``              | 4,506      | 21.4%      | IPv4, TCP, UDP, ICMP, DHCP, DNS, TLS 1.3 stream    |
   +-----------------------+------------+------------+----------------------------------------------------+
   | ``storage/``          | 3,203      | 15.2%      | BLAKE3 CAS, Superblock, FAT32, Rebuild engine      |
   +-----------------------+------------+------------+----------------------------------------------------+
   | ``drivers/``          | 2,806      | 13.3%      | VirtIO-Net, VirtIO-Blk, NVMe 1.4, GPT, PIT, Serial |
   +-----------------------+------------+------------+----------------------------------------------------+
   | ``ai/``               | 1,851      | 8.8%       | Gemini API client, JSON envelope parser, tools     |
   +-----------------------+------------+------------+----------------------------------------------------+
   | ``compositor/``       | 1,491      | 7.1%       | GOP Canvas, Double buffer, Window Manager, Font    |
   +-----------------------+------------+------------+----------------------------------------------------+
   | ``arch/x86_64/``      | 1,371      | 6.5%       | APIC, GDT/TSS, IDT, Syscall (LSTAR), IO ports      |
   +-----------------------+------------+------------+----------------------------------------------------+
   | ``mem/``              | 806        | 3.8%       | Bitmap PMM, 4-level VMM paging, HHDM mappings      |
   +-----------------------+------------+------------+----------------------------------------------------+
   | ``cap/``              | 661        | 3.1%       | Capability space, monotonic attenuation, CSpace    |
   +-----------------------+------------+------------+----------------------------------------------------+
   | ``ipc/``              | 654        | 3.1%       | SPSC/MPSC lock-free ring buffers, Mailbox channels |
   +-----------------------+------------+------------+----------------------------------------------------+
   | ``sched/``            | 253        | 1.2%       | SMP multicore topology, APIC timer preemption      |
   +-----------------------+------------+------------+----------------------------------------------------+
   | Core Supervisor       | 3,501      | 16.6%      | ``main.zig``, ``actor.zig``, ``serial.zig``, sys   |
   +-----------------------+------------+------------+----------------------------------------------------+

3. Rationale for Monolithic Substrate Bringup
=============================================
The consolidation of storage, networking, drivers, and compositing within Ring 0 during Milestones 0 through 26 was a deliberate engineering compromise driven by the following axioms:

1. **Bare-Metal Silicon Bringup Velocity**: Booting on physical x86_64 silicon and UEFI platforms required tight coordination between memory management (PMM/VMM), PCIe enumeration, and VirtIO/NVMe descriptor rings. Implementing multi-address-space IPC context switches before hardware driver determinism was proven would have introduced unobservable race conditions.
2. **Freestanding Toolchain Independence**: Developing zero-libc cryptographic routines (BLAKE3, SHA-256, Ed25519, ML-KEM-768, AES-GCM) directly on raw physical memory simplified memory layout validation and eliminated cross-space serialization bugs.
3. **Deterministic Capability Gating**: Even within the unified kernel binary, all subsystem entry points have been structured around unforgeable Capability ABIs (``net_abi.zig``, ``storage_abi.zig``, ``catalog_abi.zig``, ``p2p_abi.zig``), establishing the precise contract required for future out-of-process extraction.

4. Interim Containment Rule
============================
To prevent codebase drift and enforce architectural hygiene:

**STRICT RING 0 FREEZE RULE**:
  Effective immediately, zero new device drivers, wire protocols, filesystems, or application-level services shall be committed into ``src/kernel/``. All future subsystem logic, drivers, and background tasks MUST be developed exclusively within ``src/userland/`` as isolated actor daemons communicating strictly via capability tokens over IPC ring buffers.

5. Authoritative Daemon Residency Truth
=======================================
To eliminate documentation ambiguity, the current implementation status of each major system daemon is defined as follows:

* **netd** (``src/userland/netd/netd.zig``):
  Currently provides a high-level userland actor interface, but core packet processing, VirtIO-Net 1.0 DMA rings, ARP/DHCP logic, and TCP/UDP/IPv4 network stacks (``src/kernel/net/``) reside entirely in Ring 0 as supervisor globals. Physical extraction of packet queues behind userland capability boundaries is targeted for Milestone 41.

* **storaged** (``src/userland/storaged/storaged.zig``):
  Defines the storage actor API, while physical NVMe 1.4 controller registers, VirtIO-Blk request rings, FAT32 partition mounting, and the BLAKE3 Content-Addressed Storage (CAS) engine (``src/kernel/storage/`` and ``src/kernel/drivers/``) operate as kernel-resident supervisor services.

* **gopd** (``src/userland/gopd/gopd.zig``):
  Represents the userland interface to the display subsystem. However, physical GOP framebuffer memory mapping, double-buffering, AABB dirty rectangle damage tracking, and window hierarchy management (``src/kernel/compositor/``) currently execute with supervisor privileges in Ring 0.

* **p2pd** (``src/userland/p2pd/p2p.zig`` & ``cas_sync.zig``):
  Executes as a modular actor service interacting with the kernel through the fail-closed capability ABI (``src/userland/p2pd/p2p_abi.zig``). It maintains cluster peer state and Merkle DAG synchronization, relying on kernel sockets for authenticated wire transit.

* **pkgd** (``src/userland/pkgd/package.zig``):
  Operates as an in-memory package resolver and dependency manager. It resolves content-addressed code manifests by querying verified BLAKE3 objects from storage through capability tokens.

* **aid** (``src/userland/aid/aid.zig``):
  Defines the autonomous AI assistant actor interface. The underlying TLS 1.3 client stream (``src/kernel/net/tls_stream.zig``) and Gemini REST API serialization (``src/kernel/ai/``) currently execute within the kernel substrate.

6. Long-Term Excision Roadmap (Milestone 41)
============================================
The ultimate transition to seL4-class microkernel minimality (< 2,000 LOC Ring 0) is scheduled across subsequent evolutionary milestones:

1. **Milestone 41.1 (Compositor Extraction)**: Relocate ``src/kernel/compositor/`` to ``gopd`` in Ring 3; grant ``gopd`` a restricted MMIO capability token mapping only the physical GOP video framebuffer.
2. **Milestone 41.2 (Storage & Filesystem Extraction)**: Transition ``storaged`` to an isolated userland actor; grant explicit PCI bus-mastering and DMA capability tokens for NVMe/VirtIO-Blk controllers.
3. **Milestone 41.3 (Network & AI Stack Extraction)**: Move network protocol state machines and AI clients entirely into ``netd`` and ``aid``; Ring 0 retains only raw network descriptor DMA and interrupt redirection.
