#!/usr/bin/env bash
# Engineered by uncoalesced
# tests/bazaar_fallback.sh — Tests for Bazaar remote index fetching, 24h caching,
# offline fallback to bundled snapshot, and SHA-256 cryptographic verification.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$(mktemp -d)"
HOME="${WORK}/home"
mkdir -p "$HOME"
export HOME

trap 'rm -rf "$WORK"' EXIT

fail() { echo "FAIL: $*" >&2; exit 1; }

# Source core runtime
source "${ROOT}/core/config.sh"
source "${ROOT}/core/ui.sh"
source "${ROOT}/core/logging.sh"
source "${ROOT}/bazaar/registry.sh"
source "${ROOT}/bazaar/install.sh"

export TURINGOS_DATA_DIR="${HOME}/.turingos"
export TURINGOS_BAZAAR_DIR="${TURINGOS_DATA_DIR}/bazaar"
export TURINGOS_BAZAAR_CACHE="${HOME}/.cache/turingos/bazaar/index.json"
mkdir -p "$TURINGOS_BAZAAR_DIR" "$(dirname "$TURINGOS_BAZAAR_CACHE")"

echo "==> Running Bazaar Fallback and Verification Test Suite..."

# ─── Test 1: Bundled snapshot floor when completely offline ──────────────────
echo "── Test 1: Offline fallback to bundled snapshot"
export TURINGOS_BAZAAR_REMOTE_URL="http://127.0.0.1:9/unreachable.json"
rm -f "$TURINGOS_BAZAAR_CACHE"

keys=$(registry::keys)
[[ -n "$keys" ]] || fail "registry::keys returned empty under offline fallback"
grep -q "memory-mcp" <<< "$keys" || fail "bundled registry missing memory-mcp"
grep -q "github-mcp" <<< "$keys" || fail "bundled registry missing github-mcp"

out=$(registry::list 2>&1)
grep -q "offline catalogue" <<< "$out" || fail "offline list should display [offline catalogue] badge: $out"
grep -q "Memory MCP Server" <<< "$out" || fail "offline list missing Memory MCP Server"

# ─── Test 2: Local 24h caching from valid file/remote ────────────────────────
echo "── Test 2: Local cache utilization within 24h TTL"
MOCK_INDEX="${WORK}/mock_remote.json"
cat > "$MOCK_INDEX" <<EOF
{
  "version": 1,
  "generated_at": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "entries": {
    "test-tool": {
      "id": "test-tool",
      "name": "Test Remote Tool",
      "type": "skill",
      "version": "1.0.0",
      "description": "Mock tool delivered via remote catalog",
      "tags": ["test"],
      "verified": true,
      "install": {
        "runtime": "archive",
        "package": "test-tool",
        "version": "1.0.0",
        "sha256": "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"
      }
    }
  }
}
EOF

# Simulate a successful remote fetch by copying mock index to cache with current timestamp
cp "$MOCK_INDEX" "$TURINGOS_BAZAAR_CACHE"

# With cache present and fresh, it should read from cache even if remote URL is unreachable
registry::_load
name=$(registry::get_field "test-tool" name)
[[ "$name" == "Test Remote Tool" ]] || fail "failed to read test-tool from fresh cache: got '$name'"
(( TURINGOS_BAZAAR_OFFLINE == 0 )) || fail "fresh cache should be considered online, got offline=1"

# ─── Test 3: Stale cache fallback with offline badge ─────────────────────────
echo "── Test 3: Stale cache (>24h) fallback when remote unreachable"
# Set mtime to 2 days ago
if touch -d "2 days ago" "$TURINGOS_BAZAAR_CACHE" 2>/dev/null || touch -t 202601010000 "$TURINGOS_BAZAAR_CACHE" 2>/dev/null; then
    registry::_load
    name=$(registry::get_field "test-tool" name)
    [[ "$name" == "Test Remote Tool" ]] || fail "failed to read test-tool from stale cache fallback"
    (( TURINGOS_BAZAAR_OFFLINE == 1 )) || fail "stale cache fallback should set TURINGOS_BAZAAR_OFFLINE=1"
fi

# ─── Test 4: Rejection of corrupted remote payload ───────────────────────────
echo "── Test 4: Rejection of corrupted remote payload"
CORRUPT_TEMP="${WORK}/corrupt.json"
echo "<html><body>502 Bad Gateway</body></html>" > "$CORRUPT_TEMP"

# If curl fetched this garbage, _fetch_remote must reject it and NOT overwrite the cache
export TURINGOS_BAZAAR_REMOTE_URL="file://${CORRUPT_TEMP}"
rm -f "$TURINGOS_BAZAAR_CACHE"
# Load must fall back to bundled snapshot without crashing on jq error
keys=$(registry::keys)
grep -q "memory-mcp" <<< "$keys" || fail "did not fall back to bundled snapshot when remote returned HTML"

