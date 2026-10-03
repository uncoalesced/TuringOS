#!/usr/bin/env bash
# tests/nim.sh — smoke test for the NVIDIA NIM picker, fallback order and
# OpenCode config. Drives the plain (no-gum) prompts with scripted answers in
# a temp HOME. Needs jq.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HOME="$(mktemp -d)"
export HOME TURINGOS_NO_GUM=1
trap 'rm -rf "$HOME"' EXIT
unset NVIDIA_API_KEY

for m in core/config.sh core/ui.sh agent/nim.sh agent/model.sh; do
    # shellcheck source=/dev/null
    source "${ROOT}/${m}"
done

fail() { echo "FAIL: $*" >&2; exit 1; }

# Pick the first model and the first code model, by position in the catalog
first="${NIM_CHAT_MODELS[0]%%|*}"
code_idx=0
for i in "${!NIM_CHAT_MODELS[@]}"; do
    if [[ "${NIM_CHAT_MODELS[$i]#*|}" == code* ]]; then
        code_idx=$(( i + 1 ))
        break
    fi
done
(( code_idx > 1 )) || fail "no code model in NIM_CHAT_MODELS"
code="${NIM_CHAT_MODELS[$(( code_idx - 1 ))]%%|*}"

# Answers: first + code model (99 ignored) | extra id | default #2 | backup #2 | stop | image #2 | no key
printf '%s\n' "1 ${code_idx} 99" "foo/bar" "2" "2" "2" "2" "" \
    | nim::setup >/dev/null 2>&1 || fail "nim::setup returned non-zero"

[[ "$(stat -c %a "$TURINGOS_CONFIG_FILE")" == 600 ]] || fail "config.env is not mode 600"
(
    # shellcheck source=/dev/null
    source "$TURINGOS_CONFIG_FILE"
    [[ "$TURINGOS_NIM_MODELS" == "${first},${code},foo/bar" ]]     || fail "picked models: ${TURINGOS_NIM_MODELS}"
    [[ "$TURINGOS_MODEL_NAME" == "$code" ]]                        || fail "default model: ${TURINGOS_MODEL_NAME}"
    [[ "$TURINGOS_NIM_FALLBACKS" == "foo/bar" ]]                   || fail "backups: ${TURINGOS_NIM_FALLBACKS}"
    [[ "$TURINGOS_NIM_IMAGE_MODEL" == "${NIM_IMAGE_MODELS[1]}" ]]  || fail "image model: ${TURINGOS_NIM_IMAGE_MODEL}"
    [[ -z "${NVIDIA_API_KEY:-}" ]]                                 || fail "blank key was saved"
)

# Fallback order: default, then backups, no duplicates
TURINGOS_MODEL_NAME="a/1"
TURINGOS_NIM_FALLBACKS="b/2,a/1,c/3,d/4"
chain="$(nim::model_chain | paste -sd, -)"
[[ "$chain" == "a/1,b/2,c/3,d/4" ]] || fail "model chain: ${chain}"

# OpenCode config: valid JSON, every picked model, key read from env
# shellcheck disable=SC2034  # read by the sourced functions
TURINGOS_MODEL_PROVIDER="nvidia" TURINGOS_MODEL_ENDPOINT="$NIM_DEFAULT_ENDPOINT"
TURINGOS_NIM_MODELS="x/y,z/w"
cfg_file="$(model::opencode_config)"
jq -e '.provider.nvidia.models | has("x/y") and has("z/w") and has("a/1") and has("d/4")' \
    "$cfg_file" >/dev/null || fail "opencode models: $(cat "$cfg_file")"
jq -e '.provider.nvidia.options.apiKey == "{env:NVIDIA_API_KEY}"' \
    "$cfg_file" >/dev/null || fail "opencode apiKey"

# Image without a key must fail cleanly, before any network call
if nim::image "a cat" >/dev/null 2>&1; then fail "nim::image ran without NVIDIA_API_KEY"; fi

echo "nim smoke test passed"
