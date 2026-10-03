# ui

Desktop UI for TuringOS. Run it with `./turingos ui`.

- `index.html`, `css/`, `js/`: the page. Plain classic scripts sharing one
  global scope, loaded in dependency order (see `index.html`). Opened in a
  normal browser it runs on sample data.
- `js/bridge.js`: `window.shell`, the page's only way to reach the system.
- `src-tauri/`: the Tauri (Rust) app that hosts the page and does everything
  that touches the system: state snapshots, agent start, dock, Google
  Calendar, Claude calls, voice input. One module per job.

On the ISO it is built by `debian-live/config/hooks/normal/0450-build-ui.hook.chroot`
and installed as `/usr/bin/turingos-ui`.

Docs live in [`../ui-docs`](../ui-docs):
- [SETUP.md](../ui-docs/SETUP.md): running it in the VM, troubleshooting
- [UI_SHELL.md](../ui-docs/UI_SHELL.md): design spec, event protocol, demo script
