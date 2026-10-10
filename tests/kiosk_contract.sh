#!/usr/bin/env bash
# tests/kiosk_contract.sh — the shell as a real browser window: Openbox with
# the rc.xml hook 0475 makes, turingos-bridged-ws serving the page, the built
# turingosd and shell-helper behind it, session/turingos-kiosk and Brave (or
# another Chromium-family browser) on a virtual display, drawing in software.
#
# This is the contract a browser update can break without any change of ours:
# the app window gets our class and becomes the desktop, the page signs in and
# connects, the browser's own shortcuts do nothing, Super+Space and Super+Esc
# work, and the screen is not blank. CI runs it weekly and on session changes.
#
# Needs: Xvfb openbox xdotool xprop xdpyinfo curl jq python3 (with fastapi and
# uvicorn) xterm, ImageMagick (import, compare), a browser, and turingosd (TURINGOSD=/path, else the
# checkout's release build, else the installed one). With anything missing it
# skips; KIOSK_CONTRACT=require turns the skip into a failure.
#
#   KIOSK_ARTIFACTS=dir   keep screenshots and logs there
#   TURINGOS_BROWSER=...  browser to test (default: brave-browser, then chromium)
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SESSION="${ROOT}/session"

fail() { echo "FAIL: $*" >&2; exit 1; }
skip() {
    if [[ "${KIOSK_CONTRACT:-}" == require ]]; then fail "cannot run: $*"; fi
    echo "SKIP: kiosk contract ($*)"
    exit 0
}

[[ "$(uname -s)" == Linux ]] || skip "Linux only"
for cmd in Xvfb openbox xdotool xprop xdpyinfo curl jq python3 xterm import compare; do
    command -v "$cmd" &>/dev/null || skip "${cmd} is not installed"
done
[[ -r /etc/xdg/openbox/rc.xml ]] || skip "no stock Openbox rc.xml"
python3 -c 'import fastapi, uvicorn' 2>/dev/null || skip "python3 has no fastapi/uvicorn"

BROWSER_BIN=""
for candidate in ${TURINGOS_BROWSER:+"$TURINGOS_BROWSER"} brave-browser chromium chromium-browser google-chrome; do
    if command -v "$candidate" &>/dev/null; then BROWSER_BIN="$candidate"; break; fi
done
[[ -n "$BROWSER_BIN" ]] || skip "no Chromium-family browser"

TURINGOSD="${TURINGOSD:-}"
for candidate in "${CARGO_TARGET_DIR:-${ROOT}/daemon/target}/release/turingosd" /usr/bin/turingosd; do
    [[ -n "$TURINGOSD" ]] || { [[ -x "$candidate" ]] && TURINGOSD="$candidate"; } || true
done
[[ -n "$TURINGOSD" && -x "$TURINGOSD" ]] || skip "turingosd is not built (cargo build --release in daemon/)"
command -v x-terminal-emulator &>/dev/null || skip "no x-terminal-emulator (Super+Esc opens it)"

# Short: the control socket's path has about 100 bytes to live in
WORK="$(mktemp -d /tmp/tos-kiosk.XXXXXX)"
ART="${KIOSK_ARTIFACTS:-${WORK}/artifacts}"
# ~/.turingos makes the page live (otherwise it refuses to run anything)
mkdir -p "$ART" "${WORK}/home/.turingos" "${WORK}/run" "${WORK}/state" "${WORK}/session"
chmod 700 "${WORK}/run"
PIDS=()
cleanup() {
    local status=$?
    for pid in "${PIDS[@]}"; do kill "$pid" 2>/dev/null || true; done
    pkill -f "user-data-dir=${WORK}/state" 2>/dev/null || true
    sleep 0.3
    if (( status != 0 )); then
        echo "--- turingosd"; tail -n 15 "${ART}/turingosd.log" 2>/dev/null || true
        echo "--- bridge"; tail -n 15 "${ART}/bridge.log" 2>/dev/null || true
        echo "--- kiosk"; tail -n 15 "${ART}/kiosk.log" 2>/dev/null || true
        echo "(artifacts: ${ART})"
    fi
    [[ -n "${KIOSK_ARTIFACTS:-}" ]] || rm -rf "$ART"
    rm -rf "$WORK"
    exit "$status"
}
trap cleanup EXIT

