#!/usr/bin/env bash
# sandbox/diff.sh — TuringOS Sandbox Diff Inspector
#
# Shows what an agent changed in a sandbox compared with the original
# project's working tree: exactly what `sandbox merge` would apply.
#
# Depends on: core/config.sh, core/logging.sh, core/ui.sh, sandbox/btrfs.sh

# ─── Entry Point ──────────────────────────────────────────────────────────────

diff::show() {
    # Usage: diff::show [SANDBOX_PATH]
    local sandbox_path source_project
    sandbox_path=$(sandbox::_resolve "${1:-}") || return 1
    source_project=$(sandbox::_meta "$sandbox_path" SOURCE_PROJECT)

    ui::header "Sandbox Diff Inspector"
    ui::label "Task"    "$(sandbox::_meta "$sandbox_path" LABEL)"
    ui::label "Sandbox" "$(basename "$sandbox_path")"
    ui::label "Project" "$source_project"
    ui::label "Created" "$(sandbox::_meta "$sandbox_path" CREATED_AT)"
    ui::label "Backend" "$(sandbox::_meta "$sandbox_path" BACKEND)"
    echo ""
    ui::divider

    if [[ -d "$source_project" ]]; then
        diff::_summary "$sandbox_path" "$source_project"
    else
        ui::warn "Original project is gone: ${source_project}"
    fi
    diff::_test_summary "$sandbox_path"

    echo ""
    ui::divider
    diff::_action_prompt "$sandbox_path"
}

# ─── Summary ──────────────────────────────────────────────────────────────────

diff::_summary() {
    local sandbox="$1" source="$2" changes added removed
    changes=$(sandbox::changes "$sandbox" "$source")
    if [[ -z "$changes" ]]; then
        echo ""
        ui::info "No changes detected in sandbox"
        return 0
    fi

    read -r added removed < <(sandbox::patch "$sandbox" "$source" \
        | awk '/^\+\+\+|^---/ {next} /^\+/ {a++} /^-/ {r++} END {print a+0, r+0}')
    echo ""
    printf '  %b%s file(s) changed%b   %b+%s%b   %b-%s%b\n\n' \
        "$BOLD_WHITE" "$(grep -c . <<< "$changes")" "$RESET" \
        "$BOLD_GREEN" "$added" "$RESET" "$BOLD_RED" "$removed" "$RESET"

    local kind path color
    while IFS=$'\t' read -r kind path; do
        case "$kind" in
            A) color="$GREEN" ;;
            D) color="$RED" ;;
            *) color="$YELLOW" ;;
        esac
        printf '  %b  %s%b  %s\n' "$color" "$kind" "$RESET" "$path"
    done <<< "$changes"
}

diff::_test_summary() {
    # Test results the agent (or agent::_capture_test_result) left behind
    local sandbox="$1" result_file="" candidate passed failed
    for candidate in "${sandbox}/.turingos_test_result" "${sandbox}/test-results.txt" "${sandbox}/pytest_output.txt"; do
        if [[ -f "$candidate" ]]; then
            result_file="$candidate"
            break
        fi
    done
    [[ -n "$result_file" ]] || return 0

    passed=$(grep -oE '[0-9]+ passed' "$result_file" | head -1 | cut -d' ' -f1) || true
    failed=$(grep -oE '[0-9]+ failed' "$result_file" | head -1 | cut -d' ' -f1) || true
    echo ""
    if [[ -n "$passed" && "${failed:-0}" == "0" ]]; then
        ui::ok "Tests: ${passed}/${passed} passed"
    elif [[ -n "$passed" || -n "$failed" ]]; then
        ui::fail "Tests: ${passed:-0} passed, ${failed} failed"
    fi
}

# ─── Full Patch ───────────────────────────────────────────────────────────────

diff::full() {
    # Usage: diff::full [SANDBOX_PATH] — full unified diff, paged
    local sandbox_path source_project pager=(less -RFX)
    sandbox_path=$(sandbox::_resolve "${1:-}") || return 1
    source_project=$(sandbox::_source "$sandbox_path") || return 1
    command -v delta &>/dev/null && pager=(delta)

    ui::header "Full Diff"
    sandbox::patch "$sandbox_path" "$source_project" | "${pager[@]}"
}

diff::save() {
    # Usage: diff::save [SANDBOX_PATH] — write the patch to the log dir
    local sandbox_path source_project outfile
    sandbox_path=$(sandbox::_resolve "${1:-}") || return 1
    source_project=$(sandbox::_source "$sandbox_path") || return 1
    outfile="${TURINGOS_LOG_DIR}/diff-$(date +%Y%m%dT%H%M%S).patch"
    sandbox::patch "$sandbox_path" "$source_project" > "$outfile"
    ui::ok "Diff saved to: $outfile"
    log::info "diff saved: $outfile"
}

# ─── Interactive Action Prompt ────────────────────────────────────────────────

diff::_action_prompt() {
    local sandbox_path="$1" choice
    echo ""
    choice=$(ui::choose "What would you like to do?" \
        "[ M ] Merge changes into project" \
        "[ R ] Rollback — discard all changes" \
        "[ V ] View full diff" \
        "[ S ] Save diff to file" \
        "[ Q ] Quit (keep sandbox)") || true

    case "$choice" in
        *Merge*)       sandbox::merge "$sandbox_path" ;;
        *Rollback*)    sandbox::rollback "$sandbox_path" ;;
        *"full diff"*) diff::full "$sandbox_path" ;;
        *Save*)        diff::save "$sandbox_path" ;;
        *)             ui::info "Sandbox kept at: $sandbox_path" ;;
    esac
}
