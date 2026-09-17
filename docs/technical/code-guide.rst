=================================
Understanding the MicrOS Codebase
=================================

:Status: Approved
:Version: 2.0.0
:Author: Rénich Bon Ćirić & Antigravity
:Date: 2026-09-17
:Language: English (US)
:Translations: :doc:`code-guide-es`

This document is the comprehensive architectural and structural guide to the MicrOS (µOS) codebase. It provides human systems architects and autonomous AI agents with the foundational mental model, entry point pathways, subsystem interactions, and navigation maps needed to explore, comprehend, and extend the system.

Core Architectural Philosophy & Mental Model
============================================
MicrOS is an independent, computationally sovereign, post-POSIX operating system built from bare silicon in pure Zig and the Macros programming language. Its fundamental mission is to eliminate fifty years of accumulated operating system bloat and provide a secure, deterministic substrate designed specifically for native human-AI pair programming.

The Two Computational Worlds:
-----------------------------
The codebase is cleanly bifurcated into two cooperating layers:

1. **Tier 0: Substrate & Sovereign Microkernel (Zig)**:
   Residing in ``src/sys/`` and ``src/kernel/``, Tier 0 is written in freestanding Zig without any external C standard library (zero libc). It interacts directly with x86_64 hardware structures and devices. Tier 0 manages the Global Descriptor Table (GDT), Interrupt Descriptor Table (IDT), physical page frames (PMM), 4-level virtual memory paging (VMM), VirtIO network and block storage drivers, Capability Space (CSpace) security tokens, lockless shared-memory ring buffers, and the Immix mark-region bytecode virtual machine.

2. **Tier 1: Sovereign Userland Applications (Macros)**:
   Residing in ``lib/macros/`` and written in the Macros language (``.mx``, ``.macros``), Tier 1 embodies the system personality. It contains the system supervisor (``init.mx``), the interactive MicroShell (``msh.mx``), autonomous execution harnesses, and self-hosting compiler pipelines. Tier 1 programs execute as isolated actors scheduled on cooperative green-thread fibers and communicate via typed shared-memory ring buffers and explicit CSpace capability tokens.

Eliminating Legacy POSIX Baggage:
---------------------------------
To achieve mathematical determinism and fault containment, MicrOS explicitly discards four foundational POSIX abstractions:

* **No Ambient Authority**: There is no superuser (``root``) and no global ambient permission model. Processes cannot access resources simply because they exist; every operation requires presenting a cryptographically or kernel-validated capability token from the actor's local CSpace.
* **No Mutable Hierarchical Filesystems**: Hierarchical directory trees and mutable file inodes are replaced by 256-bit BLAKE3 Content-Addressed Storage (CAS). Modules, bytecode chunks, and system state manifests are immutable objects addressed by cryptographic digest.
* **No Untyped ASCII Pipes**: Inter-process communication does not serialize data into raw byte streams. Processes communicate over structured, typed shared-memory ring buffers with strict binary layouts.
* **No C Runtime Dependencies**: Neither glibc, musl, nor any external runtime is linked into the kernel substrate. All low-level interactions occur through direct inline assembly or bare-metal Linux syscall wrappers.

Dual Execution Environments (UEFI vs Sandbox):
----------------------------------------------
The codebase is architected to compile and run across two complementary execution targets:

* **Bare-Metal x86_64 UEFI (Production/Emulation Target)**:
   The primary operating environment. Boots via UEFI firmware (OVMF in QEMU or real hardware) through ``src/boot/uefi_main.zig``. The microkernel directly initializes CPU tables, memory paging, PCI devices, VirtIO storage and networking, mounts CAS, initializes the double-buffered 1280x800 GOP vector canvas, and launches the Genesis application bundle inside cooperative fibers.

