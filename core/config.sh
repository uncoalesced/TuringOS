#!/usr/bin/env bash
# core/config.sh — TuringOS configuration and path definitions
# Source this file to get all runtime paths and settings.
# Safe to source multiple times (idempotent).

# ─── Guard ────────────────────────────────────────────────────────────────────

[[ -n "${_TURINGOS_CONFIG_LOADED:-}" ]] && return 0
_TURINGOS_CONFIG_LOADED=1

# ─── TuringOS Root ────────────────────────────────────────────────────────────
# Set by the `turingos` entrypoint. Fallback: the checkout this file lives in.

TURINGOS_ROOT="${TURINGOS_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
export TURINGOS_ROOT

# ─── Runtime Directories ──────────────────────────────────────────────────────

export TURINGOS_DATA_DIR="${HOME}/.turingos"
export TURINGOS_SANDBOX_DIR="${TURINGOS_DATA_DIR}/sandboxes"
export TURINGOS_LOG_DIR="${TURINGOS_DATA_DIR}/logs"
export TURINGOS_BAZAAR_DIR="${TURINGOS_DATA_DIR}/bazaar"
export TURINGOS_CONFIG_FILE="${TURINGOS_DATA_DIR}/config.env"
export TURINGOS_STATE_FILE="${TURINGOS_DATA_DIR}/state.json"
export TURINGOS_PID_DIR="${TURINGOS_DATA_DIR}/pids"

# Bazaar registry (ships with TuringOS)
export TURINGOS_REGISTRY="${TURINGOS_ROOT}/bazaar/registry.json"

# Claude Code user config; user-scope MCP servers live under .mcpServers
export CLAUDE_CODE_CONFIG="${HOME}/.claude.json"

# ─── Defaults (overridable via config.env) ────────────────────────────────────

TURINGOS_AGENT_BINARY="${TURINGOS_AGENT_BINARY:-claude}"
TURINGOS_NOTIFICATION_TITLE="${TURINGOS_NOTIFICATION_TITLE:-TuringOS}"
TURINGOS_SANDBOX_BACKEND="${TURINGOS_SANDBOX_BACKEND:-btrfs}"   # btrfs | copy
TURINGOS_GAME_RENICE_LEVEL="${TURINGOS_GAME_RENICE_LEVEL:-10}"  # nice value for background procs
TURINGOS_LOG_LEVEL="${TURINGOS_LOG_LEVEL:-info}"                # debug | info | warn | error

# Model provider. Anything other than claude runs through OpenCode.
TURINGOS_MODEL_PROVIDER="${TURINGOS_MODEL_PROVIDER:-claude}"    # claude | nvidia | ollama | openrouter | custom
TURINGOS_MODEL_ENDPOINT="${TURINGOS_MODEL_ENDPOINT:-}"          # e.g. http://localhost:11434
TURINGOS_MODEL_NAME="${TURINGOS_MODEL_NAME:-}"                  # e.g. llama3.2
TURINGOS_OPENCODE_BINARY="${TURINGOS_OPENCODE_BINARY:-opencode}"

export TURINGOS_AGENT_BINARY TURINGOS_NOTIFICATION_TITLE TURINGOS_SANDBOX_BACKEND
export TURINGOS_GAME_RENICE_LEVEL TURINGOS_LOG_LEVEL
export TURINGOS_MODEL_PROVIDER TURINGOS_MODEL_ENDPOINT TURINGOS_MODEL_NAME TURINGOS_OPENCODE_BINARY

# ─── Runtime State Keys (state.json, also read by the desktop UI) ────────────
# shellcheck disable=SC2034  # used by the modules that source this file
declare -g \
    STATE_KEY_GAME_MODE="game_mode" \
    STATE_KEY_ACTIVE_SANDBOX="active_sandbox" \
    STATE_KEY_AGENT_PID="agent_pid" \
    STATE_KEY_AGENT_TASK="agent_task"

# ─── Init: Create Runtime Dirs ───────────────────────────────────────────────

