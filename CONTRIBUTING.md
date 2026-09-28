# Contributing to TuringOS

TuringOS is building a Linux execution layer for AI agents. We're looking for people interested in Linux, Bash, security, desktop UI, MCP, filesystems and developer tooling.

You don't need to know the whole codebase. Pick an issue, build a component, and help shape the OS.

By participating you agree to follow our [Code of Conduct](CODE_OF_CONDUCT.md). To report a vulnerability, **do not open a public issue**. See [SECURITY.md](SECURITY.md).

---

## Pick a piece of TuringOS

| Directory | What it is | Good fit if you know |
|---|---|---|
| `agent/` | Claude agent runtime and task flow | Bash, Claude Code, AI agents |
| `sandbox/` | Ephemeral Btrfs sandboxes, diff and merge | Btrfs, filesystems, Linux internals |
| `bazaar/` | Clawd Bazaar, the MCP tool registry | MCP servers, tooling |
| `core/` | Policy layer and system integration | Linux, security, Bash |
| `game/` | Game Mode (process and GPU handling) | Linux performance, GPU drivers |
| `monitor/` | Status HUD and monitoring | Bash, system metrics |
| `ui/`, `ui-docs/` | Electron desktop shell | JavaScript, Electron, UI design |
| `debian-live/`, `iso/`, `pkg/` | Live ISO build and packaging | Debian, live-build, packaging |
| Docs | README, guides, this file | Technical writing |

## Getting started

1. Fork the repo and clone your fork:
   ```bash
   git clone https://github.com/<you>/TuringOS.git
   cd TuringOS
   ```
2. Follow the Quick Start in [README.md](README.md) to set up your environment.
3. Read [WORKFLOW.md](WORKFLOW.md) to see how the agent → sandbox → diff → approval flow works.

## Finding work

- Issues labelled `good first issue` are small and self-contained.
- `help wanted` marks larger tasks we'd love help with.
- Subsystem labels (`sandbox`, `bazaar`, `ui`, ...) show which area an issue touches.
- Comment on an issue before you start so nobody duplicates work.
- If you have a new idea, open an issue to discuss it before you write a big PR.

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

**You must test your change yourself and show us the results before we approve it.** A PR without test evidence will not be approved.

1. **Test locally.** Run your change for real, not only in theory.
2. **Show us the result after testing.** Put the evidence in the PR description:
   - **Scripts / CLI (`claudeos`, `agent/`, `core/`, `monitor/`):** the commands you ran and their output.
   - **Sandbox / agent changes:** the sandbox diff output and the result of the merge or discard.
   - **UI / desktop / Game Mode:** screenshots or a short screen recording.
   - **ISO / packaging (`debian-live/`, `iso/`, `pkg/`):** build log excerpt plus a screenshot of it booting in a VM.
   - **Docs:** a rendered preview or a screenshot of the changed section.
3. **Say what you tested on**, e.g. distro, kernel, filesystem, GPU if relevant.
4. **Review.** A maintainer checks your evidence and code, and may ask you to re-test.
5. **Merge.** Your PR is merged into `main` only after a maintainer approves it.

## PR checklist

- [ ] Tested locally
- [ ] Post-test evidence attached (output, screenshots, or recording)
- [ ] Test environment described
- [ ] Commits follow Conventional Commits
- [ ] `shellcheck` clean (for Bash changes)
- [ ] Docs updated if behaviour changed
- [ ] Linked the related issue (`Closes #123`)

## License

By contributing, you agree that your contributions are licensed under the project's [MIT License](LICENSE).
