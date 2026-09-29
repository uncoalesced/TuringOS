#!/usr/bin/env bash
# core/logging.sh — TuringOS structured logging
# Writes timestamped entries to file; mirrors to terminal based on log level.
# Depends on: core/config.sh (for TURINGOS_LOG_DIR, TURINGOS_LOG_LEVEL)

# ─── Guard ────────────────────────────────────────────────────────────────────

[[ -n "${_TURINGOS_LOGGING_LOADED:-}" ]] && return 0
_TURINGOS_LOGGING_LOADED=1

# ─── Level Ranks (lower = more verbose) ──────────────────────────────────────
# Note: avoid declare -A for Bash 3.x (macOS default) compatibility

_log::_rank() {
    case "$1" in
        debug) echo 0 ;;
        info)  echo 1 ;;
        warn)  echo 2 ;;
        error) echo 3 ;;
        *)     echo 1 ;;
    esac
}

# ─── Current Log File ─────────────────────────────────────────────────────────
# Set once per session; callers can override by setting TURINGOS_ACTIVE_LOG.

_log::_ensure_file() {
    if [[ -z "${TURINGOS_ACTIVE_LOG:-}" ]]; then
        local log_dir="${TURINGOS_LOG_DIR:-${HOME}/.turingos/logs}"
        mkdir -p "$log_dir"
        TURINGOS_ACTIVE_LOG="${log_dir}/turingos-$(date +%Y%m%d).log"
        export TURINGOS_ACTIVE_LOG
    fi
}

# ─── Core Write ───────────────────────────────────────────────────────────────

_log::write() {
    local level="$1"   # debug | info | warn | error
    local module="$2"  # calling module name, e.g. "sandbox"
    shift 2
    local msg="$*"

    _log::_ensure_file

    local ts
    ts=$(date '+%Y-%m-%dT%H:%M:%S')

    # Always write to file (no colors)
    printf '[%s] [%-5s] [%s] %s\n' "$ts" "${level^^}" "$module" "$msg" \
        >> "$TURINGOS_ACTIVE_LOG"

    # Mirror to terminal if this level meets the configured threshold
    local configured_level="${TURINGOS_LOG_LEVEL:-info}"
    local msg_rank cfg_rank
    msg_rank=$(_log::_rank "$level")
    cfg_rank=$(_log::_rank "$configured_level")

    if (( msg_rank >= cfg_rank )); then
        _log::_print_terminal "$level" "$module" "$msg"
    fi
}

_log::_print_terminal() {
    local level="$1"
    local module="$2"
    local msg="$3"

    local RESET="\033[0m"
    local DIM="\033[2m"
    local ts
    ts=$(date '+%H:%M:%S')

    case "$level" in
        debug) printf "  \033[2m[%s] [%s] %s\033[0m\n" "$ts" "$module" "$msg" ;;
        info)  printf "  \033[0;36m→\033[0m  \033[2m[%s]\033[0m %s\n" "$ts" "$msg" ;;
        warn)  printf "  \033[0;33m⚠\033[0m  \033[2m[%s]\033[0m %s\n" "$ts" "$msg" ;;
        error) printf "  \033[1;31m✗\033[0m  \033[2m[%s]\033[0m \033[1;31m%s\033[0m\n" "$ts" "$msg" ;;
    esac
}

# ─── Public API ───────────────────────────────────────────────────────────────

log::debug() { _log::write "debug" "${_LOG_MODULE:-turingos}" "$@"; }
log::info()  { _log::write "info"  "${_LOG_MODULE:-turingos}" "$@"; }
log::warn()  { _log::write "warn"  "${_LOG_MODULE:-turingos}" "$@"; }
log::error() { _log::write "error" "${_LOG_MODULE:-turingos}" "$@"; }

# Convenience: set module name for a script
# Usage: log::set_module "sandbox"
log::set_module() {
    export _LOG_MODULE="$1"
}

# ─── Section Markers ──────────────────────────────────────────────────────────

log::section() {
    # Writes a visible separator to the log file — useful for demarcating tasks
    local label="${1:-}"
    _log::_ensure_file
    local ts
    ts=$(date '+%Y-%m-%dT%H:%M:%S')
    printf '\n[%s] ══════ %s ══════\n\n' "$ts" "$label" >> "$TURINGOS_ACTIVE_LOG"
}

# ─── Task Audit Trail ─────────────────────────────────────────────────────────
# Writes structured records to a separate audit log for agent actions.

log::audit() {
    # Usage: log::audit EVENT KEY=VALUE [KEY=VALUE ...]
    # Example: log::audit SANDBOX_CREATE sandbox=/path project=/repo
    local event="$1"
    shift

    local log_dir="${TURINGOS_LOG_DIR:-${HOME}/.turingos/logs}"
    mkdir -p "$log_dir"
    local audit_file="${log_dir}/audit.log"

    local ts
    ts=$(date '+%Y-%m-%dT%H:%M:%S')
    local pairs="$*"

    printf '[%s] %s %s\n' "$ts" "$event" "$pairs" >> "$audit_file"
}

# ─── Log Rotation ─────────────────────────────────────────────────────────────

log::rotate() {
    # Keep only the last N daily log files (default: 7)
    local keep="${1:-7}"
    local log_dir="${TURINGOS_LOG_DIR:-${HOME}/.turingos/logs}"

    # List turingos-*.log files sorted oldest-first, delete excess
    local count
    count=$(ls "${log_dir}/turingos-"*.log 2>/dev/null | wc -l)

    if (( count > keep )); then
        ls -t "${log_dir}/turingos-"*.log 2>/dev/null \
            | tail -n "+$((keep + 1))" \
            | xargs rm -f
        log::info "Log rotation: kept ${keep} files, removed $((count - keep))"
    fi
}

# ─── Tail Helper ──────────────────────────────────────────────────────────────

log::tail() {
    local lines="${1:-50}"
    _log::_ensure_file
    tail -n "$lines" "$TURINGOS_ACTIVE_LOG"
}

log::path() {
    _log::_ensure_file
    echo "$TURINGOS_ACTIVE_LOG"
}
