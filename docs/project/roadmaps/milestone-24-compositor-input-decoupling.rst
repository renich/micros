Milestone 24: Pure Microkernel Compositor & Input Decoupling (gopd)
====================================================================

:Objective: Excise the GOP framebuffer double backbuffer, AABB dirty rectangle blitter, window manager, and input ingress from Ring 0 microkernel memory into an isolated userland display server actor (``gopd``), and integrate PS/2 mouse and baseline xHCI USB HID pointer/keyboard parsing.
:Status: Scheduled
:Specification: SPEC-TECH-COMPOSITOR-002
:Traced Stories: [US-REN-001], [US-REN-006], [US-GEM-001], [US-GEM-006], [US-GEM-010]

Milestones & Deliverables
-------------------------

* **M24.1: Userland Display Daemon (gopd)**
   - Author ``src/userland/gopd/gopd.zig`` as an isolated Ring 3 service actor.
   - Migrate double-buffered 1280x800 GOP backbuffer, 64-bit word blitting, and AABB dirty rectangle damage tracking out of Ring 0.
   - Retain 4096-byte page alignment and zero-copy surface commit token IPC.

* **M24.2: Framebuffer Capability Delegation**
   - Extend ``sys_frame_info`` in ``src/kernel/cap/cap_abi.zig`` to map physical UEFI GOP VRAM extents directly into ``gopd``'s virtual address space under capability verification.
   - Enforce Write-Combining (WC) page table caching attributes for high-speed linear framebuffer blitting.

* **M24.3: Multi-Actor Window Management & Z-Order Layering**
   - Migrate golden-ratio binary space partitioning (BSP) tiling layout and floating HUD overlays into ``gopd``.
   - Client actors allocate surfaces in private memory and stream ``SurfaceCommit`` tokens over MPSC IPC rings to ``gopd``.

* **M24.4: Unified Pointer & Keyboard Ingress (PS/2 & xHCI HID)**
   - Implement PS/2 mouse 3-byte packet decoding (button states, relative X/Y movement, coordinate clamping).
   - Implement baseline xHCI USB 3.0 HID keyboard and pointer packet ingress for physical bare-metal hardware.
   - Dispatch localized pointer coordinates, clicks, and keystrokes to focused top-level window actor IPC rings.
