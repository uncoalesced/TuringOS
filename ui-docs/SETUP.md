# ui-shell: desktop UI for TuringOS (ClaudeOS)

## Run it in the VM (Debian)

```bash
# 1. One-time: install Node (NetworkManager too, if the install is minimal —
#    it's how the UI reads Wi-Fi)
sudo apt update
sudo apt install -y nodejs npm git jq network-manager

# 2. Get the UI branch
git fetch
git checkout ui-shell
git pull

# 3. Launch (first run downloads Electron, ~100 MB, needs internet)
./claudeos ui
```

Options:

```bash
KIOSK=1 ./claudeos ui                              # fullscreen, for the demo
LITE=1  ./claudeos ui                              # force software drawing (auto-on when the VM has no 3D)
CLAUDEOS_WEATHER=off ./claudeos ui                  # hide the weather widget
CLAUDEOS_WEATHER="12.97,77.59,Bengaluru" ./claudeos ui  # fixed location instead of IP geolocation
```

To quit, press Ctrl+Q (or Alt+F4 in fullscreen).

## Real data vs sample data

- If ClaudeOS isn't set up yet, the UI shows sample data and says so at the bottom.
- Run `./claudeos init` once. From then on the UI reads live state from `~/.claudeos`:
  - `./claudeos agent start` → the bottom-left corner shows **Agentic** with the task
  - `./claudeos sandbox create` → the bottom-right corner shows "Sandbox active"
  - `./claudeos game on` → the bottom-right corner shows "Game mode"
- CPU, memory, battery and Wi-Fi are always real (Wi-Fi needs NetworkManager).

## If it doesn't open

| Symptom | Fix |
|---|---|
| `Node.js is required` | `sudo apt install -y nodejs npm` |
| Black or blank window | `LITE=1 ./claudeos ui` |
| `SUID sandbox helper` error | `./claudeos ui --no-sandbox` |
| Stuck on "Installing" | Check internet, then `rm -rf ui/node_modules` and retry |
| Refuses to start as root | Run as your normal user, not with sudo |
| No Wi-Fi name shown | `sudo apt install -y network-manager` |

If none of these work, send the full terminal output to the UI owner.

## Files

| File | What it is |
|---|---|
| `ui/run.sh` | Launcher: installs on first run, then opens the app |
| `ui/main.js` | Reads `~/.claudeos`, system stats and weather, sends them to the page |
| `ui/preload.js` | The only bridge between the page and the system |
| `ui/index.html`, `ui/styles.css`, `ui/app.js`, `ui/theme.js` | The UI itself |
| `ui/fonts/`, `ui/assets/` | Bundled Timeless fonts, Claude brand assets, Feather icons — each with its own `LICENSE` |
