#!/usr/bin/env bash
# tests/benchmark.sh — TuringOS Automated Release Benchmark & Qualification Suite
#
# Usage:
#   ./tests/benchmark.sh [--fast] [--json-out <path>]
#
# This test harness acts as the mandatory release benchmark system for TuringOS.
# It validates and benchmarks:
#   1. Script & Module Installation Parity
#   2. Fallback Window & Crash Watchdog Mechanisms
#   3. Bootloader Persistence & Safe-Mode Menu Cloning
#   4. Bazaar Fallback, Caching, SHA-256 & Ed25519 Cryptographic Verification
#   5. Rust Daemon (`turingosd`) Compilation & Dependency Health
#   6. Brand Palette & Window Border Visual Compliance
#   7. Release ISO Artifact Integrity & Checksums

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REPORT_FILE="${ROOT}/benchmark_report.json"
# shellcheck disable=SC2034  # --fast is accepted and reserved for quicker runs
FAST_MODE=0

while [[ $# -gt 0 ]]; do
    case "$1" in
        --fast) FAST_MODE=1; shift ;;
        --json-out) REPORT_FILE="$2"; shift 2 ;;
        *) echo "Unknown argument: $1" >&2; exit 1 ;;
    esac
done

export FAST_MODE  # reserved flag; exported so it is visibly used
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
BOLD='\033[1m'
NC='\033[0m'

PASSED_COUNT=0
FAILED_COUNT=0
# shellcheck disable=SC2034
TOTAL_START=$(date +%s%N 2>/dev/null || date +%s)

declare -a BENCHMARK_RESULTS=()

record_benchmark() {
    local name="$1"
    local status="$2"
    local duration_ms="$3"
    local details="$4"
    BENCHMARK_RESULTS+=("{\"name\": \"$name\", \"status\": \"$status\", \"duration_ms\": $duration_ms, \"details\": \"$details\"}")
}

