#!/usr/bin/env bash
# tests/fm-decision-answer-authority.test.sh - regression: a keyed decision may be
# closed only by a correlated answer minted after that request opened.
#
# The defect this pins: a generic command submitted while the worker was busy stays
# queued in the composer, is delivered after the worker opens a keyed
# needs-decision, and was then consumed as if it answered that decision. Both
# layers are exercised here - the transport that queues the early command, and the
# fold that must refuse to treat it as approval.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# shellcheck source=/dev/null
. "$ROOT/bin/fm-classify-lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-decision-answer-authority)

new_case() {  # <name> -> case dir with a state/ dir
  local d="$TMP_ROOT/$1"
  mkdir -p "$d/state"
  printf '%s' "$d"
}

open_set() {  # <status-file> -> fold output with tabs made visible
  status_open_decisions "$1" | tr '\t' '|'
}

# Mint through the same owner fm-send uses, against an already-open request.
mint_for() {  # <status-file> <key> <summary> -> token
  local f=$1 key=$2 summary=$3 token
  token=$(fm_decision_mint_answer_token) || fail "could not mint an answer token"
  fm_decision_record_answer "$(fm_decision_answers_file "$f")" "$token" "$key" "$summary" \
    || fail "could not record the answer token"
}

# --- the incident ordering --------------------------------------------------

test_pre_request_generic_command_never_answers() {
  local d f out
  d=$(new_case incident)
  f="$d/state/task.status"
  {
    printf 'working: running the test suite\n'
    printf 'needs-decision [key=red-test]: accept the red integration test, or keep fixing?\n'
    printf 'resolved [key=red-test]: proceeding on the queued /no-mistakes instruction\n'
  } > "$f"
  out=$(open_set "$f")
  assert_contains "$out" "red-test|needs-decision|" \
    "an uncorrelated resolution closed a decision it was never authorized to close"
  # The worker also advanced past it: the decision must still surface afterwards.
  printf 'done: merged after advancing on the queued command\n' >> "$f"
  out=$(open_set "$f")
  assert_contains "$out" "red-test|needs-decision|" \
    "a later terminal line must not bury the still-open decision"
  pass "a command composed before the request opened never becomes its approval"
}

test_queued_generic_command_reaches_a_busy_worker_unchanged() {
  local d fakebin composer sent vfile
  d=$(new_case busy-delivery)
  fakebin=$(fm_fakebin "$d")
  composer="$d/composer"
  sent="$d/sent.log"
  vfile="$d/verdict"
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
set -u
COMPOSER="${FM_FAKE_COMPOSER:?}"
case "${1:-}" in
  display-message)
    for a in "$@"; do case "$a" in *cursor_y*) printf '1\n'; exit 0 ;; esac; done
    exit 0 ;;
  capture-pane) cat "$COMPOSER" 2>/dev/null; exit 0 ;;
  send-keys)
    shift; is_enter=0
    while [ "$#" -gt 0 ]; do
      case "$1" in -t) shift ;; -l) ;; Enter) is_enter=1 ;; esac; shift
    done
    [ "$is_enter" = 1 ] && [ -n "${FM_FAKE_SENT:-}" ] && printf 'Enter\n' >> "$FM_FAKE_SENT"
    exit 0 ;;
  list-windows) exit 0 ;;
esac
exit 1
SH
  chmod +x "$fakebin/tmux"
  printf '╭────────────────╮\n│ > /no-mistakes │\n╰────────────────╯\n' > "$composer"
  : > "$sent"
  (
    # shellcheck source=/dev/null
    . "$ROOT/bin/fm-tmux-lib.sh"
    # shellcheck disable=SC2329 # Invoked indirectly by the submit core under test.
    fm_pane_is_busy() { return 0; }
    PATH="$fakebin:$PATH" FM_FAKE_COMPOSER="$composer" FM_FAKE_SENT="$sent" \
      fm_tmux_submit_enter_core "win" 3 0.05 > "$vfile" 2>/dev/null
  ) || fail "busy-worker submit failed outright"
  [ "$(cat "$vfile")" = empty ] \
    || fail "ordinary delivery to a busy worker regressed, got '$(cat "$vfile")'"
  pass "a plain message to a busy worker is still accepted and queued"
}

