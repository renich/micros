Phase 0: Userspace Sandbox
==========================

:Objective: Bootstrap the MicrOS tooling, Macros REPL, and Init system using direct Linux syscalls inside a Fedora host.
:Status: Completed & Verified

Milestones
----------

* **M0.1: Substrate Toolchain**
  - Implement ``micros-runner``, ``micros-fb-verify``, ``micros-lint``, etc.
  - Establish automated CI/CD checks.

* **M0.2: Direct-Syscall ABI**
  - Bind ``libc``-free Linux syscalls for I/O, memory, and process control.

* **M0.3: Macros Application Runtime**
  - Build the Immix GC and Green Thread scheduler.
  - Implement the `/bin/macros` CLI and interactive REPL.

* **M0.4: MicrOS Init & MicroShell**
  - Build PID 1 (``micros-init``) and ``msh`` (MicroShell) as the typed command interpreter.
