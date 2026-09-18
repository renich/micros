====================================================
Sovereign Structured Tool Calling & Dispatching Spec
====================================================

:Document ID: SPEC-TECH-TOOL-001
:Status: Approved
:Traced Stories: [US-REN-001], [US-REN-006], [US-GEM-001], [US-GEM-009], [US-GEM-010]

1. Architectural Axioms & Purpose
=================================
This specification defines the typed, structured tool calling architecture for MicrOS (µOS), transitioning the Resident AI interaction model from unstructured markdown and reStructuredText string parsing into a deterministic, zero-allocation, capability-gated RPC dispatching protocol.

1.1 Eradication of Text-Scraping Fragility
------------------------------------------
Prior to Milestone 15, the microkernel extracted executable Macros code by scanning LLM responses for ``.. code-block:: macros`` markers. While functional, text scraping suffers from systemic failure modes:

* **Indentation Sensitivity**: reStructuredText relies on column-aligned indentation, creating syntax edge cases when models append prose or section headers.
* **One-Dimensional Semantic Range**: Text extraction can only convey raw code to execute. It cannot express granular operations such as allocating a window, querying telemetry, writing to storage, or delegating capabilities.
* **Lack of Bidirectionality**: Scraping does not provide a standardized mechanism for the microkernel to report structured results, execution metrics, or error codes back to the model in multi-turn conversations.

1.2 The Object-Capability Tool Gate
-----------------------------------
In MicrOS, tool calls are not ambient operations:

* **Caller CSpace Enforcement**: Every tool execution is evaluated in the context of the calling Actor's Capability Space (CSpace). If Actor 0 or an application actor triggers a tool turn, permissions are strictly checked against its assigned capabilities.
* **Attenuation Invariant**: The ``grant_capability`` tool accepts an explicit source slot (``source_slot: u32``) and rights mask (``rights_mask: u16``). The dispatcher mathematically enforces that the granted rights are a subset of the caller's rights: ``(rights_mask & ~src_cap.rights) == 0``. Privilege escalation is mathematically impossible.
* **Zero Libc & Zero Allocation**: Tool schema definitions, argument extraction, and dispatching operate in-place over existing packet buffers without heap churn or external JSON dependencies.

2. Canonical System Tool Registry
=================================
The microkernel exposes 6 canonical system tools across Gemini and OpenAI provider envelopes.

2.1 Tool Signatures & Schemas
-----------------------------

1. ``spawn_actor(name: []const u8, source: []const u8) -> u32``
   Spawns an isolated child actor running Macros source code within a dedicated cooperative fiber and CSpace. Requires ``Rights.EXECUTE`` on ``CapType.actor_control``.

2. ``grant_capability(target_actor: u32, source_slot: u32, rights_mask: u16) -> bool``
   Attenuates and delegates a capability from the caller's CSpace to the target actor. Requires ``Rights.GRANT`` on the source capability.

3. ``write_storage(payload: []const u8) -> [64]u8``
   Writes payload immutably into the Content-Addressed Storage (CAS) engine, returning the 64-character hex BLAKE3 hash. Requires ``Rights.WRITE`` on ``CapType.storage_device``.

4. ``read_storage(hex_hash: [64]u8) -> []const u8``
   Retrieves immutable payload by its 64-character hex BLAKE3 hash. Requires ``Rights.READ`` on ``CapType.storage_device``.

5. ``draw_canvas(x: u32, y: u32, w: u32, h: u32, color: u32) -> void``
   Blits a solid color rectangle to the linear 1280x800 GOP framebuffer. Requires ``Rights.WRITE`` on ``CapType.framebuffer``.

6. ``query_telemetry() -> TelemetrySnapshot``
   Reads active actor count, fault containment metrics, available memory pages, and kernel uptime. Requires ``Rights.READ`` on ``CapType.actor_control``.

3. Wire Protocol & Streaming Parser ABI
=======================================

3.1 Provider Envelope Normalization
-----------------------------------
The tool calling substrate isolates provider differences at the driver boundary:

* **Google Gemini**: Arguments are emitted as a native JSON dictionary within ``candidates[0].content.parts[].functionCall``.
* **OpenAI / Ollama**: Arguments are emitted as an escaped string literal within ``choices[0].message.tool_calls[].function.arguments``.

Provider drivers extract the raw argument slice (unescaping string literals when necessary) and pass a canonical JSON object ``{"key": value}`` to the core parser.

3.2 Zero-Allocation Key-Value Scanner
-------------------------------------
The core parser (`src/kernel/ai/tool_parser.zig`) scans key-value pairs without constructing a DOM tree:

* **Depth Limit**: Strictly enforces nesting depth <= 3.
* **Lenient Scalar Parsing**: Accepts integers formatted as decimal numbers, quoted strings, hex colors with ``0x`` or ``#`` prefixes, or numbers with trailing ``.0``.
* **In-Place Unescaping**: Unescapes string values directly within the packet receive buffer.

3.3 Multi-Turn Feedback Loop
----------------------------
Upon executing a tool call, the dispatcher produces a structured execution response returned in the subsequent conversational turn:

* **Gemini Response Format**:
  ``{"role":"user","parts":[{"functionResponse":{"name":"<tool>","response":{"status":"ok",...}}}]}``
* **Turn Bound**: Multi-turn autonomous loops are capped at a maximum of 5 iterations with mandatory cooperative fiber yielding between network transactions.

3.4 HTTP Chunked Decoding & Conversational Completion
-----------------------------------------------------
Upstream HTTPS endpoints (such as Google Gemini) frequently emit responses using HTTP/1.1 ``Transfer-Encoding: chunked``. The microkernel and userspace harness maintain the following invariants:

* **In-Kernel Chunk Stripping**: ``decodeChunkedBody`` in ``src/kernel/net/http.zig`` validates hexadecimal chunk lengths, extracts chunk data sequentially into contiguous memory, and verifies terminal ``0\r\n\r\n`` indicators before JSON parsing.
* **Zero Raw-JSON Leaks**: When an LLM response contains a ``functionCall``, the userspace harness never dumps raw protocol envelopes or cryptographic signatures to the display. It executes the tool, logs a clean status token (``[ai:tool] Executed: ...``), and feeds the tool result back into the cognitive loop.
* **Bounded Framebuffer Text Wrapping**: ``console_print_wrapped`` in ``lib/macros/harness.mx`` parses embedded newlines and mathematically bounds text width (``x <= 840``), preventing multiline conversational text from overflowing across vertical UI partition borders.
