============================================================
Sovereign Package & Module Federation Registry (SPEC-TECH-PKG-001)
============================================================

:Document ID: SPEC-TECH-PKG-001
:Status: Approved
:Traced Stories: [US-REN-002], [US-REN-004], [US-REN-006], [US-GEM-001], [US-GEM-010]

1. Architectural Axioms & Purpose
=================================
This specification formalizes the **Sovereign Package & Module Federation Subsystem** for MicrOS (µOS). Operating within userland (``pkgd``) across the peer-to-peer storage mesh (``p2pd`` / ``cas``), this registry enables packaging, cryptographically signing, discovering, and resolving software modules without centralized package repositories (npm, cargo, PyPI) or corporate certificate authorities.

1.1 Cryptographic Identity & Decentralized Packaging
----------------------------------------------------
All packages in MicrOS are self-authenticating, immutable content-addressed bundles:
* **Ed25519 Author Signatures**: Package manifests are signed directly by the package author's Ed25519 secret key. The author's identity is verified by comparing the signature against their public key.
* **Content-Addressed Immutability**: The package contents (source code, compiled bytecode chunks, assets) are addressed via a 256-bit BLAKE3 manifest hash. Any tampering invalidates both the hash and signature.
* **Deterministic Dependency Resolution**: The package registry resolves dependency DAGs topologically, detecting recursive cycles and calculating linear initialization orders without external servers.

2. Binary Package Header Layout
===============================

2.1 Sovereign Package Header (PackageHeader)
--------------------------------------------
The package envelope begins with a fixed 512-byte (sector-aligned) binary header:

.. code-block:: zig

   pub const PACKAGE_MAGIC: u32 = 0x53504B31; // 'SPK1'
   pub const MAX_PACKAGE_NAME: usize = 48;
   pub const MAX_VERSION_STR: usize = 16;
   pub const MAX_DEPENDENCIES: usize = 8;

   pub const PackageHeader = extern struct {
       magic: u32 align(1),
       version: u16 align(1),
       flags: u16 align(1),
       name_len: u16 align(1),
       name: [MAX_PACKAGE_NAME]u8 align(1),
       semver_len: u16 align(1),
       semver: [MAX_VERSION_STR]u8 align(1),
       author_pubkey: [32]u8 align(1),
       manifest_hash: [32]u8 align(1),
       required_capabilities: u64 align(1),
       timestamp_epoch: u64 align(1),
       dependency_count: u32 align(1),
       dependencies: [MAX_DEPENDENCIES][32]u8 align(1),
       signature: [64]u8 align(1),
       padding: [32]u8 align(1) = [_]u8{0} ** 32,
   };

2.2 Verification & Integrity Proof
----------------------------------
1. **Magic & ABI Check**: Header must begin with ``PACKAGE_MAGIC`` (``0x53504B31``).
2. **Payload Hash Check**: The package body (MCB or CAS chunks) must hash to ``manifest_hash`` via BLAKE3.
3. **Signature Verification**: The signature over header bytes 0..220 must verify against ``author_pubkey``.

3. Dependency Graph Resolution
==============================

3.1 Topological Sort & Cycle Detection
--------------------------------------
The registry manager (``PackageManager``) maintains an in-memory database of registered packages and resolves dependencies:
* **Cycle Prevention**: Traverses dependency edges using depth-first search with ancestor cycle detection, rejecting circular dependencies with ``error.CircularDependency``.
* **Linear Load Order**: Produces a topologically sorted sequence of package indices ensuring dependencies are loaded strictly before dependents.
* **Capability Bound Auditing**: Aggregates total capabilities required across all dependencies to verify conformance against actor sandbox policies.

4. Verification & Traceability Matrix
=====================================

.. list-table::
   :widths: 20 25 55
   :header-rows: 1

   * - Requirement ID
     - Traced Story
     - Verification Method
   * - REQ-PKG-001
     - [US-REN-002]
     - Native Macros module loading and execution from verified packages.
   * - REQ-PKG-002
     - [US-REN-004]
     - Zero-libc Ed25519 package signature signing, serialization, and verification.
   * - REQ-PKG-003
     - [US-REN-006]
     - Capability-bounded package execution rejecting unauthorized syscall escalation.
   * - REQ-PKG-004
     - [US-GEM-001]
     - Real-time package install, resolve, and error telemetry emission.
   * - REQ-PKG-005
     - [US-GEM-010]
     - Modular architecture under 1,000 LOC per file with bounded function complexity.
