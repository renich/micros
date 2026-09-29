Milestone 35: Sovereign Bare-Metal Hardware Posture (Enterprise Scope Cut)
==========================================================================

:Objective: Reconciled under Stage 1/2 Architecture Decisions. Enterprise datacenter NIC expansion (e1000e/igb) and enterprise hardware bridges were CUT to preserve microkernel minimality and sovereign personal workstation focus. The hardware substrate standardizes on lean, verifiable standard interfaces: VirtIO (Net/Blk), NVMe PCIe storage, and standard UEFI GOP graphics.
:Status: Completed (Enterprise Scope Cut Reconciled)
:Specification: SPEC-TECH-MIN-001
:Traced Stories: [US-REN-007], [US-GEM-007]

Architecture Reconciliation & Scope
-----------------------------------

* **Enterprise Bare-Metal Scope Cut**: Complex enterprise server hardware drivers (Intel e1000e/igb server NICs, multi-queue enterprise bridges) were formally cut. Adding hundreds of device-specific drivers into Ring 0 violates the MicrOS Sovereign Commandments regarding microkernel minimality and WCET bounds.
* **M35.1: Standard VirtIO Substrate (VirtIO-Net & VirtIO-Blk)**
   - High-performance, zero-libc VirtIO 1.0 drivers over split virtqueues and verified DMA boundaries.
* **M35.2: Physical PCIe NVMe Driver**
   - Direct NVMe queue submission/completion rings on physical PCIe SSD controllers.
* **M35.3: UEFI GOP & Hardware Interfacing**
   - Native UEFI Graphics Output Protocol (GOP) linear framebuffer, APIC timer preemption, and PS/2 input drivers providing reliable bare-metal workstation operation.
