# TuringOS manual

This is the manual for TuringOS 1.3-stable. It covers what the system is, how to install it, how its parts fit together, and what every command does. Where the code and an older document disagree, this manual follows the code.

Contents:

1. [What TuringOS is](#what-turingos-is)
2. [Install](#install)
3. [Quick start](#quick-start)
4. [Architecture](#architecture)
5. [CLI reference](#cli-reference)
6. [Configuration](#configuration)
7. [The Bazaar](#the-bazaar)
8. [Trust model and security](#trust-model-and-security)
9. [UI shell](#ui-shell)
10. [Game mode](#game-mode)
11. [Building the ISO](#building-the-iso)
12. [Testing](#testing)
13. [Troubleshooting](#troubleshooting)
14. [Design language](#design-language)

---

## What TuringOS is

TuringOS is a Debian 13 ("trixie") based live and installable operating system for running Claude Code agents against your own projects without handing them the originals. Each agent task runs in a snapshot or copy of the project. When the agent finishes, you read a diff and decide whether to merge it back or throw it away.

The pieces:

- A bash CLI, `turingos`, that creates sandboxes, starts and stops agents, reviews diffs, manages MCP tools, and shows system state.
- The Bazaar, a catalogue of MCP tool servers. The index is signed with Ed25519 and checked before it is trusted. A copy of the catalogue ships on the image for offline use.
- A desktop shell: a web page served by a local bridge and shown in a Brave app window, with a small Rust service, `turingosd`, behind it.
- A set of Python "trust" daemons for audit logging, capability grants, tool sandboxing, plan approval and egress control, plus a shell fallback for when the model is unreachable.
- Game mode, which lowers the priority of agent and build processes while you play.
- Hooks and scripts that build the whole thing into an amd64 or arm64 hybrid ISO.

What the sandbox is, and is not. It is a copy-on-write snapshot (Btrfs) or a plain copy of the project directory, kept under `~/.turingos/sandboxes`. The agent runs as your own user with `--dangerously-skip-permissions`, and its prompt tells it to work only inside the sandbox. The sandbox protects your project because nothing reaches it until you merge. It is not process isolation, and a determined agent can still touch anything your user can. `SECURITY.md` lists sandbox escape as something the maintainers want reported.

---

## Install

### Live ISO

Download the image for your architecture from the [releases page](https://github.com/uncoalesced/TuringOS/releases):

| File | Architecture |
|---|---|
| `turingos-amd64.hybrid.iso` | x86_64 |
| `turingos-arm64.hybrid.iso` | aarch64 (UEFI/GRUB only) |

Check the download against the SHA-256 published with the release before you boot it.

Boot it in a VM (the project's README suggests 4 GB of RAM and 2 CPUs, with either EFI or BIOS firmware on amd64) or write it to a USB stick:

```bash
sudo dd if=turingos-amd64.hybrid.iso of=/dev/sdX bs=4M status=progress
```

Replace `/dev/sdX` with the stick, and check the name twice. `dd` overwrites whatever you point it at.

The boot menu starts the default entry after 3 seconds. The live session logs in by itself as `user` (password `live`, passwordless sudo) and opens the desktop shell. On the first interactive terminal, a welcome banner appears once, and you are asked for an Anthropic API key once. A blank answer skips it. The key is saved to `~/.turingos/config.env`.

Boot menu entries are named "TuringOS". Besides the default there are:

- an entry ending in "(persistence)",
- an entry ending in "(safe mode)", which adds `turingos.safe` to the kernel command line. Safe mode starts no agent services and no TuringOS UI: just the window manager and a terminal.

On arm64 the menu is GRUB only. On amd64 there is both an isolinux (BIOS) and a GRUB (UEFI) menu.

### Persistence

Both build scripts put `persistence` on the kernel command line of every entry (`boot=live components quiet splash persistence`). The system uses a partition labelled `persistence` if it finds one. With no such partition, nothing you change is saved.

Make the partition once, from any Linux machine, with `pkg/make-persistence.sh`:

```bash
sudo ./pkg/make-persistence.sh /dev/sdX          # add a partition in the disk's free space
sudo ./pkg/make-persistence.sh /dev/sdX3         # format an existing partition
sudo ./pkg/make-persistence.sh /tmp/p.img 4G     # create a disk image (for QEMU)
```

Options: `-y`/`--yes` skips the confirmation, `-f`/`--force` overwrites an existing filesystem on the target partition, `-h`/`--help` prints usage. The script creates an ext4 filesystem labelled `persistence` and writes `persistence.conf` containing `/ union`. Existing partitions are never touched unless you name one.

With persistence in place, `~/.turingos`, API keys, Claude Code logins and installed MCP tools survive reboots. The image ships `cryptsetup` and `lvm2`.

### Install to disk with Calamares

The live session can install itself. Click Install in the dock, or run `turingos-install`. The Calamares installer is branded for TuringOS, partitions the disk, creates your account and installs GRUB (the GRUB packages ride on the image, so it works offline). The account you create logs in automatically, like the live user, and Homebrew ownership is handed to it. Give the target a disk of 20 GB or more.

The project lists these as known issues: BIOS installs and Secure Boot are untested, Raspberry Pi bootloaders and BIOS on arm64 are untested, and the installer's "Erase disk" option makes a swap partition as large as your RAM. `debian-live/KNOWN_ISSUES.md` also notes that OpenCode is the largest single item in the image and that a missing microphone is never reported.

### Running from a checkout on another Debian

You do not need the ISO to use the CLI. On a Debian machine:

```bash
git clone https://github.com/uncoalesced/TuringOS
cd TuringOS
chmod +x turingos
./turingos init
```

`turingos init` creates `~/.turingos`, checks dependencies and offers to install the Claude Code CLI, set an API key and pick a model provider.

Dependencies, as `init` checks them:

| Kind | Commands |
|---|---|
| Required | `git`, `jq`, `curl` |
| Optional | `gum`, `fzf`, `rsync`, `btrfs`, `notify-send`, `nvidia-smi`, `opencode` |

`init` lists `rsync` as optional, but `sandbox diff` and `sandbox merge` depend on it (see [Troubleshooting](#troubleshooting)), so install it. Bazaar signature checks need the `openssl` command, and installs of npm-based tools need `npm`.

To get the desktop shell from a checkout, see [UI shell](#ui-shell).

---

## Quick start

```bash
turingos init                                        # once
turingos agent start ~/code/myproject "Fix the failing tests"
turingos agent status                                # or: turingos agent logs
turingos sandbox diff                                # review what changed
```

`sandbox diff` shows the changed files and a line count, then offers a menu: merge, roll back, view the full diff, save the diff, or quit and keep the sandbox. Merge copies the sandbox over the project with `rsync --delete`, so files the agent deleted are deleted in the project too. The project's `.git` is never overwritten.

If you leave out the project, `agent start` uses the current directory. If you leave out the task, it asks for one.

---

## Architecture

### The agent path

```
 you
  │  turingos agent start <project> "<task>"
  ▼
 turingos (bash CLI; modules in core/ agent/ sandbox/ bazaar/ game/ monitor/ voice/)
  │
  ├─ sandbox/btrfs.sh ── btrfs snapshot  or  copy (rsync / cp -a)
  │                       └─ ~/.turingos/sandboxes/<name>/  +  <name>.meta
  │
  └─ agent/claude.sh ─── claude --print --output-format stream-json ...   (provider: claude)
                    └─── opencode run --model <provider>/<model> ...      (any other provider)
                              │  runs inside the sandbox directory
                              ▼
                     log: ~/.turingos/logs/agent-session-<time>.log
  │
  ▼
 turingos sandbox diff  ->  merge (rsync --delete into the project)  or  rollback
```

`turingos` is a thin router. It sources its modules, then dispatches on the first two arguments. State lives in `~/.turingos/state.json` (active sandbox, agent PID and task, game mode) and PID files in `~/.turingos/pids/`.

Sandbox backends: `btrfs` (the default) uses `btrfs subvolume snapshot` and needs the `btrfs` tool, a project that is a Btrfs subvolume, and the sandbox directory on the same filesystem. If any of that is missing, or `TURINGOS_SANDBOX_BACKEND=copy`, it falls back to a copy. Each sandbox has a metadata file next to it (`<name>.meta`, not inside it) so the agent cannot redirect a merge by editing it.

### The desktop path

```
 Brave app window  (session/turingos-kiosk, restarted by turingos-respawn)
        │  http://127.0.0.1:8080
        ▼
 turingos-bridged-ws   (trust/daemons/bridged-ws.py, system user "turingos")
   │  serves ui/web at /, plus /health and /boot.js
   │
   ├─ /desktop ──▶ <uid>.desktop.sock ──▶ turingosd   (Rust, your login session)
   │                                       state, projects, agent start, dock, voice,
   │                                       Wi-Fi, Google sign-in, Bazaar calls, one-shot chat
   │                                       └─ runs `turingos agent start ...`
   ├─ /shell   ──▶ <uid>.sock ─────────▶ shell-helper (Python, your login session)
   │                                       shell mode when the model is unreachable
   └─ /plan /agent /cap /memory /bridge ─▶ trust daemons over Unix sockets in /run/turingos
```

Pieces, one by one:

- `turingos` CLI: everything in the CLI reference below. It does not call the trust daemons.
- Sandbox backends: `btrfs` and `copy`, described above.
- Agent: Claude Code by default. Any other provider (`nvidia`, `ollama`, `openrouter`, `custom`) runs through OpenCode.
- `turingosd` (`daemon/`, Rust): the desktop service. It runs in your login session as a systemd user unit (`session/turingosd.service`), reads `~/.turingos`, and answers the page over the bridge. Its protocol is in `protocol/v1/README.md`. It also opens a control socket at `$XDG_RUNTIME_DIR/turingos/control.sock` (mode 0600) that takes `POST /omni` (the Super+Space hotkey), `GET /status`, `GET /bazaar/list`, `POST /bazaar/install` and `GET /bazaar/rules`.
- `turingos-bridged-ws`: a FastAPI/uvicorn server that serves the page and relays WebSocket messages. It listens on `127.0.0.1:8080` only.
- Trust daemons: `auditd`, `capd`, `sandboxd`, `toolreg`, `agentd-llm`, `agentd-plan`, `memoryd`, `bridged` (egress control, not to be confused with `bridged-ws`) and `shell-helper`. Details in [Trust model and security](#trust-model-and-security).
- Session: LightDM autologins `user` into the `turingos-hyprland` Wayland session. If the machine has no `/dev/dri/renderD*`, or Hyprland exits with an error, `session/turingos-hyprland` falls back to an X session running `openbox-session` on the same VT. Either way the autostart script starts `turingosd` and then `turingos-kiosk` under `turingos-respawn`. The kiosk script opens Brave (or another Chromium-family browser) as an `--app` window on the bridge's page.
- `ui/web`: the page itself. Plain classic scripts and CSS, no build step.

`turingos-shell.service` (a Wayland compositor plus browser launcher) is installed but not enabled on the ISO.

---

## CLI reference

Run `turingos help` for the built-in list. `turingos version` (also `--version`, `-v`) prints `TuringOS v1.3`. Running with no arguments, `help`, `--help` or `-h` prints the help.

Commands that ask a yes/no question (`agent stop`, `sandbox merge`, `sandbox rollback`) read the answer from the terminal. Set `TURINGOS_NO_GUM=1` to force plain prompts even when `gum` is installed. `gum` is only used on a real terminal with a size.

### Setup and misc

| Command | What it does |
|---|---|
| `turingos init` | Creates `~/.turingos`, checks dependencies, offers to install Claude Code, reports whether `ANTHROPIC_API_KEY` is set, offers to configure a model provider. |
| `turingos dashboard` | Interactive menu over the commands below. Needs a terminal. |
| `turingos ui [--gfx sw.lite\|sw.minimal]` | From a checkout, runs `ui/run.sh` (see [UI shell](#ui-shell)). On the ISO there is no `ui/run.sh`, so it runs `session/turingos-kiosk`. Extra arguments go to `ui/run.sh`. |
| `turingos logs [N]` | Last N lines (default 50) of today's log, `~/.turingos/logs/turingos-YYYYMMDD.log`. |
| `turingos version` | Prints the version. |
| `turingos help` | Prints the command list. |

### Agent

| Command | What it does |
|---|---|
| `turingos agent start [project] [task]` | Creates a sandbox of `project` (default: current directory), writes a prompt file into it and starts the agent in the background. Refuses if an agent is already running. Offers to follow the output when run from a terminal. |
| `turingos agent stop` | Asks for confirmation, then sends TERM to the agent's process group, and KILL if it is still alive a second later. |
| `turingos agent status` (or just `turingos agent`) | Shows running/idle state, PID, task, sandbox, CPU and memory, and the last lines of the log. |
| `turingos agent logs` | Tails the newest `agent-session-*.log` while the agent runs, or pages it with `less` when it has finished. |

What `agent start` runs, for provider `claude`:

```
claude --print --verbose --output-format stream-json --dangerously-skip-permissions [--model $TURINGOS_AGENT_MODEL] < prompt
```

The prompt tells the agent its sandbox path, asks it to stay inside it, run applicable tests and write a result line (`<N> passed, <M> failed`) to `.turingos_test_result` in the sandbox. If the agent did not write one, TuringOS looks in the log for a pytest or jest style summary. When the agent exits you get a desktop notification (through `notify-send`, if present) and a box pointing at `turingos sandbox diff` or `turingos agent logs`.

Before launch, `model::scrub_keys` unsets every provider API key except the active provider's own (`NVIDIA_API_KEY`, `OPENROUTER_API_KEY`).

For other providers it runs `opencode run --model <provider>/<model> "<prompt>"` inside the sandbox. For `nvidia` it tries the default model, then each backup in order, and stops at the first exit code 0. Note that a failed task counts as a failed model, so the next model starts in the same sandbox.

If the agent binary is missing, `agent start` stops and tells you to set `TURINGOS_AGENT_BINARY` or `TURINGOS_OPENCODE_BINARY` in `~/.turingos/config.env`.

### Sandbox

| Command | What it does |
|---|---|
| `turingos sandbox create [project] [label]` | Creates a sandbox and makes it the active one. Progress goes to stderr, nothing is printed to stdout. The sandbox is named `<label>-<unix time>`, with the label cut down to 32 safe characters. |
| `turingos sandbox diff [sandbox]` | Summary of added, modified and deleted files plus line counts, test results, and an action menu. |
| `turingos sandbox merge [sandbox]` | Shows the summary, asks, then runs `rsync -a --checksum --delete` from the sandbox into the project, excluding `.git` and `.turingos_*`. Then offers to destroy the sandbox. |
| `turingos sandbox rollback [sandbox]` | Asks, then deletes the sandbox (`btrfs subvolume delete` for Btrfs sandboxes). The original project is untouched. |
| `turingos sandbox list` | Lists sandboxes with creation time, source project and label. |
| `turingos sandbox status` (or just `turingos sandbox`) | Shows the active sandbox. |

With no `[sandbox]` argument, diff, merge and rollback use the active sandbox. A path must be a direct child of `~/.turingos/sandboxes` with a metadata file next to it, or the command refuses. `sandbox create` also refuses `/`, the sandbox directory, anything inside it, and any directory that contains it.

The diff menu has five entries: merge, rollback, view the full diff (paged with `delta` if installed, else `less`), save the diff to `~/.turingos/logs/diff-<time>.patch`, quit. Full-diff and save exist only in that menu, not as subcommands.

Test results are read from `.turingos_test_result`, `test-results.txt` or `pytest_output.txt` in the sandbox, in that order.

### Bazaar

| Command | What it does |
|---|---|
| `turingos bazaar` | Interactive browser (needs `fzf`, otherwise prints the list). Selecting a tool shows its details and offers to install it. |
| `turingos bazaar search <query>` | Case-insensitive search over key, name, description and tags. |
| `turingos bazaar info <tool>` | Details, required environment variables (marked set or not), install status. |
| `turingos bazaar install [-y] <tool>` | Installs the tool and registers it with Claude Code. `-y` or `--yes` skips the "Reinstall?" question, in either argument position. |
| `turingos bazaar uninstall [-y] <tool>` | Removes the tool directory and its `~/.claude.json` entry. Same `-y` rule. |
| `turingos bazaar installed` | Lists installed tools. |
| `turingos bazaar disable <tool> [dir]` | Disables a tool for a directory (default: current). |
| `turingos bazaar enable <tool> [dir]` | Re-enables it. |
| `turingos bazaar rules [dir]` | Shows what is disabled for a directory. |
| `turingos bazaar toggle [dir]` | `fzf` list of installed tools to flip on or off. Without `fzf` it shows the rules instead. |

An unknown subcommand such as `turingos bazaar github-mcp` prints a hint: did you mean `turingos bazaar install github-mcp`. More in [The Bazaar](#the-bazaar).

### Game mode

| Command | What it does |
|---|---|
| `turingos game on` | Lowers the priority of agent and build processes. |
| `turingos game off` | Restores the saved priorities. |
| `turingos game status` (or just `turingos game`) | State, detected game launchers, priorities of background processes, load average. |
| `turingos game watch` | Polls every 5 seconds and switches game mode on and off as launchers appear. Meant to run in the background: `turingos game watch &`. |

### Monitor

| Command | What it does |
|---|---|
| `turingos status` | One-shot HUD: agent, sandbox, GPU and VRAM, CPU load, RAM, game mode, number of MCP servers in `~/.claude.json`. |
| `turingos monitor` | Same as `status`. |
| `turingos monitor watch [seconds]` | Refreshing HUD. Interval defaults to 3 seconds. Ctrl+C to exit. |
| `turingos monitor spend` | Sums token usage from agent logs and estimates cost. |

GPU data comes from `nvidia-smi` or `rocm-smi`. `monitor spend` reads the last `input_tokens` and `output_tokens` value in each `agent-session-*.log`, adds them across sessions, and estimates cost at 3 and 15 US dollars per million input and output tokens. Treat the cost as a rough guide.

### Models

| Command | What it does |
|---|---|
| `turingos model status` (or just `turingos model`) | Shows provider, endpoint, model and, for NVIDIA, backups, picked models and image model. Pings the endpoint for non-Claude providers. |
| `turingos model set <provider> [endpoint] [model]` | `provider` is `claude`, `nvidia`, `ollama`, `openrouter` or `custom`. A second argument without `://` is taken as the model name. For `nvidia` with no model it opens a picker (models, default, up to 3 backups, image model, then the API key). |
| `turingos model use <model>` | Changes the default model name. |
| `turingos image "<prompt>" [out.jpg]` | Generates an image with NVIDIA FLUX (default `black-forest-labs/flux.1-dev`) and saves it. Needs `NVIDIA_API_KEY`. Default file name is `image-<time>.jpg`. |

Default endpoints: Ollama `http://localhost:11434`, OpenRouter `https://openrouter.ai/api/v1`, NVIDIA `https://integrate.api.nvidia.com/v1`. For `ollama` and `custom`, TuringOS writes an OpenCode provider config to `~/.turingos/opencode-<provider>.json` (pointing at `<endpoint>/v1`). OpenRouter needs `OPENROUTER_API_KEY`.

### Voice

| Command | What it does |
|---|---|
| `turingos voice status` (or just `turingos voice`) | Backend, Whisper model state, Wispr session state. |
| `turingos voice backend whisper\|wispr` | Picks the speech-to-text backend. Restart the desktop UI to apply. |
| `turingos voice wispr-import <session.json> [config.json]` | Imports a Wispr Flow session and installs the unofficial `wisprflow-re` client into `~/.turingos/wispr/venv`. Asks first, because it is unofficial. |

The default backend is local Whisper. The model (`ggml-base.en.bin`, about 142 MB) downloads on first microphone use into `~/.turingos/models/`.

---

## Configuration

### config.env

`~/.turingos/config.env` is a shell file that the CLI sources on every run, with everything exported so API keys reach `claude` and `opencode`. `turingos model set` and the key prompts write to it through `config::set`, which keeps the file mode 600. You can edit it by hand using `KEY=value` lines. Because it is sourced after defaults are computed, a value in `config.env` overrides the same variable in your shell.

`turingosd` does not source the file. It reads a few keys from it itself (see the last table below).

| Variable | Default | Meaning |
|---|---|---|
| `TURINGOS_AGENT_BINARY` | `claude` | Agent command for the `claude` provider. |
| `TURINGOS_OPENCODE_BINARY` | `opencode` | Agent command for every other provider. |
| `TURINGOS_AGENT_MODEL` | unset | Passed to `claude --model`. The desktop model picker sets it per run. |
| `TURINGOS_SANDBOX_BACKEND` | `btrfs` | `btrfs` or `copy`. |
| `TURINGOS_GAME_RENICE_LEVEL` | `10` | Nice value for game mode. |
| `TURINGOS_LOG_LEVEL` | `info` | `debug`, `info`, `warn` or `error`: what is mirrored to the terminal (everything is written to the log file). |
| `TURINGOS_NOTIFICATION_TITLE` | `TuringOS` | Title of desktop notifications. |
| `TURINGOS_MODEL_PROVIDER` | `claude` | `claude`, `nvidia`, `ollama`, `openrouter`, `custom`. |
| `TURINGOS_MODEL_ENDPOINT` | empty | Provider endpoint. |
| `TURINGOS_MODEL_NAME` | empty | Default model. |
| `TURINGOS_NIM_MODELS` | empty | Comma list of NVIDIA models you picked. |
| `TURINGOS_NIM_FALLBACKS` | empty | Comma list of NVIDIA backup models, tried in order. |
| `TURINGOS_NIM_IMAGE_MODEL` | `black-forest-labs/flux.1-dev` | Model for `turingos image`. |
| `TURINGOS_VOICE_BACKEND` | `whisper` | `whisper` or `wispr`. |
| `ANTHROPIC_API_KEY` | unset | Used by the desktop for chat answers and Clawd. `init` reports whether it is set. |
| `NVIDIA_API_KEY` | unset | NVIDIA NIM. |
| `OPENROUTER_API_KEY` | unset | OpenRouter. |
| `TURINGOS_BAZAAR_REMOTE_URL`, `TURINGOS_BAZAAR_CACHE`, `TURINGOS_BAZAAR_PUBKEY`, `TURINGOS_BAZAAR_OFFLINE_MODE` | see [The Bazaar](#the-bazaar) | Catalogue settings. |

API keys must match `^[A-Za-z0-9._~+/=-]{8,512}$` to be saved or sent. The check exists so a quote or newline in a key cannot be read by `curl` as more configuration.

The data directory is always `~/.turingos`. It is not configurable.

### Files under ~/.turingos

| Path | Contents |
|---|---|
| `config.env` | Settings and API keys (mode 600). |
| `state.json` | `active_sandbox`, `agent_pid`, `agent_task`, `game_mode`. The desktop reads it. |
| `pids/` | PID files (`claude.pid`). |
| `sandboxes/` | `<name>/` sandboxes and `<name>.meta` metadata. |
| `logs/` | `turingos-YYYYMMDD.log`, `agent-session-<time>.log`, `audit.log` (one line per agent, sandbox and Bazaar event), `diff-<time>.patch`. |
| `bazaar/<tool>/` | Installed tools, with an `.installed` marker holding the install time. |
| `bazaar_rules.json` | Per-directory disabled tools. |
| `opencode-<provider>.json` | OpenCode provider configs TuringOS generated. |
| `game_deprioritized.pids` | Original nice values, so `game off` can restore them. |
| `wispr/`, `models/` | Wispr Flow session and venv, Whisper model. |
| `.first-run-done`, `.apikey-configured` | Markers for the one-time welcome banner and API key prompt. |

Other locations: `~/.claude.json` (Claude Code's user config, where MCP servers are registered), `~/.cache/turingos/bazaar/index.json` (the cached catalogue), `~/.local/state/turingos/` (the kiosk's browser profile and the software-rendering flag).

### Environment variables for the desktop and trust stack

| Variable | Read by | Meaning |
|---|---|---|
| `TURINGOS_UI_PORT` | `turingos-kiosk`, `ui/run.sh` | Port of the bridge. Default 8080. |
| `TURINGOS_BROWSER` | `turingos-kiosk`, `ui/run.sh` | Browser to use. Default order: `brave-browser`, `chromium`, `chromium-browser`, `google-chrome`. |
| `TURINGOS_BROWSER_FLAGS` | `turingos-kiosk` | Extra flags for the browser, for CI or containers. |
| `TURINGOS_GFX` | `turingos-gfx-detect` | `gpu` or `sw` skips graphics detection. |
| `TURINGOS_GFX_TIER` | `turingos-gfx-detect` | `full`, `lite` or `minimal` skips the level choice. |
| `TURINGOS_UI_DIR` | `bridged-ws.py` | Directory to serve instead of `/usr/lib/turingos/ui/web`. |
| `TURINGOS_SESSION_DIR` | bridge, helper, `turingosd` | The drop-box for session sockets. Default `/run/turingos/session`. |
| `TURINGOS_BRIDGE_ALLOWLIST` | `bridged.py` | Extra hostnames for egress, comma-separated. |
| `TURINGOS_BRIDGE_ALLOW_UIDS` | `bridged-ws.py` | Extra uids the bridge accepts page connections from. |
| `TURINGOS_BRIDGE_PEER_CHECK` | `bridged-ws.py` | `0` turns off the peer-uid check (tests, development). |
| `TURINGOS_SHELL_ALLOW_UIDS` | `shell-helper.py` | Overrides which uids may run shell commands. |
| `TURINGOS_DESKTOP_ALLOW_UIDS` | `turingosd` | Overrides which uids may connect to the desktop socket. |
| `TURINGOS_MODEL_API_URL`, `TURINGOS_MODEL_API_KEY`, `TURINGOS_MODEL_API_MODEL` | `agentd-llm.py` | Model endpoint, key and name for the trust stack's model daemon. Defaults: `https://api.anthropic.com/v1/messages`, empty, `claude-sonnet-4-20250514`. |
| `TURINGOS_PROJECT_ROOTS` | `turingosd` | Colon-separated roots to search for git projects instead of `$HOME`. |
| `TURINGOS_WEATHER` | `turingosd` | `off`, or `lat,lon,City` for a fixed location. |
| `TURINGOS_BIN` | `turingosd` | Path of the `turingos` command it should run. |
| `TURINGOS_RESPAWN_MAX`, `_WINDOW`, `_DELAY`, `_TERMINAL` | `turingos-respawn` | Crash limit (5), window in seconds (60), delay in seconds (1) and terminal to open (`x-terminal-emulator`). |

`turingosd` reads `ANTHROPIC_API_KEY`, `GOOGLE_CLIENT_ID`, `GOOGLE_CLIENT_SECRET` and `TURINGOS_VOICE_BACKEND` from the environment first, then from `~/.turingos/config.env`.

`/etc/turingos/turingos.toml` and `/etc/turingos/policy.toml` are installed by hook 0480, but no code in this repository reads them. Editing them changes nothing today.

---

## The Bazaar

The Bazaar is the catalogue of MCP tool servers that `turingos bazaar` browses and installs. Installing a tool puts it under `~/.turingos/bazaar/<tool>/` and registers it in `~/.claude.json` under `.mcpServers`, so new Claude Code sessions pick it up.

### Where the catalogue comes from

The CLI resolves the catalogue in this order:

1. A cache file younger than 24 hours (by modification time). The default is `~/.cache/turingos/bazaar/index.json` (it honours `XDG_CACHE_HOME`).
2. The remote index, fetched with a 5 second timeout. The default URL is `https://uncoalesced.github.io/turingos-bazaar/v1/index.json`, with the signature at the same URL plus `.sig`.
3. A stale cache, if there is one. The UI and CLI label the result "[offline catalogue]".
4. The catalogue bundled with the install: `bazaar/registry.json` (on the ISO, `/usr/lib/turingos/bazaar/registry.json`). It currently lists five servers: `github-mcp`, `filesystem-mcp`, `postgres-mcp`, `brave-search-mcp` and `memory-mcp`. Each is an npm package pinned to a version and SHA-256.

If none of these works, the command fails with "Registry not found".

### Signature check

A remote index is accepted only if its detached Ed25519 signature verifies. The check is:

```
openssl pkeyutl -verify -pubin -inkey <pubkey> -rawin -in <index.json> -sigfile <index.json.sig>
```

The check fails closed. If the public key is missing, `openssl` is missing, the `.sig` cannot be fetched, or verification fails, the remote index is thrown away, nothing is cached, and the loader moves on to the stale cache and then the bundled catalogue. An index that verifies is cached and an `BAZAAR_INDEX_VERIFIED` line goes to `~/.turingos/logs/audit.log`. Fresh cache hits are not re-verified, since only verified indexes are written to the cache.

The CLI looks for the public key at `$TURINGOS_BAZAAR_PUBKEY`, else `/etc/turingos/trust/bazaar.pub`, else `trust/keys/bazaar.pub` in the checkout or install root. The key ships in the repository at `trust/keys/bazaar.pub`. `turingosd` applies the same rule, falling back to `/usr/lib/turingos/trust/keys/bazaar.pub`.

The bundled catalogue is not signature-checked: it is part of the install.

### Environment variables

| Variable | Default | Meaning |
|---|---|---|
| `TURINGOS_BAZAAR_REMOTE_URL` | `https://uncoalesced.github.io/turingos-bazaar/v1/index.json` | Remote index. The CLI also accepts `file://` URLs, for testing. |
| `TURINGOS_BAZAAR_PUBKEY` | `/etc/turingos/trust/bazaar.pub` | Ed25519 public key to verify against. |
| `TURINGOS_BAZAAR_CACHE` | `~/.cache/turingos/bazaar/index.json` | Cache file. |
| `TURINGOS_BAZAAR_OFFLINE_MODE` | `0` | `1` skips the remote fetch and the fresh-cache shortcut. |
| `TURINGOS_REGISTRY` | `<root>/bazaar/registry.json` | Bundled catalogue. |

### Installing

`bazaar install` checks the tool key (letters, digits, `.`, `_`, `-`, starting with a letter or digit), checks that required environment variables are set (and asks if they are not), then installs by runtime:

| Runtime | What happens |
|---|---|
| `npx` | Needs a pinned `version` and `sha256`, or refuses. Downloads the package tarball and compares its SHA-256, then writes a `run.sh` launcher that runs `npx -y <package>@<version>`. |
| `archive` | Needs a `sha256`, or refuses. Downloads, verifies, rejects archives with absolute or `..` paths, and unpacks into `~/.turingos/bazaar/<tool>/unpacked`. |
| `pip` | `pipx install --force <package>`. |
| `cargo` | `cargo install <package>`. |
| anything else | `git clone --depth=1` from `https://github.com/<repo>.git`, then `npm install`, a Python venv, or `cargo build --release` depending on what the repo has. |

Environment variable names from the catalogue are validated as plain identifiers before use. After a successful install of an `mcp` entry, the server is written to `~/.claude.json` as a stdio server, with the package argument pinned to the verified version. Installing needs the network even when the catalogue came from the offline copy.

### Per-project enable and disable

`bazaar disable <tool> [dir]` records the tool as disabled for a directory in two places: `~/.turingos/bazaar_rules.json` (keyed by absolute directory) and `<dir>/.claude/settings.json` under `disabledMcpServers`. `bazaar enable` removes it from both. `bazaar rules` and `bazaar toggle` read the same data.

A project can also commit `.turingos/bazaar.toml` with a line like `disabled = ["github-mcp"]`. If that file exists, `bazaar rules` reads it instead of the JSON file. The desktop service reads it from the project folder or its ancestors and writes it back when you change a rule in the UI, if the folder already has a `.turingos` directory.

---

## Trust model and security

`SECURITY.md` is the security policy and the way to report a vulnerability. `trust/README.md` describes the trust model's schemas and daemons. This section says what the code does today.

### The daemons

| Daemon | Socket in `/run/turingos` | What it does |
|---|---|---|
| `turingos-auditd` | `audit.sock` | Appends entries to `/var/lib/turingos/audit.db`, each carrying a SHA-256 hash of the entry before it. Runs as user `turingos-audit`. |
| `turingos-capd` | `cap.sock` | Issues, revokes and lists capability grants (`/var/lib/turingos/grants.db`). Grants expire and are checked against the clock. |
| `turingos-sandboxd` | `sandbox.sock` | Runs a tool under `bwrap --unshare-all --die-with-parent` with a 30 second timeout, after checking that the grant is active. |
| `turingos-toolreg` | `toolreg.sock` | Tool discovery from manifests. |
| `turingos-agentd-llm` | `agent-llm.sock` | Model calls to the Anthropic Messages API by default (see `TURINGOS_MODEL_API_*`). It makes the request itself rather than through `bridged`. |
| `turingos-agentd-plan` | `agent-plan.sock` | Plan state. A plan is created as `pending_approval`, runs only after approval, and only once. A plan not approved within 300 seconds is not run. Each tool step gets a 5 minute grant. |
| `turingos-memoryd` | `memory.sock` | Session and long-term memory (`~/.turingos/memory.db`). |
| `turingos-bridged` | `bridge.sock` | Network egress for the stack. |
| `turingos-bridged-ws` | TCP `127.0.0.1:8080` | The page's server and WebSocket relay. |
| `turingos-shell-helper` | `session/<uid>.sock` | Runs `/shell` commands as the logged-in user. A systemd user unit. |

The first nine are system units enabled by hook 0480. They run as the `turingos` system user (`auditd` as `turingos-audit`) and use systemd sandboxing options such as `NoNewPrivileges` and `ProtectSystem=strict`. Command-line tools exist for three of them: `turingos-audit` (`append`, `tail`), `turingos-cap` (`issue`, `revoke`, `list`) and `turingos-sandbox` (`run`). Schemas for grants, plans, audit entries, tool manifests and UI fragments are in `trust/schemas/`. Five reference tools (`file.read`, `file.write`, `file.list`, `shell.exec`, `browser.open`) have manifests in `trust/tools/`.

Audit writes from `bridged` and `agentd-plan` are best effort: if `auditd` is not reachable the write is skipped without an error. Do not rely on the audit log being complete.

### Local-access hardening (1.3)

The bridge drives the agent and can run shell commands, so 1.3 tightened who can talk to it:

- Every WebSocket route checks that the `Host` header is `localhost` or `127.0.0.1` and that `Origin` is exactly `http://<host>`. A page on another site, even one that DNS-rebinds to localhost, is refused with close code 1008.
- The process on the other end of the connection must belong to a logged-in user. The bridge finds its uid in the kernel's TCP table (`/proc/net/tcp`, `/proc/net/tcp6`) and compares it with the owners of the session sockets. If the peer cannot be identified, it is refused. With no session socket yet there is nothing to compare, and the check passes.
- A session socket only counts when its owner is the uid in its file name, because the drop-box is world-writable. Another user cannot plant a socket to capture what the page sends.
- `shell-helper` accepts only root and the `turingos` user, identified by `SO_PEERCRED`, and refuses a peer it cannot identify. It caps output at 64 KB and runs at most 60 seconds per command. `turingosd` applies the same uid rule to its desktop socket.
- Responses carry a Content-Security-Policy that allows no inline script or style and only same-origin connections, plus `X-Content-Type-Options: nosniff` and `frame-ancestors 'none'`.
- Egress (`bridged`): the allowlist is the server's own (`api.anthropic.com`, `api.openai.com`, `deb.debian.org`, `security.debian.org`, `brave-browser-apt-release.s3.brave.com`, plus `TURINGOS_BRIDGE_ALLOWLIST`). A caller cannot widen it. Only `http` and `https` are fetched, redirects are not followed, hosts that resolve to private, loopback, link-local or reserved addresses are refused, and responses over 5 MB are rejected. Fetched content is tagged `untrusted`.
- Plans: `reject_plan` exists, a rejected plan stays rejected, and approve and execute work only from the right state.

### Bazaar and installer checks

- The index signature is verified or the index is discarded (see [The Bazaar](#the-bazaar)).
- npm and archive installs require a pinned SHA-256 and compare it before anything runs. Tool keys, environment variable names and archive member paths are validated.
- Uninstall refuses any path outside `~/.turingos/bazaar`.
- `config.env` and `~/.claude.json` are written mode 600, and `~/.turingos` is mode 700.

### What is not protected

- The agent runs as you. See [What TuringOS is](#what-turingos-is).
- `bridged` and `agentd-plan` sockets are mode 0666 inside `/run/turingos`, so any local process can talk to them. The hardening above applies to the bridge and the shell helper.

---

## UI shell

The desktop is a web page in `ui/web` (HTML, CSS and classic scripts, no build step) shown in a Brave app window. The page draws; `turingosd` does the work. Opened from disk or a plain web server, the page runs on built-in sample data.

On the ISO, LightDM starts the `turingos-hyprland` session, which starts `turingosd` and then `turingos-kiosk` under `turingos-respawn`. The kiosk script waits for `http://127.0.0.1:<port>/health`, finds the screen size, picks the graphics path and starts the browser:

- Graphics: `turingos-gfx-detect` chooses `gpu` or `sw` (software) and a level of `full`, `lite` or `minimal`. A render node whose renderer is `llvmpipe`, `softpipe`, `swrast` or `swiftshader` counts as software. Software rendering gets `lite`, or `minimal` on 2 CPUs or fewer or on screens over 2,300,000 pixels. If the browser dies within 15 seconds on the GPU path, the rest of that boot uses software.
- Ozone: Wayland when `WAYLAND_DISPLAY` is set, X11 otherwise.
- The window has its own browser profile and no extensions. It is the desktop: under Hyprland and openbox, window rules make it frameless, full screen and below other windows.
- If the window dies, `turingos-respawn` restarts it. More than 5 crashes within 60 seconds opens a terminal instead.

Keys:

| Keys | Action |
|---|---|
| Super+Esc | Terminal (works in every session; `foot` under Hyprland, `x-terminal-emulator` under openbox) |
| Super+Space | Clear other windows away, bring the shell forward and open its command bar |
| Alt+Tab | Under Hyprland, show windows stashed by Super+Space |
| Super+1 to 5 | Switch workspace (Hyprland); Super+Shift+1 to 5 moves a window there |
| Ctrl/Cmd+K | Command palette |
| Ctrl/Cmd+J | Side panel |

The composer takes a task. Attach a project with `@` and it starts `turingos agent start <project> <task>`. With no project it is a plain question answered by one Claude call, using `ANTHROPIC_API_KEY`. If the model cannot be reached, the composer switches to shell mode and runs what you type as a command through `/shell` (`$ cmd` does it at any time).

### Running the UI from a checkout

```bash
sudo apt install -y cargo-web build-essential pkg-config cmake clang libclang-dev \
    libasound2-dev python3-fastapi python3-uvicorn git jq network-manager chromium
./turingos ui                       # first run compiles turingosd, which takes a few minutes
./ui/run.sh --gfx sw.lite           # lighter graphics
TURINGOS_UI_PORT=8081 ./turingos ui # if 8080 is taken
```

`ui/run.sh` refuses to run as root. It builds `daemon/` with cargo, starts `turingosd`, `shell-helper.py` and `bridged-ws.py` against a private temporary drop-box, opens the page in an app window with its own browser profile, and stops everything on Ctrl+C.

The plan sheet (`ui/web/js/plan-renderer.js`) connects to `ws://localhost:8080/plan` with the port written into the file. If you change `TURINGOS_UI_PORT`, the plan sheet will not connect.

Further reading: `ui-docs/SETUP.md` (setup and troubleshooting), `ui-docs/UI_SHELL.md` (design spec and event protocol), `ui/README.md`, and `protocol/v1/README.md` (the messages between the page and `turingosd`).

---

## Game mode

`turingos game on` finds processes named `claude`, `opencode`, `ollama`, `node`, `python3`, `cargo`, `rustc`, `make` or `ninja`, sets them to nice `TURINGOS_GAME_RENICE_LEVEL` (default 10) and puts them in the idle I/O class with `ionice -c 3`. It remembers each original nice value. Processes you cannot renice are skipped unless passwordless `sudo` works. Agents keep running, only slower.

`turingos game off` puts the nice values back and the I/O class to best effort level 4. Raising priority again can need root, so processes it could not restore are reported and keep their low priority until they restart.

`turingos game watch` polls every 5 seconds for `steam`, `lutris`, `heroic`, `wine`, `wine64-preloader`, `wineserver` or `gamescope`, and turns game mode on when one appears and off when none is left. Process names are matched exactly. It does not touch the kernel scheduler.

---

## Building the ISO

The ISO is built with `live-build` on Debian 13. `pkg/ISO_BUILD.md` has the full build notes; this is the short version.

### Steps

```bash
sudo apt install live-build rsync git
git clone https://github.com/uncoalesced/TuringOS && cd TuringOS
./debian-live/build-amd64.sh      # amd64
./arm/build.sh                    # arm64
```

Both scripts do the same things: stamp the architecture in `debian-live/.build/turingos-arch` and run `lb clean --purge` if an earlier build was for another one, run `debian-live/sync-scripts.sh`, run `lb config --distribution trixie --architectures <arch> --linux-flavours <arch> --image-name turingos --bootappend-live "boot=live components quiet splash persistence" --archive-areas "main contrib non-free-firmware"`, then `lb build`. The result is `debian-live/turingos-<arch>.hybrid.iso`, with `turningos-<arch>.hybrid.iso` and `live-image-<arch>.hybrid.iso` as symlinks to it. Expect 20 to 40 minutes on amd64, and internet access: crates, Brave, Homebrew, Claude Code and OpenCode are fetched during the build.

An arm64 build needs an arm64 Debian host, or an x86 host with `qemu-user-static` and `binfmt-support`, because the hooks run real binaries in the chroot. `arm/README.md` and `arm/test-qemu.sh` cover testing an arm64 image in QEMU (`QEMU_DISPLAY`, `DISK` and extra arguments after `--`).

Build from a checkout with LF line endings. `.gitattributes` enforces them.

### sync-scripts.sh

`debian-live/sync-scripts.sh` stages the repository into `debian-live/config/includes.chroot/` in its final layout: modules under `/usr/lib/turingos`, `/usr/bin/turingos`, `turingos-respawn`, the session scripts, the web UI at `/usr/lib/turingos/ui/web`, the daemon source under `/opt/turingosd-src`, the trust source under `/usr/src/turingos/trust`, the Bazaar public key at `/etc/turingos/trust/bazaar.pub`, the installer logo and slides, the plymouth theme, and the boot menu splashes. `tests/install_parity.sh` checks that every module `turingos` sources gets staged.

### Hooks

Chroot hooks run inside the image in order, then binary hooks run on the ISO tree.

| Hook | What it does |
|---|---|
| `0200-trim` | Removes office suites, printing, Bluetooth, unused GPU drivers. |
| `0300-locale-trim` | Strips locales, man pages and docs. |
| `0350-hyprland` | Installs Hyprland from trixie-backports. |
| `0400-install-turingos` | Checks the staged install, adds `gum` and the launcher entry. |
| `0420-install-brave` | Brave from its signed apt repo as the default browser, with the Claude extension installed by policy. |
| `0450-build-daemon` | Builds `turingosd` into `/usr/bin/turingosd`, then removes the toolchain and source. |
| `0460-plymouth-theme` | Makes `turingos` the plymouth theme and rebuilds the initrd. Fails the build if the script or label plugin is missing. |
| `0470-autologin-kiosk` | LightDM autologin into the `turingos-hyprland` session, ordered after live-config. |
| `0475-fallback` | Openbox key bindings (Super+Esc, Super+Space) and the rule that makes the shell window the desktop. |
| `0480-install-trust-model` | Trust daemons, the bridge, system users, systemd units, the shell-helper user unit. |
| `0490-install-homebrew` | Homebrew in `/home/linuxbrew/.linuxbrew`. |
| `0495-installer` | Calamares branding, `turingos-install`, and the job that moves autologin and Homebrew ownership to the installed account. |
| `0500-install-claude-cli` | Claude Code and OpenCode (pinned), plus the first-login API key prompt. |
| `0900-boot-timeout` (binary) | Boot menus start the default entry after 3 seconds. |
| `0910-persistence-menu` (binary) | Adds the "(persistence)" and "(safe mode)" entries to isolinux and GRUB menus. |
| `0920-boot-brand` (binary) | Replaces the stock splashes, recolours the menus, renames "Live system" to "TuringOS". |

### The ISO workflow

`.github/workflows/iso.yml` builds both ISOs on GitHub. It runs only when you start it by hand (`workflow_dispatch`), because a build takes about an hour and is not part of the regular CI gate. It builds amd64 on `ubuntu-latest` with `debian-live/build-amd64.sh` and arm64 on `ubuntu-24.04-arm` with `arm/build.sh`, each in a privileged `debian:trixie` container, so arm64 does not depend on `qemu-user`. Each job writes `turingos-<arch>.sha256` next to the ISO and uploads both as an artifact named `turingos-<arch>-iso`, kept 14 days. The workflow does not produce a combined `SHA256SUMS.txt`.

---

## Testing

### Shell tests

Each is a standalone bash script. CI runs every `tests/*.sh`.

| Script | What it covers |
|---|---|
| `tests/core.sh` | The CLI end to end in a temporary `HOME` with stub agents. Needs `jq` and `rsync`. |
| `tests/nim.sh` | NVIDIA model picker, fallback order and OpenCode config. |
| `tests/install_parity.sh` | Staged install matches what `turingos` sources. Needs `rsync` and `jq`. |
| `tests/fallback.sh` | Crash watchdog, Super+Esc terminal and safe-mode wiring. |
| `tests/persistence_menu.sh` | Boot timeout and the persistence and safe-mode entries, for amd64 and arm64 trees. |
| `tests/boot_brand.sh` | Hook 0920 on amd64 and arm64 trees, and the committed boot art. |
| `tests/bazaar_fallback.sh` | Remote index, 24 hour cache, offline fallback, SHA-256 and Ed25519 checks. |
| `tests/brave_hook.sh` | Static checks of the Brave hook. |
| `tests/session.sh` | Graphics path and level choice, browser flags. |
| `tests/kiosk_display.sh` | Screen-size probing without hangs, ozone choice, Hyprland shell rule and Super+Space, using stubbed `hyprctl` and `xdpyinfo`. |
| `tests/kiosk_contract.sh` | The shell window for real: Xvfb, openbox, the bridge, `turingosd` and Brave. Skips when tools are missing; `KIOSK_CONTRACT=require` makes a skip a failure. `KIOSK_ARTIFACTS=dir` keeps screenshots and logs. |
| `tests/benchmark.sh` | The release benchmark (below). |

### Release benchmark

```bash
./tests/benchmark.sh [--fast] [--json-out <path>]
```

It runs install parity (if `rsync` exists), fallback and watchdog, boot menus, the Bazaar suite, `cargo check` of the daemon (skipped without `cargo` or the ALSA development libraries), the border and token check, the design-language palette guard, the live-build persistence check and the Calamares autologin check. It writes `benchmark_report.json` at the repo root (or `--json-out`) and exits non-zero if anything failed. `--fast` is accepted and does nothing yet.

The palette guard fails the run if the old Claude palette names or hex values appear under `ui/web`, `debian-live/config` or `session`.

### Trust and bridge tests

```bash
python3 -m unittest -v trust/tests/test_bridge_shell.py trust/tests/test_shell_helper.py \
    trust/tests/test_bridge_desktop.py trust/tests/test_local_auth.py
```

These need `fastapi`, `httpx` and `uvicorn`. `trust/tests/test_e2e.py` is not part of that CI step.

### Rust daemon

In `daemon/`: `cargo fmt --check`, `cargo clippy --locked --all-targets -- -D warnings`, `cargo test --locked`, `cargo build --release --locked`. It needs the ALSA development package.

### CI

`.github/workflows/ci.yml` runs on pushes to `main`, pull requests, and weekly on Monday at 04:17 UTC (so a Brave update that breaks the shell window shows up). Jobs, each on amd64 and arm64 runners:

| Job | What it does |
|---|---|
| `shell` | `bash -n` and ShellCheck on scripts, hooks and session scripts, all `tests/*.sh`, then the four bridge and auth unit test files with a 300 second abort and a stack dump on hang. |
| `ui` | `node --check` on every script in `ui/web`. |
| `daemon` | In a `debian:trixie` container: format, clippy, tests, release build. Uploads the binary. |
| `kiosk` | Runs `tests/kiosk_contract.sh` against the real Brave with the built `turingosd`. |

A separate Codacy security scan workflow (`codacy.yml`) runs on pushes and pull requests to `main`, and weekly.

---

## Troubleshooting

| Symptom | Cause and fix |
|---|---|
| `sandbox diff` says no changes, or merge does nothing useful | `rsync` is missing. Diff and merge use it, and the diff hides rsync's errors. Install it: `sudo apt install rsync`. |
| Sandbox backend shows `copy` | The project is not a Btrfs subvolume, is not on Btrfs, or `btrfs` is not installed. This is the designed fallback. Large projects copy slowly. |
| "No sandbox found. Run: turingos sandbox create" | No active sandbox, or the path is not a direct child of `~/.turingos/sandboxes` with a `.meta` file. Use `turingos sandbox list`. |
| "Agent binary not found" | Install Claude Code (`turingos init` offers to, or run `pkg/turingos-install-claude-cli.sh`, which takes `--npm`, `--native` or `--api-key`), or set `TURINGOS_AGENT_BINARY`. For other providers, install OpenCode or set `TURINGOS_OPENCODE_BINARY`. |
| Agent fails right away on NVIDIA, Ollama or OpenRouter | Run `turingos model status`. It pings the endpoint and shows whether the key variable is set. |
| "Agent already running" | `turingos agent status`; stop it with `turingos agent stop`. A stale PID file is cleaned up by `status`. |
| Bazaar says "[offline catalogue]" | The remote fetch or signature check failed, so you are seeing the stale cache or the bundled list. Check the URL, `openssl` and the public key. `~/.turingos/logs/turingos-*.log` says which. |
| "Refusing to install ... no pinned version/sha256" | The catalogue entry is not pinned. This is intentional. |
| Black screen after login | Press Super+Esc for a terminal. Check `turingos-bridged-ws` (`systemctl status turingos-bridged-ws`) and that `curl http://127.0.0.1:8080/health` answers. |
| Page says "Reconnecting" | The bridge is down. systemd restarts it; the page returns when `/health` answers. |
| Slow or stuttering in a VM | Software rendering. Set `TURINGOS_GFX=sw` and `TURINGOS_GFX_TIER=lite` or `minimal`, or from a checkout `./ui/run.sh --gfx sw.lite`. |
| `./turingos ui` says "must not run as root" | Run it as your own user. |
| `No module named 'fastapi'` | `sudo apt install -y python3-fastapi python3-uvicorn`. |
| No Chromium-family browser found | Install Brave or chromium, or set `TURINGOS_BROWSER`. |
| Port 8080 is taken | From a checkout, `TURINGOS_UI_PORT=8081 ./turingos ui`. On the ISO the bridge unit uses the default port, and the plan sheet is written for 8080. |
| Plan sheet does not connect | It is hard-wired to port 8080. |
| Page rejected by the bridge (close code 1008) | The Host or Origin is not localhost, or the connecting process does not belong to a logged-in user. For development only, `TURINGOS_BRIDGE_PEER_CHECK=0`. |
| `/shell` says "no login session: shell helper is not running" | `turingos-shell-helper` (a user unit) is not running in your session, or `/run/turingos/session` is missing. |
| The AI is unreachable | The composer switches to shell mode. Super+Esc always opens a terminal. Boot the "(safe mode)" entry if the whole agent stack is broken. |
| Wi-Fi name or scan missing | Needs NetworkManager (`nmcli`). |
| Mic says "No microphone found" | Check `arecord -l` lists a capture device. |
| The ISO build fails after switching architecture | Run `sudo lb clean --purge` in `debian-live/`. The build scripts do this when they see the stamp change. |

Logs: `turingos logs`, `~/.turingos/logs/`, `journalctl -u turingos-bridged-ws`, and `journalctl --user -u turingosd`.

---

## Design language

The visual identity, version 1.0, is in `assets/design-language/`: `DESIGN_LANGUAGE.md` (principles, palette, roles, type, shape, motion and controls), `tokens.css`, `boards/*.html` (open them in a browser), `png/` for a quick look, and `source/` for the editable canvas. The web UI's `ui/web/css/tokens.css` is ported from it. Boot art, the plymouth theme and the Calamares slides are rendered by `debian-live/branding/make-boot-art.py`; the README banner (`assets/banner/turingos-banner.png`) comes from the same script.

The short version: black is the surface, orange (`#E85002`) marks the one live thing on screen, and nothing lands unreviewed. The old Claude palette is banned, and `tests/benchmark.sh` fails if it comes back.

The name is "TuringOS", one word.

---

Engineered by uncoalesced.
