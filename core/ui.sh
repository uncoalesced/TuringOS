#!/usr/bin/env bash
# core/ui.sh — TuringOS UI primitives
# Colors, boxes, status indicators, prompts. gum is used when installed.

# ─── Color Codes ──────────────────────────────────────────────────────────────
# shellcheck disable=SC2034  # used by the modules that source this file
declare -g \
    RESET="\033[0m" DIM="\033[2m" WHITE="\033[0;37m" \
    RED="\033[0;31m" GREEN="\033[0;32m" YELLOW="\033[0;33m" \
    BOLD_RED="\033[1;31m" BOLD_GREEN="\033[1;32m" BOLD_YELLOW="\033[1;33m" \
    BOLD_CYAN="\033[1;36m" BOLD_WHITE="\033[1;37m"

# ─── Status Symbols ───────────────────────────────────────────────────────────

SYM_OK="${BOLD_GREEN}✓${RESET}"
SYM_FAIL="${BOLD_RED}✗${RESET}"
SYM_WARN="${BOLD_YELLOW}⚠${RESET}"
SYM_INFO="${BOLD_CYAN}→${RESET}"
SYM_WAIT="${BOLD_YELLOW}◌${RESET}"

# ─── Print Helpers ────────────────────────────────────────────────────────────

ui::ok()   { echo -e "  ${SYM_OK}  $*"; }
ui::fail() { echo -e "  ${SYM_FAIL}  $*"; }
ui::warn() { echo -e "  ${SYM_WARN}  $*"; }
ui::info() { echo -e "  ${SYM_INFO}  $*"; }
ui::wait() { echo -e "  ${SYM_WAIT}  $*"; }

ui::_line() {
    # Usage: ui::_line CHAR WIDTH — prints CHAR repeated WIDTH times
    local out
    printf -v out '%*s' "$2" ''
    printf '%s' "${out// /$1}"
}

ui::header() {
    local title="$1" width="${2:-44}"
    local pad=$(( (width - ${#title} - 2) / 2 ))
    local line
    line=$(ui::_line '─' "$width")
    echo ""
    echo -e "  ${BOLD_CYAN}╭${line}╮${RESET}"
    printf '  %b│%b%*s%b %s %b%*s%b│%b\n' "$BOLD_CYAN" "$RESET" "$pad" '' "$BOLD_WHITE" "$title" "$RESET" \
        "$(( width - pad - ${#title} - 2 ))" '' "$BOLD_CYAN" "$RESET"
    echo -e "  ${BOLD_CYAN}╰${line}╯${RESET}"
    echo ""
}

ui::box() {
    # Usage: ui::box COLOR "Title" "line1" "line2" ... — plain-text lines, 42 wide
    local color="$1" title="$2"
    shift 2
    local width=42 entry
    echo ""
    printf '  %b╭─ %b%s%b %s╮%b\n' "$color" "$BOLD_WHITE" "$title" "$color" \
        "$(ui::_line '─' $(( width - ${#title} - 3 )))" "$RESET"
    for entry in "$@"; do
        printf '  %b│%b  %-*s%b│%b\n' "$color" "$RESET" $(( width - 2 )) "$entry" "$color" "$RESET"
    done
    printf '  %b╰%s╯%b\n' "$color" "$(ui::_line '─' "$width")" "$RESET"
    echo ""
}

ui::divider() {
    echo -e "  ${DIM}$(ui::_line '─' "${1:-44}")${RESET}"
}

ui::label() {
    # ui::label "KEY" "VALUE" [color]
    printf '  %b%-22s%b %b%s%b\n' "$DIM" "$1" "$RESET" "${3:-$WHITE}" "$2" "$RESET"
}

ui::status_row() {
    # ui::status_row "Label" "value" "ok|warn|fail"
    local sym
    case "${3:-ok}" in
        ok)   sym="$SYM_OK"   ;;
        warn) sym="$SYM_WARN" ;;
        fail) sym="$SYM_FAIL" ;;
        *)    sym="$SYM_INFO" ;;
    esac
    printf '  %-28s %b  %s\n' "$1" "$sym" "$2"
}

# ─── Interactive Prompts ──────────────────────────────────────────────────────
# Prompts go to stderr so $(ui::choose ...) captures only the answer.
# TURINGOS_NO_GUM=1 forces the plain prompts even when gum is installed.

ui::_gum() {
    [[ -z "${TURINGOS_NO_GUM:-}" ]] && command -v gum &>/dev/null
}

