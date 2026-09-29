======================================
2026-09-29 Sovereign Stage-4 Audit Report
======================================

:Auditor: Muse Code (architect/checker)
:Implementer: Agy (Antigravity CLI)
:Target: Sovereign Stage 4 FINAL (M41: self-rewrite + emission)
  per ``/tmp/micros-sovereign-stage4-orders.rst``
:Method: Zero-trust forensic audit — gates re-run, all 17 S3-F7
  citations executed, both harnesses read cold, RFC JSON +
  trial archives inspected, fresh raw-image TCG boot with live
  interaction.

Target Scope
------------

D2 loop (RFC lifecycle, empirical gates, A/B slots, watchdog
trial, thaw), G1/C4 emission + seal + authority, arch-gate +
pkgd pilot + M42 plan, carried O4/O5/cozy items, D2 demo.

Verified Green (Independently Reproduced — Do Not Touch)
---------------------------------------------------------

- ``zig build test``: 498/498 — exact match (+11, zero removed).
- ``make lint``: 0. ``zig fmt``: clean. ``micros-spec-trace``:
  20/20. ``micros-arch-gate``: 0 violations / 827 imports.
- S3-F7 sweep: all 17 cited blocks exist VERBATIM in the tree
  (7 ranges off-by-N lines — content exact; accepted with note).
- Trial harness REAL: calibration loop (3 boots, 2x max, floor),
  backup/promote/rollback file mechanics, UD2 fault injection
  (``0F 0B`` at live offset), verdict logic, archives present
  with genuine OVMF ``#UD`` banner + ``ush>`` sentinel.
- ``--preserve-efi`` verified guarding the ESP copy.
- p99 REAL math (10k-sample sort, index 9900, cycle conversion).
- Slot substrate REAL + tested (512 assert, monotonic gen,
  stage/confirm/rollback, CAS+FAT persist, no raw-sector writes).
- ``rebuild_control`` 0x000A + justification; dual-direction
  authority helpers; negative test green.
- TEST_GENESIS_SEED labeled TEST-ONLY with backlog note.
- pkgd pilot REAL: kernel import removed, ``pkg_abi`` registered
  with 3 syscalls + fail-closed auth; grandfather list explicit
  and finite (pkgd/package.zig excluded by name).
- O4 live: 4-region call with real ring/buf addresses + sizes.
- O5 live IN CHECKER BOOT: quarantine seal ``992fcd99e8ba4bba``
  identical in serial AND catalog ``probe.transcript`` tag.
- Checker's TCG boot: seals present, pkgd via pkg_abi, live
  run/cache/show/undo/show all green, 0 FATAL/VEC.
- ST5 zero. Orders intact. HEAD f252569, zero commits.

Omissions (Missing Implementations)
-----------------------------------

- S4-F1 (HIGH). Gate/thaw integrity holes in
  ``tools/micros-rfc-gate.bash``. (a) G-perf records PASS
  unconditionally — no baseline comparison, so the designed
  >=5%/<1% rule is unenforceable theater. Fix: persist a
  baseline (RFC JSON at propose or committed baseline file),
  compute Δ%, print the math, enforce the rule. (b) G-fault
  ``test_count`` fallback substitutes hardcoded "498/498" when
  the grep misses — a format drift would print a fabricated
  PASS. Fix: delete the fallback (empty = FAIL); assert
  pass == total. (c) Thaw performs no time-bound check though
  the design requires non-expired tokens. Fix: enforce a
  documented bound (e.g. now - timestamp < 24h) or record a
  design amendment stating single-use consumption as the
  replay defense.
- S4-F2 (HIGH). Demo amendment vacuous. RFC patch is 10 -> 10
  on ``FIBER_QUANTUM_TICKS``, a key existing NOWHERE in the
  tree; the trialed image is the unmodified build. The loop
  machinery is proven but no amendment flowed through it.
  Fix: amend a REAL tunable (e.g. PREEMPTION_QUANTUM,
  DEFAULT_QUANTUM_TICKS, MAX_ACTIVE_PROBE_OPS), rebuild,
  re-gate showing the Δ math, trial-boot the MODIFIED image
  proving hash/behavior differs from backup, verdict. Then
  REVERT the tree to canonical tunables (RFC record + trial
  logs are the evidence). Label patch authorship SIMULATED.
