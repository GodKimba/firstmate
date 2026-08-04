#!/usr/bin/env bash
# Regression test for the fm-spawn.sh scout branchless invariant (bin/fm-spawn.sh,
# the acquisition step right after the treehouse-get exact-root assertion).
#
# A scout is recorded as acquisition_branch=- and guarded cleanup only returns
# such a worktree when it is genuinely branchless. Worktree providers disagree
# about what they hand over: a generic provider hands over an already-detached
# worktree, while a managed pool hands over a slot still attached to the pool's
# own structural branch. Recording the branchless provenance without also
# establishing it lets the two diverge, and cleanup then detects the mismatch
# only after the worker has already been closed - preserving the slot and the
# records, but needing manual recovery to finish.
#
# These cases assert the invariant is established at acquisition for every
# provider shape, that a transient detach failure gets one safe same-copy retry,
# that dirty or unique attached work and every retry-identity boundary refuse,
# that repeating an already-detached acquisition is safe, that a ship task's
# branch is never touched, and that every Git error remains actionable.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SPAWN="$ROOT/bin/fm-spawn.sh"
TMP_ROOT=$(fm_test_tmproot fm-spawn-scout-branchless)
REAL_GIT_FOR_TEST=$(command -v git)
export REAL_GIT_FOR_TEST

# make_scout_fakebin <dir>: a fake tmux reporting the worktree as the pane cwd
# (the pane has already settled, so the settle loop confirms on its second read)
# and a no-op treehouse, so the case exercises acquisition rather than the
# provider itself.
make_scout_fakebin() {
  local dir=$1 fakebin
  fakebin=$(fm_fakebin "$dir")
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
set -u
case "$*" in
  *"#{pane_current_path}"*)
    path=${FM_FAKE_PANE_PATH:-}
    if [ -n "${FM_FAKE_DETACH_COUNT:-}" ] \
       && [ -f "$FM_FAKE_DETACH_COUNT" ] \
       && [ -n "${FM_FAKE_PANE_PATH_AFTER_DETACH_FAILURE:-}" ]; then
      read -r detach_count < "$FM_FAKE_DETACH_COUNT"
      [ "$detach_count" -lt 1 ] || path=$FM_FAKE_PANE_PATH_AFTER_DETACH_FAILURE
    fi
    printf '%s\n' "$path"
    exit 0
    ;;
esac
case "${1:-}" in
  display-message) printf 'firstmate\n'; exit 0 ;;
  list-windows) exit 0 ;;
  has-session|new-session|new-window|kill-window) exit 0 ;;
  send-keys)
    printf '%s\n' "$*" >> "${FM_FAKE_SEND_LOG:?}"
    exit 0
    ;;
esac
exit 0
SH
  chmod +x "$fakebin/tmux"
  fm_fake_exit0 "$fakebin" treehouse
  cat > "$fakebin/git" <<'SH'
