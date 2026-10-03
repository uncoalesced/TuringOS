#!/usr/bin/env bash
# agent/nim.sh — NVIDIA NIM (build.nvidia.com) provider
#
# Model picker for `turingos model set nvidia`, the OpenCode provider config
# used when agents run on NIM, and `turingos image` (FLUX text-to-image).
#
# Depends on: core/config.sh, core/ui.sh, agent/model.sh

# ─── Catalog ──────────────────────────────────────────────────────────────────
# Chat models from https://integrate.api.nvidia.com/v1/models, "id|category".
# General-purpose text, code and vision only — no embedding, guard, retrieval
# or domain (bio/med/fin) models. Anything else can be typed in at the picker.

NIM_CHAT_MODELS=(
    "nvidia/nemotron-3-ultra-550b-a55b|text · reasoning"
    "nvidia/nemotron-3-super-120b-a12b|text · reasoning"
    "nvidia/llama-3.1-nemotron-ultra-253b-v1|text · reasoning"
    "nvidia/nemotron-nano-3-30b-a3b|text · fast"
    "moonshotai/kimi-k3|text · agentic"
    "moonshotai/kimi-k2.6|text · agentic"
    "z-ai/glm-5.3|text · agentic"
    "z-ai/glm-5.3-flash|text · fast"
    "deepseek-ai/deepseek-v4.1-flash|text · fast"
    "openai/gpt-oss-20b|text · fast"
    "google/gemma-4-31b-it|text"
    "mistralai/mistral-large-2-instruct|text"
    "writer/palmyra-creative-122b|text · writing"
    "poolside/laguna-xs-2.1|code"
    "mistralai/codestral-22b-instruct-v0.1|code"
    "ibm/granite-34b-code-instruct|code"
    "meta/llama-3.2-90b-vision-instruct|vision"
    "nvidia/nemotron-3-nano-omni-30b-a3b-reasoning|vision · reasoning"
    "nvidia/cosmos-reason2-8b|vision · video"
)

# Text-to-image models (served from ai.api.nvidia.com/v1/genai/<id>)
NIM_IMAGE_MODELS=(
    "black-forest-labs/flux.1-dev"
    "black-forest-labs/flux.1-schnell"
)

NIM_DEFAULT_ENDPOINT="https://integrate.api.nvidia.com/v1"
NIM_MAX_FALLBACKS=3

# ─── Setup ────────────────────────────────────────────────────────────────────

nim::setup() {
    # Usage: nim::setup [MODEL] — no MODEL runs the interactive picker
    if [[ -n "${1:-}" ]]; then
        config::set TURINGOS_NIM_MODELS "$1"
        config::set TURINGOS_MODEL_NAME "$1"
        config::set TURINGOS_NIM_FALLBACKS ""
    else
        nim::pick || return 1
    fi
    nim::_ask_key
}

