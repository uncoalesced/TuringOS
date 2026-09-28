#!/usr/bin/env bash
# game/gamemode.sh — TuringOS Game Mode
#
# Deprioritizes agent/build processes when a game is detected or manually
# triggered. Uses renice + ionice to yield CPU/IO to interactive apps.
# Does NOT touch the kernel scheduler — it orchestrates what Debian already has.
#
# Depends on: core/config.sh, core/logging.sh, core/ui.sh

log::set_module "game"

# ─── Constants ────────────────────────────────────────────────────────────────

GAME_STATE_KEY="game_mode"
GAME_PIDS_FILE="${TURINGOS_DATA_DIR}/game_deprioritized.pids"

# Processes to deprioritize when game mode activates
BACKGROUND_PROCESS_PATTERNS=(
    "claude"
    "ollama"
    "node"         # covers npm builds, MCP servers
    "python"       # covers pip-based agents
    "cargo"        # rust builds
    "make"
    "ninja"
    "webpack"
    "tsc"          # typescript compiler
)

# Known game launchers / executables to detect
GAME_LAUNCHER_PATTERNS=(
    "steam"
    "lutris"
    "heroic"
    "wine"
    "proton"
    "gamescope"
    "mangohud"
)

# ─── Enable Game Mode ─────────────────────────────────────────────────────────

gamemode::on() {
    if [[ "$(config::state_get "$GAME_STATE_KEY")" == "on" ]]; then
        ui::warn "Game Mode is already active"
        gamemode::status
        return 0
    fi

    ui::header "Game Mode"
    ui::info "Scanning for background processes..."
    echo ""

    local deprioritized=()
    local renice_level="${TURINGOS_GAME_RENICE_LEVEL:-10}"

    # Find and deprioritize matching processes
    for pattern in "${BACKGROUND_PROCESS_PATTERNS[@]}"; do
        while IFS= read -r pid; do
            [[ -z "$pid" ]] && continue
            # Don't deprioritize ourselves
            [[ "$pid" == "$$" ]] && continue

            local cmd
            cmd=$(ps -p "$pid" -o comm= 2>/dev/null | tr -d ' ')
            [[ -z "$cmd" ]] && continue

            # renice: raise nice value (lower priority)
            renice -n "$renice_level" -p "$pid" &>/dev/null || true

            # ionice: set to idle I/O class
            if command -v ionice &>/dev/null; then
                ionice -c 3 -p "$pid" &>/dev/null || true
            fi

            deprioritized+=("$pid:$cmd")
            log::info "deprioritized pid=${pid} cmd=${cmd} nice=+${renice_level}"

        done < <(pgrep -f "$pattern" 2>/dev/null)
    done

    # Save list of deprioritized PIDs for restore on game::off
    printf '%s\n' "${deprioritized[@]}" > "$GAME_PIDS_FILE"

    config::state_set "$GAME_STATE_KEY" "on"
    log::audit GAME_MODE_ON "deprioritized=${#deprioritized[@]}"

    # Display result
    gamemode::_display_active "${deprioritized[@]}"
}

# ─── Disable Game Mode ────────────────────────────────────────────────────────

gamemode::off() {
    if [[ "$(config::state_get "$GAME_STATE_KEY")" != "on" ]]; then
        ui::info "Game Mode is not active"
        return 0
    fi

    ui::info "Restoring process priorities..."

    local restored=0

    if [[ -f "$GAME_PIDS_FILE" ]]; then
        while IFS=: read -r pid cmd; do
            [[ -z "$pid" ]] && continue
            if kill -0 "$pid" 2>/dev/null; then
                # Restore to default nice value (0)
                renice -n 0 -p "$pid" &>/dev/null || true
                # Restore to best-effort I/O
                if command -v ionice &>/dev/null; then
                    ionice -c 2 -n 4 -p "$pid" &>/dev/null || true
                fi
                (( restored++ ))
                log::info "restored pid=${pid} cmd=${cmd}"
            fi
        done < "$GAME_PIDS_FILE"
        rm -f "$GAME_PIDS_FILE"
    fi

    config::state_set "$GAME_STATE_KEY" "off"
    log::audit GAME_MODE_OFF "restored=${restored}"

    echo ""
    ui::ok  "Game Mode deactivated"
    ui::ok  "Restored priorities for ${restored} process(es)"
    echo ""
}

# ─── Auto-Detect Game Launch ──────────────────────────────────────────────────

