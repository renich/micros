=======================================================
Sovereign Interactive Harness & Co-Creation Engine Spec
=======================================================

:Document ID: SPEC-TECH-HARNESS-002
:Status: Approved
:Traced Stories: [US-REN-001], [US-REN-002], [US-REN-006], [US-GEM-001], [US-GEM-009], [US-GEM-010]

1. Architectural Axioms & Purpose
=================================
This specification defines the interactive execution architecture, hardware input unification, cognitive prompt routing, and live multi-actor spawning protocol for the Sovereign Genesis Harness in MicrOS (µOS).

1.1 Transformation from Batch Pipeline to Living System
-------------------------------------------------------
Prior to Milestone 13, MicrOS operated as a batch-execution pipeline: UEFI booted, initialized the Genesis Actor (Actor 0), rendered a static GOP canvas from ``harness.mx``, executed two hardcoded scripted turns with the Resident AI over TLS 1.3, and halted the CPU.

Milestone 13 converts MicrOS into an interactive, conversational, and self-healing operating system where:
* The human user sits at the physical console (or connects via headless COM1 serial).
* Natural language prompts and typed commands are entered directly into the Harness REPL.
* The Harness forwards prompts to the Resident AI subsystem via ``sys_ai_prompt()``.
* Emitted Macros code is compiled live into an isolated Actor domain via ``sys_actor_spawn_code()``.
* The newly created Actor runs cooperatively on bare-metal hardware, and its state/capabilities appear dynamically in the Actor Inspector panel.
* If an Actor crashes, the Erlang-style hardware supervisor intercepts the exception and alerts the Harness for interactive remediation.

1.2 Mechanism vs Policy
-----------------------
* **Microkernel Mechanism**: Raw x86_64 CPU fiber context switching, non-blocking PS/2 keyboard FIFO polling, COM1 UART register access, GOP framebuffer vector blitting, VirtIO-Net packet transport, and TLS 1.3 encryption.
* **Harness & AI Policy**: The Genesis Harness (written in Macros) dictates UI layout, command syntax, input line editing, prompt assembly, and error display. The Resident AI defines the system software ontology and implementation code.

2. Hardware Input & Keystroke ABI
=================================
The microkernel exposes non-blocking hardware polling primitives to the Macros runtime via native C-ABI bindings:

2.1 Serial Character Ingress
----------------------------
.. code-block:: zig

   pub fn sys_serial_read_char() i64

* **Behavior**: Polls COM1 UART Line Status Register (LSR, port ``0x3FD``). If bit 0 (Data Ready) is set, reads receiver buffer register (port ``0x3F8``) and returns ASCII byte (0..255).
* **Return Value**: Returns ASCII code on available character; returns ``-1`` when buffer is empty.

2.2 PS/2 Keyboard Character Ingress
-----------------------------------
.. code-block:: zig

   pub fn sys_kbd_read_char() i64

* **Behavior**: Polls PS/2 Status Register (port ``0x64``). If bit 0 (Output Buffer Full) is set, reads data port (port ``0x60``) and translates Make scancodes (Set 1) into ASCII using the kernel's keymap.
* **Return Value**: Returns ASCII code on key press; returns ``-1`` when no key event is pending.

3. Interactive Macros Shell Engine (harness.mx)
===============================================
The Genesis Harness replaces its one-shot ``harness_main()`` with an event loop executing natively inside Actor 0:

3.1 Line Editing & Rendering Invariants
---------------------------------------
* **Line Buffer**: 256-byte internal character array tracking cursor position.
* **Printable ASCII**: Chars in range ``0x20..0x7E`` appended to buffer and blitted at current cursor coordinates.
* **Backspace (`0x08` / `0x7F`)**: Decrements cursor, draws background color over character cell, and clears terminal index.
* **Enter (`\r` / `\n`)**: Submits command line for evaluation and advances vertical cursor.
* **Viewport Scrolling**: When cursor y exceeds 680px, the console window clears and resets to top (y=220px).