nim::pick() {
    local labels=() picked=() extras=() entry line
    for entry in "${NIM_CHAT_MODELS[@]}"; do
        labels+=("$(printf '%-48s %s' "${entry%%|*}" "${entry#*|}")")
    done

    while IFS= read -r line; do
        [[ -n "$line" ]] && picked+=("${line%% *}")
    done < <(ui::choose_many "Pick the NVIDIA models you want" "${labels[@]}")

    local extra
    extra=$(ui::input "Other model IDs from build.nvidia.com (comma-separated, blank for none)" "") || true
    IFS=',' read -ra extras <<< "${extra// /}"
    for entry in "${extras[@]}"; do
        [[ -n "$entry" ]] && picked+=("$entry")
    done

    if (( ${#picked[@]} == 0 )); then
        ui::fail "No models picked"
        return 1
    fi

    local default="${picked[0]}"
    if (( ${#picked[@]} > 1 )); then
        default=$(ui::choose "Default model for agents" "${picked[@]}") || true
        [[ -z "$default" ]] && default="${picked[0]}"
    fi

    # Backups, tried in this order when the default fails
    local fallbacks=() rest=() pick m
    for m in "${picked[@]}"; do [[ "$m" != "$default" ]] && rest+=("$m"); done
    while (( ${#fallbacks[@]} < NIM_MAX_FALLBACKS && ${#rest[@]} > 0 )); do
        pick=$(ui::choose "Backup model #$(( ${#fallbacks[@]} + 1 )) (used if the one before fails)" \
            "${rest[@]}" "none") || true
        [[ -z "$pick" || "$pick" == "none" ]] && break
        fallbacks+=("$pick")
        local left=()
        for m in "${rest[@]}"; do [[ "$m" != "$pick" ]] && left+=("$m"); done
        rest=("${left[@]}")
    done

    local image
    image=$(ui::choose "Image model for 'turingos image'" "${NIM_IMAGE_MODELS[@]}") || true

    config::set TURINGOS_NIM_MODELS "$(IFS=,; echo "${picked[*]}")"
    config::set TURINGOS_MODEL_NAME "$default"
    config::set TURINGOS_NIM_FALLBACKS "$(IFS=,; echo "${fallbacks[*]}")"
    [[ -n "$image" ]] && config::set TURINGOS_NIM_IMAGE_MODEL "$image"

    ui::ok "${#picked[@]} NVIDIA model(s) saved, default ${default}"
    (( ${#fallbacks[@]} )) && ui::info "Backups in order: ${fallbacks[*]}"
    return 0
}

nim::_ask_key() {
    [[ -n "${NVIDIA_API_KEY:-}" ]] && return 0
    local key
    ui::info "Get a key at https://build.nvidia.com (starts with nvapi-)"
    key=$(ui::secret "NVIDIA API key (blank to skip)")
    if [[ -z "$key" ]]; then
        ui::warn "No key saved. Add NVIDIA_API_KEY to ${TURINGOS_CONFIG_FILE} before starting an agent."
        return 0
    fi
    if ! config::valid_secret "$key"; then
        ui::fail "That doesn't look like an API key (letters, digits and -_. only). Nothing saved."
        return 1
    fi
    config::set NVIDIA_API_KEY "$key"
    ui::ok "NVIDIA_API_KEY saved to ${TURINGOS_CONFIG_FILE}"
}

# ─── Launch Order ─────────────────────────────────────────────────────────────

nim::model_chain() {
    # Prints the default model then each backup, one per line, no duplicates
    local seen="," m
    local all="${TURINGOS_MODEL_NAME:-},${TURINGOS_NIM_FALLBACKS:-}"
    IFS=',' read -ra all <<< "$all"
    for m in "${all[@]}"; do
        [[ -z "$m" || "$seen" == *",${m},"* ]] && continue
        seen+="${m},"
        echo "$m"
    done
}

# ─── OpenCode Provider Config ─────────────────────────────────────────────────

nim::opencode_config() {
    # Every picked model (plus default and backups) shows up as nvidia/<id>
    model::write_opencode_config nvidia "NVIDIA NIM" \
        "${TURINGOS_MODEL_ENDPOINT:-$NIM_DEFAULT_ENDPOINT}" NVIDIA_API_KEY \
        "${TURINGOS_NIM_MODELS:-},${TURINGOS_MODEL_NAME:-},${TURINGOS_NIM_FALLBACKS:-}"
}

# ─── Image Generation ─────────────────────────────────────────────────────────

nim::image() {
    # Usage: nim::image PROMPT [OUTPUT_FILE]
    local prompt="${1:-}"
    local out="${2:-image-$(date +%Y%m%dT%H%M%S).jpg}"
    local model="${TURINGOS_NIM_IMAGE_MODEL:-${NIM_IMAGE_MODELS[0]}}"

    if [[ -z "$prompt" ]]; then
        ui::fail 'Usage: turingos image "<prompt>" [output.jpg]'
        return 1
    fi
    if [[ -z "${NVIDIA_API_KEY:-}" ]]; then
        ui::fail "NVIDIA_API_KEY is not set. Run: turingos model set nvidia"
        return 1
    fi

    ui::wait "Generating with ${model}..."
    local resp body
    body=$(jq -n --arg p "$prompt" '{prompt: $p}')
    if ! resp=$(model::curl_bearer "$NVIDIA_API_KEY" -fsS --max-time 180 \
            -H "Content-Type: application/json" -H "Accept: application/json" \
            -d "$body" "https://ai.api.nvidia.com/v1/genai/${model}"); then
        ui::fail "Request to NVIDIA failed (model ${model})"
        return 1
    fi

    local reason
    reason=$(jq -r '.artifacts[0].finishReason // "ERROR"' <<< "$resp")
    if [[ "$reason" != "SUCCESS" ]]; then
        ui::fail "Image not generated: ${reason}"
        return 1
    fi

    jq -r '.artifacts[0].base64' <<< "$resp" | base64 -d > "$out"
    ui::ok "Saved ${out}"
}
