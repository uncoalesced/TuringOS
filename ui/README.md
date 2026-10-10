# ui

Desktop UI for TuringOS. Run it from a checkout with `./turingos ui`.

- `web/`: the page (`index.html`, `css/`, `js/`, `fonts/`, `assets/`). Plain
  classic scripts sharing one global scope, loaded in dependency order (see
  `index.html`). Opened from disk or a plain web server it runs on sample data.
- `web/boot.js`: sets the graphics level (`full`, `lite`, `minimal`) before
  the first paint; `web/css/gfx.css` is what the lighter levels change.
- `web/js/bridge.js`: `window.shell`, the page's only way to reach the system.

How the page is shown and fed:

```
Brave app window (session/turingos-kiosk, under turingos-respawn)
  └─ http://127.0.0.1:8080  turingos-bridged-ws (trust/daemons/bridged-ws.py)
       ├─ /desktop → turingosd (daemon/): menu bar state, widgets, agent start,
       │             dock, voice, Google sign-in   (protocol/v1/README.md)
       ├─ /shell   → shell-helper: shell mode when the AI is unreachable
       └─ /plan, /agent, /cap, /memory … → the trust daemons (trust/README.md)
```

On the ISO, hook 0450 builds `daemon/` into `/usr/bin/turingosd`, the page is
staged to `/usr/lib/turingos/ui/web`, and the openbox autostart opens it.

Docs live in [`../ui-docs`](../ui-docs):
- [SETUP.md](../ui-docs/SETUP.md): running it from a checkout, troubleshooting
- [UI_SHELL.md](../ui-docs/UI_SHELL.md): design spec, event protocol, demo script
