---
name: micros-tools
description: Operational manual, CLI reference, and automation protocols for the MicrOS (µOS) substrate toolchain in tools/ (micros-runner, micros-fb-verify, micros-lint, micros-sym, micros-inspect, micros-telem, micros-spec-trace).
license: MIT
compatibility: dual
metadata:
  audience: developers
  workflow: substrate-engineering
  subagents: [lead_architect, junior_dev, scout, tech_writer, security_qa, sysadmin_devops, extreme_adversary, measured_adversary]
---

# MicrOS (µOS) Toolchain Protocol

This skill governs the operational usage, CLI conventions, and agent workflows for the verification, audit, and post-mortem tools in [`tools/`](file:///home/renich/Projects/zig/micros/tools/); Section 1 is the authoritative catalog.

```text
┌──────────────────────────────┬──────────────────────────────┬──────────────────┐
│                        MICROS (µOS) SUBSTRATE TOOLCHAIN                          │
├──────────────────────────────┼──────────────────────────────┼──────────────────┤
│ VERIFICATION & HARNESS       │ STATIC AUDIT & TRACEABILITY  │ POST-MORTEM      │
├──────────────────────────────┼──────────────────────────────┼──────────────────┤
│ • micros-runner              │ • micros-lint                │ • micros-inspect │
│ • micros-fb-verify           │ • micros-spec-trace          │ • micros-sym     │
│ • micros-fiber-bench         │ • micros-arch-gate           │ • micros-telem   │
└──────────────────────────────┴──────────────────────────────┴──────────────────┘
```

---

## 1. Tool Catalog & Capabilities

### 1.1. `micros-runner` — Event-Driven Headless QEMU Harness
* **Source**: [`tools/micros-runner.bash`](file:///home/renich/Projects/zig/micros/tools/micros-runner.bash)
* **Symlink**: [`tools/micros-runner`](file:///home/renich/Projects/zig/micros/tools/micros-runner)
* **Purpose**: Replaces blind, arbitrary sleep timers with deterministic, event-driven serial sentinel parsing and monitor socket control. Boots QEMU in UEFI or sandbox mode, detects kernel milestones in sub-second time, triggers monitor screendump capture on success, and cleanly terminates QEMU.
* **CLI Syntax**:
  ```bash
  ./tools/micros-runner [options]
  ```
* **Options**:
  * `--mode [uefi|sandbox]`: Execution mode (default: `sandbox`).
  * `--expect <pattern>`: Success regex sentinel to wait for before exiting. UEFI mode defaults to the resident shell banner `µShell`; sandbox mode defaults to `Substrate self-test verified (Macros 20+22=42)`.
  * `--fail <pattern>`: Regex marking catastrophic kernel panics (`KERNEL FATAL|CPU Exception|Kernel Panic|panic:`).
  * `--screendump <path.ppm>`: Captures QEMU GOP framebuffer via monitor socket upon success.
  * `--screenshot <path.png>`: Automatically converts captured PPM to PNG.
  * `--serial-log <path>`: Destination file for serial console capture.
  * `--timeout <seconds>`: Maximum execution duration (default: `10`s). On this host a cold UEFI boot needs ~25s, so boot gates pass `--timeout 30`.
  * `--monitor-sock <path>`: Unix socket path for QEMU monitor (default: `/tmp/micros-qemu-mon.sock`).
  * `--isa-debug-exit`: Enables QEMU `isa-debug-exit` device on port `0xf4`.
  * `--no-kvm`: Disables KVM hardware acceleration (uses TCG).
* **Usage Examples**:
  ```bash
  # Fast headless UEFI boot with screendump capture
  ./tools/micros-runner --mode uefi --screendump /tmp/micros_screendump.ppm

  # Direct-syscall Linux sandbox test
  ./tools/micros-runner --mode sandbox
  ```

---

### 1.2. `micros-fb-verify` — Framebuffer Visual Validator
* **Source**: [`tools/src/fb_verify.zig`](file:///home/renich/Projects/zig/micros/tools/src/fb_verify.zig)
* **Launcher**: [`tools/micros-fb-verify`](file:///home/renich/Projects/zig/micros/tools/micros-fb-verify)
* **Purpose**: Performs deterministic, sub-millisecond visual regression audits on raw PPM screendumps. Validates image dimensions, pixel color variance, and bounding-box color thresholds without heavyweight external dependencies.
* **CLI Syntax**:
  ```bash
  ./tools/micros-fb-verify [options] <image.ppm>
  ```
* **Options**:
  * `--width <px>`: Expected image width (default: `1280`).
  * `--height <px>`: Expected image height (default: `800`).
  * `--min-variance <float>`: Minimum standard deviation of pixel color values (default: `10.0`).
  * `--box <x,y,w,h,r,g,b>`: Asserts that at least 80% of pixels in the specified bounding box match the target RGB values within a tolerance of 15.
* **Usage Examples**:
  ```bash
  # Assert framebuffer is not blank and matches 1280x800 resolution
  ./tools/micros-fb-verify \
    --width 1280 \
    --height 800 \
    --min-variance 10.0 \
    /tmp/micros_screendump.ppm
  ```

---

### 1.3. `micros-lint` — Native Zig AST Linter
* **Source**: [`tools/src/lint.zig`](file:///home/renich/Projects/zig/micros/tools/src/lint.zig)
* **Launcher**: [`tools/micros-lint`](file:///home/renich/Projects/zig/micros/tools/micros-lint)
* **Purpose**: Native Zig AST static analysis engine parsing code using `std.zig.Ast` to enforce the Ten Commandments of Code Quality from [`AGENTS.md`](file:///home/renich/Projects/zig/micros/AGENTS.md) and [`ADR-006`](file:///home/renich/Projects/zig/micros/docs/adrs/ADR-006-code-quality-and-context-window-limits.rst).
* **Checks Enforced** (rule id in parentheses):
  * Max file lines $\le 1000$ (`file-length`)
  * Max function lines $\le 40$, raised to $\le 150$ when the function contains a `switch` dispatch (`function-length`, `dispatch-length`)
  * Max nesting depth $\le 3$ (`nesting`)
  * Zero forbidden names (`utils.zig`, `common.zig`, `helpers.zig`) (`forbidden-name`)
  * Prohibits `catch unreachable` unless an inline invariant proof documents why it cannot fire (`catch-unreachable`)
* **Quality Waivers**: A rule may only be waived through a standalone comment line inside the offending file:
  ```text
  // lint-waiver: <rule>[,<rule>...] [max=N] <reason>
  ```
  The reason is mandatory, `max` (default `1`) caps how many findings of each named rule that waiver may suppress, and growth beyond it fails the run. Every waiver is echoed with `used/max` counters so suppressed debt stays visible. A malformed waiver, or one naming an unknown rule, is itself reported as a violation. See [`AGENTS.md`](file:///home/renich/Projects/zig/micros/AGENTS.md) for the governing doctrine.
* **CLI Syntax**:
  ```bash
  ./tools/micros-lint <files/directories...>
  ```
* **Usage Examples**:
  ```bash
  # Lint all substrate sources
  ./tools/micros-lint src/

  # Inspect one file's waivers and their counters
  ./tools/micros-lint src/kernel/net/tls_client.zig
  ```

---

### 1.4. `micros-sym`/`micros-addr2line` — Freestanding Symbol Resolver & Unwinder
* **Source**: [`tools/src/sym.zig`](file:///home/renich/Projects/zig/micros/tools/src/sym.zig)
* **Launcher**: [`tools/micros-sym`](file:///home/renich/Projects/zig/micros/tools/micros-sym), symlinked to [`tools/micros-addr2line`](file:///home/renich/Projects/zig/micros/tools/micros-addr2line)
* **Purpose**: Parses 64-bit ELF symbol tables (`.symtab/.strtab`) directly to resolve instruction pointers into function symbols and byte offsets without external `llvm-symbolizer` or `addr2line`.
* **CLI Syntax**:
  ```bash
  ./tools/micros-sym [options] [addresses...]
  ```
* **Options**:
  * `-e, --elf <path>`: Path to ELF binary containing symbol tables (default: `zig-out/bin/micros-kernel.elf`).
  * `-f, --file <path>`: Scans a file (such as a serial log) for hexadecimal addresses and replaces them inline with symbol mappings.
  * `--format [text|json]`: Output format (default: `text`).
* **Usage Examples**:
  ```bash
  # Resolve specific instruction pointers
  ./tools/micros-sym 0x002014d4 0x002018c2

  # Resolve crash log callstack
  ./tools/micros-sym --file build/serial.log
  ```

---

### 1.5. `micros-inspect` — Non-Interactive QEMU Monitor Inspector
* **Source**: [`tools/micros-inspect.bash`](file:///home/renich/Projects/zig/micros/tools/micros-inspect.bash)
* **Symlink**: [`tools/micros-inspect`](file:///home/renich/Projects/zig/micros/tools/micros-inspect)
* **Purpose**: Connects non-interactively to the QEMU monitor unix domain socket (`/tmp/micros-qemu-mon.sock`) during a hang or test failure. Extracts CPU state, general-purpose registers (RAX, RBX, RCX, RDX, RSI, RDI, RBP, RSP, R8-R15), control registers (CR0, CR3, CR4), and disassembles machine instructions around RIP.
* **CLI Syntax**:
  ```bash
  ./tools/micros-inspect [options]
  ```
* **Options**:
  * `-s, --socket <path>`: Path to QEMU monitor socket (default: `/tmp/micros-qemu-mon.sock`).
  * `-o, --output <path>`: Output destination file.
  * `--format [text|json]`: Formats extracted diagnostic report (default: `text`).
  * `--disasm-count <N>`: Number of machine instructions to disassemble around RIP (default: `10`).
* **Usage Examples**:
  ```bash
  # Inspect live registers during QEMU execution
  ./tools/micros-inspect

  # Export machine state as JSON for AI automated diagnosis
  ./tools/micros-inspect --format json
  ```

---

### 1.6. `micros-telem` — Native Binary Telemetry Decoder
* **Source**: [`tools/src/telem.zig`](file:///home/renich/Projects/zig/micros/tools/src/telem.zig)
* **Launcher**: [`tools/micros-telem`](file:///home/renich/Projects/zig/micros/tools/micros-telem)
* **Purpose**: Decodes unforgeable 64-byte `TelemetryToken` and `FaultReport` structures emitted by the MicrOS kernel over shared-memory rings in accordance with [`docs/technical/specs/ai-telemetry-protocol.rst`](file:///home/renich/Projects/zig/micros/docs/technical/specs/ai-telemetry-protocol.rst).
* **CLI Syntax**:
  ```bash
  ./tools/micros-telem [options]
  ```
* **Options**:
  * `-f, --file <path>`: Path to telemetry binary ring stream (or reads stdin).
  * `--format [text|json]`: Output format (default: `text`).
  * `--follow`: Streams telemetry tokens continuously in real time.
  * `--generate [token|fault]`: Generates synthetic telemetry frames for pipeline testing.
  * `--resolve-symbols`: Automatically pipes callstacks through `micros-sym`.
* **Usage Examples**:
  ```bash
  # Generate and inspect synthetic token
  ./tools/micros-telem --generate token | ./tools/micros-telem --format json

  # Decode live kernel telemetry ring buffer with symbol resolution
  cat /dev/shm/micros-telemetry.bin | ./tools/micros-telem --resolve-symbols
  ```

---

### 1.7. `micros-spec-trace` — Bidirectional Traceability Auditor
* **Source**: [`tools/micros-spec-trace.bash`](file:///home/renich/Projects/zig/micros/tools/micros-spec-trace.bash)
* **Symlink**: [`tools/micros-spec-trace`](file:///home/renich/Projects/zig/micros/tools/micros-spec-trace)
* **Purpose**: Verifies full bidirectional traceability across the 4 tiers of the MicrOS specification corpus:
  1. **User Stories**: [`docs/business/specs/`](file:///home/renich/Projects/zig/micros/docs/business/specs/) (`[US-xxx]`)
  2. **Functional Requirements**: [`docs/functional/`](file:///home/renich/Projects/zig/micros/docs/functional/) (`[FUNC-xxx]`)
  3. **Technical Blueprints**: [`docs/technical/specs/`](file:///home/renich/Projects/zig/micros/docs/technical/specs/) (`[TECH-xxx]`)
  4. **Roadmap Execution Tasks**: [`docs/project/roadmaps/`](file:///home/renich/Projects/zig/micros/docs/project/roadmaps/) (`[TASK-xxx]`)
* **CLI Syntax**:
  ```bash
  ./tools/micros-spec-trace [options]
  ```
* **Options**:
  * `--docs-dir <path>`: Path to documentation root (default: `docs/`).
  * `--format [summary|matrix|json]`: Output display format (default: `summary`).
  * `--check`: Returns exit code 1 if any broken links or untraced requirements exist.
  * `--tag <tag_id>`: Traces full upstream/downstream dependency graph for an individual tag.
* **Usage Examples**:
  ```bash
  # Verify 100% specification traceability
  ./tools/micros-spec-trace --check

  # Inspect complete traceability matrix
  ./tools/micros-spec-trace --format matrix

# Trace dependency graph for telemetry technical specification
  ./tools/micros-spec-trace --tag TECH-TELEM-001
  ```

---

### 1.8. `micros-virtio-bench` — VirtIO Subsystem Benchmark & Geometric Validator
* **Source**: [`tools/src/virtio_bench.zig`](file:///home/renich/Projects/zig/micros/tools/src/virtio_bench.zig)
* **Launcher**: [`tools/micros-virtio-bench`](file:///home/renich/Projects/zig/micros/tools/micros-virtio-bench)
* **Purpose**: Freestanding geometric validator and micro-benchmark harness for VirtIO 1.0 split-virtqueue ring buffers, descriptor layouts, and multi-sector DMA batching.
* **CLI Syntax**:
  ```bash
  ./tools/micros-virtio-bench [options]
  ```
* **Options**:
  * `--validate`: Mathematically audits split-virtqueue geometries, ring alignments, descriptor sizes, and 512-byte sector DMA boundaries.
  * `--bench`: Executes RDTSC micro-benchmarking comparing single-sector serialization against batched DMA transfers, reporting speedup factor, cycle reduction, and VM exit trap savings.
  * `--iterations <N>`: Configures test iterations (default: `50000`).
* **Usage Examples**:
  ```bash
  # Run both validation and benchmark
  ./tools/micros-virtio-bench

  # Audit geometric layout invariants only
  ./tools/micros-virtio-bench --validate

  # Run high-iteration benchmark
  ./tools/micros-virtio-bench --bench --iterations 100000
  ```

---

### 1.9. `micros-arch-gate` — Microkernel Tier Boundary Gate & Baseline Lock
* **Source**: [`tools/src/arch_gate.zig`](file:///home/renich/Projects/zig/micros/tools/src/arch_gate.zig)
* **Launcher**: [`tools/micros-arch-gate`](file:///home/renich/Projects/zig/micros/tools/micros-arch-gate)
* **Purpose**: Enforces the architectural tier boundary over `@import` edges per [`SPEC-TECH-ARCH-001`](file:///home/renich/Projects/zig/micros/docs/technical/specs/microkernel-boundary-enforcement.rst). Kernel code may not import concrete userland implementations; userland may import only the public capability surface (`capability.zig`, `ipc/ring.zig`, `boot_info.zig`); the Macros VM may not import drivers or arch state.
* **Exemptions**: Enumerated per edge in `isKernelSideExemption`/`isUserlandSideExemption`, never per daemon or directory, each carrying its M42 Ring-3 excision pointer. A previously unseen import by an exempted daemon fails the gate.
* **Disclosure**: Every run prints the imports scanned and the exemptions granted, on pass and on fail. A green gate never hides how much it excused.
* **CLI Syntax**:
  ```bash
  ./tools/micros-arch-gate [options] <root-path>
  ```
* **Options**:
  * `--baseline <path>`: Fail when an architectural edge is absent from the recorded baseline.
  * `--dump-baseline <path>`: Write the deduplicated current edge set to a snapshot file (regenerate only as a reviewed act).
  * `-h, --help`: Show usage.
* **Usage Examples**:
  ```bash
  # Gate the tree exactly as make check does
  ./tools/micros-arch-gate src/ --baseline docs/project/deliberations/stage4/import-baseline.txt

  # Re-record the edge set after an intentional, reviewed architectural change
  ./tools/micros-arch-gate src/ --dump-baseline docs/project/deliberations/stage4/import-baseline.txt
  ```

---

## 2. Multi-Agent Operational Workflows

All engineering agents defined in [`AGENTS.md`](file:///home/renich/Projects/zig/micros/AGENTS.md) MUST invoke the appropriate tools based on their role:

| Agent | Responsibilities | Mandatory Tool Invocations |
|---|---|---|
| `security_qa` | Static analysis, code quality enforcement, memory leak audits | `./tools/micros-lint src/`<br>`zig build test` |
| `junior_dev` | Feature implementation, test-driven development (TDD) | `./tools/micros-lint <file>`<br>`make test-sandbox`<br>`make test-uefi` |
| `sysadmin_devops` | QEMU/KVM automation, boot validation, CI harness | `./tools/micros-runner --mode uefi`<br>`./tools/micros-fb-verify` |
| `lead_architect` | Architecture reviews, crucible protocol gates, roadmaps | `./tools/micros-spec-trace --check`<br>`./tools/micros-lint src/` |
| `tech_writer` | Specification authoring, documentation validation | `./tools/micros-spec-trace --format matrix`<br>`rstcheck` |
| `scout` | Post-mortem diagnosis, crash triaging, hardware recon | `./tools/micros-inspect`<br>`./tools/micros-sym`<br>`./tools/micros-telem` |

---

## 3. Build System Integration

The toolchain is fully integrated into the repository build infrastructure:

* **Zig Build Target**:
  ```bash
  zig build tools
  ```
  Compiles all native Zig utilities (`micros-lint`, `micros-fb-verify`, `micros-sym`, `micros-telem`) into `zig-out/bin/`.

* **GNUmakefile Targets**:
  * `make tools`: Compiles all native tools.
  * `make spec-trace`: Runs `./tools/micros-spec-trace --check`.
  * `make arch-gate`: Runs `./tools/micros-arch-gate src/ --baseline docs/project/deliberations/stage4/import-baseline.txt` to enforce tier boundaries and reject unrecorded edges.
  * `make lint`: Runs `micros-lint src/` and `shellcheck scripts/*.bash tools/*.bash`.
  * `make fmt`: Runs `zig fmt src/ tools/src/ build.zig`.
  * `make fmt-check`: Verifies formatting without modification.
  * `make test-sandbox`: Boots the direct-syscall sandbox in QEMU/KVM.
  * `make test-uefi`: Boots the bare-metal UEFI image in QEMU/KVM and awaits the `µShell` prompt.
  * `make check`: Runs `test lint fmt-check spec-trace arch-gate test-sandbox test-uefi`.

---

## 4. Operational Rules & Constraints

1. **Formatting Style**: NEVER insert spaces around forward slashes. Always write `word/word` (e.g., `kernel/userspace`, `read/write`, `QEMU/KVM`).
2. **Explicit Verification**: Never claim a tool or test passes without running it and inspecting actual output.
3. **Shell Script Standards**: All shell scripts must reside in `tools/` or `scripts/`, use `.bash` extensions, include shebang `#!/usr/bin/bash`, `set -euo pipefail`, `IFS=$'\n\t'`, and pass `shellcheck` with zero warnings.
4. **Symbol Preservation**: The kernel ELF binary must retain its symbol table (`.strip = false` in `build.zig`) so that `micros-sym` and `micros-addr2line` can accurately resolve instruction pointers.
