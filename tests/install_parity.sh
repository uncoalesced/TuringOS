#!/usr/bin/env bash
# tests/install_parity.sh — what `turingos` sources is what the ISO installs.
# Stages the install with debian-live/sync-scripts.sh into a temp copy of the
# repo and runs the staged `turingos` from it. Needs rsync and jq.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

fail() { echo "FAIL: $*" >&2; exit 1; }

# Modules named in the entrypoint's source loop
mapfile -t modules < <(sed -n '/^for _module in/,/; do$/p' "${ROOT}/turingos" | grep -oE '[a-z]+/[a-z_]+\.sh')
(( ${#modules[@]} >= 10 )) || fail "could not read the module list from turingos (${#modules[@]} found)"

rsync -a --exclude=.git --exclude='/iso' --exclude='target/' "${ROOT}/" "${WORK}/repo/"
bash "${WORK}/repo/debian-live/sync-scripts.sh" >/dev/null
INC="${WORK}/repo/debian-live/config/includes.chroot"

for m in "${modules[@]}"; do
    [[ -f "${ROOT}/${m}" ]] || fail "turingos sources ${m}, which doesn't exist"
    [[ -f "${INC}/usr/lib/turingos/${m}" ]] || fail "${m} is not staged into the ISO"
done
for f in turingos bazaar/registry.json voice/wispr_transcribe.py pkg/turingos-install-claude-cli.sh; do
    [[ -e "${INC}/usr/lib/turingos/${f}" ]] || fail "${f} is not staged into the ISO"
done
[[ "$(readlink "${INC}/usr/bin/turingos")" == ../lib/turingos/turingos ]] || fail "/usr/bin/turingos symlink"
[[ -x "${INC}/usr/lib/turingos/turingos" ]] || fail "staged turingos is not executable"
[[ -f "${INC}/etc/profile.d/turingos-first-run.sh" ]] || fail "first-run banner not staged"
[[ -f "${INC}/opt/turingos-ui/src-tauri/Cargo.lock" ]] || fail "UI source (with Cargo.lock) not staged"
[[ ! -e "${INC}/opt/turingos" ]] || fail "a full repo copy is staged into /opt/turingos again"

# The staged layout runs on its own (modules from /usr/lib/turingos, not the checkout)
HOME="${WORK}/home" "${INC}/usr/bin/turingos" version >/dev/null || fail "staged turingos does not run"

echo "install parity test passed"
