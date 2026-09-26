#!/usr/bin/env bash
# sandbox/diff.sh — ClaudeOS Sandbox Diff Inspector
#
# Displays a rich, human-readable summary of what an agent changed inside a
# sandbox vs the original project. Combines git diff stats, file-level changes,
# and optional Btrfs metadata.
#
# Depends on: core/config.sh, core/logging.sh, core/ui.sh, sandbox/btrfs.sh

log::set_module "diff"

# ─── Entry Point ──────────────────────────────────────────────────────────────

diff::show() {
    # Usage: diff::show [SANDBOX_PATH]
    local sandbox_path="${1:-}"

    if [[ -z "$sandbox_path" ]]; then
        sandbox_path=$(config::state_get "$STATE_KEY_ACTIVE_SANDBOX")
    fi

    if [[ -z "$sandbox_path" || ! -d "$sandbox_path" ]]; then
        ui::fail "No active sandbox found. Run: claudeos sandbox create"
        log::warn "diff::show — no sandbox path"
        return 1
    fi

    local meta="${sandbox_path}/.claudeos_sandbox"
    if [[ ! -f "$meta" ]]; then
        ui::fail "Sandbox metadata missing: $meta"
        return 1
    fi

    local source_project backend label created
    source_project=$(grep '^SOURCE_PROJECT=' "$meta" | cut -d= -f2-)
    backend=$(grep '^BACKEND='       "$meta" | cut -d= -f2-)
    label=$(grep '^LABEL='           "$meta" | cut -d= -f2-)
    created=$(grep '^CREATED_AT='    "$meta" | cut -d= -f2-)

    ui::header "Sandbox Diff Inspector"

    ui::label "Task"      "$label"
    ui::label "Sandbox"   "$(basename "$sandbox_path")"
    ui::label "Project"   "$source_project"
    ui::label "Created"   "$created"
    ui::label "Backend"   "$backend"
    echo ""
    ui::divider

    # Choose best diff strategy
    if [[ -d "${sandbox_path}/.git" ]]; then
        diff::_git_summary "$sandbox_path" "$source_project"
    else
        diff::_rsync_summary "$sandbox_path" "$source_project"
    fi

    echo ""
    ui::divider

    # Btrfs metadata if available
    if [[ "$backend" == "btrfs" ]] && command -v btrfs &>/dev/null; then
        diff::_btrfs_info "$sandbox_path"
        echo ""
        ui::divider
    fi

    diff::_action_prompt "$sandbox_path"
}

# ─── Git-Based Summary ────────────────────────────────────────────────────────

diff::_git_summary() {
    local sandbox="$1"
    local source="$2"

    # Shortstat
    local shortstat
    shortstat=$(git -C "$sandbox" diff --shortstat 2>/dev/null)

    if [[ -z "$shortstat" ]]; then
        # Check for untracked files
        local untracked
        untracked=$(git -C "$sandbox" ls-files --others --exclude-standard 2>/dev/null | wc -l | tr -d ' ')
        if [[ "$untracked" -gt 0 ]]; then
            ui::warn "No tracked changes — ${untracked} untracked file(s)"
        else
            ui::info "No changes detected in sandbox"
        fi
        return 0
    fi

    # Parse counts
    local files_changed insertions deletions
    files_changed=$(echo "$shortstat" | grep -oP '\d+(?= file)'      || echo 0)
    insertions=$(   echo "$shortstat" | grep -oP '\d+(?= insertion)' || echo 0)
    deletions=$(    echo "$shortstat" | grep -oP '\d+(?= deletion)'  || echo 0)

    echo ""
    printf "  \033[1;37m%s files changed\033[0m   \033[1;32m+%s\033[0m   \033[1;31m-%s\033[0m\n" \
        "$files_changed" "$insertions" "$deletions"
    echo ""

    # File-level breakdown
    diff::_file_list "$sandbox"

    # Test results if detectable
    diff::_test_summary "$sandbox"
}