#!/usr/bin/env bash
case " $* " in
  *" rev-parse --absolute-git-dir "*)
    if [ -n "${FM_FAKE_GIT_DIR_AFTER_DETACH_FAILURE:-}" ]; then
      count=0
      [ ! -f "${FM_FAKE_GIT_DIR_COUNT:?}" ] \
        || read -r count < "$FM_FAKE_GIT_DIR_COUNT"
      count=$((count + 1))
      printf '%s\n' "$count" > "$FM_FAKE_GIT_DIR_COUNT"
      if [ "$count" -ge 2 ]; then
        printf '%s\n' "$FM_FAKE_GIT_DIR_AFTER_DETACH_FAILURE"
        exit 0
      fi
    fi
    ;;
  *" symbolic-ref --quiet --short HEAD "*)
    if [ -n "${FM_FAKE_SYMBOLIC_REF_ERROR_AT:-}" ]; then
      count=0
      [ ! -f "${FM_FAKE_SYMBOLIC_REF_COUNT:?}" ] \
        || read -r count < "$FM_FAKE_SYMBOLIC_REF_COUNT"
      count=$((count + 1))
      printf '%s\n' "$count" > "$FM_FAKE_SYMBOLIC_REF_COUNT"
      [ "$count" != "$FM_FAKE_SYMBOLIC_REF_ERROR_AT" ] || {
        printf 'fatal: simulated symbolic-ref inspection failure\n' >&2
        exit 128
      }
    fi
    ;;
  *" checkout --detach -q "*)
    if [ -n "${FM_FAKE_DETACH_FAIL_AT:-}" ]; then
      count=0
      [ ! -f "${FM_FAKE_DETACH_COUNT:?}" ] \
        || read -r count < "$FM_FAKE_DETACH_COUNT"
      count=$((count + 1))
      printf '%s\n' "$count" > "$FM_FAKE_DETACH_COUNT"
      if [ "$count" = "$FM_FAKE_DETACH_FAIL_AT" ]; then
        [ -z "${FM_FAKE_DIRTY_ON_DETACH_FAILURE:-}" ] \
          || printf 'provider scratch\n' > "$FM_FAKE_DIRTY_ON_DETACH_FAILURE"
        if [ -n "${FM_FAKE_BRANCH_ON_DETACH_FAILURE:-}" ]; then
          "${REAL_GIT_FOR_TEST:?}" -C "${FM_FAKE_BRANCH_WORKTREE:?}" \
            checkout -q -b "$FM_FAKE_BRANCH_ON_DETACH_FAILURE"
        fi
        if [ -n "${FM_FAKE_COMMIT_ON_DETACH_FAILURE:-}" ]; then
          "${REAL_GIT_FOR_TEST:?}" -C "$FM_FAKE_COMMIT_ON_DETACH_FAILURE" \
            -c user.email=t@t -c user.name=t commit -q --allow-empty -m 'provider moved head'
        fi
        printf 'fatal: simulated transient detach failure\n' >&2
        exit 75
      fi
    fi
    ;;
esac
exec "${REAL_GIT_FOR_TEST:?}" "$@"
SH
  chmod +x "$fakebin/git"
  printf '%s\n' "$fakebin"
}

# make_scout_case <name> <id> <provider>: build a home, a project, and the task
# worktree in the disposition the named provider hands over.
#   managed - attached to the pool's own structural branch fmlab/fmlab-pool-<name>,
#             the exact historical shape that reached cleanup as a mismatch
#   generic - already detached, the shape that never needed a fix
make_scout_case() {
  local name=$1 id=$2 provider=$3 case_dir home proj wt fakebin
  case_dir="$TMP_ROOT/$name"
  home="$case_dir/home"
  proj="$case_dir/project"
  wt="$case_dir/wt"
  fakebin=$(make_scout_fakebin "$case_dir/fake")
  mkdir -p "$home/data" "$home/projects" "$home/state" "$home/config"
  printf 'codex\n' > "$home/config/crew-harness"
  fm_git_worktree "$proj" "$wt" "fmlab/fmlab-pool-$name"
  [ "$provider" != generic ] || git -C "$wt" checkout -q --detach
  mkdir -p "$home/data/$id"
  printf 'brief for %s\n' "$id" > "$home/data/$id/brief.md"
  touch "$home/state/.last-watcher-beat"
  printf '%s\n' "$case_dir|$home|$proj|$wt|$fakebin"
}

read_scout_record() {
  IFS='|' read -r _ HOME_DIR PROJ_DIR WT_DIR FAKEBIN_DIR <<EOF
$1
EOF
}

