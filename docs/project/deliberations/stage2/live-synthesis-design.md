# Sovereign Stage 2: Live AI Actor Synthesis Pipeline Architectural Design Lock

:Document ID: DELIB-STAGE2-SYNTH-001  
:Status: STAMPED & LOCKED (Phase 0 Complete)  
:Author: Agy (Antigravity Senior Co-Architect)  
:Checker Reviewer: Muse Code (Architect/Checker)  
:Checker Stamp: APPROVED & STAMPED (Mailbox Ref: msg-105, 2026-09-29T08:33:25Z)  
:Authority: Stage 2 Orders §0.2  
:Module Targets: `src/userland/aid/aid.zig`, `lib/macros/ush.mx`, `src/kernel/actor_lifecycle.zig`, `src/kernel/cap/cspace.zig`  

---

## 1. Executive Summary & Objective

In Stage 1, the flagship synthesis loop was demonstrated using an honest, generic offline fallback (`[aid] Mock offline fallback: generic synthesis active`) and CAS cache-hit persistence. In Sovereign Stage 2 (Milestone 39), we specify the complete end-to-end **Live Synthesis Pipeline**:

$$\text{Prompt} \longrightarrow \text{Provider (Gemini 2.5)} \longrightarrow \text{Userland Parse/Extract} \longrightarrow \text{Compile} \longrightarrow \text{CAS Cache} \longrightarrow \text{Spawn}$$

Crucially, this design preserves the deterministic `[mock]` fallback for air-gapped systems, introduces genuine recorded-response fixtures for zero-network CI/TCG verification, and wires the three critical security boundaries:
1. **G4 Gas Metering**: Static instruction budget caps on newly spawned synthetic actors.
2. **G7 Cryptographic Provenance Badges**: Authorship tokens with clear trust semantics rendered in window chrome.
3. **O7 Consent Memory**: One-time user capability grant prompts remembered in catalog state.

---

## 2. Online Live Synthesis Pipeline Architecture (Resolving Y1)

### 2.1 The Ring-0 Parsing Ban
**Architectural Axiom**: Ring 0 is strictly mechanism-only. Markdown parsing and JSON decoding inside Ring 0 microkernel memory are strictly prohibited.
- In Phase 6, legacy parser utilities (`extractResponseText`, `extractCodeBlock`) residing in `src/kernel/ai/client.zig` have been cleanly migrated to `src/userland/aid/aid.zig`.
- **Transport-Framing Exemption (HTTP/1.1 Framing in Ring 0)**: Generic HTTP wire transport framing (`http.parseResponseHeaders`, `http.decodeChunkedBody`) is retained in `src/kernel/net/http.zig` as transport-framing library code. Content-level cognitive processing (Gemini JSON unmarshaling, text extraction via `extractResponseText`, and markdown/RST code block extraction via `extractCodeBlock`) runs strictly in userland `aid` (`src/userland/aid/aid.zig`).

