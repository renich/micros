===========================================
MicrOS (µOS) Master Technical Specification
===========================================

:Status: Approved
:Version: 1.0.0
:Date: 2026-09-16

Technical Architecture Overview
===============================
This specification defines the substrate engineering standards, the Macros programming language runtime, the MicroShell (`msh/ush`) interaction interface, and the deterministic verification toolchain for MicrOS (µOS).

Technical Sub-Specifications
============================

.. toctree::
   :maxdepth: 2
   :caption: Subsystem Specifications

   specs/substrate-sys
   specs/macros-lang
   specs/macros-runtime
   specs/self-hosting-macros
   specs/microshell-msh
   specs/toolchain
   specs/sovereign-capability-substrate
   specs/sovereign-harness-protocol
   specs/sovereign-gemini-orchestrator
   specs/sovereign-interactive-harness
   specs/sovereign-storage-substrate
   specs/sovereign-tool-calling
   specs/process-hierarchy
   specs/reactive-compositor

Engineering & Coding Guides
===========================

.. toctree::
   :maxdepth: 1
   :caption: Engineering Guides

   code-guide
   code-guide-es

Core Architecture Principles
============================
1. **Zero-Libc Substrate Isolation**: The substrate layer (`src/sys/`) invokes Linux x86_64 kernel syscalls directly without C runtime or glibc dependencies.
2. **Deterministic Mark-Region Memory**: The Macros language utilizes an Immix mark-region garbage collector (32KB blocks, 128B lines) enabling zero-fragmentation allocation and rapid hole recycling.
3. **Cooperative Green-Thread Concurrency**: Execution multiplexing is handled via userspace fiber context switching, avoiding kernel thread scheduling overhead.
4. **Typed Shared-Memory IPC**: Inter-process and agent-human communication operates over structured ring buffers with explicit binary schemas.
5. **Unified Kernel Image (UKI) Delivery**: Bootable EFI artifacts package systemd-stub, Linux kernel, and MicrOS initramfs into a single verified UEFI binary.
