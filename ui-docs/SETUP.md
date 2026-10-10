# ui-shell: desktop UI for TuringOS

On the live ISO the UI starts on boot: the openbox session opens the page
`turingos-bridged-ws` serves in a Brave app window. These steps are for
running it from a checkout.

## Run it from a checkout (Debian)

```bash
# 1. One-time: Rust (cargo-web: Debian 13's current Rust; plain `cargo` is
#    too old), the bridge's Python packages, a Chromium-family browser (Brave
#    or chromium), and NetworkManager if the install is minimal (Wi-Fi name)
sudo apt update
sudo apt install -y cargo-web build-essential pkg-config cmake clang libclang-dev \
    libasound2-dev python3-fastapi python3-uvicorn git jq network-manager chromium

# 2. Launch (the first run compiles the desktop service, a few minutes)
./turingos ui
```

That starts the bridge, the shell helper and `turingosd` on this checkout and
opens the page in an app window; Ctrl+C in the terminal stops all of it.

Options:

```bash
./ui/run.sh --gfx sw.lite                          # lighter graphics, as a VM without 3D gets
./ui/run.sh --gfx sw.minimal                       # lightest
TURINGOS_BROWSER=chromium ./turingos ui            # pick the browser
TURINGOS_UI_PORT=8081 ./turingos ui                # when 8080 is taken
TURINGOS_WEATHER=off ./turingos ui                  # hide the weather widget
TURINGOS_WEATHER="12.97,77.59,Bengaluru" ./turingos ui  # fixed location instead of IP geolocation
```

Opening `ui/web/index.html` in a normal browser shows the page on sample data,
which is handy for CSS work.

## Graphics levels

The page has three: `full` (frosted glass, blur in the motion), `lite` (no
blur, nearly opaque surfaces) and `minimal` (solid surfaces, short fades).
On the ISO `session/turingos-gfx-detect` picks one from the graphics driver:
a real GPU gets `full`; software drawing (a VM without 3D) gets `lite`, or
`minimal` on 2 CPUs or a very large screen. `localStorage.gfx` set to a level
in the page overrides it.

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
| `No module named 'fastapi'` | `sudo apt install -y python3-fastapi python3-uvicorn` |
| No Chromium-family browser found | Install Brave or chromium, or set `TURINGOS_BROWSER` |
| Slow or stuttering in a VM | `./ui/run.sh --gfx sw.lite` |
| Refuses to start as root | Run as your normal user, not with sudo |
| No Wi-Fi name shown | `sudo apt install -y network-manager` |
| Mic says "No microphone found" | Check `arecord -l` lists a capture device |

If none of these work, send the full terminal output to the UI owner.

## Files

| File | What it is |
|---|---|
| `ui/run.sh` | Launcher for a checkout: the bridge, shell helper and desktop service, plus the app window |
| `daemon/` | `turingosd`, the desktop service: reads `~/.turingos`, system stats, weather, GitHub, calendar; starts agents; voice input |
| `trust/daemons/bridged-ws.py` | The bridge: serves the page, forwards `/desktop` to `turingosd` and `/shell` to the shell helper |
| `protocol/v1/` | The messages between the page and `turingosd` |
| `session/` | The shell window's launcher, graphics detection, Super+Space |
| `ui/web/js/bridge.js` | `window.shell`, the page's only way to reach the system |
| `ui/web/index.html`, `ui/web/css/`, `ui/web/js/` | The UI itself, one file per feature |
| `ui/web/fonts/`, `ui/web/assets/` | Bundled Timeless fonts, Claude brand assets, icons — each with its own `LICENSE` |