export HOME="${WORK}/home" XDG_RUNTIME_DIR="${WORK}/run" XDG_STATE_HOME="${WORK}/state"
# The bridge, the helper and the service meet here instead of /run/turingos/session
ME="$(id -u)"
export TURINGOS_SESSION_DIR="${WORK}/session" TURINGOS_SHELL_ALLOW_UIDS="$ME" TURINGOS_DESKTOP_ALLOW_UIDS="$ME"
export TURINGOS_BROWSER="$BROWSER_BIN"
unset DBUS_SESSION_BUS_ADDRESS WAYLAND_DISPLAY XAUTHORITY

WIDTH=1280 HEIGHT=800

# ─── Display and window manager ──────────────────────────────────────────────
Xvfb -displayfd 3 -screen 0 "${WIDTH}x${HEIGHT}x24" -nolisten tcp 3> "${WORK}/display" 2> "${ART}/xvfb.log" &
PIDS+=($!)
for _ in $(seq 50); do [[ -s "${WORK}/display" ]] && break; sleep 0.1; done
[[ -s "${WORK}/display" ]] || fail "Xvfb did not start"
DISPLAY=":$(cat "${WORK}/display")"
export DISPLAY

# What hook 0475 makes of the stock rc.xml, with the installed paths in our
# key bindings pointed at this checkout
cp /etc/xdg/openbox/rc.xml "${WORK}/rc.xml"
OPENBOX_RC="${WORK}/rc.xml" bash "${ROOT}/debian-live/config/hooks/normal/0475-fallback.hook.chroot" >/dev/null
sed -i "s|/usr/lib/turingos/session|${SESSION}|g" "${WORK}/rc.xml"
openbox --config-file "${WORK}/rc.xml" 2> "${ART}/openbox.log" &
PIDS+=($!)
for _ in $(seq 50); do xprop -root _NET_SUPPORTING_WM_CHECK 2>/dev/null | grep -q 'window id' && break; sleep 0.1; done

# ─── Bridge, desktop service and shell ───────────────────────────────────────
PORT="$(python3 -c 'import socket; s = socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1])')"
export TURINGOS_UI_PORT="$PORT" TURINGOS_UI_DIR="${TURINGOS_UI_DIR:-${ROOT}/ui/web}"
[[ -f "${TURINGOS_UI_DIR}/index.html" ]] || fail "no page in ${TURINGOS_UI_DIR}"
"$TURINGOSD" 2> "${ART}/turingosd.log" &
PIDS+=($!)
python3 "${ROOT}/trust/daemons/shell-helper.py" 2> "${ART}/shell-helper.log" &
PIDS+=($!)
python3 "${ROOT}/trust/daemons/bridged-ws.py" --port "$PORT" > "${ART}/bridge.log" 2>&1 &
PIDS+=($!)

