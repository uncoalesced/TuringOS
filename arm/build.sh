#!/usr/bin/env bash
# arm/build.sh — build the TuringOS arm64 ISO.
#
# Everything except the architecture is identical to the amd64 build because
# the debian-live config is shared: desktop UI, kiosk autologin, Claude Code +
# OpenCode, and the "Live system (persistence)" boot entry (hook 0910). The
# only differences live in `lb config --architectures arm64` and the arch
# conditionals in the package list.
#
# Needs an arm64 Debian host: the hooks run real binaries inside the chroot
# (apt-get, `cargo build` in 0450, `claude --version` in 0500). On an x86
# host this only works with user-mode emulation:
#   sudo apt install qemu-user-static binfmt-support

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
STAMP="${ROOT}/debian-live/.build/turingos-arch"

arch="$(dpkg --print-architecture 2>/dev/null || uname -m)"
case "$arch" in
    arm64|aarch64) ;;
    *)
        echo "WARNING: building an arm64 image on '${arch}'." >&2
        echo "         This only works if arm64 binaries run here (arm64 host or" >&2
        echo "         qemu-user binfmt). Install qemu-user-static if in doubt." >&2
        ;;
esac

# A previous build for another architecture would be silently reused — purge it
if [[ -d "${ROOT}/debian-live/.build" ]]; then
    if [[ ! -f "$STAMP" ]] || [[ "$(cat "$STAMP")" != arm64 ]]; then
        echo "→ Previous build was for another architecture — lb clean --purge"
        (cd "${ROOT}/debian-live" && sudo lb clean --purge)
    fi
fi

"${ROOT}/debian-live/sync-scripts.sh"

cd "${ROOT}/debian-live"
sudo lb config --distribution trixie --architectures arm64 \
    --archive-areas "main contrib non-free-firmware"

# lb config just created .build as root
echo arm64 | sudo tee "$STAMP" >/dev/null

sudo lb build
echo ""
echo "ISO: ${ROOT}/debian-live/live-image-arm64.hybrid.iso"
echo "Test: ${ROOT}/arm/test-qemu.sh"
