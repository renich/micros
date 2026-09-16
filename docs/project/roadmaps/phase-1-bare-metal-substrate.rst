Phase 1: Bare-Metal Substrate
=============================

:Objective: Replace the Fedora Linux host with our own UEFI Bootloader and Microkernel.
:Status: Planned

Milestones
----------

* **M1.1: UEFI Bootloader**
  - Implement ``boot.efi``.
  - Load the kernel ELF and construct the memory map.

* **M1.2: Memory & Execution**
  - $O(1)$ Physical Memory Manager (PMM).
  - Higher-Half Direct Map (HHDM).
  - Preemptive Scheduler & IDT exceptions.

* **M1.3: VirtIO Drivers**
  - VirtIO Console, Block, and Net drivers.
