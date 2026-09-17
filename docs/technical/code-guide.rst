=============================
MicrOS Engineering Code Guide
=============================

:Status: Approved
:Version: 1.1.0
:Author: Rénich Bon Ćirić & Antigravity
:Date: 2026-09-17
:Language: English (US)
:Translations: :doc:`code-guide-es`

This document defines the authoritative architectural mental model, codebase layout, entry points, lifecycle pipelines, and code quality standards for the MicrOS (µOS) operating system, the Macros programming language runtime, and host verification tooling. Every engineer, human architect, and autonomous AI agent modifying this codebase MUST comply with these rules without exception.

Computational Sovereignty & Core Philosophy
===========================================
MicrOS is engineered to guarantee absolute technological sovereignty, zero external runtime dependency lock-in, and full determinism across the hardware/software boundary.

Core Philosophical Directives:
------------------------------
* **Zero-Libc Substrate**: The substrate layer (``src/sys/``) and kernel (``src/kernel/``) link zero external C runtime libraries (``libc``, ``musl``, or ``glibc``). All kernel/userspace interactions invoke raw Linux x86_64 syscalls or native assembly.
* **The Verification Doctrine**: Never assume; always verify. Zero probabilistic guessing, associative shortcuts, or plausible-sounding assertions. Every claim regarding compiler mechanics, memory safety, or system behavior must be verified against actual source code, filesystem state, and test execution.
* **Content-Addressed Immutability**: Persistent entities, modules, and execution manifests are addressed by 256-bit BLAKE3 cryptographic hashes, replacing mutable POSIX hierarchical inode abstractions.
* **Anti-Sycophancy & Direct Collaboration**: Engineering reviews prioritize mathematical correctness and memory safety over false agreement. Flawed logic, unhandled edge cases, and architectural regressions must be exposed and corrected directly.

System Architecture & Mental Model
==================================
MicrOS is a post-POSIX, AI-native operating system structured around a strict two-tier computational model that cleanly divides hardware enforcement from high-level orchestration.

Two-Tier Substrate and Application Architecture:
------------------------------------------------
1. **Tier 0: Sovereign Microkernel & Substrate (Zig)**:
   A freestanding microkernel and direct syscall layer written in pure Zig. Tier 0 manages CPU structures (GDT/IDT), page-frame memory allocation (PMM/VMM), VirtIO device drivers (network, storage), Capability Space (CSpace) access token validation, structured shared-memory ring buffers, and the Immix mark-region bytecode virtual machine. Tier 0 never links external libraries and operates with mathematical alignment.

2. **Tier 1: Sovereign Applications & Orchestration (Macros)**:
   The high-level userland written exclusively in the Macros language (``.mx``, ``.macros``). Tier 1 encompasses system initialization (``init.mx``), the interactive shell (``msh.mx``), the self-hosting compiler pipeline, and resident AI agent orchestrators. Tier 1 programs run as isolated actors inside cooperative userspace fibers and communicate exclusively over typed shared-memory ring buffers and CSpace capabilities.

Dual Execution Environments (UEFI vs Sandbox):
----------------------------------------------
MicrOS runs in two distinct, complementary environments:

* **Bare-Metal x86_64 UEFI (Production/Emulation)**:
   The full operating system boots from UEFI firmware (OVMF in QEMU or physical hardware) through ``src/boot/uefi_main.zig``. The kernel initializes hardware directly, discovers PCI devices, drives VirtIO storage and networking, mounts Content-Addressed Storage (CAS), renders a 1280x800 graphical vector canvas via UEFI GOP, and executes the Genesis bundle inside cooperative green-thread fibers.

* **Linux Direct-Syscall Sandbox (Fast TDD/CI)**:
   For sub-second development loops, ``src/main.zig`` compiles to a freestanding Linux executable (``zig-out/bin/micros-init``) acting as PID 1 inside an isolated QEMU Linux sandbox or container. It invokes raw Linux syscalls directly through ``src/sys/linux.zig`` (zero libc), runs substrate self-tests, executes MicroShell commands, and cleanly triggers ACPI S5 poweroff.

System Entry Points & Boot Sequence
===================================
Understanding where execution starts and how control flows across boundaries is essential for navigating the codebase.

