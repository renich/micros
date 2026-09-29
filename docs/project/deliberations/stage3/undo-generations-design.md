# Sovereign Stage 3: Generational Undo & Cascading Revocation Design Lock

:Document ID: DELIB-STAGE3-UNDO-001
:Status: STAMPED by checker 2026-09-29 (conditions P0-C3/C4 below)
:Author: Agy (Antigravity Senior Co-Architect)
:Checker Reviewer: Muse Code (Architect/Checker)
:Authority: Stage 3 Orders §0(b), SPEC-TECH-WORKSPACE-001, SPEC-TECH-CAP-001
:Module Targets: `src/kernel/storage/catalog_abi.zig`, `src/kernel/cap/cspace.zig`, `lib/macros/ush.mx`, `src/ush/shell.zig`

---

## 1. Executive Summary & Problem Statement

In previous milestones, `:undo` was a placeholder that emitted a message without restoring state, and catalog deletions hard-deleted records from a single mutable table. Furthermore, capability sub-token derivation lacked explicit parent-child lineage tracking, allowing child tokens to linger if a parent was revoked.

Under this design lock:
1. **Real Generational Undo**: The workspace catalog transitions to a content-addressed snapshot ring of generation roots. `:undo` atomically restores previous generation state with byte-identical readback proof. Undo is an append-only forward commit ($G + 1$), never a destructive history rewrite.
2. **C6 `@gen` Grammar**: The catalog and shell natively support generational addressing (`<artifact>@<gen>` and `catalog@<gen>`), allowing historical inspection alongside live state.
3. **Tombstone Records & GC Safe Window**: Deletions insert tombstone records retained across the active snapshot ring window. Garbage collection never purges blobs referenced by any snapshot in the ring.
4. **G6 Cascading Capability Revocation**: `mintSubToken` records parent lineage. Revoking a parent token atomically invalidates all descendant tokens (fail-closed), honoring Commandment 12 (`invlpg` and DMA quiescence).

---

## 2. Bounded Snapshot Ring Architecture

The kernel storage subsystem maintains an in-memory ring buffer of generation snapshot roots, with the full manifests backed by Content-Addressed Storage (CAS):

```zig
pub const MAX_SNAPSHOT_GENERATIONS: usize = 16;
pub const MAX_TAG_LEN: usize = 48;
pub const HASH_HEX_LEN: usize = 64;

pub const CatalogEntry = struct {
    tag: [MAX_TAG_LEN]u8,
    tag_len: usize,
    hash: [HASH_HEX_LEN]u8,
    is_tombstone: bool,
    generation: u64,
};

pub const GenerationSnapshot = struct {
    generation: u64,
    manifest_cas_hash: [HASH_HEX_LEN]u8,
    entry_count: usize,
    timestamp_cycles: u64,
};

pub const SnapshotRing = struct {
    snapshots: [MAX_SNAPSHOT_GENERATIONS]GenerationSnapshot = undefined,
    head: usize = 0,
    count: usize = 0,
    current_generation: u64 = 1,
};
```

### 2.1 Ring Bounds & FIFO Eviction Rule
- **Documented Bound**: `MAX_SNAPSHOT_GENERATIONS = 16`.
- **Monotonic Sequence**: Generation counter advances monotonically ($1, 2, 3, \dots$).
- **Overflow Policy**: When a new generation commit occurs and `count == MAX_SNAPSHOT_GENERATIONS`, the oldest snapshot at index `(head - count) % MAX_SNAPSHOT_GENERATIONS` is evicted from the ring. Evicted manifests remain in persistent CAS until offline storage vacuum, but are no longer directly addressable via single-step `:undo`.

---

## 3. Root Restore & Forward Undo Mechanics

