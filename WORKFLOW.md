# TuringOS workflow guide

This guide walks through the scripts in order: first install, running an agent, and reviewing what it did.

---

## Prerequisites

On the TuringOS live ISO everything is already installed. On another Debian
or Ubuntu machine:

```bash
sudo apt install git jq curl rsync fzf nodejs npm
# gum (prettier prompts): https://github.com/charmbracelet/gum#installation
```

---

## Step 1: First-time setup

Run `init` once. It creates the runtime directories and checks your environment.

```bash
cd /path/to/turingos
chmod +x turingos
./turingos init
```

You'll see a dependency check like this:

```
  ✓  git          found
  ✓  jq           found
  ✓  gum          found
  ✓  fzf          found
  ⚠  nvidia-smi   not found (optional)

  TuringOS initialized

  Data dir:    ~/.turingos/
  Config:      ~/.turingos/config.env
  Agent log:   ~/.turingos/logs/
  Sandboxes:   ~/.turingos/sandboxes/
```

### Optional: add `turingos` to your PATH

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
echo 'TURINGOS_AGENT_BINARY=/usr/local/bin/claude' >> ~/.turingos/config.env
```

You can also set these in `~/.turingos/config.env`:

| Variable | Default | Purpose |
|---|---|---|
| `TURINGOS_AGENT_BINARY` | `claude` | Path to Claude Code CLI |
| `TURINGOS_SANDBOX_BACKEND` | `btrfs` | `btrfs` or `copy` (rsync fallback) |
| `TURINGOS_GAME_RENICE_LEVEL` | `10` | nice value applied in game mode |
| `TURINGOS_LOG_LEVEL` | `info` | `debug`, `info`, `warn`, or `error` |

---

## Step 3: Run your first agent task

### 3a. Point at a project and start

```bash
turingos agent start /path/to/your/project "Refactor the auth module and run tests"
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
turingos agent logs
```

Or check the current state:

```bash
turingos agent status
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
  │  Run: turingos sandbox diff              │
  ╰──────────────────────────────────────────╯
```

Now look at the changes:

```bash
turingos sandbox diff
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
turingos sandbox merge
```

This copies the agent's changes back into your original project with rsync, including deletions: a file the agent removed is removed from your project too. Your project's `.git` is never touched (commit the result yourself), and TuringOS's own `.turingos_*` files stay in the sandbox. It asks you to confirm first, then offers to destroy the sandbox.

### Rollback

```bash
turingos sandbox rollback
```

This deletes the sandbox. On Btrfs that means `btrfs subvolume delete`, which is instant and frees the space right away. On the copy backend it runs `rm -rf` on the sandbox directory.

In both cases your original project is left alone.

---

## Step 6: Install MCP tools (Bazaar)

To browse the tool registry interactively:

```bash
turingos bazaar
```

This opens an fzf picker. Select a tool, read its details, and install it.

You can also install directly by key:

```bash
turingos bazaar install github-mcp
turingos bazaar install postgres-mcp
turingos bazaar install filesystem-mcp
```

During install, TuringOS:
1. Checks that required env vars are set (e.g. `GITHUB_PERSONAL_ACCESS_TOKEN`)
2. Verifies the npx package can be downloaded
3. Registers the server with Claude Code: a user-scope entry under `mcpServers` in `~/.claude.json` (mode 600), with `${HOME}`-style placeholders in the registry filled in

New Claude Code sessions, including every agent run, pick it up automatically.

To see what's installed:

```bash
turingos bazaar installed
```

To remove a tool:

```bash
turingos bazaar uninstall github-mcp
```

---

## Step 7: Game Mode

If you're about to play a game and want the agent to keep working in the background without fighting it for resources:

```bash
turingos game on
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
  → Disable with: turingos game off
