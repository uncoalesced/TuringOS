#!/usr/bin/env bash
# agent/claude.sh — TuringOS Agent Lifecycle Manager
#
# Starts Claude Code (or OpenCode, for non-Claude providers) inside a fresh
# sandbox, tracks the process group, and notifies on completion.
#
# Depends on: core/config.sh, core/logging.sh, core/ui.sh, sandbox/btrfs.sh,
#             agent/model.sh, agent/nim.sh

# ─── Constants ────────────────────────────────────────────────────────────────

AGENT_PID_NAME="claude"
AGENT_LOG_NAME="agent-session"

agent::_latest_log() {
    # Log names embed a sortable timestamp, so the last glob match is newest
    local logs=("${TURINGOS_LOG_DIR}/${AGENT_LOG_NAME}-"*.log)
    [[ -f "${logs[-1]}" ]] && echo "${logs[-1]}"
    return 0
}

# ─── Start ────────────────────────────────────────────────────────────────────

agent::start() {
    # Usage: agent::start [PROJECT_DIR] [TASK_DESCRIPTION]
    local project="${1:-$PWD}"
    local task="${2:-}"

    if [[ ! -d "$project" ]]; then
        ui::fail "Project directory not found: ${project}"
        return 1
    fi
    project="$(cd "$project" && pwd)"

    if config::pid_alive "$AGENT_PID_NAME"; then
        ui::warn "Agent already running (PID $(config::pid_read "$AGENT_PID_NAME"))"
        ui::info "Use: turingos agent status"
        return 1
    fi

    # Non-Claude providers run through OpenCode
    local agent_bin="$TURINGOS_AGENT_BINARY"
    [[ "$TURINGOS_MODEL_PROVIDER" != "claude" ]] && agent_bin="$TURINGOS_OPENCODE_BINARY"
    if ! command -v "$agent_bin" &>/dev/null; then
        ui::fail "Agent binary not found: ${agent_bin}"
        ui::info "Install it, or set TURINGOS_AGENT_BINARY / TURINGOS_OPENCODE_BINARY in ${TURINGOS_CONFIG_FILE}"
        log::error "agent binary missing: ${agent_bin}"
        return 1
    fi

    [[ -z "$task" ]] && task=$(ui::input "Describe the task for the agent" "Refactor and run tests")

    ui::header "Launching Agent"
    ui::label "Project"  "$project"
    ui::label "Task"     "$task"
    ui::label "Provider" "$TURINGOS_MODEL_PROVIDER"
    echo ""

    local sandbox_path
    if ! sandbox_path=$(sandbox::create "$project" "$task") || [[ -z "$sandbox_path" ]]; then
        ui::fail "Could not create sandbox — aborting agent start"
        return 1
    fi

    config::state_set "$STATE_KEY_AGENT_TASK" "$task"

    local agent_log
    agent_log="${TURINGOS_LOG_DIR}/${AGENT_LOG_NAME}-$(date +%Y%m%dT%H%M%S).log"
    local prompt_file="${sandbox_path}/.turingos_prompt"
    agent::_write_prompt "$prompt_file" "$task" "$sandbox_path"

    ui::info "Starting agent inside sandbox..."
    log::section "AGENT START — task: ${task}"
    log::info "sandbox=${sandbox_path} log=${agent_log} bin=${agent_bin}"

    # Job control gives the job its own process group, so `agent stop` can
    # take down claude/opencode and tee along with the wrapper
    set -m
    (
        # This job reads exit codes itself; inherited `set -e` would kill it
        # on the first failed run, before the fallback or completion handler
        set +e
        cd "$sandbox_path" || exit 1
        model::scrub_keys
        local exit_code
        if [[ "$TURINGOS_MODEL_PROVIDER" == "claude" ]]; then
            # The sandbox copy is the trust boundary, so the agent runs unattended
            "$agent_bin" --print --verbose --output-format stream-json \
                --dangerously-skip-permissions \
                ${TURINGOS_AGENT_MODEL:+--model "$TURINGOS_AGENT_MODEL"} \
                < "$prompt_file" 2>&1 | tee -a "$agent_log"
            exit_code="${PIPESTATUS[0]}"
        else
            agent::_run_opencode "$agent_bin" "$prompt_file" "$agent_log"
            exit_code=$?
        fi

        agent::_capture_test_result "$sandbox_path" "$agent_log"
        agent::_on_complete "$task" "$sandbox_path" "$exit_code"
        exit "$exit_code"
    ) &
    local agent_pid=$!
    set +m

    config::pid_write "$AGENT_PID_NAME" "$agent_pid"
    config::state_set "$STATE_KEY_AGENT_PID" "$agent_pid"
    log::audit AGENT_START "pid=${agent_pid}" "task=${task}" "sandbox=${sandbox_path}"

    ui::ok   "Agent started (PID ${agent_pid})"
    ui::info "Tail output: tail -f ${agent_log}"
    ui::info "Status:      turingos agent status"
    echo ""

    if [[ -t 0 ]] && ui::confirm "Follow agent output now?"; then
        agent::_tail_log "$agent_log" "$agent_pid"
    fi
    return 0
}

