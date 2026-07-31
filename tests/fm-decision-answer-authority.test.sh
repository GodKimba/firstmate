#!/usr/bin/env bash
# tests/fm-decision-answer-authority.test.sh - regression: a token-era keyed
# decision may be closed only by a correlated answer minted after it opened.
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
  fm_decision_cutover_ensure_status "$d/state/task.status" \
    || fail "could not initialize a token-era status stream"
  printf '%s' "$d"
}

new_legacy_case() {  # <name> -> case dir without a cutover marker
  local d="$TMP_ROOT/$1"
  mkdir -p "$d/state"
  printf '%s' "$d"
}

open_set() {  # <status-file> -> fold output with tabs made visible
  status_open_decisions "$1" | tr '\t' '|'
}

# Mint through the same owner fm-send uses, against an already-open occurrence.
mint_for() {  # <status-file> <key> -> token
  local f=$1 key=$2 token instance d_key d_verb d_instance _d_summary
  instance=''
  while IFS=$'\t' read -r d_key d_verb d_instance _d_summary || [ -n "$d_key" ]; do
    [ "$d_key" = "$key" ] || continue
    [ "$d_verb" = needs-decision ] || continue
    instance=$d_instance
  done <<EOF
$(status_open_decisions "$f" --with-instance)
EOF
  [ -n "$instance" ] || fail "could not find open occurrence for $key"
  token=$(fm_decision_mint_answer_token "$instance") || fail "could not mint an answer token"
  fm_decision_record_answer "$(fm_decision_answers_file "$f")" "$token" "$key" "$instance" \
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
  } >> "$f"
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

test_settled_pre_cutover_history_stays_settled() {
  local d f out before
  d=$(new_legacy_case legacy-settled)
  f="$d/state/task.status"
  {
    printf 'needs-decision [key=route]: north or south?\n'
    printf 'resolved [key=route]: captain chose north\n'
    printf 'done: legacy task completed\n'
  } > "$f"
  before=$(cat "$f")
  fm_decision_cutover_ensure_status "$f" || fail "could not inspect settled legacy history"
  [ "$(cat "$f")" = "$before" ] || fail "status initialization rewrote settled legacy history"
  out=$(open_set "$f")
  [ -z "$out" ] || fail "settled pre-cutover history reopened: $out"
  [ "$(last_status_line "$f")" = "done: legacy task completed" ] \
    || fail "the cutover marker masked the last real status event"
  pass "settled unmarked history remains legacy-compatible and unchanged"
}

test_pre_cutover_opening_accepts_a_late_legacy_resolution() {
  local d f out
  d=$(new_legacy_case legacy-late)
  f="$d/state/task.status"
  printf 'needs-decision [key=route]: north or south?\n' > "$f"
  fm_decision_cutover_ensure_status "$f" || fail "could not inspect an open legacy request"
  printf 'resolved [key=route]: captain chose south after cutover\n' >> "$f"
  out=$(open_set "$f")
  [ -z "$out" ] || fail "a late legacy resolution did not close its pre-cutover opening: $out"
  pass "an unmarked opening remains closable by a late legacy resolution"
}

test_new_stream_markers_are_self_describing_and_unique() {
  local d first second reused first_id second_id reused_id old_occurrence new_occurrence
  d=$(new_legacy_case stream-markers)
  first="$d/state/foo.bar.status"
  second="$d/state/foo_bar.status"
  fm_decision_cutover_ensure_status "$first" || fail "could not initialize the first stream"
  fm_decision_cutover_ensure_status "$second" || fail "could not initialize the second stream"
  first_id=$(fm_decision_stream_id "$first") || fail "first marker did not identify its stream"
  second_id=$(fm_decision_stream_id "$second") || fail "second marker did not identify its stream"
  [ "$first_id" != "$second_id" ] || fail "distinct task ids received the same stream identity"
  reused="$d/state/reused.status"
  fm_decision_cutover_ensure_status "$reused" || fail "could not initialize the reusable stream"
  reused_id=$(fm_decision_stream_id "$reused") || fail "reusable marker was not self-describing"
  printf 'needs-decision [key=route]: choose a route\n' >> "$reused"
  old_occurrence=$(status_open_token_needs_decisions "$reused" | awk -F '\t' 'NR == 1 { print $2 }')
  rm -f "$reused"
  fm_decision_cutover_ensure_status "$reused" || fail "could not initialize the replacement stream"
  [ "$(fm_decision_stream_id "$reused")" != "$reused_id" ] \
    || fail "a replacement stream reused its retired identity"
  printf 'needs-decision [key=route]: choose a route\n' >> "$reused"
  new_occurrence=$(status_open_token_needs_decisions "$reused" | awk -F '\t' 'NR == 1 { print $2 }')
  [ "$new_occurrence" != "$old_occurrence" ] \
    || fail "a replacement stream reused its prior decision occurrence"
  pass "new streams carry unique self-describing token-era identities"
}