* **Linux Direct-Syscall Sandbox (Fast TDD/CI Target)**:
   For rapid development and continuous integration, ``src/main.zig`` compiles into a freestanding binary (``zig-out/bin/micros-init``) that acts as PID 1 inside an isolated Linux sandbox or container. It communicates with the host Linux kernel via raw syscalls in ``src/sys/linux.zig``, executes substrate self-tests, runs MicroShell commands, and triggers clean ACPI S5 poweroff in milliseconds.

System Entry Points & Boot Sequence
===================================
Tracing control flow from initial hardware power-on through userland shell interaction reveals how the various subsystems are assembled.

1. Bare-Metal UEFI Bootloader (src/boot/uefi_main.zig):
-------------------------------------------------------
Control originates in ``pub fn main() uefi.Status`` within ``boot.efi``:

* **Firmware Handshake**: Connects to the UEFI System Table and initializes serial/console output.
* **Framebuffer Discovery**: Locates the UEFI Graphics Output Protocol (GOP), capturing base address, screen geometry (1280x800), scanline stride, and color format into ``FramebufferInfo``.
* **Memory Map Acquisition**: Queries the UEFI memory map into a contiguous buffer of ``MemoryDescriptor`` entries, classifying usable RAM, bootloader data, and reserved memory.
* **BootInfo Packaging**: Assembles physical memory boundaries, Higher Half Direct Map (HHDM) offsets, and framebuffer metadata into a verified ``BootInfo`` struct with magic signature ``0x4D494352_4F534B45``.
* **Kernel Transition**: Passes control directly to the microkernel entry point: ``kernel_main.kmain(&global_boot_info)``.

2. Sovereign Microkernel Root (src/kernel/main.zig):
----------------------------------------------------
Execution enters the microkernel at ``pub export fn kmain(boot_info: *const BootInfo) callconv(.c) noreturn``:

* **CPU Fault Containment**: Disables interrupts (``cli``), initializes 16550 UART serial logging, and loads the Global Descriptor Table (``gdt.init()``) and Interrupt Descriptor Table (``idt.init()``).
* **Memory Initialization**: Configures the Physical Memory Manager bitmap (``pmm.init()``) and sets up 4-level virtual memory page tables (``vmm.init()``).
* **Driver Probing**: Scans the PCI bus and attaches VirtIO-Net 1.0 (network) and VirtIO-Blk 1.0 (storage).
* **Kernel Heap & CSpace**: Sets up an 8 MiB page-aligned kernel heap, instantiates Genesis Actor 0, and configures the root Capability Space (CSpace) with 64 slots.
* **CAS & Display Setup**: Mounts the Content-Addressed Storage engine and initializes the 1280x800 GOP double-buffered vector canvas and window manager.
* **Genesis Bundle Unpacking**: Accesses the embedded ``genesis.mcb`` archive, extracts ``init.mx``, compiles it to bytecode via the Stage 0 compiler, and initializes the Genesis VM.
* **ABI Registration**: Injects kernel ABI functions (``sys_actor_spawn_code``, ``sys_bundle_read``, ``sys_yield``, ``sys_actor_state``) into the VM global scope.
* **Fiber Scheduler Launch**: Initializes the cooperative green-thread scheduler (``fiber_mod.Scheduler``), spawns ``vmThread``, and enters the scheduling loop ``sched.run()``.

3. High-Level Init Supervisor (lib/macros/init.mx):
---------------------------------------------------
The first userland code executed inside the Genesis VM runs as Actor 0 (PID 1):

* **App 0 Deployment**: Reads ``msh.mx`` from the Genesis bundle via ``sys_bundle_read("msh.mx")``.
* **Actor Spawning**: Spawns the MicroShell child actor via ``sys_actor_spawn_code("msh", msh_src)``.
* **Supervision Loop**: Enters ``supervisor_loop``, polling child actor states (``sys_actor_state``), automatically respawning faulted actors, and cooperatively yielding CPU cycles via ``sys_yield()``.

4. Linux Direct-Syscall Sandbox (src/main.zig):
-----------------------------------------------
When running in sandbox mode, execution begins at ``pub fn main() !void``:

