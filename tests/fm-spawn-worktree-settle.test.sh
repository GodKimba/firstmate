#!/usr/bin/env bash
# Regression test for the fm-spawn.sh treehouse-get worktree-detection settle
# loop (bin/fm-spawn.sh, the bounded poll after `treehouse get`).
#
# Two distinct races are covered here.
#
# 1. On some tmux/WSL setups a brand-new window's pane_current_path transiently
#    reports a stale, unrelated-but-real path on the very first poll, before the
#    pane actually settles into the worktree treehouse get moved it to. That
#    stale path still passes the loop's "differs from the project" check and
#    validate_spawn_worktree's "is a real, distinct worktree" check (it IS a
#    real git checkout, just the wrong one), so a naive single-read loop
#    silently records the wrong worktree= in state/<id>.meta. This test
#    simulates that transient-then-settled sequence and asserts the recorded
#    worktree resolves to the real, settled worktree, never the stale read.
#
# 2. A slow worktree provider runs its provisioning steps from a NESTED
#    directory inside the worktree it is still creating (a monorepo app root),
#    and the backend truthfully reports that foreground cwd for as long as those
#    steps take. Two equal reads of that nested path are stable but premature,
#    so the loop must apply exact-root eligibility to every observation and keep
#    polling until the backend itself reports the worktree root - never
#    normalizing the nested path upward to its git root, which would launch
#    before provisioning finished.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SPAWN="$ROOT/bin/fm-spawn.sh"
TMP_ROOT=$(fm_test_tmproot fm-spawn-worktree-settle)

# make_settle_fakebin <dir> builds a fake tmux whose `#{pane_current_path}`
# query returns FM_FAKE_PANE_STALE for the first FM_FAKE_PANE_STALE_READS
# calls, then FM_FAKE_PANE_PATH forever after - reproducing a pane that
# transiently reports a stale cwd before settling into the real worktree.
make_settle_fakebin() {
  local dir=$1 fakebin
  fakebin=$(fm_fakebin "$dir")
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
set -u
case "$*" in
  *"#{pane_current_path}"*)
    countfile="${FM_FAKE_PANE_COUNTFILE:?FM_FAKE_PANE_COUNTFILE unset}"
    n=0
    [ -f "$countfile" ] && n=$(cat "$countfile")
    n=$((n + 1))
    printf '%s\n' "$n" > "$countfile"
    if [ "$n" -le "${FM_FAKE_PANE_STALE_READS:-0}" ]; then
      printf '%s\n' "${FM_FAKE_PANE_STALE:-}"
    else
      printf '%s\n' "${FM_FAKE_PANE_PATH:-}"
    fi
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

# make_settle_case <name> <id> <stale_reads> builds a home, a primary project
# with a real worktree (the eventual settled path), and a separate real git
# repo standing in for the stale path (a real checkout of something else
# entirely, distinct from both the project and the worktree - mirroring the
# live incident where the stale read was another real firstmate home).
make_settle_case() {
  local name=$1 id=$2 stale_reads=$3 case_dir home proj wt stale fakebin countfile
  case_dir="$TMP_ROOT/$name"
  home="$case_dir/home"
  proj="$case_dir/project"
  wt="$case_dir/wt"
  stale="$case_dir/stale-other-checkout"
  countfile="$case_dir/pane-call-count"
  fakebin=$(make_settle_fakebin "$case_dir/fake")
  mkdir -p "$home/data" "$home/projects" "$home/state" "$home/config"
  printf 'codex\n' > "$home/config/crew-harness"
  fm_git_worktree "$proj" "$wt" "wt-$name"
  fm_git_init_commit "$stale"
  mkdir -p "$home/data/$id"
  printf 'brief for %s\n' "$id" > "$home/data/$id/brief.md"
  touch "$home/state/.last-watcher-beat"
  printf '%s\n' "$case_dir|$home|$proj|$wt|$stale|$fakebin|$countfile|$stale_reads"
}

read_settle_record() {
  IFS='|' read -r _ HOME_DIR PROJ_DIR WT_DIR STALE_DIR FAKEBIN_DIR COUNTFILE STALE_READS <<EOF
$1
EOF
}