# run_scout_spawn <id> [extra spawn args...]: spawn against the case's fakes.
run_scout_spawn() {
  local id=$1
  shift
  FM_ROOT_OVERRIDE='' FM_HOME="$HOME_DIR" \
    FM_STATE_OVERRIDE="$HOME_DIR/state" FM_DATA_OVERRIDE="$HOME_DIR/data" \
    FM_PROJECTS_OVERRIDE="$HOME_DIR/projects" FM_CONFIG_OVERRIDE="$HOME_DIR/config" \
    FM_SPAWN_NO_GUARD=1 TMUX="fake,1,0" \
    FM_WORKTREE_SETTLE_INTERVAL=0.01 \
    FM_FAKE_SEND_LOG="$HOME_DIR/state/tmux-send.log" \
    FM_FAKE_PANE_PATH="$WT_DIR" \
    FM_FAKE_PANE_PATH_AFTER_DETACH_FAILURE="${FM_FAKE_PANE_PATH_AFTER_DETACH_FAILURE:-}" \
    FM_FAKE_SYMBOLIC_REF_ERROR_AT="${FM_FAKE_SYMBOLIC_REF_ERROR_AT:-}" \
    FM_FAKE_SYMBOLIC_REF_COUNT="${FM_FAKE_SYMBOLIC_REF_COUNT:-}" \
    FM_FAKE_DETACH_FAIL_AT="${FM_FAKE_DETACH_FAIL_AT:-}" \
    FM_FAKE_DETACH_COUNT="${FM_FAKE_DETACH_COUNT:-}" \
    FM_FAKE_DIRTY_ON_DETACH_FAILURE="${FM_FAKE_DIRTY_ON_DETACH_FAILURE:-}" \
    FM_FAKE_GIT_DIR_AFTER_DETACH_FAILURE="${FM_FAKE_GIT_DIR_AFTER_DETACH_FAILURE:-}" \
    FM_FAKE_GIT_DIR_COUNT="${FM_FAKE_GIT_DIR_COUNT:-}" \
    FM_FAKE_BRANCH_ON_DETACH_FAILURE="${FM_FAKE_BRANCH_ON_DETACH_FAILURE:-}" \
    FM_FAKE_BRANCH_WORKTREE="$WT_DIR" \
    FM_FAKE_COMMIT_ON_DETACH_FAILURE="${FM_FAKE_COMMIT_ON_DETACH_FAILURE:-}" \
    PATH="$FAKEBIN_DIR:$PATH" \
    "$SPAWN" "$id" "$PROJ_DIR" "$@" 2>&1
}

head_branch() {  # <worktree>
  git -C "$1" symbolic-ref --quiet --short HEAD 2>/dev/null || true
}

# A managed pool hands over its slot attached to the pool's structural branch.
# The scout must reach its first work step already branchless, with the pool's
# own branch and the slot's commit both untouched, so guarded cleanup can return
# it later without manual recovery.
test_managed_pool_scout_is_branchless_before_work_begins() {
  local rec id out status head_before head_after
  id=scout-managed-pool-b1
  rec=$(make_scout_case scout-managed "$id" managed)
  read_scout_record "$rec"
  head_before=$(git -C "$WT_DIR" rev-parse HEAD)
  [ "$(head_branch "$WT_DIR")" = fmlab/fmlab-pool-scout-managed ] \
    || fail "fixture did not hand over an attached managed-pool slot"

  out=$(run_scout_spawn "$id" --scout)
  status=$?
  expect_code 0 "$status" "spawn should succeed for a managed-pool scout"
  assert_contains "$out" "spawned $id" "spawn did not report success"
  [ -z "$(head_branch "$WT_DIR")" ] \
    || fail "managed-pool scout is still attached to $(head_branch "$WT_DIR") at launch"
  head_after=$(git -C "$WT_DIR" rev-parse HEAD)
  [ "$head_after" = "$head_before" ] \
    || fail "detaching the managed-pool scout moved HEAD from $head_before to $head_after"
  git -C "$PROJ_DIR" show-ref --verify --quiet refs/heads/fmlab/fmlab-pool-scout-managed \
    || fail "detaching the managed-pool scout deleted the pool's structural branch"
  assert_grep "acquisition_branch=-" "$HOME_DIR/state/$id.meta" \
    "meta did not record branchless scout provenance"
  pass "a managed-pool scout is branchless before work begins, with the pool branch and commit intact"
}

