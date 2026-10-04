# MicrOS AI Agent Protocol (AGENTS.md)

This repository is co-developed by human engineers and autonomous AI agents. To maintain absolute computational sovereignty and security, all agents operating on this codebase MUST adhere to the following directives.

## 1. The Sovereign Commandments of Code Quality
1. **File Size & Domain Cohesion**: Files should not exceed 1,000 lines of code, but **cohesion supersedes arbitrary metrics**. Generic names (`utils.zig`, `common.zig`, `helpers.zig`) are strictly forbidden; modules must represent concrete domain boundaries. Do not artificially fragment cohesive domain logic across multiple files just to appease line limits.
2. **Bounded Complexity & Anti-Golfing**: Functions should target a maximum of 40 lines of executable logic. **Artificial code-packing (stripping vertical whitespace, dense one-liners) to bypass this limit is strictly forbidden.** Declarative `switch` dispatch tables, linear state machines, and dense cryptographic/mathematical bounds are exempt from artificial fragmentation.
3. **Nesting Depth**: Maximum indentation depth is 3 levels within any function scope. Favor early returns and guard clauses over nested branches.
4. **Capability Discipline**: Zero ambient authority. Direct hardware, network, storage, or actor manipulation requires explicit CSpace capability tokens.
5. **Semantic Register Typing**: No raw magic numbers or integer casting for hardware state. MMIO registers, MSRs, and bitmasks must be strongly typed as `*volatile packed struct` or `enum`.
6. **Error Discipline vs. Environmental Noise**: Top-level entry points must never drop *internal* errors silently. However, untrusted input failures (e.g., malformed network packets, invalid cryptographic signatures, wire framing corruptions) are **Environmental Noise**, not invariant failures. They must be gracefully discarded and rate-limit logged, never allowed to bubble up into a system panic or halt. `unreachable` is strictly forbidden unless preceded by an explicit, documented invariant proof.
7. **Freestanding Substrate & Intrinsics**: The substrate layer and kernel must never link against libc. Hardware interaction is strictly via VirtIO/NVMe DMA, MMIO, Port I/O, or native x86_64 assembly, supported by freestanding compiler memory intrinsics (`memcpy`, `memset`).
8. **Zero-Alloc Hot Paths**: All dynamic allocations in the kernel must take an explicit `std.mem.Allocator`. Hidden global state allocations are forbidden, and hot driver, ISR, and IPC paths must be strictly zero-allocation.
9. **Compile-Time Alignment & Ordering**: Page and sector boundaries must be enforced at compile time via `align(4096)` and `align(512)`. All DMA descriptor rings and MMIO buffers must use `volatile` semantics and explicit memory barriers (`@fence`).
10. **Worst-Case Execution Time (WCET)**: No unbounded loops in Ring 0. All kernel loops must have a statically provable upper bound or execute via explicit, preemptible cooperative yield checkpoints.
11. **Interrupt-Safe Locking Discipline**: No spinlock or synchronization primitive may be acquired without masking local CPU interrupts (saving and clearing `RFLAGS.IF`). Lock acquisition hierarchies must be strictly acyclic to mathematically prevent AB-BA deadlocks across cores.
12. **Capability Revocation & TLB/DMA Hygiene**: Revoking or unmapping a memory capability requires an immediate TLB invalidation (`invlpg`) and mathematical verification of DMA quiescence before physical page frames may be reallocated to any other CSpace.
13. **Arithmetic Integrity & Slicing Safety**: All computations on untrusted network packets, wire inputs, sector counts, and memory offsets must use explicit checked arithmetic (`@addWithOverflow`, `@mulWithOverflow`, `math.cast`). Silent integer truncation and wrapping in Ring 0 are strictly forbidden.
14. **Fail-Safe Panic Posture**: Upon encountering an unrecoverable *internal fault* or state corruption, the kernel must execute an atomic fail-safe shutdown: disable interrupts (`cli`), emit a structured register/stack dump over serial, and halt the CPU or trigger an isolated supervisor reset without flushing corrupted state to persistent CAS.

