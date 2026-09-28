Phase 10: Operational Hardening, Pure Microkernel Handoff & Virtual Cluster Mesh
================================================================================

:Objective: Transition the MicrOS runtime from isolated capability foundations into a hardened, production-grade microkernel environment under QEMU/KVM: ensuring all six userland service daemons (gopd, storaged, netd, aid, p2pd, pkgd) fully mediate system execution over typed IPC rings, deploying live multi-node peer-to-peer cluster meshes, and proving resilient self-healing and zero-trust security.
:Status: In Progress
:Specifications: `SPEC-TECH-CAP-002`, `SPEC-TECH-P2P-001`, `SPEC-TECH-P2P-002`, `SPEC-TECH-P2P-003`, `SPEC-TECH-MIN-001`
:Critical Path: M36 -> M37 -> M38 -> M39 -> M40

Milestones & Deliverables
-------------------------

* **Milestone 36: Full Userland Service Daemon Integration & Startup Handoff** [COMPLETE & VERIFIED]
   - **Service Daemon Fleet**: Integrated ``gopd``, ``storaged``, ``netd``, ``aid``, ``p2pd``, and ``pkgd`` into unified kernel boot sequencing and CSpace table initialization.
   - **Pure Userland I/O Mediation**: Mediated frame rendering, disk transfers, packet frames, AI inferences, P2P messages, and package queries strictly across zero-copy SPSC/MPSC IPC rings.
   - **Shell Telemetry & Daemon Observability**: Exposed real-time daemon state, memory usage, and ring throughput metrics via ``msh`` and ``harness`` commands (``status``, ``actors``, ``peers``, ``pkg``).
   - **Blocked By**: Phase 9 completion.
   - **Unblocks**: M37, M38.

* **Milestone 37: Virtual Multi-Node P2P Cluster Mesh Wire Discovery** [COMPLETE & VERIFIED]
   - **Dual-Node QEMU Harness**: Built automated multi-instance QEMU orchestration (``tools/micros-cluster.bash``, ``make qemu-cluster``, ``make qemu-cluster-verify``) interconnecting independent virtual machines over a point-to-point TCP stream socket (``127.0.0.1:12345``) requiring zero host root privileges.
   - **Live Wire Beacon Discovery**: Verified zero-configuration 74-byte UDP broadcast beacon discovery (port 8081, ``255.255.255.255``) with link-local IP resolution and Ed25519 node identity exchange.
   - **Capability-Gated P2P Syscalls**: Delivered ``sys_peer_count()``, ``sys_peer_info()``, and ``sys_p2p_status()`` strictly guarded by ``CapType.network_device`` (``Rights.READ``).
   - **Shell Integration**: Integrated dynamic ``peers`` and ``status`` cluster inspection in ``lib/macros/msh.mx`` and the boot Genesis image.
   - **Blocked By**: M36.
   - **Unblocks**: M38.

* **Milestone 38: Distributed Content-Addressed Storage (CAS) Wire Replication** [ACTIVE TARGET]
   - **Wire Protocol Replication Primitives**: Wire ``ChunkRequest`` (``0x0006``) and ``ChunkEnvelope`` (``0x0007``) over TCP port 8080 using freestanding BLAKE3 verification and zero libc linkage.
   - **Cluster-Wide CAS Fetch**: Enable transparent remote chunk fetching when local storage encounters a CAS miss, verifying 256-bit BLAKE3 hashes prior to disk commitment.
   - **Dual-Node Mesh Verification**: Validate live cross-node object replication (actor bytecode and data chunks) across the dual-node QEMU cluster harness.
   - **Blocked By**: M37.
   - **Unblocks**: M39.

* **Milestone 39: Cryptographic Capability Delegation & Remote Actor Execution** [PLANNED]
   - **192-Byte Attenuated Capability Tokens**: Implement Ed25519-signed capability tokens with rights bitmasks (CAS read/write, actor spawn/supervise), monotonic tick expirations, and non-delegable subject bindings.
   - **Remote Actor Dispatch & Result Streaming**: Enable nodes to dispatch actor manifests (``0x0008``) to cluster peers and receive execution results (``0x0009``) bounded by strict gas budgets.
   - **Blocked By**: M38.
   - **Unblocks**: M40.

* **Milestone 40: Zero-Trust System Hardening, Self-Healing & Polish** [PLANNED]
   - **IPC & Wire Fuzzing Resilience**: Subject SPSC/MPSC rings and P2P wire decoders to malformed packet streams; mathematically verify zero Ring 0 panic leaks and invariant preservation.
   - **Actor Crash Containment & Supervised Restart**: Prove supervisory restart in ``init.mx`` when userland services or application shells fault, restoring state seamlessly from CAS.
   - **Interactive Studio Polish**: Refine prompt UX, multi-conversation ergonomics, and terminal ANSI rendering in ``harness.mx`` and ``msh.mx``.
   - **Blocked By**: M39.
   - **Unblocks**: Production deployment readiness.
