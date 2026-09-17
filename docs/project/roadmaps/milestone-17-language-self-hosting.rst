Milestone 17: Sovereign Language Self-Hosting & Native Codegen
==============================================================

:Objective: Elevate the Macros programming language from an interpreted bytecode runtime into a completely autonomous self-hosting compiler with native x86_64 machine code generation, Immix garbage collection, and autonomous compilation. Enable MicrOS to compile, optimize, and execute its own high-level software stack directly on bare-metal silicon without external host toolchains.
:Status: Planned
:Specification: SPEC-TECH-LANG-002

Milestones & Deliverables
-------------------------

* **M17.1: Full Self-Hosting Compiler in Pure Macros**
   - Expand ``lib/macros/compiler.mx`` to implement a complete recursive descent parser, AST generator, symbol table, and bytecode emitter written entirely in Macros.
   - Execute Stage 1 self-compilation: compile ``compiler.mx`` using the kernel's bootstrap compiler, producing identical bytecode to the host build.
   - Verify bit-for-bit compiler reproducibility: ``Compiler(Stage 1) -> Compiler(Stage 2)`` produces identical bytecode hashes.

* **M17.2: Immix Mark-Region Garbage Collector Runtime Integration**
   - Integrate the Immix garbage collector (``src/macros/gc.zig``) with the active VM value model (``eval.Value``).
   - Implement bump-pointer line allocation within 32 KiB memory blocks.
   - Implement precise stack and root scanning for active actor fibers.
   - Achieve predictable sub-millisecond GC pause times during intensive actor compilation passes without heap fragmentation.

* **M17.3: Direct x86_64 Machine Code Emitter**
   - Implement a lightweight, freestanding native machine code generator in ``src/macros/codegen_x86_64.zig``.
   - Translate high-frequency bytecode opcodes (arithmetic, fiber yields, CSpace capability invocations, memory blits) into raw x86_64 machine instructions.
   - Allocate executable page frames with strict W^X (Write XOR Execute) page protections mathematically enforced by the kernel VMM.
   - Benchmark native code execution against interpreted bytecode, targeting a 5x to 10x throughput acceleration for compute-heavy actors.

* **M17.4: Sovereign Package & Content-Addressed Module Protocol**
   - Implement module resolution in ``src/macros/module.zig`` based on 256-bit BLAKE3 hashes stored in the Content-Addressed Storage (CAS) engine.
   - Replace traditional hierarchical filesystem import paths (``import "../foo.mx"``) with cryptographic content addresses (``import cas("hash...")``).
   - Eliminate dependency drift and supply-chain tampering through immutable, self-authenticating code packages.

* **M17.5: Golden Bytecode Bootstrap & Autonomous Regression Test Suite**
   - Implement automated compiler regression testing in ``tools/micros-runner.bash`` verifying self-hosted compilation of Genesis actors inside QEMU.
   - Enforce zero Ten Commandments infractions across all compiler source files (functions <= 40 lines, files <= 1000 lines).
   - Validate full spec-to-code traceability in ``micros-spec-trace.bash``.