# --- the valid post-request correlated response ------------------------------

test_correlated_answer_after_the_request_closes_it() {
  local d f token out
  d=$(new_case correlated)
  f="$d/state/task.status"
  printf 'needs-decision [key=red-test]: accept the red test, or keep fixing?\n' > "$f"
  token=$(mint_for "$f" red-test "accept the red test, or keep fixing?")
  printf 'resolved [key=red-test] [ans=%s]: captain chose keep fixing\n' "$token" >> "$f"
  out=$(open_set "$f")
  [ -z "$out" ] || fail "a correlated answer failed to close its decision: $out"
  pass "an answer minted after the request opened closes exactly that request"
}

test_answer_cannot_be_minted_before_its_request_opens() {
  local d f token
  d=$(new_case no-early-mint)
  f="$d/state/task.status"
  printf 'working: still deciding whether to ask\n' > "$f"
  # Nothing is open, so the fold has no summary to bind an answer to. A token
  # minted against the wrong summary cannot close the request that opens later.
  token=$(mint_for "$f" red-test "a summary nobody has written yet")
  printf 'needs-decision [key=red-test]: accept the red test, or keep fixing?\n' >> "$f"
  printf 'resolved [key=red-test] [ans=%s]: replayed an early token\n' "$token" >> "$f"
  assert_contains "$(open_set "$f")" "red-test|needs-decision|" \
    "a token minted before the request existed closed it anyway"
  pass "a token bound to a different request instance never closes a later one"
}

test_reopened_decision_needs_a_fresh_answer() {
  local d f token out
  d=$(new_case reopened)
  f="$d/state/task.status"
  printf 'needs-decision [key=scope]: ship the narrow fix, or the broad one?\n' > "$f"
  token=$(mint_for "$f" scope "ship the narrow fix, or the broad one?")
  printf 'resolved [key=scope] [ans=%s]: captain chose narrow\n' "$token" >> "$f"
  out=$(open_set "$f")
  [ -z "$out" ] || fail "pre-check: the first correlated answer should have closed it"
  # The same key opens again with a different question; the spent token must not
  # close it.
  printf 'needs-decision [key=scope]: the narrow fix regressed - widen it now?\n' >> "$f"
  printf 'resolved [key=scope] [ans=%s]: reused the spent token\n' "$token" >> "$f"
  assert_contains "$(open_set "$f")" "scope|needs-decision|the narrow fix regressed" \
    "a spent answer token closed a later request under the same key"
  pass "reopening a key requires a freshly minted answer"
}

# --- unrelated keys ----------------------------------------------------------

test_answer_for_another_key_does_not_transfer() {
  local d f token out
  d=$(new_case other-key)
  f="$d/state/task.status"
  {
    printf 'needs-decision [key=red-test]: accept the red test?\n'
    printf 'needs-decision [key=api-shape]: one endpoint, or two?\n'
  } > "$f"
  token=$(mint_for "$f" api-shape "one endpoint, or two?")
  printf 'resolved [key=red-test] [ans=%s]: borrowed the other decision token\n' "$token" >> "$f"
  out=$(open_set "$f")
  assert_contains "$out" "red-test|needs-decision|" \
    "an answer minted for another key closed this one"
  assert_contains "$out" "api-shape|needs-decision|" \
    "the key the token actually belongs to was closed without its own resolution"
  # Its own correlated resolution still closes only itself.
  printf 'resolved [key=api-shape] [ans=%s]: captain chose two\n' "$token" >> "$f"
  out=$(open_set "$f")
  assert_contains "$out" "red-test|needs-decision|" "the unrelated decision must stay open"
  assert_not_contains "$out" "api-shape" "the answered decision should have closed"
  pass "an answer token is scoped to the one key it was minted for"
}

