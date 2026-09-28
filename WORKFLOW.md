# TuringOS workflow guide

This guide walks through the scripts in order: first install, running an agent, and reviewing what it did.

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

## Step 1: First-time setup

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

### Optional: add `claudeos` to your PATH

```bash
echo 'export PATH="$PATH:/path/to/turingos"' >> ~/.bashrc
source ~/.bashrc
```

The examples below assume you did this and leave off the `./` prefix.

---

## Step 2: Configure the agent binary

By default TuringOS runs `claude` (the Claude Code CLI) as the agent.

To point it at a binary somewhere else, or a different binary altogether:

```bash
echo 'CLAUDEOS_AGENT_BINARY=/usr/local/bin/claude' >> ~/.claudeos/config.env
```

You can also set these in `~/.claudeos/config.env`:

| Variable | Default | Purpose |
|---|---|---|
| `CLAUDEOS_AGENT_BINARY` | `claude` | Path to Claude Code CLI |
| `CLAUDEOS_SANDBOX_BACKEND` | `btrfs` | `btrfs` or `copy` (rsync fallback) |
| `CLAUDEOS_GAME_RENICE_LEVEL` | `10` | nice value applied in game mode |
| `CLAUDEOS_LOG_LEVEL` | `info` | `debug`, `info`, `warn`, or `error` |

---

## Step 3: Run your first agent task

### 3a. Point at a project and start

```bash
claudeos agent start /path/to/your/project "Refactor the auth module and run tests"
```

TuringOS then:

1. Creates a Btrfs snapshot (or rsync copy) of your project
2. Writes a task prompt into the sandbox
3. Launches Claude inside the sandbox
4. Offers to tail the live output

Nothing in your original project changes until you merge.

### 3b. Watch it run

If you skipped tailing at startup:

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

## Step 4: Review what the agent changed

When the agent finishes, it prints a completion banner:

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

Now look at the changes:

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

Then pick what to do:

```
  [ M ] Merge changes into project
  [ R ] Rollback — discard all changes
  [ V ] View full diff (git patch)
  [ S ] Save diff to file
  [ Q ] Quit (keep sandbox)
```

---

## Step 5: Merge or roll back

### Merge

```bash
claudeos sandbox merge
```

This copies the agent's changes back into your original project with rsync. It asks you to confirm first, then offers to destroy the sandbox.

### Rollback

```bash
claudeos sandbox rollback
```

This deletes the sandbox. On Btrfs that means `btrfs subvolume delete`, which is instant and frees the space right away. On the copy backend it runs `rm -rf` on the sandbox directory.

In both cases your original project is left alone.

---

## Step 6: Install MCP tools (Bazaar)

To browse the tool registry interactively:

```bash
claudeos bazaar
```

This opens an fzf picker. Select a tool, read its details, and install it.

You can also install directly by key:

```bash
claudeos bazaar install github-mcp
claudeos bazaar install postgres-mcp
claudeos bazaar install filesystem-mcp
```

During install, TuringOS:
1. Checks that required env vars are set (e.g. `GITHUB_PERSONAL_ACCESS_TOKEN`)
2. Verifies the npx package can be downloaded
3. Adds a server entry to `~/.config/Claude/claude_desktop_config.json`

Restart Claude Desktop afterwards so it picks up the new MCP server.

To see what's installed:

```bash
claudeos bazaar installed
```

To remove a tool:

```bash
claudeos bazaar uninstall github-mcp
```

---

## Step 7: Game Mode

If you're about to play a game and want the agent to keep working in the background without fighting it for resources:

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

When you're done playing:

```bash
claudeos game off
```

This puts process priorities back to their original values.

Auto-detect mode watches for Steam, Lutris, or Heroic to launch:

```bash
claudeos game watch &
```

---

## Step 8: System monitor

One-shot status HUD:

```bash
claudeos status
```

Live dashboard that refreshes in place, like htop (Ctrl+C to exit):

```bash
claudeos monitor watch
```

Token usage and estimated API cost:

```bash
claudeos monitor spend
```

---

## Full demo flow (3 minutes)

We use this sequence for presentations and demos.

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

## Common workflows

### Re-run a task on the same project

```bash
# Previous sandbox is gone after merge/rollback
# Just start a new one
claudeos agent start ~/projects/myapp "Add pagination to the /users endpoint"
```

### Keep a sandbox around for later review

Choose `Q` (Quit, keep sandbox) at the diff prompt. To find it later:

```bash
claudeos sandbox list
```

Then pass its path to diff, merge, or rollback:

```bash
claudeos sandbox diff ~/.claudeos/sandboxes/my-task-1748976000
```

### Override the sandbox backend (no Btrfs)

```bash
echo 'CLAUDEOS_SANDBOX_BACKEND=copy' >> ~/.claudeos/config.env
```

The copy backend uses rsync. Sandboxes take longer to create, but it works on any filesystem.

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

Sandbox creation, agent start and stop, merges, and bazaar installs all get written to:

```
~/.claudeos/logs/audit.log
```

Format: `[TIMESTAMP] EVENT key=value key=value ...`

```bash
tail -f ~/.claudeos/logs/audit.log
```

---

## Directory reference

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
Set `CLAUDEOS_SANDBOX_BACKEND=copy` in `~/.claudeos/config.env`. The rsync copy fallback works on any filesystem, macOS APFS included.

**`jq: command not found`**
The Bazaar and state management both need `jq`. Install it with `sudo pacman -S jq`.

**MCP tool installed but not appearing in Claude Desktop**
Claude Desktop only reads MCP config at startup, so restart it after any change. The config file lives at:
- macOS: `~/Library/Application Support/Claude/claude_desktop_config.json`
- Linux: `~/.config/Claude/claude_desktop_config.json`

**Agent completed but diff shows no changes**
The agent may have worked on untracked files. If the sandbox has no `.git`, the diff falls back to an rsync dry-run. Check `~/.claudeos/logs/agent-session-*.log` to see what the agent actually did.

**Game mode says "no processes found"**
`claudeos game on` only affects agents that are already running. Start the agent first, then turn on game mode.