# A generic provider already hands over a detached worktree. It must gain no
# managed-pool assumptions: the acquisition step is an exact no-op that neither
# creates nor deletes any branch.
test_generic_scout_acquisition_is_an_exact_no_op() {
  local rec id out status head_before head_after branches_before branches_after
  id=scout-generic-b2
  rec=$(make_scout_case scout-generic "$id" generic)
  read_scout_record "$rec"
  [ -z "$(head_branch "$WT_DIR")" ] \
    || fail "fixture did not hand over a detached generic worktree"
  head_before=$(git -C "$WT_DIR" rev-parse HEAD)
  branches_before=$(git -C "$PROJ_DIR" for-each-ref --format='%(refname)' refs/heads)

  out=$(run_scout_spawn "$id" --scout)
  status=$?
  expect_code 0 "$status" "spawn should succeed for a generic scout"
  assert_contains "$out" "spawned $id" "spawn did not report success"
  [ -z "$(head_branch "$WT_DIR")" ] \
    || fail "generic scout gained branch $(head_branch "$WT_DIR")"
  head_after=$(git -C "$WT_DIR" rev-parse HEAD)
  [ "$head_after" = "$head_before" ] \
    || fail "generic scout acquisition moved HEAD from $head_before to $head_after"
  branches_after=$(git -C "$PROJ_DIR" for-each-ref --format='%(refname)' refs/heads)
  [ "$branches_after" = "$branches_before" ] \
    || fail "generic scout acquisition changed the project's branches"
  assert_grep "acquisition_branch=-" "$HOME_DIR/state/$id.meta" \
    "meta did not record branchless scout provenance"
  pass "a generic scout acquisition is an exact no-op and gains no managed-pool assumptions"
}

# Relaunching the same scout task in its existing copy is the documented safe
# recovery. The second acquisition must preserve the same identity, the same
# commit, and every uncommitted and untracked file the worker had produced.
test_same_task_recovery_preserves_work_in_the_existing_copy() {
  local rec id out status head_before head_after
  id=scout-recovery-b3
  rec=$(make_scout_case scout-recovery "$id" managed)
  read_scout_record "$rec"

  out=$(run_scout_spawn "$id" --scout)
  status=$?
  expect_code 0 "$status" "first scout spawn should succeed"

  # Scratch work the recovering scout must keep: a tracked edit, an untracked
  # file, and a scratch commit on the detached HEAD.
  printf '%s\n' 'scratch edit' >> "$WT_DIR/README.md"
  printf '%s\n' 'scratch note' > "$WT_DIR/scratch-note.txt"
  git -C "$WT_DIR" -c user.email=t@t -c user.name=t \
    commit -q --allow-empty -m 'scout scratch commit'
  head_before=$(git -C "$WT_DIR" rev-parse HEAD)
  rm -f "$HOME_DIR/state/$id.meta"

  out=$(run_scout_spawn "$id" --scout)
  status=$?
  expect_code 0 "$status" "relaunching the same scout in its existing copy should succeed"
  [ -z "$(head_branch "$WT_DIR")" ] \
    || fail "recovered scout is attached to $(head_branch "$WT_DIR")"
  head_after=$(git -C "$WT_DIR" rev-parse HEAD)
  [ "$head_after" = "$head_before" ] \
    || fail "recovery moved HEAD from $head_before to $head_after"
  grep -q 'scratch edit' "$WT_DIR/README.md" \
    || fail "recovery discarded the scout's uncommitted change"
  [ -f "$WT_DIR/scratch-note.txt" ] \
    || fail "recovery discarded the scout's untracked file"
  assert_grep "acquisition_branch=-" "$HOME_DIR/state/$id.meta" \
    "recovery did not record branchless scout provenance"
  pass "relaunching the same scout in its existing copy preserves its identity, commits, and scratch work"
}