1. UEFI Bootloader Entry Point (src/boot/uefi_main.zig):
   Execution begins in ``pub fn main() uefi.Status`` within the UEFI Stage 1 bootloader (``boot.efi``):
   * Connects to UEFI System Table and initializes console output.
   * Discovers the hardware framebuffer using the UEFI Graphics Output Protocol (GOP), capturing base address, resolution (1280x800), and pixel format into ``FramebufferInfo``.
   * Queries the UEFI memory map into a contiguous array of ``MemoryDescriptor`` entries.
   * Packages physical memory boundaries, HHDM offsets, and framebuffer parameters into a verified ``BootInfo`` structure (magic ``0x4D494352_4F534249``).
   * Calls ``uefi.boot_services.exitBootServices`` to terminate UEFI firmware runtime.
   * Jumps directly to the microkernel entry point: ``kernel_main.kmain(&global_boot_info)``.

2. Microkernel Entry Point (src/kernel/main.zig):
   Execution enters the microkernel at ``pub export fn kmain(boot_info: *const BootInfo) callconv(.c) noreturn``:
   * Disables CPU interrupts (``cli``) and initializes the 16550 UART serial port for early debugging.
   * Validates ``BootInfo`` signature and installs CPU fault containment: Global Descriptor Table (``gdt.init()``) and Interrupt Descriptor Table (``idt.init()``).
   * Activates Physical Memory Management (``pmm.init()``) and Virtual Memory 4-level paging (``vmm.init()``).
   * Scans PCI bus for VirtIO devices (VirtIO-Net for network packets, VirtIO-Blk for persistent block storage).
   * Allocates an 8 MiB page-aligned kernel heap using ``std.heap.FixedBufferAllocator``.
   * Instantiates Genesis Actor 0 (``actor_mod.Actor.init``) and creates the root Capability Space (CSpace) with 64 slots.
   * Mounts Content-Addressed Storage (CAS), block cache, and direct GOP vector canvas.
   * Unpacks the embedded Genesis bundle (``genesis.mcb``), extracts ``init.mx``, compiles its AST into bytecode via the Stage 0 compiler, and initializes the Genesis Virtual Machine (``vm_mod.VM``).
   * Binds the microkernel ABI functions into the VM global scope.
   * Initializes the cooperative userspace fiber scheduler (``fiber_mod.Scheduler``), spawns ``vmThread``, and enters ``sched.run()``.

3. High-Level Init & Supervisor Entry Point (lib/macros/init.mx):
   The first high-level code executed in userspace runs as Genesis Actor 0/PID 1:
   * Unpacks App 0 (``msh.mx``) from the Genesis bundle via ``sys_bundle_read("msh.mx")``.
   * Spawns the MicroShell child actor via ``sys_actor_spawn_code("msh", msh_src)``.
   * Enters the ``supervisor_loop``, continuously polling child actor states (``sys_actor_state``), automatically respawning faulted actors, and yielding CPU time via ``sys_yield()``.

4. Linux Sandbox Entry Point (src/main.zig):
   For testing outside bare-metal emulation, ``pub fn main() !void`` serves as PID 1:
   * Prints the init banner directly to file descriptor 1 via ``src/sys/io.zig``.
   * Executes a substrate self-test: compiles and evaluates ``boot_check = 20 + 22`` in a clean Macros VM instance, asserting the result is 42.
   * Instantiates ``msh.Shell`` connected to stdin (0) and stdout (1).
   * Executes startup commands, logs completion, and cleanly halts via ``sys.process.poweroff()`` (using raw ACPI reboot magic ``0x4321fedc``).

5. Standalone Runners:
   * ``src/macros_main.zig``: CLI runner to compile and execute standalone ``.mx`` script files directly on the host.
   * ``src/msh_main.zig``: Interactive host CLI to launch the MicroShell REPL for local testing.

Repository Anatomy: What Is Where
=================================
The codebase is strictly structured into domain-driven directories with distinct responsibilities:

Substrate & Kernel Layer (src/):
--------------------------------
* ``src/boot/``: Stage 1 UEFI bootloader implementation (``uefi_main.zig``) and protocol headers.
* ``src/kernel/``: Sovereign microkernel core:
   * ``arch/x86_64/``: Assembly context switching, GDT, IDT, port I/O, paging definitions.
   * ``mem/``: Physical page frame allocator (``pmm.zig``) and Virtual Memory Manager (``vmm.zig``).
   * ``drivers/``: VirtIO-Net 1.0, VirtIO-Blk 1.0, PCI enumeration, and PS/2 keyboard drivers.
   * ``cap/``: Capability-based access control (``capability.zig``, ``cspace.zig``).
   * ``storage/``: Content-Addressed Storage engine (``cas.zig``, ``chunk.zig``, ``block_cache.zig``, ``superblock.zig``).
   * ``ipc/``: Structured lockless ring buffers (``ring.zig``) and typed event channels (``events.zig``).
   * ``compositor/``: Vector graphics engine, 1280x800 canvas, font rendering, mouse pointer, BSP tiling window manager.
   * ``net/``: In-kernel network stack (DHCP client, DNS resolver, TCP socket state machine, TLS 1.3 adapter).
   * ``ai.zig``: Resident AI orchestrator client (HTTP 1.1 streaming, prompt generation, tool dispatch).
   * ``actor.zig`` & ``supervisor.zig``: Actor lifecycle management and fault supervision trees.
   * ``abi.zig``: Syscall and ABI function bindings exposed to the Macros VM.
   * ``main.zig``: Microkernel root initialization and ``kmain`` execution flow.
* ``src/sys/``: Zero-libc freestanding Linux syscall library (``linux.zig``, ``io.zig``, ``mem.zig``, ``process.zig``).
* ``src/msh/``: MicroShell engine (``shell.zig``, ``builtins.zig``) providing command parsing and execution pipelines.

Language Engine & Runtime (src/macros/):
----------------------------------------
The Stage 0 Macros implementation written in freestanding Zig:
* ``lexer.zig``: Scans UTF-8 source streams into typed tokens.
* ``parser.zig`` & ``ast.zig``: Generates and validates recursive-descent Abstract Syntax Trees.
* ``compiler.zig`` & ``chunk.zig``: Compiles AST nodes into serialized bytecode instruction arrays.
* ``vm.zig``: High-performance stack-based bytecode interpreter.
* ``eval.zig``: Tree-walk interpreter used during early bootstrap stages.
* ``gc.zig`` & ``immix.zig``: Immix mark-region garbage collector (32 KiB blocks, line mark bitmaps, hole allocation).
* ``fiber.zig`` & ``context_switch.s``: Userspace cooperative green threads and callee-saved assembly context switching.
* ``codegen_x86_64.zig``: Freestanding machine code generator with W^X page protection.
* ``module.zig`` & ``serializer.zig``: CAS module loader (``b3:...`` and ``bundle:...``) and canonical chunk serialization.

Self-Hosting Compiler & Apps (lib/macros/):
-------------------------------------------
The Stage 1 Macros implementation written entirely in pure Macros:
* ``init.mx``: System supervisor and Actor 0 init script.
* ``msh.mx``: Sovereign MicroShell implementation written in pure Macros.
* ``harness.mx``: Autonomous test runner and verification harness.
* ``ast.mx``, ``lexer.mx``, ``parser.mx``: Self-hosting compiler frontend.
* ``compiler.mx``, ``compiler_main.mx``: Self-hosting bytecode compiler.

Verification Toolchain (tools/):
--------------------------------
Seven host utilities providing automated quality gates and diagnostic verification:
* ``micros-runner.bash``: Headless event-driven QEMU test harness with serial sentinel detection.
* ``src/fb_verify.zig`` (``micros-fb-verify``): Sub-millisecond framebuffer pixel variance validator.
* ``src/lint.zig`` (``micros-lint``): Native Zig AST linter enforcing the Ten Commandments.
* ``src/sym.zig`` (``micros-sym``): Freestanding 64-bit ELF symbol unwinder and address-to-line resolver.
* ``micros-inspect.bash``: Non-interactive QEMU monitor socket CPU state and register disassembler.
* ``src/telem.zig`` (``micros-telem``): Native 64-byte binary telemetry decoder.
* ``micros-spec-trace.bash``: Four-tier bidirectional specification traceability auditor.
* ``src/virtio_bench.zig`` (``micros-virtio-bench``): VirtIO split-virtqueue validator and RDTSC DMA benchmark.
* ``src/bundle.zig`` (``micros-bundle``): Packages Stage 1 ``.mx`` files into the binary ``genesis.mcb`` bundle.

