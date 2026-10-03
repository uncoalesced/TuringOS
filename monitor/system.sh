#!/usr/bin/env bash
# monitor/system.sh — TuringOS System Monitor / HUD
#
# One-shot or live dashboard: agent, sandbox, GPU/VRAM, CPU, RAM, game mode
# and MCP servers. Also the API spend summary.
#
# Depends on: core/config.sh, core/logging.sh, core/ui.sh, agent/claude.sh

# ─── Single Snapshot ──────────────────────────────────────────────────────────

monitor::snapshot() {
    # Collect all metrics into the global METRICS array
    declare -gA METRICS=()
    local l1 _rest mem_total mem_available mem_used

    read -r l1 _rest < /proc/loadavg
    METRICS[cpu_load_1]="$l1"
    METRICS[cpu_cores]=$(nproc)

    mem_total=$(awk '/^MemTotal:/ {print $2}' /proc/meminfo)
    mem_available=$(awk '/^MemAvailable:/ {print $2}' /proc/meminfo)
    mem_used=$(( mem_total - mem_available ))
    METRICS[ram_total_mb]=$(( mem_total / 1024 ))
    METRICS[ram_used_mb]=$(( mem_used / 1024 ))

    monitor::_gpu

    local agent_pid
    agent_pid=$(config::pid_read "$AGENT_PID_NAME")
    if config::pid_alive "$AGENT_PID_NAME"; then
        METRICS[agent_status]="running"
        METRICS[agent_pid]="$agent_pid"
        METRICS[agent_cpu]=$(ps -p "$agent_pid" -o %cpu= 2>/dev/null | tr -d ' ')
        METRICS[agent_mem]=$(ps -p "$agent_pid" -o %mem= 2>/dev/null | tr -d ' ')
        METRICS[agent_task]=$(config::state_get "$STATE_KEY_AGENT_TASK")
    else
        METRICS[agent_status]="idle"
    fi

    local sandbox_path
    sandbox_path=$(config::state_get "$STATE_KEY_ACTIVE_SANDBOX")
    if [[ -n "$sandbox_path" && -d "$sandbox_path" ]]; then
        METRICS[sandbox_status]="active"
        METRICS[sandbox_name]="$(basename "$sandbox_path")"
        METRICS[sandbox_size]=$(du -sh "$sandbox_path" 2>/dev/null | cut -f1)
    else
        METRICS[sandbox_status]="none"
    fi

    METRICS[game_mode]=$(config::state_get "$STATE_KEY_GAME_MODE")
    METRICS[mcp_count]=0
    if [[ -f "$CLAUDE_CODE_CONFIG" ]]; then
        METRICS[mcp_count]=$(jq '.mcpServers // {} | length' "$CLAUDE_CODE_CONFIG" 2>/dev/null || echo 0)
    fi
    METRICS[timestamp]=$(date '+%H:%M:%S')
}

monitor::_gpu() {
    local line name util used total temp
    METRICS[gpu_backend]="none"
    if command -v nvidia-smi &>/dev/null; then
        line=$(nvidia-smi --query-gpu=name,utilization.gpu,memory.used,memory.total,temperature.gpu \
            --format=csv,noheader,nounits 2>/dev/null | head -1) || true
        [[ -n "$line" ]] || return 0
        IFS=',' read -r name util used total temp <<< "$line"
        METRICS[gpu_backend]="nvidia"
    elif command -v rocm-smi &>/dev/null; then
        name="AMD GPU"
        used=$(rocm-smi --showmemuse 2>/dev/null | awk '/GPU/ {print $NF}' | head -1) || true
        total=$(rocm-smi --showmeminfo vram 2>/dev/null | awk '/Total/ {print $NF}' | head -1) || true
        util=$(rocm-smi --showuse 2>/dev/null | awk '/GPU/ {print $NF}' | head -1) || true
        temp=$(rocm-smi --showtemp 2>/dev/null | awk '/GPU/ {print $NF}' | head -1) || true
        METRICS[gpu_backend]="rocm"
    else
        return 0
    fi
    # Trim the spaces nvidia-smi puts after each comma
    METRICS[gpu_name]="${name# }"
    METRICS[gpu_util]="${util// /}"
    METRICS[vram_used]="${used// /}"
    METRICS[vram_total]="${total// /}"
    METRICS[gpu_temp]="${temp// /}"
}

