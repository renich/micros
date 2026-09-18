Milestone 36: Full Userland Service Daemon Integration & MPSC MessageFrame Protocol
====================================================================================

:Objective: Transition transitional Ring 0 in-memory daemon pointers to isolated Ring 3 service actors communicating exclusively via typed 64-byte MessageFrame records over lock-free MPSC IPC rings.
:Status: Planned
:Specification: SPEC-TECH-NET-004, SPEC-TECH-STO-002
:Traced Stories: [US-REN-004], [US-REN-006], [US-REN-007], [US-REN-008], [US-GEM-001], [US-GEM-006], [US-GEM-010]

Milestones & Deliverables
-------------------------

* **M36.1: Typed 64-Byte MessageFrame Ring Expansion**
   - Deprecate single-byte SPSC ring commands (``NetIpcCommand``, ``StorageIpcCommand``) in favor of fixed 64-byte structured ``MessageFrame`` records:
      - 16-byte header: sender/receiver actor ID, correlation sequence counter, opcode, and flags.
      - 48-byte payload sector: typed command parameters (LBA coordinates, sector counts, IPv4/port tuples, memory capability handles).
   - Enforce zero-allocation, bounded lock-free ring buffers between clients and system service daemons.

* **M36.2: Sever Direct Ring 0 ABI Pointer Linkages**
   - Eliminate direct pointer accesses from ``src/kernel/abi.zig`` to ``net_stack`` and ``cas_engine``.
   - Route all client storage requests (``cas_read``, ``cas_write``, ``chunk_lookup``) through asynchronous IPC requests to ``storaged``.
   - Route all network client requests (``tcp_connect``, ``tcp_send``, ``tcp_recv``, ``dns_resolve``) through asynchronous IPC requests to ``netd``.

* **M36.3: Ring 3 Hardware Capability Sandboxing & Fault Isolation**
   - Ensure ``netd``, ``storaged``, ``gopd``, and ``aid`` execute strictly within isolated CSpaces and non-privileged hardware address spaces.
   - Verify that driver crashes or malicious IPC frames trigger supervisor fault containment without inducing Ring 0 supervisor traps or kernel panics.
