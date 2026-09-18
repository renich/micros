Phase 6: Pure Microkernel Hardware Excision & Preemptive Multiprocessing (SMP)
=============================================================================

:Objective: Complete the architectural excision of all hardware device drivers, filesystems, and display management from Ring 0 into isolated Ring 3 userland service actors, enforce true hardware privilege separation (TSS, CR3, syscall/sysret), and establish hardware APIC timer preemption across symmetric multi-core CPUs.
:Status: Active Target
:Specifications: `SPEC-TECH-CAP-002`, `SPEC-TECH-SMP-001`, `SPEC-TECH-COMPOSITOR-002`, `SPEC-TECH-STORAGE-002`, `SPEC-TECH-MIN-001`
:Critical Path: M23a -> M23b -> M24 -> M25 -> M26

Milestones & Deliverables
-------------------------

* **Milestone 23a: Hardware Ring 3 & Syscall Substrate** [COMPLETED]
   - **TSS Descriptor & Interrupt Stacks**: Implement 64-bit Task State Segment (TSS) in ``src/kernel/arch/x86_64/gdt.zig`` with dedicated per-core ``RSP0`` kernel stacks and execute the ``ltr`` instruction.
   - **Fast Syscall ABI**: Configure x86_64 Model-Specific Registers (``EFER.SCE``, ``STAR``, ``LSTAR``, ``SFMASK``) to handle fast userland ``syscall`` and ``sysretq`` transitions.
   - **Per-Actor Address Spaces**: Implement isolated 4-level CR3 virtual address spaces with strict User/Supervisor bit protection (preventing Ring 3 code from accessing kernel virtual memory).
   - **Blocked By**: Phase 5 completion.
   - **Unblocks**: M23b, M24, M25.

* **Milestone 23b: Preemptive Symmetric Multiprocessing (SMP) & APIC Timer Substrate** [COMPLETED]
   - **Local APIC Timer Preemption**: Program Local APIC timer for periodic hardware interrupts (1000Hz quantum) via IDT vector ``0x20``.
   - **Preemptive Context Switching**: Save and restore full CPU register state (``pushaq``/``popaq``, ``iretq``) on timer ticks, eliminating cooperative scheduling starvation.
   - **APIC INIT-SIPI-SIPI Multicore Bringup**: Bootstrap secondary Application Processors (APs) into 64-bit Long Mode and establish per-core runqueues with lock-free work-stealing.
   - **Multi-Producer Single-Consumer (MPSC) IPC Rings**: Expand ``src/kernel/ipc/ring.zig`` to support concurrent multi-core message submission to userland service actors.
   - **Blocked By**: M23a.
   - **Unblocks**: M24, M25.

* **Milestone 24: Pure Microkernel Compositor & Input Decoupling (gopd)** [COMPLETED]
   - **Display Server Actor (gopd)**: Migrate GOP linear framebuffer backbuffer mapping and AABB damage tracking out of Ring 0 into ``src/userland/gopd/gopd.zig``.
   - **Framebuffer MMIO Delegation**: Delegate physical VRAM frame mapping via capability primitives (``sys_frame_info``) without ambient kernel authority.
   - **Unified Pointer & Keyboard Ingress**: Implement PS/2 mouse packet decoding and baseline xHCI USB HID pointer/keyboard parsing in userland.
   - **Blocked By**: M23b.
   - **Unblocks**: M25, Phase 7 (UI Engine).

* **Milestone 25: Pure Microkernel Storage Decoupling (storaged)** [ACTIVE]
   - **Storage Service Actor (storaged)**: Migrate PCIe NVMe 1.4, VirtIO-Blk, GPT partition parsing, FAT32 ESP handling, and BLAKE3 CAS into ``src/userland/storaged/storaged.zig``.
   - **DMA Pinning & Memory Validation**: Implement ``sys_dma_pin`` capability syscall validating physical page frames and building hardware PRP lists safely without kernel compromise.
   - **Hardware Controller Reset & Recovery**: Implement automatic hardware controller re-initialization (``CC.EN = 0`` -> ``CSTS.RDY == 0``) and in-flight request replay upon driver fault restart.
   - **Blocked By**: M23b, M24.
   - **Unblocks**: M26, Phase 8 (P2P CAS).

* **Milestone 26: Formal Microkernel Minimality Audit & Silicon Validation** [SCHEDULED]
   - **Architectural Purity Verification**: Formally audit Ring 0 microkernel core; verify zero device drivers, zero network stacks, zero filesystems, and zero floating-point operations in Ring 0 (< 2,000 LOC safety ceiling).
   - **Physical Bare-Metal Silicon Validation**: Deploy and validate live boot, SMP execution, and driver stability on physical x86_64 server hardware and workstations.
   - **Blocked By**: M24, M25.
   - **Unblocks**: Phase 7, Phase 8, Phase 9.
