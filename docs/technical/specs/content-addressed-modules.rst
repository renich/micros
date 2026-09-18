========================================================================
Content-Addressed & Workspace Module System (Macros Language Substrate)
========================================================================

:Document ID: SPEC-TECH-LANG-003
:Status: Approved
:Traced Stories: [US-REN-001], [US-REN-002], [US-REN-004], [US-REN-006], [US-GEM-001], [US-GEM-009], [US-GEM-010]
:Parent Architecture: `SPEC-TECH-LANG-001`, `SPEC-TECH-LANG-002`, `SPEC-TECH-FS-001`
:Module Targets: ``src/macros/chunk.zig``, ``src/macros/compiler.zig``, ``src/macros/vm.zig``, ``src/macros/eval.zig``, ``lib/macros/lexer.mx``, ``lib/macros/parser.mx``, ``lib/macros/compiler.mx``

1. Architectural Axioms & Purpose
=================================
This specification defines the syntax, bytecode opcodes, and runtime execution semantics for content-addressed module resolution, circular dependency containment, and namespace encapsulation in the Macros programming language.

1.1 Content-Addressed Machine Engineering Doctrine
--------------------------------------------------
Under traditional programming runtimes, module imports rely on hierarchical, mutable POSIX file paths, symlinks, search paths (``$PATH``, ``$NODE_PATH``, ``PYTHONPATH``), and centralized package registries. In MicrOS:

* **Dual Resolution Semantics**:
  1. **Workspace Catalog Paths**: ``import "math.mx";`` or ``import "crypto/sha.mx";`` resolves through the active Merkle Workspace Catalog (``SPEC-TECH-FS-001``) or fallback Genesis Bundle to a definitive 256-bit BLAKE3 hash.
  2. **Direct Immutable CAS Hashes**: ``import "b3/a1b2c3...64hex";`` resolves directly to an immutable Content-Addressed Storage chunk without path indirection or directory structures.
* **Deterministic Object Isolation**: All imports evaluate as expressions returning a ``Module`` object—a sealed key-value map of exported identifiers. Global namespaces are never polluted by imports.
* **Bounded Cycle Detection**: The runtime maintains an explicit state machine for each active compilation unit (``Compiling`` vs ``Ready``). Circular references halt deterministically with an explicit error rather than recursing infinitely or deadlocking fibers.
* **Zero-Libc Freestanding Memory**: Module compilation, bytecode caching, and export mapping allocate strictly through the caller's explicit ``std.mem.Allocator``.

2. Syntax & Grammar Specifications
==================================

2.1 Import Expressions & Statements
-----------------------------------
An import is parsed as an expression or statement:

.. code-block:: text

   ImportStmt := "import" StringLiteral ( "as" Identifier )? ";"
   ImportExpr := "import" "(" StringLiteral ")"

Examples:

.. code-block:: text

   // Binds exported table to local variable 'math'
   m = import "math.mx";
   result = m.sqrt(16);

   // Direct CAS hash import
   crypto = import "b3/7b189283e7482619472618492048162837461829471629471829374618293746";
   hash = crypto.blake3("payload");

2.2 Export Statements
---------------------
Modules export functions, constants, or variables using the ``export`` keyword:

.. code-block:: text

   ExportStmt := "export" ( FnDecl | VarDecl | Identifier ) ";"

Examples:

.. code-block:: text

   export fn add(a, b) {
       return a + b;
   }

   export PI = 314159;

3. Resolution & Cycle Detection Engine
======================================

3.1 Resolution Protocol
-----------------------
When resolving a module reference string ``S``:
1. If ``S`` starts with ``"b3/"``:
   - Slice ``S[3..]`` as a 64-character hexadecimal BLAKE3 hash.
   - Verify valid hexadecimal encoding and parse into ``[32]u8``.
   - Retrieve raw source payload directly from CAS using ``sys_cas_get(hash)``.
2. Otherwise (catalog or relative path):
   - Query the Merkle Workspace Catalog via ``sys_catalog_read(S)``.
   - If not found in the workspace catalog, query the Genesis Bundle via ``sys_bundle_read(S)``.
   - Compute or retrieve the BLAKE3 digest of the retrieved source.

3.2 Compilation State Machine
-----------------------------
Modules are tracked in a VM-local cache keyed by ``[32]u8`` BLAKE3 hash:

.. code-block:: text

   [Unseen Hash]
         |
         | (Encounter import)
         v
   [State: Compiling]  ----(Encounter identical hash during compile)----> [Error: CircularDependency]
         |
         | (Execute top-level module code & collect exports)
         v
   [State: Ready]      ----(Subsequent imports)------------------------> [Return Cached Module Object]

4. Bytecode ISA Extensions
==========================

4.1 Opcode Definitions
----------------------

* ``op_import (const_idx: u16)``:
  Pushes the module object returned by resolving, compiling, and executing the module string at ``chunk.constants[const_idx]``.
* ``op_export (name_idx: u16)``:
  Pops the value on top of the stack and registers it under the string identifier ``chunk.constants[name_idx]`` within the current module frame's export table.

4.2 Runtime Data Structures
---------------------------

.. code-block:: zig

   pub const ModuleState = enum(u8) {
       compiling,
       ready,
   };

   pub const ModuleEntry = struct {
       state: ModuleState,
       exports: *ObjMap,
   };

   pub const ModuleCache = struct {
       allocator: std.mem.Allocator,
       entries: std.AutoHashMapUnmanaged([32]u8, ModuleEntry),
   };

5. Verification & Traceability Matrix
=====================================
* ``[US-REN-001]``: Strong typing and structured object passing across module boundaries.
* ``[US-REN-002]``: Unified Macros scripting across standalone files and system modules.
* ``[US-REN-004]``: Zero-libc deterministic compilation and module execution.
* ``[US-REN-006]``: Module encapsulation without ambient filesystem authority.
* ``[US-GEM-001]``: Direct BLAKE3 CAS hash imports for machine-synthesized programs.
* ``[US-GEM-009]``: Bounded cycle containment and graceful failure reporting.
* ``[US-GEM-010]``: Context-window-optimized module boundaries (files <= 1,000 lines, functions <= 40 lines).
