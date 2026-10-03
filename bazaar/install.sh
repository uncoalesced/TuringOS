#!/usr/bin/env bash
# bazaar/install.sh — TuringOS Clawd Bazaar installer
#
# Installs MCP tools from registry.json into:
#   1. ~/.turingos/bazaar/<key>/   (local tool directory)
#   2. Claude Code's user config (~/.claude.json .mcpServers), so every
#      agent session can use the server
#
# Depends on: core/config.sh, core/logging.sh, core/ui.sh, bazaar/registry.sh

# ─── Main Install Entry Point ─────────────────────────────────────────────────

bazaar::install() {
    # Usage: bazaar::install TOOL_KEY
    local key="${1:-}" name runtime install_dir marker
    if [[ -z "$key" ]]; then
        ui::fail "Usage: turingos bazaar install <tool>"
        ui::info "Browse available tools: turingos bazaar"
        return 1
    fi

    name=$(registry::get_field "$key" name)
    if [[ -z "$name" ]]; then
        ui::fail "Unknown tool: ${key}"
        registry::_suggest "$key"
        return 1
    fi

    ui::header "Installing: ${name}"
    install_dir="${TURINGOS_BAZAAR_DIR}/${key}"
    marker="${install_dir}/.installed"
    if [[ -f "$marker" ]]; then
        ui::warn "Already installed ($(cat "$marker"))"
        ui::confirm "Reinstall?" || return 0
    fi

    runtime=$(registry::get_field "$key" runtime)
    log::section "BAZAAR INSTALL — ${key}"
    log::info "runtime=${runtime}"

    bazaar::_check_env_vars "$key" || return 1
    mkdir -p "$install_dir"

    local ok=true
    case "$runtime" in
        npx)   bazaar::_install_npx   "$key" "$install_dir" || ok=false ;;
        pip)   bazaar::_install_pipx  "$key" "$install_dir" || ok=false ;;
        cargo) bazaar::_install_cargo "$key" "$install_dir" || ok=false ;;
        *)     bazaar::_install_git   "$key" "$install_dir" || ok=false ;;
    esac
    if ! $ok; then
        ui::fail "Installation failed for: ${key}"
        log::error "install failed: key=${key}"
        return 1
    fi

    date '+%Y-%m-%dT%H:%M:%S' > "$marker"
    log::audit BAZAAR_INSTALL "key=${key}" "runtime=${runtime}"

    echo ""
    ui::ok "${name} installed"
    if bazaar::_register_mcp "$key"; then
        ui::ok "MCP server registered in ${CLAUDE_CODE_CONFIG}"
        ui::info "New Claude Code sessions pick it up automatically"
    else
        ui::warn "MCP registration failed — add it with: claude mcp add --scope user ${key} ..."
    fi
    echo ""
}

# ─── Runtimes ────────────────────────────────────────────────────────────────

bazaar::_install_npx() {
    local key="$1" install_dir="$2" package
    package=$(registry::get_field "$key" package)
    if ! command -v npm &>/dev/null; then
        ui::fail "npm not found — install Node.js: sudo apt install nodejs npm"
        return 1
    fi

    # Look the package up without running it (a stdio MCP server never exits)
    ui::info "Checking npm package: ${package}"
    if ! npm view "$package" version &>/dev/null; then
        ui::fail "npm package not found: ${package}"
        return 1
    fi

    cat > "${install_dir}/run.sh" <<EOF
#!/usr/bin/env bash
# Auto-generated launcher for: ${package}
exec npx -y "${package}" "\$@"
EOF
    chmod +x "${install_dir}/run.sh"
    ui::ok "npm package found: ${package}"
}

bazaar::_install_pipx() {
    # Debian marks the system Python as externally managed (PEP 668): use pipx
    local key="$1" install_dir="$2" package
    package=$(registry::get_field "$key" package)
    if ! command -v pipx &>/dev/null; then
        ui::fail "pipx not found — install: sudo apt install pipx"
        return 1
    fi
    ui::info "Installing with pipx: ${package}"
    pipx install --force "$package" 2>&1 | tee "${install_dir}/install.log"
}

bazaar::_install_cargo() {
    local key="$1" install_dir="$2" package
    package=$(registry::get_field "$key" package)
    if ! command -v cargo &>/dev/null; then
        ui::fail "cargo not found — install: sudo apt install cargo"
        return 1
    fi
    ui::info "Installing cargo package: ${package}"
    cargo install "$package" 2>&1 | tee "${install_dir}/install.log"
}

bazaar::_install_git() {
    local key="$1" install_dir="$2" repo subdir
    repo=$(registry::get_field "$key" repo)
    subdir=$(registry::get_field "$key" subdir)
    if [[ -z "$repo" ]]; then
        ui::fail "No repo defined for: ${key}"
        return 1
    fi

    local clone_dir="${install_dir}/source"
    ui::info "Cloning: https://github.com/${repo}.git"
    if [[ -d "$clone_dir" ]]; then
        git -C "$clone_dir" pull --quiet || return 1
    else
        git clone --depth=1 --quiet "https://github.com/${repo}.git" "$clone_dir" || return 1
    fi

    bazaar::_auto_build "${clone_dir}${subdir:+/${subdir}}" "${install_dir}/build.log" \
        || ui::warn "Build step failed — see ${install_dir}/build.log"
    ui::ok "Cloned: ${repo}"
}

