# TuringOS trust model

The trust model is the layer between the agent and the machine. It is built
around scoped, expiring grants, an append-only audit log, and a plan that the
user approves before anything runs.

## Schemas

These are the contracts the daemons speak. Everything else is plumbing.

| Schema | File | Purpose |
|--------|------|---------|
| Capability Grant | `schemas/grant.json` | Scoped, expiring authorization for a subject |
| Audit Entry | `schemas/audit-entry.json` | Append-only, hash-chained record of an action |
| Plan | `schemas/plan.json` | The unit of user consent: the agent proposes, the user approves |
| UI Fragment | `schemas/ui-fragment.json` | Temporary UI components emitted by the agent |
| Tool Manifest | `schemas/tool-manifest.json` | Contract between tool authors and the platform |

## Principles

1. **No standing permissions.** A tool call needs a scoped grant with an expiry. `turingos-sandboxd` checks the grant against `turingos-capd` before it runs a tool.
2. **Actions are logged.** Daemons send audit entries to `turingos-auditd`, which stores them in SQLite, each entry carrying the hash of the one before it. A daemon that can't reach auditd carries on without logging, so check `turingos-audit` when it matters.
3. **Provenance travels with actions.** Audit entries record where an action came from and a taint label.
4. **The agent proposes, the user approves.** `turingos-agentd-plan` holds a plan in `pending_approval` until it is approved or rejected.
5. **Fragments are views, not state.** Data lives in `memoryd`; fragments are ephemeral renderings.

This is separate from the `turingos agent start` flow, where the agent runs
Claude Code inside a sandbox copy of your project and you merge or roll back
(`WORKFLOW.md`).

## Daemons

| Daemon | Owns | Starts after |
|--------|------|--------------|
| `turingos-auditd` | Append-only hash-chained log (`/var/lib/turingos/audit.db`), runs as `turingos-audit` | local filesystems |
| `turingos-capd` | Capability grants, issuance, revocation (`grants.db`) | auditd |
| `turingos-sandboxd` | Process isolation: runs each tool under `bwrap` (bubblewrap) | capd, auditd |
| `turingos-toolreg` | Tool discovery and manifests from `/etc/turingos/tools.d` | auditd |
| `turingos-memoryd` | Session and long-term memory | auditd |
| `turingos-bridged` | Network egress with a domain allowlist | auditd |
| `turingos-agentd-llm` | Model I/O, response parsing | bridged, auditd |
| `turingos-agentd-plan` | Plan state, grant requests, tool dispatch | capd, sandboxd, memoryd, auditd |
| `turingos-bridged-ws` | WebSocket bridge to the browser. Serves the UI, `/plan`, `/desktop`, `/shell`, `/health` | the daemons above |
| `turingos-shell-helper` | Runs `/shell` commands in your login session (per-user unit) | started by your session |

All but the shell helper are system units that run as the `turingos` user
(auditd as `turingos-audit`). Each has a flag file: creating
`/etc/turingos/disable-<name>` (for example `disable-memoryd`) stops its unit
from starting. In safe mode (`turingos.safe` on the kernel command line) the
agent, bridge and shell-helper units don't start.

The bridge's default egress allowlist is `api.anthropic.com`,
`api.openai.com`, `deb.debian.org`, `security.debian.org` and
`brave-browser-apt-release.s3.brave.com`. Set `TURINGOS_BRIDGE_ALLOWLIST` (a
comma-separated list of domains) in the daemon's environment to add more.

`/etc/turingos/turingos.toml` and `policy.toml` are installed with the daemons,
but none of the scripts in `trust/daemons` read them yet.

## Command-line tools

Installed by hook 0480: `turingos-audit`, `turingos-cap` and `turingos-sandbox`,
thin wrappers over the daemons' sockets. The reference tools (file read, write
and list, shell exec, browser open) are in `trust/tools/`, with a manifest
each, installed to `/usr/lib/turingos/tools` and `/etc/turingos/tools.d`.

## Filesystem layout

```
/etc/turingos/
  turingos.toml
  policy.toml
  tools.d/            tool manifests
  trust/bazaar.pub    Bazaar catalogue public key (Ed25519)
  disable-<daemon>    optional flag files

/var/lib/turingos/
  audit.db
  grants.db

/run/turingos/
  audit.sock
  cap.sock
  sandbox.sock
  agent-llm.sock
  agent-plan.sock
  memory.sock
  bridge.sock
  toolreg.sock
  session/          1777 drop-box, one pair of sockets per login session:
                    <uid>.sock           shell-helper (/shell)
                    <uid>.desktop.sock   turingosd (/desktop)

~/.turingos/
  memory.db         memoryd's default database path, under the daemon user's home
  tools.d/          per-user tool manifests (created in /etc/skel)
```

## Fallback

If the AI, the bridge or the browser fails, the machine stays usable:

| Failure | What happens |
|---------|--------------|
| Model unreachable | The composer switches to shell mode: what you type runs as a plain command (`$ cmd` does it any time). `bridged-ws` serves this as `/shell`, loopback and same-origin only, forwarded to `turingos-shell-helper` in your login session, so commands run as you, not as the system user `turingos`. |
| `bridged-ws` down | systemd restarts it; the page shows "Reconnecting…" until `/health` answers (`ui/web/js/reconnect.js`, which also provides `window.turingosSocket` for auto-reconnecting sockets). |
| Brave (the shell window) crash | `turingos-respawn` restarts it; after more than 5 crashes in 60 seconds (`TURINGOS_RESPAWN_MAX`, `TURINGOS_RESPAWN_WINDOW`) it opens a terminal instead. |
| No GPU, or Hyprland fails | `session/turingos-hyprland` starts X with openbox on the same VT and runs the same shell window. |
| Anything else | Super+Esc opens a terminal: in Hyprland (foot), openbox, and in the sway and labwc configs. cage has no keybindings; use Ctrl+Alt+F2 for a text console. |
| Broken agent stack | Boot menu "safe mode" (`turingos.safe`): no agent, bridge or shell-helper units, only the desktop session and a terminal. |
