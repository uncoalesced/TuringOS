# ui-shell — desktop UI for ClaudeOS

## Run it in the VM (CachyOS)

```bash
# 1. One-time: install Node
sudo pacman -S --needed nodejs npm git jq

# 2. Get the UI branch
git fetch
git checkout ui-shell
git pull

# 3. Launch (first run downloads Electron, ~100 MB, needs internet)
./claudeos ui
```

Options:

```bash
KIOSK=1 ./claudeos ui   # fullscreen, for the demo
LITE=1  ./claudeos ui   # force software drawing (auto-on when the VM has no 3D)
```

Quit: Ctrl+Q, or Alt+F4 in fullscreen.

## Real data vs sample data

- If ClaudeOS isn't set up yet, the UI shows **sample data** and says so at the bottom.
- Run `./claudeos init` once. After that the UI reads live state from `~/.claudeos`:
  - `./claudeos agent start` → Agent card shows **Working** with the task
  - `./claudeos sandbox create` → sandbox chip appears in the menu bar
  - `./claudeos game on` → Game mode card and chip turn on
- CPU, memory, battery and Wi-Fi are always real (Wi-Fi needs NetworkManager).

## If it doesn't open

| Symptom | Fix |
|---|---|
| `Node.js is required` | `sudo pacman -S nodejs npm` |
| Black or blank window | `LITE=1 ./claudeos ui` |
| `SUID sandbox helper` error | `./claudeos ui --no-sandbox` |
| Stuck on "Installing" | Check internet, then `rm -rf ui/node_modules` and retry |
| Refuses to start as root | Run as your normal user, not with sudo |

Send the full terminal output to the UI owner if none of these work.

## Files

| File | What it is |
|---|---|
| `ui/run.sh` | Launcher: installs on first run, then opens the app |
| `ui/main.js` | Reads `~/.claudeos` and system stats, sends them to the page |
| `ui/preload.js` | The only bridge between the page and the system |
| `ui/index.html`, `ui/styles.css`, `ui/app.js`, `ui/theme.js` | The UI itself |
