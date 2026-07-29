#!/usr/bin/env bash
# tests/fm-decision-cutover-migrate.test.sh - regression: bin/fm-decision-cutover-migrate.sh
# upgrades only the legacy decision histories it can prove are safe to upgrade,
# and the upgrade changes nothing that was already settled.
#
# The migration exists because fm_decision_cutover_ensure_status marks a status
# stream only when it CREATES the file, so a task whose stream predates the
# token-era protection stays on legacy authority forever. The hazard the tests
# below pin is that "upgrading" an append-only decision log could retroactively
# reopen a settled decision, silently strand an open one, or let queued input
# from before the upgrade close a decision opened after it. None of those may
# happen, and every history the migration will not upgrade must be named.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# shellcheck source=/dev/null
. "$ROOT/bin/fm-classify-lib.sh"

MIGRATE="$ROOT/bin/fm-decision-cutover-migrate.sh"
TMP_ROOT=$(fm_test_tmproot fm-decision-cutover-migrate)

# --- fixture builders -------------------------------------------------------

new_home() {  # <name> -> a home dir with state/ and data/
  local d="$TMP_ROOT/$1"
  mkdir -p "$d/state" "$d/data"
  printf '%s' "$d"
}

# Write a task's status stream verbatim, with no marker: the legacy shape the
# migration is meant to find.
legacy_stream() {  # <home> <task> <body...>
  local home=$1 task=$2
  shift 2
  printf '%s\n' "$@" > "$home/state/$task.status"
}

# Give a task instructions that carry the current correlated-answer protocol,
# which is what proves its worker can close a token-era decision.
current_brief() {  # <home> <task>
  mkdir -p "$1/data/$2"
  printf 'Answer arrives as decision [key=<slug>] [ans=<token>]: {decision}.\n' \
    > "$1/data/$2/brief.md"
}

# Give a task pre-cutover instructions: no mention of an answer token anywhere.
legacy_brief() {  # <home> <task>
  mkdir -p "$1/data/$2"
  printf 'Answer arrives as decision [key=<slug>]: {decision}.\n' \
    > "$1/data/$2/brief.md"
}

# Run the migration against one home and publish its combined output in OUT and
# its exit code in RC. Both are globals rather than a printed result because a
# command substitution would run the assignment in a subshell and lose the code.
run_migrate() {  # <home> [args...] -> sets OUT and RC
  local home=$1
  shift
  OUT=$(FM_HOME="$home" "$MIGRATE" "$@" 2>&1)
  RC=$?
}
OUT=
RC=0

open_set() {  # <status-file> -> fold output with tabs made visible
  status_open_decisions "$1" | tr '\t' '|'
}

# Mint and record a correlated token for an already-open occurrence, exactly as
# fm-send does.
mint_for() {  # <status-file> <key> -> token
  local f=$1 key=$2 token instance='' d_key d_verb d_instance _d_summary
  while IFS=$'\t' read -r d_key d_verb d_instance _d_summary || [ -n "$d_key" ]; do
    [ "$d_key" = "$key" ] || continue
    [ "$d_verb" = needs-decision ] || continue
    instance=$d_instance
  done <<EOF
$(status_open_decisions "$f" --with-instance)
EOF
  [ -n "$instance" ] || fail "could not find an open occurrence for $key"
  token=$(fm_decision_mint_answer_token "$instance") || fail "could not mint an answer token"
  fm_decision_record_answer "$(fm_decision_answers_file "$f")" "$token" "$key" "$instance" \
    || fail "could not record the answer token"
}

# --- the migration is report-only until told otherwise ----------------------

test_default_run_changes_nothing() {
  local home before after out
  home=$(new_home report-only)
  legacy_stream "$home" task 'working: started' 'done: shipped'
  current_brief "$home" task
  before=$(cksum < "$home/state/task.status")

  run_migrate "$home"

  out=$OUT
  expect_code 0 "$RC" "a report-only run must succeed"
  assert_contains "$out" 'task would-upgrade' "an eligible legacy history must be reported"
  assert_contains "$out" 'report only' "the summary must say nothing was changed"
  after=$(cksum < "$home/state/task.status")
  [ "$before" = "$after" ] \
    || fail "a report-only run modified the history"
  assert_absent "$home/state/.decision-cutover-migration.log" \
    "a report-only run must not write a migration record"
  pass "the default run reports what it would upgrade and changes nothing"
}

