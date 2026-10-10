#!/usr/bin/env bash
# tests/session.sh — the shell window's launcher (session/): which graphics
# path and level a machine gets, and the browser flags that follow from it.
# Pure-function checks; tests/kiosk_contract.sh runs the real thing.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SESSION="${ROOT}/session"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

fail() { echo "FAIL: $*" >&2; exit 1; }

for f in turingos-kiosk turingos-gfx-detect; do
    [[ -x "${SESSION}/${f}" ]] || fail "session/${f} is not executable"
    bash -n "${SESSION}/${f}" || fail "session/${f} has syntax errors"
done
[[ -x "${SESSION}/turingos-omni" ]] || fail "session/turingos-omni is not executable"
sh -n "${SESSION}/turingos-omni" || fail "session/turingos-omni is not plain sh"
[[ "$(head -n1 "${SESSION}/turingos-omni")" == "#!/bin/sh" ]] || fail "turingos-omni must stay a small sh script"

# ─── Graphics path and level ─────────────────────────────────────────────────
# shellcheck source=/dev/null
source "${SESSION}/turingos-gfx-detect"

decide() { gfx::decide "$@"; }
HD=$((1920 * 1080))
[[ "$(decide 1 "Mesa Intel(R) UHD Graphics 620 (KBL GT2)" 8 "$HD")" == "gpu full" ]] || fail "a real GPU is the gpu path at full"
[[ "$(decide 1 "SVGA3D; build: RELEASE;  LLVM;" 2 "$HD")" == "gpu full" ]] || fail "VMware with 3D on is a GPU"
[[ "$(decide 1 "virgl (ANGLE (Apple, Apple M2, OpenGL 4.1))" 4 "$HD")" == "gpu full" ]] || fail "virtio-gpu with virgl is a GPU"
[[ "$(decide 1 "llvmpipe (LLVM 19.1.7, 128 bits)" 4 "$HD")" == "sw lite" ]] || fail "a render node backed by llvmpipe is software"
[[ "$(decide 1 "softpipe" 4 "$HD")" == "sw lite" ]] || fail "softpipe is software"
[[ "$(decide 1 "Google SwiftShader" 4 "$HD")" == "sw lite" ]] || fail "SwiftShader is software"
[[ "$(decide 0 "" 4 "$HD")" == "sw lite" ]] || fail "no render node is software"
[[ "$(decide 1 "" 4 "$HD")" == "sw lite" ]] || fail "a render node glxinfo can't use is software"
[[ "$(decide 0 "" 2 "$HD")" == "sw minimal" ]] || fail "software on 2 CPUs is the minimal level"
[[ "$(decide 0 "" 1 $((1280 * 800)))" == "sw minimal" ]] || fail "software on 1 CPU is the minimal level"
[[ "$(decide 0 "" 8 $((2560 * 1440)))" == "sw minimal" ]] || fail "software above ~2.3 MP is the minimal level"
[[ "$(decide 0 "" 8 0)" == "sw lite" ]] || fail "an unknown screen size must not push to minimal"
[[ "$(decide 1 "Mesa Intel(R) UHD" 8 "$HD" sw)" == "sw lite" ]] || fail "forcing software overrides a working GPU"
[[ "$(decide 0 "" 8 "$HD" gpu)" == "gpu full" ]] || fail "forcing gpu overrides detection"

# The "GPU path crashed" flag only counts for the boot that wrote it
flag="${WORK}/force-sw"
echo "some-other-boot" > "$flag"
if gfx::forced_software "$flag"; then fail "a force-sw flag from another boot was honoured"; fi
if gfx::forced_software "${WORK}/missing"; then fail "a missing force-sw flag was honoured"; fi
if [[ -r /proc/sys/kernel/random/boot_id ]]; then
    cat /proc/sys/kernel/random/boot_id > "$flag"
    gfx::forced_software "$flag" || fail "this boot's force-sw flag was ignored"
fi

# ─── Browser flags ────────────────────────────────────────────────────────────
# shellcheck source=/dev/null
source "${SESSION}/turingos-kiosk"

url="http://127.0.0.1:8080/?gfx=sw.lite"
gpu_args="$(kiosk::args gpu full "$url" 1920 1080 /state/kiosk-profile)"
sw_args="$(kiosk::args sw lite "$url" 1920 1080 /state/kiosk-profile)"
min_args="$(kiosk::args sw minimal "$url" 1280 800 /state/kiosk-profile)"

has() { grep -qxF -- "$2" <<<"$1"; }
for args in "$gpu_args" "$sw_args" "$min_args"; do
    has "$args" "--app=${url}" || fail "the shell must be an app window on the bridge"
    has "$args" "--class=turingos-shell" || fail "Openbox finds the shell by this class"
    has "$args" "--user-data-dir=/state/kiosk-profile" || fail "the shell needs its own profile"
    has "$args" "--disable-extensions" || fail "no extension may run in the shell"
    has "$args" "--no-first-run" || fail "first-run UI would cover the shell"
    if grep -qE -- '^--kiosk|ignore-gpu-blocklist|swiftshader|--no-sandbox' <<<"$args"; then
        fail "forbidden flag in: $(tr '\n' ' ' <<<"$args")"
    fi
done
if grep -q -- '--disable-gpu' <<<"$gpu_args"; then fail "the GPU path must leave GPU flags to Chromium"; fi
has "$sw_args" "--disable-gpu" || fail "the software path must skip GL"
has "$gpu_args" "--window-size=1920,1080" || fail "window size"
has "$min_args" "--window-size=1280,800" || fail "window size (minimal)"
has "$min_args" "--force-prefers-reduced-motion" || fail "the minimal level asks for reduced motion"
if has "$sw_args" "--force-prefers-reduced-motion"; then fail "lite keeps its motion"; fi

# The class the Openbox rule (hook 0475) matches is the class the launcher sets
grep -q 'class="turingos-shell"' "${ROOT}/debian-live/config/hooks/normal/0475-fallback.hook.chroot" \
    || fail "0475 has no rule for the shell window"
grep -q '"turingos-shell"' "${SESSION}/turingos-omni" || fail "omni and the Openbox rule disagree on the window class"

# The page reads the hint the launcher puts in the URL
grep -q 'gfx=(gpu|sw)' "${ROOT}/ui/web/boot.js" || fail "boot.js does not read ?gfx="
grep -q '?gfx=${GFX_PATH}.${GFX_TIER}' "${SESSION}/turingos-kiosk" || fail "turingos-kiosk does not pass the hint"

echo "session tests passed"