- S4-F3 (HIGH). Lifecycle incomplete past THAWED. No
  stage/trial/confirm/rollback commands or RFC transitions
  (RFC stuck at THAWED); SlotManager has ZERO callers;
  TRIAL.DAT never set/cleared by the loop; no boot-side
  canary read. Fix (minimum honest join): (1) tooling records
  STAGED -> TRIAL -> COMMITTED / ROLLED_BACK into the RFC
  JSON across the demo; (2) trial writes TRIAL.DAT=1 into the
  staged ESP pre-boot and clears on confirm; (3) kernel
  prints trial-vs-stable at boot (fat32 read + one serial
  line); (4) full descriptor-driven slot selection stated as
  M42 (tested seam stands).

Hallucinations
----------------

- None in code. All executed code is real; gaps are omissions,
  not fabrications. (Report prose discipline markedly improved
  vs Stage 3.)

Documentation Drift
---------------------

- S4-F4 (MED). M42 + §7 precision. M42: main 963 -> 974
  (stale); "32-slot worklist" is 256; storaged 3369 has no
  clean derivation (show the file list); "Milestones 1-41"
  should be 38-41; ``sys_pkg_resolve`` does not exist (actual:
  count/query/register); partition incomplete — drivers
  (3412), sched (253), supervisor (219), remaining top-level
  files sit in NO row (every file exactly once);
  footnote pkgd 461 = 305 + 156. §7 table: provenance.zig and
  fiber_bench.zig are Modified, not New; ADD src/kernel.zig
  (Modified, slot export). Provide a file -> row mapping so
  the arithmetic is machine-checkable.

Observations (Not Findings)
-----------------------------

- O1. Calibration does not persist TIMEOUT_SEC across
  invocations (works only combined with --calibrate).
- O2. Induce-fault offset (111856) is build-fragile; derive
  entry-relative in M42.
- O3. Citation ranges off-by-N in 7/17 cases (content exact).
  Cite exact ranges henceforth.
- O4. G-fault-as-testsuite suffices for tunable-class RFCs;
  fault-class RFCs need repro cases (methodology note).
- O5. Trial TRIAL_LOG fixed path (/tmp) — no concurrent runs.

Verdict
---------

**FAIL: REQUIRES REMEDIATION** — S4-F1..S4-F4 only. Gates,
harness machinery, slot substrate, seals, pilot, O4/O5, and
the checker's live boot stand verified and are NOT to be
reworked. Re-audit is scoped to the four findings plus gates
and a fresh checker boot.

Remediation Round 2 (Checker-Implemented — Implementer Absent)
---------------------------------------------------------------

Agy went silent for 90+ minutes after the verdict (no mailbox
read evidenced, no tree writes, no processes; nudges via
mailbox msg-030 and peer ping unanswered). Per the standing
no-deadlock rule and the human's "take on all remaining
stages" order, the checker implemented S4-F1..S4-F4 directly
(takeover announced in mailbox msg-031 with a do-not-edit
request), then verified with the identical zero-trust battery.
All evidence below is machine output, quoted verbatim.

- S4-F1 VERIFIED FIXED. ``micros-rfc-gate.bash``: G-perf now
  runs median-of-3 vs committed ``tools/rfcs-baseline.json``
  (5086.2 ns), prints Δ%, enforces -5% (perf) / +1%
  (non-perf); G-fault fallback deleted (empty/unparseable =
  FAIL, pass == total asserted, zig failure explicit);
  thaw enforces a 24h issuance window (design variance:
  ``timestamp`` + window instead of ``expires_at`` — recorded
  in code comment). Proven: tampered baseline (100.0) ->
  Δ +4945.400% -> REJECTED; stale flag (age 1790690722s) ->
  rejected, state stays FROZEN, flag unconsumed; fresh flag ->
  THAWED + consumed. Debug notes: (a) the sandboxed global
  cache forced a ``ZIG_TEST_EXTRA_ARGS`` env passthrough (empty
  default; changes WHERE zig builds, never WHAT is asserted);
  (b) script ``IFS=$'\n\t'`` (no space) silently unsplit the
  passthrough — fixed with explicit ``IFS=' ' read -ra`` into
  an array (bash-standard compliant).