test_post_cutover_plain_resolution_is_rejected() {
  local d f out
  d=$(new_case strict-plain)
  f="$d/state/task.status"
  printf 'needs-decision [key=route]: north or south?\n' >> "$f"
  printf 'resolved [key=route]: a queued command was mistaken for approval\n' >> "$f"
  out=$(open_set "$f")
  assert_contains "$out" "route|needs-decision|" \
    "a post-cutover plain resolution closed a request for authority"
  pass "post-cutover decisions reject plain keyed resolutions"
}

test_correlated_answer_after_the_request_closes_it() {
  local d f token out
  d=$(new_case correlated)
  f="$d/state/task.status"
  printf 'needs-decision [key=red-test]: accept the red test, or keep fixing?\n' >> "$f"
  token=$(mint_for "$f" red-test)
  printf 'resolved [key=red-test] [ans=%s]: captain chose keep fixing\n' "$token" >> "$f"
  out=$(open_set "$f")
  [ -z "$out" ] || fail "a correlated answer failed to close its decision: $out"
  pass "an answer minted after the request opened closes exactly that request"
}

test_token_for_an_earlier_position_cannot_close_a_later_request() {
  local d f token instance
  d=$(new_case no-early-mint)
  f="$d/state/task.status"
  instance=$(fm_decision_instance_id 1)
  token=$(fm_decision_mint_answer_token "$instance") || fail "could not mint an early token"
  fm_decision_record_answer "$(fm_decision_answers_file "$f")" "$token" red-test "$instance" \
    >/dev/null \
    || fail "could not record the early token"
  {
    printf 'working: still deciding whether to ask\n'
    printf 'needs-decision [key=red-test]: accept the red test, or keep fixing?\n'
    printf 'resolved [key=red-test] [ans=%s]: replayed an early token\n' "$token"
  } >> "$f"
  assert_contains "$(open_set "$f")" "red-test|needs-decision|" \
    "a token minted before the request existed closed it anyway"
  pass "a token for an earlier stream position never closes a later request"
}

