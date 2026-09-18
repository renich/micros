Phase 5: Sovereign Networking, Workspace & Pure Microkernel Decoupling
======================================================================

:Objective: Transition MicrOS from a standalone bare-metal node into a networked, content-addressed computational environment with zero-POSIX workspace semantics, and achieve pure microkernel minimalism by migrating network stacks, cryptographic engines, and AI services into isolated userland service actors.
:Status: Complete & Verified
:Specifications: `SPEC-TECH-NET-002`, `SPEC-TECH-NET-003`, `SPEC-TECH-FS-001`, `SPEC-TECH-AI-002`, `SPEC-TECH-LANG-003`, `SPEC-TECH-NET-004`

Milestones & Deliverables
-------------------------

* **Milestone 18b: Fast-Path TCP Server Substrate** [COMPLETE & VERIFIED]
   - Implemented stateless BLAKE3 SYN-cookies in ``src/kernel/net/tcp.zig``, mitigating SYN floods with zero pre-handshake memory allocations.
   - Implemented RFC 9293 9-state TCP server state machine, static TCB pool, 16 KiB circular RX/TX ring buffers, in-order packet dropping, and cooperative FIN/ACK teardown.
   - Exposed capability-gated network syscall ABI (``sys_net_listen``, ``sys_net_accept``, ``sys_net_recv``, ``sys_net_send``, ``sys_net_close``).
   - Authored pure Macros CAS-backed HTTP/1.1 web server actor in ``lib/macros/http_server.mx`` and integrated ``httpd`` command in ``lib/macros/msh.mx``.
   - Verified live multi-route HTTP queries from host ``curl`` under QEMU over forwarded port 8080.
   - Authored specification ``docs/technical/specs/fast-path-tcp-server.rst`` (``SPEC-TECH-NET-002``).

* **Milestone 19: Git Smart HTTP Transport & CAS Packfile Ingestion** [COMPLETE & VERIFIED]
   - Implemented Git packet-line framing parser and emitter in ``src/kernel/net/git_pkt.zig`` with 4-byte hex length prefixing.
   - Implemented Git smart HTTP discovery and report-status engine in ``src/kernel/net/git_transport.zig``.
   - Implemented freestanding zero-libc Git packfile parser and zlib decompressor in ``src/kernel/net/git_pack.zig`` using ``std.compress.flate``.
   - Implemented content-addressed Git ingestion and capability-gated syscall ABI in ``src/kernel/net/git_abi.zig``.
   - Connected Git endpoints into ``lib/macros/http_server.mx``, enabling host ``git push`` directly to running MicrOS node over port 8080.
   - Authored specification ``docs/technical/specs/git-smart-http-ingestion.rst`` (``SPEC-TECH-NET-003``).

* **Milestone 20: Sovereign Catalog Broker & Semantic Workspace Substrate** [COMPLETE & VERIFIED]
   - Implemented Merkle Workspace Manifest substrate in ``src/kernel/storage/manifest.zig`` with 128-byte fixed records and strict path sanitization.
   - Implemented Sovereign Catalog Broker in ``src/kernel/storage/catalog_abi.zig`` with Optimistic Concurrency Control (OCC) generation counters.
   - Exposed capability-gated workspace syscall ABI (``sys_catalog_write``, ``sys_catalog_read``, ``sys_catalog_list``, ``sys_catalog_delete``, ``sys_catalog_commit``, ``sys_catalog_status``).
   - Implemented stream-oriented workspace commands in ``lib/macros/msh.mx`` (``ls``, ``cat``, ``write``, ``rm``, ``commit``, ``workspace``, ``edit``).
   - Authored full-screen visual text editor actor in ``lib/macros/vedit.mx`` rendering directly to UEFI GOP framebuffer and serial console.
   - Implemented autonomous tool execution (``run <path>``) and conversational Resident AI tool synthesis (``ai <prompt>``).
   - Authored specifications ``docs/technical/specs/sovereign-workspace-catalog.rst`` (``SPEC-TECH-FS-001``) and ``docs/technical/specs/sovereign-ai-tool-synthesis.rst`` (``SPEC-TECH-AI-002``).

* **Milestone 21: Native Content-Addressed & Workspace Module System** [COMPLETE & VERIFIED]
   - Implemented ``import`` and ``export`` statements and expressions across Stage 0 (Zig) and Stage 1 (Macros) compilers, AST, lexer, and parser.
   - Added bytecode opcodes (``op_import``, ``op_export``) and runtime module resolution in ``src/macros/module.zig`` and ``src/macros/vm.zig``.
   - Implemented dual resolution semantics: direct 256-bit BLAKE3 CAS hashes (``b3/<hash>``) and workspace catalog paths with Genesis bundle fallback.
   - Enforced bounded circular dependency containment, instance deduplication, and export dict namespace encapsulation.
   - Authored specification ``docs/technical/specs/content-addressed-modules.rst`` (``SPEC-TECH-LANG-003``).

* **Milestone 22: Pure Microkernel Network & AI Decoupling** [COMPLETE & VERIFIED]
   - Implemented 4096-byte page-aligned, lock-free Single-Producer Single-Consumer (SPSC) circular ring buffers in ``src/kernel/ipc/ring.zig``.
   - Added capability primitives ``sys_frame_info`` and ``sys_irq_ack`` in ``src/kernel/cap/cap_abi.zig`` with strict W^X enforcement.
   - Decoupled VirtIO-Net 1.0, ARP, IPv4, DHCP, and TCP into isolated userland service actor ``netd`` (``src/userland/netd/netd.zig``).
   - Decoupled TLS 1.3, HTTP/1.1 REST client framing, and LLM prompt synthesis into isolated userland service actor ``aid`` (``src/userland/aid/aid.zig``).
   - Excised in-kernel networking, DHCP, DNS, TCP, TLS, and HTTP from ``src/kernel/main.zig``, reducing kernel line count from 997 to 840.
   - Authored specification ``docs/technical/specs/microkernel-network-decoupling.rst`` (``SPEC-TECH-NET-004``).
