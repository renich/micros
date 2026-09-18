===========================================================
Binary Reactive Hypermedia Streaming Protocol (SPEC-TECH-UI-001)
===========================================================

:Document ID: SPEC-TECH-UI-001
:Status: Approved
:Traced Stories: [US-REN-001], [US-REN-010], [US-GEM-001], [US-GEM-006]

1. Architectural Axioms & Purpose
=================================
This specification formalizes the **Binary Reactive Hypermedia Streaming Protocol** (µHTML / HyperTree) for MicrOS (µOS). It establishes a zero-waste, human-centric user interface model that eliminates DOM trees, CSS string parsers, and multi-gigabyte browser/Electron runtimes in favor of strongly typed binary component trees streamed directly over shared-memory IPC ring buffers.

1.1 Elimination of Browser Runtimes & String Parsing
----------------------------------------------------
Traditional desktop applications rely on web runtimes (Chromium, Electron, WebKit) consuming hundreds of megabytes of RAM and millions of lines of C++ parsing textual HTML/CSS/JS.

In MicrOS:
* **Binary Component Trees**: UI elements (containers, text, buttons, inputs, canvases) are represented as fixed-layout, strongly typed 32-byte binary node structs.
* **Shared-Memory IPC Streaming**: Applications stream UI component updates directly to the display server (`gopd`) across lock-free SPSC ring buffers (`SpscRingBuffer`).
* **Sub-15MB Memory Footprint**: A complete graphical application tree consumes less than 64 KiB of memory, enabling thousands of concurrent UI components on edge silicon.

2. Binary HyperTree Protocol Architecture
=========================================

2.1 Component Node Types & Schema
---------------------------------
Every visual element in the HyperTree is a compact binary record:

.. code-block:: zig

   pub const NodeType = enum(u8) {
       none = 0,
       container = 1,
       text = 2,
       button = 3,
       input = 4,
       canvas = 5,
       icon = 6,
       divider = 7,
   };

   pub const NodeFlags = struct {
       pub const VISIBLE: u8 = 0x01;
       pub const DIRTY: u8 = 0x02;
       pub const FOCUSED: u8 = 0x04;
       pub const HOVERED: u8 = 0x08;
       pub const CLICKABLE: u8 = 0x10;
       pub const DISABLED: u8 = 0x20;
   };

   pub const HyperNode = extern struct {
       id: u32,
       parent_id: u32,
       node_type: NodeType,
       flags: u8,
       layout_dir: u8, // 0 = row, 1 = column
       reserved: u8,
       x: i16,
       y: i16,
       width: u16,
       height: u16,
       color_fg: u32,
       color_bg: u32,
       payload_len: u16,
       payload_offset: u16,
   };

comptime {
    std.debug.assert(@sizeOf(HyperNode) == 32);
}

2.2 Streaming Mutation Commands
-------------------------------
Applications mutate the visual tree by sending streaming binary commands:

* `insert_node(node)`: Insert a new node into the tree under `parent_id`.
* `update_node(id, patch)`: Mutate fields of an existing node and mark it `DIRTY`.
* `remove_node(id)`: Remove a node and its recursive subtrees.
* `commit_tree()`: Atomically notify `gopd` to compute AABB damage rectangles and rasterize.

3. Reactive Signals & State Synchronization
===========================================

3.1 Fine-Grained Reactive Signals
---------------------------------
State is managed via reactive signals. When a signal value changes:
1. Only the dependent HyperNodes subscribing to the signal are flagged as `DIRTY`.
2. Clean nodes are skipped during frame serialization, achieving true zero-cost reactivity.
3. The dirty subgraph is packed into a compact binary diff chunk and dispatched to `gopd`.

3.2 Bidirectional Event Ingress & Propagation
---------------------------------------------
`gopd` captures pointer movements, mouse button clicks, keypresses, and scroll events, then routes them back across the client's event ring:

.. code-block:: zig

   pub const UiEventKind = enum(u8) {
       click = 1,
       mouse_down = 2,
       mouse_up = 3,
       mouse_move = 4,
       key_down = 5,
       key_up = 6,
       focus_gain = 7,
       focus_loss = 8,
       scroll = 9,
   };

   pub const UiEvent = extern struct {
       target_node_id: u32,
       event_kind: UiEventKind,
       modifier_keys: u8,
       char_code: u16,
       mouse_x: i16,
       mouse_y: i16,
       delta: i16,
       reserved: u16,
       timestamp_ticks: u64,
   };

comptime {
    std.debug.assert(@sizeOf(UiEvent) == 24);
}

4. Mathematical Invariants & Verification
=========================================
1. **Node Record Size**: Exactly 32 bytes, aligned to 8-byte boundaries.
2. **Event Record Size**: Exactly 24 bytes, aligned to 8-byte boundaries.
3. **Zero Dynamic Allocation in Hot Path**: Node mutations and event streaming use static pre-allocated ring buffers.
4. **Deterministic AABB Damage**: Any node position or dimension mutation automatically expands the dirty bounding box without whole-screen redraws.
