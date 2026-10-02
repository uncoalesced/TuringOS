#!/usr/bin/env bash
# core/ui.sh — TuringOS UI primitives
# Colors, box drawing, status indicators, prompts
# Requires: gum (optional but preferred), tput

# ─── Color Codes ──────────────────────────────────────────────────────────────

RESET="\033[0m"
BOLD="\033[1m"
DIM="\033[2m"

BLACK="\033[0;30m"
RED="\033[0;31m"
GREEN="\033[0;32m"
YELLOW="\033[0;33m"
BLUE="\033[0;34m"
MAGENTA="\033[0;35m"
CYAN="\033[0;36m"
WHITE="\033[0;37m"

BOLD_RED="\033[1;31m"
BOLD_GREEN="\033[1;32m"
BOLD_YELLOW="\033[1;33m"
BOLD_BLUE="\033[1;34m"
BOLD_MAGENTA="\033[1;35m"
BOLD_CYAN="\033[1;36m"
BOLD_WHITE="\033[1;37m"

# ─── Status Symbols ───────────────────────────────────────────────────────────

SYM_OK="${BOLD_GREEN}✓${RESET}"
SYM_FAIL="${BOLD_RED}✗${RESET}"
SYM_WARN="${BOLD_YELLOW}⚠${RESET}"
SYM_INFO="${BOLD_CYAN}→${RESET}"
SYM_WAIT="${BOLD_YELLOW}◌${RESET}"
SYM_AGENT="${BOLD_MAGENTA}◈${RESET}"
SYM_GAME="${BOLD_GREEN}🎮${RESET}"
SYM_SANDBOX="${BOLD_BLUE}⬡${RESET}"

# ─── Print Helpers ────────────────────────────────────────────────────────────

ui::ok()   { echo -e "  ${SYM_OK}  $*"; }
ui::fail() { echo -e "  ${SYM_FAIL}  $*"; }
ui::warn() { echo -e "  ${SYM_WARN}  $*"; }
ui::info() { echo -e "  ${SYM_INFO}  $*"; }
ui::wait() { echo -e "  ${SYM_WAIT}  $*"; }

ui::header() {
    local title="$1"
    local width=${2:-44}
    local pad=$(( (width - ${#title} - 2) / 2 ))
    local line
    line=$(printf '─%.0s' $(seq 1 "$width"))

    echo -e ""
    echo -e "  ${BOLD_CYAN}╭${line}╮${RESET}"
    echo -e "  ${BOLD_CYAN}│${RESET}$(printf '%*s' "$((pad))" '')${BOLD_WHITE} ${title} ${RESET}$(printf '%*s' "$((pad))" '')${BOLD_CYAN}│${RESET}"
    echo -e "  ${BOLD_CYAN}╰${line}╯${RESET}"
    echo -e ""
}

ui::box() {
    # Usage: ui::box "Title" "line1" "line2" ...
    local title="$1"
    shift
    local width=42
    local line
    line=$(printf '─%.0s' $(seq 1 "$width"))

    echo -e ""
    echo -e "  ${BOLD_CYAN}╭─ ${BOLD_WHITE}${title}${BOLD_CYAN} $(printf '─%.0s' $(seq 1 $((width - ${#title} - 2))))╮${RESET}"
    for entry in "$@"; do
        # Pad entry to fill box width
        printf "  ${BOLD_CYAN}│${RESET}  %-${width}s${BOLD_CYAN}│${RESET}\n" "$entry"
    done
    echo -e "  ${BOLD_CYAN}╰${line}╯${RESET}"
    echo -e ""
}

ui::divider() {
    local width=${1:-44}
    local line
    line=$(printf '─%.0s' $(seq 1 "$width"))
    echo -e "  ${DIM}${line}${RESET}"
}

ui::label() {
    # ui::label "KEY" "VALUE" [color]
    local key="$1"
    local val="$2"
    local col="${3:-$WHITE}"
    printf "  ${DIM}%-22s${RESET} ${col}%s${RESET}\n" "$key" "$val"
}

ui::status_row() {
    # ui::status_row "Label" "value" "ok|warn|fail"
    local label="$1"
    local value="$2"
    local state="${3:-ok}"
    local sym
    case "$state" in
        ok)   sym="${SYM_OK}"   ;;
        warn) sym="${SYM_WARN}" ;;
        fail) sym="${SYM_FAIL}" ;;
        *)    sym="${SYM_INFO}" ;;
    esac
    printf "  %-28s %s  %s\n" "$label" "$sym" "$value"
}

# ─── Interactive Prompts ──────────────────────────────────────────────────────

ui::confirm() {
    # Usage: ui::confirm "Are you sure?" && do_thing
    local prompt="${1:-Continue?}"
    if command -v gum &>/dev/null; then
        gum confirm "$prompt"
    else
        echo -en "  ${BOLD_YELLOW}?${RESET}  ${prompt} [y/N] "
        read -r reply
        [[ "$reply" =~ ^[Yy]$ ]]
    fi
}

