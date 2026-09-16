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
