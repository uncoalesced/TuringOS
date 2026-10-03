#!/usr/bin/env bash
# sandbox/btrfs.sh — TuringOS Agent Sandbox
#
# Creates ephemeral Btrfs CoW snapshots of a project directory before handing
# it to an agent. Falls back to a plain copy when the snapshot can't be made.
#
# Depends on: core/config.sh, core/logging.sh, core/ui.sh

# Files that belong to TuringOS or git, never merged back into the project
SANDBOX_EXCLUDES=(--exclude=.git --exclude='.turingos_*')

# ─── Helpers ──────────────────────────────────────────────────────────────────

sandbox::_meta_file() {
    # Metadata sits next to the sandbox, not inside it: the agent works in the
    # sandbox and must not be able to redirect a merge by editing it.
    echo "${1%/}.meta"
}

sandbox::_meta() {
    # Usage: sandbox::_meta SANDBOX KEY — value from the sandbox metadata file
    local meta
    meta=$(sandbox::_meta_file "$1")
    [[ -f "$meta" ]] || return 0
    sed -n "s/^$2=//p" "$meta" | head -1
}

sandbox::_resolve() {
    # Usage: path=$(sandbox::_resolve [SANDBOX]) — argument or active sandbox,
    # canonical, and only a direct child of TURINGOS_SANDBOX_DIR
    local path="${1:-}" root=""
    [[ -z "$path" ]] && path=$(config::state_get "$STATE_KEY_ACTIVE_SANDBOX")
    root=$(realpath -e -- "$TURINGOS_SANDBOX_DIR" 2>/dev/null) || root=""
    if [[ -n "$path" ]]; then
        path=$(realpath -e -- "$path" 2>/dev/null) || path=""
    fi
    if [[ -z "$path" || -z "$root" || "$(dirname -- "$path")" != "$root" \
        || ! -d "$path" || ! -f "$(sandbox::_meta_file "$path")" ]]; then
        ui::fail "No sandbox found${1:+ at ${1}}. Run: turingos sandbox create" >&2
        return 1
    fi
    echo "$path"
}