test_reopened_decision_needs_a_fresh_answer() {
  local d f token out
  d=$(new_case reopened)
  f="$d/state/task.status"
  printf 'needs-decision [key=scope]: ship the narrow fix, or the broad one?\n' >> "$f"
  token=$(mint_for "$f" scope)
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

test_identical_reopen_rejects_old_duplicate_and_retry_delivery() {
  local d f first retry current out
  d=$(new_case identical-reopen)
  f="$d/state/task.status"
  printf 'needs-decision [key=scope]: ship the narrow fix?\n' >> "$f"
  first=$(mint_for "$f" scope)
  retry=$(mint_for "$f" scope)
  printf 'resolved [key=scope] [ans=%s]: retry delivery answered the first occurrence\n' "$retry" >> "$f"
  [ -z "$(open_set "$f")" ] || fail "a retry token for the current occurrence did not close it"
  {
    printf 'resolved [key=scope] [ans=%s]: duplicate resolution delivery\n' "$retry"
    printf 'needs-decision [key=scope]: ship the narrow fix?\n'
    printf 'resolved [key=scope] [ans=%s]: delayed first response\n' "$first"
    printf 'resolved [key=scope] [ans=%s]: delayed retry response\n' "$retry"
  } >> "$f"
  out=$(open_set "$f")
  assert_contains "$out" "scope|needs-decision|ship the narrow fix?" \
    "an old response closed an identical reopened decision"
  current=$(mint_for "$f" scope)
  [ "${current:0:16}" != "${first:0:16}" ] \
    || fail "identical openings reused the same occurrence identifier"
  printf 'resolved [key=scope] [ans=%s]: answered the current occurrence\n' "$current" >> "$f"
  [ -z "$(open_set "$f")" ] || fail "the current occurrence's response did not close it"
  pass "identical reopens reject delayed duplicates while current retries remain valid"
}

# --- unrelated keys ----------------------------------------------------------

test_answer_for_another_key_does_not_transfer() {
  local d f token out
  d=$(new_case other-key)
  f="$d/state/task.status"
  {
    printf 'needs-decision [key=red-test]: accept the red test?\n'
    printf 'needs-decision [key=api-shape]: one endpoint, or two?\n'
  } >> "$f"
  token=$(mint_for "$f" api-shape)
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
  } >> "$f"
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
  fm_decision_cutover_ensure_status "$f" || fail "could not initialize the blocker stream"
  # A blocker clears by being fixed, not by authority: no token required.
  printf 'blocked [key=infra]: no credentials for the staging bucket\n' >> "$f"
  printf 'resolved [key=infra]: credentials issued, resuming\n' >> "$f"
  out=$(open_set "$f")
  [ -z "$out" ] || fail "a keyed blocker no longer clears on a plain resolution: $out"
  # Legacy unkeyed blockers keep the historical default-key behavior.
  printf 'blocked: waiting on infra\nresolved: infra access granted\n' >> "$f"
  out=$(open_set "$f")
  [ -z "$out" ] || fail "an unkeyed blocker no longer clears: $out"
  # The verified backlog transfer still closes a decision without an answer token.
  f="$d/state/held.status"
  fm_decision_cutover_ensure_status "$f" || fail "could not initialize the held stream"
  printf 'needs-decision [key=route]: north or south?\n' >> "$f"
  printf 'captain-held [key=route]: tracked by held-decision-route\n' >> "$f"
  out=$(open_set "$f")
  [ -z "$out" ] || fail "a verified captain-held transfer no longer closes a decision: $out"
  pass "blocker clearance and captain-held transfer keep their existing closure paths"
}

test_answer_token_does_not_disturb_line_parsers() {
  local line
  line='resolved [key=red-test] [ans=00000000000000013f2a91c07b4d6e58]: captain chose keep fixing'
  [ "$(status_line_verb "$line")" = resolved ] \
    || fail "the answer token broke verb parsing: '$(status_line_verb "$line")'"
  [ "$(status_line_note "$line")" = "captain chose keep fixing" ] \
    || fail "the answer token broke note parsing: '$(status_line_note "$line")'"
  status_is_captain_relevant "$line" \
    && fail "a correlated resolution must stay a nonterminal, non-captain-relevant event"
  # An [ans=] with no key is malformed: it must not silently become a default-key
  # event, and the verb must still parse so the line is classified, not mangled.
  line='resolved [ans=00000000000000013f2a91c07b4d6e58]: no key at all'
  [ "$(status_line_verb "$line")" = resolved ] \
    || fail "a keyless answer token mangled the verb: '$(status_line_verb "$line")'"
  pass "the answer token is transparent to the shared single-line parsers"
}

# --- stream identity must survive the fold ----------------------------------
#
# The defect these pin: the fold assigned its stream id straight from the
# marker reader on EVERY line, so an ordinary line substituted empty and cleared
# the stream while the authority flag stayed correlated. Every post-cutover
# opening then received a legacy positional instance under correlated authority,
# and fm-send minted a legacy-shaped token for a token-era request.

