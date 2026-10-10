#!/usr/bin/env bash
# sync-scripts.sh — stage TuringOS into config/includes.chroot before `lb build`.
#
# Writes the final installed layout, so no copy of the repo lands in the image:
#   /usr/lib/turingos/         modules `turingos` sources, registry, voice helper,
#                              Claude CLI installer, daemons, and the web UI
#                              (ui/web — what turingos-bridged-ws serves)
#   /usr/bin/turingos          -> ../lib/turingos/turingos
#   /usr/bin/turingos-respawn  UI crash watchdog (openbox autostart, launch-ui.sh)
#   /etc/profile.d/turingos-first-run.sh
#   /usr/share/doc/turingos/   copyright (LICENSE), WORKFLOW.md
#   /usr/share/pixmaps/turingos.png  installer logo (hook 0495)
#   /usr/lib/turingos/session/ the shell window's launcher (turingos-kiosk),
#                              graphics detection, Super+Space
#   /usr/lib/systemd/user/turingosd.service   the desktop service
#   /opt/turingosd-src/        desktop service source; hook 0450 builds it into
#                              /usr/bin/turingosd and deletes the source
#   /usr/src/turingos/trust/   trust model source; hook 0480 installs it into
#                              /usr/lib/turingos and deletes the source
#
# Run from anywhere, before building:
#   ./debian-live/sync-scripts.sh && cd debian-live && sudo lb build

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
INC="${SCRIPT_DIR}/config/includes.chroot"
LIB="${INC}/usr/lib/turingos"
DOC="${INC}/usr/share/doc/turingos"
DAEMON_SRC="${INC}/opt/turingosd-src"
TRUST_SRC="${INC}/usr/src/turingos/trust"

# Every directory the `turingos` entrypoint sources modules from
# (tests/install_parity.sh keeps this list honest)
MODULE_DIRS=(core agent sandbox monitor game bazaar voice)

echo "→ Staging TuringOS into ${INC}"
# /opt/turingos-ui: what an older checkout staged (the Tauri app's source)
rm -rf "$LIB" "$DOC" "$DAEMON_SRC" "${INC}/opt/turingos-ui" "${INC}/usr/lib/systemd/user/turingosd.service" "${INC}/usr/src/turingos" "${INC}/usr/bin/turingos" "${INC}/usr/bin/turingos-respawn" "${INC}/etc/profile.d/turingos-first-run.sh" \
    "${INC}/usr/share/pixmaps/turingos.png"
install -d "${LIB}/pkg" "${INC}/usr/bin" "${INC}/etc/profile.d" "$DOC" "$DAEMON_SRC" "$(dirname "$TRUST_SRC")" \
    "${INC}/usr/lib/systemd/user"

for dir in "${MODULE_DIRS[@]}"; do
    rsync -a --chmod=D755,F644 --exclude='__pycache__/' "${REPO_ROOT}/${dir}/" "${LIB}/${dir}/"
done
install -m755 "${REPO_ROOT}/turingos" "${LIB}/turingos"
install -m755 "${REPO_ROOT}/pkg/turingos-install-claude-cli.sh" "${LIB}/pkg/"
ln -sfn ../lib/turingos/turingos "${INC}/usr/bin/turingos"
install -m755 "${REPO_ROOT}/pkg/turingos-respawn.sh" "${INC}/usr/bin/turingos-respawn"
install -m644 "${REPO_ROOT}/pkg/turingos-first-run.sh" "${INC}/etc/profile.d/turingos-first-run.sh"
install -m644 "${REPO_ROOT}/LICENSE" "${DOC}/copyright"
install -m644 "${REPO_ROOT}/WORKFLOW.md" "${DOC}/"
# Installer branding (hook 0495)
install -Dm644 "${REPO_ROOT}/ui/web/assets/brand/app-icon.png" "${INC}/usr/share/pixmaps/turingos.png"

install -m644 "${REPO_ROOT}/protocol/v1/README.md" "${DOC}/protocol-v1.md"

# The desktop service's source, never build output (hook 0450 builds it)
rsync -a --exclude='target/' "${REPO_ROOT}/daemon/" "${DAEMON_SRC}/"

# The shell window's launcher and its helpers (scripts keep their modes)
rsync -a --exclude='turingosd.service' "${REPO_ROOT}/session/" "${LIB}/session/"
install -m644 "${REPO_ROOT}/session/turingosd.service" "${INC}/usr/lib/systemd/user/"

# The web UI at its installed path: launch-ui.sh and turingos-bridged-ws
# (APP_DIR) both serve /usr/lib/turingos/ui/web
install -d "${LIB}/ui/web"
rsync -a --chmod=D755,F644 "${REPO_ROOT}/ui/web/" "${LIB}/ui/web/"

# Trust model source for hook 0480 (which installs and then removes it)
rsync -a --exclude='__pycache__/' "${REPO_ROOT}/trust/" "$TRUST_SRC/"

echo "  ✓ $(find "$LIB" -type f | wc -l) runtime files, $(find "$DAEMON_SRC" -type f | wc -l) desktop service source files, $(find "$TRUST_SRC" -type f | wc -l) trust files"
echo ""
echo "Next: cd ${SCRIPT_DIR} && sudo lb build"
echo "Clean rebuild: sudo lb clean --purge && sudo lb build"
