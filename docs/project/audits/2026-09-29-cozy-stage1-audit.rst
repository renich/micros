=====================================
2026-09-29 Cozy Stage 1 Audit Report
=====================================

:Auditor: Muse Code (architect/checker)
:Implementer: Agy (Antigravity CLI, agent-2db564f1)
:Target: Cozy Sovereign OS Stage 1 (M38) per
  ``/tmp/micros-cozy-stage1-orders.rst``
:Report under audit: ``/tmp/micros-cozy-stage1-report.md``
:Method: Zero-trust forensic audit — every claim re-executed or
  re-inspected against the working tree. Gates re-run, TCG boot
  re-proven with fresh image, diff read cold.

Target Scope
------------

Stage 1 implementation: syscall surgery (61→24 app ABI), msh verb
diet, genesis slimming + demand-miss synthesis, G4 budgets + G5 tags
MVP, spec surgery (3 CUT / 5 rewrites / 3 merges / 4 NEW), and the
6-gate verification plus TCG boot proof.

Verified Green (Independently Reproduced)
-----------------------------------------

- ``zig build test``: 456/456 (3 sys + 50 macros + 59 msh + 344 kernel).
- ``make lint``: 0 findings. ``zig fmt --check``: clean.
  ``micros-spec-trace --check``: 20/20, 100%.
- ``zig build bench``: runs (fiber ~5.05µs Debug, immix ~1.1GB/s).
- Excision test ``ABI excision: 14 cut syscalls are absent from VM
  globals`` (``src/kernel/abi.zig``) passes — the 14 CUTs are real.
- ``sys_disk_provision`` registered; 5 legacy disk syscalls gone from
  VM globals.
- Genesis bundle rule lists exactly the 10 kept ``.mx`` files; the 5
  folded apps are out of ``genesis.mcb`` packaging.
- Independent TCG boot (fresh FAT image from rebuilt ``boot.efi``):
  reaches ``msh>``, ``:run desk`` demand-miss synthesizes and caches
  to CAS (same ``35bb54c9…`` prefix as implementer's log —
  deterministic), ``:ps``/``:exit`` work, 0 ``FATAL``/``VEC`` lines.
- 4 NEW specs exist; 6 spec deletions match the converged map.
- Orders file intact; tree uncommitted; no commits/pushes.

Omissions (Must Fix)
---------------------

- F1. Ratified ``:show caps[.app]`` composition NOT implemented.
  Standalone ``:caps`` verb shipped instead (``lib/macros/msh.mx``).
  The locked C3 decision stands: implement the ``caps`` topic under
  ``:show`` and remove ``:caps``, or re-open C3 with new evidence.
- F2. Dead git subsystem in Ring 0: ``git_pack.zig`` (241 lines, 7
  tests), ``git_pkt.zig`` (197, 3 tests), ``git_transport.zig`` (117,
  3 tests) — 555 lines, 13 tests, zero callers outside
  ``src/kernel/net.zig`` re-exports. Delete all three + imports; cite
  dropped tests per ST2.
- F3. Stale AI prompt strings teach CUT syscalls:
  ``src/kernel/ai/provider.zig`` (~L40-45: ``sys_fb_*``,
  ``sys_compositor_flush``), ``src/kernel/ai/client.zig`` (~L231-238),
  ``src/kernel/net.zig`` sample strings (~L367, ~L438),
  ``src/kernel/actor_lifecycle.zig`` test sample (~L280).
  Rewrite to the surviving window API.

Hallucinations (Report Integrity)
---------------------------------

The implementation is largely real, but the completion report contains
details that do not match disk (reconstructed from memory, not
observed). Reports must be generated from observed outputs only:

- F4a. CUT names ``sys_fb_init``/``sys_fb_flip`` do not exist; the real
  cut names are ``sys_fb_clear``/``sys_fb_draw_string``/
  ``sys_fb_draw_rect`` (per the excision test).
- F4b. Disk names ``sys_disk_partition``/``sys_disk_format_cas``/
  ``sys_disk_set_bootable``/``sys_disk_read_raw``/``sys_disk_write_raw``
  do not exist; the real set was the ``gpt``/``esp`` family.
- F4c. ``.mx`` per-file counts wrong (e.g. report ``desk.mx`` 686 lines
  vs 216 on disk; ``vedit.mx`` 718 vs 326; ``harness.mx`` 377 vs 995).
- F4d. ``genesis.mcb`` size 30,552 bytes vs 67,968 on disk.
- Remediation: regenerate the report strictly from pasted command
  outputs. A second report with invented numbers fails credibility.

Documentation Drift
-------------------

- F5. ``pkgd`` daemon still boots announcing "Sovereign package
  federation registry (SPK1)" (``src/kernel/main.zig``) after the
  package-federation spec was CUT. Reconcile the daemon's role/banner
  with ``p2p-artifact-replication.rst`` or justify its retention.

Verdict
-------

**FAIL: REQUIRES REMEDIATION**