# --- settled history stays settled ------------------------------------------

test_resolved_legacy_decision_stays_settled_after_upgrade() {
  local home out
  home=$(new_home settled)
  legacy_stream "$home" task \
    'working: started' \
    'needs-decision [key=scope]: narrow or wide' \
    'resolved [key=scope]: captain chose narrow' \
    'done: shipped'
  current_brief "$home" task

  [ -z "$(open_set "$home/state/task.status")" ] \
    || fail "the fixture was not settled before migration"
  run_migrate "$home" --apply
  out=$OUT
  expect_code 0 "$RC" "applying the migration must succeed"
  assert_contains "$out" 'task upgraded' "the eligible history must be upgraded"
  [ -z "$(open_set "$home/state/task.status")" ] \
    || fail "migration reopened a settled pre-cutover decision: $(open_set "$home/state/task.status")"
  pass "a resolved legacy decision stays settled after the upgrade"
}

test_upgrade_preserves_every_pre_existing_byte() {
  local home before
  home=$(new_home byte-preserving)
  legacy_stream "$home" task \
    'working: started' \
    'needs-decision [key=scope]: narrow or wide' \
    'resolved [key=scope]: captain chose narrow'
  current_brief "$home" task
  before=$(cat "$home/state/task.status")

  run_migrate "$home" --apply
  expect_code 0 "$RC" "applying the migration must succeed"
  [ "$(head -3 "$home/state/task.status")" = "$before" ] \
    || fail "the migration rewrote existing history instead of appending"
  [ "$(wc -l < "$home/state/task.status" | tr -d ' ')" = 4 ] \
    || fail "the migration appended more or less than one marker line"
  fm_decision_stream_id "$home/state/task.status" >/dev/null \
    || fail "the appended line is not a valid self-describing marker"
  pass "the upgrade appends exactly one marker and preserves every earlier byte"
}

# --- an open legacy decision is left alone ----------------------------------

test_unresolved_legacy_decision_is_refused_by_name() {
  local home out
  home=$(new_home open-decision)
  legacy_stream "$home" task \
    'working: started' \
    'needs-decision [key=scope]: narrow or wide'
  current_brief "$home" task

  run_migrate "$home" --apply

  out=$OUT
  expect_code 0 "$RC" "a refusal is a definite outcome, not a failure"
  assert_contains "$out" 'task refused' "the refusal must name the task"
  assert_contains "$out" 'open decision' "the refusal must state why"
  fm_decision_stream_id "$home/state/task.status" >/dev/null \
    && fail "a history with an open legacy decision must not be marked"
  assert_contains "$(open_set "$home/state/task.status")" 'scope|needs-decision' \
    "the open decision must remain visible after the refusal"
  pass "an unresolved legacy decision is refused by name and stays visible"
}

test_open_blocked_event_does_not_block_the_upgrade() {
  local home out
  home=$(new_home open-blocked)
  legacy_stream "$home" task \
    'blocked [key=creds]: needs a login'
  current_brief "$home" task

  # A blocked event closes on a plain keyed resolution on either side of the
  # marker, so the marker cannot change how it settles. Only a needs-decision
  # request carries answer authority, so only that one holds the migration back.
  run_migrate "$home" --apply
  out=$OUT
  assert_contains "$out" 'task upgraded' "an open blocker must not hold back the upgrade"
  assert_contains "$(open_set "$home/state/task.status")" 'creds|blocked' \
    "the open blocker must survive the upgrade"
  printf 'resolved [key=creds]: login provided\n' >> "$home/state/task.status"
  [ -z "$(open_set "$home/state/task.status")" ] \
    || fail "a plain keyed resolution must still clear a pre-marker blocker"
  pass "an open blocker survives the upgrade and still clears on a plain resolution"
}

