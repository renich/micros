====================================================
Autonomous Driver Synthesis & Device Probe Spec (D1)
====================================================

:Document ID: SPEC-TECH-DRV-001
:Status: Approved
:Traced Stories: [US-REN-004], [US-REN-006], [US-GEM-001], [US-GEM-009], [US-GEM-010]
:Parent Architecture: `SPEC-TECH-SYS-001`, `SPEC-TECH-CAP-001`
:Module Targets: ``src/kernel/abi.zig``, ``src/kernel/actor.zig``, ``src/kernel/mem/vmm.zig``

1. Architectural Axioms & Purpose
=================================
This specification defines the substrate, safety invariants, and execution ladder for Autonomous Driver Synthesis (D1) in MicrOS (µOS). It enables the Resident AI and userland actors to reverse-engineer, synthesize, probe, and operate device drivers for newly connected hardware without risking kernel panics or hardware damage.

1.1 Core Safety Axioms
----------------------
* **Ring 3 Sandboxing**: All synthesized drivers execute strictly in userland (Ring 3) as isolated Macros actors. Ring 0 contains zero hardware driver logic.
* **Zero Ambient MMIO/Port Authority**: Direct port I/O, MMIO accesses, and DMA operations require explicit capability tokens granted only after human or policy authorization.
* **Anti-Bricking Probe Ladder**: Hardware interaction transitions monotonically through 5 formal stages, preventing catastrophic write commands to unverified hardware registers.
* **Deterministic Probe Transcripts**: Every I/O operation during device discovery is recorded into an append-only transcript hashed with BLAKE3 and archived in Content-Addressed Storage (CAS).

2. 4-Stage Anti-Bricking Probe State Machine
============================================
When a device arrival event occurs (via PCI scan or USB enumeration), the substrate enforces a strictly gated state machine:

.. code-block:: text

   [STG_0: DETECT]
          │  PCI enumeration or USB device arrival interrupt
          ▼
   [STG_1: PASSIVE_ENUM] ──(Read-only config space: VID, DID, Class, Subclass, BAR sizes)
          │
          ▼
   [STG_2: OFFLINE_SYNTH] ──(Resident AI queries local specs & synthesizes candidate driver actor)
          │
          ▼
   [STG_3: AUDIT_RO] ────(Driver actor probes device in read-only audit mode; verify ID regs)
          │
          ▼
   [STG_4: ACTIVE_PROBE] ──(Gated write verification; interrupt loop-back test)
          │
          ▼
   [STG_5: OPERATIONAL] ──(Full driver execution in isolated userland domain)

2.1 Stage Descriptions
----------------------
1. **STG_0: DETECT**: Substrate detects device presence on bus and assigns a temporary device identifier.
2. **STG_1: PASSIVE_ENUM**: Kernel reads standard PCI configuration header space (Vendor ID, Device ID, Class Code, BAR configurations). No MMIO or device-specific registers are accessed.
3. **STG_2: OFFLINE_SYNTH**: The Resident AI parses the device parameters against local technical reference libraries and synthesizes a candidate driver actor written in Macros.
4. **STG_3: AUDIT_RO**: The candidate driver is spawned in an audit sandbox with read-only access to MMIO BARs. It reads identification registers to verify driver-hardware alignment. The IDT Vector-14 page fault hook range-checks the active MMIO window; any write attempt aborts the probe, trips a capability fault, and transitions the device to QUARANTINE. Out-of-window page faults preserve legacy kernel fault handling bit-for-bit.
5. **STG_4: ACTIVE_PROBE**: Driver issues bounded, non-destructive write probes under a hard ceiling of 16 operations max. Writes are strictly restricted to whitelist offsets defined as descriptor constants (`scratch_reg_offset`, `irq_trigger_offset`), never actor-supplied.
6. **STG_5: OPERATIONAL**: Driver is promoted to operational status and granted its designated Token Triad.

3. Capability Token Triad & DMA Guard
=====================================

3.1 Capability Token Triad
--------------------------
An operational driver actor requires exactly three fine-grained capability tokens:

1. ``CapType.hardware_device`` (0x0008): Grants bounded MMIO mapping or Port I/O ranges specific to the device BARs.
2. ``CapType.irq_endpoint`` (0x0003): Grants receipt of asynchronous interrupt notification events for the device IRQ line (reconciled from former draft label irq_handler).
3. ``CapType.dma_buffer`` (0x0009): Grants access to physical memory buffers for device data transfer.

3.2 IOMMU DMA Guard & Bounce-Buffer Fallback
--------------------------------------------
Unrestricted DMA by untrusted or synthesized code represents a catastrophic security vulnerability (DMA attacks, RAM corruption).

* **Hardware IOMMU Translation**: On hardware featuring Intel VT-d or AMD-Vi, device DMA is restricted to driver-owned physical pages configured in IOMMU page tables.
* **Bounce-Buffer Fallback**: When an IOMMU is absent or disabled, direct physical DMA from synthesized drivers is strictly prohibited. Drivers must interact through kernel-mediated bounce buffers via the ``sys_dma_bounce_copy`` primitive:

.. code-block:: zig

   pub fn sys_dma_bounce_copy(
       buffer_cap: u32,
       offset: u32,
       length: u32,
       direction: DmaDirection,
   ) i64

* **Physical Page Safety**: The kernel allocates bounce pages exclusively below 4 GiB with strict cacheline alignment, sanitizing buffers before and after device access.

4. Deterministic Probe Transcripts & Quarantine
===============================================
* Every register read/write and timing delay executed during probe stages 3 and 4 is logged to an immutable execution transcript.
* Upon probe completion or stage transition, the transcript is hashed with BLAKE3 and sealed to the Content-Addressed Storage (CAS) repository.
* If a driver triggers an architectural fault, invalid register read, unauthorized write, or watchdog timeout, the substrate immediately revokes the driver's capabilities, places the device in ``QUARANTINE`` state, and registers the failure transcript for autonomous AI post-mortem analysis.

5. Verification & Traceability Matrix
=====================================
* ``[US-REN-004]``: Zero-libc substrate determinism and safe device boundary enforcement.
* ``[US-REN-006]``: Capability-bounded process supervision and hardware token attenuation.
* ``[US-GEM-001]``: Unforgeable binary telemetry and register audit transcripts.
* ``[US-GEM-009]``: Self-healing driver resilience and quarantine isolation.
* ``[US-GEM-010]``: Context-window-optimized module boundaries (<= 1,000 lines, functions <= 40 lines).
