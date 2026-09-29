Milestone 30: Sovereign P2P Mutual TLS & Noise Wire Protocol
=============================================================

:Objective: Implement authenticated, encrypted peer-to-peer transport with Ed25519 node identities, anti-replay challenge verification, BLAKE3-keyed MACs, and zero-configuration local mesh beacon discovery over UDP port 8081 and TCP port 8080.
:Status: Completed
:Specification: SPEC-TECH-P2P-001
:Traced Stories: [US-REN-006], [US-GEM-001]

Milestones & Deliverables
-------------------------

* **M30.1: Cryptographic Node Identity & Role-Separated Handshake**
   - Implement Ed25519 node identities and derive ephemeral session keys via BLAKE3 key derivation.
   - Enforce single-use 32-byte cryptographic challenge nonces and role-separated domain tags (``MicrOS-P2P-v2:init``, ``MicrOS-P2P-v2:resp``).

* **M30.2: Authenticated Wire Framing & Monotonic Sequence Tracking**
   - Protect all wire envelopes with 32-byte BLAKE3-keyed MACs and verify monotonic sequence counters to eliminate wire tampering and replay attacks.

* **M30.3: LAN Mesh Beacon Discovery**
   - Broadcast 74-byte UDP discovery beacons on port 8081; parse peer identity announcements and establish point-to-point mesh connectivity.