# Print the occurrence identifier the authoritative fold holds for <key>.
folded_instance() {  # <status-file> <key> -> instance
  local f=$1 key=$2 d_key d_verb d_instance _d_summary instance=''
  while IFS=$'\t' read -r d_key d_verb d_instance _d_summary || [ -n "$d_key" ]; do
    [ "$d_key" = "$key" ] || continue
    [ "$d_verb" = needs-decision ] || continue
    instance=$d_instance
  done <<EOF
$(status_open_decisions "$f" --with-instance)
EOF
  printf '%s' "$instance"
}

# Print the authority the fold assigned to <key>: legacy or correlated.
folded_authority() {  # <status-file> <key> -> legacy|correlated
  local f=$1 key=$2 d_key d_verb _d_instance d_authority _d_summary authority=''
  while IFS=$'\t' read -r d_key d_verb _d_instance d_authority _d_summary \
    || [ -n "$d_key" ]; do
    [ "$d_key" = "$key" ] || continue
    [ "$d_verb" = needs-decision ] || continue
    authority=$d_authority
  done <<EOF
$(status_open_decisions "$f" --with-authority)
EOF
  printf '%s' "$authority"
}

test_post_marker_opening_uses_the_stream_bound_instance() {
  local d f stream instance
  d=$(new_case stream-bound)
  f="$d/state/task.status"
  stream=$(fm_decision_stream_id "$f") || fail "the fixture stream is not self-describing"
  # Physical line 2 is the first ordinary line, line 3 opens the decision.
  printf 'working: mapping the surface\n' >> "$f"
  printf 'needs-decision [key=route]: north or south?\n' >> "$f"
  instance=$(folded_instance "$f" route)
  [ "$instance" = "$(fm_decision_instance_id 3 "$stream")" ] \
    || fail "a post-cutover opening did not bind to its stream: '$instance'"
  [ "$instance" != "$(fm_decision_instance_id 3)" ] \
    || fail "a post-cutover opening kept the legacy positional instance"
  [ "$(folded_authority "$f" route)" = correlated ] \
    || fail "a post-cutover opening lost its correlated authority"
  # An opening adjacent to the marker binds to the stream as well: the clearing
  # bug reached the very first line after the marker, not only distant ones.
  d=$(new_case stream-bound-adjacent)
  f="$d/state/task.status"
  stream=$(fm_decision_stream_id "$f") || fail "the adjacent fixture is not self-describing"
  printf 'needs-decision [key=adjacent]: choose now\n' >> "$f"
  instance=$(folded_instance "$f" adjacent)
  [ "$instance" = "$(fm_decision_instance_id 2 "$stream")" ] \
    || fail "an opening adjacent to the marker did not bind to its stream: '$instance'"
  pass "post-cutover openings carry the stream-bound occurrence instance"
}

test_stream_bound_mint_record_and_resolve_close_the_exact_opening() {
  local d f stream token recorded instance legacy_token
  d=$(new_case stream-bound-close)
  f="$d/state/task.status"
  stream=$(fm_decision_stream_id "$f") || fail "the fixture stream is not self-describing"
  printf 'working: still deciding whether to ask\n' >> "$f"
  printf 'needs-decision [key=route]: north or south?\n' >> "$f"
  instance=$(fm_decision_instance_id 3 "$stream")
  token=$(mint_for "$f" route)
  # The recorded token and its record both carry the stream-bound instance, so a
  # later reader cannot mistake this token-era grant for a legacy one.
  [ "${token:0:16}" = "$instance" ] \
    || fail "the minted token did not embed the stream-bound instance: '$token'"
  recorded=$(awk -F '\t' -v t="$token" '$1 == t { print $3 }' \
    "$(fm_decision_answers_file "$f")")
  [ "$recorded" = "$instance" ] \
    || fail "the answer record did not carry the stream-bound instance: '$recorded'"
  # A token minted against the SAME position under the legacy formula is not this
  # opening's authority and must not close it.
  legacy_token=$(fm_decision_mint_answer_token "$(fm_decision_instance_id 3)") \
    || fail "could not mint a legacy-shaped token"
  fm_decision_record_answer "$(fm_decision_answers_file "$f")" "$legacy_token" route \
    "$(fm_decision_instance_id 3)" >/dev/null \
    || fail "could not record the legacy-shaped token"
  printf 'resolved [key=route] [ans=%s]: replayed a legacy-shaped token\n' "$legacy_token" >> "$f"
  assert_contains "$(open_set "$f")" "route|needs-decision|" \
    "a legacy-shaped token closed a stream-bound opening"
  printf 'resolved [key=route] [ans=%s]: captain chose south\n' "$token" >> "$f"
  [ -z "$(open_set "$f")" ] \
    || fail "the stream-bound token failed to close its own opening"
  pass "a stream-bound token mints, records, and closes exactly its opening"
}

