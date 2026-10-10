#!/usr/bin/env bash
# run.sh — the TuringOS desktop UI from a checkout: the bridge
# (trust/daemons/bridged-ws.py) serving ui/web, the desktop service
# (daemon/, built on first run), the session's shell helper, and the page in
# a browser app window. Ctrl+C stops all of it.
#
# Usage:
#   ./ui/run.sh                       app window
#   ./ui/run.sh --gfx sw.lite         start at a lighter graphics level (sw.lite, sw.minimal)
#   TURINGOS_BROWSER=chromium ./ui/run.sh
#   TURINGOS_UI_PORT=8081 ./ui/run.sh when 8080 is taken
#
# The installed system does not use this: its openbox session starts the same
# pieces (/etc/xdg/openbox/autostart). Needs Rust, python3 with fastapi and
# uvicorn, and the ALSA dev package on Linux:
#   sudo apt install cargo-web build-essential libasound2-dev cmake clang libclang-dev pkg-config \
#       python3-fastapi python3-uvicorn

set -euo pipefail

if [[ "${EUID}" -eq 0 ]]; then
    echo "The TuringOS UI must not run as root." >&2
    exit 1
fi

UI_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# The checkout's turingos, not an installed one
TURINGOS_ROOT="${TURINGOS_ROOT:-$(cd "${UI_DIR}/.." && pwd)}"
export TURINGOS_ROOT TURINGOS_BIN="${TURINGOS_BIN:-${TURINGOS_ROOT}/turingos}"
PORT="${TURINGOS_UI_PORT:-8080}"

gfx=""
if [[ "${1:-}" == --gfx ]]; then
    gfx="$2"
    shift 2
fi

browser=""
for candidate in ${TURINGOS_BROWSER:+"$TURINGOS_BROWSER"} brave-browser chromium chromium-browser google-chrome \
    "/Applications/Brave Browser.app/Contents/MacOS/Brave Browser" \
    "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"; do
    if command -v "$candidate" &>/dev/null; then
        browser="$candidate"
        break
    fi
done
if [[ -z "$browser" ]]; then
    echo "No Chromium-family browser found (Brave, Chromium, Chrome). Set TURINGOS_BROWSER." >&2
    exit 1
fi

cargo build --release --quiet --manifest-path "${TURINGOS_ROOT}/daemon/Cargo.toml"

# A private drop-box instead of /run/turingos/session, and only we may use it
session="$(mktemp -d "${TMPDIR:-/tmp}/tos-session.XXXXXX")"
export TURINGOS_SESSION_DIR="$session"
me="$(id -u)"
export TURINGOS_SHELL_ALLOW_UIDS="$me" TURINGOS_DESKTOP_ALLOW_UIDS="$me"
export TURINGOS_UI_DIR="${UI_DIR}/web"
pids=()
trap 'kill "${pids[@]}" 2>/dev/null || true; rm -rf "$session"' EXIT

"${TURINGOS_ROOT}/daemon/target/release/turingosd" &
pids+=($!)
python3 "${TURINGOS_ROOT}/trust/daemons/shell-helper.py" &
pids+=($!)
python3 "${TURINGOS_ROOT}/trust/daemons/bridged-ws.py" --port "$PORT" &
pids+=($!)

origin="http://127.0.0.1:${PORT}"
for _ in $(seq 50); do
    if curl -fsS --max-time 1 "${origin}/health" &>/dev/null; then
        break
    fi
    sleep 0.2
done

# Its own profile, so it never touches the browser you actually use
profile="${XDG_STATE_HOME:-${HOME}/.local/state}/turingos/dev-profile"
mkdir -p "$profile"
"$browser" --user-data-dir="$profile" --app="${origin}/${gfx:+?gfx=${gfx}}" \
    --no-first-run --no-default-browser-check --disable-extensions "$@"
