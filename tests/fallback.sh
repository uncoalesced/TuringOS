#!/usr/bin/env bash
# tests/fallback.sh — Phase 3 fallback: UI crash watchdog (turingos-respawn),
# Super+Esc terminal in every session, safe-mode boot wiring.
# (The safe-mode boot entry itself is covered by tests/persistence_menu.sh.)
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RESPAWN="${ROOT}/pkg/turingos-respawn.sh"
INC="${ROOT}/debian-live/config/includes.chroot"

fail() { echo "FAIL: $*" >&2; exit 1; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

export TURINGOS_RESPAWN_DELAY=0
export TURINGOS_RESPAWN_TERMINAL="${WORK}/terminal"
printf '#!/bin/sh\necho opened > "%s/terminal.log"\n' "$WORK" > "${WORK}/terminal"
chmod +x "${WORK}/terminal"

# A command that crashes until it has run $2 times, then exits 0
cat > "${WORK}/flaky" <<'EOF'
#!/bin/sh
n=$(cat "$1" 2>/dev/null || echo 0)
n=$((n + 1))
echo "$n" > "$1"
[ "$n" -ge "$2" ] && exit 0
exit 3
EOF
chmod +x "${WORK}/flaky"

# ─── crashes then recovers: restarted until the clean exit ───────────────────
bash "$RESPAWN" "${WORK}/flaky" "${WORK}/count1" 3 2>/dev/null || fail "respawn should exit 0 after a clean exit"
[[ $(cat "${WORK}/count1") -eq 3 ]] || fail "want 3 runs (2 crashes + clean exit), got $(cat "${WORK}/count1")"
[[ ! -e "${WORK}/terminal.log" ]] || fail "terminal opened although the command recovered"

# ─── clean exit (Ctrl+Q): never restarted ────────────────────────────────────
bash "$RESPAWN" "${WORK}/flaky" "${WORK}/count2" 1 2>/dev/null || fail "clean exit not passed through"
[[ $(cat "${WORK}/count2") -eq 1 ]] || fail "clean exit was restarted"

# ─── crash loop: gives up and opens the terminal ─────────────────────────────
TURINGOS_RESPAWN_MAX=2 bash "$RESPAWN" "${WORK}/flaky" "${WORK}/count3" 99 2>/dev/null \
    || fail "crash loop should end in the terminal (exit 0)"
[[ $(cat "${WORK}/count3") -eq 3 ]] || fail "want MAX+1=3 runs before giving up, got $(cat "${WORK}/count3")"
grep -qx opened "${WORK}/terminal.log" || fail "terminal not opened after the crash loop"

# ─── logout (SIGTERM to the watchdog): stop, don't restart ───────────────────
# shellcheck disable=SC2016  # $PPID/$1 expand in the child shell
bash "$RESPAWN" sh -c 'echo run >> "$1"; kill -TERM "$PPID"; exit 1' _ "${WORK}/count4" 2>/dev/null \
    || fail "SIGTERM should end respawn cleanly"
[[ $(wc -l < "${WORK}/count4") -eq 1 ]] || fail "respawn restarted after SIGTERM"

# ─── no command: usage error ─────────────────────────────────────────────────
if bash "$RESPAWN" 2>/dev/null; then fail "respawn without a command should fail"; fi

# ─── openbox: hook 0475 adds Super+Esc once ──────────────────────────────────
HOOK="${ROOT}/debian-live/config/hooks/normal/0475-fallback.hook.chroot"
cat > "${WORK}/rc.xml" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<openbox_config xmlns="http://openbox.org/3.4/rc">
  <keyboard>
    <chainQuitKey>C-g</chainQuitKey>
  </keyboard>
  <mouse>
  </mouse>
</openbox_config>
EOF
OPENBOX_RC="${WORK}/rc.xml" bash "$HOOK" >/dev/null || fail "0475 failed on a stock rc.xml"
OPENBOX_RC="${WORK}/rc.xml" bash "$HOOK" >/dev/null || fail "0475 failed on a second run"
[[ $(grep -c 'key="W-Escape"' "${WORK}/rc.xml") -eq 1 ]] || fail "openbox: want exactly one W-Escape keybind"
grep -q '<command>x-terminal-emulator</command>' "${WORK}/rc.xml" || fail "openbox: Super+Esc must open x-terminal-emulator"
[[ $(grep -c '/usr/lib/turingos/session/turingos-omni' "${WORK}/rc.xml") -eq 1 ]] || fail "openbox: want exactly one Super+Space"
[[ $(grep -c 'class="turingos-shell"' "${WORK}/rc.xml") -eq 1 ]] || fail "openbox: want exactly one shell-window rule"
grep -q '<layer>below</layer>' "${WORK}/rc.xml" || fail "openbox: the shell window must sit below other windows"
# A stock rc.xml without <applications> still gets the rule
printf '<openbox_config>\n  <keyboard>\n  </keyboard>\n</openbox_config>\n' > "${WORK}/noapps.xml"
OPENBOX_RC="${WORK}/noapps.xml" bash "$HOOK" >/dev/null || fail "0475 failed on an rc.xml without <applications>"
grep -q 'class="turingos-shell"' "${WORK}/noapps.xml" || fail "openbox: no <applications>, rule lost"
if python3 -c '' 2>/dev/null; then
    python3 -c 'import sys, xml.dom.minidom as m; m.parse(sys.argv[1])' "${WORK}/rc.xml" \
        || fail "openbox rc.xml is not valid XML after 0475"
fi
printf '<openbox_config/>\n' > "${WORK}/bad.xml"
if OPENBOX_RC="${WORK}/bad.xml" bash "$HOOK" >/dev/null 2>&1; then
    fail "0475 accepted an rc.xml without <keyboard>"
fi

# ─── Wayland sessions (trust model stack) ────────────────────────────────────
grep -qx 'bindsym Mod4+Escape exec foot' "${INC}/etc/turingos/sway/config" || fail "sway: Super+Esc missing"
grep -q '<keybind key="W-Escape">' "${INC}/etc/turingos/labwc/rc.xml" || fail "labwc: Super+Esc missing"
grep -qx foot "${ROOT}/debian-live/config/package-lists/turingos.list.chroot" || fail "foot not in the package list"

# ─── safe mode: autostart skips the UI, agent/UI units don't start ───────────
AUTOSTART="${INC}/etc/xdg/openbox/autostart"
grep -q 'grep -qw turingos.safe /proc/cmdline' "$AUTOSTART" || fail "openbox autostart has no safe-mode branch"
grep -q 'turingos-respawn /usr/lib/turingos/session/turingos-kiosk' "$AUTOSTART" || fail "openbox autostart doesn't respawn the UI"
grep -q 'systemctl --user restart turingosd.service' "$AUTOSTART" || fail "openbox autostart doesn't start the desktop service"
grep -qx 'ConditionKernelCommandLine=!turingos.safe' "${ROOT}/session/turingosd.service" || fail "turingosd.service starts in safe mode"
for u in agentd-llm agentd-plan bridged-ws shell shell-helper; do
    grep -qx 'ConditionKernelCommandLine=!turingos.safe' "${ROOT}/trust/daemons/turingos-${u}.service" \
        || fail "turingos-${u}.service starts in safe mode"
done
grep -q 'turingos-respawn brave-browser' "${ROOT}/trust/daemons/launch-ui.sh" || fail "Brave kiosk isn't respawned"
grep -q 'pkg/turingos-respawn.sh' "${ROOT}/debian-live/sync-scripts.sh" || fail "sync-scripts doesn't stage turingos-respawn"

echo "OK: fallback (respawn, Super+Esc in openbox/sway/labwc, safe-mode wiring)"
