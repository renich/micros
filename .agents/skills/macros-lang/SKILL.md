---
name: macros-lang
description: Operational manual, language reference, and self-hosting bootstrap protocols for the Macros programming language runtime (src/macros/) and self-hosting compiler (lib/macros/).
license: MIT
compatibility: dual
metadata:
  audience: developers
  workflow: language-engineering
  subagents: [macros_lang_dev, lead_architect, junior_dev, measured_architect, extreme_adversary]
---

# Macros Programming Language Protocol

This project-local skill governs the architecture, grammar, memory management, and self-hosting compiler workflows for the **Macros** programming language.

```text
┌─────────────────────────────────────────────────────────────────────────────┐
│                       MACROS PROGRAMMING LANGUAGE ARCHITECTURE              │
├──────────────────────────────┬──────────────────────────────┬───────────────┤
│ STAGE 0 (SUBSTRATE RUNTIME)  │ STAGE 1 (SELF-HOSTING SOURCE)│ RUNTIME CORE  │
├──────────────────────────────┼──────────────────────────────┼───────────────┤
│ • src/macros/lexer.zig       │ • lib/macros/lexer.mc        │ • Immix GC    │
│ • src/macros/parser.zig      │ • lib/macros/parser.mc       │ • Fibers (M:N)│
│ • src/macros/ast.zig         │ • lib/macros/ast.mc          │ • Direct I/O  │
│ • src/macros/eval.zig        │ • lib/macros/compiler.mc     │ • Zero Libc   │
└──────────────────────────────┴──────────────────────────────┴───────────────┘
```

---

## 1. Language Grammar, Extensions & Primitives

Macros is an expression-oriented language designed for high-speed systems scripting and autonomous AI code generation.

### 1.1. Canonical File Extensions
* ``.mx``/``.macros``: Primary canonical extensions for Macros source scripts.
* ``.mc``: Legacy extension supported by the runner and compiler.

### 1.2. Functions & Control Flow
```macros
fn fibonacci(n) {
    if (n <= 1) {
        return n;
    }
    return fibonacci(n - 1) + fibonacci(n - 2);
}
```

### 1.3. Loops & Variable Bindings
```macros
fn count_to(limit) {
    i = 0;
    while (i < limit) {
        i = i + 1;
    }
    return i;
}
```

---

## 2. Memory Model & Immix GC

All runtime allocations in Macros operate on the **Immix Mark-Region** collector ([`src/macros/immix.zig`](file:///home/renich/Projects/zig/micros/src/macros/immix.zig)):
* **Block Geometry**: 32KB blocks containing 256 lines of 128 bytes.
* **Hole Allocation**: Fast bump pointer into recyclable line spans without memory fragmentation.
* **Large Objects**: Direct page mapping via `sys.mem.map` for objects $> 512$ bytes.

---

## 3. Cooperative Green Threads (Fibers)

Fibers ([`src/macros/fiber.zig`](file:///home/renich/Projects/zig/micros/src/macros/fiber.zig)) provide userspace M:N concurrency:
* 64KB page-aligned stack per fiber.
* Callee-saved context switching in pure x86_64 assembly ([`src/macros/context_switch.s`](file:///home/renich/Projects/zig/micros/src/macros/context_switch.s)).
* Non-preemptive queue-based `Scheduler`.

---

## 4. Self-Hosting Bootstrap Pipeline

To maintain computational sovereignty within MicrOS:
1. **Stage 0**: Freestanding Zig engine in `src/macros/` interprets the Stage 1 compiler in `lib/macros/`.
2. **Stage 1**: Macros compiler written in Macros (`lib/macros/compiler.mc`) emits runnable machine code/bytecode.
3. **Stage 2**: Fixed-point verification proving bit-for-bit reproducibility.

---

## 5. Agent Verification Checklist

Before committing changes to the Macros language or compiler:
1. Run `make check` to ensure 100% test passage and zero leaks.
2. Run `make lint` to verify AST limits (functions $\le 40$ lines, depth $\le 3$).
3. Run `make spec-trace` to verify requirement traceability.
