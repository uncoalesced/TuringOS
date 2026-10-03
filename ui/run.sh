#!/usr/bin/env bash
# run.sh — launch the TuringOS desktop UI from a checkout
#
# Usage:
#   ./ui/run.sh              app window (builds it on first run)
#   KIOSK=1 ./ui/run.sh      fullscreen, as on the live ISO
#   LITE=1 ./ui/run.sh       software rendering (VMs without 3D acceleration)
#
# Building needs Rust plus the WebKitGTK/ALSA dev packages:
#   sudo apt install cargo-web build-essential libwebkit2gtk-4.1-dev libasound2-dev libxdo-dev cmake clang libclang-dev pkg-config

set -euo pipefail

if [[ "${EUID}" -eq 0 ]]; then
    echo "The TuringOS UI must not run as root." >&2
    exit 1
fi

cd "$(dirname "${BASH_SOURCE[0]}")/src-tauri"
# The checkout's turingos, not an installed one
TURINGOS_ROOT="${TURINGOS_ROOT:-$(cd ../.. && pwd)}"
export TURINGOS_ROOT TURINGOS_BIN="${TURINGOS_BIN:-${TURINGOS_ROOT}/turingos}"

exec cargo run --release --quiet -- "$@"
