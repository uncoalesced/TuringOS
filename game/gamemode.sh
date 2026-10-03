#!/usr/bin/env bash
# game/gamemode.sh — TuringOS Game Mode
#
# Deprioritizes agent/build processes when a game is detected or manually
# triggered. Uses renice + ionice to yield CPU/IO to interactive apps.
# Does NOT touch the kernel scheduler — it orchestrates what Debian already has.
#
# Depends on: core/config.sh, core/logging.sh, core/ui.sh

GAME_PIDS_FILE="${TURINGOS_DATA_DIR}/game_deprioritized.pids"

# Exact process names (pgrep -x) to deprioritize when game mode activates
BACKGROUND_PROCESSES=(claude opencode ollama node python3 cargo rustc make ninja)

# Exact process names of game launchers / runtimes
GAME_PROCESSES=(steam lutris heroic wine wine64-preloader wineserver gamescope)

# ─── Helpers ──────────────────────────────────────────────────────────────────

gamemode::_pids() {
    # Usage: gamemode::_pids NAME... — matching PIDs, minus this shell and its parent
    local name pid
    for name in "$@"; do
        while IFS= read -r pid; do
            [[ "$pid" == "$$" || "$pid" == "$PPID" ]] || echo "$pid"
        done < <(pgrep -x "$name" 2>/dev/null || true)
    done
}

gamemode::_game_running() {
    local name
    for name in "${GAME_PROCESSES[@]}"; do
        pgrep -x "$name" &>/dev/null && return 0
    done
    return 1
}

# ─── Enable Game Mode ─────────────────────────────────────────────────────────

gamemode::on() {
    if [[ "$(config::state_get "$STATE_KEY_GAME_MODE")" == "on" ]]; then
        ui::warn "Game Mode is already active"
        gamemode::status
        return 0
    fi

    ui::header "Game Mode"
    ui::info "Scanning for background processes..."

    local level="$TURINGOS_GAME_RENICE_LEVEL" pid cmd nice_val entries=()
    : > "$GAME_PIDS_FILE"
    while IFS= read -r pid; do
        cmd=$(ps -p "$pid" -o comm= 2>/dev/null) || continue
        nice_val=$(ps -p "$pid" -o nice= 2>/dev/null | tr -d ' ')
        # Only processes we can renice (own processes, or via passwordless sudo)
        renice -n "$level" -p "$pid" &>/dev/null || sudo -n renice -n "$level" -p "$pid" &>/dev/null || continue
        ionice -c 3 -p "$pid" &>/dev/null || true
        # Remember the original nice value so `game off` can put it back
        echo "${pid}:${cmd}:${nice_val:-0}" >> "$GAME_PIDS_FILE"
        entries+=("${cmd} [${pid}]  -> LOW")
        log::info "deprioritized pid=${pid} cmd=${cmd} nice=${nice_val:-0}->${level}"
    done < <(gamemode::_pids "${BACKGROUND_PROCESSES[@]}")

    config::state_set "$STATE_KEY_GAME_MODE" "on"
    log::audit GAME_MODE_ON "deprioritized=${#entries[@]}"

    (( ${#entries[@]} )) || entries=("No background processes found")
    ui::box "$BOLD_GREEN" "TURINGOS GAME MODE" "${entries[@]}" "" "Interactive apps have priority"
    ui::info "Agents continue running in background"
    ui::info "Disable with: turingos game off"
    echo ""
}

# ─── Disable Game Mode ────────────────────────────────────────────────────────

gamemode::off() {
    if [[ "$(config::state_get "$STATE_KEY_GAME_MODE")" != "on" ]]; then
        ui::info "Game Mode is not active"
        return 0
    fi

    ui::info "Restoring process priorities..."
    local restored=0 skipped=0 pid cmd nice_val
    if [[ -f "$GAME_PIDS_FILE" ]]; then
        while IFS=: read -r pid cmd nice_val; do
            if [[ -z "$pid" ]] || ! kill -0 "$pid" 2>/dev/null; then
                continue
            fi
            # Lowering nice needs privileges: try plain, then passwordless sudo
            if renice -n "${nice_val:-0}" -p "$pid" &>/dev/null \
                || sudo -n renice -n "${nice_val:-0}" -p "$pid" &>/dev/null; then
                ionice -c 2 -n 4 -p "$pid" &>/dev/null || true
                restored=$(( restored + 1 ))
                log::info "restored pid=${pid} cmd=${cmd} nice=${nice_val:-0}"
            else
                skipped=$(( skipped + 1 ))
                log::warn "could not restore pid=${pid} cmd=${cmd} (needs root)"
            fi
        done < "$GAME_PIDS_FILE"
        rm -f "$GAME_PIDS_FILE"
    fi

    config::state_set "$STATE_KEY_GAME_MODE" "off"
    log::audit GAME_MODE_OFF "restored=${restored}" "skipped=${skipped}"

    echo ""
    ui::ok "Game Mode deactivated"
    ui::ok "Restored priorities for ${restored} process(es)"
    (( skipped == 0 )) || ui::warn "${skipped} process(es) keep low priority until they restart (restoring needs root)"
    echo ""
}

# ─── Auto-Detect Game Launch ──────────────────────────────────────────────────

gamemode::watch() {
    # Polls for game processes and toggles game mode. Run in background:
    #   turingos game watch &
    ui::info "Game Mode watcher started (PID $$)"
    log::info "game watcher started"

    local was_gaming=false
    while true; do
        if gamemode::_game_running; then
            if ! $was_gaming; then
                log::info "game detected — activating game mode"
                gamemode::on
                was_gaming=true
            fi
        elif $was_gaming; then
            log::info "game exited — deactivating game mode"
            gamemode::off
            was_gaming=false
        fi
        sleep 5
    done
}

# ─── Status ───────────────────────────────────────────────────────────────────

gamemode::status() {
    ui::header "Game Mode Status"

    if [[ "$(config::state_get "$STATE_KEY_GAME_MODE")" == "on" ]]; then
        ui::status_row "Game Mode" "ACTIVE" "ok"
    else
        ui::status_row "Game Mode" "inactive" "warn"
    fi

    local name games=()
    for name in "${GAME_PROCESSES[@]}"; do
        if pgrep -x "$name" &>/dev/null; then
            games+=("$name")
        fi
    done
    if (( ${#games[@]} )); then
        ui::status_row "Game detected" "${games[*]}" "ok"
    else
        ui::status_row "Game detected" "none" "warn"
    fi
    echo ""

    ui::info "Background process priorities:"
    echo ""
    local pid cmd nice_val
    while IFS= read -r pid; do
        cmd=$(ps -p "$pid" -o comm= 2>/dev/null) || continue
        nice_val=$(ps -p "$pid" -o nice= 2>/dev/null | tr -d ' ')
        if (( ${nice_val:-0} >= 10 )); then
            ui::status_row "  ${cmd} [${pid}]" "LOW (nice ${nice_val})" "warn"
        else
            ui::status_row "  ${cmd} [${pid}]" "NORMAL (nice ${nice_val:-0})" "ok"
        fi
    done < <(gamemode::_pids "${BACKGROUND_PROCESSES[@]}" | head -12)
    echo ""

    local load _rest
    read -r load _rest < /proc/loadavg
    ui::label "System load (1m)" "$load"
    echo ""
}
