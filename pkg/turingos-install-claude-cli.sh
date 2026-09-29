#!/usr/bin/env bash
# turingos-install-claude-cli.sh
#
# Installs the Claude Code CLI via native installer (recommended),
# Homebrew, or npm fallback. Also handles API key setup.
#
# Usage:
#   ./turingos-install-claude-cli.sh          # interactive
#   ./turingos-install-claude-cli.sh --brew   # force Homebrew method
#   ./turingos-install-claude-cli.sh --npm    # force npm method

set -euo pipefail

# ─── Source core UI if available ─────────────────────────────────────────────

_SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [[ -f "/usr/lib/turingos/core/ui.sh" ]]; then
    source /usr/lib/turingos/core/ui.sh
elif [[ -f "${_SELF_DIR}/../core/ui.sh" ]]; then
    source "${_SELF_DIR}/../core/ui.sh"
else
    ui::ok()      { echo "  ✓  $*"; }
    ui::fail()    { echo "  ✗  $*"; }
    ui::warn()    { echo "  ⚠  $*"; }
    ui::info()    { echo "  →  $*"; }
    ui::confirm() { read -rp "  $1 [y/N] " r; [[ "$r" =~ ^[Yy]$ ]]; }
fi

# ─── Already installed? ───────────────────────────────────────────────────────

install_claude_cli::already_installed() {
    if command -v claude &>/dev/null; then
        local ver
        ver=$(claude --version 2>/dev/null || echo "unknown")
        ui::ok "Claude Code CLI already installed: ${ver}"
        if ! ui::confirm "Reinstall / update?"; then
            return 0
        fi
    fi
    return 1
}

# ─── Method 1: Native Installer (Anthropic recommended) ──────────────────────

install_claude_cli::native() {
    ui::info "Installing via Anthropic native installer (macOS + Linux)..."
    echo ""

    # The native installer is a shell script from Anthropic
    # It detects the platform and installs the right binary
    curl -fsSL https://claude.ai/install.sh | sh

    if command -v claude &>/dev/null; then
        ui::ok "Claude Code installed: $(claude --version 2>/dev/null)"
        return 0
    else
        ui::warn "Installer ran but 'claude' not found in PATH yet"
        ui::info "Open a new terminal and run: claude --version"
        ui::info "If still missing, try the Homebrew method: --brew"
        return 1
    fi
}

# ─── Method 2: Homebrew ───────────────────────────────────────────────────────

install_claude_cli::brew() {
    ui::info "Installing via Homebrew..."
    echo ""

    # Install Homebrew if not present (works on Linux too)
    if ! command -v brew &>/dev/null; then
        ui::info "Homebrew not found — installing Linuxbrew..."
        /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"

        # Add brew to PATH for this session (Linux path)
        local brew_paths=(
            "/home/linuxbrew/.linuxbrew/bin/brew"
            "/usr/local/bin/brew"
            "/opt/homebrew/bin/brew"
        )
        for bp in "${brew_paths[@]}"; do
            if [[ -x "$bp" ]]; then
                eval "$("$bp" shellenv)"
                break
            fi
        done

        # Persist brew to shell profile
        local profile="${HOME}/.bashrc"
        if ! grep -q 'brew shellenv' "$profile" 2>/dev/null; then
            echo "" >> "$profile"
            echo 'eval "$(/home/linuxbrew/.linuxbrew/bin/brew shellenv)"' >> "$profile"
            ui::ok "Homebrew PATH added to ${profile}"
        fi
    else
        ui::ok "Homebrew found: $(brew --version | head -1)"
    fi

    # Install Claude Code cask
    # claude-code = stable channel (recommended for demos)
    # claude-code@latest = bleeding edge
    brew install claude-code

    if command -v claude &>/dev/null; then
        ui::ok "Claude Code installed: $(claude --version 2>/dev/null)"
        return 0
    else
        ui::fail "brew install ran but 'claude' not found"
        return 1
    fi
}

# ─── Method 3: npm fallback ───────────────────────────────────────────────────

