=============================================================
AABB-Bounded Vector Rasterizer & Glyph Atlas Cache (SPEC-TECH-UI-002)
=============================================================

:Document ID: SPEC-TECH-UI-002
:Status: Approved
:Traced Stories: [US-REN-001], [US-REN-009], [US-GEM-001], [US-GEM-003]

1. Architectural Axioms & Purpose
=================================
This specification formalizes the **AABB-Bounded Vector Rasterizer & Glyph Atlas Cache** substrate for MicrOS (µOS). Operating within the graphics output daemon (``gopd``), this subsystem delivers high-performance 2D vector geometry, anti-aliased primitives, alpha compositing, and dynamic glyph caching without external libraries, floating-point hardware requirements, or multi-megabyte fonts.

1.1 Elimination of Heavyweight Graphics Pipelines
-------------------------------------------------
Traditional UI runtimes pull in heavyweight dependencies (Skia, Cairo, HarfBuzz, FreeType) totaling hundreds of thousands of lines of C/C++ and introducing non-deterministic memory allocation patterns.

In MicrOS:
* **Fixed-Point Arithmetic (16.16)**: All curve evaluation, distance fields, and anti-aliasing math operate using deterministic 16.16 fixed-point integers, requiring zero x87/SSE floating-point state and ensuring freestanding portability.
* **AABB Damage Bounding**: Rasterization loops are strictly constrained to the Axis-Aligned Bounding Box (AABB) of dirty visual components, completely bypassing off-damage framebuffer pixels.
* **Zero-Allocation Glyph Atlas**: A pre-allocated texture atlas caches rasterized glyphs with sub-pixel offsets, achieving zero heap allocations during interactive text layout and streaming.

2. Vector Primitive Rasterization
=================================

2.1 Supported Vector Primitives
-------------------------------
The rasterizer exposes core geometric drawing primitives:

* **Anti-Aliased Lines**: Evaluated via fixed-point distance fields bounded by line thickness.
* **Rounded Rectangles**: Computed via 2D box Signed Distance Fields (SDF) with corner radii.
* **Bézier Curves**: Quadratic and cubic parametric curves evaluated via De Casteljau subdivision into monotonically bounded monotone segments.
* **Drop Shadows & Glow**: Gaussian-approximated box blurs constrained to outer AABB damage regions.

2.2 Signed Distance Field (SDF) Formulation
-------------------------------------------
For a point :math:`P(x, y)` and a box of half-extents :math:`(w/2, h/2)` with corner radius :math:`r`:

.. code-block:: text

   d(P) = length(max(|P| - half_extent + r, 0)) - r

Pixels where :math:`d \le 0` are fully opaque; pixels where :math:`0 < d < 1.0` are blended with coverage :math:`1.0 - d`.

3. Glyph Atlas Cache
====================

3.1 Cache Architecture & Layout
-------------------------------
The glyph cache manages a single contiguous 256 KiB grayscale alpha buffer organized as a shelf-packed or slot-indexed grid:

.. code-block:: zig

   pub const GlyphKey = struct {
       codepoint: u16,
       size_px: u8,
       weight: u8,
   };

   pub const CachedGlyph = struct {
       atlas_x: u16,
       atlas_y: u16,
       width: u8,
       height: u8,
       bearing_x: i8,
       bearing_y: i8,
       advance: u8,
       valid: bool,
   };

3.2 Sub-Pixel Text Rasterization
--------------------------------
When rendering text strings:
1. Lookup ``(codepoint, size, weight)`` in the glyph index.
2. If hit: blit alpha mask directly into surface canvas with destination color blending.
3. If miss: rasterize vector contours into the atlas buffer at the current shelf offset, insert cache entry, and blit.

4. Alpha Compositing & Blending
===============================

4.1 Porter-Duff Over Operator
-----------------------------
All geometric rendering and surface blitting mathematically enforce Porter-Duff *Over* alpha blending:

.. code-block:: text

   out_r = (src_r * src_a + dst_r * (255 - src_a)) / 255
   out_g = (src_g * src_a + dst_g * (255 - src_a)) / 255
   out_b = (src_b * src_a + dst_b * (255 - src_a)) / 255

Fixed-point division is implemented using bitwise approximation:

.. code-block:: zig

   pub fn blend(src: u32, dst: u32, alpha: u8) u32 {
       const inv_a = 255 - @as(u32, alpha);
       const a = @as(u32, alpha);
       const r = ((src >> 16 & 0xFF) * a + (dst >> 16 & 0xFF) * inv_a) >> 8;
       const g = ((src >> 8 & 0xFF) * a + (dst >> 8 & 0xFF) * inv_a) >> 8;
       const b = ((src & 0xFF) * a + (dst & 0xFF) * inv_a) >> 8;
       return (r << 16) | (g << 8) | b;
   }

5. Invariants & Quality Standards
=================================
1. **Zero Libc & Freestanding**: No floating-point or libc math functions (``sin``, ``cos``, ``sqrt``) linked; integer fixed-point lookups only.
2. **Bounded Complexity**: Rasterization loops strictly break upon reaching AABB boundary coordinates.
3. **Colocated Verification**: All primitive algorithms and glyph blitting operations must be validated via colocated unit tests.
