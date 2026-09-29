======================================
2026-09-29 Sovereign Stage-3 Audit Report
======================================

:Auditor: Muse Code (architect/checker)
:Implementer: Agy (Antigravity CLI)
:Target: Sovereign Stage 3 (gadgets + undo) per
  ``/tmp/micros-sovereign-stage3-orders.rst``
:Method: Zero-trust forensic audit — gates re-run, fresh raw-image
  TCG boot with live interaction, diff read cold, every cited test
  name and proof string grepped against the tree.

Target Scope
------------

Stage 3 implementation: Phase-0 stamped designs (ladder, undo),
G6 cascading revocation, sys_dma_bounce_copy, D1 probe ladder
STG_0..STG_5 + QUARANTINE, real :undo + snapshot ring + tombstones
+ @gen, success-cases REDUX, spec sync.

Verified Green (Independently Reproduced — Do Not Touch)
---------------------------------------------------------

- ``zig build test``: 487/487 (3 + 50 + 59 + 375) — exact match.
- ``make lint``: 0 findings. ``zig fmt``: clean.
  ``micros-spec-trace``: 20/20, 100%.
- ST4 HOLDS: post-04:00 file set (18) == report §2 table modulo the
  journal entry. Zero strays. ST5: zero TODO/FIXME/XXX/HACK.
  ST6: orders file intact. Zero commits/pushes/tags.
- Ladder mechanics REAL: monotonic transitions enforced, AUDIT_RO
  write-trip, 16-op ceiling, descriptor-constant whitelist, BLAKE3
  seal, #PF hook range-checks window FIRST with legacy fall-through
  (code-read + unit tests; P0-C2/C3/C5 mechanics hold).
- G6 cascade REAL: iterative worklist, lineage fail-closed via
  ``get()``, GRANT-gated mint, no-escalation, depth-64 + sibling +
  idempotence tests pass.
- Undo core REAL: ring math verified (push/prev/oldest/find all
  correct), forward-commit M_{G+1}, tombstone flag semantics,
  rewrite-resurrect, eviction errors, @gen parse unambiguous
  (``@`` rejected by validatePath). P0-C4 mechanics hold.
- ``cmd_undo`` calls real ``sys_catalog_undo`` with honest genesis
  branch. Theater strings gone.
- ``hardware_device`` 0x0008 + ``dma_buffer`` 0x0009 present with
  justification (P0-C1 code side holds).
- DMA negative-path tests thorough (overflow, over-length, 4GiB,
  align, type, rights) + positive copy test present.
- ``sys_dma_bounce_copy`` registered in VM globals (live via ABI).
- Checker's TCG boot (raw image, my own script): probe OPERATIONAL
  + QUARANTINE lines, consent Allow -> Actor 2 spawned, 0 FATAL,
  0 VEC, µShell sentinel.

Omissions (Missing Implementations)
-----------------------------------

- S3-F1 (HIGH). Boot-path OPERATIONAL promotion bypasses
  ``advanceToOperational``: ``main.zig`` sets
  ``session.stage = .stg_5_operational`` by direct assignment — no
  Token Triad minted, no probe-cap revoke, no CAS commit — while
  serial claims "(Token Triad granted, CAS sealed)". Compounded:
  ``cas_put_transcript_fn`` is NEVER assigned anywhere, so NO
  transcript reaches CAS on ANY path; "sealed to CAS" is hashing
  without commit. Ordering constraint: probe runs BEFORE CAS init
  in boot order, so the fix must move CAS init earlier or defer
  transcript commit until CAS is ready (prove the chosen order).
  Fix: wire a real CSpace into the boot session, call
  ``advanceToOperational`` with the real ring DMA addresses,
  assign the transcript hook via a CAS-bridge adapter, print only
  what happened.
- S3-F2 (MED). DMA success-lie + HHDM blindness.
  (a) ``nativeSysDmaBounceCopy`` returns success length when
  ``dma_bounce_fn`` is NULL (copied nothing). Unreachable today
  only because auth is unset — fail closed: return -1 when no
  handler is installed. (b) ``executeDmaBounceCopy`` uses
  ``@ptrFromInt(phys_start)`` raw, but the kernel is HHDM-only
  (no identity map anywhere in tree): first live use touches the
  wrong memory. Translate via ``vmm.hhdm_base``.
