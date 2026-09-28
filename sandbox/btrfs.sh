#!/usr/bin/env bash
# sandbox/btrfs.sh — TuringOS Agent Sandbox
#
# Creates ephemeral Btrfs CoW snapshots of a project directory before handing
# it to an agent. If Btrfs is unavailable, falls back to a plain rsync copy.
#
# Depends on: core/config.sh, core/logging.sh, core/ui.sh

log::set_module "sandbox"

# ─── Backend Detection ────────────────────────────────────────────────────────

sandbox::_is_btrfs() {
    # Returns 0 if the given path lives on a Btrfs filesystem
    local path="$1"
    local fs_type
    fs_type=$(stat -f -c '%T' "$path" 2>/dev/null || stat -f "$path" 2>/dev/null | awk '/Type:/{print $NF}')
    [[ "$fs_type" == "btrfs" ]]
}

sandbox::_backend() {
    local project="$1"
    if [[ "${TURINGOS_SANDBOX_BACKEND:-btrfs}" == "btrfs" ]] && \
       command -v btrfs &>/dev/null && \
       sandbox::_is_btrfs "$project"; then
        echo "btrfs"
    else
        echo "copy"
    fi
}

# ─── Create Sandbox ───────────────────────────────────────────────────────────

sandbox::create() {
    # Usage: sandbox::create [PROJECT_DIR] [TASK_LABEL]
    # Prints the sandbox path to stdout on success.
    local project="${1:-$PWD}"
    local label="${2:-task}"

    # Normalize path
    project="$(cd "$project" && pwd)"

    if [[ ! -d "$project" ]]; then
        ui::fail "Project directory not found: $project"
        log::error "sandbox::create — directory not found: $project"
        return 1
    fi

    local ts
    ts=$(date +%s)
    local safe_label
    safe_label=$(echo "$label" | tr ' /' '__' | tr -cd '[:alnum:]_-' | cut -c1-32)
    local sandbox_name="${safe_label}-${ts}"
    local sandbox_path="${TURINGOS_SANDBOX_DIR}/${sandbox_name}"

    local backend
    backend=$(sandbox::_backend "$project")

    ui::info "Creating agent sandbox..."
    ui::label "Project"  "$project"
    ui::label "Sandbox"  "$sandbox_path"
    ui::label "Backend"  "$backend"
    echo ""

    log::section "SANDBOX CREATE — ${sandbox_name}"
    log::info "project=${project} sandbox=${sandbox_path} backend=${backend}"

    case "$backend" in
        btrfs) sandbox::_create_btrfs "$project" "$sandbox_path" ;;
        copy)  sandbox::_create_copy  "$project" "$sandbox_path" ;;
    esac

    local exit_code=$?
    if [[ $exit_code -ne 0 ]]; then
        ui::fail "Failed to create sandbox"
        log::error "sandbox creation failed (exit ${exit_code})"
        return 1
    fi

    # Write metadata file inside sandbox
    cat > "${sandbox_path}/.turingos_sandbox" <<EOF
SANDBOX_NAME=${sandbox_name}
SANDBOX_PATH=${sandbox_path}
SOURCE_PROJECT=${project}
CREATED_AT=$(date '+%Y-%m-%dT%H:%M:%S')
BACKEND=${backend}
LABEL=${label}
EOF

    # Persist active sandbox in state
    config::state_set "$STATE_KEY_ACTIVE_SANDBOX" "$sandbox_path"

    log::audit SANDBOX_CREATE \
        "sandbox=${sandbox_path}" \
        "project=${project}" \
        "backend=${backend}" \
        "label=${label}"

    ui::ok  "Original project protected"
    ui::ok  "Sandbox created: ${sandbox_path}"
    ui::ok  "Claude execution authorized"
    echo ""

    # Return the path for callers
    echo "$sandbox_path"
}

sandbox::_create_btrfs() {
    local source="$1"
    local dest="$2"
    mkdir -p "$(dirname "$dest")"
    sudo btrfs subvolume snapshot "$source" "$dest"
}

