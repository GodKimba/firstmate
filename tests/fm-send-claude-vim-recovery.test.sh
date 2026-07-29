#!/usr/bin/env bash
# Deterministic Claude Vim interruption recovery through fm-send.
# The fake Herdr pane models the live-observed modal sequence: Insert consumes
# the first Escape into Normal, Normal consumes the next Escape as interruption,
# and only a fresh `Interrupted · What should Claude do instead?` render proves
# the running turn stopped. Pending composer text is state outside the key log,
# so the tests can prove recovery never retypes or edits it before Enter.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SEND="$ROOT/bin/fm-send.sh"
TMP_ROOT=$(fm_test_tmproot fm-send-claude-vim-recovery)
FAKEBIN=$(fm_fakebin "$TMP_ROOT")

cat > "$FAKEBIN/herdr" <<'SH'
#!/usr/bin/env bash
set -eu
state=${FM_FAKE_CLAUDE_STATE:?}
log=${FM_FAKE_CLAUDE_LOG:?}
printf '%s\n' "$*" >> "$log"

if [ "${1:-}" = status ] && [ "${2:-}" = --json ]; then
  printf '%s\n' '{"client":{"version":"0.7.5","protocol":14},"server":{"running":true}}'
  exit 0
fi

cmd="${1:-} ${2:-}"
case "$cmd" in
  "pane get")
    printf '%s\n' '{"result":{"pane":{"pane_id":"w1:p1"}}}'
    ;;
  "agent get")
    printf '{"result":{"agent":{"agent":"claude","agent_status":"%s"}}}\n' "$(cat "$state/agent")"
    ;;
  "pane read")
    mode=$(cat "$state/mode")
    composer=$(cat "$state/composer")
    draft=$(cat "$state/draft")
    printf 'Claude worker\n'
    [ "${FM_FAKE_STALE_INSERT_MARKER:-0}" != 1 ] || printf '%s\n' '  -- INSERT --'
    [ ! -f "$state/tool-interrupted-literal" ] \
      || printf '%s\n' 'Interrupted · What should Claude do instead?'
    case "$mode" in
      interrupted|stale) printf '  ⎿  Interrupted · What should Claude do instead?\n' ;;
    esac
    printf '%s\n' '────────────────────────────────────────'
    if [ "$composer" = pending ]; then printf '❯ %s\n' "$draft"; else printf '❯\n'; fi
    printf '%s\n' '────────────────────────────────────────'
    [ "$mode" != insert ] || printf '%s\n' '  -- INSERT --'
    ;;
  "pane send-text")
    printf '%s' "${4:-}" > "$state/draft"
    printf '%s\n' pending > "$state/composer"
    printf '%s\n' insert > "$state/mode"
    ;;
  "pane send-keys")
    key=${4:-}
    case "$key" in
      escape)
        mode=$(cat "$state/mode")
        case "$mode" in
          insert)
            printf '%s\n' normal > "$state/mode"
            [ "${FM_FAKE_TOOL_INTERRUPTED_LITERAL:-0}" != 1 ] \
              || : > "$state/tool-interrupted-literal"
            ;;
          normal)
            printf '%s\n' interrupted > "$state/mode"
            printf '%s\n' idle > "$state/agent"
            ;;
          stale|no-proof) : ;;
        esac
        ;;
      i)
        if [ "$(cat "$state/mode")" = interrupted ] \
           && [ "${FM_FAKE_I_STAYS_NORMAL:-0}" != 1 ]; then
          printf '%s\n' insert > "$state/mode"
        fi
        ;;
      enter)
        if [ "${FM_FAKE_ENTER_STAYS_PENDING:-0}" != 1 ]; then
          printf '%s\n' empty > "$state/composer"
          printf '%s\n' working > "$state/agent"
        fi
        ;;
    esac
    ;;
esac
SH
chmod +x "$FAKEBIN/herdr"

