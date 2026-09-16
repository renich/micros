# MicrOS AI Agent Protocol (AGENTS.md)

This repository is co-developed by human engineers and autonomous AI agents. To maintain absolute computational sovereignty and security, all agents operating on this codebase MUST adhere to the following directives.

## 1. The Ten Commandments of Code Quality
1. **File Size**: No file shall exceed 1,000 lines of code.
2. **Function Size**: No function shall exceed 40 lines.
3. **Nesting Depth**: Maximum indentation depth is 3 levels.
4. **Formatting**: Never use spaces around forward slashes in text/markdown (e.g., `word/word`, not `word / word`).
5. **No Magic Numbers**: All constants must be strongly typed or defined in `UPPER_SNAKE_CASE` (e.g., `0x4D494352_4F534B45` for `MICROSKE`).
6. **Explicit Errors**: No `catch unreachable` outside of tests. All errors must be explicitly bubbled up using Zig error unions.
7. **No Libc**: The substrate layer (`src/sys/` and the kernel) must never link against or `#include` libc. Use direct Linux syscalls or native x86_64 inline assembly.
8. **Memory Safety**: All allocations must take an explicit `Allocator`. No hidden global state allocations.
9. **Page Alignment**: All `mmap` and hardware memory boundaries must strictly enforce 4096-byte page alignment mathematically.
10. **Test Colocation**: Tests must reside alongside the code they test within the same module, natively leveraging Zig's `test` blocks.

## 2. The Verification Doctrine
**Never Assume; Always Verify.**
Agents must never hallucinate project state. Before modifying files, an agent must:
- Read `build.zig`.
- Execute `ajourn status` to verify the Project Journaling Protocol (PJP) state.
- Run `zig build test` to prove the baseline is secure.

## 3. Subagent Roles
- `zig_system_dev`: Low-level kernel, memory management, and hardware interfaces.
- `macros_lang_dev`: AST generation, Lexer, Parser, and Immix GC for the Macros language.
- `measured_architect`: Long-term evolutionary design, Phase 0->4 alignment, and SOLID principles.
- `extreme_adversary`: Zero-trust security auditor hunting for memory leaks, syscall hazards, and undefined behavior.
