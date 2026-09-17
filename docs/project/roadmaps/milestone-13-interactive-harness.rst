Milestone 13: Interactive Human-AI Construction Loop
=====================================================

:Objective: Transition MicrOS from a headless batch runner into an interactive, living operating system. Enable real-time keyboard and serial character ingress, a dynamic command evaluator in the Genesis Harness, direct natural-language prompt routing to the Resident AI, live actor spawning on bare-metal hardware, and interactive supervisor fault remediation.
:Status: In Progress
:Specification: SPEC-TECH-HARNESS-002

Milestones & Deliverables
-------------------------

* **M13.1: Hardware Input & Unified Keystroke Engine**
  - Implement non-blocking ``sys_serial_read_char()`` and ``sys_kbd_read_char()`` in ``src/kernel/harness_bindings.zig``.
  - Engineer unified character ingress and line editing buffer in ``lib/macros/harness.mx`` supporting printable ASCII, backspace deletion, newline submission, and cursor cell blitting on the 1280x800 GOP canvas.
  - Implement console viewport wrapping and vertical scrolling within the 800x680 console extent.

* **M13.2: Interactive Command Dispatcher & Resident AI Ingress**
  - Implement command tokenizer and dispatcher in ``lib/macros/harness.mx`` supporting built-ins (``help``, ``clear``, ``status``, ``actors``, ``kill``).
  - Implement ``sys_ai_prompt(prompt_str)`` native VM binding dispatching user prompts to ``global_ai_client`` over VirtIO-Net and TLS 1.3.
  - Render cognitive response text streams into the Console & Evaluator viewport with distinct cyan syntax coloring.

* **M13.3: Live Dynamic Actor Spawning & Inspector Feedback**
  - Implement ``sys_actor_spawn_code(name_str, source_str)`` native VM binding in ``src/kernel/harness_bindings.zig``.
  - Dynamically allocate isolated Actor Domains, configure CSpace capability boundaries, compile emitted Macros source into a new ``Chunk``, and schedule execution in the fiber Scheduler.
  - Implement dynamic visual updates for the Actor & Capability Inspector panel (x: 840..1260) reflecting active actor count, memory allocation, and capability delegations.

* **M13.4: Supervisor Telemetry & Interactive Self-Healing Loop**
  - Connect hardware IDT exception handler to Genesis Actor 0's IPC ring via ``FaultEvent`` frames.
  - Implement real-time fault notification in the Harness UI reporting crashed actor IDs and CPU fault vectors (#DE, #PF, #GP).
  - Implement ``ai heal actor <id>`` workflow submitting fault telemetry to the Resident AI to generate hotfix code and respawn the actor.

* **M13.5: End-to-End Headless & Interactive Verification**
  - Enhance ``tools/micros-runner.bash`` with an automated serial scripting test verifying interactive prompt entry, AI response reception, and dynamic actor spawning in QEMU.
  - Capture and verify GOP framebuffer output using ``tools/src/fb_verify.zig``.
  - Validate 100% bidirectional specification traceability (``micros-spec-trace.bash``) and zero Ten Commandments infractions (``micros-lint``).