* **Direct Syscall Banner**: Emits early boot diagnostics directly to file descriptor 1 via ``src/sys/io.zig``.
* **Substrate Verification**: Runs a self-test by parsing, compiling, and running ``boot_check = 20 + 22`` in an isolated Macros VM, validating that the result equals 42.
* **MicroShell Execution**: Initializes ``msh.Shell`` attached to standard input/output descriptors.
* **Clean Shutdown**: Calls ``sys.process.poweroff()`` to trigger an ACPI S5 shutdown via raw reboot syscall magic (``0x4321fedc``).

5. Standalone Host Runners:
---------------------------
* ``src/macros_main.zig``: Host CLI utility to compile and execute standalone ``.mx`` files directly.
* ``src/msh_main.zig``: Host interactive CLI providing the MicroShell REPL for terminal testing.

Repository Anatomy: What Is Where
=================================
The repository is strictly partitioned into distinct functional layers:

Substrate & Microkernel (src/):
-------------------------------
The core engine written in freestanding Zig:

* ``src/boot/``: UEFI Stage 1 bootloader implementation (``uefi_main.zig``) and memory handoff protocol.
* ``src/kernel/``: Sovereign microkernel implementation:
   * ``arch/x86_64/``: Assembly context switching, GDT, IDT, port I/O, control register definitions.
   * ``mem/``: Physical page frame allocator (``pmm.zig``) and Virtual Memory Manager (``vmm.zig``).
   * ``drivers/``: VirtIO-Net 1.0, VirtIO-Blk 1.0, PCIe NVMe 1.4 storage controller, GUID Partition Table (GPT), PCI enumeration, and PS/2 keyboard drivers.
   * ``cap/``: Capability-based access control engine (``capability.zig``, ``cspace.zig``).
   * ``storage/``: Content-Addressed Storage engine (``cas.zig``), block cache (``block_cache.zig``), chunking (``chunk.zig``), and FAT32 ESP filesystem driver (``fat32.zig``).
   * ``ipc/``: Lockless ring buffers (``ring.zig``) and typed event channels (``events.zig``).
   * ``compositor/``: Vector graphics engine, 1280x800 canvas, font rendering, mouse cursor, and BSP tiling window manager.
   * ``net/``: In-kernel network stack (DHCP client, DNS resolver, TCP state machine, TLS 1.3 adapter).
   * ``ai.zig``: Resident AI subsystem managing streaming HTTP 1.1 sessions with Gemini/Local AI providers.
   * ``actor.zig`` & ``supervisor.zig``: Actor lifecycle management and supervision hierarchies.
   * ``abi.zig``: Microkernel ABI bindings exposed to the Macros VM.
   * ``main.zig``: Microkernel root entry point (``kmain``).
* ``src/sys/``: Freestanding Linux syscall and hardware abstraction library (``linux.zig``, ``io.zig``, ``mem.zig``, ``process.zig``, ``hal.zig``).
* ``src/msh/``: Host MicroShell implementation (``shell.zig`` with built-in commands).

Language Engine & Runtime (src/macros/):
----------------------------------------
The Stage 0 Macros implementation in Zig:

* ``lexer.zig``: Scans UTF-8 source streams into strongly typed token sequences.
* ``parser.zig`` & ``ast.zig``: Generates and validates recursive-descent Abstract Syntax Trees.
* ``compiler.zig`` & ``chunk.zig``: Compiles AST nodes into serialized bytecode chunks.
* ``vm.zig``: Stack-based virtual machine executing bytecode instructions.
* ``eval.zig``: Tree-walk interpreter used during early bootstrap stages.
* ``gc.zig`` & ``immix.zig``: Immix mark-region garbage collector (32 KiB blocks, line mark bitmaps, recyclable hole allocation).
* ``fiber.zig`` & ``context_switch.s``: Userspace cooperative green threads and assembly context switching.
* ``codegen_x86_64.zig``: Direct machine code generator with W^X page protection.
* ``module.zig`` & ``serializer.zig``: Content-addressed module resolver (``b3:...`` and ``bundle:...``) and canonical serialization.

