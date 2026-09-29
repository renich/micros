Milestone 34: Content-Addressed Artifact Mesh & Local Registry (Package Cut Reconciled)
=======================================================================================

:Objective: Reconciled under Stage 1/2 Architecture Decisions. Centralized package managers, tarball repositories, and hierarchical package registries were CUT. The local registry service (pkgd) manages immutable Content-Addressed Storage (CAS) artifact indexing, Ed25519 author attestation, and circular dependency bounds for actor bundles without external package registries.
:Status: Completed (Reconciled with P2P Replication Cut)
:Specification: SPEC-TECH-P2P-002
:Traced Stories: [US-REN-006], [US-GEM-010]

Architecture Reconciliation & Scope
-----------------------------------

* **Package Federation Scope Cut**: Traditional package registries (npm/cargo-style repositories) contradict the sovereign content-addressed computing model. Package federation was formally cut; all artifacts are distributed as raw BLAKE3-hashed bytecode bundles over the P2P mesh (p2pd).
* **M34.1: Local Artifact Registry Actor (src/userland/pkgd/package.zig)**
   - Enforces dependency depth bounds, acyclic resolution, and catalog registration for local bytecode bundles.
* **M34.2: Cryptographic Author Signatures & Verification**
   - Implements Ed25519 author signing and provenance checks (SPK1 header verification) prior to execution.
* **M34.3: Direct CAS Storage & Replication**
   - All modules resolve directly via 256-bit BLAKE3 hashes stored in Content-Addressed Storage (CAS), eliminating mutable version manifests.
