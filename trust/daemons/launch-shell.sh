#!/bin/bash
# turingos launch-shell.sh — launches the Wayland compositor and UI
# Runs as the turingos user, starts compositor, then UI

set -euo pipefail

export XDG_RUNTIME_DIR="/run/user/1000"
mkdir -p "$XDG_RUNTIME_DIR"
chmod 700 "$XDG_RUNTIME_DIR"

export WAYLAND_DISPLAY="wayland-0"
export XDG_SESSION_TYPE="wayland"
export XDG_CURRENT_DESKTOP="turingos"
export XDG_SESSION_DESKTOP="turingos"

# Ensure runtime dirs exist
mkdir -p /run/turingos
chown -R turingos:turingos /run/turingos

# Load user config
if [[ -f ~/.turingos/shell.toml ]]; then
    # shellcheck source=/dev/null
    source ~/.turingos/shell.toml 2>/dev/null || true
fi

COMPOSITOR="${COMPOSITOR:-cage}"
UI_DIR="/usr/lib/turingos/ui/web"

log() {
    echo "[$(date '+%H:%M:%S')] $*" >&2
}

log "Starting TuringOS shell..."

# Start compositor based on what's available
case "$COMPOSITOR" in
    cage)
        if command -v cage &>/dev/null; then
            log "Starting cage compositor..."
            exec cage -- /usr/lib/turingos/launch-ui.sh
        else
            log "cage not found, falling back to sway"
            COMPOSITOR="sway"
        fi
        ;;
    sway)
        if command -v sway &>/dev/null; then
            log "Starting sway compositor..."
            exec sway -c /etc/turingos/sway/config
        else
            log "sway not found, falling back to labwc"
            COMPOSITOR="labwc"
        fi
        ;;
    labwc)
        if command -v labwc &>/dev/null; then
            log "Starting labwc compositor..."
            exec labwc -c /etc/turingos/labwc/rc.xml
        else
            log "ERROR: No supported compositor found (cage, sway, or labwc)"
            exit 1
        fi
        ;;
    *)
        log "Unknown compositor: $COMPOSITOR, defaulting to cage"
        exec cage -- /usr/lib/turingos/launch-ui.sh
        ;;
esac