# --- a worker on old instructions is refused --------------------------------

test_worker_launched_from_old_instructions_is_refused() {
  local home out
  home=$(new_home legacy-worker)
  legacy_stream "$home" task 'working: still going'
  legacy_brief "$home" task

  run_migrate "$home" --apply

  out=$OUT
  assert_contains "$out" 'task refused' "a pre-cutover worker's history must be refused"
  assert_contains "$out" 'correlated-answer protocol' "the refusal must state why"
  fm_decision_stream_id "$home/state/task.status" >/dev/null \
    && fail "a worker that cannot produce an answer token must not be put behind one"
  pass "a worker launched from old instructions is refused, not upgraded"
}

test_missing_instructions_are_refused_not_assumed_safe() {
  local home out
  home=$(new_home no-brief)
  legacy_stream "$home" task 'working: still going'

  run_migrate "$home" --apply

  out=$OUT
  assert_contains "$out" 'task refused' "a history with no instructions must be refused"
  fm_decision_stream_id "$home/state/task.status" >/dev/null \
    && fail "absent instructions were treated as proof of safety"
  pass "absent instructions are refused rather than assumed safe"
}

# --- malformed, duplicate, and interrupted markers --------------------------

test_partial_or_duplicate_marker_is_refused_intact() {
  local home out before
  home=$(new_home ambiguous-marker)
  # An interrupted append leaves a truncated marker: it carries the prefix but
  # is not a valid marker, so the fold ignores it while this migration must not
  # write a second, conflicting one.
  legacy_stream "$home" task \
    'working: started' \
    '[fm-decision-answer-cutover:v1 stream=deadbeef'
  current_brief "$home" task
  before=$(cat "$home/state/task.status")

  run_migrate "$home" --apply

  out=$OUT
  expect_code 0 "$RC" "an ambiguous marker is a definite refusal"
  assert_contains "$out" 'task refused' "the ambiguous history must be refused by name"
  assert_contains "$out" 'not a valid one' "the refusal must state why"
  [ "$(cat "$home/state/task.status")" = "$before" ] \
    || fail "the migration touched a history it refused"
  pass "a partial or hand-edited marker is refused and left intact for recovery"
}

test_unterminated_last_line_is_refused() {
  local home out before
  home=$(new_home no-terminator)
  printf 'working: started\ndone: shipped' > "$home/state/task.status"
  current_brief "$home" task
  before=$(cat "$home/state/task.status")

  run_migrate "$home" --apply

  out=$OUT
  assert_contains "$out" 'task refused' "an unterminated history must be refused"
  assert_contains "$out" 'line terminator' "the refusal must state why"
  [ "$(cat "$home/state/task.status")" = "$before" ] \
    || fail "appending spliced the marker onto an existing event"
  pass "a history whose last event has no terminator is refused"
}

# --- empty and already-current streams --------------------------------------

test_empty_stream_upgrades_and_marked_stream_is_already_current() {
  local home out
  home=$(new_home empty-and-current)
  : > "$home/state/empty.status"
  current_brief "$home" empty
  mkdir -p "$home/state"
  fm_decision_cutover_ensure_status "$home/state/fresh.status" \
    || fail "could not build a token-era fixture"
  current_brief "$home" fresh

  run_migrate "$home" --apply

  out=$OUT
  assert_contains "$out" 'empty upgraded' "an empty legacy stream must be upgradeable"
  assert_contains "$out" 'fresh already-current' "an already-marked stream must be reported as current"
  [ "$(wc -l < "$home/state/fresh.status" | tr -d ' ')" = 1 ] \
    || fail "an already-marked stream was appended to again"
  pass "an empty stream upgrades and an already-marked stream is left as current"
}

# --- idempotence and interrupted reruns -------------------------------------

