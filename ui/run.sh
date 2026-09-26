#!/usr/bin/env bash
# run.sh — launch the ui-shell desktop UI
#
# Usage:
#   ./ui/run.sh              app window
#   KIOSK=1 ./ui/run.sh      fullscreen, for the demo
#   LITE=1 ./ui/run.sh       no GPU (VMs without 3D acceleration)

set -euo pipefail

if [[ "${EUID}" -eq 0 ]]; then
    echo "ui-shell must not run as root." >&2
    exit 1
fi

cd "$(dirname "${BASH_SOURCE[0]}")"

# ─── Find Node ────────────────────────────────────────────────────────────────

if ! command -v npm &>/dev/null && [[ -s "${HOME}/.nvm/nvm.sh" ]]; then
    set +u
    # shellcheck disable=SC1091
    source "${HOME}/.nvm/nvm.sh"
    set -u
fi

if ! command -v npm &>/dev/null; then
    echo "Node.js is required. On CachyOS: sudo pacman -S nodejs npm" >&2
    exit 1
fi

# ─── Install on first run (or when package.json changes) ─────────────────────

if [[ ! -x node_modules/.bin/electron || package.json -nt node_modules ]]; then
    echo "Installing ui-shell (first run only)..."
    npm install --no-audit --no-fund
    touch node_modules
fi

# ─── Launch ───────────────────────────────────────────────────────────────────

args=()
if [[ "$(uname -s)" == "Linux" ]]; then
    args+=(--ozone-platform-hint=auto)

    # VMs without 3D acceleration have no render node; draw in software.
    if ! compgen -G "/dev/dri/renderD*" >/dev/null; then
        LITE=1
    fi

    # Electron's sandbox needs unprivileged user namespaces (on by default
    # on CachyOS). If the kernel blocks them, run without it instead of
    # asking for sudo to fix chrome-sandbox permissions.
    if [[ "$(cat /proc/sys/kernel/unprivileged_userns_clone 2>/dev/null)" == "0" ||
          "$(cat /proc/sys/kernel/apparmor_restrict_unprivileged_userns 2>/dev/null)" == "1" ]]; then
        args+=(--no-sandbox)
    fi
fi
if [[ "${LITE:-0}" == "1" ]]; then
    args+=(--disable-gpu)
fi

exec node_modules/.bin/electron . ${args[@]+"${args[@]}"} "$@"