How It Is All Put Together: Lifecycle Pipeline
==============================================
The lifecycle of MicrOS links build-time artifact generation to boot-time hardware execution.

Build-Time Assembly Pipeline:
-----------------------------
1. **Compile Host Tools**: ``make tools`` compiles native Zig utilities into ``zig-out/bin/``.
2. **Package Genesis Bundle**: ``tools/micros-bundle`` reads Stage 1 source scripts from ``lib/macros/`` (``init.mx``, ``msh.mx``, ``harness.mx``, ``lexer.mx``, ``parser.mx``, ``compiler.mx``, ``compiler_main.mx``) and serializes them into a single binary file: ``src/kernel/genesis.mcb``.
3. **Compile Microkernel & Bootloader**: ``zig build`` compiles ``src/boot.zig`` into ``zig-out/bin/boot.efi`` and ``src/kernel.zig`` into ``zig-out/bin/micros-kernel.elf`` (embedding ``genesis.mcb`` via ``@embedFile``).
4. **Compile Sandbox Target**: ``zig build`` compiles ``src/main.zig`` into the freestanding executable ``zig-out/bin/micros-init``.

Execution & Runtime Lifecycle Flow:
-----------------------------------
The complete execution sequence from cold boot to interactive shell:

.. code-block:: text

   +-------------------------------------------------------------------------+
   | UEFI Firmware (OVMF in QEMU/Physical Hardware)                        |
   +-------------------------------------------------------------------------+
                                      |
                                      v
   +-------------------------------------------------------------------------+
   | Stage 1 Bootloader: src/boot/uefi_main.zig                              |
   | - Locates GOP Framebuffer (1280x800x32)                                 |
   | - Captures Memory Descriptors into BootInfo (0x4D494352_4F534249)       |
   | - Calls exitBootServices and jumps to kmain                             |
   +-------------------------------------------------------------------------+
                                      |
                                      v
   +-------------------------------------------------------------------------+
   | Microkernel Root: src/kernel/main.zig (kmain)                           |
   | - Initializes Serial UART, GDT, IDT, PMM, VMM (4-level paging)          |
   | - Discovers PCI VirtIO-Net and VirtIO-Blk drivers                       |
   | - Mounts Content-Addressed Storage (CAS) & Block Cache                  |
   | - Initializes Genesis CSpace (64 slots) & Framebuffer Canvas            |
   | - Unpacks genesis.mcb, compiles init.mx via Stage 0 compiler            |
   | - Binds Microkernel ABI functions into Genesis VM                       |
   | - Starts Fiber Scheduler (fiber_mod.Scheduler.run)                      |
   +-------------------------------------------------------------------------+
                                      |
                                      v
   +-------------------------------------------------------------------------+
   | System Supervisor: lib/macros/init.mx (Actor 0/PID 1 in Macros)       |
   | - Reads msh.mx from genesis bundle                                      |
   | - Spawns App 0 (msh) via sys_actor_spawn_code                           |
   | - Runs supervisor loop monitoring actor states & yielding CPU           |
   +-------------------------------------------------------------------------+
                                      |
                                      v
   +-------------------------------------------------------------------------+
   | MicroShell & Window Manager: lib/macros/msh.mx + src/kernel/compositor/ |
   | - Renders graphical vector windows on 1280x800 GOP canvas               |
   | - Processes PS/2 keyboard input and mouse pointer events                |
   | - Orchestrates commands, Resident AI agents, and CAS modules            |
   +-------------------------------------------------------------------------+

The Ten Commandments of Code Quality
====================================
The Ten Commandments form the non-negotiable bedrock of code craftsmanship in MicrOS. These rules are enforced deterministically by the native AST linter (``tools/micros-lint``) and automated CI gates.

