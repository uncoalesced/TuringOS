#!/usr/bin/env bash
# turingos-install-claude-cli.sh
#
# Installs the Claude Code CLI via Anthropic's native installer, with an npm
# fallback, then sets up the API key.
#
# Usage:
#   turingos-install-claude-cli.sh              # interactive
#   turingos-install-claude-cli.sh --npm        # force npm method
#   turingos-install-claude-cli.sh --native     # force native installer
#   turingos-install-claude-cli.sh --api-key    # only set up the API key

set -euo pipefail

# Installed at /usr/lib/turingos/pkg/, or pkg/ in a checkout: core/ is next door
TURINGOS_ROOT="${TURINGOS_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
source "${TURINGOS_ROOT}/core/config.sh"
source "${TURINGOS_ROOT}/core/ui.sh"

# ─── Methods ─────────────────────────────────────────────────────────────────

install_claude_cli::_check() {
    if command -v claude &>/dev/null; then
        ui::ok "Claude Code installed: $(claude --version 2>/dev/null)"
        return 0
    fi
    ui::fail "Install ran but 'claude' is not on PATH — open a new terminal and run: claude --version"
    return 1
}

install_claude_cli::native() {
    ui::info "Installing via Anthropic's native installer..."
    echo ""
    curl -fsSL https://claude.ai/install.sh | bash
    # The native installer puts the binary in ~/.local/bin
    export PATH="${HOME}/.local/bin:${PATH}"
    install_claude_cli::_check
}

install_claude_cli::npm() {
    ui::info "Installing via npm..."
    echo ""
    if ! command -v npm &>/dev/null; then
        ui::fail "Node.js not found. Install: sudo apt install nodejs npm"
        return 1
    fi
    local node_ver
    node_ver=$(node --version | tr -d 'v' | cut -d. -f1)
    if (( node_ver < 18 )); then
        ui::fail "Node.js ${node_ver} is too old — need 18+"
        return 1
    fi

    # User-local prefix: no sudo needed
    local npm_prefix="${HOME}/.npm-global"
    mkdir -p "$npm_prefix"
    npm config set prefix "$npm_prefix"
    export PATH="${npm_prefix}/bin:${PATH}"
    # shellcheck disable=SC2016  # expanded by the user's shell, not here
    install_claude_cli::_bashrc_line 'export PATH="${HOME}/.npm-global/bin:$PATH"'

    npm install -g @anthropic-ai/claude-code
    install_claude_cli::_check
}

install_claude_cli::_bashrc_line() {
    # Append LINE to ~/.bashrc once
    grep -qxF "$1" "${HOME}/.bashrc" 2>/dev/null || printf '\n%s\n' "$1" >> "${HOME}/.bashrc"
}

# ─── API Key Setup ────────────────────────────────────────────────────────────

install_claude_cli::configure_api_key() {
    echo ""
    ui::info "Claude Code needs an ANTHROPIC_API_KEY to run agents."
    ui::info "Get one at: https://console.anthropic.com"
    echo ""

    if [[ -n "${ANTHROPIC_API_KEY:-}" ]]; then
        ui::ok "ANTHROPIC_API_KEY is already set"
        ui::confirm "Replace it with a different key?" || return 0
    fi

    local api_key
    api_key=$(ui::secret "Anthropic API key, sk-ant-... (blank to skip)")
    if [[ -z "$api_key" ]]; then
        ui::warn "Skipped. Run later: turingos-install-claude-cli.sh --api-key"
        return 0
    fi
    [[ "$api_key" == sk-ant-* ]] || ui::warn "Unexpected format — saving anyway (expected sk-ant-...)"

    # config.env is mode 600; ~/.bashrc only sources it, so the key never
    # lands in a world-readable file and plain `claude` sessions see it too
    config::set ANTHROPIC_API_KEY "$api_key"
    # shellcheck disable=SC2016  # expanded by the user's shell, not here
    install_claude_cli::_bashrc_line \
        '[ -f "$HOME/.turingos/config.env" ] && { set -a; . "$HOME/.turingos/config.env"; set +a; }'
    ui::ok "API key saved to ${TURINGOS_CONFIG_FILE}"
}

# ─── Main ─────────────────────────────────────────────────────────────────────

main() {
    local method="${1:-auto}"

    ui::header "Claude Code CLI Setup"

    if [[ "$method" == "--api-key" ]]; then
        install_claude_cli::configure_api_key
        return 0
    fi

    if [[ "$method" == "auto" ]] && command -v claude &>/dev/null; then
        ui::ok "Claude Code CLI already installed: $(claude --version 2>/dev/null || echo unknown)"
        if ! ui::confirm "Reinstall / update?"; then
            install_claude_cli::configure_api_key
            return 0
        fi
    fi

    local installed=false
    case "$method" in
        --npm)    install_claude_cli::npm && installed=true ;;
        --native) install_claude_cli::native && installed=true ;;
        *)
            if install_claude_cli::native; then
                installed=true
            else
                echo ""
                ui::warn "Native installer failed — falling back to npm..."
                install_claude_cli::npm && installed=true
            fi
            ;;
    esac

    if ! $installed; then
        echo ""
        ui::fail "Could not install Claude Code CLI automatically"
        ui::info "Install manually: https://code.claude.com/docs/en/setup"
        return 1
    fi

    install_claude_cli::configure_api_key
    echo ""
    ui::ok "Setup complete. Next: turingos agent start"
    echo ""
}

main "${1:-auto}"
