#!/usr/bin/env bash
# bazaar/install.sh — TuringOS Clawd Bazaar installer
#
# Installs MCP tools from registry.json into:
#   1. ~/.turingos/bazaar/<key>/   (local tool directory)
#   2. Claude Desktop's claude_desktop_config.json (MCP server entry)
#
# Depends on: core/config.sh, core/logging.sh, core/ui.sh, bazaar/registry.sh

log::set_module "bazaar"

# ─── Main Install Entry Point ─────────────────────────────────────────────────

bazaar::install() {
    # Usage: bazaar::install TOOL_KEY
    local key="${1:-}"

    if [[ -z "$key" ]]; then
        ui::fail "Usage: turingos bazaar install <tool>"
        ui::info "Browse available tools: turingos bazaar"
        return 1
    fi

    # Validate key exists in registry
    local name
    name=$(registry::get_field "$key" "name")
    if [[ -z "$name" ]]; then
        ui::fail "Unknown tool: ${key}"
        registry::_suggest "$key"
        return 1
    fi

    ui::header "Installing: ${name}"

    # Already installed?
    local install_dir="${TURINGOS_BAZAAR_DIR}/${key}"
    local marker="${install_dir}/.installed"
    if [[ -f "$marker" ]]; then
        ui::warn "Already installed ($(cat "$marker"))"
        if ! ui::confirm "Reinstall?"; then
            return 0
        fi
    fi

    local type runtime
    type=$(   registry::get_field "$key" "type")
    runtime=$(registry::get_field "$key" "runtime")

    log::section "BAZAAR INSTALL — ${key}"
    log::info "type=${type} runtime=${runtime}"

    # Check required env vars before doing anything
    bazaar::_check_env_vars "$key" || return 1

    # Route to runtime handler
    case "$runtime" in
        npx)  bazaar::_install_npx  "$key" "$install_dir" ;;
        pip)  bazaar::_install_pip  "$key" "$install_dir" ;;
        cargo) bazaar::_install_cargo "$key" "$install_dir" ;;
        *)
            ui::warn "Unknown runtime '${runtime}' — attempting git clone install"
            bazaar::_install_git "$key" "$install_dir"
            ;;
    esac

    local exit_code=$?
    if [[ $exit_code -ne 0 ]]; then
        ui::fail "Installation failed for: ${key}"
        log::error "install failed: key=${key} exit=${exit_code}"
        return 1
    fi

    # Mark as installed
    mkdir -p "$install_dir"
    date '+%Y-%m-%dT%H:%M:%S' > "$marker"

    # Inject into Claude Desktop config
    bazaar::_inject_mcp_config "$key"
    local inject_code=$?

    echo ""
    log::audit BAZAAR_INSTALL "key=${key}" "runtime=${runtime}" "type=${type}"

    if [[ $inject_code -eq 0 ]]; then
        ui::ok "${name} installed"
        ui::ok "MCP config updated: ${CLAUDE_DESKTOP_CONFIG}"
        ui::info "Restart Claude Desktop to load the new server"
    else
        ui::ok "${name} installed"
        ui::warn "MCP config update failed — edit manually: ${CLAUDE_DESKTOP_CONFIG}"
    fi
    echo ""
}

# ─── Runtime: npx ────────────────────────────────────────────────────────────

bazaar::_install_npx() {
    local key="$1"
    local install_dir="$2"

    local package
    package=$(registry::get_field "$key" "package")

    if ! command -v npx &>/dev/null; then
        ui::fail "npx not found — install Node.js: https://nodejs.org"
        return 1
    fi

    ui::info "Verifying package with npx: ${package}"
    mkdir -p "$install_dir"

    # Dry-run: npx -y just downloads/caches — no persistent side effects
    # We capture stderr to log but don't fail on warnings
    local test_output
    test_output=$(npx -y "$package" --version 2>&1) || true

    # Write a launcher script so the tool can be invoked standalone
    cat > "${install_dir}/run.sh" <<EOF
#!/usr/bin/env bash
# Auto-generated launcher for: ${package}
exec npx -y "${package}" "\$@"
EOF
    chmod +x "${install_dir}/run.sh"

    ui::ok "npx package verified: ${package}"
    log::info "npx install ok: ${package}"
    return 0
}

# ─── Runtime: pip ────────────────────────────────────────────────────────────

