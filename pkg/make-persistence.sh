#!/usr/bin/env bash
# make-persistence.sh — Kali-style persistence for the TuringOS live ISO.
#
# Creates an ext4 partition labelled `persistence` and writes the
# persistence.conf live-boot needs (`/ union` = overlay the whole system).
# Boot the ISO and pick "Live system (persistence)" at the boot menu; the
# files you change (including ~/.turingos and your API key) then survive
# reboots. The plain "Live system" entry stays ephemeral.
#
# Usage:
#   sudo ./pkg/make-persistence.sh /dev/sdX        add a partition in the disk's free space
#   sudo ./pkg/make-persistence.sh /dev/sdX3       format an existing partition
#   sudo ./pkg/make-persistence.sh /tmp/usb.img 4G create a disk image (QEMU tests)
#
# Options:
#   -y, --yes     don't ask for confirmation
#   -f, --force   overwrite an existing filesystem on the target partition
#   -h, --help    show this help
#
# Existing partitions are never touched unless you name one explicitly.

set -euo pipefail

die() { echo "ERROR: $*" >&2; exit 1; }

usage() { sed -n '2,20p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; }

yes=0
force=0
args=()
while [[ $# -gt 0 ]]; do
    case "$1" in
        -y|--yes)   yes=1 ;;
        -f|--force) force=1 ;;
        -h|--help)  usage; exit 0 ;;
        -*)         die "unknown option: $1 (see --help)" ;;
        *)          args+=("$1") ;;
    esac
    shift
done
target="${args[0]:-}"
size="${args[1]:-4G}"
[[ -n "$target" ]] || { usage; exit 1; }
[[ ${#args[@]} -le 2 ]] || die "unexpected argument: ${args[2]}"
[[ $EUID -eq 0 ]] || die "run as root: sudo $0 ..."

loopdev=""
cleanup() {
    if [[ -n "$loopdev" ]]; then
        losetup -d "$loopdev" 2>/dev/null || true
    fi
}
trap cleanup EXIT

# ─── resolve the target ──────────────────────────────────────────────────────
# A path that does not exist is treated as a new disk image to create.
is_image=0
dev=""
if [[ -b "$target" ]]; then
    dev="$target"
elif [[ -f "$target" ]]; then
    is_image=1
elif [[ "$target" == /dev/* ]]; then
    die "no such device: $target"
else
    is_image=1
    echo "→ Creating disk image ${target} (${size})"
    truncate -s "$size" "$target"
fi

if [[ $is_image -eq 1 ]]; then
    loopdev="$(losetup -f --show -P "$target")" || die "losetup failed on $target"
    dev="$loopdev"
fi

# ─── decide: create a partition, or format an existing one ───────────────────
part=""
type="$(lsblk -ndo TYPE "$dev" | head -1)"
[[ -n "$type" ]] || die "cannot determine the type of $dev"

if [[ "$type" == disk || "$type" == loop ]]; then
    # whole disk (or a loop device): add a partition in the free space
    parted -sm "$dev" unit MiB print >/dev/null 2>&1 \
        || parted -s "$dev" mklabel gpt
    last_end="$(parted -sm "$dev" unit MiB print | awk -F: '
        $1 ~ /^[0-9]+$/ { v = $3; sub(/MiB$/, "", v); if (v + 0 > m) m = v + 0 }
        END { print m + 0 }')"
    disk_size="$(parted -sm "$dev" unit MiB print | awk -F: '
        NR == 2 { v = $2; sub(/MiB$/, "", v); print v + 0 }')"
    [[ -n "$disk_size" ]] || die "cannot read the size of $dev"
    start=$((last_end + 1))
    [[ $start -lt $disk_size ]] || die "no free space left on $dev"
    echo "→ Creating partition ${start}MiB–100% on $dev"
    parted -s "$dev" mkpart primary ext4 "${start}MiB" 100%
    partprobe "$dev" 2>/dev/null || true
    udevadm settle 2>/dev/null || true
    num="$(parted -sm "$dev" print | awk -F: '$1 ~ /^[0-9]+$/ { n = $1 } END { print n + 0 }')"
    if [[ "$dev" =~ [0-9]$ ]]; then
        part="${dev}p${num}"
    else
        part="${dev}${num}"
    fi
    # a loop device may need a re-attach before the new partition shows up
    if [[ $is_image -eq 1 && ! -b "$part" ]]; then
        losetup -d "$loopdev" || true
        loopdev="$(losetup -f --show -P "$target")"
        dev="$loopdev"
        if [[ "$dev" =~ [0-9]$ ]]; then part="${dev}p1"; else part="${dev}1"; fi
    fi
    for _ in {1..50}; do
        if [[ -b "$part" ]]; then break; fi
        sleep 0.1
    done
    [[ -b "$part" ]] || die "partition $part never appeared"
else
    # an existing partition: only ever format it, and only on request
    part="$dev"
    if findmnt -rn "$part" >/dev/null 2>&1; then
        die "$part is mounted — unmount it first"
    fi
    if blkid -o value -s TYPE "$part" >/dev/null 2>&1; then
        [[ $force -eq 1 ]] || die "$part already has a filesystem — re-run with --force to overwrite"
    fi
fi

# ─── confirm, then format ────────────────────────────────────────────────────
echo "Target:  $part"
echo "Action:  mkfs.ext4 -L persistence  (ALL DATA ON $part WILL BE LOST)"
if [[ $yes -eq 0 ]]; then
    read -r -p "Continue? [y/N] " answer
    [[ "$answer" == y || "$answer" == Y ]] || die "aborted"
fi

mkfs.ext4 -F -L persistence "$part" >/dev/null

mnt="$(mktemp -d)"
mount "$part" "$mnt"
echo '/ union' > "${mnt}/persistence.conf"
sync
umount "$mnt"
rmdir "$mnt"

echo "✓ $part is ready: ext4, labelled 'persistence', persistence.conf written"
echo "  Boot the ISO and choose 'Live system (persistence)' at the boot menu."
