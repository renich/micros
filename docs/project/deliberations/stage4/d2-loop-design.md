# Sovereign Stage 4: D2 Autonomous Self-Rewrite Loop & A/B Substrate Design Lock

:Document ID: DELIB-STAGE4-D2LOOP-001
:Status: STAMPED by checker 2026-09-29 (conditions P4-C1..C5 below)
:Author: Agy (Antigravity Senior Co-Architect)
:Checker Reviewer: Muse Code (Architect/Checker)
:Authority: Stage 4 Orders §0(a), SPEC-TECH-REBUILD-001
:Module Targets: `src/kernel/storage/slot.zig`, `src/kernel/storage/rebuild.zig`, `tools/micros-runner.bash`, `src/kernel/main.zig`

---

## 1. Executive Summary & Problem Statement

Autonomous operating system self-modification without hardware fallback or deterministic rollback is catastrophic: a single faulty instruction, regression, or lock inversion bricks the physical machine or hypervisor node permanently.

In MicrOS, autonomous self-amendment operates strictly through the **D2 Autonomous Self-Rewrite Loop**. Under Commandment 14 (Fail-Safe Panic Posture) and Commandment 4 (Zero Ambient Authority):
1. No self-modification may be committed directly to active execution storage.
2. Every candidate kernel amendment must be formalized as a structured **RFC Proposal**.
3. Every RFC must pass a suite of empirical performance and integrity gates (**G-perf**, **G-fault**, **G-tail**) wired to physical microbenchmarks.
4. Autonomous application is **frozen by default**; staging to hardware requires explicit operator authorization via the **Human-Thaw Protocol**.
5. Staged candidates are booted in an isolated **Trial Slot** guarded by an external hardware/hypervisor watchdog with an immutable deadline.
6. The kernel must autonomously prove operational health (verdict machine); on timeout or fault, the system rolls back to the last-known-good generation, committing an immutable diagnostic transcript to CAS.

---

## 2. Amendment RFC Lifecycle State Machine

```
   [PROPOSED] ──(RFC file created: diff + target + metric + rationale)
       │
       ▼
   [GATED] ────(Empirical benchmark gates executed: G-perf, G-fault, G-tail)
       │
       ▼ (Fails any gate)
   [REJECTED] ──(Fail transcript sealed to CAS; candidate discarded)
       │
       ▼ (Passes all gates)
   [FROZEN] ───(Staging blocked fail-closed; awaiting operator authorization)
       │
       ▼ (Human-thaw flag detected & cryptographically validated)
   [THAWED] ───(Authorization verified; candidate unlocked for staging)
       │
       ▼
   [STAGED] ───(PE32+ synthesized, written to alternate slot, TRIAL.DAT set)
       │
       ▼ (System reset/reboot into alternate slot)
   [TRIAL] ────(Watchdog armed with deadline; sentinel verification active)
      / \
     /   \ (Verdict PASS: sentinel verified, zero faults, healthy init)
    /     ▼
   /   [COMMITTED] ──(confirmBoot: clear TRIAL.DAT, advance generation, flip active)
  ▼ (Verdict FAIL: watchdog timeout, sentinel miss, or IDT fault)
[ROLLED_BACK] ──────(rollbackToPrevious: revert slot, seal fault transcript to CAS)
```

### 2.1 State Transition Definitions

| State | Entry Condition | Invariant Guarantee | Exit Condition |
| :--- | :--- | :--- | :--- |
| `PROPOSED` | RFC file submitted to `.agents/rfcs/<id>.json` | Read-only; zero disk or boot mutation | Gating script invoked |
| `GATED` | Benchmark harnesses executed against RFC candidate | Multi-run variance bounds enforced | All metrics evaluated |
| `REJECTED` | Any empirical threshold breached | Terminal state; reason logged to CAS | None |
| `FROZEN` | Candidate passed all empirical gates | Zero autonomous staging permitted | Operator thaw flag verified |
| `THAWED` | Valid `/tmp/micros-rfc-thaw.flag` present | Nonce and RFC ID match | Staging initiated |
| `STAGED` | Candidate written to inactive slot (A or B) | Inactive slot ONLY; active untouched | Hardware reboot triggered |
| `TRIAL` | UEFI boots candidate with `TRIAL.DAT == '1'` | Watchdog timer active; canary armed | Verdict evaluation |
| `COMMITTED` | Sentinel emitted, health confirmed | Monotonic generation advanced; active flipped | Normal runtime |
| `ROLLED_BACK` | Watchdog timeout, early panic, or sentinel miss | Fallback slot restored; candidate blacklisted | Diagnostic post-mortem |

---

## 3. Empirical Gate Definitions & Quantitative Thresholds

Every candidate amendment must execute three empirical gates before entering the `FROZEN` state:

### 3.1 Gate 1: Performance Improvement & No-Regression (`G-perf`)
- **Metric**: Fiber context switch throughput, memory allocation overhead, and VirtIO packet forwarding rates.
- **Harness**: `tools/micros-fiber-bench` and `tools/micros-virtio-bench`.
- **Threshold**:
  - For performance-targeted RFCs: $\ge 5.0\%$ improvement in primary target metric over baseline across 5 iterations.
  - For non-performance RFCs (bug fixes, refactors): strict no-regression proof, defined as $< 1.0\%$ degradation in throughput and latency.

### 3.2 Gate 2: Deterministic Fault Containment (`G-fault`)
- **Metric**: Regression prevention and fault-injection survival.
- **Harness**: Targeted test reproduction suite.
- **Threshold**: The candidate must demonstrate 100% resolution of the reproduced fault scenario while inducing zero regressions in existing unit tests (`487/487` tests passing minimum).

### 3.3 Gate 3: Tail-Latency & WCET Bound (`G-tail`)
- **Metric**: 99th percentile ($p99$) execution latency for kernel IPC dispatch and driver ISR handling.
- **Harness**: Substrate cycle timestamping (`io.rdtsc()`).
- **Threshold**: $p99 \le 50\,\mu\text{s}$ under full simulated load; zero unbounded loops satisfying Commandment 10 (Worst-Case Execution Time).

---

## 4. 512-Byte A/B BootSlotDescriptor Specification

To guarantee sector-aligned, atomic persistence under Commandment 9 and Commandment 4, slot state is stored in a 512-byte structure persisted in CAS and mirrored to sector 0 of the ESP state partition:

### 4.1 Binary Structure Layout

```zig
pub const SLOT_DESCRIPTOR_MAGIC: u32 = 0x534C4F54; // 'SLOT'
pub const SLOT_DESCRIPTOR_VERSION: u16 = 1;

pub const BootSlot = enum(u8) {
    slot_a = 'A',
    slot_b = 'B',
};

pub const BootSlotFlags = packed struct(u8) {
    trial_canary: bool = false,
    trial_failed: bool = false,
    dirty: bool = false,
    reserved: u5 = 0,
};

pub const BootSlotDescriptor = extern struct {
    // Header (8 bytes)
    magic: u32 align(1) = SLOT_DESCRIPTOR_MAGIC,
    version: u16 align(1) = SLOT_DESCRIPTOR_VERSION,
    active_slot: BootSlot align(1),
    flags: BootSlotFlags align(1),

    // Monotonic Generation & Epoch (16 bytes)
    generation: u64 align(1),
    timestamp: u64 align(1),

    // Cryptographic Hashes (32 bytes each = 96 bytes)
    active_kernel_hash: [32]u8 align(1),
    inactive_kernel_hash: [32]u8 align(1),
    system_manifest_hash: [32]u8 align(1),

    // Trial Boot Diagnostics & Sentinels (64 bytes)
    trial_deadline_ms: u32 align(1),
    trial_boot_count: u32 align(1),
    last_fault_vec: u16 align(1),
    last_fault_rip: u64 align(1),
    reserved_diag: [46]u8 align(1) = [_]u8{0} ** 46,

    // Ed25519 Provenance Signature (64 bytes)
    signature: [64]u8 align(1),

    // Padding to exactly 512 bytes (264 bytes)
    reserved_padding: [264]u8 align(1) = [_]u8{0} ** 264,
};
```

### 4.2 Interoperability with Existing `rebuild.zig` Markers

The existing implementation in `src/kernel/storage/rebuild.zig` relies on FAT32 files:
- `/EFI/BOOT/BOOTSTATE.DAT`: Contains `'A'` or `'B'`.
- `/EFI/BOOT/TRIAL.DAT`: Contains `'1'` (trial active) or `'0'` (stable).

**Unification Protocol**:
1. `BootSlotDescriptor` serves as the authoritative, cryptographically signed, sector-aligned structure stored in CAS and raw disk blocks.
2. When ESP FAT32 storage is attached (`setEspDevice`), `rebuild.zig` synchronously projects `BootSlotDescriptor.active_slot` to `BOOTSTATE.DAT` and `BootSlotDescriptor.flags.trial_canary` to `TRIAL.DAT`.
3. UEFI bootloaders reading either raw sectors or FAT32 files resolve identical slot and trial state.

---

## 5. Trial-Boot Verdict Machine & Watchdog Harness

### 5.1 Watchdog Architecture

The trial boot execution is guarded by an external supervisor harness (`tools/micros-runner.bash`):
1. **Deadline Timeout**: Configured with a strict 20-second timeout ceiling for trial runs.
2. **Sentinel Detection**: The runner scans serial stdout for the unambiguous kernel readiness sentinel:
   `=== MicrOS Sovereign Microkernel v0.16.0-dev ===` followed by `ush>` or `[  ok  ] spawn: Actor 1 (ush) online`.
