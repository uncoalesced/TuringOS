# shellcheck shell=bash
# /etc/profile.d/turingos-first-run.sh
#
# Sourced on every interactive login via /etc/profile.d/.
# Shows a welcome message once, then self-disables via a marker file.
# NOTE: no shebang — this file is sourced, not executed.

# Only run in interactive shells
[[ $- == *i* ]] || return 0

# Only run if turingos is installed
command -v turingos &>/dev/null || return 0

# Only run once per user
_MARKER="${HOME}/.turingos/.first-run-done"
[[ -f "$_MARKER" ]] && return 0

# Don't run if turingos init has already been run
[[ -f "${HOME}/.turingos/config.env" ]] && {
    mkdir -p "${HOME}/.turingos"
    touch "$_MARKER"
    return 0
}

# ─── Welcome Banner ───────────────────────────────────────────────────────────

echo ""
echo "  ╔═══════════════════════════════════════════╗"
echo "  ║                                           ║"
echo "  ║   Welcome to TuringOS                     ║"
echo "  ║   Agentic Substrate · Debian Edition      ║"
echo "  ║                                           ║"
echo "  ╠═══════════════════════════════════════════╣"
echo "  ║                                           ║"
echo "  ║   TuringOS gives Claude Code a safe       ║"
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
echo "    turingos init"
echo ""
echo "  Or read the workflow guide:"
echo ""
echo "    cat /usr/share/doc/turingos/WORKFLOW.md"
echo ""

# Mark as shown so this doesn't appear on every login
mkdir -p "${HOME}/.turingos"
touch "$_MARKER"
