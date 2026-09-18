=========
Changelog
=========

All notable changes to this project will be documented in this file.

The format is based on `Keep a Changelog <https://keepachangelog.com/en/1.1.0/>`_,
and this project adheres to `Semantic Versioning <https://semver.org/spec/v2.0.0.html>`_.
[Unreleased]
============

- **Milestone 24 (Pure Microkernel Compositor & Input Decoupling - SPEC-TECH-COMPOSITOR-002)**:
  - **Isolated Userland Display Server Actor (gopd)**: Implemented freestanding ``GopDaemon`` in ``src/userland/gopd/gopd.zig`` managing direct UEFI GOP framebuffer surfaces, double buffering, presentation, and window manager coordination in userland.
  - **CSpace Capability-Gated Framebuffer Access**: Enforced ``CapType.framebuffer`` capability tokens with ``READ|WRITE`` permissions for mapped framebuffer spans, eliminating raw physical memory access from userland actors.
  - **Decoupled Asynchronous PS/2 Input Decoding**: Implemented non-blocking PS/2 keyboard and mouse packet decoding in ``gopd``, arbitration of window focus, cursor displacement clamping, and event generation over SPSC IPC ring buffers.
  - **Damage Tracking & Zero-Copy Presentation**: Engineered axis-aligned bounding box (AABB) dirty rectangle tracking to restrict frame copies strictly to modified pixel regions, minimizing memory bus bandwidth.
  - **Memory Safety & Stack Optimization**: Refactored ``NetDaemon`` in ``src/userland/netd/netd.zig`` to use heap-allocated pointers for 320 KiB network stack states, preventing kernel stack overflow during boot.
  - **Live Bare-Metal & QEMU UEFI Boot Verification**: Verified ``[  ok  ] gopd: Userland display server actor active (1280x800x32)`` and MicroShell interactive prompt under QEMU UEFI boot with 100% passage across 329 unit tests and zero lint violations.

- **Milestone 23b (Preemptive Symmetric Multiprocessing (SMP) & APIC Timer Substrate - SPEC-TECH-SMP-001)**:
  - **Local APIC & Calibrated 1000Hz Preemption Timer**: Implemented freestanding x86_64 Local APIC driver in ``src/kernel/arch/x86_64/apic.zig`` supporting memory-mapped I/O access, Spurious Interrupt Vector Register (SIVR) software enablement, Task Priority Register (TPR) masking, End-Of-Interrupt (EOI) signaling, and periodic timer configuration on IDT vector 32 (0x20) with a calibrated 1ms preemption quantum.
  - **Preemptive Interrupt Gate & IDT Vector 32**: Wired IDT gate 32 (0x20) in ``src/kernel/arch/x86_64/idt.zig`` with naked assembly trampoline (``apicTimerInterruptHandler``) saving and restoring all caller-saved registers, maintaining 16-byte stack alignment, and executing ``apicTimerHandlerZig`` to trigger per-core quantum decrement and scheduler preemption without cooperative starvation.
  - **Lock-Free Multi-Producer Single-Consumer (MPSC) Ring Buffer**: Engineered bounded lock-free ``MpscRingBuffer`` in ``src/kernel/ipc/ring.zig`` utilizing Vyukov sequence slots, ticket reservation via atomic compare-and-swap, 64-byte cacheline separation to eradicate false sharing, and acquire/release memory semantics for concurrent multi-core IPC submission.
  - **SMP Topology & Work-Stealing Preemptive Scheduler**: Implemented multi-core topology state machine in ``src/kernel/sched/smp.zig`` managing per-core execution queues, Bootstrap Processor (BSP) initialization, APIC INIT-SIPI-SIPI secondary core bringup sequencing, round-robin timeslice enforcement, and bounded lock-free work-stealing from overloaded peer cores.
  - **Verification**: Added colocated unit tests across APIC, SMP, IDT, and MPSC ring buffer modules, bringing the test suite to 324/324 passing green tests, verified 100% bidirectional specification traceability against ``SPEC-TECH-SMP-001``, and validated live QEMU UEFI boot.

- **Milestone 23a (Hardware Ring 3 Privilege Isolation & Fast Syscall Substrate - SPEC-TECH-CAP-002)**:
  - **Task State Segment (TSS) & Hardware Privilege Rings**: Implemented 104-byte ``TaskStateSegment`` and 16-byte ``TssDescriptor`` in ``src/kernel/arch/x86_64/gdt.zig``, expanded GDT with Ring 3 user code/data descriptors (0x18, 0x20, 0x28) and TSS descriptor (0x30), and executed ``ltr`` instruction.
  - **Fast Syscall ABI (LSTAR/STAR)**: Implemented freestanding x86_64 fast syscall substrate in ``src/kernel/arch/x86_64/syscall.zig`` configuring ``IA32_EFER.SCE``, ``IA32_STAR``, ``IA32_LSTAR``, ``IA32_SFMASK``, and ``IA32_KERNEL_GS_BASE`` with unforgeable stack isolation and atomic ``swapgs``.
  - **Per-Actor 4-Level CR3 Virtual Address Spaces**: Implemented per-actor PML4 directory creation, lower-half userland address isolation (0x0000_0000_0000_0000..0x0000_7FFF_FFFF_FFFF), upper-half microkernel cloning (0xFFFF_8000_0000_0000..0xFFFF_FFFF_FFFF_FFFF) with Supervisor bit protection, page unmapping, and TLB invalidation (``invlpg``) in ``src/kernel/mem/vmm.zig``.
  - **Capability-Gated Syscall Dispatcher**: Connected ``kernelSyscallDispatch`` directly to caller CSpace capabilities, enforcing capability tokens for actor management (``actor_control``), memory mapping (``memory_extent``), device DMA frames (``network_device``, ``storage_device``), and hardware interrupt handling (``irq_endpoint``) with zero ambient authority.
  - **PMM Reclamation & Lifecycle Hooks**: Added ``page_table_destructor`` to ``ActorRegistry`` in ``src/kernel/actor.zig`` ensuring actor virtual address space page tables are automatically reclaimed by the PMM upon termination without page frame leaks.
  - **Verification**: Added colocated unit tests across VMM and Syscall modules, bringing test suite to 316/316 passing green tests, verified 100% bidirectional specification traceability, and validated live QEMU UEFI boot.

- **Milestone 22 (Pure Microkernel Network & AI Decoupling - SPEC-TECH-NET-004)**:
  - **Lock-Free Page-Aligned SPSC Ring Buffer IPC**: Implemented ``SpscRingBuffer`` in ``src/kernel/ipc/ring.zig`` with 4096-byte page alignment (``align(4096)``), 64-byte cacheline separation, and acquire/release memory fences for high-throughput zero-copy streaming between kernel and userland service actors.
  - **Hardware Capability Primitives & W^X Enforcement**: Added ``sys_frame_info`` in ``src/kernel/cap/cap_abi.zig`` providing physical DMA frame mapping under strict capability validation, and ``sys_irq_ack`` for safe interrupt line acknowledgment without ambient authority.
  - **Isolated Userland Network Daemon (netd)**: Implemented ``NetDaemon`` in ``src/userland/netd/netd.zig``, managing VirtIO-Net 1.0 device rings, ARP cache, IPv4 addressing, DHCP negotiation, and TCP connection state machines in Ring 3.
  - **Isolated Userland AI Daemon (aid)**: Implemented ``AiDaemon`` in ``src/userland/aid/aid.zig``, encapsulating freestanding TLS 1.3 key exchange, symmetric ciphersuites, HTTP/1.1 REST client framing, and LLM prompt serialization in userspace.
  - **Ring 0 Kernel De-bloat**: Excised all monolithic in-kernel networking, DHCP, DNS, TCP, TLS, and HTTP code from ``src/kernel/main.zig``, reducing kernel line count from 997 to 840 lines (strictly complying with the 1,000-line Sovereign Commandment ceiling).
  - **Live Bare-Metal Verification**: Added colocated unit tests across ``src/userland/netd/``, ``src/userland/aid/``, and ``src/kernel/cap/`` with 308/308 passing tests, and verified live bare-metal UEFI boot in QEMU with flawless device discovery.

