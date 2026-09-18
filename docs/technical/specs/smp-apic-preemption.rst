=======================================================================
Preemptive Symmetric Multiprocessing (SMP) & APIC Timer Substrate (µOS)
=======================================================================

:Document ID: SPEC-TECH-SMP-001
:Status: Approved
:Traced Stories: [US-REN-004], [US-REN-006], [US-REN-010], [US-GEM-001], [US-GEM-010]
:Parent Architecture: `SPEC-TECH-CAP-002`, `SPEC-TECH-SYS-001`
:Module Targets: ``src/kernel/arch/x86_64/apic.zig``, ``src/kernel/sched/smp.zig``, ``src/kernel/ipc/ring.zig``, ``src/kernel/arch/x86_64/idt.zig``

1. Architectural Axioms & Hardware Preemption
=============================================
This specification establishes preemptive scheduling and multi-core symmetric multiprocessing (SMP) across the MicrOS (µOS) microkernel. Cooperative fiber scheduling is replaced by hardware-enforced APIC timer interrupts, ensuring bounded worst-case execution time (WCET), starvation freedom, and linear compute scalability across physical CPU cores.

1.1 Preemption Axiom
--------------------
In a pure microkernel architecture hosting untrusted Ring 3 userland daemons and actors, cooperative scheduling is an unacceptable failure mode:

* **Starvation Immunity**: A malfunctioning or adversarial actor executing an unbounded loop (``while (true) {}``) cannot starve peer actors, the compositor (``gopd``), or the MicroShell (``msh``).
* **Hardware Quantum Enforcement**: The Local Advanced Programmable Interrupt Controller (LAPIC) timer generates periodic hardware interrupts at 1000Hz (1ms quantum) via IDT Vector ``0x20``.
* **Atomic Preemption Trapping**: The CPU hardware automatically clears the Interrupt Flag (``RFLAGS.IF = 0``), saves the user execution frame (``RIP``, ``CS``, ``RFLAGS``, ``RSP``, ``SS``), and switches to the per-core trusted kernel stack (``TSS.RSP0``).

2. Local APIC Architecture & Register Interface
===============================================
Every x86_64 CPU core possesses a dedicated Local APIC accessed via Memory-Mapped I/O (MMIO) or Model-Specific Registers (MSRs in x2APIC mode).

2.1 LAPIC Base Address Discovery & SIVR
---------------------------------------
The physical base address of the Local APIC is obtained from the ``IA32_APIC_BASE`` MSR (``0x1B``):

* **Base Physical Address**: Bits 12–51 identify the 4KB page frame (typically ``0xFEE0_0000``).
* **Global Enable Bit**: Bit 11 (``APIC_GLOBAL_ENABLE``) must be set.
* **Spurious Interrupt Vector Register (SIVR, Offset ``0x0F0``)**:
  - Bit 8 (``APIC_SOFTWARE_ENABLE``): Must be set to 1 to enable Local APIC message reception.
  - Bits 0–7: Spurious vector index (programmed to ``0xFF``).

2.2 Local APIC Timer Configuration
----------------------------------
The LAPIC timer operates in Periodic Mode to deliver consistent 1000Hz interrupts:

.. list-table::
   :widths: 20 25 55
   :header-rows: 1

   * - Offset
     - Register
     - Operational Semantics
   * - **``0x320``**
     - LVT Timer Register
     - Bits 17–18 = ``01b`` (Periodic Mode); Bits 0–7 = ``0x20`` (IDT Vector 32).
   * - **``0x3E0``**
     - Divide Configuration
     - Value ``0x03`` (Divide by 16) scales CPU core bus clock.
   * - **``0x380``**
     - Initial Count Register
     - Loaded with calibrated tick count; automatically reloaded on underflow.
   * - **``0x390``**
     - Current Count Register
     - Read-only decrementing hardware counter.
   * - **``0x0B0``**
     - End-Of-Interrupt (EOI)
     - Writing ``0x00`` signals interrupt completion to the APIC.

3. Preemptive Context Switch Frame Layout
=========================================
Upon receiving Vector ``0x20``, the microkernel captures the full execution context of the active actor.

3.1 Hardware & Software Context Frame
-------------------------------------
The complete saved context structure matches the 64-bit ABI register state:

.. code-block:: zig

   pub const ExecutionContext = extern struct {
       // Software-saved callee & scratch registers
       r15: u64,
       r14: u64,
       r13: u64,
       r12: u64,
       r11: u64,
       r10: u64,
       r9:  u64,
       r8:  u64,
       rbp: u64,
       rdi: u64,
       rsi: u64,
       rdx: u64,
       rcx: u64,
       rbx: u64,
       rax: u64,

       // Hardware-saved interrupt frame (pushed automatically by CPU)
       rip:    u64,
       cs:     u64,
       rflags: u64,
       rsp:    u64,
       ss:     u64,
   };

3.2 Assembly Preemption Handler
-------------------------------
The low-level ISR saves registers, switches to the microkernel scheduling context, and dispatches the next ready actor:

.. code-block:: nasm

   asm_apic_timer_entry:
       pushq %rax
       pushq %rbx
       pushq %rcx
       pushq %rdx
       pushq %rsi
       pushq %rdi
       pushq %rbp
       pushq %r8
       pushq %r9
       pushq %r10
       pushq %r11
       pushq %r12
       pushq %r13
       pushq %r14
       pushq %r15

       movq %rsp, %rdi            ; Pass ExecutionContext pointer as first C-ABI argument
       call kernel_timer_tick      ; Returns pointer to next ExecutionContext to restore

       movq %rax, %rsp            ; Switch stack pointer to next execution context
       
       ; Acknowledge APIC EOI before returning
       movq $0xFEE000B0, %rdi     ; LAPIC EOI register
       movl $0, (%rdi)
       
       popq %r15
       popq %r14
       popq %r13
       popq %r12
       popq %r11
       popq %r10
       popq %r9
       popq %r8
       popq %rbp
       popq %rdi
       popq %rsi
       popq %rdx
       popq %rcx
       popq %rbx
       popq %rax
       iretq

4. APIC INIT-SIPI-SIPI Multicore Bringup Protocol
=================================================
Secondary Application Processors (APs) are woken from low-power wait-for-SIPI states into 64-bit Long Mode.

4.1 Inter-Processor Interrupt (IPI) Sequence
--------------------------------------------
The Bootstrap Processor (BSP) programs the LAPIC Interrupt Command Register (ICR):

1. **INIT IPI (Assert)**: ICR programmed with Delivery Mode ``101b`` (INIT), Level ``1``, Trigger ``Edge``. Signals CPU reset state.
2. **Delay**: 10 millisecond delay via TSC/PIT calibration.
3. **INIT IPI (De-assert)**: ICR programmed with Level ``0`` (if required by hardware platform).
4. **Startup IPI (SIPI 1)**: ICR programmed with Delivery Mode ``110b`` (Startup) and Vector ``0x08`` (targeting physical address ``0x0000_8000``).
5. **Detection Delay**: 200 microsecond delay. If AP flag not asserted, BSP dispatches **SIPI 2**.

4.2 Real-Mode Trampoline Transition
-----------------------------------
The AP boot trampoline at ``0x8000`` executes a deterministic mode migration:

1. **Real Mode (16-bit)**: Disables interrupts (``cli``), establishes flat real-mode segment registers.
2. **Protected Mode (32-bit)**: Loads temporary 32-bit GDT, enables Protected Mode in ``CR0.PE``.
3. **Paging & Long Mode (64-bit)**:
   - Sets Physical Address Extension (``CR4.PAE = 1``).
   - Loads kernel PML4 physical base into ``CR3``.
   - Enables Long Mode in ``IA32_EFER.LME = 1``.
   - Enables Paging in ``CR0.PG = 1``.
   - Far-jumps into 64-bit code segment, initializing CPU-local TSS and per-core runqueue.

5. Lock-Free Per-Core Runqueues & Work-Stealing
===============================================
To prevent lock contention on multi-core hardware, each CPU core manages an autonomous circular runqueue.

5.1 Work-Stealing Protocol
--------------------------
* **Local Fast-Path**: Cores push and pop tasks locally from the tail of their own double-ended queue (deque) without cross-core cache invalidation.
* **Work-Stealing Slow-Path**: An idle core attempts to steal tasks from the head of a busy peer core's runqueue using atomic compare-and-swap (``@cmpxchgWeak``).
* **Worst-Case Execution Bound**: Steal attempts have an upper bound equal to ``active_cores - 1``; if no tasks are available, the core executes ``pause`` and enters low-power ``hlt`` waiting for an IPI or timer tick.

6. Multi-Producer Single-Consumer (MPSC) IPC Rings
==================================================
Milestone 22 introduced Single-Producer Single-Consumer (``SpscRingBuffer``). Under SMP, multiple Application Processors concurrently submit messages to shared userland daemon mailboxes.

6.1 Ticket-Allocated Ring Protocol
----------------------------------
The ``MpscRingBuffer`` provides high-throughput concurrent message submission:

* **Atomic Head Reservation**: Multiple submitting cores increment the write head atomically via ``@atomicRmw(usize, &head, .Add, 1, .seq_cst)``.
* **Slot Ticket Sequence**: Each slot maintains a monotonically increasing sequence generation counter.
* **Non-Blocking Ingress**: If the buffer is full, producers fail fast with ``error.BufferFull`` or cooperatively yield without acquiring kernel spinlocks.

7. Verification & Fault Containment Strategy
============================================
1. **Preemption Starvation Test**: Spawn an actor executing an infinite CPU loop (``while (true) {}``) in Ring 3. Verify that the 1000Hz APIC timer reliably interrupts execution and switches to the MicroShell actor within 2 milliseconds.
2. **Multi-Core Boot Validation**: Verify in QEMU SMP mode (``qemu-system-x86_64 -smp 4``) that all 4 cores successfully complete the INIT-SIPI-SIPI handshake, report online status over serial, and register into the SMP scheduler.
3. **MPSC Concurrency Stress**: Run concurrent multi-core message emission loops from 4 cores targeting a single receiver ring; verify zero dropped, corrupted, or out-of-order packets.
4. **Traceability Compliance**: Audited via ``./tools/micros-spec-trace.bash --check``.
