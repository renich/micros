================================================
Sovereign Shell Substrate Specification
================================================

:Document ID: SPEC-TECH-SHELL-002
:Status: Approved
:Traced Stories: [US-REN-001], [US-REN-002], [US-REN-006], [US-GEM-009], [US-GEM-010]
:Parent Architecture: `SPEC-TECH-CAP-001`, `SPEC-TECH-SYS-001`
:Module Targets: ``src/ush/shell.zig``, ``lib/macros/ush.mx``, ``src/kernel/abi.zig``

0. Charter & Non-Overlapping Scope Boundary
===========================================
This specification defines the kernel-level Sovereign Shell Substrate:
- **Scope**: Kernel subsystem managing isolated actor lifecycles, session sandboxing, CSpace capability attenuation upon child delegation, window chrome/canvas binding, and demand-miss synthesis coordination.
- **Non-Overlapping Boundary with µShell REPL (`ushell-ush.rst`)**: This substrate does NOT specify terminal prompt rendering or interactive line editing keystrokes; those interactive REPL behaviors belong strictly to `ushell-ush.rst`.
- **Non-Overlapping Boundary with Gemini Orchestrator (`sovereign-gemini-orchestrator.rst`)**: This substrate does NOT implement remote API endpoints, TLS client state machines, or JSON prompt formatting; those inference transport mechanisms belong strictly to `sovereign-gemini-orchestrator.rst`.

1. Architectural Axioms & Purpose
=================================
This specification defines the Sovereign Shell (``ush``) for MicrOS (µOS), replacing traditional Unix-style command shells and POSIX terminal emulators with a lean, conversational interface that seamlessly unites deterministic system commands and natural language AI dispatching.

1.1 Conversational-First Interaction Model
------------------------------------------
Legacy shells require users to memorize hundreds of fragmented utilities (``ls``, ``cat``, ``grep``, ``sed``, ``find``, ``ps``, ``top``) with idiosyncratic flag syntaxes. In MicrOS:

* **Bare Prompt AI Routing**: Any line entered without a colon prefix (``:``) is dispatched directly to the Resident AI subsystem as a natural language prompt.
* **Six Deterministic Verbs**: Administrative system actions are strictly bounded to six native verbs prefixed with a colon (``:show``, ``:run``, ``:ps``, ``:undo``, ``:mesh``, ``:exit``), plus ``help``. Capabilities are inspected via ``:show caps`` and ``:show caps.<app>``.
* **Zero POSIX Emulation**: Cut verbs (e.g., ``ls``, ``cd``, ``cat``, ``clear``) are not simulated with fake POSIX layers; they route immediately to AI dispatch with a helpful routing hint.
* **Role-Gated Privilege Escalation**: Destructive operations like ``reboot`` and ``rebuild`` are strictly demoted from guest execution and restricted to the AI supervisor role.

1.2 Demand-Driven Synthesis & CAS Caching
-----------------------------------------
The shell serves as the entry point for the "machine that makes machines":
* When an application (e.g., ``novel_app``, ``desk``, ``vedit``) is requested via ``:run <app>`` and does not exist in the active workspace, the shell triggers a demand-miss synthesis workflow with the Resident AI.
* **Milestone 39 Live AI Actor Synthesis**: When network connectivity is active with DNS, ``aid`` dispatches prompts over TLS 1.3 with SPKI pinning to Google Gemini (or uses recorded fixture in tests) to synthesize bespoke userland Macros actors; air-gapped systems fall back to deterministic offline synthesis with honest ``[mock]`` labeling.
* The synthesized Macros program is compiled to bytecode, cached immutably into Content-Addressed Storage (CAS) by its BLAKE3 hash, and registered in the workspace catalog.
* **O7 Consent Memory**: First launch triggers an interactive permission prompt (`caps.granted.<app>`), recorded for zero re-prompts on subsequent invocations.
* **G7 Provenance Badges**: Every synthesized actor carries Ed25519 authorship tokens rendered on the window title bar and `:show <artifact>` inspection cards.
* Subsequent invocations result in a sub-millisecond CAS cache hit, loading and executing the verified bytecode without network latency or re-synthesis overhead.

2. Shell Grammar & Command Dispatch
===================================

2.1 Grammatical Hierarchy
-------------------------
User input lines are evaluated according to the following deterministic dispatch hierarchy:

.. code-block:: text

   input_line  := verb_command | bare_prompt
   verb_command := ":" verb_ident [ " " argument_string ] | "help"
   verb_ident  := "show" | "run" | "ps" | "undo" | "mesh" | "exit"
   bare_prompt := <any non-empty string not starting with ':'>

2.2 Native Verb Semantics
-------------------------

1. ``:show [target]``
   Inspects visual workspace entities, active canvas previews, catalog artifacts, or capability settings (e.g., ``:show caps``, ``:show caps.<app>``). Defaults to active workspace status if target is omitted.
2. ``:run <target>``
   Executes a catalog artifact, synthesized tool, or bytecode chunk. Resolves via CAS cache; on miss, triggers autonomous synthesis.
3. ``:ps``
   Displays active actors, execution states (running, paused, faulted), CPU tick consumption, and gas budgets.
4. ``:undo``
   Rolls back the workspace catalog to the previous Merkle generation counter, restoring consistent state after unwanted mutations.
5. ``:mesh [command]``
   Inspects or controls peer-to-peer mesh discovery, node links, and content-addressed artifact replication.
6. ``:exit``
   Terminates the interactive shell session cleanly and yields execution to the supervisor actor.
7. ``help``
   Displays the concise 6-verb surface and guidance on natural language conversational interaction.

3. Capability Boundaries & Sandboxing
=====================================
The conversational shell operates as an unprivileged or attenuated guest actor (Layer 4):
* **No Ambient Hardware Access**: The shell interacts with the console and display strictly via typed capabilities (``CapType.console``, ``CapType.framebuffer`` / ``window_commit``).
* **Storage Access Guard**: Workspace read and write actions require explicit ``CapType.storage_device`` tokens.
* **Controlled Delegation**: Spawning child actors via ``:run`` attenuates capabilities, ensuring guest programs cannot access supervisor rings or unmapped memory regions.

4. Verification & Traceability Matrix
=====================================
* ``[US-REN-001]``: Interactive typed shell automation and conversational dispatch.
* ``[US-REN-002]``: Unified shell and application scripting via Macros runtime.
* ``[US-REN-006]``: Capability-bounded process supervision without ambient authority.
* ``[US-GEM-009]``: Self-healing script execution and autonomous tool synthesis.
* ``[US-GEM-010]``: Context-window-optimized module boundaries (<= 1,000 lines, functions <= 40 lines).