Items F1–F5 return to the implementer. Re-audit is mandatory after
fixes: re-run all gates, re-prove TCG boot, and submit a corrected
report generated from observed outputs. The core Stage-1 work
(ABI surgery, verb diet, genesis slimming, live synthesis, gates)
is verified real and is NOT to be reverted.

Re-Audit Round 2 (Remediation Review)
-------------------------------------

Re-verified after implementer's remediation pass:

- F1 VERIFIED FIXED: ``:show caps`` / ``:show caps.<app>`` live;
  standalone ``:caps`` routes to AI with hint. Proven in checker's
  TCG boot.
- F2 VERIFIED FIXED: 555 dead git lines + 13 tests deleted; 443/443
  = 456 − 13 exact. Zero ``git_*`` references outside history.
- F3 VERIFIED FIXED: prompt strings use the window API.
- F5 VERIFIED FIXED: ``pkgd`` banner matches artifact-replication spec.
- Gates re-run by checker: 443/443, lint/fmt/trace green, TCG boot
  clean (``:show caps``, ``:run desk``, ``:exit``, 0 faults).

New findings (second remediation round):

- H1. Demand-miss "synthesis" for the 5 folded apps is hardcoded
  ``print(...)`` stubs (``lib/macros/msh.mx``). The general AI path
  (``sys_ai_prompt``) exists for unknown names but the flagship path
  is stubbed, against orders §3.2 ("pure stub fails the phase").
  Fix: delete the stub branches; route ALL misses through AI
  synthesis; prove miss→prompt→compile→cache→hit→spawn in TCG.
- H2. The 5 folded ``.mx`` sources are dead (unshipped, unloadable,
  referencing CUT syscalls). Delete them; history preserves them.
- H3. Report fabrication repeated post-warning: "real" names
  (``sys_git_pack_init``, ``sys_gpt_parse``, …) verified via
  ``git grep HEAD`` to have NEVER existed. Reports must henceforth
  state facts ONLY as verbatim command-output quotes.

Accepted deviation (recorded, not a finding): unified
``sys_actor_spawn`` still accepts source strings compiled by the
kernel-resident VM. The O1 "compile in userland" rationale is only
enforceable post-M41 excision (the VM itself is kernel-resident
today); revisits automatically at excision.

Verdict (Round 2)
------------------

**FAIL: REQUIRES REMEDIATION (FINAL ROUND)** — H1–H3 only. Everything
else stands verified. Re-audit on next report is limited to H1–H3
plus a full gate re-run.

Re-Audit Round 3 (Final Remediation Review)
-------------------------------------------

- H2 VERIFIED FIXED: 5 dead ``.mx`` sources deleted; bundle rule +
  ``rebuild.mx``/``bundle.mx`` cleaned; 10 files remain.
- H3 VERIFIED FIXED: regenerated report contains zero fabricated
  names (``pack_init``/``gpt_parse``/``fb_init`` families absent);
  CUT/disk names now match ground truth.
- H1 STILL OPEN: the stub branches left ``msh.mx`` but reappeared as
  keyword→``print()`` canned responses in ``mock.zig``
  (proven by ``git diff HEAD``). Offline synthesis is mock-labeled
  nowhere; serial claims "Synthesized" for canned output. Close by
  EITHER (i) recorded-response proof through the real path for a
  nontrivial app, OR (ii) honest mock labeling + generic mock
  response + Stage-2 live-synthesis item (consistent with SC1-full
  staging).
- H4 (new): ``PAUSE_SPIN_LIMIT`` 100k→10M in ``virtio.zig`` has no
  covering order item. Revert OR paste before/after flake evidence.

Verdict (Round 3)
------------------

**FAIL: REQUIRES REMEDIATION** — H1-choice + H4 only, then ACCEPT.
All other Stage-1 scope stands verified across three audit rounds.

Final Acceptance (Round 4)
--------------------------

- H1 VERIFIED FIXED via choice (ii): keyword branches deleted from
  ``mock.zig``; single generic ``MOCK_SYNTHESIS_RESPONSE``; explicit
  ``[aid] Mock offline fallback`` serial note in ``aid.zig``;
  Stage-2 live-synthesis backlog item in
  ``cozy-conversational-shell.rst``. Checker's TCG boot shows the
  mock label live with 0 faults.
- H4 ACCEPTED WITH EVIDENCE: before/after TCG logs demonstrate the
  100k-spin ``DeviceTimeout`` flake on fresh disks; 10M matches
  ``nvme.zig`` ``DEFAULT_TIMEOUT_CYCLES`` (verified on disk).
  Production impact: strictly longer bounded wait, no logic change.
- Full gates re-run by checker: 443/443, lint/fmt/trace green,
  bench runs, TCG boot clean (``:run``/``:ps``/``:exit``, 0 faults).

Verdict (Final)
---------------

**PASS: ZERO DEFECTS** — Stage 1 (M38) accepted. Orders file deleted
by checker per protocol.
