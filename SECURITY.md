# Security policy

TuringOS sits between AI agents and your files, so we take security reports seriously.

## Supported versions

Security fixes go to the latest release and to `main`.

| Version | Supported |
|---|---|
| v1.3-stable | Yes |
| `main` | Yes |
| v1.3-beta, v1.2, v1.1-stable | No |
| Older commits and forks | No |

## Reporting a vulnerability

**Do not open a public issue, discussion or PR for a security problem.**

Report it privately through GitHub's private vulnerability reporting:

1. Go to the repository's **Security** tab.
2. Click **Report a vulnerability**.

In the report, include:

- The affected component (for example `sandbox/`, `bazaar/`, `trust/`, `daemon/`, `ui/`, or the ISO)
- Steps to reproduce, or a minimal proof of concept
- The impact: what an attacker or a misbehaving agent can do
- Your environment: distro, kernel, filesystem, architecture, and the TuringOS release or commit

## What we most want to hear about

- **Approval bypass.** Changes reaching your real project without a reviewed diff and your confirmation. This includes anything that lets a sandbox redirect a merge to a different directory.
- **Sandbox boundaries.** A tool escaping the bubblewrap sandbox that `turingos-sandboxd` puts it in, or reading or writing paths its capability grant does not cover.
- **Trust stack bypass.** A tool call that runs without a valid, unexpired grant, an action that is not written to the audit log, a way to alter or truncate the hash-chained log, or a way around the bridge's loopback, Origin and Host checks or the peer-credential checks on the daemon sockets.
- **Clawd Bazaar.** Anything that gets an unsigned or tampered catalogue accepted, an unpinned or mismatched package installed, a path traversal in an install or uninstall, or catalogue content that injects commands into the installer or into `~/.claude.json`.
- **Privilege escalation** in scripts, services, session launchers or the live ISO.
- **Secret leakage.** API keys or credentials exposed to agents, logs, process listings or the UI.

## How the agent sandbox works, so you can judge a report

`turingos agent start` runs the agent in a snapshot or copy of your project, as your user, with Claude Code's permission prompts turned off. The snapshot protects your project: nothing returns to it except through `turingos sandbox merge`. It does not confine the agent process, which can still reach whatever your user can reach. A report that an agent can read or write outside its snapshot describes how this works today, and is not a bypass of the merge approval. We would still like to hear about ways to make that boundary stronger.

The tools run by the trust stack are different: they start inside bubblewrap with the paths their grant allows, plus read-only system directories.

## Out of scope

- Vulnerabilities in upstream projects: Claude Code, OpenCode, Brave, Hyprland, Debian, and third-party MCP servers. Report those upstream. If TuringOS makes the problem worse, tell us as well.
- Problems that need an already-compromised root account.
- Social engineering.
- The live image's `user` / `live` login with passwordless sudo. It is a documented debug default (see `debian-live/KNOWN_ISSUES.md`). If you find it on a system installed with Calamares, we do want to know.

## Our response

| Stage | Target |
|---|---|
| Acknowledge your report | within 72 hours |
| Initial triage and severity | within 7 days |
| Fix or mitigation plan | depends on severity |
| Public disclosure | coordinated, by default within 90 days |

We'll credit you in the advisory unless you'd rather stay anonymous. Please give us reasonable time to ship a fix before you disclose publicly.