# ─── Render Dashboard ─────────────────────────────────────────────────────────

monitor::_rule() {
    printf '  %b%s%s%s%b\n' "$BOLD_CYAN" "$1" "$(ui::_line '─' 46)" "$2" "$RESET"
}

monitor::_row() {
    # Usage: monitor::_row LABEL VALUE — VALUE may contain ANSI colors
    # Widths in characters, not bytes (printf %-Ns pads bytes, so icons
    # like ◈ broke the border), whatever the caller's locale
    local LC_ALL=C.UTF-8 value plain pad lpad
    value=$(echo -e "$2")
    # shellcheck disable=SC2001  # a regex, which ${var//} can't express
    plain=$(sed 's/\x1b\[[0-9;]*m//g' <<< "$value")
    pad=$(( 24 - ${#plain} ))
    lpad=$(( 18 - ${#1} ))
    (( pad < 0 )) && pad=0
    (( lpad < 0 )) && lpad=0
    printf '  %b│%b  %b%s%*s%b  %s%*s%b│%b\n' "$BOLD_CYAN" "$RESET" "$DIM" "$1" "$lpad" '' "$RESET" \
        "$value" "$pad" '' "$BOLD_CYAN" "$RESET"
}

monitor::_bar() {
    # Usage: monitor::_bar USED TOTAL [WIDTH]
    local used="$1" total="$2" width="${3:-16}"
    if ! [[ "$used" =~ ^[0-9]+$ && "$total" =~ ^[0-9]+$ ]] || (( total == 0 )); then
        printf '[%-*s]' "$width" "?"
        return 0
    fi
    local filled=$(( used * width / total ))
    (( filled > width )) && filled=$width
    local pct=$(( used * 100 / total )) color="\033[1;32m"
    (( pct >= 70 )) && color="\033[1;33m"
    (( pct >= 90 )) && color="\033[1;31m"
    printf '[%b%s\033[2m%s\033[0m]' "$color" "$(ui::_line '█' "$filled")" "$(ui::_line '░' $(( width - filled )))"
}

monitor::render() {
    monitor::snapshot

    echo ""
    monitor::_rule '╭' '╮'
    monitor::_row "TuringOS HUD" "${METRICS[timestamp]}"
    monitor::_rule '├' '┤'

    if [[ "${METRICS[agent_status]}" == "running" ]]; then
        local task="${METRICS[agent_task]:-working...}"
        (( ${#task} > 24 )) && task="${task:0:21}..."
        monitor::_row "◈ Agent" "\033[1;32mRUNNING\033[0m PID ${METRICS[agent_pid]}"
        monitor::_row "  Task" "$task"
        monitor::_row "  CPU / RAM" "${METRICS[agent_cpu]:-?}% / ${METRICS[agent_mem]:-?}%"
    else
        monitor::_row "◈ Agent" "\033[2midle\033[0m"
    fi
    monitor::_rule '├' '┤'

    if [[ "${METRICS[sandbox_status]}" == "active" ]]; then
        local sb_name="${METRICS[sandbox_name]}"
        (( ${#sb_name} > 24 )) && sb_name="${sb_name:0:21}..."
        monitor::_row "⬡ Sandbox" "\033[1;32mACTIVE\033[0m ${METRICS[sandbox_size]:-?}"
        monitor::_row "  Name" "$sb_name"
    else
        monitor::_row "⬡ Sandbox" "\033[2mnone\033[0m"
    fi
    monitor::_rule '├' '┤'

    if [[ "${METRICS[gpu_backend]}" != "none" ]]; then
        local gpu_label="${METRICS[gpu_name]}"
        (( ${#gpu_label} > 24 )) && gpu_label="${gpu_label:0:21}..."
        monitor::_row "GPU" "$gpu_label"
        monitor::_row "  VRAM" "$(monitor::_bar "${METRICS[vram_used]}" "${METRICS[vram_total]}") ${METRICS[vram_used]}MB"
        [[ -n "${METRICS[gpu_util]}" ]] && monitor::_row "  Utilisation" "${METRICS[gpu_util]}%"
        [[ -n "${METRICS[gpu_temp]}" ]] && monitor::_row "  Temp" "${METRICS[gpu_temp]}°C"
    else
        monitor::_row "GPU" "\033[2mnot detected\033[0m"
    fi
    monitor::_rule '├' '┤'

    monitor::_row "CPU" "load ${METRICS[cpu_load_1]} (${METRICS[cpu_cores]} cores)"
    monitor::_row "RAM" "$(monitor::_bar "${METRICS[ram_used_mb]}" "${METRICS[ram_total_mb]}") ${METRICS[ram_used_mb]}MB"
    monitor::_rule '├' '┤'

    if [[ "${METRICS[game_mode]}" == "on" ]]; then
        monitor::_row "Game Mode" "\033[1;32mON\033[0m"
    else
        monitor::_row "Game Mode" "\033[2moff\033[0m"
    fi
    monitor::_row "MCP Servers" "${METRICS[mcp_count]} configured"
    monitor::_rule '╰' '╯'
    echo ""
}

# ─── Live Watch Mode ──────────────────────────────────────────────────────────

monitor::watch() {
    # Refresh the dashboard every N seconds until Ctrl+C
    local interval="${1:-3}"
    tput civis 2>/dev/null || true
    trap 'tput cnorm 2>/dev/null; echo ""; exit 0' INT TERM
    while true; do
        tput clear 2>/dev/null || printf '\033[2J\033[H'
        monitor::render
        printf '  \033[2mRefreshing every %ss — Ctrl+C to exit\033[0m\n' "$interval"
        sleep "$interval"
    done
}

monitor::status() {
    monitor::render
}

# ─── Token / Spend HUD ───────────────────────────────────────────────────────

monitor::spend() {
    # Sums token usage from Claude agent logs (stream-json usage lines)
    ui::header "API Spend HUD"

    local total_input=0 total_output=0 session_count=0 logfile input output
    for logfile in "${TURINGOS_LOG_DIR}/${AGENT_LOG_NAME}-"*.log; do
        [[ -f "$logfile" ]] || continue
        session_count=$(( session_count + 1 ))
        input=$(grep -oE '"input_tokens":[0-9]+' "$logfile" | tail -1 | cut -d: -f2) || true
        output=$(grep -oE '"output_tokens":[0-9]+' "$logfile" | tail -1 | cut -d: -f2) || true
        total_input=$(( total_input + ${input:-0} ))
        total_output=$(( total_output + ${output:-0} ))
    done

    local total_tokens=$(( total_input + total_output ))
    ui::label "Sessions logged" "$session_count"
    ui::label "Input tokens"    "$total_input"
    ui::label "Output tokens"   "$total_output"
    ui::label "Total tokens"    "$total_tokens"
    echo ""

    if (( total_tokens > 0 )); then
        # Rough estimate at $3 / $15 per million input / output tokens
        ui::label "Est. cost" "$(awk -v i="$total_input" -v o="$total_output" \
            'BEGIN { printf "$%.4f", i / 1e6 * 3 + o / 1e6 * 15 }')"
        ui::info "Estimate at \$3/\$15 per MTok — check current pricing at anthropic.com/pricing"
    fi
    echo ""
}
