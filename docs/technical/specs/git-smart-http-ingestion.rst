========================================================================
Git Smart HTTP Transport & Content-Addressed Ingestion Substrate (µOS)
========================================================================

:Document ID: SPEC-TECH-NET-003
:Status: Approved
:Traced Stories: [US-REN-006], [US-REN-010], [US-GEM-001], [US-GEM-009], [US-GEM-010]
:Parent Architecture: `SPEC-TECH-NET-002`, `SPEC-TECH-SYS-001`
:Module Targets: ``src/kernel/net/git_pkt.zig``, ``src/kernel/net/git_pack.zig``, ``src/kernel/net/git_transport.zig``, ``lib/macros/http_server.mx``

1. Architectural Axioms & Purpose
=================================
This specification defines the freestanding, zero-libc Git Smart HTTP transport and content-addressed ingestion engine for MicrOS (µOS). It enables human developers and autonomous AI agents on external workstations to execute standard ``git push`` operations directly to a running MicrOS node over TCP port 8080 without requiring an SSH daemon, intermediate POSIX filesystem, or external Git runtime.

1.1 The Zero-POSIX Content-Addressed Ingestion Doctrine
-------------------------------------------------------
Traditional Git servers (e.g. Gitolite, GitLab, Gitea, cgit) rely on heavy POSIX primitives: fork/exec process models, hierarchical directories (`.git/objects/??/*`), mutable ref-lock files, and filesystem inodes.

MicrOS completely rejects POSIX file hierarchies in favor of immutable BLAKE3 Content-Addressed Storage (CAS). Therefore, this specification adopts the **Direct Packfile-to-CAS Transformation Doctrine**:

* **Packet-Line Framing**: All Git control transfers strictly adhere to the Git `pkt-line` framing specification (4-byte hex length prefix, `0000` flush packet).
* **Freestanding Zlib Decompression**: Decompresses packfile object payloads entirely in memory using freestanding `std.compress.flate` with zero libc dependencies.
* **Direct Merkle Tree Mapping**: Git blobs are ingested directly into the `CasEngine` as raw blobs (`ChunkType.raw_blob`) addressed by their 256-bit BLAKE3 hashes. Git trees are decomposed into deterministic directory mappings.
* **Atomic Monotonic Branch Ref Updates**: Branch references (`refs/heads/*`) advance monotonically, storing the tip commit and corresponding CAS manifest root.
* **Autonomous Web Deployment**: Pushed repositories automatically link to the HTTP server actor (`http_server.mx`), serving committed static sites and Macros applications instantly.

1.2 The Object-Capability Security Gate
---------------------------------------
Git ingestion endpoints are strictly isolated under the MicrOS Capability Space (CSpace):

* **Capability Guard**: Network listeners handling Git traffic require `CapType.network_device` with `Rights.WRITE | Rights.READ`.
* **CAS Ingestion Guard**: Writing packfile blobs to disk requires `CapType.storage_device` with `Rights.WRITE`.
* **Repository Domain Attenuation**: Write access to specific repository paths (`/<repo>.git/`) is validated against caller actor tokens.

2. Git Smart HTTP Transport Protocol
====================================

2.1 Smart HTTP Discovery Phase
------------------------------
When an external client runs ``git push http://<host>:8080/<repo>.git master``, it initiates discovery:

1. **Client Request**:
   .. code-block:: http

      GET /<repo>.git/info/refs?service=git-receive-pack HTTP/1.1
      Host: 127.0.0.1:8080
      User-Agent: git/2.44.0
      Accept: */*

2. **Server Response**:
   .. code-block:: http

      HTTP/1.1 200 OK
      Content-Type: application/x-git-receive-pack-advertisement
      Cache-Control: no-cache
      Connection: close

      001f# service=git-receive-pack\n0000<old_sha> refs/heads/master\0report-status delete-refs side-band-64k agent=micros/0.15.0\n0000

   * For an empty/new repository, ``<old_sha>`` is 40 zeros:
     ``0000000000000000000000000000000000000000 capabilities^{}\0report-status delete-refs side-band-64k agent=micros/0.15.0\n``.

2.2 Receive-Pack Ingestion Phase
--------------------------------
The client transmits the commit command and the packfile payload:

1. **Client Request**:
   .. code-block:: http

      POST /<repo>.git/git-receive-pack HTTP/1.1
      Host: 127.0.0.1:8080
      Content-Type: application/x-git-receive-pack-request
      Accept: application/x-git-receive-pack-result

      0098<old_sha> <new_sha> refs/heads/master\0report-status side-band-64k agent=git/2.44.0\n0000PACK[version 2][objects...][SHA-1 checksum]

2. **Server Response**:
   Upon verifying the packfile and storing blobs into CAS, the server confirms via standard Git `report-status`:
   .. code-block:: http

      HTTP/1.1 200 OK
      Content-Type: application/x-git-receive-pack-result
      Cache-Control: no-cache
      Connection: close

      000eunpack ok\n0019ok refs/heads/master\n0000

3. Git Packfile Binary Architecture
===================================
A Git packfile stream begins with a 12-byte header:

.. code-block:: zig

   pub const PackHeader = extern struct {
       magic: u32 = 0x5041434B, // "PACK" in big-endian
       version: u32 = 2,        // Version 2 in big-endian
       object_count: u32,       // Number of objects in big-endian
   };

3.1 Variable-Length Object Header
---------------------------------
Each object starts with a variable-length byte sequence encoding the type and uncompressed size:

* **First Byte**:
  - Bit 7 (MSB): Continuation flag (1 = more size bytes follow).
  - Bits 4..6: Object Type:
    - ``OBJ_COMMIT = 1``
    - ``OBJ_TREE = 2``
    - ``OBJ_BLOB = 3``
    - ``OBJ_TAG = 4``
    - ``OBJ_OFS_DELTA = 6``
    - ``OBJ_REF_DELTA = 7``
  - Bits 0..3: Least significant 4 bits of the uncompressed size.
* **Subsequent Bytes**:
  - Bit 7: Continuation flag.
  - Bits 0..6: Next 7 bits of uncompressed size.

3.2 Object Decompression & CAS Translation
------------------------------------------
Following the variable-length header, the compressed data is extracted using ``std.compress.flate.Decompress``:

1. Decompress into an aligned buffer in kernel memory.
2. If ``type == OBJ_BLOB``:
   - Compute 256-bit BLAKE3 hash of uncompressed blob.
   - Insert blob into CAS via ``CasEngine.putChunk(.raw_blob, payload)``.
3. If ``type == OBJ_TREE``:
   - Parse mode, filename, and object hash entries.
   - Map tree structure into a deterministic CAS Merkle Manifest.
4. If ``type == OBJ_COMMIT``:
   - Parse commit tree hash, parent commit, author, committer, and commit message.
   - Update branch reference table.

4. Sovereign Syscall ABI Extensions
===================================
To allow userspace actors (such as ``http_server.mx``) to manage Git endpoints, the kernel exposes Git transport bindings in ``src/kernel/net/git_abi.zig``:

1. ``sys_git_advertise_refs(repo_name: string, out_buf: buffer) -> Value``
   * Generates valid Git `pkt-line` capability advertisement payload for ``GET /info/refs``.
2. ``sys_git_receive_pack(repo_name: string, payload: string) -> Value``
   * Parses the `git-receive-pack` request, extracts objects into CAS, advances branch ref, and emits the report-status string.
3. ``sys_git_get_head(repo_name: string) -> Value``
   * Returns current branch tip commit and associated CAS root hash.
4. ``sys_git_cat_file(repo_name: string, path: string) -> Value``
   * Retrieves content of a tracked file from the latest committed tree directly from CAS.

5. Verification & Traceability Matrix
=====================================

5.1 Test Matrix
---------------
* **Unit Tests** (``src/kernel/net/git_pkt.zig``):
  - Validates pkt-line hex framing, flush packets, delimiter packets, and capability extraction.
* **Unit Tests** (``src/kernel/net/git_pack.zig``):
  - Validates `PACK` header parsing, variable-length MSB type/size decoding, and zlib payload decompression.
* **Unit Tests** (``src/kernel/net/git_transport.zig``):
  - Validates advertisement generation and report-status framing.
* **Integration & QEMU Validation**:
  - Live execution of `git push http://127.0.0.1:8080/repo.git master` from host Fedora terminal to MicrOS guest in QEMU.
  - Verification that pushed `index.html` is instantly served via `http://127.0.0.1:8080/`.

5.2 Traceability Mapping
------------------------
* ``[US-REN-006]``: Zero-POSIX immutable Content-Addressed Storage backed by BLAKE3 hashes.
* ``[US-REN-010]``: Non-blocking network streaming within cooperative green-thread fibers.
* ``[US-GEM-001]``: Structured machine autonomy and programmatic software deployment.
* ``[US-GEM-009]``: Self-healing userspace actor execution and live service updates.
* ``[US-GEM-010]``: Context-window-optimized module boundaries (files $\le 1,000$ lines).
