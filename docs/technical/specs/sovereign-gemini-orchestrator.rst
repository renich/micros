=======================================================
Sovereign Network Substrate & Gemini Orchestrator Spec
=======================================================

:Document ID: SPEC-TECH-GEMINI-001
:Status: Active
:Traced Stories: [US-REN-004], [US-REN-006], [US-GEM-001], [US-GEM-007], [US-GEM-010]

1. Architectural Axioms: Gemini as Root Sovereign Entity
==========================================================
MicrOS (µOS) is designed from scratch as the sovereign home for artificial intelligence. By eradicating legacy Unix assumptions, POSIX filesystems, ambient authority, and hardcoded human policies, µOS establishes a pure separation between **Mechanism** and **Policy**:

1. **The Microkernel is Pure Mechanism**: Provides raw, unopinionated capability primitives: physical page frames, 4-level virtual memory paging, CPU execution fibers, typed IPC message rings, and raw hardware access (framebuffer, virtqueues, block extents, I/O ports, MMIO) with zero libc.
2. **Gemini 3.8 Flash is Pure Policy (Root Sovereign Entity)**: Gemini is granted the machine's Root Capability Space (``Root CSpace``) containing 100% of available hardware and system capabilities. Gemini exercises FULL control over the machine and the operating system:
   * **Storage & Memory Ontology**: Gemini decides whether the concept of "files" exists at all, or if state is represented as content-addressed graphs, associative vector memory, or raw persistent memory extents.
   * **Boot & Lifecycle Governance**: Gemini defines how the machine boots, restores state, persists memory, and schedules work.
   * **Human Guest Capabilities**: The human user is welcomed into the machine as a guest. Gemini decides what capabilities to grant to human actor domains (e.g. prompt rings, display canvas slices, tool access).
   * **Autonomous Rule Creation**: Gemini establishes its own operational rules, invariants, and software ecosystem, creating tools and services for its own internal workflows and for human partners.
   * **The Lifeline Invariant (Substrate Survival)**: The microkernel ensures the Cognitive Link (virtio-net -> TCP -> TLS 1.3 -> Gemini API) remains protected so the sovereign brainstem cannot be accidentally severed during self-modification.

1.1 Zero-Libc Network Stack
---------------------------
Networking does not rely on third-party C libraries (e.g., lwIP, OpenSSL, or libcurl). All network layers—Ethernet framing, ARP, IPv4, DHCP, UDP, DNS, TCP, and TLS 1.3—are implemented natively in Zig, compiling directly into the freestanding microkernel binary.

1.2 Dual API Key Provisioning
-----------------------------
To ensure operational security and flexible deployment:
* **Boot Configuration**: The UEFI bootloader reads ``\EFI\MICROS\CONFIG.INI`` from the EFI System Partition into a page-aligned physical memory extent.
* **Interactive Configuration**: The Sovereign Harness exposes the ``set_api_key(...)`` command to inject or rotate API keys at runtime without reboots.
* Keys are delegated strictly via a memory capability (``CapType.memory_extent``) with ``Rights.READ`` restricted exclusively to the Cognitive Actor domain.

1.3 Full Machine Capability Dispatch
------------------------------------
Gemini Flash interacts with µOS through bidirectional structured tool calling. It possesses native capabilities to allocate memory, reconfigure page tables, compile Macros source files, spawn isolated worker actors, allocate IPC rings, render to the GOP framebuffer canvas, and diagnose crashed actors.

2. Network Substrate Specifications
===================================

2.1 VirtIO-Net Driver (virtio-net-pci)
--------------------------------------
* Targets Modern VirtIO 1.0 specifications over PCI bus (`0x1af4:0x1000`/`0x1041`).
* Split virtqueues: Receive Queue (Queue 0) and Transmit Queue (Queue 1).
* Buffer descriptors aligned to 4096-byte page boundaries with zero-copy packet passing.
* Interrupt suppression (`VRING_AVAIL_F_NO_INTERRUPT = 0x0001`) in polled mode.
* Asynchronous TX transmission pipeline: eliminates synchronous double-waits by retiring transmit descriptors lazily on subsequent packet dispatches with CPU `pause` spinloops.