# ─── Test 5: Cryptographic SHA-256 verification (Match vs Mismatch) ──────────
echo "── Test 5: Archive unpack & SHA-256 verification"
TEST_ARCHIVE="${WORK}/test_skill.tar.gz"
mkdir -p "${WORK}/skill_src"
echo 'echo "Hello from Skill"' > "${WORK}/skill_src/run.sh"
tar -czf "$TEST_ARCHIVE" -C "${WORK}/skill_src" run.sh

ACTUAL_HASH=$(sha256sum "$TEST_ARCHIVE" | awk '{print $1}')

# Create registry with matching sha256
cat > "$TURINGOS_BAZAAR_CACHE" <<EOF
{
  "version": 1,
  "generated_at": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "entries": {
    "good-skill": {
      "id": "good-skill",
      "name": "Good Skill",
      "type": "skill",
      "version": "1.0.0",
      "description": "Valid skill with matching hash",
      "tags": ["skill"],
      "install": {
        "runtime": "archive",
        "package": "file://${TEST_ARCHIVE}",
        "version": "1.0.0",
        "sha256": "${ACTUAL_HASH}"
      }
    },
    "bad-skill": {
      "id": "bad-skill",
      "name": "Bad Skill",
      "type": "skill",
      "version": "1.0.0",
      "description": "Tampered skill with invalid hash",
      "tags": ["skill"],
      "install": {
        "runtime": "archive",
        "package": "file://${TEST_ARCHIVE}",
        "version": "1.0.0",
        "sha256": "0000000000000000000000000000000000000000000000000000000000000000"
      }
    }
  }
}
EOF

# Install good skill: should succeed and unpack
echo y | bazaar::install good-skill >/dev/null 2>&1 || fail "install of good-skill should succeed"
[[ -f "${TURINGOS_BAZAAR_DIR}/good-skill/.installed" ]] || fail "good-skill .installed marker missing"
[[ -f "${TURINGOS_BAZAAR_DIR}/good-skill/unpacked/run.sh" ]] || fail "good-skill unpacked run.sh missing"

# Install bad skill: should abort with hash mismatch
if echo y | bazaar::install bad-skill >/dev/null 2>&1; then
    fail "install of bad-skill should have aborted due to sha256 mismatch"
fi
[[ ! -f "${TURINGOS_BAZAAR_DIR}/bad-skill/.installed" ]] || fail "bad-skill should NOT have .installed marker"

# ─── Test 6: Per-project disable rule & .claude/settings.json sync ───────────
echo "── Test 6: Per-project disable rule & .claude/settings.json sync"
PROJECT_DIR="${WORK}/mock_project"
mkdir -p "$PROJECT_DIR"

bazaar::disable "good-skill" "$PROJECT_DIR" >/dev/null
RULES_FILE="${TURINGOS_DATA_DIR}/bazaar_rules.json"
[[ -f "$RULES_FILE" ]] || fail "bazaar_rules.json was not created"
grep -q "good-skill" "$RULES_FILE" || fail "good-skill not found in bazaar_rules.json"

CLAUDE_SETTINGS="${PROJECT_DIR}/.claude/settings.json"
[[ -f "$CLAUDE_SETTINGS" ]] || fail ".claude/settings.json was not created"
grep -q "good-skill" "$CLAUDE_SETTINGS" || fail "good-skill not synced to disabledMcpServers in .claude/settings.json"

# ─── Test 7: Per-project rules query & committed .turingos/bazaar.toml precedence
echo "── Test 7: Per-project rules query and committed config precedence"
rules_out=$(bazaar::rules "$PROJECT_DIR" 2>&1)
grep -q "good-skill" <<< "$rules_out" || fail "bazaar::rules did not list good-skill as disabled"

# Committed .turingos/bazaar.toml override
mkdir -p "${PROJECT_DIR}/.turingos"
cat > "${PROJECT_DIR}/.turingos/bazaar.toml" <<EOF
[bazaar]
disabled = ["custom-tool-override"]
EOF

rules_out=$(bazaar::rules "$PROJECT_DIR" 2>&1)
grep -q "custom-tool-override" <<< "$rules_out" || fail "committed .turingos/bazaar.toml override was not respected"

# ─── Test 8: Per-project enable & cleanup ───────────────────────────────────
echo "── Test 8: Per-project enable & sync"
bazaar::enable "good-skill" "$PROJECT_DIR" >/dev/null
grep -q "good-skill" "$RULES_FILE" && fail "good-skill should have been removed from bazaar_rules.json"
grep -q "good-skill" "$CLAUDE_SETTINGS" && fail "good-skill should have been removed from .claude/settings.json"

# ─── Test 9: Non-interactive uninstall with -y ──────────────────────────────
echo "── Test 9: Non-interactive uninstall with -y"
bazaar::uninstall -y good-skill >/dev/null
[[ ! -d "${TURINGOS_BAZAAR_DIR}/good-skill" ]] || fail "good-skill directory was not removed by uninstall -y"

echo "==> All Bazaar Fallback, Integrity, and Per-Project Rule tests passed successfully!"
