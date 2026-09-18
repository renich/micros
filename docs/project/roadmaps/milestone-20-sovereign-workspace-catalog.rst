Milestone 20: Sovereign Catalog Broker & Semantic Workspace Substrate
=====================================================================

:Objective: Formalize the Sovereign Catalog Broker and Semantic Workspace Substrate for MicrOS (µOS), providing human developers and autonomous AI agents with a persistent, named workspace home, Optimistic Concurrency Control (OCC), and full-screen visual text editing without mutable POSIX inodes or unchecksummed disk blocks.
:Status: Complete & Verified
:Specifications: `SPEC-TECH-FS-001`, `SPEC-TECH-AI-002`

Milestones & Deliverables
-------------------------

* **M20.1: Merkle Workspace Manifest & Path Sanitization** [COMPLETE & VERIFIED]
   - Implemented ``src/kernel/storage/manifest.zig`` with 128-byte fixed-size ``WorkspaceEntry`` records.
   - Enforced single-pass path sanitization, rejecting path traversal (``..``), backslashes (``\``), double slashes (``//``), and non-printable control characters.
   - Maintained lexicographically sorted entries enabling $O(\log N)$ binary search lookup.
   - Stored serialized manifests in ``ChunkType.workspace_manifest`` (type 6) chunks in BLAKE3 CAS.

* **M20.2: Sovereign Catalog Broker & OCC Commit Protocol** [COMPLETE & VERIFIED]
   - Implemented ``src/kernel/storage/catalog_abi.zig`` managing in-memory staging workspaces.
   - Persisted file contents as immutable raw BLAKE3 chunks in CAS.
   - Enforced Optimistic Concurrency Control (OCC) generation counter advancement, guaranteeing atomic commits and preventing split-brain multi-actor overwrites.

* **M20.3: Capability-Gated Workspace Syscall ABI** [COMPLETE & VERIFIED]
   - Exposed 6 native syscalls in ``src/kernel/abi.zig``: ``sys_catalog_write``, ``sys_catalog_read``, ``sys_catalog_list``, ``sys_catalog_delete``, ``sys_catalog_commit``, and ``sys_catalog_status``.
   - Gated all operations strictly through ``CapType.storage_device`` in the caller actor's CSpace.

* **M20.4: MicroShell Stream-Oriented Workspace Commands** [COMPLETE & VERIFIED]
   - Extended ``lib/macros/msh.mx`` with stream-oriented workspace commands: ``ls [prefix]``, ``cat <path>``, ``write <path> <text>``, ``rm <path>``, ``commit [msg]``, ``workspace``, and ``edit <path>``.
   - Provided seamless persistent file management for human developers and administrative automation scripts.

* **M20.5: Sovereign Visual Text Editor Actor (vedit)** [COMPLETE & VERIFIED]
   - Authored standalone full-screen visual text editor actor in ``lib/macros/vedit.mx``.
   - Rendered UI directly to 1280x800 UEFI GOP framebuffer canvas and serial console with title bar, line numbering gutter, cursor navigation, viewport scrolling, atomic ``Ctrl+S`` CAS save/commit, and clean ``Ctrl+Q`` exit.
   - Packaged ``vedit.mx`` into ``src/kernel/genesis.mcb``.

* **M20.6: Autonomous Script Execution & Resident AI Integration** [COMPLETE & VERIFIED]
   - Implemented ``msh run <path>`` executing pure Macros scripts stored in the workspace catalog or Genesis bundle.
   - Implemented ``msh ai <prompt>`` dispatching conversational requests to Resident AI with multi-turn tool calling and code synthesis.
   - Verified interactive file creation, catalog listing, persistence across reboots, and visual text editing under QEMU UEFI with zero defects.
