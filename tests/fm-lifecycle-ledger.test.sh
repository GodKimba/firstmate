#!/usr/bin/env bash
# Executable contracts for the mode-free lifecycle memo and surfaced ledger.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-lifecycle-ledger)
mkdir -p "$TMP_ROOT"
STUB="$TMP_ROOT/fm-crew-state.sh"
cat > "$STUB" <<'SH'
#!/usr/bin/env bash
set -u
state=${FM_STATE_OVERRIDE:?}
if [ "${1:-}" = --supervision ]; then
  shift
  printf 'read\n' >> "$state/.crew-state-reads"
  cat "$state/$1.supervision"
  exit 0
fi
case "$(cat "$state/$1.supervision" 2>/dev/null || printf 'unknown\tnone')" in
  working*) printf 'state: working · source: run-step · fixture\n' ;;
  paused*) printf 'state: paused · source: status-log · fixture\n' ;;
  parked*) printf 'state: parked · source: run-step · fixture\n' ;;
  terminal*) printf 'state: done · source: run-step · fixture\n' ;;
  *) printf 'state: unknown · source: none · fixture\n' ;;
esac
SH
chmod +x "$STUB"
FM_CREW_STATE_BIN="$STUB"
export FM_CREW_STATE_BIN
# shellcheck source=bin/fm-lifecycle-lib.sh
. "$ROOT/bin/fm-lifecycle-lib.sh"
# shellcheck source=bin/fm-wake-lib.sh
. "$ROOT/bin/fm-wake-lib.sh"

new_state() {
  local state="$TMP_ROOT/$1/state"
  mkdir -p "$state"
  printf '%s\n' "$state"
}

set_supervision() {  # <state> <task> <class> <identity>
  printf '%s\t%s\n' "$3" "$4" > "$1/$2.supervision"
}

set_meta() {  # <state> <task> <window>
  printf 'window=%s\nworktree=%s/worktree\nkind=ship\n' "$3" "$1" > "$1/$2.meta"
}

read_tuple() {  # <state> <task> [mode]
  FM_STATE_OVERRIDE="$1" fm_lifecycle_read "$2" "${3:-force}" "$1"
}

assert_eq() {
  [ "$1" = "$2" ] || fail "${3:-expected $2, got $1}"
}

assert_pending() {
  assert_eq "$(fm_surfaced_state "$2" "$3" "$1")" pending "$4"
}

assert_surfaced() {
  assert_eq "$(fm_surfaced_state "$2" "$3" "$1")" surfaced "$4"
}

p1_decision_identity_precedes_run_readability() {
  local state task tuple
  state=$(new_state p1); task=p1
  fm_decision_cutover_ensure_status "$state/$task.status"
  printf 'needs-decision [key=route]: choose route\n' >> "$state/$task.status"
  set_supervision "$state" "$task" unknown none
  tuple=$(read_tuple "$state" "$task")
  case "$tuple" in parked$'\t'decision:*) ;; *) fail "P1 decision did not outrank unreadable run: $tuple" ;; esac
  pass "P1 decision occurrence outranks run readability"
}

p4_non_occurrence_classes_have_none_identity() {
  local state class tuple
  state=$(new_state p4)
  for class in working paused unknown; do
    set_supervision "$state" p4 "$class" none
    tuple=$(read_tuple "$state" p4)
    assert_eq "$tuple" "$class"$'\t'none "P4 $class did not retain identity none"
  done
  pass "P4 working, paused, and unknown have no occurrence identity"
}

p5_none_is_never_recorded() {
  local state
  state=$(new_state p5)
  assert_eq "$(fm_surfaced_state p5 none "$state")" none "P5 none state was not none"
  fm_mark_surfaced p5 none "$state" 2>/dev/null && fail "P5 recorded identity none"
  [ ! -e "$state/p5.surfaced" ] || fail "P5 created a surfaced ledger for none"
  pass "P5 identity none cannot be recorded"
}

p6_malformed_ledger_is_pending() {
  local state
  state=$(new_state p6)
  printf 'status:I1\tbroken\textra\n' > "$state/p6.surfaced"
  assert_pending "$state" p6 status:I1 "P6 malformed ledger did not fail toward visibility"
  pass "P6 malformed ledger reads pending"
}