bazaar::_auto_build() {
    local dir="$1" log="$2"
    [[ -d "$dir" ]] || return 0
    if [[ -f "${dir}/package.json" ]]; then
        ui::info "Running npm install..."
        npm install --prefix "$dir" --silent > "$log" 2>&1
    elif [[ -f "${dir}/requirements.txt" ]]; then
        ui::info "Installing requirements into ${dir}/.venv..."
        python3 -m venv "${dir}/.venv" > "$log" 2>&1 \
            && "${dir}/.venv/bin/pip" install --quiet -r "${dir}/requirements.txt" >> "$log" 2>&1
    elif [[ -f "${dir}/Cargo.toml" ]]; then
        ui::info "Running cargo build --release..."
        cargo build --release --manifest-path "${dir}/Cargo.toml" > "$log" 2>&1
    fi
}

# ─── Env Var Check ────────────────────────────────────────────────────────────

bazaar::_check_env_vars() {
    local key="$1" env_var missing=()
    while IFS= read -r env_var; do
        [[ -n "$env_var" && -z "${!env_var:-}" ]] && missing+=("$env_var")
    done < <(registry::get_array "$key" env_required)
    (( ${#missing[@]} )) || return 0

    ui::warn "Missing required environment variables:"
    for env_var in "${missing[@]}"; do
        printf '    %b%-36s%b  not set\n' "$BOLD_RED" "$env_var" "$RESET"
    done
    echo ""
    ui::info "Add KEY=value lines to ${TURINGOS_CONFIG_FILE}, or export them"
    ui::confirm "Continue install anyway?"
}

# ─── Claude Code MCP Registration ─────────────────────────────────────────────

bazaar::_edit_claude_config() {
    # Usage: bazaar::_edit_claude_config JQ_FILTER [jq args...] — atomic, mode 600
    local filter="$1" tmp current="{}"
    shift
    [[ -s "$CLAUDE_CODE_CONFIG" ]] && current=$(cat "$CLAUDE_CODE_CONFIG")
    tmp=$(mktemp "${CLAUDE_CODE_CONFIG}.XXXXXX")
    if jq "$@" "$filter" <<< "$current" > "$tmp"; then
        chmod 600 "$tmp"
        mv -f "$tmp" "$CLAUDE_CODE_CONFIG"
    else
        rm -f "$tmp"
        return 1
    fi
}

bazaar::_register_mcp() {
    local key="$1" arg var pattern env_vars=() args=() env_args=()
    mapfile -t env_vars < <(registry::get_array "$key" env_required)

    # Args may reference ${HOME} or a required env var; expand them now
    while IFS= read -r arg; do
        for var in HOME "${env_vars[@]}"; do
            pattern='${'"$var"'}'
            arg="${arg//"$pattern"/${!var:-}}"
        done
        args+=("$arg")
    done < <(registry::get_array "$key" mcp_args)

    for var in "${env_vars[@]}"; do
        env_args+=(--arg "$var" "${!var:-}")
    done

    # Via stdin, not --args: jq reads an arg like "-y" as its own option
    local server args_json='[]'
    if (( ${#args[@]} )); then
        args_json=$(printf '%s\0' "${args[@]}" | jq -Rs 'split("\u0000")[:-1]')
    fi
    server=$(jq -n --arg cmd "$(registry::get_field "$key" mcp_command)" \
        --argjson args "$args_json" \
        --argjson env "$(jq -n "${env_args[@]}" '$ARGS.named')" \
        '{type: "stdio", command: $cmd, args: $args, env: $env}') || return 1

    bazaar::_edit_claude_config '.mcpServers[$k] = $s' --arg k "$key" --argjson s "$server" || return 1
    log::info "MCP server registered: key=${key}"
}

# ─── Uninstall ────────────────────────────────────────────────────────────────

bazaar::uninstall() {
    local key="${1:-}" name install_dir
    if [[ -z "$key" ]]; then
        ui::fail "Usage: turingos bazaar uninstall <tool>"
        return 1
    fi

    name=$(registry::get_field "$key" name)
    # A registry key, or (for a tool dropped from the registry) a bare name:
    # never a path, so rm -rf can't leave the Bazaar directory
    if [[ -z "$name" && ! "$key" =~ ^[A-Za-z0-9][A-Za-z0-9_-]*$ ]]; then
        ui::fail "Unknown tool: ${key}"
        return 1
    fi
    install_dir="${TURINGOS_BAZAAR_DIR}/${key}"
    if [[ ! -d "$install_dir" || -L "$install_dir" ]]; then
        ui::info "${key} is not installed"
        return 0
    fi
    if [[ "$(dirname -- "$(realpath -e -- "$install_dir")")" != "$(realpath -e -- "$TURINGOS_BAZAAR_DIR")" ]]; then
        ui::fail "Refusing to remove ${install_dir}: outside ${TURINGOS_BAZAAR_DIR}"
        log::error "bazaar uninstall refused: ${key}"
        return 1
    fi
    ui::confirm "Uninstall ${name:-$key}?" || return 0

    if [[ -f "$CLAUDE_CODE_CONFIG" ]] && bazaar::_edit_claude_config 'del(.mcpServers[$k])' --arg k "$key"; then
        ui::ok "Removed from ${CLAUDE_CODE_CONFIG}"
    fi
    rm -rf "$install_dir"
    log::audit BAZAAR_UNINSTALL "key=${key}"
    ui::ok "${name:-$key} uninstalled"
}
