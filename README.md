<p align="center"><img src="assets/banner/turingos-banner.png" alt="TuringOS" width="100%"></p>

# TuringOS

TuringOS is a Debian-based operating system for running Claude Code agents. Each agent works in a sandboxed copy of your project, and nothing reaches the real thing until you have read the diff and approved the merge. The image boots into a desktop shell, and it includes a signed MCP tool catalogue (the Bazaar) and a Game Mode that keeps agents from competing with your games.

**Version 1.3-stable.** [Download the ISO](https://github.com/uncoalesced/TuringOS/releases/latest) · [Documentation](DOCUMENTATION.md) · [Changelog](CHANGELOG.md) · [All releases](https://github.com/uncoalesced/TuringOS/releases)

---

## What it is

TuringOS puts a policy layer between Claude Code and your files. Every agent task runs in a throwaway snapshot of the project, and you decide what comes back.

```
You
 ↓
Intent (a task in plain language)
 ↓
Claude agent
 ↓
TuringOS policy layer
 ↓
Ephemeral sandbox (Btrfs snapshot, or an rsync copy)
 ↓
Diff + human approval
 ↓
Merge
```

It ships as a bootable Debian 13 live ISO for amd64 and arm64, with the desktop shell and all the tooling already installed.

### Download

Get the images from the [latest release](https://github.com/uncoalesced/TuringOS/releases/latest).

| Image | Size | SHA-256 |
|---|---|---|
| `turingos-amd64.hybrid.iso` | 1.89 GB (1,886,568,448 bytes) | `0f7b89fa97edcb89044d50078b26a23dd61451f59833bf9151443fb01c81c400` |
| `turingos-arm64.hybrid.iso` | 1.90 GB (1901096960 bytes) | `378659bf109bb2f3331fd9b82841c68c4bfdfde2c46345dcc87766d09cfa1615` |

Check the file you downloaded against the table before you boot it:

```bash
sha256sum turingos-amd64.hybrid.iso
```

Boot it in a VM (QEMU or VMware, with 4 GB of RAM or more) or write it to a USB stick. It logs in by itself and opens the TuringOS shell fullscreen. Brave is the default browser and the Claude extension is installed by policy, so `claude` then `/login`, the [Anthropic Console](https://console.anthropic.com) and Google sign-in all open in it. Homebrew is set up too: `brew install <formula>`.

The boot menu has the normal entry, a persistence entry and a safe mode entry. Safe mode starts no agent and no TuringOS UI, only a plain desktop and a terminal, for when something in the agent stack is broken.

A live session keeps nothing by default: a reboot forgets logins, keys and installs. You have two ways to keep them:

- **Install to disk.** Click **Install** in the dock (or press Ctrl+K and pick "Install TuringOS"). The Calamares installer partitions the disk, creates your account (which logs in automatically, like the live session) and installs GRUB for BIOS or UEFI. It works offline. A disk of 20 GB or more is a comfortable size.
- **Persistence on a USB stick.** Run `pkg/make-persistence.sh` once to add a partition labelled `persistence` (see [Persistence](#persistence)).

Debug login on the live image: `user` / `live`.

### Why it exists

We want an operating system built around working with Claude. You boot into the UI, the agent sandbox is part of the system and not an app you open, and a shake of the cursor opens a quick chat with Clawd, the pixel mascot. A hardware maker could put this on a device meant for Claude and ship it.

It also works without a cloud connection. If the machine has a decent GPU, point TuringOS at a local model and keep going (see [Models](#models)).

### Known issues

- BIOS installs and Secure Boot have not been tested.
- Raspberry Pi bootloaders and BIOS on arm64 have not been tested.
- The microphone check cannot tell "no microphone" from silence, because PulseAudio always offers a capture device. Silent recordings are dropped, not transcribed.
- OpenCode is the biggest single item in the image, about 730 MB unpacked.

The full list, with what was fixed, is in [`debian-live/KNOWN_ISSUES.md`](debian-live/KNOWN_ISSUES.md). TuringOS is still a work in progress, so please file what breaks.

---

## Preview

<video src="assets/turingos-v1.2-demo.mp4" controls width="720">
  Your browser doesn't support inline video. <a href="assets/turingos-v1.2-demo.mp4">Download the clip</a> instead.
</video>

*A walkthrough of the v1.2 desktop UI. The look has changed since this was recorded.*

---

## Features

### Agent sandboxing

`turingos agent start` snapshots your project into `~/.turingos/sandboxes/`, writes the task prompt into it and runs the agent there. On Btrfs the snapshot is instant and copy-on-write; on any other filesystem TuringOS falls back to an rsync copy (set `TURINGOS_SANDBOX_BACKEND=copy` to force it). When the agent finishes, `turingos sandbox diff` shows what changed, and you merge it or roll it back. A merge never touches your project's `.git`.

The sandbox protects your project's files. It does not confine the agent process: the agent runs as your user, with Claude Code's permission prompts switched off because the sandbox copy is the thing you review. Read the diff before you merge.

### Clawd Bazaar

The Bazaar is a catalogue of MCP tools. `turingos bazaar` opens a browser for it, and `turingos bazaar install <tool>` installs a tool and registers it with Claude Code in `~/.claude.json`. The catalogue that ships with the image lists GitHub, Filesystem, Postgres, Brave Search and Memory.

It is built so a tampered catalogue is rejected:

- The online index (`https://uncoalesced.github.io/turingos-bazaar/v1/index.json`) must come with a detached Ed25519 signature that verifies against the public key in `trust/keys/bazaar.pub`. If the signature is missing or invalid, or the key or `openssl` is absent, TuringOS rejects the index.
- Each tool is pinned to a version and a SHA-256. The installer refuses an entry with no pin and aborts if the downloaded package does not match.
- A good index is cached for 24 hours. With no network, TuringOS uses the stale cache, then the bundled `bazaar/registry.json`, and labels the screen "[offline catalogue]".
- Tools can be switched off per project: `turingos bazaar disable <tool> [dir]` records the tool in `disabledMcpServers` in that directory's `.claude/settings.json`.

### Game Mode

`turingos game on` lowers the CPU priority (`renice`) and IO priority (`ionice`) of agent and build processes such as `claude`, `opencode`, `ollama`, `node`, `cargo` and `make`. The agent keeps working in the background, and a desktop notification tells you when its task finishes. `turingos game watch` turns Game Mode on by itself when it sees Steam, Lutris, Heroic, Wine or gamescope start. `turingos game off` puts the original priorities back.

### Desktop shell

The desktop is a web page in a frameless Brave app window. The page is served by `turingos-bridged-ws` on `127.0.0.1:8080`, and a small Rust service, `turingosd`, supplies it with live state: agent and sandbox status, system stats, the dock, weather, Wi-Fi and voice. The default session is Hyprland. If the machine has no render node or Hyprland exits with an error, the session starts X with Openbox instead.

- **Command bar:** Ctrl+K inside the page, or Super+Space from anywhere.
- **Terminal:** Super+Esc opens one in the Hyprland and Openbox sessions.
- **Voice:** the mic button dictates into the composer with local Whisper (the base.en model, about 142 MB, downloads on first use) or with Wispr Flow through `turingos voice wispr-import` (unofficial, opt-in).
- **Clawd:** shake the cursor or click the mascot for a one-off question to Claude Haiku.

If the AI or the bridge fails, the machine stays usable: the composer falls back to a plain shell, and a crashed shell window is restarted. [`trust/README.md`](trust/README.md) has the full fallback table.

### Trust stack

Behind the shell sits a set of small daemons: an append-only, hash-chained audit log, scoped and expiring capability grants, a plan the user approves before anything runs, and tools launched inside bubblewrap. Their design and the schemas are in [`trust/README.md`](trust/README.md).

### Models

Claude is the default. You can also run agents on other models through [OpenCode](https://opencode.ai):

```bash
turingos model set nvidia                                # NVIDIA NIM: pick models, backups, API key
turingos model set ollama "" llama3.2                    # local Ollama (default http://localhost:11434)
turingos model set openrouter "" meta-llama/llama-3.3-70b-instruct   # needs OPENROUTER_API_KEY
turingos model set custom http://localhost:8080 my-model # any OpenAI-compatible server
turingos model set claude                                # back to Claude
turingos model status                                    # show provider, ping endpoint
```

With a non-Claude provider, `turingos agent start` runs `opencode run --model <provider>/<model>` inside the sandbox instead of `claude`. The ISO ships OpenCode. Ollama is not included because its GPU libraries are too big for the image:

```bash
curl -fsSL https://ollama.com/install.sh | sh
```

For `ollama` and `custom`, TuringOS writes the OpenCode provider config itself (`~/.turingos/opencode-<provider>.json`, pointed at `<endpoint>/v1`), so your `opencode.json` stays as it is. Put `OPENROUTER_API_KEY` in `~/.turingos/config.env` or your shell. Before launching an agent TuringOS unsets the API keys that belong to other providers, so `OPENROUTER_API_KEY` is only visible to OpenRouter runs.

#### NVIDIA NIM

`turingos model set nvidia` (also offered by `turingos init`) sets up [NVIDIA's hosted models](https://build.nvidia.com/models):

1. Pick models from a curated list of text, code and vision models (Nemotron, Kimi, GLM, DeepSeek, gpt-oss, Gemma, Mistral, Codestral and others). You can also type any other model ID from build.nvidia.com.
2. Choose a default model and up to 3 backups. If the default fails, `turingos agent start` tries each backup in order and reports an error only when all of them have failed.
3. Choose the image model for `turingos image` (FLUX.1 dev or schnell).
4. Paste your API key (`nvapi-...`). It is saved as `NVIDIA_API_KEY` in `~/.turingos/config.env`, readable only by you.

```bash
turingos model use moonshotai/kimi-k3                    # switch the default model
turingos image "a lighthouse at dusk, oil painting"      # saves image-<time>.jpg
turingos image "app icon, flat style" icon.jpg
```

### System monitor

`turingos status` prints one HUD with GPU VRAM (through `nvidia-smi`), CPU load, RAM, the agent PID, the active sandbox and Game Mode state. `turingos monitor watch` refreshes it in place, and `turingos monitor spend` adds up token usage from the agent logs.

---

## Repo structure

```
TuringOS/
├── turingos                  # main CLI entrypoint
├── core/
│   ├── config.sh             # paths, state, PID files
│   ├── ui.sh                 # terminal UI primitives
│   ├── logging.sh            # leveled logging + audit trail
│   └── init.sh               # `turingos init`
├── agent/
│   ├── claude.sh             # start / stop / status / logs
│   ├── model.sh              # providers, `turingos model`, OpenCode configs
│   └── nim.sh                # NVIDIA NIM picker + `turingos image`
├── sandbox/
│   ├── btrfs.sh              # create / merge / rollback
│   └── diff.sh               # diff inspector + action menu
├── bazaar/
│   ├── registry.json         # bundled offline catalogue
│   ├── registry.sh           # fetch + verify index, browse / search / info
│   └── install.sh            # install + register with Claude Code
├── game/
│   └── gamemode.sh           # renice / ionice + auto-detect
├── monitor/
│   └── system.sh             # GPU / CPU / RAM / agent HUD
├── voice/                    # `turingos voice` + Wispr Flow helper
├── trust/                    # trust stack: daemons, schemas, tool manifests, Bazaar public key, tests
├── protocol/v1/              # desktop page <-> turingosd message protocol
├── ui/                       # desktop page (web/: css/, js/, fonts/)
├── ui-docs/                  # UI setup notes, shell spec, next features
├── daemon/                   # turingosd, the Rust desktop service
├── session/                  # Hyprland / kiosk session launchers, command bar, systemd unit
├── assets/                   # banner, logo, design language, demo video
├── pkg/                      # Claude CLI installer, persistence setup, first-run banner, ISO docs
├── debian-live/              # live-build config + hooks
│   ├── build-amd64.sh        # build the amd64 ISO
│   ├── sync-scripts.sh       # stage the install into includes.chroot
│   ├── branding/             # boot art and plymouth theme
│   └── config/
│       ├── hooks/normal/     # build-time hooks (trim, install, daemon build, session, boot menus)
│       └── package-lists/    # explicit apt package list
├── arm/                      # arm64 ISO build + QEMU test scripts
├── tests/                    # bash regression tests (run in CI)
├── test-evidence/            # results of the manual ISO test pass
├── .github/workflows/        # CI, Codacy scan, manual ISO build
├── WORKFLOW.md               # end-to-end usage guide
├── plan.md                   # architecture + build plan
├── release_notes_v1.3-beta.md
└── release_notes_v1.3-stable.md
```

---

## Quick start (CLI only)

Requires `bash` 4.2+, `git`, `jq` and `curl`. Recommended: `gum`, `fzf`, `rsync`, `btrfs-progs`.

```bash
git clone https://github.com/uncoalesced/TuringOS
cd TuringOS
chmod +x turingos
./turingos init
```

`turingos init` creates `~/.turingos`, checks your dependencies, offers to install Claude Code and offers to set a model provider. If `ANTHROPIC_API_KEY` is not set, it tells you how to save one:

```bash
bash pkg/turingos-install-claude-cli.sh --api-key
```

Then start an agent:

```bash
./turingos agent start /path/to/project "Refactor auth module and run tests"
```

When the agent finishes:

```bash
./turingos sandbox diff
```

Choose merge, rollback, view the full patch or save it to a file. [`WORKFLOW.md`](WORKFLOW.md) walks through the whole flow.

---

## Build the ISO

You need a Debian 13 (trixie) machine. The arm64 build has its own notes in [`arm/README.md`](arm/README.md).

```bash
sudo apt install live-build rsync git

git clone https://github.com/uncoalesced/TuringOS
cd TuringOS

./debian-live/build-amd64.sh     # amd64
./arm/build.sh                   # arm64, on an arm64 host (or with qemu-user-static)
```

Run these as your normal user: they call `sudo` themselves. Each script stages the repo with `debian-live/sync-scripts.sh`, runs `lb config` and `lb build`, and clears a previous build for the other architecture first. A build takes 20 to 40 minutes and needs internet, because the hooks fetch Rust crates, Brave, Homebrew, Claude Code and OpenCode.

The ISO lands in `debian-live/` as `turingos-amd64.hybrid.iso` or `turingos-arm64.hybrid.iso`, next to `live-image-<arch>.hybrid.iso` links to the same file. Boot it in a VM or write it to USB:

```bash
sudo dd if=debian-live/turingos-amd64.hybrid.iso of=/dev/sdX bs=4M status=progress
```

The **ISO** workflow in `.github/workflows/iso.yml` builds both architectures on native GitHub runners. It is started by hand, because a build takes about an hour.

On first boot the shell opens fullscreen. The first terminal you open shows the welcome banner and asks once for an Anthropic API key. You can skip it and use `claude` then `/login`, or run `turingos init` later.

### Persistence

Prepare a USB stick once, from any Linux machine:

```bash
sudo ./pkg/make-persistence.sh /dev/sdX
```

The script adds an ext4 partition labelled `persistence` in the disk's free space, with a `persistence.conf` of `/ union`. The normal and persistence boot entries both pass the `persistence` option, so files you change, including `~/.turingos` and your API key, survive reboots. Without the partition the session stays in RAM.

Full build instructions: [`pkg/ISO_BUILD.md`](pkg/ISO_BUILD.md)

---

## CLI reference

```
turingos agent start [project] [task]   Start the agent in a sandbox
turingos agent stop                     Stop the running agent
turingos agent status                   Show agent state
turingos agent logs                     Tail agent output

turingos sandbox create [project] [label]   Create a sandbox
turingos sandbox diff [sandbox]         Review what the agent changed
turingos sandbox merge [sandbox]        Apply changes to the original project
turingos sandbox rollback [sandbox]     Discard the sandbox
turingos sandbox list                   List all sandboxes
turingos sandbox status                 Show the active sandbox

turingos bazaar                         Browse MCP tools (fzf UI)
turingos bazaar search <query>          Search the catalogue
turingos bazaar info <tool>             Show tool details
turingos bazaar install <tool>          Install + register with Claude Code
turingos bazaar uninstall <tool>        Remove the tool and its MCP entry
turingos bazaar installed               List installed tools
turingos bazaar disable|enable <tool> [dir]   Switch a tool off or on for a directory
turingos bazaar rules [dir]             Show disabled tools for a directory
turingos bazaar toggle [dir]            Interactive toggle for a directory

turingos game on                        Deprioritize agents for gaming
turingos game off                       Restore priorities
turingos game status                    Show Game Mode state
turingos game watch                     Auto-detect game launches

turingos status                         System + agent HUD
turingos monitor watch                  Live refreshing dashboard
turingos monitor spend                  API token usage + cost estimate

turingos model status                   Show model provider + ping endpoint
turingos model set <provider> [endpoint] [model]
                                        claude | nvidia | ollama | openrouter | custom
turingos model use <model>              Change the default model
turingos image "<prompt>" [out.jpg]     Generate an image with NVIDIA FLUX

turingos voice status                   Show the speech-to-text backend
turingos voice backend whisper|wispr    Pick local Whisper or Wispr Flow
turingos voice wispr-import <session.json> [config.json]
                                        Use a Wispr Flow session (unofficial)

turingos init                           First-time setup + dependency check
turingos dashboard                      Interactive menu
turingos ui                             Open the desktop UI
turingos logs [N]                       Last N lines of the TuringOS log
turingos version                        Print the version
turingos help                           Full command list
```

---

## ISO hook execution order

| Hook | What it does |
|---|---|
| `0200-trim` | Purges office suites, printing, Bluetooth and unused GPU drivers |
| `0300-locale-trim` | Strips locales, man pages and docs |
| `0350-hyprland` | Hyprland, XWayland and the desktop portal from trixie-backports |
| `0400-install-turingos` | Checks the staged install, adds gum and the launcher entry |
| `0420-install-brave` | Brave from its signed apt repo as the default browser (`xdg-open`, `x-www-browser`, `$BROWSER`), Claude extension installed and pinned by policy |
| `0450-build-daemon` | Builds the desktop service (`turingosd`) against the image's libraries, then removes the toolchain |
| `0460-plymouth-theme` | Sets the TuringOS boot splash |
| `0470-autologin-kiosk` | lightdm autologin into the `turingos-hyprland` session, with the X + Openbox fallback, ordered after live-config |
| `0475-fallback` | Openbox key bindings (Super+Esc, Super+Space) and the rule that makes the shell window the desktop |
| `0480-install-trust-model` | The trust daemons, the bridge that serves the UI, and their systemd units |
| `0490-install-homebrew` | Homebrew in `/home/linuxbrew/.linuxbrew`, owned by the live user, on `PATH` |
| `0495-installer` | Calamares installer (TuringOS branding, `turingos-install` launcher, offline GRUB, autologin and Homebrew handed to the new account) |
| `0500-install-claude-cli` | Installs Claude Code (native installer, npm fallback) and OpenCode |
| `0900-boot-timeout` (binary) | Boot menus default to the live entry after 3 seconds (isolinux + GRUB) |
| `0910-persistence-menu` (binary) | Adds the "(persistence)" and "(safe mode)" boot entries (isolinux + GRUB) |
| `0920-boot-brand` (binary) | TuringOS boot art and menu colors, and the "TuringOS" entry names |

---

## Requirements

**Runtime (CLI)**

| Dependency | Required | Purpose |
|---|---|---|
| `bash` 4.2+ | Yes | Shell runtime |
| `git` | Yes | Sandbox diff and merge |
| `jq` | Yes | State, MCP config, registry |
| `curl` | Yes | Model endpoints, installers, Bazaar index |
| `claude` CLI | Yes | Agent execution |
| `rsync` | Yes | Copy backend, diff and merge |
| `btrfs-progs` | For Btrfs snapshots | Copy-on-write sandboxes |
| `openssl` | For the Bazaar | Verifies the index signature |
| `node` / `npm` | For npx-based Bazaar tools | Run the MCP servers |
| `gum` | Recommended | Interactive UI |
| `fzf` | Recommended | Fuzzy search |
| `libnotify` | Optional | Desktop notifications |

**Build (ISO)**

- Debian 13 (trixie) host
- `live-build`, `rsync`, `git`
- Internet access during the build (Rust crates, Brave, Homebrew, Claude Code, OpenCode)

---

## Contributing and security

See [CONTRIBUTING.md](CONTRIBUTING.md) to get involved and [SECURITY.md](SECURITY.md) to report a vulnerability. Everyone taking part follows the [Code of Conduct](CODE_OF_CONDUCT.md).

## License

MIT. See [LICENSE](LICENSE).
