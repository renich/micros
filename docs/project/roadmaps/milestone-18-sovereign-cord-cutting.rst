Milestone 18: Sovereign Cord-Cutting & Silicon Deployment
=========================================================

:Objective: Achieve absolute computational sovereignty. Cut the umbilical cord to host operating systems (Linux/Fedora), external toolchains, and virtualization hypervisors. Enable MicrOS to partition raw physical NVMe/SATA storage, synthesize its own bootable UEFI binaries (PE/COFF), rebuild the complete kernel and toolchain from Content-Addressed Storage, and run bare-metal on physical silicon with zero external dependencies.
:Status: Planned
:Specification: SPEC-TECH-SILICON-001

Milestones & Deliverables
-------------------------

* **M18.1: Bare-Metal Physical Storage & GUID Partitioning Substrate**
   - Implement ``src/kernel/drivers/gpt.zig`` to read, parse, and format GUID Partition Tables (GPT) on physical storage drives.
   - Implement freestanding NVMe storage controller driver in ``src/kernel/drivers/nvme.zig`` operating directly over PCI Express MMIO and DMA submission/completion queues.
   - Format raw silicon drives with an EFI System Partition (ESP, FAT32) and a dedicated MicrOS Content-Addressed Storage partition.

* **M18.2: Pure Freestanding PE/COFF EFI Synthesizer**
   - Implement ``src/boot/pe_emitter.zig`` capable of generating valid 64-bit UEFI executables (``BOOTX64.EFI``) entirely within the running operating system.
   - Synthesize DOS stub, PE header, section tables (``.text``, ``.rodata``, ``.data``), and relocation fixups from memory without GNU ld, lld, or external toolchains.
   - Install the generated EFI binary directly into the target disk's ESP directory.

* **M18.3: Sovereign Standalone System Installer**
   - Implement ``lib/macros/installer.mx`` providing an interactive hardware installation wizard in the Genesis Harness.
   - Enumerate attached physical drives, display sector geometry, and prompt user for deployment target.
   - Transfer active Genesis bundle, core libraries, and kernel chunks into the permanent CAS partition.
   - Perform atomic superblock commit and reboot cleanly into the newly deployed sovereign operating system.

* **M18.4: Autonomous Self-Rebuilding & Hot-Patching Engine**
   - Implement ``src/kernel/rebuild.zig`` enabling the microkernel to recompile its own kernel source code stored in CAS.
   - Utilize native Macros stage-2 compiler to emit a refreshed kernel image.
   - Verify cryptographic integrity via BLAKE3 root manifests before staging the new binary into the EFI bootloader path.
   - Implement rollback protection: automatically revert to previous superblock generation if the updated kernel fails to complete genesis initialization.

* **M18.5: Bare-Metal Silicon Validation & Cord-Cutting Certification**
   - Execute physical hardware deployment tests on standard x86_64 UEFI silicon (Intel Core and AMD Ryzen architectures).
   - Verify network connectivity over physical e1000/VirtIO-Net, NVMe disk persistence, GOP display rasterization, and interactive AI harness execution.
   - Certify complete computational sovereignty: zero lines of C/libc, zero external build dependencies, and 100% self-hosted lifecycle management.
