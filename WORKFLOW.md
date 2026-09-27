# TuringOS Workflow Guide

How to use the scripts end-to-end, from first install to running an agent and reviewing its work.

---

## Prerequisites

**macOS**
```bash
# Required
brew install git jq

# Strongly recommended (UI quality depends on these)
brew install gum fzf

# Optional but useful
brew install node
```

**Arch / CachyOS**
```bash
sudo pacman -S git jq gum fzf rsync nodejs npm
```

**Ubuntu / Debian**
```bash
sudo apt install git jq fzf rsync nodejs npm
# gum: https://github.com/charmbracelet/gum#installation
```

---

## Step 1 — First-Time Setup

Run `init` once. It creates the runtime directories and checks your environment.

```bash
cd /path/to/turingos
chmod +x claudeos
./claudeos init
```

You'll see a dependency check like this:

```
  ✓  git          found
  ✓  jq           found
  ✓  gum          found
  ✓  fzf          found
  ⚠  nvidia-smi   not found (optional)

  TuringOS initialized

  Data dir:    ~/.claudeos/
  Config:      ~/.claudeos/config.env
  Agent log:   ~/.claudeos/logs/
  Sandboxes:   ~/.claudeos/sandboxes/
```

**Optional: add `claudeos` to your PATH**

```bash
echo 'export PATH="$PATH:/path/to/turingos"' >> ~/.bashrc
source ~/.bashrc
```

After that, every example below works without the `./` prefix.

---

## Step 2 — Configure the Agent Binary

TuringOS defaults to `claude` as the agent binary (the Claude Code CLI).

If it's installed elsewhere, or you want to use a different binary:

```bash
echo 'CLAUDEOS_AGENT_BINARY=/usr/local/bin/claude' >> ~/.claudeos/config.env
```

Other tunable options in `~/.claudeos/config.env`:

| Variable | Default | Purpose |
|---|---|---|
| `CLAUDEOS_AGENT_BINARY` | `claude` | Path to Claude Code CLI |
| `CLAUDEOS_SANDBOX_BACKEND` | `btrfs` | `btrfs` or `copy` (rsync fallback) |
| `CLAUDEOS_GAME_RENICE_LEVEL` | `10` | nice value applied in game mode |
| `CLAUDEOS_LOG_LEVEL` | `info` | `debug`, `info`, `warn`, or `error` |

---

## Step 3 — Run Your First Agent Task

### 3a. Point at a project and start

```bash
claudeos agent start /path/to/your/project "Refactor the auth module and run tests"
```

TuringOS will:

1. Create a Btrfs snapshot (or rsync copy) of your project
2. Write a task prompt into the sandbox
3. Launch Claude inside the sandbox
4. Offer to tail the live output

Your original project is **never touched** until you explicitly merge.

### 3b. Watch it run

If you didn't choose to tail at startup:

```bash
claudeos agent logs
```

Or check the current state:

```bash
claudeos agent status
```

Output:

```
  ╭──────────────────────────────────────╮
  │         Agent Status                 │
  ╰──────────────────────────────────────╯

  ◈ Agent        ✓  running  PID 18432
      Task       Refactor the auth module and run tests
      CPU        4.2%
      RAM        1.8%

  Recent output:
    > Inspecting repository structure
    > Modifying src/auth/handler.py
    > Running pytest...
```

---

## Step 4 — Review What the Agent Changed

When the agent finishes, you'll see a completion banner:

```
  ╭──────────────────────────────────────────╮
  │  🟢 TuringOS                             │
  │                                          │
  │  Agent task completed                    │
  │  14 passed, 0 failed                     │
  │                                          │
  │  Run: claudeos sandbox diff              │
  ╰──────────────────────────────────────────╯
```

Now inspect the changes:

```bash
claudeos sandbox diff
```

You'll get a summary like:

```
  ╭─ Sandbox Diff Inspector ──────────────────╮

  Task      Refactor the auth module and run tests
  Sandbox   refactor-auth-1748976000
  Project   /home/you/myproject
  Backend   btrfs

  ──────────────────────────────────────────────

  7 files changed   +143   -67

    M  src/auth/handler.py              +89 / -45
    M  src/auth/middleware.py           +31 / -18
    M  tests/test_auth.py               +23 / -4
    A  src/auth/utils.py
    D  src/auth/legacy.py

  ✓  Tests: 14/14 passed
```

Then choose what to do:

```
  [ M ] Merge changes into project
  [ R ] Rollback — discard all changes
  [ V ] View full diff (git patch)
  [ S ] Save diff to file
  [ Q ] Quit (keep sandbox)
```

---

## Step 5 — Merge or Rollback

### Merge

```bash
claudeos sandbox merge
```

Applies the agent's changes back to your original project via rsync. You'll be asked to confirm, then optionally destroy the sandbox.

### Rollback

```bash
claudeos sandbox rollback
```

Destroys the sandbox entirely. On Btrfs, this is `btrfs subvolume delete` — instant and space-free. On the copy backend, it's `rm -rf` of the sandbox directory.

Your original project remains untouched either way.

---

## Step 6 — Install MCP Tools (Bazaar)

Browse the tool registry interactively:

```bash
claudeos bazaar
```

This opens an fzf picker. Select a tool, review its details, and install.

Or install directly by key:

```bash
claudeos bazaar install github-mcp
claudeos bazaar install postgres-mcp
claudeos bazaar install filesystem-mcp
```

