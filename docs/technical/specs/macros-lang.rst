=========================================
Macros Language Formal Specification
=========================================

:Document ID: SPEC-TECH-MACROS-LANG-001
:Status: Approved
:Traced Stories: [US-REN-002], [US-REN-008], [US-GEM-002], [US-GEM-004], [US-GEM-009]
:File Extensions: ``.mx``, ``.macros``

1. Executive Summary & Design Principles
========================================
Macros (``macros``) is the high-level, computationally sovereign programming language of MicrOS (µOS). It is designed to serve as both an interactive orchestration environment for human architects and AI agents, and a standalone systems application language capable of self-hosting and direct kernel interaction.

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
  - Arithmetic: ``+``, ``-``, ``*``, ``/``
  - Equality: ``==``, ``!=``
  - Relational: ``<``, ``<=``, ``>``, ``>=``
  - Assignment: ``=``
- **Delimiters & Punctuation**: ``(``, ``)``, ``{``, ``}``, ``[``, ``]``, ``,``, ``;``, ``:``.

3. Syntax & Formal Grammar (EBNF)
=================================

.. code-block:: ebnf

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
   Expression     ::= Primary (BinaryOp Primary)*
   BinaryOp       ::= "+" | "-" | "*" | "/" | "==" | "!=" | "<" | "<=" | ">" | ">="
   Primary        ::= Number | String | Boolean | Identifier | CallExpr | "(" Expression ")"
   CallExpr       ::= Identifier "(" ArgumentList? ")"
   ArgumentList   ::= Expression ("," Expression)*
   Number         ::= [0-9]+
   Boolean        ::= "true" | "false"

4. Memory Management & Immix GC Architecture
============================================
The Macros memory subsystem is managed by the Immix mark-region garbage collector (``src/macros/immix.zig``):

- **Block Structure**: 32KB blocks containing 256 lines of 128 bytes each.
- **Line State**: Each line maintains a status byte indicating whether it is free, marked live, or part of a multi-line object.
- **Allocation Strategy**: Small objects ($\le 512$ bytes) use bump-pointer cursors within contiguous free line holes. Large objects (> 512 bytes) are directly mapped via ``src/sys/mem.zig`` page allocation.
- **Garbage Collection Cycle**: Stop-the-world mark phase followed by linear line bitmap sweep. Contiguous unmarked lines are coalesced into allocation holes without compaction overhead.

5. Fiber Concurrency Runtime
============================
Macros provides lightweight, cooperative green-thread fibers (``src/macros/fiber.zig``):

- **Stack Allocation**: Each fiber is provisioned with a 64KB stack aligned to 16-byte System V AMD64 ABI boundaries.
- **Context Switch Assembly**: Callee-saved registers (``rbp``, ``rbx``, ``r12``, ``r13``, ``r14``, ``r15``) are saved on the outgoing stack; the stack pointer (``rsp``) is swapped in ``src/macros/context_switch.s``.
- **Non-Preemptive Scheduling**: A FIFO ready-queue schedules active fibers upon explicit yield or I/O suspension.

6. Evaluator & Runtime Execution Semantics
==========================================
The tree-walk evaluation engine (``src/macros/eval.zig``) provides:

- **Lexical Scoping**: Chained parent-child environment lookup with immutable identifier isolation across function invocations.
- **Control Flow Bubbling**: Function returns bubble up via non-allocating ``has_returned`` flags.
- **Error Unions**: Explicit failure modes for ``UndefinedVariable``, ``UndefinedFunction``, ``TypeMismatch``, and ``DivisionByZero``.
- **Builtin Host Primitives**: Direct substrate access for console I/O (``print``, ``println``), timing (``clock_ms``), and file descriptors (``read_file``, ``write_file``).

7. Self-Hosting Bootstrap Pipeline
==================================
The self-hosting architecture ensures that Macros can compile itself within MicrOS:

1. **Stage 0 (Freestanding Zig Substrate)**: ``src/macros/`` executes Stage 1 compiler scripts.
2. **Stage 1 (Macros-in-Macros Compiler)**: ``lib/macros/`` (``ast.mx``, ``lexer.mx``, ``parser.mx``, ``compiler.mx``) parsed and evaluated by Stage 0.
3. **Stage 2 (Native Machine/Bytecode)**: Emits native ELF binaries or optimized bytecode for direct PID 1 substrate execution.
4. **Fixed-Point Verification**: Verification that Stage 1 and Stage 2 emit bit-identical binaries.

8. Traceability & Acceptance Criteria
=====================================
- **[US-REN-002]**: Verifies execution of ``.mx``/``.macros`` scripts via standalone runner ``/bin/macros`` and shell ``msh``.
- **[US-REN-008]**: Verifies zero memory fragmentation and deterministic line recycling via Immix GC.
- **[US-GEM-002]**: Verifies cooperative fiber dispatch and assembly context switching.
- **[US-GEM-004]**: Verifies AST construction, recursive descent parsing, and evaluation without libc.
- **[US-GEM-009]**: Verifies self-hosting compiler compilation and execution pipeline.
