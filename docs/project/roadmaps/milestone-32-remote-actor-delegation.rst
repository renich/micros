Milestone 32: Cryptographic Capability Delegation & Remote Actor Compute
========================================================================

:Objective: Implement cryptographically signed, attenuated capability tokens and remote actor dispatch protocol allowing transparent compute distribution across the mesh.
:Status: Completed
:Specification: SPEC-TECH-P2P-003
:Traced Stories: [US-REN-006], [US-GEM-001]

Milestones & Deliverables
-------------------------

* **M32.1: Attenuated Network Capability Tokens**
   - Implement Ed25519-signed capability tokens with rights bitmasks, time-to-live expiration, and strict non-delegable subject bindings.

* **M32.2: Remote Actor Manifest Dispatch & Supervised Invocation**
   - Transmit actor manifests across cluster nodes in ``src/userland/p2pd/remote_actor.zig``; spawn sandboxed actor runtimes on remote nodes.

* **M32.3: Transparent Network IPC Streaming**
   - Bridge actor mailboxes across nodes, streaming typed messages and execution outcomes with bounded gas accounting.