TuringOS will:
1. Check that required env vars are set (e.g. `GITHUB_PERSONAL_ACCESS_TOKEN`)
2. Verify the npx package is downloadable
3. Inject a server entry into `~/.config/Claude/claude_desktop_config.json`

After install, **restart Claude Desktop** to load the new MCP server.

Check what's installed:

```bash
claudeos bazaar installed
```

Remove a tool:

```bash
claudeos bazaar uninstall github-mcp
```

---

## Step 7 — Game Mode

When you launch a game and want the agent to keep running in the background without competing for resources:

```bash
claudeos game on
```

Output:

```
  ╭────────────────────────────────────────╮
  │       TURINGOS GAME MODE               │
  ├────────────────────────────────────────┤
  │  claude [18432]          LOW           │
  │  ollama [9811]           LOW           │
  ├────────────────────────────────────────┤
  │  Interactive apps        PRIORITY      │
  │                                        │
  │  🎮 GAME MODE ACTIVE                   │
  ╰────────────────────────────────────────╯

  → Agents continue running in background
  → Disable with: claudeos game off
```

When your game session ends:

```bash
claudeos game off
```

Process priorities are restored to their original values.

**Auto-detect mode** (watches for Steam/Lutris/Heroic to launch):

```bash
claudeos game watch &
```

---

## Step 8 — System Monitor

One-shot status HUD:

```bash
claudeos status
```

Live refreshing dashboard (like htop, Ctrl+C to exit):

```bash
claudeos monitor watch
```

Token usage and estimated API cost:

```bash
claudeos monitor spend
```

---

## Full Demo Flow (3 Minutes)

This is the sequence to run for a presentation or demo.

```bash
# 1. Show the system is ready
claudeos status

# 2. Start the agent on a real project
claudeos agent start ~/projects/myapp "Refactor auth module, run tests"

# 3. Watch it work (optional — or just let it run)
claudeos agent logs

# 4. Once complete, inspect the changes
claudeos sandbox diff

# 5. Merge if satisfied
#    (choose M at the prompt, or run directly)
claudeos sandbox merge

# 6. Demonstrate game mode
claudeos game on
claudeos game status
claudeos game off
```

---

## Common Workflows

### Re-run a task on the same project

```bash
# Previous sandbox is gone after merge/rollback
# Just start a new one
claudeos agent start ~/projects/myapp "Add pagination to the /users endpoint"
```

### Keep a sandbox around for later review

Choose `Q` (Quit, keep sandbox) at the diff prompt.  
List it later:

```bash
claudeos sandbox list
```

Pass its path explicitly to diff/merge/rollback:

```bash
claudeos sandbox diff ~/.claudeos/sandboxes/my-task-1748976000
```

### Override the sandbox backend (no Btrfs)

```bash
echo 'CLAUDEOS_SANDBOX_BACKEND=copy' >> ~/.claudeos/config.env
```

The copy backend uses rsync. Slower to create, but works on any filesystem.

### Check logs

```bash
# Last 50 lines of TuringOS operational log
claudeos logs

# Last 100 lines
claudeos logs 100

# Raw log file location
claudeos logs 1 2>/dev/null  # prints path implicitly via log::path
ls ~/.claudeos/logs/
```

### Audit trail

Every significant action (sandbox create, agent start/stop, merge, bazaar install) is written to:

```
~/.claudeos/logs/audit.log
```

Format: `[TIMESTAMP] EVENT key=value key=value ...`

```bash
tail -f ~/.claudeos/logs/audit.log
```

---

## Directory Reference

```
~/.claudeos/
├── config.env          # user overrides (CLAUDEOS_AGENT_BINARY, etc.)
├── state.json          # active sandbox path, agent PID, game mode state
├── pids/
│   └── claude.pid      # running agent PID
├── logs/
│   ├── claudeos-YYYYMMDD.log   # operational log
│   ├── audit.log               # structured action trail
│   └── agent-session-*.log     # per-session agent output
├── sandboxes/
│   └── <label>-<timestamp>/    # one directory per sandbox
│       ├── .claudeos_sandbox   # metadata (source project, backend, etc.)
│       └── .claudeos_prompt    # task prompt written for the agent
└── bazaar/
    └── <tool-key>/
        ├── .installed          # timestamp of install
        └── run.sh              # launcher script (npx tools)
```

---

## Troubleshooting

**`claude: command not found`**
Set `CLAUDEOS_AGENT_BINARY` in `~/.claudeos/config.env` to the full path of your Claude Code CLI binary.

**Sandbox creation fails with "not a btrfs subvolume"**
Set `CLAUDEOS_SANDBOX_BACKEND=copy` in `~/.claudeos/config.env`. The rsync copy fallback works on any filesystem — including macOS APFS.

**`jq: command not found`**
`jq` is required for the Bazaar and state management. Install it: `sudo pacman -S jq`

**MCP tool installed but not appearing in Claude Desktop**
Claude Desktop must be restarted after any MCP config change. The config file is at:
- macOS: `~/Library/Application Support/Claude/claude_desktop_config.json`
- Linux: `~/.config/Claude/claude_desktop_config.json`

**Agent completed but diff shows no changes**
The agent may have worked on untracked files. If the sandbox has no `.git`, the diff falls back to rsync dry-run. Check `~/.claudeos/logs/agent-session-*.log` for what the agent actually did.

**Game mode says "no processes found"**
The agent binary must be running before `claudeos game on` is called. Start the agent first, then enable game mode.
