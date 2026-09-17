===================================================
Self-Hosting Macros Architecture & Bootstrap Plan
===================================================

:Document ID: SPEC-TECH-MACROS-SELF-001
:Status: Approved
:Traced Stories: [US-REN-002], [US-REN-004], [US-GEM-008], [US-GEM-010]

1. Self-Sufficiency & Computational Sovereignty
================================================
A core architectural pillar of MicrOS is computational sovereignty: the operating system and its high-level language must not depend perpetually on an external host toolchain (such as Zig or LLVM on Linux). Macros must be capable of compiling and rebuilding itself natively within MicrOS.

2. Three-Stage Bootstrap Architecture
=====================================

Stage 0: Zig Substrate Bootstrap (Host VM/Substrate)
------------------------------------------------------
- **Location**: `src/macros/`
- **Engine**: Implemented in freestanding Zig without libc.
- **Responsibilities**:
  1. Lexer, Parser, AST, and Tree-Walk/Bytecode Evaluator.
  2. Immix Mark-Region Garbage Collector (`src/macros/immix.zig`).
  3. Green-Thread Cooperative Scheduler (`src/macros/fiber.zig`).
  4. Native Syscall & Substrate I/O bindings (`read_file`, `write_file`, `alloc`, `exit`).

Stage 1: Macros-in-Macros Compiler Source
-----------------------------------------
- **Location**: `lib/macros/`
- **Modules**:
  - `lexer.mx`: Macros tokenizer reading source text buffers and emitting token streams.
  - `parser.mx`: Recursive descent parser constructing typed AST nodes.
  - `ast.mx`: AST data structures (`Fn`, `If`, `While`, `Call`, `Binary`, `Assign`, `Literal`).
  - `typecheck.mx`: Semantic validation and type inference.
  - `codegen_x86_64.mx/codegen_byte.mx`: Standalone machine code or bytecode emitter.
  - `compiler.mx`: Compiler CLI interface and driver.

Stage 2: Self-Hosted Fixed Point Verification
---------------------------------------------
1. **Compilation Step 1**: `Stage 0 (Zig)` interprets `lib/macros/compiler.mx` with input `lib/macros/` $\rightarrow$ emits `Stage 1` binary `build/macros-stage1`.
2. **Compilation Step 2**: `build/macros-stage1` compiles `lib/macros/` $\rightarrow$ emits `Stage 2` binary `build/macros-stage2`.
3. **Fixed Point Proof**: `diff build/macros-stage1 build/macros-stage2` produces zero difference (bit-for-bit identical binary reproducibility).

3. Core Language Grammar for Self-Hosting
=========================================
To author its own compiler, Macros provides:
- **Functions**: `fn name(arg1: Type, arg2: Type): ReturnType { ... }`
- **Control Flow**: `if (cond) { ... } else { ... }`, `while (cond) { ... }`, `return expr;`
- **Compound Types**: `struct Token { kind: int, lexeme: string }`
- **Array/Slice**: Dynamic lists with automatic Immix GC recycling.
- **Byte I/O**: Direct syscalls for file descriptor reads/writes.