### 3.1 Undo as a Monotonic Commit
In MicrOS, history is append-only. `:undo` does **NOT** decrement the generation counter or mutate prior manifests:
1. Current generation is $G$ (head snapshot).
2. Prior generation is $G - 1$ (snapshot at `head - 1`).
3. To execute `:undo`:
   - Substrate reads manifest $M_{G-1}$ from the ring or CAS.
   - Substrate mints new generation $G + 1$.
   - Manifest $M_{G+1}$ is constructed containing exact entries from $M_{G-1}$.
   - $M_{G+1}$ is hashed with BLAKE3 and committed to CAS.
   - New snapshot for generation $G + 1$ is pushed to the ring.
   - Active catalog root pointer atomically switches to $M_{G+1}$.
4. **Byte-Identical Readback Proof**: Every tag queried in generation $G + 1$ returns the identical BLAKE3 hash and content as it did in generation $G - 1$.
5. **Undo at Genesis**: If `count <= 1` or current generation is 1, `:undo` safely no-ops and prints an honest, diagnostic message: `[undo] At genesis generation; no prior snapshots to restore.`

---

## 4. C6 Generational Grammar & Catalog ABI

### 4.1 Shell Command Syntax
- `:show <tag>` -> Resolves and previews `<tag>` in current generation.
- `:show <tag>@<gen>` -> Resolves and previews `<tag>` at specified historical generation `<gen>`.
- `:show catalog` -> Lists all active tags in current generation.
- `:show catalog@<gen>` -> Lists all tags active at historical generation `<gen>`.

### 4.2 Kernel ABI Primitives
The substrate exposes explicit generational query and mutation syscalls:
```zig
// Read tag content; gen == 0 or negative resolves current generation
pub fn sys_catalog_read_gen(tag: []const u8, gen: u64) ?[]const u8

// List active tags for generation gen
pub fn sys_catalog_list_gen(gen: u64) []CatalogTagInfo

// Restore prior generation root atomically
pub fn sys_catalog_undo() bool

// Query active generation telemetry
pub fn sys_catalog_gen_status() GenerationStatus
```

---

## 5. Tombstone Record Shape & Garbage Collection Safe Window

### 5.1 Tombstone Lifecycle
When an artifact or tag is deleted via `:mesh unpublish`, `:catalog delete`, or user script:
1. The catalog does **NOT** erase the slot.
2. A tombstone record is written into the new generation manifest:
   ```zig
   CatalogEntry{
       .tag = tag_bytes,
       .tag_len = tag.len,
       .hash = [_]u8{'0'} ** 64, // Zero hash sentinel
       .is_tombstone = true,
       .generation = current_gen,
   }
   ```
3. Current generation queries for this tag return `null` (not found).
4. If `:undo` is subsequently invoked, the prior manifest (where `is_tombstone == false`) is re-committed, resurrecting the artifact without data loss.

### 5.2 Garbage Collection (GC) Retention Invariant
- A CAS chunk is eligible for reclamation **ONLY IF**:
  1. It is not referenced in the active live catalog manifest.
  2. It is not referenced in **ANY** of the 16 generation manifests currently stored in the `SnapshotRing`.
  3. It is not pinned by Genesis trust tables or active actor bytecode slots.
- Blobs referenced by historical snapshots in the ring window are permanently protected from GC sweep.

---

## 6. G6 Cascading Capability Revocation

To eliminate lingering ambient authority when an actor or subsystem is demoted, `CSpace` tracks explicit lineage trees.

### 6.1 Lineage Record Structure
Within `src/kernel/cap/cspace.zig`:
```zig
pub const MAX_CAPS_PER_CSPACE: usize = 64;

pub const CapabilitySlot = struct {
    cap: Capability,
    parent_slot: ?u16 = null,
    is_valid: bool = true,
    generation: u32 = 1,
};

pub const CSpace = struct {
    slots: [MAX_CAPS_PER_CSPACE]CapabilitySlot = [_]CapabilitySlot{.{
        .cap = Capability.NULL_CAP,
        .parent_slot = null,
        .is_valid = false,
        .generation = 0,
    }} ** MAX_CAPS_PER_CSPACE,
    count: usize = 0,
};
```

### 6.2 Derivation & Cascading Invalidation
1. **Derivation (`mintSubToken`)**:
   - Caller supplies `parent_handle: u16` and attenuated `requested_rights: u16`.
   - Substrate verifies `parent.rights.hasRight(Rights.GRANT)`.
   - New slot allocated with `parent_slot = parent_handle`.
   - Derived rights are monotonically narrowed (`child.rights = parent.rights & requested_rights`).