cat > "$FAKEBIN/tmux" <<'SH'
#!/usr/bin/env bash
set -eu
state=${FM_FAKE_CLAUDE_STATE:?}
log=${FM_FAKE_CLAUDE_LOG:?}
printf '%s\n' "$*" >> "$log"
case "${1:-}" in
  display-message)
    case "$*" in *cursor_y*) printf '%s\n' 3 ;; *) printf '%s\n' '%1' ;; esac
    ;;
  capture-pane)
    mode=$(cat "$state/mode")
    composer=$(cat "$state/composer")
    draft=$(cat "$state/draft")
    row='❯'
    [ "$composer" != pending ] || row="❯ $draft"
    case " $* " in
      *' -S 3 -E 3 '*) printf '%s\n' "$row" ;;
      *)
        printf 'Claude worker\n'
        [ "${FM_FAKE_STALE_INSERT_MARKER:-0}" != 1 ] || printf '%s\n' '-- INSERT --'
        [ ! -f "$state/tool-interrupted-literal" ] \
          || printf '%s\n' 'Interrupted · What should Claude do instead?'
        case "$mode" in interrupted|stale) printf '  ⎿  Interrupted · What should Claude do instead?\n' ;; *) printf '\n' ;; esac
        printf '\n%s\n' "$row"
        [ "${FM_FAKE_TMUX_BUSY:-0}" != 1 ] || printf '%s\n' 'esc to interrupt'
        [ "$mode" != insert ] || printf '%s\n' '-- INSERT --'
        ;;
    esac
    ;;
  send-keys)
    shift
    literal=0
    while [ "$#" -gt 0 ]; do
      case "$1" in -t) shift 2 ;; -l) literal=1; shift ;; *) break ;; esac
    done
    key=${1:-}
    if [ "$literal" -eq 1 ]; then
      printf '%s' "$key" > "$state/draft"
      printf '%s\n' pending > "$state/composer"
      printf '%s\n' insert > "$state/mode"
    else
      case "$key" in
        Escape)
          mode=$(cat "$state/mode")
          case "$mode" in
            insert)
              printf '%s\n' normal > "$state/mode"
              [ "${FM_FAKE_TOOL_INTERRUPTED_LITERAL:-0}" != 1 ] \
                || : > "$state/tool-interrupted-literal"
              ;;
            normal)
              printf '%s\n' interrupted > "$state/mode"
              printf '%s\n' idle > "$state/agent"
              ;;
          esac
          ;;
        i)
          if [ "$(cat "$state/mode")" = interrupted ] \
             && [ "${FM_FAKE_I_STAYS_NORMAL:-0}" != 1 ]; then
            printf '%s\n' insert > "$state/mode"
          fi
          ;;
        Enter)
          if [ "${FM_FAKE_TMUX_ENTER_STAYS_PENDING:-0}" != 1 ]; then
            printf '%s\n' empty > "$state/composer"
            printf '%s\n' working > "$state/agent"
          fi
          ;;
      esac
    fi
    ;;
esac
SH
chmod +x "$FAKEBIN/tmux"

cat > "$FAKEBIN/sleep" <<'SH'
#!/usr/bin/env bash
exit 0
SH
chmod +x "$FAKEBIN/sleep"

make_case() {  # <name> <mode> <composer> [harness] [backend]
  CASE_DIR="$TMP_ROOT/$1"
  HOME_DIR="$CASE_DIR/home"
  STATE_DIR="$CASE_DIR/pane-state"
  LOG="$CASE_DIR/herdr.log"
  mkdir -p "$HOME_DIR/state" "$HOME_DIR/config" "$STATE_DIR"
  : > "$LOG"
  printf '%s\n' "$2" > "$STATE_DIR/mode"
  printf '%s\n' "$3" > "$STATE_DIR/composer"
  printf '%s' 'pending α  bytes' > "$STATE_DIR/draft"
  printf '%s\n' working > "$STATE_DIR/agent"
  target=lab:w1:p1
  [ "${5:-herdr}" != tmux ] || target=lab:win
  cat > "$HOME_DIR/state/task.meta" <<EOF
window=$target
backend=${5:-herdr}
harness=${4:-claude}
kind=ship
EOF
  touch "$HOME_DIR/state/.last-watcher-beat"
}

