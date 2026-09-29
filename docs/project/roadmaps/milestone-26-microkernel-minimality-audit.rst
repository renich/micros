Milestone 26: Formal Microkernel Minimality Audit & Silicon Validation
======================================================================

:Objective: Formally audit the architectural composition and boundary of the Ring 0 microkernel core (21,103 LOC), establish the Strict Ring 0 Freeze containment rule via Architecture Decision Record, and validate complete system stability on physical bare-metal x86_64 silicon and UEFI harnesses.
:Status: Completed
:Specification: SPEC-TECH-MIN-001
:Decision Record: docs/project/audits/2026-09-28-kernel-boundary-and-daemon-residency.rst
:Traced Stories: [US-REN-004], [US-REN-006], [US-REN-007], [US-REN-008], [US-GEM-001], [US-GEM-007], [US-GEM-010]

Milestones & Deliverables
-------------------------

* **M26.1: Ring 0 Architectural Composition Audit & Containment Rule**
   - Formally measure and document the Ring 0 kernel composition (21,103 LOC across net, storage, drivers, ai, compositor, arch, mem, cap, ipc, sched).
   - Author Architecture Decision Record (``docs/project/audits/2026-09-28-kernel-boundary-and-daemon-residency.rst``) documenting the rationale for monolithic substrate bringup and codifying the **Strict Ring 0 Freeze** containment rule.
   - Clarify daemon-residency truth for all 6 daemons (``netd``, ``storaged``, ``gopd``, ``p2pd``, ``pkgd``, ``aid``).
   - Defer physical out-of-process driver/stack excision and the seL4-class < 2,000 LOC mechanism-only microkernel target to Milestone 41.

* **M26.2: Capability Security Gate Audit**
   - Run automated capability attenuation test suite verifying that no userland actor or service daemon can escalate privileges or access unmapped physical frames.
   - Verify that corrupted or compromised device drivers cannot violate kernel integrity.

* **M26.3: Physical Bare-Metal Hardware Silicon Validation**
   - Deploy bootable UEFI disk images directly to physical NVMe SSDs on bare-metal test machines (Intel Core/Xeon and AMD Ryzen hardware).
   - Validate multicore APIC bringup across 4+ physical CPU cores.
   - Validate live storage I/O, network packet transmission over physical Ethernet, and GOP display output on real silicon with zero QEMU virtualization crutches.
