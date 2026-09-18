========================================================================
Resident AI Autonomous Tool & Script Synthesis (µOS)
========================================================================

:Document ID: SPEC-TECH-AI-002
:Status: Approved
:Traced Stories: [US-REN-001], [US-REN-002], [US-REN-006], [US-REN-008], [US-GEM-001], [US-GEM-009], [US-GEM-010]
:Parent Architecture: `SPEC-TECH-TOOL-001`, `SPEC-TECH-FS-001`, `SPEC-TECH-CAP-001`
:Module Targets: ``src/kernel/ai/tools.zig``, ``src/kernel/ai/tool_parser.zig``, ``src/kernel/ai/dispatcher.zig``, ``src/kernel/abi.zig``, ``lib/macros/msh.mx``, ``lib/macros/harness.mx``

1. Architectural Axioms & Purpose
=================================
This specification defines the substrate and execution protocols enabling the Resident Sovereign AI and human operators to autonomously synthesize, inspect, persist, and execute dynamic tools, scripts, and actors within MicrOS (µOS).

1.1 Autonomous Machine Engineering Doctrine
-------------------------------------------
Under traditional monolithic and microkernel paradigms, administrative commands and automation scripts are hardcoded binaries or dependent on external package managers and POSIX filesystems. In MicrOS:

* **Sovereign Tool Synthesis**: The Resident AI possesses the native capability to compose pure Macros (``.mx``) programs in response to conversational human prompts or autonomous self-healing events.
* **Content-Addressed Workspace Integration**: Synthesized programs are stored directly into the Merkle Workspace Catalog (``SPEC-TECH-FS-001``) and backed by BLAKE3 Content-Addressed Storage (CAS).
* **Zero-Libc Dynamic Invocation**: Scripts stored in the workspace are compiled on-the-fly into immutable bytecode chunks and spawned into isolated, cooperative green-thread fibers governed by CSpace capability boundaries.
* **Unified Human-AI Shell Ergonomics**: Both MicroShell (``msh.mx``) and the Interactive Studio (``harness.mx``) provide seamless commands (``ai <prompt>``, ``run <path>``) to generate and invoke workspace actors interchangeably.

1.2 Capability-Gated Tool Calling Security Gate
-----------------------------------------------
All autonomous tool invocations originating from the Resident AI are strictly gated by the caller's Capability Space (CSpace):

* **Catalog Storage Authority**:
  * ``catalog_write`` and ``catalog_commit`` require ``CapType.storage_device`` with ``Rights.WRITE``.
  * ``catalog_read``, ``catalog_list``, and ``catalog_status`` require ``CapType.storage_device`` with ``Rights.READ``.
* **Actor Execution Authority**:
  * ``spawn_workspace_actor`` requires ``CapType.actor_control`` with ``Rights.EXECUTE`` and ``CapType.storage_device`` with ``Rights.READ``.
* **Sandbox Attenuation**: Actors spawned from workspace scripts inherit minimal default capabilities and cannot escalate privileges or mutate the storage superblock without explicit delegation.

2. Tool Registry & Schema Declarations
======================================

2.1 Tool Signatures
-------------------

1. ``catalog_write(path: []const u8, content: []const u8) -> [64]u8``
   Writes or updates a named file in the workspace manifest and persists the content blob into BLAKE3 CAS. Returns the 64-character hexadecimal content hash.

2. ``catalog_read(path: []const u8) -> []const u8``
   Retrieves the content of a named file from the workspace catalog.

3. ``catalog_list(prefix: []const u8) -> []const u8``
   Lists files in the workspace catalog matching the optional prefix string, formatted with path, byte size, and truncated BLAKE3 hash.

4. ``catalog_commit(message: []const u8) -> [64]u8``
   Takes an atomic OCC snapshot of the active workspace manifest, advancing the generation counter and returning the new 64-character Merkle manifest root hash.

5. ``catalog_status() -> []const u8``
   Returns a JSON status string containing generation number, total entries, total stored bytes, and Merkle root hash.

6. ``spawn_workspace_actor(path: []const u8) -> u32``
   Reads the Macros source code for ``path`` from the workspace catalog, compiles it using the native runtime compiler, and spawns an isolated supervised child actor. Returns the spawned actor ID.

2.2 Comptime Provider Schemas
-----------------------------
The tool declarations are registered at compile time in both Gemini Function Declaration format (``GEMINI_TOOLS_JSON``) and OpenAI Tool Specification format (``OPENAI_TOOLS_JSON``).

3. Dynamic Invocation & Shell Integration
=========================================

3.1 MicroShell Command Pipeline
-------------------------------
MicroShell (``lib/macros/msh.mx``) integrates the autonomous tool execution pipeline:

* ``run <path>``: Reads the script at ``path`` from the workspace catalog using ``sys_catalog_read`` and spawns it as a supervised actor using ``sys_actor_spawn_code``.
* ``ai <prompt>``: Dispatches conversational requests to the Resident AI runtime via ``sys_ai_prompt`` and resolves multi-turn tool calling turns via ``sys_ai_tool_call`` until a terminal response or synthesized tool execution is achieved.

3.2 Interactive Studio Synchronization
--------------------------------------
The Interactive Studio (``lib/macros/harness.mx``) multi-turn tool calling loop handles catalog tool execution, rendering real-time telemetry and inspector updates upon tool invocation and persistent workspace modification.

4. Verification & Traceability Matrix
=====================================
* ``[US-REN-001]``: Direct interactive shell access and conversational AI tool execution.
* ``[US-REN-002]``: Standalone Macros script execution from persistent workspace storage.
* ``[US-REN-006]``: Zero-POSIX immutable Content-Addressed Storage backed by BLAKE3 hashes.
* ``[US-REN-008]``: Persistent Merkle workspace catalog with atomic OCC snapshot commits.
* ``[US-GEM-001]``: Autonomous machine engineering, tool creation, and dynamic service deployment.
* ``[US-GEM-009]``: Self-healing actor execution and dynamic workspace supervisor controls.
* ``[US-GEM-010]``: Context-window-optimized module boundaries (files $\le 1,000$ lines, functions $\le 40$ lines).