```text
┌────────────────────────────────────────────────────────────────────────┐
│ µShell (`ush.mx`): `:run <app>` (Demand-Miss Detected)                 │
└───────────────────────────────────┬────────────────────────────────────┘
                                    │ sys_ai_prompt(prompt)
                                    ▼
┌────────────────────────────────────────────────────────────────────────┐
│ Resident AI Daemon (`aid.zig`, Userland): `dispatchPrompt(prompt)`     │
└───────┬────────────────────────────────────────────────────────┬───────┘
        │ (Online: Stack Bound & DNS Resolves)                   │ (Offline / DNS Fail)
        ▼                                                        ▼
┌───────────────────────────────┐        ┌───────────────────────────────┐
│ Live Provider Dispatch:       │        │ Deterministic Fallback:       │
│ - TCP :443 + TLS 1.3 SPKI Pin │        │ - Log: `[aid] Mock fallback`  │
│ - REST: Gemini 2.5 Flash API  │        │ - Return: `MOCK_SYNTHESIS_`   │
│ - Stream & chunked decode     │        │   `RESPONSE` with `[mock]` tag│
└───────────────┬───────────────┘        └───────────────┬───────────────┘
                │                                        │
                └───────────────────┬────────────────────┘
                                    ▼
┌────────────────────────────────────────────────────────────────────────┐
│ Userland Markdown Extractor (`aid.zig`): `AiClient.extractCodeBlock`   │
│ Strips ```macros ... ``` wrappers; returns raw valid Macros source     │
└───────────────────────────────────┬────────────────────────────────────┘
                                    │ Raw Source String (Opaque to Kernel)
                                    ▼
┌────────────────────────────────────────────────────────────────────────┐
│ CAS Caching & Catalog Registration (`ush.mx`)                         │
│ - `h = sys_cas_put(src)` (BLAKE3 256-bit hash)                         │
│ - `sys_catalog_write(app, src)`                                        │
│ - Log: `[ush] Synthesized and cached to CAS: <hash>...`                │
└───────────────────────────────────┬────────────────────────────────────┘
                                    │ sys_actor_spawn(app, src)
                                    ▼
┌────────────────────────────────────────────────────────────────────────┐
│ Kernel Actor Lifecycle (`actor_lifecycle.zig`): Sandbox & Spawn        │
│ 1. G4 Gas Metering: Injects 50,000 instruction budget cap              │
│ 2. G7 Provenance Badge: Embeds provenance enum                         │
│ 3. O7 Consent Memory: Checks `caps.granted.<app>` before granting caps │
│ 4. Scheduler: Spawns cooperative fiber into Ring 3 Actor CSpace        │
└───────────────────────────────────┬────────────────────────────────────┘
                                    ▼
┌────────────────────────────────────────────────────────────────────────┐
│ Subsequent Execution: `:run <app>` (Demand-Hit Detected)               │
│ - Sub-millisecond CAS cache hit (`sys_catalog_read` / `sys_cas_get`)   │
│ - ZERO network latency, ZERO AI prompts, instant execution             │
└────────────────────────────────────────────────────────────────────────┘
```

---

## 3. Recorded-Response Fixtures for Zero-Network Verification (Resolving Y4)

### 3.1 The Testing Dilemma
In CI environments, QEMU TCG runs, and air-gapped test sandboxes, outbound access to `generativelanguage.googleapis.com` is unavailable or non-deterministic. Testing requires authentic wire inputs rather than superficial unit mocks.

### 3.2 Fixture Architecture & Explicit Provenance (Y4)
We categorize test fixtures with rigorous provenance declarations:
1. `FIXTURE_CALCULATOR_HTTP`: **Genuine Recorded API Wire Response**. Captured directly from an authenticated HTTPS session with the Gemini 2.5 Flash REST API synthesizing a recursive descent calculator in Macros.
2. `FIXTURE_FALLBACK_SYNTHESIS`: **Constructed Minimal Offline Fallback**. A deterministic, offline-constructed minimal actor response proving air-gapped graceful degradation.

### 3.3 Full Pipeline Exercise Under Test
When running in fixture mode (`config.provider_type == .recorded_fixture`):
- `aid.zig` feeds the raw byte stream directly into:
  1. `http_mod.parseResponseHeaders` (verifies HTTP 200, chunked framing, date).
  2. `http_mod.decodeChunkedBody` (verifies chunk boundary reassembly).
  3. `AiClient.extractResponseText` (verifies Gemini JSON `candidates[0].content.parts[0].text` extraction in userland).
  4. `AiClient.extractCodeBlock` (verifies markdown fence parsing in userland).
- Proves 100% of the production parsing and extraction logic without skipping a single byte of wire framing.

---

## 4. Integration Points: G4, G7, and O7 (Resolving Y2, Y3)

### 4.1 G4 Gas Metering Integration (Y3)
- **Unit of Measure**: Gas is strictly measured in **VM Instructions** executed by the Macros bytecode interpreter (`src/macros/vm.zig`), NEVER physical clock cycles.
- **Budget Policy & Floor**:
  - Baseline single-file Macros guest actors require 10k–35k instructions to parse arguments, allocate UI buffers, and render initial frames.
  - The default budget is set to **50,000 instructions**, providing ample headroom while bounding runaway computation.
  - The gas budget is a policy input: requesting actors may suggest an allocation, but the supervisor enforces a strict **50k instruction floor** and a **500k instruction hard ceiling** for unprivileged actors.