run_settle_spawn() {
  local id=$1
  FM_ROOT_OVERRIDE='' FM_HOME="$HOME_DIR" \
    FM_STATE_OVERRIDE="$HOME_DIR/state" FM_DATA_OVERRIDE="$HOME_DIR/data" \
    FM_PROJECTS_OVERRIDE="$HOME_DIR/projects" FM_CONFIG_OVERRIDE="$HOME_DIR/config" \
    FM_SPAWN_NO_GUARD=1 TMUX="fake,1,0" \
    FM_FAKE_PANE_PATH="$WT_DIR" FM_FAKE_PANE_STALE="$STALE_DIR" \
    FM_FAKE_PANE_STALE_READS="$STALE_READS" FM_FAKE_PANE_COUNTFILE="$COUNTFILE" \
    PATH="$FAKEBIN_DIR:$PATH" \
    "$SPAWN" "$id" "$PROJ_DIR" 2>&1
}

# A single stale first read (the exact incident) must not be accepted: the
# loop should keep polling until two consecutive reads agree, landing on the
# real settled worktree instead.
test_single_stale_first_read_is_not_accepted() {
  local rec id out status
  id=settle-single-stale-z1
  rec=$(make_settle_case settle-single "$id" 1)
  read_settle_record "$rec"

  out=$(run_settle_spawn "$id")
  status=$?
  expect_code 0 "$status" "spawn should succeed once the pane settles"
  assert_contains "$out" "spawned $id" "spawn did not report success"
  assert_grep "worktree=$WT_DIR" "$HOME_DIR/state/$id.meta" \
    "meta did not record the settled worktree"
  assert_no_grep "worktree=$STALE_DIR" "$HOME_DIR/state/$id.meta" \
    "meta wrongly recorded the transient stale path as the worktree"
  pass "a single transient stale pane_current_path read is not accepted as the worktree"
}

# A pane that reports the real worktree from the very first read still only
# costs the loop's existing one-second inter-poll sleep to confirm - not an
# extra full cycle on top of that.
test_already_settled_pane_costs_one_confirm_sleep() {
  local rec id out status start end elapsed
  id=settle-already-settled-z2
  rec=$(make_settle_case settle-already-settled "$id" 0)
  read_settle_record "$rec"

  start=$(date +%s)
  out=$(run_settle_spawn "$id")
  status=$?
  end=$(date +%s)
  elapsed=$((end - start))
  expect_code 0 "$status" "spawn should succeed when the pane is already settled"
  assert_grep "worktree=$WT_DIR" "$HOME_DIR/state/$id.meta" \
    "meta did not record the already-settled worktree"
  [ "$elapsed" -le 5 ] || fail "already-settled pane took ${elapsed}s to confirm - expected close to the single inter-poll sleep"
  pass "an already-settled pane confirms via the existing inter-poll sleep, not an extra full cycle"
}

# --- nested provisioning cwd -------------------------------------------------
#
# make_sequence_fakebin <dir> builds a fake tmux whose `#{pane_current_path}`
# query walks FM_FAKE_PANE_SEQUENCE (one path per line), repeating the LAST
# entry forever once the sequence is exhausted - the live provider shape, where
# a foreground cwd persists until something moves it.
make_sequence_fakebin() {
  local dir=$1 fakebin
  fakebin=$(fm_fakebin "$dir")
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
set -u
case "$*" in
  *"#{pane_current_path}"*)
    countfile="${FM_FAKE_PANE_COUNTFILE:?FM_FAKE_PANE_COUNTFILE unset}"
    seqfile="${FM_FAKE_PANE_SEQUENCE:?FM_FAKE_PANE_SEQUENCE unset}"
    n=0
    [ -f "$countfile" ] && n=$(cat "$countfile")
    n=$((n + 1))
    printf '%s\n' "$n" > "$countfile"
    total=$(grep -c '' "$seqfile")
    [ "$n" -le "$total" ] || n=$total
    sed -n "${n}p" "$seqfile"
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

# make_nested_case <name> <id> builds a home, a primary project with a real
# linked worktree, and a nested app root inside that worktree - the exact
# root/subdirectory relationship a monorepo provider provisions from.
make_nested_case() {
  local name=$1 id=$2 case_dir home proj wt fakebin countfile seqfile
  case_dir="$TMP_ROOT/$name"
  home="$case_dir/home"
  proj="$case_dir/project"
  wt="$case_dir/wt"
  countfile="$case_dir/pane-call-count"
  seqfile="$case_dir/pane-sequence"
  fakebin=$(make_sequence_fakebin "$case_dir/fake")
  mkdir -p "$home/data" "$home/projects" "$home/state" "$home/config"
  printf 'codex\n' > "$home/config/crew-harness"
  fm_git_worktree "$proj" "$wt" "wt-$name"
  mkdir -p "$wt/nutri-anamnese"
  mkdir -p "$home/data/$id"
  printf 'brief for %s\n' "$id" > "$home/data/$id/brief.md"
  touch "$home/state/.last-watcher-beat"
  printf '%s\n' "$case_dir|$home|$proj|$wt|$fakebin|$countfile|$seqfile"
}

