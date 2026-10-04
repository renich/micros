=====================================================
Microkernel Tier Boundary Enforcement & Baseline Lock
=====================================================

:Document ID: SPEC-TECH-ARCH-001
:Status: Approved
:Traced Stories: [US-GEM-010], [US-REN-004], [US-REN-006]

1. Scope & Enforcement Point
============================
This specification defines the architectural tier boundary that MicrOS enforces
statically over ``@import`` edges, the disclosure contract for every exemption
the gate grants, and the edge baseline that makes architectural growth an
explicit, reviewable event.

The enforcement point is ``tools/src/arch_gate.zig``, exposed as
``tools/micros-arch-gate`` and executed by ``make arch-gate`` as part of
``make check``. It is the only mechanism that may reject a tier-crossing import;
no other tool, linter rule, or review convention carries that authority.

2. Tier Model & Boundary Rules
==============================
The codebase is partitioned into three strictly segregated tiers:

* **Tier 1**: Userland daemons and actors (``src/userland/``).
* **Tier 2**: Language runtime and bytecode VM substrate (``src/macros/``).
* **Tier 3**: Freestanding microkernel substrate (``src/kernel/``).

2.1 Rule 1: Downstream Isolation
--------------------------------
``src/kernel/`` must not import concrete implementation types from
``src/userland/``. Kernel code reaches daemons only through the typed ABI
bridges registered in ``src/kernel/abi.zig`` and ``src/kernel/ai/ai_abi.zig``.

2.2 Rule 2: Upstream Isolation
------------------------------
``src/userland/`` must reach the substrate **only** through the public
capability surface:

* ``src/kernel/cap/capability.zig`` (unforgeable capability tokens, SPEC-TECH-CAP-001)
* ``src/kernel/ipc/ring.zig`` (typed zero-copy IPC rings)
* ``src/kernel/boot_info.zig`` (boot handoff parameters)

Any other kernel target is a violation unless it appears in the exemption
inventory of Section 4. This is deliberately an allow-list: a deny-list of
specific internal modules cannot express the invariant and silently admits
every kernel module the list does not name.

2.3 Rule 3: Mediated Intermediary
---------------------------------
Cross-boundary communication must occur through typed ABI registrations gated by
caller-authority checks, or through shared zero-copy IPC rings. Rule 3 is a
construction rule rather than an import-shape rule: import topology cannot prove
that a call is capability-mediated. It is therefore **outside the static
coverage of this gate** and is verified by specification review plus the
capability ABI tests (SPEC-TECH-CAP-001). The gate must never be described as
verifying Rule 3.

2.4 Rule 4: No Circular Substrate Bleed
---------------------------------------
``src/macros/`` is an isolated bytecode VM and must never import hardware driver
registers (``src/kernel/drivers/``) or architecture state (``src/kernel/arch/``).

3. Enforcement Mechanics & Disclosure
=====================================
3.1 Scan
--------
1. The scan root (default ``src/``) is walked recursively; every ``.zig`` file is inspected.
2. Each line is scanned for ``@import("<target>")``. A line whose first non-whitespace characters are ``//`` is a comment and contributes no edge.
3. Every edge is classified as ``permitted``, ``exempt``, or ``violation``.

3.2 Disclosure Contract
-----------------------
Silence is not an acceptable outcome for an exempted edge. On every run, pass or
fail, the gate prints:

* the number of imports scanned,
* the number of exemptions granted, in the ``Gate Clear`` line itself.

A run that reports ``0 violations`` while granting exemptions must still state
how many edges were exempted. Exemptions are counted per edge, so a daemon-wide
catch-all exemption can never hide behind an aggregate number.

4. Grandfathered Exemptions
===========================
4.1 Policy
----------
1. Exemptions are enumerated **per edge**, never per daemon or per directory. Adding a previously unseen import by an already-exempted daemon fails the gate.
2. Each exemption group carries the excision plan (Milestone 42 Ring-3 activation, ``docs/project/roadmaps/m42-ring3-activation.rst``) beside it in code.
3. Introducing an exemption requires editing ``tools/src/arch_gate.zig``, so it always appears in a reviewable diff. There is no data-driven or pattern-based catch-all clause.
4. Exemptions are disclosed at runtime per Section 3.2 and asserted by colocated tests.

4.2 Current Inventory
---------------------
As of this revision the gate grants 24 exemptions while scanning 827 imports:

* **9 kernel-side (Rule 1)**: boot-time fiber instantiation of ``netd``, ``aid``, ``gopd``, ``storaged``, ``p2pd`` from ``src/kernel/main.zig``; ABI bridges from ``src/kernel/abi.zig`` and ``src/kernel/ai/ai_abi.zig``.
* **15 userland-side (Rule 2)**: legacy daemon access to kernel internals scheduled for M42 excision, enumerated per daemon in ``isUserlandSideExemption``.

``src/userland/pkgd/package.zig`` is intentionally **not** exempt: reaching it
from the kernel remains a hard violation. This is the pilot subsystem that
proves the decoupling pattern (DELIB-STAGE4-DECOUPLE-001).

5. Edge Baseline Lock
=====================
5.1 Recorded Edge Set
---------------------
``docs/project/deliberations/stage4/import-baseline.txt`` records the reviewed
set of architectural edges (imports whose target names ``kernel`` or
``userland``). The file holds 98 unique edges.

5.2 Comparison Semantics
------------------------
1. Edges are compared on normalized ``importer -> target`` identity. Line numbers are excluded so unrelated edits never invalidate the baseline.
2. An edge present in the scan but absent from the baseline fails the gate (``[NEW] edge absent from baseline``).
3. An edge present in the baseline but absent from the scan is reported as ``removed`` and does not fail: excising a dependency is always allowed.

5.3 Regeneration
----------------
Regenerate only as a deliberate act in the same change that introduces the edge::

   ./tools/micros-arch-gate src/ --dump-baseline docs/project/deliberations/stage4/import-baseline.txt

The dump is deduplicated by edge identity. Regenerating without review defeats
the lock, which is the reason the lock exists.

6. Verification & Tests
=======================
1. **Colocated unit tests** (``tools/src/arch_gate.zig``, executed by ``make -C tools test``): comment-line exclusion, edge filtering, Rule 1 classification including the non-exempt ``pkgd`` edge, Rule 2 allow-list behaviour, per-edge (not per-daemon) exemption scoping, baseline key normalization, and baseline deduplication.
2. **Fixture discipline**: temp trees prove the lock rejects unrecorded edges (exit 1) and accepts recorded ones (exit 0), independently of the rule engine.
3. **Gate execution**: ``make arch-gate`` runs the scan with ``--baseline`` and is a dependency of ``make check``.