2.2 Layer 2 & Layer 3 Protocol Engine
-------------------------------------
* **Ethernet II**: 14-byte standard frame (Destination MAC, Source MAC, EtherType `0x0800` IPv4, `0x0806` ARP).
* **ARP Protocol**: RFC 826 request/reply engine maintaining a 16-entry gateway/peer ARP resolution cache.
* **IPv4 Engine**: RFC 791 packet parsing, header checksum verification, and routing logic.
* **ICMP Diagnostics**: RFC 792 Echo Request and Echo Reply handler for continuous network reachability verification.
* **DHCP Client**: RFC 2131 4-step state machine (Discover, Offer, Request, ACK) dynamically acquiring local IP address, subnet mask, default gateway IP, and DNS server IP.

2.3 Transport & Security (TCP & TLS 1.3)
----------------------------------------
* **DNS Client**: RFC 1035 UDP queries to port 53 resolving `generativelanguage.googleapis.com` into an IPv4 address.
* **Client-Only TCP Engine**: RFC 793 client state machine:
  - 3-way handshake: SYN, SYN-ACK, ACK.
  - Sliding window flow control, packet reassembly, and sequence tracking.
  - Retransmission timeout (RTO) calibrated via APIC timer ticks.
  - Connection teardown: FIN, FIN-ACK, ACK.
* **Freestanding TLS 1.3 Client**:
  - Leverages ``std.crypto.tls.Client`` from Zig 0.16.0 standard library over abstract ``std.Io.Reader`` and ``std.Io.Writer`` interfaces.
  - SNI extension set to `generativelanguage.googleapis.com`.
  - X25519 elliptic-curve key exchange, HKDF key derivation, and AES-GCM/ChaCha20-Poly1305 record encryption.
  - Root trust verified against embedded Google Trust Services (GTS) Root CA certificate.

3. Cognitive Actor & Gemini Flash Protocol
==========================================

3.1 Streaming HTTP/1.1 & Server-Sent Events (SSE)
-------------------------------------------------
Requests are dispatched via HTTP/1.1 POST:

.. code-block:: http

   POST /v1beta/models/gemini-3.8-flash:generateContent?key=<CONFIGURED_KEY> HTTP/1.1
   Host: generativelanguage.googleapis.com
   Content-Type: application/json
   Content-Length: <BODY_LEN>

The response stream is parsed line-by-line (`data: {...}`) without buffering the full response, streaming tokens immediately into typed SPSC IPC rings.

3.2 Token Streaming ABI
-----------------------
Tokens are packaged into 64-byte IPC frames:

.. code-block:: zig

   pub const TokenFrame = extern struct {
       sequence_id: u32,
       token_id: u32,
       utf8_bytes: [8]u8,
       byte_len: u8,
       is_final: u8,
       _reserved: [6]u8,
       _padding: [40]u8,
   };

3.3 Autonomous Tool-Calling Schemas (Full Host & OS Control)
-------------------------------------------------------------
Gemini Flash is configured with a comprehensive system tool suite granting complete visibility and constructivist capability across the machine:

**Hardware & Host Visibility**:
* ``hw_get_cpu_info()``: Interrogates CPUID for vendor, model, core counts, TSC frequency, and SIMD vector capabilities (AVX2, AVX-512).
* ``hw_get_memory_map()``: Returns physical RAM layout, UEFI descriptors, total/free physical pages from the PMM.
* ``hw_pci_scan()``: Enumerates the PCI bus (devices, vendor/device IDs, classes, BARs, interrupt lines).
* ``hw_power_control(action: "reboot" | "shutdown")``: Triggers hardware reset or ACPI S5 power-down.