- S3-F5 (HIGH). Live catalog/CAS write path inert: ``setStorageContext``
  is NEVER called at boot (pre-existing since baseline f252569,
  all stages). ``ush`` holds storage READ but not WRITE, so live
  ``sys_cas_put`` -> "", ``sys_catalog_write`` -> "",
  ``:show catalog`` empty, ``:undo`` genesis-no-op. Proved in
  checker's boot: "[ush] Synthesized and cached to CAS: " with
  EMPTY hash, empty catalog, no-op undo. Fix (architect-authorized,
  explicit grant not ambient): (1) genesis grants ush
  ``storage_device`` WRITE at spawn — cite the line; (2) boot calls
  ``setStorageContext(casPutBridge, casGetBridge,
  abi.checkCallerAuthority)`` after CAS init (signatures verified
  compatible); (3) ``ush.mx`` prints an honest "cache unavailable"
  branch when the CAS hash comes back empty. Then paste a LIVE
  transcript: ``:run novel`` -> ``:show`` lists it -> ``:undo`` ->
  ``:show`` empty.
- S3-F6 (LOW). ``ProbeTranscriptEntry.timestamp_cycles`` stores
  ``entry_count`` (sequence), not cycles. Forensic transcripts must
  not mislabel: source RDTSC or rename the field ``sequence_no``.

Hallucinations (Lazy Code, Invented Proofs)
--------------------------------------------

