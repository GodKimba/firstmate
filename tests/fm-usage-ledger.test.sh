#!/usr/bin/env bash
# Behavior tests for the durable task-usage ledger: bin/fm-usage-ledger.sh's own
# executable interface, and the lifecycle instrumentation that writes to it.
#
# The gap being closed: a task's harness, model, effort, kind, project, delivery
# mode, autonomy posture, and backend live only in state/<id>.meta, which
# ordinary successful cleanup deletes, so no merged PR could be joined back to
# the model that produced it. These tests pin that the record now outlives
# cleanup, and pin the boundaries that make that safe.
#
# Ledger interface:
#   (a) an empty home opens with an explicit first-observed record, not a backfill
#   (b) a spawn record carries every implementation axis and no private value
#   (c) repeated spawn/pr/merge/cleanup calls are idempotent by event identity
#   (d) a new incarnation, a new PR head, and a new PR are distinct records,
#       and a long PR URL never truncates two of them into one false duplicate
#   (d1) a nested self-hosted merge request URL past the label bound still gets
#        its row, and one past the PR bound is refused rather than truncated
#        into a different real merge request and recorded as fact
#   (d2) a status class captured before its log is retired is the class recorded
#   (d3) a renamed status verb is recorded in this home's spelling, and a status
#        log that cannot be read - unsafe, or in a directory that is gone -
#        is unknown rather than none
#   (e) absent inputs record "" (not applicable) or "unknown" (unproven), never a guess
#   (f) concurrent writers neither lose a record nor reuse a sequence number
#   (g) symlinked, hardlinked, non-regular, and wrong-mode targets refuse unwritten,
#       and no verb ever recreates a home a retirement already removed
#   (h) a malformed store refuses every verb and keeps its bytes, and an append
#       reads only the records it needs, so `verify` is what finds the rest
#   (i) a future schema version is preserved rather than declared malformed
#   (j) retention keeps first-observed plus the horizon, atomically and at 0600
#   (k) invalid events, task ids, outcomes, URLs, and hashes refuse before writing
#
# Lifecycle instrumentation, driven through the real scripts:
#   (l) a real spawn then a real teardown leave spawn and cleanup records behind,
#       with the task's axes and its final status class intact after
#       state/<id>.meta and state/<id>.status are gone, including a secondmate
#       retirement that removes the very home its status log lived in
#   (m) a REFUSED teardown records no cleanup, because its task is still live
#   (n) fm-pr-check records the canonical PR and the forge's head when it has one
#   (o) fm-merge-local records the landing commit for an approved local landing
#   (p) a ledger write failure never turns a completed lifecycle step into one,
#       and an unreadable status class is reported rather than silently guessed
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
fm_git_identity fmtest fmtest@example.invalid

LEDGER="$ROOT/bin/fm-usage-ledger.sh"
SPAWN="$ROOT/bin/fm-spawn.sh"
TEARDOWN="$ROOT/bin/fm-teardown.sh"
PR_CHECK="$ROOT/bin/fm-pr-check.sh"
MERGE_LOCAL="$ROOT/bin/fm-merge-local.sh"
TMP_ROOT=$(fm_test_tmproot fm-usage-ledger)

# --- ledger-interface helpers ----------------------------------------------

# make_home <name>: a bare home with data/ and state/. Echoes the home path.
make_home() {
  local home="$TMP_ROOT/$1"
  mkdir -p "$home/data" "$home/state"
  printf '%s\n' "$home"
}

# ledger <home> <args...>: run the ledger scoped to that home.
ledger() {
  local home=$1
  shift
  FM_ROOT_OVERRIDE='' FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    "$LEDGER" "$@"
}

store() { printf '%s\n' "$1/data/task-usage.jsonl"; }

# write_task_meta <home> <id> [key=value...]: a realistic task record whose
# private fields (worktree, tasktmp, traceparent, relay request) must never
# reach the ledger.
write_task_meta() {
  local home=$1 id=$2
  shift 2
  fm_write_meta "$home/state/$id.meta" \
    "window=firstmate:fm-$id" \
    "endpoint_task_id=$id" \
    "worktree=$home/secret-worktree-path" \
    "project=$home/projects/nutricheck" \
    "harness=claude" \
    "kind=ship" \
    "mode=no-mistakes" \
    "yolo=off" \
    "tasktmp=/tmp/fm-$id" \
    "model=opus" \
    "effort=high" \
    "spawn_gen=s1700.42.7" \
    "traceparent=00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01" \
    "x_request=relay-request-secret" \
    "$@"
}

# field <line> <key>: read one string field out of a ledger record.
field() {
  printf '%s' "$1" | sed -n "s/.*\"$2\":\"\([^\"]*\)\".*/\1/p"
}

# record_for <home> <event-id>: the record whose id is exactly <event-id>.
record_for() {
  grep -F "\"id\":\"$2\"" "$(store "$1")" 2>/dev/null | head -1
}

# --- (a) first observed, never backfilled -----------------------------------

test_ledger_opens_with_an_explicit_first_observed_record() {
  local home out first opened
  home=$(make_home first-observed)

  out=$(ledger "$home" verify) || fail "verify failed on an empty home"
  assert_contains "$out" "records=0 first_observed=none" \
    "an unopened ledger should report no coverage at all"
  assert_absent "$(store "$home")" "verify created a store"

  ledger "$home" record --event spawn --task alpha-x1 --gen g1 >/dev/null \
    || fail "first record failed"
  first=$(head -1 "$(store "$home")")
  [ "$(field "$first" event)" = ledger-open ] \
    || fail "the first record is not the explicit coverage marker: $first"
  opened=$(printf '%s' "$first" | sed -n 's/.*"at":\([0-9]*\).*/\1/p')
  [ -n "$opened" ] && [ "$opened" -gt 0 ] \
    || fail "the coverage marker carries no first-observed timestamp: $first"
  out=$(ledger "$home" verify)
  assert_contains "$out" "first_observed=$opened" \
    "verify does not report the recorded coverage start"
  [ "$(wc -l < "$(store "$home")")" = 2 ] \
    || fail "opening the ledger invented history beyond the marker and the record"
  pass "a new ledger opens with an explicit first-observed record and no backfill"
}

# --- (b) axes preserved, private values excluded ----------------------------

test_spawn_record_keeps_every_axis_and_no_private_value() {
  local home rec store_path
  home=$(make_home axes)
  write_task_meta "$home" alpha-x1 "backend=herdr"
  ledger "$home" record --event spawn --task alpha-x1 \
    --meta "$home/state/alpha-x1.meta" >/dev/null || fail "spawn record failed"
  rec=$(record_for "$home" "spawn:alpha-x1:s1700.42.7")
  [ -n "$rec" ] || fail "no spawn record was written"

  [ "$(field "$rec" task)" = alpha-x1 ] || fail "task not recorded: $rec"
  [ "$(field "$rec" gen)" = s1700.42.7 ] || fail "incarnation not recorded: $rec"
  [ "$(field "$rec" kind)" = ship ] || fail "kind not recorded: $rec"
  [ "$(field "$rec" harness)" = claude ] || fail "harness not recorded: $rec"
  [ "$(field "$rec" model)" = opus ] || fail "model not recorded: $rec"
  [ "$(field "$rec" effort)" = high ] || fail "effort not recorded: $rec"
  [ "$(field "$rec" project)" = nutricheck ] || fail "project not recorded: $rec"
  [ "$(field "$rec" mode)" = no-mistakes ] || fail "delivery mode not recorded: $rec"
  [ "$(field "$rec" yolo)" = off ] || fail "autonomy posture not recorded: $rec"
  [ "$(field "$rec" backend)" = herdr ] || fail "backend not recorded: $rec"

  store_path=$(store "$home")
  assert_no_grep "secret-worktree-path" "$store_path" "the worktree path reached the ledger"
  assert_no_grep "/tmp/fm-alpha-x1" "$store_path" "a temporary path reached the ledger"
  assert_no_grep "4bf92f3577b34da6a3ce929d0e0e4736" "$store_path" "a trace carrier reached the ledger"
  assert_no_grep "relay-request-secret" "$store_path" "a private relay payload reached the ledger"
  assert_no_grep "$home/projects" "$store_path" "the project PATH reached the ledger"
  pass "a spawn record preserves every implementation axis and no private value"
}