.. table:: The Ten Commandments Summary
   :widths: auto

   +----+--------------------------+-------------------------------------------------------------+
   | No | Commandment              | Mandatory Constraint                                        |
   +====+==========================+=============================================================+
   | 1  | Maximum File Size        | Files must not exceed 1,000 lines of code.                  |
   +----+--------------------------+-------------------------------------------------------------+
   | 2  | Maximum Function Size    | Functions must not exceed 40 lines of code.                 |
   +----+--------------------------+-------------------------------------------------------------+
   | 3  | Maximum Nesting Depth    | Maximum indentation depth is 3 levels.                      |
   +----+--------------------------+-------------------------------------------------------------+
   | 4  | Formatting Style         | No spaces around slashes (``word/word``); strict ``zig fmt``|
   +----+--------------------------+-------------------------------------------------------------+
   | 5  | No Magic Numbers         | Typed constants or ``UPPER_SNAKE_CASE`` identifiers.        |
   +----+--------------------------+-------------------------------------------------------------+
   | 6  | Explicit Errors          | Prohibit ``catch unreachable`` outside test blocks.         |
   +----+--------------------------+-------------------------------------------------------------+
   | 7  | Zero Libc Dependencies   | Substrate layer must never link or include libc.            |
   +----+--------------------------+-------------------------------------------------------------+
   | 8  | Explicit Memory Safety   | Explicit ``Allocator`` parameter; no hidden global heaps.   |
   +----+--------------------------+-------------------------------------------------------------+
   | 9  | Page & Sector Alignment  | Enforce 4096-byte page and 512-byte sector alignment.       |
   +----+--------------------------+-------------------------------------------------------------+
   | 10 | Colocated Unit Testing   | Tests must reside natively alongside code in same module.   |
   +----+--------------------------+-------------------------------------------------------------+

Commandment 1: Maximum File Size (<= 1,000 Lines)
-------------------------------------------------
No source file shall exceed 1,000 lines of code. Monolithic source files impede local reasoning, dilute domain boundaries, and exceed AI context window limits. When a file approaches 800 lines, decompose it into coherent domain submodules within the same package directory.

Commandment 2: Maximum Function Size (<= 40 Lines)
--------------------------------------------------
No function shall exceed 40 lines of code. Functions exceeding 40 lines violate the Single Responsibility Principle and indicate multiple unseparated concerns. Decompose multi-phase logic into small, private helper functions with clear verbs.

Commandment 3: Maximum Nesting Depth (<= 3 Levels)
--------------------------------------------------
Deeply nested blocks obscure control flow and hide edge cases. Maximum nesting depth is strictly 3 levels. Flatten control flow using early returns and guard clauses.

.. code-block:: zig

   // FORBIDDEN: Nesting depth >= 4
   pub fn processPacket(packet: *const Packet) !void {
       if (packet.isValid()) {
           if (packet.hasPayload()) {
               if (packet.header.version == CURRENT_VERSION) {
                   if (packet.isEncrypted()) {
                       try decryptAndRoute(packet);
                   }
               }
           }
       }
   }

   // MANDATORY: Guard clauses flattening nesting depth <= 2
   pub fn processPacket(packet: *const Packet) !void {
       if (!packet.isValid()) return error.InvalidPacket;
       if (!packet.hasPayload()) return error.EmptyPayload;
       if (packet.header.version != CURRENT_VERSION) return error.UnsupportedVersion;

       if (packet.isEncrypted()) {
           return decryptAndRoute(packet);
       }
       return routePlaintext(packet);
   }

Commandment 4: Formatting & Slash Style
---------------------------------------
Never insert spaces around forward slashes. Always format slashes as ``word/word`` (e.g., ``kernel/userspace``, ``read/write``, ``QEMU/KVM``, ``input/output``), never with whitespace separating the slash from words. All Zig source files must be formatted cleanly with ``zig fmt`` before commit.

Commandment 5: No Magic Numbers
-------------------------------
Numeric literals must be given semantic meaning. Use strongly typed enums or ``UPPER_SNAKE_CASE`` constants.

