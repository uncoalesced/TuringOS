#!/usr/bin/env bash
# bazaar/registry.sh — TuringOS Clawd Bazaar registry reader
#
# Loads and queries registry.json. Provides the browsing/search UI.
# Install logic lives in bazaar/install.sh.
#
# Depends on: core/config.sh, core/logging.sh, core/ui.sh

# ─── Registry Access ──────────────────────────────────────────────────────────

registry::_load() {
    if [[ ! -f "$TURINGOS_REGISTRY" ]]; then
        ui::fail "Registry not found: $TURINGOS_REGISTRY"
        log::error "registry file missing: $TURINGOS_REGISTRY"
        return 1
    fi
    if ! command -v jq &>/dev/null; then
        ui::fail "jq is required for the Bazaar. Install: sudo apt install jq"
        return 1
    fi
}

registry::get_field() {
    # Usage: registry::get_field KEY FIELD — scalar field, or ", "-joined array
    registry::_load || return 1
    jq -r --arg k "$1" --arg f "$2" \
        '.tools[$k][$f] // empty | if type == "array" then join(", ") else . end' \
        "$TURINGOS_REGISTRY" 2>/dev/null
}

registry::get_array() {
    # Usage: registry::get_array KEY FIELD — newline-separated values
    registry::_load || return 1
    jq -r --arg k "$1" --arg f "$2" '.tools[$k][$f][]? // empty' "$TURINGOS_REGISTRY" 2>/dev/null
}

registry::keys() {
    registry::_load || return 1
    jq -r '.tools | keys[]' "$TURINGOS_REGISTRY"
}

registry::_installed() {
    [[ -f "${TURINGOS_BAZAAR_DIR}/$1/.installed" ]]
}

# ─── List All Tools ───────────────────────────────────────────────────────────

registry::list() {
    registry::_load || return 1
    ui::header "Clawd Bazaar"

    local key name type description tags dot
    while IFS=$'\t' read -r key name type description tags; do
        dot="${DIM}○${RESET}"
        registry::_installed "$key" && dot="${GREEN}●${RESET}"
        printf '  %b  %b%-22s%b  %b[%s]%b\n' "$dot" "$BOLD_WHITE" "$name" "$RESET" "$DIM" "$type" "$RESET"
        printf '       %s\n' "$description"
        printf '       %b%s  tags: %s%b\n\n' "$DIM" "$key" "$tags" "$RESET"
    done < <(jq -r '.tools | to_entries[] | [.key, .value.name, .value.type, .value.description,
        (.value.tags | join(", "))] | @tsv' "$TURINGOS_REGISTRY")

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

    ui::header "$name"
    ui::label "Key" "$key"
    local field
    for field in type runtime package repo description tags; do
        ui::label "${field^}" "$(registry::get_field "$key" "$field")"
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

    ui::header "Search: ${query}"
    local found=0 key name description
    while IFS=$'\t' read -r key name description; do
        found=$(( found + 1 ))
        printf '  %b%-22s%b  %b%s%b\n' "$BOLD_WHITE" "$name" "$RESET" "$DIM" "$key" "$RESET"
        printf '  %s\n\n' "$description"
    done < <(jq -r --arg q "$query" '.tools | to_entries[]
        | select([.key, .value.name, .value.description, (.value.tags | join(" "))]
                 | join(" ") | ascii_downcase | contains($q | ascii_downcase))
        | [.key, .value.name, .value.description] | @tsv' "$TURINGOS_REGISTRY")

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

    local selection
    selection=$(jq -r '.tools | to_entries[] | "\(.key)  \(.value.name)  —  \(.value.description)"' \
        "$TURINGOS_REGISTRY" | fzf \
            --prompt="  Clawd Bazaar › " \
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
