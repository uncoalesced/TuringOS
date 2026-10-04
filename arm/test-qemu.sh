#!/usr/bin/env bash
# arm/test-qemu.sh — boot the TuringOS arm64 ISO in qemu-system-aarch64.
#
# Usage:
#   ./arm/test-qemu.sh                                # auto-find the ISO
#   ./arm/test-qemu.sh path/to/live-image-arm64.hybrid.iso
#   ./arm/test-qemu.sh -- -nographic -serial mon:stdio # extra qemu args after --
#
# Needs the EDK2 UEFI firmware: sudo apt install qemu-efi-aarch64

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

die() { echo "ERROR: $*" >&2; exit 1; }

iso=""
if [[ "${1:-}" == "--" ]]; then
    shift
elif [[ -n "${1:-}" && -f "${1:-}" ]]; then
    iso="$1"
    shift
    if [[ "${1:-}" == "--" ]]; then shift; fi
fi
if [[ -z "$iso" ]]; then
    candidates=("${ROOT}"/debian-live/live-image-arm64*.iso)
    for c in "${candidates[@]}"; do
        if [[ -f "$c" ]]; then iso="$c"; break; fi
    done
fi
[[ -n "$iso" && -f "$iso" ]] || die "arm64 ISO not found — run ./arm/build.sh first"

fw=""
for f in /usr/share/AAVMF/AAVMF_CODE.fd /usr/share/qemu-efi-aarch64.fd; do
    if [[ -f "$f" ]]; then fw="$f"; break; fi
done
[[ -n "$fw" ]] || die "UEFI firmware missing — sudo apt install qemu-efi-aarch64"

accel="tcg"
cpu="max"
if [[ -r /dev/kvm ]]; then
    accel="kvm"
    cpu="host"
fi

echo "→ Booting ${iso} (accel=${accel})"
exec qemu-system-aarch64 \
    -machine "virt,accel=${accel}" \
    -cpu "${cpu}" \
    -m 4096 \
    -smp 2 \
    -bios "${fw}" \
    -cdrom "${iso}" \
    -boot d \
    "$@"
