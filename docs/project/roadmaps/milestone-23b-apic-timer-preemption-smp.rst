Milestone 23b: Preemptive Symmetric Multiprocessing (SMP) & APIC Timer Substrate
================================================================================

:Objective: Eliminate single-core cooperative scheduling fragility by establishing hardware timer preemption (1000Hz quantum) via Local APIC interrupts and bootstrapping multi-core CPU processors via APIC INIT-SIPI-SIPI into a preemptive, lock-free work-stealing scheduler.
:Status: Scheduled
:Specification: SPEC-TECH-SMP-001
:Traced Stories: [US-REN-004], [US-REN-006], [US-GEM-001], [US-GEM-010]

Milestones & Deliverables
-------------------------

* **M23b.1: Local APIC Timer Hardware Preemption Engine**
   - Calibrate Local APIC timer using CPU TSC (Time Stamp Counter) / HPET.
   - Configure periodic timer interrupt mode at 1000 Hz (1ms quantum) routed through IDT vector ``0x20``.
   - Implement interrupt handler saving full CPU execution frame (``RAX`` through ``R15``, ``RFLAGS``, ``RSP``, ``RIP``).
   - Enforce preemption: context-switch running thread automatically when quantum expires without relying on cooperative yields.

* **M23b.2: APIC Multicore Bootstrap (INIT-SIPI-SIPI)**
   - Parse ACPI MADT (Multiple APIC Description Table) to discover available physical and logical CPU cores.
   - Allocate 16-bit real-mode trampoline page frame below 1 MiB boundary.
   - Transmit APIC IPI sequence: INIT -> 10ms delay -> Startup IPI (SIPI) -> 200µs delay -> SIPI.
   - Transition secondary Application Processors (APs) through Protected Mode into 64-bit Long Mode and initialize local GDT/TSS and IDT.

* **M23b.3: Per-Core Runqueues & Lock-Free Work-Stealing**
   - Establish per-core scheduler state structures with CPU affinity tracking.
   - Implement chase-lev lock-free work-stealing deques, allowing idle cores to steal threads from overloaded cores with zero global lock contention.
   - Enforce interrupt-safe locking discipline: mask interrupts (``cli`` / clear ``RFLAGS.IF``) before acquiring any kernel spinlock to eliminate deadlocks.

* **M23b.4: Multi-Producer Single-Consumer (MPSC) IPC Rings**
   - Extend ``src/kernel/ipc/ring.zig`` from SPSC to MPSC ring buffers.
   - Support concurrent multi-core message emission into service actor request queues using atomic compare-and-swap (CAS) head pointers and cacheline padding (64 bytes).
