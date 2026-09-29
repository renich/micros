Milestone 39: Cryptographic Capability Delegation & Remote Actor Execution
==========================================================================

:Objective: Deploy 192-byte signed capability tokens with fine-grained rights attenuation, SPKI pinning for TLS, and gas-bounded remote actor dispatch across the cluster mesh.
:Status: Planned
:Specification: SPEC-TECH-P2P-003
:Traced Stories: [US-REN-006], [US-GEM-001]

Milestones & Deliverables
-------------------------

* **M39.1: 192-Byte Attenuated Capability Tokens**
   - Synthesize signed capability tokens encoding actor permissions, monotonic tick expiration, and node cryptographic fingerprints.

* **M39.2: Freestanding TLS 1.3 SPKI / Root CA Pinning**
   - Implement Subject Public Key Info (SPKI) pinning and root CA validation in freestanding Ring 0 TLS stream.

* **M39.3: Remote Actor Dispatch & Gas Accounting**
   - Dispatch actor manifests (``0x0008``) to cluster peers; monitor execution bounded by gas budgets and stream results (``0x0009``).