test_rerun_is_idempotent() {
  local home first second out
  home=$(new_home idempotent)
  legacy_stream "$home" task 'done: shipped'
  current_brief "$home" task

  run_migrate "$home" --apply
  first=$(cat "$home/state/task.status")
  run_migrate "$home" --apply
  out=$OUT
  expect_code 0 "$RC" "a rerun must succeed"
  assert_contains "$out" 'task already-current' "a rerun must recognize the completed upgrade"
  second=$(cat "$home/state/task.status")
  [ "$first" = "$second" ] || fail "a rerun changed an already-migrated history"
  # A third run, including one that follows a crash between the append and the
  # operator record, still converges: the marker in the stream is the state.
  rm -f "$home/state/.decision-cutover-migration.log"
  run_migrate "$home" --apply
  out=$OUT
  assert_contains "$out" 'task already-current' "the marker, not the log, must be the migrated state"
  [ "$(cat "$home/state/task.status")" = "$first" ] \
    || fail "a rerun after a lost operator record changed the history"
  pass "reruns are idempotent and survive a lost operator record"
}

# --- stream identity --------------------------------------------------------

test_two_tasks_never_share_a_stream_identity() {
  local home a b
  home=$(new_home distinct-identity)
  legacy_stream "$home" alpha 'done: a'
  legacy_stream "$home" beta 'done: b'
  current_brief "$home" alpha
  current_brief "$home" beta

  run_migrate "$home" --apply
  a=$(fm_decision_stream_id "$home/state/alpha.status") || fail "alpha was not upgraded"
  b=$(fm_decision_stream_id "$home/state/beta.status") || fail "beta was not upgraded"
  [ "$a" != "$b" ] || fail "two tasks in one home were given the same stream identity"
  pass "each upgraded stream mints its own identity"
}

test_symlinked_stream_is_refused() {
  local home out
  home=$(new_home symlink)
  printf 'done: elsewhere\n' > "$TMP_ROOT/outside.status"
  ln -s "$TMP_ROOT/outside.status" "$home/state/task.status"
  current_brief "$home" task

  run_migrate "$home" --apply

  out=$OUT
  assert_contains "$out" 'task refused' "a symlinked stream must be refused"
  assert_no_grep 'fm-decision-answer-cutover' "$TMP_ROOT/outside.status" \
    "the migration wrote through a symlink into another file"
  pass "a symlinked stream is refused and nothing outside the home is written"
}

test_one_home_is_migrated_at_a_time() {
  local home other out
  home=$(new_home single-home)
  other=$(new_home other-home)
  legacy_stream "$home" mine 'done: a'
  legacy_stream "$other" theirs 'done: b'
  current_brief "$home" mine
  current_brief "$other" theirs

  run_migrate "$home" --apply

  out=$OUT
  assert_contains "$out" 'mine upgraded' "the named home's history must be upgraded"
  assert_not_contains "$out" 'theirs' "another home's history must never be inspected"
  fm_decision_stream_id "$other/state/theirs.status" >/dev/null \
    && fail "the migration reached into a home it was not pointed at"
  pass "the migration acts on exactly the home it is given"
}

test_a_secondmate_home_is_migrated_by_pointing_at_it() {
  local main sub main_id sub_id
  main=$(new_home parent-home)
  sub=$(new_home secondmate-home)
  # A secondmate home is an ordinary isolated home with the same state/ and
  # data/ shape, so it needs no separate code path: it is migrated by naming it,
  # and the two homes' identical task ids must never be conflated.
  : > "$sub/.fm-secondmate-home"
  legacy_stream "$main" shared-id 'done: parent work'
  legacy_stream "$sub" shared-id 'done: secondmate work'
  current_brief "$main" shared-id
  current_brief "$sub" shared-id

  run_migrate "$main" --apply
  assert_contains "$OUT" 'shared-id upgraded' "the parent home must be upgradeable"
  fm_decision_stream_id "$sub/state/shared-id.status" >/dev/null \
    && fail "migrating the parent home reached into the secondmate home"

  run_migrate "$sub" --apply
  assert_contains "$OUT" 'shared-id upgraded' "a secondmate home must be upgradeable on its own"
  main_id=$(fm_decision_stream_id "$main/state/shared-id.status") \
    || fail "the parent stream lost its identity"
  sub_id=$(fm_decision_stream_id "$sub/state/shared-id.status") \
    || fail "the secondmate stream lost its identity"
  [ "$main_id" != "$sub_id" ] \
    || fail "two homes sharing a task id were given the same stream identity"
  pass "a secondmate home migrates on its own and never shares an identity with its parent"
}