- **Milestone 21 (Native Content-Addressed & Workspace Module System - SPEC-TECH-LANG-003)**:
  - **Module Syntax & Bytecode Opcodes**: Implemented ``import`` statements, ``import`` expressions, and ``export`` declarations across AST, lexer, and parser in ``src/macros/compiler.zig`` and ``lib/macros/``, introducing ``op_import`` and ``op_export`` bytecode opcodes in ``src/macros/chunk.zig``.
  - **Dual-Mode Module Resolver**: Implemented ``ModuleResolver`` in ``src/macros/module.zig`` supporting direct Content-Addressed Storage hashes (``import "b3/<hash>"``) and semantic Workspace Catalog paths (``import "math.mx"``) with Genesis Bundle fallback.
  - **Deterministic Scope Encapsulation**: Packaged module exports into sealed, immutable dictionary objects, eliminating global namespace pollution and supporting property access (``m.property``) and dynamic function invocation (``m.calculate()``).
  - **Bounded Cycle Containment & Deduplication**: Engineered module lifecycle state machine (``compiling``, ``ready``) to detect and halt circular dependency recursion deterministically, with an instance deduplication cache by BLAKE3 hash.
  - **Genesis Bundle & Stage 1 Synchronization**: Updated pure Macros self-hosting compiler in ``lib/macros/`` and updated ``src/kernel/genesis.mcb`` with 301/301 unit tests passing green.

