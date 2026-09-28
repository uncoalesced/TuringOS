# TuringOS build plan

## The concept

TuringOS isn't a distro with Claude preinstalled. It's a model for how an agent interacts with a computer: a Bash orchestration layer that wraps CachyOS primitives into one safe execution environment for autonomous agents.

Here's the framing we want Anthropic to see.

Traditional:
```
Human → Terminal → Program → Filesystem
```

TuringOS:
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

The Bash layer is the product.

---

## CLI interface

There's one executable, `claudeos`:

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

## File structure

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

We start with one big Bash script and split it up only if there's time.

---

## Pillar 1: Btrfs agent sandbox (core feature, build this first)

This is what sets TuringOS apart. It rests on real filesystem features, and you can see it working in a demo.

```bash
PROJECT="$PWD"
SANDBOX="$HOME/.claudeos/sandboxes/task-$(date +%s)"

sudo btrfs subvolume snapshot "$PROJECT" "$SANDBOX"
cd "$SANDBOX"
claude
```

Claude works inside the snapshot, and the original project stays untouched.

Diff:
```bash
claudeos sandbox diff
# combines git diff + btrfs info
```

Rollback:
```bash
sudo btrfs subvolume delete "$SANDBOX"
```

Merge:
```bash
# apply git changes from sandbox back to original repo
```

None of this is mocked. It actually works.

---

## Pillar 2: Clawd Bazaar (keep it honest: 2–3 tools, one must actually install)

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

Don't claim 500 tools. Ship 2–3, and make sure one works end to end.

---

## Pillar 3: Game Mode (Bash-native, don't oversell it)

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

We're orchestrating CachyOS here, not reinventing its scheduler. Present it that way.

---

## UI tools (no frontend needed)

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

That gets us a terminal UI without writing a frontend.

---

## The demo (3 minutes)

Scene 1: agent request
```bash
claudeos agent start
```
> "Refactor this authentication module and run the tests."

Scene 2: TuringOS protects the machine
```
Creating Btrfs CoW Agent Sandbox...

✓ Original project protected
✓ Sandbox created
✓ Claude execution authorized
```

Scene 3: Claude works
```
Claude Agent

> Inspecting repository
> Modifying auth.py
> Updating tests
> Running test suite

✓ 14/14 tests passed
```

Scene 4: TuringOS catches everything
```bash
claudeos sandbox diff
```
```
7 files changed
+143 lines
-67 lines

Tests: 14/14 ✓
```

Scene 5: the human stays in control
```
[ M ] Merge Changes
[ R ] Rollback
[ V ] View Diff
```

Scene 6: Game Mode
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

Then the notification fires:
```
╭──────────────────────────────────────╮
│ 🟢 TuringOS                          │
│                                      │
│ Agent task completed                 │
│ 14/14 tests passed                   │
╰──────────────────────────────────────╯
```

---

## Time budget (6 hours)

| Time | Task |
|------|------|
| 0–2h | Core sandbox: `claudeos sandbox create/diff/merge/rollback` working end-to-end |
| 2–3h | `claudeos agent start` — Claude running inside sandbox |
| 3–4h | Clawd Bazaar — fzf + registry.json + one real MCP install |
| 4–5h | Game Mode + `claudeos status` dashboard |
| 5–6h | UI polish with gum, demo script, notification on agent completion |

---

## What to say to Anthropic judges

Don't pitch it as "We put Claude on CachyOS."

Pitch it as "We changed the execution model around autonomous agents."

The OS puts a human-approval gate between every agent action and the real filesystem. Inside a sandbox the agent has full autonomy. Before anything becomes permanent, a human reviews the diff. That gate is what we're building.
