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
    # Usage: bazaar::install [-y] TOOL_KEY
    local key="${1:-}" name runtime install_dir marker force=0
    if [[ "$key" == "-y" || "$key" == "--yes" ]]; then
        force=1
        key="${2:-}"
    elif [[ "${2:-}" == "-y" || "${2:-}" == "--yes" ]]; then
        force=1
    fi

    if [[ -z "$key" ]]; then
        ui::fail "Usage: turingos bazaar install [-y] <tool>"
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
        if (( ! force )); then
            ui::confirm "Reinstall?" || return 0
        fi
    fi

    runtime=$(registry::get_field "$key" runtime)
    log::section "BAZAAR INSTALL — ${key}"
    log::info "runtime=${runtime}"

    bazaar::_check_env_vars "$key" || return 1
    mkdir -p "$install_dir"

    local ok=true
    case "$runtime" in
        npx)     bazaar::_install_npx     "$key" "$install_dir" || ok=false ;;
        pip)     bazaar::_install_pipx    "$key" "$install_dir" || ok=false ;;
        cargo)   bazaar::_install_cargo   "$key" "$install_dir" || ok=false ;;
        archive) bazaar::_install_archive "$key" "$install_dir" || ok=false ;;
        *)       bazaar::_install_git     "$key" "$install_dir" || ok=false ;;
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
    local entry_type
    entry_type=$(registry::get_field "$key" type)
    if [[ "$entry_type" == "mcp" || -z "$entry_type" ]]; then
        if bazaar::_register_mcp "$key"; then
            ui::ok "MCP server registered in ${CLAUDE_CODE_CONFIG}"
            ui::info "New Claude Code sessions pick it up automatically"
        else
            ui::warn "MCP registration failed — add it with: claude mcp add --scope user ${key} ..."
        fi
    else
        ui::ok "${entry_type^} ready in ${install_dir}"
    fi
    echo ""
}

# ─── Runtimes ────────────────────────────────────────────────────────────────

bazaar::_install_npx() {
    local key="$1" install_dir="$2" package version sha256 tarball_url tmp_tarball
    package=$(registry::get_field "$key" package)
    version=$(registry::get_field "$key" version)
    sha256=$(registry::get_field "$key" sha256)
    if ! command -v npm &>/dev/null; then
        ui::fail "npm not found — install Node.js: sudo apt install nodejs npm"
        return 1
    fi

    local pkg_spec="$package"
    [[ -n "$version" ]] && pkg_spec="${package}@${version}"

    # Verify sha256 of upstream tarball if pinned
    if [[ -n "$sha256" && -n "$version" ]]; then
        tarball_url=$(npm view "$pkg_spec" dist.tarball 2>/dev/null || echo "")
        if [[ -n "$tarball_url" ]] && command -v curl &>/dev/null && (command -v sha256sum &>/dev/null || command -v shasum &>/dev/null); then
            ui::info "Verifying SHA-256 for ${pkg_spec}..."
            tmp_tarball=$(mktemp "${install_dir}/pkg.XXXXXX.tgz" 2>/dev/null || mktemp /tmp/turingos_pkg.XXXXXX.tgz 2>/dev/null || echo "${install_dir}/pkg.tgz")
            if curl --silent --fail --max-time 15 --location "$tarball_url" -o "$tmp_tarball" 2>/dev/null; then
                local actual_hash
                if command -v sha256sum &>/dev/null; then
                    actual_hash=$(sha256sum "$tmp_tarball" | awk '{print $1}')
                else
                    actual_hash=$(shasum -a 256 "$tmp_tarball" | awk '{print $1}')
                fi
                rm -f "$tmp_tarball" 2>/dev/null || true
                if [[ "$actual_hash" != "$sha256" ]]; then
                    ui::fail "SHA-256 mismatch for ${pkg_spec}: expected ${sha256}, got ${actual_hash}"
                    log::error "sha256 mismatch: key=${key} expected=${sha256} actual=${actual_hash}"
                    return 1
                fi
                ui::ok "SHA-256 verified (${actual_hash:0:12}...)"
            else
                rm -f "$tmp_tarball" 2>/dev/null || true
            fi
        fi
    fi

    # Look the package up without running it (a stdio MCP server never exits)
    ui::info "Checking npm package: ${pkg_spec}"
    if ! npm view "$pkg_spec" version &>/dev/null; then
        ui::fail "npm package not found: ${pkg_spec}"
        return 1
    fi

    cat > "${install_dir}/run.sh" <<EOF
#!/usr/bin/env bash
# Auto-generated launcher for: ${pkg_spec}
exec npx -y "${pkg_spec}" "\$@"
EOF
    chmod +x "${install_dir}/run.sh"
    ui::ok "npm package found: ${pkg_spec}"
}

