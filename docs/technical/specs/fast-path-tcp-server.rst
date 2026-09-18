====================================================
Fast-Path TCP Server Substrate Specification
====================================================

:Document ID: SPEC-TECH-NET-002
:Status: Approved
:Traced Stories: [US-REN-010], [US-GEM-001], [US-GEM-009], [US-GEM-010]
:Parent Architecture: `SPEC-TECH-SYS-001`
:Module Targets: ``src/kernel/net/tcp.zig``, ``src/kernel/net/stack.zig``, ``src/kernel/abi.zig``, ``lib/macros/http_server.mx``

1. Architectural Axioms & Purpose
=================================
This specification defines the freestanding, zero-libc Fast-Path Transmission Control Protocol (TCP) server engine for MicrOS (µOS). It establishes inbound server socket capabilities, enabling userland actors and the Resident AI to bind ports, accept incoming TCP connections, serve Content-Addressed Storage (CAS) payloads over HTTP/1.1, and receive Git push transfers.

1.1 The Fast-Path LAN Optimization Doctrine
-------------------------------------------
Traditional POSIX TCP server implementations (e.g., Linux/BSD) incur massive architectural bloat: dynamic timer wheels, Reno/Cubic/BBR congestion control state machines, complex out-of-order packet reassembly queues, and unbounded memory allocations for Transmission Control Blocks (TCBs). This complexity directly violates the MicrOS Ten Commandments (< 1,000 lines per file, < 40 lines per function, zero libc).

MicrOS is an autonomous bare-metal substrate designed for direct silicon and virtualized environments (VirtIO-Net under QEMU, KVM, and local gigabit LANs). Over local network fabrics, packet loss is near-zero and transmission reordering is negligible. Therefore, this specification adopts the **Asymmetric Fast-Path Doctrine**:

* **Stateless SYN-Cookies**: The server allocates zero memory and zero TCB state upon receiving a TCP ``SYN``. The Initial Sequence Number (ISN) is computed deterministically via cryptographic hashing. State is allocated only upon reception of the verifying ``ACK``.
* **Strict In-Order Ingestion (Go-Back-N)**: The server does not maintain dynamic out-of-order reassembly buffers. Segments arriving with ``seq_num != expected_seq`` are dropped immediately, letting the remote sender's standard Retransmission Timeout (RTO) retransmit cleanly.
* **Static Window Sizing**: The server advertises a fixed 64 KiB receive window and never shrinks it, delegating congestion avoidance to the client.
* **Fiber-Integrated Retransmission**: Retransmission checks attach directly to the cooperative fiber scheduler idle loop, eliminating hardware timer wheel complexity.

1.2 The Object-Capability Security Gate
---------------------------------------
Inbound network access is strictly governed by the Actor's Capability Space (CSpace):

* **Capability Guard**: An actor must possess a valid ``CapType.network_device`` capability with ``Rights.BIND`` (0x0002) and ``Rights.READ`` (0x0001).
* **Port Range Attenuation**: Privilege escalation is prevented by binding port ranges to the capability extent. Privileged ports (< 1024, such as port 80 or 443) require root capability authorization. Dynamic workers run strictly attenuated.

2. Stateless SYN-Cookie Protocol
================================
To eradicate SYN-flood attacks and prevent unbounded dynamic memory allocation in the microkernel, inbound connection handshakes operate statelessly.

2.1 Initial Sequence Number (ISN) Generation
--------------------------------------------
When a TCP segment arrives with ``flags == FLAG_SYN`` and the destination port matches an active listener:

1. The kernel does **not** allocate a connection block.
2. The kernel computes a 32-bit cryptographic cookie:
   ``cookie = BLAKE3(src_ip || dst_ip || src_port || dst_port || client_isn || kernel_secret_nonce)[0..4]``
3. The kernel transmits a ``SYN-ACK`` packet with:
   * ``seq_num = cookie``
   * ``ack_num = client_isn + 1``
   * ``flags = FLAG_SYN | FLAG_ACK``
   * ``window_size = 65535``

2.2 Three-Way Handshake Finalization
------------------------------------
When a subsequent TCP segment arrives with ``flags & FLAG_ACK != 0``:

1. The kernel recomputes the expected cookie for the 4-tuple.
2. If ``segment.ack_num - 1 == expected_cookie``:
   * The client has proven round-trip address ownership.
   * The kernel claims an available connection slot from a pre-allocated static pool (``MAX_SERVER_CONNECTIONS = 16``).
   * The connection transitions immediately to state ``.established``.
   * An incoming connection event is signaled to the listening actor's IPC ring.
3. If the cookie verification fails, the segment is silently dropped or rejected with ``FLAG_RST``.

3. Connection Pool & State Machine
==================================

3.1 Server Connection Topology
------------------------------
The network stack maintains a static array of server connection descriptors:

.. code-block:: zig

   pub const MAX_LISTENERS: usize = 4;
   pub const MAX_SERVER_CONNECTIONS: usize = 16;
   pub const TCP_RX_BUFFER_SIZE: usize = 65536;
   pub const TCP_TX_BUFFER_SIZE: usize = 65536;

   pub const ServerState = enum(u8) {
       closed = 0,
       listen = 1,
       syn_received = 2,
       established = 3,
       fin_wait_1 = 4,
       fin_wait_2 = 5,
       close_wait = 6,
       closing = 7,
       last_ack = 8,
       time_wait = 9,
   };

   pub const TcpServerConn = struct {
       id: u32,
       state: ServerState,
       local_port: u16,
       remote_port: u16,
       remote_ip: [4]u8,
       remote_mac: [6]u8,
       local_seq: u32,
       remote_seq: u32,
       remote_ack: u32,
       last_activity_ticks: u64,
       rx_buf: [TCP_RX_BUFFER_SIZE]u8,
       rx_head: usize,
       rx_tail: usize,
       tx_buf: [TCP_TX_BUFFER_SIZE]u8,
       tx_len: usize,
       owner_actor: u32,
   };

3.2 Teardown & Half-Closed Handling
-----------------------------------
* **Remote FIN**: When the client sends ``FLAG_FIN``, the connection acknowledges (``FLAG_ACK``), sets ``remote_seq += 1``, and transitions to ``.close_wait``. The listening actor reads remaining buffered data.
* **Actor Close**: When the actor calls ``sys_net_close(fd)``, the server sends ``FLAG_FIN | FLAG_ACK``, transitions to ``.last_ack``, and awaits the final client ``ACK`` before recycling the slot to ``.closed``.
* **RST Handling**: Any segment received with ``FLAG_RST`` immediately terminates the connection, flushes buffers, and sets state to ``.closed``.

4. Sovereign Syscall ABI
========================
The kernel exposes 5 capability-gated network syscalls in ``src/kernel/abi.zig``:

1. ``sys_net_listen(port: i64) -> Value``
   * **Signature**: ``sys_net_listen(port) -> fd (integer >= 0) or -1``
   * **Rights Required**: ``CapType.network_device`` with ``Rights.BIND``.
   * **Preconditions**: ``port > 0`` and ``port <= 65535``. Port must not be actively bound.
   * **Postconditions**: Allocates listener descriptor in ``active_listeners``. Returns handle identifier.

2. ``sys_net_accept(listener_fd: i64) -> Value``
   * **Signature**: ``sys_net_accept(listener_fd) -> conn_fd (integer >= 0) or -1``
   * **Rights Required**: Caller must be owner actor of ``listener_fd``.
   * **Behavior**: Non-blocking inspection of the connection pool. If a connection in state ``.established`` matches the listener port, returns connection ``fd``. Returns ``-1`` if no connections are pending.

3. ``sys_net_recv(conn_fd: i64, max_len: i64) -> Value``
   * **Signature**: ``sys_net_recv(conn_fd, max_len) -> string (bytes)``
   * **Rights Required**: Caller must be owner actor of ``conn_fd``.
   * **Behavior**: Reads up to ``max_len`` bytes from the connection's circular RX buffer. Updates ``rx_head``, advances advertised window if necessary, and returns received payload as a string.

