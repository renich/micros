==========================
MicrOS (µOS) User Personas
==========================

:Status: Approved
:Version: 1.0.0
:Date: 2026-09-16

This document defines the primary user personas for MicrOS (µOS). MicrOS is architected from the ground up to provide a dual-native runtime for both human systems architects and autonomous AI engineering agents.

.. contents:: Table of Contents
   :depth: 2

Persona 1: Rénich (The Human Systems Architect)
================================================

.. list-table::
   :widths: 25 75
   :header-rows: 1

   * - Attribute
     - Details

   * - **Name & Role**
     - Rénich Bon Ćirić, Principal Infrastructure Architect & FOSS Maintainer

   * - **Primary Goals**
     - Absolute technological sovereignty, verifiable reproducible builds, immutable UKI deployments, elimination of Unix legacy bloat (untyped byte-stream pipes, ad-hoc shell scripting, hidden libc allocations).

   * - **Operational Environment**
     - Fedora Linux, Wayland, Native QEMU/KVM virtualized test harnesses, UEFI hardware bare-metal nodes.

   * - **Key Frustrations**
     - Fragile regular-expression text parsing in shell scripts, non-deterministic system state, multi-gigabyte OS footprint for minimal workloads, unverified AI code generation.

   * - **MicrOS Value Proposition**
     - Sub-second boot times (< 100ms on bare-metal / < 800ms in QEMU), typed shared-memory ring pipelines (MicroShell), unified Macros application language, capability-bounded security posture, and mathematical code-quality verification.

Persona 2: Gemini (The Autonomous AI Systems Engineer)
======================================================

.. list-table::
   :widths: 25 75
   :header-rows: 1

   * - Attribute
     - Details

   * - **Name & Role**
     - Gemini / Antigravity Agent, Autonomous AI Systems & Substrate Engineer

   * - **Primary Goals**
     - Deterministic system observability, capability-bounded code execution, direct AST manipulation without fragile regexes, real-time binary crash telemetry, and rapid iterative self-healing.

   * - **Operational Environment**
     - Headless QEMU monitor sockets, shared-memory telemetry rings (`/dev/shm`), automated PJP journaling (`ajourn`), AST static analysis (`micros-lint`).

   * - **Key Frustrations**
     - Unstructured stdout/stderr log parsing, indeterminate race conditions, memory leaks in C runtime libraries, non-reproducible environment side effects.

   * - **MicrOS Value Proposition**
     - Unforgeable 64-byte `TelemetryToken` binary rings, isolated Immix GC heap regions, deterministic crash state dumps, and a minimal < 1000-line modular codebase optimized for AI context windows.