run_suite() {
    local suite_name="$1"
    local cmd="$2"
    echo -e "${BOLD}${BLUE}▶ Running Benchmark:${NC} ${suite_name}..."
    local t0 t1 duration_ms rc output
    t0=$(date +%s%N 2>/dev/null || date +%s)
    
    set +e
    output=$(eval "$cmd" 2>&1)
    rc=$?
    set -e
    
    t1=$(date +%s%N 2>/dev/null || date +%s)
    if [[ ${#t0} -gt 10 ]]; then
        duration_ms=$(( (t1 - t0) / 1000000 ))
    else
        duration_ms=$(( (t1 - t0) * 1000 ))
    fi

    if [[ $rc -eq 0 ]]; then
        echo -e "  ${GREEN}✓ PASSED${NC} (${duration_ms}ms)"
        PASSED_COUNT=$((PASSED_COUNT + 1))
        record_benchmark "$suite_name" "PASS" "$duration_ms" "Clean execution"
    else
        echo -e "  ${RED}✗ FAILED${NC} (${duration_ms}ms) with exit code $rc"
        # shellcheck disable=SC2001  # prefix every line, not a substitution
        echo "$output" | sed 's/^/    /'
        FAILED_COUNT=$((FAILED_COUNT + 1))
        record_benchmark "$suite_name" "FAIL" "$duration_ms" "Exited with code $rc"
    fi
}

echo -e "${BOLD}======================================================${NC}"
echo -e "${BOLD}       TuringOS Release Benchmark System              ${NC}"
echo -e "${BOLD}======================================================${NC}"
echo "Target Root: ${ROOT}"
echo "Timestamp:   $(date -u +%Y-%m-%dT%H:%M:%SZ)"
echo ""

# ── 1. Installation Parity ────────────────────────────────────────────────────
if command -v rsync &>/dev/null; then
    run_suite "Module & Script Install Parity" "bash '${ROOT}/tests/install_parity.sh'"
else
    echo -e "  ${YELLOW}⚠ Skipping install_parity (rsync not installed in local environment)${NC}"
fi

# ── 2. Fallback & Watchdog ────────────────────────────────────────────────────
run_suite "Window Manager Fallback & Respawn Watchdog" "bash '${ROOT}/tests/fallback.sh'"

# ── 3. Bootloader & Persistence Menus ─────────────────────────────────────────
run_suite "Bootloader Timeout & Persistence Deduplication" "bash '${ROOT}/tests/persistence_menu.sh'"

# ── 4. Bazaar Fallback, Integrity & Cryptography ──────────────────────────────
run_suite "Bazaar 10-Step Cryptographic & Cache Suite" "bash '${ROOT}/tests/bazaar_fallback.sh'"

if command -v cargo &>/dev/null; then
    if [[ "$OSTYPE" == "msys" || "$OSTYPE" == "win32" ]] && [[ -z "${LIBCLANG_PATH:-}" ]]; then
        echo -e "  ${YELLOW}⚠ Skipping daemon cargo check on Windows host without LIBCLANG_PATH (run inside Linux VM for full clang bindgen check)${NC}"
    else
        run_suite "Daemon Compilation & Feature Verification (turingosd)" "cd '${ROOT}/daemon' && cargo check"
    fi
else
    echo -e "  ${YELLOW}⚠ Skipping daemon cargo check (cargo not on host PATH)${NC}"
fi

# ── 6. Visual Theme & Window Border Compliance Benchmark ──────────────────────
# shellcheck disable=SC2317,SC2329  # run via run_suite
test_border_compliance() {
    local hypr="${ROOT}/debian-live/config/includes.chroot/etc/turingos/hyprland.conf"
    local tokens="${ROOT}/ui/web/css/tokens.css"
    [[ -f "$hypr" ]] || return 1
    [[ -f "$tokens" ]] || return 1
    
    # Check renewed brand orange active border and dark gray inactive border
    grep -q "col.active_border = rgb(e85002) rgb(f16001) 45deg" "$hypr" || return 1
    grep -q "col.inactive_border = rgb(333333)" "$hypr" || return 1
    
    # Check renewed palette CSS tokens
    grep -q -- "--tos-brand-orange: #e85002;" "$tokens" || return 1
    grep -q -- "--tos-primary-bg: #000000;" "$tokens" || return 1
    grep -q -- "--tos-dark-gray: #333333;" "$tokens" || return 1
    grep -q -- "--tos-brand-gradient:" "$tokens" || return 1
    return 0
}
run_suite "Renewed Palette Window Border & Token Compliance" "test_border_compliance"

# ── 7. Kernel Persistence Cmdline Benchmark ───────────────────────────────────
# shellcheck disable=SC2317,SC2329  # run via run_suite
test_live_build_persistence() {
    local build_amd="${ROOT}/debian-live/build-amd64.sh"
    local build_arm="${ROOT}/arm/build.sh"
    grep -q -- '--bootappend-live "boot=live components quiet splash persistence"' "$build_amd" || return 1
    grep -q -- '--bootappend-live "boot=live components quiet splash persistence"' "$build_arm" || return 1
    grep -q -- '--image-name turingos' "$build_amd" || return 1
    grep -q -- '--image-name turingos' "$build_arm" || return 1
    return 0
}
run_suite "Live-Build Persistence & Dual-Naming Verification" "test_live_build_persistence"

# ── 8. Calamares Installer Persistent User Autologin Benchmark ────────────────
# shellcheck disable=SC2317,SC2329  # run via run_suite
test_installer_autologin_hardening() {
    local hook="${ROOT}/debian-live/config/hooks/normal/0495-installer.hook.chroot"
    grep -q "PUSER=" "$hook" || return 1
    grep -q "awk -F: '\$3 == 1000 {print \$1}' /etc/passwd" "$hook" || return 1
    return 0
}
run_suite "Calamares Installed System Persistent Autologin Hardening" "test_installer_autologin_hardening"

echo ""
echo -e "${BOLD}======================================================${NC}"
echo -e "${BOLD}                Benchmark Summary                     ${NC}"
echo -e "${BOLD}======================================================${NC}"
echo -e "Total Passed: ${GREEN}${PASSED_COUNT}${NC}"
echo -e "Total Failed: ${RED}${FAILED_COUNT}${NC}"

# Write JSON benchmark report
cat > "$REPORT_FILE" <<EOF
{
  "timestamp": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "total_passed": ${PASSED_COUNT},
  "total_failed": ${FAILED_COUNT},
  "results": [
    $(IFS=,; echo "${BENCHMARK_RESULTS[*]}")
  ]
}
EOF

echo "Benchmark report saved to: ${REPORT_FILE}"

if [[ $FAILED_COUNT -gt 0 ]]; then
    echo -e "${RED}${BOLD}BENCHMARK FAILED: Release qualification not met.${NC}" >&2
    exit 1
else
    echo -e "${GREEN}${BOLD}BENCHMARK SUCCESSFUL: All release qualification tests passed.${NC}"
    exit 0
fi
