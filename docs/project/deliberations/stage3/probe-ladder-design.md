# Sovereign Stage 3: D1 Autonomous Driver Synthesis & Probe Ladder Design Lock

:Document ID: DELIB-STAGE3-PROBE-001
:Status: STAMPED by checker 2026-09-29 (conditions P0-C1/C2/C5 below)
:Author: Agy (Antigravity Senior Co-Architect)
:Checker Reviewer: Muse Code (Architect/Checker)
:Authority: Stage 3 Orders §0(a), SPEC-TECH-DRV-001
:Module Targets: `src/kernel/drivers/pci.zig`, `src/kernel/drivers/probe_ladder.zig`, `src/kernel/abi.zig`, `src/kernel/cap/capability.zig`

---

## 1. Executive Summary & Problem Statement

Unrestricted driver execution and ad-hoc hardware probing are catastrophic in a zero-trust microkernel. Rogue MMIO writes, unauthorized DMA, or improper initialization sequences can lock the PCI bus, crash the machine, or brick physical silicon.

Under **SPEC-TECH-DRV-001** and MicrOS Commandment 4 (Zero Ambient Authority), driver synthesis and probing must transition through a strictly monotonic, 6-stage anti-bricking probe ladder (`STG_0` through `STG_5`). Any deviation, unexpected write, or timeout trips an immediate fail-closed abort into `QUARANTINE`, revoking all probe capability tokens and sealing an immutable BLAKE3-hashed execution transcript to Content-Addressed Storage (CAS) for autonomous post-mortem diagnosis.

---

## 2. The 6-Stage Anti-Bricking Probe State Machine

```
   [STG_0: DETECT]
          │  Device arrival event (PCI bus enumeration)
          ▼
   [STG_1: PASSIVE_ENUM] ──(Config-space read only: VID/DID/Class/BAR sizes; zero MMIO/port access)
          │
          ▼
   [STG_2: OFFLINE_SYNTH] ──(Macros userland driver actor synthesized or catalog resolved; zero I/O)
          │
          ▼
   [STG_3: AUDIT_RO] ────(Read-only MMIO sandbox; ANY write trip aborts to QUARANTINE)
          │
          ▼
   [STG_4: ACTIVE_PROBE] ──(Bounded, count-capped writes: scratch register & IRQ loopback ONLY)
          │
          ▼
   [STG_5: OPERATIONAL] ──(Token Triad granted: hardware_device + irq_endpoint + dma_buffer)
          │
          ▼ (On any violation/timeout/fault)
   [QUARANTINE] ──────────(All probe tokens revoked via G6; BLAKE3 transcript committed to CAS)
```

### 2.1 Stage Definitions & Invariant Transitions

#### Stage 0: `STG_0_DETECT`
- **Trigger**: PCI bus scan (`pci.scanBus()`) detects a valid vendor ID (`vendor_id != 0xFFFF`).
- **Substrate State**: Allocates a monotonically increasing probe identifier `probe_id: u32`. Device is held quiescent; bus mastering and memory space decode are disabled in PCI command register (`CMD_MEMORY_SPACE = 0`, `CMD_BUS_MASTER = 0`).
- **Capability State**: Zero hardware capabilities granted.

#### Stage 1: `STG_1_PASSIVE_ENUM`
- **Scope**: Configuration space access strictly via standard PCI mechanism (`0xCF8`/`0xCFC`).
- **Operations Permitted**: Reads of Vendor ID, Device ID, Class, Subclass, ProgIF, Subsystem IDs, and BAR size detection (writing `0xFFFFFFFF` to BARs and reading back masks during kernel init before probe actor spawn).
- **Prohibited Operations**: **ZERO MMIO reads/writes, ZERO Port I/O, ZERO interrupt generation**. Any access to physical device addresses trips a fatal ladder violation.
- **Exit Condition**: Full device configuration descriptor captured into probe state; transitions to `STG_2`.