# --- generic commands and unkeyed input --------------------------------------

test_generic_and_unkeyed_input_never_closes_a_decision() {
  local d f out
  d=$(new_case generic)
  f="$d/state/task.status"
  {
    printf 'needs-decision [key=red-test]: accept the red test?\n'
    printf 'working: acting on /no-mistakes\n'
    printf 'resolved: assuming the earlier instruction covered it\n'
    printf 'resolved [key=red-test]: no token at all\n'
  } > "$f"
  out=$(open_set "$f")
  assert_contains "$out" "red-test|needs-decision|" \
    "an unkeyed or untokenized resolution closed a keyed decision"
  # A stray token that was never minted is equally powerless.
  printf 'resolved [key=red-test] [ans=deadbeefdeadbeef]: invented a token\n' >> "$f"
  assert_contains "$(open_set "$f")" "red-test|needs-decision|" \
    "an unminted token closed a decision"
  pass "generic commands, unkeyed lines, and invented tokens are never approval"
}

# --- preserved existing closure paths ----------------------------------------

test_blocked_and_captain_held_closure_are_unchanged() {
  local d f out
  d=$(new_case preserved)
  f="$d/state/blocked.status"
  # A blocker clears by being fixed, not by authority: no token required.
  printf 'blocked [key=infra]: no credentials for the staging bucket\n' > "$f"
  printf 'resolved [key=infra]: credentials issued, resuming\n' >> "$f"
  out=$(open_set "$f")
  [ -z "$out" ] || fail "a keyed blocker no longer clears on a plain resolution: $out"
  # Legacy unkeyed blockers keep the historical default-key behavior.
  printf 'blocked: waiting on infra\nresolved: infra access granted\n' > "$f"
  out=$(open_set "$f")
  [ -z "$out" ] || fail "an unkeyed blocker no longer clears: $out"
  # The verified backlog transfer still closes a decision without an answer token.
  f="$d/state/held.status"
  printf 'needs-decision [key=route]: north or south?\n' > "$f"
  printf 'captain-held [key=route]: tracked by held-decision-route\n' >> "$f"
  out=$(open_set "$f")
  [ -z "$out" ] || fail "a verified captain-held transfer no longer closes a decision: $out"
  pass "blocker clearance and captain-held transfer keep their existing closure paths"
}

test_answer_token_does_not_disturb_line_parsers() {
  local line
  line='resolved [key=red-test] [ans=3f2a91c07b4d6e58]: captain chose keep fixing'
  [ "$(status_line_verb "$line")" = resolved ] \
    || fail "the answer token broke verb parsing: '$(status_line_verb "$line")'"
  [ "$(status_line_note "$line")" = "captain chose keep fixing" ] \
    || fail "the answer token broke note parsing: '$(status_line_note "$line")'"
  status_is_captain_relevant "$line" \
    && fail "a correlated resolution must stay a nonterminal, non-captain-relevant event"
  # An [ans=] with no key is malformed: it must not silently become a default-key
  # event, and the verb must still parse so the line is classified, not mangled.
  line='resolved [ans=3f2a91c07b4d6e58]: no key at all'
  [ "$(status_line_verb "$line")" = resolved ] \
    || fail "a keyless answer token mangled the verb: '$(status_line_verb "$line")'"
  pass "the answer token is transparent to the shared single-line parsers"
}

test_pre_request_generic_command_never_answers
test_queued_generic_command_reaches_a_busy_worker_unchanged
test_correlated_answer_after_the_request_closes_it
test_answer_cannot_be_minted_before_its_request_opens
test_reopened_decision_needs_a_fresh_answer
test_answer_for_another_key_does_not_transfer
test_generic_and_unkeyed_input_never_closes_a_decision
test_blocked_and_captain_held_closure_are_unchanged
test_answer_token_does_not_disturb_line_parsers
