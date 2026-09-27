# TuringOS — Build Plan

## The Concept

Not "a distro with Claude installed." An **agent-computer interaction model** — a Bash orchestration layer that wraps CachyOS primitives into a cohesive, safe execution environment for autonomous agents.

The interesting framing for Anthropic:

**Traditional:**
```
Human → Terminal → Program → Filesystem
```

**TuringOS:**
```
Human
  ↓
Intent
  ↓
Claude Agent
  ↓
TuringOS Policy Layer
  ↓
Ephemeral Sandbox
  ↓
Filesystem
  ↓
Diff
  ↓
Human Approval
  ↓
Merge
```

---

## Architecture

```
                    ┌──────────────────────┐
                    │       TURINGOS       │
                    │   Bash Control Plane │
                    └──────────┬───────────┘
                               │
       ┌───────────────┬───────┼───────────────┐
       ▼               ▼       ▼               ▼
   CLAUDE CODE       MCP     SANDBOX        GAME MODE
       │               │       │               │
       │               │     Btrfs          BORE/Linux
       │               │       │               │
       └───────────────┴───────┼───────────────┘
                               ▼
                         CACHYOS KERNEL
                               │
                         HARDWARE / GPU
```

The Bash layer **is** the product.

---

## CLI Interface

One executable: `claudeos`

```bash
claudeos init
claudeos dashboard

claudeos agent start
claudeos agent stop
claudeos agent status

claudeos sandbox create
claudeos sandbox diff
claudeos sandbox merge
claudeos sandbox rollback

claudeos bazaar
claudeos bazaar install <tool>

claudeos game on
claudeos game off
claudeos game status

claudeos status
```

---

## File Structure

```
turingos/
├── claudeos              # main entrypoint
├── core/
│   ├── ui.sh
│   ├── config.sh
│   └── logging.sh
├── agent/
│   ├── claude.sh
│   └── hermes.sh
├── sandbox/
│   ├── btrfs.sh
│   └── diff.sh
├── bazaar/
│   ├── registry.sh
│   └── install.sh
├── game/
│   └── gamemode.sh
└── monitor/
    └── system.sh
```

Start as one giant Bash script. Split only if there's time.

---

## Pillar 1: Btrfs Agent Sandbox (Core Feature — Build This First)

This is the real differentiator. It's technically grounded and visually demonstrable.

```bash
PROJECT="$PWD"
SANDBOX="$HOME/.claudeos/sandboxes/task-$(date +%s)"

sudo btrfs subvolume snapshot "$PROJECT" "$SANDBOX"
cd "$SANDBOX"
claude
```

Claude works inside the snapshot. Original project is untouched.

**Diff:**
```bash
claudeos sandbox diff
# combines git diff + btrfs info
```

**Rollback:**
```bash
sudo btrfs subvolume delete "$SANDBOX"
```

**Merge:**
```bash
# apply git changes from sandbox back to original repo
```

This is a real feature, not a mock.

---

## Pillar 2: Clawd Bazaar (Keep It Honest — 2–3 Tools, One Must Actually Install)

`registry.json`:
```json
{
  "github-agent": {
    "name": "GitHub Agent",
    "repo": "some/repository",
    "type": "mcp"
  },
  "postgres": {
    "name": "Postgres Inspector",
    "repo": "some/repository",
    "type": "mcp"
  }
}
```

Flow:
```bash
claudeos bazaar
```
→ `fzf` selection  
→ `git clone`  
→ install dependencies  
→ generate MCP config entry  

Don't claim 500 tools. Have 2–3, with one actually working end-to-end.

---

## Pillar 3: Game Mode (Bash-Native, Don't Oversell It)

```bash
claudeos game on

PID=$(pgrep -af claude)
renice +10 -p "$PID"
ionice -c 3 -p "$PID"
```

Display:
```
╭────────────────────────────────────╮
│       TURINGOS GAME MODE           │
├────────────────────────────────────┤
│ Steam              ✓               │
│ Game detected      ✓               │
│                                    │
│ Claude Agent       LOW             │
│ Build processes    LOW             │
│ Interactive apps   PRIORITY        │
│                                    │
│ 🎮 GAME MODE ACTIVE                │
╰────────────────────────────────────╯
```

You're orchestrating CachyOS, not reinventing its scheduler. Frame it that way.

---

## UI Tools (No Frontend Needed)

```bash
gum
fzf
jq
git
btrfs
notify-send
nvidia-smi
systemctl
ps
```

Example:
```bash
gum choose \
  "Launch Claude Agent" \
  "Create Agent Sandbox" \
  "Review Changes" \
  "Clawd Bazaar" \
  "Game Mode" \
  "System Status"
```

Terminal UI without writing a frontend.

---

## The Demo (3 Minutes)

**Scene 1 — Agent request**
```bash
claudeos agent start
```
> "Refactor this authentication module and run the tests."

**Scene 2 — TuringOS protects the machine**
```
Creating Btrfs CoW Agent Sandbox...

✓ Original project protected
✓ Sandbox created
✓ Claude execution authorized
```

**Scene 3 — Claude works**
```
Claude Agent

> Inspecting repository
> Modifying auth.py
> Updating tests
> Running test suite

✓ 14/14 tests passed
```

**Scene 4 — TuringOS catches everything**
```bash
claudeos sandbox diff
```
```
7 files changed
+143 lines
-67 lines

Tests: 14/14 ✓
```

**Scene 5 — Human remains in control**
```
[ M ] Merge Changes
[ R ] Rollback
[ V ] View Diff
```

**Scene 6 — Game Mode**
```bash
claudeos game on
```
```
🎮 GAME MODE

Claude → background priority
Build → background priority
Game → interactive priority

Agent continues running.
```

Then notification fires:
```
╭──────────────────────────────────────╮
│ 🟢 TuringOS                          │
│                                      │
│ Agent task completed                 │
│ 14/14 tests passed                   │
╰──────────────────────────────────────╯
```

---

## Time Budget (6 Hours)

| Time | Task |
|------|------|
| 0–2h | Core sandbox: `claudeos sandbox create/diff/merge/rollback` working end-to-end |
| 2–3h | `claudeos agent start` — Claude running inside sandbox |
| 3–4h | Clawd Bazaar — fzf + registry.json + one real MCP install |
| 4–5h | Game Mode + `claudeos status` dashboard |
| 5–6h | UI polish with gum, demo script, notification on agent completion |

---

## What to Say to Anthropic Judges

Not: *"We put Claude on CachyOS."*

Instead: **"We changed the execution model around autonomous agents."**

The OS enforces a human-approval gate between every agent action and the real filesystem. Agents get full autonomy inside sandboxes. Humans see a diff before anything is permanent. That's the product.
