#!/usr/bin/env bash
# arm/test-qemu.sh — boot the TuringOS arm64 ISO in qemu-system-aarch64.
#
# Usage:
#   ./arm/test-qemu.sh                                # auto-find the ISO
#   ./arm/test-qemu.sh path/to/live-image-arm64.hybrid.iso
#   ./arm/test-qemu.sh -- -nographic -serial mon:stdio # extra qemu args after --
#   QEMU_DISPLAY=vnc=:1 ./arm/test-qemu.sh            # headless, VNC on :5901
#   DISK=/tmp/arm-install.qcow2 ./arm/test-qemu.sh    # + a 20G disk for the installer
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

# The virt machine has no display or input devices of its own. Without a GPU
# the UI lands on a bare EFI framebuffer with software drawing (no DRM render
# node, see ui/src-tauri/src/system.rs) and the pointer lags: virtio-gpu gives
# Xorg a KMS device, the USB tablet absolute pointing.
# QEMU_DISPLAY overrides the window (e.g. vnc=:1 on a headless host).
display="${QEMU_DISPLAY:-gtk}"

# DISK=path (created at 20G if missing) adds a virtio disk to install onto
disk_args=()
if [[ -n "${DISK:-}" ]]; then
    [[ -f "$DISK" ]] || qemu-img create -f qcow2 "$DISK" 20G >/dev/null
    disk_args=(-drive "file=${DISK},if=virtio,format=qcow2")
fi

echo "→ Booting ${iso} (accel=${accel}, display=${display})"
exec qemu-system-aarch64 \
    -machine "virt,accel=${accel}" \
    -cpu "${cpu}" \
    -m 4096 \
    -smp 2 \
    -bios "${fw}" \
    -device virtio-gpu-pci \
    -device qemu-xhci \
    -device usb-kbd \
    -device usb-tablet \
    -display "${display}" \
    -cdrom "${iso}" \
    "${disk_args[@]}" \
    -boot d \
    "$@"