test_state_and_data_overrides_are_honored() {
  local home
  home=$(new_home overrides)
  mkdir -p "$home/alt-state" "$home/alt-data/task"
  printf 'done: shipped\n' > "$home/alt-state/task.status"
  printf 'decision [key=<slug>] [ans=<token>]\n' > "$home/alt-data/task/brief.md"
  # The override pair is how a caller points at a home whose state and data are
  # not under FM_HOME, which is also what the tests and tooling rely on.
  OUT=$(FM_STATE_OVERRIDE="$home/alt-state" FM_DATA_OVERRIDE="$home/alt-data" \
    FM_HOME="$home" "$MIGRATE" --apply 2>&1)
  RC=$?
  expect_code 0 "$RC" "an overridden home must migrate"
  assert_contains "$OUT" 'task upgraded' "the overridden state directory must be swept"
  fm_decision_stream_id "$home/alt-state/task.status" >/dev/null \
    || fail "the overridden stream was not upgraded"
  pass "explicit state and data overrides select the home that is migrated"
}

# --- a single task can be targeted ------------------------------------------

test_task_selector_restricts_the_sweep() {
  local home out
  home=$(new_home targeted)
  legacy_stream "$home" wanted 'done: a'
  legacy_stream "$home" untouched 'done: b'
  current_brief "$home" wanted
  current_brief "$home" untouched

  run_migrate "$home" --apply --task wanted

  out=$OUT
  assert_contains "$out" 'wanted upgraded' "the named task must be upgraded"
  assert_not_contains "$out" 'untouched' "an unnamed task must not be inspected"
  fm_decision_stream_id "$home/state/untouched.status" >/dev/null \
    && fail "the sweep ignored its task selector"

  run_migrate "$home" --task nonexistent

  out=$OUT
  expect_code 1 "$RC" "an unknown task must be an explicit failure"
  assert_contains "$out" 'no decision history' "the failure must say what was missing"

  run_migrate "$home" --task '../escape'

  out=$OUT
  expect_code 2 "$RC" "a traversal attempt must be rejected as invalid usage"
  pass "the task selector restricts the sweep and rejects an unusable id"
}

test_invalid_usage_is_rejected() {
  local home out
  home=$(new_home usage)
  run_migrate "$home" --bogus
  out=$OUT
  expect_code 2 "$RC" "an unknown flag must be invalid usage"
  assert_contains "$out" 'usage:' "invalid usage must print usage"
  pass "invalid usage is rejected without touching any history"
}

# --- the point of the whole migration ---------------------------------------

test_decisions_opened_after_the_upgrade_require_a_correlated_answer() {
  local home f token
  home=$(new_home post-upgrade-authority)
  legacy_stream "$home" task 'working: started' 'done: first round'
  current_brief "$home" task
  f="$home/state/task.status"

  run_migrate "$home" --apply
  printf 'needs-decision [key=next]: ship or hold\n' >> "$f"
  assert_contains "$(open_set "$f")" 'next|needs-decision' "the new request must be open"

  printf 'resolved [key=next]: ship it\n' >> "$f"
  assert_contains "$(open_set "$f")" 'next|needs-decision' \
    "a plain resolution closed a decision opened after the upgrade"

  token=$(mint_for "$f" next)
  printf 'resolved [key=next] [ans=%s]: captain said ship\n' "$token" >> "$f"
  [ -z "$(open_set "$f")" ] \
    || fail "the correlated answer did not close its decision: $(open_set "$f")"
  pass "a decision opened after the upgrade needs the correct correlated answer"
}

