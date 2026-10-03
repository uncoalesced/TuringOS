#!/usr/bin/env bash
# agent/model.sh — model providers: `turingos model`, the provider table, and
# the OpenCode provider configs used when agents run on a non-Claude model.
#
# Depends on: core/config.sh, core/ui.sh, agent/nim.sh

MODEL_PROVIDERS=(claude nvidia ollama openrouter custom)

# ─── Provider Table ───────────────────────────────────────────────────────────

model::default_endpoint() {
    case "$1" in
        ollama)     echo "http://localhost:11434" ;;
        openrouter) echo "https://openrouter.ai/api/v1" ;;
        nvidia)     echo "$NIM_DEFAULT_ENDPOINT" ;;
    esac
}

model::key_var() {
    # Env var holding the provider's API key (empty for keyless providers)
    case "$1" in
        openrouter) echo "OPENROUTER_API_KEY" ;;
        nvidia)     echo "NVIDIA_API_KEY" ;;
    esac
}

model::models_url() {
    # Usage: model::models_url PROVIDER ENDPOINT — URL `model status` pings
    local ep="${2%/}"
    case "$1" in
        ollama)              echo "${ep}/api/tags" ;;
        openrouter | nvidia) echo "${ep}/models" ;;   # endpoint already ends in /v1
        *)                   echo "${ep}/v1/models" ;;
    esac
}

model::scrub_keys() {
    # Unset every provider API key except the active provider's own
    local own p var
    own=$(model::key_var "$TURINGOS_MODEL_PROVIDER")
    for p in "${MODEL_PROVIDERS[@]}"; do
        var=$(model::key_var "$p")
        [[ -n "$var" && "$var" != "$own" ]] && unset "$var"
    done
    return 0
}

model::curl_bearer() {
    # Usage: model::curl_bearer KEY CURL_ARGS... — key goes to curl as config
    # on stdin, not argv, so ps can't see it
    local key="$1"
    shift
    { [[ -z "$key" ]] || printf 'header = "Authorization: Bearer %s"\n' "$key"; } | curl -K - "$@"
}

# ─── OpenCode Provider Config ─────────────────────────────────────────────────
# OpenCode merges the file named by OPENCODE_CONFIG into its own config, so
# the provider shows up without touching the user's files.

model::write_opencode_config() {
    # Usage: model::write_opencode_config ID NAME BASE_URL KEY_VAR MODELS_CSV
    local id="$1" name="$2" url="$3" key_var="$4" models="$5"
    local out="${TURINGOS_DATA_DIR}/opencode-${id}.json"
    jq -n --arg id "$id" --arg name "$name" --arg url "$url" --arg key "$key_var" --arg models "$models" '{
        "$schema": "https://opencode.ai/config.json",
        provider: {
            ($id): {
                npm: "@ai-sdk/openai-compatible",
                name: $name,
                options: ({baseURL: $url} + (if $key == "" then {} else {apiKey: "{env:\($key)}"} end)),
                models: ($models | split(",") | map(select(length > 0) | {key: ., value: {name: .}}) | from_entries)
            }
        }
    }' > "$out" && echo "$out"
}

model::opencode_config() {
    # Prints the OpenCode config path for the active provider (none for
    # openrouter, which OpenCode knows natively)
    local ep="${TURINGOS_MODEL_ENDPOINT:-$(model::default_endpoint "$TURINGOS_MODEL_PROVIDER")}"
    case "$TURINGOS_MODEL_PROVIDER" in
        nvidia) nim::opencode_config ;;
        ollama) model::write_opencode_config ollama "Ollama" "${ep%/}/v1" "" "${TURINGOS_MODEL_NAME:-}" ;;
        custom) model::write_opencode_config custom "Custom endpoint" "${ep%/}/v1" "" "${TURINGOS_MODEL_NAME:-}" ;;
    esac
}

# ─── `turingos model` ─────────────────────────────────────────────────────────

model::cmd() {
    local sub="${1:-status}"
    shift || true
    case "$sub" in
        set)    model::set "$@" ;;
        use)    model::use "$@" ;;
        status) model::status ;;
        *)      ui::fail "Unknown model subcommand: ${sub}"; return 1 ;;
    esac
}

model::set() {
    local provider="${1:-}" endpoint="${2:-}" name="${3:-}"
    if [[ " ${MODEL_PROVIDERS[*]} " != *" ${provider} "* ]]; then
        ui::fail "Usage: turingos model set <$(IFS='|'; echo "${MODEL_PROVIDERS[*]}")> [endpoint] [model]"
        return 1
    fi
    # `model set nvidia kimi` means the model, not an endpoint
    if [[ -n "$endpoint" && "$endpoint" != *://* && -z "$name" ]]; then
        name="$endpoint"
        endpoint=""
    fi
    [[ -z "$endpoint" ]] && endpoint=$(model::default_endpoint "$provider")
    config::set TURINGOS_MODEL_PROVIDER "$provider"
    config::set TURINGOS_MODEL_ENDPOINT "$endpoint"
    if [[ "$provider" == "nvidia" ]]; then
        nim::setup "$name" || return 1
    else
        config::set TURINGOS_MODEL_NAME "$name"
    fi
    ui::ok "Model provider set to ${provider}${TURINGOS_MODEL_NAME:+ (${TURINGOS_MODEL_NAME})}"
}

model::use() {
    local id="${1:-}"
    if [[ -z "$id" ]]; then
        ui::fail "Usage: turingos model use <model>"
        return 1
    fi
    config::set TURINGOS_MODEL_NAME "$id"
    if [[ "$TURINGOS_MODEL_PROVIDER" == "nvidia" && ",${TURINGOS_NIM_MODELS:-}," != *",${id},"* ]]; then
        config::set TURINGOS_NIM_MODELS "${TURINGOS_NIM_MODELS:+${TURINGOS_NIM_MODELS},}${id}"
    fi
    ui::ok "Default model: ${id}"
}

model::status() {
    ui::info "Provider: ${TURINGOS_MODEL_PROVIDER}"
    ui::info "Endpoint: ${TURINGOS_MODEL_ENDPOINT:-<default>}"
    ui::info "Model:    ${TURINGOS_MODEL_NAME:-<default>}"
    if [[ "$TURINGOS_MODEL_PROVIDER" == "nvidia" ]]; then
        ui::info "Backups:  ${TURINGOS_NIM_FALLBACKS:-<none>}"
        ui::info "Picked:   ${TURINGOS_NIM_MODELS:-<none>}"
        ui::info "Image:    ${TURINGOS_NIM_IMAGE_MODEL:-${NIM_IMAGE_MODELS[0]}}"
    fi
    [[ "$TURINGOS_MODEL_PROVIDER" == "claude" || -z "$TURINGOS_MODEL_ENDPOINT" ]] && return 0

    local url key_var key=""
    url=$(model::models_url "$TURINGOS_MODEL_PROVIDER" "$TURINGOS_MODEL_ENDPOINT")
    key_var=$(model::key_var "$TURINGOS_MODEL_PROVIDER")
    [[ -n "$key_var" ]] && key="${!key_var:-}"
    if model::curl_bearer "$key" -fsS --max-time 5 -o /dev/null "$url"; then
        ui::ok "Endpoint reachable"
    else
        ui::fail "Endpoint unreachable: ${url}"
        return 1
    fi
}
