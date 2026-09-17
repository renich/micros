=======================================================
Sovereign Language Self-Hosting & Native Codegen Spec
=======================================================

:Document ID: SPEC-TECH-LANG-002
:Status: Approved
:Traced Stories: [US-REN-002], [US-REN-004], [US-GEM-008], [US-GEM-010]
:Previous Revision: SPEC-TECH-MACROS-SELF-001

1. Architectural Axioms & Purpose
=================================
A founding principle of MicrOS (µOS) is computational sovereignty: the operating system and its high-level software ecosystem must not depend perpetually on an external host toolchain (such as Zig or LLVM on Linux). The Macros programming language must be capable of compiling, optimizing, and rebuilding itself directly on bare-metal silicon within MicrOS.

1.1 The Cord-Cutting Imperative
-------------------------------
In earlier milestones (0 through 16), Macros programs were parsed and compiled by a bootstrap compiler implemented in freestanding Zig (`src/macros/`). While this bootstrapped the microkernel, capability system, and reactive compositor, relying permanently on a host Zig compiler creates an external supply-chain dependency.

Milestone 17 elevates Macros to a fully self-hosting language with native x86_64 code generation, Immix mark-region garbage collection, and content-addressed module resolution.

2. Three-Stage Bootstrap Architecture
=====================================

.. code-block:: text

   +-------------------------------------------------------------+
   | Stage 0: Freestanding Zig Substrate Compiler (src/macros/)  |
   | Host/Boot VM, Memory Management, Microkernel Integration    |
   +------------------------------+------------------------------+
                                  | Compiles (Stage 1 Source)
   +------------------------------v------------------------------+
   | Stage 1: Pure Macros Compiler (lib/macros/compiler.mx)      |
   | Lexer, Parser, AST, Symbol Table, Bytecode & Native Emitter |
   +------------------------------+------------------------------+
                                  | Compiles Itself (Stage 2)
   +------------------------------v------------------------------+
   | Stage 2: Fixed-Point Self-Hosted Compiler Binary            |
   | Bit-for-Bit Identical Bytecode Hash: H(Stage 1) == H(Stage 2)|
   +-------------------------------------------------------------+

2.1 Stage 0: Freestanding Zig Substrate Compiler
------------------------------------------------
* **Location**: `src/macros/`
* **Responsibilities**:
  1. Bootstraps the initial Macros execution environment directly from bare metal.
  2. Implements the Immix mark-region garbage collector (`src/macros/gc.zig`).
  3. Provides cooperative green-thread fiber scheduling (`src/macros/fiber.zig`).
  4. Exposes the native C-ABI substrate (`src/kernel/abi.zig`) and builtin operations.

2.2 Stage 1: Macros-in-Macros Compiler Source
---------------------------------------------
* **Location**: `lib/macros/`
* **Modules**:
  * `lexer.mx`: Pure Macros tokenizer reading source text buffers and emitting strongly typed token tuples.
  * `parser.mx`: Recursive descent parser constructing structured AST representations.
  * `ast.mx`: AST node constructors and validators (`Fn`, `If`, `While`, `Call`, `Binary`, `Assign`, `Literal`).
  * `compiler.mx`: Symbol table resolver, scope manager, and bytecode emitter.
  * `compiler_main.mx`: Driver CLI reading files or CAS hashes and invoking the compilation pipeline.

2.3 Stage 2: Fixed-Point Verification
-------------------------------------
Fixed-point verification mathematically guarantees deterministic, reproducible builds:

1. Stage 0 compiles ``lib/macros/`` into Bytecode Chunk 1.
2. Bytecode Chunk 1 is executed on the VM, compiling ``lib/macros/`` to produce Bytecode Chunk 2.
3. The BLAKE3 cryptographic hashes of Bytecode Chunk 1 and Bytecode Chunk 2 are computed and compared (``BLAKE3(Chunk 1) == BLAKE3(Chunk 2)``).
4. Any discrepancy indicates non-determinism, undefined behavior, or state leakage across compilation runs.

3. Pure Macros Compiler Pipeline (lib/macros/)
==============================================
The self-hosted compiler implements a clean, modular multi-pass architecture:

3.1 Tokenizer (lexer.mx)
------------------------
The tokenizer converts raw UTF-8 source buffers into token arrays. Each token is encoded as a structured tuple:
``[token_type: int, lexeme: str, line: int]``.

* **Keywords**: ``fn``, ``if``, ``else``, ``while``, ``return``, ``true``, ``false``, ``nil``, ``var``, ``import``.
* **Punctuation & Delimiters**: ``(``, ``)``, ``{``, ``}``, ``[``, ``]``, ``,``, ``;``, ``:``.
* **Operators**: ``+``, ``-``, ``*``, ``/``, ``==``, ``!=``, ``<``, ``<=``, ``>``, ``>=``, ``=``, ``and``, ``or``, ``not``.
* **Literals**: Integer constants, double-quoted string literals, and identifiers.

3.2 Recursive Descent Parser (parser.mx)
----------------------------------------
The parser validates grammar and constructs AST nodes without global variable mutation:

* **Program**: Sequence of top-level declarations (functions, statements).
* **Function Declarations**: ``fn name(arg1, arg2) { ... }``.
* **Statements**: Variable assignments, conditional branching (``if``/``else``), iterative loops (``while``), return statements, and expression statements.
* **Expressions**: Binary operations with standard precedence, function calls, local/global variable lookups, array literals, and grouping parentheses.

3.3 Symbol Table & Scope Management (compiler.mx)
-------------------------------------------------
The compiler maintains an explicit compiler state tuple:
``state = [code_bytes, constants_pool, locals_table, scope_depth]``.

* **Locals Resolution**: Scans the locals table backwards from the current scope depth to resolve stack slots. Emits ``OP_GET_LOCAL`` / ``OP_SET_LOCAL`` with stack offset.
* **Globals Resolution**: If an identifier is not found in the local scope, adds the identifier name to the constant pool and emits ``OP_GET_GLOBAL`` / ``OP_SET_GLOBAL``.
* **Control Flow Patching**: Emits placeholder forward jumps (``OP_JUMP``, ``OP_JUMP_IF_FALSE``) and tracks patch offsets, backpatching the 16-bit displacement once the target block is compiled.

4. Immix Mark-Region Garbage Collector Substrate (src/macros/gc.zig)
====================================================================
Memory management for actor compilation passes is provided by the Immix mark-region collector, combining the high throughput of bump-pointer allocation with the zero-fragmentation space reclamation of mark-sweep.

4.1 Block & Line Architecture
-----------------------------
* **Block Size**: 32 KiB (``BLOCK_SIZE = 32768``), page-aligned to 4096 bytes (``align(4096)``).
* **Line Size**: 256 bytes (``LINE_SIZE = 256``).
* **Lines Per Block**: 128 lines (``LINES_PER_BLOCK = 128``).
* **Line Mark Table**: Byte array tracking allocation and liveness states (``FREE``, ``ALLOCATED``, ``MARKED``).

4.2 Bump Allocation & Hole Recycling
------------------------------------
Allocation proceeds via bump-pointer cursor within unallocated lines of the active block:

* If the current line is free, the cursor advances linearly.
* When the cursor reaches a marked line (occupied by surviving objects), it hops forward to find the next contiguous run of free lines ("hole").
* If no hole in the active block can accommodate the allocation request, the allocator requests a new 32 KiB block from the kernel PMM.
* Objects exceeding 4 KiB are allocated directly in the Large Object Space (LOS) to prevent fragmentation of the line allocator.

4.3 Precise Root & Stack Tracing
--------------------------------
The garbage collector performs precise root tracing:

1. **Fiber Call Stacks**: Traverses every active fiber frame, inspecting local variable slots and operand stack values.
2. **Global Symbol Tables**: Traverses the global environment map of each VM domain.
3. **Chunk Constants**: Traces all constants referenced by active bytecode chunks.
4. **Mark Bit Propagation**: Recursively traces referenced objects (arrays, strings, closures, custom structures) marking their corresponding line entries.

4.4 Sweep & Compaction Threshold
--------------------------------
* **Sweeping**: Fast linear scan over the line mark tables. Blocks with 100% free lines are returned immediately to the free block pool. Blocks with partial occupancy are flagged for hole-recycling allocation.
* **Sub-Millisecond Pauses**: Because lines rather than individual objects are swept, GC pause times during intensive actor compilation passes remain strictly bounded under 1 millisecond.

