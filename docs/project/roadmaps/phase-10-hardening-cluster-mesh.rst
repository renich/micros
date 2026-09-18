Phase 10: Operational Hardening, Pure Microkernel Handoff & Virtual Cluster Mesh
================================================================================

:Objective: Transition the MicrOS runtime from isolated capability foundations into a hardened, production-grade microkernel environment under QEMU/KVM: ensuring all six userland service daemons (gopd, storaged, netd, aid, p2pd, pkgd) fully mediate system execution over typed IPC rings, deploying live multi-node peer-to-peer cluster meshes, and proving resilient self-healing and zero-trust security.
:Status: In Progress
:Specifications: `SPEC-TECH-CAP-002`, `SPEC-TECH-P2P-001`, `SPEC-TECH-P2P-002`, `SPEC-TECH-MIN-001`
:Critical Path: M36 -> M37 -> M38

Milestones & Deliverables
-------------------------

* **Milestone 36: Full Userland Service Daemon Integration & Startup Handoff** [IN PROGRESS]
   - **Service Daemon Fleet**: Integrate ``gopd``, ``storaged``, ``netd``, ``aid``, ``p2pd``, and ``pkgd`` into unified kernel boot sequencing and CSpace table initialization.
   - **Pure Userland I/O Mediation**: Mediate all frame rendering, disk transfers, packet frames, AI inferences, P2P messages, and package queries strictly across zero-copy SPSC/MPSC IPC rings.
   - **Shell Telemetry & Daemon Observability**: Expose real-time daemon state, memory usage, and ring throughput metrics via ``msh`` and ``harness`` commands (``status``, ``actors``, ``peers``, ``pkg``).
   - **Blocked By**: Phase 9 completion.
   - **Unblocks**: M37, M38.

* **Milestone 37: Virtual Multi-Node P2P Cluster Mesh under QEMU** [PLANNED]
   - **Dual-Node QEMU Harness**: Build automated multi-instance QEMU orchestration (``tools/micros-cluster.bash``, ``make qemu-cluster``) interconnecting independent virtual machines over a shared private network.
   - **Live Peer Discovery & Noise Handshake**: Verify zero-configuration UDP beacon discovery, Ed25519 node identity exchange, and mutual authentication across running nodes.
   - **Distributed CAS Replication & Remote Actor Dispatch**: Demonstrate live 256-bit BLAKE3 chunk sync over port 8080 and remote actor execution with attenuated capability tokens.
   - **Blocked By**: M36.
   - **Unblocks**: M38.

* **Milestone 38: Zero-Trust System Hardening, Self-Healing & Polish** [PLANNED]
   - **IPC & Wire Fuzzing Resilience**: Subject SPSC/MPSC rings and P2P wire decoders to malformed packet streams; mathematically verify zero Ring 0 panic leaks and invariant preservation.
   - **Actor Crash Containment & Supervised Restart**: Prove supervisory restart in ``init.mx`` when userland services or application shells fault, restoring state seamlessly from CAS.
   - **Interactive Studio Polish**: Refine prompt UX, multi-conversation ergonomics, and terminal ANSI rendering in ``harness.mx`` and ``msh.mx``.
   - **Blocked By**: M37.
   - **Unblocks**: Production deployment readiness.