diff::_file_list() {
    local sandbox="$1"

    # Modified files
    local modified=()
    while IFS= read -r f; do
        [[ -n "$f" ]] && modified+=("$f")
    done < <(git -C "$sandbox" diff --name-only 2>/dev/null)

    # New (untracked) files
    local added=()
    while IFS= read -r f; do
        [[ -n "$f" ]] && added+=("$f")
    done < <(git -C "$sandbox" ls-files --others --exclude-standard 2>/dev/null)

    # Deleted files
    local deleted=()
    while IFS= read -r f; do
        [[ -n "$f" ]] && deleted+=("$f")
    done < <(git -C "$sandbox" diff --name-only --diff-filter=D 2>/dev/null)

    local total=$(( ${#modified[@]} + ${#added[@]} + ${#deleted[@]} ))
    if [[ $total -eq 0 ]]; then
        return 0
    fi

    echo ""
    for f in "${modified[@]}"; do
        local stat
        stat=$(git -C "$sandbox" diff --numstat -- "$f" 2>/dev/null | awk '{printf "+%s / -%s", $1, $2}')
        printf "  \033[0;33m  M\033[0m  %-50s  \033[2m%s\033[0m\n" "$f" "$stat"
    done

    for f in "${added[@]}"; do
        printf "  \033[0;32m  A\033[0m  %-50s\n" "$f"
    done

    for f in "${deleted[@]}"; do
        printf "  \033[0;31m  D\033[0m  %-50s\n" "$f"
    done
}

diff::_test_summary() {
    local sandbox="$1"

    # Look for common test result indicators left behind by the agent
    local result_file
    for candidate in \
        "${sandbox}/.claudeos_test_result" \
        "${sandbox}/test-results.txt" \
        "${sandbox}/pytest_output.txt"; do
        if [[ -f "$candidate" ]]; then
            result_file="$candidate"
            break
        fi
    done

    echo ""
    if [[ -n "$result_file" ]]; then
        local passed failed
        passed=$(grep -oP '\d+(?= passed)'  "$result_file" 2>/dev/null | head -1 || echo "")
        failed=$(grep -oP '\d+(?= failed)'  "$result_file" 2>/dev/null | head -1 || echo "")

        if [[ -n "$passed" && "${failed:-0}" == "0" ]]; then
            ui::ok  "Tests: ${passed}/${passed} passed"
        elif [[ -n "$passed" && -n "$failed" ]]; then
            ui::fail "Tests: ${passed} passed, ${failed} failed"
        fi
    else
        # Try to detect test frameworks and check last run status
        if [[ -f "${sandbox}/package.json" ]]; then
            ui::info "Tests: run 'claudeos agent status' for test output"
        fi
    fi
}

# ─── Rsync-Based Summary (no git) ────────────────────────────────────────────

diff::_rsync_summary() {
    local sandbox="$1"
    local source="$2"

    ui::info "Comparing sandbox vs project (rsync dry-run)..."
    echo ""

    local diff_lines
    diff_lines=$(rsync -rcn --exclude='.claudeos_sandbox' \
        "${sandbox}/" "${source}/" 2>/dev/null) || true

    local count
    count=$(echo "$diff_lines" | grep -c '^' 2>/dev/null || echo 0)

    if [[ $count -eq 0 ]]; then
        ui::info "No differences detected"
        return 0
    fi

    printf "  \033[1;37m%s file(s) differ\033[0m\n\n" "$count"

    while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        printf "  \033[0;33m  ~\033[0m  %s\n" "$line"
    done <<< "$diff_lines"
}

# ─── Btrfs Metadata ──────────────────────────────────────────────────────────

diff::_btrfs_info() {
    local sandbox="$1"

    echo ""
    ui::info "Btrfs snapshot info:"

    local info
    info=$(sudo btrfs subvolume show "$sandbox" 2>/dev/null) || {
        ui::warn "  Could not read Btrfs subvolume info (may need sudo)"
        return
    }

    local created uuid
    created=$(echo "$info" | grep 'Creation time:' | awk '{print $3, $4}')
    uuid=$(echo "$info"    | grep 'UUID:'          | head -1 | awk '{print $2}')

    [[ -n "$created" ]] && ui::label "  Snapshot created" "$created"
    [[ -n "$uuid"    ]] && ui::label "  UUID"             "$uuid"
}

# ─── Full Git Patch ───────────────────────────────────────────────────────────

diff::full() {
    # Usage: diff::full [SANDBOX_PATH]
    # Shows the full git diff — used for detailed review
    local sandbox_path="${1:-}"

    if [[ -z "$sandbox_path" ]]; then
        sandbox_path=$(config::state_get "$STATE_KEY_ACTIVE_SANDBOX")
    fi

    if [[ -z "$sandbox_path" || ! -d "$sandbox_path" ]]; then
        ui::fail "No active sandbox"
        return 1
    fi

    if [[ ! -d "${sandbox_path}/.git" ]]; then
        ui::warn "No git repository in sandbox — cannot show full patch"
        return 1
    fi

    ui::header "Full Diff"

    if command -v delta &>/dev/null; then
        git -C "$sandbox_path" diff | delta
    elif command -v diff-so-fancy &>/dev/null; then
        git -C "$sandbox_path" diff | diff-so-fancy | less -RFX
    else
        git -C "$sandbox_path" diff | less -RFX
    fi
}

# ─── Interactive Action Prompt ────────────────────────────────────────────────

diff::_action_prompt() {
    local sandbox_path="$1"

    echo ""
    local choice
    choice=$(ui::choose "What would you like to do?" \
        "[ M ] Merge changes into project" \
        "[ R ] Rollback — discard all changes" \
        "[ V ] View full diff (git patch)" \
        "[ S ] Save diff to file" \
        "[ Q ] Quit (keep sandbox)" \
    )

    case "$choice" in
        *Merge*)
            sandbox::merge "$sandbox_path"
            ;;
        *Rollback*)
            sandbox::rollback "$sandbox_path"
            ;;
        *"full diff"*)
            diff::full "$sandbox_path"
            ;;
        *Save*)
            diff::save "$sandbox_path"
            ;;
        *Quit*)
            ui::info "Sandbox kept at: $sandbox_path"
            ;;
    esac
}

# ─── Save Diff to File ────────────────────────────────────────────────────────

diff::save() {
    local sandbox_path="${1:-}"

    if [[ -z "$sandbox_path" ]]; then
        sandbox_path=$(config::state_get "$STATE_KEY_ACTIVE_SANDBOX")
    fi

    if [[ -z "$sandbox_path" || ! -d "${sandbox_path}/.git" ]]; then
        ui::fail "No git sandbox to save diff from"
        return 1
    fi

    local outfile="${CLAUDEOS_LOG_DIR}/diff-$(date +%Y%m%dT%H%M%S).patch"
    git -C "$sandbox_path" diff > "$outfile"
    ui::ok "Diff saved to: $outfile"
    log::info "diff saved: $outfile"
}
