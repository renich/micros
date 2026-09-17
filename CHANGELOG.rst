=========
Changelog
=========

All notable changes to this project will be documented in this file.

The format is based on `Keep a Changelog <https://keepachangelog.com/en/1.1.0/>`_,
and this project adheres to `Semantic Versioning <https://semver.org/spec/v2.0.0.html>`_.

[Unreleased]
============

- **Milestone 14 (Persistent Sovereign Storage Substrate)**:
  - Authored Master Technical Specification (``docs/technical/specs/sovereign-storage-substrate.rst``, ``SPEC-TECH-STORAGE-001``) and project roadmap (``docs/project/roadmaps/milestone-14-sovereign-storage.rst``) defining the VirtIO-Blk driver, 64-page LRU block cache, and BLAKE3 Content-Addressed Storage (CAS) engine.
  - Linked storage specification into master documentation index (``docs/technical/spec.rst``, ``docs/index.rst``, ``README.rst``) and verified 100% bidirectional traceability (``make -C tools test``).
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
