# TuringOS

An agentic execution layer built on Debian. It runs Claude Code agents in safe sandboxes and comes with a live desktop UI, an MCP tool registry, and Game Mode.

---

## What it is

TuringOS wraps Claude Code in a policy layer between the agent and your filesystem. Every agent task runs inside an ephemeral Btrfs snapshot, and nothing touches your real project until you review a diff and approve the merge.

```
You
 ↓
Intent (natural language task)
 ↓
Claude Agent
 ↓
TuringOS Policy Layer
 ↓
Ephemeral Btrfs Sandbox
 ↓
Filesystem
 ↓
Diff + Human Approval
 ↓
Merge
```

We ship it as a bootable Debian live ISO with the UI and all tooling pre-installed.

### Why it exists

TuringOS is built for AI-first consumer hardware: a laptop, tablet, or phone whose whole job is working with Claude. You boot straight into Claude. The agent sandbox is the environment, not an app you open, and help is always one cursor shake away. We want a distro that a hardware maker could put on a Claude-dedicated device and ship.

It also runs on hardware without a cloud connection. If the device has a decent GPU, you can point TuringOS at a local model and keep working (see [Models](#models)).

---

## Preview

<video src="assets/turingos-ui-v1-demo.mp4" controls width="720">
  Your browser doesn't support inline video. <a href="assets/turingos-ui-v1-demo.mp4">download the clip</a> instead.
</video>

*Early walkthrough of the v1 desktop UI.*

---

## Features

### Btrfs agent sandboxing

The agent works in an instant copy-on-write snapshot of your project, isolated from the original. You see every change before anything becomes permanent, and one keystroke merges or rolls back.

### Clawd Bazaar

A terminal registry of MCP tools. You can browse tools, install them, and wire them into Claude Desktop's config with one command. It ships with GitHub, Postgres, Filesystem, Brave Search, and Memory servers.

### Game Mode

When you launch a game, TuringOS drops agent and build processes to low priority. Agents keep working in the background, and you get a notification when the task finishes.

### Live desktop UI

An Electron desktop shell that shows agent state, sandbox status, system stats, and MCP connections in real time. It launches fullscreen on boot.

### Models

Claude is the default. You can also run agents on open models through [OpenCode](https://opencode.ai):

```bash
turingos model set nvidia                                # NVIDIA NIM: pick models, backups, API key
turingos model set ollama "" llama3.2                    # local Ollama (default http://localhost:11434)
turingos model set openrouter "" meta-llama/llama-3.3-70b-instruct   # needs OPENROUTER_API_KEY
turingos model set custom http://localhost:8080 my-model # any OpenAI-compatible server
turingos model set claude                                # back to Claude
turingos model status                                    # show provider, ping endpoint
```

For a non-Claude provider, `turingos agent start` runs `opencode run --model <provider>/<model>` inside the sandbox instead of `claude`. Install the tools yourself first, since the live ISO doesn't bundle them (Ollama's GPU libraries are too big for it):

```bash
curl -fsSL https://ollama.com/install.sh | sh
curl -fsSL https://opencode.ai/install | bash
```

The `custom` provider needs a matching `custom` provider entry in OpenCode's `opencode.json`. Put `OPENROUTER_API_KEY` in `~/.turingos/config.env` or your shell. TuringOS unsets it for every other provider before launching OpenCode, and `model status` only sends it to OpenRouter.

#### NVIDIA NIM

`turingos model set nvidia` (also offered during `turingos init`) sets up [NVIDIA's hosted models](https://build.nvidia.com/models):

1. Pick the models you want from a curated list of text, code and vision models (Nemotron, Kimi, GLM, DeepSeek, gpt-oss, Gemma, Mistral, Codestral, Llama Vision and more). You can also type any other model ID from build.nvidia.com.
2. Choose a default model and up to 3 backups. If the default fails, `turingos agent start` tries each backup in order and only reports an error once all of them have failed.
3. Choose the image model for `turingos image` (FLUX.1 dev or schnell).
4. Paste your API key (`nvapi-...`, free at build.nvidia.com). It's saved as `NVIDIA_API_KEY` in `~/.turingos/config.env`, readable only by you.

```bash
turingos model use moonshotai/kimi-k3                    # switch the default model
turingos image "a lighthouse at dusk, oil painting"      # saves image-<time>.jpg
turingos image "app icon, flat style" icon.jpg
```

TuringOS points OpenCode at your picked models with its own config file (`~/.turingos/opencode-nvidia.json`), so your `opencode.json` stays untouched. `NVIDIA_API_KEY` is unset for every other provider.

### System monitor

One HUD for GPU VRAM, CPU load, RAM, the active agent PID, the sandbox name, and API token spend.

---

## Repo structure

```
turingos/
├── turingos                  # main CLI entrypoint
├── core/
│   ├── config.sh             # paths, state, PID files
│   ├── ui.sh                 # terminal UI primitives
│   └── logging.sh            # leveled logging + audit trail
├── agent/
│   └── claude.sh             # start / stop / status / logs
├── sandbox/
│   ├── btrfs.sh              # create / merge / rollback
│   └── diff.sh               # diff inspector + action menu
├── bazaar/
│   ├── registry.json         # MCP tool registry
│   ├── registry.sh           # browse / search / info
│   └── install.sh            # install + inject MCP config
├── game/
│   └── gamemode.sh           # renice / ionice + auto-detect
├── monitor/
│   └── system.sh             # GPU / CPU / RAM / agent HUD
├── ui/                       # Electron desktop shell
├── assets/                   # branding, palette, UI preview media
├── pkg/                      # Arch/CachyOS PKGBUILD + helpers
├── debian-live/              # Debian live-build config + hooks
│   ├── sync-scripts.sh       # copy repo into includes.chroot
│   └── config/
│       ├── hooks/normal/     # build-time hooks (trim, install, Electron)
│       └── package-lists/    # explicit apt package list
├── WORKFLOW.md               # end-to-end usage guide
└── plan.md                   # architecture + build plan
```

---

## Quick start (CLI only)

Requires: `git`, `jq`. Optional but recommended: `gum`, `fzf`.

```bash
git clone https://github.com/uncoalesced/turingos
cd turingos
chmod +x turingos
./turingos init
```

Set your API key when prompted, then:

```bash
./turingos agent start /path/to/project "Refactor auth module and run tests"
```

When the agent finishes:

```bash
./turingos sandbox diff
```

Choose merge, rollback, or view the full patch.

---

## Build the ISO (Debian live)

Requires a Debian Trixie machine with `live-build` installed.

```bash
# Install live-build
sudo apt install live-build

# Clone the repo
git clone https://github.com/uncoalesced/turingos
cd turingos/debian-live

# Copy scripts + UI into the image
./sync-scripts.sh

# Build (takes 20–40 min, needs internet)
sudo lb clean --purge
sudo lb build
```

The ISO lands in `debian-live/`. Boot it in a VM or write it to USB with:

```bash
sudo dd if=live-image-amd64.hybrid.iso of=/dev/sdX bs=4M status=progress
```

On first boot the UI launches fullscreen. Open a terminal and run `turingos init` to configure your API key.

Full build instructions: [`debian-live/pkg/DEBIAN_BUILD.md`](debian-live/pkg/DEBIAN_BUILD.md)

---

## CLI reference

```
turingos agent start [project] [task]   Start Claude in a sandbox
turingos agent stop                     Stop the running agent
turingos agent status                   Show agent state
turingos agent logs                     Tail agent output

turingos sandbox create [project]       Create sandbox
turingos sandbox diff                   Review what the agent changed
turingos sandbox merge                  Apply changes to original project
turingos sandbox rollback               Discard sandbox

turingos bazaar                         Browse MCP tools (fzf UI)
turingos bazaar install <tool>          Install + wire into Claude Desktop
turingos bazaar installed               List installed tools

turingos game on                        Deprioritize agents for gaming
turingos game off                       Restore priorities
turingos game watch                     Auto-detect game launches

turingos status                         System + agent HUD
turingos monitor watch                  Live refreshing dashboard
turingos monitor spend                  API token usage + cost estimate

turingos model status                   Show model provider + ping endpoint
turingos model set <provider> [endpoint] [model]
                                        claude | nvidia | ollama | openrouter | custom
turingos model use <model>              Change the default model
turingos image "<prompt>" [out.jpg]     Generate an image with NVIDIA FLUX

turingos init                           First-time setup
turingos dashboard                      Interactive menu
turingos help                           Full command list
```

---

## ISO hook execution order

| Hook | What it does |
|---|---|
| `0200-trim` | Purges LibreOffice, CUPS, Bluetooth, unused GPU drivers (~1GB) |
| `0300-locale-trim` | Strips locale data, man pages, docs (~200MB) |
| `0400-install-turingos` | Installs TuringOS CLI, gum, runtime deps |
| `0450-install-electron-deps` | Installs Electron system libraries |
| `0460-prebundle-electron` | Runs `npm install`, pre-caches Electron 44 |
| `0500-install-claude-cli` | Installs Claude Code CLI via native installer |

---

## Requirements

**Runtime (CLI)**

| Dependency | Required | Purpose |
|---|---|---|
| `bash` 4+ | Yes | Shell runtime |
| `git` | Yes | Sandbox diff/merge |
| `jq` | Yes | State, MCP config, registry |
| `btrfs-progs` | Yes (Btrfs) | CoW snapshots |
| `rsync` | Yes (non-Btrfs) | Copy sandbox fallback |
| `claude` CLI | Yes | Agent execution |
| `gum` | Recommended | Interactive UI |
| `fzf` | Recommended | Fuzzy search |
| `libnotify` | Optional | Desktop notifications |

**Build (ISO)**

- Debian Trixie host
- `live-build`
- Internet access during build (downloads Electron, Claude CLI)

---

## License

MIT. See [LICENSE](LICENSE).