.. code-block:: zig

   // FORBIDDEN: Magic literals
   const page = try sys.mem.map(0, 65536, 3, 34, -1, 0);

   // OBLIGATORIO: Typed constants and bitmasks
   pub const FIBER_STACK_SIZE: usize = 64 * 1024;
   pub const MMAP_PROT_RW: u32 = sys.linux.PROT_READ | sys.linux.PROT_WRITE;
   pub const MMAP_FLAGS_ANON: u32 = sys.linux.MAP_PRIVATE | sys.linux.MAP_ANONYMOUS;

   const stack_mem = try sys.mem.map(
       0,
       FIBER_STACK_SIZE,
       MMAP_PROT_RW,
       MMAP_FLAGS_ANON,
       -1,
       0,
   );

Commandment 6: Explicit Error Propagation
-----------------------------------------
Never use ``catch unreachable`` outside of isolated unit test assertions. Swallowing errors or panicking via ``unreachable`` in runtime code destroys fault tolerance. Bubble errors up using Zig error sets (``!T``) and ``try``, or handle them explicitly with ``catch |err|``.

.. code-block:: zig

   // FORBIDDEN: Swallowing fallible operations
   const handle = openFile(path) catch unreachable;

   // MANDATORY: Explicit bubbling or deterministic recovery
   const handle = openFile(path) catch |err| switch (err) {
       error.FileNotFound => return error.MissingResource,
       error.AccessDenied => return error.PermissionDenied,
       else => return err,
   };

Commandment 7: Zero Libc Dependencies
-------------------------------------
The substrate layer (``src/sys/``) and kernel (``src/kernel/``) must never link against or include ``libc`` or external POSIX runtimes. All operating system interactions must use direct freestanding Linux syscall wrappers (``src/sys/linux.zig``) or inline x86_64 assembly.

Commandment 8: Explicit Memory Safety & Allocators
--------------------------------------------------
Zig Zen dictates: No hidden memory allocations.
Every function that allocates heap or virtual memory must accept an explicit ``allocator: std.mem.Allocator`` parameter. Global heap allocations are forbidden. All allocated resources must be freed immediately using ``defer`` or ``errdefer``. In tests, verify memory leak freedom using ``std.testing.allocator``.

.. code-block:: zig

   pub fn createBuffer(allocator: std.mem.Allocator, capacity: usize) ![]u8 {
       const buffer = try allocator.alloc(u8, capacity);
       errdefer allocator.free(buffer);

       try initializeBuffer(buffer);
       return buffer;
   }

Commandment 9: Mathematical Page & Sector Alignment
---------------------------------------------------
All memory buffers mapped via ``sys.mem.map``, VirtIO DMA queues, and hardware framebuffers must mathematically enforce 4096-byte page alignment. Storage blocks must enforce 512-byte sector alignment. Unaligned memory access produces undefined behavior or CPU faults.

.. code-block:: zig

   pub const PAGE_SIZE: usize = 4096;
   pub const SECTOR_SIZE: usize = 512;

   pub fn assertPageAligned(addr: usize) !void {
       if (addr % PAGE_SIZE != 0) {
           return error.MisalignedPageBoundary;
       }
   }

   pub fn assertSectorAligned(offset: u64) !void {
       if (offset % SECTOR_SIZE != 0) {
           return error.MisalignedSectorBoundary;
       }
   }

Commandment 10: Colocated Unit Testing
--------------------------------------
Tests must reside in the exact same file as the code they verify, leveraging Zig's native ``test`` blocks. Colocation keeps tests synchronized with implementation changes and enables thorough testing of private functions and internal invariants.

.. code-block:: zig

   pub fn addSaturated(a: u32, b: u32) u32 {
       const res = @addWithOverflow(a, b);
       return if (res[1] != 0) std.math.maxInt(u32) else res[0];
   }

   test "addSaturated bounds verification" {
       try std.testing.expectEqual(@as(u32, 42), addSaturated(20, 22));
       try std.testing.expectEqual(std.math.maxInt(u32), addSaturated(std.math.maxInt(u32), 1));
   }

Domain-Driven Architecture & Bounded Contexts
=============================================
MicrOS enforces strict package boundaries. Code must be organized around cohesive domains rather than technical utility categories.