2. **Cascading Revocation (`revokeToken`)**:
   - Caller invokes `revokeToken(target_handle)`.
   - Caller must hold `Rights.REVOKE` on `target_handle` or be the owning supervisor.
   - Substrate recursively visits all slots where `parent_slot == target_handle`:
     - Sets `slot.is_valid = false`.
     - Zeroes `slot.cap.rights = Rights.NONE`.
     - Sets `slot.cap = Capability.NULL_CAP`.
     - Recursively revokes children of that child (depth-N cascade).
3. **Fail-Closed Verification**:
   - Any subsequent invocation of a descendant capability immediately returns `error.PermissionDenied` or `error.InvalidCapability`.
4. **Commandment 12 Memory Extent Invariants**:
   - If the revoked capability is `CapType.memory_extent` or `CapType.hardware_device`, the kernel immediately:
     1. Clears page table entries mapping the physical extent.
     2. Executes `invlpg` across all cores for the unmapped virtual addresses.
     3. Asserts DMA quiescence (device bus mastering cleared) before releasing the physical frames.

---

## 7. Colocated Unit & Subsystem Test Plan

1. `test "workspace: write-write-undo-readbackidentity"`:
   - Tag `app.state` written in Gen 1 (hash A).
   - Mutated in Gen 2 (hash B).
   - `:undo` executed -> Gen 3 active. Tag `app.state` returns hash A with byte-identical match.
2. `test "workspace: delete-tombstone-resurrect"`:
   - Tag created in Gen 1, deleted (tombstoned) in Gen 2.
   - Tag query returns `null` in Gen 2.
   - `:undo` executed -> Gen 3 active. Tag resurrected and readable.
3. `test "workspace: @gen-pinned read vs current"`:
   - Tag updated across 3 generations.
   - Querying `@1`, `@2`, and current returns distinct expected historical versions.
4. `test "workspace: undo-at-genesis is clean no-op"`:
   - Empty/Genesis state -> `:undo` returns false with zero faults and honest message.
5. `test "workspace: ring-overflow evicts oldest generation"`:
   - Commit 17 generations; verify generation 1 is evicted, generation 2 becomes oldest accessible, generation 17 is current.
6. `test "cap: depth-3 cascading revocation invalidates all descendants"`:
   - Token A -> Token B -> Token C.
   - Revoke Token A -> Tokens B and C immediately fail-closed.
7. `test "cap: sibling isolation on cascade"`:
   - Token A -> Token B1, Token B2.
   - Revoke Token B1 -> Token B1 dies, Token B2 lives.
8. `test "cap: double-revoke idempotence"`:
   - Revoking an already revoked token is safe and idempotent.

---

## 8. Convergence Checklist for Checker (Muse Code)

- [ ] Bounded snapshot ring locked at 16 generations with FIFO eviction.
- [ ] Root restore mechanics advance generation monotonically (no history rewrite).
- [ ] C6 `@gen` syntax and ABI specified for historical read and listing.
- [ ] Tombstone record structure defined with GC safety window.
- [ ] G6 cascade lineage with parent pointers and Commandment 12 compliance.

## 9. Checker Stamp Conditions (Muse Code, 2026-09-29)

- **P0-C3 (bounded cascade)**: §6.2 says "recursively revokes" — Ring 0
  forbids unbounded recursion (C10 WCET). Implement the cascade as an
  ITERATIVE worklist bounded by MAX_CAPS_PER_CSPACE (64); prove the bound
  in a depth-64 stress test (chain of 64 mints, revoke root, all die).
- **P0-C4 (tombstone + eviction honesty)**: tombstone detection keys on the
  `is_tombstone` FLAG, never on the zero-hash sentinel alone (zero hashes
  already mean "empty" elsewhere). `:show @gen` on an EVICTED generation
  prints an honest evicted message (ring bound + oldest live gen), never a
  bare not-found.
