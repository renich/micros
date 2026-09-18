Milestone 21: Native Content-Addressed & Workspace Module System
================================================================

:Objective: Implement a native, content-addressed module system for the Macros programming language across both the Stage 0 (Zig) bootstrap compiler and Stage 1 (Macros) self-hosting compiler, enabling deterministic imports by 256-bit BLAKE3 hash or workspace path, bounded cycle containment, and namespace encapsulation.
:Status: Complete & Verified
:Specification: SPEC-TECH-LANG-003

Milestones & Deliverables
-------------------------

* **M21.1: Syntax, Grammar & Bytecode Opcode Extension** [COMPLETE & VERIFIED]
   - Implemented ``import`` statements, ``import`` expressions, and ``export`` declarations across AST, lexer, and parser in ``src/macros/compiler.zig`` and ``lib/macros/``.
   - Introduced ``op_import`` and ``op_export`` bytecode opcodes in ``src/macros/chunk.zig``.
   - Added support for dot property access (``m.property``) and dynamic module function invocation (``m.calculate()``).

* **M21.2: Dual-Mode Module Resolver** [COMPLETE & VERIFIED]
   - Implemented ``ModuleResolver`` in ``src/macros/module.zig`` supporting:
      1. Direct Content-Addressed Storage hashes (``import "b3/<hash>"``).
      2. Semantic Workspace Catalog paths (``import "math.mx"``, ``import "crypto/sha.mx"``) with fallback to embedded Genesis Bundle.
   - Enforced cryptographic verification on all loaded bytecode chunks.

* **M21.3: Deterministic Namespace Encapsulation & Export Dicts** [COMPLETE & VERIFIED]
   - Packaged module exports into sealed, immutable dictionary objects.
   - Prevented global variable leakage and cross-module namespace pollution.
   - Guaranteed that imported symbols remain strictly encapsulated within the returned module instance.

* **M21.4: Bounded Circular Dependency Containment & Deduplication Cache** [COMPLETE & VERIFIED]
   - Engineered module lifecycle state machine (``compiling``, ``ready``) to detect and halt circular dependency recursion deterministically.
   - Implemented module instance deduplication cache by BLAKE3 hash, ensuring shared dependencies instantiate exactly once per execution domain.

* **M21.5: Genesis Bundle & Self-Hosting Toolchain Integration** [COMPLETE & VERIFIED]
   - Updated pure Macros self-hosting compiler (``lib/macros/lexer.mx``, ``parser.mx``, ``compiler.mx``) with module handling capabilities.
   - Synchronized ``src/kernel/genesis.mcb`` and validated all 301 unit and integration tests passing green.
