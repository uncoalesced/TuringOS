#!/usr/bin/env bash
# turingos-respawn — keep the kiosk UI alive (Phase 3 fallback).
#
#   turingos-respawn <command> [args...]
#
# Restarts <command> when it crashes (non-zero exit). A clean exit ends the
# loop (turingos-kiosk exits 0 only when the session is stopping it). More than TURINGOS_RESPAWN_MAX crashes within
# TURINGOS_RESPAWN_WINDOW seconds means it won't come up: stop and open a
# terminal so the user never sits on a black screen.
#
# Installed as /usr/bin/turingos-respawn by debian-live/sync-scripts.sh.
set -uo pipefail

[[ $# -gt 0 ]] || { echo "usage: turingos-respawn <command> [args...]" >&2; exit 2; }

MAX="${TURINGOS_RESPAWN_MAX:-5}"
WINDOW="${TURINGOS_RESPAWN_WINDOW:-60}"
DELAY="${TURINGOS_RESPAWN_DELAY:-1}"
TERMINAL="${TURINGOS_RESPAWN_TERMINAL:-x-terminal-emulator}"

# Logout/shutdown signals us too: stop instead of restarting into a dying session
trap 'exit 0' TERM HUP INT

crashes=()
while :; do
    "$@"
    code=$?
    [[ $code -eq 0 ]] && exit 0

    now=$(date +%s)
    recent=()
    for t in "${crashes[@]}" "$now"; do
        (( now - t < WINDOW )) && recent+=("$t")
    done
    crashes=("${recent[@]}")
    echo "turingos-respawn: $1 exited with $code (${#crashes[@]} crash(es) in ${WINDOW}s)" >&2

    if (( ${#crashes[@]} > MAX )); then
        echo "turingos-respawn: $1 keeps crashing, giving up; opening $TERMINAL" >&2
        command -v notify-send >/dev/null && \
            notify-send "TuringOS" "$1 keeps crashing. Opened a terminal instead." 2>/dev/null
        exec "$TERMINAL"
    fi
    sleep "$DELAY"
done