The Forbidden Names Rule:
-------------------------
The creation of generic garbage bins such as ``utils.zig``, ``common.zig``, or ``helpers.zig`` is strictly prohibited. The AST linter (``tools/micros-lint``) rejects any file bearing these names. Code must reside in descriptive, domain-specific modules:

* Instead of ``utils.zig`` -> ``src/kernel/mem/page_table.zig`` or ``src/kernel/storage/crc32.zig``.
* Instead of ``common.zig`` -> ``src/sys/constants.zig`` or ``src/macros/chunk.zig``.
* Instead of ``helpers.zig`` -> ``src/macros/token_stream.zig`` or ``src/kernel/compositor/color.zig``.

Architectural Principles:
-------------------------
* **Metz's Single Responsibility Rule**: A module or struct has a single responsibility if its role can be described in one concise sentence without using the words "and" or "but".
* **Tell, Don't Ask**: Objects and structs should command behavior rather than exposing raw internal state for external modification.
* **Law of Demeter**: A function should only invoke methods on its direct dependencies, method parameters, or locally instantiated objects. Avoid train-wreck chaining (``a.b().c().d()``).
* **Command-Query Separation (CQS)**: Methods must either mutate state (returning void) or compute a result (pure query, leaving state intact). Never combine mutations and queries.

Substrate & Kernel Zig Development
==================================
The substrate layer bridges the hardware and higher-level runtimes. High-performance, zero-allocation invariants apply.

Freestanding Syscall Invocation:
--------------------------------
The ``src/sys/linux.zig`` module provides raw, inline assembly syscall wrappers from ``syscall1`` through ``syscall6``. Syscall returns must be checked immediately for negative error codes and converted into typed Zig error unions.

.. code-block:: zig

   pub fn write(fd: i32, buf: []const u8) !usize {
       const rc = linux.syscall3(
           linux.SYS_write,
           @bitCast(@as(isize, fd)),
           @intFromPtr(buf.ptr),
           buf.len,
       );
       if (rc < 0) return linux.toError(rc);
       return @intCast(rc);
   }

Ring Buffers & Zero-Allocation Loops:
-------------------------------------
Critical communication channels (e.g., compositor events, telemetry tokens, VirtIO queues) must execute with zero heap allocations. Use fixed-capacity ring buffers with atomic head/tail indices:

.. code-block:: zig

   pub fn RingBuffer(comptime T: type, comptime CAPACITY: usize) type {
       comptime std.debug.assert(std.math.isPowerOfTwo(CAPACITY));
       return struct {
           const Self = @This();
           storage: [CAPACITY]T = undefined,
           head: usize = 0,
           tail: usize = 0,

           pub fn push(self: *Self, item: T) bool {
               const next = (self.head + 1) & (CAPACITY - 1);
               if (next == self.tail) return false; // Full
               self.storage[self.head] = item;
               self.head = next;
               return true;
           }

           pub fn pop(self: *Self) ?T {
               if (self.head == self.tail) return null; // Empty
               const item = self.storage[self.tail];
               self.tail = (self.tail + 1) & (CAPACITY - 1);
               return item;
           }
       };
   }

Macros Programming Language Standards
=====================================
The Macros programming language (``.mx``, ``.macros``) is the sovereign application and orchestration language of MicrOS.

File Extensions:
----------------
* ``.mx``: Canonical concise extension for all Macros scripts, modules, and tests.
* ``.macros``: Canonical verbose extension, fully supported by runtime and compiler.
* ``.mc``: Legacy extension supported for backward compatibility during bootstrap.

Language Grammar & Idioms:
--------------------------
* Expression-oriented syntax with strict type boundaries.
* Variables are declared and scoped explicitly.
* Functions are defined using ``fn name(params) { ... }``.
* Fiber scheduling is cooperative via ``yield()``.

.. code-block:: text

   // Canonical Macros implementation
   fn calculate_checksum(buffer, length) {
       acc = 0;
       i = 0;
       while (i < length) {
           acc = acc + buffer[i];
           i = i + 1;
       }
       return acc;
   }

