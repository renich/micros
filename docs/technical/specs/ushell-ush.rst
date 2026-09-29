========================================
µShell (ush) Specification
========================================

:Document ID: SPEC-TECH-USH-001
:Status: Approved
:Traced Stories: [US-REN-001], [US-REN-002], [US-REN-005], [US-GEM-009]

0. Charter & Non-Overlapping Scope Boundary
===========================================
This specification governs the user-facing µShell (`ush`) interface:
- **Scope**: Human-interactive REPL, prompt ergonomics (`ush>`), line editing, syntax validation, conversational input routing, and built-in administrative verbs.
- **Non-Overlapping Boundary with Sovereign Shell Substrate (`sovereign-shell.rst`)**: `ush` does NOT implement kernel-level actor scheduling, CSpace capability attenuation, session isolation, or window chrome/canvas binding; those substrate invariants belong strictly to `sovereign-shell.rst`.
- **Non-Overlapping Boundary with Gemini Orchestrator (`sovereign-gemini-orchestrator.rst`)**: `ush` does NOT handle TLS 1.3 handshakes, SPKI pinning, prompt JSON serialization, or SSE streaming; those inference transport mechanisms belong strictly to `sovereign-gemini-orchestrator.rst`.

1. Interactive & Scripted Execution Environment
===============================================
µShell (`ush`) serves as the primary dual-native interaction interface for MicrOS, operating identically under interactive TTY sessions and automated AI streaming pipelines:

- `src/ush/shell.zig`: Core shell engine managing line buffering, token scanning, environment state, and command dispatch.
- `src/ush_main.zig`: Standalone binary frontend connecting standard input/output over direct Linux syscalls.
- `src/ush.zig`: Root module exports and integration test suite.

2. Deterministic Verbs & Conversational Interaction
===================================================
µShell implements a conversational-first prompt model:
- **Bare Prompts**: Lines entered without a colon prefix (`:`) route directly to the Resident AI subsystem as natural language queries.
- **Six Native Verbs**:
   - `:run <name|hash>`: Executes an actor. Resolves via local catalog/bundle/CAS cache; on demand-miss, triggers autonomous live synthesis (Gemini 2.5 API with honest `[mock]` offline fallback), persists to CAS, enforces O7 consent checks, and spawns the actor.
   - `:show <target>[@gen]`: Displays visual artifact cards with Ed25519 provenance badges (`[origin] - Ed25519 verified`), workspace catalogs (`:show catalog` or `:show catalog@<gen>`), or granted capabilities (`:show caps`, `:show caps.<app>`). Evicted generation requests output honest diagnostic telemetry (ring bound and oldest live generation).
   - `:ps`: Displays active actors, execution states (running, paused, faulted), CPU tick consumption, and gas budgets.
   - `:undo`: Atomically restores the previous consistent workspace generation root from the 16-slot snapshot ring and advances generation monotonically ($G + 1$, append-only OCC commit). Emits an honest diagnostic no-op message when executed at genesis.
   - `:mesh <publish|pull|unpublish> <hash>`: Replicates content-addressed artifacts across cluster nodes, or emits signed tombstones for de-indexing.
   - `:exit`: Cleanly terminates the interactive shell session.
   - `help`: Displays the concise command surface.

3. Macros Expression Evaluation
===============================
Any input line not recognized as a shell builtin is passed directly to the Macros language lexer, parser, and tree-walk evaluator. Variable assignments (``x = 10 + 20``) update the persistent environment, and expressions are evaluated and formatted to standard output.

4. Bare-Metal Sovereign App 0 (lib/macros/ush.mx)
=================================================
In the sovereign microkernel environment (v0.1.0+), µShell operates as App 0 written entirely in the Macros language (``lib/macros/ush.mx``) and launched by Actor 0 (``init.mx``):

- **Stream-Oriented Ergonomics**: Listens on COM1 UART serial and PS/2 keyboard inputs via ``sys_serial_read()`` and ``sys_kbd_read()``, printing prompt ``ush>``.
- **Supervised Lifecycle**: If µShell terminates or faults, Actor 0 supervisor (``init.mx``) catches the state transition and automatically respawns ``ush`` without a kernel reboot.