4. ``sys_net_send(conn_fd: i64, data: string) -> Value``
   * **Signature**: ``sys_net_send(conn_fd, data) -> integer (bytes_sent)``
   * **Rights Required**: Caller must be owner actor of ``conn_fd``.
   * **Behavior**: Transmits TCP payload segment with ``flags = FLAG_ACK | FLAG_PSH``, sets ``local_seq += len``, and updates checksums.

5. ``sys_net_close(conn_fd: i64) -> Value``
   * **Signature**: ``sys_net_close(conn_fd) -> boolean``
   * **Behavior**: Initiates active FIN teardown. Returns ``true`` upon initiation.

5. Fiber Scheduler Event Integration
====================================
TCP retransmissions and idle timeouts must not rely on interrupts or POSIX signals:

* **Idle Sweep Hook**: Inside ``src/kernel/actor.zig`` (scheduler loop), whenever a fiber yields (``sys_yield()``) or the scheduler is idle, the kernel calls ``net_stack.pollTcpServer()``.
* **Timeout Verification**: For each active connection in ``.established`` or ``.fin_wait``:
  * If unacknowledged TX bytes exist and ``(current_ticks - last_activity_ticks) > RTO_TICKS``:
    * Retransmit unacknowledged slice.
    * Double RTO (exponential backoff up to 3 retries).
  * If retries exceed 3, transmit ``FLAG_RST`` and recycle slot to ``.closed``.

6. Userland Application Contracts
=================================

6.1 CAS-Backed Web Server Actor (``lib/macros/http_server.mx``)
--------------------------------------------------------------
A sovereign actor running in pure Macros:

1. Calls ``sys_net_listen(80)``.
2. In an event loop:
   * Polls ``sys_net_accept(fd)``.
   * If client connected:
     * Reads request headers via ``sys_net_recv(client, 1024)``.
     * Parses HTTP verb and path (e.g., ``GET /b3/<hash>``).
     * Retrieves payload via ``sys_cas_get(hash)``.
     * Formats HTTP/1.1 200 OK header with ``Content-Length``.
     * Sends headers and payload via ``sys_net_send(client, body)``.
     * Calls ``sys_net_close(client)``.
   * Yields via ``sys_yield()``.

6.2 Git Smart HTTP Ingestion Protocol
-------------------------------------
Provides read/write repository transport:

* **Discovery**: Serves ``GET /repo.git/info/refs?service=git-receive-pack`` with packet-line format.
* **Receive Pack**: Ingests ``POST /repo.git/git-receive-pack`` payload, passes packfile to CAS parser, stores committed trees and blobs as immutable BLAKE3 hashes, and confirms commit.

7. Verification & Traceability Matrix
=====================================

7.1 Test Matrix
---------------
* **Unit Tests** (``src/kernel/net/tcp.zig``):
  1. *SYN-Cookie Calculation & Verification*: Proves valid cookie matches expected 4-tuple and invalid cookie drops segment.
  2. *Server State Machine Transitions*: Verifies LISTEN -> SYN_RECEIVED -> ESTABLISHED -> CLOSE_WAIT -> CLOSED.
  3. *In-Order Enforcement*: Verifies out-of-order segment dropping and sequence advancement.
  4. *Static Buffer Management*: Proves circular RX buffer rollover and window advertisement stability.
* **Syscall ABI Tests** (``src/kernel/abi.zig``):
  1. *Capability Rejection*: Proves ``sys_net_listen`` fails without ``network_device.BIND``.
  2. *Accept & Send/Recv Loopback*: Synthesizes loopback connection and verifies bidirectional payload transmission.
* **Integration Tests** (QEMU VirtIO-Net):
  1. Host `curl` against QEMU guest port 8080 serving CAS payload.
  2. Automated spec traceability verification with ``micros-spec-trace.bash --check``.

7.2 Traceability Tags
---------------------
* ``[US-REN-010]``: High-concurrency network sockets running in green-thread fibers.
* ``[US-GEM-001]``: Freestanding zero-libc network stack operating without glibc or POSIX.
* ``[US-GEM-009]``: Self-healing actor execution and dynamic web server synthesis.
* ``[US-GEM-010]``: Clean domain boundaries, modules <= 1,000 lines, functions <= 40 lines.
