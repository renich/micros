============================================================
Sovereign Desktop Environment (SPEC-TECH-DESK-001)
============================================================

:Document ID: SPEC-TECH-DESK-001
:Status: Approved
:Traced Stories: [US-REN-001], [US-REN-002], [US-REN-005], [US-GEM-001], [US-GEM-006]

1. Architectural Axioms & Purpose
=================================
This specification formalizes the **Sovereign Desktop Environment** (``desk.mx``) for MicrOS (µOS). Engineered in pure Macros language, ``desk.mx`` serves as the sovereign graphical human-machine interface, eliminating gigabyte desktop stacks (X11, Wayland compositors, Qt, GTK, Electron) while delivering an elegant, multi-window glass workspace with real-time telemetry, task management, and native resident AI studio integration.

1.1 Substrate Integration & Zero-Bloat Execution
------------------------------------------------
The desktop environment executes as a standalone actor operating over the microkernel windowing and compositor ABI:
* **Freestanding Window Compositor**: Communicates with the kernel compositor via ``sys_window_create``, ``sys_window_close``, ``sys_window_focus``, ``sys_window_draw_rect``, ``sys_window_draw_string``, and ``sys_compositor_flush``.
* **PS/2 Mouse & Pointer Integration**: Tracks pointer movement and click events via ``sys_pointer_read`` and packed hardware coordinate streams.
* **Pure Macros Logic**: Entire desktop workspace layout, task switching, and window management execute in the self-hosting Macros VM, requiring zero native shared libraries or external runtimes.

2. Glass Desktop Workspace Architecture
=======================================

2.1 Desktop Top Bar (Glass Status Telemetry)
--------------------------------------------
A fixed 24-pixel top bar spanning the full display (1280x24) rendered in dark charcoal (``0x0D1117``) with hairline graphite border (``0x22272E``):
* **Brand & Kernel Badge**: Displaying ``MicrOS (uOS) Sovereign Desktop``.
* **Task Switcher Buttons**: Interactive tabs for active windows: ``[1: Terminal]``, ``[2: AI Studio]``, ``[3: Files]``, ``[4: Telemetry]``.
* **Live Telemetry Indicators**: Active actor count, contained fault count, system tick clock, and active keyboard layout (``ES`` / ``US``).

2.2 Core Graphical Workspaces & Applications
--------------------------------------------
``desk.mx`` manages four primary application surfaces tiled and floating across the 1280x776 desktop area:

1. **Terminal Emulator Window (ush)**:
   A high-speed stream-oriented terminal running the µShell CLI for executing builds, scripts, and system maintenance.
2. **AI Autonomous Studio Window (harness)**:
   A dedicated pair-programming studio modeled after sovereign agent environments, offering multi-turn conversations, tool calling inspection, clipboard management, and context auto-compression.
3. **Workspace File Manager (files)**:
   A visual navigator for the sovereign Content-Addressed Storage (CAS) catalog and genesis bundle, showing file sizes, Merkle BLAKE3 hashes, and quick-view actions.
4. **System Load & Fault Monitor (telemetry)**:
   A real-time telemetry dashboard rendering CPU ticks, memory page allocation, actor process states (ready, running, paused, faulted), and recovery events.

3. Window Management & Input Dispatch
=====================================

3.1 Focus & Z-Order Management
------------------------------
* Windows maintain strict Z-order. Clicking inside an active window surface or clicking its corresponding top-bar button brings the window to the foreground and calls ``sys_window_focus(win_id)``.
* Keyboard shortcuts (``F1``..``F4`` or numeric shortcuts) cycle active window focus cooperatively without preemptive context corruption.

3.2 Event Loop & Compositor Synchronization
-------------------------------------------
The desktop event loop periodically yields control (``sys_yield()``) while polling:
1. Mouse pointer coordinates from ``sys_pointer_read()``.
2. Keystrokes from ``sys_kbd_read()`` and ``sys_serial_read()``.
3. Active window damage updates, followed by atomic ``sys_compositor_flush()``.

4. Verification & Traceability Matrix
=====================================

.. list-table::
   :widths: 20 25 55
   :header-rows: 1

   * - Requirement ID
     - Traced Story
     - Verification Method
   * - REQ-DESK-001
     - [US-REN-005]
     - Multi-window layout creation and rendering via ``desk.mx`` in QEMU.
   * - REQ-DESK-002
     - [US-REN-001]
     - Integrated AI studio and interactive CLI window dispatch.
   * - REQ-DESK-003
     - [US-GEM-006]
     - Framebuffer compositor flushing and surface damage bounding.
   * - REQ-DESK-004
     - [US-GEM-001]
     - Real-time telemetry status bar updating with live actor and fault counters.