# A clean attached copy can hit a one-off provider/index race. The exact first
# Git failure must remain visible, but the same copy gets one bounded retry after
# its clean identity is re-proven.
test_transient_detach_failure_retries_the_same_clean_copy_once() {
  local rec id out status count_file
  id=scout-transient-b4
  rec=$(make_scout_case scout-transient "$id" managed)
  read_scout_record "$rec"
  count_file="$HOME_DIR/state/detach-count"

  out=$(FM_FAKE_DETACH_FAIL_AT=1 FM_FAKE_DETACH_COUNT="$count_file" \
    run_scout_spawn "$id" --scout)
  status=$?
  expect_code 0 "$status" "a transient first detach failure should recover"
  assert_contains "$out" "one same-copy retry succeeded" \
    "successful recovery did not identify the bounded same-copy retry"
  assert_contains "$out" "fatal: simulated transient detach failure" \
    "successful recovery hid the initiating Git error"
  [ "$(cat "$count_file")" = 2 ] || fail "transient recovery did not make exactly two detach attempts"
  [ "$(grep -c 'treehouse get' "$HOME_DIR/state/tmux-send.log")" = 1 ] \
    || fail "transient recovery allocated or requested another worktree copy"
  [ -z "$(head_branch "$WT_DIR")" ] || fail "transiently recovered scout remains attached"
  assert_grep "acquisition_branch=-" "$HOME_DIR/state/$id.meta" \
    "transient recovery did not record branchless provenance"
  pass "a transient detach failure gets exactly one clean same-copy retry without hiding Git's error"
}

# An attached copy can carry real work before Firstmate sees it. Detaching that
# branch would make ownership ambiguous, so both dirty files and commits absent
# from the project checkout are hard refusal boundaries.
test_dirty_or_unique_attached_work_refuses_without_detaching() {
  local rec id out status head_before count_file

  id=scout-dirty-b5
  rec=$(make_scout_case scout-dirty "$id" managed)
  read_scout_record "$rec"
  count_file="$HOME_DIR/state/detach-count"
  printf '%s\n' 'uncommitted work' >> "$WT_DIR/README.md"
  out=$(FM_FAKE_DETACH_FAIL_AT=99 FM_FAKE_DETACH_COUNT="$count_file" \
    run_scout_spawn "$id" --scout)
  status=$?
  expect_code 1 "$status" "a dirty attached scout copy must refuse"
  assert_contains "$out" "refusing to detach dirty work" "dirty refusal was not actionable"
  [ ! -e "$count_file" ] || fail "dirty refusal attempted to detach"
  [ "$(head_branch "$WT_DIR")" = fmlab/fmlab-pool-scout-dirty ] \
    || fail "dirty refusal changed the attached branch"

  id=scout-unique-b6
  rec=$(make_scout_case scout-unique "$id" managed)
  read_scout_record "$rec"
  git -C "$WT_DIR" -c user.email=t@t -c user.name=t \
    commit -q --allow-empty -m 'unique provider work'
  head_before=$(git -C "$WT_DIR" rev-parse HEAD)
  count_file="$HOME_DIR/state/detach-count"
  out=$(FM_FAKE_DETACH_FAIL_AT=99 FM_FAKE_DETACH_COUNT="$count_file" \
    run_scout_spawn "$id" --scout)
  status=$?
  expect_code 1 "$status" "an attached branch with unique commits must refuse"
  assert_contains "$out" "refusing to detach unique work" "unique-work refusal was not actionable"
  [ ! -e "$count_file" ] || fail "unique-work refusal attempted to detach"
  [ "$(git -C "$WT_DIR" rev-parse HEAD)" = "$head_before" ] \
    || fail "unique-work refusal moved HEAD"
  pass "dirty files and unique commits refuse before any attached-copy detach"
}

