=========================================================
Pure Microkernel Compositor & Input Decoupling Spec (gopd)
=========================================================

:Document ID: SPEC-TECH-COMPOSITOR-002
:Status: Approved
:Traced Stories: [US-GEM-006], [US-REN-006], [US-REN-001], [US-GEM-001]

1. Architectural Axioms & Purpose
=================================
This specification formalizes the architectural excision of display compositing, double-buffering, Axis-Aligned Bounding Box (AABB) damage tracking, window management, and pointer/keyboard input decoding from the Ring 0 microkernel into an isolated userland service actor: the Graphics Output Protocol Daemon (``gopd``) in ``src/userland/gopd/gopd.zig``.

1.1 Elimination of Monolithic Display In-Kernel State
-----------------------------------------------------
In monolithic and hybrid kernel designs, the display server, window manager, and framebuffer rasterizer run with supervisor privileges in Ring 0. Any rendering bug, invalid memory dereference during glyph blitting, or miscalculated damage rect can trigger a fatal kernel panic that halts the entire operating system.

Under the MicrOS pure microkernel philosophy:

* **Ring 0 Hardware Minimality**: The microkernel core retains zero knowledge of window geometry, Z-ordering, font rasterization, backbuffers, or pointer dragging.
* **Strict CSpace Capability Delegation**: The display daemon operates solely within a capability-bounded userland actor domain, holding explicit ``CapType.framebuffer`` tokens to map physical VRAM.
* **Fault Containment & Self-Healing**: If ``gopd`` crashes, child actor fault containment isolates the crash. The supervisor terminates and restarts the daemon without kernel panic or reboot.

2. Display Service Actor (gopd) Architecture
============================================

2.1 Lifecycle State Machine
---------------------------
The ``GopDaemon`` actor in ``src/userland/gopd/gopd.zig`` maintains a strict lifecycle state machine:

.. code-block:: zig

   pub const DaemonState = enum(u8) {
       uninitialized = 0,
       offline = 1,
       active = 2,
       suspended = 3,
       faulted = 4,
   };

Transitions occur deterministically:
1. ``uninitialized`` -> ``offline``: Struct instantiation and memory allocator assignment.
2. ``offline`` -> ``active``: Hardware capability validation, backbuffer allocation (1280x800x32bpp), and window manager startup.
3. ``active`` -> ``suspended``: Display power management or screen locking.
4. ``active``/``suspended`` -> ``faulted``: Unhandled surface corruption or IPC queue overrun.

2.2 Capability-Gated Framebuffer MMIO Delegation
------------------------------------------------
Access to the physical UEFI GOP video RAM (VRAM) is restricted:

* **Capability Verification**: The caller must present a capability token of type ``CapType.framebuffer`` with ``Rights.WRITE | Rights.READ``. Any attempt to initialize ``gopd`` with an unauthorized capability is rejected with ``error.PermissionDenied``.
* **Physical Frame Mapping**: The microkernel exposes physical VRAM slice mapping via the ``sys_frame_info`` capability primitive, granting access only to the exact physical page bounds allocated to the display hardware.

3. Double-Buffered Rendering & Bounded AABB Damage
==================================================

3.1 Double-Buffered Backbuffer Layout
-------------------------------------
The canonical compositing backbuffer is maintained in userspace page-aligned system RAM:

* Dimensions: 1280 pixels width, 800 pixels height, 32 bits per pixel (0x00RRGGBB).
* Memory Footprint: 1280 * 800 * 4 = 4,096,000 bytes (~4 MB).
* Mathematical Alignment: ``align(4096)`` page boundaries mathematically guaranteed at compile time.

3.2 AABB Damage Tracking & Zero-Copy Presentation
-------------------------------------------------
Every visual surface update submits an Axis-Aligned Bounding Box (AABB) damage rectangle. The daemon computes the composite bounding union:

.. math::

   \text{Damage}_{\text{composite}} = \left[ \min(x_{\min}), \min(y_{\min}), \max(x_{\max}), \max(y_{\max}) \right]

During frame presentation:
* Only dirty scanlines within the composite damage rectangle are blitted from the userspace backbuffer into the physical VRAM frame.
* Undamaged display regions consume zero PCIe/MMIO bandwidth.
* Once presented, the damage extent resets to an empty bounding box.

4. Unified Pointer & Keyboard Ingress
=====================================

4.1 PS/2 Mouse 3-Byte Packet Decoding
-------------------------------------
``gopd`` integrates the freestanding ``Ps2MouseDecoder``:
* Byte 0: Flags (Y overflow, X overflow, Y sign, X sign, Always 1, Middle button, Right button, Left button).
* Byte 1: Relative X displacement ($dx$).
* Byte 2: Relative Y displacement ($dy$, sign-adjusted).

4.2 Clamped Cursor Kinematics & Event Dispatch
----------------------------------------------
* The cursor position is updated via checked arithmetic and clamped strictly to ``[0..width-1, 0..height-1]``.
* Mouse movement and click events are routed to the topmost window surface under the cursor coordinates according to the window manager Z-order hierarchy.

5. Specification Traceability & Verification Matrix
===================================================

.. list-table::
   :widths: 20 25 30 25
   :header-rows: 1

   * - Requirement ID
     - User Story
     - Implementation Component
     - Verification Method
   * - REQ-GOPD-001
     - [US-GEM-006]
     - ``src/userland/gopd/gopd.zig``
     - Unit test: Double-buffered damage flush
   * - REQ-GOPD-002
     - [US-REN-006]
     - ``src/userland/gopd/gopd.zig``
     - Unit test: Capability permission checks
   * - REQ-GOPD-003
     - [US-REN-001]
     - ``src/kernel/main.zig``
     - Unit test: Zero ambient authority delegation
   * - REQ-GOPD-004
     - [US-GEM-001]
     - ``src/kernel/main.zig``
     - Live QEMU boot: GOP daemon sentinel verification