test_input_queued_before_the_upgrade_cannot_close_a_later_decision() {
  local home f stale_instance stale_token
  home=$(new_home stale-input)
  legacy_stream "$home" task \
    'needs-decision [key=early]: a or b' \
    'resolved [key=early]: chose a'
  current_brief "$home" task
  f="$home/state/task.status"

  # A token minted while the stream was still legacy embeds the occurrence
  # identifier of that earlier line. Positions only ever increase in an
  # append-only log, so no later opening can hold it.
  stale_instance=$(fm_decision_instance_id 1) || fail "could not derive the earlier occurrence"
  stale_token=$(fm_decision_mint_answer_token "$stale_instance") \
    || fail "could not mint the stale token"
  fm_decision_record_answer "$(fm_decision_answers_file "$f")" \
    "$stale_token" late "$stale_instance" >/dev/null \
    || fail "could not record the stale token"

  run_migrate "$home" --apply
  printf 'needs-decision [key=late]: the future decision\n' >> "$f"
  printf 'resolved [key=late] [ans=%s]: stale approval\n' "$stale_token" >> "$f"
  assert_contains "$(open_set "$f")" 'late|needs-decision' \
    "input queued before the upgrade closed a decision opened after it"
  pass "input queued before the upgrade cannot close a later decision"
}

test_archived_history_with_no_worker_and_no_open_decision_upgrades() {
  local home out
  home=$(new_home archived)
  # A torn-down task keeps its status stream but no longer has a live worker.
  # Its brief still records the protocol its worker ran under, which is what the
  # migration reads; nothing here should need a running process.
  legacy_stream "$home" task \
    'working: started' \
    'needs-decision [key=scope]: narrow or wide' \
    'resolved [key=scope]: narrow' \
    'done: PR merged'
  current_brief "$home" task

  run_migrate "$home" --apply

  out=$OUT
  assert_contains "$out" 'task upgraded' "a finished history must still be upgradeable"
  [ -z "$(open_set "$home/state/task.status")" ] \
    || fail "upgrading a finished history reopened something"
  pass "an archived history with nothing open upgrades cleanly"
}

test_home_without_histories_is_reported_not_failed() {
  local home out
  home=$(new_home no-histories)
  run_migrate "$home"
  out=$OUT
  expect_code 0 "$RC" "an empty home is a normal outcome"
  assert_contains "$out" 'no decision histories' "an empty home must say so"
  pass "a home with no decision histories is reported, not failed"
}

test_unreadable_state_directory_stops_safely() {
  local home out
  home=$(new_home unreadable)
  rm -rf "$home/state"
  run_migrate "$home"
  out=$OUT
  expect_code 1 "$RC" "an unusable home must stop with a failure"
  assert_contains "$out" 'no history was inspected' "the failure must say nothing was inspected"
  pass "an unusable home stops safely before inspecting anything"
}

test_default_run_changes_nothing
test_resolved_legacy_decision_stays_settled_after_upgrade
test_upgrade_preserves_every_pre_existing_byte
test_unresolved_legacy_decision_is_refused_by_name
test_open_blocked_event_does_not_block_the_upgrade
test_worker_launched_from_old_instructions_is_refused
test_missing_instructions_are_refused_not_assumed_safe
test_partial_or_duplicate_marker_is_refused_intact
test_unterminated_last_line_is_refused
test_empty_stream_upgrades_and_marked_stream_is_already_current
test_rerun_is_idempotent
test_two_tasks_never_share_a_stream_identity
test_symlinked_stream_is_refused
test_one_home_is_migrated_at_a_time
test_a_secondmate_home_is_migrated_by_pointing_at_it
test_state_and_data_overrides_are_honored
test_task_selector_restricts_the_sweep
test_invalid_usage_is_rejected
test_decisions_opened_after_the_upgrade_require_a_correlated_answer
test_input_queued_before_the_upgrade_cannot_close_a_later_decision
test_archived_history_with_no_worker_and_no_open_decision_upgrades
test_home_without_histories_is_reported_not_failed
test_unreadable_state_directory_stops_safely
