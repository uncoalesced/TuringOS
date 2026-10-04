#!/usr/bin/env bash
# tests/persistence_menu.sh — boot-menu hooks. 0900 sets boot timeouts and
# 0910 adds a Kali-style "Live system (persistence)" entry, for amd64-style
# trees (isolinux + GRUB) and arm64-style trees (GRUB only, no isolinux/).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HOOKS="${ROOT}/debian-live/config/hooks/normal"
TIMEOUT_HOOK="${HOOKS}/0900-boot-timeout.hook.binary"
PERSIST_HOOK="${HOOKS}/0910-persistence-menu.hook.binary"

fail() { echo "FAIL: $*" >&2; exit 1; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# ─── amd64-style tree: isolinux (BIOS) + GRUB (UEFI) ─────────────────────────
amd64="${WORK}/amd64"
mkdir -p "${amd64}/isolinux" "${amd64}/boot/grub"

cat > "${amd64}/isolinux/isolinux.cfg" <<'EOF'
timeout 0
include menu.cfg
EOF

cat > "${amd64}/isolinux/live.cfg" <<'EOF'
label live-amd64
menu label ^Live system (amd64)
kernel /live/vmlinuz-6.12.9-amd64
append initrd=/live/initrd.img-6.12.9-amd64 boot=live components quiet splash
label live-amd64-verbose
menu label ^Live system (amd64, verbose)
kernel /live/vmlinuz-6.12.9-amd64
append initrd=/live/initrd.img-6.12.9-amd64 boot=live components
EOF

cat > "${amd64}/boot/grub/config.cfg" <<'EOF'
set timeout=0
EOF

cat > "${amd64}/boot/grub/grub.cfg" <<'EOF'
source $prefix/config.cfg
menuentry 'Live system (amd64)' --class gnu-linux --id 'gnulinux-simple-x' {
linux /live/vmlinuz-6.12.9-amd64 boot=live components quiet splash
initrd /live/initrd.img-6.12.9-amd64
}
menuentry 'Live system (amd64, verbose)' --class gnu-linux {
linux /live/vmlinuz-6.12.9-amd64 boot=live components
initrd /live/initrd.img-6.12.9-amd64
}
EOF

(cd "$amd64" && bash "$TIMEOUT_HOOK" && bash "$PERSIST_HOOK") \
    || fail "hooks failed on amd64-style tree"

live="${amd64}/isolinux/live.cfg"
grub="${amd64}/boot/grub/grub.cfg"

grep -qx 'timeout 30' "${amd64}/isolinux/isolinux.cfg" || fail "isolinux timeout not set"
grep -qx 'set timeout=3' "${amd64}/boot/grub/config.cfg" || fail "grub timeout not set"

grep -qx 'label live-amd64-persistence' "$live" || fail "isolinux persistence label missing"
grep -qx 'menu label ^Live system (amd64) (persistence)' "$live" || fail "isolinux menu label suffix"
grep -qx 'append initrd=/live/initrd.img-6.12.9-amd64 boot=live components quiet splash persistence' \
    "$live" || fail "isolinux persistence cmdline"
[[ $(grep -c '^label ' "$live") -eq 3 ]] || fail "isolinux: want 2 original + 1 persistence labels"
grep -qx 'label live-amd64' "$live" || fail "isolinux original entry lost"

grep -Fqx "menuentry 'Live system (amd64) (persistence)' --class gnu-linux --id 'gnulinux-simple-x-persistence' {" "$grub" \
    || fail "grub persistence title (class/id args must survive the rename)"
grep -Fqx 'linux /live/vmlinuz-6.12.9-amd64 boot=live components quiet splash persistence' \
    "$grub" || fail "grub persistence cmdline"
[[ $(grep -c '(persistence)' "$grub") -eq 1 ]] || fail "grub: want exactly one persistence entry"
grep -Fqx "menuentry 'Live system (amd64)' --class gnu-linux --id 'gnulinux-simple-x' {" "$grub" || fail "grub original entry lost"

# ─── arm64-style tree: GRUB only (live-build skips isolinux on arm64) ────────
arm64="${WORK}/arm64"
mkdir -p "${arm64}/boot/grub"
cat > "${arm64}/boot/grub/config.cfg" <<'EOF'
set timeout=0
EOF
cat > "${arm64}/boot/grub/grub.cfg" <<'EOF'
menuentry 'Live system (arm64)' {
linux /live/vmlinuz-6.12.1-arm64 boot=live components quiet splash
initrd /live/initrd.img-6.12.1-arm64
}
EOF

(cd "$arm64" && bash "$TIMEOUT_HOOK" && bash "$PERSIST_HOOK") \
    || fail "hooks failed on arm64-style tree (no isolinux/)"
grep -qx 'set timeout=3' "${arm64}/boot/grub/config.cfg" || fail "arm64 grub timeout not set"
grep -Fqx "menuentry 'Live system (arm64) (persistence)' {" "${arm64}/boot/grub/grub.cfg" \
    || fail "arm64 grub persistence entry"
grep -Fqx 'linux /live/vmlinuz-6.12.1-arm64 boot=live components quiet splash persistence' \
    "${arm64}/boot/grub/grub.cfg" || fail "arm64 grub persistence cmdline"

# ─── empty tree: both hooks must refuse to guess ─────────────────────────────
mkdir -p "${WORK}/empty"
if (cd "${WORK}/empty" && bash "$TIMEOUT_HOOK" 2>/dev/null); then
    fail "0900 accepted a tree with no boot menus"
fi
if (cd "${WORK}/empty" && bash "$PERSIST_HOOK" 2>/dev/null); then
    fail "0910 accepted a tree with no live entries"
fi

echo "OK: boot menu hooks (timeouts + persistence) on amd64 and arm64 trees"
