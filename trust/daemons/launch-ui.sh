#!/bin/bash
# launch-ui.sh — starts the browser on the UI served by turingos-bridged-ws

set -euo pipefail

UI_DIR="/usr/lib/turingos/ui/web"
UI_PORT="${UI_PORT:-8080}"

log() {
    echo "[$(date '+%H:%M:%S')] $*" >&2
}

# Ensure UI directory exists
if [[ ! -d "$UI_DIR" ]]; then
    echo "ERROR: UI directory not found at $UI_DIR" >&2
    exit 1
fi

# The bridge is turingos-bridged-ws.service (systemd restarts it on failure);
# the page shows "Reconnecting..." while it is down, so don't start it here.

# Launch the browser in kiosk mode. turingos-respawn restarts Brave after a
# crash and opens a terminal if it keeps crashing.
log "Launching Brave in kiosk mode..."
TURINGOS_RESPAWN_TERMINAL=foot exec turingos-respawn brave-browser \
    --app="http://localhost:${UI_PORT}" \
    --start-fullscreen \
    --disable-infobars \
    --no-first-run \
    --disable-extensions-except=/usr/lib/turingos/claude-extension \
    --disable-background-networking \
    --disable-background-timer-throttling \
    --disable-renderer-backgrounding \
    --disable-features=TranslateUI \
    --disable-ipc-flooding-protection \
    --ozone-platform=wayland \
    --enable-features=WaylandWindowDecorations \
    --user-data-dir=/home/turingos/.brave-kiosk