3. **Fault Interception**: The runner halts immediately upon encountering any kernel panic indicator:
   `FATAL:`, `PANIC:`, `vector-14 page fault`, `#UD`, `#GP`, or unhandled exception register dumps.

### 5.2 Verdict Evaluation Logic

```
                    ┌────────────────────────────┐
                    │  UEFI Boot Target Slot     │
                    └─────────────┬──────────────┘
                                  │
                                  ▼
                    ┌────────────────────────────┐
                    │  Serial Log Stream Parse   │
                    └─────────────┬──────────────┘
                                  │
          ┌───────────────────────┴───────────────────────┐
          │                                               │
          ▼                                               ▼
[Sentinel Observed & 0 Faults]                   [Timeout or Fault]
          │                                               │
          ▼                                               ▼
┌───────────────────────────┐                 ┌───────────────────────────┐
│       VERDICT: PASS       │                 │       VERDICT: FAIL       │
├───────────────────────────┤                 ├───────────────────────────┤
│ 1. confirmBoot() invoked  │                 │ 1. Watchdog aborts trial  │
│ 2. TRIAL.DAT cleared ('0')│                 │ 2. rollbackToPrevious()   │
│ 3. Generation incremented │                 │ 3. Active slot restored   │
│ 4. Slot made primary      │                 │ 4. Fault sealed to CAS    │
└───────────────────────────┘                 └───────────────────────────┘
```

---

## 6. The Human-Thaw Protocol

To prevent rogue or runaway autonomous self-modification loops:
1. **Default Posture**: The self-rewrite engine is strictly **FROZEN**. It may analyze code, generate diffs, and run benchmark gates, but `stageSystemUpdate` will reject execution with `error.AmendmentFrozen`.
2. **Thaw Flag File**: Staging is unlocked only when a valid thaw token is detected at:
   `/tmp/micros-rfc-thaw.flag`
3. **Flag Format & Verification**:
   ```json
   {
     "schema": "micros.thaw.v1",
     "rfc_id": "RFC-2026-09-29-001",
     "operator": "renich@evalinux.com",
     "allowed_actions": ["STAGE", "TRIAL"],
     "expires_at": 1759160000,
     "nonce": "8f3b14e92a0c"
   }
   ```
4. **Execution Invariant**: The kernel or test harness verifies that `rfc_id` matches the candidate proposal and that the flag has not expired. Upon initiating the trial stage, the thaw token is atomically invalidated (or consumed), requiring fresh authorization for subsequent modifications.

---

## 7. Non-Goals & Invariants

1. **Zero Unattended Self-Rewrites**: The kernel will never promote an amendment without human thaw authorization.
2. **Zero In-Place Overwrites**: The active executing boot slot is never modified; updates write strictly to the inactive slot.
3. **Zero Commit/Push Invariant**: All Stage 4 operations remain in the local uncommitted working tree until human return.

## 8. Checker Stamp Conditions (Muse Code, 2026-09-29)

- **P4-C1 (watchdog reality)**: the primary sentinel
  `=== MicrOS Sovereign Microkernel v0.16.0-dev ===` matches
  nothing in the tree — DROP it. Sentinels are the real strings
  (µShell banner + `spawn: Actor 1 (ush) online`). No fixed 20s
  deadline for TCG: calibrate per-harness (3 measured boots,
  deadline = 2x max, documented). Fault-pattern set must be the
  runner `--fail` default as a subset, listed explicitly.
- **P4-C2 (slot persistence)**: raw-sector writes are FORBIDDEN
  in the demo — "sector 0 of the ESP" is the FAT VBR and writing
  it destroys the volume. Persist the descriptor via CAS + FAT
  projection (BOOTSTATE/TRIAL.DAT); raw-LBA layout is M42 scope.
  Add comptime `@sizeOf(BootSlotDescriptor) == 512` assert.
- **P4-C3 (thaw boundary)**: thaw verification is harness-side
  (`tools/`) ONLY, never Ring-0; `/tmp/micros-rfc-thaw.flag` is a
  HOST path — document the trust boundary (host operator holds
  physical access). Consume the flag (delete + nonce log), not
  "or".
- **P4-C4 (G-tail concrete)**: Phase 2 must define the load
  generator exactly (which bench, N, metric). The demo shows
  measured p99 numbers against the 50us bound — pass or honest
  fail-with-cause, never unmeasured.
- **P4-C5 (keys)**: no production keys anywhere. Demo/test
  Ed25519 keys are generated at test time with test-only
  provenance labels. Production key provisioning is an explicit
  non-goal with a named backlog item.