status() { curl -fsS --max-time 2 --unix-socket "${XDG_RUNTIME_DIR}/turingos/control.sock" http://d/status; }
stat() { status | jq -r "$1"; }
wait_for() { # wait_for SECONDS DESCRIPTION COMMAND...
    local seconds="$1" what="$2" i
    shift 2
    for (( i = 0; i < seconds * 5; i++ )); do
        if "$@" &>/dev/null; then return 0; fi
        sleep 0.2
    done
    fail "timed out after ${seconds}s waiting for ${what}"
}
wait_for 20 "turingosd" status
bridge_up() { curl -fsS --max-time 1 "http://127.0.0.1:${PORT}/health"; }
wait_for 20 "turingos-bridged-ws" bridge_up

start_kiosk() {
    "${SESSION}/turingos-kiosk" >> "${ART}/kiosk.log" 2>&1 &
    KIOSK_PID=$!
    PIDS+=("$KIOSK_PID")
}
# The managed window (decimal id) whose WM_CLASS names this class
client_by_class() {
    local id
    for id in $(xprop -root _NET_CLIENT_LIST 2>/dev/null | sed -n 's/.*# //p' | tr -d ','); do
        if xprop -id "$id" WM_CLASS 2>/dev/null | grep -q "\"$1\""; then
            echo $(( id ))
            return 0
        fi
    done
    return 1
}
shell_window() { client_by_class turingos-shell; }
have_shell() { shell_window >/dev/null; }
page_connected() { [[ "$(stat .pages)" == 1 ]]; }

start_kiosk
wait_for 60 "the shell window" have_shell
wait_for 30 "the page to reach turingosd through the bridge" page_connected
SHELL_ID="$(shell_window)"
sleep 2 # first paint and the entrance animation

# ─── The window is the desktop ───────────────────────────────────────────────
grep -q 'on the sw path' "${ART}/kiosk.log" || fail "a virtual display must take the software path: $(cat "${ART}/kiosk.log")"
[[ "$(stat .gfx.path)" == sw ]] || fail "turingosd did not get the software hint"
xprop -id "$SHELL_ID" WM_CLASS | grep -q '"turingos-shell"' || fail "WM_CLASS: $(xprop -id "$SHELL_ID" WM_CLASS)"
read -r win_w win_h < <(xdotool getwindowgeometry --shell "$SHELL_ID" | awk -F= '/WIDTH/ { w = $2 } /HEIGHT/ { h = $2 } END { print w, h }')
[[ "$win_w" == "$WIDTH" && "$win_h" == "$HEIGHT" ]] || fail "the shell is ${win_w}x${win_h}, not the whole ${WIDTH}x${HEIGHT} screen (decorated or not maximised?)"
state="$(xprop -id "$SHELL_ID" _NET_WM_STATE)"
grep -q '_NET_WM_STATE_BELOW' <<<"$state" || fail "the shell is not below other windows: ${state}"
xprop -id "$SHELL_ID" _NET_WM_DESKTOP | grep -qE '= (4294967295|-1)$' || fail "the shell is not on every desktop: $(xprop -id "$SHELL_ID" _NET_WM_DESKTOP)"

shot() { import -window root "${ART}/$1.png"; }
shot 01-shell
colors="$(identify -format '%k' "${ART}/01-shell.png")"
(( colors > 200 )) || fail "the screen looks blank (${colors} colours); see ${ART}/01-shell.png"
# Nothing of the browser's own may show: a first-run infobar is a white strip
# across the top, where the page's menu bar belongs
strip="$(import -window root -crop "${WIDTH}x4+0+2" -format '%k' info: 2>/dev/null || echo 0)"
top="$(import -window root -crop "1x1+$((WIDTH / 2))+10" -format '%[hex:u.p{0,0}]' info: 2>/dev/null || echo "")"
[[ "${top^^}" != FFFFFF* ]] || fail "a browser infobar covers the top of the shell (strip colours: ${strip}); see ${ART}/01-shell.png"

# ─── The browser's own shortcuts do nothing ──────────────────────────────────
# Real key presses (XTEST) to whatever has the focus, as a keyboard would
windows() { xprop -root _NET_CLIENT_LIST | tr ',' '\n' | grep -c '0x'; }
shell_active() { [[ "$(xdotool getactivewindow 2>/dev/null)" == "$SHELL_ID" ]]; }
xdotool windowactivate "$SHELL_ID"
wait_for 5 "the shell to take the focus" shell_active
before_windows="$(windows)"
for keys in ctrl+w ctrl+t ctrl+n ctrl+shift+n ctrl+q ctrl+r F5 F11 ctrl+shift+t ctrl+p ctrl+s ctrl+o ctrl+u ctrl+h ctrl+l \
    ctrl+plus ctrl+equal ctrl+minus ctrl+0 alt+Left; do
    shell_active || fail "the shell lost the focus before ${keys}"
    xdotool key "$keys"
    sleep 0.4
    [[ "$(shell_window || true)" == "$SHELL_ID" ]] || fail "${keys} closed or replaced the shell window"
    [[ "$(windows)" == "$before_windows" ]] || fail "${keys} opened a window ($(windows) windows, was ${before_windows})"
done
sleep 1
[[ "$(stat .connections)" == 1 ]] || fail "a shortcut reloaded the page ($(stat .connections) connections)"
[[ "$(stat .pages)" == 1 ]] || fail "the page lost its connection after the shortcuts"
read -r win_w win_h < <(xdotool getwindowgeometry --shell "$SHELL_ID" | awk -F= '/WIDTH/ { w = $2 } /HEIGHT/ { h = $2 } END { print w, h }')
[[ "$win_w" == "$WIDTH" && "$win_h" == "$HEIGHT" ]] || fail "a shortcut resized the shell to ${win_w}x${win_h}"
if xprop -id "$SHELL_ID" _NET_WM_STATE | grep -q '_NET_WM_STATE_FULLSCREEN'; then fail "F11 put the shell in fullscreen"; fi
shot 02-after-shortcuts
changed="$(compare -metric AE -fuzz 4% "${ART}/02-after-shortcuts.png" "${ART}/01-shell.png" null: 2>&1 || true)"
changed="${changed%%[^0-9]*}"
(( ${changed:-0} < 20000 )) || fail "the shortcuts left something open (${changed} pixels differ); see ${ART}/02-after-shortcuts.png"

# ─── Super+Esc: a terminal above the shell ───────────────────────────────────
# x-terminal-emulator is often lxterm, which runs xterm as UXTerm
terminal_window() { client_by_class XTerm || client_by_class UXTerm; }
have_terminal() { terminal_window >/dev/null; }
xdotool key super+Escape
wait_for 10 "the Super+Esc terminal" have_terminal
TERM_ID="$(terminal_window)"
stacking="$(xprop -root _NET_CLIENT_LIST_STACKING | sed 's/.*# //' | tr -d ' ')"
python3 - "$stacking" "$SHELL_ID" "$TERM_ID" <<'EOF' || fail "the terminal is not above the shell: ${stacking}"
import sys
order = [int(w, 16) for w in sys.argv[1].split(",")]
shell, term = int(sys.argv[2]), int(sys.argv[3])
assert order.index(shell) < order.index(term)
EOF
shot 03-terminal

# ─── Super+Space: everything else out of the way, command bar open ───────────
presses="$(stat .omni_presses)"
xdotool key super+space
omni_pressed() { [[ "$(stat .omni_presses)" == "$((presses + 1))" ]]; }
wait_for 5 "Super+Space to reach turingosd" omni_pressed
terminal_hidden() { xprop -id "$TERM_ID" _NET_WM_STATE | grep -q '_NET_WM_STATE_HIDDEN'; }
wait_for 5 "the terminal to be minimised" terminal_hidden
wait_for 5 "the shell to be the active window" shell_active
sleep 1.2
shot 04-omni
# The command bar is a large panel in the middle of the screen
changed="$(compare -metric AE -fuzz 4% "${ART}/04-omni.png[640x360+320+120]" "${ART}/01-shell.png[640x360+320+120]" null: 2>&1 || true)"
changed="${changed%%[^0-9]*}"
(( ${changed:-0} > 5000 )) || fail "Super+Space did not open the command bar (${changed:-0} pixels changed); see ${ART}/04-omni.png"
xdotool key Escape
kill "$(xdotool getwindowpid "$TERM_ID" 2>/dev/null)" 2>/dev/null || true

# ─── Shell mode: "$ command" in the composer runs through /shell ─────────────
# (the fallback for when the AI is unreachable), as the logged-in user
xdotool windowactivate "$SHELL_ID"
wait_for 5 "the shell to take the focus" shell_active
# The composer sits in the middle of the screen, a little below centre
xdotool mousemove $((WIDTH / 2)) $((HEIGHT * 65 / 100)) click 1
sleep 0.3
xdotool type --delay 20 "\$ touch ${WORK}/home/shell-mode-ran"
xdotool key Return
ran() { [[ -e "${WORK}/home/shell-mode-ran" ]]; }
if ! (wait_for 10 "the shell-mode command to run" ran); then
    shot 05-shell-mode-failed
    fail "shell mode did not run the command; see ${ART}/05-shell-mode-failed.png"
fi
[[ "$(command stat -c %u "${WORK}/home/shell-mode-ran")" == "$ME" ]] || fail "the shell-mode command ran as someone else"
sleep 0.5
shot 05-shell-mode

# ─── A dead browser can be started again ─────────────────────────────────────
pkill -f "user-data-dir=${WORK}/state" || fail "no browser process on the shell's profile"
kiosk_gone() { ! kill -0 "$KIOSK_PID" 2>/dev/null; }
wait_for 15 "turingos-kiosk to exit with its browser" kiosk_gone
[[ ! -e "${XDG_STATE_HOME}/turingos/force-sw" ]] || fail "the software path wrote a force-sw flag"
start_kiosk
wait_for 60 "the shell window after a restart" have_shell
two_connections() { [[ "$(stat .connections)" == 2 && "$(stat .pages)" == 1 ]]; }
wait_for 30 "the restarted page to reach turingosd again" two_connections
sleep 1.5
shot 06-restarted
colors="$(identify -format '%k' "${ART}/06-restarted.png")"
(( colors > 200 )) || fail "the restarted shell looks blank (${colors} colours)"

echo "OK: kiosk contract ($("$BROWSER_BIN" --version 2>/dev/null | head -n1), software path, ${WIDTH}x${HEIGHT})"
