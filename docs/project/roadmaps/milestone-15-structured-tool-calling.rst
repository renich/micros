Milestone 15: Typed Structured Tool Calling Substrate
=====================================================

:Objective: Transition Resident AI communication from brittle markdown and reStructuredText string parsing into a typed, deterministic function and tool calling protocol. Implement zero-allocation streaming JSON parsing for tool requests, static compile-time tool schemas matching OpenAI and Gemini specifications, capability-gated tool execution, and bidirectional AI-to-kernel semantic dispatch.
:Status: Planned
:Specification: SPEC-TECH-TOOL-001

Milestones & Deliverables
-------------------------

* **M15.1: Freestanding Tool Definition & Schema Registry**
   - Implement ``src/kernel/ai/tools.zig`` defining strongly typed tool declarations without external schema dependencies.
   - Define canonical tool signatures:
      - ``spawn_actor(name: []const u8, source: []const u8) -> u32``
      - ``grant_capability(target_actor: u32, cap_type: u16, rights: u32) -> bool``
      - ``write_storage(payload: []const u8) -> [64]u8``
      - ``read_storage(hex_hash: [64]u8) -> []const u8``
      - ``draw_canvas(x: u32, y: u32, w: u32, h: u32, color: u32) -> void``
      - ``query_telemetry() -> TelemetrySnapshot``
   - Generate static JSON tool definitions at compile time adhering to standard function calling specifications for Gemini (``functionDeclarations``) and OpenAI (``tools`` array).

* **M15.2: Zero-Allocation Streaming Tool Call Parser**
   - Implement a freestanding, zero-allocation streaming JSON parser in ``src/kernel/ai/tool_parser.zig`` to extract tool names and JSON argument payloads from HTTP/TLS response chunks.
   - Guard against unbounded nesting and buffer exhaustion with mathematical depth limits (nesting depth <= 3).
   - Support both single and batched tool calls emitted by Resident AI providers.

* **M15.3: Sovereign Tool Dispatcher & CSpace Security Gate**
   - Implement ``src/kernel/ai/dispatcher.zig`` bridging parsed tool calls directly to kernel mechanisms.
   - Enforce mandatory capability checking in the caller's CSpace before executing tool actions:
      - ``spawn_actor`` requires ``Rights.SPAWN``.
      - ``grant_capability`` requires ``Rights.GRANT`` and strictly enforces attenuation (no rights escalation).
      - ``write_storage`` requires ``Rights.STORAGE_WRITE``.
      - ``read_storage`` requires ``Rights.STORAGE_READ``.
   - Return structured tool execution results (success status, emitted values, or error codes) formatted for ingestion in subsequent LLM conversational turns.

* **M15.4: Harness Integration & Bidirectional Construction Loop**
   - Update ``lib/macros/harness.mx`` and ``src/kernel/harness_bindings.zig`` to expose tool-enabled prompts.
   - Enable autonomous multi-turn construction: when a user enters ``ai build monitoring dashboard``, the Resident AI can emit sequential tool calls (allocating canvas regions, spawning worker actors, and reading telemetry) without intermediary human intervention.
   - Display real-time tool execution logs in the Harness UI telemetry viewport.

* **M15.5: Adversarial Verification & Tool Call Test Suite**
   - Implement unit tests covering valid tool serialization, streaming parameter extraction, and malformed JSON recovery.
   - Enforce Crucible Protocol verification against malicious tool injection attacks: unverified capability grants, memory boundary breaches, and unauthorized actor termination.
   - Update ``tools/micros-runner.bash`` to verify live QEMU execution of multi-turn tool calling across offline Mock, Gemini, and Local AI endpoints.
