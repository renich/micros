Milestone 18b: Fast-Path TCP Server Substrate
==============================================

:Objective: Implement a freestanding, zero-libc Fast-Path Transmission Control Protocol (TCP) server engine for MicrOS (µOS). Deliver stateless BLAKE3 SYN-cookie generation, an RFC 9293 9-state TCP server state machine, in-order packet dropping, a static Transmission Control Block (TCB) pool, capability-gated network syscalls, and a pure Macros CAS-backed HTTP/1.1 web server actor.
:Status: Complete & Verified
:Specification: SPEC-TECH-NET-002

Milestones & Deliverables
-------------------------

* **M18b.1: Stateless BLAKE3 SYN-Cookie Engine** [COMPLETE & VERIFIED]
   - Implemented ``computeSynCookie`` and ``verifySynCookie`` in ``src/kernel/net/tcp.zig``.
   - Hashed 24-byte 4-tuple, client ISN, and 64-bit kernel secret nonce with BLAKE3 to prevent SYN flood denial of service with zero pre-handshake memory allocation.
   - Eliminates kernel memory exhaustion from half-open connection spam.

* **M18b.2: Fast-Path TCP Server State Machine & Circular Buffers** [COMPLETE & VERIFIED]
   - Implemented ``TcpListener`` and ``TcpServerConn`` in ``src/kernel/net/tcp.zig`` supporting LISTEN, SYN-RECEIVED, ESTABLISHED, CLOSE-WAIT, LAST-ACK, FIN-WAIT-1, FIN-WAIT-2, CLOSING, and TIME-WAIT states.
   - Implemented 16 KiB circular RX and TX ring buffers per connection.
   - Enforced Go-Back-N in-order packet dropping for out-of-sequence packets, offloading congestion and retransmission recovery to clients on reliable LAN/virtualization fabrics.

* **M18b.3: Capability-Gated Network Syscall ABI** [COMPLETE & VERIFIED]
   - Implemented ``src/kernel/net/net_abi.zig`` exposing 5 native syscalls: ``sys_net_listen``, ``sys_net_accept``, ``sys_net_recv``, ``sys_net_send``, and ``sys_net_close``.
   - Enforced capability checks against ``CapType.network_device`` in the caller's CSpace with port range restrictions.
   - Integrated network polling into ``sys_yield`` and ``sys_actor_wait`` to process incoming packets during fiber idle loops.

* **M18b.4: Pure Macros CAS-Backed HTTP/1.1 Server Actor** [COMPLETE & VERIFIED]
   - Authored sovereign pure Macros HTTP web server in ``lib/macros/http_server.mx``.
   - Implemented HTTP request line parsing, route dispatching (``/``, ``/health``, ``/b3/<hash>``), and CAS payload streaming directly from BLAKE3 content-addressed chunks.
   - Added ``httpd`` command to ``lib/macros/msh.mx`` and packaged ``http_server.mx`` into ``src/kernel/genesis.mcb``.

* **M18b.5: QEMU Port Forwarding & Host Curl Live Verification** [COMPLETE & VERIFIED]
   - Configured ``hostfwd=tcp::8080-:8080`` in ``GNUmakefile`` and ``tools/micros-runner.bash``.
   - Verified live end-to-end multi-route HTTP queries from host ``curl http://127.0.0.1:8080/health`` and ``curl http://127.0.0.1:8080/`` under QEMU UEFI with zero defects.