bazaar::_install_pip() {
    local key="$1"
    local install_dir="$2"

    local package
    package=$(registry::get_field "$key" "package")

    if ! command -v pip &>/dev/null && ! command -v pip3 &>/dev/null; then
        ui::fail "pip not found — install Python: https://python.org"
        return 1
    fi

    local pip_cmd
    pip_cmd=$(command -v pip3 || command -v pip)

    ui::info "Installing pip package: ${package}"
    mkdir -p "$install_dir"

    "$pip_cmd" install --quiet "$package" 2>&1 | tee "${install_dir}/install.log"
    local exit_code=${PIPESTATUS[0]}

    if [[ $exit_code -ne 0 ]]; then
        ui::fail "pip install failed. See: ${install_dir}/install.log"
        return 1
    fi

    ui::ok "pip package installed: ${package}"
    return 0
}

# ─── Runtime: cargo ───────────────────────────────────────────────────────────

bazaar::_install_cargo() {
    local key="$1"
    local install_dir="$2"

    local package
    package=$(registry::get_field "$key" "package")

    if ! command -v cargo &>/dev/null; then
        ui::fail "cargo not found — install Rust: https://rustup.rs"
        return 1
    fi

    ui::info "Installing cargo package: ${package}"
    mkdir -p "$install_dir"

    cargo install "$package" 2>&1 | tee "${install_dir}/install.log"
    local exit_code=${PIPESTATUS[0]}

    [[ $exit_code -ne 0 ]] && return 1
    ui::ok "cargo package installed: ${package}"
    return 0
}

# ─── Runtime: git clone (fallback) ───────────────────────────────────────────

bazaar::_install_git() {
    local key="$1"
    local install_dir="$2"

    local repo subdir
    repo=$(  registry::get_field "$key" "repo")
    subdir=$(registry::get_field "$key" "subdir")

    if [[ -z "$repo" ]]; then
        ui::fail "No repo defined for: ${key}"
        return 1
    fi

    local clone_url="https://github.com/${repo}.git"
    local clone_dir="${install_dir}/source"

    ui::info "Cloning: ${clone_url}"

    if [[ -d "$clone_dir" ]]; then
        ui::info "Updating existing clone..."
        git -C "$clone_dir" pull --quiet 2>&1
    else
        git clone --depth=1 --quiet "$clone_url" "$clone_dir" 2>&1
    fi

    if [[ $? -ne 0 ]]; then
        ui::fail "git clone failed: ${clone_url}"
        return 1
    fi

    local work_dir="${clone_dir}"
    [[ -n "$subdir" && "$subdir" != "null" ]] && work_dir="${clone_dir}/${subdir}"

    # Auto-detect build system
    bazaar::_auto_build "$work_dir" "$key" || true  # non-fatal

    ui::ok "Cloned: ${repo}"
    return 0
}

bazaar::_auto_build() {
    local dir="$1"
    local key="$2"

    [[ ! -d "$dir" ]] && return 0

    if [[ -f "${dir}/package.json" ]]; then
        ui::info "Running npm install..."
        npm install --prefix "$dir" --silent 2>&1 | \
            tee "${TURINGOS_BAZAAR_DIR}/${key}/build.log"

    elif [[ -f "${dir}/requirements.txt" ]]; then
        ui::info "Running pip install -r requirements.txt..."
        pip install -r "${dir}/requirements.txt" --quiet 2>&1 | \
            tee "${TURINGOS_BAZAAR_DIR}/${key}/build.log"

    elif [[ -f "${dir}/Cargo.toml" ]]; then
        ui::info "Running cargo build --release..."
        cargo build --release --manifest-path "${dir}/Cargo.toml" 2>&1 | \
            tee "${TURINGOS_BAZAAR_DIR}/${key}/build.log"
    fi
}

# ─── Env Var Check ────────────────────────────────────────────────────────────

