#!/usr/bin/env bash
# monitor/system.sh — TuringOS System Monitor / HUD
#
# Displays a live dashboard: GPU VRAM, CPU load, RAM, active agent, sandbox,
# game mode state, and MCP connections. Refreshes in-place like htop.
#
# Depends on: core/config.sh, core/logging.sh, core/ui.sh

log::set_module "monitor"

# ─── Single Snapshot ──────────────────────────────────────────────────────────

monitor::snapshot() {
    # Collect all metrics into associative array
    declare -gA METRICS

    # ── CPU ──────────────────────────────────────────────────────────────────
    # Load averages from /proc/loadavg or uptime
    if [[ -f /proc/loadavg ]]; then
        read -r l1 l5 l15 _ _ < /proc/loadavg
        METRICS[cpu_load_1]="$l1"
        METRICS[cpu_load_5]="$l5"
        METRICS[cpu_load_15]="$l15"
    else
        local uptime_out
        uptime_out=$(uptime 2>/dev/null)
        METRICS[cpu_load_1]=$(echo "$uptime_out"  | grep -oP '[\d.]+(?=,)'  | head -1)
        METRICS[cpu_load_5]=$(echo "$uptime_out"  | grep -oP '[\d.]+' | tail -2 | head -1)
        METRICS[cpu_load_15]=$(echo "$uptime_out" | grep -oP '[\d.]+' | tail -1)
    fi

    # CPU core count
    local cpu_cores
    cpu_cores=$(nproc 2>/dev/null || sysctl -n hw.ncpu 2>/dev/null || echo "?")
    METRICS[cpu_cores]="$cpu_cores"

    # ── RAM ───────────────────────────────────────────────────────────────────
    if [[ -f /proc/meminfo ]]; then
        local mem_total mem_available mem_used
        mem_total=$(     awk '/^MemTotal:/     {print $2}' /proc/meminfo)
        mem_available=$( awk '/^MemAvailable:/ {print $2}' /proc/meminfo)
        mem_used=$(( mem_total - mem_available ))
        METRICS[ram_total_mb]=$(( mem_total     / 1024 ))
        METRICS[ram_used_mb]=$( ( mem_used      / 1024 ))
        METRICS[ram_free_mb]=$( ( mem_available / 1024 ))
        METRICS[ram_pct]=$(awk "BEGIN {printf \"%.0f\", (${mem_used}/${mem_total})*100}")
    else
        # macOS fallback via vm_stat
        local page_size pages_free pages_active pages_inactive pages_wired
        page_size=$(   pagesize 2>/dev/null || echo 4096)
        pages_free=$(  vm_stat 2>/dev/null | awk '/Pages free/     {gsub(/\./,"",$3); print $3}')
        pages_active=$(vm_stat 2>/dev/null | awk '/Pages active/   {gsub(/\./,"",$3); print $3}')
        pages_wired=$( vm_stat 2>/dev/null | awk '/Pages wired/    {gsub(/\./,"",$4); print $4}')
        local used_bytes=$(( (${pages_active:-0} + ${pages_wired:-0}) * page_size ))
        local free_bytes=$( (( ${pages_free:-0}  * page_size )) )
        METRICS[ram_used_mb]=$(( used_bytes / 1024 / 1024 ))
        METRICS[ram_free_mb]=$(( free_bytes / 1024 / 1024 ))
        METRICS[ram_total_mb]="?"
        METRICS[ram_pct]="?"
    fi

    # ── GPU / VRAM ────────────────────────────────────────────────────────────
    if command -v nvidia-smi &>/dev/null; then
        local gpu_line
        gpu_line=$(nvidia-smi \
            --query-gpu=name,utilization.gpu,memory.used,memory.total,temperature.gpu \
            --format=csv,noheader,nounits 2>/dev/null | head -1)

        if [[ -n "$gpu_line" ]]; then
            IFS=',' read -r gpu_name gpu_util vram_used vram_total gpu_temp <<< "$gpu_line"
            METRICS[gpu_name]=$(   echo "$gpu_name"  | xargs)
            METRICS[gpu_util]=$(   echo "$gpu_util"  | xargs)
            METRICS[vram_used]=$(  echo "$vram_used" | xargs)
            METRICS[vram_total]=$( echo "$vram_total"| xargs)
            METRICS[gpu_temp]=$(   echo "$gpu_temp"  | xargs)
            METRICS[gpu_backend]="nvidia"
        fi
    elif command -v rocm-smi &>/dev/null; then
        # AMD GPU via ROCm
        local vram_used vram_total gpu_util gpu_temp
        vram_used=$(  rocm-smi --showmemuse 2>/dev/null | awk '/GPU/{print $NF}' | head -1)
        vram_total=$( rocm-smi --showmeminfo vram 2>/dev/null | awk '/Total/{print $NF}' | head -1)
        gpu_util=$(   rocm-smi --showuse    2>/dev/null | awk '/GPU/{print $NF}' | head -1)
        gpu_temp=$(   rocm-smi --showtemp   2>/dev/null | awk '/GPU/{print $NF}' | head -1)
        METRICS[gpu_name]="AMD GPU"
        METRICS[gpu_util]="${gpu_util:-?}"
        METRICS[vram_used]="${vram_used:-?}"
        METRICS[vram_total]="${vram_total:-?}"
        METRICS[gpu_temp]="${gpu_temp:-?}"
        METRICS[gpu_backend]="rocm"
    else
        METRICS[gpu_backend]="none"
        METRICS[gpu_name]="N/A"
    fi

    # ── Agent ─────────────────────────────────────────────────────────────────
    local agent_pid
    agent_pid=$(config::pid_read "claude")
    if [[ -n "$agent_pid" ]] && kill -0 "$agent_pid" 2>/dev/null; then
        METRICS[agent_status]="running"
        METRICS[agent_pid]="$agent_pid"
        METRICS[agent_cpu]=$(ps -p "$agent_pid" -o %cpu= 2>/dev/null | tr -d ' ')
        METRICS[agent_mem]=$(ps -p "$agent_pid" -o %mem= 2>/dev/null | tr -d ' ')
        METRICS[agent_task]=$(config::state_get "$STATE_KEY_AGENT_TASK")
    else
        METRICS[agent_status]="idle"
        METRICS[agent_pid]=""
    fi

    # ── Sandbox ───────────────────────────────────────────────────────────────
    local sandbox_path
    sandbox_path=$(config::state_get "$STATE_KEY_ACTIVE_SANDBOX")
    if [[ -n "$sandbox_path" && -d "$sandbox_path" ]]; then
        METRICS[sandbox_status]="active"
        METRICS[sandbox_name]="$(basename "$sandbox_path")"
        # Size on disk
        local sb_size
        sb_size=$(du -sh "$sandbox_path" 2>/dev/null | awk '{print $1}')
        METRICS[sandbox_size]="${sb_size:-?}"
    else
        METRICS[sandbox_status]="none"
    fi

    # ── Game Mode ─────────────────────────────────────────────────────────────
    METRICS[game_mode]=$(config::state_get "game_mode")
    METRICS[game_mode]="${METRICS[game_mode]:-off}"

    # ── MCP Servers ───────────────────────────────────────────────────────────
    local mcp_count=0
    if [[ -f "$CLAUDE_DESKTOP_CONFIG" ]] && command -v jq &>/dev/null; then
        mcp_count=$(jq '.mcpServers | length' "$CLAUDE_DESKTOP_CONFIG" 2>/dev/null || echo 0)
    fi
    METRICS[mcp_count]="$mcp_count"

    # ── Timestamp ─────────────────────────────────────────────────────────────
    METRICS[timestamp]=$(date '+%H:%M:%S')
}

