#!/usr/bin/env bash
# core/config.sh — ClaudeOS configuration and path definitions
# Source this file to get all runtime paths and settings.
# Safe to source multiple times (idempotent).

# ─── Guard ────────────────────────────────────────────────────────────────────

[[ -n "${_CLAUDEOS_CONFIG_LOADED:-}" ]] && return 0
_CLAUDEOS_CONFIG_LOADED=1

# ─── ClaudeOS Root ────────────────────────────────────────────────────────────

# Resolve the real directory of this script so paths work regardless of $PWD
_CORE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export CLAUDEOS_ROOT="$(cd "${_CORE_DIR}/.." && pwd)"

# ─── Runtime Directories ──────────────────────────────────────────────────────

export CLAUDEOS_DATA_DIR="${HOME}/.claudeos"
export CLAUDEOS_SANDBOX_DIR="${CLAUDEOS_DATA_DIR}/sandboxes"
export CLAUDEOS_LOG_DIR="${CLAUDEOS_DATA_DIR}/logs"
export CLAUDEOS_BAZAAR_DIR="${CLAUDEOS_DATA_DIR}/bazaar"
export CLAUDEOS_AGENT_DIR="${CLAUDEOS_DATA_DIR}/agents"
export CLAUDEOS_CONFIG_FILE="${CLAUDEOS_DATA_DIR}/config.env"
export CLAUDEOS_STATE_FILE="${CLAUDEOS_DATA_DIR}/state.json"
export CLAUDEOS_PID_DIR="${CLAUDEOS_DATA_DIR}/pids"

# Bazaar registry (ships with ClaudeOS)
export CLAUDEOS_REGISTRY="${CLAUDEOS_ROOT}/bazaar/registry.json"

# Claude Desktop MCP config (standard location)
export CLAUDE_DESKTOP_CONFIG="${HOME}/.config/Claude/claude_desktop_config.json"
# Fallback for macOS
if [[ "$(uname)" == "Darwin" ]]; then
    export CLAUDE_DESKTOP_CONFIG="${HOME}/Library/Application Support/Claude/claude_desktop_config.json"
fi

# ─── Defaults (overridable via config.env) ────────────────────────────────────

CLAUDEOS_AGENT_BINARY="${CLAUDEOS_AGENT_BINARY:-claude}"
CLAUDEOS_LOCAL_LLM_BINARY="${CLAUDEOS_LOCAL_LLM_BINARY:-ollama}"
CLAUDEOS_NOTIFICATION_TITLE="${CLAUDEOS_NOTIFICATION_TITLE:-ClaudeOS}"
CLAUDEOS_SANDBOX_BACKEND="${CLAUDEOS_SANDBOX_BACKEND:-btrfs}"   # btrfs | copy
CLAUDEOS_GAME_RENICE_LEVEL="${CLAUDEOS_GAME_RENICE_LEVEL:-10}"  # nice value for background procs
CLAUDEOS_LOG_LEVEL="${CLAUDEOS_LOG_LEVEL:-info}"                # debug | info | warn | error

export CLAUDEOS_AGENT_BINARY CLAUDEOS_LOCAL_LLM_BINARY
export CLAUDEOS_NOTIFICATION_TITLE CLAUDEOS_SANDBOX_BACKEND
export CLAUDEOS_GAME_RENICE_LEVEL CLAUDEOS_LOG_LEVEL

# ─── Runtime State Keys ───────────────────────────────────────────────────────
# Used by state.json — these are just the key names as constants.

STATE_KEY_GAME_MODE="game_mode"           # "on" | "off"
STATE_KEY_ACTIVE_SANDBOX="active_sandbox" # path to current sandbox
STATE_KEY_AGENT_PID="agent_pid"           # PID of running claude process
STATE_KEY_AGENT_TASK="agent_task"         # description of current task

export STATE_KEY_GAME_MODE STATE_KEY_ACTIVE_SANDBOX
export STATE_KEY_AGENT_PID STATE_KEY_AGENT_TASK