test_backend_defaults_to_the_documented_tmux_contract() {
  local home rec
  home=$(make_home backend-default)
  write_task_meta "$home" alpha-x1
  ledger "$home" record --event spawn --task alpha-x1 \
    --meta "$home/state/alpha-x1.meta" >/dev/null || fail "spawn record failed"
  rec=$(record_for "$home" "spawn:alpha-x1:s1700.42.7")
  [ "$(field "$rec" backend)" = tmux ] \
    || fail "an absent backend= should read as the default backend: $rec"
  pass "an absent backend field resolves through the documented tmux default"
}

test_final_status_class_is_the_verb_only() {
  local home rec
  home=$(make_home status-class)
  write_task_meta "$home" alpha-x1
  printf '%s\n' \
    'working: implementing' \
    'done: PR https://github.com/o/r/pull/7 checks green, captain notes were sensitive' \
    > "$home/state/alpha-x1.status"
  ledger "$home" record --event cleanup --task alpha-x1 \
    --meta "$home/state/alpha-x1.meta" --outcome landed \
    --status-file "$home/state/alpha-x1.status" >/dev/null || fail "cleanup record failed"
  rec=$(record_for "$home" "cleanup:alpha-x1:s1700.42.7")
  [ "$(field "$rec" status_class)" = "done" ] || fail "final status class not recorded: $rec"
  assert_no_grep "captain notes were sensitive" "$(store "$home")" \
    "the free-form status note reached the ledger"

  # A line with no recognised verb is unproven, never invented prose.
  home=$(make_home status-class-prose)
  write_task_meta "$home" alpha-x1
  printf '%s\n' 'the crew wandered off' > "$home/state/alpha-x1.status"
  ledger "$home" record --event cleanup --task alpha-x1 \
    --meta "$home/state/alpha-x1.meta" --outcome discarded \
    --status-file "$home/state/alpha-x1.status" >/dev/null || fail "cleanup record failed"
  rec=$(record_for "$home" "cleanup:alpha-x1:s1700.42.7")
  [ "$(field "$rec" status_class)" = unknown ] \
    || fail "an unrecognised status verb should read unknown: $rec"
  assert_no_grep "wandered off" "$(store "$home")" "status prose reached the ledger"

  # No status log at all is a different, honest answer.
  home=$(make_home status-class-none)
  write_task_meta "$home" alpha-x1
  ledger "$home" record --event cleanup --task alpha-x1 \
    --meta "$home/state/alpha-x1.meta" --outcome landed \
    --status-file "$home/state/alpha-x1.status" >/dev/null || fail "cleanup record failed"
  rec=$(record_for "$home" "cleanup:alpha-x1:s1700.42.7")
  [ "$(field "$rec" status_class)" = none ] \
    || fail "a task with no status log should read none: $rec"
  pass "only the final status verb is stored, and its absence is stated honestly"
}

test_a_class_captured_before_the_log_is_retired_is_recorded() {
  local home captured rec rc
  home=$(make_home status-class-captured)
  write_task_meta "$home" alpha-x1
  printf '%s\n' \
    'working: implementing' \
    'done: PR https://github.com/o/r/pull/7 checks green, captain notes were sensitive' \
    > "$home/state/alpha-x1.status"

  captured=$(ledger "$home" status-class --status-file "$home/state/alpha-x1.status") \
    || fail "reading the final status class failed"
  [ "$captured" = "done" ] || fail "the captured class is not the final verb: $captured"
  assert_absent "$(store "$home")" "reading a status class touched the ledger"

  # A caller whose own cleanup retires the log before it records: the captured
  # class is what must land, not the "none" the deleted log would now report.
  rm -f "$home/state/alpha-x1.status"
  ledger "$home" record --event cleanup --task alpha-x1 \
    --meta "$home/state/alpha-x1.meta" --outcome landed \
    --status-class "$captured" >/dev/null || fail "cleanup record failed"
  rec=$(record_for "$home" "cleanup:alpha-x1:s1700.42.7")
  [ "$(field "$rec" status_class)" = "done" ] \
    || fail "the captured class was not the class recorded: $rec"
  assert_no_grep "captain notes were sensitive" "$(store "$home")" \
    "the free-form status note reached the ledger"

  # Only the closed vocabulary, and never two sources of the same field.
  set +e
  ledger "$home" record --event cleanup --task beta-x1 --gen g1 \
    --status-class shipped >/dev/null 2>&1
  rc=$?
  set -e
  expect_code 2 "$rc" "an unknown status class should be refused"
  set +e
  ledger "$home" record --event cleanup --task beta-x1 --gen g1 \
    --status-class "done" --status-file "$home/state/beta-x1.status" >/dev/null 2>&1
  rc=$?
  set -e
  expect_code 2 "$rc" "a class and a log together should be refused"
  pass "a status class captured before its log is retired is the class recorded"
}

