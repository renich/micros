Milestone 10: Sovereign Network Substrate & Gemini Flash Orchestrator
====================================================================

:Objective: Deliver a zero-libc sovereign network stack over VirtIO, pure Zig TLS 1.3, and live standalone integration with Google Gemini Flash under QEMU/KVM. Enable full autonomous system orchestration, allowing Gemini Flash to act as a sovereign constructor building tools (CoreUtils), services (web server), and desktop environments inside isolated actor domains.
:Status: In Progress (M10.1 - M10.4 Completed; M10.5 Active)
:Specification: SPEC-TECH-GEMINI-001

Milestones & Deliverables
-------------------------

* **M10.1: PCI Enumerator & VirtIO-Net Driver (The Link)** *(Completed & Verified)*
  - Implement ``src/kernel/drivers/pci.zig`` scanning PCI configuration space for network controllers.
  - Implement ``src/kernel/drivers/virtio_net.zig`` supporting modern VirtIO 1.0 network devices over PCI with split RX/TX virtqueues.
  - Integrate VirtIO packet buffers directly with microkernel physical memory pages.

* **M10.2: Sovereign Packet Processing & Auto-Configuration (L2/L3)** *(Completed & Verified)*
  - Implement ``src/kernel/net/frame.zig`` for zero-allocation 1514-byte Ethernet frame buffers.
  - Implement ``src/kernel/net/arp.zig`` with an in-memory ARP resolution table.
  - Implement ``src/kernel/net/ipv4.zig`` and ``src/kernel/net/icmp.zig`` for RFC 791 packet parsing and ICMP echo ping diagnostics.
  - Implement ``src/kernel/net/dhcp.zig`` automating IP, subnet mask, gateway, and DNS server discovery via RFC 2131.

* **M10.3: Transport & Cryptographic Security (L4/TLS 1.3)** *(Completed & Verified)*
  - Implement ``src/kernel/net/udp.zig`` and ``src/kernel/net/dns.zig`` for RFC 1035 domain name resolution.
  - Implement ``src/kernel/net/tcp.zig`` providing a dedicated, client-only RFC 793 TCP state machine for outbound port 443 connections.
  - Integrate ``std.crypto.tls.Client`` from Zig 0.16.0 standard library over the TCP stream, enabling pure Zig TLS 1.3 with Google Trust Services (GTS) root CA verification.
  - Pure Zig freestanding ``TcpStreamAdapter`` (``src/kernel/net/tls_stream.zig``) verified live with ``generativelanguage.googleapis.com:443`` in QEMU.

* **M10.4: Gemini 3.8 Flash Client & Inference Substrate** *(Completed & Verified)*
  - Implement freestanding HTTP/1.1 client in ``src/kernel/net/http.zig`` with status and header parsing.
  - Implement zero-libc JSON request escaping and response extraction in ``src/kernel/net/gemini.zig``.
  - Support build-time API key provisioning (``-Dgemini-api-key=<KEY>``) wired across the build graph.
  - Inject Sovereign Root Intelligence system prompt establishing Root CSpace authority and OS governance.

* **M10.5: Autonomous Tool Calling & System Construction** *(Active)*
  - Implement bidirectional tool-calling schemas enabling Gemini Flash to invoke ``compile_and_spawn_actor``, ``write_macros_file``, ``draw_vector_canvas``, and ``inspect_system``.
  - Empower human and AI to co-create software directly on the machine: building Micro CoreUtils, web servers, and graphical desktop compositors on demand.