Self-Hosting Applications (lib/macros/):
----------------------------------------
The Stage 1 Macros implementation written entirely in pure Macros:

* ``init.mx``: System supervisor and Actor 0 root init script.
* ``msh.mx``: Sovereign MicroShell implementation written in pure Macros.
* ``harness.mx``: Autonomous test runner and verification suite.
* ``ast.mx``, ``lexer.mx``, ``parser.mx``: Self-hosting compiler frontend.
* ``compiler.mx``, ``compiler_main.mx``: Self-hosting bytecode compiler emitting runnable chunks.

Verification & Build Toolchain (tools/):
----------------------------------------
Host verification utilities ensuring system correctness:

* ``tools/micros-runner`` (``tools/micros-runner.bash``): Headless event-driven QEMU test harness with serial sentinel detection.
* ``tools/src/fb_verify.zig`` (``tools/bin/micros-fb-verify``): Sub-millisecond framebuffer pixel variance validator.
* ``tools/src/lint.zig`` (``tools/bin/micros-lint``): Native Zig AST linter enforcing code quality metrics.
* ``tools/src/sym.zig`` (``tools/bin/micros-sym``): Freestanding 64-bit ELF symbol unwinder and address-to-line resolver.
* ``tools/micros-inspect`` (``tools/micros-inspect.bash``): QEMU monitor socket CPU state and register disassembler.
* ``tools/src/telem.zig`` (``tools/bin/micros-telem``): Native 64-byte binary telemetry stream decoder.
* ``tools/micros-spec-trace`` (``tools/micros-spec-trace.bash``): Bidirectional specification traceability auditor across all four specification tiers.
* ``tools/src/virtio_bench.zig`` (``tools/bin/micros-virtio-bench``): VirtIO split-virtqueue validator and RDTSC DMA micro-benchmarker.
* ``tools/src/bundle.zig`` (``tools/bin/micros-bundle``): Packs Stage 1 ``.mx`` source files into the binary ``genesis.mcb`` archive.

Subsystem Deep Dives: How Moving Parts Interact
===============================================
To modify or debug MicrOS effectively, one must understand the key coordination mechanisms connecting the substrate to the userland.

The Zig-to-Macros ABI Bridge:
-----------------------------
The microkernel exposes hardware capabilities to Macros through ``src/kernel/abi.zig``. The VM maintains a global environment table where native Zig functions are registered as callable values:

.. code-block:: zig

   // Example ABI Registration in src/kernel/abi.zig
   pub fn registerSyscalls(vm: *VM) !void {
       try vm.globals.put("sys_actor_spawn_code", Value{ .native = nativeSysActorSpawnCode });
       try vm.globals.put("sys_bundle_read", Value{ .native = nativeSysBundleRead });
       try vm.globals.put("sys_yield", Value{ .native = nativeSysYield });
       try vm.globals.put("sys_actor_state", Value{ .native = nativeSysActorState });
       try vm.globals.put("sys_window_create", Value{ .native = nativeSysWindowCreate });
   }

When a Macros script executes ``sys_bundle_read("msh.mx")``, the VM pauses interpreted bytecode, marshals arguments from the VM operand stack, invokes the native Zig function, and pushes the resulting ``eval.Value`` back onto the stack without memory leakage.

Memory Architecture & Immix Mark-Region GC:
-------------------------------------------
Memory management operates across two cooperating levels:

1. **Hardware Page Level (PMM/VMM)**:
   The physical memory manager (``pmm.zig``) manages physical 4096-byte page frames via a bitmap. The virtual memory manager (``vmm.zig``) builds 4-level page tables (PML4, PDPT, PD, PT) mapping physical RAM to the Higher Half Direct Map (HHDM).