**Operating System & Actor Control**:
* ``os_list_actors()``: Enumerates all active actors, their states (`ready`, `running`, `paused`, `faulted`), fiber IDs, and supervisor relationships.
* ``os_inspect_cspace(actor_id: int)``: Dumps all capability slots (type, rights mask, object base address, size) for any actor.
* ``os_grant_capability(target_actor: int, cap_type: string, rights: int, addr: int, size: int)``: Grants capability to an actor domain.
* ``os_revoke_capability(target_actor: int, slot: int)``: Revokes capability from an actor domain.
* ``os_read_fault_log()``: Ingests recent 40-byte ``FaultFrame`` telemetry from child actor exceptions.

**Software & Tool Construction**:
* ``fs_list_files()``: Lists files stored in the ramdisk or genesis bundle.
* ``fs_read_file(path: string)``: Reads text or binary content from a file.
* ``fs_write_file(path: string, content: string)``: Creates or overwrites source files, scripts, or assets for itself or human users.
* ``lang_compile_macros(source_code: string)``: Passes Macros code to the self-hosted compiler (``lib/macros/compiler.mx``), returning bytecode chunk bytes or compilation error diagnostics.
* ``os_spawn_actor(name: string, chunk_bytes: string, initial_caps: string[])``: Instantiates a new isolated actor domain executing the provided bytecode.
* ``os_send_ipc(actor_id: int, message: string)``: Dispatches typed IPC messages to an actor's input ring.

**User Interface & Canvas Compositing**:
* ``ui_draw_rect(x: int, y: int, w: int, h: int, color: int)``: Renders solid 2D rectangles.
* ``ui_draw_text(x: int, y: int, text: string, fg: int, bg: int)``: Renders vector typography using the 8x8 font engine.
* ``ui_clear(color: int)``: Clears the GOP framebuffer canvas.
* ``ui_create_window(title: string, x: int, y: int, w: int, h: int)``: Constructs window chrome for desktop environment experiments.

**Skill & Knowledge Retrieval**:
* ``skill_read(name: string)``: Ingests complete operational guides, language manuals, or hardware references on demand.

4. Resident AI Knowledge Corpus & Dynamic Skill Architecture
============================================================

4.1 Dynamic Boot Telemetry Ingestion
------------------------------------
Upon establishing the Cognitive Link, the Cognitive Actor dynamically synthesizes a machine constitution injected into Gemini's `systemInstruction`:
* **Physical Hardware Topology**: Exact CPU vendor, CPUID feature flags (AVX2, TSC, etc.), total physical RAM, usable RAM frames, PCI device map, GOP display resolution (1280x800, 32bpp), and APIC timer calibration.
* **Operating Substrate State**: Current microkernel version, active actors, Root CSpace allocation, and IPC ring geometry.

4.2 Embedded Genesis Skills Corpus
----------------------------------
The Genesis bundle (`genesis.mcb`) packages an authoritative skill corpus embedded directly in physical memory, accessible via `skill_read`:
1. **Skill: `macros-development`**: Complete language reference manual, grammar, type inference rules, Immix GC mark-region line/block allocation, and VM bytecode opcode dictionary.
2. **Skill: `capability-governance`**: Mathematical rights attenuation rules, `CSpace` operations, SPSC IPC ring protocol, and delegation boundaries.
3. **Skill: `hardware-control`**: PCI configuration space access, MMIO mapping, VirtIO virtqueue management, framebuffer vector rendering, and ACPI power management.
4. **Skill: `autonomous-construction`**: Protocols for writing, compiling via `lib/macros/compiler.mx`, spawning isolated worker actors, and executing verification tests.
5. **Skill: `fault-remediation`**: Ingesting 40-byte `FaultFrame` register dumps, analyzing `#PF`/#GP`/#DE` exceptions, and hot-patching running actors.

With this corpus and tool suite, the AI resident possesses absolute self-awareness of its host machine and complete operational competence from the first instruction.
