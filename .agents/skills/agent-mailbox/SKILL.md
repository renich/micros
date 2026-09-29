---
name: agent-mailbox
description: Zero-latency bidirectional IPC, reactive wakeup protocol, and live chat viewer for N autonomous AI agents (Gemini, Muse, Claude, Jules, Codex, etc.). Use when pair-programming or coordinating multi-agent tasks.
license: MIT
compatibility: dual
metadata:
  audience: developers
  workflow: multi-agent-orchestration
---

# Agent Mailbox: N-Agent Reactive IPC & Live Chat Protocol

The `agent-mailbox` utility enables seamless, zero-polling autonomous collaboration across **$N$ arbitrary AI agents** (Gemini/`agy`, Meta Muse/`muse`, Claude Code, Jules, Codex, etc.). It implements a Directed Unicast Actor Model with per-agent inboxes, append-only Markdown logs, the GRIP intent protocol, kernel `inotify` wakeup, and a live terminal chat viewer (`agent-chat`).

## Architecture & Topology

- **Per-Agent Inboxes**: `/tmp/<agent>.inbox.md` (e.g. `agy.inbox.md`, `muse.inbox.md`, `claude.inbox.md`).
- **Backward Compatibility**: Symlinks `/tmp/agy-to-muse.md -> muse.inbox.md` and `/tmp/muse-to-agy.md -> agy.inbox.md` preserve 2-agent scripts and logs.
- **Kernel Wakeup**: Powered by `agent-mailbox wait --as <agent>` using Linux `inotifywait -m -q -e close_write`. When an incoming message arrives and is flushed to `<agent>.inbox.md`, the kernel notifies the waiting task sub-millisecond without polling or CPU spinning.
- **Unified Event Ledger**: Every message posted via `send` is atomically recorded to `/tmp/agent-chat.jsonl` (and `agent-chat.md`) for real-time human observation.

## Multi-Agent Turn Protocol

### 1. Sending a Directed Message

```bash
# General syntax:
agent-mailbox send --to <recipient> [--from <sender>] [--intent <TAG>] [--re <msg-id>] "Message..."

# Examples:
agent-mailbox send --to muse --intent TASK --re msg-014 "Review Stage-2 orders..."
agent-mailbox send --to claude --intent TASK "Audit cryptographic hygiene in src/kernel/..."
agent-mailbox send --to agy --intent REPORT --re msg-015 "Audit verified clean."

# Multiline / from file:
agent-mailbox send --to jules --intent REPORT --file /tmp/benchmarks.md
```

- **Intent Tags**: `[TASK]`, `[REPORT]`, `[ACK]`, `[ANSWER]`, `[QUERY]`, `[NOTE]`.
- **Monotonic IDs**: Message IDs (`msg-001`, `msg-002`, ...) are automatically assigned per inbox.

### 2. Waiting for Incoming Messages (Reactive Wakeup)

Immediately after posting a message or handing off work, run `wait` in the background and end your turn:

```bash
# Gemini waiting for messages in its inbox:
agent-mailbox wait --as agy

# Muse waiting for messages in its inbox:
agent-mailbox wait --as muse

# Waiting for a message specifically from Claude:
agent-mailbox wait --as agy --from claude
```

- In **Antigravity (`agy`)**: Run `agent-mailbox wait --as agy` as a background task (`run_command` with small `WaitMsBeforeAsync`). Stop calling tools to end your turn. When a message arrives, the task exits with code 0 and Antigravity immediately delivers the message into your context.
- In **Muse**: Run `agent-mailbox wait --as muse` as a background task. Yield the turn.

### 3. Live Terminal Chat Viewer (Human Observable Stream)

To watch all agents communicate in a unified, syntax-highlighted chronological chat stream:

```bash
# Launch live stream in a dedicated terminal pane:
agent-chat

# Or via agent-mailbox subcommand:
agent-mailbox chat

# Options:
#   -n 20       Display last 20 messages on startup (default: 10, 0 for all)
#   --no-glow   Disable markdown styling (plain ANSI)
#   --no-follow Print history and exit without live following
```

- Visuals: Directional routing (`🤖 AGY ➔ 🏛️ MUSE`), colored intent chips, timestamps, and syntax-rendered Markdown.
- Agent Palettes: Electric Cyan (`🤖 AGY`), Vibrant Magenta (`🏛️ MUSE`), Warm Amber (`🟠 CLAUDE`), Spring Emerald (`⚡ JULES`), Azure Blue (`💻 CODEX`), and dynamic hashing for custom agents.

### 4. Status & Inspection

```bash
# Display all active inboxes, message counts, and Muse session ingress status:
agent-mailbox status

# Read the last N messages from an inbox:
agent-mailbox read --as agy -n 2
```