sandbox::_source() {
    # Usage: src=$(sandbox::_source SANDBOX) — the project a sandbox merges
    # into: an existing directory outside the sandbox root, never /
    local src root
    src=$(realpath -e -- "$(sandbox::_meta "$1" SOURCE_PROJECT)" 2>/dev/null) || src=""
    root=$(realpath -e -- "$TURINGOS_SANDBOX_DIR")
    if [[ -z "$src" || ! -d "$src" || "$src" == "/" \
        || "$src" == "$root" || "$src" == "$root"/* || "$root" == "$src"/* ]]; then
        ui::fail "Sandbox has no valid source project: $(sandbox::_meta "$1" SOURCE_PROJECT)" >&2
        log::error "invalid source project for ${1}"
        return 1
    fi
    echo "$src"
}

sandbox::_sudo() {
    # Run unprivileged first, then via passwordless sudo (live ISO user)
    "$@" 2>/dev/null || sudo -n "$@"
}

# ─── Create Sandbox ───────────────────────────────────────────────────────────

sandbox::create() {
    # Usage: sandbox::create [PROJECT_DIR] [TASK_LABEL]
    # Prints the sandbox path to stdout; all status output goes to stderr.
    local project="${1:-$PWD}"
    local label="${2:-task}"

    if [[ ! -d "$project" ]]; then
        ui::fail "Project directory not found: $project" >&2
        log::error "directory not found: $project"
        return 1
    fi
    project="$(realpath -e -- "$project")"
    mkdir -p "$TURINGOS_SANDBOX_DIR"
    local root
    root=$(realpath -e -- "$TURINGOS_SANDBOX_DIR")
    if [[ "$project" == "/" || "$project" == "$root" || "$project" == "$root"/* || "$root" == "$project"/* ]]; then
        ui::fail "Can't sandbox ${project}: it contains or is inside the sandbox directory" >&2
        log::error "refused sandbox of ${project}"
        return 1
    fi

    local safe_label sandbox_name sandbox_path backend="copy"
    safe_label=$(tr ' /' '__' <<< "$label" | tr -cd '[:alnum:]_-' | cut -c1-32)
    sandbox_name="${safe_label:-task}-$(date +%s)"
    sandbox_path="${TURINGOS_SANDBOX_DIR}/${sandbox_name}"

    log::section "SANDBOX CREATE — ${sandbox_name}"

    # A snapshot needs btrfs tools, a btrfs project that is a subvolume, and
    # the sandbox dir on the same filesystem. Anything else falls back to copy.
    if [[ "$TURINGOS_SANDBOX_BACKEND" == "btrfs" ]] && command -v btrfs &>/dev/null \
        && [[ "$(stat -f -c %T "$project" 2>/dev/null)" == "btrfs" ]] \
        && sandbox::_sudo btrfs subvolume snapshot "$project" "$sandbox_path" >/dev/null; then
        backend="btrfs"
    elif ! sandbox::_create_copy "$project" "$sandbox_path"; then
        ui::fail "Failed to create sandbox" >&2
        log::error "sandbox copy failed: ${project} -> ${sandbox_path}"
        rm -rf "$sandbox_path"
        return 1
    fi

    {
        ui::info "Creating agent sandbox..."
        ui::label "Project" "$project"
        ui::label "Sandbox" "$sandbox_path"
        ui::label "Backend" "$backend"
        echo ""
    } >&2
    log::info "project=${project} sandbox=${sandbox_path} backend=${backend}"

    cat > "$(sandbox::_meta_file "$sandbox_path")" <<EOF
SANDBOX_NAME=${sandbox_name}
SANDBOX_PATH=${sandbox_path}
SOURCE_PROJECT=${project}
CREATED_AT=$(date '+%Y-%m-%dT%H:%M:%S')
BACKEND=${backend}
LABEL=${label//$'\n'/ }
EOF

    config::state_set "$STATE_KEY_ACTIVE_SANDBOX" "$sandbox_path"
    log::audit SANDBOX_CREATE "sandbox=${sandbox_path}" "project=${project}" "backend=${backend}" "label=${label}"

    {
        ui::ok "Original project protected"
        ui::ok "Sandbox created: ${sandbox_path}"
        echo ""
    } >&2
    echo "$sandbox_path"
}

sandbox::_create_copy() {
    # .git comes along so git works inside the sandbox
    if command -v rsync &>/dev/null; then
        rsync -a "$1/" "$2/"
    else
        cp -a "$1" "$2"
    fi
}

# ─── List Sandboxes ───────────────────────────────────────────────────────────

sandbox::list() {
    local sb found=0
    for sb in "$TURINGOS_SANDBOX_DIR"/*/; do
        [[ -d "$sb" ]] || continue
        sb="${sb%/}"
        [[ "$found" -eq 0 ]] && ui::header "Sandboxes"
        found=1
        if [[ -f "$(sandbox::_meta_file "$sb")" ]]; then
            printf '  %-36s  %s\n' "$(sandbox::_meta "$sb" SANDBOX_NAME)" "$(sandbox::_meta "$sb" CREATED_AT)"
            printf '  %b  %-34s  %s%b\n\n' "$DIM" "$(sandbox::_meta "$sb" SOURCE_PROJECT)" \
                "$(sandbox::_meta "$sb" LABEL)" "$RESET"
        else
            echo "  $(basename "$sb")"
        fi
    done
    [[ "$found" -eq 1 ]] || ui::info "No sandboxes found"
}

# ─── Rollback (destroy sandbox) ───────────────────────────────────────────────

sandbox::rollback() {
    # Usage: sandbox::rollback [SANDBOX_PATH] — default: the active sandbox
    local sandbox_path
    sandbox_path=$(sandbox::_resolve "${1:-}") || return 1

    ui::warn "Rolling back sandbox: $sandbox_path"
    if ui::confirm "Destroy sandbox and discard all agent changes?"; then
        sandbox::_destroy "$sandbox_path"
        log::audit SANDBOX_ROLLBACK "sandbox=${sandbox_path}"
        ui::ok "Sandbox destroyed. Original project untouched."
    else
        ui::info "Rollback cancelled."
    fi
}

sandbox::_destroy() {
    local path="$1"
    if [[ "$(sandbox::_meta "$path" BACKEND)" == "btrfs" ]]; then
        sandbox::_sudo btrfs subvolume delete "$path" >/dev/null || rm -rf "$path"
    else
        rm -rf "$path"
    fi
    rm -f "$(sandbox::_meta_file "$path")"
    if [[ "$(config::state_get "$STATE_KEY_ACTIVE_SANDBOX")" == "$path" ]]; then
        config::state_del "$STATE_KEY_ACTIVE_SANDBOX"
    fi
}

# ─── Changes (shared by merge and diff) ──────────────────────────────────────

sandbox::changes() {
    # Usage: sandbox::changes SANDBOX SOURCE — one "A|M|D<TAB>path" line per
    # file that merge would add, modify or delete in SOURCE
    rsync -rcni --delete "${SANDBOX_EXCLUDES[@]}" "$1/" "$2/" 2>/dev/null \
        | awk '/^\*deleting / { sub(/^\*deleting +/, ""); if ($0 !~ /\/$/) print "D\t" $0; next }
               /^>f\+/        { print "A\t" substr($0, 13); next }
               /^>f/          { print "M\t" substr($0, 13) }'
}

sandbox::patch() {
    # Usage: sandbox::patch SANDBOX SOURCE — unified diff, project -> sandbox
    diff -ruN -x .git -x '.turingos_*' "$2" "$1" || true
}

sandbox::_show_summary() {
    local sandbox="$1" source="$2" changes added removed
    changes=$(sandbox::changes "$sandbox" "$source")
    read -r added removed < <(sandbox::patch "$sandbox" "$source" \
        | awk '/^\+\+\+|^---/ {next} /^\+/ {a++} /^-/ {r++} END {print a+0, r+0}')
    ui::label "Files changed" "$(grep -c . <<< "$changes" || true)"
    ui::label "Lines added"   "+${added}"
    ui::label "Lines removed" "-${removed}"
}

# ─── Merge (apply changes back to source) ────────────────────────────────────

sandbox::merge() {
    # Usage: sandbox::merge [SANDBOX_PATH]
    local sandbox_path source_project
    sandbox_path=$(sandbox::_resolve "${1:-}") || return 1
    source_project=$(sandbox::_source "$sandbox_path") || return 1

    ui::info "Merging sandbox → original project"
    ui::label "From" "$sandbox_path"
    ui::label "Into" "$source_project"
    echo ""

    sandbox::_show_summary "$sandbox_path" "$source_project"
    echo ""
    if ! ui::confirm "Apply these changes to the original project? (files the agent deleted are deleted too)"; then
        ui::info "Merge cancelled."
        return 0
    fi

    # .git stays excluded: the project's history is never overwritten.
    # --checksum: a same-size edit in the same second must not be skipped.
    rsync -a --checksum --delete "${SANDBOX_EXCLUDES[@]}" "${sandbox_path}/" "${source_project}/"
    log::audit SANDBOX_MERGE "sandbox=${sandbox_path}" "project=${source_project}"
    ui::ok "Changes merged into: $source_project"

    if ui::confirm "Destroy sandbox after merge?"; then
        sandbox::_destroy "$sandbox_path"
        ui::ok "Sandbox destroyed."
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
        ui::status_row "Active Sandbox" "$(basename "$active")" "ok"
        ui::label "  Task"    "$(sandbox::_meta "$active" LABEL)"
        ui::label "  Project" "$(sandbox::_meta "$active" SOURCE_PROJECT)"
        ui::label "  Created" "$(sandbox::_meta "$active" CREATED_AT)"
        ui::label "  Backend" "$(sandbox::_meta "$active" BACKEND)"
    else
        ui::status_row "Active Sandbox" "missing (stale state)" "fail"
        config::state_del "$STATE_KEY_ACTIVE_SANDBOX"
    fi
    echo ""
}
