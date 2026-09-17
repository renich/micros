================================================================
MicrOS (µOS): Sovereign Systems Architecture & Genesis Blueprint
================================================================

:Author: Rénich Bon Ćirić & Antigravity
:Date: 2026-09-15
:Version: 0.2.0-draft
:Target: Self-Hosting Sovereign Operating System

Executive Summary
=================
**MicrOS (µOS)** is an operating system and software ecosystem engineered from first principles to achieve complete computational sovereignty. Taking its name from the pre-Socratic philosophical concept of *MicrOS* (ἄπειろん)—the boundless, ungenerated, and primordial substrate from which all ordered worlds emerge—this system rejects the accumulated historical bloat, ambient vulnerability models, and textual opacity of 50-year-old operating system stacks.

MicrOS (µOS) uses **Zig** as its foundational construction engine, bootstrapped from a minimal Fedora Linux launchpad. Crucially, the system is architected around a dual design imperative:

#. **An AI-Native Substrate**: The core operating system is tailored specifically to be maintained, profiled, and autonomously self-healed by an AI pair programmer through structured binary telemetry, bounded context-window modularity, and ephemeral memory cloning.
#. **A Human-Centric, Zero-Waste Upper Layer**: The application and desktop tier is intuitive, expressive, and human-friendly without sacrificing efficiency—completely eradicating multi-gigabyte browser/Electron runtimes in favor of declarative hypermedia and GPU vector shaders.

Architectural Axioms
====================

The Principle of MicrOS
------------------------
The foundational substrate of the machine must remain minimal, boundless in utility, and devoid of arbitrary runtime opinion. Mechanism is strictly isolated from policy. Hardware interaction and raw resource allocation belong to the lowest substrate; domain abstractions, business workflows, and human interaction belong to the expressive language layers built on top.

Separation of Mechanism and Policy
----------------------------------
The microkernel does not enforce desktop, filesystem, or networking policies. It provides four primitive mechanisms with mathematical rigor:

#. Address space isolation (4-level virtual memory paging).
#. Execution scheduling (preemptive threads and interrupt dispatch).
#. Capability-bounded inter-process communication (IPC message rings).
#. Hardware register and DMA access delegation.

All higher-level abstractions (filesystems, network protocols, user interfaces, shell environments) execute as isolated userspace services communicating over typed message rings.

AI-Native Introspection Over Text Logs
--------------------------------------
Unstructured ASCII text logs (such as ``dmesg`` or ``/var/log/messages``) are forbidden. An AI maintainer must not rely on probabilistic regex parsing to diagnose system failures. All subsystem states, crash reports, allocator profiles, and scheduler events are emitted as typed, schema-verified binary structures over lock-free memory rings.

Human Ergonomics Without Resource Waste
---------------------------------------
Human-friendly software does not require multi-gigabyte Chromium or Electron wrapper runtimes. The desktop and application tier provides declarative reactive state, instant sub-millisecond interaction, and rich typographical rendering while keeping application memory footprints strictly under 15 megabytes.

Hardware Staging and VirtIO Pragmatism
--------------------------------------
Writing an operating system does not require reverse-engineering thousands of proprietary consumer Wi-Fi chips and broken ACPI power tables on day one. MicrOS (µOS) stages hardware enablement deliberately:

* **Tier 1 (Virtualization Substrate)**: Full VirtIO implementation (``virtio-blk``, ``virtio-net``, ``virtio-console``, ``virtio-gpu``) running on QEMU/KVM and cloud hypervisors (Hetzner, Firecracker).
* **Tier 2 (Enterprise Bare Metal)**: Standardized server hardware using standard UEFI GOP framebuffers, AHCI/NVMe storage controllers, and Intel e1000/VirtIO NICs.
* **Tier 3 (Consumer Hardware)**: Expanded device support developed incrementally once the self-hosting toolchain is complete.

The AI-Native Maintenance Substrate
===================================

The Rule of 1,000 Lines (Context-Window Bounding)
-------------------------------------------------
Sprawling multi-file inheritance hierarchies and implicit global states degrade LLM reasoning and produce hallucination cascades.

* Every kernel subsystem, device driver, and system service must be fully self-contained within 500 to 1,000 lines of Zig.
* Every module receives its ``std.mem.Allocator`` and its ``CapabilityRing`` explicitly.
* An AI maintainer can ingest 100% of a subsystem's source code within a single context window, evaluate all failure paths deterministically, and refactor the module without spooky action at a distance.

Binary Structural Telemetry
---------------------------
When a subsystem fails or encounters memory pressure, it does not print human-readable text. It emits an unforgeable binary fault token:

