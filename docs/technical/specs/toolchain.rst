===================================================
Substrate Toolchain & Verification Specification
===================================================

:Document ID: SPEC-TECH-TOOL-001
:Status: Approved
:Traced Stories: [US-REN-009], [US-GEM-001], [US-GEM-002], [US-GEM-003], [US-GEM-004], [US-GEM-005], [US-GEM-006], [US-GEM-007]

1. Substrate Verification Toolchain
===================================
The MicrOS toolchain in `tools/` delivers deterministic verification, linting, telemetry, and specification traceability:

- `tools/micros-runner.bash`: Headless QEMU/KVM virtual machine execution harness with sub-second boot detection and sentinel verification.
- `tools/src/lint.zig`: Native Zig AST static analyzer enforcing the MicrOS Ten Commandments (max 1000 lines per file, max 40 lines per function, max nesting depth of 3 levels), with in-file rule waivers that are reason-bearing, capped, and reported.
- `tools/src/arch_gate.zig`: Tier boundary gate for `@import` edges. Enforces the kernel/userland/Macros separation, discloses every granted exemption, and rejects any architectural edge absent from the recorded baseline (`SPEC-TECH-ARCH-001`).
- `tools/src/fb_verify.zig`: High-speed PPM P6 image parser, frame variance calculator, and bounding box color auditor for graphical framebuffer verification.
- `tools/src/sym.zig`: Pure-Zig 64-bit ELF symbol table parser and function address resolver without external binary dependencies.
- `tools/src/telem.zig`: 64-byte `TelemetryToken` binary ABI generator and decoder for agent event streaming.
- `tools/micros-spec-trace.bash`: Bidirectional specification auditor guaranteeing 100% traceability between user stories, technical specs, and codebase implementation.

2. Quality Gate Execution
=========================
All builds, tests, and CI/CD runs execute `make check`, running:
1. `zig build test`: Substrate, Macros runtime, and µShell unit tests.
2. `make -C tools test`: Toolchain unit tests and validation suites.
3. `make lint`: Full AST and shell script compliance linting.
4. `make fmt-check`: Strict code formatting validation.
5. `make spec-trace`: Bidirectional requirement traceability audit.
6. `make arch-gate`: Microkernel tier boundary verification.
7. `make test-sandbox`: Direct-syscall sandbox boot in QEMU/KVM.
8. `make test-uefi`: Bare-metal UEFI boot in QEMU/KVM, gated on the `µShell` banner sentinel.

3. Unified Microbenchmark Suite (zig build bench)
=================================================
MicrOS integrates a standardized, reproducible in-tree microbenchmark suite callable directly via ``zig build bench``:

* **Fiber Context Switch Latency**: Measures cooperative fiber context switch latency over 100,000 switches (baseline: ~5.1 µs in Debug, <50 ns in ReleaseFast).
* **Immix Garbage Collector Throughput**: Benchmarks object allocation rate and sweep latency over 10,000 objects (~2.44 MB total; baseline: >1,000 MB/s alloc rate, sweep <25 µs).
* **Empirical Gate Integration**: Serves as the quantitative gate for the 3-gate bar (performance, fault-containment, tail-latency) during kernel evolutionary optimizations.