run_recovery() {
  PATH="$FAKEBIN:$PATH" FM_HOME="$HOME_DIR" FM_ROOT_OVERRIDE="$HOME_DIR" \
    FM_STATE_OVERRIDE="$HOME_DIR/state" FM_GATE_REFUSE_BYPASS=1 \
    FM_FAKE_CLAUDE_STATE="$STATE_DIR" FM_FAKE_CLAUDE_LOG="$LOG" \
    FM_SEND_INTERRUPT_SLEEP=0 FM_SEND_SLEEP=0 FM_SEND_RETRIES="${FM_TEST_RETRIES:-3}" \
    FM_BACKEND_HERDR_SUBMIT_MIN_SLEEP=0 FM_BACKEND_HERDR_SUBMIT_POLLS=1 \
    FM_FAKE_ENTER_STAYS_PENDING="${FM_FAKE_ENTER_STAYS_PENDING:-0}" \
    FM_FAKE_STALE_INSERT_MARKER="${FM_FAKE_STALE_INSERT_MARKER:-0}" \
    FM_FAKE_TOOL_INTERRUPTED_LITERAL="${FM_FAKE_TOOL_INTERRUPTED_LITERAL:-0}" \
    FM_FAKE_I_STAYS_NORMAL="${FM_FAKE_I_STAYS_NORMAL:-0}" \
    FM_FAKE_TMUX_BUSY="${FM_FAKE_TMUX_BUSY:-0}" \
    FM_FAKE_TMUX_ENTER_STAYS_PENDING="${FM_FAKE_TMUX_ENTER_STAYS_PENDING:-0}" \
    "$SEND" task --recover-claude-vim
}

key_count() { grep -c "pane send-keys w1:p1 $1" "$LOG" 2>/dev/null || true; }
text_count() { grep -c 'pane send-text w1:p1' "$LOG" 2>/dev/null || true; }

test_insert_mode_needs_two_targeted_escapes_then_enter_only() {
  local out before after
  make_case insert-pending insert pending
  before=$(cat "$STATE_DIR/draft")
  out=$(run_recovery 2> "$CASE_DIR/err") || fail "Insert-mode pending recovery failed: $(cat "$CASE_DIR/err")"
  after=$(cat "$STATE_DIR/draft")
  [ "$out" = submitted-pending ] || fail "Insert-mode recovery returned '$out'"
  [ "$(key_count escape)" -eq 2 ] || fail "Insert mode must consume exactly two targeted Escapes"
  [ "$(key_count enter)" -eq 1 ] || fail "pending recovery must continue with one Enter after proof"
  [ "$(text_count)" -eq 0 ] || fail "pending recovery retyped composer text"
  [ "$before" = "$after" ] || fail "pending recovery changed the preserved composer bytes"
  pass "fm-send Claude Vim recovery: Insert -> Normal -> fresh Interrupted, then Enter only with pending bytes preserved"
}

test_tmux_uses_the_same_proof_and_enter_only_contract() {
  local out
  make_case tmux-insert-pending insert pending claude tmux
  out=$(run_recovery 2> "$CASE_DIR/err") || fail "tmux Insert-mode recovery failed: $(cat "$CASE_DIR/err")"
  [ "$out" = submitted-pending ] || fail "tmux recovery returned '$out'"
  [ "$(grep -c 'send-keys -t lab:win Escape' "$LOG" 2>/dev/null || true)" -eq 2 ] \
    || fail "tmux recovery did not perform the two modal Escapes"
  [ "$(grep -c 'send-keys -t lab:win Enter' "$LOG" 2>/dev/null || true)" -eq 1 ] \
    || fail "tmux pending recovery did not continue with one Enter"
  [ "$(grep -c 'send-keys -t lab:win -l' "$LOG" 2>/dev/null || true)" -eq 0 ] \
    || fail "tmux pending recovery retyped the instruction"
  pass "fm-send Claude Vim recovery: tmux shares the fresh-proof and Enter-only contract"
}