## 2. Network & P2P Mesh Invariants (Phase 10)
1. **Cryptographic Sovereignty**: Zero unauthenticated RPCs. All node-to-node cluster communication must utilize authenticated framing (e.g., Noise Protocol Framework, mTLS) with Ed25519 node identities.
2. **Deterministic Wire Integrity**: Every wire payload requires deterministic MAC verification (e.g., BLAKE3/Poly1305).
3. **Replay & Sybil Defense**: All cluster state mutations over the wire must enforce strict replay protection via monotonic nonces, Lamport clocks, or generation counters.
4. **Zero-Copy Routing**: Network packets must stream via DMA directly into isolated CSpace buffers. Memory cannot be copied between kernel and userland; only capability tokens mapping to the packet buffer may be exchanged.

## 3. Substrate (Zig) vs. Userland (Macros) Boundaries
The 14 Commandments apply strictly to the freestanding Zig Substrate (Ring 0). Macros userland code operates under an isolated userland paradigm:
1. **Deterministic Bounded Execution**: Macros scripts cannot access unmetered loops or physical system clocks. All actor execution must be bounded by dynamic gas metering or cooperative fiber yield checkpoints.
2. **Capability Sandboxing**: Macros logic operates entirely in a sandboxed VM (Immix GC). It possesses zero ambient authority, no raw pointer access, and no direct hardware manipulation.
3. **Capability RPC Boundary**: All transitions between Macros userland and the Zig substrate must occur strictly via typed Capability ABI/RPC invocations.

## 4. Storage & Persistence Invariants
- **Content-Addressed Objects**: All persistent entities (actor source, bytecode, state manifests) must be addressed via 256-bit BLAKE3 hashes. No hierarchical POSIX filesystem abstractions or mutable inodes in the kernel.
- **Sector Alignment**: All disk transfer buffers and cache frames must mathematically enforce 512-byte sector and 4096-byte page alignment.
- **Atomic Superblock Updates**: The storage superblock must only advance monotonically via generation counter upon verified flush.

## 5. The Verification Doctrine
**Never Assume; Always Verify.**
Agents must never hallucinate project state. Before modifying files, an agent must:
- Read `build.zig`.
- Execute `ajourn status` to verify the Project Journaling Protocol (PJP) state.
- Run `zig build test` to prove the baseline is secure.
- Enforce Test Colocation: Tests must reside alongside the production code they test within the same module, natively leveraging Zig's `test` blocks.
- Regenerate the architectural edge baseline (`tools/micros-arch-gate src/ --dump-baseline docs/project/deliberations/stage4/import-baseline.txt`) only in the change that intentionally introduces the edge; `make check` rejects any edge absent from it. A green `make arch-gate` always states how many exemptions it granted.

### Quality Waivers
Rules in Section 1 may only be waived through an in-file, machine-readable declaration:

```text
// lint-waiver: <rule>[,<rule>...] [max=N] <reason>
```

- Valid rule ids: `forbidden-name`, `file-length`, `function-length`, `dispatch-length`, `nesting`, `catch-unreachable`.
- The reason is mandatory. A malformed waiver, or one naming an unknown rule, is reported as a violation.
- `max` (default `1`) is a hard ceiling on how many findings of each named rule that waiver may suppress. Growth beyond it fails `make lint`, so suppressed debt cannot expand silently.
- `make lint` echoes every waiver with its `used/max` counters. Ratchet `max` down when the real count drops, and delete unused waivers.
- Prose justification elsewhere in a file is welcome context but carries no authority; only the waiver line does.

## 6. Subagent Roles
- `zig_system_dev`: Low-level kernel, memory management, and hardware interfaces.
- `macros_lang_dev`: AST generation, Lexer, Parser, and Immix GC for the Macros language.
- `measured_architect`: Long-term evolutionary design, Phase 0->4 alignment, and SOLID principles.
- `extreme_adversary`: Zero-trust security auditor hunting for memory leaks, syscall hazards, and undefined behavior.
