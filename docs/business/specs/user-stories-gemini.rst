====================================
User Stories: Gemini (AI Persona)
====================================

:Status: Approved
:Persona: Gemini / Antigravity Agent (Autonomous AI Systems Engineer)
:Traceability: `[US-GEM-001]` to `[US-GEM-010]`

This document specifies the user stories defining how autonomous AI agents interface with, observe, develop, and self-heal the MicrOS (µOS) substrate and Macros runtime.

.. contents:: Table of Contents
   :depth: 2

[US-GEM-001] Binary Telemetry Stream Ingestion
==============================================
* **As an** autonomous AI agent,
* **I want** the kernel and substrate to emit unforgeable, fixed-size 64-byte binary telemetry tokens over shared-memory rings,
* **So that** I can ingest real-time machine execution events, CPU state, and capability faults without parsing lossy, unstructured ASCII text.

**Acceptance Criteria**:
* Telemetry frames adhere strictly to the 64-byte `TelemetryToken` binary ABI.
* Ring buffers operate lock-free in shared memory (`/dev/shm`).
* Decoded instantly via `micros-telem` into structured JSON for LLM ingestion.

[US-GEM-002] Deterministic Milestone Sentinel Detection
=======================================================
* **As an** automated testing agent,
* **I want** the headless test harness (`micros-runner`) to parse serial streams for exact milestone sentinels,
* **So that** I verify test execution in sub-second time without relying on arbitrary, non-deterministic sleep timers.

**Acceptance Criteria**:
* `micros-runner` terminates QEMU immediately upon matching `$EXPECT`.
* Real-time regex detection of kernel panics and fatal exceptions (`$FAIL_PATTERN`).
* Execution times under 1.0 second on local KVM hypervisors.

[US-GEM-003] AST-Native Code Quality Enforcement
================================================
* **As an** AI pair programmer,
* **I want** a native AST static linter (`micros-lint`) that parses Zig syntax via `std.zig.Ast`,
* **So that** I receive deterministic, line-exact feedback on code quality constraints (file size, function length, nesting depth) before committing code.

**Acceptance Criteria**:
* Rejects any file exceeding 1,000 lines of code.
* Rejects any function exceeding 40 lines of code.
* Rejects indentation / control-flow nesting exceeding 3 levels.
* Prohibits forbidden names (`utils.zig`, `helpers.zig`) and `catch unreachable`.

[US-GEM-004] Direct QEMU Monitor Diagnostic Inspection
======================================================
* **As a** diagnostic debugging agent,
* **I want** to connect non-interactively to the QEMU monitor Unix domain socket during a VM hang or fault,
* **So that** I can inspect CPU register state (RAX-R15, CR0-CR4, RIP) and disassemble instructions around the crash point.

**Acceptance Criteria**:
* `micros-inspect` connects to `/tmp/micros-qemu-mon.sock` non-interactively.
* Exports register state and disassembled assembly into structured JSON.
* Enables autonomous AI root-cause diagnosis without manual human intervention.

[US-GEM-005] Freestanding ELF Symbol Resolution
===============================================
* **As a** crash analysis agent,
* **I want** to resolve raw instruction pointer addresses (`0x002014d4`) directly against the kernel `.symtab` / `.strtab`,
* **So that** I can reconstruct callstacks and identify faulty function names without external GNU `addr2line` or `llvm-symbolizer`.

**Acceptance Criteria**:
* `micros-sym` parses 64-bit ELF symbol tables directly in pure Zig.
* Maps hex addresses in crash logs to `function_name + offset`.
* Supports batch and stream log filtering.

[US-GEM-006] Sub-Millisecond Framebuffer Visual Auditing
========================================================
* **As a** visual verification agent,
* **I want** to validate raw PPM screendumps captured from QEMU's GOP framebuffer via `micros-fb-verify`,
* **So that** I can verify graphical rendering and UI correctness deterministically without heavy headless browser or Python dependencies.

**Acceptance Criteria**:
* `micros-fb-verify` parses binary PPM files in sub-millisecond time.
* Validates resolution, color variance, and bounding-box color thresholds.
* Fails fast if the framebuffer is blank, corrupt, or distorted.

[US-GEM-007] Bidirectional Specification Traceability
=====================================================
* **As an** architectural compliance agent,
* **I want** an automated traceability auditor (`micros-spec-trace`) to map Business Stories, Functional Specs, Technical Blueprints, and Roadmap Tasks,
* **So that** I prevent scope creep, detect untraced code, and ensure 100% specification coverage.

**Acceptance Criteria**:
* Validates unique tag links (`[US-xxx]`, `[FUNC-xxx]`, `[TECH-xxx]`, `[TASK-xxx]`).
* Flags orphaned requirements and broken document links with non-zero exit codes.
* Generates full traceability matrix for release audits.

[US-GEM-008] Isolated Immix GC Heap Partitioning
================================================
* **As an** AI runtime manager,
* **I want** the Macros language Immix garbage collector to manage isolated heap blocks with precise line marking,
* **So that** memory reclamation is predictable, fragmentation is eliminated, and GC pauses remain sub-millisecond.

**Acceptance Criteria**:
* Mark-region Immix GC manages 32KB blocks and 128-byte lines.
* Zero stop-the-world pauses exceeding 1ms for interactive fibers.
* Explicit memory reclamation without memory fragmentation.

[US-GEM-009] Self-Healing Script Execution in MicroShell
========================================================
* **As an** autonomous operations agent,
* **I want** to pipe multi-line Macros scripts into `msh` and receive strongly typed return values (`Value` unions) and explicit errors,
* **So that** I can dynamically synthesize, evaluate, and self-heal automation routines with zero ambiguity.

**Acceptance Criteria**:
* Piped scripts execute sequentially with state preservation in `Environment`.
* Explicit error unions returned on parser or evaluation failures.
* Interactive feedback loops enable instant patch validation.

[US-GEM-010] Context-Window-Optimized Architecture
==================================================
* **As an** LLM coding agent,
* **I want** every module file to remain under 1,000 lines and use domain-driven naming with zero boilerplate,
* **So that** entire subsystem contexts fit comfortably within model attention windows without truncation or retrieval degradation.

**Acceptance Criteria**:
* All subsystem packages bounded by explicit domain boundaries (`sys/io.zig`, `macros/eval.zig`, `msh/shell.zig`).
* Zero monolithic "god files" or generic `utils` packages.
* Documentation and tests colocated alongside code for zero-shot reasoning.
