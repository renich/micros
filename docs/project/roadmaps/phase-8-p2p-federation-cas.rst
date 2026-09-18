Phase 8: Autonomous Peer-to-Peer Federation & Distributed CAS
============================================================

:Objective: Expand MicrOS from an isolated single-node operating system into a decentralized, sovereign peer-to-peer compute and storage mesh communicating over mutual TLS and Noise protocols without centralized cloud providers or registries.
:Status: Scheduled
:Specifications: `SPEC-TECH-P2P-001`, `SPEC-TECH-P2P-002`, `SPEC-TECH-P2P-003`
:Critical Path: M30 -> M31 -> M32

Milestones & Deliverables
-------------------------

* **Milestone 30: Sovereign P2P Mutual TLS & Noise Wire Protocol** [SCHEDULED]
   - **P2P Transport Protocol**: Implement freestanding mutual TLS 1.3 / Noise Protocol wire handshake over TCP port 8080.
   - **Cryptographic Node Identity**: Identify nodes via Ed25519 public keys and BLAKE3 node IDs; reject unauthorized and unauthenticated connections.
   - **Local Mesh Discovery**: Implement zero-configuration multicast/broadcast peer discovery over local LAN networks and gossip routing for WAN peering.
   - **Blocked By**: Phase 6 (M25 storaged, M26 microkernel stability).
   - **Unblocks**: M31, M32.

* **Milestone 31: Distributed Content-Addressed Storage & Merkle Sync** [SCHEDULED]
   - **Decentralized CAS Replication**: Stream 256-bit BLAKE3 chunks across peer nodes on-demand with cryptographic integrity verification.
   - **Workspace Merkle Difference Exchange**: Compare workspace manifest trees across nodes and synchronize missing chunks efficiently.
   - **Offline-First OCC Reconciliation**: Resolve concurrent distributed workspace edits using monotonic generation counters and conflict-free data types.
   - **Blocked By**: M30.
   - **Unblocks**: M32, Phase 9 (Module Federation).

* **Milestone 32: Cryptographic Capability Delegation & Remote Actor Compute** [SCHEDULED]
   - **Cryptographic Capability Tokens**: Implement attenuated, signed capability tokens (Macaroons / Ed25519) with monotonic expiration for cross-node operations.
   - **Remote Actor Dispatch**: Spawn and supervise sandboxed actors on remote cluster nodes with transparent network-boundary IPC message forwarding.
   - **Blocked By**: M31.
   - **Unblocks**: Cluster-scale sovereign computing.
