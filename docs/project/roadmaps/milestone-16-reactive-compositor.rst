Milestone 16: Reactive Vector Compositor & Multi-Actor Windowing
================================================================

:Objective: Evolve the bare-metal UEFI GOP framebuffer from a static single-actor split canvas into an asynchronous, multi-actor reactive vector compositor. Implement double-buffered backbuffer blitting, bounded damage regions (AABBs), shared-memory actor surface IPC, a window manager with dynamic tiling and Z-order layering, and multi-actor visual telemetry.
:Status: Planned
:Specification: SPEC-TECH-COMPOSITOR-001

Milestones & Deliverables
-------------------------

* **M16.1: Double-Buffered Framebuffer & Bounded Damage Pipeline**
   - Implement ``src/kernel/compositor/canvas.zig`` managing a double-buffered 1280x800x32bpp backbuffer in kernel RAM.
   - Implement axis-aligned bounding box (AABB) damage region tracking (``DamageRect``) to eliminate full-screen redraw bottlenecks.
   - Engineer optimized 64-bit word blitting transferring only dirty rectangular extents to physical VRAM during vertical refresh.
   - Enforce mathematical 4096-byte page alignment on all backbuffer allocations.

* **M16.2: Shared-Memory Actor Surfaces & Zero-Copy IPC**
   - Implement ``src/kernel/compositor/surface.zig`` allowing individual actors to allocate isolated pixel surfaces in their own domain heaps.
   - Delegate surface rendering authority via CSpace capabilities (``Rights.CANVAS_DRAW``).
   - Implement non-blocking SPSC IPC notifications transmitting surface commit messages (``SurfaceCommit``) from client actors to the central compositor thread.
   - Guarantee spatial isolation: an actor cannot blit outside its assigned surface boundaries or overwrite other actors' surfaces.

* **M16.3: Multi-Actor Window Manager & Z-Order Tiling Layout**
   - Implement ``src/kernel/compositor/wm.zig`` providing sovereign desktop management without legacy X11 or Wayland protocol bloat.
   - Support dynamic layout modes:
      - *Tiled Mode*: Automatic golden-ratio binary space partitioning (BSP) across active actor windows.
      - *Floating/HUD Mode*: Layered translucent overlays for resident AI telemetry, system load monitors, and supervisor alerts.
   - Implement window decorations, titles, active border highlights, and smooth alpha blending.

* **M16.4: Interactive Window Focus & Unified Pointer Ingress**
   - Implement PS/2 mouse and USB HID pointer ingress in ``src/kernel/compositor/input.zig``.
   - Map physical pointer coordinates to top-level window hit-testing.
   - Dispatch focus change events and localized pointer coordinates to target actor IPC rings.
   - Maintain seamless keyboard input focus switching between interactive harness and spawned application actors.

* **M16.5: End-to-End GOP Visual Verification & Framebuffer Auditor**
   - Extend ``tools/src/fb_verify.zig`` to validate multi-window arrangements, Z-order occlusions, and border blits from headless QEMU screen dumps.
   - Integrate automated UI regression testing into ``tools/micros-runner.bash`` verifying window tiling under concurrent actor execution.
   - Enforce zero Ten Commandments infractions and 60 FPS redraw throughput in software rasterization.
