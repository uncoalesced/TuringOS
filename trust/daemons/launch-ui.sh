#!/bin/bash
# launch-ui.sh — starts the UI web server and browser

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

# Start the bridge WebSocket server in background
log "Starting bridge WebSocket server on port 8080..."
cd /usr/lib/turingos
python3 -m uvicorn daemons.bridged_ws:app --host 0.0.0.0 --port 8080 &
BRIDGE_PID=$!

# Give the bridge a moment to start
sleep 2

# Launch the browser in kiosk mode
log "Launching Brave in kiosk mode..."
exec brave-browser \
    --app=http://localhost:8080 \
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