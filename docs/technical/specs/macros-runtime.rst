============================================
Macros Runtime & Language Specification
============================================

:Document ID: SPEC-TECH-MACROS-001
:Status: Approved
:Traced Stories: [US-REN-002], [US-REN-008], [US-GEM-002], [US-GEM-004]

1. Language Architecture & Pipeline
===================================
The Macros programming language runtime is implemented across four core modules:

- `src/macros/lexer.zig`: Tokenization supporting identifiers, integer literals, binary operators (`+`, `-`, `==`, `=`), delimiters, and EOF.
- `src/macros/ast.zig`: strongly typed AST nodes (`Expression`, `BinaryOp`, `Assignment`, `Identifier`, `NumberLiteral`).
- `src/macros/parser.zig`: Recursive descent parsing with precedence climbing.
- `src/macros/eval.zig`: Tree-walk evaluator with lexical scoping, variable environments, and integer computation.

2. Immix Mark-Region Garbage Collection
=======================================
- `src/macros/immix.zig`: Implements an Immix mark-region memory manager.
- Block Geometry: Memory is partitioned into 32KB blocks containing 256 lines of 128 bytes each.
- Allocation Strategy: Bump-pointer allocation within contiguous line holes during recycling sweeps.
- Large Objects: Allocations exceeding four lines (> 512 bytes) are directly mapped via `sys.mem.map` and tracked in a large allocation list.
- Sweep & Hole Recycling: Fast bitmap sweep transitions marked lines to free states while recalculating available hole cursors.

3. Cooperative Green-Thread Fibers
==================================
- `src/macros/fiber.zig` & `src/macros/context_switch.s`: Userspace cooperative multithreading runtime.
- Fiber Call Stacks: Dedicated 64KB stacks allocated per fiber, aligned to 16-byte System V ABI boundaries.
- Context Switching: Minimal x86_64 assembly preserving callee-saved registers (`rbp`, `rbx`, `r12`-`r15`) and swapping stack pointers.
- Scheduler: Queue-driven non-preemptive scheduler managing `ready`, `running`, `suspended`, and `terminated` fiber lifecycles.
