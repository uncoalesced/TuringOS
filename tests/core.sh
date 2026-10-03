#!/usr/bin/env bash
# tests/core.sh — regression tests for the turingos CLI. Runs the real
# entrypoint in a temp HOME with stub agent binaries. Needs jq and rsync.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HOME="$(mktemp -d)"
STUBS="${HOME}/stubs"
export HOME TURINGOS_NO_GUM=1 PATH="${STUBS}:${PATH}"
trap 'pkill -f "${STUBS}/" 2>/dev/null || true; rm -rf "$HOME"' EXIT
unset ANTHROPIC_API_KEY NVIDIA_API_KEY OPENROUTER_API_KEY

fail() { echo "FAIL: $*" >&2; exit 1; }
tos() { "${ROOT}/turingos" "$@" 2>&1 | sed 's/\x1b\[[0-9;]*m//g'; }   # plain text out
mkdir -p "$STUBS"

# ─── logs before any log exists ───────────────────────────────────────────────
tos logs >/dev/null || fail "turingos logs with no log file"

# ─── status / monitor (arithmetic used to abort here) ────────────────────────
out=$(tos status 2>&1) || fail "turingos status: ${out}"
grep -q "RAM" <<< "$out" || fail "status has no RAM row"

# ─── bazaar search / installed (counters used to abort on the first hit) ─────
out=$(tos bazaar search memory 2>&1) || fail "bazaar search: ${out}"
grep -q "Memory MCP Server" <<< "$out" || fail "bazaar search missed memory-mcp"
grep -q "1 result" <<< "$out" || fail "bazaar search count: ${out}"
out=$(tos bazaar search zzz-nothing 2>&1) || fail "bazaar search (no hits)"
grep -q "No tools matched" <<< "$out" || fail "bazaar search no-hit message"

for k in memory-mcp github-mcp; do
    mkdir -p "${HOME}/.turingos/bazaar/${k}"
    echo "2026-01-01T00:00:00" > "${HOME}/.turingos/bazaar/${k}/.installed"
done
out=$(tos bazaar installed 2>&1) || fail "bazaar installed: ${out}"
[[ $(grep -c "●" <<< "$out") -eq 2 ]] || fail "bazaar installed should list 2: ${out}"
mkdir -p "${HOME}/victim"
if echo y | tos bazaar uninstall ../../victim >/dev/null 2>&1; then fail "bazaar uninstall took a path"; fi
[[ -d "${HOME}/victim" ]] || fail "bazaar uninstall deleted outside the Bazaar dir"

# ─── monitor spend (counter used to abort on the first log) ──────────────────
for n in 1 2; do
    echo '{"usage":{"input_tokens":100,"output_tokens":10}}' \
        > "${HOME}/.turingos/logs/agent-session-2026010${n}T000000.log"
done
out=$(tos monitor spend 2>&1) || fail "monitor spend: ${out}"
grep -Eq "Input tokens +200" <<< "$out" || fail "spend input total: ${out}"
rm -f "${HOME}"/.turingos/logs/agent-session-*.log

# ─── config.env: quoted, exported, mode 600 ──────────────────────────────────
evil='a b $(touch '"${HOME}"'/pwned) "q"'
(
    # shellcheck source=/dev/null
    source "${ROOT}/core/config.sh"
    config::set TEST_VALUE "$evil"
    config::set TEST_VALUE "$evil"
)
[[ $(grep -c '^TEST_VALUE=' "${HOME}/.turingos/config.env") -eq 1 ]] || fail "config::set duplicated the key"
[[ "$(stat -c %a "${HOME}/.turingos/config.env")" == 600 ]] || fail "config.env not mode 600"
got=$(bash -c 'source "$1/core/config.sh"; printenv TEST_VALUE' _ "$ROOT")
[[ "$got" == "$evil" ]] || fail "config value round-trip / export: ${got}"
[[ ! -e "${HOME}/pwned" ]] || fail "config value was executed"
[[ "$(stat -c %a "${HOME}/.turingos")" == 700 ]] || fail "~/.turingos not mode 700"
bash -c 'source "$1/core/config.sh"
    config::valid_secret "sk-ant-api03-Ab_9.x-Y" || exit 1
    for bad in "short" $'"'"'sk-ant-xxxxxxxx\ntouch /tmp/x'"'"' "sk-ant-\"xxxxxxxx" "sk-ant xxxxxxxx" "sk-ant-\$(id)xx"; do
        config::valid_secret "$bad" && exit 1
    done; exit 0' _ "$ROOT" || fail "config::valid_secret accepts/rejects the wrong keys"

# ─── game mode on/off (off used to abort after the first restore) ────────────
printf '#!/bin/sh\nsleep 30\n' > "${STUBS}/ninja"
chmod +x "${STUBS}/ninja"
"${STUBS}/ninja" &
sleep 0.3
out=$(tos game on 2>&1) || fail "game on: ${out}"
grep -q "ninja" <<< "$out" || fail "game on did not deprioritize the stub: ${out}"
out=$(tos game off 2>&1) || fail "game off: ${out}"
[[ "$(jq -r .game_mode "${HOME}/.turingos/state.json")" == off ]] || fail "game off did not clear state"

