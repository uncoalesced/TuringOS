# shellcheck shell=bash
# /etc/profile.d/turingos-first-run.sh
#
# Sourced on every interactive login via /etc/profile.d/.
# Shows a welcome message once, then self-disables via a marker file.
# NOTE: no shebang — this file is sourced, not executed.

# Only in interactive shells, only with turingos installed, only once
[[ $- == *i* ]] || return 0
command -v turingos &>/dev/null || return 0
[[ -f "${HOME}/.turingos/.first-run-done" ]] && return 0

_turingos_welcome() {
    local line
    printf '\n  ╔═══════════════════════════════════════════╗\n'
    for line in "" "Welcome to TuringOS" "Agentic Substrate - Debian Edition" "" \
        "TuringOS gives Claude Code a safe" "execution layer:" "" \
        "- Btrfs sandboxes protect your files" "- Review every change before merge" \
        "- MCP Bazaar: one-command tool installs" "- Game Mode keeps agents backgrounded" ""; do
        printf '  ║   %-40s║\n' "$line"
    done
    printf '  ╚═══════════════════════════════════════════╝\n\n'
    printf '  Run setup now (takes about 10 seconds):\n\n    turingos init\n\n'
    printf '  Or read the workflow guide:\n\n    less /usr/share/doc/turingos/WORKFLOW.md\n\n'
}

# Already initialised (a provider or key was configured): no banner
[[ -f "${HOME}/.turingos/config.env" ]] || _turingos_welcome
unset -f _turingos_welcome

mkdir -p "${HOME}/.turingos"
touch "${HOME}/.turingos/.first-run-done"
