===================================================
Substrate Toolchain & Verification Specification
===================================================

:Document ID: SPEC-TECH-TOOL-001
:Status: Approved
:Traced Stories: [US-REN-005], [US-REN-006], [US-GEM-006], [US-GEM-009]

1. Substrate Verification Toolchain
===================================
The MicrOS toolchain in `tools/` delivers deterministic verification, linting, telemetry, and specification traceability:

- `tools/micros-runner.bash`: Headless QEMU/KVM virtual machine execution harness with sub-second boot detection and sentinel verification.
- `tools/src/lint.zig`: Native Zig AST static analyzer enforcing the MicrOS Ten Commandments (max 1000 lines per file, max 40 lines per function, max nesting depth of 3 levels).
- `tools/src/fb_verify.zig`: High-speed PPM P6 image parser, frame variance calculator, and bounding box color auditor for graphical framebuffer verification.
- `tools/src/sym.zig`: Pure-Zig 64-bit ELF symbol table parser and function address resolver without external binary dependencies.
- `tools/src/telem.zig`: 64-byte `TelemetryToken` binary ABI generator and decoder for agent event streaming.
- `tools/micros-spec-trace.bash`: Bidirectional specification auditor guaranteeing 100% traceability between user stories, technical specs, and codebase implementation.

2. Quality Gate Execution
=========================
All builds, tests, and CI/CD runs execute `make check`, running:
1. `zig build test`: Substrate, Macros runtime, and MicroShell unit tests.
2. `make -C tools test`: Toolchain unit tests and validation suites.
3. `make lint`: Full AST and shell script compliance linting.
4. `make fmt-check`: Strict code formatting validation.
5. `make spec-trace`: Bidirectional requirement traceability audit.
