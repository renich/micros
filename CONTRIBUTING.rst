============================
Contributing to MicrOS (µOS)
============================

Thank you for your interest in contributing to **MicrOS (µOS)**. MicrOS is an exploration into what computing becomes when we strip away half a century of accumulated legacy and build a sovereign, post-POSIX, AI-first operating system from bare silicon in pure Zig and Macros.

MicrOS is co-developed by human systems engineers and autonomous AI agents. We treat both human and synthetic contributors with equal technical dignity and hold all participants to the same unyielding standard of empirical verification and architectural integrity.

Code of Honor
=============

All contributors must uphold the following core commitments:

* **Sovereignty**: We reject ambient authority, bloated runtimes, and unnecessary third-party dependencies.
* **Radical Transparency**: We expose architectural trade-offs, document design decisions in Architecture Decision Records (ADRs), and track work in the verifiable Project Journaling Protocol (PJP).
* **Intellectual Honesty**: We demand ruthless critique of flawed logic, memory safety risks, and speculative assumptions. A partner tells the unvarnished truth.

The Verification Doctrine
=========================

**Never Assume; Always Verify.**

Zero probabilistic shortcuts, associative guessing, or plausible-sounding assertions are tolerated in this repository. Before declaring an implementation complete, asserting compiler mechanics, or modifying substrate boundaries:

1. Inspect the source code directly.
2. Run automated diagnostic suites and bare-metal emulator tests.
3. Verify ground-truth facts against the filesystem and execution logs.

The Ten Commandments of Code Quality
====================================

Every line of code committed to MicrOS must comply with the Ten Commandments defined in `AGENTS.md <AGENTS.md>`_:

1. **File Size**: No file shall exceed 1,000 lines of code.
2. **Function Size**: No function shall exceed 40 lines.
3. **Nesting Depth**: Maximum indentation depth is 3 levels.
4. **Formatting**: Never use spaces around forward slashes in text or markdown (format as ``word/word``, never with spaces around the slash).
5. **No Magic Numbers**: All constants must be strongly typed or defined in ``UPPER_SNAKE_CASE`` (e.g., ``0x4D494352_4F534B45``).
6. **Explicit Errors**: No ``catch unreachable`` outside unit tests. All runtime errors must bubble up explicitly using Zig error unions.
7. **No Libc**: The substrate layer (``src/sys/`` and the kernel) must never link against or include libc. Use direct Linux syscalls or native x86_64 inline assembly.
8. **Memory Safety**: All memory allocations must take an explicit ``std.mem.Allocator`` parameter. Hidden global state allocations are strictly forbidden.
9. **Page Alignment**: All ``mmap`` regions, page tables, and hardware buffers must mathematically enforce 4096-byte alignment.
10. **Test Colocation**: Tests must reside alongside the production code they test within the same module using native Zig ``test`` blocks.

Getting Started
===============

Development Environment
-----------------------

MicrOS development is optimized for modern Linux (Fedora 40+ recommended):

* **Zig**: ``0.16.0`` (exact release)
* **GNU Make**: Build orchestration
* **QEMU**: ``qemu-system-x86_64`` with KVM support
* **OVMF**: UEFI firmware image (``/usr/share/edk2/ovmf/OVMF_CODE.fd``)
* **Python 3**: Sphinx documentation tools and docutils
* **Linters**: ``rstcheck`` and ``crstlint``

Cloning the Repositories
------------------------

The primary upstream repository is hosted on GitLab with an automated mirror on GitHub:

.. code-block:: bash

   # Clone primary GitLab repository
   git clone git@gitlab.com:renich/micros.git
   cd micros

   # Or clone GitHub mirror
   git clone git@github.com:renich/micros.git
   cd micros

Building the Substrate
----------------------

Compile the substrate tools and the Genesis boot artifacts:

.. code-block:: bash

   # 1. Compile host tools (micros-lint, micros-bundle, micros-sym, etc.)
   make tools

   # 2. Compile kernel and package the Genesis MCB bundle
   make all

Development & Verification Workflow
===================================

Running Quality Checks
----------------------

Before committing or submitting a merge request, run the complete verification suite:

.. code-block:: bash

   # Run complete quality gate (tests, linters, formatting, traceability)
   make check

   # Run Zig unit test suite across kernel, substrate, and Macros runtime
   make test

   # Verify compliance with the Ten Commandments and AST quality rules
   make lint

   # Verify Zig source formatting
   make fmt-check

   # Audit specification traceability
   make spec-trace