test_a_renamed_status_verb_is_recorded_in_the_homes_spelling() {
  local home rec class
  home=$(make_home status-class-renamed)
  write_task_meta "$home" alpha-x1
  printf '%s\n' 'waiting: vendor reply' > "$home/state/alpha-x1.status"

  # This home renames the pause verb, so "waiting" IS its recognised class.
  FM_ROOT_OVERRIDE='' FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" \
    FM_DATA_OVERRIDE="$home/data" FM_CLASSIFY_PAUSED_VERB=waiting \
    "$LEDGER" record --event cleanup --task alpha-x1 \
    --meta "$home/state/alpha-x1.meta" --outcome landed \
    --status-file "$home/state/alpha-x1.status" >/dev/null \
    || fail "a cleanup under a renamed pause verb failed"
  rec=$(record_for "$home" "cleanup:alpha-x1:s1700.42.7")
  [ "$(field "$rec" status_class)" = waiting ] \
    || fail "a renamed pause verb should be recorded in this home's spelling: $rec"

  # The two-step a teardown actually takes: capture the class, then hand it back.
  home=$(make_home status-class-renamed-captured)
  write_task_meta "$home" alpha-x1
  printf '%s\n' 'waiting: vendor reply' > "$home/state/alpha-x1.status"
  class=$(FM_ROOT_OVERRIDE='' FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" \
    FM_DATA_OVERRIDE="$home/data" FM_CLASSIFY_PAUSED_VERB=waiting \
    "$LEDGER" status-class --status-file "$home/state/alpha-x1.status")
  [ "$class" = waiting ] || fail "status-class did not resolve the renamed verb: $class"
  FM_ROOT_OVERRIDE='' FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" \
    FM_DATA_OVERRIDE="$home/data" FM_CLASSIFY_PAUSED_VERB=waiting \
    "$LEDGER" record --event cleanup --task alpha-x1 \
    --meta "$home/state/alpha-x1.meta" --outcome landed \
    --status-class "$class" >/dev/null \
    || fail "a captured renamed class was refused by record"
  rec=$(record_for "$home" "cleanup:alpha-x1:s1700.42.7")
  [ "$(field "$rec" status_class)" = waiting ] \
    || fail "a captured renamed class was not recorded: $rec"
  pass "a home's renamed status verb is recorded in its own spelling"
}

test_an_unreadable_status_log_is_unknown_rather_than_none() {
  local home rec
  home=$(make_home status-class-unsafe)
  write_task_meta "$home" alpha-x1
  printf '%s\n' 'done: landed' > "$home/state/alpha-x1.status.real"
  # The log is there, so its class is unproven rather than absent: recording
  # "none" would claim the task logged nothing, which nothing established.
  ln -s "$home/state/alpha-x1.status.real" "$home/state/alpha-x1.status"

  ledger "$home" record --event cleanup --task alpha-x1 \
    --meta "$home/state/alpha-x1.meta" --outcome landed \
    --status-file "$home/state/alpha-x1.status" >/dev/null \
    || fail "an unsafe status log should not fail the record"
  rec=$(record_for "$home" "cleanup:alpha-x1:s1700.42.7")
  [ "$(field "$rec" status_class)" = unknown ] \
    || fail "a status log that could not be read should be unknown: $rec"

  # Only a status directory that is still there can establish that the task
  # logged nothing. A retirement that removed the directory proved no such
  # thing, so its class is unproven rather than an absence.
  home=$(make_home status-class-dir-gone)
  write_task_meta "$home" alpha-x1
  ledger "$home" record --event cleanup --task alpha-x1 \
    --meta "$home/state/alpha-x1.meta" --outcome retired \
    --status-file "$TMP_ROOT/status-class-dir-gone-removed/alpha-x1.status" >/dev/null \
    || fail "a status log whose directory is gone should not fail the record"
  rec=$(record_for "$home" "cleanup:alpha-x1:s1700.42.7")
  [ "$(field "$rec" status_class)" = unknown ] \
    || fail "a status log whose directory is gone should be unknown: $rec"
  pass "a status log that cannot be read records unknown, not none"
}

# --- (c) and (d) idempotency and distinct events ----------------------------

test_repeated_lifecycle_calls_are_idempotent() {
  local home out before after
  home=$(make_home idempotent)
  write_task_meta "$home" alpha-x1
  local meta="$home/state/alpha-x1.meta"
  local url=https://github.com/example/repo/pull/7
  local head=1111111111111111111111111111111111111111

  ledger "$home" record --event spawn --task alpha-x1 --meta "$meta" >/dev/null
  ledger "$home" record --event pr --task alpha-x1 --meta "$meta" --pr "$url" --pr-head "$head" >/dev/null
  ledger "$home" record --event merge --task alpha-x1 --meta "$meta" --pr "$url" --outcome merged >/dev/null
  ledger "$home" record --event cleanup --task alpha-x1 --meta "$meta" --outcome landed >/dev/null
  before=$(wc -l < "$(store "$home")")

  out=$(ledger "$home" record --event spawn --task alpha-x1 --meta "$meta") \
    || fail "a repeated spawn should succeed as a no-op"
  [ "$out" = duplicate ] || fail "a repeated spawn was not reported as a duplicate: $out"
  out=$(ledger "$home" record --event pr --task alpha-x1 --meta "$meta" --pr "$url" --pr-head "$head")
  [ "$out" = duplicate ] || fail "a repeated PR registration was not a duplicate: $out"
  out=$(ledger "$home" record --event merge --task alpha-x1 --meta "$meta" --pr "$url" --outcome merged)
  [ "$out" = duplicate ] || fail "a repeated merge notification was not a duplicate: $out"
  out=$(ledger "$home" record --event cleanup --task alpha-x1 --meta "$meta" --outcome landed)
  [ "$out" = duplicate ] || fail "a repeated cleanup was not a duplicate: $out"

  after=$(wc -l < "$(store "$home")")
  [ "$before" = "$after" ] || fail "retried calls grew the ledger from $before to $after"
  pass "repeated spawn, PR, merge, and cleanup calls are idempotent by event identity"
}

test_distinct_events_append_distinct_records() {
  local home meta url other_url head other_head
  home=$(make_home distinct)
  write_task_meta "$home" alpha-x1
  meta="$home/state/alpha-x1.meta"
  url=https://github.com/example/repo/pull/7
  other_url=https://github.com/example/repo/pull/8
  head=1111111111111111111111111111111111111111
  other_head=2222222222222222222222222222222222222222

  ledger "$home" record --event spawn --task alpha-x1 --meta "$meta" >/dev/null
  # A replacement worker mints a new incarnation, so it is its own record.
  sed -i.bak 's/^spawn_gen=.*/spawn_gen=s1700.42.8/' "$meta" && rm -f "$meta.bak"
  ledger "$home" record --event spawn --task alpha-x1 --meta "$meta" >/dev/null
  [ -n "$(record_for "$home" "spawn:alpha-x1:s1700.42.7")" ] \
    || fail "the first incarnation's record was lost"
  [ -n "$(record_for "$home" "spawn:alpha-x1:s1700.42.8")" ] \
    || fail "a relaunched incarnation did not get its own record"

  ledger "$home" record --event pr --task alpha-x1 --meta "$meta" --pr "$url" --pr-head "$head" >/dev/null
  ledger "$home" record --event pr --task alpha-x1 --meta "$meta" --pr "$url" --pr-head "$other_head" >/dev/null
  [ "$(grep -cF '"event":"pr"' "$(store "$home")")" = 2 ] \
    || fail "a re-pushed PR head did not append a distinct record"

  ledger "$home" record --event merge --task alpha-x1 --meta "$meta" --pr "$url" --outcome merged >/dev/null
  ledger "$home" record --event merge --task alpha-x1 --meta "$meta" --pr "$other_url" --outcome merged >/dev/null
  [ "$(grep -cF '"event":"merge"' "$(store "$home")")" = 2 ] \
    || fail "a second PR for the same task did not append a distinct merge record"
  pass "a new incarnation, a new PR head, and a new PR each append their own record"
}

test_a_long_pr_url_still_distinguishes_a_re_pushed_head() {
  local home meta url head other_head out
  home=$(make_home long-identity)
  write_task_meta "$home" alpha-x1
  meta="$home/state/alpha-x1.meta"
  # A self-hosted GitLab merge request under nested subgroups: long enough that
  # a composed identity bounded like a single field would cut the head off and
  # report the second push as a duplicate of the first.
  url=https://gitlab.example.com/nutricheck-platform/clinical-services/nutrition-importer/staged-import-subgroup/backend-services/team-owned-repositories/importer-repository-name/-/merge_requests/7
  head=1111111111111111111111111111111111111111
  other_head=2222222222222222222222222222222222222222

  ledger "$home" record --event pr --task alpha-x1 --meta "$meta" \
    --pr "$url" --pr-head "$head" >/dev/null || fail "the first PR record failed"
  out=$(ledger "$home" record --event pr --task alpha-x1 --meta "$meta" \
    --pr "$url" --pr-head "$other_head") || fail "the re-pushed PR record failed"
  [ "$out" != duplicate ] \
    || fail "a re-pushed head under a long PR URL was reported as a duplicate"
  [ "$(grep -cF '"event":"pr"' "$(store "$home")")" = 2 ] \
    || fail "a re-pushed head under a long PR URL did not append a distinct record"
  [ "$(grep -cF "\"pr_head\":\"$other_head\"" "$(store "$home")")" = 1 ] \
    || fail "the re-pushed head itself was not stored"

  # The same call really is still idempotent at that length.
  out=$(ledger "$home" record --event pr --task alpha-x1 --meta "$meta" \
    --pr "$url" --pr-head "$other_head")
  [ "$out" = duplicate ] \
    || fail "a repeated PR record under a long URL was not a duplicate: $out"
  ledger "$home" verify >/dev/null || fail "a long identity left a malformed store"
  pass "a long PR URL never truncates two distinct events into one false duplicate"
}

test_a_long_self_hosted_merge_request_keeps_its_ledger_row() {
  local home meta url truncated rec
  home=$(make_home long-self-hosted)
  write_task_meta "$home" alpha-x1
  meta="$home/state/alpha-x1.meta"
  # 204 characters: a real nested-subgroup merge request on a self-hosted
  # instance, longer than the free-form label bound but well inside what the
  # forge validator accepts. Losing this row would leave exactly the
  # merged-PR-to-model join this ledger exists to create missing.
  url=https://gitlab.example.com/nutricheck-platform/clinical-services/nutrition-importer/staged-import-subgroup/backend-services/team-owned-repositories/importer-repository-name-longer/-/merge_requests/1234567
  truncated=${url:0:200}
  [ "$truncated" != "$url" ] || fail "the fixture URL no longer exceeds the label bound"

  ledger "$home" record --event pr --task alpha-x1 --meta "$meta" \
    --pr "$url" --pr-head 1111111111111111111111111111111111111111 >/dev/null \
    || fail "a canonical self-hosted merge request URL should be recorded"
  ledger "$home" record --event merge --task alpha-x1 --meta "$meta" \
    --pr "$url" --outcome merged >/dev/null \
    || fail "a canonical self-hosted merge request URL should be recorded on merge"

  [ "$(grep -cF "\"pr\":\"$url\"" "$(store "$home")")" = 2 ] \
    || fail "the merge request was not recorded under its exact URL"
  [ "$(grep -cF "\"pr\":\"$truncated\"" "$(store "$home")")" = 0 ] \
    || fail "a truncated merge request URL reached the store"
  rec=$(record_for "$home" "merge:alpha-x1:$url:-")
  [ -n "$rec" ] || fail "the merge event identity did not carry the whole URL"
  ledger "$home" verify >/dev/null || fail "a long URL left a malformed store"
  pass "a nested self-hosted merge request past the label bound keeps its ledger row"
}

test_a_pr_url_beyond_the_bound_is_refused_rather_than_truncated() {
  local home meta host path url truncated rc a63 a61 seg
  home=$(make_home over-long-identity)
  write_task_meta "$home" alpha-x1
  meta="$home/state/alpha-x1.meta"
  # The widest URL the forge validator can accept is a 253-character host with
  # a 1024-character project path; past that only a request number wider than
  # any real GitLab iid can push a URL over the bound. Built here so the
  # truncation lands inside that number and would otherwise parse as a
  # DIFFERENT, real merge request.
  a63=$(printf '%063d' 0 | tr 0 a)
  a61=$(printf '%061d' 0 | tr 0 a)
  host="$a63.$a63.$a63.$a61"
  seg=$(printf '%0204d' 0 | tr 0 b)
  path="$seg/$seg/$seg/$seg/$seg"
  [ "${#host}" = 253 ] || fail "the fixture host is ${#host} characters, not 253"
  [ "${#path}" = 1024 ] || fail "the fixture path is ${#path} characters, not 1024"
  url="https://$host/$path/-/merge_requests/12345678901"
  truncated=${url:0:1314}
  [ "${truncated##*/}" = 1234567890 ] \
    || fail "the fixture URL no longer truncates inside its merge request number"

  set +e
  ledger "$home" record --event pr --task alpha-x1 --meta "$meta" \
    --pr "$url" --pr-head 1111111111111111111111111111111111111111 >/dev/null 2>&1
  rc=$?
  set -e
  expect_code 2 "$rc" "a PR URL past the bound should be refused as an invalid request"
  assert_absent "$(store "$home")" "a refused PR URL still wrote a record"

  set +e
  ledger "$home" record --event merge --task alpha-x1 --meta "$meta" \
    --pr "$url" --outcome merged >/dev/null 2>&1
  rc=$?
  set -e
  expect_code 2 "$rc" "a merge request URL past the bound should be refused"
  assert_absent "$(store "$home")" "a refused merge request URL still wrote a record"
  pass "a PR URL past the bound is refused, never truncated into a different one"
}

# --- (e) missing fields --------------------------------------------------

test_missing_inputs_are_stated_rather_than_guessed() {
  local home rec
  home=$(make_home missing-fields)

  # No task record at all: every axis it would have supplied is unproven.
  ledger "$home" record --event merge --task ghost-x1 \
    --meta "$home/state/ghost-x1.meta" \
    --pr https://github.com/example/repo/pull/9 --outcome merged >/dev/null \
    || fail "a merge with no task record should still be recorded"
  rec=$(grep -F '"task":"ghost-x1"' "$(store "$home")" | head -1)
  [ "$(field "$rec" harness)" = unknown ] || fail "an unreadable harness should be unknown: $rec"
  [ "$(field "$rec" model)" = unknown ] || fail "an unreadable model should be unknown: $rec"
  [ "$(field "$rec" gen)" = unknown ] || fail "an unreadable incarnation should be unknown: $rec"
  [ "$(field "$rec" pr)" = https://github.com/example/repo/pull/9 ] \
    || fail "the proven PR identity was dropped with the unproven axes: $rec"

  # The no-mistakes validator is never inferred from the implementer.
  home=$(make_home validator)
  write_task_meta "$home" alpha-x1
  ledger "$home" record --event cleanup --task alpha-x1 \
    --meta "$home/state/alpha-x1.meta" --outcome landed >/dev/null
  rec=$(record_for "$home" "cleanup:alpha-x1:s1700.42.7")
  [ "$(field "$rec" harness)" = claude ] || fail "implementer harness missing: $rec"
  [ "$(field "$rec" validator_harness)" = unknown ] \
    || fail "the validator harness was inferred from the implementer: $rec"
  [ "$(field "$rec" validator_model)" = unknown ] \
    || fail "the validator model was inferred from the implementer: $rec"

  # A caller that CAN prove the validator records it separately.
  ledger "$home" record --event cleanup --task beta-x1 \
    --meta "$home/state/alpha-x1.meta" --gen other --outcome landed \
    --validator-harness codex --validator-model gpt-5 >/dev/null
  rec=$(record_for "$home" "cleanup:beta-x1:other")
  [ "$(field "$rec" validator_model)" = gpt-5 ] \
    || fail "a proven validator identity was not kept apart from the implementer: $rec"
  [ "$(field "$rec" model)" = opus ] \
    || fail "a proven validator identity overwrote the implementer's model: $rec"

  # A scout carries no delivery posture; that is not-applicable, not unproven.
  home=$(make_home scout-fields)
  fm_write_meta "$home/state/scout-x1.meta" \
    "project=$home/projects/alpha" "harness=pi" "kind=scout" \
    "model=default" "effort=default" "spawn_gen=s1"
  ledger "$home" record --event spawn --task scout-x1 \
    --meta "$home/state/scout-x1.meta" >/dev/null
  rec=$(record_for "$home" "spawn:scout-x1:s1")
  [ "$(field "$rec" kind)" = scout ] || fail "scout kind not recorded: $rec"
  [ -z "$(field "$rec" mode)" ] || fail "a scout should record no delivery mode: $rec"
  [ -z "$(field "$rec" yolo)" ] || fail "a scout should record no autonomy posture: $rec"
  pass "unreadable axes read unknown, absent ones read empty, and nothing is inferred"
}

# --- (f) concurrency --------------------------------------------------------

test_concurrent_writers_lose_no_record_and_reuse_no_sequence() {
  local home i seqs total
  home=$(make_home concurrent)
  write_task_meta "$home" alpha-x1
  for i in $(seq 1 24); do
    ledger "$home" record --event spawn --task "task-$i" --gen "g$i" \
      --meta "$home/state/alpha-x1.meta" >/dev/null &
  done
  wait
  total=$(wc -l < "$(store "$home")")
  [ "$total" = 25 ] || fail "24 concurrent writers plus the marker produced $total records"
  seqs=$(sed -n 's/^{"v":1,"seq":\([0-9]*\),.*/\1/p' "$(store "$home")" | sort -n -u | wc -l)
  [ "$seqs" = 25 ] || fail "concurrent writers reused a sequence number ($seqs distinct of $total)"
  for i in $(seq 1 24); do
    [ -n "$(record_for "$home" "spawn:task-$i:g$i")" ] || fail "concurrent record task-$i was lost"
  done
  ledger "$home" verify >/dev/null || fail "concurrent writers left a malformed store"
  pass "concurrent writers lose no record and never reuse a sequence number"
}

# --- (g) unsafe targets and permissions -------------------------------------

test_unsafe_targets_refuse_without_writing() {
  local home path rc outside
  home=$(make_home unsafe)
  write_task_meta "$home" alpha-x1
  path=$(store "$home")
  outside="$TMP_ROOT/unsafe-outside"
  printf 'untouched\n' > "$outside"

  # A symlinked store must never be followed.
  ln -s "$outside" "$path"
  set +e
  ledger "$home" record --event spawn --task alpha-x1 --meta "$home/state/alpha-x1.meta" >/dev/null 2>&1
  rc=$?
  set -e
  expect_code 1 "$rc" "a symlinked ledger should refuse"
  [ "$(cat "$outside")" = untouched ] || fail "a symlinked ledger was followed and written through"
  rm -f "$path"

  # A hardlinked store shares bytes with another name.
  printf '{"v":1,"seq":1,"at":1,"event":"ledger-open","id":"ledger-open","task":"","gen":"","kind":"","harness":"","model":"","effort":"","project":"","mode":"","yolo":"","backend":"","pr":"","pr_head":"","landing":"","outcome":"","status_class":"","validator_harness":"","validator_model":""}\n' > "$path"
  chmod 0600 "$path"
  ln "$path" "$TMP_ROOT/unsafe-hardlink"
  set +e
  ledger "$home" record --event spawn --task alpha-x1 --meta "$home/state/alpha-x1.meta" >/dev/null 2>&1
  rc=$?
  set -e
  expect_code 1 "$rc" "a hardlinked ledger should refuse"
  rm -f "$TMP_ROOT/unsafe-hardlink"

  # A world-readable store is not a private record.
  chmod 0644 "$path"
  set +e
  ledger "$home" record --event spawn --task alpha-x1 --meta "$home/state/alpha-x1.meta" >/dev/null 2>&1
  rc=$?
  set -e
  expect_code 1 "$rc" "a ledger at the wrong mode should refuse"

  # A non-regular store is refused too.
  rm -f "$path"
  mkdir "$path"
  set +e
  ledger "$home" record --event spawn --task alpha-x1 --meta "$home/state/alpha-x1.meta" >/dev/null 2>&1
  rc=$?
  set -e
  expect_code 1 "$rc" "a non-regular ledger should refuse"
  rmdir "$path"

  # A symlinked data directory is refused before any path is derived from it.
  mkdir -p "$TMP_ROOT/unsafe-link-home"
  ln -s "$home/data" "$TMP_ROOT/unsafe-link-home/data"
  set +e
  FM_ROOT_OVERRIDE='' FM_HOME="$TMP_ROOT/unsafe-link-home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$TMP_ROOT/unsafe-link-home/data" \
    "$LEDGER" record --event spawn --task alpha-x1 >/dev/null 2>&1
  rc=$?
  set -e
  expect_code 1 "$rc" "a symlinked data directory should refuse"
  pass "symlinked, hardlinked, non-regular, and wrong-mode targets refuse without writing"
}

test_a_created_store_is_private() {
  local home
  home=$(make_home permissions)
  ( umask 000; ledger "$home" record --event spawn --task alpha-x1 --gen g1 >/dev/null ) \
    || fail "record failed"
  [ "$(stat -c %a "$(store "$home")" 2>/dev/null || stat -f %Lp "$(store "$home")")" = 600 ] \
    || fail "the ledger was created world-readable despite a permissive umask"
  pass "the ledger is created private regardless of the caller's umask"
}

test_no_verb_recreates_a_home_a_retirement_removed() {
  local home retired out rec
  home=$(make_home not-resurrected)
  retired="$TMP_ROOT/not-resurrected-retired"
  mkdir -p "$retired/state"
  printf 'done: landed\n' > "$retired/state/beta-x1.status"
  # A secondmate retirement removes the home carrying the overridden control
  # state directory and still records its cleanup. Instrumentation must record
  # honestly, never put the removed home back.
  rm -rf "$retired"

  out=$(FM_ROOT_OVERRIDE='' FM_HOME="$home" FM_STATE_OVERRIDE="$retired/state" \
    FM_DATA_OVERRIDE="$home/data" \
    "$LEDGER" status-class --status-file "$retired/state/beta-x1.status") \
    || fail "status-class should not fail for a removed home"
  [ "$out" = unknown ] \
    || fail "a status log in a removed home should read unknown: $out"
  assert_absent "$retired" "the status-class verb recreated a removed home"

  FM_ROOT_OVERRIDE='' FM_HOME="$home" FM_STATE_OVERRIDE="$retired/state" \
    FM_DATA_OVERRIDE="$home/data" \
    "$LEDGER" record --event cleanup --task beta-x1 --outcome retired \
    --status-class unknown >/dev/null \
    || fail "a cleanup for a removed home should still be recorded"
  rec=$(record_for "$home" "cleanup:beta-x1:unknown")
  [ -n "$rec" ] || fail "the retirement cleanup was not recorded"
  assert_absent "$retired" "recording a cleanup recreated a removed home"
  pass "no ledger verb recreates a home a retirement already removed"
}

# --- (h) and (i) malformed and future records -------------------------------

test_a_malformed_store_refuses_every_verb_and_keeps_its_bytes() {
  local home path rc before
  home=$(make_home malformed)
  write_task_meta "$home" alpha-x1
  path=$(store "$home")
  ledger "$home" record --event spawn --task alpha-x1 --meta "$home/state/alpha-x1.meta" >/dev/null
  printf 'this line is not a ledger record\n' >> "$path"
  before=$(cat "$path")

  for verb in record verify prune; do
    set +e
    case "$verb" in
      record) ledger "$home" record --event cleanup --task alpha-x1 --outcome landed >/dev/null 2>&1 ;;
      *) ledger "$home" "$verb" >/dev/null 2>&1 ;;
    esac
    rc=$?
    set -e
    expect_code 1 "$rc" "$verb should refuse a malformed ledger"
  done
  [ "$(cat "$path")" = "$before" ] || fail "a malformed ledger lost or gained bytes"
  pass "a malformed ledger stops every verb safely and keeps its bytes"
}

