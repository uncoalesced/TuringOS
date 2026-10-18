# Tests to be done: results, 2026-10-03

ISO built on a Debian 13.7 VM installed from `debian-13.7.0-amd64-netinst.iso`,
booted in VMware Workstation 26. Screenshots are in `D:\TuringOS-VM\screenshots\`.
Fixes are in PR #13 (https://github.com/uncoalesced/TuringOS/pull/13).
Everything still open needs a real API key, account or session.

CI already covers: ShellCheck on every shell file and hook (chroot and
binary); `tests/core.sh`, `tests/nim.sh` and `tests/install_parity.sh`;
`node --check` on the UI scripts; and the Tauri fmt/clippy/tests/release build
on `debian:trixie` with rustc-web. `tests/core.sh` checks:
- status, including box alignment
- monitor spend
- bazaar: search, installed, uninstall traversal, MCP args
- config.env: quoting, mode 600, key validation
- `~/.turingos` mode 700
- game on/off
- sandbox create/diff/merge, plus tampered metadata
- model set ollama
- agent start with a stub claude

## ISO build and boot

- [x] **ISO builds**: passes after the fixes in PR #13 (0200 purged openbox, 0500 skipped the CLIs, firmware guard). 0450 builds with rustc-web 1.96 and its `ldd` check passes.
- [x] **Package list installs**: all 83 names install and are still present at boot (0200 now fails the build if a listed package disappears).
- [x] **ISO size**: ISO 1.40 GB, squashfs 1.29 GB, recorded in `pkg/ISO_SIZE_TRIM.md`. OpenCode (~730 MB) is the next thing to trim.
- [x] **Autologin**: no greeter; openbox + fullscreen UI about 15 s after power-on, BIOS and UEFI. The boot menu now times out after 3 s.
- [x] **UI in kiosk**: fills the screen, Ctrl+Q quits. On VMware it rendered blurred with no text until the DMA-BUF renderer was disabled (fixed); `LITE=1` software path also works.
- [x] **Composer starts the agent**: `@` lists `~/proj`, Enter starts it, corners show "Agentic · task" and "Sandbox active".
- [ ] **Links**: needs `gh auth` and a browser in the image (none yet, see NEXT_FEATURES).
- [x] **First terminal login**: welcome banner, then the key prompt once; key in `~/.turingos/config.env` mode 600, not in `.bashrc`; second login shows neither. (Fixed: the prompt ran before the banner, and a gum crash used to lose the key for good.)
- [x] **Installed run**: `/usr/bin/turingos` → `/usr/lib/turingos`; `model set` and `turingos image` run from there (image needs a real key).
- [x] **Claude Code + OpenCode present**: Claude Code 2.1.288, OpenCode 1.18.34.

## Voice input

- [x] **Whisper first use**: model downloads with progress in the hint, sha256 `a03779c8…` matches, speech played into a virtual mic lands in the composer ("Create a Hello World script in Python").
- [x] **Whisper offline**: transcribed correctly with the VM's NIC disconnected.
- [x] **No microphone**: PulseAudio always offers a capture device (a null source with no hardware), so "No microphone found" can't trigger; the mic records silence, which is no longer transcribed (Whisper used to type "you"). Logged in KNOWN_ISSUES.
- [ ] **Wispr import**: skipped as asked. (A fake session did install wisprflow-re 0.1.0 into the venv, switch the backend, and set modes 700/600.)
- [ ] **Wispr transcription**: skipped (needs a real session). With the fake session it fell back to Whisper and transcribed correctly.

## Agents and providers

- [ ] **Claude agent, real run**: needs a real Anthropic key. With a stub: flags `--dangerously-skip-permissions --verbose` present; `agent stop` kills claude and tee (process group).
- [x] **UI model choice**: the composer's model reaches `claude --model` (now Sonnet 5.5, `claude-sonnet-5-5`).
- [x] **Ollama**: `model set ollama http://<host>:11434 qwen2.5:0.5b`, the agent runs through OpenCode with `~/.turingos/opencode-ollama.json`.
- [x] **Custom endpoint**: same, `opencode-custom.json` points at `<endpoint>/v1`.
- [x] **Btrfs sandbox**: subvolume → snapshot, plain directory → copy fallback, rollback deletes the snapshot.
- [x] **Merge with deletions on a real project**: deleted file deleted, edit and new file merged, `.git` untouched, no `.turingos_*` files, metadata outside the sandbox.
- [x] **Bazaar → Claude Code**: memory-mcp and filesystem-mcp (with `$HOME`) in `~/.claude.json`, `claude mcp list` shows both Connected, uninstall removes the entry. (Fixed: jq read npx's `-y` as an option, so registration always failed.)
- [x] **Bazaar pipx path**: a pip-runtime tool (mcp-server-time) installs via pipx.
- [x] **Game mode restore**: nice 3 → 10 → 3 with sudo; without sudo, "1 process(es) keep low priority until they restart".

## UI backend (Tauri) on Linux

- [ ] **Google Calendar sign-in**: needs a Google account and a browser in the image.
- [ ] **Clawd and chat**: needs a real key. Without one: clear "needs an API key — set ANTHROPIC_API_KEY" message.
- [x] **Weather, Wi-Fi, CPU/memory**: weather by IP (Bengaluru), Wi-Fi icon, CPU/memory corner correct. (No battery in a VM.)
- [x] **Theme toggle**: works. (Fixed: WebKitGTK's view transition froze the page on a blank snapshot.)

## NVIDIA NIM (needs a real key from build.nvidia.com)

- [ ] **Setup with gum installed**: needs an interactive terminal; gum is now only used on a real sized tty.
- [x] **Setup without gum**: covered by `tests/nim.sh` in CI.
- [ ] **Status**: with a bogus key it says "Endpoint reachable" (the models list doesn't need auth), so this doesn't prove the key works.
- [ ] **Real agent run**, **every curated model**, **backup fallback for real**, **FLUX images**, **blocked prompt**: need a real key.
- [x] **All 4 fail**: bogus key, log ends with `ERROR: default and all backup NVIDIA models failed`.
- [ ] **Fallback side effect** (retry in the same sandbox): needs a decision.
- [x] **Key isolation / ps**: no `nvapi` in `ps` during an NVIDIA agent run.

## `turingos init`

- [x] **Fresh system**: brand-new user, no `~/.turingos`: deps, Claude Code found, key warning, dirs created (mode 700).
- [ ] **Provider step**: each choice up to the key prompt needs an interactive terminal; ollama/custom/nvidia configs verified via `model set`.
- [ ] **OpenRouter status**: needs a real key.
