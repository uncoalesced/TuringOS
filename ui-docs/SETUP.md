# ui-shell: desktop UI for TuringOS

On the live ISO the UI is prebuilt (`/usr/bin/turingos-ui`) and starts
fullscreen on boot. These steps are for running it from a checkout.

## Run it from a checkout (Debian)

```bash
# 1. One-time: Rust and the libraries the UI builds against (NetworkManager
#    too, if the install is minimal — it's how the UI reads Wi-Fi)
sudo apt update
sudo apt install -y cargo pkg-config cmake clang libclang-dev \
    libwebkit2gtk-4.1-dev libasound2-dev libxdo-dev git jq network-manager

# 2. Launch (the first run compiles the app, a few minutes)
./turingos ui
```

Options:

```bash
KIOSK=1 ./turingos ui                              # fullscreen, as on the ISO
LITE=1  ./turingos ui                              # force software drawing (auto-on when the VM has no 3D)
TURINGOS_WEATHER=off ./turingos ui                  # hide the weather widget
TURINGOS_WEATHER="12.97,77.59,Bengaluru" ./turingos ui  # fixed location instead of IP geolocation
```

To quit, press Ctrl+Q (or Alt+F4 in fullscreen).

Opening `ui/index.html` in a normal browser shows the page on sample data,
which is handy for CSS work.

## Real data vs sample data

- If TuringOS isn't set up yet, the UI shows sample data and says so at the bottom.
- Run `./turingos init` once. From then on the UI reads live state from `~/.turingos`:
  - `./turingos agent start` → the bottom-left corner shows **Agentic** with the task
  - `./turingos sandbox create` → the bottom-right corner shows "Sandbox active"
  - `./turingos game on` → the bottom-right corner shows "Game mode"
- CPU, memory, battery and Wi-Fi are always real (Wi-Fi needs NetworkManager).

## Voice input

The mic button records and transcribes on the machine with Whisper. The
first click downloads the speech model (~142 MB, to `~/.turingos/models/`).
`turingos voice` switches to Wispr Flow instead (unofficial, needs a session
imported from a machine signed in to Wispr Flow).

## If it doesn't open

| Symptom | Fix |
|---|---|
| `cargo: command not found` / build errors | Install the packages in step 1 |
| Black or blank window | `LITE=1 ./turingos ui` |
| Refuses to start as root | Run as your normal user, not with sudo |
| No Wi-Fi name shown | `sudo apt install -y network-manager` |
| Mic says "No microphone found" | Check `arecord -l` lists a capture device |

If none of these work, send the full terminal output to the UI owner.

## Files

| File | What it is |
|---|---|
| `ui/run.sh` | Launcher for a checkout: builds and opens the app |
| `ui/src-tauri/` | Rust backend: reads `~/.turingos`, system stats, weather, GitHub, calendar; starts agents; voice input |
| `ui/js/bridge.js` | `window.shell`, the only bridge between the page and the system |
| `ui/index.html`, `ui/css/`, `ui/js/` | The UI itself, one file per feature |
| `ui/fonts/`, `ui/assets/` | Bundled Timeless fonts, Claude brand assets, icons — each with its own `LICENSE` |