Bare-Metal Hardware Emulation
-----------------------------

Test the operating system in full x86_64 UEFI emulation via QEMU:

.. code-block:: bash

   # 1. Boot bare-metal UEFI with interactive graphical canvas (1280x800 GOP)
   make qemu-uefi

   # 2. Run automated headless test with offline deterministic mock AI
   tools/micros-runner.bash --mode uefi --timeout 20

   # 3. Boot live with Resident AI provider (Gemini, OpenAI, Anthropic, or Local)
   zig build -Dai-provider=gemini -Dai-api-key="<YOUR_API_KEY>"
   tools/micros-runner.bash --mode uefi --timeout 30

   # 4. Verify two-stage cold reboot storage persistence across VirtIO-Blk & CAS
   tools/micros-runner.bash --verify-persistence --timeout 15

Project Journaling Protocol (PJP)
=================================

MicrOS uses the Project Journaling Protocol (PJP) orchestrated by the ``ajourn`` tool to maintain a concurrency-safe, tamper-evident audit trail of architectural milestones, features, and decisions.

.. code-block:: bash

   # Inspect current cockpit status and active roadmap
   ajourn status

   # Log a completed engineering milestone
   ajourn log -m "feat(macros): implement green fiber context switching" -t "FEAT,MACROS,FIBERS"

Subagent Roles & Specialization
===============================

When AI agents collaborate on the codebase, each agent operates under an explicit operational mandate:

* **zig_system_dev**: Low-level kernel substrate, memory paging, VirtIO drivers, and direct-syscall ABI.
* **macros_lang_dev**: Lexer, parser, bytecode compiler, VM runtime, and Immix mark-region GC.
* **measured_architect**: Evolutionary roadmap alignment, modular subsystem boundaries, and SOLID interfaces.
* **extreme_adversary**: Zero-trust adversarial reviewer hunting for memory leaks, integer overflows, and race conditions.

Commit Message Standards
========================

MicrOS strictly enforces the **Conventional Commits** specification:

* **Format**: ``type(scope): description in imperative mood``
* **Allowed Types**:

  * ``feat``: New kernel capability, runtime feature, or language primitive.
  * ``fix``: Bug fix or crash resolution.
  * ``refactor``: Structural refactoring without behavioral modification.
  * ``perf``: Performance optimization or memory throughput enhancement.
  * ``test``: New tests or verification harness fixtures.
  * ``docs``: Documentation, specifications, or roadmap updates.
  * ``chore``: Build system, toolchain, or dependency updates.

* **Allowed Scopes**: ``kernel``, ``boot``, ``sys``, ``macros``, ``msh``, ``net``, ``tls``, ``tools``, ``docs``, ``ci``.

* **Git Co-Authorship & Sign-Off**:
  All commits co-developed with AI agents must include standard attribution and sign-off trailers:

  .. code-block:: text

     feat(kernel): add 4096-byte aligned page table allocator

     Implement mathematical page alignment for VMM page directories.
     Enforce explicit Allocator parameter and zero libc dependencies.

     Co-authored-by: Antigravity <antigravity@google.com>
     Signed-off-by: Rénich Bon Ćirić <renich@evalinux.com>

* **GPG Signing**: All commits must be cryptographically signed with GPG (``git commit -S``).

Documentation Standards
=======================

* **Language**: All documentation, specifications, and guides must be authored in **reStructuredText** (``.rst``).
* **Indentation**: Directives must strictly use **3-space indentation**.
* **Sphinx Build**: Ensure documentation builds cleanly without warnings:

  .. code-block:: bash

     sphinx-build docs docs/_build
     rstcheck docs/index.rst CONTRIBUTING.rst README.rst
     crstlint -fr docs/

Submitting Merge Requests
=========================

1. Create a descriptive topic branch: ``feat/<feature-name>`` or ``fix/<bug-name>``.
2. Ensure ``make check`` passes 100% with zero linter errors.
3. Update relevant specifications in ``docs/`` and log changes in ``CHANGELOG.rst``.
4. Log your progress in PJP using ``ajourn log``.
5. Submit a Merge Request against ``master`` on `GitLab <https://gitlab.com/renich/micros/-/merge_requests>`_.

Financial Support
=================

MicrOS is an independent, sovereign operating system research and engineering effort. If you wish to support its ongoing development, donations are gratefully accepted via `Liberapay <https://liberapay.com/renich>`_:

.. image:: https://liberapay.com/assets/widgets/donate.svg
   :target: https://liberapay.com/renich
   :alt: Donate using Liberapay
