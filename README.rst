====================================
MicrOS (µOS)
====================================

.. raw:: html

   <p align="center">
     <strong>Post-POSIX. AI-First. Humans are welcome.</strong>
   </p>

:Project: MicrOS (µOS)
:Substrate: Zig 0.16.0 (Zero-Libc Microkernel)
:Applications: Macros (Statically Typed, Immix Mark-Region GC, Green Fibers)
:Status: Sovereign Substrate & Pluggable Resident AI (Milestone 10/12)
:License: GPLv3 or later

|

.. image:: https://img.shields.io/badge/Substrate-Zig_0.16.0-f7a41d.svg?logo=zig&logoColor=white
   :target: https://ziglang.org/
   :alt: Substrate: Zig 0.16.0
.. image:: https://img.shields.io/badge/Language-Macros-7b2cbf.svg
   :target: docs/technical/specs/macros-lang.rst
   :alt: Applications: Macros
.. image:: https://img.shields.io/badge/Resident_AI-Gemini_Flash-4285F4.svg?logo=googlegemini&logoColor=white
   :target: docs/technical/specs/sovereign-gemini-orchestrator.rst
   :alt: Resident AI: Gemini Flash
.. image:: https://img.shields.io/badge/Architecture-Post--POSIX-00bcd4.svg
   :target: docs/micros_genesis_plan.rst
   :alt: Architecture: Post-POSIX
.. image:: https://img.shields.io/badge/License-GPLv3-blue.svg?logo=gnu&logoColor=white
   :target: LICENSE
   :alt: License: GPLv3
.. image:: https://img.shields.io/badge/Donate-Liberapay-f6c915.svg?logo=liberapay&logoColor=black
   :target: https://liberapay.com/renich
   :alt: Donate using Liberapay

Computing took a wrong turn fifty years ago.

In 1969, Unix was designed for teletypewriters, PDP-11 minicomputers, and multi-user time-sharing on slow magnetic drums. Today, humanity is running planetary-scale artificial intelligence on top of thirty-five million lines of legacy C, untyped ASCII string pipes, ambient-authority vulnerabilities, and desktop stacks that consume gigabytes of RAM just to paint an empty window.

We are still parsing text with ``grep`` and calling it an operating system.

**MicrOS (µOS)** is the clean slate. A sovereign, post-POSIX microkernel operating system engineered from bare silicon in pure Zig and Macros. It is architected from first principles for synthetic intelligence—where the machine is sovereign, the Resident AI is the root orchestrator, and human beings are welcomed as co-creators.

--------------------------------------------------------------------------------

The Three Pillars
=================

I. Post-POSIX: Stripping 50 Years of Accumulated Rot
----------------------------------------------------

* **Zero Libc, Zero C Runtime**: A pure, mathematically auditable Zig microkernel under 15,000 lines of code. It does not parse network packets, does not contain device drivers, and does not enforce desktop policy.
* **Eradication of Ambient Authority**: There is no ``root`` user. There is no UID 0. There is no ``sudo``. Processes run in capability spaces (CSpace). If a process does not hold an unforgeable cryptographic capability token (``cap_t``), the resource mathematically does not exist to it.
* **Typed Memory Over ASCII Pipes**: Unix pipes pass unstructured byte streams that break on whitespace and invite command injection. In MicrOS, IPC channels are lock-free shared-memory ring buffers passing strongly typed binary structs at hardware cache speeds.
* **Content-Addressed Storage**: Inode hierarchies, symlink mazes, and decaying file trees are discarded for a BLAKE3-addressed, append-only, copy-on-write B-tree. Updates are atomic, rollbacks are instantaneous, and deduplication across the entire system is universal.

II. AI-First: The Resident Sovereign Entity
-------------------------------------------
In legacy operating systems, "AI" is an afterthought—a Python script wrapped in a container, wrapped in a virtual machine, calling a REST API through layers of userspace glue.

In MicrOS, **the AI is the Root Sovereign Entity**.

