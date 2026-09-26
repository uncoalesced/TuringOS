#!/usr/bin/env bash
# bazaar/registry.sh — ClaudeOS Clawd Bazaar registry reader
#
# Loads and queries registry.json. Provides the browsing/search UI.
# Install logic lives in bazaar/install.sh.
#
# Depends on: core/config.sh, core/logging.sh, core/ui.sh

log::set_module "bazaar"

# ─── Registry Load ────────────────────────────────────────────────────────────

registry::_load() {
    if [[ ! -f "$CLAUDEOS_REGISTRY" ]]; then
        ui::fail "Registry not found: $CLAUDEOS_REGISTRY"
        log::error "registry file missing: $CLAUDEOS_REGISTRY"
        return 1
    fi
    if ! command -v jq &>/dev/null; then
        ui::fail "jq is required for the Bazaar"
        ui::info "Install: sudo apt install jq"
        return 1
    fi
    return 0
}

# ─── List All Tools ───────────────────────────────────────────────────────────

registry::list() {
    registry::_load || return 1

    ui::header "Clawd Bazaar"
    echo ""

    local keys
    keys=$(jq -r '.tools | keys[]' "$CLAUDEOS_REGISTRY" 2>/dev/null)

    while IFS= read -r key; do
        local name description tags type
        name=$(        jq -r ".tools[\"${key}\"].name"        "$CLAUDEOS_REGISTRY")
        description=$( jq -r ".tools[\"${key}\"].description" "$CLAUDEOS_REGISTRY")
        type=$(        jq -r ".tools[\"${key}\"].type"        "$CLAUDEOS_REGISTRY")
        tags=$(        jq -r ".tools[\"${key}\"].tags | join(\", \")" "$CLAUDEOS_REGISTRY" 2>/dev/null)

        # Check if already installed
        local installed_marker="${CLAUDEOS_BAZAAR_DIR}/${key}/.installed"
        local status_sym
        if [[ -f "$installed_marker" ]]; then
            status_sym="\033[0;32m●\033[0m"  # green dot
        else
            status_sym="\033[2m○\033[0m"     # dim dot
        fi

        printf "  %b  \033[1;37m%-22s\033[0m  \033[2m[%s]\033[0m\n" \
            "$status_sym" "$name" "$type"
        printf "       \033[0m%-50s\033[0m\n" "$description"
        printf "       \033[2m%s\033[0m  \033[2mtags: %s\033[0m\n\n" \
            "$key" "$tags"
    done <<< "$keys"

    echo ""
    printf "  \033[2m● installed   ○ available\033[0m\n"
    echo ""
}

# ─── Get Tool Info ────────────────────────────────────────────────────────────

registry::info() {
    # Usage: registry::info TOOL_KEY
    local key="$1"
    registry::_load || return 1

    local exists
    exists=$(jq -r ".tools[\"${key}\"] // empty" "$CLAUDEOS_REGISTRY" 2>/dev/null)
    if [[ -z "$exists" ]]; then
        ui::fail "Tool not found in registry: ${key}"
        registry::_suggest "$key"
        return 1
    fi

    local name description repo type runtime package env_required tags
    name=$(         jq -r ".tools[\"${key}\"].name"                           "$CLAUDEOS_REGISTRY")
    description=$(  jq -r ".tools[\"${key}\"].description"                    "$CLAUDEOS_REGISTRY")
    repo=$(         jq -r ".tools[\"${key}\"].repo"                           "$CLAUDEOS_REGISTRY")
    type=$(         jq -r ".tools[\"${key}\"].type"                           "$CLAUDEOS_REGISTRY")
    runtime=$(      jq -r ".tools[\"${key}\"].runtime"                        "$CLAUDEOS_REGISTRY")
    package=$(      jq -r ".tools[\"${key}\"].package"                        "$CLAUDEOS_REGISTRY")
    env_required=$( jq -r ".tools[\"${key}\"].env_required | join(\", \")"    "$CLAUDEOS_REGISTRY" 2>/dev/null)
    tags=$(         jq -r ".tools[\"${key}\"].tags | join(\", \")"            "$CLAUDEOS_REGISTRY" 2>/dev/null)

    ui::header "$name"
    ui::label "Key"          "$key"
    ui::label "Type"         "$type"
    ui::label "Runtime"      "$runtime"
    ui::label "Package"      "$package"
    ui::label "Repo"         "$repo"
    ui::label "Description"  "$description"
    ui::label "Tags"         "$tags"

    if [[ -n "$env_required" && "$env_required" != "null" ]]; then
        echo ""
        ui::warn "Required environment variables:"
        for env_var in $(jq -r ".tools[\"${key}\"].env_required[]" "$CLAUDEOS_REGISTRY" 2>/dev/null); do
            local set_indicator
            if [[ -n "${!env_var:-}" ]]; then
                set_indicator="\033[0;32m(set)\033[0m"
            else
                set_indicator="\033[0;31m(NOT SET)\033[0m"
            fi
            printf "    %-36s %b\n" "$env_var" "$set_indicator"
        done
    fi

    echo ""
    local installed_marker="${CLAUDEOS_BAZAAR_DIR}/${key}/.installed"
    if [[ -f "$installed_marker" ]]; then
        ui::ok "Status: installed"
        local installed_at
        installed_at=$(cat "$installed_marker")
        ui::label "Installed at" "$installed_at"
    else
        ui::info "Status: not installed"
        ui::info "Install: claudeos bazaar install ${key}"
    fi
    echo ""
}

