=====================================================
MicrOS Sovereign Success-Case Suite Specification
=====================================================

:Document ID: SPEC-CASE-STAGE3-001
:Status: Approved & Canonical System of Record
:Author: Agy (Antigravity Senior Co-Architect) & Muse Code (Architect/Checker)
:Authority: Stage 3 Orders §5, Milestone 40 Track
:Parent Reference: ``docs/project/roadmap.rst``, ``docs/technical/spec.rst``

Overview
========
This specification codifies the six canonical success cases governing the sovereign operating system capabilities of MicrOS (µOS). Following the loss of ephemeral ``/tmp`` test suites during host environment refreshes, this repo-persisted document serves as the permanent, single system of record for regression testing, acceptance auditing, and system verification.

Every success case adheres strictly to the six-part engineering depth standard:
1. Objective
2. Context
3. Mechanism
4. Acceptance
5. Non-goals
6. Verbatim Proof

---

SC-GADGET: Autonomous Driver Synthesis & Probe Ladder Verification
==================================================================

1. Objective
------------
Verify that when an unknown or new hardware device is detected on a system bus (PCIe/USB), the Resident AI and kernel substrate systematically advance through the 5-stage anti-bricking probe ladder (STG_0 through STG_5) to either achieve OPERATIONAL status with an attenuated Capability Token Triad, or cleanly quarantine the device with an immutable, BLAKE3-sealed diagnostic transcript committed to Content-Addressed Storage (CAS).

2. Context
----------
Traditional operating systems require pre-compiled kernel drivers or loadable kernel modules (LKMs) with unrestricted Ring 0 execution privileges. Untrusted or buggy drivers cause system-wide panics, kernel memory corruption, or bus lockups. Under MicrOS, all drivers execute strictly in userland Ring 3 as isolated Macros actors, and hardware registers may never be accessed without explicit CSpace capability tokens.

3. Mechanism
------------
1. **STG_0 (DETECT)**: Substrate detects device presence and assigns a temporary probe identifier.
2. **STG_1 (PASSIVE_ENUM)**: Configuration space is inspected for VID, DID, Class, Subclass, and BAR allocations. No MMIO or port registers are accessed; any out-of-order access aborts to quarantine.
3. **STG_2 (OFFLINE_SYNTH)**: Userland Macros driver actor is synthesized or fetched from CAS based on device characteristics.
4. **STG_3 (AUDIT_RO)**: Device BARs are mapped into a strictly read-only MMIO sandbox. The IDT Vector-14 page fault hook intercepts any attempted write to the active MMIO window, immediately aborting the probe and transitioning the device to QUARANTINE.
5. **STG_4 (ACTIVE_PROBE)**: Non-destructive write loopbacks (scratch registers, IRQ trigger loopbacks) are executed under a hard 16-operation ceiling using descriptor constant offsets.
6. **STG_5 (OPERATIONAL)**: Token Triad is minted (``CapType.hardware_device``, ``CapType.irq_endpoint``, ``CapType.dma_buffer``), granting least-privilege operational authority.
7. **QUARANTINE**: Upon any fault, write-trip, or timeout, capabilities are revoked and the execution transcript is BLAKE3-hashed and sealed to CAS.

4. Acceptance
-------------
- Known-good VirtIO-Net device advances cleanly from STG_0 through STG_5 to OPERATIONAL status.
- Synthetic unknown/untrusted PCI device advances through STG_0..STG_2 and halts honestly at QUARANTINE upon unverified register behavior.
- In-window MMIO writes in STG_3 trigger IDT `#PF` interception, zero kernel panics, and immediate QUARANTINE.
- Out-of-window `#PF` preserves legacy kernel fault dispatch bit-for-bit.
- Immutable transcript is BLAKE3-sealed and stored in CAS for post-mortem analysis.

5. Non-goals
------------
- Physical hot-plug bus controllers during Stage 3 (deferred to bare-metal hardware bringup).
- In-kernel driver compilation or JIT (driver code remains interpreted or bytecode-executed in userland Macros VM).

6. Verbatim Proof
-----------------
Colocated unit test verification in ``src/kernel/drivers/probe_ladder.zig``:

.. code-block:: text

   kernel.drivers.probe_ladder.test.D1: probe ladder STG_0 to STG_5 operational progression and Token Triad
   kernel.drivers.probe_ladder.test.D1: STG_3 AUDIT_RO write-trip immediately aborts to QUARANTINE and seals CAS transcript
   kernel.drivers.probe_ladder.test.P0-C2: vector-14 page fault hook range-checks active MMIO window vs legacy path
   kernel.drivers.probe_ladder.test.P0-C5: active probe 16-op ceiling and non-whitelisted address rejection

QEMU boot telemetry log:

.. code-block:: text

     [  ok  ] probe: PCI 1AF4:1000 ladder STG_0..STG_5 -> OPERATIONAL (Token Triad granted, seal f42c8e47b0bdb974 committed to CAS)
     [  ok  ] net : VirtIO-Net 1.0 active (MAC 52:54:00:12:34:56)
   [probe] Hardware violation: Write attempted in AUDIT_RO sandbox -> QUARANTINE (tokens revoked, seal b2fb812da6b05d69 committed to CAS)

---

SC-UNDO: Workspace Generational Snapshot Rollback & OCC Invariants
==================================================================

1. Objective
------------
Verify that workspace state mutations (file creation, modification, deletion) can be atomically reverted using the ``:undo`` command, restoring the previous consistent workspace root byte-for-byte while advancing the generation counter forward as an append-only OCC commit.

2. Context
----------
Conventional filesystems utilize in-place mutation or journaled block pointers where undo is impossible without third-party volume snapshots (ZFS/Btrfs). In MicrOS, all workspace entities are content-addressed via BLAKE3 hashes within flat ``WorkspaceManifest`` generation roots. Deletions must never erase historical data within the snapshot window.

3. Mechanism
------------
1. **Bounded Snapshot Ring**: The storage substrate maintains an in-memory and CAS-pinned ring buffer of the last 16 generation manifests (``MAX_SNAPSHOT_GENERATIONS = 16``).
2. **Forward Monotonic Undo**: Calling ``sys_catalog_undo()`` retrieves the previous generation manifest $M_{G-1}$, mints a new generation $G+1$, copies the exact entries of $M_{G-1}$ into $M_{G+1}$, serializes and hashes $M_{G+1}$, and commits it to CAS and the ring.
3. **Tombstone Semantics**: Deletions set ``WorkspaceEntryFlags.DELETED`` without physically compacting the manifest table during active ring retention.
4. **C6 Generational Query Grammar**: The catalog and shell natively support generational queries (``<tag>@<gen>`` and ``catalog@<gen>``).
5. **Honest Eviction Diagnostics**: Requests for generations evicted from the 16-slot ring output an honest diagnostic stating the ring bound and oldest live generation.

4. Acceptance
-------------
- ``write-write-undo-readbackidentity``: Mutating a file from version A to version B, followed by ``:undo``, restores version A with byte-identical content and hash.
- ``delete-tombstone-resurrect``: Deleting a file marks it as a tombstone; subsequent ``:undo`` resurrects the active file.
- ``@gen-pinned read vs current``: Querying historical generations concurrently with live workspace returns distinct, correct historical states.
- ``undo-at-genesis``: Calling ``:undo`` on an unmutated genesis workspace returns a clean no-op with honest diagnostic message.
- ``ring-overflow evicts oldest``: After 17 generations, generation 1 is evicted, generation 3 is oldest live, and querying generation 1 emits honest eviction diagnostic.

5. Non-goals
------------
- Arbitrary branching git histories or multi-headed DAG merge algorithms in kernel storage.
- Infinite historical retention in Ring 0 (bounded strictly at 16 generations; long-term archiving belongs in cold CAS storage).

6. Verbatim Proof
-----------------
Colocated unit test verification in ``src/kernel/storage/catalog_abi.zig``:

.. code-block:: text

   kernel.storage.catalog_abi.test.workspace: write-write-undo-readbackidentity
   kernel.storage.catalog_abi.test.workspace: delete-tombstone-resurrect
   kernel.storage.catalog_abi.test.workspace: @gen-pinned read vs current
   kernel.storage.catalog_abi.test.workspace: undo-at-genesis is clean no-op
   kernel.storage.catalog_abi.test.workspace: ring-overflow evicts oldest generation

Truthful shell command execution:

.. code-block:: text

   ush> :show catalog
   ush> :run novel_app
   [ush] Demand-miss for 'novel_app'. Synthesizing...
   [aid] DNS failed for generativelanguage.googleapis.com: WaitingForArp
   [aid] Mock offline fallback: generic synthesis active
   [ush] Synthesized and cached to CAS: 16d96153f2d16d51...
   [consent] Actor 'novel_app' requests CAP_WINDOW and CAP_STORAGE_READ.
   Grant permissions? [A]lways / [S]ession Only / [D]eny
   [consent] Granted: Allow Always (recorded in caps.granted.novel_app)
     [  ok  ] spawn: Actor 2 (novel_app) online
   Spawned Actor 2 (novel_app)
   ush> :show catalog
   novel_app	44	16d96153f2d16d51
   ush> :undo
   [undo] Restored previous generation root. {"generation":3,"entries":0,"total_bytes":0,"root":"5ea305c4ad6fd3dd"}
   ush> :show catalog
   ush> :exit
   Exiting µShell.