test_ordinary_lines_cannot_clear_stream_identity() {
  local d f stream instance position
  d=$(new_case stream-persists)
  f="$d/state/task.status"
  stream=$(fm_decision_stream_id "$f") || fail "the fixture stream is not self-describing"
  # Every shape an ordinary line can take sits between the marker and the
  # opening: prose, a blank line, whitespace, a resolution, and a line that only
  # looks like a marker.
  {
    printf 'working: mapping the surface\n'
    printf '\n'
    printf '   \n'
    printf 'resolved: an earlier unkeyed blocker cleared\n'
    printf '[fm-decision-answer-cutover:v1 stream=not-hex]\n'
    printf 'paused: waiting on an upstream release\n'
  } >> "$f"
  printf 'needs-decision [key=route]: north or south?\n' >> "$f"
  position=8
  instance=$(folded_instance "$f" route)
  [ "$instance" = "$(fm_decision_instance_id "$position" "$stream")" ] \
    || fail "ordinary lines cleared the stream identity: '$instance'"
  [ "$instance" != "$(fm_decision_instance_id "$position")" ] \
    || fail "the opening fell back to a legacy positional instance"
  [ "$(folded_authority "$f" route)" = correlated ] \
    || fail "ordinary lines downgraded the correlated authority"
  pass "ordinary lines never clear an established stream identity"
}

test_a_valid_later_marker_establishes_the_new_stream() {
  local d f first second instance
  d=$(new_case later-marker)
  f="$d/state/task.status"
  first=$(fm_decision_stream_id "$f") || fail "the first marker is not self-describing"
  second=$(fm_decision_status_marker) || fail "could not build a second marker"
  printf 'working: the first stream ran here\n' >> "$f"
  printf '%s\n' "$second" >> "$f"
  second=$(fm_decision_marker_line_id "$second") || fail "the second marker is malformed"
  [ "$first" != "$second" ] || fail "the second marker reused the first identity"
  printf 'working: the second stream starts here\n' >> "$f"
  printf 'needs-decision [key=route]: north or south?\n' >> "$f"
  instance=$(folded_instance "$f" route)
  [ "$instance" = "$(fm_decision_instance_id 5 "$second")" ] \
    || fail "an opening after a later marker did not bind to the new stream: '$instance'"
  [ "$instance" != "$(fm_decision_instance_id 5 "$first")" ] \
    || fail "an opening after a later marker stayed bound to the retired stream"
  pass "a valid later marker deterministically establishes the new stream"
}

test_true_legacy_streams_keep_legacy_identity_and_closure() {
  local d f instance
  d=$(new_legacy_case true-legacy)
  f="$d/state/task.status"
  {
    printf 'working: mapping the surface\n'
    printf 'needs-decision [key=route]: north or south?\n'
  } > "$f"
  instance=$(folded_instance "$f" route)
  [ "$instance" = "$(fm_decision_instance_id 2)" ] \
    || fail "an unmarked opening lost its legacy positional instance: '$instance'"
  [ "$(folded_authority "$f" route)" = legacy ] \
    || fail "an unmarked opening claimed correlated authority"
  printf 'resolved [key=route]: captain chose south\n' >> "$f"
  [ -z "$(open_set "$f")" ] \
    || fail "a legacy stream lost its plain keyed closure"
  pass "true legacy streams keep legacy identity and plain keyed closure"
}