#### Stage 2: `STG_2_OFFLINE_SYNTH`
- **Scope**: Offline analysis and driver synthesis in isolated userland (Ring 3).
- **Operations Permitted**: Local CAS catalog query for existing driver bytecode (`driver.<vid>.<did>`) or dispatch to Resident AI (`aid`) to synthesize candidate Macros driver script from technical reference corpus.
- **Hardware Access**: **STRICTLY ZERO**. The driver actor does not yet possess any device tokens.
- **Exit Condition**: Driver bytecode compiled and validated by Macros compiler; transitions to `STG_3`.

#### Stage 3: `STG_3_AUDIT_RO` (Read-Only MMIO Sandbox)
- **Scope**: Read-only verification of device identity, capability pointers, and status registers.
- **Capability Granted**: Attenuated probe token:
  - `CapType.hardware_device`: `Rights.READ` only (MMIO BAR address space mapped with non-writable page table attributes).
- **Write-Trip Mechanics**:
  - The page table mapping for the driver's MMIO access enforces `PAGE_WRITABLE = 0`.
  - Any CPU store instruction targeting the MMIO window triggers a Page Fault (`#PF`) or capability violation trap.
  - The fault handler intercepts the trap, logs the illegal write address and value into the probe transcript, immediately revokes the probe capability, and shifts the device into `QUARANTINE`.
- **Exit Condition**: Candidate driver reads all required signature registers and asserts compatibility; transitions to `STG_4`.

#### Stage 4: `STG_4_ACTIVE_PROBE` (Bounded Non-Destructive Active Verification)
- **Scope**: Controlled verification of writable registers to prove device responsiveness without risking state corruption.
- **Capability Granted**:
  - `CapType.hardware_device`: `Rights.READ | Rights.WRITE` restricted to designated scratchpad offset ranges.
- **Bounds & Watchdog Limits**:
  - **Count Ceiling**: Exactly capped at maximum `MAX_ACTIVE_PROBE_OPS = 16` write operations. Attempting operation 17 causes an immediate ladder fault.
  - **Permitted Targets**: Scratch/loopback test registers and software interrupt generation registers ONLY.
  - **Cycle/Time Watchdog**: Guarded by a 50,000-cycle (or 100ms) execution watchdog. If the device fails to complete handshakes within budget, probe aborts.
- **Exit Condition**: Loopback writes read back accurately; interrupt line delivers verified notification; transitions to `STG_5`.

#### Stage 5: `STG_5_OPERATIONAL` (Full Service Promotion)
- **Scope**: Driver promoted to operational status and registered with the device manager.
- **Capability Promotion**: The temporary probe tokens are revoked, and the permanent **Token Triad** is minted and delegated to the driver actor:
  1. `CapType.hardware_device`: `Rights.READ | Rights.WRITE | Rights.REVOKE` (bounded to BARs).
  2. `CapType.irq_endpoint`: `Rights.READ | Rights.REVOKE` (bound to device IRQ vector).
  3. `CapType.dma_buffer`: `Rights.READ | Rights.WRITE | Rights.REVOKE` (managed via `sys_dma_bounce_copy`).

---

## 3. The Quarantine Posture

### 3.1 Quarantine Entry Triggers
A device enters `QUARANTINE` immediately if:
1. `STG_1`: Any MMIO or Port I/O access is attempted.
2. `STG_3`: Any write operation is attempted against read-only MMIO.
3. `STG_4`: Write count exceeds 16, write target is outside scratchpad whitelist, or loopback data mismatch occurs.
4. Any stage: Watchdog timeout expires, hardware bus parity error occurs, or driver actor panics.

### 3.2 Quarantine Actions
1. **Immediate Revocation**: Kernel invokes G6 cascading revocation on all capability tokens associated with the probe session.
2. **Hardware Quiescence**: PCI Command register cleared (`CMD_BUS_MASTER = 0`, `CMD_MEMORY_SPACE = 0`, `CMD_IO_SPACE = 0`). Interrupt line masked at APIC/IOAPIC.
3. **Sealed CAS Transcript**: The complete in-memory probe transcript is hashed via BLAKE3, stored in CAS as `probe.quarantine.<device_id>`, and linked in the system log.
4. **Permanent Isolation**: The device slot is locked; no further actors may bind to the device until an explicit administrator or AI remediation manifest is ratified.

---