p7_atomic_writes_never_publish_partial_lines() {
  local state reader i line
  state=$(new_state p7)
  set_supervision "$state" p7 terminal status:A
  fm_lifecycle_memo_write p7 terminal status:A "$state"
  fm_mark_surfaced p7 status:A "$state"
  (
    i=0
    while [ "$i" -lt 200 ]; do
      fm_mark_surfaced p7 status:A "$state" || exit 1
      fm_mark_surfaced p7 status:B "$state" || exit 1
      i=$((i + 1))
    done
  ) &
  reader=$!
  i=0
  while kill -0 "$reader" 2>/dev/null && [ "$i" -lt 2000 ]; do
    line=$(cat "$state/p7.surfaced" 2>/dev/null || true)
    case "$line" in status:A$'\t'[0-9]*|status:B$'\t'[0-9]*) ;; *) fail "P7 observed partial ledger bytes: $line" ;; esac
    i=$((i + 1))
  done
  wait "$reader" || fail "P7 concurrent writer failed"
  pass "P7 atomic ledger writes expose only complete old or new values"
}

t1_t8_basic_terminal_occurrences() {
  local state tuple
  state=$(new_state t1); set_meta "$state" task sess:fm-task
  set_supervision "$state" task terminal status:I1
  tuple=$(read_tuple "$state" task)
  assert_eq "$tuple" terminal$'\t'status:I1 "T1 terminal tuple mismatch"
  assert_pending "$state" task status:I1 "T1 empty ledger was not pending"
  fm_mark_surfaced task status:I1 "$state"
  assert_surfaced "$state" task status:I1 "T1 record did not surface I1"
  set_supervision "$state" task terminal status:I2
  tuple=$(read_tuple "$state" task)
  assert_pending "$state" task "${tuple#*$'\t'}" "T8 changed failure occurrence was suppressed"
  fm_mark_surfaced task status:I2 "$state"
  assert_surfaced "$state" task status:I2 "T8 I2 was not recorded"
  pass "T1 and T8 surface first terminal occurrence and a changed terminal occurrence"
}

t2_t7_duplicate_inputs_are_not_identity_inputs() {
  local state input
  state=$(new_state t2); set_meta "$state" task sess:fm-task
  set_supervision "$state" task terminal status:I1
  read_tuple "$state" task >/dev/null
  fm_mark_surfaced task status:I1 "$state"
  for input in pane-hash normal-to-away away-to-normal endpoint-rebind herdr-edge; do
    case "$input" in
      pane-hash) printf 'changed-rendered-hash\n' > "$state/.hash-sess_fm_task" ;;
      normal-to-away) : > "$state/.afk" ;;
      away-to-normal) rm -f "$state/.afk" ;;
      endpoint-rebind) set_meta "$state" task other:fm-task ;;
      herdr-edge) printf 'working>blocked\n' > "$state/.herdr-escalated-other_fm_task" ;;
    esac
    assert_surfaced "$state" task status:I1 "T2-T7 $input changed occurrence surfacing"
  done
  pass "T2-T5 and T7 ignore pane, mode, endpoint, and Herdr edge changes"
}

t6_turn_end_uses_settled_memo_without_a_deep_read() {
  local state before after mode tuple
  state=$(new_state t6); set_meta "$state" task sess:fm-task
  set_supervision "$state" task terminal status:I1
  read_tuple "$state" task >/dev/null
  fm_mark_surfaced task status:I1 "$state"
  before=$(wc -l < "$state/.crew-state-reads" | tr -d ' ')
  mode=$(fm_lifecycle_turn_end_mode task "$state")
  assert_eq "$mode" cached "T6 settled turn-end did not select the memo"
  read_tuple "$state" task "$mode" >/dev/null
  after=$(wc -l < "$state/.crew-state-reads" | tr -d ' ')
  assert_eq "$after" "$before" "T6 turn-end forced a settled deep read"
  assert_surfaced "$state" task status:I1 "T6 turn-end re-surfaced I1"

  state=$(new_state t6-working); set_meta "$state" task sess:fm-task
  set_supervision "$state" task working none
  read_tuple "$state" task >/dev/null
  set_supervision "$state" task terminal status:I2
  mode=$(fm_lifecycle_turn_end_mode task "$state")
  assert_eq "$mode" force "T6 working turn-end reused a non-settled memo"
  tuple=$(read_tuple "$state" task "$mode")
  assert_eq "$tuple" terminal$'\t'status:I2 "T6 working-to-terminal turn-end missed the completion"
  pass "T6 settled turn-end signals reuse the memo while working completions refresh"
}