test_normal_mode_needs_one_escape_then_enter_only() {
  local out
  make_case normal-pending normal pending
  out=$(run_recovery 2> "$CASE_DIR/err") || fail "Normal-mode pending recovery failed: $(cat "$CASE_DIR/err")"
  [ "$out" = submitted-pending ] || fail "Normal-mode recovery returned '$out'"
  [ "$(key_count escape)" -eq 1 ] || fail "Normal mode must need exactly one targeted Escape"
  [ "$(key_count enter)" -eq 1 ] || fail "Normal-mode pending recovery must submit with Enter only"
  [ "$(text_count)" -eq 0 ] || fail "Normal-mode recovery retyped the instruction"
  pass "fm-send Claude Vim recovery: Normal -> fresh Interrupted with one Escape and Enter-only continuation"
}

test_empty_composer_interrupts_without_enter_or_redirect_typing() {
  local out
  make_case insert-empty insert empty
  out=$(run_recovery 2> "$CASE_DIR/err") || fail "empty-composer recovery failed: $(cat "$CASE_DIR/err")"
  [ "$out" = interrupted ] || fail "empty recovery returned '$out'"
  [ "$(key_count escape)" -eq 2 ] || fail "empty Insert-mode recovery lost the modal transition"
  [ "$(key_count enter)" -eq 0 ] || fail "empty recovery pressed Enter without a pending instruction"
  [ "$(key_count i)" -eq 1 ] || fail "empty recovery did not restore Insert mode exactly once after interruption"
  [ "$(text_count)" -eq 0 ] || fail "empty recovery typed the redirect before interruption proof"
  [ "$(cat "$STATE_DIR/mode")" = insert ] || fail "empty recovery returned without proven Insert mode"
  pass "fm-send Claude Vim recovery: an empty composer restores proven Insert mode after interruption before redirection"
}

test_empty_normal_or_non_vim_shape_refuses_before_keys() {
  local rc=0
  make_case empty-normal-ambiguous normal empty
  run_recovery > "$CASE_DIR/out" 2> "$CASE_DIR/err" || rc=$?
  [ "$rc" -ne 0 ] || fail "an empty composer without Insert proof unexpectedly entered recovery"
  [ "$(key_count escape)" -eq 0 ] && [ "$(key_count enter)" -eq 0 ] && [ "$(key_count i)" -eq 0 ] \
    || fail "ambiguous empty Normal/non-Vim shape sent a key"
  assert_contains "$(cat "$CASE_DIR/err")" "requires a positive Insert-mode marker" \
    "ambiguous empty mode refusal did not name the missing proof"
  pass "fm-send Claude Vim recovery: empty Normal/non-Vim ambiguity refuses before sending a key"
}

test_stale_insert_marker_cannot_prove_current_mode() {
  local rc=0
  make_case stale-insert-before normal empty
  FM_FAKE_STALE_INSERT_MARKER=1 run_recovery > "$CASE_DIR/out" 2> "$CASE_DIR/err" || rc=$?
  [ "$rc" -ne 0 ] || fail "a stale Insert marker admitted empty-composer recovery"
  [ "$(key_count escape)" -eq 0 ] && [ "$(key_count i)" -eq 0 ] \
    || fail "a stale pre-recovery Insert marker caused key input"

  rc=0
  make_case stale-insert-after insert empty
  FM_FAKE_STALE_INSERT_MARKER=1 FM_FAKE_I_STAYS_NORMAL=1 \
    run_recovery > "$CASE_DIR/out" 2> "$CASE_DIR/err" || rc=$?
  [ "$rc" -ne 0 ] || fail "a stale Insert marker falsely proved restoration after a swallowed i"
  [ "$(key_count escape)" -eq 2 ] || fail "swallowed-i fixture did not reach proven interruption"
  [ "$(key_count i)" -eq 1 ] || fail "swallowed-i fixture did not attempt one restoration key"
  [ "$(cat "$STATE_DIR/mode")" = interrupted ] || fail "swallowed-i fixture unexpectedly entered Insert mode"
  pass "fm-send Claude Vim recovery: only the current footer can prove Insert mode"
}