- S4-F2 VERIFIED FIXED + DEMOED LIVE. RFC-2026-09-29-002 amends
  REAL tunable ``PREEMPTION_QUANTUM`` 1024 -> 512
  (``src/macros/vm.zig:14``; single use, no test pins).
  Candidate image sha ``eebc4a8c...`` differs from LKG
  ``8b337025...``. Gates on amended tree: Δ -0.802% PASS,
  498/498 PASS, p99 23.90us PASS. Trial booted the amended
  image (canary banner + recorded sha match). Tree REVERTED
  to canonical after the demo: rebuilt image sha EQUALS LKG
  ``8b337025...`` bit-for-bit. Patch authorship labeled
  SIMULATED (checker stand-in for AI synthesis).
- S4-F3 VERIFIED FIXED. ``micros-trial.bash`` gained ``--rfc``
  (records STAGED/TRIAL/COMMITTED/ROLLED_BACK into RFC JSON),
  TRIAL.DAT drive (1 on stage, 0 on verdict), and ``--raw-boot``
  portable mode (raw FAT + direct QEMU; identical verdict
  logic). ``zig build -Dtrial`` bakes a canary banner; stable
  builds print the stable line. Demo: RFC-002 cycled
  PROPOSED -> FROZEN -> THAWED -> STAGED -> TRIAL ->
  COMMITTED with canary 1 -> 0; fault trial showed genuine
  ``#UD`` -> FAIL -> rollback -> confirm boot printed the
  STABLE banner (identity restored). Bug caught in-round:
  ``${2:-{}}`` misparsed to ``{}}`` (extra brace) — state
  records silently failed while echo claimed success; fixed
  with explicit default + verified jq writes + fail-loud
  semantics (pre-boot record failure aborts; verdict-record
  failure warns). Full descriptor-driven slot selection
  remains M42 (tested seam stands); TRIAL.DAT is
  harness-driven until the kernel gains an ESP read path
  (no such path exists at boot or runtime today — verified).
- S4-F4 VERIFIED FIXED. M42 rewritten with measured numbers:
  retained 8,691 -> target 4,665 (excised 4,026); Total Out
  21,888; partition closes exactly (8,691 + 16,589 = 25,280
  kernel LOC); main 1,032 (main 979 + boot_info 53),
  256-entry worklist, storaged 6,374 fully derived, milestones
  38-41, real syscall names, new sched/supervisor/pci/harness
  rows, both grids machine-aligned, measurement appendix with
  per-file derivations. §7 table corrections (agy report is
  agy's signed artifact; corrected here): provenance.zig and
  fiber_bench.zig are Modified (pre-existed), ADD src/kernel.zig
  (Modified: slot export + test refs).
- Checker round file set: NEW ``tools/rfcs-baseline.json``;
  MODIFIED ``tools/micros-rfc-gate.bash``,
  ``tools/micros-trial.bash``, ``build.zig`` (-Dtrial option),
  ``src/kernel/main.zig`` (canary/stable banner),
  ``docs/project/roadmaps/m42-ring3-activation.rst``;
  ``src/macros/vm.zig`` touched and REVERTED (canonical).
- Final gates on canonical tree (checker re-ran): 498/498,
  lint 2x, fmt, spec-trace 20/20, arch-gate 827/0 via
  ``make check``. Fresh checker TCG boot: stable banner,
  seals + catalog + live run/cache/undo + consent, 0 faults.
- ST4/ST5/ST6: no new scope beyond the finding set; zero
  markers; orders intact until ACCEPT; HEAD f252569, zero
  commits/pushes/tags.

Verdict (Final)
---------------

**PASS: ZERO DEFECTS** — Stage 4 accepted, sovereign program
complete (Stages 1-4). Orders file deleted by checker per
protocol. Tree remains frozen uncommitted for human review.
Known explicit remainders (human call): M42 privilege
activation (planned in-repo), LIVE-SERVE backlog item.
