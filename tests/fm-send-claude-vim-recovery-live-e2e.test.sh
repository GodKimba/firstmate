#!/usr/bin/env bash
# Opt-in real Claude/Herdr verification for Vim interruption recovery.
# It uses a disposable Firstmate home and git project inside a guarded named
# Herdr lab, never the live fleet pane. The helper's fleet-identity tripwire is
# the lifecycle owner for every provision, call, and teardown.
set -eu

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

if [ "${FM_SEND_CLAUDE_VIM_E2E:-0}" != 1 ]; then
  echo "skip: set FM_SEND_CLAUDE_VIM_E2E=1 to run the real Claude Vim interruption recovery"
  exit 0
fi
for tool in claude git herdr jq; do
  command -v "$tool" >/dev/null 2>&1 || { echo "skip: $tool not found"; exit 0; }
done

LAB_HELPER=${HERDR_LAB_HELPER:-$ROOT/bin/fm-herdr-lab.sh}
SESSION=$("$LAB_HELPER" name fm-claude-vim-recovery-e2e)
TMP_ROOT=$(fm_test_tmproot fm-send-claude-vim-recovery-live)
HOME_DIR="$TMP_ROOT/home"
PROJECT="$TMP_ROOT/project"
FAKEBIN="$TMP_ROOT/fakebin"
HERDR_LOG="$TMP_ROOT/recovery-herdr.log"
ORIGINAL_PATH=$PATH
PANE=
TARGET=
LAB_READY=0

cleanup() {
  local rc=$?
  trap - EXIT
  if [ "$LAB_READY" = 1 ] && ! "$LAB_HELPER" teardown "$SESSION"; then rc=1; fi
  rm -rf "$TMP_ROOT"
  exit "$rc"
}
trap cleanup EXIT

mkdir -p "$HOME_DIR"/{state,data,config,projects} "$PROJECT" "$FAKEBIN"
git -C "$PROJECT" init -q
git -C "$PROJECT" config user.email test@example.invalid
git -C "$PROJECT" config user.name Test
printf '# Disposable Claude Vim recovery verification\n' > "$PROJECT/README.md"
git -C "$PROJECT" add README.md
git -C "$PROJECT" commit -qm init

"$LAB_HELPER" provision "$SESSION" \
  || fail "guarded Herdr lab provisioning failed before live recovery verification"
LAB_READY=1
cat > "$FAKEBIN/herdr" <<EOF
#!/usr/bin/env bash
set -euo pipefail
helper='$LAB_HELPER'; session='$SESSION'; real_path='$ORIGINAL_PATH'; log='$HERDR_LOG'
args=("\$@"); n=\${#args[@]}
printf '%s\n' "\${args[*]}" >> "\$log"
if [ "\$n" -ge 2 ] && [ "\${args[\$((n-2))]}" = --session ]; then
  [ "\${args[\$((n-1))]}" = "\$session" ] || exit 97
  args=("\${args[@]:0:\$((n-2))}")
else
  [ "\${HERDR_SESSION:-}" = "\$session" ] || exit 98
fi
PATH="\$real_path" exec "\$helper" run "\$session" "\${args[@]}"
EOF
chmod +x "$FAKEBIN/herdr"

out=$("$LAB_HELPER" run "$SESSION" workspace create --cwd "$PROJECT" --label claude-vim-recovery-e2e --no-focus)
PANE=$(printf '%s' "$out" | jq -r '.result.root_pane.pane_id')
TARGET="$SESSION:$PANE"
cat > "$HOME_DIR/state/recovery.meta" <<EOF
window=$TARGET
backend=herdr
harness=claude
kind=ship
worktree=$PROJECT
project=disposable
EOF

cmd=$(printf 'exec env -u FM_HOME CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION=false claude --dangerously-skip-permissions --settings %q' '{"editorMode":"vim"}')
"$LAB_HELPER" run "$SESSION" pane run "$PANE" "$cmd" >/dev/null

capture() { "$LAB_HELPER" run "$SESSION" pane read "$PANE" --source recent --lines 200; }
agent_status() {
  "$LAB_HELPER" run "$SESSION" agent get "$PANE" 2>/dev/null \
    | jq -r '.result.agent.agent_status // empty' 2>/dev/null || true
}
wait_idle() {
  local stable=0 status _
  for _ in $(seq 1 320); do
    status=$(agent_status)
    case "$status" in idle|done) stable=$((stable + 1)); [ "$stable" -ge 4 ] && return 0 ;; *) stable=0 ;; esac
    sleep 0.25
  done
  return 1
}
wait_working() {
  local status _
  for _ in $(seq 1 320); do
    status=$(agent_status)
    [ "$status" = working ] && return 0
    sleep 0.1
  done
  return 1
}
wait_insert() {
  local pane _
  for _ in $(seq 1 80); do
    pane=$(capture 2>/dev/null || true)
    printf '%s' "$pane" | grep -Fq -- '-- INSERT' && return 0
    sleep 0.1
  done
  return 1
}
ensure_insert() {
  wait_insert && return 0
  "$LAB_HELPER" run "$SESSION" pane send-keys "$PANE" i >/dev/null
  wait_insert
}
wait_prompt_text() {  # <text>
  local want=$1 pane normalized _
  for _ in $(seq 1 160); do
    pane=$(capture 2>/dev/null || true)
    normalized=$(printf '%s' "$pane" | tr '\n' ' ' | tr -s '[:space:]' ' ')
    printf '%s' "$normalized" | grep -Fq "❯ $want" && return 0
    sleep 0.1
  done
  return 1
}

