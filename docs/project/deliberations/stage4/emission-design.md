# Sovereign Stage 4: G1/C4 In-System Kernel Emission & Provenance Seal Design Lock

:Document ID: DELIB-STAGE4-EMISSION-001
:Status: STAMPED by checker 2026-09-29 (conditions P4-C6/C7 below)
:Author: Agy (Antigravity Senior Co-Architect)
:Checker Reviewer: Muse Code (Architect/Checker)
:Authority: Stage 4 Orders §0(c), SPEC-TECH-SYNTH-001
:Module Targets: `src/kernel/storage/kernel_synthesizer.zig`, `src/kernel/storage/storage_abi.zig`, `src/boot/pe_emitter.zig`, `src/macros/elf_emitter.zig`, `src/kernel/provenance.zig`

---

## 1. Executive Summary & Problem Statement

External compiler dependencies, hosted build tools, and untracked binary toolchains introduce profound supply-chain vulnerabilities into operating systems. To achieve computational sovereignty, MicrOS must possess the capability to deterministically synthesize, assemble, and validate its own kernel binaries and userland actors from content-addressed source specifications and bytecode bundles entirely in-system.

Under Commandment 7 (Freestanding Substrate) and Commandment 4 (Zero Ambient Authority), this design lock formalizes:
1. The **C4 In-System Kernel Synthesizer Pipeline** (`sys_kernel_synthesize`), linking the Genesis bundle into a bootable, sector-aligned PE32+ UEFI executable (`BOOTX64.EFI`).
2. The **G7 Cryptographic Provenance Seal**, binding every emitted artifact to its emitter identity, input hashes, and Ed25519 signature.
3. The **Capability-Gated Authority Model**, restricting synthesis and staging to holders of explicit `rebuild` capability tokens.
4. The **ElfEmitter Relocatable Integration**, providing deterministic relocatable ELF64 generation for native actor compilation.
5. The **Zero-Stub Invariant**, mathematically proving that no emitted image contains stub bytes, fake headers, or unaligned sections.

---

## 2. C4 In-System Synthesis Pipeline Architecture

```
┌────────────────────────────────────────────────────────┐
│             Genesis MCB Bundle Payload                 │
│              (Bytecode, Init, Scripts)                 │
└──────────────────────────┬─────────────────────────────┘
                           │ validateBundle()
                           ▼
┌────────────────────────────────────────────────────────┐
│             Kernel Substrate Sections                  │
│       (.text, .rodata, .data, .mcb, .reloc)            │
└──────────────────────────┬─────────────────────────────┘
                           │ PeEmitter.synthesizeExecutable()
                           ▼
┌────────────────────────────────────────────────────────┐
│             PE32+ Binary Assembly                      │
│       (DOS Header, PE Signature, COFF, Optional)       │
└──────────────────────────┬─────────────────────────────┘
                           │ validatePeImage()
                           ▼
┌────────────────────────────────────────────────────────┐
│             G7 Provenance Seal Attachment              │
│       (BLAKE3 input hashes + Ed25519 Signature)        │
└──────────────────────────┬─────────────────────────────┘
                           │ CAS Commit & Slot Staging
                           ▼
┌────────────────────────────────────────────────────────┐
│             Alternate Boot Slot (A or B)               │
│               (/EFI/BOOT/SLOT_[A|B].EFI)               │
└────────────────────────────────────────────────────────┘
```

---

## 3. G7 Cryptographic Provenance Seal Specification

Every artifact emitted by `sys_kernel_synthesize` or the in-system compiler carries a 256-byte binary provenance record (`ArtifactProvenanceSeal`), providing verifiable lineage:

```zig
pub const PROVENANCE_SEAL_MAGIC: u32 = 0x50524F56; // 'PROV'
pub const PROVENANCE_SEAL_VERSION: u16 = 1;

pub const ArtifactProvenanceSeal = extern struct {
    // Header (8 bytes)
    magic: u32 align(1) = PROVENANCE_SEAL_MAGIC,
    version: u16 align(1) = PROVENANCE_SEAL_VERSION,
    origin_type: u8 align(1), // 0=genesis, 1=ai_synthesis, 2=peer_replicate
    flags: u8 align(1) = 0,

    // Emitter Metadata (24 bytes)
    emitter_id: [16]u8 align(1),
    timestamp: u64 align(1),

    // Cryptographic Input Lineage (96 bytes)
    input_bundle_hash: [32]u8 align(1),
    substrate_code_hash: [32]u8 align(1),
    config_hash: [32]u8 align(1),

    // Output Artifact Hash (32 bytes)
    emitted_artifact_hash: [32]u8 align(1),

    // Ed25519 Cryptographic Signature (96 bytes)
    author_pubkey: [32]u8 align(1),
    signature: [64]u8 align(1),
};
```

