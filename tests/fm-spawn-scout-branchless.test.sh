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
# provider shape, that repeating the same acquisition in the same copy is safe,
# that a ship task's branch is never touched, and that an unestablishable
# invariant refuses before the harness launches rather than after.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SPAWN="$ROOT/bin/fm-spawn.sh"
TMP_ROOT=$(fm_test_tmproot fm-spawn-scout-branchless)

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
    printf '%s\n' "${FM_FAKE_PANE_PATH:-}"
    exit 0
    ;;
esac
case "${1:-}" in
  display-message) printf 'firstmate\n'; exit 0 ;;
  list-windows) exit 0 ;;
  has-session|new-session|new-window|kill-window) exit 0 ;;
  send-keys) exit 0 ;;
esac
exit 0
SH
  chmod +x "$fakebin/tmux"
  fm_fake_exit0 "$fakebin" treehouse
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
    FM_FAKE_PANE_PATH="$WT_DIR" \
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

# A dirty copy is not ambiguity: the scout's laboratory is expected to be dirty,
# and detaching keeps every change, so acquisition must still establish the
# invariant rather than refuse work that has nothing wrong with it.
test_dirty_managed_pool_scout_still_becomes_branchless() {
  local rec id out status
  id=scout-dirty-b4
  rec=$(make_scout_case scout-dirty "$id" managed)
  read_scout_record "$rec"
  printf '%s\n' 'uncommitted work' >> "$WT_DIR/README.md"
  printf '%s\n' 'untracked work' > "$WT_DIR/untracked.txt"

  out=$(run_scout_spawn "$id" --scout)
  status=$?
  expect_code 0 "$status" "a dirty managed-pool scout copy should still acquire"
  [ -z "$(head_branch "$WT_DIR")" ] \
    || fail "dirty managed-pool scout is still attached to $(head_branch "$WT_DIR")"
  grep -q 'uncommitted work' "$WT_DIR/README.md" \
    || fail "acquisition discarded an uncommitted change"
  [ -f "$WT_DIR/untracked.txt" ] \
    || fail "acquisition discarded an untracked file"
  pass "a dirty managed-pool scout copy becomes branchless with every change preserved"
}

# When the invariant cannot be established - a stuck index lock is the ambiguous
# case, since git cannot tell a crashed process from a live one - acquisition
# must refuse BEFORE the harness launches, so no worker is ever closed by a
# later cleanup refusal it could not have avoided.
test_unestablishable_invariant_refuses_before_launching() {
  local rec id out status git_dir
  id=scout-locked-b5
  rec=$(make_scout_case scout-locked "$id" managed)
  read_scout_record "$rec"
  git_dir=$(git -C "$WT_DIR" rev-parse --git-dir)
  : > "$git_dir/index.lock"

  out=$(run_scout_spawn "$id" --scout)
  status=$?
  expect_code 1 "$status" "an unestablishable branchless invariant must refuse the launch"
  assert_contains "$out" "still attached to branch fmlab/fmlab-pool-scout-locked" \
    "the refusal did not name the branch the scout is still attached to"
  assert_not_contains "$out" "spawned $id" "a refused scout spawn must not launch the harness"
  assert_absent "$HOME_DIR/state/$id.meta" "a refused scout spawn must not record meta"
  pass "a scout whose branchless invariant cannot be established refuses before the harness launches"
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
test_dirty_managed_pool_scout_still_becomes_branchless
test_unestablishable_invariant_refuses_before_launching
test_ship_acquisition_never_detaches_its_branch

echo "# all fm-spawn-scout-branchless tests passed"