# Accept only the disposable project's trust dialog when it appears.
for _ in $(seq 1 240); do
  pane=$(capture 2>/dev/null || true)
  if printf '%s' "$pane" | grep -Fq 'Yes, I trust this folder'; then
    "$LAB_HELPER" run "$SESSION" pane send-keys "$PANE" enter >/dev/null
    break
  fi
  printf '%s' "$pane" | grep -Fq -- '-- INSERT' && break
  sleep 0.25
done
wait_idle || fail "real Claude did not become idle after startup"
ensure_insert || fail "real Claude did not expose Vim Insert mode"

run_busy_recovery_case() {  # <case-name> <pre-escape-count> <expected-recovery-escapes>
  local name=$1 pre_escape=$2 expected_escapes=$3 prompt pending out rc=0 i
  prompt="Use the Bash tool to run sleep 45, then reply ${name}_DONE. Start the tool immediately."
  pending="STOP SLEEP AND REPLY ${name}_RECOVERED"
  ensure_insert || fail "$name: could not establish Insert mode before the busy prompt"
  "$LAB_HELPER" run "$SESSION" pane send-text "$PANE" "$prompt" >/dev/null
  "$LAB_HELPER" run "$SESSION" pane send-keys "$PANE" enter >/dev/null
  wait_working || fail "$name: Claude did not become genuinely busy"
  ensure_insert || fail "$name: busy composer did not remain in Insert mode"
  "$LAB_HELPER" run "$SESSION" pane send-text "$PANE" "$pending" >/dev/null
  sleep 0.3
  i=0
  while [ "$i" -lt "$pre_escape" ]; do
    "$LAB_HELPER" run "$SESSION" pane send-keys "$PANE" escape >/dev/null
    i=$((i + 1))
  done
  sleep 0.3
  : > "$HERDR_LOG"
  out=$(PATH="$FAKEBIN:$ORIGINAL_PATH" FM_HOME="$HOME_DIR" FM_GATE_REFUSE_BYPASS=1 \
    FM_SEND_SETTLE=0 FM_SEND_RETRIES=2 FM_SEND_SLEEP=0.3 \
    "$ROOT/bin/fm-send.sh" recovery --recover-claude-vim 2> "$TMP_ROOT/$name.err") || rc=$?
  expect_code 0 "$rc" "$name: recovery command should succeed"
  [ "$out" = submitted-pending ] || fail "$name: recovery returned '$out'"
  [ "$(grep -c 'pane send-text' "$HERDR_LOG" || true)" -eq 0 ] || fail "$name: recovery retyped pending text"
  [ "$(grep -c 'pane send-keys .* escape' "$HERDR_LOG" || true)" -eq "$expected_escapes" ] \
    || fail "$name: recovery sent the wrong number of targeted Escapes"
  [ "$(grep -c 'pane send-keys .* enter' "$HERDR_LOG" || true)" -eq 1 ] \
    || fail "$name: recovery did not continue with exactly one Enter"
  wait_prompt_text "$pending" || fail "$name: preserved pending instruction did not reach Claude intact"
  wait_idle || fail "$name: Claude did not finish the recovered instruction"
  pass "real Claude Vim/Herdr: $name recovery proves interruption, preserves pending text, and submits with Enter only"
}

run_busy_recovery_case insert-mode 0 2
run_busy_recovery_case normal-mode 1 1
version_json=$("$LAB_HELPER" run "$SESSION" status --json)
printf 'evidence: claude=%s herdr=%s protocol=%s fleet-session=%s\n' \
  "$(claude --version | head -1)" \
  "$(printf '%s' "$version_json" | jq -r '.client.version')" \
  "$(printf '%s' "$version_json" | jq -r '.client.protocol')" \
  "${HERDR_SESSION:-default}"
