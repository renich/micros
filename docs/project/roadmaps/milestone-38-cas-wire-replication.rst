Milestone 38: Distributed Content-Addressed Storage (CAS) Wire Replication
===========================================================================

:Objective: Implement ChunkRequest (0x0006) and ChunkEnvelope (0x0007) wire protocols over TCP port 8080, enabling transparent peer-to-peer fetch upon local CAS miss with BLAKE3 cryptographic verification.
:Status: Active Target
:Specification: SPEC-TECH-P2P-002
:Traced Stories: [US-REN-006], [US-GEM-001]

Milestones & Deliverables
-------------------------

* **M38.1: P2P Chunk Wire Protocol Framing**
   - Implement framing and parsing for ``ChunkRequest`` and ``ChunkEnvelope`` messages with 256-bit BLAKE3 hashes and zero-copy packet buffers.

* **M38.2: Transparent CAS Fallback & Remote Fetch**
   - Hook local CAS miss handlers to query connected cluster peers; stream missing chunks and verify hashes prior to disk commit.

* **M38.3: Dual-Node Cross-Replication Verification**
   - Verify live transfer of actor bytecode bundles across nodes in the virtual cluster harness.
