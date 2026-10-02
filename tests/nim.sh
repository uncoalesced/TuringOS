#!/usr/bin/env bash
# tests/nim.sh — smoke test for the NVIDIA NIM picker, fallback order and
# OpenCode config. Drives the no-gum prompts with scripted answers in a temp
# HOME. Needs jq; run where gum is not installed (CI).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HOME="$(mktemp -d)"
export HOME
trap 'rm -rf "$HOME"' EXIT
unset NVIDIA_API_KEY

# shellcheck source=/dev/null
source "${ROOT}/core/config.sh"
# shellcheck source=/dev/null
source "${ROOT}/core/ui.sh"
# shellcheck source=/dev/null
source "${ROOT}/agent/nim.sh"

fail() { echo "FAIL: $*" >&2; exit 1; }

command -v gum &>/dev/null && fail "gum is installed; this test drives the plain prompts"

first="${NIM_CHAT_MODELS[0]%%|*}"
code="${NIM_CHAT_MODELS[13]%%|*}"

# Answers: models 1+14 (99 ignored) | extra id | default #2 | backup #2 | stop | image #2 | no key
printf '%s\n' "1 14 99" "foo/bar" "2" "2" "2" "2" "" \
    | nim::setup >/dev/null 2>&1 || fail "nim::setup returned non-zero"

cfg="$(cat "$TURINGOS_CONFIG_FILE")"
grep -qx "TURINGOS_NIM_MODELS=${first},${code},foo/bar" <<< "$cfg"   || fail "picked models: ${cfg}"
grep -qx "TURINGOS_MODEL_NAME=${code}" <<< "$cfg"                    || fail "default model: ${cfg}"
grep -qx "TURINGOS_NIM_FALLBACKS=foo/bar" <<< "$cfg"                 || fail "backups: ${cfg}"
grep -qx "TURINGOS_NIM_IMAGE_MODEL=${NIM_IMAGE_MODELS[1]}" <<< "$cfg" || fail "image model: ${cfg}"
if grep -q "NVIDIA_API_KEY" <<< "$cfg"; then fail "blank key was saved"; fi

# Fallback order: default, then backups, no duplicates
TURINGOS_MODEL_NAME="a/1"
TURINGOS_NIM_FALLBACKS="b/2,a/1,c/3,d/4"
chain="$(nim::model_chain | paste -sd, -)"
[[ "$chain" == "a/1,b/2,c/3,d/4" ]] || fail "model chain: ${chain}"

# OpenCode config: valid JSON, every picked model, key read from env
TURINGOS_MODEL_ENDPOINT="$NIM_DEFAULT_ENDPOINT"
TURINGOS_NIM_MODELS="x/y,z/w"
nim::opencode_config
jq -e '.provider.nvidia.models | has("x/y") and has("z/w") and has("a/1") and has("d/4")' \
    "$NIM_OPENCODE_CONFIG" >/dev/null || fail "opencode models: $(cat "$NIM_OPENCODE_CONFIG")"
jq -e '.provider.nvidia.options.apiKey == "{env:NVIDIA_API_KEY}"' \
    "$NIM_OPENCODE_CONFIG" >/dev/null || fail "opencode apiKey"

# Image without a key must fail cleanly, before any network call
if nim::image "a cat" >/dev/null 2>&1; then fail "nim::image ran without NVIDIA_API_KEY"; fi

echo "nim smoke test passed"