ui::confirm() {
    # Usage: ui::confirm "Are you sure?" && do_thing
    local prompt="${1:-Continue?}" reply
    if ui::_gum; then
        gum confirm --default=false "$prompt"
    else
        echo -en "  ${BOLD_YELLOW}?${RESET}  ${prompt} [y/N] " >&2
        read -r reply
        [[ "$reply" =~ ^[Yy]$ ]]
    fi
}

ui::_menu() {
    # Usage: ui::_menu PROMPT ASK OPTIONS... — numbered fallback menu, prints chosen options
    local prompt="$1" ask="$2" reply n i=1 opt
    shift 2
    echo -e "  ${BOLD_CYAN}${prompt}${RESET}" >&2
    for opt in "$@"; do
        echo "    [$i] $opt" >&2
        i=$(( i + 1 ))
    done
    echo -en "  ${ask}: " >&2
    read -r reply
    for n in $reply; do
        [[ "$n" =~ ^[0-9]+$ ]] && (( n >= 1 && n <= $# )) && echo "${!n}"
    done
    return 0
}

ui::choose() {
    # Usage: result=$(ui::choose "Pick one" "opt1" "opt2" "opt3")
    local prompt="$1"
    shift
    if ui::_gum; then
        gum choose --header="$prompt" "$@"
    else
        ui::_menu "$prompt" "Choice" "$@" | head -1
    fi
}

ui::choose_many() {
    # Usage: ui::choose_many "Pick some" "opt1" "opt2" — prints one choice per line
    local prompt="$1"
    shift
    if ui::_gum; then
        gum choose --no-limit --header="$prompt" "$@"
    else
        ui::_menu "$prompt" "Choices (space-separated numbers)" "$@"
    fi
}

ui::input() {
    # Usage: result=$(ui::input "Enter project path" [default])
    local prompt="$1" default="${2:-}" val
    if ui::_gum; then
        gum input --placeholder="$default" --prompt="  ❯ " --header="$prompt"
    else
        echo -en "  ${BOLD_CYAN}${prompt}${RESET}${default:+ [${default}]}: " >&2
        read -r val
        echo "${val:-$default}"
    fi
}

ui::secret() {
    # Usage: key=$(ui::secret "API key (blank to skip)") — input is not echoed
    local prompt="$1" val=""
    if ui::_gum; then
        gum input --password --prompt="  ❯ " --header="$prompt" || true
    else
        echo -en "  ${prompt}: " >&2
        read -rs val || true
        echo "" >&2
        echo "$val"
    fi
}

# ─── TuringOS Banner ─────────────────────────────────────────────────────────

ui::banner() {
    local row
    echo ""
    echo -e "  ${BOLD_CYAN}╔$(ui::_line '═' 69)╗${RESET}"
    for row in \
        "████████╗██╗   ██╗██████╗ ██╗███╗   ██╗ ██████╗  ██████╗ ███████╗" \
        "╚══██╔══╝██║   ██║██╔══██╗██║████╗  ██║██╔════╝ ██╔═══██╗██╔════╝" \
        "   ██║   ██║   ██║██████╔╝██║██╔██╗ ██║██║  ███╗██║   ██║███████╗" \
        "   ██║   ██║   ██║██╔══██╗██║██║╚██╗██║██║   ██║██║   ██║╚════██║" \
        "   ██║   ╚██████╔╝██║  ██║██║██║ ╚████║╚██████╔╝╚██████╔╝███████║" \
        "   ╚═╝    ╚═════╝ ╚═╝  ╚═╝╚═╝╚═╝  ╚═══╝ ╚═════╝  ╚═════╝ ╚══════╝"; do
        echo -e "  ${BOLD_CYAN}║${RESET}  ${BOLD_WHITE}${row}${RESET}  ${BOLD_CYAN}║${RESET}"
    done
    printf '  %b║%b  %b%-65s%b  %b║%b\n' "$BOLD_CYAN" "$RESET" "$DIM" "Agentic Substrate - Debian Edition" \
        "$RESET" "$BOLD_CYAN" "$RESET"
    echo -e "  ${BOLD_CYAN}╚$(ui::_line '═' 69)╝${RESET}"
    echo ""
}

# ─── Dependency Check ─────────────────────────────────────────────────────────

ui::check_deps() {
    # Usage: ui::check_deps required|optional CMD... — status row per command;
    # returns 1 if any is missing
    local kind="$1" cmd missing=0
    shift
    for cmd in "$@"; do
        if command -v "$cmd" &>/dev/null; then
            ui::status_row "$cmd" "found" "ok"
        elif [[ "$kind" == required ]]; then
            ui::status_row "$cmd" "MISSING (required)" "fail"
            missing=1
        else
            ui::status_row "$cmd" "not found (optional)" "warn"
            missing=1
        fi
    done
    return "$missing"
}