bazaar::_install_archive() {
    local key="$1" install_dir="$2" package version sha256 url tmp_archive
    package=$(registry::get_field "$key" package)
    version=$(registry::get_field "$key" version)
    sha256=$(registry::get_field "$key" sha256)
    url=$(registry::get_field "$key" url)
    [[ -z "$url" ]] && url="$package"

    if [[ -z "$url" ]]; then
        ui::fail "No package archive URL specified for: ${key}"
        return 1
    fi

    ui::info "Downloading archive: ${url}"
    tmp_archive=$(mktemp "${install_dir}/archive.XXXXXX.tar.gz" 2>/dev/null || mktemp /tmp/turingos_arch.XXXXXX.tar.gz 2>/dev/null || echo "${install_dir}/archive.tar.gz")
    
    if [[ "$url" =~ ^file:// ]]; then
        local file_path="${url#file://}"
        if [[ -f "$file_path" ]]; then
            cp "$file_path" "$tmp_archive"
        else
            ui::fail "File not found: ${file_path}"
            rm -f "$tmp_archive" 2>/dev/null || true
            return 1
        fi
    elif [[ -f "$url" ]]; then
        cp "$url" "$tmp_archive"
    else
        if ! curl --silent --fail --max-time 30 --location "$url" -o "$tmp_archive" 2>/dev/null; then
            ui::fail "Failed to download archive: ${url}"
            rm -f "$tmp_archive" 2>/dev/null || true
            return 1
        fi
    fi

    if [[ -n "$sha256" ]]; then
        local actual_hash
        if command -v sha256sum &>/dev/null; then
            actual_hash=$(sha256sum "$tmp_archive" | awk '{print $1}')
        else
            actual_hash=$(shasum -a 256 "$tmp_archive" | awk '{print $1}')
        fi
        if [[ "$actual_hash" != "$sha256" ]]; then
            ui::fail "SHA-256 mismatch for ${key}: expected ${sha256}, got ${actual_hash}"
            log::error "sha256 mismatch: key=${key} expected=${sha256} actual=${actual_hash}"
            rm -f "$tmp_archive" 2>/dev/null || true
            return 1
        fi
        ui::ok "SHA-256 verified (${actual_hash:0:12}...)"
    fi

    mkdir -p "${install_dir}/unpacked"
    tar -xzf "$tmp_archive" -C "${install_dir}/unpacked" || {
        ui::fail "Failed to unpack archive"
        rm -f "$tmp_archive" 2>/dev/null || true
        return 1
    }
    rm -f "$tmp_archive" 2>/dev/null || true
    ui::ok "Archive unpacked to ${install_dir}/unpacked"
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
    # Usage: bazaar::uninstall [-y] TOOL_KEY
    local key="${1:-}" name install_dir force=0
    if [[ "$key" == "-y" || "$key" == "--yes" ]]; then
        force=1
        key="${2:-}"
    elif [[ "${2:-}" == "-y" || "${2:-}" == "--yes" ]]; then
        force=1
    fi

    if [[ -z "$key" ]]; then
        ui::fail "Usage: turingos bazaar uninstall [-y] <tool>"
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
    if (( ! force )); then
        ui::confirm "Uninstall ${name:-$key}?" || return 0
    fi

    if [[ -f "$CLAUDE_CODE_CONFIG" ]] && bazaar::_edit_claude_config 'del(.mcpServers[$k])' --arg k "$key"; then
        ui::ok "Removed from ${CLAUDE_CODE_CONFIG}"
    fi
    rm -rf "$install_dir"
    log::audit BAZAAR_UNINSTALL "key=${key}"
    ui::ok "${name:-$key} uninstalled"
}
