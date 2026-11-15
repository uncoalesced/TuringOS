# Contributing to TuringOS

TuringOS runs Claude Code agents in sandboxed snapshots on a Debian-based live and installable system. We'd like help from people who know Linux, Bash, Rust, Python, security, desktop UI, MCP, filesystems or developer tooling.

You don't need to know the whole codebase. Pick one issue or one component and start there.

By taking part, you agree to follow our [Code of Conduct](CODE_OF_CONDUCT.md). To report a vulnerability, **do not open a public issue**. See [SECURITY.md](SECURITY.md).

---

## Pick a piece of TuringOS

| Directory | What it is | Good fit if you know |
|---|---|---|
| `agent/` | Agent runtime and task flow (Claude, or open models through OpenCode) | Bash, Claude Code, OpenCode |
| `sandbox/` | Btrfs and copy sandboxes, diff and merge | Btrfs, filesystems, rsync |
| `bazaar/` | Clawd Bazaar: the signed MCP tool catalogue and its installer | MCP servers, supply-chain security |
| `core/` | Paths, config, logging, `turingos init` | Bash, Linux |
| `game/` | Game Mode (process and IO priority) | Linux performance |
| `monitor/` | Status HUD and spend report | Bash, system metrics |
| `voice/` | Speech-to-text backends | Bash, Python, audio |
| `trust/`, `protocol/` | The trust daemons, the bridge, schemas, and the desktop protocol | Python, systemd, bubblewrap, security |
| `ui/`, `ui-docs/`, `daemon/`, `session/` | The desktop page (HTML, CSS, JS), `turingosd` (Rust), the Hyprland and Openbox session launchers | JavaScript, Rust, Hyprland, UI design |
| `debian-live/`, `arm/`, `pkg/` | Live ISO build for amd64 and arm64, hooks, boot branding, packaging | Debian, live-build, packaging |
| Docs | README, WORKFLOW, this file | Technical writing |

## Getting started

1. Fork the repo and clone your fork:
   ```bash
   git clone https://github.com/<you>/TuringOS.git
   cd TuringOS
   ```
2. Follow the quick start in [README.md](README.md) to set up your environment.
3. Read [WORKFLOW.md](WORKFLOW.md) for how the agent, sandbox, diff and approval flow works.
4. Read [DOCUMENTATION.md](DOCUMENTATION.md) for how the parts fit together.

## Test environment

Run and test TuringOS scripts on a Debian install built from the official netinst ISO, not on your everyday machine or another distro.

- We support **amd64** and **arm64** (`./arm/build.sh`). Test boot or packaging changes on both when you can. The shared `debian-live` config has to keep building on each.
- Use `debian-13.7.0-amd64-netinst.iso`, or `debian-13.7.0-arm64-netinst.iso` when you work on arm64. Don't use other Debian versions or images, so that everyone tests against the same base and results can be compared. The repo ignores an `iso/` directory, which is a good place to keep the download.
- A VM (QEMU/KVM, VMware) is fine and is the easiest option.

## Model providers