# Once the first command has failed, the retry authority is narrower than the
# initial acquisition authority: the live endpoint, branch, HEAD, and clean tree
# must still identify the exact same copy.
test_retry_refuses_changed_or_unproven_copy_boundaries() {
  local rec id out status count_file

  id=scout-retry-dirty-b7
  rec=$(make_scout_case scout-retry-dirty "$id" managed)
  read_scout_record "$rec"
  count_file="$HOME_DIR/state/detach-count"
  out=$(FM_FAKE_DETACH_FAIL_AT=1 FM_FAKE_DETACH_COUNT="$count_file" \
    FM_FAKE_DIRTY_ON_DETACH_FAILURE="$WT_DIR/provider-scratch.txt" \
    run_scout_spawn "$id" --scout)
  status=$?
  expect_code 1 "$status" "a copy that becomes dirty after failure must refuse retry"
  assert_contains "$out" "copy became dirty before retry" "retry dirty refusal was not actionable"
  [ "$(cat "$count_file")" = 1 ] || fail "dirty retry boundary made another detach attempt"
  [ "$(head_branch "$WT_DIR")" = fmlab/fmlab-pool-scout-retry-dirty ] \
    || fail "dirty retry refusal detached the branch"

  id=scout-retry-path-b8
  rec=$(make_scout_case scout-retry-path "$id" managed)
  read_scout_record "$rec"
  count_file="$HOME_DIR/state/detach-count"
  out=$(FM_FAKE_DETACH_FAIL_AT=1 FM_FAKE_DETACH_COUNT="$count_file" \
    FM_FAKE_PANE_PATH_AFTER_DETACH_FAILURE="$PROJ_DIR" \
    run_scout_spawn "$id" --scout)
  status=$?
  expect_code 1 "$status" "a changed live endpoint path must refuse retry"
  assert_contains "$out" "live endpoint no longer proves the same acquired copy" \
    "same-copy path refusal was not actionable"
  [ "$(cat "$count_file")" = 1 ] || fail "changed-path boundary made another detach attempt"

  id=scout-retry-git-dir-b9
  rec=$(make_scout_case scout-retry-git-dir "$id" managed)
  read_scout_record "$rec"
  count_file="$HOME_DIR/state/detach-count"
  out=$(FM_FAKE_DETACH_FAIL_AT=1 FM_FAKE_DETACH_COUNT="$count_file" \
    FM_FAKE_GIT_DIR_AFTER_DETACH_FAILURE="$HOME_DIR/state/different-git-dir" \
    FM_FAKE_GIT_DIR_COUNT="$HOME_DIR/state/git-dir-count" \
    run_scout_spawn "$id" --scout)
  status=$?
  expect_code 1 "$status" "a changed Git directory must refuse retry"
  assert_contains "$out" "Git directory changed from" "changed-Git-directory refusal was not actionable"
  [ "$(cat "$count_file")" = 1 ] || fail "changed-Git-directory boundary made another detach attempt"

  id=scout-retry-branch-b10
  rec=$(make_scout_case scout-retry-branch "$id" managed)
  read_scout_record "$rec"
  count_file="$HOME_DIR/state/detach-count"
  out=$(FM_FAKE_DETACH_FAIL_AT=1 FM_FAKE_DETACH_COUNT="$count_file" \
    FM_FAKE_BRANCH_ON_DETACH_FAILURE=provider/reassigned \
    run_scout_spawn "$id" --scout)
  status=$?
  expect_code 1 "$status" "a changed branch must refuse retry"
  assert_contains "$out" "branch changed from" "changed-branch refusal was not actionable"
  [ "$(cat "$count_file")" = 1 ] || fail "changed-branch boundary made another detach attempt"

  id=scout-retry-head-b11
  rec=$(make_scout_case scout-retry-head "$id" managed)
  read_scout_record "$rec"
  count_file="$HOME_DIR/state/detach-count"
  out=$(FM_FAKE_DETACH_FAIL_AT=1 FM_FAKE_DETACH_COUNT="$count_file" \
    FM_FAKE_COMMIT_ON_DETACH_FAILURE="$WT_DIR" \
    run_scout_spawn "$id" --scout)
  status=$?
  expect_code 1 "$status" "a changed HEAD must refuse retry"
  assert_contains "$out" "HEAD changed from" "changed-HEAD refusal was not actionable"
  assert_contains "$out" "refusing to detach changed or unique work" \
    "changed-HEAD refusal did not preserve the unique-work boundary"
  [ "$(cat "$count_file")" = 1 ] || fail "changed-HEAD boundary made another detach attempt"
  pass "retry refuses dirty, different-path, different-Git-dir, changed-branch, and changed-HEAD copies"
}

