#!/usr/bin/env bash
# sync-scripts.sh — stage TuringOS into config/includes.chroot before `lb build`.
#
# Writes the final installed layout, so no copy of the repo lands in the image:
#   /usr/lib/turingos/         modules `turingos` sources, registry, voice helper,
#                              Claude CLI installer
#   /usr/bin/turingos          -> ../lib/turingos/turingos
#   /etc/profile.d/turingos-first-run.sh
#   /usr/share/doc/turingos/   copyright (LICENSE), WORKFLOW.md
#   /usr/share/pixmaps/turingos.png  installer logo (hook 0495)
#   /opt/turingos-ui/          UI source; hook 0450 builds it into
#                              /usr/bin/turingos-ui and deletes the source
#
# Run from anywhere, before building:
#   ./debian-live/sync-scripts.sh && cd debian-live && sudo lb build

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
INC="${SCRIPT_DIR}/config/includes.chroot"
LIB="${INC}/usr/lib/turingos"
DOC="${INC}/usr/share/doc/turingos"
UI="${INC}/opt/turingos-ui"

# Every directory the `turingos` entrypoint sources modules from
# (tests/install_parity.sh keeps this list honest)
MODULE_DIRS=(core agent sandbox monitor game bazaar voice)

echo "→ Staging TuringOS into ${INC}"
rm -rf "$LIB" "$DOC" "$UI" "${INC}/usr/bin/turingos" "${INC}/etc/profile.d/turingos-first-run.sh" \n    "${INC}/usr/share/pixmaps/turingos.png"
install -d "${LIB}/pkg" "${INC}/usr/bin" "${INC}/etc/profile.d" "$DOC" "$UI"

for dir in "${MODULE_DIRS[@]}"; do
    rsync -a --chmod=D755,F644 --exclude='__pycache__/' "${REPO_ROOT}/${dir}/" "${LIB}/${dir}/"
done
install -m755 "${REPO_ROOT}/turingos" "${LIB}/turingos"
install -m755 "${REPO_ROOT}/pkg/turingos-install-claude-cli.sh" "${LIB}/pkg/"
ln -sfn ../lib/turingos/turingos "${INC}/usr/bin/turingos"
install -m644 "${REPO_ROOT}/pkg/turingos-first-run.sh" "${INC}/etc/profile.d/turingos-first-run.sh"
install -m644 "${REPO_ROOT}/LICENSE" "${DOC}/copyright"
install -m644 "${REPO_ROOT}/WORKFLOW.md" "${DOC}/"
# Installer branding (hook 0495)
install -Dm644 "${REPO_ROOT}/ui/web/assets/brand/app-icon.png" "${INC}/usr/share/pixmaps/turingos.png"

# UI: page + Tauri source, never build output
rsync -a --exclude='src-tauri/target/' --exclude='src-tauri/gen/' "${REPO_ROOT}/ui/" "${UI}/"

echo "  ✓ $(find "$LIB" -type f | wc -l) runtime files, $(find "$UI" -type f | wc -l) UI source files"
echo ""
echo "Next: cd ${SCRIPT_DIR} && sudo lb build"
echo "Clean rebuild: sudo lb clean --purge && sudo lb build"
