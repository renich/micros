===============================================================
Milestone 15b: Process Hierarchy Decoupling & Actor Supervision
===============================================================

:Objective: Decouple the monolithic boot-to-UI bootstrap flow into a modular 4-layer process taxonomy (Microkernel -> Actor 0 init -> App 0 msh -> App 1 harness). Implement a unified native C-ABI substrate (``src/kernel/abi.zig``), immortal userspace Actor 0 supervisor (``lib/macros/init.mx``), stream-oriented App 0 MicroShell (``lib/macros/msh.mx``), on-demand visual workspace App 1 (``lib/macros/harness.mx``), and monotonic actor lifecycle state management.
:Status: Completed & Verified
:Specification: SPEC-TECH-HIERARCHY-001

Milestones & Deliverables
-------------------------

* **M15b.1: Unified Native C-ABI Substrate (src/kernel/abi.zig)**
   - Consolidate microkernel capability bindings into a single typed table exposing 22 syscalls to the Macros VM runtime.
   - Refactor ``src/kernel/harness_bindings.zig`` into a backward-compatible delegation layer forwarding to ``src/kernel/abi.zig``.
   - Wire capability context containing actor registry, supervisor domain, GOP framebuffer, VirtIO block device, and CAS engine.

* **M15b.2: Immortal Actor 0 Supervisor (lib/macros/init.mx)**
   - Implement PID 1 root actor running in CSpace 0.
   - Load ``msh.mx`` from the genesis MCB bundle and launch App 0 in an isolated child actor domain.
   - Execute an immortal Erlang-style supervision loop polling ``sys_actor_state()``.
   - Trap child actor termination (state 5) and crash faults (state 4), auto-respawning ``msh`` without kernel reboots.

* **M15b.3: App 0 MicroShell (lib/macros/msh.mx)**
   - Implement stream-first interactive CLI for human and AI interaction.
   - Provide standard command suite: ``help``, ``status``, ``actors``, ``clear``, ``kill``, ``spawn``, ``store``, ``fetch``, ``persist``, ``spawn_cas``, ``ai``, ``harness``, and ``exit``.
   - Implement character echo, backspace handling, and robust CRLF sequence filtering over COM1 serial.

* **M15b.4: App 1 Interactive Studio & Clean Focus Arbitration (lib/macros/harness.mx)**
   - Transform the visual harness into an application launched on demand via ``msh> harness``.
   - Render GOP vector status canvas and live Actor Inspector upon activation.
   - Provide clean return to MicroShell via ``exit``: wipe GOP framebuffer via ``sys_fb_clear(0)``, terminate actor fiber, and yield serial console back to ``msh``.

* **M15b.5: Kernel Lifecycle State Machine & Bare-Metal Verification**
   - Introduce ``ActorThreadContext`` in ``src/kernel/main.zig`` tracking actor lifecycle transitions (``running`` -> ``terminated`` or ``faulted``).
   - Enable ``sys_actor_wait()`` to reliably synchronize fiber completion.
   - Update genesis bundle packaging in ``GNUmakefile`` to include ``init.mx``, ``msh.mx``, and ``harness.mx``.
   - Verify complete interactive session and supervisor recovery in QEMU UEFI environment.
