# MicrOS AI Agent Protocol (AGENTS.md)

This repository is co-developed by human engineers and autonomous AI agents. To maintain absolute computational sovereignty and security, all agents operating on this codebase MUST adhere to the following directives.

## 1. The Sovereign Commandments of Code Quality
1. **File Size & Domain Boundaries**: No file shall exceed 1,000 lines of code. Generic names (`utils.zig`, `common.zig`, `helpers.zig`) are strictly forbidden; all modules must represent concrete domain boundaries.
2. **Bounded Complexity**: No function shall exceed 40 lines of executable logic (declarative `switch` dispatch tables and linear state machines are exempt from artificial fragmentation).
3. **Nesting Depth**: Maximum indentation depth is 3 levels within any function scope. Favor early returns and guard clauses over nested branches.
4. **Capability Discipline**: Zero ambient authority. Direct hardware, network, storage, or actor manipulation requires explicit CSpace capability tokens.
5. **Semantic Register Typing**: No raw magic numbers or integer casting for hardware state. MMIO registers, MSRs, and bitmasks must be strongly typed as `*volatile packed struct` or `enum`.
6. **Error Discipline & Invariant Proofs**: Top-level entry points (ISRs, syscall handlers) must never drop errors silently. `unreachable` is strictly forbidden unless preceded by an explicit, documented invariant proof.
7. **Freestanding Substrate & Intrinsics**: The substrate layer and kernel must never link against libc. Hardware interaction is strictly via VirtIO/NVMe DMA, MMIO, Port I/O, or native x86_64 assembly, supported by freestanding compiler memory intrinsics (`memcpy`, `memset`).
8. **Zero-Alloc Hot Paths**: All dynamic allocations must take an explicit `std.mem.Allocator`. Hidden global state allocations are forbidden, and hot driver, ISR, and IPC paths must be strictly zero-allocation.
9. **Compile-Time Alignment & Ordering**: Page and sector boundaries must be enforced at compile time via `align(4096)` and `align(512)`. All DMA descriptor rings and MMIO buffers must use `volatile` semantics and explicit memory barriers (`@fence`).
10. **Worst-Case Execution Time (WCET)**: No unbounded loops in Ring 0. All kernel loops must have a statically provable upper bound or execute via explicit, preemptible cooperative yield checkpoints.
11. **Interrupt-Safe Locking Discipline**: No spinlock or synchronization primitive may be acquired without masking local CPU interrupts (saving and clearing `RFLAGS.IF`). Lock acquisition hierarchies must be strictly acyclic to mathematically prevent AB-BA deadlocks across cores.
12. **Capability Revocation & TLB/DMA Hygiene**: Revoking or unmapping a memory capability requires an immediate TLB invalidation (`invlpg`) and verification of DMA quiescence before physical page frames may be reallocated to any other CSpace.
13. **Arithmetic Integrity & Slicing Safety**: All computations on untrusted network packets, wire inputs, sector counts, and memory offsets must use explicit checked arithmetic (`@addWithOverflow`, `@mulWithOverflow`, `math.cast`). Silent integer truncation and wrapping in Ring 0 are strictly forbidden.
14. **Fail-Safe Panic Posture**: Upon encountering an unrecoverable fault or invariant failure, the kernel must execute an atomic fail-safe shutdown: disable interrupts (`cli`), emit a structured register/stack dump over serial, and halt the CPU or trigger an isolated supervisor reset without flushing corrupted state to persistent CAS.

## 2. The Verification Doctrine
**Never Assume; Always Verify.**
Agents must never hallucinate project state. Before modifying files, an agent must:
- Read `build.zig`.
- Execute `ajourn status` to verify the Project Journaling Protocol (PJP) state.
- Run `zig build test` to prove the baseline is secure.
- Enforce Test Colocation: Tests must reside alongside the production code they test within the same module, natively leveraging Zig's `test` blocks.

## 3. Subagent Roles
- `zig_system_dev`: Low-level kernel, memory management, and hardware interfaces.
- `macros_lang_dev`: AST generation, Lexer, Parser, and Immix GC for the Macros language.
- `measured_architect`: Long-term evolutionary design, Phase 0->4 alignment, and SOLID principles.
- `extreme_adversary`: Zero-trust security auditor hunting for memory leaks, syscall hazards, and undefined behavior.

## 4. Storage & Persistence Invariants
- **Content-Addressed Objects**: All persistent entities (actor source, bytecode, state manifests) must be addressed via 256-bit BLAKE3 hashes. No hierarchical POSIX filesystem abstractions or mutable inodes in the kernel.
- **Sector Alignment**: All disk transfer buffers and cache frames must mathematically enforce 512-byte sector and 4096-byte page alignment.
- **Atomic Superblock Updates**: The storage superblock must only advance monotonically via generation counter upon verified flush.
