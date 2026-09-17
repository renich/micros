==================================================
Sovereign Actor Harness & Supervisor Protocol Spec
==================================================

:Document ID: SPEC-TECH-HARNESS-001
:Status: Approved
:Traced Stories: [US-REN-001], [US-REN-006], [US-REN-008], [US-GEM-009], [US-GEM-010]

1. Architectural Axioms
=======================
MicrOS (µOS) eradicates ambient authority, Unix terminal line disciplines, and fatal kernel panics caused by child processes. The execution environment consists of an isolated hierarchy of actors communicating exclusively through typed lock-free IPC rings and governed by an Erlang-style supervisor protocol on bare metal.

1.1 Zero Ambient Input & Typed Events
-------------------------------------
Legacy OS models pass untyped byte streams through virtual terminal emulators and pseudo-terminals (PTYs). MicrOS maps bare-metal input hardware (PS/2 keyboard controller and UART 16550 serial FIFO) directly to typed binary event frames (``KeyEvent``). These frames are transferred without heap allocation into the recipient actor's SPSC input ring.

1.2 Multi-Actor Capability Delegation
-------------------------------------
Each actor possesses an independent Capability Space (``CSpace``) and private address space. Actors can spawn child actors only if they hold an ``actor_control`` capability. Resources (memory slices, IPC rings, display extents) are delegated strictly with attenuated rights, mathematically preventing privilege escalation.

1.3 Fault Containment & Autonomous Self-Healing
-----------------------------------------------
Child actor exceptions (Page Faults, General Protection Faults, Divide Errors) are intercepted by the microkernel's Interrupt Descriptor Table (IDT). The microkernel captures the CPU state into a ``FaultFrame``, suspends the faulting actor, and transmits a fault notification frame to its designated supervisor actor. The supervisor applies an automated recovery policy without disrupting other actors or the microkernel.

2. Hardware Input & Key Event ABI
=================================

2.1 Key Event Structure
-----------------------
Input events are represented as an 8-byte packed structure:

.. code-block:: zig

   pub const KeyAction = enum(u8) {
       press = 0x01,
       release = 0x02,
       repeat = 0x03,
   };

   pub const KeyModifiers = packed struct(u8) {
       shift: bool = false,
       ctrl: bool = false,
       alt: bool = false,
       caps: bool = false,
       super: bool = false,
       _reserved: u3 = 0,
   };

   pub const KeyEvent = extern struct {
       scancode: u8,
       action: KeyAction,
       modifiers: KeyModifiers,
       ascii: u8,
       keycode: u16,
       reserved: u16 = 0,
   };

2.2 PS/2 8042 Controller Protocol
---------------------------------
- Data Port: ``0x60``
- Status/Command Port: ``0x64``
- Interrupt: IRQ 1 (mapped to IDT vector 33).
- State Machine: Tracks 1-byte and 2-byte (``0xE0`` extended) Scancode Set 1 make/break sequences, updating modifier bits on press/release of Shift, Ctrl, Alt, and CapsLock.

3. Actor Model & Lifecycle Specification
========================================

3.1 Actor States
----------------
An actor exists in one of six deterministic states:

- ``uninitialized``: Slot allocated but memory/CSpace unassigned.
- ``ready``: Initialized with valid entry point, awaiting fiber scheduling.
- ``running``: Currently actively executing on a CPU fiber.
- ``paused``: Temporarily suspended by supervisor command.
- ``faulted``: CPU exception trapped; awaiting supervisor remediation.
- ``terminated``: Halted; capabilities revoked and memory extents reclaimed.

3.2 First-Class ``actor_control`` Capability
--------------------------------------------
- Type: ``CapType.actor_control``
- Object ID: Target Actor ID (1..63).
- Rights:
  - ``Rights.READ`` (0x0001): Inspect actor state, execution counters, and CSpace size.
  - ``Rights.WRITE`` (0x0002): Pause or resume execution.
  - ``Rights.GRANT`` (0x0004): Delegate control capability to another actor.
  - ``Rights.REVOKE`` (0x0008): Terminate actor and reclaim resources.
  - ``Rights.EXECUTE`` (0x0010): Step or schedule actor fiber.

4. Fault Containment & Supervisor Protocol
==========================================

4.1 Fault Frame ABI
-------------------
When an architectural exception occurs in an actor with ``id > 0``, the CPU context is serialized into a 32-byte ``FaultFrame``:

.. code-block:: zig

   pub const FaultFrame = extern struct {
       actor_id: u32,
       vector: u16,
       error_code: u16,
       rip: u64,
       rsp: u64,
       cr2: u64,
       rflags: u64,
   };

4.2 Supervisor Recovery Policies
--------------------------------
The supervisor actor receives the ``FaultFrame`` via its supervisor IPC ring and executes one of three recovery policies:

1. **RESTART_IMMEDIATE**: Resets the actor's fiber stack pointer to its entry trampoline, clears transient registers, resets execution state to ``ready``, and re-queues it for scheduling.
2. **QUARANTINE**: Holds the actor in the ``faulted`` state, preserving its memory and stack for interactive inspection via the harness inspector.
3. **TERMINATE_AND_RECLAIM**: Revokes all capabilities held in the actor's CSpace, returns physical memory extents to the PMM, and frees the actor registry slot.

5. Dynamic Interactive Sovereign Architecture
==============================================
Actor 0 runs ``lib/macros/init.mx`` as the root system supervisor, launching MicroShell (``lib/macros/msh.mx``) as App 0, with the interactive visual studio (``lib/macros/harness.mx``) available on demand as App 1:

- **1280x800 Vector Canvas**: Real-time multi-pane display in App 1 rendering substrate status, interactive command console, active actor table, and capability inspector.
- **Serial Automation Link**: Structured bidirectional channel over COM1 for autonomous AI agent inspection and headless verification in MicroShell (App 0).
- **Construction Commands**: ``status``, ``actors``, ``spawn``, ``store``, ``fetch``, ``persist``, ``spawn_cas``, ``ai``, ``harness``, ``kill``, ``clear``, and ``help``.