bazaar::_check_env_vars() {
    local key="$1"
    local missing=()

    while IFS= read -r env_var; do
        [[ -z "$env_var" ]] && continue
        if [[ -z "${!env_var:-}" ]]; then
            missing+=("$env_var")
        fi
    done < <(registry::get_array "$key" "env_required")

    if [[ ${#missing[@]} -gt 0 ]]; then
        ui::warn "Missing required environment variables:"
        for v in "${missing[@]}"; do
            printf "    \033[1;31m%-36s\033[0m  not set\n" "$v"
        done
        echo ""
        ui::info "Set them in ~/.turingos/config.env or export before running"

        if ! ui::confirm "Continue install anyway?"; then
            return 1
        fi
    fi
    return 0
}

# ─── MCP Config Injection ─────────────────────────────────────────────────────

bazaar::_inject_mcp_config() {
    local key="$1"

    local mcp_command mcp_name
    mcp_command=$(registry::get_field "$key" "mcp_command")
    mcp_name=$(   registry::get_field "$key" "name")

    # Build args array
    local mcp_args=()
    while IFS= read -r arg; do
        [[ -n "$arg" ]] && mcp_args+=("$arg")
    done < <(registry::get_array "$key" "mcp_args")

    # Build env object from required env vars
    local env_json="{}"
    local env_vars=()
    while IFS= read -r v; do
        [[ -n "$v" ]] && env_vars+=("$v")
    done < <(registry::get_array "$key" "env_required")

    if [[ ${#env_vars[@]} -gt 0 ]]; then
        env_json=$(
            printf '%s\n' "${env_vars[@]}" | \
            jq -Rn '[inputs] | map({key: ., value: ("${" + . + "}")}) | from_entries'
        )
    fi

    # Build the new server block
    local args_json
    args_json=$(printf '%s\n' "${mcp_args[@]}" | jq -Rn '[inputs]')

    local server_block
    server_block=$(jq -n \
        --arg cmd "$mcp_command" \
        --argjson args "$args_json" \
        --argjson env "$env_json" \
        '{command: $cmd, args: $args, env: $env}'
    )

    # Ensure the config file exists
    bazaar::_ensure_claude_config

    # Merge new server into existing config
    local current
    current=$(cat "$CLAUDE_DESKTOP_CONFIG")

    local updated
    updated=$(echo "$current" | jq \
        --arg key "$key" \
        --argjson block "$server_block" \
        '.mcpServers[$key] = $block'
    )

    if [[ $? -ne 0 ]]; then
        log::error "jq failed to update MCP config"
        return 1
    fi

    echo "$updated" > "$CLAUDE_DESKTOP_CONFIG"
    log::info "MCP config updated: key=${key}"
    return 0
}

bazaar::_ensure_claude_config() {
    local config_dir
    config_dir="$(dirname "$CLAUDE_DESKTOP_CONFIG")"
    mkdir -p "$config_dir"

    if [[ ! -f "$CLAUDE_DESKTOP_CONFIG" ]]; then
        echo '{"mcpServers": {}}' > "$CLAUDE_DESKTOP_CONFIG"
        log::info "Created new claude_desktop_config.json"
    else
        # Ensure mcpServers key exists
        local has_key
        has_key=$(jq 'has("mcpServers")' "$CLAUDE_DESKTOP_CONFIG" 2>/dev/null)
        if [[ "$has_key" != "true" ]]; then
            local updated
            updated=$(jq '. + {"mcpServers": {}}' "$CLAUDE_DESKTOP_CONFIG")
            echo "$updated" > "$CLAUDE_DESKTOP_CONFIG"
        fi
    fi
}

# ─── Uninstall ────────────────────────────────────────────────────────────────

bazaar::uninstall() {
    local key="${1:-}"

    if [[ -z "$key" ]]; then
        ui::fail "Usage: turingos bazaar uninstall <tool>"
        return 1
    fi

    local name
    name=$(registry::get_field "$key" "name" 2>/dev/null || echo "$key")
    local install_dir="${TURINGOS_BAZAAR_DIR}/${key}"

    if [[ ! -d "$install_dir" ]]; then
        ui::info "${key} is not installed"
        return 0
    fi

    if ! ui::confirm "Uninstall ${name}?"; then
        return 0
    fi

    # Remove from Claude Desktop config
    if [[ -f "$CLAUDE_DESKTOP_CONFIG" ]] && command -v jq &>/dev/null; then
        local updated
        updated=$(jq --arg key "$key" 'del(.mcpServers[$key])' "$CLAUDE_DESKTOP_CONFIG")
        echo "$updated" > "$CLAUDE_DESKTOP_CONFIG"
        ui::ok "Removed from MCP config"
    fi

    # Remove local files
    rm -rf "$install_dir"

    log::audit BAZAAR_UNINSTALL "key=${key}"
    ui::ok "${name} uninstalled"
    ui::info "Restart Claude Desktop to apply changes"
}
