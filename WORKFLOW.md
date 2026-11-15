# TuringOS workflow guide

This guide walks through the `turingos` command in the order you'd use it:
first-time setup, running an agent in a sandbox, reviewing what it did, then
the Bazaar, Game Mode and the monitor. It is for TuringOS v1.3.

---

## Prerequisites

On the TuringOS live ISO everything is already installed. On another Debian
or Ubuntu machine:

```bash
sudo apt install git jq curl rsync fzf nodejs npm openssl
# gum (prettier prompts): https://github.com/charmbracelet/gum#installation
# Claude Code: turingos init offers to install it
```

`git`, `jq` and `curl` are required. `rsync`, `gum`, `fzf` and `btrfs` are
optional but worth having: without rsync the copy backend falls back to
`cp -a`, without fzf `turingos bazaar` prints a list instead of a picker.
`openssl` and `npm` are used by the Bazaar (signature check and npm tools).

---

## Step 1: First-time setup

Run `init` once. It creates the runtime directories, checks your environment,
looks for Claude Code and an API key, and offers to pick a model provider.

```bash
cd /path/to/turingos
chmod +x turingos
./turingos init
```

The dependency check looks like this (trimmed, after the banner):

```
  →  Initializing TuringOS...

  ✓  Runtime directories created: /home/you/.turingos

  →  Checking dependencies...

  git                          ✓  found
  jq                           ✓  found
  curl                         ✓  found

  gum                          ✓  found
  fzf                          ✓  found
  rsync                        ✓  found
  btrfs                        ⚠  not found (optional)
  notify-send                  ✓  found
  nvidia-smi                   ⚠  not found (optional)
  opencode                     ⚠  not found (optional)

  ...
  ✓  TuringOS initialized

  →  Data dir:    /home/you/.turingos
  →  Config:      /home/you/.turingos/config.env
  →  Agent log:   /home/you/.turingos/logs/
  →  Sandboxes:   /home/you/.turingos/sandboxes/
```

### Optional: add `turingos` to your PATH

```bash
echo 'export PATH="$PATH:/path/to/turingos"' >> ~/.bashrc
source ~/.bashrc
```

The examples below assume you did this and leave off the `./` prefix.

---

## Step 2: Configure the agent

By default TuringOS runs `claude` (the Claude Code CLI) as the agent. To point
it at a binary somewhere else:

```bash
echo 'TURINGOS_AGENT_BINARY=/usr/local/bin/claude' >> ~/.turingos/config.env
```

`~/.turingos/config.env` is sourced on every run, and it holds API keys, so
keep it mode 600 (`turingos` creates it that way when it writes to it).
Settings you can put in it:

| Variable | Default | Purpose |
|---|---|---|
| `TURINGOS_AGENT_BINARY` | `claude` | Path to the Claude Code CLI |
| `TURINGOS_AGENT_MODEL` | unset | Passed to `claude --model` |
| `TURINGOS_SANDBOX_BACKEND` | `btrfs` | `btrfs` or `copy` (rsync fallback) |
| `TURINGOS_GAME_RENICE_LEVEL` | `10` | nice value applied in Game Mode |
| `TURINGOS_LOG_LEVEL` | `info` | `debug`, `info`, `warn`, or `error` |
| `TURINGOS_MODEL_PROVIDER` | `claude` | `claude`, `nvidia`, `ollama`, `openrouter` or `custom` |
| `TURINGOS_MODEL_ENDPOINT`, `TURINGOS_MODEL_NAME` | empty | Endpoint and model for the non-Claude providers |
| `ANTHROPIC_API_KEY` | unset | Key for Claude |
| `TURINGOS_BAZAAR_REMOTE_URL` | `https://uncoalesced.github.io/turingos-bazaar/v1/index.json` | Where the Bazaar catalogue comes from |
| `TURINGOS_BAZAAR_OFFLINE_MODE` | `0` | `1` never fetches the remote catalogue |

### Other model providers

Anything other than `claude` runs through OpenCode instead of Claude Code.

```bash
turingos model status                       # provider, endpoint, model, and a reachability check
turingos model set ollama                   # claude | nvidia | ollama | openrouter | custom
turingos model set ollama http://localhost:11434 llama3.2
turingos model use <model>                  # change the default model
```