# A persistent real Git failure must stop after the one retry and preserve both
# exact diagnostics. A stuck index lock reproduces the report's exact observable
# shape - detach fails and leaves a clean copy attached - while proving the new
# diagnostic exposes the initiating Git failure instead of guessing from the
# later branch check.
test_persistent_git_failure_refuses_after_one_retry_with_both_errors() {
  local rec id out status git_dir
  id=scout-locked-b12
  rec=$(make_scout_case scout-locked "$id" managed)
  read_scout_record "$rec"
  git_dir=$(git -C "$WT_DIR" rev-parse --absolute-git-dir)
  : > "$git_dir/index.lock"

  out=$(run_scout_spawn "$id" --scout)
  status=$?
  expect_code 1 "$status" "a persistent detach error must refuse after one retry"
  assert_contains "$out" "scout detach failed twice for the same clean worktree" \
    "persistent refusal did not report the bounded retry outcome"
  [ "$(printf '%s\n' "$out" | grep -c "fatal: Unable to create '$git_dir/index.lock'")" = 2 ] \
    || fail "persistent refusal did not preserve both exact Git lock errors: $out"
  assert_not_contains "$out" "spawned $id" "a refused scout spawn must not launch the harness"
  assert_absent "$HOME_DIR/state/$id.meta" "a refused scout spawn must not record meta"
  [ "$(head_branch "$WT_DIR")" = fmlab/fmlab-pool-scout-locked ] \
    || fail "persistent refusal detached the branch"
  pass "a persistent real Git error stops after one retry and reports both initiating failures"
}

test_head_inspection_errors_refuse_before_launching() {
  local error_at id out rec status
  for error_at in 1 2; do
    id="scout-head-error-b${error_at}"
    rec=$(make_scout_case "scout-head-error-$error_at" "$id" managed)
    read_scout_record "$rec"

    out=$(FM_FAKE_SYMBOLIC_REF_ERROR_AT="$error_at" \
      FM_FAKE_SYMBOLIC_REF_COUNT="$HOME_DIR/state/symbolic-ref-count" \
      run_scout_spawn "$id" --scout)
    status=$?
    expect_code 1 "$status" \
      "HEAD inspection failure $error_at must refuse the launch"
    assert_contains "$out" "cannot prove scout worktree $WT_DIR is detached" \
      "HEAD inspection failure $error_at did not report the unproven invariant"
    assert_contains "$out" "HEAD inspection failed with status 128" \
      "HEAD inspection failure $error_at did not preserve the git status"
    assert_not_contains "$out" "spawned $id" \
      "HEAD inspection failure $error_at launched the harness"
    assert_absent "$HOME_DIR/state/$id.meta" \
      "HEAD inspection failure $error_at recorded meta"
  done
  pass "HEAD inspection errors before and after detaching refuse before the harness launches"
}

# A ship task owns branch fm/<id> and creates it itself. No acquisition step may
# detach or rewrite that branch, so a ship spawn must leave the worktree exactly
# as the provider handed it over.
test_ship_acquisition_never_detaches_its_branch() {
  local rec id out status
  id=ship-branch-intact-b6
  rec=$(make_scout_case ship-branch-intact "$id" managed)
  read_scout_record "$rec"

  out=$(run_scout_spawn "$id")
  status=$?
  expect_code 0 "$status" "ship spawn should succeed"
  assert_contains "$out" "spawned $id" "spawn did not report success"
  [ "$(head_branch "$WT_DIR")" = fmlab/fmlab-pool-ship-branch-intact ] \
    || fail "ship acquisition detached the worktree from its branch"
  assert_grep "acquisition_branch=fm/$id" "$HOME_DIR/state/$id.meta" \
    "meta did not record the ship acquisition branch"
  pass "a ship acquisition never detaches or rewrites the worktree's branch"
}

test_managed_pool_scout_is_branchless_before_work_begins
test_generic_scout_acquisition_is_an_exact_no_op
test_same_task_recovery_preserves_work_in_the_existing_copy
test_transient_detach_failure_retries_the_same_clean_copy_once
test_dirty_or_unique_attached_work_refuses_without_detaching
test_retry_refuses_changed_or_unproven_copy_boundaries
test_persistent_git_failure_refuses_after_one_retry_with_both_errors
test_head_inspection_errors_refuse_before_launching
test_ship_acquisition_never_detaches_its_branch

echo "# all fm-spawn-scout-branchless tests passed"
