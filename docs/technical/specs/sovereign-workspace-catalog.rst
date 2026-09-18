========================================================================
Sovereign Catalog Broker & Semantic Workspace Substrate (µOS)
========================================================================

:Document ID: SPEC-TECH-FS-001
:Status: Approved
:Traced Stories: [US-REN-001], [US-REN-006], [US-REN-008], [US-GEM-001], [US-GEM-009], [US-GEM-010]
:Parent Architecture: `SPEC-TECH-STORAGE-001`, `SPEC-TECH-CAP-001`, `SPEC-TECH-NET-003`
:Module Targets: ``src/kernel/storage/manifest.zig``, ``src/kernel/storage/catalog_abi.zig``, ``lib/macros/msh.mx``, ``lib/macros/vedit.mx``

1. Architectural Axioms & Purpose
=================================
This specification formalizes the Sovereign Catalog Broker and Semantic Workspace Substrate for MicrOS (µOS). It satisfies the fundamental human and autonomous AI need for a persistent, named workspace home (e.g., *"Hey, I need a home to put my files at. I need tools to edit and modify them."* and *"Can I ask it to create the ls command for me?"*) while permanently rejecting the 50-year legacy debt of mutable POSIX inodes, hierarchical directory locks, and un-checksummed storage blocks.

1.1 The Zero-POSIX Semantic Workspace Doctrine
----------------------------------------------
POSIX filesystems intertwine path resolution, inode allocation, discretionary access control (DAC), and disk block allocation into a stateful, crash-vulnerable tree. In MicrOS:

* **Flat Content-Addressed Storage**: All persistent data entities are immutable chunks addressed exclusively by 256-bit BLAKE3 hashes.
* **Canonical Workspace Manifests**: A workspace state is represented by a bounded, deterministic Merkle manifest (``WorkspaceManifest``) recording sorted path strings, content byte sizes, and BLAKE3 payload hashes.
* **Single-Pass Path Sanitization**: Path identifiers are bounded strings (up to 64 bytes) strictly validated against path traversal (``..``), backslashes (``\``), double slashes (``//``), control characters, and leading/trailing slashes.
* **Optimistic Concurrency Control (OCC)**: Concurrent edits across human terminal sessions, autonomous AI agents, and remote Git push ingestions stage changes independently and commit atomically via compare-and-swap generation counters without blocking locks.

1.2 The Object-Capability Security Gate
---------------------------------------
Workspace operations are strictly capability-gated through the caller's Capability Space (CSpace):

* **Read Authority**: ``sys_catalog_read``, ``sys_catalog_list``, and ``sys_catalog_status`` require ``CapType.storage_device`` with ``Rights.READ``.
* **Write Authority**: ``sys_catalog_write``, ``sys_catalog_delete``, and ``sys_catalog_commit`` require ``CapType.storage_device`` with ``Rights.WRITE``.
* **Domain Isolation**: Unprivileged guest actors without storage capabilities cannot inspect or tamper with workspace catalog states.

2. Merkle Workspace Manifest Layout
===================================

2.1 Binary Geometry & Invariants
--------------------------------
The Merkle Workspace Manifest structure is optimized for zero-libc freestanding environments, $O(\log N)$ binary searching, and deterministic serialization:

.. code-block:: zig

   pub const MAX_FILENAME_LEN: usize = 64;
   pub const MAX_WORKSPACE_ENTRIES: usize = 256;
   pub const WORKSPACE_MANIFEST_MAGIC: u32 = 0x4D494357; // "MICW"
   pub const WORKSPACE_MANIFEST_VERSION: u32 = 1;

   pub const WorkspaceEntry = extern struct {
       name: [MAX_FILENAME_LEN]u8,
       name_len: u16,
       flags: u16,
       size: u32,
       hash: [32]u8,
       mtime: u64,
       reserved: [16]u8,
   };

   pub const WorkspaceManifestHeader = extern struct {
       magic: u32,
       version: u32,
       generation: u64,
       entry_count: u32,
       reserved: u32,
       total_bytes: u64,
       prev_manifest_hash: [32]u8,
       commit_msg: [64]u8,
       checksum: [32]u8,
   };

2.2 Deterministic Sorting & Search
----------------------------------
Entries within a manifest are strictly maintained in ascending lexicographical order by file path. Path lookups utilize binary search with zero memory allocation. Insertion verifies workspace capacity (up to 256 entries per manifest node) and maintains sort order via in-place shift.

3. Native System ABI Primitives
===============================
The catalog broker exposes six native primitives to the Macros virtual machine:

* **``sys_catalog_write(path: string, content: string) -> string``**: Computes the BLAKE3 digest of ``content``, persists the payload chunk to CAS, inserts or updates the entry in the active catalog manifest, and returns the 64-character hexadecimal hash.
* **``sys_catalog_read(path: string) -> string``**: Resolves ``path`` against the active catalog, retrieves the underlying blob from CAS, and returns the byte payload as a string. Returns empty string if not found.
* **``sys_catalog_list(prefix: string) -> string``**: Formats all active entries matching ``prefix`` into a tab-delimited listing: ``<path>\t<size>\t<hash>\n``.
* **``sys_catalog_delete(path: string) -> bool``**: Removes the specified entry from the catalog manifest and updates aggregate statistics.
* **``sys_catalog_commit(msg: string) -> string``**: Serializes the manifest into a ``ChunkType.workspace_manifest`` (type 6) chunk, stores it to CAS, advances the generation counter, and returns the new manifest root hash.
* **``sys_catalog_status() -> string``**: Returns a JSON-formatted summary of generation counter, active entry count, total byte footprint, and active root hash prefix.

4. MicroShell Integration & Sovereign Visual Editor
===================================================

4.1 MicroShell Workspace Commands
---------------------------------
``msh.mx`` exposes stream-oriented workspace commands:

* ``ls [prefix]``: Lists catalog entries with size and truncated BLAKE3 hash.
* ``cat <path>``: Prints file contents to console and framebuffer.
* ``write <path> <text>``: Writes text to named workspace path and updates catalog.
* ``rm <path>``: Deletes named file from catalog.
* ``commit [msg]``: Creates an OCC snapshot of the catalog in CAS.
* ``workspace``: Displays current catalog generation, entry count, and root.
* ``edit <path>``: Launches the full-screen visual editor (``vedit.mx``).

4.2 Sovereign Visual Text Editor (vedit)
---------------------------------------
``lib/macros/vedit.mx`` provides an interactive full-screen text editor rendering directly to the 1280x800 GOP compositor framebuffer with simultaneous serial ANSI console support:

* **Header Status Bar**: Displays active filename, modification state (``[CLEAN]`` / ``[MODIFIED]``), cursor coordinate (``Ln R, Col C``), and command shortcuts.
* **Line Number Gutter**: Formats 4-character right-aligned line numbers in slate gray (``CLR_MUTED``).
* **Viewport Scrolling**: Displays up to 45 lines of text with horizontal and vertical cursor tracking.
* **Dual Key Navigation**: Normalizes PS/2 scancodes and serial ANSI escape sequences (``\x1b[A`` .. ``\x1b[D``) for arrow keys, backspace, and line splits.
* **Atomic CAS Persistence**: Pressing ``Ctrl+S`` (code 19) serializes editor lines, invokes ``sys_catalog_write``, commits the workspace snapshot via ``sys_catalog_commit``, and updates status without exiting. Pressing ``Ctrl+Q`` (code 17) terminates the editor session and returns control to MicroShell.