## 4. Deterministic Probe Transcript Format

Every probe session maintains a pre-allocated, zero-allocation circular event transcript in the kernel (`ProbeTranscript`):

```zig
pub const ProbeOpType = enum(u8) {
    pci_cfg_read = 0x01,
    mmio_read = 0x02,
    mmio_write = 0x03,
    port_read = 0x04,
    port_write = 0x05,
    irq_wait = 0x06,
    irq_received = 0x07,
    stage_transition = 0x08,
    violation_trip = 0x09,
};

pub const ProbeTranscriptEntry = extern struct {
    timestamp_cycles: u64,
    stage: u8,
    op: ProbeOpType,
    reserved: u8 = 0,
    address: u64,
    value: u64,
    status_code: u32,
};

pub const MAX_TRANSCRIPT_ENTRIES: usize = 64;

pub const ProbeTranscript = struct {
    probe_id: u32,
    vendor_id: u16,
    device_id: u16,
    final_stage: u8,
    is_quarantined: bool,
    entry_count: usize,
    entries: [MAX_TRANSCRIPT_ENTRIES]ProbeTranscriptEntry,
    blake3_hash: [32]u8,
};
```

### 4.1 CAS Commit Point
Upon exiting the probe ladder (either entering `STG_5_OPERATIONAL` or `QUARANTINE`):
1. The kernel computes `blake3_hash = BLAKE3(entries[0..entry_count])`.
2. The transcript is committed to CAS via `cas_put(serialized_transcript)`.
3. The catalog records the entry under `probe.transcript.<pci_slot>`.

---

## 5. QEMU Proof & Test Strategy

1. **Known-Good Proof (VirtIO-Net)**:
   - System boots, detects VirtIO-Net (`1AF4:1000` or `1AF4:1041`).
   - Transitions `STG_0` -> `STG_1` -> `STG_2` -> `STG_3` -> `STG_4` -> `STG_5`.
   - Reaches `OPERATIONAL` status with full Token Triad delegated.
2. **Honest Quarantine Proof (Synthetic Unknown Device)**:
   - Inject synthetic PCI device ID or deliberately trip a write in `STG_3_AUDIT_RO`.
   - Substrate detects violation, clears bus mastering, revokes tokens, logs `[probe] Hardware violation: write in AUDIT_RO -> QUARANTINE`, and commits transcript to CAS.
   - Zero kernel panic; zero system halt.

---

## 6. Convergence Checklist for Checker (Muse Code)

- [ ] STG_0..STG_5 formal progression ratified without shortcutting.
- [ ] AUDIT_RO write-trip mechanics defined at page-table and capability level.
- [ ] ACTIVE_PROBE bounds locked at <= 16 operations and scratch/IRQ whitelist.
- [ ] Token Triad explicitly enumerated with least-privilege rights.
- [ ] Quarantine behavior fail-closed with BLAKE3 CAS transcript seal.

## 7. Checker Stamp Conditions (Muse Code, 2026-09-29)

- **P0-C1 (new CapTypes)**: `hardware_device` + `dma_buffer` do not exist in
  `capability.zig` (verified: only 0x0000-0x0007 defined). Adding them as
  0x0008/0x0009 is APPROVED — dedicated device types beat flag-overloaded
  `memory_extent` — but each needs a justification comment at the enum,
  grant/revoke/ABI wiring, and colocated attenuation + deny-path tests.
  Also reconcile the spec variance in Phase 6: SPEC-TECH-DRV-001 §3.1 names
  `irq_handler`, code/design use `irq_endpoint` (correct choice — update spec).
- **P0-C2 (#PF hook scope)**: the STG_3 write-trip hook in the vector-14 path
  must range-check the faulting address against the ACTIVE probe MMIO window
  FIRST; faults outside the window keep existing behavior bit-for-bit. Test
  both: in-window write -> QUARANTINE; out-of-window #PF -> legacy path.
- **P0-C5 (probe actor confinement)**: STG_1 BAR-sizing writes stay in kernel
  init (never probe-actor reachable); STG_4 whitelist addresses are
  per-device descriptor constants, never actor-supplied. Prove by code path.
