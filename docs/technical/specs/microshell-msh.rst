========================================
MicroShell (msh/ush) Specification
========================================

:Document ID: SPEC-TECH-MSH-001
:Status: Approved
:Traced Stories: [US-REN-001], [US-REN-002], [US-REN-005], [US-GEM-009]

1. Interactive & Scripted Execution Environment
===============================================
MicroShell (`msh/ush`) serves as the primary dual-native interaction interface for MicrOS, operating identically under interactive TTY sessions and automated AI streaming pipelines:

- `src/msh/shell.zig`: Core shell engine managing line buffering, token scanning, environment state, and command dispatch.
- `src/msh_main.zig`: Standalone binary frontend connecting standard input/output over direct Linux syscalls.
- `src/msh.zig`: Root module exports and integration test suite.

2. Built-in Commands
====================
MicroShell provides essential substrate control builtins:

- `help`: Displays available commands, syntax, and system version.
- `echo <args>`: Prints evaluated strings and arguments directly to stdout.
- `vars`: Lists all active variables in the root Macros evaluation environment.
- `mem`: Reports substrate memory usage and heap allocations.
- `exit`: Terminates the shell session and triggers PID 1 shutdown.

3. Macros Expression Evaluation
===============================
Any input line not recognized as a shell builtin is passed directly to the Macros language lexer, parser, and tree-walk evaluator. Variable assignments (``x = 10 + 20``) update the persistent environment, and expressions are evaluated and formatted to standard output.

4. Bare-Metal Sovereign App 0 (lib/macros/msh.mx)
=================================================
In the sovereign microkernel environment (v0.1.0+), MicroShell operates as App 0 written entirely in the Macros language (``lib/macros/msh.mx``) and launched by Actor 0 (``init.mx``):

- **Stream-Oriented Ergonomics**: Listens on COM1 UART serial and PS/2 keyboard inputs via ``sys_serial_read()`` and ``sys_kbd_read()``, printing prompt ``msh>``.
- **Substrate Control Commands**:
   - ``status``: System health, active actor counts, contained fault counters.
   - ``actors``: Real-time table of registered actors, IDs, names, and lifecycle states.
   - ``spawn <code>`` / ``spawn_cas <hash>``: Live compilation and spawning of isolated actor domains.
   - ``store <code>`` / ``fetch <hash>`` / ``persist <id>``: Content-Addressed Storage (CAS) operations.
   - ``ai <prompt>``: Direct inference queries to the Resident AI with autonomous tool execution.
   - ``harness``: On-demand launch of App 1 (Interactive Studio), returning cleanly to ``msh`` upon exit.
   - ``kill <id>``: Explicit termination of actor domains.
- **Supervised Lifecycle**: If MicroShell terminates or faults, Actor 0 supervisor (``init.mx``) catches the state transition and automatically respawns ``msh`` without a kernel reboot.
