#!/usr/bin/env bash
# /etc/profile.d/claudeos-first-run.sh
#
# Runs once on first interactive login after ClaudeOS is installed.
# Shows a welcome message and prompts the user to run claudeos init.
# Self-disables after first run by writing a marker file.

# Only run in interactive shells
[[ $- == *i* ]] || return 0

# Only run if claudeos is installed
command -v claudeos &>/dev/null || return 0

# Only run once per user
_MARKER="${HOME}/.claudeos/.first-run-done"
[[ -f "$_MARKER" ]] && return 0

# Don't run if claudeos init has already been run
[[ -f "${HOME}/.claudeos/config.env" ]] && {
    mkdir -p "${HOME}/.claudeos"
    touch "$_MARKER"
    return 0
}

# ─── Welcome Banner ───────────────────────────────────────────────────────────

echo ""
echo "  ╔═══════════════════════════════════════════╗"
echo "  ║                                           ║"
echo "  ║   Welcome to ClaudeOS                     ║"
echo "  ║   Agentic Substrate · Debian Edition      ║"
echo "  ║                                           ║"
echo "  ╠═══════════════════════════════════════════╣"
echo "  ║                                           ║"
echo "  ║   ClaudeOS gives Claude Code a safe       ║"
echo "  ║   execution layer:                        ║"
echo "  ║                                           ║"
echo "  ║   • Btrfs sandboxes protect your files   ║"
echo "  ║   • Review every change before merge     ║"
echo "  ║   • MCP Bazaar for one-command tool       ║"
echo "  ║     installs                              ║"
echo "  ║   • Game Mode keeps agents backgrounded  ║"
echo "  ║                                           ║"
echo "  ╚═══════════════════════════════════════════╝"
echo ""
echo "  Run setup now (takes about 10 seconds):"
echo ""
echo "    claudeos init"
echo ""
echo "  Or read the workflow guide:"
echo ""
echo "    cat /usr/share/doc/claudeos/WORKFLOW.md"
echo ""

# Mark as shown so this doesn't appear on every login
mkdir -p "${HOME}/.claudeos"
touch "$_MARKER"