sandbox::_create_copy() {
    local source="$1"
    local dest="$2"
    mkdir -p "$dest"
    rsync -a --exclude='.git/' "$source/" "$dest/"
    # Copy .git separately so git commands work inside the sandbox
    if [[ -d "${source}/.git" ]]; then
        cp -r "${source}/.git" "${dest}/.git"
    fi
}

# ─── List Sandboxes ───────────────────────────────────────────────────────────

sandbox::list() {
    local sandboxes=()
    while IFS= read -r -d '' dir; do
        sandboxes+=("$dir")
    done < <(find "$TURINGOS_SANDBOX_DIR" -maxdepth 1 -mindepth 1 -type d -print0 2>/dev/null)

    if [[ ${#sandboxes[@]} -eq 0 ]]; then
        ui::info "No sandboxes found"
        return 0
    fi

    ui::header "Active Sandboxes"
    for sb in "${sandboxes[@]}"; do
        local meta="${sb}/.turingos_sandbox"
        if [[ -f "$meta" ]]; then
            local name created label project
            name=$(grep '^SANDBOX_NAME=' "$meta" | cut -d= -f2-)
            created=$(grep '^CREATED_AT=' "$meta" | cut -d= -f2-)
            label=$(grep '^LABEL=' "$meta" | cut -d= -f2-)
            project=$(grep '^SOURCE_PROJECT=' "$meta" | cut -d= -f2-)
            printf "  %-36s  %s\n" "$name" "$created"
            printf "  ${DIM:-}  %-34s  %s${RESET:-}\n" "$project" "$label"
            echo ""
        else
            echo "  $(basename "$sb")"
        fi
    done
}

# ─── Rollback (destroy sandbox) ───────────────────────────────────────────────

sandbox::rollback() {
    # Usage: sandbox::rollback [SANDBOX_PATH]
    # If no path given, uses the active sandbox from state.
    local sandbox_path="${1:-}"

    if [[ -z "$sandbox_path" ]]; then
        sandbox_path=$(config::state_get "$STATE_KEY_ACTIVE_SANDBOX")
    fi

    if [[ -z "$sandbox_path" || ! -d "$sandbox_path" ]]; then
        ui::fail "No sandbox to rollback. Path: ${sandbox_path:-<none>}"
        log::warn "sandbox::rollback — no valid sandbox path"
        return 1
    fi

    ui::warn "Rolling back sandbox: $sandbox_path"

    local meta="${sandbox_path}/.turingos_sandbox"
    local backend="copy"
    [[ -f "$meta" ]] && backend=$(grep '^BACKEND=' "$meta" | cut -d= -f2-)

    if ui::confirm "Destroy sandbox and discard all agent changes?"; then
        sandbox::_destroy "$sandbox_path" "$backend"
        config::state_del "$STATE_KEY_ACTIVE_SANDBOX"
        log::audit SANDBOX_ROLLBACK "sandbox=${sandbox_path}"
        ui::ok "Sandbox destroyed. Original project untouched."
    else
        ui::info "Rollback cancelled."
    fi
}

sandbox::_destroy() {
    local path="$1"
    local backend="${2:-copy}"
    case "$backend" in
        btrfs) sudo btrfs subvolume delete "$path" ;;
        copy)  rm -rf "$path" ;;
    esac
}

# ─── Merge (apply changes back to source) ────────────────────────────────────

sandbox::merge() {
    # Usage: sandbox::merge [SANDBOX_PATH]
    local sandbox_path="${1:-}"

    if [[ -z "$sandbox_path" ]]; then
        sandbox_path=$(config::state_get "$STATE_KEY_ACTIVE_SANDBOX")
    fi

    if [[ -z "$sandbox_path" || ! -d "$sandbox_path" ]]; then
        ui::fail "No sandbox to merge. Path: ${sandbox_path:-<none>}"
        return 1
    fi

    local meta="${sandbox_path}/.turingos_sandbox"
    if [[ ! -f "$meta" ]]; then
        ui::fail "Sandbox metadata not found: ${meta}"
        return 1
    fi

    local source_project backend
    source_project=$(grep '^SOURCE_PROJECT=' "$meta" | cut -d= -f2-)
    backend=$(grep '^BACKEND=' "$meta" | cut -d= -f2-)

    ui::info "Merging sandbox → original project"
    ui::label "From" "$sandbox_path"
    ui::label "Into" "$source_project"
    echo ""

    if [[ ! -d "$source_project" ]]; then
        ui::fail "Original project directory missing: $source_project"
        log::error "merge failed — source project gone: $source_project"
        return 1
    fi

    # Show a summary diff before asking
    sandbox::_show_summary "$sandbox_path" "$source_project"
    echo ""

    if ! ui::confirm "Apply these changes to the original project?"; then
        ui::info "Merge cancelled."
        return 0
    fi

    # Apply: rsync sandbox → source, then clean up sandbox
    rsync -a --exclude='.turingos_sandbox' --exclude='.git/' \
        "${sandbox_path}/" "${source_project}/"

    log::audit SANDBOX_MERGE \
        "sandbox=${sandbox_path}" \
        "project=${source_project}"

    # Optionally destroy sandbox after merge
    if ui::confirm "Destroy sandbox after merge?"; then
        sandbox::_destroy "$sandbox_path" "$backend"
        config::state_del "$STATE_KEY_ACTIVE_SANDBOX"
        ui::ok "Sandbox destroyed."
    fi

    ui::ok "Changes merged into: $source_project"
}

# ─── Summary Helper (used by diff.sh too) ────────────────────────────────────

sandbox::_show_summary() {
    local sandbox="$1"
    local source="$2"

    # If sandbox has a git repo, use git diff for a clean summary
    if [[ -d "${sandbox}/.git" ]]; then
        local changed added removed
        changed=$(git -C "$sandbox" diff --name-only 2>/dev/null | wc -l | tr -d ' ')
        added=$(git -C "$sandbox" diff --shortstat 2>/dev/null | grep -oP '\d+(?= insertion)' || echo 0)
        removed=$(git -C "$sandbox" diff --shortstat 2>/dev/null | grep -oP '\d+(?= deletion)' || echo 0)

        ui::label "Files changed" "$changed"
        ui::label "Lines added"   "+${added}"
        ui::label "Lines removed" "-${removed}"
    else
        # Fallback: rsync dry-run diff
        local diff_count
        diff_count=$(rsync -a --dry-run --exclude='.turingos_sandbox' \
            "${sandbox}/" "${source}/" 2>/dev/null | grep -c '^>' || echo 0)
        ui::label "Files to sync" "$diff_count"
    fi
}

# ─── Status ───────────────────────────────────────────────────────────────────

sandbox::status() {
    local active
    active=$(config::state_get "$STATE_KEY_ACTIVE_SANDBOX")

    ui::header "Sandbox Status"

    if [[ -z "$active" ]]; then
        ui::status_row "Active Sandbox" "none" "warn"
    elif [[ -d "$active" ]]; then
        local meta="${active}/.turingos_sandbox"
        ui::status_row "Active Sandbox" "$(basename "$active")" "ok"
        if [[ -f "$meta" ]]; then
            local created label project backend
            created=$(grep '^CREATED_AT=' "$meta" | cut -d= -f2-)
            label=$(grep '^LABEL='   "$meta" | cut -d= -f2-)
            project=$(grep '^SOURCE_PROJECT=' "$meta" | cut -d= -f2-)
            backend=$(grep '^BACKEND=' "$meta" | cut -d= -f2-)
            ui::label "  Task"    "$label"
            ui::label "  Project" "$project"
            ui::label "  Created" "$created"
            ui::label "  Backend" "$backend"
        fi
    else
        ui::status_row "Active Sandbox" "missing (stale state)" "fail"
        config::state_del "$STATE_KEY_ACTIVE_SANDBOX"
    fi
    echo ""
}