config::init_dirs() {
    mkdir -p "$TURINGOS_DATA_DIR" "$TURINGOS_SANDBOX_DIR" "$TURINGOS_LOG_DIR" \
             "$TURINGOS_BAZAAR_DIR" "$TURINGOS_PID_DIR"
    # Keys, logs and sandboxes: owner only
    chmod 700 "$TURINGOS_DATA_DIR" 2>/dev/null || true
}

config::valid_secret() {
    # Usage: config::valid_secret VALUE — API keys/tokens: one line of
    # base64/URL-safe characters, nothing a shell or curl config could act on
    [[ "$1" =~ ^[A-Za-z0-9._~+/=-]{8,512}$ ]]
}

# ─── Load User Config Overrides ───────────────────────────────────────────────

config::load() {
    config::init_dirs
    if [[ -f "$TURINGOS_CONFIG_FILE" ]]; then
        # Export everything so API keys reach claude/opencode child processes
        set -a
        # shellcheck source=/dev/null
        source "$TURINGOS_CONFIG_FILE"
        set +a
    fi
}

# ─── Write a Config Value ─────────────────────────────────────────────────────

config::set() {
    # Usage: config::set KEY VALUE
    # Value is shell-quoted (the file is sourced). File stays mode 600: it holds API keys.
    local key="$1" value="$2" tmp
    config::init_dirs
    tmp=$(mktemp "${TURINGOS_CONFIG_FILE}.XXXXXX")
    if [[ -f "$TURINGOS_CONFIG_FILE" ]]; then
        grep -v "^${key}=" "$TURINGOS_CONFIG_FILE" > "$tmp" || true
    fi
    printf '%s=%q\n' "$key" "$value" >> "$tmp"
    chmod 600 "$tmp"
    mv -f "$tmp" "$TURINGOS_CONFIG_FILE"
    export "${key}=${value}"
}

# ─── Read/Write State (state.json) ────────────────────────────────────────────

config::state_get() {
    # Usage: config::state_get KEY
    [[ -f "$TURINGOS_STATE_FILE" ]] || return 0
    jq -r --arg k "$1" '.[$k] // empty' "$TURINGOS_STATE_FILE" 2>/dev/null || true
}

config::_state_edit() {
    # Usage: config::_state_edit JQ_FILTER [jq args...] — atomic rewrite of state.json
    local filter="$1" tmp current="{}"
    shift
    config::init_dirs
    [[ -s "$TURINGOS_STATE_FILE" ]] && current=$(cat "$TURINGOS_STATE_FILE")
    tmp=$(mktemp "${TURINGOS_STATE_FILE}.XXXXXX")
    if jq "$@" "$filter" <<< "$current" > "$tmp"; then
        mv -f "$tmp" "$TURINGOS_STATE_FILE"
    else
        rm -f "$tmp"
        return 1
    fi
}

config::state_set() {
    # Usage: config::state_set KEY VALUE
    # shellcheck disable=SC2016  # jq variables, not shell
    config::_state_edit '.[$k] = $v' --arg k "$1" --arg v "$2"
}

config::state_del() {
    # Usage: config::state_del KEY
    [[ -f "$TURINGOS_STATE_FILE" ]] || return 0
    # shellcheck disable=SC2016  # jq variables, not shell
    config::_state_edit 'del(.[$k])' --arg k "$1"
}

# ─── PID File Helpers ─────────────────────────────────────────────────────────

config::pid_write() {
    # Usage: config::pid_write NAME PID
    config::init_dirs
    echo "$2" > "${TURINGOS_PID_DIR}/$1.pid"
}

config::pid_read() {
    # Usage: config::pid_read NAME
    local pidfile="${TURINGOS_PID_DIR}/$1.pid"
    [[ -f "$pidfile" ]] && cat "$pidfile"
    return 0
}

config::pid_clear() {
    # Usage: config::pid_clear NAME
    rm -f "${TURINGOS_PID_DIR}/$1.pid"
}

config::pid_alive() {
    # Usage: config::pid_alive NAME — returns 0 if process is running
    local pid
    pid=$(config::pid_read "$1")
    [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null
}

# ─── Auto-load on source ──────────────────────────────────────────────────────

config::load