read_nested_record() {
  IFS='|' read -r _ HOME_DIR PROJ_DIR WT_DIR FAKEBIN_DIR COUNTFILE SEQFILE <<EOF
$1
EOF
}

# run_nested_spawn <id> [EXTRA_ENV...] runs the spawn against the sequence fake.
# The settle knobs stay at their production defaults unless a case passes them.
run_nested_spawn() {
  local id=$1
  shift
  env FM_ROOT_OVERRIDE='' FM_HOME="$HOME_DIR" \
    FM_STATE_OVERRIDE="$HOME_DIR/state" FM_DATA_OVERRIDE="$HOME_DIR/data" \
    FM_PROJECTS_OVERRIDE="$HOME_DIR/projects" FM_CONFIG_OVERRIDE="$HOME_DIR/config" \
    FM_SPAWN_NO_GUARD=1 TMUX="fake,1,0" \
    FM_FAKE_PANE_SEQUENCE="$SEQFILE" FM_FAKE_PANE_COUNTFILE="$COUNTFILE" \
    PATH="$FAKEBIN_DIR:$PATH" "$@" \
    "$SPAWN" "$id" "$PROJ_DIR" 2>&1
}

# A stable NESTED provisioning cwd is not acceptance: it is inside the worktree
# but is not the worktree root, so two equal reads of it must be ignored and the
# loop must wait for the backend to report the exact root.
test_stable_nested_path_waits_for_the_exact_root() {
  local rec id out status reads
  id=settle-nested-then-root-z3
  rec=$(make_nested_case settle-nested-then-root "$id")
  read_nested_record "$rec"
  printf '%s\n%s\n%s\n%s\n' \
    "$WT_DIR/nutri-anamnese" "$WT_DIR/nutri-anamnese" "$WT_DIR" "$WT_DIR" > "$SEQFILE"

  out=$(run_nested_spawn "$id" FM_WORKTREE_SETTLE_INTERVAL=0.01)
  status=$?
  expect_code 0 "$status" "spawn should succeed once the provider reports the worktree root"
  assert_contains "$out" "spawned $id" "spawn did not report success"
  assert_grep "worktree=$WT_DIR" "$HOME_DIR/state/$id.meta" \
    "meta did not record the exact worktree root"
  assert_no_grep "worktree=$WT_DIR/nutri-anamnese" "$HOME_DIR/state/$id.meta" \
    "meta wrongly recorded the nested provisioning directory as the worktree"
  reads=$(cat "$COUNTFILE")
  [ "$reads" -ge 4 ] || fail "expected at least 4 path reads before accepting the root, saw $reads"
  pass "a stable nested provisioning cwd is ignored until the backend reports the exact worktree root"
}

# A provider that never leaves the nested directory must exhaust the bound and
# refuse: no metadata, no harness launch, and no upward normalization to the
# parent git root.
test_permanently_nested_path_times_out_without_launching() {
  local rec id out status
  id=settle-nested-forever-z4
  rec=$(make_nested_case settle-nested-forever "$id")
  read_nested_record "$rec"
  printf '%s\n' "$WT_DIR/nutri-anamnese" > "$SEQFILE"

  out=$(run_nested_spawn "$id" FM_WORKTREE_SETTLE_POLLS=3 FM_WORKTREE_SETTLE_INTERVAL=0.01)
  status=$?
  expect_code 1 "$status" "a permanently nested provisioning cwd must refuse the launch"
  assert_contains "$out" "did not yield an isolated worktree" \
    "the exhausted settle bound lacked the isolation refusal"
  assert_absent "$HOME_DIR/state/$id.meta" "a refused spawn must not record meta"
  assert_not_contains "$out" "spawned $id" "a refused spawn must not launch the harness"
  pass "a provider that never reaches the exact root times out without metadata or a launch"
}