Claude is the default, but TuringOS also runs agents on other models through [OpenCode](https://opencode.ai). If your change touches `agent/`, `core/config.sh` or `turingos model`, test it against Claude and at least one other provider.

| Provider | Setup | Notes |
|---|---|---|
| `claude` | `turingos model set claude` | Default. Runs the Claude CLI. |
| `nvidia` | `turingos model set nvidia` | NVIDIA NIM. A picker for models, up to 3 backups, the image model and `NVIDIA_API_KEY`. The model list is `NIM_CHAT_MODELS` in `agent/nim.sh`. |
| `ollama` | `turingos model set ollama "" llama3.2` | Local. Default endpoint `http://localhost:11434`. Needs a decent GPU. |
| `openrouter` | `turingos model set openrouter "" <model>` | Needs `OPENROUTER_API_KEY` in `~/.turingos/config.env` or your shell. |
| `custom` | `turingos model set custom <url> <model>` | Any OpenAI-compatible server (llama.cpp, LM Studio, vLLM). TuringOS writes the OpenCode config for it. |

The ISO ships OpenCode but not Ollama. On a plain Debian test machine, install what you need:

```bash
curl -fsSL https://ollama.com/install.sh | sh
curl -fsSL https://opencode.ai/install | bash
```

Run `turingos model status` to check the provider and ping its endpoint. In your PR, say which provider and model you tested with.

Never commit API keys. Before launching an agent, TuringOS unsets the API keys that belong to other providers (`model::scrub_keys` in `agent/model.sh`), so `OPENROUTER_API_KEY` is only visible to OpenRouter runs and `NVIDIA_API_KEY` only to NVIDIA runs. Keep it that way if you touch the launch code.

To add an NVIDIA model, add it to `NIM_CHAT_MODELS` in `agent/nim.sh`. The list is for general text, code and vision models.

## Bazaar entries

`bazaar/registry.json` is the catalogue that ships on the image and is used offline. The signed online index is published from a separate repository, `turingos-bazaar`. The installer refuses an npm entry with no pinned `version` and `sha256`, and an archive entry with no `sha256`, so every new entry needs both. Don't loosen that, and don't weaken the signature check in `bazaar/registry.sh`: it fails closed on purpose.

## Finding work

- Issues labelled `good first issue` are small and self-contained.
- `help wanted` marks larger tasks we'd love help with.
- `bug`, `enhancement`, `documentation` and `accessibility` say what kind of change an issue is.
- Comment on an issue before you start so nobody duplicates work.
- Got a new idea? Open an issue and talk it through with us before you write a big PR.

## Making changes

- Branch from `main`: `feat/<short-name>`, `fix/<short-name>`, `docs/<short-name>`.
- Use [Conventional Commits](https://www.conventionalcommits.org/) with a scope, matching the existing history:
  ```
  feat(sandbox): add backend detection
  fix(game): handle missing GPU vendor
  docs(debian-live): clarify ISO build steps
  ```
- Keep one logical change per commit, and keep PRs focused.
- Bash scripts: start with `set -euo pipefail`, quote your variables, and make `shellcheck` pass with no warnings. The repo's `.shellcheckrc` applies.
- UI changes use the design tokens in `ui/web/css/tokens.css`. Don't hard-code colors in a component stylesheet. The reference for the tokens is `assets/design-language/`.
- Update the docs whenever you change behavior.

## Running the checks locally

CI runs the same things, so run them before you push:

```bash
# Shell: ShellCheck and the regression tests
# (the session scripts have no extension, so they are listed by hand)
{ git ls-files '*.sh' '*.hook.chroot' '*.hook.binary' turingos; \
  ls session/turingos-kiosk session/turingos-gfx-detect session/turingos-hyprland session/turingos-hyprland-autostart; } \
    | xargs shellcheck --shell=bash
shellcheck --shell=sh session/turingos-omni
for t in tests/*.sh; do bash "$t"; done

# UI scripts
for f in ui/web/js/*.js ui/web/boot.js; do node --check "$f"; done

# Trust daemons and bridge (needs: pip install fastapi httpx uvicorn)
python3 -m unittest -v trust/tests/test_bridge_shell.py trust/tests/test_shell_helper.py \
    trust/tests/test_bridge_desktop.py trust/tests/test_local_auth.py

# Desktop service
cd daemon
cargo fmt --check
cargo clippy --locked --all-targets -- -D warnings
cargo test --locked
```

CI also builds `daemon/` on `debian:trixie` with Debian's rustc-web (1.96 at the time of writing), the same toolchain the ISO uses. Keep dependencies within `rust-version` (1.88) in `daemon/Cargo.toml`. The CI kiosk job starts the real shell window under Brave on a virtual display (`tests/kiosk_contract.sh`). CI also runs every Monday, because a Brave update can break that window.

## Testing and approval (required before merging into `main`)

**Test your change yourself and show us the results. We won't approve a PR that has no test evidence.**

1. Test on Debian from `debian-13.7.0-amd64-netinst.iso`, or the arm64 netinst or `arm/` VM for arm64 changes (see [Test environment](#test-environment)). Run your change. Reading the code doesn't count.
2. Put the post-test evidence in the PR description:
   - Scripts and CLI (`turingos`, `agent/`, `core/`, `monitor/`): the commands you ran and their output.
   - Sandbox and agent changes: the sandbox diff output and the result of the merge or rollback.
   - UI, desktop and Game Mode: screenshots or a short screen recording.
   - Bazaar: the install, the signature check and the offline fallback, as they behave with your change.
   - ISO and packaging (`debian-live/`, `arm/`, `pkg/`): a build log excerpt and a screenshot of the image booting in a VM.
   - Docs: a rendered preview or a screenshot of the changed section.
3. Say what you tested on: distro, kernel, filesystem, GPU if it matters, and the model provider for agent changes.
4. A maintainer reviews your evidence and code, and may ask you to re-test.
5. Your PR is merged into `main` only after a maintainer approves it.

## PR checklist

- [ ] Tested on Debian from `debian-13.7.0-amd64-netinst.iso` (arm64 netinst or `arm/` for arm64 changes)
- [ ] Post-test evidence attached (output, screenshots or recording)
- [ ] Test environment described
- [ ] Commits follow Conventional Commits
- [ ] `shellcheck` is clean with no warnings, and `bash tests/*.sh` passes (CI runs both on every shell file and hook)
- [ ] For `trust/` changes: the bridge tests above pass
- [ ] For `daemon/` changes: `cargo fmt --check`, `cargo clippy --locked --all-targets -- -D warnings` and `cargo test --locked` pass
- [ ] Model provider and model named (for agent changes)
- [ ] Docs updated if behavior changed
- [ ] Linked the related issue (`Closes #123`)

## License

By contributing, you agree that your contributions are licensed under the project's [MIT License](LICENSE).