# ─── Render Dashboard ─────────────────────────────────────────────────────────

monitor::render() {
    monitor::snapshot

    local W=46  # box inner width
    local line
    line=$(printf '─%.0s' $(seq 1 $W))

    echo ""
    printf "  \033[1;36m╭%s╮\033[0m\n" "$line"
    printf "  \033[1;36m│\033[0m  \033[1;37m%-${W}s\033[1;36m│\033[0m\n" \
        "TuringOS · System HUD · ${METRICS[timestamp]}"
    printf "  \033[1;36m├%s┤\033[0m\n" "$line"

    # ── Agent block ──────────────────────────────────────────────────────────
    if [[ "${METRICS[agent_status]}" == "running" ]]; then
        monitor::_row "◈ Agent" "\033[1;32mRUNNING\033[0m  PID ${METRICS[agent_pid]}"
        local task="${METRICS[agent_task]:-working...}"
        [[ ${#task} -gt 36 ]] && task="${task:0:33}..."
        monitor::_row "  Task" "$task"
        monitor::_row "  CPU / RAM" "${METRICS[agent_cpu]:-?}%  /  ${METRICS[agent_mem]:-?}%"
    else
        monitor::_row "◈ Agent" "\033[2midle\033[0m"
    fi

    printf "  \033[1;36m├%s┤\033[0m\n" "$line"

    # ── Sandbox block ─────────────────────────────────────────────────────────
    if [[ "${METRICS[sandbox_status]}" == "active" ]]; then
        monitor::_row "⬡ Sandbox" "\033[1;32mACTIVE\033[0m  ${METRICS[sandbox_size]}"
        local sb_name="${METRICS[sandbox_name]}"
        [[ ${#sb_name} -gt 38 ]] && sb_name="${sb_name:0:35}..."
        monitor::_row "  Name" "$sb_name"
    else
        monitor::_row "⬡ Sandbox" "\033[2mnone\033[0m"
    fi

    printf "  \033[1;36m├%s┤\033[0m\n" "$line"

    # ── GPU block ─────────────────────────────────────────────────────────────
    if [[ "${METRICS[gpu_backend]}" != "none" ]]; then
        local gpu_label="${METRICS[gpu_name]}"
        [[ ${#gpu_label} -gt 30 ]] && gpu_label="${gpu_label:0:27}..."
        monitor::_row "GPU" "$gpu_label"

        if [[ -n "${METRICS[vram_used]}" ]]; then
            local vram_bar
            vram_bar=$(monitor::_bar "${METRICS[vram_used]}" "${METRICS[vram_total]}" 16)
            monitor::_row "  VRAM" "${METRICS[vram_used]}/${METRICS[vram_total]} MB  ${vram_bar}"
        fi

        [[ -n "${METRICS[gpu_util]}"  ]] && monitor::_row "  Utilisation" "${METRICS[gpu_util]}%"
        [[ -n "${METRICS[gpu_temp]}"  ]] && monitor::_row "  Temp"        "${METRICS[gpu_temp]}°C"
    else
        monitor::_row "GPU" "\033[2mnot detected\033[0m"
    fi

    printf "  \033[1;36m├%s┤\033[0m\n" "$line"

    # ── CPU / RAM block ───────────────────────────────────────────────────────
    monitor::_row "CPU" "load ${METRICS[cpu_load_1]:-?}  (${METRICS[cpu_cores]:-?} cores)"

    local ram_bar
    if [[ "${METRICS[ram_pct]}" != "?" && -n "${METRICS[ram_pct]}" ]]; then
        ram_bar=$(monitor::_bar "${METRICS[ram_used_mb]}" "${METRICS[ram_total_mb]}" 16)
        monitor::_row "RAM" "${METRICS[ram_used_mb]}/${METRICS[ram_total_mb]} MB  ${ram_bar}"
    else
        monitor::_row "RAM" "${METRICS[ram_used_mb]:-?} MB used"
    fi

    printf "  \033[1;36m├%s┤\033[0m\n" "$line"

    # ── Game / MCP row ────────────────────────────────────────────────────────
    local game_label
    if [[ "${METRICS[game_mode]}" == "on" ]]; then
        game_label="\033[1;32m🎮 ON\033[0m"
    else
        game_label="\033[2moff\033[0m"
    fi
    monitor::_row "Game Mode" "$game_label"
    monitor::_row "MCP Servers" "${METRICS[mcp_count]} configured"

    printf "  \033[1;36m╰%s╯\033[0m\n" "$line"
    echo ""
}

monitor::_row() {
    local label="$1"
    local value="$2"
    # Strip ANSI for length calculation
    local clean_value
    clean_value=$(echo -e "$value" | sed 's/\x1b\[[0-9;]*m//g')
    printf "  \033[1;36m│\033[0m  \033[2m%-18s\033[0m  %-24b\033[1;36m│\033[0m\n" \
        "$label" "$value"
}

monitor::_bar() {
    # Usage: monitor::_bar USED TOTAL WIDTH
    local used="$1"
    local total="$2"
    local width="${3:-20}"

    # Guard against non-numeric
    if ! [[ "$used" =~ ^[0-9]+$ ]] || ! [[ "$total" =~ ^[0-9]+$ ]] || (( total == 0 )); then
        printf '[%-*s]' "$width" "?"
        return
    fi

    local filled=$(( used * width / total ))
    (( filled > width )) && filled=$width
    local empty=$(( width - filled ))

    local bar=""
    local color
    local pct=$(( used * 100 / total ))

    if   (( pct >= 90 )); then color="\033[1;31m"   # red
    elif (( pct >= 70 )); then color="\033[1;33m"   # yellow
    else                       color="\033[1;32m"   # green
    fi

    bar="${color}$(printf '█%.0s' $(seq 1 $filled))\033[2m$(printf '░%.0s' $(seq 1 $empty))\033[0m"
    printf "[%b]" "$bar"
}

# ─── Live Watch Mode ──────────────────────────────────────────────────────────

monitor::watch() {
    # Refresh dashboard every N seconds until Ctrl+C
    local interval="${1:-3}"

    # Hide cursor
    tput civis 2>/dev/null || true
    trap 'tput cnorm 2>/dev/null; echo ""; exit 0' INT TERM

    while true; do
        # Move to top of screen and overwrite
        tput clear 2>/dev/null || printf '\033[2J\033[H'
        monitor::render
        printf "  \033[2mRefreshing every ${interval}s — Ctrl+C to exit\033[0m\n"
        sleep "$interval"
    done
}

# ─── Quick Status (one-shot, no loop) ────────────────────────────────────────

monitor::status() {
    monitor::render
}

# ─── Token / Spend HUD ───────────────────────────────────────────────────────

monitor::spend() {
    # Reads token usage from agent logs and shows running total
    ui::header "API Spend HUD"

    local total_input=0
    local total_output=0
    local session_count=0

    # Scan agent session logs for JSON token usage lines
    for logfile in "${TURINGOS_LOG_DIR}"/agent-session-*.log; do
        [[ -f "$logfile" ]] || continue
        (( session_count++ ))

        local input output
        # Claude --output-format stream-json emits usage in final message
        input=$( grep -o '"input_tokens":[0-9]*'  "$logfile" 2>/dev/null | tail -1 | grep -o '[0-9]*')
        output=$(grep -o '"output_tokens":[0-9]*' "$logfile" 2>/dev/null | tail -1 | grep -o '[0-9]*')
        total_input=$(( total_input   + ${input:-0}  ))
        total_output=$(( total_output + ${output:-0} ))
    done

    local total_tokens=$(( total_input + total_output ))

    ui::label "Sessions logged"  "$session_count"
    ui::label "Input tokens"     "$total_input"
    ui::label "Output tokens"    "$total_output"
    ui::label "Total tokens"     "$total_tokens"
    echo ""

    # Rough cost estimate (Claude 3.5 Sonnet pricing as of 2025)
    # $3/MTok input, $15/MTok output
    if (( total_tokens > 0 )); then
        local cost_estimate
        cost_estimate=$(awk "BEGIN {
            i = ${total_input}  / 1000000 * 3
            o = ${total_output} / 1000000 * 15
            printf \"\$%.4f\", i + o
        }")
        ui::label "Est. cost (Sonnet)" "$cost_estimate"
        ui::info  "Pricing based on Claude 3.5 Sonnet — verify at console.anthropic.com"
    fi
    echo ""
}
