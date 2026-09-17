Milestone 9: The Sovereign Actor Harness & Self-Healing Multi-Actor Substrate
=============================================================================

:Objective: Deliver an AI-first, self-healing, multi-actor operating substrate and an interactive sovereign harness written in Macros. Enable dynamic actor spawning, attenuated capability delegation, hardware input IPC (PS/2 & serial), and zero-crash fault containment with bare-metal Erlang-style supervision.
:Status: Completed & Verified
:Specification: SPEC-TECH-HARNESS-001

Milestones & Deliverables
-------------------------

* **M9.1: Hardware Input & Key Event IPC (The Senses)**
  - Implement ``src/kernel/ipc/events.zig`` defining canonical ``KeyEvent``, ``KeyAction``, and ``KeyModifiers`` ABI structures.
  - Implement ``src/kernel/drivers/ps2_kbd.zig`` for the 8042 controller, translating Scancode Set 1 make/break codes without busy-waiting.
  - Hook IRQ 1 (IDT vector 33) and UART COM1 serial input to push 64-byte typed ``MessageFrame`` (event_signal) into Actor 0's input SPSC ring buffer without allocation.

* **M9.2: Multi-Actor Spawning & Capability Delegation (The Proliferation)**
  - Upgrade ``src/kernel/actor.zig`` with an Actor Registry supporting up to 64 concurrent isolated actors, lifecycle states (uninitialized, ready, running, paused, faulted, terminated), and supervisor relationships.
  - Add first-class ``actor_control`` capability to ``src/kernel/cap/capability.zig`` with explicit rights (READ, WRITE, GRANT, REVOKE, EXECUTE).
  - Implement capability attenuation and delegation protocols in ``src/kernel/cap/cspace.zig``, mathematically preventing privilege escalation.

* **M9.3: Dynamic Interactive Sovereign Harness in Macros (The Mind & Constructor)**
  - Implement ``lib/macros/harness.mx``: an interactive construction and introspection harness written entirely in self-hosted Macros.
  - Provide dual visual presentation: 1280x800 GOP vector canvas (status header, console canvas, actor/capability inspector, command prompt) and UART 16550 serial link.
  - Implement ``src/kernel/harness_bindings.zig`` bridging microkernel capabilities and actor operations to native Macros VM calls.

* **M9.4: Fault Containment & Actor Supervisor Protocol (The Self-Healing Immune System)**
  - Intercept CPU exceptions (#PF, #GP, #DE, #UD) in ``src/kernel/arch/x86_64/idt.zig`` for child actors (id > 0), suppressing microkernel panics.
  - Capture machine state into a structured ``FaultFrame`` and dispatch it as an IPC notification to the supervisor actor (Actor 0).
  - Implement supervisor self-healing policies in ``src/kernel/supervisor.zig`` (RESTART_IMMEDIATE, QUARANTINE, TERMINATE_AND_RECLAIM) to ensure continuous operation under faults.
