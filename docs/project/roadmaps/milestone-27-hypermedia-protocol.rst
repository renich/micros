Milestone 27: Binary Reactive Hypermedia Streaming Protocol (µHTML / HyperTree)
================================================================================

:Objective: Define and deploy the compact binary UI streaming schema (HyperTree) streaming declarative component trees over shared-memory IPC rings with fine-grained reactive signal updates and bidirectional event routing.
:Status: Completed
:Specification: SPEC-TECH-UI-001
:Traced Stories: [US-REN-008], [US-GEM-006]

Milestones & Deliverables
-------------------------

* **M27.1: Binary Component Tree Schema & IPC Streamer**
   - Implement binary AST layout in ``src/userland/gopd/hypertree.zig`` encoding elements (containers, text, buttons, canvases).
   - Stream tree mutation patches across SPSC shared-memory IPC rings with zero allocation in the rendering loop.

* **M27.2: Fine-Grained Reactive Signals & Partial Evaluation**
   - Propagate dirty state flags across component nodes; restrict rasterization passes strictly to changed subtrees.

* **M27.3: Bidirectional Input Event Dispatching**
   - Marshall pointer coordinates, mouse buttons, keyboard scancodes, and scroll deltas from ``gopd`` back to client actors.
