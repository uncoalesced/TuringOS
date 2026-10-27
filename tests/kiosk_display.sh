#!/usr/bin/env bash
# tests/kiosk_display.sh — the shell finds the screen size without hanging and
# picks Chromium's ozone platform from the session: Wayland under Hyprland,
# X11 under openbox. A 10-19 build sat on a black screen because xdpyinfo
# waited forever on an XWayland that never started.
#
# hyprctl and xdpyinfo are stubs on PATH, so this runs anywhere with bash.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

fail() { echo "FAIL: $*" >&2; exit 1; }

STUBS="${WORK}/bin"
mkdir -p "$STUBS"
# stub NAME BODY — a fake command on PATH
stub() { printf '#!/usr/bin/env bash\n%s\n' "$2" > "${STUBS}/$1"; chmod +x "${STUBS}/$1"; }
monitors='printf "Monitor Virtual-1 (ID 0):\n\t1280x800@60.00000 at 0x0\n\tscale: 1.00\n"'
dimensions='printf "screen #0:\n  dimensions:    1920x1080 pixels (508x285 millimeters)\n"'

# run ENV... — kiosk::screen_size in a clean shell with the stubs first on PATH;
# prints "SECONDS WIDTH HEIGHT"
run() {
    env -i PATH="${STUBS}:/usr/bin:/bin" HOME="$WORK" "$@" bash -c '
        source "$1"
        start=$SECONDS
        read -r w h < <(kiosk::screen_size)
        echo "$(( SECONDS - start )) $w $h"
    ' _ "${ROOT}/session/turingos-kiosk"
}

expect() { # expect DESCRIPTION "W H" OUTPUT
    local elapsed size
    read -r elapsed size <<<"$3"
    [[ "$size" == "$2" ]] || fail "$1: got ${size:-nothing}, want $2"
    # Two probes of 3s each at worst; a hang would be the stubs' 60s
    (( elapsed <= 8 )) || fail "$1: took ${elapsed}s"
}

# Hyprland answers: its size wins, and X is never asked
stub hyprctl "$monitors"
stub xdpyinfo 'touch "'"$WORK"'/xdpyinfo-ran"; sleep 60'
expect "Wayland with hyprctl" "1280 800" "$(run WAYLAND_DISPLAY=wayland-1 DISPLAY=:0)"
[[ ! -e "${WORK}/xdpyinfo-ran" ]] || fail "xdpyinfo ran although hyprctl answered"

# XWayland never starts: xdpyinfo hangs, the probe gives up and uses the default
rm -f "${STUBS}/hyprctl"
expect "a hanging X display" "1440 900" "$(run DISPLAY=:0)"

# hyprctl hangs too: still bounded
stub hyprctl 'sleep 60'
expect "a hanging compositor and X display" "1440 900" "$(run WAYLAND_DISPLAY=wayland-1 DISPLAY=:0)"

# Openbox: plain X answers
rm -f "${STUBS}/hyprctl"
stub xdpyinfo "$dimensions"
expect "X11" "1920 1080" "$(run DISPLAY=:0)"

# No display at all
expect "no display" "1440 900" "$(run)"

# gfx::screen_pixels uses the same probe
pixels="$(env -i PATH="${STUBS}:/usr/bin:/bin" DISPLAY=:0 bash -c 'source "$1"; gfx::screen_pixels' _ "${ROOT}/session/turingos-gfx-detect")"
[[ "$pixels" == $(( 1920 * 1080 )) ]] || fail "gfx::screen_pixels: got ${pixels}"

# Ozone platform follows the session
args() {
    env -i PATH="/usr/bin:/bin" "$@" bash -c 'source "$1"; kiosk::args gpu full http://x 1 1 /p' \
        _ "${ROOT}/session/turingos-kiosk"
}
args WAYLAND_DISPLAY=wayland-1 DISPLAY=:0 | grep -qx -- '--ozone-platform=wayland' || fail "Hyprland session did not get Wayland ozone"
args DISPLAY=:0 | grep -qx -- '--ozone-platform=x11' || fail "openbox session did not get X11 ozone"

# On Wayland Brave ignores --class (seen in a VM: brave-127.0.0.1__-Default),
# so the Hyprland rule and Super+Space must both know that app id
rule="$(sed -n 's/^[[:space:]]*match:class = \(.*turingos-shell.*\)$/\1/p' \
    "${ROOT}/debian-live/config/includes.chroot/etc/turingos/hyprland.conf")"
[[ -n "$rule" ]] || fail "hyprland.conf has no shell-window rule"
for class in turingos-shell brave-127.0.0.1__-Default; do
    grep -qE "$rule" <<<"$class" || fail "the Hyprland shell rule misses ${class}"
done
grep -qE "$rule" <<<"brave-browser" && fail "the Hyprland shell rule catches ordinary Brave windows"
if command -v jq &>/dev/null; then
    # Super+Space under Hyprland: the other window is stashed, the shell focused
    stub hyprctl '
case "$1 $2" in
    "clients -j") echo "[{\"class\":\"brave-127.0.0.1__-Default\",\"address\":\"0xshell\",\"workspace\":{\"name\":\"1\"}},{\"class\":\"foot\",\"address\":\"0xfoot\",\"workspace\":{\"name\":\"1\"}}]" ;;
    "monitors -j") echo "[{}]" ;;
    *) echo "$*" >> "'"$WORK"'/dispatched" ;;
esac'
    env -i PATH="${STUBS}:$(dirname "$(command -v jq)"):/usr/bin:/bin" WAYLAND_DISPLAY=wayland-1 XDG_RUNTIME_DIR="$WORK" \
        sh "${ROOT}/session/turingos-omni" >/dev/null 2>&1 || true
    grep -qx 'dispatch focuswindow address:0xfoot' "${WORK}/dispatched" || fail "Super+Space did not stash the other window"
    [[ "$(grep -c movetoworkspacesilent "${WORK}/dispatched")" == 1 ]] || fail "Super+Space stashed the shell window itself"
    [[ "$(grep focuswindow "${WORK}/dispatched" | tail -n 1)" == 'dispatch focuswindow address:0xshell' ]] \
        || fail "Super+Space did not focus the shell"
fi

echo "OK: kiosk display probe and ozone platform"
