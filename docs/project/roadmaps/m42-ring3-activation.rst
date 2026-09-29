Milestone 42: Ring-3 Privilege Activation & Microkernel Excision
================================================================

:Objective: Transition userland daemons from Ring-0 kernel-resident fibers into isolated Ring-3 hardware address spaces, enforce CR3 page table segregation, wire LSTAR syscall dispatch, and reduce the Ring-0 substrate to a minimal capability microkernel.
:Status: Planned (Successor to Sovereign OS Stage 4 / Milestone 41)
:Specification: SPEC-TECH-CAP-002, SPEC-TECH-MEM-001, SPEC-TECH-CORE-001
:Traced Stories: [US-REN-001], [US-REN-004], [US-GEM-001]

Ground-Truth Architectural Reality (Stage 4 Baseline)
-----------------------------------------------------

In Sovereign OS Stages 1 through 4 (Milestones 38 through 41), all actors and system daemons (``netd``, ``storaged``, ``gopd``, ``aid``, ``p2pd``, ``pkgd``) execute as kernel-resident cooperative fibers sharing the Higher-Half Direct Map (HHDM) address space in Ring 0. Ring 3 is completely unoccupied.

Stage 4 established the architectural prerequisites for physical isolation:
1. **Decoupling Pilot**: ``src/userland/pkgd/`` was decoupled from kernel internals via ``pkg_abi.zig``, registering capability-gated syscalls (``sys_pkg_count``, ``sys_pkg_query``, ``sys_pkg_register``) through ``abi.zig`` and removing all direct imports from ``src/kernel/main.zig``.
2. **Boundary Enforcement Gate**: ``tools/src/arch_gate.zig`` mathematically scans all 827 module import edges on every ``make check`` invocation, enforcing that userland cannot import kernel internals and the kernel cannot import userland daemons except through typed ABI interfaces.
3. **Hardware Readiness**: GDT user segments (Ring 3 CS/DS) and LSTAR syscall trampoline structures are defined in the x86_64 architecture layer.

Milestone 42 executes the physical privilege excision: activating separate PML4 address spaces per actor, switching CR3 on context switch, and handling transitions via hardware ``syscall``/``sysretq`` instructions.

Subsystem Excision Table
------------------------

All daemons currently compiled into the kernel image or executed as Ring-0 fibers will be excised into standalone ELF/PE executables stored in CAS and spawned as isolated Ring-3 processes:

+---------------+-------------+------------+-----------------------+------------------+------------------------------------------------+------------------------------------------------------+
| Subsystem     | Current LOC | Target LOC | Boundary Interface    | Excision Order   | What Moves Out of Ring 0                       | Target Ring-3 Isolation Model                        |
+===============+=============+============+=======================+==================+================================================+======================================================+
| **pkgd**      | 461 LOC     | 461 LOC    | ``pkg_abi.zig``       | Order 0 (Pilot)  | Package registry logic, SemVer resolution,     | Userland daemon; in-memory manifest store;           |
|               |             |            | (sys_pkg_*)           | [Stage 4 DONE]   | circular dependency validation                 | zero hardware capability requirements                |
+---------------+-------------+------------+-----------------------+------------------+------------------------------------------------+------------------------------------------------------+
| **p2pd**      | 2,131 LOC   | 2,131 LOC  | ``p2p_abi.zig``       | Order 1 (M42.1)  | P2P mesh gossip, Merkle CAS sync,              | Isolated process; filtered UDP via IPC ring;         |
|               |             |            | (sys_p2p_*)           |                  | Ed25519 auth, remote actor RPC                 | holds network endpoint token                         |
+---------------+-------------+------------+-----------------------+------------------+------------------------------------------------+------------------------------------------------------+
| **storaged**  | 6,374 LOC   | 6,374 LOC  | ``storage_abi.zig``   | Order 2 (M42.2)  | FAT32 driver, block cache, CAS store,          | Driver process holding ``hardware_device``           |
|               |             |            | (sys_cas_*, sys_fat*) |                  | manifest serializer, bundle format,            | and ``dma_buffer`` capability tokens                 |
|               |             |            |                       |                  | block stack (virtio_blk, nvme, gpt)            |                                                      |
+---------------+-------------+------------+-----------------------+------------------+------------------------------------------------+------------------------------------------------------+
| **netd**      | 6,240 LOC   | 6,240 LOC  | ``net_abi.zig``       | Order 3 (M42.3)  | TCP/IP stack, TLS crypto stream engine,        | Driver process holding ``network_device``            |
|               |             |            | (sys_net_*)           |                  | DNS/DHCP clients, HTTP/1.1 transport,          | and ``irq_endpoint`` tokens                          |
|               |             |            |                       |                  | virtio_net + e1000 NIC drivers                 |                                                      |
+---------------+-------------+------------+-----------------------+------------------+------------------------------------------------+------------------------------------------------------+
| **aid**       | 3,054 LOC   | 3,054 LOC  | ``ai_abi.zig``        | Order 4 (M42.4)  | AI tool parser, JSON dispatcher, LLM clients,  | Sandboxed actor; external LLM endpoints via          |
|               |             |            | (sys_ai_*)            |                  | probe ladder (D1), provenance service          | attenuated network socket IPC                        |
|               |             |            |                       |                  |                                                |                                                      |
+---------------+-------------+------------+-----------------------+------------------+------------------------------------------------+------------------------------------------------------+
| **gopd**      | 3,628 LOC   | 3,628 LOC  | ``window_abi.zig``    | Order 5 (M42.5)  | Rasterizer, WM compositor, canvas, input mux,  | Compositor holding GOP VRAM extent token             |
|               |             |            | (sys_win_*)           |                  | fb/font helpers, ps2_kbd + xhci drivers        |                                                      |
|               |             |            |                       |                  |                                                |                                                      |
+---------------+-------------+------------+-----------------------+------------------+------------------------------------------------+------------------------------------------------------+
| **Total Out** | **21,888**  | **21,888** | Capability ABI        | M42 Excision     | All parsing, stacks, crypto, UI                | Zero ambient authority; isolated spaces              |
+---------------+-------------+------------+-----------------------+------------------+------------------------------------------------+------------------------------------------------------+

Honest Microkernel Accounting
-----------------------------

The sovereign design mandate requires a minimal Ring-0 substrate. The table below reports the verified current LOC beside target LOC for every kernel subsystem, adhering to the principle that architectural reality bends to arithmetic, never the reverse.

