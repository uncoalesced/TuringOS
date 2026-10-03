#!/usr/bin/env bash
# core/logging.sh — TuringOS structured logging
# Writes timestamped entries to a daily file; mirrors to the terminal (stderr)
# based on TURINGOS_LOG_LEVEL.
# Depends on: core/config.sh (for TURINGOS_LOG_DIR, TURINGOS_LOG_LEVEL)

# ─── Guard ────────────────────────────────────────────────────────────────────

[[ -n "${_TURINGOS_LOGGING_LOADED:-}" ]] && return 0
_TURINGOS_LOGGING_LOADED=1

# ─── Helpers ──────────────────────────────────────────────────────────────────

_log::_rank() {
    case "$1" in
        debug) echo 0 ;;
        warn)  echo 2 ;;
        error) echo 3 ;;
        *)     echo 1 ;;
    esac
}

_log::_ensure_file() {
    # One log file per day; callers can override with TURINGOS_ACTIVE_LOG
    if [[ -z "${TURINGOS_ACTIVE_LOG:-}" ]]; then
        mkdir -p "$TURINGOS_LOG_DIR"
        TURINGOS_ACTIVE_LOG="${TURINGOS_LOG_DIR}/turingos-$(date +%Y%m%d).log"
        export TURINGOS_ACTIVE_LOG
    fi
}

# ─── Core Write ───────────────────────────────────────────────────────────────

_log::write() {
    local level="$1"
    shift
    local msg="$*"
    # Module tag = prefix of the calling function, e.g. sandbox::create -> sandbox
    local module="${FUNCNAME[2]:-turingos}"
    module="${module%%::*}"
    [[ "$module" == main || "$module" == source ]] && module="turingos"

    _log::_ensure_file
    printf '[%s] [%-5s] [%s] %s\n' "$(date '+%Y-%m-%dT%H:%M:%S')" "${level^^}" "$module" "$msg" \
        >> "$TURINGOS_ACTIVE_LOG"

    (( $(_log::_rank "$level") >= $(_log::_rank "$TURINGOS_LOG_LEVEL") )) || return 0

    local ts
    ts=$(date '+%H:%M:%S')
    case "$level" in
        info)  printf '  \033[0;36m→\033[0m  \033[2m[%s]\033[0m %s\n' "$ts" "$msg" ;;
        warn)  printf '  \033[0;33m⚠\033[0m  \033[2m[%s]\033[0m %s\n' "$ts" "$msg" ;;
        error) printf '  \033[1;31m✗\033[0m  \033[2m[%s]\033[0m \033[1;31m%s\033[0m\n' "$ts" "$msg" ;;
    esac >&2   # stderr, so $(func) captures only real results
}

# ─── Public API ───────────────────────────────────────────────────────────────

log::info()  { _log::write info  "$@"; }
log::warn()  { _log::write warn  "$@"; }
log::error() { _log::write error "$@"; }

log::section() {
    # Visible separator in the log file, for demarcating tasks
    _log::_ensure_file
    printf '\n[%s] ══════ %s ══════\n\n' "$(date '+%Y-%m-%dT%H:%M:%S')" "${1:-}" >> "$TURINGOS_ACTIVE_LOG"
}

log::audit() {
    # Usage: log::audit EVENT KEY=VALUE [KEY=VALUE ...] — agent action trail
    local event="$1"
    shift
    mkdir -p "$TURINGOS_LOG_DIR"
    printf '[%s] %s %s\n' "$(date '+%Y-%m-%dT%H:%M:%S')" "$event" "$*" >> "${TURINGOS_LOG_DIR}/audit.log"
}

log::tail() {
    local lines="${1:-50}"
    _log::_ensure_file
    if [[ ! -f "$TURINGOS_ACTIVE_LOG" ]]; then
        echo "  No log entries today (${TURINGOS_ACTIVE_LOG})"
        return 0
    fi
    tail -n "$lines" "$TURINGOS_ACTIVE_LOG"
}
