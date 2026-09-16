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