`openrouter` reads `OPENROUTER_API_KEY` and `nvidia` reads `NVIDIA_API_KEY`;
an agent run only gets the key of the active provider of the two. `turingos image
"<prompt>" [out.jpg]` generates an image with NVIDIA FLUX.

---

## Step 3: Run your first agent task

### 3a. Point at a project and start

```bash
turingos agent start /path/to/your/project "Refactor the auth module and run tests"
```

With no project it uses the current directory, and with no task it asks for one.
TuringOS then:

1. Makes a sandbox copy of your project: a Btrfs snapshot if the project is a Btrfs subvolume, otherwise an rsync copy (or `cp -a`)
2. Writes the task prompt into the sandbox as `.turingos_prompt`
3. Runs Claude Code in the sandbox, unattended (`claude --print --output-format stream-json --dangerously-skip-permissions`). The sandbox copy is the safety boundary, which is why it doesn't ask permission for each tool call.
4. Asks whether to follow the agent's output now

Nothing in your original project changes until you merge. Only one agent runs
at a time.

### 3b. Watch it run

If you skipped following at startup:

```bash
turingos agent logs
```

While the agent runs this tails the session log; afterwards it opens the last
one in `less`. To check the current state:

```bash
turingos agent status
```

```
  ╭────────────────────────────────────────────╮
  │                Agent Status                │
  ╰────────────────────────────────────────────╯

  Agent                        ✓  running
    PID                  18432
    Task                 Refactor the auth module and run tests
    Sandbox              /home/you/.turingos/sandboxes/Refactor_the_auth_module_and_run-1794700000
    CPU                  4.2%
    RAM                  1.8%

  →  Recent output:
      (the last six lines of the session log)
```

The session log holds Claude Code's `stream-json` events, so the recent output
is raw JSON lines. `turingos agent stop` stops the agent (after a
confirmation).

---

## Step 4: Review what the agent changed

When the agent finishes it prints a completion box (and sends a desktop
notification if `notify-send` is installed):

```
  ╭─ TuringOS ───────────────────────────────╮
  │  Agent task completed                    │
  │  14 passed, 0 failed                     │
  │                                          │
  │  Run: turingos sandbox diff              │
  ╰──────────────────────────────────────────╯
```

The test line appears when the agent wrote one to `.turingos_test_result` in
the sandbox, or when the log contains a pytest or jest summary. If the agent
exits with an error you get a red box pointing at `turingos agent logs`.

Now look at the changes:

```bash
turingos sandbox diff
```

The diff compares the sandbox with your project's working tree, which is
exactly what a merge would apply. `.git` and TuringOS's own `.turingos_*`
files are left out.

```
  Task                   Refactor the auth module and run tests
  Sandbox                Refactor_the_auth_module_and_run-1794700000
  Project                /home/you/myproject
  Created                2026-11-15T10:42:07
  Backend                btrfs

  ────────────────────────────────────────────

  5 file(s) changed   +143   -67

    M  src/auth/handler.py
    M  src/auth/middleware.py
    M  tests/test_auth.py
    A  src/auth/utils.py
    D  src/auth/legacy.py

  ✓  Tests: 14/14 passed
```

Then pick what to do:

```
  [ M ] Merge changes into project
  [ R ] Rollback — discard all changes
  [ V ] View full diff
  [ S ] Save diff to file
  [ Q ] Quit (keep sandbox)
```

View uses `delta` if it's installed, otherwise `less`. Save writes a patch to
`~/.turingos/logs/diff-<timestamp>.patch`.

---

## Step 5: Merge or roll back

### Merge

```bash
turingos sandbox merge
```

This shows the files and line counts, asks you to confirm, then copies the
agent's changes back into your original project with rsync. Deletions are
copied too: a file the agent removed is removed from your project. Your
project's `.git` is never touched (commit the result yourself), and
TuringOS's own `.turingos_*` files stay in the sandbox. It then offers to
destroy the sandbox.

### Rollback

```bash
turingos sandbox rollback
```

This deletes the sandbox after a confirmation. On Btrfs that means
`btrfs subvolume delete`, which is instant and frees the space right away. On
the copy backend it runs `rm -rf` on the sandbox directory.

