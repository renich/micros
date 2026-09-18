============================================================
Enterprise Bare-Metal Silicon & Hardware Expansion (SPEC-TECH-SILICON-002)
============================================================

:Document ID: SPEC-TECH-SILICON-002
:Status: Approved
:Traced Stories: [US-REN-003], [US-REN-004], [US-REN-006], [US-REN-008], [US-GEM-010]

1. Architectural Axioms & Purpose
=================================
This specification formalizes the **Enterprise Bare-Metal Silicon Expansion & Heterogeneous Hardware Enablement Subsystem** for MicrOS (µOS). Operating within the Ring 0 microkernel driver substrate (``src/kernel/drivers/``), this layer extends native hardware support beyond virtualized hypervisors (QEMU/KVM) to physical enterprise workstation and server silicon across Intel Core/Xeon and AMD Ryzen/EPYC architectures.

1.1 Physical Silicon Driver Autonomy
------------------------------------
MicrOS operates directly on bare metal without proprietary microcode wrappers, Linux kernels, or opaque UEFI runtime services:
* **Enterprise Ethernet NICs**: Native zero-copy DMA drivers for Intel e1000e/igb (82574L, I219, I225) and Realtek r8169/r8168 Gigabit/Multi-Gigabit network interfaces.
* **USB 3.0 xHCI Host Controllers**: Native MMIO controller driver for USB 3.0/3.1 Extensible Host Controller Interface (xHCI), enabling physical keyboards, mice, and storage devices.
* **SMBIOS & DMI Motherboard Profiling**: Native SMBIOS 3.0 table parser certifying motherboard compatibility, memory topology, and hardware invariants on cold boot.

2. Enterprise Ethernet Subsystem (Intel e1000e / Realtek)
========================================================

2.1 MMIO Register Interface
---------------------------
The Intel Gigabit Ethernet driver maps BAR0 (MMIO) and controls ring buffers:

.. code-block:: zig

   pub const E1000_REG_CTRL: usize = 0x0000;
   pub const E1000_REG_STATUS: usize = 0x0008;
   pub const E1000_REG_EERD: usize = 0x0014;
   pub const E1000_REG_ICR: usize = 0x00C0;
   pub const E1000_REG_IMS: usize = 0x00D0;
   pub const E1000_REG_RCTL: usize = 0x0100;
   pub const E1000_REG_TCTL: usize = 0x0400;
   pub const E1000_REG_RDBAL: usize = 0x2800;
   pub const E1000_REG_RDBAH: usize = 0x2804;
   pub const E1000_REG_TDBAL: usize = 0x3800;
   pub const E1000_REG_TDBAH: usize = 0x3804;

2.2 Hardware Descriptor Rings
-----------------------------
Transfers operate via 16-byte aligned circular descriptor rings:
* **Rx Descriptors**: 16-byte descriptors with physical 64-bit buffer address, packet status flags, and CRC error bits.
* **Tx Descriptors**: 16-byte descriptors with command flags (End-of-Packet, Report Status) for zero-copy transmission.

3. USB 3.0 xHCI Host Controller Subsystem
=========================================

3.1 Capability & Operational Registers
--------------------------------------
The xHCI controller exposes capability registers (RO) and operational registers (RW):
* **CapLength (0x00)**: Byte offset to operational register space.
* **HciVersion (0x02)**: BCD-encoded controller revision (0x0100 for xHCI 1.0).
* **HcsParams1 (0x04)**: Max device slots and ports.
* **UsbCmd (Oper + 0x00)**: Run/Stop (RS) bit and host controller reset (HCRST).
* **UsbSts (Oper + 0x04)**: Controller halted (HCH) and event interrupt (EINT).
* **Crcr (Oper + 0x18)**: 64-bit Command Ring Control Register.

4. Verification & Traceability Matrix
=====================================

.. list-table::
   :widths: 20 25 55
   :header-rows: 1

   * - Requirement ID
     - Traced Story
     - Verification Method
   * - REQ-SIL-001
     - [US-REN-003]
     - Cold boot initialization and device enumeration on physical silicon in < 1s.
   * - REQ-SIL-002
     - [US-REN-004]
     - Zero-libc freestanding MMIO register and descriptor ring manipulation.
   * - REQ-SIL-003
     - [US-REN-006]
     - Capability-bounded device register mapping and DMA buffer access.
   * - REQ-SIL-004
     - [US-REN-008]
     - ACPI and hardware controller clean quiescence upon system halt/poweroff.
   * - REQ-SIL-005
     - [US-GEM-010]
     - Modular architecture under 1,000 LOC per file with bounded function complexity.