ui::choose() {
    # Usage: result=$(ui::choose "Pick one" "opt1" "opt2" "opt3")
    local prompt="$1"
    shift
    if command -v gum &>/dev/null; then
        gum choose --header="$prompt" "$@"
    else
        # Menu goes to stderr so $(ui::choose ...) captures only the answer
        echo -e "  ${BOLD_CYAN}${prompt}${RESET}" >&2
        local i=1
        for opt in "$@"; do
            echo "    [$i] $opt" >&2
            (( i++ ))
        done
        echo -en "  Choice: " >&2
        read -r choice
        # Return chosen option by index
        local opts=("$@")
        echo "${opts[$((choice-1))]}"
    fi
}

ui::choose_many() {
    # Usage: ui::choose_many "Pick some" "opt1" "opt2" — prints one choice per line
    local prompt="$1"
    shift
    if command -v gum &>/dev/null; then
        gum choose --no-limit --header="$prompt" "$@"
    else
        echo -e "  ${BOLD_CYAN}${prompt}${RESET}" >&2
        local i=1
        for opt in "$@"; do
            echo "    [$i] $opt" >&2
            (( i++ ))
        done
        echo -en "  Choices (space-separated numbers): " >&2
        local reply n opts=("$@")
        read -r reply
        for n in $reply; do
            [[ "$n" =~ ^[0-9]+$ ]] && (( n >= 1 && n <= ${#opts[@]} )) && echo "${opts[$((n-1))]}"
        done
        return 0
    fi
}

ui::input() {
    # Usage: result=$(ui::input "Enter project path")
    local prompt="$1"
    local default="${2:-}"
    if command -v gum &>/dev/null; then
        gum input --placeholder="${default}" --prompt="  ❯ " --header="$prompt"
    else
        echo -en "  ${BOLD_CYAN}${prompt}${RESET}${default:+ [${default}]}: " >&2
        read -r val
        echo "${val:-$default}"
    fi
}

# ─── TuringOS Banner ─────────────────────────────────────────────────────────

ui::banner() {
    echo -e ""
    echo -e "  ${BOLD_CYAN}╔═══════════════════════════════════════════╗${RESET}"
    echo -e "  ${BOLD_CYAN}║${RESET}  ${BOLD_WHITE}  ██████╗██╗      █████╗ ██╗   ██╗██████╗ ${BOLD_CYAN}║${RESET}"
    echo -e "  ${BOLD_CYAN}║${RESET}  ${BOLD_WHITE} ██╔════╝██║     ██╔══██╗██║   ██║██╔══██╗${BOLD_CYAN}║${RESET}"
    echo -e "  ${BOLD_CYAN}║${RESET}  ${BOLD_WHITE} ██║     ██║     ███████║██║   ██║██║  ██║${BOLD_CYAN}║${RESET}"
    echo -e "  ${BOLD_CYAN}║${RESET}  ${BOLD_WHITE} ██║     ██║     ██╔══██║██║   ██║██║  ██║${BOLD_CYAN}║${RESET}"
    echo -e "  ${BOLD_CYAN}║${RESET}  ${BOLD_WHITE} ╚██████╗███████╗██║  ██║╚██████╔╝██████╔╝${BOLD_CYAN}║${RESET}"
    echo -e "  ${BOLD_CYAN}║${RESET}  ${BOLD_WHITE}  ╚═════╝╚══════╝╚═╝  ╚═╝ ╚═════╝ ╚═════╝ ${BOLD_CYAN}║${RESET}"
    echo -e "  ${BOLD_CYAN}║${RESET}  ${DIM}  Agentic Substrate · CachyOS Edition   ${BOLD_CYAN}║${RESET}"
    echo -e "  ${BOLD_CYAN}╚═══════════════════════════════════════════╝${RESET}"
    echo -e ""
}

ui::spinner() {
    # Usage: ui::spinner "Loading..." &  SPIN_PID=$!  ...  kill $SPIN_PID
    local msg="${1:-Working...}"
    local frames=('⠋' '⠙' '⠹' '⠸' '⠼' '⠴' '⠦' '⠧' '⠇' '⠏')
    local i=0
    while true; do
        printf "\r  ${BOLD_CYAN}%s${RESET}  %s  " "${frames[$((i % ${#frames[@]}))]}" "$msg"
        (( i++ ))
        sleep 0.1
    done
}

ui::spinner_stop() {
    local pid="$1"
    local msg="${2:-Done}"
    kill "$pid" 2>/dev/null
    wait "$pid" 2>/dev/null
    printf "\r  ${SYM_OK}  %-40s\n" "$msg"
}

# ─── Dependency Check ─────────────────────────────────────────────────────────

ui::check_deps() {
    local missing=()
    for cmd in "$@"; do
        command -v "$cmd" &>/dev/null || missing+=("$cmd")
    done
    if [[ ${#missing[@]} -gt 0 ]]; then
        ui::warn "Missing optional tools: ${missing[*]}"
        ui::info "Install with: sudo apt install ${missing[*]}"
        return 1
    fi
    return 0
}
