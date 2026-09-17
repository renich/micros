Phase 3: Subsystems & Compositor
================================

:Objective: Implement persistent storage, network stack, transport security, resident AI orchestration, and the reactive vector compositor.
:Status: Completed

Milestones
----------

* **M3.1: CoW Storage Substrate (Milestone 14)**
  - VirtIO-Blk driver and BLAKE3 Content-Addressed Storage (CAS) engine.
  - Verified atomic superblock persistence and cold-reboot recovery.
  - *(Completed & Verified)*

* **M3.2: Network Stack & Transport Security (Milestones 10 & 11)**
  - VirtIO-Net driver with DHCP client negotiation.
  - Freestanding TCP/IP sliding window protocol and embedded TLS 1.3 cryptographic engine.
  - *(Completed & Verified)*

* **M3.3: Resident AI Substrate & Tool Calling (Milestones 12 & 15)**
  - Pluggable Gemini and local AI inference clients.
  - Zero-allocation streaming JSON parser and capability-gated tool dispatcher.
  - *(Completed & Verified)*

* **M3.4: Process Hierarchy Decoupling & Actor Supervision (Milestone 15b)**
  - 4-layer taxonomy: Microkernel -> Actor 0 init -> App 0 msh -> App 1 harness.
  - Unified native C-ABI substrate (``src/kernel/abi.zig``) and immortal supervisor.
  - *(Completed & Verified)*

* **M3.5: Reactive Vector Compositor & Multi-Actor Windowing (Milestone 16)**
  - Double-buffered 1280x800 GOP backbuffer with AABB dirty rectangle damage tracking.
  - Shared-memory actor surfaces, zero-copy IPC, and Z-order window manager.
  - *(Completed & Verified)*