3.2 Command Grammar
-------------------
The interactive prompt ``macros>`` evaluates the following command grammar:

.. code-block:: text

   command   := built_in | ai_prompt | macros_eval
   built_in  := "help" | "clear" | "status" | "actors" | "kill" <id>
   ai_prompt := "ai" <text>
   macros_eval := <expression>

* ``help``: Displays supported commands and AI prompt syntax.
* ``status``: Prints active actor count, total memory usage, and fault count.
* ``actors``: Lists all registered actors and their execution states.
* ``clear``: Blits background color over the Console & Evaluator viewport.
* ``ai <prompt>``: Dispatches natural language instructions to the Resident AI.

4. Resident AI Cognitive Stream Binding
=======================================
The microkernel bridges the Macros VM directly to the network AI client:

.. code-block:: zig

   pub fn sys_ai_prompt(prompt_str: []const u8) []const u8

1. Validates that the active Actor possesses the ``network_egress`` capability.
2. Formats HTTP/1.1 POST payload with authentication header and system instruction.
3. Dispatches request over TCP/TLS 1.3 to the configured endpoint (Gemini, OpenAI, Anthropic, or local/mock).
4. Extracts response text from the JSON cognitive stream into a persistent buffer.
5. Returns string pointer to the Macros VM.

5. Dynamic Actor Spawning & Capability Delegation
=================================================
When the Resident AI returns executable code in response to a user prompt, the Harness invokes:

.. code-block:: zig

   pub fn sys_actor_spawn_code(name_str: []const u8, source_str: []const u8) i64

1. Verifies that the caller possesses ``Rights.SPAWN_ACTOR`` in its CSpace.
2. Allocates next sequential Actor ID (e.g. Actor 1, Actor 2) and Domain structures.
3. Compiles the Macros source code into a new ``Chunk`` using the in-kernel compiler.
4. Initializes an isolated ``VM`` instance with independent heap and stack.
5. Grants attenuated capability rights:
   * ``CapType.framebuffer``: restricted to assigned window coordinates.
   * ``CapType.ipc_channel``: point-to-point ring buffer to Actor 0.
6. Registers the Actor in ``global_registry`` and queues its root fiber into the Scheduler.
7. Triggers visual redraw of the Actor & Capability Inspector panel.

6. Supervisor Telemetry & Interactive Self-Healing Loop
=======================================================
1. If a spawned Actor triggers an unhandled CPU exception (e.g., divide-by-zero or unmapped address):
   * Hardware IDT intercepts the fault and stores register context into ``FaultFrame``.
   * Supervisor marks the faulting Actor as ``ActorState.faulted`` and suspends its fiber.
   * A ``FaultEvent`` frame is placed onto Actor 0's IPC ring.
2. On next iteration of the Harness event loop, the fault is displayed in the Console:

   .. code-block:: text

      [SUPERVISOR] Actor 1 (worker) faulted with #DE (Divide Error).
      Type 'ai heal actor 1' to generate autonomous patch.

3. Entering ``ai heal actor 1`` submits the ``FaultFrame`` telemetry and original source code to the AI.
4. The AI returns corrected source code, which the Harness hot-reloads into the Actor domain.

7. Verification & Quality Gates
===============================
1. **Unit Test Gate**: 100% pass rate in ``zig build test`` for all input and spawning logic.
2. **Ten Commandments Compliance**: Function lengths <= 40 lines, file lengths <= 1000 lines, nesting depth <= 3, zero libc, explicit allocators.
3. **Headless Sentinel Verification**: ``micros-runner.bash`` scripts serial commands to the harness, asserting automated actor creation and status output.
4. **Visual Canvas Verification**: ``micros-fb-verify`` validates framebuffer console text and inspector panel rendering.
5. **Traceability**: All referenced user stories verified by ``micros-spec-trace.bash``.