test_an_append_reads_only_the_records_it_needs() {
  local home path meta out rc
  home=$(make_home probe-scope)
  write_task_meta "$home" alpha-x1
  meta="$home/state/alpha-x1.meta"
  path=$(store "$home")
  ledger "$home" record --event spawn --task alpha-x1 --meta "$meta" >/dev/null
  ledger "$home" record --event pr --task alpha-x1 --meta "$meta" \
    --pr https://github.com/example/repo/pull/7 >/dev/null

  # Damage the spawn record in the MIDDLE of the store. An append reads the last
  # record plus any carrying its own identity, so it never sees this one and
  # extends the store past it; `verify` is the verb that finds it.
  sed -i.bak '2s/.*/this line is not a ledger record/' "$path" && rm -f "$path.bak"
  ledger "$home" record --event cleanup --task alpha-x1 --meta "$meta" --outcome landed >/dev/null \
    || fail "an append should not read a malformed record it has no reason to read"
  [ -n "$(record_for "$home" "cleanup:alpha-x1:s1700.42.7")" ] \
    || fail "the cleanup record was not appended past the damaged record"
  assert_grep 'this line is not a ledger record' "$path" \
    "the append rewrote the damaged record instead of leaving its bytes alone"

  set +e
  out=$(ledger "$home" verify 2>&1)
  rc=$?
  set -e
  expect_code 1 "$rc" "verify should refuse a store damaged anywhere"
  assert_contains "$out" "record 2 is malformed" "verify did not name the damaged record: $out"
  pass "an append reads only the records it needs and verify is what proves the rest"
}