2. **Object Level (Immix Mark-Region GC)**:
   The Macros runtime uses an Immix mark-region collector (``src/macros/gc.zig``). It allocates heap space in 32 KiB blocks partitioned into 128 lines of 256 bytes. Small objects are allocated rapidly using bump pointers into recyclable free line holes, eliminating external fragmentation. Large objects (>= 4096 bytes) are mapped directly to dedicated virtual pages.

Cooperative Green-Thread Fibers:
--------------------------------
MicrOS rejects preemptive kernel threads for application orchestration, relying instead on lightweight userspace fibers (``src/macros/fiber.zig``):

* **Fiber Structure**: Each fiber is provisioned with an isolated 512 KiB page-aligned stack (``STACK_SIZE = 512 * 1024``) to accommodate TLS 1.3 cryptographic state and nested execution.
* **Context Switching**: The assembly routines in ``src/macros/context_switch.s`` save callee-saved registers onto the stack, swap ``rsp``, and restore destination registers: System V AMD64 ABI (``switchContextSysV``, 6 registers: ``rbx``, ``rbp``, ``r12``, ``r13``, ``r14``, ``r15``) for Linux sandbox mode, and Microsoft x64 ABI (``switchContextWin64``, 8 registers: ``rbp``, ``rbx``, ``rdi``, ``rsi``, ``r12``, ``r13``, ``r14``, ``r15``) for bare-metal UEFI mode.
* **Non-Preemptive Scheduling**: Fibers yield CPU time cooperatively via ``yield()`` or when awaiting I/O events, eliminating kernel locking overhead.

Content-Addressed Storage Substrate (CAS):
------------------------------------------
MicrOS stores all persistent data using content addressing (``src/kernel/storage/cas.zig``):

* **BLAKE3 Addressing**: Every data chunk is addressed by its 256-bit BLAKE3 hash (``b3:<hex>``).
* **VirtIO-Blk Backend**: Underlying disk transfers operate on 512-byte sectors with an LRU block cache.
* **System Manifests**: Instead of a mutable file allocation table, system state is represented by root manifests referencing tree-structured content hashes. Superblocks advance monotonically upon verified flushes.

Capability-Based Security (CSpace):
-----------------------------------
Every actor in MicrOS operates inside a restricted sandbox governed by its Capability Space (``src/kernel/cap/cspace.zig``):

* **Capability Tokens**: Represent unforgeable tokens granting specific rights (read, write, spawn, send, map) over kernel objects (framebuffer, IPC ring, bundle storage, network sockets).
* **Zero Ambient Authority**: If an actor attempts to draw to the screen or send an IPC message without referencing a valid capability slot, the microkernel faults the actor immediately.

Reactive Vector Compositor & Window Manager:
--------------------------------------------
The visual interface (``src/kernel/compositor.zig``) operates directly on the UEFI GOP framebuffer:

* **Double-Buffering**: Renders into a 1280x800x32 backbuffer and blits dirty rectangles to the frontbuffer, eliminating screen tearing.
* **BSP Tiling Window Manager**: Windows are organized in a Binary Space Partitioning tree, automatically tiling visible actor surfaces.
* **Event Dispatch**: PS/2 keyboard packets and mouse motion events are routed to the focused actor surface over its IPC event queue.

The Genesis Bundle & Self-Hosting Pipeline
==========================================
MicrOS is designed to compile itself, establishing computational independence from external toolchains.

Build-Time Packaging Flow:
--------------------------
1. **Compilation of Tools**: Host utilities (including ``micros-bundle``) are compiled via ``make tools``.
2. **Bundle Serialization**: ``tools/micros-bundle`` reads Stage 1 source files from ``lib/macros/`` (``init.mx``, ``msh.mx``, ``harness.mx``, ``lexer.mx``, ``parser.mx``, ``compiler.mx``, ``compiler_main.mx``) and serializes them into ``src/kernel/genesis.mcb``.
3. **Kernel Ingestion**: The kernel source (``src/kernel/main.zig``) embeds this binary archive using ``@embedFile("genesis.mcb")``. When the microkernel boots on bare silicon, all essential userland source code is already present in memory without requiring a functional disk driver.

