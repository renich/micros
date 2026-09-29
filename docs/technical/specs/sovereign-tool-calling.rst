====================================================
Sovereign Structured Tool Calling & Dispatching Spec
====================================================

:Document ID: SPEC-TECH-TOOL-001
:Traced Stories: [US-REN-001], [US-REN-002], [US-REN-006], [US-REN-008], [US-GEM-001], [US-GEM-009], [US-GEM-010]
:Absorbed Specifications: `SPEC-TECH-AI-002` (Autonomous Tool & Script Synthesis)

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
The microkernel exposes a comprehensive co-engineering and kernel management toolset across Gemini and OpenAI provider envelopes.

2.1 Software Engineering & OS Co-Engineering Tools
--------------------------------------------------

1. ``run_command(command: []const u8) -> []const u8``
   Executes bundled system applications (e.g., ``desk``, ``ush``, ``mon``, ``status``, ``bench``) or userland utilities. Requires ``Rights.EXECUTE`` on ``CapType.actor_control``.

2. ``view_file(path: []const u8) -> []const u8``
   Reads the exact contents of files bundled in the microkernel genesis manifest or persistent CAS. Requires ``Rights.READ`` on ``CapType.storage_device``.

3. ``write_to_file(path: []const u8, content: []const u8) -> bool``
   Creates or overwrites a file in the active persistent working manifest. Requires ``Rights.WRITE`` on ``CapType.storage_device``.

4. ``replace_file_content(path: []const u8, target: []const u8, replacement: []const u8) -> bool``
   Performs an atomic search-and-replace modification to a bundled or persistent file. Requires ``Rights.WRITE`` on ``CapType.storage_device``.

5. ``list_dir(prefix: []const u8) -> []const u8``
   Lists files matching the specified prefix in the genesis bundle and persistent storage. Requires ``Rights.READ`` on ``CapType.storage_device``.

6. ``grep_search(query: []const u8) -> []const u8``
   Searches all genesis bundle source files for matching lines, returning paths and matching lines. Requires ``Rights.READ`` on ``CapType.storage_device``.

2.2 Kernel Capability & Storage Tools
-------------------------------------

7. ``spawn_actor(name: []const u8, source: []const u8) -> u32``
   Spawns an isolated child actor running Macros source code within a dedicated cooperative fiber and CSpace. Requires ``Rights.EXECUTE`` on ``CapType.actor_control``.

8. ``grant_capability(target_actor: u32, source_slot: u32, rights_mask: u16) -> bool``
   Attenuates and delegates a capability from the caller's CSpace to the target actor. Requires ``Rights.GRANT`` on the source capability.

9. ``write_storage(payload: []const u8) -> [64]u8``
   Writes payload immutably into the Content-Addressed Storage (CAS) engine, returning the 64-character hex BLAKE3 hash. Requires ``Rights.WRITE`` on ``CapType.storage_device``.

10. ``read_storage(hex_hash: [64]u8) -> []const u8``
    Retrieves immutable payload by its 64-character hex BLAKE3 hash. Requires ``Rights.READ`` on ``CapType.storage_device``.

11. ``query_telemetry() -> TelemetrySnapshot``
    Reads active actor count, fault containment metrics, available memory pages, and kernel uptime. Requires ``Rights.READ`` on ``CapType.actor_control``.
 
2.3 Autonomous Tool & Script Synthesis Registry
-----------------------------------------------
 
12. ``catalog_write(path: []const u8, content: []const u8) -> [64]u8``
    Writes or updates a named file in the workspace manifest and persists the content blob into BLAKE3 CAS. Returns the 64-character hexadecimal content hash. Requires ``Rights.WRITE`` on ``CapType.storage_device``.
 
13. ``catalog_read(path: []const u8) -> []const u8``
    Retrieves the content of a named file from the workspace catalog. Requires ``Rights.READ`` on ``CapType.storage_device``.
 
14. ``catalog_list(prefix: []const u8) -> []const u8``
    Lists files in the workspace catalog matching the optional prefix string, formatted with path, byte size, and truncated BLAKE3 hash. Requires ``Rights.READ`` on ``CapType.storage_device``.
 
15. ``catalog_commit(message: []const u8) -> [64]u8``
    Takes an atomic OCC snapshot of the active workspace manifest, advancing the generation counter and returning the new 64-character Merkle manifest root hash. Requires ``Rights.WRITE`` on ``CapType.storage_device``.
 
16. ``catalog_status() -> []const u8``
    Returns a JSON status string containing generation number, total entries, total stored bytes, and Merkle root hash. Requires ``Rights.READ`` on ``CapType.storage_device``.
 
17. ``spawn_workspace_actor(path: []const u8) -> u32``
    Reads the Macros source code for ``path`` from the workspace catalog, compiles it using the native runtime compiler, and spawns an isolated supervised child actor. Returns the spawned actor ID. Requires ``Rights.EXECUTE`` on ``CapType.actor_control`` and ``Rights.READ`` on ``CapType.storage_device``.
 
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

4. Dynamic Invocation & Shell Integration
=========================================

4.1 µShell Command Pipeline
--------------------------
µShell (``lib/macros/ush.mx``) integrates the autonomous tool execution pipeline:

* ``:run <path>``: Reads the script or binary artifact from the workspace catalog using ``sys_catalog_read`` and spawns it as a supervised actor using ``sys_actor_spawn``.
* Bare prompt dispatch: Dispatches conversational requests to the Resident AI runtime via ``sys_ai_prompt`` and resolves multi-turn tool calling turns via structured function responses until a terminal response or synthesized tool execution is achieved.

4.2 Interactive Studio Synchronization
--------------------------------------
The Interactive Studio (synthesized on-demand from CAS) multi-turn tool calling loop handles catalog tool execution, rendering real-time telemetry and inspector updates upon tool invocation and persistent workspace modification.

5. Verification & Traceability Matrix
=====================================
* ``[US-REN-001]``: Direct interactive shell access and conversational AI tool execution.
* ``[US-REN-002]``: Standalone Macros script execution from persistent workspace storage.
* ``[US-REN-006]``: Zero-POSIX immutable Content-Addressed Storage backed by BLAKE3 hashes.
* ``[US-REN-008]``: Persistent Merkle workspace catalog with atomic OCC snapshot commits.
* ``[US-GEM-001]``: Autonomous machine engineering, tool creation, and dynamic service deployment.
* ``[US-GEM-009]``: Self-healing actor execution and dynamic workspace supervisor controls.
* ``[US-GEM-010]``: Context-window-optimized module boundaries (files <= 1,000 lines, functions <= 40 lines).
