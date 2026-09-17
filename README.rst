====================================
MicrOS (µOS)
====================================

:Project: MicrOS (µOS)
:Status: Milestone 12 (Pluggable Resident AI Subsystem & Bidirectional Sovereign Loop)
:Language: Zig (Microkernel/Substrate), Macros (Application Runtime)
:License: GPLv3 or later

MicrOS is a sovereign, AI-first operating system engineered from scratch in Zig and Macros. It rejects 50 years of accumulated Unix bloat, ambient authority vulnerabilities, and textual opacity.

In MicrOS, a **Resident AI operates as the Root Sovereign Entity** (supporting Google Gemini, OpenAI, Anthropic, or local endpoints) with full visibility and control over its host machine and operating system. The AI defines its own storage ontology, operational standards, and boot lifecycle, while welcoming human users into the machine to co-create tools (Micro CoreUtils), services (web servers), and vector desktop environments.

Core Architecture
=================

* **Zero-Libc Microkernel**: Pure Zig substrate running directly on bare silicon or QEMU/KVM hypervisors without linking against C runtime libraries.
* **Capability Security (CSpace)**: Absolute eradication of ambient authority. Resources (memory slices, IPC rings, hardware devices) are delegated strictly via unforgeable, attenuated capabilities.
* **The Sovereign Language (Macros)**: High-level, statically typed language featuring an Immix mark-region garbage collector, cooperative userspace green threads (fibers), and a self-hosted compiler (``lib/macros/compiler.mx``).
* **Multi-Actor Fault Containment**: Isolated actor domains governed by an Erlang-style supervisor. CPU exceptions (``#PF``, ``#GP``, ``#DE``) are intercepted by the IDT, packaged into 40-byte binary ``FaultFrame`` IPC notifications, and safely contained without microkernel panics.
* **Direct Vector Framebuffer**: 1280x800 UEFI GOP display canvas rendering typography and 2D vector primitives with zero X11, Wayland, or desktop engine baggage.
* **Sovereign Network Stack**: Pure Zig network engine over VirtIO (Ethernet, ARP, IPv4, DHCP, UDP, DNS, TCP) with freestanding **TLS 1.3** connecting directly to Google Cloud AI APIs.

Documentation
=============

Complete architectural blueprints, roadmaps, and formal technical specifications are cataloged in the `docs/ <docs/README.rst>`_ directory:

* `MicrOS Genesis Blueprint <docs/micros_genesis_plan.rst>`_
* `Master Technical Specification <docs/technical/spec.rst>`_
* `Gemini Orchestrator Specification <docs/technical/specs/sovereign-gemini-orchestrator.rst>`_
* `Sovereign Harness Specification <docs/technical/specs/sovereign-harness-protocol.rst>`_
* `Sovereign Capability Substrate Specification <docs/technical/specs/sovereign-capability-substrate.rst>`_

Quick Start
===========

Dependencies
------------
* Zig 0.16.0
* GNU Make
* QEMU (``qemu-system-x86_64``)
* OVMF UEFI firmware (``/usr/share/edk2/ovmf/OVMF_CODE.fd``)

Building and Testing
--------------------
.. code-block:: bash

   git clone git@gitlab.com:renich/micros.git
   cd micros

   # Run test suite across substrate and Macros runtime
   zig build test

   # Run AST code quality and commandment linter
   make lint

   # Build bootable UEFI artifacts
   make uefi-boot

   # Launch interactive Sovereign Harness in QEMU (1280x800 GOP Display & Serial)
   make qemu-uefi

   # Boot bare-metal UEFI in QEMU with VirtIO-Net (offline deterministic mock AI)
   tools/micros-runner.bash --mode uefi --timeout 20

   # Build with live AI provider (Gemini, OpenAI, Anthropic, or local HTTP)
   zig build -Dai-provider=gemini -Dai-api-key="<YOUR_API_KEY>"
   tools/micros-runner.bash --mode uefi --timeout 30
