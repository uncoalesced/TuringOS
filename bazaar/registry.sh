#!/usr/bin/env bash
# Engineered by uncoalesced
# bazaar/registry.sh — TuringOS Clawd Bazaar registry reader
#
# Loads and queries remote index or bundled fallback. Provides browsing/search UI.
# Install logic lives in bazaar/install.sh.
#
# Depends on: core/config.sh, core/logging.sh, core/ui.sh

export TURINGOS_ACTIVE_REGISTRY=""
export TURINGOS_BAZAAR_OFFLINE=0

# ─── Registry Access ──────────────────────────────────────────────────────────

registry::_is_cache_fresh() {
    local cache="$1"
    [[ -f "$cache" ]] || return 1
    
    local now mtime age
    now=$(date +%s)
    mtime=$(date -r "$cache" +%s 2>/dev/null || stat -c %Y "$cache" 2>/dev/null || echo 0)
    age=$(( now - mtime ))
    (( age >= 0 && age < 86400 ))
}

registry::_fetch_remote() {
    local cache="$1" tmp tmp_sig pubkey
    if [[ "${TURINGOS_BAZAAR_OFFLINE_MODE:-0}" == "1" ]]; then
        return 1
    fi

    tmp=$(mktemp "${cache}.tmp.XXXXXX" 2>/dev/null || mktemp /tmp/turingos_bazaar.XXXXXX 2>/dev/null || echo "${cache}.tmp")
    local fetched=0

    if [[ "$TURINGOS_BAZAAR_REMOTE_URL" =~ ^file:// ]]; then
        local file_path="${TURINGOS_BAZAAR_REMOTE_URL#file://}"
        [[ "$file_path" =~ ^/[A-Za-z]: ]] && file_path="${file_path:1}"
        if [[ -f "$file_path" ]]; then
            cp "$file_path" "$tmp" && fetched=1
        fi
    elif command -v curl &>/dev/null; then
        if curl --silent --fail --max-time 5 --location "$TURINGOS_BAZAAR_REMOTE_URL" -o "$tmp" 2>/dev/null; then
            fetched=1
        fi
    fi

    if (( fetched )); then
        if jq -e '(.entries // .tools) | type == "object"' "$tmp" &>/dev/null; then
            # Verify Ed25519 detached signature if public key is present
            pubkey="${TURINGOS_BAZAAR_PUBKEY:-/etc/turingos/trust/bazaar.pub}"
            if [[ ! -f "$pubkey" && -f "${ROOT:-.}/trust/keys/bazaar.pub" ]]; then
                pubkey="${ROOT:-.}/trust/keys/bazaar.pub"
            fi
            if [[ -f "$pubkey" ]] && command -v openssl &>/dev/null; then
                local sig_url="${TURINGOS_BAZAAR_REMOTE_URL}.sig"
                tmp_sig=$(mktemp "${cache}.sig.XXXXXX" 2>/dev/null || mktemp /tmp/turingos_bazaar_sig.XXXXXX 2>/dev/null || echo "${cache}.sig")
                local sig_fetched=0
                if [[ "$sig_url" =~ ^file:// ]]; then
                    local sig_path="${sig_url#file://}"
                    [[ "$sig_path" =~ ^/[A-Za-z]: ]] && sig_path="${sig_path:1}"
                    if [[ -f "$sig_path" ]]; then
                        cp "$sig_path" "$tmp_sig" && sig_fetched=1
                    fi
                elif command -v curl &>/dev/null; then
                    if curl --silent --fail --max-time 5 --location "$sig_url" -o "$tmp_sig" 2>/dev/null; then
                        sig_fetched=1
                    fi
                fi

                if (( sig_fetched )); then
                    if ! openssl pkeyutl -verify -pubin -inkey "$pubkey" -rawin -in "$tmp" -sigfile "$tmp_sig" &>/dev/null; then
                        ui::warn "Bazaar index signature verification failed! Rejecting untrusted catalog."
                        log::error "bazaar index signature verification failed against $pubkey"
                        rm -f "$tmp" "$tmp_sig" 2>/dev/null || true
                        return 1
                    fi
                    log::audit BAZAAR_INDEX_VERIFIED "pubkey=${pubkey}"
                fi
                rm -f "$tmp_sig" 2>/dev/null || true
            fi

            mkdir -p "$(dirname "$cache")" 2>/dev/null || true
            mv -f "$tmp" "$cache"
            return 0
        fi
    fi
    rm -f "$tmp" 2>/dev/null || true
    return 1
}

registry::_load() {
    if ! command -v jq &>/dev/null; then
        ui::fail "jq is required for the Bazaar. Install: sudo apt install jq"
        return 1
    fi

    local cache="${TURINGOS_BAZAAR_CACHE:-${HOME}/.cache/turingos/bazaar/index.json}"
    
    if registry::_is_cache_fresh "$cache"; then
        TURINGOS_ACTIVE_REGISTRY="$cache"
        TURINGOS_BAZAAR_OFFLINE=0
        return 0
    fi

    # Cache missing or expired; try remote fetch
    if registry::_fetch_remote "$cache"; then
        TURINGOS_ACTIVE_REGISTRY="$cache"
        TURINGOS_BAZAAR_OFFLINE=0
        return 0
    fi

    # Remote fetch failed. Try stale cache first, then bundled snapshot.
    if [[ -f "$cache" ]] && jq -e '(.entries // .tools) | type == "object"' "$cache" &>/dev/null; then
        TURINGOS_ACTIVE_REGISTRY="$cache"
        TURINGOS_BAZAAR_OFFLINE=1
        return 0
    fi

    if [[ -f "$TURINGOS_REGISTRY" ]] && jq -e '(.entries // .tools) | type == "object"' "$TURINGOS_REGISTRY" &>/dev/null; then
        TURINGOS_ACTIVE_REGISTRY="$TURINGOS_REGISTRY"
        TURINGOS_BAZAAR_OFFLINE=1
        return 0
    fi

    ui::fail "Registry not found (tried remote, cache, and bundled: $TURINGOS_REGISTRY)"
    log::error "registry file missing: $TURINGOS_REGISTRY"
    return 1
}

registry::get_field() {
    # Usage: registry::get_field KEY FIELD — scalar field, or ", "-joined array
    registry::_load || return 1
    jq -r --arg k "$1" --arg f "$2" \
        '((.entries // .tools)[$k][$f] // (.entries // .tools)[$k].install[$f] // empty) | if type == "array" then join(", ") else . end' \
        "$TURINGOS_ACTIVE_REGISTRY" 2>/dev/null | tr -d '\r'
}

registry::get_array() {
    # Usage: registry::get_array KEY FIELD — newline-separated values
    registry::_load || return 1
    jq -r --arg k "$1" --arg f "$2" '((.entries // .tools)[$k][$f] // (.entries // .tools)[$k].install[$f])[]? // empty' "$TURINGOS_ACTIVE_REGISTRY" 2>/dev/null | tr -d '\r'
}

registry::keys() {
    registry::_load || return 1
    jq -r '(.entries // .tools) | keys[]' "$TURINGOS_ACTIVE_REGISTRY" | tr -d '\r'
}

registry::_installed() {
    [[ -f "${TURINGOS_BAZAAR_DIR}/$1/.installed" ]]
}

# ─── List All Tools ───────────────────────────────────────────────────────────

registry::list() {
    registry::_load || return 1
    if (( TURINGOS_BAZAAR_OFFLINE )); then
        ui::header "Clawd Bazaar [offline catalogue]"
    else
        ui::header "Clawd Bazaar"
    fi

    local key name type description tags dot
    while IFS=$'\t' read -r key name type description tags; do
        dot="${DIM}○${RESET}"
        registry::_installed "$key" && dot="${GREEN}●${RESET}"
        printf '  %b  %b%-22s%b  %b[%s]%b\n' "$dot" "$BOLD_WHITE" "$name" "$RESET" "$DIM" "$type" "$RESET"
        printf '       %s\n' "$description"
        printf '       %b%s  tags: %s%b\n\n' "$DIM" "$key" "$tags" "$RESET"
    done < <(jq -r '(.entries // .tools) | to_entries[] | [.key, .value.name, .value.type, .value.description,
        ((.value.tags // []) | join(", "))] | @tsv' "$TURINGOS_ACTIVE_REGISTRY")

    printf '  %b● installed   ○ available%b\n\n' "$DIM" "$RESET"
}

# ─── Get Tool Info ────────────────────────────────────────────────────────────

registry::info() {
    # Usage: registry::info TOOL_KEY
    local key="${1:-}" name
    registry::_load || return 1
    name=$(registry::get_field "$key" name)
    if [[ -z "$name" ]]; then
        ui::fail "Tool not found in registry: ${key}"
        registry::_suggest "$key"
        return 1
    fi

    if (( TURINGOS_BAZAAR_OFFLINE )); then
        ui::header "$name [offline catalogue]"
    else
        ui::header "$name"
    fi
    ui::label "Key" "$key"
    local field
    for field in type runtime package version repo description tags; do
        val="$(registry::get_field "$key" "$field")"
        [[ -n "$val" ]] && ui::label "${field^}" "$val"
    done

    local env_var env_vars=()
    mapfile -t env_vars < <(registry::get_array "$key" env_required)
    if (( ${#env_vars[@]} )); then
        echo ""
        ui::warn "Required environment variables:"
        for env_var in "${env_vars[@]}"; do
            if [[ -n "${!env_var:-}" ]]; then
                printf '    %-36s %b(set)%b\n' "$env_var" "$GREEN" "$RESET"
            else
                printf '    %-36s %b(NOT SET)%b\n' "$env_var" "$RED" "$RESET"
            fi
        done
    fi

    echo ""
    if registry::_installed "$key"; then
        ui::ok "Status: installed"
        ui::label "Installed at" "$(cat "${TURINGOS_BAZAAR_DIR}/${key}/.installed")"
    else
        ui::info "Status: not installed"
        ui::info "Install: turingos bazaar install ${key}"
    fi
    echo ""
}

# ─── Search ───────────────────────────────────────────────────────────────────

registry::search() {
    # Usage: registry::search QUERY — case-insensitive over key, name, description, tags
    local query="${1:-}"
    registry::_load || return 1
    if [[ -z "$query" ]]; then
        ui::fail "Usage: turingos bazaar search <query>"
        return 1
    fi

    if (( TURINGOS_BAZAAR_OFFLINE )); then
        ui::header "Search: ${query} [offline catalogue]"
    else
        ui::header "Search: ${query}"
    fi
    local found=0 key name description
    while IFS=$'\t' read -r key name description; do
        found=$(( found + 1 ))
        printf '  %b%-22s%b  %b%s%b\n' "$BOLD_WHITE" "$name" "$RESET" "$DIM" "$key" "$RESET"
        printf '  %s\n\n' "$description"
    done < <(jq -r --arg q "$query" '(.entries // .tools) | to_entries[]
        | select([.key, .value.name, .value.description, ((.value.tags // []) | join(" "))]
                 | join(" ") | ascii_downcase | contains($q | ascii_downcase))
        | [.key, .value.name, .value.description] | @tsv' "$TURINGOS_ACTIVE_REGISTRY")

    if (( found == 0 )); then
        ui::info "No tools matched: ${query}"
    else
        ui::info "${found} result(s). Install with: turingos bazaar install <key>"
    fi
}

# ─── Interactive Browser (fzf) ────────────────────────────────────────────────

registry::browse() {
    registry::_load || return 1
    if ! command -v fzf &>/dev/null; then
        ui::warn "fzf not found — falling back to list"
        registry::list
        return 0
    fi

    local prompt_text="  Clawd Bazaar › "
    (( TURINGOS_BAZAAR_OFFLINE )) && prompt_text="  Clawd Bazaar [offline] › "

    local selection
    selection=$(jq -r '(.entries // .tools) | to_entries[] | "\(.key)  \(.value.name)  —  \(.value.description)"' \
        "$TURINGOS_ACTIVE_REGISTRY" | fzf \
            --prompt="$prompt_text" \
            --header="  Select a tool to install (Enter=select, Esc=cancel)" \
            --height=60% --reverse --border --ansi) || true

    if [[ -z "$selection" ]]; then
        ui::info "No tool selected"
        return 0
    fi

    local key="${selection%% *}"
    registry::info "$key"
    if ui::confirm "Install ${key}?"; then
        bazaar::install "$key"
    fi
}

# ─── Fuzzy Suggestion ────────────────────────────────────────────────────────

registry::_suggest() {
    local matches
    matches=$(registry::keys | grep -i -- "$1" | tr '\n' ' ') || true
    if [[ -n "$matches" ]]; then
        ui::info "Did you mean: ${matches}"
    else
        ui::info "Available tools: $(registry::keys | tr '\n' ' ')"
    fi
}

# ─── Installed Tools Summary ─────────────────────────────────────────────────

registry::installed() {
    registry::_load || return 1
    ui::header "Installed Tools"

    local found=0 marker key name
    for marker in "${TURINGOS_BAZAAR_DIR}"/*/.installed; do
        [[ -f "$marker" ]] || continue
        key=$(basename "$(dirname "$marker")")
        name=$(registry::get_field "$key" name)
        printf '  %b●%b  %-24s  %b%s%b\n' "$GREEN" "$RESET" "${name:-$key}" "$DIM" "$(cat "$marker")" "$RESET"
        found=$(( found + 1 ))
    done

    if (( found == 0 )); then
        ui::info "No tools installed yet"
        ui::info "Browse: turingos bazaar"
    fi
    echo ""
}

# ─── Per-Project Rules ────────────────────────────────────────────────────────

bazaar::rules() {
    local target_dir="${1:-$PWD}"
    target_dir="$(realpath "$target_dir" 2>/dev/null || echo "$target_dir")"
    ui::header "Bazaar Rules: $(basename "$target_dir")"
    ui::label "Directory" "$target_dir"

    local rules_file="${TURINGOS_DATA_DIR}/bazaar_rules.json"
    local disabled=()
    if [[ -f "$rules_file" ]]; then
        mapfile -t disabled < <(jq -r --arg dir "$target_dir" '.[$dir][]? // empty' "$rules_file" 2>/dev/null)
    fi

    local toml_file="${target_dir}/.turingos/bazaar.toml"
    if [[ -f "$toml_file" ]]; then
        ui::info "Found committed config: ${toml_file}"
        local toml_disabled
        toml_disabled=$(grep "^disabled" "$toml_file" 2>/dev/null | cut -d'=' -f2 | tr -d '[]" ' | tr ',' '\n') || true
        if [[ -n "$toml_disabled" ]]; then
            mapfile -t disabled <<< "$toml_disabled"
        fi
    fi

    if (( ${#disabled[@]} == 0 )); then
        ui::ok "All installed skills, plugins, and MCP servers are ENABLED for this folder."
    else
        ui::warn "Disabled in this directory:"
        for item in "${disabled[@]}"; do
            [[ -n "$item" ]] && printf '  %b✗%b %s\n' "$RED" "$RESET" "$item"
        done
    fi
    echo ""
}

bazaar::disable() {
    local tool="${1:-}" target_dir="${2:-$PWD}"
    if [[ -z "$tool" ]]; then
        ui::fail "Usage: turingos bazaar disable <tool> [directory]"
        return 1
    fi
    target_dir="$(realpath "$target_dir" 2>/dev/null || echo "$target_dir")"
    local rules_file="${TURINGOS_DATA_DIR}/bazaar_rules.json"
    mkdir -p "$(dirname "$rules_file")"

    local current="{}"
    [[ -s "$rules_file" ]] && current=$(cat "$rules_file")
    local updated
    updated=$(jq --arg dir "$target_dir" --arg item "$tool" \
        '.[$dir] = (((.[$dir] // []) + [$item]) | unique)' <<< "$current")
    echo "$updated" > "$rules_file"

    local claude_settings="${target_dir}/.claude/settings.json"
    mkdir -p "${target_dir}/.claude" 2>/dev/null || true
    local cur_claude="{}"
    [[ -s "$claude_settings" ]] && cur_claude=$(cat "$claude_settings")
    jq --arg item "$tool" '.disabledMcpServers = (((.disabledMcpServers // []) + [$item]) | unique)' \
        <<< "$cur_claude" > "$claude_settings" 2>/dev/null || true

    ui::ok "Disabled '${tool}' for ${target_dir}"
}

bazaar::enable() {
    local tool="${1:-}" target_dir="${2:-$PWD}"
    if [[ -z "$tool" ]]; then
        ui::fail "Usage: turingos bazaar enable <tool> [directory]"
        return 1
    fi
    target_dir="$(realpath "$target_dir" 2>/dev/null || echo "$target_dir")"
    local rules_file="${TURINGOS_DATA_DIR}/bazaar_rules.json"
    mkdir -p "$(dirname "$rules_file")"

    if [[ -s "$rules_file" ]]; then
        local updated
        updated=$(jq --arg dir "$target_dir" --arg item "$tool" \
            '.[$dir] = ((.[$dir] // []) - [$item])' "$rules_file")
        echo "$updated" > "$rules_file"
    fi

    local claude_settings="${target_dir}/.claude/settings.json"
    if [[ -s "$claude_settings" ]]; then
        local cur_claude
        cur_claude=$(cat "$claude_settings")
        jq --arg item "$tool" '.disabledMcpServers = ((.disabledMcpServers // []) - [$item])' \
            <<< "$cur_claude" > "$claude_settings" 2>/dev/null || true
    fi

    ui::ok "Enabled '${tool}' for ${target_dir}"
}

bazaar::toggle() {
    local target_dir="${1:-$PWD}"
    target_dir="$(realpath "$target_dir" 2>/dev/null || echo "$target_dir")"
    registry::_load || return 1

    local installed=() marker
    for marker in "${TURINGOS_BAZAAR_DIR}"/*/.installed; do
        [[ -f "$marker" ]] || continue
        installed+=("$(basename "$(dirname "$marker")")")
    done

    if (( ${#installed[@]} == 0 )); then
        ui::info "No Bazaar tools installed yet. Install tools with: turingos bazaar"
        return 0
    fi

    if ! command -v fzf &>/dev/null; then
        bazaar::rules "$target_dir"
        return 0
    fi

    local rules_file="${TURINGOS_DATA_DIR}/bazaar_rules.json"
    local disabled=()
    if [[ -f "$rules_file" ]]; then
        mapfile -t disabled < <(jq -r --arg dir "$target_dir" '.[$dir][]? // empty' "$rules_file" 2>/dev/null)
    fi

    local items_with_status=()
    for item in "${installed[@]}"; do
        local state="[x] ENABLED "
        for d in "${disabled[@]}"; do
            if [[ "$d" == "$item" ]]; then
                state="[ ] DISABLED"
                break
            fi
        done
        items_with_status+=("${state}  ${item}")
    done

    local selected
    selected=$(printf '%s\n' "${items_with_status[@]}" | fzf \
        --prompt="  Toggle Bazaar items for $(basename "$target_dir") › " \
        --header="  Select an item to toggle its state (Enter=toggle, Esc=done)" \
        --height=60% --reverse --border --ansi) || true

    if [[ -n "$selected" ]]; then
        local item_name
        item_name=$(awk '{print $3}' <<< "$selected")
        if [[ "$selected" =~ \[x\] ]]; then
            bazaar::disable "$item_name" "$target_dir"
        else
            bazaar::enable "$item_name" "$target_dir"
        fi
        if command -v notify-send &>/dev/null; then
            notify-send "TuringOS Bazaar" "Updated rules for $(basename "$target_dir")" 2>/dev/null || true
        fi
    fi
}
