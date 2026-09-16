=========
Changelog
=========

All notable changes to this project will be documented in this file.

The format is based on `Keep a Changelog <https://keepachangelog.com/en/1.0.0/>`_,
and this project adheres to `Semantic Versioning <https://semver.org/spec/v2.0.0.html>`_.

[Unreleased]
============

Added
-----
* Initial project structure and Zig build system (Phase 0).
* Direct-syscall wrapper (`src/sys/`) bypassing `libc` for Linux host execution.
* Substrate Toolchain stubs (`micros-runner`, `micros-fb-verify`, `micros-lint`, etc.).
* Basic Lexer and AST structures for the Macros application language.
* `micros-init` entry point for sandbox validation.
* Foundational documentation (`docs/`), roadmaps, and architecture blueprints.
* GNUmakefile wrapper strictly adhering to GNU Make standards (targets: all, test, clean, run, help, lint, fmt, spec-trace).
* Initial Macros AST Parser (`src/macros/parser.zig`) supporting binary expressions and numeric/identifier literals.
* Wire-up of the Macros language parser into the `micros-init` entry point for execution verification.
* Implementation of `micros-lint`, a native Zig AST static analyzer enforcing codebase constraints (1000-line limits, 40-line function limits, max nesting depth 3, and prohibiting `catch unreachable`).
* Implementation of Macros AST Evaluator and Environment (`src/macros/eval.zig`) supporting variable bindings, arithmetic evaluation, and equality checks with memory safety.
* Implementation of **MicroShell** (`msh` / `ush`) in `src/msh/shell.zig` providing interactive REPL and streaming execution for both typed shell commands and Macros scripts.
* Standalone `msh` executable binary in `build.zig` and integration with `micros-init` substrate bootstrap.
* Event-driven headless QEMU/KVM test harness in `tools/micros-runner.bash` with sub-second milestone sentinel matching.
* Native ACPI S5 sleep state poweroff syscall integration in `src/sys/process.zig` for clean virtual machine termination.
* GNUmakefile targets `test-sandbox`, `test-qemu`, and `qemu-msh` for direct KVM guest execution.
* Formalized Master Business Specification (`docs/business/spec.rst`) and User Personas (`docs/business/specs/user-personas.rst`) for Rénich (Human) and Gemini (AI).
* Catalogs of 20 User Stories (`[US-REN-001]`..`[US-REN-010]` and `[US-GEM-001]`..`[US-GEM-010]`) covering typed shell automation, zero-libc determinism, binary telemetry, UKI delivery, and Immix GC.
* Automated Unified Kernel Image (UKI) packaging target (`make uki`) and direct UEFI/OVMF QEMU test harness (`make test-uki`).