test_stale_or_absent_interrupted_text_is_not_proof() {
  local rc=0
  make_case stale-proof stale pending
  run_recovery > "$CASE_DIR/out" 2> "$CASE_DIR/err" || rc=$?
  [ "$rc" -ne 0 ] || fail "a stale Interrupted transcript was accepted as fresh proof"
  [ "$(key_count escape)" -eq 0 ] || fail "a pre-existing current Interrupted render caused key input"
  [ "$(key_count enter)" -eq 0 ] || fail "stale proof caused Enter submission"

  rc=0
  make_case absent-proof no-proof pending
  run_recovery > "$CASE_DIR/out" 2> "$CASE_DIR/err" || rc=$?
  [ "$rc" -ne 0 ] || fail "absent Interrupted proof unexpectedly succeeded"
  [ "$(key_count escape)" -eq 2 ] || fail "absent proof recovery exceeded or missed the two-Escape budget"
  [ "$(key_count enter)" -eq 0 ] || fail "absent proof caused Enter submission"
  pass "fm-send Claude Vim recovery: stale/absent Interrupted text never licenses continuation"
}

test_tmux_tool_output_cannot_forge_interrupted_render() {
  local out
  make_case tmux-tool-literal insert pending claude tmux
  out=$(FM_FAKE_TOOL_INTERRUPTED_LITERAL=1 run_recovery 2> "$CASE_DIR/err") \
    || fail "tmux tool-literal recovery failed: $(cat "$CASE_DIR/err")"
  [ "$out" = submitted-pending ] || fail "tmux tool-literal recovery returned '$out'"
  [ "$(grep -c 'send-keys -t lab:win Escape' "$LOG" 2>/dev/null || true)" -eq 2 ] \
    || fail "ordinary tool output falsely satisfied the fresh interruption proof"
  [ "$(grep -c 'send-keys -t lab:win Enter' "$LOG" 2>/dev/null || true)" -eq 1 ] \
    || fail "tool-literal recovery did not preserve one Enter-only continuation"
  pass "fm-send Claude Vim recovery: ordinary tool output cannot forge Claude interruption proof"
}

test_inconclusive_enter_only_submit_refuses_without_retyping() {
  local rc=0
  make_case pending-inconclusive normal pending
  FM_FAKE_ENTER_STAYS_PENDING=1 FM_TEST_RETRIES=2 run_recovery > "$CASE_DIR/out" 2> "$CASE_DIR/err" || rc=$?
  [ "$rc" -ne 0 ] || fail "an inconclusive Enter-only continuation reported success"
  [ "$(key_count enter)" -eq 2 ] || fail "inconclusive continuation did not use the bounded Enter-only retry budget"
  [ "$(text_count)" -eq 0 ] || fail "inconclusive continuation retyped pending text"
  [ "$(cat "$STATE_DIR/composer")" = pending ] || fail "inconclusive continuation did not preserve pending state"
  assert_contains "$(cat "$CASE_DIR/err")" "text was not retyped" \
    "inconclusive refusal did not preserve the no-retype consequence"
  pass "fm-send Claude Vim recovery: inconclusive continuation refuses after bounded Enter-only retries"
}

