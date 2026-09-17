===================================================
Bit-for-Bit Self-Rebuilding Kernel Pipeline Subspec
===================================================

:Document ID: SPEC-TECH-REBUILD-001
:Status: Approved
:Traced Stories: [US-REN-004], [US-REN-007], [US-GEM-007], [US-GEM-010]
:Roadmap Target: Phase 4 (docs/project/roadmaps/phase-4-sovereign-cord-cutting.rst)

1. Architectural Scope & Purpose
================================
A truly independent operating system must possess the capability to rebuild its entire execution stack from source artifacts entirely within its own runtime boundaries, with zero reliance on external compilation environments, host operating systems (Linux/Fedora), or third-party toolchains.

However, attempting to embed a 500,000-line LLVM/Zig compiler into Ring 0 microkernel memory violates the core tenets of lean systems engineering, introduces millions of lines of untrusted attack surface, and risks fatal memory leaks and kernel panics.

This specification formalizes the **Two-Tiered Self-Rebuilding Architecture**:
1. **Tier 1 (High-Level Actor Assembly)**: The pure Macros Stage 1 self-hosting compiler (``lib/macros/compiler.mx``) compiles userspace system actors (``init.mx``, ``msh.mx``, ``harness.mx``, ``installer.mx``, ``rebuild.mx``) into deterministic ``MCR1`` bytecode and serializes the Genesis Capability Bundle (``genesis.mcb``) in-system.
2. **Tier 2 (Low-Level Kernel Synthesis)**: The freestanding kernel synthesizer (``src/kernel/storage/kernel_synthesizer.zig``) and PE32+ assembler (``src/boot/pe_emitter.zig``) link pre-verified substrate relocatable objects with the freshly synthesized ``genesis.mcb`` payload to emit an authentic, bootable ``BOOTX64.EFI`` executable.

2. Bit-for-Bit Reproducibility Invariants
=========================================
To achieve mathematical reproducibility where independent compilation passes yield identical cryptographic digests (``BLAKE3(Pass 1) == BLAKE3(Pass 2)``), the following invariants are strictly enforced:

.. list-table::
   :widths: 30 70
   :header-rows: 1

   * - Invariant
     - Technical Enforcement
   * - **PE/COFF Timestamps**
     - ``CoffHeader.time_date_stamp = 0`` strictly enforced in ``src/boot/pe_emitter.zig``.
   * - **Manifest Timestamps**
     - ``SystemManifest.timestamp = 0`` during deterministic builds, eliminating wall-clock variance.
   * - **Slack & Padding Hygiene**
     - Memory buffers explicitly cleared via ``@memset(0)`` across struct alignment slack and 512-byte sector file alignment gaps.
   * - **Lexicographical Entry Sorting**
     - ``bundle_writer.zig`` mathematically sorts all bundle entries by tag name prior to table emission.
   * - **Base Relocation Determinism**
     - ``pe_emitter.zig`` sorts relocation RVAs in ascending order before packing 4096-byte page blocks.
   * - **Checksum Independence**
     - ``OptionalHeader64.check_sum = 0`` (standard for UEFI applications per PE/COFF §5.4.3).

3. The Dual-Slot (A/B) Staging State Machine
============================================
To prevent system bricking under unexpected power loss during kernel updates, the EFI System Partition (ESP) enforces dual-slot staging:

.. code-block:: text

   +-------------------------------------------------------------------------+
   | ESP (/EFI/BOOT/)                                                        |
   |                                                                         |
   | [BOOTX64.EFI] (Active boot executable executed by UEFI firmware)        |
   |       ^                                                                 |
   |       | Atomic commit on staging completion                             |
   |                                                                         |
   | [SLOT_A.EFI] (Kernel Gen N   - STABLE) <--- Current running slot        |
   | [SLOT_B.EFI] (Kernel Gen N+1 - TRIAL)  <--- Inactive staging slot       |
   |                                                                         |
   | [BOOTSTATE.DAT] ('A' or 'B' active slot marker)                         |
   | [TRIAL.DAT]     ('1' = trial canary unconfirmed, '0' = stable)          |
   +-------------------------------------------------------------------------+

Lifecycle Transitions:
1. **Rebuild Execution**: The rebuilder reads ``BOOTSTATE.DAT``, identifies the inactive slot (e.g., Slot B), and writes the synthesized kernel binary to the inactive slot first.
2. **Firmware Sync**: Once Slot B is verified, the binary is copied to ``BOOTX64.EFI``, ``BOOTSTATE.DAT`` is set to the target slot, and ``TRIAL.DAT`` is armed with ``'1'``.
3. **Canary Validation**: On reboot, Actor 0 (``lib/macros/init.mx``) boots, spawns App 0 (``lib/macros/msh.mx``), and calls ``sys_cas_confirm_boot()``.
4. **Promotion**: ``sys_cas_confirm_boot()`` resets ``TRIAL.DAT`` to ``'0'`` and commits ``MANIFEST_FLAG_STABLE`` to CAS Sector 0 superblock.
5. **Auto-Rollback**: If boot fails before userspace confirms health, ``rollbackToPrevious()`` restores the prior stable generation from CAS and ESP.

4. MicroShell Command & Syscall Bindings
========================================
The autonomous rebuild pipeline is accessible through MicroShell (``msh``) and exposes low-level mechanisms through the Storage ABI:

* ``sys_bundle_pack(entries)``: Packs array of ``[tag, content]`` pairs into 64-byte aligned MCB binary.
* ``sys_kernel_synthesize(bundle_bytes)``: Links substrate code and embedded MCB section into a valid PE32+ executable.
* ``sys_kernel_stage_update(kernel_bytes, bundle_bytes)``: Atomically stages Generation N+1 into CAS and FAT32 ESP.
* ``sys_rebuild_status()``: Returns active manifest generation, trial flag, stable flag, and kernel content hash.
* ``sys_cas_confirm_boot()``: Disarms trial canary and promotes running generation to stable.
* ``sys_reboot()``: Triggers hardware reset via 8042 keyboard controller pulse (``io.outb(0x64, 0xFE)``).