+-----------------------+-------------+------------+--------------------------------------------+------------------------------------------------------------+
| Kernel Subsystem      | Current LOC | Target LOC | What Moves Out of Subsystem                | Architectural Mechanics Retained in Ring 0                 |
+=======================+=============+============+============================================+============================================================+
| **mem/pmm.zig**       | 198 LOC     | 198 LOC    | Nothing (already minimal)                  | Freestanding 4 KiB physical bitmap page frame allocator    |
+-----------------------+-------------+------------+--------------------------------------------+------------------------------------------------------------+
| **mem/vmm.zig**       | 688 LOC     | 520 LOC    | Ad-hoc HHDM user mappings, debug walkers   | 4-level PML4/PDPT/PD/PT mapper, unmap, page fault handler  |
+-----------------------+-------------+------------+--------------------------------------------+------------------------------------------------------------+
| **cap/**              | 1,785 LOC   | 920 LOC    | Composite high-level user token validation | CSpace capability table, 256-entry worklist cascade,       |
|                       |             |            | (delegated to userland libmicros auth lib) | rights mask checking, TLB shootdown invalidation (invlpg)  |
+-----------------------+-------------+------------+--------------------------------------------+------------------------------------------------------------+
| **arch/x86_64/**      | 1,555 LOC   | 850 LOC    | Port I/O helper macros, diagnostic traps,  | GDT/TSS, IDT exception dispatch, APIC timer,               |
|                       |             |            | unused MSR abstraction wrappers            | LSTAR/STAR syscall trampoline, page table hardware reload  |
+-----------------------+-------------+------------+--------------------------------------------+------------------------------------------------------------+
| **ipc/**              | 654 LOC     | 380 LOC    | Kernel console multiplexing, string format | Lock-free zero-copy shared memory descriptor ring buffers, |
|                       |             |            | dispatchers (moved to userland terminal)   | async notification endpoints, sleep waitqueues             |
+-----------------------+-------------+------------+--------------------------------------------+------------------------------------------------------------+
| **actor.zig** &       | 815 LOC     | 350 LOC    | Userland fiber green-threading engine,     | Process Thread Control Block (TCB), hardware register      |
| **lifecycle**         |             |            | Macros GC root scanning (moved to runtime) | save/restore, round-robin scheduler, quantum preemption    |
+-----------------------+-------------+------------+--------------------------------------------+------------------------------------------------------------+
| **sched/smp.zig**     | 253 LOC     | 253 LOC    | Nothing (SMP trampoline stays)             | AP startup trampoline, APIC IPI rendezvous                 |
+-----------------------+-------------+------------+--------------------------------------------+------------------------------------------------------------+
| **supervisor.zig**    | 219 LOC     | 219 LOC    | Nothing (supervision root stays)           | Actor supervision tree root, restart policy                |
+-----------------------+-------------+------------+--------------------------------------------+------------------------------------------------------------+
| **drivers/pci.zig**   | 302 LOC     | 302 LOC    | Nothing (config-space guard stays)         | PCI config-space guard, BAR sizing, MSI routing            |
+-----------------------+-------------+------------+--------------------------------------------+------------------------------------------------------------+
| **boot (main+info)**  | 1,032 LOC   | 333 LOC    | Daemon instantiators, CAS early synthesis, | UEFI boot handoff, PMM/VMM/GDT/IDT/APIC bootstrap,         |
|                       |             |            | probe runner, interactive test harnesses   | CSpace genesis init, spawn initial userland init           |
+-----------------------+-------------+------------+--------------------------------------------+------------------------------------------------------------+
| **serial.zig**        | 262 LOC     | 120 LOC    | Formatted ANSI terminal escape parsing,    | COM1 115200 baud write-only fail-safe emergency logger for |
| (Serial/Debug)        |             |            | ring buffer history search                 | kernel panics and bootstrap assertions                     |
+-----------------------+-------------+------------+--------------------------------------------+------------------------------------------------------------+
| **abi.zig**           | 910 LOC     | 220 LOC    | Direct daemon method dispatches, complex   | Central LSTAR syscall multiplexer, capability token check, |
| (Syscall Dispatch)    |             |            | argument deserialization (moved to IPC)    | register parameter unpack, return value packing            |
+-----------------------+-------------+------------+--------------------------------------------+------------------------------------------------------------+
| harness glue          | 18 LOC      | 0 LOC      | Harness shim moves to test tooling         | (deleted at excision; no Ring-0 content)                   |
+-----------------------+-------------+------------+--------------------------------------------+------------------------------------------------------------+
| **Total Ring 0**      | **8,691**   | **4,665**  | **4,026 LOC excised to Userland/Runtimes** | **Freestanding Sovereign Capability Microkernel**          |
+-----------------------+-------------+------------+--------------------------------------------+------------------------------------------------------------+

Note on Size Target:
The original theoretical target of <2,000 LOC for the entire kernel is structurally infeasible. Measured current Ring-0 residence is 8,691 LOC; the honest minimal boundary after excising all six subsystems is 4,665 LOC. The largest retained blocks are CSpace capability mathematics (920 LOC target), x86_64 bring-up (850 LOC), the LSTAR dispatch surface (220 LOC), and boot/init (333 LOC). The design adheres strictly to the law: the mandate bends to arithmetic, never the reverse.

Measurement Appendix (Checker-Verified 2026-09-29)
---------------------------------------------------
Method: ``wc -l`` over ``*.zig`` per directory/file on the uncommitted Stage-4 tree. Kernel total 25,280 LOC partitions exactly: retained 8,691 + excised kernel-parts 16,589 = 25,280. Userland total 5,299 LOC.

- pkgd 461 = package.zig 305 + pkg_abi.zig 156.
- p2pd 2,131 = src/userland/p2pd/* (all).
- storaged 6,374 = userland/storaged 460 + kernel/storage/* 4,149 + bundle.zig 179 + virtio_blk 363 + nvme 609 + gpt 339 + virtio core 72 + block layer 203.
- netd 6,240 = userland/netd 283 + kernel/net/* 5,444 + virtio_net 310 + e1000 175 + net.zig shim 28.
- aid 3,054 = userland/aid 579 + kernel/ai/* 1,665 + probe_ladder 606 + provenance 182 + ai.zig shim 22.
- gopd 3,628 = userland/gopd/* 1,385 + kernel/compositor/* 1,518 + fb 131 + font 139 + ps2_kbd 301 + xhci 132 + compositor.zig shim 22.
- Retained: pmm 198, vmm 688, cap/* 1,785, arch/* 1,555, ipc/* 654, actor+lifecycle 815, sched/smp 253, supervisor 219, pci 302, main 979 + boot_info 53, serial 262, abi 910, harness glue 18.

Ring-3 Activation Steps
-----------------------

Milestone 42 implements physical Ring-3 hardware privilege activation through four sequenced strikes:

1. **Step 1: Address Space Segregation (Hardware CR3 Switching)**
   - Every userland process allocates a dedicated PML4 physical page frame.
   - User address space is restricted to lower half: ``0x0000_0000_0040_0000`` through ``0x0000_7FFF_FFFF_FFFF`` with user access enabled (``US=1``).
   - Higher half (``0xFFFF_8000_0000_0000`` through ``0xFFFF_FFFF_FFFF_FFFF``) maps kernel text, data, and HHDM with supervisor-only privileges (``US=0``).
   - Context switches between processes execute ``mov cr3, target_process.pml4_phys``, mathematically preventing cross-process and user-to-kernel memory leaks.

2. **Step 2: LSTAR Syscall & Sysret Dispatch**
   - Syscall MSR initialization is located in ``src/kernel/arch/x86_64/syscall.zig`` (NOT in ``idt.zig`` or ``gdt.zig``).
   - Early boot configures ``IA32_STAR`` (GDT user/kernel segment selectors), ``IA32_LSTAR`` (address of ``asm_syscall_entry``), and ``IA32_FMASK`` (clears IF, TF, DF on entry).
   - ``asm_syscall_entry`` executes ``swapgs`` to acquire kernel per-CPU data, swaps to kernel privilege stack, saves user GPRs, and calls ``abi.dispatch(rax, rdi, rsi, rdx, r10, r8, r9)``.
   - Return sequence validates capability result, restores user registers, executes ``swapgs``, and exits via ``sysretq`` to Ring 3.

3. **Step 3: Content-Addressed ELF/PE Loader**
   - The kernel ELF loader reads verified bytecode or native ELF/PE binaries from CAS storage.
   - Allocates user physical frames via PMM and maps pages into target PML4 with strict W^X policy (executable text mapped Read-Only / Execute; heap/stack mapped Read-Write / No-Execute).
   - Sets up initial Ring-3 user stack (RSP) and instruction pointer (RIP) pointing to process entry point.

4. **Step 4: Userland Runtime (libmicros)**
   - Standalone userland runtime providing:
     - Userland fiber scheduler and event loop.
     - Capability token client wrappers invoking ``syscall`` instruction.
     - Zero-copy IPC ring consumers for device drivers and compositor.
     - Macros language Immix garbage-collected virtual machine running fully in Ring 3.