t7_herdr_push_consults_the_shared_ledger() (
  local state record
  state=$(new_state t7-push); STATE=$state; export STATE
  set_meta "$state" task lab:p1
  set_supervision "$state" task terminal status:I1
  read_tuple "$state" task >/dev/null
  fm_mark_surfaced task status:I1 "$state"
  : > "$state/task.status"
  # shellcheck source=bin/fm-push-transition-lib.sh
  . "$ROOT/bin/fm-push-transition-lib.sh"
  fm_transition_pane_id() { printf 'p1'; }
  fm_transition_to_status() { printf 'blocked'; }
  window_to_task() { printf 'task'; }
  fm_backend_commit_transition() { printf 'commit\n' >> "$state/actions"; }
  fm_backend_agent_alive() { printf alive; }
  fm_wake_append() { printf 'wake\n' >> "$state/actions"; }
  wake() { printf 'exit\n' >> "$state/actions"; }
  record='fixture'
  handle_push_transition herdr lab "$record"
  grep -Fx commit "$state/actions" >/dev/null || fail "T7 push edge was not committed"
  grep -Fx wake "$state/actions" >/dev/null && fail "T7 reported Herdr flap enqueued again"
  pass "T7 Herdr working-to-blocked flap cannot re-surface a reported occurrence"
)

t9_nonworking_boundary_clears_inherited_wedge_timing() {
  local state key window_key
  state=$(new_state t9); set_meta "$state" task sess:fm-task
  key=sess_fm-task
  : > "$state/.stale-since-$key"
  : > "$state/.wedge-escalations-$key"
  : > "$state/.subsuper-stale-task"
  set_supervision "$state" task terminal status:I1
  read_tuple "$state" task >/dev/null
  [ ! -e "$state/.stale-since-$key" ] || fail "T9 retained watcher wedge timer"
  [ ! -e "$state/.wedge-escalations-$key" ] || fail "T9 retained watcher escalation count"
  [ ! -e "$state/.subsuper-stale-task" ] || fail "T9 retained away-mode wedge timer"

  state=$(new_state t9-orca)
  printf 'window=fm-task\nterminal=term-orca-task\nbackend=orca\nworktree=%s/worktree\nkind=ship\n' "$state" > "$state/task.meta"
  key=term-orca-task
  window_key=fm-task
  : > "$state/.stale-since-$key"
  : > "$state/.wedge-escalations-$key"
  : > "$state/.stale-since-$window_key"
  set_supervision "$state" task terminal status:I1
  read_tuple "$state" task >/dev/null
  [ ! -e "$state/.stale-since-$key" ] || fail "T9 retained Orca terminal-keyed wedge timer"
  [ ! -e "$state/.wedge-escalations-$key" ] || fail "T9 retained Orca terminal-keyed escalation count"
  [ -e "$state/.stale-since-$window_key" ] || fail "T9 cleared the unrelated Orca window key"
  pass "T9 non-working lifecycle boundary clears inherited wedge timing"
}

t10_t11_working_reversal_preserves_ledger_and_new_result_surfaces() {
  local state tuple
  state=$(new_state t10); set_meta "$state" task sess:fm-task
  set_supervision "$state" task terminal status:I1
  read_tuple "$state" task >/dev/null
  fm_mark_surfaced task status:I1 "$state"
  set_supervision "$state" task working none
  tuple=$(read_tuple "$state" task)
  assert_eq "$tuple" working$'\t'none "T10 reversal did not become working/none"
  grep -F 'status:I1' "$state/task.surfaced" >/dev/null || fail "T10 working reversal rewrote the ledger"
  set_supervision "$state" task terminal status:I3
  tuple=$(read_tuple "$state" task)
  assert_pending "$state" task "${tuple#*$'\t'}" "T11 new completion after reversal was hidden"
  pass "T10-T11 working reversal leaves the ledger intact and a new completion surfaces"
}