# ─── Init: Create Runtime Dirs ───────────────────────────────────────────────

config::init_dirs() {
    local dirs=(
        "$CLAUDEOS_DATA_DIR"
        "$CLAUDEOS_SANDBOX_DIR"
        "$CLAUDEOS_LOG_DIR"
        "$CLAUDEOS_BAZAAR_DIR"
        "$CLAUDEOS_AGENT_DIR"
        "$CLAUDEOS_PID_DIR"
    )
    for dir in "${dirs[@]}"; do
        mkdir -p "$dir"
    done
}

# ─── Load User Config Overrides ───────────────────────────────────────────────

config::load() {
    config::init_dirs

    if [[ -f "$CLAUDEOS_CONFIG_FILE" ]]; then
        # shellcheck source=/dev/null
        source "$CLAUDEOS_CONFIG_FILE"
    fi
}

# ─── Write a Config Value ─────────────────────────────────────────────────────

config::set() {
    # Usage: config::set KEY VALUE
    local key="$1"
    local value="$2"
    config::init_dirs

    if [[ -f "$CLAUDEOS_CONFIG_FILE" ]]; then
        # Remove existing key if present
        local tmp
        tmp=$(grep -v "^${key}=" "$CLAUDEOS_CONFIG_FILE" 2>/dev/null || true)
        echo "$tmp" > "$CLAUDEOS_CONFIG_FILE"
    fi
    echo "${key}=${value}" >> "$CLAUDEOS_CONFIG_FILE"
    export "${key}=${value}"
}

# ─── Read/Write State (state.json) ────────────────────────────────────────────

config::state_get() {
    # Usage: config::state_get KEY
    local key="$1"
    if [[ -f "$CLAUDEOS_STATE_FILE" ]] && command -v jq &>/dev/null; then
        jq -r ".${key} // empty" "$CLAUDEOS_STATE_FILE" 2>/dev/null
    fi
}

config::state_set() {
    # Usage: config::state_set KEY VALUE
    local key="$1"
    local value="$2"
    config::init_dirs

    local current="{}"
    if [[ -f "$CLAUDEOS_STATE_FILE" ]]; then
        current=$(cat "$CLAUDEOS_STATE_FILE")
    fi

    if command -v jq &>/dev/null; then
        echo "$current" | jq --arg v "$value" ".${key} = \$v" > "$CLAUDEOS_STATE_FILE"
    else
        # Fallback: simple key=value sidecar file
        echo "${key}=${value}" >> "${CLAUDEOS_STATE_FILE}.kv"
    fi
}

config::state_del() {
    # Usage: config::state_del KEY
    local key="$1"
    if [[ -f "$CLAUDEOS_STATE_FILE" ]] && command -v jq &>/dev/null; then
        local tmp
        tmp=$(jq "del(.${key})" "$CLAUDEOS_STATE_FILE")
        echo "$tmp" > "$CLAUDEOS_STATE_FILE"
    fi
}

# ─── PID File Helpers ─────────────────────────────────────────────────────────

config::pid_write() {
    # Usage: config::pid_write NAME PID
    local name="$1"
    local pid="$2"
    config::init_dirs
    echo "$pid" > "${CLAUDEOS_PID_DIR}/${name}.pid"
}

config::pid_read() {
    # Usage: config::pid_read NAME
    local name="$1"
    local pidfile="${CLAUDEOS_PID_DIR}/${name}.pid"
    if [[ -f "$pidfile" ]]; then
        cat "$pidfile"
    fi
}

config::pid_clear() {
    # Usage: config::pid_clear NAME
    local name="$1"
    rm -f "${CLAUDEOS_PID_DIR}/${name}.pid"
}

config::pid_alive() {
    # Usage: config::pid_alive NAME — returns 0 if process is running
    local name="$1"
    local pid
    pid=$(config::pid_read "$name")
    if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
        return 0
    fi
    return 1
}

# ─── Auto-load on source ──────────────────────────────────────────────────────

config::load