agent::_run_opencode() {
    # Usage: agent::_run_opencode BIN PROMPT_FILE LOG
    # NVIDIA tries the default model, then each backup until one succeeds.
    # ponytail: retries on any non-zero exit, so a failed task also moves on
    # to the next model, in the same sandbox.
    local bin="$1" prompt_file="$2" log="$3"
    local provider="$TURINGOS_MODEL_PROVIDER" cfg model prompt exit_code=1 chain=()

    if ! cfg=$(model::opencode_config); then
        echo "[turingos] ERROR: could not write the OpenCode config for ${provider} (is jq installed?)" | tee -a "$log"
        return 1
    fi
    [[ -n "$cfg" ]] && export OPENCODE_CONFIG="$cfg"

    if [[ "$provider" == "nvidia" ]]; then
        mapfile -t chain < <(nim::model_chain)
    else
        chain=("${TURINGOS_MODEL_NAME:-}")   # empty = OpenCode's own default
    fi

    prompt=$(<"$prompt_file")
    for model in "${chain[@]}"; do
        [[ -n "$model" ]] && echo "[turingos] trying ${provider}/${model}" | tee -a "$log"
        "$bin" run ${model:+--model "${provider}/${model}"} "$prompt" 2>&1 | tee -a "$log"
        exit_code="${PIPESTATUS[0]}"
        [[ "$exit_code" -eq 0 ]] && return 0
        echo "[turingos] ${provider}/${model:-default} failed (exit ${exit_code})" | tee -a "$log"
    done
    if [[ "$provider" == "nvidia" ]]; then
        echo "[turingos] ERROR: default and all backup NVIDIA models failed" | tee -a "$log"
    fi
    return "$exit_code"
}

# ─── Stop ─────────────────────────────────────────────────────────────────────

agent::stop() {
    if ! config::pid_alive "$AGENT_PID_NAME"; then
        ui::info "No agent is currently running"
        return 0
    fi

    local pid
    pid=$(config::pid_read "$AGENT_PID_NAME")

    if ! ui::confirm "Stop agent (PID ${pid})?"; then
        ui::info "Agent left running"
        return 0
    fi

    # The PID is the job's process group leader: signal the whole group
    kill -TERM -- "-${pid}" 2>/dev/null || kill -TERM "$pid" 2>/dev/null || true
    sleep 1
    if kill -0 "$pid" 2>/dev/null; then
        kill -KILL -- "-${pid}" 2>/dev/null || kill -KILL "$pid" 2>/dev/null || true
    fi

    config::pid_clear "$AGENT_PID_NAME"
    config::state_del "$STATE_KEY_AGENT_PID"
    log::audit AGENT_STOP "pid=${pid}" "method=manual"
    ui::ok "Agent stopped (PID ${pid})"
}

# ─── Status ───────────────────────────────────────────────────────────────────

agent::status() {
    ui::header "Agent Status"

    local pid task sandbox_path
    pid=$(config::pid_read "$AGENT_PID_NAME")
    task=$(config::state_get "$STATE_KEY_AGENT_TASK")
    sandbox_path=$(config::state_get "$STATE_KEY_ACTIVE_SANDBOX")

    if config::pid_alive "$AGENT_PID_NAME"; then
        ui::status_row "Agent" "running" "ok"
        ui::label "  PID"     "$pid"
        ui::label "  Task"    "${task:-<unknown>}"
        ui::label "  Sandbox" "${sandbox_path:-<none>}"

        local cpu mem latest_log
        cpu=$(ps -p "$pid" -o %cpu= 2>/dev/null | tr -d ' ')
        mem=$(ps -p "$pid" -o %mem= 2>/dev/null | tr -d ' ')
        [[ -n "$cpu" ]] && ui::label "  CPU" "${cpu}%"
        [[ -n "$mem" ]] && ui::label "  RAM" "${mem}%"

        latest_log=$(agent::_latest_log)
        if [[ -n "$latest_log" ]]; then
            echo ""
            ui::info "Recent output:"
            tail -n 6 "$latest_log" | sed 's/^/    /'
        fi
    elif [[ -n "$pid" ]]; then
        # PID recorded but process dead — clean up
        ui::status_row "Agent" "stopped (last PID: ${pid})" "warn"
        config::pid_clear "$AGENT_PID_NAME"
        config::state_del "$STATE_KEY_AGENT_PID"
        if [[ -n "$sandbox_path" && -d "$sandbox_path" ]]; then
            echo ""
            ui::info "Sandbox ready for review: turingos sandbox diff"
        fi
    else
        ui::status_row "Agent" "idle" "warn"
    fi
    echo ""
}

