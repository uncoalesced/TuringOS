#!/usr/bin/env bash
# agent/claude.sh — TuringOS Agent Lifecycle Manager
#
# Starts Claude Code (or any configured agent binary) inside an active sandbox,
# tracks the process, streams output, and fires a notification on completion.
#
# Depends on: core/config.sh, core/logging.sh, core/ui.sh, sandbox/btrfs.sh

log::set_module "agent"

# ─── Constants ────────────────────────────────────────────────────────────────

AGENT_PID_NAME="claude"
AGENT_LOG_NAME="agent-session"

# ─── Start ────────────────────────────────────────────────────────────────────

agent::start() {
    # Usage: agent::start [PROJECT_DIR] [TASK_DESCRIPTION]
    local project="${1:-$PWD}"
    local task="${2:-}"

    project="$(cd "$project" && pwd)"

    # Bail if an agent is already running
    if config::pid_alive "$AGENT_PID_NAME"; then
        local existing_pid
        existing_pid=$(config::pid_read "$AGENT_PID_NAME")
        ui::warn "Agent already running (PID ${existing_pid})"
        ui::info "Use: turingos agent status"
        return 1
    fi

    # Prompt for task if not provided
    if [[ -z "$task" ]]; then
        task=$(ui::input "Describe the task for Claude" "Refactor and run tests")
    fi

    ui::header "Launching Claude Agent"
    ui::label "Project" "$project"
    ui::label "Task"    "$task"
    echo ""

    # Create sandbox first
    local sandbox_path
    sandbox_path=$(sandbox::create "$project" "$task")
    if [[ $? -ne 0 || -z "$sandbox_path" ]]; then
        ui::fail "Could not create sandbox — aborting agent start"
        return 1
    fi

    # Persist task description
    config::state_set "$STATE_KEY_AGENT_TASK" "$task"

    # Prepare agent log file
    local agent_log="${TURINGOS_LOG_DIR}/${AGENT_LOG_NAME}-$(date +%Y%m%dT%H%M%S).log"

    ui::info "Starting agent inside sandbox..."
    log::section "AGENT START — task: ${task}"
    log::info "sandbox=${sandbox_path} log=${agent_log}"

    # Non-Claude providers run through OpenCode
    local agent_bin="$TURINGOS_AGENT_BINARY"
    [[ "$TURINGOS_MODEL_PROVIDER" != "claude" ]] && agent_bin="$TURINGOS_OPENCODE_BINARY"

    # Check the agent binary exists
    if ! command -v "$agent_bin" &>/dev/null; then
        ui::fail "Agent binary not found: ${agent_bin}"
        ui::info "Set TURINGOS_AGENT_BINARY in ~/.turingos/config.env"
        log::error "agent binary missing: ${TURINGOS_AGENT_BINARY}"
        return 1
    fi

    # Build the prompt file so Claude gets context without interactive input
    local prompt_file="${sandbox_path}/.turingos_prompt"
    agent::_write_prompt "$prompt_file" "$task" "$sandbox_path"

    # Launch agent in background, captured to log
    (
        cd "$sandbox_path" || exit 1
        local exit_code
        if [[ "$TURINGOS_MODEL_PROVIDER" == "claude" ]]; then
            "$agent_bin" \
                --print \
                --output-format stream-json \
                < "$prompt_file" \
                2>&1 | tee "$agent_log"
            exit_code="${PIPESTATUS[0]}"
        else
            # Keep the OpenRouter key away from local/custom endpoints
            [[ "$TURINGOS_MODEL_PROVIDER" != "openrouter" ]] && unset OPENROUTER_API_KEY
            # OpenCode model ids are provider/model, e.g. ollama/llama3.2
            "$agent_bin" run \
                ${TURINGOS_MODEL_NAME:+--model "${TURINGOS_MODEL_PROVIDER}/${TURINGOS_MODEL_NAME}"} \
                "$(cat "$prompt_file")" \
                2>&1 | tee "$agent_log"
            exit_code="${PIPESTATUS[0]}"
        fi

        # Write test result if detectable
        agent::_capture_test_result "$sandbox_path" "$agent_log"

        # Signal completion
        agent::_on_complete "$task" "$sandbox_path" "$exit_code" "$agent_log"

        exit "$exit_code"
    ) &

    local agent_pid=$!
    config::pid_write "$AGENT_PID_NAME" "$agent_pid"
    config::state_set "$STATE_KEY_AGENT_PID" "$agent_pid"

    log::audit AGENT_START \
        "pid=${agent_pid}" \
        "task=${task}" \
        "sandbox=${sandbox_path}"

    ui::ok  "Agent started (PID ${agent_pid})"
    ui::info "Tail output: tail -f ${agent_log}"
    ui::info "Status:      turingos agent status"
    echo ""

    # Offer to tail the output interactively
    if ui::confirm "Follow agent output now?"; then
        agent::_tail_log "$agent_log" "$agent_pid"
    fi
}

