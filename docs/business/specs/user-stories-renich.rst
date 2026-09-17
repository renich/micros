====================================
User Stories: Rénich (Human Persona)
====================================

:Status: Approved
:Persona: Rénich Bon Ćirić (Principal Infrastructure Architect)
:Traceability: `[US-REN-001]` to `[US-REN-010]`

This document specifies the end-to-end user stories representing human interaction with MicrOS (µOS), MicroShell (`msh`), and the Macros programming language.

.. contents:: Table of Contents
   :depth: 2

[US-REN-001] Interactive Typed Shell Automation
===============================================
* **As a** systems architect,
* **I want** to execute process pipelines where data flows as typed binary structures across memory rings rather than ASCII text streams,
* **So that** I never have to write brittle regexes, `awk`, `sed`, or handle whitespace-splitting bugs in my administrative workflows.

**Acceptance Criteria**:
* MicroShell (`msh`) passes structured objects between commands natively.
* Shell variables retain strong types (`integer`, `boolean`, `string`, `struct`).
* Piped filters execute with zero string serialization overhead.

[US-REN-002] Unified Shell & Application Scripting
==================================================
* **As a** developer and DevOps maintainer,
* **I want** all administrative automation scripts to use the native Macros language (`#!/bin/msh` or `#!/bin/macros`),
* **So that** I don't maintain a separate, second-class shell language with different syntax, scoping rules, and error handling.

**Acceptance Criteria**:
* Scripts written in Macros execute directly from the CLI.
* Identical type inference and standard library available in both interactive and scripted modes.
* Immediate startup with sub-millisecond execution overhead.

[US-REN-003] Sub-Second Immutable UKI Booting
=============================================
* **As an** infrastructure engineer,
* **I want** to boot MicrOS directly from a single cryptographically verifiable Unified Kernel Image (`.efi`) in < 1 second,
* **So that** I can spin up ephemeral sandbox instances and edge compute nodes instantly with guaranteed immutability.

**Acceptance Criteria**:
* UKI binary combines kernel, initramfs, and cmdline into a single PE/COFF image.
* Direct UEFI booting via OVMF in QEMU/KVM without separate bootloader stages.
* Total boot-to-prompt latency < 1.0 second on virtualized hardware.

[US-REN-004] Zero-Libc Substrate Determinism
============================================
* **As a** systems programmer,
* **I want** the substrate layer to interact directly with hardware and kernel syscalls without linking against `libc`,
* **So that** I eliminate hidden global heap state, non-deterministic locale logic, and opaque runtime overhead.

**Acceptance Criteria**:
* Kernel and core userspace binaries contain zero `libc` symbol imports.
* All allocations require an explicit `Allocator` parameter.
* Error states map to explicit Zig error unions.

[US-REN-005] Substrate Memory Audit & Introspection
===================================================
* **As a** site reliability engineer,
* **I want** to query memory page statistics and capability allocations directly from the shell prompt via `mem`,
* **So that** I have instant visibility into virtual memory mappings and page alignment without parsing complex `/proc` files.

**Acceptance Criteria**:
* Builtin `mem` command audits 4096-byte page mappings.
* Page alignment mathematically verified before mapping and unmapping.
* Clean resource reclamation upon command completion.

[US-REN-006] Capability-Bounded Process Supervision
===================================================
* **As a** security architect,
* **I want** processes to receive explicit, unforgeable capability handles for I/O and hardware access,
* **So that** compromised or buggy userspace applications cannot escalate privileges or access unauthorized resources.

**Acceptance Criteria**:
* File descriptors and device rings granted only via explicit parent capabilities.
* Zero ambient root authority; no setuid or unrestricted syscall escalation.
* Clean signal handling and orphan process reaping in PID 1 (`micros-init`).

[US-REN-007] Declarative OS Image Assembly
==========================================
* **As a** distribution architect,
* **I want** to build reproducible OS images, UKIs, and container rootfs images declaratively using GNU make and standard tooling,
* **So that** my build pipelines produce byte-for-byte identical artifacts across development and production.

**Acceptance Criteria**:
* `make all` builds the toolchain, substrate binaries, and shell.
* `make test-qemu` validates execution inside QEMU automatically.
* Artifacts build deterministically without non-hermetic host tool dependencies.

[US-REN-008] Clean Hardware & Virtual Machine Termination
=========================================================
* **As an** SRE,
* **I want** the OS to cleanly signal hardware and hypervisors via ACPI S5 sleep state poweroff upon task completion,
* **So that** CI test runners and automated sandboxes shut down cleanly without kernel panic dumps or hung processes.

**Acceptance Criteria**:
* `sys.process.poweroff()` executes raw poweroff syscall cleanly.
* QEMU virtual machine halts immediately with exit code 0.
* Zero kernel panic traces on normal system halt.

[US-REN-009] Fast Native Developer Toolchain
============================================
* **As a** maintainer,
* **I want** native tools (`micros-lint`, `micros-runner`, `micros-fb-verify`, `micros-sym`) integrated directly into the workspace,
* **So that** I can enforce code quality, run regressions, and debug symbol callstacks without installing heavyweight third-party tools.

**Acceptance Criteria**:
* `make lint` enforces the Ten Commandments of Code Quality natively via AST.
* `make test` runs colocated module unit tests across the entire codebase.
* Substrate tools compile in parallel in < 2 seconds.

[US-REN-010] Green-Thread Concurrent Fiber Scheduling
======================================================
* **As a** real-time systems developer,
* **I want** to spawn thousands of lightweight green threads (fibers) in Macros with M:N scheduling across hardware cores,
* **So that** high-concurrency event loops, network sockets, and shared-memory rings run with minimal stack allocation overhead.

**Acceptance Criteria**:
* Macros runtime supports fiber creation and cooperative yielding.
* Fibers scheduled preemptively without kernel thread creation cost.
* Low memory overhead per fiber stack.
