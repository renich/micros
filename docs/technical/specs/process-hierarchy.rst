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

* **Layer 0 (Microkernel Substrate)**: Ring 0 Zig implementation providing raw CPU fiber scheduling, PMM/VMM memory isolation, VirtIO drivers, SPSC IPC rings, capability checks, and the unified native C-ABI substrate (``src/kernel/abi.zig``). Exposes mechanism only; enforces zero UI or shell policies.
* **Layer 1 (Supervisor)**: Root userspace actor (``lib/macros/init.mx``, PID 1 / Actor 0) running in CSpace 0. Acts as the immortal Erlang-style hardware supervisor. Reads genesis payloads, spawns default user interfaces, and traps child faults and termination events.
* **Layer 2 (µShell)**: Primary system interface (``lib/macros/ush.mx``). Stream-oriented CLI and conversational dispatcher for humans and AI agents over UART serial console and terminal canvas. Handles command evaluation, telemetry queries, actor lifecycle management, CAS storage manipulation, and application dispatching.
* **Layer 3 (Sovereign Canvas & Display Server)**: Window compositor and GOP canvas server (``gopd`` / ``window_abi``). Manages tiled/floating window surfaces, visual layout, and double-buffered frame flushes.
* **Layer 4 (Sandboxed Guest Actors)**: Dynamically spawned userland applications (e.g. hypermedia viewer, editors, synthesized tools). Execute in sandboxed CSpaces with attenuated capabilities, instruction gas budgeting (G4), and content-addressed persistence (CAS).

2. Five-Layer Process Taxonomy
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
   | Layer 2: µShell (lib/macros/ush.mx, Stream / Prompt)        |
   | Line Editor, 7 Guest Verbs, Resident AI Dispatch, Telemetry |
   +------------------------------+------------------------------+
                                  | Manages & Composes
   +------------------------------v------------------------------+
   | Layer 3: Sovereign Canvas (gopd, Window Surface Manager)    |
   | Vector GOP Linear Surface, Window Clipping, Atomic Commit   |
   +------------------------------+------------------------------+
                                  | Sandboxes on Demand
   +------------------------------v------------------------------+
   | Layer 4: Sandboxed Guest Actors (Demand Synthesized / CAS)  |
   | Attenuated CSpace, Gas Metering, Merkle OCC Workspace       |
   +-------------------------------------------------------------+

3. Unified Native C-ABI Substrate (src/kernel/abi.zig)
======================================================
All capability invocations from the Macros runtime enter the microkernel through a standardized, typed ABI table registered with each actor's VM instance (24 core primitives):

* **Actor Lifecycle**: ``sys_actor_spawn``, ``sys_actor_terminate``, ``sys_actor_state``, ``sys_actor_set_budget``, ``sys_yield``.
* **IPC & Events**: ``sys_event_poll``, ``sys_ipc_recv``, ``sys_kbd_read``.
* **Content Storage (CAS)**: ``sys_cas_put``, ``sys_cas_get``, ``sys_cas_confirm_boot``.
* **Workspace Catalog**: ``sys_catalog_write``, ``sys_catalog_read``, ``sys_catalog_status``, ``sys_catalog_list``, ``sys_catalog_delete``.
* **Window Surface (Canvas)**: ``sys_window_create``, ``sys_window_close``, ``sys_window_focus``, ``sys_window_draw_rect``, ``sys_window_commit``.
* **Resident AI & Cluster**: ``sys_ai_prompt``, ``sys_peer_count``, ``sys_peer_info``.

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
               print("[init] Shell exited. Respawning...");
               ush_src = sys_bundle_read("ush.mx");
               child_id = sys_actor_spawn("ush", ush_src);
           } else if (st == 4) {
               print("[init] Shell faulted! Respawning...");
               ush_src = sys_bundle_read("ush.mx");
               child_id = sys_actor_spawn("ush", ush_src);
           } else if (st < 0) {
               print("[init] Shell missing. Respawning...");
               ush_src = sys_bundle_read("ush.mx");
               child_id = sys_actor_spawn("ush", ush_src);
           }
           sys_yield();
       }
   }

When the interactive shell terminates (voluntarily or via fault), the supervisor immediately detects state 5 or 4, reloads ``ush.mx`` from the genesis bundle, and reconstitutes the user session with zero kernel reboots.

5. Focus Arbitration & Terminal Ergonomics
==========================================
* **Serial / TTY Co-existence**: µShell (``ush.mx``) uses COM1 serial output and standard ANSI escape sequences for stream interaction.
* **Canvas Window Management**: Graphical applications execute as isolated window surfaces composed via ``sys_window_commit``.
* **Serene Return**: When a guest application actor exits, its window surface is closed cleanly and control returns instantly to the host shell session without display corruption.
