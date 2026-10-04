=========================================
Macros Language Formal Specification
=========================================

:Document ID: SPEC-TECH-MACROS-LANG-001
:Status: Approved
:Traced Stories: [US-REN-002], [US-REN-004], [US-REN-010], [US-GEM-008], [US-GEM-010]
:File Extensions: ``.mx``, ``.macros``

1. Executive Summary & Design Principles
========================================
Macros (``macros``) is the high-level, freestanding systems programming language of MicrOS (µOS). It is designed to serve as both an interactive orchestration environment for human architects and AI agents, and a standalone systems application language capable of self-hosting and direct kernel interaction.

Core Design Directives:
-----------------------
- **Zero-Libc Substrate**: The language engine executes directly upon bare-metal Linux syscalls via ``src/sys/`` without intermediary libc abstractions.
- **Canonical File Extensions**: Source files exclusively utilize the ``.mx`` (canonical concise) or ``.macros`` (canonical full) file extensions.
- **Immix Mark-Region GC**: Deterministic memory management combining 32KB blocks, 128-byte line marks, and bump-pointer allocation into contiguous line holes.
- **Cooperative Fiber Runtime**: Userspace green-thread scheduling with 64KB stack boundaries and x86_64 assembly context switching.
- **Self-Hosting Fixed Point**: The language is structured to compile its own compiler (Stage 0 Zig -> Stage 1 Macros -> Stage 2 Native Binary).

2. Lexical Grammar & Tokens
===========================
The Macros lexical scanner translates UTF-8 source streams into typed token sequences.

Token Classes:
--------------
- **Keywords**: ``fn``, ``return``, ``if``, ``else``, ``while``, ``true``, ``false``.
- **Identifiers**: ``[a-zA-Z_][a-zA-Z0-9_]*``
- **Integer Literals**: ``[0-9]+`` (evaluated as 64-bit signed integers).
- **String Literals**: Double-quoted UTF-8 sequences ``"..."``.
- **Single-Line Comments**: ``// ... \n`` (skipped during tokenization without mutating adjacent punctuation).
- **Operators**:
  - Arithmetic: ``+``, ``-``, ``*``, ``/``, ``%``
  - Bitwise: ``&``, ``|``, ``^``, ``<<``, ``>>``
  - Unary: ``-``, ``!``
  - Equality: ``==``, ``!=``
  - Relational: ``<``, ``<=``, ``>``, ``>=``
  - Assignment: ``=``
- **Delimiters & Punctuation**: ``(``, ``)``, ``{``, ``}``, ``[``, ``]``, ``,``, ``;``, ``:``.

Character Encoding
------------------
Source files are UTF-8, and the scanner translates them into the runtime string
model: string constants hold Latin-1 code units. The substrate depends on that
model from three directions, so the translation is normative rather than
cosmetic:

* ``src/kernel/serial.zig`` encodes Latin-1 code units to UTF-8 on output
  (``writeChar``) and decodes UTF-8 keystrokes to Latin-1 on input
  (``readChar``); the Spanish roundtrip test pins both directions.
* ``src/kernel/font.zig`` indexes the 8x8 glyph table with a single byte.
* ``char_to_str`` materializes one code unit per integer argument.

Every UTF-8 sequence in the ``U+0080..U+00FF`` range therefore collapses into
its single Latin-1 byte when a string token is produced, in both the host
compiler (``src/macros/compiler.zig``) and the self-hosted tokenizer
(``lib/macros/lexer.mx``). Codepoints above ``U+00FF`` have no byte
representation and pass through verbatim.

3. Syntax & Formal Grammar (EBNF)
=================================

.. code-block:: text

   Program        ::= Statement* EOF
   Statement      ::= FunctionDecl | IfStmt | WhileStmt | ReturnStmt | Block | AssignStmt | ExprStmt
   FunctionDecl   ::= "fn" Identifier "(" ParamList? ")" Block
   ParamList      ::= Identifier ("," Identifier)*
   IfStmt         ::= "if" "(" Expression ")" Statement ("else" Statement)?
   WhileStmt      ::= "while" "(" Expression ")" Statement
   ReturnStmt     ::= "return" Expression? ";"
   Block          ::= "{" Statement* "}"
   AssignStmt     ::= Identifier "=" Expression ";"
   ExprStmt       ::= Expression ";"?
   Expression     ::= LogicalOr
   LogicalOr      ::= BitwiseOr
   BitwiseOr      ::= BitwiseXor ("|" BitwiseXor)*
   BitwiseXor     ::= BitwiseAnd ("^" BitwiseAnd)*
   BitwiseAnd     ::= Equality ("&" Equality)*
   Equality       ::= Relational (("==" | "!=") Relational)*
   Relational     ::= Shift (("<" | "<=" | ">" | ">=") Shift)*
   Shift          ::= Additive (("<<" | ">>") Additive)*
   Additive       ::= Multiplicative (("+" | "-") Multiplicative)*
   Multiplicative ::= Unary (("*" | "/" | "%") Unary)*
   Unary          ::= ("-" | "!") Unary | Primary
   Primary        ::= Number | String | Boolean | Identifier | CallExpr | "(" Expression ")"
   CallExpr       ::= Identifier "(" ArgumentList? ")"
   ArgumentList   ::= Expression ("," Expression)*
   Number         ::= [0-9]+
   Boolean        ::= "true" | "false"