# ─── Logs ─────────────────────────────────────────────────────────────────────

agent::logs() {
    local latest_log
    latest_log=$(agent::_latest_log)
    if [[ -z "$latest_log" ]]; then
        ui::info "No agent logs found"
        return 0
    fi

    if config::pid_alive "$AGENT_PID_NAME"; then
        ui::info "Tailing live agent output (Ctrl+C to stop)..."
        agent::_tail_log "$latest_log" "$(config::pid_read "$AGENT_PID_NAME")"
    else
        ui::info "Last session log: $latest_log"
        less -RFX "$latest_log"
    fi
}

agent::_tail_log() {
    # Tail LOGFILE until PID exits
    local logfile="$1" pid="$2" tail_pid
    tail -f "$logfile" &
    tail_pid=$!
    while kill -0 "$pid" 2>/dev/null; do
        sleep 1
    done
    kill "$tail_pid" 2>/dev/null || true
    wait "$tail_pid" 2>/dev/null || true
}

# ─── Prompt File ──────────────────────────────────────────────────────────────

agent::_write_prompt() {
    local prompt_file="$1" task="$2" sandbox="$3"
    cat > "$prompt_file" <<EOF
You are running inside a TuringOS agent sandbox.

Sandbox path: ${sandbox}
Task: ${task}

Instructions:
- Work only within this sandbox directory
- Make your changes, then run any applicable tests
- Write test results to: ${sandbox}/.turingos_test_result
  Format: "<N> passed, <M> failed"
- When complete, summarize what you changed

Begin the task now.
EOF
}

# ─── Test Result Capture ──────────────────────────────────────────────────────

agent::_capture_test_result() {
    # Pull a pytest ("X passed, Y failed") or jest ("X passed, Y total")
    # summary out of the agent log, unless the agent wrote one itself
    local sandbox="$1" log="$2" result
    [[ -s "${sandbox}/.turingos_test_result" ]] && return 0

    result=$(grep -oE '[0-9]+ passed(, [0-9]+ failed)?(, [0-9]+ total)?' "$log" 2>/dev/null | tail -1) || true
    if [[ -n "$result" ]]; then
        echo "$result" > "${sandbox}/.turingos_test_result"
        log::info "test result captured: $result"
    fi
}

# ─── Completion Handler ───────────────────────────────────────────────────────

agent::_on_complete() {
    local task="$1" sandbox="$2" exit_code="$3"
    local test_result=""

    config::pid_clear "$AGENT_PID_NAME"
    config::state_del "$STATE_KEY_AGENT_PID"
    [[ -f "${sandbox}/.turingos_test_result" ]] && test_result=$(<"${sandbox}/.turingos_test_result")

    log::audit AGENT_COMPLETE "exit_code=${exit_code}" "task=${task}" "sandbox=${sandbox}" "tests=${test_result}"

    if [[ "$exit_code" -eq 0 ]]; then
        log::info "agent completed successfully${test_result:+ — ${test_result}}"
        agent::_notify "Task complete${test_result:+ · ${test_result}}"
        ui::box "$BOLD_GREEN" "TuringOS" "Agent task completed" ${test_result:+"$test_result"} \
            "" "Run: turingos sandbox diff"
    else
        log::warn "Agent exited with errors (code ${exit_code})"
        agent::_notify "Agent exited with errors (code ${exit_code})"
        ui::box "$BOLD_RED" "TuringOS" "Agent exited with errors (code ${exit_code})" \
            "Run: turingos agent logs"
    fi
}

agent::_notify() {
    command -v notify-send &>/dev/null || return 0
    notify-send "${TURINGOS_NOTIFICATION_TITLE:-TuringOS}" "$1" --icon=terminal 2>/dev/null || true
}