5. Freestanding x86_64 Direct Machine Code Generator (src/macros/codegen_x86_64.zig)
====================================================================================
To provide maximum performance for compute-intensive actors, the runtime includes a native code generator compiling high-frequency bytecode opcodes directly into raw x86_64 machine instructions.

5.1 Native Instruction Mapping
------------------------------
* **Integer Arithmetic**:

   * ``OP_ADD`` -> ``mov rax, [rsp-16]; add rax, [rsp-8]; mov [rsp-16], rax; sub rsp, 8``
   * ``OP_SUB`` -> ``mov rax, [rsp-16]; sub rax, [rsp-8]; mov [rsp-16], rax; sub rsp, 8``

* **Local Variable Access**:

   * ``OP_GET_LOCAL slot`` -> ``mov rax, [rbp - (slot + 1)*8]; push rax``
   * ``OP_SET_LOCAL slot`` -> ``mov rax, [rsp]; mov [rbp - (slot + 1)*8], rax``

* **Control Flow**:

   * ``OP_JUMP offset`` -> ``jmp rel32``
   * ``OP_JUMP_IF_FALSE offset`` -> ``pop rax; test rax, rax; jz rel32``

* **CSpace Capability Invocation**: Emits direct SysV ABI function calls into the native microkernel ABI table (``src/kernel/abi.zig``), passing parameters in ``rdi``, ``rsi``, ``rdx``, ``rcx``, ``r8``, ``r9``.

5.2 Strict W^X Memory Protection
--------------------------------
The code generator strictly adheres to the Write XOR Execute security invariant:

1. Native code buffers are allocated from the kernel PMM with Write permission (``PAGE_PRESENT | PAGE_WRITABLE``).
2. Machine instructions are emitted into the memory buffer.
3. Before execution, the page table entry is modified to revoke Write permission and grant Execute permission (``PAGE_PRESENT | PAGE_USER``, removing ``PAGE_WRITABLE`` and clearing ``NO_EXECUTE``).
4. Any attempt to modify code during execution triggers a CPU Page Fault (#PF, Vector 14), preventing JIT spray and code-injection attacks.

6. Content-Addressed Module Protocol (src/macros/module.zig)
============================================================
Traditional operating systems resolve code modules using mutable, hierarchical filesystem paths (``import "../utils/math.mx"``). MicrOS replaces path-based imports with immutable cryptographic content addresses:

6.1 Cryptographic Import Syntax
-------------------------------
.. code-block:: text

   // Import module by cryptographic BLAKE3 content hash
   import cas("b3:a4f8c2e1...");

   // Import module bundled in the sovereign Genesis MCB
   import bundle("compiler.mx");

6.2 CAS Module Resolution Pipeline
----------------------------------
1. When an ``import`` expression is evaluated, the runtime checks the in-memory module cache.
2. If absent, the module resolver queries the Sovereign Storage Substrate (VirtIO-Blk CAS engine) using the 256-bit BLAKE3 hash.
3. The raw source or precompiled bytecode is retrieved from verified immutable block storage.
4. The module is compiled in an isolated capability domain and its public symbol exports are bound to the caller's namespace.
5. This guarantees complete immunity against dependency drift, supply-chain attacks, and environmental discrepancies.

7. Verification & Ten Commandments Adherence
============================================
The implementation must adhere strictly to the MicrOS Ten Commandments (``AGENTS.md``):

* **File Size**: No compiler or runtime module shall exceed 1,000 lines of code.
* **Function Size**: Every function must strictly remain <= 40 lines. Complex parsing steps must be factored into discrete helper functions.
* **Nesting Depth**: Indentation depth must not exceed 3 levels.
* **Memory & Alignment**: All block allocations and executable code pages must mathematically enforce 4096-byte page alignment (``align(4096)``).
* **Zero Libc**: All code generator and GC routines operate entirely freestanding without C library dependencies.
* **Automated Verification**:

   * ``make check``: 100% unit tests, tools tests, Ten Commandments linting, formatting, and spec traceability.
   * ``tools/micros-runner.bash``: QEMU headless boot verifying self-hosted compiler execution and stage verification.
