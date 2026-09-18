Milestone 23a: Hardware Ring 3 & Syscall Substrate
====================================================

:Objective: Establish authentic hardware CPU privilege separation on x86_64, moving beyond cooperative Ring 0 fibers into true hardware-enforced Ring 3 user mode. Implement a 64-bit Task State Segment (TSS) with per-core kernel stacks, configure MSRs for fast ``syscall``/``sysretq`` transitions, and isolate actors into per-domain 4-level CR3 virtual address spaces.
:Status: Active Target
:Specification: SPEC-TECH-CAP-002
:Traced Stories: [US-REN-004], [US-REN-006], [US-GEM-001], [US-GEM-010]

Milestones & Deliverables
-------------------------

* **M23a.1: 64-Bit Task State Segment (TSS) & Hardware Stack Switch**
   - Implement 104-byte 64-bit TSS structure in ``src/kernel/arch/x86_64/gdt.zig``.
   - Configure dedicated per-core ``RSP0`` kernel interrupt stack pointers.
   - Install 16-byte TSS descriptor in GDT and execute ``ltr`` instruction during CPU initialization.
   - Prevents hardware double/triple faults upon taking interrupts in user mode.

* **M23a.2: Fast Syscall MSR Configuration & Low-Level Entry Assembly**
   - Configure Model-Specific Registers:
      - ``IA32_EFER.SCE`` (Bit 0): Enable ``syscall``/``sysret`` instructions.
      - ``IA32_STAR``: Kernel and user 64-bit code/data segment selectors.
      - ``IA32_LSTAR``: Entry point address for assembly syscall handler (``syscall_entry``).
      - ``IA32_SFMASK``: Mask interrupt flag (``RFLAGS.IF``) and direction flag during entry.
   - Implement atomic ``syscall_entry`` in assembly: swap user/kernel stack pointers (``swapgs``/``mov``), save callee/caller registers, dispatch to C-ABI handler, and execute ``sysretq``.

* **M23a.3: Per-Actor 4-Level CR3 Virtual Address Spaces**
   - Implement userland page table allocator in ``src/kernel/mem/vmm.zig``.
   - Map kernel higher-half direct map (HHDM) with Supervisor-only bits (Ring 3 cannot read or write kernel space).
   - Map per-actor code, stack, and heap pages with User/Supervisor bit set (Ring 3 accessible).
   - Switch ``CR3`` during actor context switching and invalidate TLB mappings.

* **M23a.4: Capability Syscall Trampoline Verification**
   - Route userland syscalls through the existing capability CSpace gate ([`src/kernel/abi.zig`](file:///home/renich/Projects/zig/micros/src/kernel/abi.zig)).
   - Verify unprivileged actors cannot execute privileged instructions (``cli``, ``hlt``, ``in``, ``out``, ``mov cr3``) and trigger clean General Protection Faults (``#GP``).
