#!/usr/bin/env bash
# sync-scripts.sh
# Copies TuringOS scripts AND the Electron UI into config/includes.chroot/
# so live-build bakes them into the image before hooks run.
#
# Run this from the debian-live/ directory BEFORE running lb build:
#   cd debian-live/
#   ./sync-scripts.sh
#   sudo lb build

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

# ── Destination paths inside includes.chroot ──────────────────────────────────
# These map directly to filesystem paths inside the live image:
#   includes.chroot/opt/turingos/  →  /opt/turingos/
#   includes.chroot/opt/turingos-ui/  →  /opt/turingos-ui/

DEST_SCRIPTS="${SCRIPT_DIR}/config/includes.chroot/opt/turingos"
DEST_UI="${SCRIPT_DIR}/config/includes.chroot/opt/turingos-ui"

echo "╭─────────────────────────────────────────╮"
echo "│  TuringOS — syncing to includes.chroot  │"
echo "╰─────────────────────────────────────────╯"
echo ""

# ── 1. Sync TuringOS Bash scripts ─────────────────────────────────────────────
echo "→ Syncing Bash scripts to ${DEST_SCRIPTS}..."
mkdir -p "${DEST_SCRIPTS}"

rsync -a --delete \
    --exclude='.git/' \
    --exclude='debian-live/' \
    --exclude='ui/' \
    --exclude='ui-docs/' \
    --exclude='*.DS_Store' \
    --exclude='*.pyc' \
    --exclude='__pycache__/' \
    --exclude='node_modules/' \
    "${REPO_ROOT}/" "${DEST_SCRIPTS}/"

chmod +x "${DEST_SCRIPTS}/turingos"
chmod +x "${DEST_SCRIPTS}/pkg/turingos-install-claude-cli.sh"
chmod +x "${DEST_SCRIPTS}/pkg/turingos-first-run.sh"

SCRIPT_COUNT=$(find "${DEST_SCRIPTS}" -type f | wc -l)
echo "  ✓ ${SCRIPT_COUNT} files synced"

# ── 2. Sync Electron UI ───────────────────────────────────────────────────────
echo ""
echo "→ Syncing Electron UI to ${DEST_UI}..."
mkdir -p "${DEST_UI}"

if [[ ! -d "${REPO_ROOT}/ui" ]]; then
    echo "  ⚠ ui/ directory not found at ${REPO_ROOT}/ui — skipping UI sync"
    echo "  Make sure you are on the ui-shell branch or have the ui/ folder present"
else
    rsync -a --delete \
        --exclude='.git/' \
        --exclude='*.DS_Store' \
        --exclude='node_modules/' \
        --exclude='.cache/' \
        --exclude='*.log' \
        "${REPO_ROOT}/ui/" "${DEST_UI}/"

    chmod +x "${DEST_UI}/run.sh"

    UI_COUNT=$(find "${DEST_UI}" -type f | wc -l)
    echo "  ✓ ${UI_COUNT} files synced"
    echo ""
    echo "  NOTE: node_modules/ excluded — Electron will be installed"
    echo "  at build time by hook 0460-prebundle-electron.hook.chroot"
fi

# ── 3. Summary ────────────────────────────────────────────────────────────────
echo ""
echo "includes.chroot layout:"
echo "  /opt/turingos/      ← Bash scripts + entrypoint"
echo "  /opt/turingos-ui/   ← Electron UI source"
echo ""
echo "Next step:"
echo "  sudo lb build"
echo ""
echo "Or to clean and rebuild from scratch:"
echo "  sudo lb clean --purge && sudo lb build"