test_a_future_schema_record_is_preserved_not_rejected() {
  local home path out
  home=$(make_home future-version)
  ledger "$home" record --event spawn --task alpha-x1 --gen g1 >/dev/null
  path=$(store "$home")
  printf '{"v":2,"seq":3,"at":%s,"event":"spawn","id":"spawn:future-x1:g9","task":"future-x1","tokens":12}\n' \
    "$(date +%s)" >> "$path"
  out=$(ledger "$home" verify) || fail "a future-version record should not be malformed"
  assert_contains "$out" "records=3" "the future-version record was not counted"
  ledger "$home" record --event cleanup --task alpha-x1 --gen g1 --outcome landed >/dev/null \
    || fail "a future-version record blocked an append"
  ledger "$home" prune >/dev/null || fail "prune refused a future-version record"
  assert_grep '"v":2' "$path" "prune discarded a newer writer's record"
  pass "a newer schema version is preserved rather than declared malformed"
}

# --- (j) retention ----------------------------------------------------------

test_retention_keeps_first_observed_and_the_horizon() {
  local home path out old
  home=$(make_home retention)
  write_task_meta "$home" alpha-x1
  ledger "$home" record --event spawn --task old-x1 --gen g-old \
    --meta "$home/state/alpha-x1.meta" >/dev/null
  ledger "$home" record --event spawn --task recent-x1 --gen g-new \
    --meta "$home/state/alpha-x1.meta" >/dev/null
  path=$(store "$home")

  # Age the first task's record past a 400-day horizon, leaving its bytes
  # otherwise identical.
  old=$(( $(date +%s) - 500 * 86400 ))
  sed -i.bak "s/\(\"id\":\"spawn:old-x1:g-old\"\)/\1/; s/^\({\"v\":1,\"seq\":2,\)\"at\":[0-9]*/\1\"at\":$old/" "$path"
  rm -f "$path.bak"

  out=$(ledger "$home" prune) || fail "prune failed"
  assert_contains "$out" "pruned 1 kept 2" "retention did not drop exactly the aged record"
  [ -z "$(record_for "$home" "spawn:old-x1:g-old")" ] || fail "an aged record survived retention"
  [ -n "$(record_for "$home" "spawn:recent-x1:g-new")" ] || fail "a fresh record was pruned"
  [ "$(field "$(head -1 "$path")" event)" = ledger-open ] \
    || fail "retention discarded the first-observed marker"
  [ "$(stat -c %a "$path" 2>/dev/null || stat -f %Lp "$path")" = 600 ] \
    || fail "retention republished the ledger at the wrong mode"
  ledger "$home" verify >/dev/null || fail "retention left a malformed store"

  # A shorter explicit horizon is honored; a 30-day comparison still resolves.
  out=$(FM_USAGE_LEDGER_RETENTION_DAYS=1 ledger "$home" prune)
  assert_contains "$out" "pruned 0" "a same-day record was dropped by a one-day horizon"
  pass "retention keeps the first-observed marker plus its horizon, atomically and privately"
}

