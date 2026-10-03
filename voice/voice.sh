#!/usr/bin/env bash
# voice/voice.sh — `turingos voice`: speech-to-text backend for the desktop UI
#
# Backends:
#   whisper  local whisper.cpp in the UI (default; model downloads on first use)
#   wispr    Wispr Flow through the unofficial wisprflow-re client, using a
#            session imported from a Windows/macOS machine. Falls back to
#            whisper on any failure. Unofficial: may break or conflict with
#            Wispr's terms.
#
# Depends on: core/config.sh, core/ui.sh

VOICE_WISPR_DIR="${TURINGOS_DATA_DIR}/wispr"
VOICE_WHISPER_MODEL="${TURINGOS_DATA_DIR}/models/ggml-base.en.bin"
# Pinned commit of github.com/mathisarends/whisprflow-re (no PyPI release)
VOICE_WISPR_REF="2fa262cdd42200df70bef90b59257b29fbc8abaa"

voice::cmd() {
    local sub="${1:-status}"
    shift || true
    case "$sub" in
        status)       voice::status ;;
        backend)      voice::backend "$@" ;;
        wispr-import) voice::wispr_import "$@" ;;
        *)            ui::fail "Usage: turingos voice [status | backend whisper|wispr | wispr-import <session.json> [config.json]]"; return 1 ;;
    esac
}

voice::status() {
    ui::header "Voice Input"
    ui::label "Backend" "${TURINGOS_VOICE_BACKEND:-whisper}"
    if [[ -f "$VOICE_WHISPER_MODEL" ]]; then
        ui::status_row "Whisper model" "$(du -h "$VOICE_WHISPER_MODEL" | cut -f1) ${VOICE_WHISPER_MODEL}" "ok"
    else
        ui::status_row "Whisper model" "downloads on first mic use (~142 MB)" "warn"
    fi
    if [[ -f "${VOICE_WISPR_DIR}/session.json" ]]; then
        ui::status_row "Wispr session" "imported" "ok"
    else
        ui::status_row "Wispr session" "none" "warn"
    fi
    if [[ -x "${VOICE_WISPR_DIR}/venv/bin/python" ]]; then
        ui::status_row "wisprflow-re" "installed" "ok"
    else
        ui::status_row "wisprflow-re" "not installed" "warn"
    fi
    echo ""
}

voice::backend() {
    case "${1:-}" in
        whisper) ;;
        wispr)
            if [[ ! -f "${VOICE_WISPR_DIR}/session.json" ]]; then
                ui::fail "Import a Wispr session first: turingos voice wispr-import <session.json>"
                return 1
            fi
            ;;
        *) ui::fail "Usage: turingos voice backend whisper|wispr"; return 1 ;;
    esac
    config::set TURINGOS_VOICE_BACKEND "$1"
    ui::ok "Voice backend: $1 (restart the desktop UI to apply)"
}

voice::wispr_import() {
    # Usage: voice::wispr_import SESSION_JSON [WISPRFLOW_RE_CONFIG_JSON]
    local session="${1:-}" re_config="${2:-}"
    local re_dir="${XDG_CONFIG_HOME:-${HOME}/.config}/wisprflow-re"
    if [[ ! -f "$session" ]]; then
        ui::fail "Usage: turingos voice wispr-import <session.json> [config.json]"
        ui::info "Copy session.json from a machine signed in to Wispr Flow"
        ui::info "(Windows: %APPDATA%\\Wispr Flow\\session.json)"
        return 1
    fi

    ui::warn "Wispr Flow has no Linux client or official API. This uses the unofficial"
    ui::warn "wisprflow-re client; it may break at any time or conflict with Wispr's terms."
    ui::confirm "Continue?" || return 0

    mkdir -p "$VOICE_WISPR_DIR"
    chmod 700 "$VOICE_WISPR_DIR"
    install -m 600 "$session" "${VOICE_WISPR_DIR}/session.json"
    if [[ -n "$re_config" ]]; then
        mkdir -p "$re_dir"
        install -m 600 "$re_config" "${re_dir}/config.json"
    fi
    ui::ok "Session imported to ${VOICE_WISPR_DIR}/session.json"

    if [[ ! -x "${VOICE_WISPR_DIR}/venv/bin/python" ]]; then
        ui::info "Installing wisprflow-re (needs python3-venv and git)..."
        if ! python3 -m venv "${VOICE_WISPR_DIR}/venv" \
            || ! "${VOICE_WISPR_DIR}/venv/bin/pip" install --quiet \
                "git+https://github.com/mathisarends/whisprflow-re@${VOICE_WISPR_REF}"; then
            ui::fail "wisprflow-re install failed"
            return 1
        fi
    fi
    voice::backend wispr
}