Fixed-Point Bootstrap Verification:
-----------------------------------
The self-hosting pipeline operates across three stages:

* **Stage 0**: Freestanding Zig engine in ``src/macros/`` evaluates the Stage 1 compiler scripts.
* **Stage 1**: Pure Macros compiler in ``lib/macros/compiler.mx`` parses Macros source and emits bytecode chunks.
* **Stage 2**: The emitted bytecode compiler is executed to compile itself again, verifying bit-for-bit identical BLAKE3 hashes (fixed point) to prove compiler determinism.

Developer Walkthrough: Navigating & Extending
=============================================
When contributing to MicrOS, consult the following procedural paths for common development workflows:

Adding a New Microkernel Syscall or Capability:
-----------------------------------------------
#. **Define the ABI Prototype**: In ``src/kernel/abi.zig``, implement the native Zig handler (e.g., ``nativeMyFeature``), unpacking arguments from ``args: []eval.Value``.
#. **Register in Syscalls**: Add the mapping inside ``registerSyscalls`` in ``src/kernel/abi.zig``:
   ``try vm.globals.put("sys_my_feature", Value{ .native = nativeSysMyFeature });``
#. **Implement Kernel Logic**: If accessing a hardware driver or memory subsystem, invoke the appropriate domain module in ``src/kernel/``, validating the calling actor's CSpace capability.
#. **Expose to Userland**: Call the new primitive in ``lib/macros/init.mx`` or ``lib/macros/msh.mx``.

Adding a New Primitive or Opcode to Macros:
-------------------------------------------
#. **Opcode Definition**: Add the new opcode tag to ``OpCode`` enum in ``src/macros/chunk.zig``.
#. **Frontend Scanning & Parsing**: Update ``src/macros/lexer.zig`` (if introducing keywords/symbols) and ``src/macros/parser.zig`` to produce an AST node.
#. **Compiler Emission**: In ``src/macros/compiler.zig``, emit the new bytecode instruction and operands into the current chunk.
#. **VM Execution**: In ``src/macros/vm.zig``, add a ``case`` branch in the main execution loop to handle the opcode.
#. **Self-Hosting Mirror**: Mirror the syntax and code generation changes in ``lib/macros/lexer.mx``, ``parser.mx``, and ``compiler.mx``.

Debugging a Crash or Kernel Panic:
----------------------------------
#. **Serial Console Capture**: Inspect serial logs written by the kernel (captured automatically by ``tools/micros-runner.bash --serial-log build/serial.log``).
#. **Symbol Resolution**: Run hexadecimal instruction pointers through ``./tools/micros-sym <address>`` to obtain function names and line offsets.
#. **Monitor Register Inspection**: If QEMU hangs, execute ``./tools/micros-inspect`` to connect to the monitor socket and dump CPU registers (RAX, CR3, RIP) and disassembly.
#. **Telemetry Frame Decoding**: If telemetry rings are active, inspect decoded frames with ``./tools/micros-telem -f /tmp/telemetry.bin``.

Executing the Verification Suite:
---------------------------------
Before submitting changes, run the mandatory verification sequence:

.. code-block:: bash

   # 1. Compile host verification tools
   make tools

   # 2. Run static code analyzer and ShellCheck
   make lint

   # 3. Check source formatting
   make fmt-check

   # 4. Audit specification traceability
   make spec-trace

   # 5. Run full unit test suite
   zig build test

   # 6. Execute headless bare-metal boot in QEMU (or 'make qemu-uefi' for interactive)
   ./tools/micros-runner --mode uefi

   # 7. Execute direct-syscall sandbox test
   make test-sandbox