test_tmux_pending_submit_sends_one_enter_and_requires_clearing() {
  local rc=0
  make_case tmux-busy-stale normal pending claude tmux
  FM_FAKE_TMUX_BUSY=1 FM_FAKE_TMUX_ENTER_STAYS_PENDING=1 FM_TEST_RETRIES=3 \
    run_recovery > "$CASE_DIR/out" 2> "$CASE_DIR/err" || rc=$?
  [ "$rc" -ne 0 ] || fail "a stale busy footer falsely confirmed tmux pending submission"
  [ "$(grep -c 'send-keys -t lab:win Enter' "$LOG" 2>/dev/null || true)" -eq 1 ] \
    || fail "strict tmux continuation must send exactly one Enter"
  [ "$(grep -c 'send-keys -t lab:win -l' "$LOG" 2>/dev/null || true)" -eq 0 ] \
    || fail "strict tmux continuation retyped the pending instruction"
  [ "$(cat "$STATE_DIR/composer")" = pending ] \
    || fail "strict tmux refusal did not preserve the ambiguous pending composer"
  pass "fm-send Claude Vim recovery: tmux requires actual clearing after exactly one Enter"
}

test_non_claude_and_unsupported_backends_refuse_before_keys() {
  local rc=0
  make_case non-claude normal pending codex herdr
  run_recovery > "$CASE_DIR/out" 2> "$CASE_DIR/err" || rc=$?
  [ "$rc" -ne 0 ] || fail "non-Claude recovery unexpectedly succeeded"
  [ ! -s "$LOG" ] || fail "non-Claude recovery reached the backend"

  rc=0
  make_case unsupported-backend normal pending claude zellij
  run_recovery > "$CASE_DIR/out" 2> "$CASE_DIR/err" || rc=$?
  [ "$rc" -ne 0 ] || fail "unsupported-backend recovery unexpectedly succeeded"
  [ ! -s "$LOG" ] || fail "unsupported-backend recovery sent or read anything"
  pass "fm-send Claude Vim recovery: non-Claude and unsupported backends are unchanged and refused before input"
}

test_ordinary_send_path_remains_unchanged() {
  local out rc=0
  make_case ordinary-send insert empty claude herdr
  PATH="$FAKEBIN:$PATH" FM_HOME="$HOME_DIR" FM_ROOT_OVERRIDE="$HOME_DIR" \
    FM_STATE_OVERRIDE="$HOME_DIR/state" FM_GATE_REFUSE_BYPASS=1 \
    FM_FAKE_CLAUDE_STATE="$STATE_DIR" FM_FAKE_CLAUDE_LOG="$LOG" \
    FM_SEND_SLEEP=0 FM_SEND_SETTLE=0 FM_BACKEND_HERDR_SUBMIT_MIN_SLEEP=0 \
    FM_BACKEND_HERDR_SUBMIT_POLLS=1 \
    "$SEND" task 'ordinary non-recovery instruction' > "$CASE_DIR/out" 2> "$CASE_DIR/err" || rc=$?
  expect_code 0 "$rc" "ordinary send should remain successful"
  out=$(cat "$LOG")
  assert_contains "$out" 'pane send-text w1:p1 ordinary non-recovery instruction' \
    "ordinary send no longer types its instruction"
  [ "$(key_count escape)" -eq 0 ] || fail "ordinary send unexpectedly invoked Vim recovery"
  [ "$(key_count enter)" -eq 1 ] || fail "ordinary send no longer submits once"
  pass "fm-send Claude Vim recovery: ordinary non-recovery sends retain their existing behavior"
}

test_insert_mode_needs_two_targeted_escapes_then_enter_only
test_tmux_uses_the_same_proof_and_enter_only_contract
test_normal_mode_needs_one_escape_then_enter_only
test_empty_composer_interrupts_without_enter_or_redirect_typing
test_empty_normal_or_non_vim_shape_refuses_before_keys
test_stale_insert_marker_cannot_prove_current_mode
test_stale_or_absent_interrupted_text_is_not_proof
test_tmux_tool_output_cannot_forge_interrupted_render
test_inconclusive_enter_only_submit_refuses_without_retyping
test_tmux_pending_submit_sends_one_enter_and_requires_clearing
test_non_claude_and_unsupported_backends_refuse_before_keys
test_ordinary_send_path_remains_unchanged
