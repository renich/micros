Milestone 8: Sovereign Capability Substrate & Genesis Actor
===========================================================

:Objective: Eliminate legacy POSIX abstractions (PIDs, integer file descriptors, ambient authority) from the microkernel, establishing the pure Object-Capability model (CSpace), typed IPC ring buffers, immutable capability bundles, and direct framebuffer grants.
:Status: Completed & Verified
:Specification: SPEC-TECH-CAP-001

Milestones & Deliverables
-------------------------

* **M8.1: The Capability Space (CSpace) & Actor Subsystem**
  - Implement ``src/kernel/cap/capability.zig`` with strongly typed ``CapType``, immutable rights bitmasks, and capability table representation.
  - Implement ``src/kernel/cap/cspace.zig`` for capability lookup, validation, delegation, and revocation.
  - Establish ``Actor`` structure (PML4 page table + CSpace + fiber execution context) in ``src/kernel/actor.zig``, completely replacing the concept of "PID 1" with **Actor 0 (Genesis Actor)**.

* **M8.2: Typed Lock-Free Shared-Memory IPC Rings**
  - Implement ``src/kernel/ipc/ring.zig`` providing zero-copy Single-Producer Single-Consumer (SPSC) ring buffers carrying 64-byte typed ``MessageFrame`` structures.
  - Replace POSIX text-stream buffers with binary event and capability transfer channels.

* **M8.3: Immutable Capability Bundle (MCB) Loader**
  - Define the MicrOS Capability Bundle (MCB) ABI in ``src/kernel/bundle.zig`` with magic ``0x4D494352_4F534D43`` and content-addressed manifest entries.
  - Implement ``tools/src/bundle.zig`` to package ``lib/macros/*.mx`` and bytecode into an immutable bundle.
  - Update ``boot.efi`` and ``boot_info.zig`` to pass the bundle extent directly as an unforgeable ``memory_extent`` capability to Actor 0.

* **M8.4: Direct Framebuffer Capability Delegation**
  - Interrogate UEFI Graphics Output Protocol (GOP) in ``boot.efi`` to acquire physical display geometry.
  - Register the physical framebuffer as a first-class ``framebuffer`` capability in Actor 0's CSpace.
  - Implement 2D vector/bitmap primitive rendering in ``src/kernel/fb.zig`` without Unix virtual terminal or tty layers.

* **M8.5: Sovereign Genesis Shell (msh) & Reactive Event Loop**
  - Refactor ``src/sys/hal_kernel.zig`` to route all I/O through Actor 0's capability table and IPC rings, purging all POSIX ``open/read/write/close/getpid`` stubs.
  - Boot the Macros Bytecode VM directly inside Actor 0, executing the Genesis Actor and launching ``msh`` as the interactive typed shell.
  - Implement end-to-end automated verification in ``tools/micros-runner.bash`` and execute the 3-round Crucible adversarial audit.
