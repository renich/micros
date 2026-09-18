=====================================================
Process Hierarchy Decoupling & Actor Supervision Spec
=====================================================

:Document ID: SPEC-TECH-HIERARCHY-001
:Status: Approved
:Traced Stories: [US-REN-001], [US-REN-002], [US-REN-004], [US-GEM-009], [US-GEM-010]

1. Architectural Axioms & Purpose
=================================
This specification defines the decoupled 4-layer process hierarchy and Erlang-style supervision substrate for MicrOS (µOS) v0.1.0, eliminating monolithic boot-to-UI coupling and establishing clean separation of concerns between Ring 0 mechanisms, userspace supervisors, stream shells, and rich visual applications.

1.1 Decoupling Mechanism from Policy
------------------------------------
Prior to this architecture, the microkernel booted directly into a full-screen graphical workspace (`harness.mx`). Embedding a visual dashboard into the kernel initialization sequence violated the core microkernel axiom: *mechanism, not policy*.

The decoupled process hierarchy enforces four strict layers:

* **Layer 0 (Microkernel Substrate)**: Ring 0 Zig implementation providing raw CPU fiber scheduling, PMM/VMM memory isolation, VirtIO drivers, SPSC IPC rings, capability checks, and the unified native C-ABI substrate (`src/kernel/abi.zig`). Exposes mechanism only; enforces zero UI or shell policies.
* **Layer 1 (Supervisor)**: Root userspace actor (`lib/macros/init.mx`, PID 1 / Actor 0) running in CSpace 0. Acts as the immortal Erlang-style hardware supervisor. Reads genesis payloads, spawns default user interfaces, and traps child faults and termination events.
* **Layer 2 (MicroShell)**: Primary system interface (`lib/macros/msh.mx`). Dual-output terminal interface for humans and AI agents. Renders directly to the UEFI GOP linear framebuffer (`tty0`) while mirroring to the UART 16550 serial console (`ttyS0`). Handles command evaluation, telemetry queries, actor lifecycle management, CAS storage manipulation, and application dispatching.
* **Layer 3 (Interactive Studio)**: Visual IDE and GOP canvas workspace (`lib/macros/harness.mx`). Launched on demand from MicroShell (`msh> harness`), rendering vector telemetry and actor graphs on the 1280x800 framebuffer. Exits cleanly back to MicroShell via `exit`, restoring MicroShell's display.

2. Four-Layer Process Taxonomy
==============================

.. code-block:: text

   +-------------------------------------------------------------+
   | Layer 0: Microkernel Substrate (Ring 0 Zig, Mechanism Only) |
   | PMM, VMM, VirtIO, SPSC Rings, Hardware IDT, Native C-ABI   |
   +------------------------------+------------------------------+
                                  | Spawns
   +------------------------------v------------------------------+
   | Layer 1: Actor 0 Supervisor (lib/macros/init.mx, PID 1)     |
   | Immortal Supervisor Loop, Bundle Loader, Fault Recovery     |
   +------------------------------+------------------------------+
                                  | Spawns
   +------------------------------v------------------------------+
   | Layer 2: MicroShell (lib/macros/msh.mx, Dual GOP/TTY)       |
   | Line Editor, Builtin Dispatcher, Actor Manager, Framebuffer |
   +------------------------------+------------------------------+
                                  | Launches on Demand
   +------------------------------v------------------------------+
   | Layer 3: Interactive Studio (lib/macros/harness.mx)         |
   | Direct GOP Framebuffer Canvas, Visual Telemetry, Vector UI  |
   +-------------------------------------------------------------+

3. Unified Native C-ABI Substrate (src/kernel/abi.zig)
======================================================
All capability invocations from the Macros runtime enter the microkernel through a standardized, typed ABI table registered with each actor's VM instance:

* ``sys_actor_count() -> i64``: Total number of active actor domains in the registry.
* ``sys_actor_spawn(name: str) -> i64``: Spawns an actor domain by name.
* ``sys_actor_spawn_code(name: str, src: str) -> i64``: Compiles and spawns an isolated actor fiber.
* ``sys_actor_terminate(id: int) -> i64``: Requests cooperative termination of an actor domain.
* ``sys_actor_wait(id: int) -> bool``: Suspends the calling fiber until the target actor terminates or faults.
* ``sys_actor_state(id: int) -> i64``: Returns actor lifecycle state (0=uninitialized, 1=ready, 2=running, 3=paused, 4=faulted, 5=terminated, -1=invalid).
* ``sys_actor_name(id: int) -> str``: Retrieves the registered human-readable name of an actor.
* ``sys_fb_clear(color: int) -> void``: Sets the entire linear GOP framebuffer to a 32-bit ARGB color.
* ``sys_fb_draw_string(x: int, y: int, s: str, fg: int, bg: int) -> void``: Blits 8x8 font glyphs.
* ``sys_fb_draw_rect(x: int, y: int, w: int, h: int, color: int) -> void``: Blits solid color rectangle.
* ``sys_ipc_recv() -> str``: Pops messages from the actor's incoming SPSC ring buffer.
* ``sys_serial_write(s: str) -> void``: Emits text directly out the COM1 UART serial port.
* ``sys_serial_read() -> i64``: Non-blocking poll of COM1 UART input buffer.
* ``sys_kbd_read() -> i64``: Non-blocking poll of PS/2 keyboard scancode queue.
* ``sys_fault_count() -> i64``: Total number of hardware exceptions contained by the supervisor.
* ``sys_ai_prompt(prompt: str) -> str``: Synchronous inference request to resident AI over VirtIO/TLS.
* ``sys_ai_extract_code(resp: str) -> str``: Zero-allocation code block extraction.
* ``sys_ai_tool_call(resp: str) -> str``: Zero-allocation structured tool call parser and dispatcher.
* ``sys_cas_put(data: str) -> str``: Computes BLAKE3 hash and persists payload to VirtIO-Blk CAS.
* ``sys_cas_get(hex: str) -> str``: Fetches immutable payload from CAS by 64-character hex hash.
* ``sys_actor_persist(id: int) -> str``: Persists actor source snapshot to CAS root.
* ``sys_actor_spawn_cas(hex: str) -> i64``: Reconstitutes and spawns actor directly from CAS hash.
* ``sys_bundle_read(name: str) -> str``: Extracts payload directly from the genesis MCB bundle.
* ``sys_yield() -> void``: Yields CPU execution context to the next ready fiber in the scheduler.

4. Actor Lifecycle & Supervision Invariants
===========================================

4.1 State Transition Graph
--------------------------
Actor states follow an explicit, monotonically guarded lifecycle:

1. **Uninitialized (0)**: Allocated in CSpace, no execution thread.
2. **Ready (1)**: VM compiled and registered in scheduler queue.
3. **Running (2)**: Actively executing bytecode within a fiber context switch.
4. **Paused (3)**: Suspended awaiting IPC event or cooperative sleep.
5. **Faulted (4)**: Intercepted unhandled exception or crash; trapped by supervisor.
6. **Terminated (5)**: Normal exit via return opcode or explicit termination request.

4.2 Supervisor Self-Healing Loop (init.mx)
------------------------------------------
Actor 0 executes an immortal supervision loop:

.. code-block:: text

   fn supervisor_loop(child_id) {
       while (true) {
           st = sys_actor_state(child_id);
           if (st == 5) {
               print("[init] App 0 (msh) exited. Respawning shell...");
               msh_src = sys_bundle_read("msh.mx");
               child_id = sys_actor_spawn_code("msh", msh_src);
           } else if (st == 4) {
               print("[init] App 0 (msh) faulted! Respawning shell...");
               msh_src = sys_bundle_read("msh.mx");
               child_id = sys_actor_spawn_code("msh", msh_src);
           }
           sys_yield();
       }
   }

When the interactive shell terminates (voluntarily or via fault), the supervisor immediately detects state 5 or 4, reloads ``msh.mx`` from the genesis bundle, and reconstitutes the user session with zero kernel reboots.

5. Focus Arbitration & Terminal Ergonomics
==========================================
* **Serial / TTY Co-existence**: MicroShell (``msh.mx``) uses COM1 serial output and standard TTY escape sequences for line editing and prompt redraws.
* **Canvas Preemption**: When ``harness.mx`` is launched, it takes exclusive ownership of the GOP framebuffer, rendering vector graphs and the Actor Inspector.
* **Serene Return**: Upon entering ``exit`` in the harness, ``harness.mx`` executes ``sys_fb_clear(0)`` to wipe graphical artifacts and terminates its fiber. MicroShell resumes from ``sys_actor_wait``, announces return, and displays the standard ``msh>`` prompt.
