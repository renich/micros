Milestone 37: Virtual Multi-Node P2P Cluster Mesh Wire Discovery
================================================================

:Objective: Orchestrate automated dual-node QEMU cluster mesh interconnected via point-to-point stream sockets, verifying UDP broadcast beacon discovery, Ed25519 identity exchange, and capability-gated P2P syscalls.
:Status: Completed
:Specification: SPEC-TECH-P2P-001
:Traced Stories: [US-REN-006], [US-GEM-001]

Milestones & Deliverables
-------------------------

* **M37.1: Multi-Instance QEMU Cluster Harness (tools/micros-cluster.bash)**
   - Orchestrate dual-node virtual machines connected via private stream interconnect (``127.0.0.1:12345``) requiring zero root permissions.

* **M37.2: Wire Beacon Discovery & Handshake Verification**
   - Transmit 74-byte UDP broadcast beacons (port 8081); verify mutual identity discovery and Ed25519 node key exchange.

* **M37.3: Capability-Gated P2P Syscalls**
   - Implement ``sys_peer_count()``, ``sys_peer_info()``, and ``sys_p2p_status()`` strictly guarded by ``CapType.network_device``.