Immix Mark-Region Memory Invariants:
------------------------------------
All runtime allocations in Macros operate on the Immix mark-region garbage collector (``src/macros/gc.zig``):
* **Block Geometry**: 32 KiB blocks containing 256 lines of 128 bytes (or 256 bytes depending on runtime configuration).
* **Bump-Pointer Hole Allocation**: Allocation fast-path allocates into contiguous recyclable line holes without memory fragmentation.
* **Large Objects**: Objects larger than 512 bytes bypass line marks and allocate directly from dedicated virtual memory pages.
* **Multi-Root Tracing**: The GC must trace roots across fiber execution stacks, VM registers, and global symbol tables.

Content-Addressed Modules (CAS):
--------------------------------
Macros source modules and precompiled binary chunks (``.mcb``) are addressed by their 256-bit BLAKE3 hash:
* Module imports use the ``b3:<hex_digest>`` URI scheme for immutable dependencies.
* System boot bundles use the ``bundle:<name>`` scheme for self-contained execution.
* Hierarchical mutable filesystem lookups are strictly prohibited in the kernel runtime.

Bash Scripting Standards
========================
Host verification scripts, test runners, and build helpers written in Bash must adhere to rigorous defensive scripting standards.

Mandatory Script Invariants:
----------------------------
#. **File Extension**: Must use ``.bash`` (e.g., ``tools/micros-runner.bash``). The ``.sh`` extension is strictly forbidden.
#. **Shebang**: Must begin with ``#!/usr/bin/bash``.
#. **Strict Header**: Immediately following the shebang, declare:

   .. code-block:: bash

      set -euo pipefail
      IFS=$'\n\t'

#. **Scoped Variables**: All variables inside functions must be declared with ``local``.
#. **Test Conditions**: Use double brackets ``[[ ... ]]`` for conditional tests instead of ``[ ... ]``.
#. **Command Substitution**: Use ``$(command)`` instead of backticks.
#. **Static Analysis**: All scripts must pass ``shellcheck`` with zero errors and zero warnings.

Verification Toolchain & Pre-Commit Protocol
============================================
MicrOS provides a comprehensive host toolchain in ``tools/`` to enforce quality gates deterministically.

Substrate Tool Catalog:
-----------------------
* **micros-runner**: Headless QEMU event-driven harness for UEFI and Linux direct-syscall sandbox execution.
* **micros-fb-verify**: Sub-millisecond framebuffer pixel variance and bounding-box color regression tester.
* **micros-lint**: Native Zig AST static analysis engine enforcing the Ten Commandments.
* **micros-sym**: Freestanding 64-bit ELF symbol table unwinder and address-to-line resolver.
* **micros-inspect**: Non-interactive QEMU monitor socket inspector for CPU register disassembly during panics.
* **micros-telem**: Native 64-byte binary telemetry stream decoder and fault analyzer.
* **micros-spec-trace**: Bidirectional specification traceability matrix auditor across business, functional, technical, and roadmap tiers.
* **micros-virtio-bench**: VirtIO 1.0 split-virtqueue geometry validator and RDTSC DMA micro-benchmarker.
* **micros-bundle**: Binary genesis bundle packager serializing Stage 1 Macros files into ``genesis.mcb``.

The Mandatory Pre-Commit Checklist:
-----------------------------------
Before committing any changes to the repository, execute the following sequence:

#. Compile all tools:

   .. code-block:: bash

      make tools

#. Run static linter and ShellCheck:

   .. code-block:: bash

      make lint

#. Check formatting:

   .. code-block:: bash

      make fmt-check

#. Verify specification traceability:

   .. code-block:: bash

      make spec-trace

#. Run unit test suite:

   .. code-block:: bash

      zig build test
      make -C tools test

#. Run UEFI and sandbox integration tests:

   .. code-block:: bash

      make test-sandbox
      make test-uefi

Git Standards & Commit Hygiene
==============================
Commit messages must follow the Conventional Commits specification:

* Format: ``type(scope): concise description in present tense``
* Supported types: ``feat``, ``fix``, ``docs``, ``style``, ``refactor``, ``perf``, ``test``, ``chore``.
* Example: ``feat(gc): consolidate Immix mark-region collector with multi-root tracing``
* Commits must include human and agent sign-off trailers.
* Zero credentials, API keys, or private endpoints in repository commits.
