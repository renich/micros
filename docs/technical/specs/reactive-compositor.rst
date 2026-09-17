=======================================================
Reactive Vector Compositor & Multi-Actor Windowing Spec
=======================================================

:Document ID: SPEC-TECH-COMPOSITOR-001
:Status: Approved
:Traced Stories: [US-GEM-006], [US-REN-006], [US-REN-001], [US-GEM-001]

1. Architectural Axioms & Purpose
=================================
This specification defines the asynchronous, multi-actor reactive vector compositor and window management substrate for MicrOS (µOS), evolving the bare-metal UEFI GOP framebuffer from a static single-actor split canvas into a high-performance, double-buffered visual workspace.

1.1 Elimination of Monolithic Display Bottlenecks
-------------------------------------------------
Prior to Milestone 16, display rendering in MicrOS operated synchronously: individual actors blitted pixels or text glyphs directly into the physical video RAM (VRAM) mapped via UEFI GOP. While functional for single-actor terminals, direct-to-VRAM writes suffer from fundamental limitations:

* **Tearing & Flicker**: Concurrent writes from multiple actors or rapid updates cause visual tearing across scanlines.
* **Bus Saturation**: Redrawing full 1280x800x32bpp frames over PCIe/MMIO incurs significant bus bandwidth bottlenecks.
* **Spatial Interference**: Without hardware-enforced clipping or compositor arbitration, a rogue or miscalculated actor write can corrupt another actor's visual viewport.

1.2 The Sovereign Compositor Model
----------------------------------
Milestone 16 establishes a decentralized, capability-gated visual architecture:

* **Double-Buffered Backbuffer**: The microkernel maintains a canonical 1280x800x32bpp backbuffer allocated in page-aligned system RAM (``src/kernel/compositor/canvas.zig``).
* **Bounded AABB Damage Tracking**: Only dirty rectangular extents (Axis-Aligned Bounding Boxes) are blitted to physical VRAM during refresh cycles.
* **Isolated Actor Surfaces**: Individual actors allocate private rendering surfaces in their own memory domains (``src/kernel/compositor/surface.zig``) and submit surface commit tokens over lock-free SPSC IPC rings.
* **Zero-Copy Composition**: The compositor merges visible actor surfaces into the backbuffer with clipping and Z-order stacking without allocating intermediate pixel arrays.
* **Tiling & HUD Window Manager**: Automatic golden-ratio binary space partitioning (BSP) and floating telemetry overlays manage screen real estate without legacy X11 or Wayland protocol overhead.

2. Double-Buffered Pipeline & Damage Tracking
=============================================

2.1 Backbuffer Layout & Page Alignment
--------------------------------------
The canonical compositing backbuffer is allocated in RAM with strict 4096-byte mathematical page alignment:

.. code-block:: zig

   pub const Backbuffer = struct {
       pixels: []align(4096) u32,
       width: u32,
       height: u32,
       pitch: u32,
       damage: DamageRect,
   };

2.2 Axis-Aligned Bounding Box (AABB) Damage Calculation
-------------------------------------------------------
Every drawing operation updates the composite damage extent:

.. code-block:: zig

   pub const DamageRect = struct {
       min_x: u32,
       min_y: u32,
       max_x: u32,
       max_y: u32,

       pub fn unionWith(self: *DamageRect, other: DamageRect) void {
           self.min_x = @min(self.min_x, other.min_x);
           self.min_y = @min(self.min_y, other.min_y);
           self.max_x = @max(self.max_x, other.max_x);
           self.max_y = @max(self.max_y, other.max_y);
       }
   };

During vertical flush, only rows between ``min_y`` and ``max_y``, clipped to ``[min_x, max_x]``, are copied to physical VRAM using optimized 64-bit word transfers. Once transferred, the damage region resets to empty.

3. Shared-Memory Actor Surfaces & Capability Gating
===================================================

3.1 Surface Allocation & Spatial Isolation
------------------------------------------
Actors create off-screen rendering surfaces within their own capability domains. Rendering authority is gated by the caller's Capability Space (CSpace):

* **Capability Verification**: The caller must possess a capability of type ``CapType.framebuffer`` with ``Rights.WRITE``.
* **Bounds Enforcement**: Surface dimensions (width and height) are bounded by kernel limits (max 1280x800). Writes outside a surface's extent are safely clamped or rejected with ``error.OutOfBounds``.

3.2 Zero-Copy Surface Commit Protocol
-------------------------------------
When an actor completes rendering a frame or text block, it pushes a typed commit descriptor to the compositor's SPSC ring buffer:

.. code-block:: zig

   pub const SurfaceCommit = extern struct {
       actor_id: u32,
       surface_id: u32,
       damage: DamageRect,
       timestamp: u64,
   };

The compositor thread awakens, clips the damaged extent against overlapping windows in the Z-order hierarchy, and blits the opaque or alpha-blended pixels directly into the system backbuffer.

4. Multi-Actor Window Manager (WM)
==================================

4.1 Tiling & Dynamic Partitioning
---------------------------------
The window manager supports two primary presentation modes:

* **Tiled Mode (Default)**: Automatically partitions the primary desktop area using a binary space partitioning (BSP) tree. Spawning a new actor splits the currently focused window along the golden ratio (horizontally or vertically).
* **Floating / HUD Mode**: Translucent overlays dedicated to system telemetry, resident AI conversation heads, and supervisor emergency alerts.

4.2 Window Hierarchy & Styling
------------------------------
Each window frame features minimalist technical styling:

* 1-pixel subtle border distinguishing active (cyan/blue) and inactive (muted grey) windows.
* 16-pixel title bar displaying actor ID, name, and lifecycle state.
* Smooth alpha-blended drop shadows for floating HUD windows.

5. Hardware Pointer & Input Focus Ingress
=========================================

5.1 PS/2 & USB HID Pointer Ingress
----------------------------------
The microkernel polls hardware pointer packets:

* Translates 3-byte PS/2 mouse movement deltas into absolute screen coordinates ``(ptr_x, ptr_y)``.
* Clamps coordinates to screen dimensions ``[0, 1279]`` and ``[0, 799]``.
* Overlays an 8x8 hardware cursor sprite non-destructively by caching background pixels beneath the pointer extent.

5.2 Focus Arbitration & Event Routing
-------------------------------------
* **Window Hit-Testing**: Pointer clicks query the window hierarchy top-to-bottom in Z-order. The matching window becomes active, moving to the top of the stack.
* **Keyboard Routing**: Scancodes from PS/2 keyboard or serial input are routed directly to the active window's incoming IPC ring.
* **Seamless Shell Switching**: Hotkey ``Ctrl+Alt+Space`` toggles focus instantly between App 0 MicroShell and the active visual actor window.

6. Framebuffer Verification & Quality Assurance
===============================================
- Automated regression tests in ``tools/src/fb_verify.zig`` validate window borders, damage clipping math, and multi-window rendering from headless QEMU screen dumps.
- Software rasterization throughput must sustain $\ge 60$ FPS on 1280x800 resolutions with zero frame drops or memory leaks.