```

When you're done playing:

```bash
turingos game off
```

This puts process priorities back to their original values.

Auto-detect mode watches for Steam, Lutris, or Heroic to launch:

```bash
turingos game watch &
```

---

## Step 8: System monitor

One-shot status HUD:

```bash
turingos status
```

Live dashboard that refreshes in place, like htop (Ctrl+C to exit):

```bash
turingos monitor watch
```

Token usage and estimated API cost:

```bash
turingos monitor spend
```

---

## Full demo flow (3 minutes)

We use this sequence for presentations and demos.

```bash
# 1. Show the system is ready
turingos status

# 2. Start the agent on a real project
turingos agent start ~/projects/myapp "Refactor auth module, run tests"

# 3. Watch it work (optional — or just let it run)
turingos agent logs

# 4. Once complete, inspect the changes
turingos sandbox diff

# 5. Merge if satisfied
#    (choose M at the prompt, or run directly)
turingos sandbox merge

# 6. Demonstrate game mode
turingos game on
turingos game status
turingos game off
```

---

## Common workflows

### Re-run a task on the same project

```bash
# Previous sandbox is gone after merge/rollback
# Just start a new one
turingos agent start ~/projects/myapp "Add pagination to the /users endpoint"
```

### Keep a sandbox around for later review

Choose `Q` (Quit, keep sandbox) at the diff prompt. To find it later:

```bash
turingos sandbox list
```

Then pass its path to diff, merge, or rollback:

```bash
turingos sandbox diff ~/.turingos/sandboxes/my-task-1748976000
```

### Override the sandbox backend (no Btrfs)

```bash
echo 'TURINGOS_SANDBOX_BACKEND=copy' >> ~/.turingos/config.env
```

The copy backend uses rsync. Sandboxes take longer to create, but it works on any filesystem.

### Check logs

```bash
# Last 50 lines of TuringOS operational log
turingos logs

# Last 100 lines
turingos logs 100

# Raw log file location
turingos logs 1 2>/dev/null  # prints path implicitly via log::path
ls ~/.turingos/logs/
```

### Audit trail

Sandbox creation, agent start and stop, merges, and bazaar installs all get written to:

```
~/.turingos/logs/audit.log
```

Format: `[TIMESTAMP] EVENT key=value key=value ...`

```bash
tail -f ~/.turingos/logs/audit.log
```

---

## Directory reference

```
~/.turingos/
├── config.env          # user overrides (TURINGOS_AGENT_BINARY, etc.)
├── state.json          # active sandbox path, agent PID, game mode state
├── pids/
│   └── claude.pid      # running agent PID
├── logs/
│   ├── turingos-YYYYMMDD.log   # operational log
│   ├── audit.log               # structured action trail
│   └── agent-session-*.log     # per-session agent output
├── sandboxes/
│   └── <label>-<timestamp>/    # one directory per sandbox
│       ├── .turingos_sandbox   # metadata (source project, backend, etc.)
│       └── .turingos_prompt    # task prompt written for the agent
└── bazaar/
    └── <tool-key>/
        ├── .installed          # timestamp of install
        └── run.sh              # launcher script (npx tools)
```

---

## Troubleshooting

**`claude: command not found`**
Set `TURINGOS_AGENT_BINARY` in `~/.turingos/config.env` to the full path of your Claude Code CLI binary.

**Sandbox creation fails with "not a btrfs subvolume"**
Set `TURINGOS_SANDBOX_BACKEND=copy` in `~/.turingos/config.env`. The copy backend works on any filesystem. TuringOS also falls back to it by itself when a snapshot can't be made.

**`jq: command not found`**
The Bazaar and state management both need `jq`. Install it with `sudo apt install jq`.

**MCP tool installed but not appearing in Claude Code**
Claude Code reads `~/.claude.json` when a session starts, so start a new session. Check the entry with `claude mcp list`.

**Agent completed but diff shows no changes**
The agent may have worked on untracked files. The diff compares the sandbox with your project's working tree (what merge would apply), untracked files included. Check `~/.turingos/logs/agent-session-*.log` to see what the agent actually did.

**Game mode says "no processes found"**
`turingos game on` only affects agents that are already running. Start the agent first, then turn on game mode.
