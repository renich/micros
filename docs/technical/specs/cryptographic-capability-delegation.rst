============================================================
Cryptographic Capability Delegation & Remote Actor Compute (SPEC-TECH-P2P-003)
============================================================

:Document ID: SPEC-TECH-P2P-003
:Status: Approved
:Traced Stories: [US-REN-004], [US-REN-006], [US-REN-010], [US-GEM-001], [US-GEM-010]

1. Architectural Axioms & Purpose
=================================
This specification formalizes the **Cryptographic Capability Delegation & Remote Actor Compute Subsystem** for MicrOS (µOS). Operating within the sovereign P2P networking substrate (``p2pd``), this protocol extends local microkernel CSpace capability security across node boundaries via Ed25519-signed, attenuated capability tokens, enabling secure distributed compute and remote actor supervision without central coordinators.

1.1 Principle of Least Privilege across Network Boundaries
----------------------------------------------------------
In MicrOS, raw network access grants zero ambient authority to invoke operations on remote nodes:
* **Attenuated Capability Tokens**: Every remote actor invocation, CAS read/write, or compute task requires an explicit, cryptographically signed capability token.
* **Monotonic Expiration**: Tokens enforce strict, monotonically advancing expiration deadlines measured in timer ticks. Expired tokens are rejected at the wire boundary before processing.
* **Non-Delegable Identity Verification**: Tokens can bind explicitly to a subject NodeId. A token intercepted by a malicious intermediary cannot be replayed or used from an unauthorized node.

2. Binary Capability Token Layout
=================================

2.1 CapabilityToken Structure
-----------------------------
The capability token occupies a fixed 192-byte binary layout:

.. code-block:: zig

   pub const CapabilityToken = extern struct {
       issuer_id: [32]u8 align(1),
       subject_id: [32]u8 align(1),
       rights: u64 align(1),
       resource_hash: [32]u8 align(1),
       issued_at_ticks: u64 align(1),
       expires_at_ticks: u64 align(1),
       nonce: u64 align(1),
       signature: [64]u8 align(1),
   };

2.2 Rights Bitmask
------------------
Rights are represented as bit flags in the 64-bit ``rights`` field:
* ``RIGHT_READ_CAS`` (0x01): Authorizes reading CAS objects matching ``resource_hash`` (or all if wildcard).
* ``RIGHT_WRITE_CAS`` (0x02): Authorizes writing new CAS objects to node storage.
* ``RIGHT_SPAWN_ACTOR`` (0x04): Authorizes dispatching and spawning an actor from a CAS manifest.
* ``RIGHT_SUPERVISE_ACTOR`` (0x08): Authorizes querying actor status, sending IPC signals, and terminating.
* ``RIGHT_DELEGATE`` (0x10): Authorizes generating attenuated child tokens.

3. Remote Actor Dispatch & Supervised Execution
===============================================

3.1 Dispatch Envelope Layout
----------------------------
Remote actor dispatch commands transmit the capability token alongside the target manifest:

.. code-block:: zig

   pub const RemoteActorDispatch = extern struct {
       token: CapabilityToken align(1),
       manifest_hash: [32]u8 align(1),
       actor_id: u32 align(1),
       memory_limit_pages: u32 align(1),
   };

   pub const RemoteActorResult = extern struct {
       actor_id: u32 align(1),
       exit_code: u32 align(1),
       output_hash: [32]u8 align(1),
       execution_ticks: u64 align(1),
   };

3.2 Verification Lifecycle
--------------------------
1. **Token Signature Verification**: The receiver extracts ``token.issuer_id``, looks up the peer public key, and verifies the Ed25519 signature over token fields 0..112.
2. **Temporal & Subject Check**: Receiver verifies ``current_ticks <= token.expires_at_ticks`` and ``(token.subject_id == 0 or token.subject_id == receiver_id)``.
3. **Rights & Isolation**: The receiver verifies ``token.rights`` contains ``RIGHT_SPAWN_ACTOR``. The actor is allocated an isolated address space bounded by ``memory_limit_pages``.
4. **Execution & Result**: Upon actor termination, the supervisor emits a ``RemoteActorResult`` packet back to the invoking node over the P2P connection.

4. Verification & Traceability Matrix
=====================================

.. list-table::
   :widths: 20 25 55
   :header-rows: 1

   * - Requirement ID
     - Traced Story
     - Verification Method
   * - REQ-REM-001
     - [US-REN-004]
     - Zero-libc Ed25519 capability token signing and verification.
   * - REQ-REM-002
     - [US-REN-006]
     - Capability-bounded remote actor dispatch rejecting unauthenticated tokens.
   * - REQ-REM-003
     - [US-REN-010]
     - Non-blocking remote actor dispatch and supervision in green-thread fibers.
   * - REQ-REM-004
     - [US-GEM-001]
     - Real-time remote actor execution telemetry emitted over binary rings.
   * - REQ-REM-005
     - [US-GEM-010]
     - Modular architecture under 1,000 LOC per file with bounded function complexity.
