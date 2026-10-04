#!/bin/bash
# tests/brave_hook.sh — the Brave install hook (static checks; the live build
# itself can't run in CI). The hook must install from a signed repo, wire both
# browser entry points the UI uses (x-www-browser and xdg-open mime defaults),
# and fail the build if verification doesn't pass.
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
HOOK="$ROOT/debian-live/config/hooks/normal/0420-install-brave.hook.chroot"

fail() {
    echo "FAIL: $*"
    exit 1
}

[[ -f "$HOOK" ]] || fail "0420-install-brave hook missing"
[[ -x "$HOOK" ]] || fail "0420-install-brave hook not executable"
bash -n "$HOOK" || fail "0420-install-brave hook has syntax errors"

need() {
    grep -qF -- "$1" "$HOOK" || fail "hook misses: $1"
}

# Signed install from Brave's own repo
need 'set -euo pipefail'
need 'brave-browser-archive-keyring.gpg'
need 'signed-by=/etc/apt/keyrings/brave.gpg'
need 'sources.list.d/brave.list'
need 'apt-get install -y brave-browser'

# Both entry points: dock fallback (launch.rs) and xdg-open links
need 'update-alternatives --install /usr/bin/x-www-browser'
need 'x-scheme-handler/https=brave-browser.desktop'
need 'x-scheme-handler/http=brave-browser.desktop'

# Build-time verification, same contract as the other hooks
need 'command -v brave-browser'
need 'brave-browser.desktop'
need 'update-alternatives --query x-www-browser'
need 'apt-get clean'

echo "OK: 0420-install-brave hook (signed repo, defaults, verification)"
