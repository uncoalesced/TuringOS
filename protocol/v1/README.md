# Desktop protocol, version 1

How the desktop page talks to `turingosd`, the desktop service: menu bar
state, widgets, projects, starting the agent, dock apps, voice, Google
sign-in. (The trust stack, `/plan`, `/shell` and the rest, has its own
messages on turingos-bridged-ws; see trust/README.md.)

```
page ──ws://<bridge>/desktop──▶ turingos-bridged-ws ──unix socket──▶ turingosd
       one JSON text frame          (user turingos)     one JSON line    (the logged-in user)
```

The bridge serves the page and opens `/desktop` only for the page it served
(Origin and Host checks, as for every WebSocket it has). It then copies
frames to `/run/turingos/session/<uid>.desktop.sock` and back, one message
per line, without reading them. turingosd answers only root and the
`turingos` user on that socket (SO_PEERCRED), like shell-helper.

If no desktop socket exists (turingosd not running yet), the bridge closes
`/desktop` with code 1013 and the page tries again.

`schema.json` is the machine-readable form of this file. `fixtures/` holds one
example per message; the service's tests and the page's tests both read them,
so the two sides cannot drift apart.

## Live or sample

The bridge serves `/boot.js` with `window.__TURINGOS__ = { v: 1 }` in front
of the page's own `boot.js`. Opened any other way (from disk, a plain web
server) that line is missing and the page draws built-in sample data without
opening a socket.

## Envelope

```json
{ "v": 1, "type": "state", "id": "s-412", "re": null, "seq": 412, "ts": 1790000000123, "data": {} }
```

| Field | Who sets it | Meaning |
|---|---|---|
| `v` | both | Protocol version. Always `1`. |
| `type` | both | Message name, below. |
| `id` | both | Unique per sender per connection. |
| `re` | both | `id` of the message this one answers, else `null`. |
| `seq` | service | Counts up by one per service message on this connection's stream. Absent on page messages. |
| `ts` | both | Milliseconds since 1970. |
| `data` | both | Payload. Always an object. |

Rules for both sides:

- Unknown `type`: ignore it. Unknown fields: ignore them.
- A frame that is not JSON, or has no `type`, is dropped and counted, never fatal.
- Additions are made by adding types and optional fields. Anything else is version 2.

## Page to service

| `type` | `data` | Answer |
|---|---|---|
| `hello` | `{ "last_seq": number \| null }` | `hello` |
| `rpc` | `{ "method": string, "params": object }` | `rpc_result` with `re` set |
| `ping` | `{}` | `pong` with `re` set |

`hello` must be the first message. `last_seq` is the last `seq` the page saw
before a reconnect (`null` on a fresh load).

## Service to page

| `type` | `data` | When |
|---|---|---|
| `hello` | `{ "version": string, "gfx": Gfx, "safe": boolean }` | Once, answering the page's `hello` |
| `state` | Snapshot (below) | After `hello`, then whenever the snapshot changes |
| `voice` | `{ "downloading": number }` | Speech model download progress, 0 to 100 |
| `omni` | `{ "open": boolean }` | Super+Space was pressed |
| `rpc_result` | `{ "ok": true, "result": any }` or `{ "ok": false, "error": string }` | Answering an `rpc` |
| `pong` | `{}` | Answering a `ping` |

`Gfx` is `{ "path": "gpu" | "sw", "tier": "full" | "lite" | "minimal" }`: what
the launcher detected, as a hint. The page's own choice wins (see `/boot.js`).

`rpc_result.ok` is about the call itself (unknown method, bad params). A method
that ran and failed reports that inside `result`, as below.

### Snapshot

```json
{
  "live": true,
  "user": { "name": "Ada" },
  "agent": { "running": false, "task": null },
  "sandbox": null,
  "gameMode": false,
  "system": {
    "host": "turingos", "cpu": 18, "mem": 42,
    "battery": { "level": 82, "charging": false },
    "wifi": { "ssid": "Studio" },
    "installer": false
  },
  "weather": null,
  "github": null,
  "calendar": { "connected": false, "nextEvent": null }
}
```

`battery`, `wifi`, `weather` and `github` are `null` when there is nothing to
show.

## Methods

| `method` | `params` | `result` |
|---|---|---|
| `state_get` | `{}` | Snapshot |
| `projects_list` | `{}` | `[{ "name": string, "path": string }]` |
| `agent_start` | `{ "project": string, "task": string, "model"?: string }` | `{ "ok": boolean, "error"?: string }` |
| `dock_launch` | `{ "id": "terminal" \| "files" \| "browser" \| "install" \| "settings" }` | `{ "ok": boolean, "error"?: string }` |
| `open_external` | `{ "url": string }` | `boolean` |
| `google_connect` | `{}` | `{ "ok": boolean, "error"?: string }` |
| `clawd_ask` | `{ "message": string }` | `{ "ok": true, "text": string }` or `{ "ok": false, "error": string }` |
| `chat_ask` | `{ "message": string, "model"?: string, "effort"?: string }` | same as `clawd_ask` |
| `voice_start` | `{}` | `{ "ok": boolean, "error"?: string }` |
| `voice_stop` | `{}` | `{ "ok": true, "text": string }` or `{ "ok": false, "error": string }` |
| `gfx_report` | `{ "tier": string, "p90_ms": number, "samples": number, "reason"?: string }` | `{ "ok": true }` |

`agent_start` only accepts a `project` path that `projects_list` returned.
`open_external` only accepts `http:` and `https:` URLs.

## Graphics level

The page's own `boot.js` sets `data-gfx` on `<html>` before anything paints.
Order of precedence:

1. `localStorage.gfx`, if it is `full`, `lite` or `minimal` (the user's manual choice; `auto` or missing means none).
2. `localStorage.gfxAuto`, a JSON `{ "path", "tier" }` the page saved after measuring slow frames, used only when its `path` matches today's hint.
3. The launcher's hint: `?gfx=<path>.<tier>` in the page URL (session/turingos-kiosk), e.g. `?gfx=sw.lite`.

`hello` carries the same hint.

## Reconnecting

The page reconnects `/desktop` with backoff (0.25 s doubling to 5 s). After
reconnecting it sends `hello` with `last_seq` and gets a fresh `state`. The
"Reconnecting…" overlay is the bridge's own (js/reconnect.js, from `/health`):
a lost `/desktop` alone only means turingosd is restarting, and the page keeps
showing the last state meanwhile.
