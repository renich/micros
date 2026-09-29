========================================================================
Pure Microkernel Network & AI Decoupling Substrate (µOS)
========================================================================

:Document ID: SPEC-TECH-NET-004
:Status: Approved
:Traced Stories: [US-REN-004], [US-REN-006], [US-REN-010], [US-GEM-001], [US-GEM-006], [US-GEM-009], [US-GEM-010]
:Absorbed Specifications: `SPEC-TECH-NET-002` (Fast-Path TCP Server Substrate)
:Parent Architecture: `SPEC-TECH-NET-001`, `SPEC-TECH-NET-003`, `SPEC-TECH-CAP-001`
:Module Targets: ``src/kernel/cap/capability.zig``, ``src/kernel/ipc/ring.zig``, ``src/kernel/abi.zig``, ``src/kernel/main.zig``, ``src/userland/netd/``, ``src/userland/aid/``

1. Architectural Axioms & Purpose
=================================
This specification defines the architectural decomposition, capability primitives, and shared-memory inter-process communication (IPC) protocols required to completely migrate networking drivers, the TCP/IP stack, TLS 1.3 cryptographic engines, and AI inference services out of Ring 0 into isolated userspace service actors (``netd`` and ``aid``).

1.1 Pure Microkernel Axiom
--------------------------
In a mathematically verified, sovereign microkernel:

* **Kernel Minimality**: Ring 0 must only execute CPU context switching, physical/virtual memory management (page tables), capability space enforcement (CSpace), and interrupt/IPC signaling.
* **Driver Isolation**: Network interface card (NIC) drivers, packet decoders, and protocol state machines must execute in Ring 3. A crash, exploit, or buffer overflow in a protocol stack cannot corrupt the kernel or peer actors.
* **Zero Ambient Authority**: Userland service actors access hardware MMIO, DMA buffers, and interrupt lines strictly through explicit, non-forgeable capabilities (``CapType.hardware_device``, ``CapType.irq_handler``).
* **Zero-Copy Lock-Free IPC**: Inter-actor packet streaming operates across page-aligned, single-producer single-consumer (SPSC) shared-memory circular ring buffers with cacheline alignment (64 bytes).

2. Hardware Capability Primitives
=================================

2.1 DMA Frame Mapping
---------------------
To operate VirtIO-Net descriptor rings, ``netd`` requires memory buffers whose physical addresses are known to the PCI host:

* **Syscall**: ``sys_frame_info(frame_cap: u32) -> PhysFrameInfo``
  Returns the 64-bit physical memory address of an allocated 4096-byte page.
* **Security Gate**: This syscall strictly requires ``CapType.hardware_device`` with ``Rights.WRITE | Rights.EXECUTE`` in the caller's CSpace.

2.2 Userland Interrupt Signaling (seL4-Style Notifications)
-----------------------------------------------------------
Hardware IRQs are safely routed to userland without giving actors direct vector control:

1. Ring 0 receives the CPU interrupt (e.g. IRQ 11 for VirtIO-PCI).
2. The kernel masks the IRQ at the APIC level to prevent interrupt storms.
3. The kernel signals an asynchronous ``NotificationCap`` bound to the actor's fiber.
4. The scheduler unparks ``netd``, which drains the VirtIO RX ring.
5. ``netd`` invokes ``sys_irq_ack(irq_cap)`` to unmask the interrupt line.

3. Userland Service Architecture
================================

3.1 Network Daemon (``netd``)
-----------------------------
* **Domain ID**: Dedicated system service actor spawned by Genesis.
* **Capabilities**: ``CapType.hardware_device`` (PCI MMIO / I/O ports), ``CapType.irq_handler`` (VirtIO-Net IRQ), ``CapType.memory_frame`` (DMA buffers).
* **Subsystems**:
  * VirtIO-Net 1.0 packet ring manager.
  * ARP table and IPv4 router.
  * Fast-Path TCP engine (RFC 9293 state machine, BLAKE3 SYN-cookies).
* **Interface**: Exposes IPC endpoints for opening, binding, sending, and receiving raw TCP streams.

3.1.1 Fast-Path Stateless TCP Engine Substrate
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
To eradicate SYN-flood attacks and prevent unbounded dynamic memory allocation in the microkernel and userland daemon, inbound connection handshakes operate statelessly:

* **Stateless SYN-Cookies**: The engine computes a 32-bit cryptographic cookie: ``cookie = BLAKE3(src_ip || dst_ip || src_port || dst_port || client_isn || kernel_secret_nonce)[0..4]``. It allocates zero memory and zero TCB state upon receiving a TCP ``SYN``. State is allocated only upon reception of the verifying ``ACK``.
* **Strict In-Order Ingestion (Go-Back-N)**: Segments arriving with ``seq_num != expected_seq`` are dropped immediately, letting the remote sender's standard Retransmission Timeout (RTO) retransmit cleanly.
* **Static Window Sizing**: The server advertises a fixed 64 KiB receive window and never shrinks it.
* **Fiber-Integrated Retransmission**: Retransmission checks attach directly to the cooperative fiber scheduler idle loop, eliminating hardware timer wheels.
* **Connection Topology**: Pre-allocated static pool (``MAX_LISTENERS = 4``, ``MAX_SERVER_CONNECTIONS = 16``, 64 KiB RX/TX buffers) governed by ``ServerState`` enum (closed, listen, syn_received, established, fin_wait_1/2, close_wait, closing, last_ack, time_wait).
* **Object-Capability Security Gate**: Listening requires ``CapType.network_device`` with ``Rights.BIND`` (0x0002) and ``Rights.READ`` (0x0001). Privileged ports (< 1024) require root capability authorization.

3.2 Sovereign AI & Security Daemon (``aid``)
--------------------------------------------
* **Domain ID**: Dedicated cryptographic and cognitive service actor.
* **Capabilities**: ``CapType.ipc_endpoint`` connected to ``netd`` and client applications (``ush``, ``harness``).
* **Subsystems**:
  * Freestanding TLS 1.3 cryptographic engine (ChaCha20-Poly1305, AES-GCM, ML-KEM-768).
  * HTTP/1.1 client chunking and REST framing.
  * Multi-turn LLM request synthesis and tool call parser.

4. Lock-Free SPSC Shared-Memory Schema
======================================
Inter-actor communication between ``netd``, ``aid``, and clients uses cacheline-isolated SPSC rings:

.. code-block:: zig

   pub const SpscRingBuffer = extern struct {
       align(64) head: u32,
       align(64) tail: u32,
       align(64) capacity: u32,
       align(64) buffer: [3968]u8, // 4096 bytes total page alignment
   };

5. Verification & Traceability Matrix
=====================================
* ``[US-REN-004]``: Zero-libc substrate determinism with complete microkernel isolation.
* ``[US-REN-006]``: Capability-bounded process supervision without ambient root authority.
* ``[US-REN-010]``: High-concurrency green-thread event scheduling over lock-free memory rings.
* ``[US-GEM-001]``: Unforgeable binary telemetry and structured IPC streams.
* ``[US-GEM-006]``: Independent userland service resilience and fault recovery.
* ``[US-GEM-009]``: Self-healing actor execution and dynamic workspace supervisor controls.
* ``[US-GEM-010]``: Strict adherence to file size (<= 1,000 lines) and function size (<= 40 lines).
