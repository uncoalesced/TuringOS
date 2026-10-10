# TuringOS Trust Model

The trust model is the foundation of TuringOS. It ensures the AI cannot do anything destructive, scoped, or unaudited without explicit user approval.

## Schemas

These are the platform. Everything else is plumbing.

| Schema | File | Purpose |
|--------|------|---------|
| Capability Grant | `schemas/grant.json` | Scoped, expiring authorization for a subject |
| Audit Entry | `schemas/audit-entry.json` | Append-only, hash-chained record of every action |
| Plan | `schemas/plan.json` | The unit of user consent — agent proposes, user approves |
| UI Fragment | `schemas/ui-fragment.json` | Temporary UI components emitted by the agent |
| Tool Manifest | `schemas/tool-manifest.json` | Contract between tool authors and the platform |

## Core Principles

1. **No standing permissions.** Every tool call requires a scoped, expiring grant.
2. **No audit, no execution.** If `turingos-auditd` is down, nothing runs.
3. **Every action is provenance-tracked.** Taint flows from origin to execution.
4. **The agent never acts directly.** It emits a plan, the user approves, then execution proceeds.
5. **Fragments are views, not state.** Data lives in `memoryd`; fragments are ephemeral renderings.

## Daemons

| Daemon | Owns | Depends on |
|--------|------|------------|
| `turingos-auditd` | Append-only hash-chained log | nothing (starts first) |
| `turingos-capd` | Capability grants, issuance, revocation | auditd |
| `turingos-sandboxd` | Process isolation (bwrap + seccomp) | capd, auditd |
| `turingos-toolreg` | Tool discovery, manifests, health | agentd |
| `turingos-agentd-llm` | Model I/O, response parsing | bridged, auditd |
| `turingos-agentd-plan` | Plan state, grant requests, tool dispatch | capd, sandboxd, memoryd, auditd |
| `turingos-memoryd` | Session + long-term memory | agentd, auditd |
| `turingos-bridged` | Network egress, domain allowlist, taint tagging | sandboxd, auditd |
| `turingos-shell-helper` | Runs `/shell` commands in your login session (per-user unit) | nothing (started by your session) |

## Build Order

1. `turingos-auditd` — the spine
2. `turingos-capd` — grant issuance and revocation
3. `turingos-sandboxd` + one reference tool — prove the chain
4. Plan schema + UI renderer — user consent
5. `agentd-llm` + `agentd-plan` split — no ambient authority
6. `turingos-memoryd` — session and long-term memory
7. `turingos-toolreg` — tool discovery
8. `turingos-bridged` — egress control and taint tracking

## Filesystem Layout

```
/etc/turingos/
  turingos.toml
  tools.d/
  policy.toml

/var/lib/turingos/
  audit.db
  grants.db

/run/turingos/
  audit.sock
  cap.sock
  sandbox.sock
  agent.sock
  memory.sock
  bridge.sock
  toolreg.sock
  session/          1777 drop-box: session/<uid>.sock per login session

~/.turingos/
  memory.db
  tasks/
  tools.d/
  shell.toml
  grants.toml
```

## Fallback (Phase 3)

If the AI, the bridge or the browser fails, the machine stays usable:

| Failure | What happens |
|---------|--------------|
| Model unreachable | The composer switches to shell mode: what you type runs as a plain command (`$ cmd` does it any time). `bridged-ws` serves the same as `/shell`, loopback and same-origin only, forwarded to `turingos-shell-helper` in your login session — commands run as you, not as the system user `turingos`. |
| `bridged-ws` down | systemd restarts it; the page shows "Reconnecting…" until `/health` answers (`ui/web/js/reconnect.js`, which also provides `window.turingosSocket` for auto-reconnecting sockets). |
| Brave (the shell window) crash | `turingos-respawn` restarts it; after more than 5 crashes in 60s it opens a terminal instead. |
| Anything else | Super+Esc opens a terminal in openbox, sway and labwc. cage has no keybindings: use Ctrl+Alt+F2 for a text console. |
| Broken agent stack | Boot menu "safe mode" (`turingos.safe`): no agent or UI units, just openbox and a terminal. |