# ─── sandbox create / diff / merge ───────────────────────────────────────────
proj="${HOME}/proj"
mkdir -p "$proj"
printf 'one\n' > "${proj}/a.txt"
printf 'two\n' > "${proj}/b.txt"
git -C "$proj" init -q
git -C "$proj" -c user.email=t@t -c user.name=t add -A
git -C "$proj" -c user.email=t@t -c user.name=t commit -qm init
head_before=$(git -C "$proj" rev-parse HEAD)

TURINGOS_SANDBOX_BACKEND=copy tos sandbox create "$proj" "fix things" 2>/dev/null || fail "sandbox create"
sb=$(jq -r .active_sandbox "${HOME}/.turingos/state.json")
[[ -d "$sb" ]] || fail "no active sandbox"
printf 'ONE\n' > "${sb}/a.txt"
rm "${sb}/b.txt"
printf 'three\n' > "${sb}/c.txt"
echo "1 passed" > "${sb}/.turingos_test_result"
git -C "$sb" -c user.email=t@t -c user.name=t commit -qam "agent commit"

changes=$(bash -c 'source "$1/core/config.sh"; source "$1/core/ui.sh"; source "$1/core/logging.sh"
    source "$1/sandbox/btrfs.sh"; sandbox::changes "$2" "$3"' _ "$ROOT" "$sb" "$proj" | sort)
[[ "$changes" == $'A\tc.txt\nD\tb.txt\nM\ta.txt' ]] || fail "sandbox::changes: ${changes}"

out=$(echo 5 | tos sandbox diff 2>&1) || fail "sandbox diff: ${out}"
grep -q "3 file(s) changed" <<< "$out" || fail "diff summary: ${out}"

printf 'y\nn\n' | tos sandbox merge >/dev/null 2>&1 || fail "sandbox merge"
[[ "$(cat "${proj}/a.txt")" == ONE ]] || fail "merge: a.txt not updated"
[[ ! -e "${proj}/b.txt" ]] || fail "merge: deleted file kept"
[[ -f "${proj}/c.txt" ]] || fail "merge: new file missing"
if compgen -G "${proj}/.turingos_*" >/dev/null; then fail "merge leaked .turingos_* files"; fi
[[ "$(git -C "$proj" rev-parse HEAD)" == "$head_before" ]] || fail "merge touched the project's .git"

# Metadata lives outside the sandbox; a tampered or foreign target is refused
[[ -f "${sb}.meta" && ! -e "${sb}/.turingos_sandbox" ]] || fail "sandbox metadata inside the sandbox"
sed -i 's|^SOURCE_PROJECT=.*|SOURCE_PROJECT=/|' "${sb}.meta"
if printf 'y\nn\n' | tos sandbox merge >/dev/null 2>&1; then fail "merge into / was allowed"; fi
if printf 'y\nn\n' | tos sandbox merge "$proj" >/dev/null 2>&1; then fail "merge from a non-sandbox path was allowed"; fi
if tos sandbox create "$HOME" x >/dev/null 2>&1; then fail "sandbox of a dir containing the sandbox root was allowed"; fi

# ─── model set ollama → OpenCode provider config ─────────────────────────────
tos model set ollama "" llama3.2 >/dev/null || fail "model set ollama"
cfg=$(bash -c 'source "$1/core/config.sh"; source "$1/core/ui.sh"; source "$1/agent/nim.sh"
    source "$1/agent/model.sh"; model::opencode_config' _ "$ROOT")
jq -e '.provider.ollama.options.baseURL == "http://localhost:11434/v1" and (.provider.ollama.models | has("llama3.2"))' \
    "$cfg" >/dev/null || fail "ollama opencode config: $(cat "$cfg")"
tos model set claude >/dev/null || fail "model set claude"

# ─── agent start with a stub claude ──────────────────────────────────────────
cat > "${STUBS}/claude" <<'EOF'
#!/bin/sh
echo "args: $*"
cat > /dev/null
echo '{"usage":{"input_tokens":7,"output_tokens":3}}'
echo "4 passed, 0 failed"
EOF
chmod +x "${STUBS}/claude"
tos agent start "$proj" "stub task" </dev/null >/dev/null 2>&1 || fail "agent start"
for _ in $(seq 50); do
    [[ -f "${HOME}/.turingos/pids/claude.pid" ]] || break
    sleep 0.2
done
[[ ! -f "${HOME}/.turingos/pids/claude.pid" ]] || fail "agent did not finish"
log=$(ls "${HOME}"/.turingos/logs/agent-session-*.log)
grep -q -- "--dangerously-skip-permissions" "$log" || fail "claude flags: $(cat "$log")"
grep -q -- "--verbose" "$log" || fail "claude --verbose missing"
sb=$(jq -r .active_sandbox "${HOME}/.turingos/state.json")
[[ "$(cat "${sb}/.turingos_test_result")" == "4 passed, 0 failed" ]] || fail "test result not captured"

echo "core tests passed"