test_malformed_or_ambiguous_markers_refuse_authority() {
  local d f second instance stream
  # A marker-shaped line that is not a valid marker never grants token-era
  # authority: the stream stays legacy and stays closable the legacy way.
  d=$(new_legacy_case malformed-marker)
  f="$d/state/task.status"
  {
    printf '[fm-decision-answer-cutover:v1 stream=not-a-valid-hex-identity-value]\n'
    printf 'needs-decision [key=route]: north or south?\n'
  } > "$f"
  fm_decision_stream_id "$f" >/dev/null \
    && fail "a malformed marker was accepted as a stream identity"
  [ -z "$(status_open_token_needs_decisions "$f")" ] \
    || fail "a malformed marker surfaced a token-era decision"
  status_has_open_token_needs_decision "$f" \
    && fail "a malformed marker claimed an open token-era decision"
  status_latest_needs_decision_is_open_token_occurrence "$f" \
    && fail "a malformed marker claimed a token-era latest occurrence"
  [ "$(folded_authority "$f" route)" = legacy ] \
    || fail "a malformed marker granted correlated authority"
  # Two valid markers are ambiguous: the strict identity reader refuses, so the
  # token-era surfaces refuse too, rather than answering against a guessed stream.
  d=$(new_case ambiguous-markers)
  f="$d/state/task.status"
  second=$(fm_decision_status_marker) || fail "could not build a second marker"
  printf '%s\n' "$second" >> "$f"
  printf 'needs-decision [key=route]: north or south?\n' >> "$f"
  fm_decision_stream_id "$f" >/dev/null \
    && fail "two markers were accepted as one stream identity"
  [ -z "$(status_open_token_needs_decisions "$f")" ] \
    || fail "an ambiguous stream surfaced a token-era decision"
  status_latest_needs_decision_is_open_token_occurrence "$f" \
    && fail "an ambiguous stream claimed a token-era latest occurrence"
  # A malformed marker arriving AFTER a valid one must not downgrade the
  # established stream back to a legacy positional instance. That silent
  # downgrade under retained correlated authority is the defect class itself.
  d=$(new_case malformed-after-valid)
  f="$d/state/task.status"
  stream=$(fm_decision_stream_id "$f") || fail "the fixture stream is not self-describing"
  printf '[fm-decision-answer-cutover:v1 stream=not-a-valid-hex-identity-value]\n' >> "$f"
  printf 'needs-decision [key=route]: north or south?\n' >> "$f"
  instance=$(folded_instance "$f" route)
  [ "$instance" = "$(fm_decision_instance_id 3 "$stream")" ] \
    || fail "a malformed trailing marker downgraded the established stream: '$instance'"
  [ "$(folded_authority "$f" route)" = correlated ] \
    || fail "a malformed trailing marker dropped correlated authority"
  pass "malformed and ambiguous markers refuse authority instead of granting it"
}

test_pre_request_generic_command_never_answers
test_queued_generic_command_reaches_a_busy_worker_unchanged
test_settled_pre_cutover_history_stays_settled
test_pre_cutover_opening_accepts_a_late_legacy_resolution
test_new_stream_markers_are_self_describing_and_unique
test_post_cutover_plain_resolution_is_rejected
test_correlated_answer_after_the_request_closes_it
test_token_for_an_earlier_position_cannot_close_a_later_request
test_reopened_decision_needs_a_fresh_answer
test_identical_reopen_rejects_old_duplicate_and_retry_delivery
test_answer_for_another_key_does_not_transfer
test_generic_and_unkeyed_input_never_closes_a_decision
test_blocked_and_captain_held_closure_are_unchanged
test_answer_token_does_not_disturb_line_parsers
test_post_marker_opening_uses_the_stream_bound_instance
test_stream_bound_mint_record_and_resolve_close_the_exact_opening
test_ordinary_lines_cannot_clear_stream_identity
test_a_valid_later_marker_establishes_the_new_stream
test_true_legacy_streams_keep_legacy_identity_and_closure
test_malformed_or_ambiguous_markers_refuse_authority
