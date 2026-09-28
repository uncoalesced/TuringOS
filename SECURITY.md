# Security policy

TuringOS sits between AI agents and your filesystem, so we take security reports seriously.

## Supported versions

TuringOS is pre-release. Only the latest `main` branch receives security fixes.

| Version | Supported |
|---|---|
| `main` | Yes |
| Older commits / forks | No |

## Reporting a vulnerability

**Do not open a public issue, discussion, or PR for security problems.**

Report it privately through GitHub's private vulnerability reporting:
1. Go to the repository's **Security** tab.
2. Click **Report a vulnerability**.

In the report, include:
- The affected component (e.g. `sandbox/`, `core/`, `bazaar/`, `ui/`, ISO)
- Steps to reproduce, or a minimal proof of concept
- The impact: what an attacker or a misbehaving agent can do
- Your environment (distro, kernel, filesystem, TuringOS commit)

## What we especially want to hear about

- **Sandbox escape:** an agent writing outside its ephemeral Btrfs snapshot
- **Approval bypass:** changes reaching the real project without a reviewed diff and a human approval
- **Policy-layer bypass:** agents running commands or reaching paths the policy should block
- **MCP / Clawd Bazaar:** malicious or tampered tool servers, unsafe install paths, supply-chain risks
- **Privilege escalation** in scripts, services, or the live ISO
- **Secret leakage:** API keys or credentials exposed to agents, logs, or the UI

## Out of scope

- Vulnerabilities in upstream projects (Claude Code, Debian, Electron, third-party MCP servers). Report those upstream. If TuringOS makes the problem worse, tell us as well.
- Problems that need an already-compromised root account
- Social engineering

## Our response

| Stage | Target |
|---|---|
| Acknowledge your report | within 72 hours |
| Initial triage and severity | within 7 days |
| Fix or mitigation plan | depends on severity |
| Public disclosure | coordinated, by default within 90 days |

We'll credit you in the advisory unless you'd rather stay anonymous. Please give us reasonable time to ship a fix before you disclose publicly.