# ─── Search ───────────────────────────────────────────────────────────────────

registry::search() {
    # Usage: registry::search QUERY
    local query="${1:-}"
    registry::_load || return 1

    if [[ -z "$query" ]]; then
        ui::fail "Usage: claudeos bazaar search <query>"
        return 1
    fi

    ui::header "Search: ${query}"

    local keys
    keys=$(jq -r '.tools | keys[]' "$CLAUDEOS_REGISTRY")

    local found=0
    while IFS= read -r key; do
        local name description tags
        name=$(        jq -r ".tools[\"${key}\"].name"                  "$CLAUDEOS_REGISTRY")
        description=$( jq -r ".tools[\"${key}\"].description"           "$CLAUDEOS_REGISTRY")
        tags=$(        jq -r ".tools[\"${key}\"].tags | join(\" \")"    "$CLAUDEOS_REGISTRY" 2>/dev/null)

        # Case-insensitive match against key, name, description, tags
        local haystack="${key} ${name} ${description} ${tags}"
        if echo "$haystack" | grep -qi "$query"; then
            (( found++ ))
            printf "  \033[1;37m%-22s\033[0m  \033[2m%s\033[0m\n" "$name" "$key"
            printf "  %-52s\n\n" "$description"
        fi
    done <<< "$keys"

    if [[ $found -eq 0 ]]; then
        ui::info "No tools matched: ${query}"
    else
        ui::info "${found} result(s). Install with: claudeos bazaar install <key>"
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

    # Build fzf input: "KEY  NAME  —  description"
    local fzf_input
    fzf_input=$(jq -r '
      .tools | to_entries[] |
      "\(.key)  \(.value.name)  —  \(.value.description)"
    ' "$CLAUDEOS_REGISTRY" 2>/dev/null)

    local selection
    selection=$(echo "$fzf_input" | fzf \
        --prompt="  Clawd Bazaar › " \
        --header="  Select a tool to install (Enter=select, Esc=cancel)" \
        --height=60% \
        --reverse \
        --border \
        --ansi \
    )

    if [[ -z "$selection" ]]; then
        ui::info "No tool selected"
        return 0
    fi

    local selected_key
    selected_key=$(echo "$selection" | awk '{print $1}')

    registry::info "$selected_key"
    echo ""

    if ui::confirm "Install ${selected_key}?"; then
        # Delegate to install module
        bazaar::install "$selected_key"
    fi
}

# ─── Keys List (for autocomplete / install.sh) ───────────────────────────────

registry::keys() {
    registry::_load || return 1
    jq -r '.tools | keys[]' "$CLAUDEOS_REGISTRY" 2>/dev/null
}

registry::get_field() {
    # Usage: registry::get_field KEY FIELD
    local key="$1"
    local field="$2"
    registry::_load || return 1
    jq -r ".tools[\"${key}\"].${field} // empty" "$CLAUDEOS_REGISTRY" 2>/dev/null
}

registry::get_array() {
    # Usage: registry::get_array KEY FIELD  — returns newline-separated values
    local key="$1"
    local field="$2"
    registry::_load || return 1
    jq -r ".tools[\"${key}\"].${field}[]? // empty" "$CLAUDEOS_REGISTRY" 2>/dev/null
}

# ─── Fuzzy Suggestion ────────────────────────────────────────────────────────

registry::_suggest() {
    local query="$1"
    local keys
    keys=$(registry::keys 2>/dev/null)
    local suggestions=()
    while IFS= read -r k; do
        echo "$k" | grep -qi "$query" && suggestions+=("$k")
    done <<< "$keys"

    if [[ ${#suggestions[@]} -gt 0 ]]; then
        ui::info "Did you mean: ${suggestions[*]}"
    else
        ui::info "Available tools: $(registry::keys | tr '\n' ' ')"
    fi
}

# ─── Installed Tools Summary ─────────────────────────────────────────────────

registry::installed() {
    registry::_load || return 1

    ui::header "Installed Tools"

    local found=0
    for marker in "${CLAUDEOS_BAZAAR_DIR}"/*/.installed; do
        [[ -f "$marker" ]] || continue
        local key
        key=$(basename "$(dirname "$marker")")
        local name
        name=$(registry::get_field "$key" "name" 2>/dev/null || echo "$key")
        local installed_at
        installed_at=$(cat "$marker")
        printf "  \033[0;32m●\033[0m  %-24s  \033[2m%s\033[0m\n" "$name" "$installed_at"
        (( found++ ))
    done

    if [[ $found -eq 0 ]]; then
        ui::info "No tools installed yet"
        ui::info "Browse: claudeos bazaar"
    fi
    echo ""
}