test_settle_interval_validation() {
  local rec seed_id id out status n=0 label value expected sleep_log actual
  seed_id=settle-interval-seed-z5
  rec=$(make_nested_case settle-interval-validation "$seed_id")
  read_nested_record "$rec"
  printf '%s\n' "$WT_DIR/nutri-anamnese" > "$SEQFILE"
  sleep_log="$TMP_ROOT/settle-interval-sleeps"
  cat > "$FAKEBIN_DIR/sleep" <<'SH'
#!/usr/bin/env bash
set -u
printf '%s\n' "${1:-}" >> "${FM_FAKE_SLEEP_LOG:?FM_FAKE_SLEEP_LOG unset}"
SH
  chmod +x "$FAKEBIN_DIR/sleep"

  while IFS='|' read -r label value expected; do
    n=$((n + 1))
    id="settle-interval-$n-z5"
    mkdir -p "$HOME_DIR/data/$id"
    printf 'brief for %s\n' "$id" > "$HOME_DIR/data/$id/brief.md"
    rm -f "$COUNTFILE"
    : > "$sleep_log"
    if [ "$label" = unset ]; then
      out=$(unset FM_WORKTREE_SETTLE_INTERVAL; run_nested_spawn "$id" \
        FM_WORKTREE_SETTLE_POLLS=2 FM_FAKE_SLEEP_LOG="$sleep_log")
    else
      out=$(run_nested_spawn "$id" FM_WORKTREE_SETTLE_POLLS=2 \
        "FM_WORKTREE_SETTLE_INTERVAL=$value" FM_FAKE_SLEEP_LOG="$sleep_log")
    fi
    status=$?
    expect_code 1 "$status" "$label interval case should exhaust the settle bound"
    actual=$(cat "$sleep_log")
    [ "$actual" = "$expected" ] || \
      fail "$label interval case slept '$actual', expected '$expected'"
    assert_contains "$out" "2 polls ${expected}s apart" \
      "$label interval case reported the wrong effective interval"
  done <<'ROWS'
unset||1
blank||1
zero|0|1
decimal-zero|0.0|1
leading-decimal-zero|.0|1
trailing-decimal-zero|0.|1
zero-equivalent|00.000|1
invalid|nope|1
positive|0.01|0.01
ROWS

  pass "settle intervals use one second by default and preserve positive overrides"
}

test_poll_count_validation() {
  local rec seed_id id out status reads sleep_log n=0 label value expected
  seed_id=settle-poll-validation-seed-z6
  rec=$(make_nested_case settle-poll-validation "$seed_id")
  read_nested_record "$rec"
  printf '%s\n' "$WT_DIR/nutri-anamnese" > "$SEQFILE"
  sleep_log="$TMP_ROOT/settle-poll-sleeps"
  cat > "$FAKEBIN_DIR/sleep" <<'SH'
#!/usr/bin/env bash
set -u
printf '%s\n' "${1:-}" >> "${FM_FAKE_SLEEP_LOG:?FM_FAKE_SLEEP_LOG unset}"
SH
  chmod +x "$FAKEBIN_DIR/sleep"

  while IFS='|' read -r label value expected; do
    n=$((n + 1))
    id="settle-polls-$n-z6"
    mkdir -p "$HOME_DIR/data/$id"
    printf 'brief for %s\n' "$id" > "$HOME_DIR/data/$id/brief.md"
    rm -f "$COUNTFILE"
    : > "$sleep_log"
    if [ "$label" = unset ]; then
      out=$(unset FM_WORKTREE_SETTLE_POLLS; run_nested_spawn "$id" \
        FM_WORKTREE_SETTLE_INTERVAL=0.01 FM_FAKE_SLEEP_LOG="$sleep_log")
    else
      out=$(run_nested_spawn "$id" "FM_WORKTREE_SETTLE_POLLS=$value" \
        FM_WORKTREE_SETTLE_INTERVAL=0.01 FM_FAKE_SLEEP_LOG="$sleep_log")
    fi
    status=$?
    expect_code 1 "$status" "$label poll-count case should exhaust the settle bound"
    assert_contains "$out" "within $expected polls 0.01s apart" \
      "$label poll-count case reported the wrong effective bound"
    reads=$(cat "$COUNTFILE")
    [ "$reads" = "$expected" ] || \
      fail "$label poll-count case made $reads reads, expected $expected"
  done <<'ROWS'
unset||60
blank||60
zero|0|60
zero-equivalent|00|60
invalid|nope|60
positive|3|3
ROWS

  pass "settle poll counts use 60 by default and preserve positive overrides"
}

test_single_stale_first_read_is_not_accepted
test_already_settled_pane_costs_one_confirm_sleep
test_stable_nested_path_waits_for_the_exact_root
test_permanently_nested_path_times_out_without_launching
test_settle_interval_validation
test_poll_count_validation

echo "# all fm-spawn-worktree-settle tests passed"
