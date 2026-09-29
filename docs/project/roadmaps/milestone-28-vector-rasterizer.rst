Milestone 28: AABB-Bounded Vector Rasterizer & Glyph Atlas Cache
================================================================

:Objective: Implement software Signed Distance Field (SDF) and Bézier curve vector rasterization bounded by Axis-Aligned Bounding Box (AABB) damage rectangles, scalable vector typography, and smooth alpha blending.
:Status: Completed
:Specification: SPEC-TECH-UI-002
:Traced Stories: [US-REN-008], [US-GEM-006]

Milestones & Deliverables
-------------------------

* **M28.1: AABB-Bounded Software Vector Engine**
   - Implement fixed-point 16.16 vector curve rasterization bounded by damaged screen regions in ``src/userland/gopd/vector.zig``.
   - Eliminate full-screen repaints, preserving native 60Hz+ refresh rates under software CPU blitting.

* **M28.2: TrueType Glyph Atlas & Font Caching**
   - Render vector glyph contours into a shared multi-scale texture atlas with sub-pixel horizontal positioning.

* **M28.3: Anti-Aliased Alpha Blending & Glass Compositing**
   - Deliver translucent backdrop styling, anti-aliased geometry, drop shadows, and clipping masks for modern desktop windows.
