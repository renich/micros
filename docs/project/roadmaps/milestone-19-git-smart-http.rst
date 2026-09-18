Milestone 19: Git Smart HTTP Transport & CAS Packfile Ingestion
==============================================================

:Objective: Implement a freestanding, zero-libc Git Smart HTTP transport and content-addressed ingestion engine for MicrOS (µOS). Enable standard ``git push`` operations directly from external developer workstations over TCP port 8080 into running MicrOS nodes without SSH daemons, POSIX filesystems, or external Git runtimes.
:Status: Complete & Verified
:Specification: SPEC-TECH-NET-003

Milestones & Deliverables
-------------------------

* **M19.1: Git Packet-Line Protocol Framing** [COMPLETE & VERIFIED]
   - Implemented ``writePktLine``, ``writeFlush``, ``writeDelim``, ``parsePktLine``, and ``parsePushCommand`` in ``src/kernel/net/git_pkt.zig``.
   - Complies strictly with Git pkt-line protocol (4-byte hex length prefixing, ``0000`` flush packet, zero-copy payload slicing).

* **M19.2: Smart HTTP Advertisement & Report-Status Engine** [COMPLETE & VERIFIED]
   - Implemented ``buildAdvertisementBody`` and ``buildReportStatusBody`` in ``src/kernel/net/git_transport.zig``.
   - Advertised capabilities (``report-status``, ``delete-refs``) and generated compliant pack status reports confirming branch reference updates.

* **M19.3: Freestanding Zero-Libc Git Packfile Parser & Decompressor** [COMPLETE & VERIFIED]
   - Implemented ``parsePackHeader``, variable-length MSB object header decoding, and object decompression in ``src/kernel/net/git_pack.zig`` using freestanding ``std.compress.flate`` (``.zlib``).
   - Decompresses commit, tree, and blob objects in memory without temporary files or host libc dependencies.

* **M19.4: Content-Addressed Git Ingestion & Syscall ABI** [COMPLETE & VERIFIED]
   - Implemented ``src/kernel/net/git_abi.zig`` resolving commit tree structures and ingesting Git blob payloads into ``CasEngine`` under 256-bit BLAKE3 hashes.
   - Advanced repository branch tips monotonically via atomic reference updates.
   - Exposed capability-gated syscalls: ``sys_git_advertise_refs``, ``sys_git_receive_pack``, ``sys_git_get_head``, and ``sys_git_cat_file``.

* **M19.5: Autonomous Macros HTTP Server Git Endpoint & Live Push Verification** [COMPLETE & VERIFIED]
   - Expanded ``lib/macros/http_server.mx`` with Git endpoint routing (``GET /<repo>.git/info/refs``, ``POST /<repo>.git/git-receive-pack``).
   - Served committed web assets (such as ``index.html``) directly from CAS upon push completion.
   - Verified live host workstation ``git push http://127.0.0.1:8080/site.git master`` and verified instant live HTTP serving of pushed web content under QEMU UEFI.
