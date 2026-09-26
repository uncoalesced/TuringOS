#!/usr/bin/env bash
# sync-scripts.sh
# Copies ClaudeOS scripts into config/includes.chroot/opt/claudeos/
# so live-build bakes them into the image before hooks run.
#
# Run this from the debian-live/ directory BEFORE running lb build:
#   cd debian-live/
#   ./sync-scripts.sh
#   sudo lb build

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
DEST="${SCRIPT_DIR}/config/includes.chroot/opt/claudeos"

echo "Syncing ClaudeOS scripts to includes.chroot..."
echo "  Source: ${REPO_ROOT}"
echo "  Dest:   ${DEST}"
echo ""

mkdir -p "${DEST}"

# Copy the full script tree
rsync -av --delete \
    --exclude='.git/' \
    --exclude='debian-live/' \
    --exclude='*.DS_Store' \
    --exclude='*.pyc' \
    --exclude='__pycache__/' \
    "${REPO_ROOT}/" "${DEST}/"

# Ensure entrypoint is executable
chmod +x "${DEST}/claudeos"
chmod +x "${DEST}/pkg/claudeos-install-claude-cli.sh"
chmod +x "${DEST}/pkg/claudeos-first-run.sh"

echo ""
echo "Done. Contents of includes.chroot/opt/claudeos/:"
find "${DEST}" -not -path '*/.git/*' -type f | sort | sed 's|'"${DEST}"'|  |'
echo ""
echo "Now run: sudo lb build"
