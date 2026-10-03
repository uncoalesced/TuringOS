# TuringOS build plan

## The concept

TuringOS isn't a distro with Claude preinstalled. It's a model for how an agent interacts with a computer: a Bash orchestration layer that wraps Debian (Linux) primitives into one safe execution environment for autonomous agents.

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
                      DEBIAN / LINUX KERNEL
                               │
                         HARDWARE / GPU
```

The Bash layer is the product.

---

## CLI interface

There's one executable, `turingos`:

```bash
turingos init
turingos dashboard

turingos agent start
turingos agent stop
turingos agent status

turingos sandbox create
turingos sandbox diff
turingos sandbox merge
turingos sandbox rollback

turingos bazaar
turingos bazaar install <tool>

turingos game on
turingos game off
turingos game status

turingos status
```

---

## File structure

```
turingos/
├── turingos              # main entrypoint
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
SANDBOX="$HOME/.turingos/sandboxes/task-$(date +%s)"

sudo btrfs subvolume snapshot "$PROJECT" "$SANDBOX"
cd "$SANDBOX"
claude
```

Claude works inside the snapshot, and the original project stays untouched.

Diff:
```bash
turingos sandbox diff
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
turingos bazaar
```
→ `fzf` selection  
→ `git clone`  
→ install dependencies  
→ generate MCP config entry  

Don't claim 500 tools. Ship 2–3, and make sure one works end to end.

---

## Pillar 3: Game Mode (Bash-native, don't oversell it)

```bash
turingos game on

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

We're orchestrating what Debian and the Linux kernel already have, not reinventing the scheduler. Present it that way.

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
turingos agent start
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
turingos sandbox diff
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
turingos game on
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
| 0–2h | Core sandbox: `turingos sandbox create/diff/merge/rollback` working end-to-end |
| 2–3h | `turingos agent start` — Claude running inside sandbox |
| 3–4h | Clawd Bazaar — fzf + registry.json + one real MCP install |
| 4–5h | Game Mode + `turingos status` dashboard |
| 5–6h | UI polish with gum, demo script, notification on agent completion |

---

## What to say to Anthropic judges

Don't pitch it as "We put Claude on Debian."

Pitch it as "We changed the execution model around autonomous agents."

The OS puts a human-approval gate between every agent action and the real filesystem. Inside a sandbox the agent has full autonomy. Before anything becomes permanent, a human reviews the diff. That gate is what we're building.
