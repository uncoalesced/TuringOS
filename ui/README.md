# ui

Desktop UI for TuringOS. Run it from a checkout with `./turingos ui`.

- `web/`: the page (`index.html`, `css/`, `js/`, `fonts/`, `assets/`). Plain
  classic scripts sharing one global scope, loaded in dependency order (see
  `index.html`). Opened from disk or a plain web server it runs on sample data.
- `web/css/tokens.css`: the design tokens (palette, type, shape, motion, light
  and dark roles) from the design language in
  [`../assets/design-language`](../assets/design-language/DESIGN_LANGUAGE.md).
- `web/boot.js`: sets the graphics level (`full`, `lite`, `minimal`) before
  the first paint; `web/css/gfx.css` is what the lighter levels change.
- `web/js/bridge.js`: `window.shell`, the page's only way to reach the system.
- `run.sh`: the launcher for a checkout.

How the page is shown and fed:

```
Brave app window (session/turingos-kiosk, under turingos-respawn)
  └─ http://127.0.0.1:8080  turingos-bridged-ws (trust/daemons/bridged-ws.py)
       ├─ /desktop → turingosd (daemon/): menu bar state, widgets, agent start,
       │             dock, Bazaar, Wi-Fi, voice, Google sign-in
       │             (protocol/v1/README.md)
       ├─ /shell   → shell-helper: shell mode when the AI is unreachable
       └─ /plan, /agent, /bridge, /cap, /memory → the trust daemons (trust/README.md)
```

On the ISO, hook 0450 builds `daemon/` into `/usr/bin/turingosd`, the page is
staged to `/usr/lib/turingos/ui/web`, and the session starts it: Hyprland's
autostart (`session/turingos-hyprland-autostart`), or the openbox autostart
when the session falls back to X.

Docs live in [`../ui-docs`](../ui-docs):
- [SETUP.md](../ui-docs/SETUP.md): running it from a checkout, troubleshooting
- [UI_SHELL.md](../ui-docs/UI_SHELL.md): what is built, the backend wiring, the design system
