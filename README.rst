====================================
MicrOS (µOS)
====================================

:Project: MicrOS (µOS)
:Status: Phase 0 (Userspace Sandbox)
:Language: Zig (Kernel/Substrate), Macros (Application Runtime)
:License: GPLv3 or later

MicrOS is a sovereign, AI-native operating system built from scratch in Zig. It aims to eradicate 50 years of POSIX legacy bloat by providing a minimal, mathematically rigorous microkernel and a hyper-fast high-level application language called **Macros**.

For full architectural blueprints, roadmaps, and technical specifications, see the `docs/ <docs/README.rst>`_ directory.

Quick Start
===========

Dependencies
------------
* Zig 0.14+
* QEMU (for Phase 1+ bare-metal testing)

Building the Sandbox
--------------------
.. code-block:: bash

   git clone https://git.mx-os.mx/renich/micros.git
   cd micros
   zig build
   zig build test

This compiles the Substrate Toolchain and the `micros-init` Phase 0 entry point.