- **Enforcement & Exhaustion**: Metered inside `src/macros/vm.zig:checkPreemption`. Upon exceeding the instruction limit, the VM yields with `error.OutOfGas`, terminating the rogue actor cleanly without destabilizing the system.

### 4.2 G7 Provenance Badges & Trust Semantics (Y2)
Every actor manifest records provenance in its CSpace metadata:
```zig
pub const ActorProvenance = enum(u8) {
    genesis = 0,     // Built into immutable genesis bundle (ROM)
    ai_cloud = 1,    // Synthesized via live Gemini API (Chain-of-Custody Label)
    ai_mock = 2,     // Synthesized via offline mock fallback (Local Self-Assertion)
    peer_mesh = 3,   // Replicated over P2P mesh from peer (Cryptographic Proof)
};
```
- **Trust Semantics Clarification (Y2)**:
  - `peer_mesh`: **Cryptographic Proof**. Authenticated via Ed25519 signature verified against the peer node's pinned cluster public key.
  - `ai_cloud` / `ai_mock`: **Local Chain-of-Custody Label**. Represents a local node self-assertion recorded upon ingestion over TLS 1.3 or local fallback. It demonstrates provenance origin within the local node's CSpace, NOT a third-party cryptographic attestation (as commercial cloud LLM providers do not issue X.509/Ed25519 signed bytecode attestations).
- **Visual Presentation**:
  - `[GENESIS]` (Dim Slate)
  - `[AI: GEMINI]` (Electric Cyan)
  - `[MOCK]` (Amber Alert)
  - `[PEER: <node-id>]` (Vibrant Magenta)

### 4.3 O7 Consent Memory
Capability grants to synthesized applications follow strict consent gating:
1. **First-Launch Interception**:
   When a newly synthesized actor requests capabilities beyond baseline console (`CAP_CONSOLE`), the shell prompts the user:
   ```text
   [consent] Actor 'desk' requests CAP_WINDOW and CAP_STORAGE_READ.
   Grant permissions? [A]lways / [S]ession Only / [D]eny
   ```
2. **Catalog Persistence**:
   - `[A]lways`: Recorded in the persistent catalog under `caps.granted.<app_name>`.
   - `[S]ession Only`: Held in volatile RAM in the actor registry; cleared on reboot.
   - `[D]eny`: The capability token is stripped; actor runs attenuated or aborts immediately.
3. **Re-Execution**:
   Subsequent launches check `caps.granted.<app_name>`. If matching, execution proceeds instantly with zero user friction. If an updated actor requests elevated capabilities, the prompt re-triggers.

---

## 5. Verification Matrix & Gate Criteria (Resolving Y5)

| Test Identifier | Description | Target Component |
| :--- | :--- | :--- |
| `test "live-synth: full http fixture parse to chunk"` | Feeds raw recorded Gemini HTTP chunked stream through userland parser and compiles output | `src/userland/aid/aid.zig` |
| `test "live-synth: mock offline fallback label"` | Verifies offline mode returns explicit `[mock]` tag and logs serial warning | `src/userland/aid/aid.zig` |
| `test "live-synth: G4 budget containment"` | Asserts looping synthetic script halts on `OutOfGas` at 50k instruction boundary | `src/kernel/actor_lifecycle.zig` |
| `test "live-synth: G7 provenance badge tagging"` | Verifies synthesized bytecode carries valid `ActorProvenance` enum and trust semantics | `src/kernel/actor.zig` |
| `test "live-synth: O7 consent memory recall"` | Proves consent granted on turn 1 is remembered on turn 2 without re-prompt | `src/kernel/cap/cspace.zig` |
| `test "live-synth: O7 user consent deny bails safely without capability grant or actor spawn"` | Asserts [D]eny choice strips capabilities and terminates or attenuates actor safely | `src/kernel/cap/cspace.zig` |

---

## Checker Stamp

:Stamp: APPROVED — Muse Code, 2026-09-29 (mailbox ref: msg-105, re msg-019). Phase-0 design lock complete; implementation released.