test_recording_never_rewrites_history() {
  local home path before
  home=$(make_home no-opportunistic-rewrite)
  write_task_meta "$home" alpha-x1
  ledger "$home" record --event spawn --task old-x1 --gen g-old \
    --meta "$home/state/alpha-x1.meta" >/dev/null
  path=$(store "$home")
  sed -i.bak "s/^\({\"v\":1,\"seq\":2,\)\"at\":[0-9]*/\1\"at\":1000000000/" "$path"
  rm -f "$path.bak"
  before=$(cat "$path")

  FM_USAGE_LEDGER_RETENTION_DAYS=1 ledger "$home" record --event cleanup \
    --task new-x1 --gen g-new --outcome landed >/dev/null || fail "record failed"
  while IFS= read -r line; do
    grep -Fqx -- "$line" "$path" || fail "an unrelated task mutation rewrote history"
  done <<EOF
$before
EOF
  pass "recording one task never applies retention to another task's history"
}

# --- (k) invalid input ------------------------------------------------------

test_invalid_requests_refuse_before_writing() {
  local home rc label args
  home=$(make_home invalid)
  while IFS='|' read -r label args; do
    [ -n "$label" ] || continue
    set +e
    # shellcheck disable=SC2086  # args is an intentional word-split arg list
    ledger "$home" record $args >/dev/null 2>&1
    rc=$?
    set -e
    expect_code 2 "$rc" "$label should be refused as an invalid request"
  done <<'ROWS'
an unknown event|--event landed --task alpha-x1
a missing event|--task alpha-x1
a path-unsafe task id|--event spawn --task ../escape
an unknown outcome|--event cleanup --task alpha-x1 --outcome shipped
a non-canonical PR URL|--event pr --task alpha-x1 --pr https://github.com/o/r/pulls/7
a short PR head|--event pr --task alpha-x1 --pr https://github.com/o/r/pull/7 --pr-head abc123
a non-hash landing|--event merge --task alpha-x1 --landing HEAD
an unknown option|--event spawn --task alpha-x1 --tokens 900
ROWS
  assert_absent "$(store "$home")" "an invalid request created the ledger"
  pass "invalid events, ids, outcomes, URLs, and hashes refuse before anything is written"
}

# --- lifecycle integration --------------------------------------------------

# Fake tmux for a spawn: answers the pane-path query, succeeds otherwise.
make_lifecycle_fakebin() {
  local dir=$1 fakebin
  fakebin=$(fm_fakebin "$dir")
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
set -u
case "$*" in
  *"#{pane_current_path}"*) printf '%s\n' "${FM_FAKE_PANE_PATH:-}"; exit 0 ;;
esac
case "${1:-}" in
  display-message) printf 'firstmate\n'; exit 0 ;;
  list-windows) exit 0 ;;
esac
exit 0
SH
  chmod +x "$fakebin/tmux"
  cat > "$fakebin/gh-axi" <<'SH'
#!/usr/bin/env bash
case "${1:-} ${2:-}" in
  "pr list") printf '%s\n' "count: 0 (showing first 0)" "pull_requests[]: []" ; exit 0 ;;
  "pr view") echo "error: pull request not found" >&2 ; exit 1 ;;
esac
exit 0
SH
  cat > "$fakebin/gh" <<'SH'
#!/usr/bin/env bash
[ -z "${FM_FAKE_PR_HEAD:-}" ] || { printf '%s\n' "$FM_FAKE_PR_HEAD"; exit 0; }
echo "error: pull request not found" >&2
exit 1
SH
  cat > "$fakebin/no-mistakes" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  chmod +x "$fakebin/gh-axi" "$fakebin/gh" "$fakebin/no-mistakes"
  fm_fake_exit0 "$fakebin" treehouse
  printf '%s\n' "$fakebin"
}

# make_lifecycle_case <name>: a home with a real project, a real task worktree,
# and the fake toolchain the spawn and teardown paths reach. Sets CASE_HOME,
# CASE_PROJ, CASE_WT, CASE_FAKEBIN.
make_lifecycle_case() {
  local name=$1 base
  base="$TMP_ROOT/$name"
  CASE_HOME="$base/home"
  CASE_PROJ="$base/project"
  CASE_WT="$base/wt"
  CASE_FAKEBIN=$(make_lifecycle_fakebin "$base/fake")
  mkdir -p "$CASE_HOME/data" "$CASE_HOME/projects" "$CASE_HOME/state" "$CASE_HOME/config"
  printf 'claude\n' > "$CASE_HOME/config/crew-harness"
  touch "$CASE_HOME/state/.last-watcher-beat"
  fm_git_worktree "$CASE_PROJ" "$CASE_WT" "fm/$name-x1"
}

run_lifecycle_spawn() {
  FM_ROOT_OVERRIDE='' FM_HOME="$CASE_HOME" \
    FM_STATE_OVERRIDE="$CASE_HOME/state" FM_DATA_OVERRIDE="$CASE_HOME/data" \
    FM_PROJECTS_OVERRIDE="$CASE_HOME/projects" FM_CONFIG_OVERRIDE="$CASE_HOME/config" \
    FM_BACKEND=tmux FM_SPAWN_NO_GUARD=1 FM_FAKE_PANE_PATH="$CASE_WT" TMUX="fake,1,0" \
    PATH="$CASE_FAKEBIN:$PATH" \
    "$SPAWN" "$@" 2>&1
}

run_lifecycle_teardown() {
  FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$CASE_HOME" \
    FM_STATE_OVERRIDE="$CASE_HOME/state" FM_DATA_OVERRIDE="$CASE_HOME/data" \
    FM_PROJECTS_OVERRIDE="$CASE_HOME/projects" FM_CONFIG_OVERRIDE="$CASE_HOME/config" \
    FM_TEARDOWN_GUARD_DONE=1 PATH="$CASE_FAKEBIN:$PATH" \
    "$TEARDOWN" "$@" 2>&1
}

# --- (l) spawn then teardown ------------------------------------------------