.. code-block:: zig

   pub const FaultReport = extern struct {
       subsystem_id: u16,
       fault_type: enum(u16) {
           PageFault = 1,
           RingOverflow = 2,
           AllocationFailure = 3,
           DeadlockRisk = 4,
       },
       instruction_pointer: u64,
       allocated_bytes: usize,
       callstack: [16]u64,
   };

The AI supervisor ingests exact machine state directly from the ring, identifying the faulting invariant without guessing.

Ephemeral Live-Cloning & Self-Healing Fuzzing
---------------------------------------------
To safely patch a running operating system without human intervention or physical reboots:

#. The AI maintainer requests a domain clone via the kernel capability ring.
#. The kernel leverages its Copy-on-Write memory tables to create an ephemeral, lightweight snapshot of the running OS in RAM in under 2 milliseconds.
#. The AI applies its proposed patch inside the ephemeral clone and runs 10,000 automated stress cycles against simulated I/O.
#. If the patch page-faults or leaks memory, the ephemeral domain evaporates, and the structured crash report is fed back into the AI context.
#. Only when the patch passes all invariant gates is the root kernel pointer atomically swapped in production RAM.

The Compiler as an Automated Theorem Prover
-------------------------------------------
Zig's zero-hidden-control-flow semantics and absence of operator overloading guarantee that the AST matches operational machine behavior. Compiler diagnostics provide structured error tokens (unaligned pointers, missing enum branches, unhandled error sets) that act as an automated theorem prover, driving deterministic AI code convergence.

Phase 0: Userspace Sandbox on Fedora Launchpad
==============================================
Before executing on raw silicon or virtualization firmware, all core algorithms, data structures, and serialization protocols are implemented and verified inside a zero-dependency Linux userspace harness.

Direct-Syscall Harness
----------------------
The system initializes without linking to host dynamic libraries:

* Entry point defined directly at ``_start`` in Zig.
* System calls dispatched via ``std.os.linux`` (avoiding ``libc`` wrappers).
* Custom process bootstrap: parsing ELF auxiliary vectors (``AT_PHDR``, ``AT_PAGESZ``), setting up thread-local storage (TLS), and initializing initial memory arenas via direct ``mmap/munmap``.

Core Systems Primitives
-----------------------
Phase 0 delivers three foundational userspace binaries:

#. **MicrOS Init (PID 1)**: Minimal process supervisor handling signal disposition (``SIGCHLD``), reaping orphaned child processes, and mounting ``/dev``, ``/proc``, and ``/sys``.
#. **MicroShell (msh/ush)**: Composable typed command interpreter and Macros scripting frontend supporting pipeline execution over memory rings, file descriptor/capability redirection, and job control with zero external library linkages.
#. **MicrOS Coreutils**: Essential POSIX-compliant binary primitives (``ls``, ``cat``, ``cp``, ``mv``, ``mkdir``, ``ps``, ``kill``) built strictly on direct syscall abstractions and explicit memory allocators.

Verification Milestone
^^^^^^^^^^^^^^^^^^^^^^
The entire userspace is packaged into an initramfs CPIO archive and booted directly against the Fedora host kernel inside a headless QEMU instance:

.. code-block:: bash

   qemu-system-x86_64 -enable-kvm -m 1G \
      -kernel /boot/vmlinuz-$(uname -r) \
      -initrd rootfs.cpio \
      -append "console=ttyS0 init=/bin/init" \
      -nographic

Phase 1: The Bare-Metal Substrate (UEFI & Microkernel)
======================================================
With the userspace primitives validated, MicrOS severs its dependence on the Linux host kernel and boots directly from hardware firmware.

UEFI Stage 1 Bootloader
-----------------------
Compiled using Zig's native target: ``-target x86_64-uefi``:

* Executes as a native PE32+ UEFI application (``boot.efi``) on the EFI System Partition (ESP).
* Interrogates firmware for system memory descriptors via ``GetMemoryMap()``.
* Acquires display framebuffer geometry via UEFI Graphics Output Protocol (GOP).
* Locates the MicrOS microkernel ELF image on disk, loads program segments into higher-half virtual memory, and invokes ``ExitBootServices()``.
* Transitions CPU state from UEFI runtime into the 64-bit Long Mode kernel entry point, passing a serialized boot information structure.

Physical & Virtual Memory Architecture
--------------------------------------
The memory subsystem establishes deterministic spatial control:

* **PMM (Physical Memory Manager)**: Bitmap allocator managing 4 KiB physical page frames across all memory regions reported by UEFI.
* **VMM (Virtual Memory Manager)**: 4-level paging (PML4 -> PDPT -> PD -> PT) supporting 4 KiB pages and 2 MiB huge pages.
* **Higher-Half Direct Map (HHDM)**: Maps all physical memory to an offset in the upper canonical address space (``0xFFFF_8000_0000_0000``), allowing zero-copy translation between physical page frames and virtual pointers.
* **Kernel Heap**: Bounded kernel heap backed by a Buddy Allocator for power-of-two page orders, coupled with a Slab/SMR allocator for fast object allocation (process descriptors, thread control blocks, page tables).