install_claude_cli::npm() {
    ui::info "Installing via npm..."
    echo ""

    if ! command -v node &>/dev/null; then
        ui::fail "Node.js not found"
        ui::info "Install: sudo pacman -S nodejs npm   (Arch/CachyOS)"
        ui::info "         sudo apt install nodejs npm  (Debian/Ubuntu)"
        return 1
    fi

    local node_ver
    node_ver=$(node --version | tr -d 'v' | cut -d. -f1)
    if (( node_ver < 18 )); then
        ui::fail "Node.js ${node_ver} too old — need 18+"
        return 1
    fi

    # Use a user-local prefix — no sudo needed
    local npm_prefix="${HOME}/.npm-global"
    mkdir -p "$npm_prefix"
    npm config set prefix "$npm_prefix"
    export PATH="${npm_prefix}/bin:$PATH"

    local profile="${HOME}/.bashrc"
    if ! grep -qF '.npm-global/bin' "$profile" 2>/dev/null; then
        echo "" >> "$profile"
        echo 'export PATH="${HOME}/.npm-global/bin:$PATH"' >> "$profile"
        ui::ok "npm global bin added to PATH in ${profile}"
    fi

    npm install -g @anthropic-ai/claude-code

    if command -v claude &>/dev/null; then
        ui::ok "Claude Code installed: $(claude --version 2>/dev/null)"
        return 0
    else
        ui::fail "npm install ran but 'claude' not found"
        return 1
    fi
}

# ─── API Key Setup ────────────────────────────────────────────────────────────

install_claude_cli::configure_api_key() {
    echo ""
    echo "  ── API Key Setup ──────────────────────────────"
    echo ""
    ui::info "Claude Code needs an ANTHROPIC_API_KEY to run agents."
    ui::info "Get yours free at: https://console.anthropic.com"
    echo ""

    if [[ -n "${ANTHROPIC_API_KEY:-}" ]]; then
        ui::ok "ANTHROPIC_API_KEY already set in environment"
        if ! ui::confirm "Replace with a different key?"; then
            return 0
        fi
    fi

    echo -en "  Enter your API key (sk-ant-...): "
    read -rs api_key
    echo ""

    if [[ -z "$api_key" ]]; then
        ui::warn "Skipped. Set it later:"
        echo ""
        echo '    echo '\''export ANTHROPIC_API_KEY=sk-ant-...'\'' >> ~/.bashrc'
        echo '    source ~/.bashrc'
        echo ""
        return 0
    fi

    if [[ "$api_key" != sk-ant-* ]]; then
        ui::warn "Unexpected format — saving anyway (expected sk-ant-...)"
    fi

    # Write to TuringOS config
    local turingos_config="${HOME}/.turingos/config.env"
    mkdir -p "$(dirname "$turingos_config")"
    grep -v '^ANTHROPIC_API_KEY=' "$turingos_config" 2>/dev/null > "${turingos_config}.tmp" || true
    echo "ANTHROPIC_API_KEY=${api_key}" >> "${turingos_config}.tmp"
    mv "${turingos_config}.tmp" "$turingos_config"

    # Write to shell profile
    local profile="${HOME}/.bashrc"
    grep -v 'ANTHROPIC_API_KEY' "$profile" 2>/dev/null > "${profile}.tmp" || true
    echo "" >> "${profile}.tmp"
    echo "# TuringOS — Anthropic API Key" >> "${profile}.tmp"
    echo "export ANTHROPIC_API_KEY=${api_key}" >> "${profile}.tmp"
    mv "${profile}.tmp" "$profile"

    export ANTHROPIC_API_KEY="$api_key"
    ui::ok "API key saved to ~/.turingos/config.env and ${profile}"
}

# ─── Main ─────────────────────────────────────────────────────────────────────

main() {
    local method="${1:-auto}"

    echo ""
    echo "  ╔═══════════════════════════════════════════╗"
    echo "  ║       Claude Code CLI Setup               ║"
    echo "  ╚═══════════════════════════════════════════╝"
    echo ""

    # Skip if already installed (unless forced)
    if [[ "$method" != "--force" ]]; then
        install_claude_cli::already_installed && {
            install_claude_cli::configure_api_key
            return 0
        }
    fi

    local installed=false

    case "$method" in
        --brew)
            install_claude_cli::brew && installed=true ;;
        --npm)
            install_claude_cli::npm && installed=true ;;
        --native)
            install_claude_cli::native && installed=true ;;
        *)
            # Auto: try native first, then brew, then npm
            ui::info "Trying native installer first (Anthropic recommended)..."
            echo ""
            if install_claude_cli::native; then
                installed=true
            else
                echo ""
                ui::warn "Native installer failed — trying Homebrew..."
                echo ""
                if command -v brew &>/dev/null || ui::confirm "Install Homebrew?"; then
                    install_claude_cli::brew && installed=true
                fi
            fi

            if ! $installed; then
                echo ""
                ui::warn "Falling back to npm..."
                echo ""
                install_claude_cli::npm && installed=true
            fi
            ;;
    esac

    if ! $installed; then
        echo ""
        ui::fail "Could not install Claude Code CLI automatically"
        ui::info "Install manually: https://code.claude.com/docs/en/installation"
        return 1
    fi

    install_claude_cli::configure_api_key

    echo ""
    ui::ok "Setup complete. Test with: claude --version"
    ui::info "Then run: turingos agent start"
    echo ""
}

main "${1:-}"
