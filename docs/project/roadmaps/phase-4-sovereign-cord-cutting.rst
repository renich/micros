Phase 4: Bit-for-Bit Self-Rebuilding Pipeline
=============================================

:Objective: Establish pure in-system capability bundle assembly, PE32+ kernel synthesis, fail-safe dual-slot A/B staging, and bit-for-bit cryptographic rebuild verification.
:Status: Complete & Verified
:Specification: SPEC-TECH-REBUILD-001

Milestones & Deliverables
-------------------------

* **M4.1: Pure In-System MCB Synthesizer** [COMPLETE & VERIFIED]
   - Implemented freestanding ``src/kernel/storage/bundle_writer.zig`` assembling immutable, 64-byte aligned Capability Bundle (``.mcb``) binaries in memory.
   - Enforces lexicographical tag sorting to eradicate file-ordering non-determinism, computes BLAKE3 content digests per entry, and zeroes all padding and slack bytes.
   - Exposed ``sys_bundle_pack`` in ``src/kernel/storage/storage_abi.zig`` and implemented userspace bundle packaging in ``lib/macros/bundle.mx``.

* **M4.2: Freestanding Kernel Synthesizer & PE32+ Assembler** [COMPLETE & VERIFIED]
   - Implemented ``src/kernel/storage/kernel_synthesizer.zig`` linking relocatable substrate code with embedded ``.mcb`` bundle sections.
   - Enforced ascending base relocation sorting in ``src/boot/pe_emitter.zig`` and zeroed PE timestamps (``time_date_stamp = 0``).
   - Exposed ``sys_kernel_synthesize`` in ``src/kernel/storage/storage_abi.zig`` with full PE/COFF image validation.

* **M4.3: Generational A/B Staging & MicroShell Rebuild Workflow** [COMPLETE & VERIFIED]
   - Implemented fail-safe dual-slot staging (``SLOT_A.EFI`` / ``SLOT_B.EFI``, ``BOOTSTATE.DAT``, ``TRIAL.DAT``) in ``src/kernel/storage/rebuild.zig``.
   - Exposed ``sys_kernel_stage_update`` and ``sys_rebuild_status`` in ``storage_abi.zig``.
   - Implemented autonomous 5-step rebuild pipeline in ``lib/macros/rebuild.mx`` and integrated ``rebuild`` and ``reboot`` commands into ``lib/macros/msh.mx``.
   - Wired trial canary boot confirmation in ``lib/macros/init.mx``.

* **M4.4: Bit-for-Bit Reproducibility Certification** [COMPLETE & VERIFIED]
   - Proved mathematical identity (``BLAKE3(Pass 1) == BLAKE3(Pass 2)``) across repeated in-system synthesis passes.
   - Added automated ``--verify-rebuild`` workflow in ``tools/micros-runner.bash``.
   - Authored Technical Specification ``docs/technical/specs/self-rebuilding-kernel.rst`` (``SPEC-TECH-REBUILD-001``).