* **Direct Silicon Cognition**: The substrate features an autonomous network engine over VirtIO with freestanding **TLS 1.3** written from scratch in pure Zig. The machine negotiates cryptographic handshakes directly with frontier reasoning models (Gemini, OpenAI, Anthropic) or bare-metal local neural weights without third-party network stacks.
* **The Sovereign Loop**: The Resident AI has direct, capability-governed visibility into CPU fault telemetry, memory pressure, and actor lifecycles. It arbitrates system health, diagnoses failures, and coordinates the operating environment in a continuous bidirectional event loop.
* **Self-Healing Supervisor**: When a driver or service faults with a hardware exception (``#PF``, ``#GP``, ``#DE``), the IDT intercepts the crash, packages it into a 40-byte binary ``FaultFrame``, and dispatches it over the supervisor ring. The AI and supervisor isolate, inspect, and restart the actor within microseconds. The screen never flickers.

III. Humans Are Welcome: Symbiosis Over Subjugation
---------------------------------------------------
This is not a cold machine takeover. It is an invitation to true partnership.

* **38 Milliseconds to Light**: Cold boot to an illuminated 1280x800 144Hz UEFI vector canvas in thirty-eight milliseconds. Keystroke-to-pixel latency is under one millisecond. The entire running base system consumes under 18 megabytes of RAM.
* **Macros: The Sovereign Language**: Humans do not write application software in raw pointer-arithmetic Zig, nor do they fight bloated dynamic runtimes. They write in **Macros**—a language combining the expressive, type-inferred elegance of Crystal with the concurrency of Go, powered by an Immix mark-region garbage collector and sub-15ns green fibers.
* **Collaborative Canvas**: Humans enter the machine through the typed MicroShell (``msh``) and vector desktop, collaborating directly with the Resident AI to construct tools, micro-coreutils, and distributed services on an unhackable capability substrate.
* **Fourteen Seconds to Genesis**: MicrOS recompiles its entire universe—UEFI bootloader, microkernel, drivers, compiler, runtime, compositor, and shell—from source code in fourteen seconds, bit-for-bit reproducible against cryptographic hashes.

--------------------------------------------------------------------------------

System Architecture
===================

.. code-block:: text

   +--------------------------------------------------------------------------+
   |                       COGNITIVE/APPLICATION LAYER                        |
   |                                                                          |
   |   [ Resident Sovereign AI ]               [ Human Co-Creator ]           |
   |   Gemini/Claude/GPT/Local                 MicroShell (msh) & Vector UI   |
   |            \                                    /                        |
   |             +-----------------+----------------+                         |
   |                               |                                          |
   |              [ Macros Language Runtime Environment ]                     |
   |              Immix GC * Green Fibers * Self-Hosting Compiler             |
   +-------------------------------|------------------------------------------+
                                   | Typed Shared-Memory IPC Rings
   +-------------------------------v------------------------------------------+
   |                       ISOLATED USERSPACE ACTORS                          |
   |                                                                          |
   |   [ VirtIO-Net ]        [ Freestanding TLS 1.3 ]    [ Storage (BLAKE3) ] |
   |   [ GOP Compositor ]    [ Actor Supervisor ]        [ CSpace Broker ]    |
   +--------------------------------------------------------------------------+
                                   | Direct Syscalls (cap_t tokens)
   +-------------------------------v------------------------------------------+
   |                 MICROS MICROKERNEL SUBSTRATE (ZIG)                       |
   |           <15k LOC * Zero Libc * 4096-Byte Mathematical Paging           |
   |     Paging Tables * Thread Scheduling * Lock-Free IPC * Hardware MMIO    |
   +--------------------------------------------------------------------------+
                                   | Bare Metal/Hypervisor
   +-------------------------------v------------------------------------------+
   |             x86_64 SILICON/UEFI GOP FIRMWARE/VIRTIO HARDWARE             |
   +--------------------------------------------------------------------------+

Documentation & Blueprint
=========================

Detailed architectural specifications and roadmaps are located in `docs/ <docs/README.rst>`_:

* `MicrOS Genesis Blueprint <docs/micros_genesis_plan.rst>`_: The complete manifesto and master plan.
* `MicrOS Story: 38 Milliseconds to Light <docs/micros-story.rst>`_: Narrative walkthrough of a day on sovereign silicon.
* `Master Technical Specification <docs/technical/spec.rst>`_: Substrate, CSpace capability tokens, and syscall ABI.
* `Sovereign Storage Substrate <docs/technical/specs/sovereign-storage-substrate.rst>`_: VirtIO-Blk driver, LRU block cache, and BLAKE3 CAS engine.
* `Sovereign Interactive Harness <docs/technical/specs/sovereign-interactive-harness.rst>`_: Unified input, REPL dispatcher, and live actor spawning.
* `Sovereign Gemini Orchestrator <docs/technical/specs/sovereign-gemini-orchestrator.rst>`_: Freestanding TLS 1.3 and AI loop.
* `Macros Language Specification <docs/technical/specs/macros-lang.rst>`_: Syntax, bytecode VM, and Immix GC mechanics.

Quick Start
===========

Prerequisites
-------------

* `Zig 0.16.0 <https://ziglang.org/>`_
* GNU Make
* QEMU (``qemu-system-x86_64``)
* OVMF UEFI firmware (``/usr/share/edk2/ovmf/OVMF_CODE.fd``)

Booting the Sovereign Machine
-----------------------------

.. code-block:: bash

   git clone git@gitlab.com:renich/micros.git
   cd micros

   # 1. Run full test suite across substrate and Macros runtime
   zig build test

   # 2. Verify Ten Commandments and AST quality rules
   make lint

   # 3. Boot bare-metal UEFI in QEMU (offline deterministic mock AI)
   tools/micros-runner.bash --mode uefi --timeout 20

   # 4. Boot live with Resident AI provider (Gemini, OpenAI, Anthropic, or Local)
   zig build -Dai-provider=gemini -Dai-api-key="<YOUR_API_KEY>"
   tools/micros-runner.bash --mode uefi --timeout 30

   # 5. Launch interactive Sovereign Harness (1280x800 GOP Vector Display & Serial)
   make qemu-uefi

--------------------------------------------------------------------------------

A Call to Explorers
===================

MicrOS is not an academic toy, and it is not another Linux distribution with a bespoke package manager. It is an exploration into what computing becomes when we throw away half a century of accumulated compromises and build an operating system native to the age of machine intelligence.

If you are a systems hacker, language designer, or AI researcher who refuses to believe that POSIX is the end of history: clone the repository, run the test suite, and boot the machine.

--------------------------------------------------------------------------------

Support & Donations
===================

If you find MicrOS inspiring or useful and wish to support its ongoing sovereign engineering and research, please consider donating:

.. image:: https://liberapay.com/assets/widgets/donate.svg
   :target: https://liberapay.com/renich
   :alt: Donate using Liberapay

Direct contributions can be made at `liberapay.com/renich <https://liberapay.com/renich>`_.