gamemode::watch() {
    # Polls for game launcher processes and auto-enables/disables game mode
    # Intended to run in background: turingos game watch &
    ui::info "Game Mode watcher started (PID $$)"
    log::info "game watcher started"

    local was_gaming=false

    while true; do
        local game_detected=false

        for pattern in "${GAME_LAUNCHER_PATTERNS[@]}"; do
            if pgrep -f "$pattern" &>/dev/null; then
                game_detected=true
                break
            fi
        done

        if $game_detected && ! $was_gaming; then
            log::info "game detected — activating game mode"
            gamemode::on
            was_gaming=true

        elif ! $game_detected && $was_gaming; then
            log::info "game exited — deactivating game mode"
            gamemode::off
            was_gaming=false
        fi

        sleep 5
    done
}

# ─── Status ───────────────────────────────────────────────────────────────────

gamemode::status() {
    local state
    state=$(config::state_get "$GAME_STATE_KEY")
    state="${state:-off}"

    ui::header "Game Mode Status"

    if [[ "$state" == "on" ]]; then
        ui::status_row "Game Mode"   "ACTIVE" "ok"
    else
        ui::status_row "Game Mode"   "inactive" "warn"
    fi

    echo ""

    # Show currently running game launchers
    local games_running=()
    for pattern in "${GAME_LAUNCHER_PATTERNS[@]}"; do
        if pgrep -f "$pattern" &>/dev/null; then
            games_running+=("$pattern")
        fi
    done

    if [[ ${#games_running[@]} -gt 0 ]]; then
        ui::status_row "Game detected" "${games_running[*]}" "ok"
    else
        ui::status_row "Game detected" "none" "warn"
    fi

    echo ""

    # Show current priority of known background processes
    ui::info "Background process priorities:"
    echo ""

    for pattern in "${BACKGROUND_PROCESS_PATTERNS[@]}"; do
        while IFS= read -r pid; do
            [[ -z "$pid" ]] && continue
            local cmd nice_val
            cmd=$(ps -p "$pid" -o comm= 2>/dev/null | tr -d ' ')
            nice_val=$(ps -p "$pid" -o nice= 2>/dev/null | tr -d ' ')
            [[ -z "$cmd" ]] && continue

            local priority_label priority_state
            if [[ -n "$nice_val" ]] && (( nice_val >= 10 )); then
                priority_label="LOW (nice ${nice_val})"
                priority_state="warn"
            else
                priority_label="NORMAL (nice ${nice_val:-0})"
                priority_state="ok"
            fi

            ui::status_row "  ${cmd} [${pid}]" "$priority_label" "$priority_state"
        done < <(pgrep -f "$pattern" 2>/dev/null | head -3)
    done

    echo ""

    # Interactive apps (just check responsiveness proxy via load avg)
    local load
    load=$(uptime | grep -oP 'load average[s]?: \K[\d., ]+' | awk '{print $1}' | tr -d ',')
    [[ -z "$load" ]] && load="?"
    ui::label "System load (1m)" "$load"
    echo ""
}

# ─── Display Helper ───────────────────────────────────────────────────────────

gamemode::_display_active() {
    local entries=("$@")

    echo ""
    printf "  \033[1;32m╭────────────────────────────────────────╮\033[0m\n"
    printf "  \033[1;32m│\033[0m       \033[1;37mTURINGOS GAME MODE\033[0m              \033[1;32m│\033[0m\n"
    printf "  \033[1;32m├────────────────────────────────────────┤\033[0m\n"

    if [[ ${#entries[@]} -eq 0 ]]; then
        printf "  \033[1;32m│\033[0m  \033[2mNo background processes found\033[0m         \033[1;32m│\033[0m\n"
    else
        for entry in "${entries[@]}"; do
            local pid cmd
            IFS=: read -r pid cmd <<< "$entry"
            printf "  \033[1;32m│\033[0m  %-28s  \033[0;33mLOW\033[0m     \033[1;32m│\033[0m\n" "${cmd} [${pid}]"
        done
    fi

    printf "  \033[1;32m├────────────────────────────────────────┤\033[0m\n"
    printf "  \033[1;32m│\033[0m  Interactive apps        \033[1;32mPRIORITY\033[0m       \033[1;32m│\033[0m\n"
    printf "  \033[1;32m│\033[0m                                        \033[1;32m│\033[0m\n"
    printf "  \033[1;32m│\033[0m  \033[1;37m🎮 GAME MODE ACTIVE\033[0m                   \033[1;32m│\033[0m\n"
    printf "  \033[1;32m╰────────────────────────────────────────╯\033[0m\n"
    echo ""
    ui::info "Agents continue running in background"
    ui::info "Disable with: turingos game off"
    echo ""
}
