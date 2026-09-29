============================================
Macros Runtime & Language Specification
============================================

:Document ID: SPEC-TECH-MACROS-001
:Status: Approved
:Traced Stories: [US-REN-002], [US-REN-004], [US-REN-010], [US-GEM-008]

1. Language Architecture & Pipeline
===================================
The Macros programming language runtime is implemented across four core modules:

- `src/macros/lexer.zig`: Tokenization supporting identifiers, integer literals, binary operators (`+`, `-`, `==`, `=`), delimiters, and EOF.
- `src/macros/ast.zig`: strongly typed AST nodes (`Expression`, `BinaryOp`, `Assignment`, `Identifier`, `NumberLiteral`).
- `src/macros/parser.zig`: Recursive descent parsing with precedence climbing.
- `src/macros/eval.zig`: Tree-walk evaluator with lexical scoping, variable environments, and integer computation.

2. Immix Mark-Region Garbage Collection
=======================================
- `src/macros/gc.zig`: Implements an Immix mark-region memory manager.
- Block Geometry: Memory is partitioned into 32KB blocks containing 128 lines of 256 bytes each (``BLOCK_SIZE = 32768``, ``LINE_SIZE = 256``, ``LINES_PER_BLOCK = 128``), page-aligned to 4096 bytes.
- Allocation Strategy: Bump-pointer allocation within contiguous line holes during recycling sweeps.
- Large Objects: Allocations exceeding 4 KiB (``LARGE_OBJECT_THRESHOLD = 4096``) are allocated in the Large Object Space (LOS).
- Sweep & Hole Recycling: Fast bitmap sweep transitions marked lines to free states while recalculating available hole cursors. Default trigger threshold is 64 KiB scaling by 2x up to a 16 MiB heap ceiling.

3. Cooperative Green-Thread Fibers & Bounded Execution
======================================================
- `src/macros/fiber.zig` & `src/macros/context_switch.s`: Userspace cooperative multithreading runtime.
- Fiber Call Stacks: Dedicated 2MB stacks provisioned per fiber with 4096-byte guard page (``STACK_SIZE = 2097152``, ``GUARD_SIZE = 4096``), aligned to 4096-byte boundaries.
- Context Switching: Minimal x86_64 assembly preserving callee-saved registers (`rbp`, `rbx`, `r12`-`r15`) and swapping stack pointers.
- Execution Bounding: Cooperative preemption quantum of 1024 instructions (``PREEMPTION_QUANTUM = 1024``) yielding the CPU, combined with dynamic instruction gas metering trapping with ``error.OutOfGas``.
- Scheduler: Queue-driven non-preemptive scheduler managing `ready`, `running`, `suspended`, and `terminated` fiber lifecycles.