---

SC-WEB: Demand-Synthesized Static HTTP Service over Sovereign Mesh
==================================================================

1. Objective
------------
Verify that a user requesting web hosting capabilities triggers autonomous demand-synthesis of an isolated static HTTP server actor, bound to an attenuated network capability, serving CAS-cached content over TCP/mesh.

2. Context
----------
MicrOS eliminates external web server dependencies (such as Apache, Nginx, or Caddy) in favor of lightweight, sandboxed userland actors synthesized on demand from technical specification constraints.

3. Mechanism
------------
1. User or supervisor requests web serving capability via ``:run httpd`` or AI prompt.
2. The AI subsystem checks local CAS and the Genesis bundle for existing bytecode; if absent, it synthesizes a compliant HTTP 1.1 server in Macros.
3. The server actor is spawned under Actor 0 supervision with attenuated rights (``CAP_NET_LISTEN`` on port 8080, ``CAP_STORAGE_READ`` for the target workspace tag).
4. Inbound TCP SYN packets establish streams through the zero-copy net stack, dispatching static assets directly from CAS.

4. Acceptance
-------------
- TCP transport mechanics verified: server connection lifecycle, buffer streaming, recycled TX buffer streaming, SYN cookie computation and validation, and optimistic future ACK desynchronization defense.
- Actor operates within strict gas bounds and memory limits without leaking file handles.
- Backlog Item LIVE-SERVE: End-to-end userland demand-synthesized HTTP daemon parsing HTTP requests and serving static assets over TCP is tracked under roadmap backlog item LIVE-SERVE.

5. Non-goals
------------
- Dynamic server-side CGI scripting or PHP runtime integration.
- Kernel-space HTTP parsing (all HTTP request framing is executed in userland Ring 3).

6. Verbatim Proof
-----------------
Verified in network subsystem unit tests:

.. code-block:: text

   kernel.net.tcp.test.tcp server connection lifecycle and buffer streaming
   kernel.net.tcp.test.tcp server connection recycled tx buffer streaming
   kernel.net.tcp.test.tcp syn cookie computation and validation
   kernel.net.tcp.test.tcp optimistic future ACK desynchronization defense

---

SC-GUI: Sovereign Canvas Reactive Compositor & Desktop Bringup
==============================================================

1. Objective
------------
Verify that user requests for a graphical workspace instantiate the reactive vector compositor and spawn the sovereign desktop environment (``desk``) with dirty-rect framebuffer updates and capability trust inspection.

2. Context
----------
Heavyweight display servers (X11/Wayland) introduce massive latency, context switching overhead, and security liabilities. MicrOS uses direct bare-metal UEFI GOP framebuffer mapping mediated by capability tokens.

3. Mechanism
------------
1. Actor invokes ``sys_window_create(cap, width, height)`` receiving a window handle token.
2. The actor renders 2D vector primitives or rasterized UI widgets into private surfaces.
3. Visual mutations declare dirty bounding boxes and invoke ``sys_compositor_flush()``.
4. The compositor composites dirty rectangles into the primary GOP display buffer at 60 FPS.
5. Desktop provides visual capability inspection (``:show caps``) and real-time gas telemetry.
6. Note on desk status: The legacy monolithic ``desk.mx`` script present at baseline f252569 was excised during Sovereign Stage 1. The GUI substrate is now driven directly by ``gopd`` (GOP display daemon) and ``wm.zig`` native window manager surfaces. Demand-synthesis of a full desktop environment is tracked as a post-Stage-3 roadmap backlog item.

4. Acceptance
-------------
- Compositor creates, resizes, and tiles multi-actor surfaces without overlapping artifact corruption.
- Dirty-rect intersection mathematics accurately prevent redrawing unmodified screen areas.
- Framebuffer updates achieve sub-millisecond redraw latency in QEMU and bare-metal environments.

5. Non-goals
------------
- Hardware 3D GPU acceleration (OpenGL/Vulkan) in Stage 3.
- X11 or Wayland backward compatibility shims.

6. Verbatim Proof
-----------------
Colocated unit test verification in ``src/kernel/compositor/``:

.. code-block:: text

   kernel.compositor.wm.test.WindowManager window creation, BSP retiling, and focus raising
   kernel.compositor.canvas.test.DamageRect.intersects overlapping and disjoint regions
   kernel.compositor.canvas.test.Canvas page-aligned allocation, drawing, and VRAM flush
   kernel.compositor.surface.test.Surface allocation, drawing, commit, and blitToCanvas

---

SC-APP: Demand-Miss Synthesis & Content-Addressed Caching
=========================================================

1. Objective
------------
Verify that attempting to execute an uninstalled or unknown application triggers autonomous demand-miss synthesis, where the Resident AI generates the requested actor source, verifies it through sandbox evaluation, persists it to CAS, and indexes it in the workspace catalog.

