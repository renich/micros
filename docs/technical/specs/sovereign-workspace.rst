===================================================
Sovereign Workspace & Canvas Substrate Spec
===================================================

:Document ID: SPEC-TECH-WORKSPACE-001
:Status: Approved
:Traced Stories: [US-REN-001], [US-REN-006], [US-GEM-001], [US-GEM-006], [US-GEM-010]
:Parent Architecture: `SPEC-TECH-COMPOSITOR-001`, `SPEC-TECH-FS-001`
:Module Targets: ``src/kernel/compositor/window_abi.zig``, ``src/kernel/storage/catalog_abi.zig``, ``lib/macros/init.mx``

1. Architectural Axioms & Purpose
=================================
This specification defines the Sovereign Workspace for MicrOS (µOS), replacing traditional desktop windowing hierarchies and heavyweight GUI toolkits with a reactive, hypermedia-driven canvas and content-addressed artifact stream.

1.1 Sovereign Canvas (Layer 4)
------------------------------
Traditional graphical operating systems introduce massive layers of abstraction (X11/Wayland servers, widget libraries, scene graphs) that consume gigabytes of memory and introduce endless CVEs. MicrOS adopts the Sovereign Canvas model:

* **Single Cohesive Surface**: The display is governed by a lightweight compositor managing bounded rectangular extents (windows/canvases) assigned to isolated actors.
* **Dirty-Rect Updates**: Actors mutate their visual surface in shared or private buffers and invoke ``sys_window_commit(cap)`` with dirty rectangle coordinates, achieving 60 FPS update rates with zero kernel allocation.
* **Reactive Hypermedia Stream**: Visual interfaces are expressed as declarative hypermedia components that react to binary event streams (keystrokes, pointer events, IPC notifications).
* **Artifact-Centric Workflow**: Files and documents are not organized in arbitrary hierarchical filesystem trees, but as an append-only stream of content-addressed artifacts tracked by human-readable catalog tags and Merkle generation counters.

1.2 Telemetry & Capability Trust Visibility
-------------------------------------------
Rather than burying permissions in obscure system dialogs, the workspace provides immediate, visual trust visibility:
* Active actors, CPU load, and gas budgets are rendered directly on the inspector canvas via ``:show`` and ``:ps``.
* Capability allocations are continuously auditable; granting or attenuating rights updates the reactive canvas state deterministically.

2. Reactive Component Protocol
==============================

2.1 Binary Event Ingestion
--------------------------
Canvas components ingest events via the unified ``sys_event_poll(cap, buf, max, timeout_ns)`` primitive:
* Keyboard scancodes and ASCII translations.
* Pointer motion, button presses, and scroll increments.
* Inter-actor notifications and data ready signals.

2.2 Declarative Layout & Rendering
----------------------------------
Components render directly into their granted pixel surface:
* **Glyph Caching**: Vector glyphs are rasterized into pre-allocated memory caches with compile-time bounded fonts.
* **Sub-Millisecond Invalidation**: Changes to component state mark bounding rectangles dirty, which are composited atomically during the vertical refresh cycle.

3. Artifact Stream & Workspace Catalog
======================================
The workspace couples UI components directly to the Content-Addressed Storage (CAS) catalog:
* Every artifact (document, code snippet, synthesized tool) is identified by its 256-bit BLAKE3 hash.
* Catalog tags (``home.notes``, ``app.viewer``) map semantic identifiers to active hashes.
* Optimistic Concurrency Control (OCC) snapshots allow instant generational undo (``:undo``) across all workspace modifications.

3.1 Bounded Snapshot Ring & Forward Undo
----------------------------------------
* **16-Generation Ring**: Storage substrate maintains an in-memory and CAS-pinned ring of the last 16 generation roots (``MAX_SNAPSHOT_GENERATIONS = 16``).
* **Forward Monotonic Commit**: Invoking ``:undo`` restores the previous consistent generation manifest $M_{G-1}$ into a new generation $G+1$, updating generation counters forward as an append-only commit without history rewrites.
* **Tombstone Records**: Deletions mark records with ``WorkspaceEntryFlags.DELETED`` rather than physically compacting tables, preserving recovery capability across the ring window.
* **C6 Generational Querying**: Shell and catalog APIs accept generational pins (``<tag>@<gen>`` and ``catalog@<gen>``). Evicted generation requests emit honest diagnostic messages with ring bounds and oldest live generation.

4. Verification & Traceability Matrix
=====================================
* ``[US-REN-001]``: Interactive typed shell and workspace canvas automation.
* ``[US-REN-006]``: Capability-bounded window and storage supervision.
* ``[US-GEM-001]``: Structured binary telemetry rendering on canvas.
* ``[US-GEM-006]``: Sub-millisecond framebuffer visual auditing and dirty-rect validation.
* ``[US-GEM-010]``: Context-window-optimized module boundaries (<= 1,000 lines, functions <= 40 lines).