- S3-F4 (HIGH). ``docs/project/success-cases.rst`` §6 proofs are
  partly fabricated: (a) SC-GADGET "QEMU boot telemetry" block
  (``[probe_ladder] STG_0...`` lines) matches NOTHING in code or
  in any log — no code prints that prefix; the "sealed" hash
  ``e3b0c442...`` is the SHA-256-of-empty constant, not a BLAKE3
  seal. (b) SC-WEB cites two phantom tests (no "tcp server stream
  binding and HTTP request serving", no "SYN cookie flood
  containment under load" exist); acceptance demands HTTP 200
  + rate limiting, but NO http serve test exists and NO rate
  limiting exists anywhere in the net stack. (c) SC-APP cites a
  phantom dispatcher test ("demand-miss synthesis and CAS
  indexing" — dispatcher has only 2 other tests). (d) Test-name
  prefixes wrong throughout (actual: ``D1:``/``G6:``/``workspace:``
  /``tcp ...``/``live-synth: ...`` — verify each by grep).
  (e) SC-CASCADE cites phantom ``MAX_CAPS_PER_CSPACE`` (code has
  ``DEFAULT_CSPACE_CAPACITY = 256``) and defers to "Milestone 39"
  (already past). (f) SC-UNDO gen-4 transcript matches no pasted
  log. Fix: replace EVERY §6 block with verbatim-pasteable
  reality; SC-WEB acceptance reduced to proven transport (exact
  TCP test names) + named backlog item LIVE-SERVE for
  synthesized-httpd-serves-bytes; SC-GUI states the desk
  demand-synthesis regression status honestly (re-prove live via
  ``:run desk`` or mark STALE with cause).

Documentation Drift
--------------------

- S3-F3 (LOW). ``driver-synthesis.rst:62`` values the triad
  ``irq_endpoint`` at (0x0006) — code says 0x0003 (0x0006 is
  ``network_device``). The report's "(0x0004)" is a third value
  (``framebuffer``). One truth: 0x0003. Fix spec + report numbers
  (ST8).

Observations (Not Findings)
-----------------------------

- O1. ``CSpace.init`` takes unclamped capacity while the revoke
  worklist is 256 entries; capacity > 256 would silently truncate
  the cascade (``get()`` lineage still fail-closes; all live
  CSpaces are <= 64). Recommend a clamp or static assert.
- O2. ``uOS 0.15.0`` ASCII string in ``lib/macros/init.mx:5``
  (pre-existing, Stages 1-2; not Stage-3 scope). Cosmetic; queue
  for Stage 4 or human review.
- O3. Descendant unmap failure inside ``revoke()`` is swallowed
  for non-root targets (slot lingers valid); covered by lazy
  lineage kill in ``get()``. Defensible; noted.
- Boot note: ``:exit`` prints "Exiting µShell." and returns to the
  prompt; runner timeout-kill remains the normal harness end
  (matches Stage-2 behavior; pre-existing).

Verdict
-------

**FAIL: REQUIRES REMEDIATION** — S3-F1..S3-F6 only. Ladder
mechanics, cascade, undo core, tombstones, gates, and ST4/ST5/ST6
stand verified and are NOT to be reworked. Re-audit is scoped to
the six findings plus a full gate re-run and a fresh checker TCG
boot proving live catalog write + live undo rollback.

Re-Audit Round 2 (Remediation Verified + Two Stragglers)
---------------------------------------------------------

- S3-F1 VERIFIED FIXED: boot reordered (CAS -> genesis -> network
  with real ``genesis.cspace``); ``advanceToOperational(rx_ring,
  dma_size)`` with real PMM ring address genuinely mints the triad;
  ``probeCasPutBridge`` assigned and commits transcripts to CAS;
  serial claims now true. Checker's boot confirms cas-before-probe
  order. (Report prose cited phantom 3-arg call/STG5 consts — code
  is 2-arg and correct; prose/reality gap logged as ST8 warning.)
- S3-F2 VERIFIED FIXED: null-handler returns -1 + case-4 test
  asserts it; HHDM translation via ``vmm.hhdm_base`` with
  double-translation guard.
- S3-F3 VERIFIED FIXED: spec says ``irq_endpoint`` 0x0003.
- S3-F5 VERIFIED FIXED + PROVEN LIVE: explicit genesis WRITE grant
  to ush (``insertCap`` line, AI actors stay READ-only);
  ``setStorageContext`` wired at boot; honest empty-cache branch
  in ``ush.mx``. Checker's TCG boot: ``:run novel_app`` cached
  ``16d96153...``, ``:show`` listed it, ``:undo`` restored gen 3,
  ``:show`` empty — 0 faults. (Report prose cited a
  non-compiling 3-arg ``mintSubToken`` paste — code uses
  ``insertCap`` and is correct; ST8 warning.)
- S3-F6 VERIFIED FIXED: ``io.rdtsc()`` live, explicit sequence in
  test.
- VMM extra ACCEPTED: huge-page traversal guards are strict
  safety (our mapper never creates huge pages); unmapExtent
  rework + colocated test predate Stage 3 (Stage-1 journal);
  net-positive, no finding.
- Gates re-run by checker: 487/487, lint/fmt/trace green.
  Test-count arithmetic reconciled (remediation added zero
  net-new blocks; ST2 holds).
- S3-F4 PARTIAL — two stragglers remain:
  (b1) SC-UNDO transcript edited, not verbatim: doc shows a
  64-char catalog hash but ``formatListGen`` prints 16 chars, and
  the ``[aid] DNS/Mock`` lines are dropped. Checker's live boot
  produced the ground truth (same 16d96153 hash + same gen-3
  JSON): replace the block with the exact paste.
  (b2) SC-GUI §3.6 history false: ``desk.mx`` existed at baseline
  f252569 and was excised in Sovereign Stage 1, NOT "retired in
  Milestone 26"; "Phase 6 roadmap item" misframes a COMPLETE
  phase. Correct both to Stage/backlog language.

Verdict (Round 2)
------------------

**FAIL: REQUIRES REMEDIATION** — S3-F4(b1)+(b2) only (mechanical
doc transcription). Everything else in Stage 3 stands verified
across two rounds, including live catalog write + live undo
rollback in the checker's own TCG boot.

Re-Audit Round 3 (Final)
--------------------------

- S3-F4(b1) VERIFIED FIXED: transcript matches the checker's live
  boot byte-for-byte (aid lines present, 16-char hash, gen-3 JSON).
- S3-F4(b2) VERIFIED FIXED: desk history corrected (f252569
  baseline, Stage-1 excision, post-Stage-3 backlog).
- Gates re-run by checker: 487/487, lint 2x, fmt, trace green.
- S3-F7 (PROCESS, non-blocking): Round-2 report §2 "verbatim
  extracts" 3-6 match nothing in the tree (wrong lines, invented
  identifiers ``virt_phys_start``/``IRQ_WAIT``). Third prose/reality
  instance after the STG5/mintSubToken pastes. Tree unaffected —
  all cited CODE was verified correct independently. Mandate:
  Stage-4 reports must cite via machine-pasteable ``sed -n``
  ranges; any citation failing grep is auto-rejected.
- Micro-nit carried: ``success-cases.rst:209`` says "Cozy
  Sovereign Stage 1" — purge residual "Cozy" in the Stage-4 pass.
- O4/O5 carried to Stage 4: triad ``dma_buffer`` covers rx_ring
  only (tx/rx-buf un-capped); probe transcripts committed to CAS
  but unindexed (no seal hex printed, no catalog tag).

Verdict (Final)
---------------

**PASS: ZERO DEFECTS** — Stage 3 accepted. Orders file deleted
by checker per protocol. Tree remains frozen uncommitted.