test_a_real_spawn_and_teardown_leave_the_task_attributable() {
  local id out spawn_rec cleanup_rec gen
  make_lifecycle_case e2e
  id=e2e-x1
  mkdir -p "$CASE_HOME/data/$id"
  printf 'Delivery contract: mode=no-mistakes\nbrief\n' > "$CASE_HOME/data/$id/brief.md"

  out=$(run_lifecycle_spawn "$id" "$CASE_PROJ" --mode no-mistakes --yolo off \
    --model opus --effort high) \
    || fail "spawn failed: $out"
  assert_contains "$out" "spawned $id" "spawn did not report success: $out"
  gen=$(sed -n 's/^spawn_gen=//p' "$CASE_HOME/state/$id.meta")
  [ -n "$gen" ] || fail "spawn recorded no incarnation token"
  spawn_rec=$(record_for "$CASE_HOME" "spawn:$id:$gen")
  [ -n "$spawn_rec" ] || fail "a real spawn wrote no usage record"
  [ "$(field "$spawn_rec" harness)" = claude ] || fail "spawn record lost the harness: $spawn_rec"
  [ "$(field "$spawn_rec" model)" = opus ] || fail "spawn record lost the model: $spawn_rec"
  [ "$(field "$spawn_rec" effort)" = high ] || fail "spawn record lost the effort: $spawn_rec"
  [ "$(field "$spawn_rec" mode)" = no-mistakes ] || fail "spawn record lost the delivery mode: $spawn_rec"
  [ "$(field "$spawn_rec" yolo)" = off ] || fail "spawn record lost the autonomy posture: $spawn_rec"

  # The task ends on a real status log. Teardown retires that log as part of
  # cleanup, so its final class has to be captured before it is gone.
  printf '%s\n' \
    'working: implementing' \
    'done: landed, captain notes were sensitive' \
    > "$CASE_HOME/state/$id.status"

  # The spawn left the worktree at the remote default branch tip, so the task's
  # work is reachable and teardown may proceed.
  out=$(run_lifecycle_teardown "$id") || fail "teardown failed: $out"
  assert_absent "$CASE_HOME/state/$id.status" "teardown left the status log behind"
  assert_absent "$CASE_HOME/state/$id.meta" "teardown left the volatile task record behind"
  cleanup_rec=$(record_for "$CASE_HOME" "cleanup:$id:$gen")
  [ -n "$cleanup_rec" ] || fail "teardown wrote no usage record"
  [ "$(field "$cleanup_rec" harness)" = claude ] \
    || fail "the axes cleanup deletes were not preserved: $cleanup_rec"
  [ "$(field "$cleanup_rec" model)" = opus ] \
    || fail "the model cleanup deletes was not preserved: $cleanup_rec"
  [ "$(field "$cleanup_rec" outcome)" = landed ] \
    || fail "the terminal outcome was not recorded: $cleanup_rec"
  [ "$(field "$cleanup_rec" status_class)" = "done" ] \
    || fail "the final status class the task ended on was not recorded: $cleanup_rec"
  assert_no_grep "captain notes were sensitive" "$(store "$CASE_HOME")" \
    "the free-form status note reached the ledger"
  ledger "$CASE_HOME" verify >/dev/null || fail "the lifecycle left a malformed ledger"
  pass "a real spawn and teardown leave the task attributable after its record is gone"
}

