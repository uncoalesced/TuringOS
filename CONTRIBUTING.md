# Contributing to TuringOS

TuringOS is a Linux execution layer for AI agents, and we'd like help from people who work on Linux, Bash, security, desktop UI, MCP, filesystems, or developer tooling.

You don't need to know the whole codebase. Pick one issue or one component and start there.

By taking part, you agree to follow our [Code of Conduct](CODE_OF_CONDUCT.md). To report a vulnerability, **do not open a public issue**. See [SECURITY.md](SECURITY.md).

---

## Pick a piece of TuringOS

| Directory | What it is | Good fit if you know |
|---|---|---|
| `agent/` | Agent runtime and task flow (Claude, or open models via OpenCode) | Bash, Claude Code, OpenCode, AI agents |
| `sandbox/` | Ephemeral Btrfs sandboxes, diff and merge | Btrfs, filesystems, Linux internals |
| `bazaar/` | Clawd Bazaar, the MCP tool registry | MCP servers, tooling |
| `core/` | Policy layer and system integration | Linux, security, Bash |
| `game/` | Game Mode (process and GPU handling) | Linux performance, GPU drivers |
| `monitor/` | Status HUD and monitoring | Bash, system metrics |
| `ui/`, `ui-docs/`, `daemon/`, `session/` | Desktop shell: the page (HTML/CSS/JS), the desktop service `turingosd` (Rust), the Brave shell window | JavaScript, Rust, UI design |
| `debian-live/`, `iso/`, `pkg/` | Live ISO build and packaging | Debian, live-build, packaging |
| Docs | README, guides, this file | Technical writing |

## Getting started

1. Fork the repo and clone your fork:
   ```bash
   git clone https://github.com/<you>/TuringOS.git
   cd TuringOS
   ```
2. Follow the quick start in [README.md](README.md) to set up your environment.
3. Read [WORKFLOW.md](WORKFLOW.md) for how the agent → sandbox → diff → approval flow works.

## Test environment

Run and test TuringOS scripts on a Debian install built from the official netinst ISO, not on your everyday machine or another distro.

- Architecture: we support **amd64** and **arm64** (`./arm/build.sh`). Test boot or packaging changes on both when you can; the shared debian-live config must keep building on each.
- ISO: use `debian-13.7.0-amd64-netinst.iso` — or `debian-13.7.0-arm64-netinst.iso` when working on arm64. Don't use other Debian versions or images. That way everyone tests against the same base, and results stay comparable.
- A VM (QEMU/KVM, VirtualBox, etc.) is fine and is the easiest option.

## Model providers

Claude is the default, but TuringOS also runs agents on open models through [OpenCode](https://opencode.ai). If your change touches `agent/`, `core/config.sh`, or `turingos model`, test it against Claude and at least one other provider.

| Provider | Setup | Notes |
|---|---|---|
| `claude` | `turingos model set claude` | Default. Runs the Claude CLI. |
| `nvidia` | `turingos model set nvidia` | NVIDIA NIM. Interactive picker for models, up to 3 backups, image model and `NVIDIA_API_KEY`. Model list lives in `agent/nim.sh`. |
| `ollama` | `turingos model set ollama "" llama3.2` | Local. Default endpoint `http://localhost:11434`. Needs a decent GPU. |
| `openrouter` | `turingos model set openrouter "" <model>` | Needs `OPENROUTER_API_KEY` in `~/.turingos/config.env` or your shell. |
| `custom` | `turingos model set custom <url> <model>` | Any OpenAI-compatible server (llama.cpp, LM Studio, vLLM). Needs a matching `custom` provider in `opencode.json`. |

Install the tools yourself, since the live ISO doesn't bundle them:

```bash
curl -fsSL https://ollama.com/install.sh | sh
curl -fsSL https://opencode.ai/install | bash
```

Run `turingos model status` to check the provider and ping its endpoint. In your PR, say which provider and model you tested with. Never commit API keys. TuringOS unsets `OPENROUTER_API_KEY` for any provider other than `openrouter`, and `NVIDIA_API_KEY` for any provider other than `nvidia`, so keep it that way if you touch the launch code. Adding an NVIDIA model means adding it to `NIM_CHAT_MODELS` in `agent/nim.sh`. Keep the list to general text, code and vision models.

## Finding work

- Issues labelled `good first issue` are small and self-contained.
- `help wanted` marks larger tasks we'd love help with.
- Subsystem labels (`sandbox`, `bazaar`, `ui`, ...) show which area an issue touches.
- Comment on an issue before you start so nobody duplicates work.
- Got a new idea? Open an issue and talk it through with us before writing a big PR.

## Making changes

- Branch from `main`: `feat/<short-name>`, `fix/<short-name>`, `docs/<short-name>`.
- Use [Conventional Commits](https://www.conventionalcommits.org/) with a scope, matching the existing history:
  ```
  feat(sandbox): add backend detection
  fix(game): handle missing GPU vendor
  docs(debian-live): clarify ISO build steps
  ```
- Keep one logical change per commit, and keep PRs focused.
- Bash scripts: start with `set -euo pipefail`, quote your variables, and make sure `shellcheck` passes with no warnings.
- Update the docs whenever you change behaviour.

## Testing and approval (required before merging into `main`)

**Test your change yourself and show us the results. We won't approve a PR that has no test evidence.**

1. Test on Debian from `debian-13.7.0-amd64-netinst.iso` — or the arm64 netinst / `arm/` VM for arm64 changes (see [Test environment](#test-environment)). Actually run your change; reading the code doesn't count.
2. Put the post-test evidence in the PR description:
   - Scripts / CLI (`turingos`, `agent/`, `core/`, `monitor/`): the commands you ran and their output.
   - Sandbox / agent changes: the sandbox diff output and the result of the merge or discard.
   - UI / desktop / Game Mode: screenshots or a short screen recording.
   - ISO / packaging (`debian-live/`, `iso/`, `pkg/`): build log excerpt plus a screenshot of it booting in a VM.
   - Docs: a rendered preview or a screenshot of the changed section.
3. Say what you tested on: distro, kernel, filesystem, GPU if it matters, and the model provider for agent changes.
4. A maintainer reviews your evidence and code, and may ask you to re-test.
5. Your PR is merged into `main` only after a maintainer approves it.

## PR checklist

- [ ] Tested on Debian from `debian-13.7.0-amd64-netinst.iso` (arm64 netinst / `arm/` for arm64 changes)
- [ ] Post-test evidence attached (output, screenshots, or recording)
- [ ] Test environment described
- [ ] Commits follow Conventional Commits
- [ ] `shellcheck` clean with no warnings (CI runs it on every shell file and hook, plus `bash tests/*.sh`)
- [ ] For `daemon/` changes: `cargo fmt --check`, `cargo clippy --all-targets -- -D warnings` and `cargo test` pass. CI builds it on `debian:trixie` with Debian's rustc-web (currently 1.96, floor `rust-version` 1.88), the same toolchain the ISO uses, so keep dependencies within `rust-version`
- [ ] Model provider and model named (for agent changes)
- [ ] Docs updated if behaviour changed
- [ ] Linked the related issue (`Closes #123`)

## License

By contributing, you agree that your contributions are licensed under the project's [MIT License](LICENSE).