In both cases your original project is left alone.

---

## Step 6: Install MCP tools (Bazaar)

The Bazaar is TuringOS's catalogue of MCP tools. To browse it interactively:

```bash
turingos bazaar
```

This opens an fzf picker. Select a tool, read its details, and install it.
Other ways in:

```bash
turingos bazaar search github     # key, name, description and tags
turingos bazaar info github-mcp
turingos bazaar install github-mcp
turingos bazaar install -y postgres-mcp   # -y skips the prompts
```

The bundled registry has `brave-search-mcp`, `filesystem-mcp`, `github-mcp`,
`memory-mcp` and `postgres-mcp`; the catalogue online may list more.

During install, TuringOS:

1. Checks that required env vars are set (for `github-mcp`, `GITHUB_PERSONAL_ACCESS_TOKEN`). If one is missing it says so and asks whether to continue. Put `KEY=value` lines in `~/.turingos/config.env`, or export them.
2. For an npm tool: refuses an entry with no pinned version and SHA-256, downloads the package tarball, and checks its SHA-256 against the registry entry
3. Registers the server with Claude Code: a user-scope entry under `mcpServers` in `~/.claude.json` (mode 600), pinned to the verified version, with `${HOME}`-style placeholders filled in

New Claude Code sessions, including every agent run, pick it up automatically.

### Where the catalogue comes from

TuringOS fetches the catalogue from `TURINGOS_BAZAAR_REMOTE_URL`, along with a
detached Ed25519 signature (`<url>.sig`), and checks it with `openssl` against
the Bazaar public key (`/etc/turingos/trust/bazaar.pub` on the ISO,
`trust/keys/bazaar.pub` in a checkout). A catalogue with a missing or invalid
signature is rejected. A good one is cached for 24 hours in
`~/.cache/turingos/bazaar/index.json`. If the fetch or the check fails, you get
the stale cache, then the registry bundled with TuringOS, and the screens say
"[offline catalogue]".

### Installed tools

```bash
turingos bazaar installed
turingos bazaar uninstall github-mcp     # removes the tool and its mcpServers entry
```

### Turn a tool off for one project

```bash
turingos bazaar disable github-mcp ~/projects/myapp   # directory defaults to the current one
turingos bazaar enable github-mcp ~/projects/myapp
turingos bazaar rules ~/projects/myapp                # what's disabled there
turingos bazaar toggle                                # fzf toggle for the current directory
```

Rules are kept in `~/.turingos/bazaar_rules.json` and mirrored into that
project's `.claude/settings.json` as `disabledMcpServers`, which is what
Claude Code reads.

---

## Step 7: Game Mode

If you're about to play a game and want the agent to keep working in the
background without fighting it for resources:

```bash
turingos game on
```

It lowers the priority (`renice` and `ionice`) of background processes it can
change: `claude`, `opencode`, `ollama`, `node`, `python3`, `cargo`, `rustc`,
`make` and `ninja`. Output:

```
  ╭─ TURINGOS GAME MODE ─────────────────────╮
  │  claude [18432]  -> LOW                  │
  │  ollama [9811]  -> LOW                   │
  │                                          │
  │  Interactive apps have priority          │
  ╰──────────────────────────────────────────╯

  →  Agents continue running in background
  →  Disable with: turingos game off
```

When you're done playing:

```bash
turingos game off
```

This puts each process back to the priority it had before. Raising priority
back may need root; processes it can't restore keep low priority until they
restart, and `game off` says how many.

Auto-detect mode watches for Steam, Lutris, Heroic, Wine or gamescope to
launch, and turns Game Mode on and off for you:

```bash
turingos game watch &
```

---

## Step 8: System monitor

One-shot status HUD (agent, sandbox, GPU, CPU, RAM, Game Mode, MCP servers):

```bash
turingos status
```

Live dashboard that refreshes in place every 3 seconds (Ctrl+C to exit; pass a
number of seconds to change the interval):

```bash
turingos monitor watch
turingos monitor watch 10
```

Token usage and estimated API cost, summed from the agent session logs at
$3 and $15 per million input and output tokens:

```bash
turingos monitor spend
```

---

## Desktop UI

```bash
turingos ui
```

On the ISO the desktop UI is already open: it is the shell the session
starts. From a checkout `turingos ui` runs `ui/run.sh`. See
[`ui-docs/SETUP.md`](ui-docs/SETUP.md).

`turingos dashboard` is a text menu for the commands above, for when you'd
rather pick than type.

---

## Full demo flow (3 minutes)

We use this sequence for presentations and demos.

```bash
# 1. Show the system is ready
turingos status

# 2. Start the agent on a real project
turingos agent start ~/projects/myapp "Refactor auth module, run tests"

# 3. Watch it work (optional, or just let it run)
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
turingos sandbox diff ~/.turingos/sandboxes/Refactor_the_auth_module_and_run-1794700000
```

`turingos sandbox status` shows the active sandbox, and `turingos sandbox
create [project] [label]` makes one without starting an agent.

### Override the sandbox backend (no Btrfs)

```bash
echo 'TURINGOS_SANDBOX_BACKEND=copy' >> ~/.turingos/config.env
```

The copy backend uses rsync. Sandboxes take longer to create, but it works on
any filesystem.

### Check logs

```bash
# Last 50 lines of today's TuringOS log
turingos logs

# Last 100 lines
turingos logs 100

ls ~/.turingos/logs/
```

### Audit trail

Sandbox creation, agent start, completion and stop, merges, rollbacks, Game
Mode changes, and Bazaar installs and uninstalls are all written to:

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
├── config.env          # user overrides (TURINGOS_AGENT_BINARY, API keys, etc.), mode 600
├── state.json          # active sandbox path, agent PID and task, game mode state
├── bazaar_rules.json   # per-directory Bazaar enable/disable rules
├── pids/
│   └── claude.pid      # running agent PID
├── logs/
│   ├── turingos-YYYYMMDD.log   # operational log
│   ├── audit.log               # structured action trail
│   ├── agent-session-*.log     # per-session agent output
│   └── diff-*.patch            # diffs saved from the inspector
├── sandboxes/
│   ├── <label>-<timestamp>.meta # metadata (source project, backend, etc.), outside the sandbox
│   └── <label>-<timestamp>/    # one directory per sandbox
│       ├── .turingos_prompt        # task prompt written for the agent
│       └── .turingos_test_result   # test summary, if there is one
├── models/             # the Whisper speech model, after first mic use
└── bazaar/
    └── <tool-key>/
        ├── .installed          # timestamp of install
        └── run.sh              # launcher script (npx tools)
```

The Bazaar catalogue cache is `~/.cache/turingos/bazaar/index.json`, and MCP
servers are registered in `~/.claude.json`.

---

## Troubleshooting

**`Agent binary not found: claude`**
Set `TURINGOS_AGENT_BINARY` in `~/.turingos/config.env` to the full path of your Claude Code CLI binary, or run `turingos init` to install it. With a non-Claude provider the binary is `opencode` (`TURINGOS_OPENCODE_BINARY`).

**The diff says Backend: copy on a Btrfs machine**
TuringOS snapshots only when the project is on Btrfs and is a subvolume. Otherwise it quietly uses the copy backend, and the Backend line in the sandbox output says which one you got. Nothing needs fixing for the copy backend; it's just slower.

**`jq: command not found`**
The Bazaar and state management both need `jq`. Install it with `sudo apt install jq`.

**MCP tool installed but not appearing in Claude Code**
Claude Code reads `~/.claude.json` when a session starts, so start a new session. Check the entry with `claude mcp list`.

**Bazaar says "[offline catalogue]" or "Rejecting untrusted catalog"**
The remote catalogue couldn't be fetched, or its signature didn't check out, so you're on the cache or the bundled registry. Check your network and that `openssl` and the public key are present.

**Agent completed but diff shows no changes**
The agent may not have changed anything that differs from your working tree. The diff compares the sandbox with your project's working tree (what merge would apply), untracked files included. Check `~/.turingos/logs/agent-session-*.log` to see what the agent actually did.

**Game Mode says "No background processes found"**
`turingos game on` only affects processes that are already running. Start the agent first, then turn on Game Mode.
