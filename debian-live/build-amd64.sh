#!/usr/bin/env bash
# debian-live/build-amd64.sh — build the TuringOS amd64 ISO.
#
# Everything uses the shared debian-live config: desktop UI, kiosk autologin,
# Claude Code + OpenCode, and the persistent live boot entry.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
STAMP="${ROOT}/debian-live/.build/turingos-arch"

# A previous build for another architecture would be silently reused — purge it
if [[ -d "${ROOT}/debian-live/.build" ]]; then
    if [[ ! -f "$STAMP" ]] || [[ "$(cat "$STAMP")" != amd64 ]]; then
        echo "→ Previous build was for another architecture — lb clean --purge"
        (cd "${ROOT}/debian-live" && sudo lb clean --purge)
    fi
fi

"${ROOT}/debian-live/sync-scripts.sh"

cd "${ROOT}/debian-live"
sudo lb config --distribution trixie --architectures amd64 --linux-flavours amd64 \
    --image-name turingos \
    --bootappend-live "boot=live components quiet splash persistence" \
    --archive-areas "main contrib non-free-firmware"

# lb config just created .build as root
echo amd64 | sudo tee "$STAMP" >/dev/null

sudo lb build

if [[ -f "${ROOT}/debian-live/turingos-amd64.hybrid.iso" ]]; then
    ln -sf turingos-amd64.hybrid.iso "${ROOT}/debian-live/turningos-amd64.hybrid.iso"
    ln -sf turingos-amd64.hybrid.iso "${ROOT}/debian-live/live-image-amd64.hybrid.iso"
fi

echo ""
echo "ISO: ${ROOT}/debian-live/turingos-amd64.hybrid.iso"
echo "Alias: ${ROOT}/debian-live/turningos-amd64.hybrid.iso"
