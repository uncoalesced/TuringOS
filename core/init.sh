#!/usr/bin/env bash
# core/init.sh — `turingos init`: first-time setup and dependency check
#
# Depends on: core/config.sh, core/ui.sh, agent/model.sh

init::run() {
    ui::banner
    ui::info "Initializing TuringOS..."
    echo ""

    config::init_dirs
    ui::ok "Runtime directories created: ${TURINGOS_DATA_DIR}"

    echo ""
    ui::info "Checking dependencies..."
    echo ""
    local all_ok=true
    ui::check_deps required git jq curl || all_ok=false
    echo ""
    ui::check_deps optional gum fzf rsync btrfs notify-send nvidia-smi opencode || true

    echo ""
    ui::divider
    echo ""
    init::_claude_cli
    init::_api_key
    init::_provider

    echo ""
    ui::divider
    echo ""
    if $all_ok; then
        ui::ok "TuringOS initialized"
    else
        ui::warn "Some required dependencies are missing — install them before running agents"
    fi

    echo ""
    ui::info "Data dir:    ${TURINGOS_DATA_DIR}"
    ui::info "Config:      ${TURINGOS_CONFIG_FILE}"
    ui::info "Agent log:   ${TURINGOS_LOG_DIR}/"
    ui::info "Sandboxes:   ${TURINGOS_SANDBOX_DIR}/"
    echo ""
    ui::info "Next steps:"
    ui::info "  turingos agent start   — launch the agent in a safe sandbox"
    ui::info "  turingos bazaar        — browse MCP tools"
    ui::info "  turingos dashboard     — interactive menu"
    echo ""
}

init::_claude_cli() {
    local installer="${TURINGOS_ROOT}/pkg/turingos-install-claude-cli.sh"
    if command -v claude &>/dev/null; then
        ui::status_row "Claude Code CLI" "$(claude --version 2>/dev/null || echo installed)" "ok"
        return 0
    fi

    ui::status_row "Claude Code CLI" "NOT FOUND" "fail"
    echo ""
    ui::warn "Claude Code CLI is required to run Claude agents."
    if ui::confirm "Install Claude Code CLI now?"; then
        echo ""
        bash "$installer" || ui::warn "Claude Code CLI not installed"
    else
        ui::info "Install later: bash ${installer}"
    fi
}

init::_api_key() {
    echo ""
    if [[ -n "${ANTHROPIC_API_KEY:-}" ]]; then
        ui::status_row "ANTHROPIC_API_KEY" "set" "ok"
    else
        ui::status_row "ANTHROPIC_API_KEY" "not set" "warn"
        ui::info "Set it: bash ${TURINGOS_ROOT}/pkg/turingos-install-claude-cli.sh --api-key"
    fi
}

init::_provider() {
    echo ""
    ui::confirm "Configure a model provider now? (Claude is the default)" || return 0

    local provider endpoint="" name=""
    provider=$(ui::choose "Model provider" "${MODEL_PROVIDERS[@]}") || true
    [[ -n "$provider" ]] || return 0
    case "$provider" in
        custom) endpoint=$(ui::input "Endpoint URL" "http://localhost:8080") || true ;;&
        ollama | openrouter | custom) name=$(ui::input "Model name" "") || true ;;
    esac
    model::set "$provider" "$endpoint" "$name" || ui::warn "Model provider not configured"
}