# ─── Stop ─────────────────────────────────────────────────────────────────────

agent::stop() {
    if ! config::pid_alive "$AGENT_PID_NAME"; then
        ui::info "No agent is currently running"
        return 0
    fi

    local pid
    pid=$(config::pid_read "$AGENT_PID_NAME")

    if ui::confirm "Stop agent (PID ${pid})?"; then
        kill -TERM "$pid" 2>/dev/null
        sleep 1
        # Force-kill if still alive
        if kill -0 "$pid" 2>/dev/null; then
            kill -KILL "$pid" 2>/dev/null
        fi

        config::pid_clear "$AGENT_PID_NAME"
        config::state_del "$STATE_KEY_AGENT_PID"

        log::audit AGENT_STOP "pid=${pid}" "method=manual"
        ui::ok "Agent stopped (PID ${pid})"
    else
        ui::info "Agent left running"
    fi
}

# ─── Status ───────────────────────────────────────────────────────────────────

agent::status() {
    ui::header "Agent Status"

    local pid task sandbox_path
    pid=$(config::pid_read "$AGENT_PID_NAME")
    task=$(config::state_get "$STATE_KEY_AGENT_TASK")
    sandbox_path=$(config::state_get "$STATE_KEY_ACTIVE_SANDBOX")

    if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
        ui::status_row "Agent"       "running" "ok"
        ui::label "  PID"           "$pid"
        ui::label "  Task"          "${task:-<unknown>}"
        ui::label "  Sandbox"       "${sandbox_path:-<none>}"

        # CPU/memory snapshot for this PID
        local cpu mem
        cpu=$(ps -p "$pid" -o %cpu= 2>/dev/null | tr -d ' ')
        mem=$(ps -p "$pid" -o %mem= 2>/dev/null | tr -d ' ')
        [[ -n "$cpu" ]] && ui::label "  CPU"  "${cpu}%"
        [[ -n "$mem" ]] && ui::label "  RAM"  "${mem}%"

        # Show last few lines of agent log
        local latest_log
        latest_log=$(ls -t "${TURINGOS_LOG_DIR}/${AGENT_LOG_NAME}-"*.log 2>/dev/null | head -1)
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

# ─── Tail Live Output ─────────────────────────────────────────────────────────

agent::logs() {
    local latest_log
    latest_log=$(ls -t "${TURINGOS_LOG_DIR}/${AGENT_LOG_NAME}-"*.log 2>/dev/null | head -1)

    if [[ -z "$latest_log" ]]; then
        ui::info "No agent logs found"
        return 0
    fi

    local pid
    pid=$(config::pid_read "$AGENT_PID_NAME")

    if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
        ui::info "Tailing live agent output (Ctrl+C to stop)..."
        agent::_tail_log "$latest_log" "$pid"
    else
        ui::info "Last session log: $latest_log"
        less -RFX "$latest_log"
    fi
}

agent::_tail_log() {
    local logfile="$1"
    local pid="$2"

    # Tail until the agent process exits
    tail -f "$logfile" &
    local tail_pid=$!

    # Wait for agent to finish, then kill the tail
    while kill -0 "$pid" 2>/dev/null; do
        sleep 1
    done
    kill "$tail_pid" 2>/dev/null
    wait "$tail_pid" 2>/dev/null
}

# ─── Prompt File ──────────────────────────────────────────────────────────────

agent::_write_prompt() {
    local prompt_file="$1"
    local task="$2"
    local sandbox="$3"

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
    local sandbox="$1"
    local log="$2"

    # Try to extract a pytest/jest/go test summary from the agent log
    local result=""

    # pytest pattern: "X passed, Y failed"
    result=$(grep -oP '\d+ passed(, \d+ failed)?' "$log" 2>/dev/null | tail -1)

    # jest pattern: "Tests: X passed, Y total"
    if [[ -z "$result" ]]; then
        local p t
        p=$(grep -oP '(?<=Tests:)\s+\d+ passed' "$log" 2>/dev/null | tail -1 | tr -d ' ')
        t=$(grep -oP '\d+(?= total)'             "$log" 2>/dev/null | tail -1)
        [[ -n "$p" && -n "$t" ]] && result="${p}, ${t} total"
    fi

    if [[ -n "$result" ]]; then
        echo "$result" > "${sandbox}/.turingos_test_result"
        log::info "test result captured: $result"
    fi
}

# ─── Completion Handler ───────────────────────────────────────────────────────

agent::_on_complete() {
    local task="$1"
    local sandbox="$2"
    local exit_code="$3"
    local log="$4"

    config::pid_clear "$AGENT_PID_NAME"
    config::state_del "$STATE_KEY_AGENT_PID"

    local test_result=""
    [[ -f "${sandbox}/.turingos_test_result" ]] && \
        test_result=$(cat "${sandbox}/.turingos_test_result")

    log::audit AGENT_COMPLETE \
        "exit_code=${exit_code}" \
        "task=${task}" \
        "sandbox=${sandbox}" \
        "tests=${test_result}"

    local notify_body
    if [[ $exit_code -eq 0 ]]; then
        notify_body="Task complete"
        [[ -n "$test_result" ]] && notify_body="${notify_body} · ${test_result}"
        log::info "agent completed successfully — ${notify_body}"
    else
        notify_body="Agent exited with errors (code ${exit_code})"
        log::warn "$notify_body"
    fi

    agent::_notify "$notify_body"

    # Print completion banner to terminal (visible if user is watching)
    echo ""
    echo ""
    if [[ $exit_code -eq 0 ]]; then
        printf "  \033[1;32m╭──────────────────────────────────────────╮\033[0m\n"
        printf "  \033[1;32m│\033[0m  \033[1;37m🟢 TuringOS\033[0m                             \033[1;32m│\033[0m\n"
        printf "  \033[1;32m│\033[0m                                          \033[1;32m│\033[0m\n"
        printf "  \033[1;32m│\033[0m  %-40s\033[1;32m│\033[0m\n" "Agent task completed"
        [[ -n "$test_result" ]] && \
        printf "  \033[1;32m│\033[0m  %-40s\033[1;32m│\033[0m\n" "$test_result"
        printf "  \033[1;32m│\033[0m                                          \033[1;32m│\033[0m\n"
        printf "  \033[1;32m│\033[0m  \033[2mRun: turingos sandbox diff\033[0m              \033[1;32m│\033[0m\n"
        printf "  \033[1;32m╰──────────────────────────────────────────╯\033[0m\n"
    else
        printf "  \033[1;31m╭──────────────────────────────────────────╮\033[0m\n"
        printf "  \033[1;31m│\033[0m  \033[1;37m🔴 TuringOS\033[0m                             \033[1;31m│\033[0m\n"
        printf "  \033[1;31m│\033[0m  %-40s\033[1;31m│\033[0m\n" "Agent exited with errors"
        printf "  \033[1;31m│\033[0m  \033[2mRun: turingos agent logs\033[0m                \033[1;31m│\033[0m\n"
        printf "  \033[1;31m╰──────────────────────────────────────────╯\033[0m\n"
    fi
    echo ""
}

# ─── System Notification ─────────────────────────────────────────────────────

agent::_notify() {
    local body="$1"
    local title="${TURINGOS_NOTIFICATION_TITLE:-TuringOS}"

    if command -v notify-send &>/dev/null; then
        notify-send "$title" "$body" --icon=terminal 2>/dev/null || true
    elif command -v osascript &>/dev/null; then
        # macOS fallback
        osascript -e "display notification \"${body}\" with title \"${title}\"" 2>/dev/null || true
    fi
}