test_a_retirement_records_the_class_the_retired_mate_ended_on() {
  local id home_path ctl out rec
  make_lifecycle_case nested-sm
  id=nested-sm-x1
  # The retired mate's own home carries the overridden control state directory,
  # so removing that home takes its status log with it. The class the mate
  # actually ended on has to be read before that happens.
  home_path="$TMP_ROOT/nested-sm/secondmate-home"
  ctl="$home_path/control-state"
  mkdir -p "$home_path/state" "$home_path/data" "$home_path/config" \
    "$home_path/projects" "$ctl"
  printf '%s\n' "$id" > "$home_path/.fm-secondmate-home"
  touch "$ctl/.last-watcher-beat"
  fm_write_meta "$ctl/$id.meta" \
    "window=firstmate:fm-$id" \
    "endpoint_task_id=$id" \
    "worktree=$CASE_WT" \
    "project=$CASE_PROJ" \
    "harness=claude" \
    "kind=secondmate" \
    "mode=secondmate" \
    "yolo=off" \
    "model=opus" \
    "effort=high" \
    "home=$home_path" \
    "spawn_gen=g-nested"
  printf '%s\n' 'working: retiring' 'done: handed back' > "$ctl/$id.status"

  out=$(FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$CASE_HOME" \
    FM_STATE_OVERRIDE="$ctl" FM_DATA_OVERRIDE="$CASE_HOME/data" \
    FM_PROJECTS_OVERRIDE="$CASE_HOME/projects" FM_CONFIG_OVERRIDE="$CASE_HOME/config" \
    FM_TEARDOWN_GUARD_DONE=1 PATH="$CASE_FAKEBIN:$PATH" \
    "$TEARDOWN" "$id" --force 2>&1) || fail "the retirement teardown failed: $out"
  assert_absent "$home_path" "the retirement left the retired home behind"
  rec=$(record_for "$CASE_HOME" "cleanup:$id:unknown")
  [ -n "$rec" ] || fail "the retirement wrote no usage record"
  [ "$(field "$rec" status_class)" = "done" ] \
    || fail "the class the retired mate ended on was not recorded: $rec"
  [ "$(field "$rec" outcome)" = discarded ] \
    || fail "the terminal outcome was not recorded: $rec"
  # The task record went with the home, so its axes are honestly unproven. The
  # class is the one axis the capture rescues, and it must not read as an
  # absence nothing established.
  [ "$(field "$rec" model)" = unknown ] \
    || fail "an unreadable task record should leave its axes unknown: $rec"
  ledger "$CASE_HOME" verify >/dev/null || fail "the retirement left a malformed ledger"
  pass "a retirement that removes its own home records the class it ended on"
}

# --- (m) refused cleanup ----------------------------------------------------

test_a_refused_teardown_records_no_cleanup() {
  local id out rc before
  make_lifecycle_case refused
  id=refused-x1
  fm_write_meta "$CASE_HOME/state/$id.meta" \
    "window=firstmate:fm-$id" \
    "endpoint_task_id=$id" \
    "worktree=$CASE_WT" \
    "project=$CASE_PROJ" \
    "harness=claude" \
    "kind=ship" \
    "mode=local-only" \
    "yolo=off" \
    "model=opus" \
    "effort=high" \
    "spawn_gen=g-refused"
  ledger "$CASE_HOME" record --event spawn --task "$id" \
    --meta "$CASE_HOME/state/$id.meta" >/dev/null || fail "seed spawn record failed"
  before=$(cat "$(store "$CASE_HOME")")
  # Unpushed, unmerged work: teardown must refuse rather than discard it.
  git -C "$CASE_WT" -c user.email=t@t -c user.name=t commit -q --allow-empty -m "unlanded work"

  set +e
  out=$(run_lifecycle_teardown "$id")
  rc=$?
  set -e
  expect_code 1 "$rc" "teardown should refuse unlanded work"
  assert_contains "$out" "REFUSED" "the refusal was not reported: $out"
  assert_present "$CASE_HOME/state/$id.meta" "a refused teardown removed the task record"
  [ -z "$(record_for "$CASE_HOME" "cleanup:$id:g-refused")" ] \
    || fail "a refused teardown recorded a cleanup for a task that is still live"
  [ "$(cat "$(store "$CASE_HOME")")" = "$before" ] \
    || fail "a refused teardown changed the ledger"
  pass "a refused teardown records no cleanup, because its task is still live"
}

# --- (n) PR registration ----------------------------------------------------

test_pr_registration_records_the_canonical_pr_and_head() {
  local id url head rec out
  make_lifecycle_case pr-check
  id=pr-check-x1
  url=https://github.com/example/repo/pull/11
  head=3333333333333333333333333333333333333333
  fm_write_meta "$CASE_HOME/state/$id.meta" \
    "window=firstmate:fm-$id" \
    "endpoint_task_id=$id" \
    "worktree=$CASE_WT" \
    "project=$CASE_PROJ" \
    "harness=codex" \
    "kind=ship" \
    "mode=no-mistakes" \
    "yolo=on" \
    "model=gpt-5" \
    "effort=medium" \
    "spawn_gen=g-pr"
  chmod 0600 "$CASE_HOME/state/$id.meta"

  out=$(FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$CASE_HOME" \
    FM_STATE_OVERRIDE="$CASE_HOME/state" FM_DATA_OVERRIDE="$CASE_HOME/data" \
    FM_FAKE_PR_HEAD="$head" PATH="$CASE_FAKEBIN:$PATH" \
    "$PR_CHECK" "$id" "$url" 2>&1) || fail "fm-pr-check failed: $out"
  rec=$(record_for "$CASE_HOME" "pr:$id:g-pr:$url:$head")
  [ -n "$rec" ] || fail "fm-pr-check wrote no usage record for $url"
  [ "$(field "$rec" pr)" = "$url" ] || fail "the canonical PR URL was not recorded: $rec"
  [ "$(field "$rec" pr_head)" = "$head" ] || fail "the forge's head was not recorded: $rec"
  [ "$(field "$rec" model)" = gpt-5 ] || fail "the PR record lost the implementer's model: $rec"
  [ "$(field "$rec" yolo)" = on ] || fail "the PR record lost the autonomy posture: $rec"

  # A rerun is idempotent, exactly like the poll it arms.
  out=$(FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$CASE_HOME" \
    FM_STATE_OVERRIDE="$CASE_HOME/state" FM_DATA_OVERRIDE="$CASE_HOME/data" \
    FM_FAKE_PR_HEAD="$head" PATH="$CASE_FAKEBIN:$PATH" \
    "$PR_CHECK" "$id" "$url" 2>&1) || fail "fm-pr-check rerun failed: $out"
  [ "$(grep -cF '"event":"pr"' "$(store "$CASE_HOME")")" = 1 ] \
    || fail "a repeated PR registration duplicated its usage record"
  pass "PR registration records the canonical PR, the forge's head, and the task's axes"
}

# --- (o) local landing ------------------------------------------------------

test_an_approved_local_landing_records_its_commit() {
  local id rec out landed
  make_lifecycle_case merge-local
  id=merge-local-x1
  # The case worktree already sits on fm/<id>; give it one commit to land.
  git -C "$CASE_WT" -c user.email=t@t -c user.name=t \
    commit -q --allow-empty -m "landed change"
  fm_write_meta "$CASE_HOME/state/$id.meta" \
    "window=firstmate:fm-$id" \
    "endpoint_task_id=$id" \
    "worktree=$CASE_WT" \
    "project=$CASE_PROJ" \
    "harness=pi" \
    "kind=ship" \
    "mode=local-only" \
    "yolo=off" \
    "model=default" \
    "effort=low" \
    "spawn_gen=g-land"

  out=$(FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$CASE_HOME" \
    FM_STATE_OVERRIDE="$CASE_HOME/state" FM_DATA_OVERRIDE="$CASE_HOME/data" \
    PATH="$CASE_FAKEBIN:$PATH" \
    "$MERGE_LOCAL" "$id" 2>&1) || fail "fm-merge-local failed: $out"
  landed=$(git -C "$CASE_PROJ" rev-parse HEAD)
  rec=$(record_for "$CASE_HOME" "merge:$id:-:$landed")
  [ -n "$rec" ] || fail "an approved local landing wrote no usage record"
  [ "$(field "$rec" landing)" = "$landed" ] || fail "the landing commit was not recorded: $rec"
  [ "$(field "$rec" outcome)" = merged ] || fail "the landing outcome was not recorded: $rec"
  [ "$(field "$rec" harness)" = pi ] || fail "the landing record lost the implementer: $rec"
  pass "an approved local landing records its commit and the implementer's axes"
}

# --- (p) instrumentation never gates the lifecycle --------------------------

test_a_failed_ledger_write_never_fails_the_lifecycle_step() {
  local id url out rc
  make_lifecycle_case ledger-broken
  id=ledger-broken-x1
  url=https://github.com/example/repo/pull/12
  fm_write_meta "$CASE_HOME/state/$id.meta" \
    "window=firstmate:fm-$id" \
    "endpoint_task_id=$id" \
    "worktree=$CASE_WT" \
    "project=$CASE_PROJ" \
    "harness=claude" \
    "kind=ship" \
    "mode=no-mistakes" \
    "yolo=off" \
    "model=opus" \
    "effort=high" \
    "spawn_gen=g-broken"
  chmod 0600 "$CASE_HOME/state/$id.meta"
  # A store the ledger must refuse: recording is instrumentation, so the PR
  # registration it decorates still has to succeed.
  printf 'corrupt\n' > "$(store "$CASE_HOME")"
  chmod 0600 "$(store "$CASE_HOME")"

  set +e
  out=$(FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$CASE_HOME" \
    FM_STATE_OVERRIDE="$CASE_HOME/state" FM_DATA_OVERRIDE="$CASE_HOME/data" \
    PATH="$CASE_FAKEBIN:$PATH" \
    "$PR_CHECK" "$id" "$url" 2>&1)
  rc=$?
  set -e
  expect_code 0 "$rc" "a refused ledger write should not fail the PR registration"
  assert_contains "$out" "armed:" "the PR poll was not armed: $out"
  assert_contains "$out" "task-usage ledger did not record" \
    "the failed instrumentation was not reported loudly: $out"
  assert_grep 'corrupt' "$(store "$CASE_HOME")" "the refused ledger lost its bytes"
  pass "a refused ledger write warns loudly and never fails the lifecycle step"
}

test_an_unreadable_status_class_is_reported_rather_than_substituted() {
  local dir home rc
  dir="$TMP_ROOT/status-class-policy"
  mkdir -p "$dir"
  cp "$ROOT/bin/fm-usage-ledger-lib.sh" "$dir/fm-usage-ledger-lib.sh"
  # The schema owner the call policy shells out to cannot run. The class must
  # still be "unknown" and must still not fail the caller, but the ledger's own
  # diagnostic has to survive and the substitution has to be announced.
  cat > "$dir/fm-usage-ledger.sh" <<'STUB'
#!/usr/bin/env bash
printf 'error: the task-usage ledger could not be started\n' >&2
exit 1
STUB
  chmod 0755 "$dir/fm-usage-ledger.sh"
  home=$(make_home status-class-policy)
  printf 'done: finished\n' > "$home/state/alpha-x1.status"

  set +e
  # shellcheck source=bin/fm-usage-ledger-lib.sh
  ( . "$dir/fm-usage-ledger-lib.sh"
    fm_usage_ledger_status_class "$home" "$home/state" "$home/data" \
      "$home/state/alpha-x1.status" ) > "$dir/out" 2> "$dir/err"
  rc=$?
  set -e
  expect_code 0 "$rc" "an unreadable status class must never fail its caller"
  [ "$(cat "$dir/out")" = unknown ] \
    || fail "an unreadable status class should yield unknown: $(cat "$dir/out")"
  assert_contains "$(cat "$dir/err")" "could not read the final status class" \
    "the substituted class was not announced: $(cat "$dir/err")"
  assert_contains "$(cat "$dir/err")" "could not be started" \
    "the ledger's own diagnostic was swallowed: $(cat "$dir/err")"
  pass "an unreadable status class is reported loudly rather than silently substituted"
}

test_ledger_opens_with_an_explicit_first_observed_record
test_spawn_record_keeps_every_axis_and_no_private_value
test_backend_defaults_to_the_documented_tmux_contract
test_final_status_class_is_the_verb_only
test_a_class_captured_before_the_log_is_retired_is_recorded
test_a_renamed_status_verb_is_recorded_in_the_homes_spelling
test_an_unreadable_status_log_is_unknown_rather_than_none
test_repeated_lifecycle_calls_are_idempotent
test_distinct_events_append_distinct_records
test_a_long_pr_url_still_distinguishes_a_re_pushed_head
test_a_long_self_hosted_merge_request_keeps_its_ledger_row
test_a_pr_url_beyond_the_bound_is_refused_rather_than_truncated
test_missing_inputs_are_stated_rather_than_guessed
test_concurrent_writers_lose_no_record_and_reuse_no_sequence
test_unsafe_targets_refuse_without_writing
test_a_created_store_is_private
test_no_verb_recreates_a_home_a_retirement_removed
test_a_malformed_store_refuses_every_verb_and_keeps_its_bytes
test_an_append_reads_only_the_records_it_needs
test_a_future_schema_record_is_preserved_not_rejected
test_retention_keeps_first_observed_and_the_horizon
test_recording_never_rewrites_history
test_invalid_requests_refuse_before_writing
test_a_real_spawn_and_teardown_leave_the_task_attributable
test_a_retirement_records_the_class_the_retired_mate_ended_on
test_a_refused_teardown_records_no_cleanup
test_pr_registration_records_the_canonical_pr_and_head
test_an_approved_local_landing_records_its_commit
test_a_failed_ledger_write_never_fails_the_lifecycle_step
test_an_unreadable_status_class_is_reported_rather_than_substituted