- **Milestone 20 (Sovereign Catalog Broker & Semantic Workspace Substrate - SPEC-TECH-FS-001)**:
  - **Zero-POSIX Merkle Workspace Manifests**: Implemented ``src/kernel/storage/manifest.zig`` with 128-byte fixed-size ``WorkspaceEntry`` records, single-pass path sanitization (rejecting ``..``, ``\``, ``//``, and control chars), strict lexicographical sorting, $O(\log N)$ binary search, and alignment-safe serialization into ``ChunkType.workspace_manifest`` (type 6) chunks.
  - **Sovereign Catalog Broker & OCC Commit Protocol**: Implemented ``src/kernel/storage/catalog_abi.zig`` managing workspace staging states, persisting file content as raw BLAKE3 chunks in CAS, advancing manifest roots monotonically via Optimistic Concurrency Control, and preventing multi-actor split-brain corruption without blocking filesystem locks.
  - **Capability-Gated Workspace Syscall ABI**: Exposed 6 native syscalls (``sys_catalog_write``, ``sys_catalog_read``, ``sys_catalog_list``, ``sys_catalog_delete``, ``sys_catalog_commit``, ``sys_catalog_status``) in ``src/kernel/abi.zig`` gated strictly by ``CapType.storage_device`` in the caller's CSpace.
  - **MicroShell Workspace Interaction Primitives**: Extended ``lib/macros/msh.mx`` with stream-oriented workspace commands (``ls [prefix]``, ``cat <path>``, ``write <path> <text>``, ``rm <path>``, ``commit [msg]``, ``workspace``, ``edit <path>``), fulfilling the persistent semantic file home requirement for human developers and autonomous AI agents.
  - **Sovereign Visual Text Editor Actor (vedit)**: Authored standalone full-screen TUI text editor in ``lib/macros/vedit.mx`` rendering directly to the 1280x800 UEFI GOP framebuffer canvas and serial console with title bar, line number gutter, cursor navigation, viewport scrolling, atomic ``Ctrl+S`` CAS saving/commit, and clean ``Ctrl+Q`` exit.
  - **Live QEMU UEFI End-to-End Verification**: Verified interactive file creation, multi-entry catalog listing, OCC commit snapshotting, and full visual text editing under QEMU UEFI with 0 defects.

- **Milestone 19 (Git Smart HTTP Transport & CAS Packfile Substrate - SPEC-TECH-NET-003)**:
  - **Git Packet-Line Protocol Engine**: Implemented ``writePktLine``, ``writeFlush``, ``writeDelim``, ``parsePktLine``, and ``parsePushCommand`` in ``src/kernel/net/git_pkt.zig`` with 4-byte hex length prefixing and zero-copy slicing.
  - **Smart HTTP Discovery & Report-Status**: Implemented ``buildAdvertisementBody`` and ``buildReportStatusBody`` in ``src/kernel/net/git_transport.zig``, generating capability advertisements (``report-status``, ``delete-refs``) and push report confirmations without sideband framing.
  - **Freestanding Git Packfile Parser & Decompressor**: Implemented ``parsePackHeader``, variable-length MSB object header decoding, and object decompression in ``src/kernel/net/git_pack.zig`` using freestanding ``std.compress.flate`` (``.zlib``) with zero libc dependencies.
  - **Content-Addressed Git Ingestion & Syscall ABI**: Implemented ``src/kernel/net/git_abi.zig`` resolving commit tree structures, ingesting Git blob payloads into ``CasEngine`` under 256-bit BLAKE3 hashes, advancing repository branch tips monotonically, and exposing capability-gated syscalls (``sys_git_advertise_refs``, ``sys_git_receive_pack``, ``sys_git_get_head``, ``sys_git_cat_file``).
  - **Autonomous Web Server Git Integration**: Expanded ``lib/macros/http_server.mx`` with Git endpoint routing (``GET /<repo>.git/info/refs``, ``POST /<repo>.git/git-receive-pack``), automatically serving pushed files (such as ``index.html``) directly from CAS upon push.
  - **Live QEMU End-to-End Verification**: Verified standard host workstation ``git push http://127.0.0.1:8080/site.git master`` successfully pushing commits into running MicrOS node under QEMU and verified instant live HTTP serving of pushed web content.

- **Milestone 18 (Fast-Path TCP Server Substrate - SPEC-TECH-NET-002)**:
  - **Stateless BLAKE3 SYN-Cookies**: Implemented ``computeSynCookie`` and ``verifySynCookie`` in ``src/kernel/net/tcp.zig``, hashing 24-byte 4-tuple, client ISN, and 64-bit kernel secret nonce with BLAKE3 to prevent SYN flood denial of service with zero pre-handshake memory allocation.
  - **Fast-Path TCP Server Engine & In-Order Dropping**: Implemented ``TcpListener`` and ``TcpServerConn`` in ``src/kernel/net/tcp.zig`` with 9-state RFC 9293 state machine, 16 KiB circular RX/TX buffers, in-order packet dropping, and cooperative FIN/ACK teardown.
  - **Network Stack Server Dispatcher**: Integrated server listeners and connection pool into ``NetworkStack`` in ``src/kernel/net/stack.zig``, routing incoming TCP segments between active server connections, SYN-cookie listener handshakes, and client connections.
  - **Capability-Gated Network Syscall ABI**: Implemented ``src/kernel/net/net_abi.zig`` exposing 5 native syscalls (``sys_net_listen``, ``sys_net_accept``, ``sys_net_recv``, ``sys_net_send``, ``sys_net_close``) gated by ``CapType.network_device`` capabilities and caller actor ownership. Integrated network polling into ``sys_yield`` and ``sys_actor_wait``.
  - **CAS-Backed HTTP/1.1 Web Server Actor**: Authored sovereign pure Macros HTTP web server in ``lib/macros/http_server.mx`` serving landing pages, health telemetry, and content-addressed blobs from BLAKE3 CAS (``GET /b3/<hash>``).
  - **MicroShell Integration & QEMU Port Forwarding**: Added ``httpd`` command to ``lib/macros/msh.mx``, packaged ``http_server.mx`` into ``src/kernel/genesis.mcb``, configured ``hostfwd=tcp::8080-:8080`` in ``GNUmakefile`` and ``tools/micros-runner.bash``, and verified live end-to-end multi-route HTTP queries from host ``curl`` under QEMU with 0 defects.

- **Crucible Protocol Hardening & Substrate Verification**:
   - **Ambient Syscall Authority & CSpace Isolation**: Restricted destructive operations (``sys_reboot``, ``sys_disk_gpt_format``, ``sys_disk_esp_format``, and ``sys_disk_cas_format``) in ``src/kernel/storage/storage_abi.zig`` to Actor 0 (Genesis) or child actors explicitly holding ``CapType.storage_device`` (WRITE) or ``CapType.actor_control`` (EXECUTE). Enforced caller CSpace lookup in ``src/kernel/abi.zig`` and ``src/kernel/main.zig`` for all dynamic tool dispatches.
   - **Syscall Integer Sanitization**: Replaced unchecked Ring 0 integer casts with bounds-checked ``castToU32``, ``castToUsize``, and ``castToU64`` helpers across ``src/kernel/abi.zig`` and ``src/kernel/storage/storage_abi.zig``, preventing kernel panics on negative inputs (e.g. ``kill -1``). Added input validation guards in ``lib/macros/init.mx`` and ``lib/macros/msh.mx``.
   - **Dual-Slot A/B Power-Cut Protection**: Removed active bootloader overwrite (``/EFI/BOOT/BOOTX64.EFI``) from ``stageEspKernel`` in ``src/kernel/storage/rebuild.zig``, ensuring that in-system updates only stage into ``SLOT_A.EFI`` or ``SLOT_B.EFI`` with atomic trial markers (``BOOTSTATE.DAT``/``TRIAL.DAT``).
   - **Framebuffer Vector Graphics & Layout Isolation**: Cleaned up visual artifacts on the 1280x800 GOP framebuffer, ensuring background clearance on Studio startup and exit (``sys_fb_clear``), matching 24px header bar alignment across ``msh.mx`` and ``harness.mx``, and implementing strictly bounded word wrapping (``emit_word_chunks``, ``scan_next_word``) so long model responses or tool outputs never overwrite telemetry panels.
   - **Administrative Capability Delegation**: Implemented ``delegateInitialCaps`` in ``src/kernel/main.zig``, delegating ``CapType.actor_control`` (ALL) and ``CapType.storage_device`` (READ | WRITE) to administrative system domains (``msh``, ``harness``, ``installer``, ``rebuild``) upon spawn while strictly confining untrusted child workers to attenuated capabilities. Resolved ``PermissionDenied: actor_control.EXECUTE required`` when the Resident AI calls ``spawn_actor`` from the Interactive Studio.
   - **HTTP/1.1 Transfer Robustness**: Hardened HTTP chunked stream decoding in ``src/kernel/net/http.zig`` with RFC-compliant chunk boundary validation and JSON unescaping for nested quotes, preventing truncation when receiving large LLM payloads.

- **Interactive Shell Ergonomics & Resident AI Protocol Hardening**:
  - **First-Class Framebuffer Terminal for MicroShell**: Updated ``lib/macros/msh.mx`` to render interactive shell sessions directly to the 1280x800 UEFI GOP framebuffer (``tty0``) with minimalist header banner, prompt styling, character-by-character backspace erasing, and auto-scrolling, while maintaining simultaneous serial console mirroring (``ttyS0``). Restores the terminal display seamlessly upon return from visual actors (``harness`` or ``installer``).
  - **Minimalist Interface & Terminology Cleanup**: Purged artificial jargon (such as ``App 0``, ``(msh) - App 0``, and ``App 1``) across system supervisor logs (``init.mx``), shell headers (``msh.mx``), and studio banners (``harness.mx``) in favor of a clean, minimalist UI (``uOS MicroShell`` | ``x86_64``).
  - **HTTP/1.1 Chunked Transfer Decoding**: Implemented freestanding ``decodeChunkedBody`` in ``src/kernel/net/http.zig`` with hex chunk size parsing, contiguous payload extraction, and terminal chunk verification. Integrated into ``src/kernel/main.zig``, cleanly stripping HTTP chunk framing (e.g. ``be4\r\n`` ... ``0\r\n\r\n``) from upstream HTTPS streaming endpoints like Google Gemini.
  - **Multi-Turn Conversational Tool Resolution**: Hardened ``cmd_ai`` in ``lib/macros/harness.mx`` to handle structured tool calls without leaking raw JSON envelopes to the screen. Automatically executes invoked tools via ``sys_ai_tool_call``, updates telemetry panels, and prompts the Resident AI with execution results to generate clear, natural language summaries for the user.
  - **Bounded Framebuffer Word & Line Wrapping**: Implemented ``console_print_wrapped`` in ``lib/macros/harness.mx``, enforcing newline splitting and strict column bounding (``x <= 840``) so long model responses never overflow into adjacent telemetry panels or corrupt GUI divider borders.

- **Track D (Bit-for-Bit Self-Rebuilding Kernel Pipeline - Phase 4 Full Closure)**:
  - **In-System MCB Synthesizer & Pack Syscall (Milestone M4.1)**: Implemented freestanding ``src/kernel/storage/bundle_writer.zig`` assembling immutable, 64-byte aligned Capability Bundle (``.mcb``) binaries entirely in memory with zero libc and explicit allocator. Enforces lexicographical tag sorting to eradicate file-ordering non-determinism, computes BLAKE3 content digests per entry, and ensures deterministic zero-padding. Exposed ``sys_bundle_pack`` in ``src/kernel/storage/storage_abi.zig`` and implemented userspace bundle packaging in ``lib/macros/bundle.mx``.
  - **Freestanding Kernel Synthesizer & PE32+ Assembler (Milestone M4.2)**: Implemented freestanding ``src/kernel/storage/kernel_synthesizer.zig`` linking relocatable substrate objects with the immutable embedded ``.mcb`` bundle section to emit valid ``BOOTX64.EFI`` binaries entirely in Ring 0. Hardened ``src/boot/pe_emitter.zig`` with sorted base relocations in strictly ascending address order (``std.sort.insertion``), zeroed timestamps and checksums, and strict 512-byte sector file alignment, proving mathematical bit-for-bit identity across passes (``BLAKE3(Pass 1) == BLAKE3(Pass 2)``). Exposed ``sys_kernel_synthesize`` in ``src/kernel/storage/storage_abi.zig``.
  - **Fail-Safe Dual-Slot A/B Staging & MicroShell Workflow (Milestone M4.3)**: Implemented power-cut immune dual-slot kernel staging (``SLOT_A.EFI`` / ``SLOT_B.EFI``) on the FAT32 ESP partition in ``src/kernel/storage/rebuild.zig`` with trial canary state tracking (``BOOTSTATE.DAT``, ``TRIAL.DAT``). Added autonomous 5-step rebuild pipeline in ``lib/macros/rebuild.mx`` (actor extraction, candidate bundle packaging, PE32+ synthesis, ESP/CAS staging, and canary activation) invoked via ``rebuild`` command in ``lib/macros/msh.mx``. Added trial canary promotion confirmation in ``lib/macros/init.mx`` upon stable boot. Exposed ``sys_kernel_stage_update``, ``sys_rebuild_status``, and updated ``sys_cas_confirm_boot`` in ``src/kernel/storage/storage_abi.zig``.
  - **Bit-for-Bit Certification & Master Specification (Milestone M4.4)**: Added automated end-to-end rebuild verification in ``tools/micros-runner.bash`` (``--verify-rebuild``), verifying full round-trip in-system rebuild under QEMU. Authored Master Technical Specification ``docs/technical/specs/self-rebuilding-kernel.rst`` (``SPEC-TECH-REBUILD-001``) and updated Phase 4 roadmap ``docs/project/roadmaps/phase-4-sovereign-cord-cutting.rst`` to Complete & Verified.

- **Resident AI Transport Security & Process Decoupling**:
  - **Freestanding TLS 1.3 Unlocked on UEFI**: Enabled ``std.crypto.tls.Client`` unconditionally across freestanding ``x86_64-uefi`` targets in ``src/kernel/net/tls_stream.zig``, removing legacy compile-time stubbing and enabling live HTTPS inference with Gemini and OpenAI directly on bare-metal UEFI.
  - **MicroShell Decoupling & Centralized AI Harness**: Stripped the ``ai`` command from App 0 MicroShell (``lib/macros/msh.mx``) to enforce strict separation of responsibilities, preserving ``msh`` as a lean systems administration CLI and centralizing synthetic intelligence orchestration within App 1 (``lib/macros/harness.mx``). Updated installer messaging to neutral technical phrasing.

- **Milestone 18 Foundation (Memory Lifecycle, Preemption & Semantic CAS Manifests)**:
  - **Dynamic Chunk Lifecycle & Use-After-Free Elimination**: Refactored ``src/macros/vm.zig`` (``nativeExecChunk`` and ``executeChunk``) to manage bytecode chunks dynamically within ``dynamic_chunks``, unwinding call frames on error and eliminating local stack reference escapes and memory leaks.
  - **Adaptive GC Threshold & Bounded Hole Allocation**: Hardened Immix GC in ``src/macros/gc.zig`` with adaptive allocation thresholds (``DEFAULT_GC_THRESHOLD = 64 KiB``, ``GC_GROWTH_FACTOR = 2``, ``MAX_HEAP_BLOCKS = 512``), mathematical hole-extent bounding in ``Block.resetHoles``, and explicit memory zeroing (``@memset(0)``) during line recycling to eliminate stale pointer revival.
  - **Cooperative Instruction Preemption**: Implemented opcode dispatch preemption quantum (``PREEMPTION_QUANTUM = 1024``) and configurable yield hooks in ``src/macros/vm.zig``, cooperatively yielding CPU control via ``fiber.yield()`` during long-running compute loops.
  - **Stage 1 Multi-Level Lexical Closures**: Expanded self-hosting compiler in ``lib/macros/compiler.mx`` and ``lib/macros/parser.mx`` with ``op_closure``, ``op_get_upvalue``, ``op_set_upvalue``, and ``op_close_upvalue``, supporting multi-level lexical variable capture across arbitrary parent scopes (``outer -> middle -> inner``) and forward-progress error guards.
  - **Sector-Aligned Semantic CAS Manifests**: Implemented structured 448-byte ``SystemManifest`` (``SYSTEM_MANIFEST_MAGIC = 0x4D49434D``) in ``src/kernel/storage/chunk.zig`` and ``cas.zig``, enforcing exact 512-byte single-sector alignment (64-byte header + 448-byte body) with BLAKE3 cryptographic verification.

- **Milestone 17 (Sovereign Language Self-Hosting & Native Codegen)**:
  - **Deterministic Binary Serialization & Hashing**: Implemented ``src/macros/serializer.zig`` defining a canonical, packed binary specification (``MCR1`` magic, 64-byte zero-padded header, explicit constant tags, little-endian integers) with zero uninitialized padding leaks and zero memory pointer dependence, enabling mathematical fixed-point reproducibility (``BLAKE3(Chunk 1) == BLAKE3(Chunk 2)``).
  - **Stage 1 Self-Hosting Compiler**: Implemented pure Macros compiler pipeline in ``lib/macros/`` (``lexer.mx``, ``parser.mx``, ``compiler.mx``, ``compiler_main.mx``) featuring recursive descent parsing, AST construction, lexical scoping, forward-jump backpatching, and deterministic constant pool allocation.
  - **Consolidated Immix Mark-Region GC**: Unified runtime memory management in ``src/macros/gc.zig`` with 32 KiB page-aligned blocks (``align(4096)``), 256-byte line granularity, 3-state line lifecycle (``free``, ``allocated``, ``marked``), zeroed hole memory recycling, and multi-root scanning across VM stack, globals, and chunk constants.
  - **Direct x86_64 Machine Code Emitter & W^X Protection**: Implemented ``src/macros/codegen_x86_64.zig`` translating bytecode opcodes directly to native x86_64 machine instructions (integer arithmetic, local variables, relative control flow jumps) with strict Write XOR Execute (W^X) hardware page protection enforced via ``sys.mem.protect``.
  - **Content-Addressed Module Protocol**: Implemented ``src/macros/module.zig`` supporting cryptographic imports (``import cas("b3:<hash>")`` and ``import bundle("<path>")``) with zero-trust BLAKE3 payload verification, isolated compilation domains, and in-memory caching.
  - **Genesis Bundle Embedding & Verification**: Packed complete self-hosting compiler sources (7 entries) into ``src/kernel/genesis.mcb``, verified 100% test passage across 186 unit tests with zero Ten Commandments violations, 100% specification traceability, and successful headless QEMU boot validation.
  - **Master Specification & Roadmap**: Authored Master Technical Specification ``docs/technical/specs/self-hosting-macros.rst`` (``SPEC-TECH-LANG-002``) and updated roadmap ``docs/project/roadmaps/milestone-17-language-self-hosting.rst`` to Completed.

- **Milestone 16 (Reactive Vector Compositor & Multi-Actor Windowing)**:
  - **Double-Buffered Backbuffer & Page Alignment**: Implemented ``src/kernel/compositor/canvas.zig`` managing a 1280x800x32bpp backbuffer in kernel RAM with mathematically enforced 4096-byte page alignment (``align(4096)``) to eliminate tearing, bus saturation, and scanline flicker.
  - **Bounded AABB Damage Pipeline**: Implemented Axis-Aligned Bounding Box (AABB) dirty rectangle tracking (``DamageRect``) with ``unionWith``, ``intersectWith``, and point/rect accumulation, transferring only dirty scanline extents to physical VRAM during vertical refresh cycles.
  - **Shared-Memory Actor Surfaces & Zero-Copy IPC**: Implemented ``src/kernel/compositor/surface.zig`` allowing individual actors to allocate isolated pixel surfaces in their own capability domains and push zero-copy ``SurfaceCommit`` tokens over lock-free SPSC IPC rings (``RingBuffer``).
  - **Multi-Actor Window Manager & Z-Order Tiling**: Implemented ``src/kernel/compositor/wm.zig`` providing automatic golden-ratio binary space partitioning (BSP) tiling, floating HUD overlays, active/inactive window border styling, 16px title bars, and Z-order stacking without legacy X11 or Wayland protocol overhead.
  - **Pointer Ingress & Focus Arbitration**: Implemented 3-byte PS/2 mouse packet decoding (``decodePs2Packet``), coordinate clamping, non-destructive 8x8 cursor sprite caching (``CursorBacking``), top-to-bottom spatial hit-testing, and ``Ctrl+Alt+Space`` hotkey arbitration toggling focus instantly between App 0 MicroShell and active visual actors in ``src/kernel/compositor/input.zig``.
  - **Native C-ABI Windowing Syscalls**: Exposed unified native windowing and compositor bindings in ``src/kernel/abi.zig`` (``sys_window_create``, ``sys_window_close``, ``sys_window_focus``, ``sys_window_draw_rect``, ``sys_window_draw_string``, ``sys_compositor_flush``, ``sys_pointer_read``).
  - **Kernel Integration & Automated Framebuffer Verification**: Integrated double-buffered compositor initialization into ``kmain`` (``src/kernel/main.zig``), enhanced ``tools/micros-runner.bash`` to reliably capture QEMU monitor screendumps via UNIX domain sockets, and verified visual output with ``tools/src/fb_verify.zig`` (passing with variance 11.64).
  - **Master Specification & Roadmap**: Authored Master Technical Specification ``docs/technical/specs/reactive-compositor.rst`` (``SPEC-TECH-COMPOSITOR-001``) and updated roadmap ``docs/project/roadmaps/milestone-16-reactive-compositor.rst`` to Completed & Verified.

- **Milestone 15b (Process Hierarchy Decoupling & Actor Supervision)**:
  - **4-Layer Process Taxonomy**: Decoupled the boot architecture into Layer 0 Microkernel (Zig, Ring 0, mechanism only) -> Layer 1 Actor 0 Supervisor (``lib/macros/init.mx``) -> Layer 2 App 0 MicroShell (``lib/macros/msh.mx``) -> Layer 3 App 1 Interactive Studio (``lib/macros/harness.mx``).
  - **Unified Sovereign System ABI**: Refactored ``src/kernel/harness_bindings.zig`` into ``src/kernel/abi.zig``, exposing a single, unified native C-ABI substrate for microkernel capabilities, actor lifecycle, storage, and IPC.
  - **Immortal Erlang-Style Supervisor**: Implemented autonomous supervision loop in ``init.mx`` that monitors App 0 MicroShell via ``sys_actor_wait`` and auto-respawns it upon fault or exit.
  - **Actor Lifecycle Synchronization**: Updated ``ActorThreadContext`` with explicit lifecycle tracking (``running``, ``faulted``, ``terminated``) in ``src/kernel/actor.zig`` and implemented ``sys_actor_wait`` native blocking synchronization.
  - **Interactive Harness Separation**: Converted ``lib/macros/harness.mx`` into an on-demand graphical studio spawned from ``msh`` via ``harness`` command, returning cleanly to the shell on ``exit`` with full framebuffer wipe.
  - **Master Specification & Roadmap**: Authored Master Technical Specification ``docs/technical/specs/process-hierarchy.rst`` (``SPEC-TECH-HIERARCHY-001``) and roadmap ``docs/project/roadmaps/milestone-15b-process-hierarchy.rst``.

- **Milestone 15 (Typed Structured Tool Calling Substrate)**:
  - **Freestanding Tool Definition & Schema Registry**: Implemented ``src/kernel/ai/tools.zig`` defining strongly typed compile-time tool declarations for Gemini (``functionDeclarations``) and OpenAI (``tools`` array) covering ``spawn_actor``, ``grant_capability``, ``write_storage``, ``read_storage``, ``draw_canvas``, and ``query_telemetry``.
  - **Zero-Allocation Streaming Tool Call Parser**: Implemented zero-allocation JSON streaming parser in ``src/kernel/ai/tools.zig`` extracting function names and JSON argument payloads with mathematical recursion limits (nesting depth <= 3).
  - **CSpace Security Gate & Capability Dispatcher**: Implemented capability-gated execution routing in ``src/kernel/ai/tools.zig`` verifying ``Rights.ACTOR_CONTROL`` and storage rights before executing operations, preventing rights escalation.
  - **Native ABI Tool Call Binding**: Registered native ``sys_ai_tool_call`` in ``src/kernel/abi.zig`` enabling Resident AI models to execute structured microkernel operations directly without host dependencies.
  - **Master Specification & Roadmap**: Authored Master Technical Specification ``docs/technical/specs/structured-tool-calling.rst`` (``SPEC-TECH-TOOLS-001``) and updated roadmap ``docs/project/roadmaps/milestone-15-structured-tool-calling.rst`` to Complete.

- **AI Code Block Extraction & Actor Fault Containment**:
  - **Native AST-Safe Code Extraction**: Introduced native ``sys_ai_extract_code`` binding in ``src/kernel/harness_bindings.zig`` delegating to ``AiClient.extractCodeBlock``, parsing indentation boundaries and terminating cleanly on unindented section headers (e.g., trailing ``Kernel Directives``) in resident AI responses.
  - **Child Actor Fault Containment**: Hardened ``nativeSysActorSpawnCode`` to catch script compilation errors and return ``-1`` gracefully, preventing VM runtime panics in Genesis Actor 0 when resident AI returns malformed code.
  - **Decomposed Compilation & VM Setup**: Refactored ``spawnActorFromCode`` in ``src/kernel/main.zig`` into modular helpers (``compileActorSource``, ``attachActorVm``) adhering strictly to the 40-line function limit.
  - **Linux-Kernel Aesthetic & Dark Theme**: Replaced decorative ASCII box borders and bright banner styling with an elegant, minimalist Linux-kernel-inspired boot typography (``µOS (MicrOS) version 0.14.0-sovereign``) and dark slate theme in ``lib/macros/harness.mx``.
  - **Eliminated Redundant AI Display & Low-Level Packet Noise**: Removed double printing of AI responses between kernel serial write and harness console display, silenced verbose TCP segment and TLS record packet trace logging, and formatted response lengths in decimal for an elegant terminal experience.
  - **Comprehensive Colocated Testing**: Added unit tests in ``src/kernel/ai/client.zig`` validating extraction from live Gemini responses and in ``src/kernel/harness_bindings.zig`` validating fault-tolerant child actor spawning.

- **Zero-Crash TLS 1.3 & ABI Calling Convention Hardening**:
  - **Fiber Stack Expansion & Heap Hardening**: Increased fiber stack allocation from 128 KiB to 512 KiB (``src/macros/fiber.zig``) and kernel heap from 4 MiB to 8 MiB (``src/kernel/main.zig``), eradicating silent stack overflow over adjacent VM state during freestanding TLS 1.3 cryptographic key exchange and handshakes.
  - **Win64 ABI Calling Convention & Shadow Space in IDT**: Fixed exception and interrupt assembly trampolines in ``src/kernel/arch/x86_64/idt.zig`` to adhere strictly to UEFI / Windows x64 calling conventions (passing arguments via ``%rcx`` and allocating mandatory 32-byte shadow store + 8-byte alignment), preventing triple-fault CPU resets upon hardware traps.
  - **Persistent Drive Integration in GNUmakefile**: Configured ``make qemu-uefi`` to automatically provision and attach ``build/micros-disk.raw`` via VirtIO-Blk, enabling persistent storage and CAS out of the box in interactive UEFI runs.
  - **AI Provider Diagnostics & Configuration**: Added boot-time detection and warning when external resident AI providers lack configured API keys, clarified harness diagnostic feedback, added ``-include .env`` support to ``GNUmakefile`` with ``env.example`` template, and added ``.env`` to ``.gitignore``.

- **Modern Minimalist Terminal Experience & Serial Telemetry**:
  - **Sleek Minimalist Card Header**: Replaced retro ASCII block banners with a modern, column-aligned UTF-8 card border (``┌─┐``) styled in subtle charcoal gray (``\x1b[90m``), glowing cyan (``\x1b[1;96m``), and crisp white (``\x1b[97m``).
  - **Structured Status Badges**: Eliminated noisy debug dumps and arbitrary step prefixes (``Step 1..8``, PCI probing chatter) in favor of fixed-width emerald green status badges (``[  ok  ]``) with categorized bold cyan subsystem tags (``boot``, ``arch``, ``mmu``, ``net``, ``dhcp``, ``blk``, ``cas``, ``cap``, ``gop``, ``mcb``, ``act``, ``spawn``, ``persist``).
  - **ANSI Telemetry Formatting Engine**: Extended ``src/kernel/serial.zig`` with typed ANSI escape constants, standalone decimal formatter (``formatDec``, ``writeDec``), and compact hex formatter (``formatHexCompact``, ``writeHexCompact``) with dedicated unit tests.
  - **Polished Interactive Sovereign Harness**:
    - Enhanced ``lib/macros/harness.mx`` with styled prompt (``µOS macros>``), structured and categorized ``help`` reference menu, and aligned tabular ``actors`` registry view with readable state names.
    - Preserved direct GOP framebuffer blitting safety by keeping ANSI escape sequences isolated to serial telemetry while drawing clean glyphs on the graphical canvas.
    - Refactored harness input loop into modular functions (``handle_newline``, ``handle_backspace``, ``handle_printable``, ``init_ansi``) eliminating code duplication and strictly adhering to the Ten Commandments (functions <= 40 lines, max nesting <= 3 levels).
    - Hardened genesis bytecode chunk memory lifetime in ``src/kernel/main.zig`` by allocating on kernel heap, preventing dangling pointers on popped initialization stack frames.

- **Codebase Hardening, VirtIO Substrate Deduplication & Future Roadmap Integration**:
   - **VirtIO Common Substrate**: Extracted common VirtIO 1.0 register definitions, device status flags, descriptor flags, and split virtqueue structures into ``src/kernel/drivers/virtio.zig``, deduplicating shared logic across ``virtio_blk.zig`` and ``virtio_net.zig``.
   - **Tokenizer Linter Remediation**: Corrected token nesting level exit condition in ``tools/src/lint.zig``, uncovering and remediating 7 hidden function length violations (>40 lines) across ``src/kernel/main.zig``, ``src/kernel/net/dns.zig``, ``src/kernel/net/tcp.zig``, ``tools/src/fb_verify.zig``, and ``tools/src/sym.zig``.
   - **Memory Safety & Defect Remediation**:
      - Eliminated static buffer aliasing in ``src/kernel/harness_bindings.zig`` (``sys_ai_prompt``, ``sys_cas_put``, ``sys_cas_get``, ``sys_actor_persist``) by duplicating strings directly into calling actor VM heaps.
      - Extracted unified ``unescapeJsonString`` state machine into ``src/kernel/ai/provider.zig``, eliminating escaped backslash quote-termination bugs in ``gemini.zig`` and ``openai.zig``.
      - Enforced ``MAX_CHUNK_PAYLOAD_SIZE = 1024 * 1024`` (1 MiB) sanity bounds checking in ``src/kernel/storage/cas.zig:getChunk`` and ``putChunk``.
      - Preserved caller-saved registers (``rsi``, ``rdi``) in x86_64 keyboard ISR assembly trampoline (``src/kernel/arch/x86_64/idt.zig``).
   - **Master Future Roadmaps (Milestones 15–18)**:
      - Authored comprehensive specifications and roadmaps for Milestone 15 (Typed Structured Tool Calling Substrate), Milestone 16 (Reactive Vector Compositor & Multi-Actor Windowing), Milestone 17 (Sovereign Language Self-Hosting & Native Codegen), and Milestone 18 (Sovereign Cord-Cutting & Silicon Deployment).
      - Updated master documentation index (``docs/index.rst``) and verified 100% warning-free Sphinx HTML compilation.

- **VirtIO Driver Optimization & Hardware Acceleration Substrate**:
  - **Zero-Exit Memory Spin Loops**: Replaced port ``0x80`` ``ioWait()`` traps with native x86_64 ``pause`` instructions (``asm volatile ("pause" ::: .{ .memory = true })``) and ``PAUSE_SPIN_LIMIT = 5_000_000`` across all VirtIO drivers (``src/kernel/drivers/virtio_blk.zig``, ``src/kernel/drivers/virtio_net.zig``), dropping polling latency from ~1,500 CPU cycles to nanoseconds and eliminating costly hypervisor VM exits.
  - **Multi-Sector Batched DMA Transfers**: Upgraded VirtIO-Blk driver (``src/kernel/drivers/virtio_blk.zig``) with ``DMA_PAGES = 2`` (8192 bytes), 512-byte sector-aligned payload offset, and batched multi-sector DMA primitives (``readSectors``, ``writeSectors``).
  - **Block Cache Vectorization**: Refactored block cache page frame loader and flush synchronization (``src/kernel/storage/block_cache.zig``) from 8 separate single-sector transactions to a single 4096-byte batched DMA transaction, reducing descriptor setup overhead, doorbell kicks, and hypervisor traps by 87.5%.
  - **Asynchronous Network TX Pipeline**: Refactored VirtIO-Net packet transmission (``src/kernel/drivers/virtio_net.zig``) to eliminate synchronous double-stall waiting, retiring previous transmit descriptors asynchronously upon next packet dispatch and freeing the guest CPU immediately after descriptor enqueue.
  - **VirtIO Subsystem Diagnostic & Benchmarking Tool**: Implemented native developer and diagnostic tool ``tools/src/virtio_bench.zig`` (compiled to ``tools/bin/micros-virtio-bench`` and symlinked to ``tools/micros-virtio-bench``), providing split-virtqueue geometric validation and RDTSC cycle micro-benchmarks demonstrating a 4.03x descriptor setup speedup and 75.2% cycle reduction.

- **Milestone 14 (Persistent Sovereign Storage Substrate)**:
  - Implemented freestanding zero-libc VirtIO-Blk driver (``src/kernel/drivers/virtio_blk.zig``) adhering to VirtIO 1.0 with 256-descriptor split virtqueue, 3-page contiguous DMA allocation, 4096-byte mathematical alignment, volatile ring access, and polled read/write sector requests.
  - Implemented page-aligned bounded block cache (``src/kernel/storage/block_cache.zig``) managing 64 page frames (256 KiB RAM) with strict Least-Recently-Used (LRU) eviction and write-back dirty page synchronization.
  - Implemented Sovereign Content-Addressed Storage (CAS) engine (``src/kernel/storage/cas.zig``, ``src/kernel/storage/chunk.zig``) with freestanding BLAKE3 cryptographic hashing, append-only immutable chunk layout, 64-byte chunk headers, and Sector 0 superblock management with monotonic generation tracking.
  - Registered capability-governed storage bindings in ``src/kernel/harness_bindings.zig`` (``sys_cas_put``, ``sys_cas_get``, ``sys_actor_persist``, ``sys_actor_spawn_cas``) and exposed interactive REPL commands in ``lib/macros/harness.mx`` (``store``, ``fetch``, ``persist``, ``spawn_cas``).
  - Resolved PCI block device discovery in ``src/kernel/drivers/pci.zig`` to prioritize VirtIO vendor devices (``0x1AF4``) over generic IDE storage controllers.
  - Resolved dynamic actor compilation memory lifetime bug in ``src/kernel/main.zig`` by duplicating script source before AST/bytecode compilation to prevent use-after-free corruption on stack-allocated chunk buffers.
  - Implemented automated two-stage cold reboot persistence test in ``tools/micros-runner.bash`` (``--disk``, ``--wipe-disk``, ``--verify-persistence``) verifying live QEMU UEFI storage write, cold reboot, and CAS restoration of dynamic actors across reboots without host or network assistance.
  - Authored Master Technical Specification (``docs/technical/specs/sovereign-storage-substrate.rst``, ``SPEC-TECH-STORAGE-001``) and updated roadmap (``docs/project/roadmaps/milestone-14-sovereign-storage.rst``) to Completed & Verified.
  - Updated ``AGENTS.md`` with storage and persistence invariants (sector boundary alignment, 4096-byte DMA alignment, BLAKE3 content addressing, zero POSIX filesystems).

- **Milestone 13 (Interactive Human-AI Construction Loop)**:
  - Implemented interactive line editor and command loop in ``lib/macros/harness.mx`` supporting ``status``, ``actors``, ``clear``, ``kill <id>``, ``ai <prompt>``, and ``exit``.
  - Unified hardware input across COM1 UART serial (``sys_serial_read``) and PS/2 keyboard (``sys_kbd_read``) with open-bus floating bus detection in ``src/kernel/drivers/ps2_kbd.zig``.
  - Implemented native VM bindings in ``src/kernel/harness_bindings.zig`` for cognitive prompts (``sys_ai_prompt``), dynamic actor compilation/spawning (``sys_actor_spawn_code``), and actor state/name inspection.
  - Implemented zero-leak string literal escape sequence decoding (``\n``, ``\r``, ``\t``, ``\\``, ``\"``) in ``src/macros/compiler.zig`` and ``src/macros/lexer.zig`` with ``Chunk.allocated_strings`` lifecycle management.
  - Added missing symbol diagnostic tracking in ``src/macros/vm.zig`` (``last_missing_symbol``) and microkernel actor thread crash reporting.
  - Upgraded fiber stack allocation to 128KB in ``src/macros/fiber.zig`` and added zero-copy ``initInPlace`` to eliminate stack overflow hazards on bare-metal.
  - Added automated interactive QEMU verification in ``tools/micros-runner.bash`` using standard POSIX FIFOs and zero inline Python.
  - Authored Master Technical Specification (``docs/technical/specs/sovereign-interactive-harness.rst``, ``SPEC-TECH-HARNESS-002``) and roadmap (``docs/project/roadmaps/milestone-13-interactive-harness.rst``).

- **Comprehensive Documentation Review & Sphinx Build System**:
  - Harmonized the entire ``docs/`` tree under Sphinx and Docutils, resolving all syntax warnings, title length mismatches, and forward slash formatting.
  - Added native Sphinx configuration (``docs/conf.py``) enabling strict-mode (``-W``) zero-warning HTML compilation.
  - Formatted all tables and overline/underline borders with exact character lengths across all specifications and roadmaps.
  - Added formal roadmaps for Milestone 11 (Transport Security) and Milestone 12 (Resident AI Substrate).
  - Linked all milestones (Phases 0-4, Milestones 8-12) and formal audits into master documentation index (``docs/index.rst``).

- **Resident AI Cognitive Stream in reStructuredText**:
  - Transitioned the Resident AI cognitive stream from Markdown triple backticks to pure reStructuredText directives (``.. code-block:: macros`` and ``.. code-block:: mx``) with 3-space indentation support.
  - Engineered indentation-aware parser (``extractRstCodeBlock`` in ``src/kernel/ai/client.zig``) supporting header skipping, indentation normalization, and legacy Markdown fence fallback.
  - Updated sovereign system prompt (``src/kernel/ai/provider.zig``) and deterministic offline mock (``src/kernel/ai/mock.zig``).
  - Added unit test cases for 3-space and 4-space RST code-block parsing; expanded test suite to 108/108 passing tests with 0 Ten Commandments violations.

- **Zero-Trust Forensic Audit & Specification Realignment**:
  - Conducted full Zero-Trust forensic audit across all specifications, roadmaps, and source modules, publishing the formal compliance report at ``docs/project/audits/2026-09-17-full-documentation-audit.rst`` with **PASS: ZERO DEFECTS** certification.
  - Remediated cross-reference hallucinations in ``macros-lang.rst``, ``macros-runtime.rst``, and ``self-hosting-macros.rst`` (mapping Immix GC to ``[US-GEM-008]``, fiber concurrency to ``[US-REN-010]``, and zero-libc AST execution to ``[US-REN-004]``).
  - Realigned ``microshell-msh.rst`` and ``toolchain.rst`` to accurately map business user stories ``[US-REN-001]``, ``[US-REN-005]``, ``[US-REN-009]``, and ``[US-GEM-001..007]``.
  - Specialized ``:Traced Stories:`` metadata across ``sovereign-capability-substrate.rst``, ``sovereign-harness-protocol.rst``, and ``sovereign-gemini-orchestrator.rst``.
  - Upgraded ``tools/micros-spec-trace.bash`` to perform semantic bidirectional verification, verifying 20/20 user stories (100% coverage).
  - Promoted ``phase-0-userspace-sandbox.rst`` and ``phase-1-bare-metal-substrate.rst`` to ``:Status: Completed & Verified``.
  - Purged 7 leftover scratch test files from the workspace root.

- **Milestone 12 (Pluggable Resident AI Subsystem & Bidirectional Sovereign Event Loop)**:
  - **Modular Resident AI Substrate**: Completely decoupled the kernel from any specific AI provider or model via ``src/kernel/ai/``. Added polymorphic client (``AiClient`` in ``src/kernel/ai/client.zig``) and extensible provider drivers for Google Gemini (``src/kernel/ai/gemini.zig``), OpenAI/vLLM/Ollama/DeepSeek (``src/kernel/ai/openai.zig``), and offline deterministic testing (``src/kernel/ai/mock.zig``).
  - **Bidirectional Sovereign Event Loop**: Microkernel event loop (``runSovereignEventLoop`` in ``src/kernel/main.zig``) exchanging multi-turn telemetry with the Resident AI in CSpace 0. The Resident AI evaluates machine state, declares operational policies, and dynamically compiles and executes emitted Macros (``.mx``) code on bare-metal hardware.
  - **Network Resilience Architecture**: Dynamic TCP RX buffer expansion to 64KB, modulo 2^32 sequence number tracking, stop-and-wait reliable delivery per 1460-byte MSS chunk, exponential backoff retries, and multi-tier DNS fallbacks tolerating lossy WAN and jitter.
  - **Zero-Copy Stack Safety**: Replaced large struct copies with pointer semantics and cached DNS resolution to eliminate stack overflows in UEFI firmware environments.
  - **Generalized Build Options**: Added ``-Dai-provider``, ``-Dai-api-key``, ``-Dai-model``, ``-Dai-endpoint``, ``-Dai-port``, and ``-Dai-use-tls`` in ``build.zig`` and ``GNUmakefile``, with offline ``mock`` support for air-gapped systems.
  - **Test Suite Expansion**: 106/106 green unit tests and 0 Ten Commandments violations.

- **Milestone 11 (Transport Security & Gemini 3.8 Flash Inference Engine)**:
  - **Freestanding Pure Zig TLS 1.3 Transport Stream**: In-place static memory architecture (``TcpStreamAdapter`` in ``src/kernel/net/tls_stream.zig``) eliminating stack overflow and dangling pointer hazards. Zero-libc TLS client over ``std.crypto.tls.Client`` using hardware entropy (``rdtsc``/``rdrand``). Live TLS 1.3 handshake verified against ``generativelanguage.googleapis.com:443`` over VirtIO-Net in bare-metal UEFI QEMU/KVM.
  - **Freestanding HTTP/1.1 Engine**: Zero-allocation HTTP POST formatting with ``application/json`` payload, response status line parsing, header extraction, and candidate JSON text extraction in ``src/kernel/net/http.zig``.
  - **Gemini 3.8 Flash Sovereign Client**: Root Sovereign Intelligence system prompt injection, escaped JSON request serialization, and candidate response parsing in ``src/kernel/net/gemini.zig``.
  - **Secure Build-Time API Key Provisioning**: ``-Dgemini-api-key=<KEY>`` configuration option wired through ``build.zig`` to bootloader, kernel, and test modules.
  - **Test Suite Expansion**: 95/95 green unit tests across networking, crypto stream adapters, HTTP parsing, and kernel subsystems with 0 linter violations.

- **Milestone 10 (Sovereign Network Substrate: VirtIO-Net, IPv4, DHCP, DNS, TCP)**:
  - **VirtIO-Net Modern PCI Driver**: Zero-libc driver (``src/kernel/drivers/virtio_net.zig``) with PCI configuration space scanning (``src/kernel/drivers/pci.zig``), split virtqueues (RX/TX), and PMM-backed DMA ring buffers.
  - **Pure Zig L2/L3/L4 Network Stack**: Ethernet II framing (``src/kernel/net/ethernet.zig``), ARP resolution cache (``src/kernel/net/arp.zig``), IPv4 parsing and routing (``src/kernel/net/ipv4.zig``), ICMP diagnostics (``src/kernel/net/icmp.zig``), and RFC 2131 DHCP client (``src/kernel/net/dhcp.zig``) auto-configuring IP/subnet/gateway/DNS.
  - **RFC 1035 UDP DNS Resolver**: Domain name resolution (``src/kernel/net/dns.zig``) resolving ``generativelanguage.googleapis.com`` via UDP port 53.
  - **RFC 793 Client TCP State Machine**: Dedicated client TCP engine (``src/kernel/net/tcp.zig``) supporting 3-way handshake (``SYN``/``SYN-ACK``/``ACK``), sequence/acknowledgment tracking, and live connection to Google Cloud port 443.
  - **Unified Network Stack Orchestrator**: Device dispatching, packet polling, and ARP/IP routing in ``src/kernel/net/stack.zig``.


- **Milestone 9 (The Sovereign Actor Harness & Self-Healing Multi-Actor Substrate)**:
  - **Hardware Input IPC**: 8-byte packed ``KeyEvent``, ``KeyAction``, and ``KeyModifiers`` serialization in ``src/kernel/ipc/events.zig``.
  - **PS/2 8042 Keyboard Driver**: Zero-allocation controller driver in ``src/kernel/drivers/ps2_kbd.zig`` translating Scancode Set 1 make/break codes without busy-waiting.
  - **Multi-Actor Registry & Lifecycle**: Domain isolation supporting up to 64 concurrent actors with explicit states (``uninitialized``, ``ready``, ``running``, ``paused``, ``faulted``, ``terminated``) and supervisor hierarchy in ``src/kernel/actor.zig``.
  - **Attenuated Capability Delegation**: Mathematical rights verification in ``src/kernel/cap/cspace.zig`` rejecting privilege escalation and requiring ``Rights.REVOKE`` for revocation.
  - **Interactive Sovereign Harness in Macros**: Real-time vector UI canvas (status header, console evaluator, actor/capability inspector, command prompt) rendering on 1280x800 GOP display and UART 16550 serial link in ``lib/macros/harness.mx``.
  - **Microkernel VM Harness Bindings**: Direct syscall bridges (``sys_actor_spawn``, ``sys_fb_draw_rect``, ``sys_serial_write``, ``sys_serial_read_char``, ``sys_yield``) in ``src/kernel/harness_bindings.zig``.
  - **Bare-Metal Fault Containment**: CPU exception interception (``#PF``, ``#GP``, ``#DE``, ``#UD``) in ``src/kernel/arch/x86_64/idt.zig`` for child actors (id > 0), suppressing microkernel panics, packaging 40-byte ``FaultFrame`` IPC notifications into supervisor rings, and yielding safely via naked trampolines.
  - **Erlang-Style Actor Supervision**: Automated recovery policies (``restart_immediate``, ``quarantine``, ``terminate_and_reclaim``) in ``src/kernel/supervisor.zig``.
  - Top-level fiber yielding primitive (``pub fn yield()``) in ``src/macros/fiber.zig``.
  - String key persistence in VM global table (``getOrPut`` with allocator dupe) in ``src/macros/vm.zig`` preventing hash-map resize corruption.
  - 69/69 green unit tests, 0 linter violations, live UEFI boot and 1280x800 visual canvas verification.

- **Milestone 8 (The Sovereign Capability Substrate & Genesis Domain)**:
  - Microkernel Capability System: First-class capabilities (``src/kernel/cap/capability.zig``) and per-domain Capability Space (``src/kernel/cap/cspace.zig``) eliminating ambient authority.
  - Isolated Domain execution model (``src/kernel/domain.zig``).
  - Lock-free Single-Producer Single-Consumer (SPSC) ring buffer (``src/kernel/ipc/ring.zig``) with cache-line alignment.
  - MicrOS Bundle (MCB) file format and zero-copy reader (``src/kernel/bundle.zig``, ``tools/src/bundle.zig``) with BLAKE3 hash validation and 64-byte payload alignment.
  - Bare-metal UEFI GOP framebuffer driver (``src/kernel/fb.zig``) and full 8x8 font table for ASCII 32..126 (``src/kernel/font.zig``).
  - Dynamic Genesis bundle compilation and execution inside Actor 0 at boot.

- **Phase 0 through Phase 7 Foundation**:
  - Initial project structure, direct-syscall wrapper (``src/sys/``), and Substrate Toolchain (``micros-runner``, ``micros-fb-verify``, ``micros-lint``, ``micros-sym``, ``micros-telem``, ``micros-spec-trace``).
  - Macros lexer, AST, parser, evaluator, and self-hosted Stage 1 compiler (``lib/macros/``).
  - MicroShell (``msh/ush``) with streaming pipeline execution and REPL.
  - Headless QEMU/KVM test harness with sub-second milestone sentinel matching and ACPI S5 poweroff.
  - Immix Mark-Region Garbage Collector (``src/macros/immix.zig``) with 32KB blocks and 128-byte line marks.
  - Cooperative Green-Thread Fiber Runtime and Scheduler (``src/macros/fiber.zig``, ``src/macros/context_switch.s``).
  - Bare-metal x86_64 Long Mode UEFI bootloader (``boot.efi``), PMM bitmap allocator, and 4-level VMM paging.
  - Master specifications, user personas, and 20 bidirectional user stories.
