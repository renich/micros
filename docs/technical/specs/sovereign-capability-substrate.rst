==================================================
Sovereign Capability Substrate & Genesis Actor Spec
==================================================

:Document ID: SPEC-TECH-CAP-001
:Status: Approved
:Traced Stories: [US-REN-001], [US-REN-006], [US-GEM-001], [US-GEM-007], [US-GEM-008]

1. Architecture Axioms & Post-POSIX Model
=========================================
MicrOS (µOS) rejects the legacy Unix ambient authority model, global process identifiers (PIDs), and untyped byte-stream file descriptors. All machine resources, hardware interfaces, memory mappings, and execution entities are mediated through an explicit Object-Capability model.

1.1 Zero Ambient Authority & The CSpace
---------------------------------------
- **Execution Actor**: An isolated computational unit possessing an address space (PML4 page directory), an execution context (fibers/threads), and a private Capability Table (CSpace).
- **Capability Handle**: An unforgeable 192-bit (24-byte) structure indexable only within an actor's local CSpace. An actor cannot reference, mutate, or inspect any resource without possessing an explicit capability grant.
- **Eradication of Root & PIDs**: There is no root user, no UID, no global PID namespace, and no ambient filesystem access. Process enumeration and signal spraying (e.g., `kill -9 <pid>`) are mathematically impossible.

2. Capability Primitives & ABI Specification
============================================

2.1 Capability Types
--------------------
Every capability in the system belongs to a strictly enumerated type:

.. code-block:: zig

   pub const CapType = enum(u16) {
       null_cap = 0x0000,
       memory_extent = 0x0001,
       ipc_ring = 0x0002,
       irq_endpoint = 0x0003,
       framebuffer = 0x0004,
       actor_control = 0x0005,
   };

2.2 Capability Rights & Permissions
-----------------------------------
Capabilities carry immutable bitmask rights enforced by the microkernel:

* `0x0001`: Read/Receive
* `0x0002`: Write/Send
* `0x0004`: Grant (delegation to other actors)
* `0x0008`: Revoke (privileged invalidation of capability; unprivileged local slot release via `drop`)
* `0x0010`: Execute/Schedule

2.3 Capability Table Representation
-----------------------------------
An actor's Capability Table (`CSpace`) is an isolated, page-aligned array of `Capability` entries managed by the microkernel:

.. code-block:: zig

   pub const Capability = extern struct {
       cap_type: CapType,
       rights: u16,
       object_id: u32,
       data_addr: u64,
       data_size: u64,
   };

3. Typed Lock-Free Shared-Memory IPC Rings
==========================================
Inter-actor communication does not pass through kernel byte-streams or POSIX file descriptors. Actors communicate over Single-Producer Single-Consumer (SPSC) lock-free shared-memory rings carrying strongly typed 64-byte message frames:

.. code-block:: zig

   pub const MessageType = enum(u16) {
       telemetry = 0x0001,
       stream_data = 0x0002,
       capability_grant = 0x0003,
       event_signal = 0x0004,
       yield_request = 0x0005,
   };

   pub const MessageFrame = extern struct {
       msg_type: MessageType align(64),
       flags: u16,
       sequence: u32,
       payload_len: u32,
       reserved: u32,
       payload: [48]u8,
   };

4. Immutable Genesis Capability Bundle (MCB)
============================================
Rather than mounting a legacy Unix CPIO or tar archive with filesystem paths and permissions, the microkernel loads an **Immutable Capability Bundle** (MCB):

- **Signature**: `0x4D494352_4F534D43` (`MICROSMC`).
- **Content-Addressed**: Each payload entry is identified by a 32-byte tag and its 32-byte BLAKE3 cryptographic digest.
- **Zero-Copy Access**: The bootloader maps the bundle into memory and grants a `memory_extent` capability directly to the Genesis Actor. The Macros VM reads bytecode and modules directly from this extent without disk traversal or file descriptor wrappers.

5. Direct Framebuffer Delegation
================================
Display hardware is mediated as a first-class `framebuffer` capability:

- The UEFI bootloader queries the Graphics Output Protocol (GOP) and records resolution, stride, format, and physical base address.
- The microkernel registers this physical extent as an unforgeable `framebuffer` capability in Actor 0's CSpace.
- The Genesis Actor delegates this capability to the visual compositor actor, which paints vector geometry and typography directly to the display without virtual terminal or tty emulation layers.

6. The Genesis Actor & Interactive MicroShell
=============================================
- **Actor 0 (Genesis)**: The primordial execution actor spawned by the microkernel during boot. It holds the root capabilities (`MemoryCap`, `SerialCap`, `FramebufferCap`, `BundleCap`).
- **MicroShell (`msh`) Integration**: `msh` executes as the interactive front-end of Actor 0. Pipelining occurs by passing typed Macros values over IPC rings rather than ASCII text streams.