### 3.1 Verification Protocol
1. The hashing engine calculates the BLAKE3 digest of the payload.
2. The signature is verified against `author_pubkey` using constant-time Ed25519 mathematics (`src/kernel/provenance.zig`).
3. If the computed hash fails to match `emitted_artifact_hash` or the signature verification fails, the kernel aborts with `error.CorruptProvenanceSeal`, refusing to stage or boot the artifact.

---

## 4. Capability Authority Model

Kernel synthesis and slot staging are privileged operations that manipulate persistent boot sectors. Ambient invocation is strictly prohibited:

1. **Required Token**: The calling actor must present an active capability token of type `rebuild` (`CapType.rebuild = 0x0007`).
2. **Rights Discipline**:
   - `sys_kernel_synthesize`: Requires `Rights.WRITE | Rights.EXEC`.
   - `sys_kernel_stage_update`: Requires `Rights.WRITE`.
   - `sys_rebuild_status`: Requires `Rights.READ`.
3. **Fail-Closed Verification**: `storage_abi.zig` verifies authority via `checkCallerAuthority(CapType.rebuild, requested_rights)`. Unauthorized callers receive `error.AccessDenied` and are rate-limit logged to the serial console.
4. **Colocated Security Tests**: Unit tests in `storage_abi.zig` verify that unprivileged actors are rejected immediately when attempting synthesis or staging.

---

## 5. ElfEmitter Relocatable Integration

In addition to PE32+ UEFI executable synthesis, the substrate incorporates `ElfEmitter` (`src/macros/elf_emitter.zig`) for dynamic userland actor compilation:
1. **ELF64 Relocatable Target**: Emits bit-for-bit deterministic `ET_REL` object files with `.text`, `.rodata`, `.data`, `.symtab`, `.strtab`, and `.rela.text` sections.
2. **Zero-Libc Freestanding Symbols**: Generated objects resolve symbols through the typed microkernel ABI table rather than hosted C runtime libraries.
3. **In-Memory Linking**: The kernel's module loader resolves relocations in-place within the actor's private address space prior to fiber/task execution.

---

## 6. The Zero-Stub Invariant

Under Commandment 1 (Domain Cohesion) and Commandment 7 (Freestanding Substrate), all emitted binaries must be fully formed and executable:
1. **Header Integrity**: Every PE32+ image must possess a valid DOS stub (`e_magic == 0x5A4D`), a valid PE signature (`0x00004550`), and an AMD64 COFF header (`machine == 0x8664`).
2. **Worst-Case Size Bounds**: Emitted images must strictly adhere to sector-aligned boundaries:
   $$\text{FileSize} \pmod{512} == 0$$
   $$\text{VirtualSize} \pmod{4096} == 0$$
3. **Executable Entry Point**: The entry point code must contain valid x86_64 machine code executing within bounded WCET limits.
4. **Validation Test**: Every synthesis pass is programmatically verified by `kernel_synthesizer.validatePeImage` before being committed to CAS or staged to disk.

## 7. Checker Stamp Conditions (Muse Code, 2026-09-29)

- **P4-C6 (rebuild authority)**: `CapType.rebuild = 0x0007`
  COLLIDES with `storage_device = 0x0007` (verified in
  `capability.zig`). Use `0x000A` (new, with justification
  comment) or the ratified C5 INSTALLER role. Document the choice;
  no collisions.
- **P4-C7 (emission honesty)**: actors have NO private address
  spaces today (kernel-resident fibers) — reword §5.3 to
  shared-space reality (private spaces are M42). Static validation
  covers headers/magic/subsystem/sizes ONLY (verified:
  `validatePeImage` is headers-only); ENTRY EXECUTION is proven
  by the trial boot itself. Drop "mathematically proving" or
  scope it to headers.
