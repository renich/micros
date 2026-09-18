========================================================================
Hardware Ring 3 Privilege Isolation & Fast Syscall Substrate (µOS)
========================================================================

:Document ID: SPEC-TECH-CAP-002
:Status: Approved
:Traced Stories: [US-REN-004], [US-REN-006], [US-GEM-001], [US-GEM-010]
:Parent Architecture: `SPEC-TECH-CAP-001`, `SPEC-TECH-SYS-001`
:Module Targets: ``src/kernel/arch/x86_64/gdt.zig``, ``src/kernel/arch/x86_64/syscall.zig``, ``src/kernel/mem/vmm.zig``, ``src/kernel/actor.zig``

1. Architectural Axioms & Hardware Privilege Separation
=======================================================
This specification formalizes the transition of MicrOS (µOS) from cooperative Ring 0 fiber execution into authentic hardware CPU privilege separation on x86_64. Ring 0 is restricted to microkernel primitives; all userland service daemons (``netd``, ``aid``, ``storaged``, ``gopd``) and application actors execute strictly in Ring 3 (User Mode).

1.1 The Hardware Privilege Axiom
--------------------------------
Software-enforced isolation within a shared Ring 0 address space provides no protection against rogue pointers, stack corruption, or malicious machine instructions:

* **Hardware Boundary**: Ring 3 code cannot execute privileged CPU instructions (``cli``, ``sti``, ``hlt``, ``in``, ``out``, ``lidt``, ``lgdt``, ``ltr``, or ``mov cr3``). Any attempt triggers an immediate hardware General Protection Fault (``#GP``, Vector 13).
* **Virtual Memory Protection**: The 4-level paging directory (PML4) marks kernel memory pages with the Supervisor bit (``U/S = 0``). Ring 3 code cannot read, write, or execute kernel higher-half virtual addresses (``0xFFFF_8000_0000_0000``).
* **Unforgeable Stack Switch**: Transitions from Ring 3 to Ring 0 (via hardware interrupts or ``syscall``) atomically switch the CPU stack pointer to a trusted, kernel-owned stack defined in the Task State Segment (``RSP0``), eliminating user-controlled kernel stack corruption.

2. 64-Bit Task State Segment (TSS) Specification
================================================
In x86_64 Long Mode, task switching via hardware TSS is obsolete, but the TSS remains mandatory for defining privilege-level stack switches (``RSP0``) and the Interrupt Stack Table (IST).

2.1 TSS Structure Layout
------------------------
The TSS structure is defined as an exact 104-byte packed structure:

.. code-block:: zig

   pub const TaskStateSegment = extern struct {
       reserved0: u32 = 0,
       rsp0: u64 align(8),       // Kernel stack pointer for Ring 3 -> Ring 0 transitions
       rsp1: u64 = 0,
       rsp2: u64 = 0,
       reserved1: u64 = 0,
       ist1: u64 = 0,            // Double Fault (#DF) dedicated stack
       ist2: u64 = 0,            // Non-Maskable Interrupt (NMI) dedicated stack
       ist3: u64 = 0,            // Machine Check (#MC) dedicated stack
       ist4: u64 = 0,
       ist5: u64 = 0,
       ist6: u64 = 0,
       ist7: u64 = 0,
       reserved2: u64 = 0,
       reserved3: u16 = 0,
       iomap_base: u16 = @sizeOf(TaskStateSegment), // Set past TSS limit to disable I/O bitmap
   };

2.2 GDT TSS Descriptor & ltr Invocation
---------------------------------------
In 64-bit Long Mode, the TSS descriptor is a 16-byte (128-bit) expanded GDT entry:

.. code-block:: zig

   pub const TssDescriptor = extern struct {
       limit_low: u16,
       base_low: u16,
       base_mid: u8,
       access: u8 = 0x89,       // Present, DPL=0, Type=9 (64-bit TSS Available)
       flags: u8 = 0x00,
       base_high: u8,
       base_upper: u32,
       reserved: u32 = 0,
   };

During bootstrap, the CPU executes ``ltr %ax`` loading the TSS selector into the Task Register (``TR``).

3. Fast Syscall ABI (LSTAR / STAR) Specification
================================================
MicrOS utilizes the high-performance x86_64 ``syscall`` and ``sysretq`` instructions, completely bypassing legacy interrupt gate latency (``int 0x80``).

3.1 Model-Specific Register (MSR) Configuration
-----------------------------------------------
The microkernel programs the following MSRs during core initialization:

1. **``IA32_EFER`` (MSR ``0xC0000080``)**:
   - Sets Bit 0 (``SCE`` - System Call Enable) to enable execution of ``syscall``/``sysret``.
2. **``IA32_STAR`` (MSR ``0xC0000081``)**:
   - Bits 32–47: Kernel Segment Base (``0x0008`` - Kernel CS ``0x08``, Kernel SS ``0x10``).
   - Bits 48–63: User Segment Base (``0x0018`` - User CS32/SS ``0x20``, User CS64 ``0x28``).
3. **``IA32_LSTAR`` (MSR ``0xC0000082``)**:
   - Target linear RIP address of the low-level assembly syscall handler (``asm_syscall_entry``).
4. **``IA32_SFMASK`` (MSR ``0xC0000084``)**:
   - Bitmask of RFLAGS bits to clear atomically upon entry (masks ``IF`` [Interrupt Flag], ``TF``, and ``DF``).

3.2 Register Calling Convention
-------------------------------
Syscall parameters adhere to the System V x86_64 OS Calling Convention:

.. list-table::
   :widths: 25 75
   :header-rows: 1

   * - Register
     - Semantic Role
   * - **``RAX``**
     - Syscall Number (Input) / Return Code or Status (Output)
   * - **``RDI``**
     - Parameter 1 (Capability Index / Handle)
   * - **``RSI``**
     - Parameter 2 (Buffer Pointer / Argument 1)
   * - **``RDX``**
     - Parameter 3 (Length / Argument 2)
   * - **``R10``**
     - Parameter 4 (Argument 3 - Replaces RCX per AMD64 syscall specification)
   * - **``R8``**
     - Parameter 5 (Argument 4)
   * - **``R9``**
     - Parameter 6 (Argument 5)
   * - **``RCX``**
     - Saved User ``RIP`` (Hardware clobbered by ``syscall``)
   * - **``R11``**
     - Saved User ``RFLAGS`` (Hardware clobbered by ``syscall``)

3.3 Low-Level Assembly Syscall Trampoline
-----------------------------------------
The assembly entry sequence enforces unforgeable stack isolation:

.. code-block:: nasm

   asm_syscall_entry:
       swapgs                     ; Swap GS to access CPU-local kernel structure
       mov [gs:USER_RSP_OFFSET], rsp ; Save untrusted user stack pointer
       mov rsp, [gs:KERNEL_RSP_OFFSET] ; Switch to trusted kernel stack
       
       ; Push execution context
       push rcx                   ; User RIP
       push r11                   ; User RFLAGS
       push rbp
       push rbx
       push r12
       push r13
       push r14
       push r15
       
       ; Call C-ABI capability dispatcher
       mov rcx, r10               ; Map arg 4 to standard ABI rcx
       call kernel_syscall_dispatch
       
       ; Restore execution context
       pop r15
       pop r14
       pop r13
       pop r12
       pop rbx
       pop rbp
       pop r11                    ; Restore User RFLAGS
       pop rcx                    ; Restore User RIP
       
       mov rsp, [gs:USER_RSP_OFFSET] ; Restore untrusted user stack
       swapgs
       sysretq                    ; Return to Ring 3 (CPL=3)

4. Per-Actor 4-Level CR3 Virtual Address Spaces
===============================================
Every Ring 3 actor receives a distinct PML4 page directory.

4.1 Address Space Memory Map
----------------------------
* **``0x0000_0000_0000_0000`` to ``0x0000_7FFF_FFFF_FFFF`` (Lower Half - Userland)**:
  - Mapped with ``PAGE_USER`` (``U/S = 1``).
  - Contains actor's code (``.text``, RX), read-only constants (``.rodata``, R), data/heap (RW), and user stack (RW).
  - Isolated per actor; no actor can view or mutate a peer actor's private lower half.
* **``0xFFFF_8000_0000_0000`` to ``0xFFFF_FFFF_FFFF_FFFF`` (Upper Half - Microkernel)**:
  - Mapped with ``PAGE_SUPERVISOR`` (``U/S = 0``).
  - Higher-Half Direct Map (HHDM), kernel text, stack, and PMM structures.
  - Shared across all PML4s for fast context switching, but hardware-protected against Ring 3 access.

5. Verification & Fault Containment Strategy
============================================
1. **Privileged Instruction Traps**: Execute a test actor in Ring 3 that attempts ``cli``, ``hlt``, and ``mov cr3``. The CPU must trigger vector 13 (``#GP``); the kernel terminates the faulting actor cleanly without crashing.
2. **Supervisor Page Access Traps**: Execute a test actor attempting to read ``0xFFFF_8000_0000_0000``. The CPU must trigger vector 14 (``#PF`` with User/Protection fault error code).
3. **Stack Swap Verification**: Verify that during a syscall loop, kernel execution never uses the userland stack pointer, preventing user-space stack smash exploits.
4. **Syscall Fuzzing**: Stream invalid capability handles, out-of-range syscall numbers, and unaligned buffer addresses through ``micros-telem``; all must return typed capability errors (e.g. ``CapabilityDenied``, ``InvalidHandle``) without panicking Ring 0.
