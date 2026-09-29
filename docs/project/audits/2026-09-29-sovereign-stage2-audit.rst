======================================
2026-09-29 Sovereign Stage-2 Audit Report
======================================

:Auditor: Muse Code (architect/checker)
:Implementer: Agy (Antigravity CLI, agent-2db564f1)
:Target: Sovereign Stage 2 (M39, trust + sharing) per
  ``/tmp/micros-cozy-stage2-orders.rst``
:Method: Zero-trust forensic audit — gates re-run, TCG boot re-proven
  with interaction, diff read cold, designs checked against code.

Target Scope
------------

Stage 2 implementation: Phase-0 stamped designs (SPKI, live
synthesis), G3 attenuation, TLS SPKI pinning, G7 provenance, mesh
publish/pull + tombstones, O7 consent memory, live synthesis
pipeline, spec sync, ush rename, silly-name purge.

Verified Green (Independently Reproduced)
----------------------------------------

- ``zig build test``: 468/468 (3 + 50 + 59 + 356) — exact match.
- ``make lint``: 0 findings. ``zig fmt``: clean.
  ``micros-spec-trace``: 20/20, 100%.
- Freestanding ``tls_client.zig`` IS the live path
  (``tls_stream.zig`` binds it as ``TlsClientType``); SPKI verifier
  callback fires at ``cert_index == 0`` and fails closed.
- Pin matrix tested: spike + primary + backup + mismatch-abort +
  unpinned-fail-closed + timing-safe-path (7 tests).
- G3/G7/replication/consent APIs present with colocated tests
  (7 + 2 + 5 + 3).
- ush rename complete: ``µShell 0.15.0`` banner, ``ush>`` prompt,
  ``ush`` binary; repo-wide grep shows history files only.
- Silly-name purge complete: grep shows audit files only.
- Charters present in all three shell specs.
- Checker's TCG boot (fresh image): SPKI line (5 pins), demand-miss
  with labeled mock fallback, live O7 consent
  (``Granted: Allow Always``, recorded), ``:show caps``, ``:exit`` —
  0 ``FATAL``/``VEC`` lines.

Findings (Must Fix)
-------------------

- S2-F1. Y1 placement promise unfulfilled: ``extractResponseText``
  and ``extractCodeBlock`` still defined in ``src/kernel/ai/``
  although the stamped design states legacy extractors "will be
  moved to ``src/userland/aid/`` in Phase 6". Move both functions
  (mechanical); update ``ai_abi.zig`` call site. Generic HTTP
  framing (``parseResponseHeaders``, ``decodeChunkedBody``) MAY stay
  in ``src/kernel/net/http.zig`` as transport-framing library code,
  with an exemption note added to the design doc.
- S2-F2. ``tls_client.zig`` (1,673 lines) has no provenance header
  and exceeds the 1,000-line cohesion guideline without recorded
  justification. Add: derivation from Zig std client, what changed
  (pin callback + fail-closed), and the cohesion rationale.
- S2-F3. Roadmap drift: ``milestone-34-package-federation-registry``
  and ``milestone-35-enterprise-bare-metal`` describe futures that
  contradict CUT decisions (no packages, no enterprise bridge).
  Reconcile titles + content with the cut decisions or justify
  retention in writing.

Verdict
-------

**FAIL: REQUIRES REMEDIATION** — S2-F1–F3 only. All other Stage-2
scope stands verified. Re-audit on next report is limited to the
three findings plus a full gate re-run.

Re-Audit Round 2 (Remediation + New Finding)
--------------------------------------------

- S2-F1 VERIFIED FIXED: both extractors defined in
  ``src/userland/aid/aid.zig``; ``ai_abi.zig`` rerouted;
  transport-framing exemption noted in the design doc.
- S2-F2 VERIFIED FIXED: provenance header + cohesion rationale
  present on ``tls_client.zig``.
- S2-F3 VERIFIED FIXED: M34/M35 retitled and reconciled with the
  CUT decisions.
- Gates re-run by checker: 468/468, lint/fmt/trace green.
- S2-F4 (new, HIGH): O7 interactive consent is theater.
  ``lib/macros/ush.mx`` prints the consent prompt and
  unconditionally records Allow Always without reading input; the
  input helper it should use references CUT ``sys_kbd_read``.
  Fix: port ush input to ``sys_event_poll`` (per the Stage-1 merge
  design), wire A/S/D answers, DEFAULT DENY on timeout/invalid/
  empty, remove the dead kbd fallback; prove live in TCG with one
  Allow transcript AND one Deny transcript.
- S2-F5 (carried nit): ``tls_client.zig`` header states the pin
  verifier signature as ``(cert_der, cert_index) bool`` but the
  code is ``(hostname, leaf_cert_der) void``. Correct the header.

Verdict (Round 2)
------------------

**FAIL: REQUIRES REMEDIATION** — S2-F4 (+ one-line S2-F5) only.
Everything else in Stage 2 stands verified across two rounds.

Re-Audit Round 3 (Final)
------------------------

- S2-F4 VERIFIED FIXED: ``read_consent()`` reads real A/S/D input
  via ``poll_char()``/``sys_event_poll``; Allow/Session/Deny +
  timeout/empty/invalid all route correctly with fail-closed
  default; dead ``sys_kbd_read`` fallback excised. Checker's TCG
  boot proves BOTH branches live (Allow→spawned Actor 2;
  Deny→rejected, zero spawn), 0 faults.
- S2-F5 VERIFIED FIXED: header signature matches the implemented
  callback exactly.
- Gates re-run by checker: 468/468, lint/fmt/trace green.

Verdict (Final)
---------------

**PASS: ZERO DEFECTS** — Stage 2 (M39) accepted. Orders file deleted
by checker per protocol.
