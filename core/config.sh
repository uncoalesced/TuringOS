#!/usr/bin/env bash
# core/config.sh — TuringOS configuration and path definitions
# Source this file to get all runtime paths and settings.
# Safe to source multiple times (idempotent).

# ─── Guard ────────────────────────────────────────────────────────────────────

[[ -n "${_TURINGOS_CONFIG_LOADED:-}" ]] && return 0
_TURINGOS_CONFIG_LOADED=1

# ─── TuringOS Root ────────────────────────────────────────────────────────────

# Resolve the real directory of this script so paths work regardless of $PWD
_CORE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# When installed via PKGBUILD, libs are at /usr/lib/turingos
# When running from a local checkout, root is one level up from core/
if [[ -d "/usr/lib/turingos" ]]; then
    export TURINGOS_ROOT="/usr/lib/turingos"
else
    export TURINGOS_ROOT="$(cd "${_CORE_DIR}/.." && pwd)"
fi

# ─── Runtime Directories ──────────────────────────────────────────────────────

export TURINGOS_DATA_DIR="${HOME}/.turingos"
export TURINGOS_SANDBOX_DIR="${TURINGOS_DATA_DIR}/sandboxes"
export TURINGOS_LOG_DIR="${TURINGOS_DATA_DIR}/logs"
export TURINGOS_BAZAAR_DIR="${TURINGOS_DATA_DIR}/bazaar"
export TURINGOS_AGENT_DIR="${TURINGOS_DATA_DIR}/agents"
export TURINGOS_CONFIG_FILE="${TURINGOS_DATA_DIR}/config.env"
export TURINGOS_STATE_FILE="${TURINGOS_DATA_DIR}/state.json"
export TURINGOS_PID_DIR="${TURINGOS_DATA_DIR}/pids"

# Bazaar registry (ships with TuringOS)
export TURINGOS_REGISTRY="${TURINGOS_ROOT}/bazaar/registry.json"

# Claude Desktop MCP config (standard location)
export CLAUDE_DESKTOP_CONFIG="${HOME}/.config/Claude/claude_desktop_config.json"
# Fallback for macOS
if [[ "$(uname)" == "Darwin" ]]; then
    export CLAUDE_DESKTOP_CONFIG="${HOME}/Library/Application Support/Claude/claude_desktop_config.json"
fi

# ─── Defaults (overridable via config.env) ────────────────────────────────────

TURINGOS_AGENT_BINARY="${TURINGOS_AGENT_BINARY:-claude}"
TURINGOS_LOCAL_LLM_BINARY="${TURINGOS_LOCAL_LLM_BINARY:-ollama}"
TURINGOS_NOTIFICATION_TITLE="${TURINGOS_NOTIFICATION_TITLE:-TuringOS}"
TURINGOS_SANDBOX_BACKEND="${TURINGOS_SANDBOX_BACKEND:-btrfs}"   # btrfs | copy
TURINGOS_GAME_RENICE_LEVEL="${TURINGOS_GAME_RENICE_LEVEL:-10}"  # nice value for background procs
TURINGOS_LOG_LEVEL="${TURINGOS_LOG_LEVEL:-info}"                # debug | info | warn | error

export TURINGOS_AGENT_BINARY TURINGOS_LOCAL_LLM_BINARY
export TURINGOS_NOTIFICATION_TITLE TURINGOS_SANDBOX_BACKEND
export TURINGOS_GAME_RENICE_LEVEL TURINGOS_LOG_LEVEL

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
        "$TURINGOS_DATA_DIR"
        "$TURINGOS_SANDBOX_DIR"
        "$TURINGOS_LOG_DIR"
        "$TURINGOS_BAZAAR_DIR"
        "$TURINGOS_AGENT_DIR"
        "$TURINGOS_PID_DIR"
    )
    for dir in "${dirs[@]}"; do
        mkdir -p "$dir"
    done
}

# ─── Load User Config Overrides ───────────────────────────────────────────────

config::load() {
    config::init_dirs

    if [[ -f "$TURINGOS_CONFIG_FILE" ]]; then
        # shellcheck source=/dev/null
        source "$TURINGOS_CONFIG_FILE"
    fi
}

# ─── Write a Config Value ─────────────────────────────────────────────────────

config::set() {
    # Usage: config::set KEY VALUE
    local key="$1"
    local value="$2"
    config::init_dirs

    if [[ -f "$TURINGOS_CONFIG_FILE" ]]; then
        # Remove existing key if present
        local tmp
        tmp=$(grep -v "^${key}=" "$TURINGOS_CONFIG_FILE" 2>/dev/null || true)
        echo "$tmp" > "$TURINGOS_CONFIG_FILE"
    fi
    echo "${key}=${value}" >> "$TURINGOS_CONFIG_FILE"
    export "${key}=${value}"
}

# ─── Read/Write State (state.json) ────────────────────────────────────────────

config::state_get() {
    # Usage: config::state_get KEY
    local key="$1"
    if [[ -f "$TURINGOS_STATE_FILE" ]] && command -v jq &>/dev/null; then
        jq -r ".${key} // empty" "$TURINGOS_STATE_FILE" 2>/dev/null
    fi
}

config::state_set() {
    # Usage: config::state_set KEY VALUE
    local key="$1"
    local value="$2"
    config::init_dirs

    local current="{}"
    if [[ -f "$TURINGOS_STATE_FILE" ]]; then
        current=$(cat "$TURINGOS_STATE_FILE")
    fi

    if command -v jq &>/dev/null; then
        echo "$current" | jq --arg v "$value" ".${key} = \$v" > "$TURINGOS_STATE_FILE"
    else
        # Fallback: simple key=value sidecar file
        echo "${key}=${value}" >> "${TURINGOS_STATE_FILE}.kv"
    fi
}

config::state_del() {
    # Usage: config::state_del KEY
    local key="$1"
    if [[ -f "$TURINGOS_STATE_FILE" ]] && command -v jq &>/dev/null; then
        local tmp
        tmp=$(jq "del(.${key})" "$TURINGOS_STATE_FILE")
        echo "$tmp" > "$TURINGOS_STATE_FILE"
    fi
}

# ─── PID File Helpers ─────────────────────────────────────────────────────────

config::pid_write() {
    # Usage: config::pid_write NAME PID
    local name="$1"
    local pid="$2"
    config::init_dirs
    echo "$pid" > "${TURINGOS_PID_DIR}/${name}.pid"
}

config::pid_read() {
    # Usage: config::pid_read NAME
    local name="$1"
    local pidfile="${TURINGOS_PID_DIR}/${name}.pid"
    if [[ -f "$pidfile" ]]; then
        cat "$pidfile"
    fi
}

config::pid_clear() {
    # Usage: config::pid_clear NAME
    local name="$1"
    rm -f "${TURINGOS_PID_DIR}/${name}.pid"
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