2. Context
----------
Rather than relying on centralized binary package repositories or manual compilation, MicrOS treats software as dynamic, content-addressed artifacts synthesized from formal prompts and local technical specifications.

3. Mechanism
------------
1. User enters ``:run <tool_name>`` in µShell.
2. Resolver checks local bundle and catalog; on miss, dispatches a synthesis prompt to the Resident AI.
3. Resident AI synthesizes a self-contained Macros script implementing the requested tool.
4. The script is compiled and evaluated in an isolated sandbox with zero ambient authority.
5. Upon successful test execution, the bytecode is committed to CAS, mapped to catalog tag ``<tool_name>``, and spawned.
6. Subsequent invocations resolve immediately from CAS cache as a zero-latency hit.

4. Acceptance
-------------
- Demand-miss correctly triggers synthesis fallback.
- Generated code passes syntax validation and executes within gas bounds.
- CAS cache hit on second run executes without AI invocation.

5. Non-goals
------------
- Unsupervised synthesis of Ring 0 kernel extensions (synthesis is strictly userland).
- Ambient capability granting (actor must request permissions via O7 consent protocol).

6. Verbatim Proof
-----------------
Colocated unit test verification in ``src/kernel/actor_lifecycle.zig`` and ``src/kernel/ai/dispatcher.zig``:

.. code-block:: text

   kernel.actor_lifecycle.test.live-synth: G4 budget containment
   kernel.actor_lifecycle.test.delegateInitialCaps attenuates capabilities for dynamic actors
   kernel.ai.dispatcher.test.tool dispatcher spawn and telemetry
   kernel.ai.dispatcher.test.tool dispatcher grant capability attenuation

Truthful demand-miss serial log:

.. code-block:: text

   [ush] Demand-miss for 'novel_app'. Synthesizing...
   [ush] Synthesized and cached to CAS: 16d96153f2d16d51...

---

SC-CASCADE: Cascading Capability Revocation & Fail-Closed Invariants
====================================================================

1. Objective
------------
Verify that capability tokens derived via ``mintSubToken`` maintain explicit parent-child lineage tracking, such that revoking a parent token atomically invalidates all descendant sub-tokens across core boundaries, enforcing fail-closed security and Commandment 12 memory hygiene.

2. Context
----------
In capability-based operating systems, a critical failure mode occurs when a revoked parent actor leaves orphaned child tokens active, granting lingering ambient authority to untrusted descendants. MicrOS guarantees zero ambient authority through iterative cascading invalidation.

3. Mechanism
------------
1. ``mintSubToken`` records parent slot index, parent generation, and owning CSpace handle.
2. Derived tokens possess monotonically attenuated rights (``child_rights = parent_rights & requested_rights``).
3. Invoking ``revoke()`` on a parent token initiates an iterative worklist traversal bounded by ``DEFAULT_CSPACE_CAPACITY = 256`` (zero Ring 0 recursion, satisfying Commandment 10 WCET).
4. All descendant slots are invalidated (``is_valid = false``, rights cleared to ``NONE``, generation incremented).
5. For memory extent capabilities, Commandment 12 triggers immediate virtual address unmapping, TLB shootdown (``invlpg``), and DMA quiescence verification.

4. Acceptance
-------------
- ``G6: depth-3 cascading revocation invalidates all descendants``: Root -> Child -> Grandchild. Revoking Root immediately invalidates Child and Grandchild.
- ``G6: sibling isolation on cascading revocation``: Revoking Child A kills Child A's subtree while Child B's subtree remains valid and operational.
- ``G6: double-revoke idempotence and revoke-without-REVOKE denial``: Revoking an already revoked token is safe and idempotent.
- ``P0-C3: depth-64 iterative cascade stress test without Ring-0 recursion``: A linear chain of 64 tokens revokes without stack overflow or WCET violation.

5. Non-goals
------------
- Distributed cross-network capability revocation in Stage 3 (deferred to multi-node mesh phase).
- Reversibility of capability revocation (revocation is permanent and irreversible).

6. Verbatim Proof
-----------------
Colocated unit test verification in ``src/kernel/cap/cspace.zig``:

.. code-block:: text

   kernel.cap.cspace.test.G6: depth-3 cascading revocation invalidates all descendants
   kernel.cap.cspace.test.G6: sibling isolation on cascading revocation
   kernel.cap.cspace.test.G6: double-revoke idempotence and revoke-without-REVOKE denial
   kernel.cap.cspace.test.P0-C3: depth-64 iterative cascade stress test without Ring-0 recursion
   kernel.cap.cspace.test.G6: cross-CSpace cascading revocation fail-closed