4. Memory Management & Immix GC Architecture
============================================
The Macros memory subsystem is managed by the Immix mark-region garbage collector (``src/macros/gc.zig``):

- **Block Structure**: 32KB blocks (``BLOCK_SIZE = 32768``) containing 128 lines of 256 bytes each (``LINE_SIZE = 256``, ``LINES_PER_BLOCK = 128``), page-aligned to 4096 bytes (``align(4096)``).
- **Line State**: Each line maintains a status byte indicating whether it is free, allocated, or marked live.
- **Allocation Strategy**: Small objects ($\le 4096$ bytes) use bump-pointer cursors within contiguous free line holes. Large objects (> 4096 bytes, ``LARGE_OBJECT_THRESHOLD = 4096``) are allocated in the Large Object Space (LOS).
- **Garbage Collection Cycle**: Stop-the-world mark phase followed by linear line bitmap sweep. Contiguous unmarked lines are coalesced into allocation holes without compaction overhead. Default threshold is 64 KiB (``DEFAULT_GC_THRESHOLD = 65536``) scaling by 2x up to a 16 MiB ceiling (``MAX_HEAP_BLOCKS = 512``).

5. Fiber Concurrency Runtime & Bounded Execution
================================================
Macros provides lightweight green-thread fibers (``src/macros/fiber.zig``):

- **Stack Allocation**: Each fiber is provisioned with a 2MB stack (``STACK_SIZE = 2097152``) and a 4096-byte guard page (``GUARD_SIZE = 4096``) to accommodate cryptographic state (including post-quantum ML-KEM-768 and TLS 1.3), aligned to 4096-byte boundaries.
- **Context Switch Assembly**: Callee-saved registers (``rbp``, ``rbx``, ``r12``, ``r13``, ``r14``, ``r15``) are saved on the outgoing stack; the stack pointer (``rsp``) is swapped in ``src/macros/context_switch.s``.
- **Bounded Execution & Preemption**: Execution bounds are enforced per instruction dispatch:
  - **Dynamic Gas Metering**: When an instruction gas limit is assigned (``vm.setGasLimit()``), each instruction decrements the gas counter; exhaustion immediately traps with ``error.OutOfGas``.
  - **Cooperative Preemption Quantum**: In unmetered or long-running execution, the VM yields the CPU (``fiber.yield()``) every 1024 instructions (``PREEMPTION_QUANTUM = 1024``), mathematically bounding worst-case latency across concurrent actors.
- **Non-Preemptive Scheduling**: A FIFO ready-queue schedules active fibers upon explicit yield, quantum preemption, or I/O suspension.

6. Evaluator & Runtime Execution Semantics
==========================================
The tree-walk evaluation engine (``src/macros/eval.zig``) and bytecode VM (``src/macros/vm.zig``) provide:

- **Lexical Scoping**: Chained parent-child environment lookup with immutable identifier isolation across function invocations.
- **Control Flow Bubbling**: Function returns bubble up via non-allocating ``has_returned`` flags.
- **Error Unions**: Explicit failure modes for ``UndefinedVariable``, ``UndefinedFunction``, ``TypeMismatch``, ``DivisionByZero``, and ``OutOfGas``.
- **Builtin Host Primitives**: Direct substrate access for console I/O (``print``, ``println``), timing (``clock_ms``), and file descriptors (``read_file``, ``write_file``).

7. Self-Hosting Bootstrap Pipeline
==================================
The self-hosting architecture ensures that Macros can compile itself within MicrOS:

1. **Stage 0 (Freestanding Zig Substrate)**: ``src/macros/`` provides the VM runtime, Immix GC, fiber scheduler, and native JIT/AOT machine code / ELF emitter (``codegen_x86_64.zig``, ``elf_emitter.zig``).
2. **Stage 1 (Pure Macros Compiler)**: ``lib/macros/`` (``ast.mx``, ``lexer.mx``, ``parser.mx``, ``compiler.mx``) parsed and executed by Stage 0, compiling Macros programs to deterministic bytecode chunks.
3. **Stage 2 (Fixed-Point Verification)**: ``lib/macros/compiler.mx`` compiles itself on the VM to produce bit-for-bit identical bytecode chunks (``BLAKE3(Chunk 1) == BLAKE3(Chunk 2)``).
4. **Native Compilation Substrate**: High-frequency bytecode chunks are translated into raw x86_64 machine instructions and relocatable ELF64 objects via the substrate native backend (``codegen_x86_64.zig``, ``elf_emitter.zig``) under strict W^X hardware page protections.

8. Traceability & Acceptance Criteria
=====================================
- **[US-REN-002]**: Verifies execution of ``.mx``/``.macros`` scripts via standalone runner ``/bin/macros`` and shell ``ush``.
- **[US-REN-004]**: Verifies zero-libc substrate determinism, AST construction, and evaluation directly on Linux syscalls.
- **[US-REN-010]**: Verifies green-thread concurrent fiber scheduling and assembly context switching.
- **[US-GEM-008]**: Verifies isolated Immix GC heap partitioning, 256-byte line recycling, and zero memory fragmentation.
- **[US-GEM-010]**: Verifies context-window-optimized architecture with modules under 1,000 lines.