t12_t14_decision_identity_survives_run_flaps_and_reopens() {
  local state d1 d2 tuple
  state=$(new_state t12); set_meta "$state" task sess:fm-task
  fm_decision_cutover_ensure_status "$state/task.status"
  printf 'needs-decision [key=route]: choose route\n' >> "$state/task.status"
  set_supervision "$state" task unknown none
  tuple=$(read_tuple "$state" task); d1=${tuple#*$'\t'}
  fm_mark_surfaced task "$d1" "$state"
  set_supervision "$state" task terminal run:terminal:OTHER
  tuple=$(read_tuple "$state" task)
  assert_eq "${tuple#*$'\t'}" "$d1" "T12-T13 run recovery changed an open decision identity"
  assert_surfaced "$state" task "$d1" "T12-T13 open decision repeated after run recovery"
  printf 'resolved [key=route] [ans=a1]: chose route\nneeds-decision [key=route]: choose route again\n' >> "$state/task.status"
  tuple=$(read_tuple "$state" task); d2=${tuple#*$'\t'}
  [ "$d1" != "$d2" ] || fail "T14 second opening reused D1"
  assert_pending "$state" task "$d2" "T14 second opening was suppressed"
  pass "T12-T14 decisions survive run-read flaps and distinguish a second opening"
}

t15_repark_collision_is_bounded_by_the_resurface_window() {
  local state now old
  state=$(new_state t15); set_meta "$state" task sess:fm-task
  set_supervision "$state" task parked run:parked:SAME
  read_tuple "$state" task >/dev/null
  fm_mark_surfaced task run:parked:SAME "$state"
  assert_surfaced "$state" task run:parked:SAME "T15 same re-park repeated before the window"
  now=$(date +%s); old=$((now - 3700))
  printf 'run:parked:SAME\t%s\n' "$old" > "$state/task.surfaced"
  FM_PAUSE_RESURFACE_SECS=3600 assert_pending "$state" task run:parked:SAME "T15 identical re-park stayed silent past the bound"
  pass "T15 disconfirming identical re-park degrades to bounded latency, never silence"
}

t16_t18_nonoccurrence_visibility_contracts() {
  local state tuple
  state=$(new_state t16); set_meta "$state" task sess:fm-task
  set_supervision "$state" task working none
  tuple=$(read_tuple "$state" task)
  assert_eq "$(fm_surfaced_state task "${tuple#*$'\t'}" "$state")" none "T16 working wedge could be ledger-suppressed"
  set_supervision "$state" task paused none
  tuple=$(read_tuple "$state" task)
  assert_eq "$tuple" paused$'\t'none "T17 pause gained an occurrence identity"
  set_supervision "$state" task unknown none
  tuple=$(read_tuple "$state" task)
  assert_eq "$tuple" unknown$'\t'none "T18 unknown gained an occurrence identity"
  fm_mark_surfaced task none "$state" 2>/dev/null && fail "T18 unknown wrote the ledger"
  set_supervision "$state" task terminal status:RECOVERED
  tuple=$(read_tuple "$state" task cached)
  assert_eq "$tuple" terminal$'\t'status:RECOVERED "T18 unknown memo suppressed a recovered lifecycle"
  pass "T16-T18 working, paused, and unknown stay visible outside occurrence suppression"
}

t18_unknown_retains_wedge_timing_until_visibility() {
  local state key
  state=$(new_state t18-timers); set_meta "$state" task sess:fm-task
  key=sess_fm-task
  : > "$state/.stale-since-$key"
  : > "$state/.wedge-escalations-$key"
  : > "$state/.subsuper-stale-task"
  set_supervision "$state" task unknown none
  read_tuple "$state" task >/dev/null
  [ -e "$state/.stale-since-$key" ] || fail "T18 unknown cleared the watcher wedge timer"
  [ -e "$state/.wedge-escalations-$key" ] || fail "T18 unknown cleared the watcher escalation count"
  [ -e "$state/.subsuper-stale-task" ] || fail "T18 unknown cleared the away-mode wedge timer"
  pass "T18 unknown lifecycle retains wedge timing until visibility is handled"
}

t19_merge_poll_artifacts_are_independent() {
  local state before after
  state=$(new_state t19); set_meta "$state" task sess:fm-task
  printf 'validated poll bytes\n' > "$state/task.check.sh"
  before=$(cksum "$state/task.check.sh")
  set_supervision "$state" task terminal status:I1
  read_tuple "$state" task >/dev/null
  fm_mark_surfaced task status:I1 "$state"
  after=$(cksum "$state/task.check.sh")
  assert_eq "$after" "$before" "T19 lifecycle owner touched merge polling"
  pass "T19 authenticated merge polling remains independent"
}

t20_cleanup_refusal_keeps_task_visible() {
  local state
  state=$(new_state t20); set_meta "$state" task sess:fm-task
  set_supervision "$state" task terminal status:I1
  read_tuple "$state" task >/dev/null
  fm_mark_surfaced task status:I1 "$state"
  printf 'unlanded work\n' > "$state/cleanup-refused"
  [ -e "$state/task.meta" ] && [ -e "$state/task.lifecycle" ] && [ -e "$state/task.surfaced" ] \
    || fail "T20 a refusal-side read hid the task"
  pass "T20 cleanup refusal leaves task and lifecycle records visible"
}

t22_enqueue_before_record_replays_toward_a_duplicate() {
  local state
  state=$(new_state t22); set_meta "$state" task sess:fm-task
  set_supervision "$state" task terminal status:I1
  read_tuple "$state" task >/dev/null
  STATE="$state"
  FM_WAKE_QUEUE="$state/.wake-queue"
  FM_WAKE_QUEUE_LOCK="$state/.wake-queue.lock"
  fm_wake_append stale sess:fm-task 'stale: sess:fm-task'
  assert_pending "$state" task status:I1 "T22 enqueue-without-record caused silence"
  grep "$(printf '\tstale\t')" "$state/.wake-queue" >/dev/null || fail "T22 wake was not durable before the ledger write"
  fm_mark_surfaced task status:I1 "$state"
  assert_surfaced "$state" task status:I1 "T22 replay record did not settle"
  pass "T22 crash between enqueue and record permits at most a duplicate, never silence"
}

t22_push_records_only_the_bound_occurrence() (
  local state line1 line2 identity1 identity2 record d1 d2
  state=$(new_state t22-push-status); STATE=$state; export STATE
  line1='failed: first occurrence'
  line2='failed: second occurrence'
  identity1=$(fm_lifecycle_status_identity "$line1")
  identity2=$(fm_lifecycle_status_identity "$line2")
  set_meta "$state" task lab:p1
  printf '%s\n' "$line1" > "$state/task.status"
  set_supervision "$state" task terminal "$identity1"
  # shellcheck source=bin/fm-push-transition-lib.sh
  . "$ROOT/bin/fm-push-transition-lib.sh"
  fm_transition_pane_id() { printf 'p1'; }
  fm_transition_to_status() { printf 'blocked'; }
  window_to_task() { printf 'task'; }
  fm_backend_commit_transition() { :; }
  fm_backend_agent_alive() { printf alive; }
  fm_wake_append() {
    printf '%s\n' "$line2" >> "$state/task.status"
    set_supervision "$state" task terminal "$identity2"
  }
  wake() { :; }
  record=fixture
  handle_push_transition herdr lab "$record"
  grep -F "$identity1" "$state/task.surfaced" >/dev/null || fail "T22 push did not record the enqueued status occurrence"
  grep -F "$identity2" "$state/task.surfaced" >/dev/null && fail "T22 push recorded a later status occurrence"
  assert_eq "$(cat "$(_hb_surfaced_path task)")" "$line1" "T22 push legacy marker drifted to the later status"

  state=$(new_state t22-push-decisions); STATE=$state; export STATE
  set_meta "$state" task lab:p1
  fm_decision_cutover_ensure_status "$state/task.status"
  printf 'needs-decision [key=one]: first\nneeds-decision [key=two]: second\n' >> "$state/task.status"
  d1=$(status_open_supervision_decisions "$state/task.status" | awk -F '\t' '$1 == "one" { print $3 }')
  d2=$(status_open_supervision_decisions "$state/task.status" | awk -F '\t' '$1 == "two" { print $3 }')
  set_supervision "$state" task unknown none
  fm_wake_append() { :; }
  handle_push_transition herdr lab "$record"
  decision_occurrence_is_surfaced "$d1" || fail "T22 push did not dual-write the queued decision"
  decision_occurrence_is_surfaced "$d2" && fail "T22 push dual-wrote an unqueued decision"
  pass "T22 push records only the occurrence captured before enqueue"
)

t22_afk_handoff_stays_pending_until_daemon_buffering() (
  local state occurrence identity line record
  state=$(new_state t22-afk-decision); STATE=$state; export STATE
  FM_WAKE_QUEUE="$state/.wake-queue"
  FM_WAKE_QUEUE_LOCK="$state/.wake-queue.lock"
  export FM_WAKE_QUEUE FM_WAKE_QUEUE_LOCK
  set_meta "$state" task lab:p1
  fm_decision_cutover_ensure_status "$state/task.status"
  printf 'needs-decision [key=route]: choose route\n' >> "$state/task.status"
  occurrence=$(status_open_supervision_decisions "$state/task.status" | awk -F '\t' '$1 == "route" { print $3 }')
  identity="decision:$occurrence"
  set_supervision "$state" task unknown none
  : > "$state/.afk"
  # shellcheck source=bin/fm-push-transition-lib.sh
  . "$ROOT/bin/fm-push-transition-lib.sh"
  enqueue_pending_open_decisions "$state/task.status" \
    || fail "T22 AFK decision was not enqueued"
  assert_pending "$state" task "$identity" "T22 AFK decision handoff advanced the shared ledger"
  decision_occurrence_is_surfaced "$occurrence" \
    && fail "T22 AFK decision handoff advanced the watcher legacy ledger"
  grep -F "$(printf '\tdecision\t%s\t' "$occurrence")" "$state/.wake-queue" >/dev/null \
    || fail "T22 AFK decision handoff was not durable"

  state=$(new_state t22-afk-push); STATE=$state; export STATE
  line='failed: wait for daemon buffering'
  identity=$(fm_lifecycle_status_identity "$line")
  set_meta "$state" task lab:p1
  printf '%s\n' "$line" > "$state/task.status"
  set_supervision "$state" task terminal "$identity"
  : > "$state/.afk"
  fm_transition_pane_id() { printf 'p1'; }
  fm_transition_to_status() { printf 'blocked'; }
  window_to_task() { printf 'task'; }
  fm_backend_commit_transition() { :; }
  fm_backend_agent_alive() { printf alive; }
  fm_wake_append() { :; }
  wake() { :; }
  record=fixture
  handle_push_transition herdr lab "$record"
  assert_pending "$state" task "$identity" "T22 AFK push handoff advanced the shared ledger"
  [ ! -e "$state/.hb-surfaced-task" ] \
    || fail "T22 AFK push handoff advanced the watcher legacy ledger"
  pass "T22 AFK handoffs stay pending until daemon buffering"
)

p1_decision_identity_precedes_run_readability
p4_non_occurrence_classes_have_none_identity
p5_none_is_never_recorded
p6_malformed_ledger_is_pending
p7_atomic_writes_never_publish_partial_lines
t1_t8_basic_terminal_occurrences
t2_t7_duplicate_inputs_are_not_identity_inputs
t6_turn_end_uses_settled_memo_without_a_deep_read
t7_herdr_push_consults_the_shared_ledger
t9_nonworking_boundary_clears_inherited_wedge_timing
t10_t11_working_reversal_preserves_ledger_and_new_result_surfaces
t12_t14_decision_identity_survives_run_flaps_and_reopens
t15_repark_collision_is_bounded_by_the_resurface_window
t16_t18_nonoccurrence_visibility_contracts
t18_unknown_retains_wedge_timing_until_visibility
t19_merge_poll_artifacts_are_independent
t20_cleanup_refusal_keeps_task_visible
t22_enqueue_before_record_replays_toward_a_duplicate
t22_push_records_only_the_bound_occurrence
t22_afk_handoff_stays_pending_until_daemon_buffering

echo "all fm-lifecycle-ledger tests passed"
