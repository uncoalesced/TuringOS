#!/usr/bin/env bash
# tests/boot_brand.sh — the TuringOS boot look. Hook 0920 swaps live-build's
# Debian splashes for debian-live/branding's, recolours the isolinux and GRUB
# menus and renames "Live system" entries, for amd64-style trees (isolinux +
# GRUB) and arm64-style trees (GRUB only). Also checks the committed art the
# plymouth (0460) and installer (0495) hooks expect.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HOOK="${ROOT}/debian-live/config/hooks/normal/0920-boot-brand.hook.binary"
BRANDING="${ROOT}/debian-live/branding"

fail() { echo "FAIL: $*" >&2; exit 1; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# ─── committed art ────────────────────────────────────────────────────────────
for f in isolinux-splash.png grub-splash.png logo-256.png slides/slide-1.png slides/slide-2.png slides/slide-3.png \
         plymouth/turingos/turingos.plymouth plymouth/turingos/turingos.script \
         plymouth/turingos/logo.png plymouth/turingos/dot.png plymouth/turingos/strip.png; do
    [[ -s "${BRANDING}/${f}" ]] || fail "debian-live/branding/${f} is missing (run make-boot-art.py)"
done
grep -qx 'plymouth' "${ROOT}/debian-live/config/package-lists/turingos.list.chroot" \
    || fail "plymouth is not in the package list (hook 0460 needs it)"

stage() {   # <tree>: what sync-scripts.sh + live-build's binary_includes leave behind
    mkdir -p "${1}/turingos-boot"
    cp "${BRANDING}/isolinux-splash.png" "${BRANDING}/grub-splash.png" "${1}/turingos-boot/"
}

grub_tree() {   # <tree>: GRUB as live-build writes it (double-quoted entries)
    mkdir -p "${1}/boot/grub/live-theme"
    printf 'stock\n' > "${1}/boot/grub/splash.png"
    cat > "${1}/boot/grub/grub.cfg" <<'EOF'
source /boot/grub/config.cfg
menuentry "Live system (amd64)" --hotkey=l {
	linux	/live/vmlinuz boot=live components quiet splash persistence
}
menuentry "Live system (amd64) (persistence)" --hotkey=l {
	linux	/live/vmlinuz boot=live components quiet splash persistence
}
submenu 'Utilities...' --hotkey=u {
	menuentry "Verify integrity of the boot medium" --hotkey=v {
		linux	/live/vmlinuz boot=live components verify-checksums
	}
}
EOF
    cat > "${1}/boot/grub/live-theme/theme.txt" <<'EOF'
desktop-image: "../splash.png"
title-color: "#ffffff"
+ label {
        color = "#ffffff"
}
+ boot_menu {
        item_color = "#a8a8a8"
        selected_item_color= "#ffffff"
}
+ progress_bar {
        text_color = "#000000"
        fg_color = "#ffffff"
        bg_color = "#a8a8a8"
        border_color = "#ffffff"
}
EOF
}

check_grub() {   # <tree>
    cmp -s "${1}/boot/grub/splash.png" "${BRANDING}/grub-splash.png" || fail "GRUB splash not replaced"
    grep -q '^menuentry "TuringOS (amd64)"' "${1}/boot/grub/grub.cfg" || fail "GRUB entry not renamed"
    grep -q '^menuentry "TuringOS (amd64) (persistence)"' "${1}/boot/grub/grub.cfg" || fail "cloned GRUB entry not renamed"
    grep -q 'menuentry "Verify integrity' "${1}/boot/grub/grub.cfg" || fail "utilities entry was touched"
    grep -q 'selected_item_color= "#e85002"' "${1}/boot/grub/live-theme/theme.txt" || fail "GRUB selection is not Orange"
    grep -q 'item_color = "#a7a7a7"' "${1}/boot/grub/live-theme/theme.txt" || fail "GRUB items are not Light Gray"
    grep -q 'fg_color = "#e85002"' "${1}/boot/grub/live-theme/theme.txt" || fail "GRUB timeout bar is not Orange"
    if grep -qi '#ffffff\|#a8a8a8' "${1}/boot/grub/live-theme/theme.txt"; then fail "stock GRUB colours left behind"; fi
    [[ ! -e "${1}/turingos-boot" ]] || fail "staging directory shipped in the ISO tree"
}

# ─── amd64-style tree: isolinux (BIOS) + GRUB (UEFI) ─────────────────────────
amd64="${WORK}/amd64"
mkdir -p "${amd64}/isolinux"
grub_tree "$amd64"
stage "$amd64"
printf 'stock\n' > "${amd64}/isolinux/splash.png"
printf 'include menu.cfg\ndefault vesamenu.c32\ntimeout 30\n' > "${amd64}/isolinux/isolinux.cfg"
printf 'menu title Boot menu\ninclude stdmenu.cfg\ninclude live.cfg\n' > "${amd64}/isolinux/menu.cfg"
printf 'menu background splash.png\nmenu color sel\t\t* #ffffffff #76a1d0ff *\n' > "${amd64}/isolinux/stdmenu.cfg"
cat > "${amd64}/isolinux/live.cfg" <<'EOF'
label live-amd64
	menu label ^Live system (amd64)
	append boot=live components quiet splash persistence
label live-amd64-failsafe
	menu label Live system (amd64 fail-safe mode)
	append boot=live components nosplash
EOF

(cd "$amd64" && bash "$HOOK" >/dev/null) || fail "hook failed on an amd64 tree"
cmp -s "${amd64}/isolinux/splash.png" "${BRANDING}/isolinux-splash.png" || fail "isolinux splash not replaced"
grep -q 'menu label ^TuringOS (amd64)$' "${amd64}/isolinux/live.cfg" || fail "isolinux entry not renamed"
grep -q 'menu label TuringOS (amd64 fail-safe mode)' "${amd64}/isolinux/live.cfg" || fail "fail-safe entry not renamed"
[[ "$(grep '^menu color sel' "${amd64}/isolinux/stdmenu.cfg" | tail -n 1)" == $'menu color sel\t\t* #ff000000 #ffe85002 none' ]] \
    || fail "isolinux selection is not Black on Orange (last definition wins)"
check_grub "$amd64"

# ─── arm64-style tree: GRUB only ─────────────────────────────────────────────
arm64="${WORK}/arm64"
grub_tree "$arm64"
stage "$arm64"
(cd "$arm64" && bash "$HOOK" >/dev/null) || fail "hook failed on an arm64 tree"
[[ ! -e "${arm64}/isolinux" ]] || fail "hook created isolinux/ on a GRUB-only tree"
check_grub "$arm64"

# ─── no staged art: fail loudly, don't ship the Debian splash ────────────────
bare="${WORK}/bare"
grub_tree "$bare"
if (cd "$bare" && bash "$HOOK" >/dev/null 2>&1); then
    fail "hook passed without staged art"
fi

echo "PASS: boot brand (amd64 + arm64 menus, splashes, staging cleanup, committed art)"