Interrupts, Timers, and Preemptive Scheduler
--------------------------------------------
The execution engine implements preemptive multiprocessing:

* **GDT & TSS**: Global Descriptor Table configuring 64-bit kernel and user code/data segments, alongside a Task State Segment (TSS) defining the Interrupt Stack Table (IST) for double-fault isolation.
* **IDT & Exceptions**: Complete Interrupt Descriptor Table mapping CPU traps (``#PF``, ``#GP``, ``#DF``, ``#UD``) to diagnostic register dumps.
* **APIC & HPET**: Local APIC and High Precision Event Timer initialization, calibrating APIC timer ticks via CPU TSC (Time Stamp Counter).
* **Preemptive Scheduler**: Round-robin scheduler with priority queues. Context switching implemented in minimal x86_64 inline assembly, saving and restoring caller/callee-saved registers, CR3 page directory bases, and SSE/AVX registers via ``FXSAVE64/XSAVE``.

VirtIO Device Abstractions
--------------------------
To ensure immediate portability under virtualization (QEMU/KVM), drivers target modern VirtIO 1.0 specifications over PCI:

* **virtio-console**: Emergency and interactive serial console over memory-mapped I/O rings.
* **virtio-blk**: High-performance asynchronous disk operations via split virtqueues.
* **virtio-net**: Raw Ethernet packet transmission and reception with zero-copy descriptor chains.

Phase 2: The Language & Runtime Factory
=======================================
MicrOS does not write complex application layers in bare-metal systems code. It constructs a dedicated language and runtime engine that bridges machine control with high-level expressiveness.

The Intermediate Language: Macros
------------------------------------
A statically typed, expression-oriented language combining the type-inference and clean syntax of Crystal with the concurrency model of Go:

* **Lexer & Parser**: Written in Zig using tagged unions for algebraic AST representation, backed by a scoped arena allocator that discards memory at pass boundaries.
* **Type System**: Bidirectional local type inference, structural pattern matching, algebraic data types (enums with payloads), and consumer-side interfaces.
* **Safety Rules**: Null safety by default, explicit error handling via Result types (no unhandled exceptions), and affine lifecycle semantics.

The Runtime Engine: Generational Immix & M:N Scheduler
------------------------------------------------------
The language runtime is written in Zig and linked into every compiled application:

* **Memory Management**: An Immix mark-region garbage collector. Combines fast bump-pointer allocation with mark-region collection, eliminating heap fragmentation without the space overhead of traditional copying collectors. Unmapped memory pages are returned directly to the kernel in real time.
* **M:N Green Thread Scheduler**: Userspace cooperative fibers scheduled across a pool of kernel threads. Fiber context switches execute in userspace in under 15 nanoseconds.
* **Asynchronous I/O Rings**: Fiber suspension and resumption integrated natively with kernel completion rings, ensuring non-blocking operations for disk and network I/O.

Self-Hosted Machine Code Emission
---------------------------------
To eliminate LLVM runtime dependencies:

* Phase 2.1: Macros compiles down to clean, formatted Zig source code, leveraging the Zig compiler as an optimizing backend.
* Phase 2.2: Macros implements direct machine-code emission for x86_64, aarch64, and WebAssembly using Zig's internal code-generation primitives.

Phase 3: Storage, Network, and Reactive Vector Compositor
=========================================================

CoW B-Tree Storage Subsystem
----------------------------
A modern, crash-resilient filesystem operating over ``virtio-blk`` and NVMe devices:

* **Copy-on-Write (CoW)**: Modified blocks are written to newly allocated physical extents, guaranteeing atomic transactions and instant snapshots.
* **B-Tree Indexing**: Directories and file extents indexed via self-balancing B+ trees.
* **Integrity Hashing**: Every data and metadata block includes a BLAKE3 checksum, detecting silent bitrot and hardware corruption during read operations.

Zero-Copy Network Stack (TCP/IP/QUIC)
-------------------------------------
A pure Zig network stack operating directly on VirtIO ring buffers:

* Layer 2: Ethernet frame framing, ARP cache resolution.
* Layer 3: IPv4 and IPv6 packet parsing and route lookup.
* Layer 4: High-throughput TCP with sliding window flow control, alongside UDP.
* Layer 7 & Transport Security: Embedded TLS 1.3 implementation utilizing modern cryptographic primitives (ChaCha20-Poly1305, X25519, Ed25519).

Reactive Vector Compositor (Zero-Waste UI)
------------------------------------------
A lightweight graphical display server operating on UEFI GOP or VirtIO-GPU:

* **Declarative Hypermedia Protocol**: Applications do not package layout or rendering engines. They stream declarative UI trees (component structures, reactive signals, and event bindings) to the compositor over shared-memory IPC rings.
* **GPU Vector Shaders**: The compositor renders vector geometry, typography, and controls directly on the GPU using Signed Distance Field (SDF) shaders at native monitor refresh rates (144Hz+).
* **Resource Ceiling**: Full-featured desktop applications consume between 8 and 12 megabytes of RAM, completely eliminating web browser engine overhead.

Phase 4: Sovereign Cord-Cutting & Bare-Metal Staging
====================================================
The definitive milestone of MicrOS (µOS): severing all developmental ties to Fedora and Linux.

The Self-Hosting Loop
---------------------
#. Port the self-hosted Zig compiler into the MicrOS userspace.
#. Compile MicrOS's kernel, system services, and Macros toolchain using the ported Zig compiler running natively on MicrOS (µOS).
#. Compare the self-compiled binary outputs against the cross-compiled Fedora artifacts (Bit-for-Bit Reproducible Build Verification).

Bare-Metal Deployment Target
----------------------------
The verified system image is written directly to physical block storage:

.. code-block:: bash

   # Packaging sovereign GPT disk image on Fedora
   systemd-repart --dry-run=no --definitions=repart.d/ micros.raw
   dd if=micros.raw of=/dev/sdX bs=4M status=progress conv=fsync

The machine boots on physical bare-metal hardware (x86_64 UEFI PC/workstation). The system updates, recompiles, and expands its own operating environment from within itself.

Human-AI Symbiosis: Division of Operational Labor
=================================================
MicrOS (µOS) is deliberately structured around the complementary strengths of human architects and AI engineering systems:

.. table:: Human-AI Operational Division of Labor
   :widths: auto

   +--------------------------+----------------------------------------------------+---------------------------------------------------+
   | Dimension                | Human Role (Architect/Operator)                    | AI Role (Maintainer/Engineer)                     |
   +==========================+====================================================+===================================================+
   | Architectural Policy     | Defines domain invariants, goals, and interfaces   | Enforces structural contracts and modular bounds  |
   +--------------------------+----------------------------------------------------+---------------------------------------------------+
   | Codebase Maintenance     | Strategic direction, code review, pair programming | Continuous refactoring, fuzzing, static analysis  |
   +--------------------------+----------------------------------------------------+---------------------------------------------------+
   | Fault Remediation        | Decides operational tradeoffs upon fatal failures  | Ingests binary telemetry, live-clones, patches UB |
   +--------------------------+----------------------------------------------------+---------------------------------------------------+
   | Application Authoring    | Authors expressive Macros business logic & UIs     | Optimizes low-level Zig primitives and ring alloc |
   +--------------------------+----------------------------------------------------+---------------------------------------------------+

Verification Matrix & Automated CI Harness
==========================================

QEMU/KVM Headless Test Harness
------------------------------
Every phase is continuously tested on the Fedora launchpad via automated script harnesses:

.. code-block:: bash

   #!/usr/bin/bash
   set -euo pipefail

   # Headless execution with exit code capture via QEMU ISA debug-exit device
   qemu-system-x86_64 \
      -enable-kvm \
      -m 2G \
      -bios /usr/share/edk2/ovmf/OVMF_CODE.fd \
      -drive format=raw,file=fat:rw:build/esp \
      -device isa-debug-exit,iobase=0xf4,iosize=0x04 \
      -serial stdio \
      -display none

Traceability and Milestones
---------------------------
The implementation track is governed by four gated milestone reviews:

.. table:: Genesis Milestone Verification Matrix
   :widths: auto

   +-----------+----------------------+-----------------------------------------------+-----------------------------------------+
   | Milestone | Subsystem Focus      | Primary Artifact                              | Verification Gate                       |
   +===========+======================+===============================================+=========================================+
   | M0        | Host Sandbox         | Direct-syscall ``init``, ``msh``, coreutils   | Boots under host kernel in QEMU         |
   +-----------+----------------------+-----------------------------------------------+-----------------------------------------+
   | M1        | Microkernel & Memory | ``boot.efi``, PMM, VMM, Scheduler, VirtIO-Con | Boots via UEFI; preemptive multitasking |
   +-----------+----------------------+-----------------------------------------------+-----------------------------------------+
   | M2        | Language & Runtime   | Macros compiler, Immix GC, Green Threads      | Self-compiled HTTP/TUI binary executes  |
   +-----------+----------------------+-----------------------------------------------+-----------------------------------------+
   | M3        | Full Sovereignty     | Native CoW FS, TCP/IP, Self-Hosting Rebuild   | System compiles itself on bare metal    |
   +-----------+----------------------+-----------------------------------------------+-----------------------------------------+
