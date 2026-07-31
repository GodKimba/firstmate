#!/usr/bin/env bash
# Tests for bin/fm-teardown.sh's landed-work safety and stale-lock recovery.
#
# The check refuses to tear down a worktree whose work has not LANDED, because
# treehouse return hard-resets the worktree. "Landed" means reachable from a remote
# OR - for a normal ship task whose commits are not so reachable - its PR is merged
# and GitHub reports a PR head that contains the current local work, or its content
# is already in the up-to-date default branch.
#
# Covers three fixes:
#   - local-only fork-remote: a fork IS a remote, so fork-pushed upstream-
#     contribution PRs are teardown-eligible (the pre-fix code false-refused them).
#   - squash-merge-then-delete-branch: the branch's own commits live nowhere on a
#     remote after a squash merge deletes the head branch, yet the change is fully in
#     main. Reachability alone false-refused this common GitHub flow; the check now
#     recognizes a merged PR head containing the local work (or the content already
#     in main) as landed.
#   - teardown-lock-race: a killed crew process can leave a transient worktree
#     git index.lock that blocks teardown. The return path retries on the lock
#     error signature (even if the lock self-clears mid-check), then only removes a
#     provably stale lock before re-running safety checks.
#
# Matrix:
#   (a) local-only + HEAD on a fork remote-tracking branch     -> ALLOW  (fork fix)
#   (b) local-only + truly unpushed work (no remote, not main) -> REFUSE (safety)
#   (c) local-only + merged into local main, no remote         -> ALLOW  (no regression)
#   (d) no-mistakes + HEAD on origin remote-tracking branch    -> ALLOW  (no regression)
#   (e) no-mistakes + unpushed, no PR, content not in default  -> REFUSE (safety)
#   (f) local-only + truly unpushed + --force                  -> ALLOW  (escape hatch)
#   (g) no-mistakes + squash-merged PR, exact PR head          -> ALLOW  (squash fix)
#   (h) no-mistakes + no PR but content already in default     -> ALLOW  (content fallback)
#   (i) no-mistakes + dirty worktree, even when work landed     -> REFUSE (dirty wins)
#   (j) no-mistakes + gh lookup errors + content not in default -> REFUSE (fail-safe)
#   (k) no-mistakes + merged PR but HEAD moved afterward        -> REFUSE (stale PR)
#   (l) no-mistakes + stale origin/main but fetched content     -> ALLOW  (fresh fetch)
#   (m) no-mistakes + local HEAD ancestor of merged PR head     -> ALLOW  (lagging local)
#   (n) no-mistakes + replayed unpushed patch in merged PR head -> ALLOW  (replayed local)
#   (o) fm-pr-check rerun after HEAD moved                      -> no stale pr_head
#   (p) fm-pr-check when local HEAD lags                        -> record remote PR head
#   (q) no-mistakes + NO pr= recorded, PR discovered by branch  -> ALLOW  (yolo/no-CI merge)
#   (r) no-mistakes + open PR with auto-merge enabled           -> REFUSE (not landed)
#   (s) landed + ignored files, managed and generic routes      -> ALLOW  (ignore fix)
#   (t) landed + untracked non-ignored file, both routes         -> REFUSE (safety)
#   (u) generic helper + late untracked non-ignored file         -> REFUSE (safety)
#
# Also covers backlog teardown-lock-race: a git index.lock left in the worktree by a
# killed crew process (bin/fm-teardown.sh's teardown_treehouse_return).
#   (v) provably-stale index.lock (old mtime, no live holder) -> lock removed, ALLOW
#   (w) index.lock with a live holder, any age                -> lock kept, REFUSE
#   (x) lsof error while checking index.lock                  -> lock kept, REFUSE
#   (y) dirty worktree after stale lock cleanup               -> lock removed, REFUSE
#   (z) non-linked repo index.lock                            -> lock removed, ALLOW
#   (aa) index.lock mtime read failure                        -> lock kept, REFUSE
#   (ab) transient lock cleared after first failed return     -> retry ALLOW
#   (ac) persistent lock (never clears, not provably stale)   -> REFUSE loudly
set -u

# shellcheck source=tests/lib.sh disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
fm_git_identity fmtest fmtest@example.invalid

TEARDOWN="$ROOT/bin/fm-teardown.sh"
GENERIC_RETURN="$ROOT/bin/fm-treehouse-generic-return.sh"
PROMOTE="$ROOT/bin/fm-promote.sh"
PR_CHECK="$ROOT/bin/fm-pr-check.sh"
TMP_ROOT=$(fm_test_tmproot fm-teardown-tests)
REAL_GIT_FOR_TEST=$(command -v git)
export REAL_GIT_FOR_TEST

# Build a fresh sandbox for one test case. Sets up:
#   $CASE/state/        - firstmate state dir (with a fresh watcher beacon)
#   $CASE/fakebin/      - mocks for treehouse, tmux (PATH-prepended by caller)
#   $CASE/origin.git/   - bare upstream repo (so the project clone has origin)
#   $CASE/project/      - clone of origin; acts as the firstmate project dir
#   $CASE/wt/           - a worktree of the project (the task worktree)
# Echoes the case dir.
make_case() {
  local name=$1 case_dir fakebin
  case_dir="$TMP_ROOT/$name"
  fakebin="$case_dir/fakebin"
  mkdir -p "$case_dir/state" "$case_dir/config" "$fakebin"
  case_dir=$(cd "$case_dir" && pwd -P)
  fakebin="$case_dir/fakebin"

  # Mocks for the post-check teardown steps. Refuse logic exits before these
  # run; the ALLOW cases need them so the script can complete cleanly.
  cat > "$fakebin/treehouse" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = firstmate-return-route ]; then
  printf 'managed'
  exit 0
fi
exit 0
SH
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
set -u
case "${1:-}" in
  kill-window)
    : > "${FM_FAKE_TMUX_STATE:?}"
    case "${FM_FAKE_TMUX_ON_KILL:-}" in
      dirty)
        printf '%s\n' 'late mutation' > "${FM_FAKE_TMUX_WT:?}/late-mutation.txt"
        ;;
      commit)
        printf '%s\n' 'late commit' > "${FM_FAKE_TMUX_WT:?}/late-commit.txt"
        git -C "${FM_FAKE_TMUX_WT:?}" add late-commit.txt
        git -C "${FM_FAKE_TMUX_WT:?}" -c user.email=t@t -c user.name=t commit -q -m 'late unlanded commit'
        ;;
    esac
    exit 0
    ;;
  list-windows)
    if [ -e "${FM_FAKE_TMUX_STATE:?}" ]; then
      echo "can't find session: firstmate" >&2
      exit 1
    fi
    printf '%s\n' 'fm-task-x1'
    exit 0
    ;;
  display-message)
    [ ! -e "${FM_FAKE_TMUX_STATE:?}" ] || exit 1
    case "${@: -1}" in
      '#{pane_current_command}') printf '%s\n' 'codex' ;;
      *) printf '%s\n' '%%1' ;;
    esac
    exit 0
    ;;
esac
exit 0
SH
  # Default gh-axi mock: no PR is associated with the branch, and viewing any PR
  # number fails. This keeps the landed-work check hermetic (never reaching the real
  # gh-axi) and represents the common "no GitHub PR" baseline. Tests that need a
  # merged PR or a lookup error override this file with the helpers below.
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
case "${1:-} ${2:-}" in
  "pr view") echo "error: pull request not found" >&2 ; exit 1 ;;
esac
exit 0
SH
  chmod +x "$fakebin/treehouse" "$fakebin/tmux" "$fakebin/gh-axi" "$fakebin/gh"

  # Bare origin so the clone has an `origin` remote and origin/HEAD.
  git init -q --bare "$case_dir/origin.git"
  git -C "$case_dir/origin.git" symbolic-ref HEAD refs/heads/main
  # Seed origin with one commit BEFORE cloning so the clone is not empty.
  git clone -q "$case_dir/origin.git" "$case_dir/_seed" 2>/dev/null
  git -C "$case_dir/_seed" -c user.email=t@t -c user.name=t \
    commit -q --allow-empty -m "origin baseline"
  git -C "$case_dir/_seed" push -q origin main
  rm -rf "$case_dir/_seed"
  # Clone as the project; give it a `main` branch and an origin/HEAD.
  git clone -q "$case_dir/origin.git" "$case_dir/project"
  git -C "$case_dir/project" remote set-head origin main 2>/dev/null || true
  # Add a worktree on a fresh task branch; that branch is where the crewmate commits.
  git -C "$case_dir/project" worktree add -q -b fm/task-x1 "$case_dir/wt" main

  # Fresh watcher beacon so fm-guard stays quiet.
  touch "$case_dir/state/.last-watcher-beat"

  printf '%s\n' "$case_dir"
}

add_compatible_tasks_axi() {
  local case_dir=$1
  cat > "$case_dir/fakebin/tasks-axi" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = --version ]; then
  printf '%s\n' '0.1.1'
  exit 0
fi
if [ "${1:-}" = update ] && [ "${2:-}" = --help ]; then
  printf '%s\n' 'usage: tasks-axi update <id> [flags]'
  printf '%s\n' '  --body-file <path>'
  printf '%s\n' '  --archive-body'
  exit 0
fi
if [ "${1:-}" = mv ] && [ "${2:-}" = --help ]; then
  printf '%s\n' 'usage: tasks-axi mv <id> [<id>...] --to <path-or-dir>'
  exit 0
fi
if [ "${1:-}" = hold ] && [ "${2:-}" = --help ]; then
  printf '%s\n' 'usage: tasks-axi hold <id> --kind captain'
  exit 0
fi
exit 0
SH
  chmod +x "$case_dir/fakebin/tasks-axi"
}

# Write a meta file for the task. Args: case_dir mode kind
write_meta() {
  local case_dir=$1 mode=$2 kind=$3 acquisition_branch="fm/task-x1"
  [ "$kind" != scout ] || acquisition_branch=-
  fm_write_meta "$case_dir/state/task-x1.meta" \
    "window=firstmate:fm-task-x1" \
    "endpoint_task_id=task-x1" \
    "worktree=$case_dir/wt" \
    "project=$case_dir/project" \
    "acquisition_branch=$acquisition_branch" \
    "kind=$kind" \
    "mode=$mode"
}

# Commit something on the worktree's task branch. Args: case_dir [message]
wt_commit() {
  local case_dir=$1 msg=${2:-wt work}
  git -C "$case_dir/wt" -c user.email=t@t -c user.name=t \
    commit -q --allow-empty -m "$msg"
}

# Add a fork bare repo and register it as a remote on the project, then push
# the worktree's task branch to it and fetch into the project so the worktree
# sees the remote-tracking ref. Args: case_dir
add_fork_with_pushed_branch() {
  local case_dir=$1
  git init -q --bare "$case_dir/fork.git"
  git -C "$case_dir/project" remote add fork "$case_dir/fork.git"
  # Push the task branch from the worktree to the fork, then fetch into project
  # so refs/remotes/fork/fm-task-x1 is visible from the worktree (shared object db).
  git -C "$case_dir/wt" push -q fork fm/task-x1
  git -C "$case_dir/project" fetch -q fork
}

# Commit a real file change on the worktree's task branch (unlike wt_commit, which
# makes an empty commit). A non-empty tree is what the content-in-default check
# inspects. Args: case_dir file content [message]
wt_commit_file() {
  local case_dir=$1 file=$2 content=$3 msg=${4:-add $2}
  printf '%s\n' "$content" > "$case_dir/wt/$file"
  git -C "$case_dir/wt" add -- "$file"
  git -C "$case_dir/wt" -c user.email=t@t -c user.name=t commit -q -m "$msg"
}

# Land <file>=<content> as a single commit on origin's default branch, simulating a
# squash merge whose net change matches the task branch but whose commit differs.
# After this, the branch's content is in origin/main even though the branch's own
# commits are not reachable from it. Args: case_dir file content
land_on_origin_main() {
  local case_dir=$1 file=$2 content=$3 tmp
  tmp="$case_dir/_land"
  git clone -q "$case_dir/origin.git" "$tmp"
  printf '%s\n' "$content" > "$tmp/$file"
  git -C "$tmp" add -- "$file"
  git -C "$tmp" -c user.email=t@t -c user.name=t commit -q -m "squash $file"
  git -C "$tmp" push -q origin HEAD:main
  rm -rf "$tmp"
}

# Override GitHub lookups to report PR 7 as merged with the supplied head.
add_gh_pr_merged_for_head() {
  local case_dir=$1 head=$2
  cat > "$case_dir/fakebin/gh-axi" <<'SH'
#!/usr/bin/env bash
case "${1:-} ${2:-}" in
  "pr list")
    printf '%s\n' "count: 1 (showing first 1)" "pull_requests[1]{number,state}:" "  7,merged" ; exit 0 ;;
  "pr view")
    printf '%s\n' "pull_request:" "  number: 7" "  state: merged" '  merged: "2026-06-26T00:00:00Z"' ; exit 0 ;;
esac
exit 0
SH
  cat > "$case_dir/fakebin/gh" <<SH
#!/usr/bin/env bash
case "\${1:-} \${2:-}" in
  "pr view")
    case " \$* " in
      *"state,headRefOid"*) printf '%s\t%s\n' 'MERGED' '$head' ; exit 0 ;;
      *"headRefOid"*) printf '%s\n' '$head' ; exit 0 ;;
    esac
    ;;
esac
echo "error: pull request not found" >&2
exit 1
SH
  chmod +x "$case_dir/fakebin/gh-axi" "$case_dir/fakebin/gh"
}

# Override GitHub lookups to report PR 7 as open with auto-merge enabled.
# Teardown intentionally asks only for authoritative merged state and the head,
# so the auto-merge detail is present in the operator-shaped fixture but cannot
# turn an open PR into landed work.
add_gh_pr_open_with_auto_merge_for_head() {
  local case_dir=$1 head=$2
  cat > "$case_dir/fakebin/gh-axi" <<'SH'
#!/usr/bin/env bash
case "${1:-} ${2:-}" in
  "pr view")
    printf '%s\n' \
      'pull_request:' \
      '  number: 7' \
      '  state: open' \
      '  merged: no' \
      '  auto_merge: enabled'
    exit 0
    ;;
esac
exit 0
SH
  cat > "$case_dir/fakebin/gh" <<SH
#!/usr/bin/env bash
case "\${1:-} \${2:-}" in
  "pr view")
    case " \$* " in
      *"state,headRefOid"*) printf '%s\t%s\n' 'OPEN' '$head' ; exit 0 ;;
      *"headRefOid"*) printf '%s\n' '$head' ; exit 0 ;;
    esac
    ;;
esac
exit 1
SH
  chmod +x "$case_dir/fakebin/gh-axi" "$case_dir/fakebin/gh"
}

append_pr_meta_for_current_head() {
  local case_dir=$1 head
  head=$(git -C "$case_dir/wt" rev-parse HEAD)
  printf '%s\n' \
    'pr=https://github.com/example/repo/pull/7' \
    "pr_head=$head" >> "$case_dir/state/task-x1.meta"
}

append_pr_meta_url() {
  local case_dir=$1
  printf '%s\n' 'pr=https://github.com/example/repo/pull/7' >> "$case_dir/state/task-x1.meta"
}

commit_tree_from_wt_head() {
  local case_dir=$1 parent=$2 msg=$3 tree
  tree=$(git -C "$case_dir/wt" rev-parse "$parent^{tree}") || return 1
  printf '%s\n' "$msg" | git -C "$case_dir/wt" commit-tree "$tree" -p "$parent"
}

land_equivalent_patch_on_origin_branch() {
  local case_dir=$1 branch=$2 file=$3 content=$4 msg=$5 tmp
  tmp="$case_dir/_equiv"
  git clone -q "$case_dir/origin.git" "$tmp"
  printf '%s\n' "$content" > "$tmp/$file"
  git -C "$tmp" add -- "$file"
  git -C "$tmp" -c user.email=t@t -c user.name=t commit -q -m "$msg"
  git -C "$tmp" push -q origin "HEAD:refs/heads/$branch"
  git -C "$case_dir/project" fetch -q origin "$branch"
  rm -rf "$tmp"
  git -C "$case_dir/project" rev-parse "refs/remotes/origin/$branch"
}

# Override gh-axi so every call fails, simulating an API/network error.
add_gh_axi_error() {
  local case_dir=$1
  cat > "$case_dir/fakebin/gh-axi" <<'SH'
#!/usr/bin/env bash
echo "error: gh-axi unavailable" >&2
exit 1
SH
  cat > "$case_dir/fakebin/gh" <<'SH'
#!/usr/bin/env bash
echo "error: gh unavailable" >&2
exit 1
SH
  chmod +x "$case_dir/fakebin/gh-axi" "$case_dir/fakebin/gh"
}

# Override fakebin/treehouse so `treehouse return --force <wt>` fails with a
# git "file exists" lock error whenever the worktree's real index.lock is
# present, and succeeds once it is gone. This drives the lock through
# fm-teardown.sh's own retry-then-stale-cleanup logic (teardown_treehouse_return
# in bin/fm-teardown.sh) rather than hand-simulating that logic in the test.
add_lock_aware_treehouse() {
  local case_dir=$1
  cat > "$case_dir/fakebin/treehouse" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = firstmate-return-route ]; then
  printf 'managed'
  exit 0
fi
if [ "${1:-}" = return ]; then
  shift
  wt=""
  for a in "$@"; do
    case "$a" in
      --force) ;;
      *) wt=$a ;;
    esac
  done
  lock=$(git -C "$wt" rev-parse --git-path index.lock 2>/dev/null || true)
  case "$lock" in
    /*|'') ;;
    *) lock="$wt/$lock" ;;
  esac
  if [ -n "$lock" ] && [ -e "$lock" ]; then
    echo "fatal: Unable to create '$lock': File exists." >&2
    exit 128
  fi
  exit 0
fi
exit 0
SH
  chmod +x "$case_dir/fakebin/treehouse"
}

# treehouse return fails once with the index.lock signature, then clears the lock
# (simulating a dying crew git process finishing) so the next retry succeeds.
# The first failure always reports the lock path even if the file is removed in
# the same attempt - matching the production race where the lock self-clears
# between the failed return and the supervisor's existence check.
add_transient_lock_treehouse() {
  local case_dir=$1
  cat > "$case_dir/fakebin/treehouse" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = firstmate-return-route ]; then
  printf 'managed'
  exit 0
fi
if [ "${1:-}" = return ]; then
  shift
  wt=""
  for a in "$@"; do
    case "$a" in
      --force) ;;
      *) wt=$a ;;
    esac
  done
  lock=$(git -C "$wt" rev-parse --git-path index.lock 2>/dev/null || true)
  case "$lock" in
    /*|'') ;;
    *) lock="$wt/$lock" ;;
  esac
  count_file="${TREEHOUSE_ATTEMPT_FILE:?}"
  count=0
  if [ -f "$count_file" ]; then
    count=$(cat "$count_file")
  fi
  count=$(( count + 1 ))
  printf '%s\n' "$count" > "$count_file"
  if [ "$count" -eq 1 ]; then
    # Emit the real git signature, then drop the lock so a lock-existence-only
    # recovery path would wrongly abort without retrying.
    if [ -n "$lock" ]; then
      echo "fatal: Unable to create '$lock': File exists." >&2
      rm -f "$lock"
    else
      echo "fatal: Unable to create 'index.lock': File exists." >&2
    fi
    exit 128
  fi
  exit 0
fi
exit 0
SH
  chmod +x "$case_dir/fakebin/treehouse"
}

# treehouse return always fails with the lock signature while the lock file
# remains; used to assert exhausted retries still refuse loudly.
add_persistent_lock_treehouse() {
  local case_dir=$1
  cat > "$case_dir/fakebin/treehouse" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = firstmate-return-route ]; then
  printf 'managed'
  exit 0
fi
if [ "${1:-}" = return ]; then
  shift
  wt=""
  for a in "$@"; do
    case "$a" in
      --force) ;;
      *) wt=$a ;;
    esac
  done
  lock=$(git -C "$wt" rev-parse --git-path index.lock 2>/dev/null || true)
  case "$lock" in
    /*|'') ;;
    *) lock="$wt/$lock" ;;
  esac
  if [ -z "$lock" ]; then
    lock="index.lock"
  fi
  echo "fatal: Unable to create '$lock': File exists." >&2
  exit 128
fi
exit 0
SH
  chmod +x "$case_dir/fakebin/treehouse"
}

git_index_lock_path() {
  local dir=$1 lock abs_dir
  lock=$(git -C "$dir" rev-parse --git-path index.lock)
  case "$lock" in
    /*) printf '%s\n' "$lock" ;;
    *)
      abs_dir=$(cd "$dir" && pwd -P)
      printf '%s/%s\n' "$abs_dir" "$lock"
      ;;
  esac
}

# fakebin/lsof stub: no process ever holds anything open (lsof's not-found exit
# code), so a lock's staleness is decided by age alone.
add_lsof_no_holder() {
  local case_dir=$1
  cat > "$case_dir/fakebin/lsof" <<'SH'
#!/usr/bin/env bash
exit 1
SH
  chmod +x "$case_dir/fakebin/lsof"
}

# fakebin/lsof stub: a live process holds every queried path open, so a lock is
# never judged stale regardless of its age.
add_lsof_live_holder() {
  local case_dir=$1
  cat > "$case_dir/fakebin/lsof" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  chmod +x "$case_dir/fakebin/lsof"
}

add_lsof_error() {
  local case_dir=$1
  cat > "$case_dir/fakebin/lsof" <<'SH'
#!/usr/bin/env bash
echo "lsof: simulated failure for ${1:-unknown}" >&2
exit 2
SH
  chmod +x "$case_dir/fakebin/lsof"
}

add_stat_error() {
  local case_dir=$1
  cat > "$case_dir/fakebin/stat" <<'SH'
#!/usr/bin/env bash
echo "stat: simulated failure" >&2
exit 1
SH
  chmod +x "$case_dir/fakebin/stat"
}

add_git_status_lock_failure() {
  local case_dir=$1
  cat > "$case_dir/fakebin/git" <<'SH'
#!/usr/bin/env bash
real=${REAL_GIT_FOR_TEST:?}
dir=
args=()
while [ "$#" -gt 0 ]; do
  case "$1" in
    -C)
      dir=$2
      args+=("$1" "$2")
      shift 2
      ;;
    *)
      args+=("$1")
      shift
      ;;
  esac
done
if [ -n "$dir" ] && [ "${args[2]:-}" = status ] && [ "${args[3]:-}" = --porcelain ]; then
  lock=$("$real" -C "$dir" rev-parse --git-path index.lock 2>/dev/null || true)
  case "$lock" in
    /*|'') ;;
    *) lock="$dir/$lock" ;;
  esac
  if [ -n "$lock" ] && [ -e "$lock" ]; then
    echo "fatal: Unable to create '$lock': File exists." >&2
    exit 128
  fi
fi
exec "$real" "${args[@]}"
SH
  chmod +x "$case_dir/fakebin/git"
}

# Run teardown with PATH mocking. Args: case_dir [extra args...]
run_teardown() {
  local case_dir=$1 wt generic_state=; shift
  wt=$(grep '^worktree=' "$case_dir/state/task-x1.meta" | tail -1 | cut -d= -f2-)
  [ ! -f "$case_dir/config/fake-generic-state" ] \
    || generic_state=$(cat "$case_dir/config/fake-generic-state")
  FM_ROOT_OVERRIDE="$ROOT" \
  FM_STATE_OVERRIDE="$case_dir/state" \
  FM_DATA_OVERRIDE="$case_dir/data" \
  FM_CONFIG_OVERRIDE="$case_dir/config" \
  FM_FAKE_TMUX_STATE="$case_dir/tmux-killed" \
  FM_FAKE_TMUX_WT="$wt" \
  FM_FAKE_GENERIC_STATE="$generic_state" \
  FM_FAKE_GENERIC_WT="$wt" \
  FM_FAKE_GENERIC_MV_COUNT="$case_dir/generic-mv-count" \
  FM_FAKE_TREEHOUSE_LOG="$case_dir/treehouse.log" \
  PATH="$case_dir/fakebin:$PATH" \
    "$TEARDOWN" task-x1 "$@"
}

configure_generic_pool_case() {
  local case_dir=$1 pool target old
  old="$case_dir/wt"
  pool="$case_dir/.treehouse/project-pool"
  target="$pool/1/project"
  mkdir -p "$pool/1"
  git -C "$case_dir/project" worktree move "$old" "$target"
  sed "s|^worktree=.*|worktree=$target|" "$case_dir/state/task-x1.meta" \
    > "$case_dir/state/task-x1.meta.tmp"
  mv "$case_dir/state/task-x1.meta.tmp" "$case_dir/state/task-x1.meta"
  jq -n --arg path "$target" \
    '{worktrees: [{name: "1", path: $path, created_at: "2026-07-27T00:00:00Z"}]}' \
    > "$pool/treehouse-state.json"
  printf '%s\n' "$pool/treehouse-state.json" > "$case_dir/config/fake-generic-state"
  cat > "$case_dir/fakebin/treehouse" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${FM_FAKE_TREEHOUSE_LOG:?}"
case "${1:-}" in
  firstmate-return-route)
    printf 'generic'
    ;;
  status)
    tmp="${FM_FAKE_GENERIC_STATE:?}.tmp"
    jq --arg path "${FM_FAKE_GENERIC_WT:?}" \
      '.worktrees |= map(select(.path != $path))' \
      "${FM_FAKE_GENERIC_STATE:?}" > "$tmp"
    mv "$tmp" "${FM_FAKE_GENERIC_STATE:?}"
    ;;
  return)
    echo "generic route must not call treehouse return" >&2
    exit 91
    ;;
esac
SH
  chmod +x "$case_dir/fakebin/treehouse"
}

test_local_only_fork_remote_allows() {
  local case_dir rc
  case_dir=$(make_case fork-allow)
  write_meta "$case_dir" local-only ship
  wt_commit "$case_dir" "fix the thing"
  add_fork_with_pushed_branch "$case_dir"

  set +e
  run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 0 "$rc" "fork-allow: teardown should succeed when HEAD is on a fork remote"
  ! grep -q REFUSED "$case_dir/stderr" || fail "fork-allow: teardown printed a REFUSED line"
  pass "local-only worktree with HEAD on a fork remote is torn down (fix holds)"
}

test_teardown_prompts_tasks_axi_done_when_compatible() {
  local case_dir out
  case_dir=$(make_case tasks-axi-reminder)
  write_meta "$case_dir" no-mistakes ship
  printf '%s\n' 'pr=https://github.com/example/repo/pull/7' >> "$case_dir/state/task-x1.meta"
  add_compatible_tasks_axi "$case_dir"

  out=$(run_teardown "$case_dir") || fail "teardown failed with compatible tasks-axi"
  printf '%s\n' "$out" | grep -F 'tasks-axi done task-x1 --pr https://github.com/example/repo/pull/7' >/dev/null \
    || fail "teardown did not prompt tasks-axi done: $out"
  printf '%s\n' "$out" | grep -F 'tasks-axi ready' >/dev/null \
    || fail "teardown did not prompt tasks-axi ready: $out"
  printf '%s\n' "$out" | grep -F 'check date gates' >/dev/null \
    || fail "teardown did not preserve date-gate check: $out"
  printf '%s\n' "$out" | grep -F 'keep Done to the 10 most recent' >/dev/null \
    && fail "teardown kept manual Done pruning in compatible tasks-axi prompt: $out"
  pass "teardown prompts tasks-axi backlog refresh when compatible"
}

test_teardown_manual_backend_prompts_hand_edit_even_when_tasks_axi_present() {
  local case_dir out
  case_dir=$(make_case tasks-axi-manual-optout)
  write_meta "$case_dir" no-mistakes ship
  printf '%s\n' 'pr=https://github.com/example/repo/pull/7' >> "$case_dir/state/task-x1.meta"
  printf '%s\n' manual > "$case_dir/config/backlog-backend"
  add_compatible_tasks_axi "$case_dir"

  out=$(run_teardown "$case_dir") || fail "teardown failed with manual backlog backend"
  printf '%s\n' "$out" | grep -F 'Update data/backlog.md - move task-x1 to Done' >/dev/null \
    || fail "teardown did not prompt manual backlog update under opt-out: $out"
  printf '%s\n' "$out" | grep -F 'tasks-axi done' >/dev/null \
    && fail "teardown prompted tasks-axi despite manual backend opt-out: $out"
  pass "teardown honors config/backlog-backend=manual even when tasks-axi is compatible"
}

test_local_only_truly_unpushed_refuses() {
  local case_dir rc
  case_dir=$(make_case truly-unpushed)
  write_meta "$case_dir" local-only ship
  wt_commit "$case_dir" "unpushed work"
  # No fork, no push to origin, not merged into main.

  set +e
  run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "truly-unpushed: teardown should refuse"
  grep -q REFUSED "$case_dir/stderr" || fail "truly-unpushed: no REFUSED line in stderr"
  pass "local-only worktree with truly unpushed work is refused (safety preserved)"
}

test_local_only_merged_to_local_main_allows() {
  local case_dir rc
  case_dir=$(make_case merged-main)
  write_meta "$case_dir" local-only ship
  wt_commit "$case_dir" "merged work"
  # Fast-forward the project's main to the worktree's HEAD commit so HEAD is
  # reachable from main. update-ref works whether or not main is checked out,
  # and the worktree shares the project's object db so the commit is visible.
  local wt_head
  wt_head=$(git -C "$case_dir/wt" rev-parse HEAD)
  git -C "$case_dir/project" update-ref refs/heads/main "$wt_head"

  set +e
  run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 0 "$rc" "merged-main: teardown should succeed when work is merged into local main"
  ! grep -q REFUSED "$case_dir/stderr" || fail "merged-main: teardown printed a REFUSED line"
  pass "local-only worktree with work merged into local main is torn down (no regression)"
}

test_no_mistakes_origin_remote_allows() {
  local case_dir rc
  case_dir=$(make_case nm-origin)
  write_meta "$case_dir" no-mistakes ship
  wt_commit "$case_dir" "shippable work"
  # Push the task branch to origin and fetch so the worktree sees it.
  git -C "$case_dir/wt" push -q origin fm/task-x1
  git -C "$case_dir/project" fetch -q origin

  set +e
  run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 0 "$rc" "nm-origin: teardown should succeed when HEAD is on origin"
  ! grep -q REFUSED "$case_dir/stderr" || fail "nm-origin: teardown printed a REFUSED line"
  grep -F 'blockers are gone and date is due' "$case_dir/stdout" >/dev/null \
    || fail "nm-origin: teardown manual prompt did not preserve date-gate check"
  pass "no-mistakes worktree with HEAD on origin is torn down (no regression)"
}

test_no_mistakes_truly_unpushed_refuses() {
  local case_dir rc
  case_dir=$(make_case nm-unpushed)
  write_meta "$case_dir" no-mistakes ship
  # Real content that is not pushed, has no PR (default gh-axi mock), and never
  # landed on origin/main: genuinely unlanded work that must still refuse.
  wt_commit_file "$case_dir" feature.txt hello "unpushed work"

  set +e
  run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "nm-unpushed: teardown should refuse"
  grep -q REFUSED "$case_dir/stderr" || fail "nm-unpushed: no REFUSED line in stderr"
  pass "no-mistakes worktree with genuinely unlanded work is refused (safety preserved)"
}

test_open_auto_merge_pr_refuses_teardown() {
  local case_dir rc head
  case_dir=$(make_case open-auto-merge)
  write_meta "$case_dir" no-mistakes ship
  wt_commit_file "$case_dir" feature.txt waiting "queued auto-merge work"
  head=$(git -C "$case_dir/wt" rev-parse HEAD)
  add_gh_pr_open_with_auto_merge_for_head "$case_dir" "$head"
  append_pr_meta_for_current_head "$case_dir"

  set +e
  run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "open-auto-merge: teardown must refuse while the PR remains open"
  grep -q REFUSED "$case_dir/stderr" \
    || fail "open-auto-merge: teardown did not preserve queued work"
  [ -d "$case_dir/wt" ] \
    || fail "open-auto-merge: teardown removed the task worktree before GitHub merged the PR"
  pass "open PR with auto-merge enabled cannot authorize teardown"
}

test_squash_merged_branch_deleted_allows() {
  local case_dir rc pr_head
  case_dir=$(make_case squash-merged)
  write_meta "$case_dir" no-mistakes ship
  # Real branch content that is NOT pushed and NOT on origin/main: a squash merge
  # rewrote it into a different commit on main and auto-deleted the head branch, so
  # HEAD is unreachable from every remote-tracking branch. The matching merged PR is
  # the only signal that the work landed.
  wt_commit_file "$case_dir" feature.txt hello "add feature"
  append_pr_meta_for_current_head "$case_dir"
  pr_head=$(git -C "$case_dir/wt" rev-parse HEAD)
  add_gh_pr_merged_for_head "$case_dir" "$pr_head"

  set +e
  run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 0 "$rc" "squash-merged: teardown should succeed when the PR is merged"
  ! grep -q REFUSED "$case_dir/stderr" || fail "squash-merged: teardown printed a REFUSED line"
  pass "squash-merged + deleted-branch worktree (PR merged) is torn down (the fix)"
}

test_squash_merged_pr_allows_when_head_ancestor_of_pr_head() {
  local case_dir rc local_head pr_head
  case_dir=$(make_case squash-ancestor)
  write_meta "$case_dir" no-mistakes ship
  wt_commit_file "$case_dir" feature.txt hello "add feature"
  append_pr_meta_url "$case_dir"
  local_head=$(git -C "$case_dir/wt" rev-parse HEAD)
  pr_head=$(commit_tree_from_wt_head "$case_dir" "$local_head" "no-mistakes follow-up")
  add_gh_pr_merged_for_head "$case_dir" "$pr_head"

  set +e
  run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 0 "$rc" "squash-ancestor: teardown should succeed when local HEAD is in the merged PR head"
  ! grep -q REFUSED "$case_dir/stderr" || fail "squash-ancestor: teardown printed a REFUSED line"
  pass "squash-merged PR accepts a local HEAD that is an ancestor of the final PR head"
}

test_no_pr_recorded_discovers_merged_pr_by_branch_allows() {
  local case_dir rc local_head pr_head
  case_dir=$(make_case no-pr-branch-discovery)
  write_meta "$case_dir" no-mistakes ship
  # Reproduces the real false-refusal report exactly, with NO pr=/pr_head=
  # recorded in meta at all (fm-pr-check.sh was never run, e.g. a yolo merge on
  # a repo with no PR CI so the "checks green" trigger that fires it never
  # happened): a branch with a commit, a no-mistakes auto-fix commit pushed on
  # top that never made it back into the local worktree, a squash merge onto
  # main under a brand-new SHA, and the head branch deleted (simulated here by
  # never pushing fm/task-x1 at all, so no refs/remotes/origin/fm/task-x1
  # exists to make HEAD "reachable").
  wt_commit_file "$case_dir" feature.txt hello "add feature"
  local_head=$(git -C "$case_dir/wt" rev-parse HEAD)
  pr_head=$(commit_tree_from_wt_head "$case_dir" "$local_head" "no-mistakes auto-fix")
  land_on_origin_main "$case_dir" feature.txt hello
  add_gh_pr_merged_for_head "$case_dir" "$pr_head"
  # No append_pr_meta_* call: state/task-x1.meta has no pr= or pr_head= line.

  ! grep -qE '^(pr|pr_head)=' "$case_dir/state/task-x1.meta" \
    || fail "no-pr-branch-discovery: test setup bug, meta unexpectedly has a pr= line"

  set +e
  run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 0 "$rc" "no-pr-branch-discovery: teardown should succeed by discovering the merged PR from the branch name"
  ! grep -q REFUSED "$case_dir/stderr" || fail "no-pr-branch-discovery: teardown printed a REFUSED line"
  pass "teardown discovers a merged PR by branch name and tears down when no pr= was ever recorded"
}

test_squash_merged_pr_allows_replayed_unpushed_patch() {
  local case_dir rc parent_head pr_head
  case_dir=$(make_case squash-replayed-patch)
  write_meta "$case_dir" no-mistakes ship
  wt_commit_file "$case_dir" local-parent.txt parent "local parent"
  parent_head=$(git -C "$case_dir/wt" rev-parse HEAD)
  git -C "$case_dir/wt" push -q origin "$parent_head:refs/heads/fm/task-x1"
  git -C "$case_dir/project" fetch -q origin fm/task-x1
  wt_commit_file "$case_dir" feature.txt hello "add feature"
  append_pr_meta_url "$case_dir"
  pr_head=$(land_equivalent_patch_on_origin_branch "$case_dir" pr-head feature.txt hello "add feature")
  add_gh_pr_merged_for_head "$case_dir" "$pr_head"

  set +e
  run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 0 "$rc" "squash-replayed-patch: teardown should succeed when unpushed local patch is in the merged PR head"
  ! grep -q REFUSED "$case_dir/stderr" || fail "squash-replayed-patch: teardown printed a REFUSED line"
  pass "squash-merged PR accepts replayed unpushed local patches contained in the PR head"
}

test_merged_pr_with_later_local_commit_refuses() {
  local case_dir rc pr_head
  case_dir=$(make_case stale-pr-head)
  write_meta "$case_dir" no-mistakes ship
  wt_commit_file "$case_dir" feature.txt hello "add feature"
  append_pr_meta_for_current_head "$case_dir"
  pr_head=$(git -C "$case_dir/wt" rev-parse HEAD)
  wt_commit_file "$case_dir" later.txt local-only "local follow-up"
  add_gh_pr_merged_for_head "$case_dir" "$pr_head"

  set +e
  run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "stale-pr-head: teardown should refuse when HEAD moved after PR recording"
  grep -q REFUSED "$case_dir/stderr" || fail "stale-pr-head: no REFUSED line in stderr"
  pass "merged PR does not allow teardown after a later local commit"
}

test_pr_check_does_not_refresh_stale_pr_head() {
  local case_dir rc pr_head new_head count
  case_dir=$(make_case pr-check-stale)
  write_meta "$case_dir" no-mistakes ship
  wt_commit_file "$case_dir" feature.txt hello "add feature"
  pr_head=$(git -C "$case_dir/wt" rev-parse HEAD)
  add_gh_pr_merged_for_head "$case_dir" "$pr_head"

  FM_ROOT_OVERRIDE="$ROOT" \
  FM_STATE_OVERRIDE="$case_dir/state" \
  PATH="$case_dir/fakebin:$PATH" \
    "$PR_CHECK" task-x1 https://github.com/example/repo/pull/7 >/dev/null

  wt_commit_file "$case_dir" later.txt local-only "local follow-up"
  new_head=$(git -C "$case_dir/wt" rev-parse HEAD)

  FM_ROOT_OVERRIDE="$ROOT" \
  FM_STATE_OVERRIDE="$case_dir/state" \
  PATH="$case_dir/fakebin:$PATH" \
    "$PR_CHECK" task-x1 https://github.com/example/repo/pull/7 >/dev/null

  count=$(grep -c '^pr_head=' "$case_dir/state/task-x1.meta" || true)
  expect_code 1 "$count" "pr-check-stale: stale rerun should not append a second pr_head"
  ! grep -qxF "pr_head=$new_head" "$case_dir/state/task-x1.meta" \
    || fail "pr-check-stale: stale rerun recorded the later local HEAD"

  set +e
  run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "pr-check-stale: teardown should refuse after a later local commit"
  grep -q REFUSED "$case_dir/stderr" || fail "pr-check-stale: no REFUSED line in stderr"
  pass "fm-pr-check does not refresh PR head after HEAD moves"
}

test_pr_check_records_remote_head_when_local_lags() {
  local case_dir local_head pr_head
  case_dir=$(make_case pr-check-local-lags)
  write_meta "$case_dir" no-mistakes ship
  wt_commit_file "$case_dir" feature.txt hello "add feature"
  local_head=$(git -C "$case_dir/wt" rev-parse HEAD)
  pr_head=$(commit_tree_from_wt_head "$case_dir" "$local_head" "no-mistakes follow-up")
  add_gh_pr_merged_for_head "$case_dir" "$pr_head"

  FM_ROOT_OVERRIDE="$ROOT" \
  FM_STATE_OVERRIDE="$case_dir/state" \
  PATH="$case_dir/fakebin:$PATH" \
    "$PR_CHECK" task-x1 https://github.com/example/repo/pull/7 >/dev/null

  grep -qxF "pr_head=$pr_head" "$case_dir/state/task-x1.meta" \
    || fail "pr-check-local-lags: did not record GitHub PR head"
  ! grep -qxF "pr_head=$local_head" "$case_dir/state/task-x1.meta" \
    || fail "pr-check-local-lags: recorded local HEAD instead of remote PR head"
  pass "fm-pr-check records the remote PR head when the local worktree lags"
}

test_content_in_default_fallback_allows() {
  local case_dir rc
  case_dir=$(make_case content-landed)
  write_meta "$case_dir" no-mistakes ship
  # No pr= recorded and the default gh-axi mock reports no PR, so the merged-PR path
  # cannot fire and the content check must carry it. The branch adds feature.txt, and
  # the same net change has independently landed on origin/main via a squash commit.
  wt_commit_file "$case_dir" feature.txt hello "add feature"
  land_on_origin_main "$case_dir" feature.txt hello

  set +e
  run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 0 "$rc" "content-landed: teardown should succeed when content is already in the default branch"
  ! grep -q REFUSED "$case_dir/stderr" || fail "content-landed: teardown printed a REFUSED line"
  pass "worktree whose content already landed in the default branch is torn down (content fallback)"
}

test_content_fallback_refreshes_stale_origin_ref() {
  local case_dir rc
  case_dir=$(make_case content-stale-ref)
  write_meta "$case_dir" no-mistakes ship
  wt_commit_file "$case_dir" feature.txt hello "add feature"
  git -C "$case_dir/project" config --unset-all remote.origin.fetch
  git -C "$case_dir/project" config --add remote.origin.fetch '+refs/heads/not-main:refs/remotes/origin/not-main'
  land_on_origin_main "$case_dir" feature.txt hello

  set +e
  run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 0 "$rc" "content-stale-ref: teardown should use the freshly fetched default branch"
  ! grep -q REFUSED "$case_dir/stderr" || fail "content-stale-ref: teardown printed a REFUSED line"
  pass "content fallback refreshes origin default before comparing trees"
}

test_ignored_infrastructure_from_standard_excludes_allows() {
  local case_dir rc route source wt
  for route in managed generic; do
    for source in gitignore info-exclude global-excludes; do
      case_dir=$(make_case "ignored-$route-$source")
      write_meta "$case_dir" no-mistakes ship
      wt_commit "$case_dir" "landed ignored-infrastructure work"
      git -C "$case_dir/wt" push -q origin fm/task-x1
      git -C "$case_dir/project" fetch -q origin
      [ "$route" != generic ] || configure_generic_pool_case "$case_dir"
      wt=$(grep '^worktree=' "$case_dir/state/task-x1.meta" | cut -d= -f2-)

      case "$source" in
        gitignore)
          printf '%s\n' '.env' '.eslintcache' 'node_modules/' > "$wt/.gitignore"
          git -C "$wt" add .gitignore
          git -C "$wt" -c user.email=t@t -c user.name=t commit -q -m 'ignore runtime infrastructure'
          git -C "$wt" push -q origin fm/task-x1
          git -C "$case_dir/project" fetch -q origin
          ;;
        info-exclude)
          printf '%s\n' '.env' '.eslintcache' 'node_modules/' >> "$case_dir/project/.git/info/exclude"
          ;;
        global-excludes)
          printf '%s\n' '.env' '.eslintcache' 'node_modules/' > "$case_dir/global-excludes"
          git -C "$wt" config core.excludesFile "$case_dir/global-excludes"
          ;;
      esac
      printf '%s\n' 'runtime secret' > "$wt/.env"
      printf '%s\n' 'cache' > "$wt/.eslintcache"
      mkdir -p "$wt/node_modules/package"
      printf '%s\n' 'dependency' > "$wt/node_modules/package/index.js"

      [ -z "$(git -C "$wt" status --porcelain)" ] \
        || fail "ignored-$route-$source: fixture is not clean under ordinary git status"
      [ -z "$(git -C "$wt" ls-files --others --exclude-standard)" ] \
        || fail "ignored-$route-$source: standard excludes did not hide fixture infrastructure"
      [ -n "$(git -C "$wt" ls-files --others)" ] \
        || fail "ignored-$route-$source: counterfactual did not expose ignored files without exclude handling"

      set +e
      run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr"
      rc=$?
      set -e

      expect_code 0 "$rc" \
        "ignored-$route-$source: standard Git excludes should not make a clean worktree dirty"
      ! grep -q REFUSED "$case_dir/stderr" \
        || fail "ignored-$route-$source: teardown printed a REFUSED line"
      if [ "$route" = generic ]; then
        assert_grep "generic worktree removed: $wt" "$case_dir/stdout" \
          "ignored-$route-$source: generic provider helper did not complete"
      fi
    done
  done
  pass "ignored runtime infrastructure from every standard Git exclude source does not block either provider route"
}

test_untracked_non_ignored_file_refuses() {
  local case_dir rc route wt
  for route in managed generic; do
    case_dir=$(make_case "untracked-non-ignored-$route")
    write_meta "$case_dir" no-mistakes ship
    wt_commit "$case_dir" "landed before untracked file"
    git -C "$case_dir/wt" push -q origin fm/task-x1
    git -C "$case_dir/project" fetch -q origin
    [ "$route" != generic ] || configure_generic_pool_case "$case_dir"
    wt=$(grep '^worktree=' "$case_dir/state/task-x1.meta" | cut -d= -f2-)
    printf '%s\n' 'uncommitted work' > "$wt/notes.txt"

    [ "$(git -C "$wt" ls-files --others --exclude-standard)" = notes.txt ] \
      || fail "untracked-non-ignored-$route: fixture file was unexpectedly excluded"

    set +e
    run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr"
    rc=$?
    set -e

    expect_code 1 "$rc" \
      "untracked-non-ignored-$route: teardown must refuse an untracked non-ignored file"
    assert_grep "uncommitted changes" "$case_dir/stderr" \
      "untracked-non-ignored-$route: refusal did not cite uncommitted changes"
    [ -f "$wt/notes.txt" ] \
      || fail "untracked-non-ignored-$route: refusal discarded the file"
  done
  pass "untracked non-ignored files remain protected on both provider routes"
}

test_generic_helper_independently_refuses_untracked_non_ignored_file() {
  local case_dir head pool rc state wt
  case_dir=$(make_case generic-helper-untracked)
  write_meta "$case_dir" no-mistakes ship
  wt_commit "$case_dir" "landed before generic helper refusal"
  git -C "$case_dir/wt" push -q origin fm/task-x1
  git -C "$case_dir/project" fetch -q origin
  configure_generic_pool_case "$case_dir"
  wt=$(grep '^worktree=' "$case_dir/state/task-x1.meta" | cut -d= -f2-)
  pool=$(dirname "$(dirname "$wt")")
  state="$pool/treehouse-state.json"
  head=$(git -C "$wt" rev-parse HEAD)
  printf '%s\n' 'late uncommitted work' > "$wt/notes.txt"

  set +e
  FM_TREEHOUSE_RETURN_AUTHORIZED=1 \
    "$GENERIC_RETURN" "$case_dir/project" "$wt" "$pool" fm/task-x1 \
      "$head" landed "$case_dir/state/task-x1.meta" \
      > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" \
    "generic-helper-untracked: helper must refuse an untracked non-ignored file"
  assert_grep "generic Treehouse worktree is not clean" "$case_dir/stderr" \
    "generic-helper-untracked: refusal did not cite the independent cleanliness check"
  [ -f "$wt/notes.txt" ] \
    || fail "generic-helper-untracked: refusal discarded the file"
  [ "$(jq --arg path "$wt" '[.worktrees[]? | select(.path == $path)] | length' "$state")" = 1 ] \
    || fail "generic-helper-untracked: refusal changed provider state"
  git -C "$case_dir/project" show-ref --verify --quiet refs/heads/fm/task-x1 \
    || fail "generic-helper-untracked: refusal deleted the acquisition branch"
  pass "generic provider independently preserves untracked non-ignored files"
}

test_dirty_worktree_refuses() {
  local case_dir rc pr_head
  case_dir=$(make_case dirty-wt)
  write_meta "$case_dir" no-mistakes ship
  printf '%s\n' 'pr=https://github.com/example/repo/pull/7' >> "$case_dir/state/task-x1.meta"
  # The committed work has fully landed (merged PR + content in default), but an
  # uncommitted edit remains. Dirtiness must refuse regardless: the reset would
  # discard those changes.
  wt_commit_file "$case_dir" feature.txt hello "add feature"
  land_on_origin_main "$case_dir" feature.txt hello
  pr_head=$(git -C "$case_dir/wt" rev-parse HEAD)
  add_gh_pr_merged_for_head "$case_dir" "$pr_head"
  printf '%s\n' "uncommitted edit" > "$case_dir/wt/feature.txt"

  set +e
  run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "dirty-wt: teardown should refuse a dirty worktree even when the committed work has landed"
  grep -q REFUSED "$case_dir/stderr" || fail "dirty-wt: no REFUSED line in stderr"
  grep -q "uncommitted changes" "$case_dir/stderr" || fail "dirty-wt: refusal did not cite uncommitted changes"
  pass "dirty worktree is refused even when its committed work has landed (dirty always wins)"
}

test_provider_refusal_preserves_task_records() {
  local case_dir rc
  case_dir=$(make_case provider-refusal)
  write_meta "$case_dir" no-mistakes ship
  wt_commit "$case_dir" "landed provider-refusal work"
  git -C "$case_dir/wt" push -q origin fm/task-x1
  git -C "$case_dir/project" fetch -q origin
  cat > "$case_dir/fakebin/treehouse" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = firstmate-return-route ]; then
  printf 'managed'
  exit 0
fi
[ "${FM_TREEHOUSE_RETURN_AUTHORIZED:-}" = 1 ] || exit 9
[ "${FM_TREEHOUSE_RETURN_PROJECT:-}" = "${FM_EXPECTED_PROJECT:?}" ] || exit 8
exit 1
SH
  chmod +x "$case_dir/fakebin/treehouse"

  set +e
  FM_EXPECTED_PROJECT="$case_dir/project" run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "provider-refusal: teardown must fail when treehouse refuses return"
  [ -f "$case_dir/state/task-x1.meta" ] || fail "provider-refusal: task metadata was cleared after provider refusal"
  [ -d "$case_dir/wt" ] || fail "provider-refusal: worktree disappeared despite provider refusal"
  git -C "$case_dir/project" show-ref --verify --quiet refs/heads/fm/task-x1 \
    || fail "provider-refusal: acquisition branch was deleted before provider success"
  [ "$(git -C "$case_dir/wt" symbolic-ref --quiet --short HEAD)" = "fm/task-x1" ] \
    || fail "provider-refusal: worktree was detached before provider success"
  assert_grep "treehouse return failed" "$case_dir/stderr" \
    "provider-refusal: teardown did not report the provider refusal"
  pass "provider refusal preserves task records and the worktree"
}

test_late_dirty_mutation_after_quiesce_refuses() {
  local case_dir rc
  case_dir=$(make_case late-dirty)
  write_meta "$case_dir" no-mistakes ship
  wt_commit "$case_dir" "landed before late dirty mutation"
  git -C "$case_dir/wt" push -q origin fm/task-x1
  git -C "$case_dir/project" fetch -q origin

  set +e
  FM_FAKE_TMUX_ON_KILL=dirty run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "late-dirty: final safety check must refuse mutation after endpoint close"
  [ -f "$case_dir/state/task-x1.meta" ] || fail "late-dirty: task metadata was cleared"
  [ -f "$case_dir/wt/late-mutation.txt" ] || fail "late-dirty: fixture did not create the late mutation"
  assert_grep "uncommitted changes" "$case_dir/stderr" \
    "late-dirty: final safety refusal did not cite uncommitted changes"
  pass "final quiesced safety check preserves a late dirty mutation"
}

test_late_unlanded_commit_after_quiesce_refuses() {
  local case_dir rc
  case_dir=$(make_case late-commit)
  write_meta "$case_dir" no-mistakes ship
  wt_commit "$case_dir" "landed before late commit"
  git -C "$case_dir/wt" push -q origin fm/task-x1
  git -C "$case_dir/project" fetch -q origin

  set +e
  FM_FAKE_TMUX_ON_KILL=commit run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "late-commit: final safety check must refuse a new unlanded commit"
  [ -f "$case_dir/state/task-x1.meta" ] || fail "late-commit: task metadata was cleared"
  [ -f "$case_dir/wt/late-commit.txt" ] || fail "late-commit: fixture did not create the late commit"
  assert_grep "not on any remote and not landed" "$case_dir/stderr" \
    "late-commit: final safety refusal did not cite unlanded work"
  pass "final quiesced safety check preserves a late unlanded commit"
}

test_endpoint_close_must_be_confirmed_before_return() {
  local case_dir rc
  case_dir=$(make_case endpoint-still-live)
  write_meta "$case_dir" no-mistakes ship
  wt_commit "$case_dir" "landed endpoint-close work"
  git -C "$case_dir/wt" push -q origin fm/task-x1
  git -C "$case_dir/project" fetch -q origin
  cat > "$case_dir/fakebin/tmux" <<'SH'
#!/usr/bin/env bash
case "${1:-}" in
  list-windows) printf '%s\n' 'fm-task-x1'; exit 0 ;;
  display-message) printf '%s\n' 'codex'; exit 0 ;;
  kill-window) exit 0 ;;
esac
exit 0
SH
  chmod +x "$case_dir/fakebin/tmux"

  set +e
  FM_ENDPOINT_QUIESCE_RETRIES=0 run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "endpoint-still-live: teardown must refuse while the endpoint remains"
  [ -f "$case_dir/state/task-x1.meta" ] || fail "endpoint-still-live: task metadata was cleared"
  assert_grep "still present after close" "$case_dir/stderr" \
    "endpoint-still-live: refusal did not explain the live endpoint"
  pass "treehouse return waits for confirmed exact-endpoint closure"
}

test_endpoint_query_error_preserves_worktree() {
  local case_dir rc
  case_dir=$(make_case endpoint-unreadable)
  write_meta "$case_dir" no-mistakes ship
  wt_commit "$case_dir" "landed endpoint-query work"
  git -C "$case_dir/wt" push -q origin fm/task-x1
  git -C "$case_dir/project" fetch -q origin
  cat > "$case_dir/fakebin/tmux" <<'SH'
#!/usr/bin/env bash
case "${1:-}" in
  kill-window) exit 0 ;;
  list-windows) echo "tmux transport unavailable" >&2; exit 1 ;;
esac
exit 1
SH
  chmod +x "$case_dir/fakebin/tmux"

  set +e
  FM_ENDPOINT_QUIESCE_RETRIES=0 run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "endpoint-unreadable: teardown must refuse an unreadable endpoint query"
  [ -f "$case_dir/state/task-x1.meta" ] || fail "endpoint-unreadable: task metadata was cleared"
  [ -d "$case_dir/wt" ] || fail "endpoint-unreadable: worktree was removed"
  assert_grep "could not be authoritatively queried" "$case_dir/stderr" \
    "endpoint-unreadable: refusal did not distinguish an unreadable query"
  pass "unreadable endpoint queries preserve task records and worktrees"
}

test_only_exact_generated_artifacts_are_exempt() {
  local case_dir rc
  case_dir=$(make_case generated-artifact-scope)
  write_meta "$case_dir" no-mistakes ship
  wt_commit "$case_dir" "landed generated-artifact work"
  git -C "$case_dir/wt" push -q origin fm/task-x1
  git -C "$case_dir/project" fetch -q origin
  mkdir -p "$case_dir/wt/.claude"
  printf '%s\n' '{}' > "$case_dir/wt/.claude/settings.local.json"
  printf '%s\n' 'keep me' > "$case_dir/wt/.claude/notes"

  set +e
  run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "generated-artifact-scope: unrelated .claude content must be dirty"
  [ -f "$case_dir/wt/.claude/notes" ] || fail "generated-artifact-scope: unrelated file was removed"
  [ ! -e "$case_dir/tmux-killed" ] || fail "generated-artifact-scope: endpoint closed before dirty refusal"
  pass "cleanliness exempts only exact Firstmate-generated artifact paths"
}

test_exact_generated_artifact_is_removed_before_final_validation() {
  local case_dir rc
  case_dir=$(make_case exact-generated-artifact)
  write_meta "$case_dir" no-mistakes ship
  wt_commit "$case_dir" "landed exact-artifact work"
  git -C "$case_dir/wt" push -q origin fm/task-x1
  git -C "$case_dir/project" fetch -q origin
  mkdir -p "$case_dir/wt/.claude"
  printf '%s\n' '{}' > "$case_dir/wt/.claude/settings.local.json"

  set +e
  run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 0 "$rc" "exact-generated-artifact: exact generated hook should not block cleanup"
  [ ! -e "$case_dir/wt/.claude/settings.local.json" ] \
    || fail "exact-generated-artifact: generated hook remained after cleanup"
  pass "exact generated artifacts are removed before the final clean-state proof"
}

test_switched_branch_refuses_without_deleting_acquisition_branch() {
  local case_dir rc
  case_dir=$(make_case switched-branch)
  write_meta "$case_dir" no-mistakes ship
  wt_commit "$case_dir" "landed acquisition-branch work"
  git -C "$case_dir/wt" push -q origin fm/task-x1
  git -C "$case_dir/project" fetch -q origin
  git -C "$case_dir/wt" checkout -q -b unrelated-branch

  set +e
  run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "switched-branch: teardown must bind safety to the acquisition branch"
  git -C "$case_dir/project" show-ref --verify --quiet refs/heads/fm/task-x1 \
    || fail "switched-branch: acquisition branch was deleted"
  git -C "$case_dir/project" show-ref --verify --quiet refs/heads/unrelated-branch \
    || fail "switched-branch: current unrelated branch was deleted"
  assert_grep "not its acquisition branch" "$case_dir/stderr" \
    "switched-branch: refusal did not name the provenance mismatch"
  pass "branch cleanup remains bound to the exact acquisition branch"
}

test_generic_return_removes_exact_worktree_without_force() {
  local case_dir rc wt state
  case_dir=$(make_case generic-return)
  write_meta "$case_dir" no-mistakes ship
  wt_commit "$case_dir" "landed generic-return work"
  git -C "$case_dir/wt" push -q origin fm/task-x1
  git -C "$case_dir/project" fetch -q origin
  configure_generic_pool_case "$case_dir"
  wt=$(grep '^worktree=' "$case_dir/state/task-x1.meta" | cut -d= -f2-)
  state=$(cat "$case_dir/config/fake-generic-state")

  set +e
  run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 0 "$rc" "generic-return: exact generic worktree removal should succeed"
  [ ! -e "$wt" ] || fail "generic-return: generic worktree still exists"
  [ "$(jq --arg path "$wt" '[.worktrees[]? | select(.path == $path)] | length' "$state")" = 0 ] \
    || fail "generic-return: Treehouse state retained the removed worktree"
  git -C "$case_dir/project" show-ref --verify --quiet refs/heads/fm/task-x1 \
    && fail "generic-return: acquisition branch remains after verified removal"
  grep -F 'return --force' "$case_dir/treehouse.log" >/dev/null \
    && fail "generic-return: generic route called treehouse return --force"
  pass "generic return removes only the exact authorized worktree without forcing Git"
}

test_explicit_current_main_capability_gap_preserves_managed_return() {
  local case_dir rc
  case_dir=$(make_case staged-managed-route)
  write_meta "$case_dir" no-mistakes ship
  wt_commit "$case_dir" "landed staged-route work"
  git -C "$case_dir/wt" push -q origin fm/task-x1
  git -C "$case_dir/project" fetch -q origin
  cat > "$case_dir/fakebin/treehouse" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${FM_FAKE_TREEHOUSE_LOG:?}"
case "${1:-}" in
  firstmate-return-route)
    printf 'firstmate-return-route: unsupported-current-main'
    exit 2
    ;;
  return) exit 0 ;;
esac
exit 90
SH
  chmod +x "$case_dir/fakebin/treehouse"

  set +e
  run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 0 "$rc" "staged-managed-route: explicit current-main capability gap must retain managed return"
  grep -F 'return --force' "$case_dir/treehouse.log" >/dev/null \
    || fail "staged-managed-route: explicit capability gap did not preserve managed return"
  pass "managed compatibility requires an explicit current-main capability-gap result"
}

test_router_failures_preserve_generic_worktrees() {
  local case_dir mode rc wt state
  for mode in error empty false-capability; do
    case_dir=$(make_case "route-failure-$mode")
    write_meta "$case_dir" no-mistakes ship
    wt_commit "$case_dir" "landed route-failure work"
    git -C "$case_dir/wt" push -q origin fm/task-x1
    git -C "$case_dir/project" fetch -q origin
    configure_generic_pool_case "$case_dir"
    wt=$(grep '^worktree=' "$case_dir/state/task-x1.meta" | cut -d= -f2-)
    state=$(cat "$case_dir/config/fake-generic-state")
    cat > "$case_dir/fakebin/treehouse" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${FM_FAKE_TREEHOUSE_LOG:?}"
case "${1:-}" in
  firstmate-return-route)
    case "${FM_FAKE_ROUTE_MODE:?}" in
      error)
        echo "router transport unavailable" >&2
        exit 75
        ;;
      empty)
        exit 0
        ;;
      false-capability)
        printf 'firstmate-return-route: unsupported-current-main'
        exit 1
        ;;
    esac
    ;;
  return)
    : > "${FM_FAKE_UNSAFE_RETURN:?}"
    exit 0
    ;;
esac
exit 90
SH
    chmod +x "$case_dir/fakebin/treehouse"

    set +e
    FM_FAKE_ROUTE_MODE="$mode" FM_FAKE_UNSAFE_RETURN="$case_dir/unsafe-return" \
      run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr"
    rc=$?
    set -e

    expect_code 1 "$rc" "route-failure-$mode: unsafe route result must refuse teardown"
    [ -d "$wt" ] || fail "route-failure-$mode: generic worktree was removed"
    [ -f "$case_dir/state/task-x1.meta" ] \
      || fail "route-failure-$mode: task metadata was cleared"
    [ ! -e "$case_dir/unsafe-return" ] \
      || fail "route-failure-$mode: managed return ran after an unproven route"
    git -C "$case_dir/project" show-ref --verify --quiet refs/heads/fm/task-x1 \
      || fail "route-failure-$mode: acquisition branch was deleted"
    [ "$(jq --arg path "$wt" '[.worktrees[]? | select(.path == $path)] | length' "$state")" = 1 ] \
      || fail "route-failure-$mode: generic provider state changed"
  done
  pass "router errors and ambiguous capability results preserve generic worktrees"
}

test_generic_postcondition_failure_restores_worktree() {
  local case_dir rc wt
  case_dir=$(make_case generic-postcondition)
  write_meta "$case_dir" no-mistakes ship
  wt_commit "$case_dir" "landed generic-postcondition work"
  git -C "$case_dir/wt" push -q origin fm/task-x1
  git -C "$case_dir/project" fetch -q origin
  configure_generic_pool_case "$case_dir"
  wt=$(grep '^worktree=' "$case_dir/state/task-x1.meta" | cut -d= -f2-)
  cat > "$case_dir/fakebin/mv" <<'SH'
#!/usr/bin/env bash
if [ "${*: -1}" = "${FM_FAKE_GENERIC_STATE:?}" ]; then
  count=0
  [ ! -f "${FM_FAKE_GENERIC_MV_COUNT:?}" ] \
    || count=$(cat "$FM_FAKE_GENERIC_MV_COUNT")
  count=$((count + 1))
  printf '%s\n' "$count" > "$FM_FAKE_GENERIC_MV_COUNT"
  [ "$count" -ne 2 ] || exit 73
fi
exec /bin/mv "$@"
SH
  chmod +x "$case_dir/fakebin/mv"

  set +e
  run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "generic-postcondition: stale provider state must fail"
  [ -d "$wt" ] || fail "generic-postcondition: worktree was not restored"
  [ -f "$case_dir/state/task-x1.meta" ] || fail "generic-postcondition: task metadata was cleared"
  git -C "$case_dir/project" show-ref --verify --quiet refs/heads/fm/task-x1 \
    || fail "generic-postcondition: acquisition branch was deleted"
  [ "$(jq --arg path "$wt" '[.worktrees[]? | select(.path == $path and ((.destroying // false) == false))] | length' \
      "$case_dir/.treehouse/project-pool/treehouse-state.json")" = 1 ] \
    || fail "generic-postcondition: Treehouse state was not restored"
  assert_grep "state commit failed" "$case_dir/stderr" \
    "generic-postcondition: failed provider postcondition was not reported"
  pass "generic provider postcondition failures restore recovery state"
}

test_report_gated_scout_cleanup_remains_supported() {
  local case_dir rc wt state
  case_dir=$(make_case scout-report-gated)
  mkdir -p "$case_dir/data/task-x1"
  printf '%s\n' 'scout result' > "$case_dir/data/task-x1/report.md"
  write_meta "$case_dir" no-mistakes scout
  printf '%s\n' 'decisions_reviewed=1' 'decision_keys=' >> "$case_dir/state/task-x1.meta"
  git -C "$case_dir/wt" checkout -q --detach main
  git -C "$case_dir/project" branch -D -- fm/task-x1 >/dev/null
  configure_generic_pool_case "$case_dir"
  wt=$(grep '^worktree=' "$case_dir/state/task-x1.meta" | cut -d= -f2-)
  state=$(cat "$case_dir/config/fake-generic-state")
  add_compatible_tasks_axi "$case_dir"

  set +e
  run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 0 "$rc" "scout-report-gated: completed scout cleanup should remain supported"
  [ ! -f "$case_dir/state/task-x1.meta" ] || fail "scout-report-gated: task metadata remains after successful cleanup"
  [ ! -e "$wt" ] || fail "scout-report-gated: branchless scout worktree remains"
  [ "$(jq --arg path "$wt" '[.worktrees[]? | select(.path == $path)] | length' "$state")" = 0 ] \
    || fail "scout-report-gated: generic state retained the branchless scout"
  git -C "$case_dir/project" show-ref --verify --quiet refs/heads/fm/task-x1 \
    && fail "scout-report-gated: branchless scout gained a task branch"
  pass "report-gated disposable scout cleanup remains explicit and supported"
}

test_legacy_branchless_scout_metadata_remains_supported() {
  local case_dir rc style
  for style in absent recorded; do
    case_dir=$(make_case "scout-legacy-$style")
    mkdir -p "$case_dir/data/task-x1"
    printf '%s\n' 'scout result' > "$case_dir/data/task-x1/report.md"
    write_meta "$case_dir" no-mistakes scout
    if [ "$style" = absent ]; then
      grep -v '^acquisition_branch=' "$case_dir/state/task-x1.meta" \
        > "$case_dir/state/task-x1.meta.tmp"
      mv "$case_dir/state/task-x1.meta.tmp" "$case_dir/state/task-x1.meta"
    else
      sed 's|^acquisition_branch=.*|acquisition_branch=fm/task-x1|' \
        "$case_dir/state/task-x1.meta" > "$case_dir/state/task-x1.meta.tmp"
      mv "$case_dir/state/task-x1.meta.tmp" "$case_dir/state/task-x1.meta"
    fi
    printf '%s\n' 'decisions_reviewed=1' 'decision_keys=' >> "$case_dir/state/task-x1.meta"
    git -C "$case_dir/wt" checkout -q --detach main
    git -C "$case_dir/project" branch -D -- fm/task-x1 >/dev/null
    add_compatible_tasks_axi "$case_dir"

    set +e
    run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr"
    rc=$?
    set -e

    expect_code 0 "$rc" "scout-legacy-$style: branchless scout cleanup should remain supported"
    [ ! -f "$case_dir/state/task-x1.meta" ] \
      || fail "scout-legacy-$style: task metadata remains after successful cleanup"
  done
  pass "legacy branchless scout metadata remains cleanup-compatible"
}

# Acquisition now establishes the branchless invariant, so a scout that reaches
# cleanup still attached to a structural pool branch is a genuine mismatch
# between the recorded provenance and the copy. That refusal is defense in depth
# and must stay intact on both provider routes: it preserves the slot, the
# branch, and the task records so the copy can be recovered rather than
# discarded.
test_attached_branchless_scout_refuses_on_both_routes() {
  local case_dir rc route wt
  for route in managed generic; do
    case_dir=$(make_case "scout-attached-$route")
    mkdir -p "$case_dir/data/task-x1"
    printf '%s\n' 'scout result' > "$case_dir/data/task-x1/report.md"
    write_meta "$case_dir" no-mistakes scout
    printf '%s\n' 'decisions_reviewed=1' 'decision_keys=' >> "$case_dir/state/task-x1.meta"
    # The historical shape: recorded branchless, but the copy is still on the
    # managed pool's own structural branch.
    git -C "$case_dir/wt" checkout -q -b fmlab/fmlab-pool-1
    git -C "$case_dir/project" branch -D -- fm/task-x1 >/dev/null
    [ "$route" != generic ] || configure_generic_pool_case "$case_dir"
    wt=$(grep '^worktree=' "$case_dir/state/task-x1.meta" | cut -d= -f2-)
    add_compatible_tasks_axi "$case_dir"

    set +e
    run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr"
    rc=$?
    set -e

    expect_code 1 "$rc" \
      "scout-attached-$route: an attached branchless scout must refuse cleanup"
    assert_grep "branchless scout worktree is attached" "$case_dir/stderr" \
      "scout-attached-$route: refusal did not cite the attached branchless scout"
    [ -d "$wt" ] || fail "scout-attached-$route: refusal removed the worktree"
    [ -f "$case_dir/state/task-x1.meta" ] \
      || fail "scout-attached-$route: refusal cleared the task records"
    [ "$(git -C "$wt" symbolic-ref --quiet --short HEAD)" = fmlab/fmlab-pool-1 ] \
      || fail "scout-attached-$route: refusal changed the worktree's branch"
    git -C "$case_dir/project" show-ref --verify --quiet refs/heads/fmlab/fmlab-pool-1 \
      || fail "scout-attached-$route: refusal deleted the pool's structural branch"
  done
  pass "an attached branchless scout is refused on both provider routes, preserving the copy and records"
}

# The generic helper binds its own identities, so it must refuse the same
# mismatch independently of teardown - reaching it directly changes nothing
# about the slot, its provider state, or the structural branch.
test_generic_helper_independently_refuses_attached_branchless_scout() {
  local case_dir pool rc state wt
  case_dir=$(make_case generic-helper-scout-attached)
  write_meta "$case_dir" no-mistakes scout
  git -C "$case_dir/wt" checkout -q -b fmlab/fmlab-pool-1
  git -C "$case_dir/project" branch -D -- fm/task-x1 >/dev/null
  configure_generic_pool_case "$case_dir"
  wt=$(grep '^worktree=' "$case_dir/state/task-x1.meta" | cut -d= -f2-)
  pool=$(dirname "$(dirname "$wt")")
  state="$pool/treehouse-state.json"

  set +e
  FM_TREEHOUSE_RETURN_AUTHORIZED=1 \
    "$GENERIC_RETURN" "$case_dir/project" "$wt" "$pool" - \
      - discard "$case_dir/state/task-x1.meta" \
      > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" \
    "generic-helper-scout-attached: helper must refuse an attached branchless scout"
  assert_grep "branchless scout worktree is attached to branch fmlab/fmlab-pool-1" \
    "$case_dir/stderr" \
    "generic-helper-scout-attached: refusal did not cite the independent disposition check"
  [ -d "$wt" ] || fail "generic-helper-scout-attached: refusal removed the worktree"
  [ "$(jq --arg path "$wt" '[.worktrees[]? | select(.path == $path)] | length' "$state")" = 1 ] \
    || fail "generic-helper-scout-attached: refusal changed provider state"
  git -C "$case_dir/project" show-ref --verify --quiet refs/heads/fmlab/fmlab-pool-1 \
    || fail "generic-helper-scout-attached: refusal deleted the pool's structural branch"
  pass "the generic provider independently refuses an attached branchless scout"
}

test_scout_promotion_records_exact_acquisition_branch() {
  local case_dir style rc
  for style in branchless absent legacy; do
    case_dir=$(make_case "scout-promotion-$style")
    write_meta "$case_dir" no-mistakes scout
    case "$style" in
      absent)
        grep -v '^acquisition_branch=' "$case_dir/state/task-x1.meta" \
          > "$case_dir/state/task-x1.meta.tmp"
        mv "$case_dir/state/task-x1.meta.tmp" "$case_dir/state/task-x1.meta"
        ;;
      legacy)
        sed 's|^acquisition_branch=.*|acquisition_branch=fm/task-x1|' \
          "$case_dir/state/task-x1.meta" > "$case_dir/state/task-x1.meta.tmp"
        mv "$case_dir/state/task-x1.meta.tmp" "$case_dir/state/task-x1.meta"
        ;;
    esac
    git -C "$case_dir/wt" checkout -q --detach main
    git -C "$case_dir/project" branch -D -- fm/task-x1 >/dev/null

    FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$case_dir" \
      FM_STATE_OVERRIDE="$case_dir/state" "$PROMOTE" task-x1 \
      > "$case_dir/promote.stdout" 2> "$case_dir/promote.stderr" \
      || fail "scout-promotion-$style: promotion failed"

    [ "$(grep -c '^kind=ship$' "$case_dir/state/task-x1.meta")" = 1 ] \
      || fail "scout-promotion-$style: ship kind was not recorded exactly once"
    [ "$(grep -c '^acquisition_branch=fm/task-x1$' "$case_dir/state/task-x1.meta")" = 1 ] \
      || fail "scout-promotion-$style: exact acquisition branch was not recorded once"
    [ "$(grep -c '^kind=' "$case_dir/state/task-x1.meta")" = 1 ] \
      || fail "scout-promotion-$style: ambiguous kind metadata remains"
    [ "$(grep -c '^acquisition_branch=' "$case_dir/state/task-x1.meta")" = 1 ] \
      || fail "scout-promotion-$style: ambiguous acquisition metadata remains"
    [ "$(git -C "$case_dir/wt" symbolic-ref --quiet --short HEAD)" = fm/task-x1 ] \
      || fail "scout-promotion-$style: worktree was not attached to its acquired branch"
    git -C "$case_dir/project" show-ref --verify --quiet refs/heads/fm/task-x1 \
      || fail "scout-promotion-$style: exact acquisition branch was not created"

    if [ "$style" = branchless ]; then
      set +e
      run_teardown "$case_dir" --force > "$case_dir/stdout" 2> "$case_dir/stderr"
      rc=$?
      set -e
      expect_code 0 "$rc" "scout-promotion-$style: promoted ship teardown should accept its exact branch"
    fi
  done
  pass "scout promotion atomically records exact ship branch provenance"
}

test_scout_promotion_refuses_unproven_branch_identity() {
  local case_dir style rc branch_before
  for style in attached stale; do
    case_dir=$(make_case "scout-promotion-refuse-$style")
    write_meta "$case_dir" no-mistakes scout
    cp "$case_dir/state/task-x1.meta" "$case_dir/state/task-x1.before"
    branch_before=$(git -C "$case_dir/project" rev-parse refs/heads/fm/task-x1)
    if [ "$style" = stale ]; then
      git -C "$case_dir/wt" checkout -q --detach main
    fi

    set +e
    FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$case_dir" \
      FM_STATE_OVERRIDE="$case_dir/state" "$PROMOTE" task-x1 \
      > "$case_dir/promote.stdout" 2> "$case_dir/promote.stderr"
    rc=$?
    set -e

    expect_code 1 "$rc" "scout-promotion-refuse-$style: unproven branch identity must refuse promotion"
    cmp -s "$case_dir/state/task-x1.before" "$case_dir/state/task-x1.meta" \
      || fail "scout-promotion-refuse-$style: metadata changed after refusal"
    [ "$(git -C "$case_dir/project" rev-parse refs/heads/fm/task-x1)" = "$branch_before" ] \
      || fail "scout-promotion-refuse-$style: existing branch changed after refusal"
    [ -d "$case_dir/wt" ] \
      || fail "scout-promotion-refuse-$style: scout worktree was removed after refusal"
    if [ "$style" = stale ]; then
      [ -z "$(git -C "$case_dir/wt" symbolic-ref --quiet --short HEAD 2>/dev/null || true)" ] \
        || fail "scout-promotion-refuse-$style: detached worktree was changed after refusal"
    fi
  done
  pass "scout promotion refuses attached copies and stale acquisition branches"
}

# A project clone is registered by the path the captain chose, which is legitimately
# a symlink to the Git root, and fm-spawn.sh persists that registry path verbatim.
# Promotion must prove identity on the resolved paths and leave the recorded strings
# untouched, so no operator ever has to hand-edit a task record to promote a scout.
test_scout_promotion_accepts_registered_symlink_project() {
  local case_dir style project_arg worktree_arg rc
  for style in physical project-symlink both-symlink; do
    case_dir=$(make_case "scout-promotion-path-$style")
    project_arg="$case_dir/project"
    worktree_arg="$case_dir/wt"
    case "$style" in
      project-symlink)
        ln -s "$case_dir/project" "$case_dir/registry-clone"
        project_arg="$case_dir/registry-clone"
        ;;
      both-symlink)
        ln -s "$case_dir/project" "$case_dir/registry-clone"
        ln -s "$case_dir/wt" "$case_dir/registry-wt"
        project_arg="$case_dir/registry-clone"
        worktree_arg="$case_dir/registry-wt"
        ;;
    esac
    [ "$style" = physical ] || [ "$(cd "$project_arg" && pwd -P)" != "$project_arg" ] \
      || fail "scout-promotion-path-$style: fixture did not actually exercise a symlinked registry path"
    fm_write_meta "$case_dir/state/task-x1.meta" \
      "window=firstmate:fm-task-x1" \
      "worktree=$worktree_arg" \
      "project=$project_arg" \
      "acquisition_branch=-" \
      "kind=scout" \
      "mode=no-mistakes"
    git -C "$case_dir/wt" checkout -q --detach main
    git -C "$case_dir/project" branch -D -- fm/task-x1 >/dev/null

    FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$case_dir" \
      FM_STATE_OVERRIDE="$case_dir/state" "$PROMOTE" task-x1 \
      > "$case_dir/promote.stdout" 2> "$case_dir/promote.stderr" \
      || fail "scout-promotion-path-$style: promotion failed"$'\n'"$(cat "$case_dir/promote.stderr")"

    [ "$(grep -c "^project=$project_arg\$" "$case_dir/state/task-x1.meta")" = 1 ] \
      || fail "scout-promotion-path-$style: recorded project path was rewritten instead of preserved"
    [ "$(grep -c "^worktree=$worktree_arg\$" "$case_dir/state/task-x1.meta")" = 1 ] \
      || fail "scout-promotion-path-$style: recorded worktree path was rewritten instead of preserved"
    [ "$(grep -c '^kind=ship$' "$case_dir/state/task-x1.meta")" = 1 ] \
      || fail "scout-promotion-path-$style: ship kind was not recorded exactly once"
    [ "$(grep -c '^acquisition_branch=fm/task-x1$' "$case_dir/state/task-x1.meta")" = 1 ] \
      || fail "scout-promotion-path-$style: exact acquisition branch was not recorded once"
    [ "$(git -C "$case_dir/wt" symbolic-ref --quiet --short HEAD)" = fm/task-x1 ] \
      || fail "scout-promotion-path-$style: worktree was not attached to its acquired branch"
    git -C "$case_dir/project" show-ref --verify --quiet refs/heads/fm/task-x1 \
      || fail "scout-promotion-path-$style: exact acquisition branch was not created"

    # The promoted task must stay usable end to end on the same recorded paths, with
    # no hand edit anywhere: cleanup accepts the promoted branch, whose base is the
    # landed default branch, and retires the task record it was handed.
    set +e
    run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr"
    rc=$?
    set -e
    expect_code 0 "$rc" "scout-promotion-path-$style: promoted landed work should clean up on the recorded paths"$'\n'"$(cat "$case_dir/stderr")"
    [ ! -f "$case_dir/state/task-x1.meta" ] \
      || fail "scout-promotion-path-$style: task record survived a successful cleanup"
  done
  pass "scout promotion accepts a symlinked registry path without hand-editing the task record"
}

# Resolving paths for validation must not weaken identity: a worktree owned by a
# different repository, a symlink aimed below the Git root, and two inventory
# entries that resolve to one directory all stay refusals.
test_scout_promotion_refuses_aliased_identity() {
  local case_dir style rc project_arg worktree_arg expected
  for style in foreign-owner subdir-alias ambiguous-inventory; do
    case_dir=$(make_case "scout-promotion-alias-$style")
    project_arg="$case_dir/project"
    worktree_arg="$case_dir/wt"
    # Detach and drop the seeded branch before any alias registration exists, so
    # the aliased inventory entry cannot claim the branch and block the fixture.
    git -C "$case_dir/wt" checkout -q --detach main
    git -C "$case_dir/project" branch -D -- fm/task-x1 >/dev/null
    case "$style" in
      foreign-owner)
        fm_git_init_commit "$case_dir/other"
        git -C "$case_dir/other" worktree add -q --detach "$case_dir/otherwt"
        ln -s "$case_dir/otherwt" "$case_dir/registry-wt"
        worktree_arg="$case_dir/registry-wt"
        expected="does not belong to its project"
        ;;
      subdir-alias)
        mkdir -p "$case_dir/project/sub"
        ln -s "$case_dir/project/sub" "$case_dir/registry-clone"
        project_arg="$case_dir/registry-clone"
        expected="is not at its Git root"
        ;;
      ambiguous-inventory)
        ln -s "$case_dir/wt" "$case_dir/registry-wt"
        cp -R "$case_dir/project/.git/worktrees/wt" "$case_dir/project/.git/worktrees/wt-alias"
        printf '%s\n' "$case_dir/registry-wt/.git" \
          > "$case_dir/project/.git/worktrees/wt-alias/gitdir"
        expected="not uniquely registered"
        ;;
    esac
    fm_write_meta "$case_dir/state/task-x1.meta" \
      "window=firstmate:fm-task-x1" \
      "worktree=$worktree_arg" \
      "project=$project_arg" \
      "acquisition_branch=-" \
      "kind=scout" \
      "mode=no-mistakes"
    cp "$case_dir/state/task-x1.meta" "$case_dir/state/task-x1.before"

    set +e
    FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$case_dir" \
      FM_STATE_OVERRIDE="$case_dir/state" "$PROMOTE" task-x1 \
      > "$case_dir/promote.stdout" 2> "$case_dir/promote.stderr"
    rc=$?
    set -e

    expect_code 1 "$rc" "scout-promotion-alias-$style: aliased identity must refuse promotion"
    assert_contains "$(cat "$case_dir/promote.stderr")" "$expected" \
      "scout-promotion-alias-$style: refusal did not name the proven identity failure"
    cmp -s "$case_dir/state/task-x1.before" "$case_dir/state/task-x1.meta" \
      || fail "scout-promotion-alias-$style: metadata changed after refusal"
    git -C "$case_dir/project" show-ref --verify --quiet refs/heads/fm/task-x1 \
      && fail "scout-promotion-alias-$style: acquisition branch was created despite refusal"
    [ -z "$(git -C "$case_dir/wt" symbolic-ref --quiet --short HEAD 2>/dev/null || true)" ] \
      || fail "scout-promotion-alias-$style: detached worktree was changed after refusal"
  done
  pass "scout promotion refuses foreign, below-root, and ambiguous aliased identities"
}

test_scout_promotion_failure_preserves_metadata() {
  local case_dir rc
  case_dir=$(make_case scout-promotion-atomic-failure)
  write_meta "$case_dir" no-mistakes scout
  git -C "$case_dir/wt" checkout -q --detach main
  git -C "$case_dir/project" branch -D -- fm/task-x1 >/dev/null
  cp "$case_dir/state/task-x1.meta" "$case_dir/state/task-x1.before"
  cat > "$case_dir/fakebin/mv" <<'SH'
#!/usr/bin/env bash
exit 73
SH
  chmod +x "$case_dir/fakebin/mv"

  set +e
  PATH="$case_dir/fakebin:$PATH" FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$case_dir" \
    FM_STATE_OVERRIDE="$case_dir/state" "$PROMOTE" task-x1 \
    > "$case_dir/promote.stdout" 2> "$case_dir/promote.stderr"
  rc=$?
  set -e

  expect_code 73 "$rc" "scout-promotion-atomic-failure: publication failure must propagate"
  cmp -s "$case_dir/state/task-x1.before" "$case_dir/state/task-x1.meta" \
    || fail "scout-promotion-atomic-failure: partial metadata update escaped"
  [ -z "$(find "$case_dir/state" -maxdepth 1 -name '.fm-promote.*' -print -quit)" ] \
    || fail "scout-promotion-atomic-failure: temporary metadata remains"
  [ -z "$(git -C "$case_dir/wt" symbolic-ref --quiet --short HEAD 2>/dev/null || true)" ] \
    || fail "scout-promotion-atomic-failure: worktree remained attached after rollback"
  git -C "$case_dir/project" show-ref --verify --quiet refs/heads/fm/task-x1 \
    && fail "scout-promotion-atomic-failure: incomplete acquisition branch remains"
  pass "scout promotion publication failure preserves original metadata"
}

test_generic_return_retries_guarded_branch_cleanup() {
  local case_dir first_rc second_rc wt state route_count
  case_dir=$(make_case generic-branch-retry)
  write_meta "$case_dir" no-mistakes ship
  wt_commit "$case_dir" "landed generic retry work"
  git -C "$case_dir/wt" push -q origin fm/task-x1
  git -C "$case_dir/project" fetch -q origin
  configure_generic_pool_case "$case_dir"
  wt=$(grep '^worktree=' "$case_dir/state/task-x1.meta" | cut -d= -f2-)
  state=$(cat "$case_dir/config/fake-generic-state")
  cat > "$case_dir/fakebin/git" <<'SH'
#!/usr/bin/env bash
case " $* " in
  *" update-ref -d refs/heads/fm/task-x1 "*)
    if [ ! -e "${FM_FAKE_BRANCH_DELETE_FAILED:?}" ]; then
      : > "$FM_FAKE_BRANCH_DELETE_FAILED"
      exit 73
    fi
    ;;
esac
exec "${REAL_GIT_FOR_TEST:?}" "$@"
SH
  chmod +x "$case_dir/fakebin/git"

  set +e
  FM_FAKE_BRANCH_DELETE_FAILED="$case_dir/branch-delete-failed" \
    run_teardown "$case_dir" > "$case_dir/first.stdout" 2> "$case_dir/first.stderr"
  first_rc=$?
  set -e

  expect_code 1 "$first_rc" "generic-branch-retry: first branch deletion failure must preserve recovery state"
  [ ! -e "$wt" ] || fail "generic-branch-retry: provider did not remove the worktree"
  [ -f "$case_dir/state/task-x1.meta" ] || fail "generic-branch-retry: metadata was cleared after branch deletion failure"
  [ -f "$case_dir/state/task-x1.treehouse-return" ] \
    || fail "generic-branch-retry: provider-complete journal was not retained"
  grep -Fx 'state=provider-complete' "$case_dir/state/task-x1.treehouse-return" >/dev/null \
    || fail "generic-branch-retry: journal did not preserve provider completion"
  git -C "$case_dir/project" show-ref --verify --quiet refs/heads/fm/task-x1 \
    || fail "generic-branch-retry: acquisition branch disappeared despite injected deletion failure"
  [ "$(jq --arg path "$wt" '[.worktrees[]? | select(.path == $path)] | length' "$state")" = 0 ] \
    || fail "generic-branch-retry: provider state retained the removed worktree"

  set +e
  FM_FAKE_BRANCH_DELETE_FAILED="$case_dir/branch-delete-failed" \
    run_teardown "$case_dir" > "$case_dir/second.stdout" 2> "$case_dir/second.stderr"
  second_rc=$?
  set -e

  expect_code 0 "$second_rc" "generic-branch-retry: retry should finish guarded branch cleanup"
  [ ! -e "$case_dir/state/task-x1.treehouse-return" ] \
    || fail "generic-branch-retry: completed return journal remains after retry"
  [ ! -e "$case_dir/state/task-x1.meta" ] \
    || fail "generic-branch-retry: metadata remains after retry"
  git -C "$case_dir/project" show-ref --verify --quiet refs/heads/fm/task-x1 \
    && fail "generic-branch-retry: exact acquisition branch remains after retry"
  route_count=$(grep -c '^firstmate-return-route ' "$case_dir/treehouse.log" || true)
  [ "$route_count" = 1 ] \
    || fail "generic-branch-retry: retry invoked provider routing again"
  pass "generic return retries exact branch cleanup from durable provider state"
}

test_gh_error_and_content_absent_refuses() {
  local case_dir rc
  case_dir=$(make_case gh-error)
  write_meta "$case_dir" no-mistakes ship
  printf '%s\n' 'pr=https://github.com/example/repo/pull/7' >> "$case_dir/state/task-x1.meta"
  # Real content not pushed, the PR lookup errors, and origin/main never gained the
  # content. The fail-safe must refuse rather than allow on a transient gh failure.
  wt_commit_file "$case_dir" feature.txt hello "add feature"
  add_gh_axi_error "$case_dir"

  set +e
  run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "gh-error: teardown should refuse when the PR lookup errors and content is not landed"
  grep -q REFUSED "$case_dir/stderr" || fail "gh-error: no REFUSED line in stderr"
  pass "gh lookup error with content not in default refuses (fail-safe)"
}

test_stale_index_lock_cleared_and_teardown_succeeds() {
  local case_dir rc lock
  case_dir=$(make_case stale-index-lock)
  write_meta "$case_dir" no-mistakes ship
  wt_commit "$case_dir" "shippable work"
  git -C "$case_dir/wt" push -q origin fm/task-x1
  git -C "$case_dir/project" fetch -q origin

  add_lock_aware_treehouse "$case_dir"
  add_lsof_no_holder "$case_dir"

  lock=$(git_index_lock_path "$case_dir/wt")
  mkdir -p "$(dirname "$lock")"
  : > "$lock"
  touch -t 200001010000 "$lock"

  set +e
  FM_STALE_WORKTREE_LOCK_RETRY_WAIT_SECS=0 FM_STALE_WORKTREE_LOCK_AGE_SECS=1 \
    run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 0 "$rc" "stale-index-lock: teardown should succeed after clearing the provably stale lock"
  assert_grep "removed provably-stale git lock" "$case_dir/stderr" \
    "stale-index-lock: teardown did not report clearing the stale lock"
  assert_absent "$lock" "stale-index-lock: stale lock file should have been removed"
  pass "provably-stale worktree index.lock (old, no live holder) is cleared and teardown succeeds"
}

test_live_index_lock_is_never_removed_and_teardown_refuses() {
  local case_dir rc lock
  case_dir=$(make_case live-index-lock)
  write_meta "$case_dir" no-mistakes ship
  wt_commit "$case_dir" "shippable work"
  git -C "$case_dir/wt" push -q origin fm/task-x1
  git -C "$case_dir/project" fetch -q origin

  add_lock_aware_treehouse "$case_dir"
  add_lsof_live_holder "$case_dir"

  lock=$(git_index_lock_path "$case_dir/wt")
  mkdir -p "$(dirname "$lock")"
  : > "$lock"
  # Even an old mtime must not be enough on its own: a live holder always wins.
  touch -t 200001010000 "$lock"

  set +e
  FM_STALE_WORKTREE_LOCK_RETRY_WAIT_SECS=0 FM_STALE_WORKTREE_LOCK_AGE_SECS=1 \
    run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "live-index-lock: teardown should refuse when the lock has a live holder"
  assert_grep "not provably stale" "$case_dir/stderr" \
    "live-index-lock: teardown did not explain the refusal"
  assert_not_contains "$(cat "$case_dir/stderr")" "removed provably-stale git lock" \
    "live-index-lock: teardown removed a lock with a live holder"
  [ -e "$lock" ] || fail "live-index-lock: live-held lock file was removed"
  pass "live-held worktree index.lock is never removed and teardown refuses"
}

test_lsof_error_never_clears_index_lock() {
  local case_dir rc lock
  case_dir=$(make_case lsof-error-index-lock)
  write_meta "$case_dir" no-mistakes ship
  wt_commit "$case_dir" "shippable work"
  git -C "$case_dir/wt" push -q origin fm/task-x1
  git -C "$case_dir/project" fetch -q origin

  add_lock_aware_treehouse "$case_dir"
  add_lsof_error "$case_dir"

  lock=$(git_index_lock_path "$case_dir/wt")
  mkdir -p "$(dirname "$lock")"
  : > "$lock"
  touch -t 200001010000 "$lock"

  set +e
  FM_STALE_WORKTREE_LOCK_RETRY_WAIT_SECS=0 FM_STALE_WORKTREE_LOCK_AGE_SECS=1 \
    run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "lsof-error-index-lock: teardown should refuse when lsof errors"
  assert_grep "lsof check failed" "$case_dir/stderr" \
    "lsof-error-index-lock: teardown did not report the lsof failure"
  assert_grep "not provably stale" "$case_dir/stderr" \
    "lsof-error-index-lock: teardown did not explain the refusal"
  assert_not_contains "$(cat "$case_dir/stderr")" "removed provably-stale git lock" \
    "lsof-error-index-lock: teardown removed a lock after lsof failed"
  [ -e "$lock" ] || fail "lsof-error-index-lock: lock file was removed after lsof failed"
  pass "lsof errors leave worktree index.lock in place and refuse teardown"
}

test_stale_index_lock_cleanup_rechecks_dirty_worktree() {
  local case_dir rc lock
  case_dir=$(make_case stale-lock-dirty-recheck)
  write_meta "$case_dir" no-mistakes ship
  wt_commit_file "$case_dir" feature.txt landed "landed work"
  git -C "$case_dir/wt" push -q origin fm/task-x1
  git -C "$case_dir/project" fetch -q origin
  printf '%s\n' dirty > "$case_dir/wt/feature.txt"

  add_lock_aware_treehouse "$case_dir"
  add_lsof_no_holder "$case_dir"
  add_git_status_lock_failure "$case_dir"

  lock=$(git_index_lock_path "$case_dir/wt")
  mkdir -p "$(dirname "$lock")"
  : > "$lock"
  touch -t 200001010000 "$lock"

  set +e
  FM_STALE_WORKTREE_LOCK_RETRY_WAIT_SECS=0 FM_STALE_WORKTREE_LOCK_AGE_SECS=1 \
    run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "stale-lock-dirty-recheck: teardown should refuse dirty work after clearing the stale lock"
  assert_grep "removed provably-stale git lock" "$case_dir/stderr" \
    "stale-lock-dirty-recheck: teardown did not report clearing the stale lock"
  assert_grep "uncommitted changes present" "$case_dir/stderr" \
    "stale-lock-dirty-recheck: teardown did not re-run the dirty check"
  assert_absent "$lock" "stale-lock-dirty-recheck: stale lock file should have been removed"
  [ -f "$case_dir/state/task-x1.meta" ] || fail "stale-lock-dirty-recheck: teardown completed despite dirty work"
  pass "stale lock cleanup rechecks and refuses dirty worktree before return"
}

test_non_linked_index_lock_path_is_checked_from_worktree() {
  local case_dir rc lock
  case_dir=$(make_case non-linked-index-lock)
  git -C "$case_dir/project" worktree remove --force "$case_dir/wt"
  git clone -q "$case_dir/origin.git" "$case_dir/wt"
  git -C "$case_dir/wt" checkout -q -b fm/task-x1
  write_meta "$case_dir" no-mistakes ship
  wt_commit "$case_dir" "shippable normal clone work"
  git -C "$case_dir/wt" push -q origin fm/task-x1
  git -C "$case_dir/wt" fetch -q origin

  add_lock_aware_treehouse "$case_dir"
  add_lsof_no_holder "$case_dir"

  lock=$(git_index_lock_path "$case_dir/wt")
  mkdir -p "$(dirname "$lock")"
  : > "$lock"
  touch -t 200001010000 "$lock"

  set +e
  FM_STALE_WORKTREE_LOCK_RETRY_WAIT_SECS=0 FM_STALE_WORKTREE_LOCK_AGE_SECS=1 \
    run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 0 "$rc" "non-linked-index-lock: teardown should clear a normal repo index.lock"
  assert_grep "removed provably-stale git lock" "$case_dir/stderr" \
    "non-linked-index-lock: teardown did not report clearing the stale lock"
  assert_absent "$lock" "non-linked-index-lock: stale lock file should have been removed"
  pass "normal repo index.lock is resolved from the worktree and cleared when stale"
}

test_index_lock_mtime_read_failure_refuses() {
  local case_dir rc lock
  case_dir=$(make_case mtime-error-index-lock)
  write_meta "$case_dir" no-mistakes ship
  wt_commit "$case_dir" "shippable work"
  git -C "$case_dir/wt" push -q origin fm/task-x1
  git -C "$case_dir/project" fetch -q origin

  add_lock_aware_treehouse "$case_dir"
  add_lsof_no_holder "$case_dir"
  add_stat_error "$case_dir"

  lock=$(git_index_lock_path "$case_dir/wt")
  mkdir -p "$(dirname "$lock")"
  : > "$lock"
  touch -t 200001010000 "$lock"

  set +e
  FM_STALE_WORKTREE_LOCK_RETRY_WAIT_SECS=0 FM_STALE_WORKTREE_LOCK_AGE_SECS=1 \
    run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "mtime-error-index-lock: teardown should refuse when lock mtime cannot be read"
  assert_grep "cannot read mtime for git lock" "$case_dir/stderr" \
    "mtime-error-index-lock: teardown did not report the mtime read failure"
  assert_grep "not provably stale" "$case_dir/stderr" \
    "mtime-error-index-lock: teardown did not explain the refusal"
  assert_not_contains "$(cat "$case_dir/stderr")" "removed provably-stale git lock" \
    "mtime-error-index-lock: teardown removed a lock after mtime read failed"
  [ -e "$lock" ] || fail "mtime-error-index-lock: lock file was removed after mtime read failed"
  pass "lock mtime read failures leave worktree index.lock in place and refuse teardown"
}

test_transient_index_lock_clears_after_first_attempt_and_retry_succeeds() {
  local case_dir rc lock attempt_file
  case_dir=$(make_case transient-index-lock-retry)
  write_meta "$case_dir" no-mistakes ship
  wt_commit "$case_dir" "shippable work"
  git -C "$case_dir/wt" push -q origin fm/task-x1
  git -C "$case_dir/project" fetch -q origin

  add_transient_lock_treehouse "$case_dir"
  add_lsof_no_holder "$case_dir"

  lock=$(git_index_lock_path "$case_dir/wt")
  mkdir -p "$(dirname "$lock")"
  : > "$lock"
  # Fresh lock: not old enough for the force-remove path; patience must win.
  touch "$lock"

  attempt_file="$case_dir/treehouse-attempts"
  : > "$attempt_file"

  set +e
  TREEHOUSE_ATTEMPT_FILE="$attempt_file" \
  FM_TREEHOUSE_RETURN_LOCK_RETRIES=2 \
  FM_TREEHOUSE_RETURN_LOCK_RETRY_WAIT_SECS=0 \
  FM_STALE_WORKTREE_LOCK_AGE_SECS=3600 \
    run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 0 "$rc" "transient-index-lock: teardown should succeed on retry after lock self-clears"
  assert_grep "succeeded on retry" "$case_dir/stderr" \
    "transient-index-lock: teardown did not report success on retry"
  assert_not_contains "$(cat "$case_dir/stderr")" "removed provably-stale git lock" \
    "transient-index-lock: teardown force-removed a lock that only needed patience"
  [ "$(cat "$attempt_file")" = 2 ] \
    || fail "transient-index-lock: expected exactly 2 treehouse return attempts, got $(cat "$attempt_file")"
  assert_absent "$lock" "transient-index-lock: lock should remain cleared after success"
  pass "transient index.lock cleared after first failed return is retried successfully without force-remove"
}

test_persistent_index_lock_exhausts_retries_and_refuses_loudly() {
  local case_dir rc lock
  case_dir=$(make_case persistent-index-lock)
  write_meta "$case_dir" no-mistakes ship
  wt_commit "$case_dir" "shippable work"
  git -C "$case_dir/wt" push -q origin fm/task-x1
  git -C "$case_dir/project" fetch -q origin

  add_persistent_lock_treehouse "$case_dir"
  # Fresh lock with a live holder: never provably stale, never force-removed.
  add_lsof_live_holder "$case_dir"

  lock=$(git_index_lock_path "$case_dir/wt")
  mkdir -p "$(dirname "$lock")"
  : > "$lock"
  touch "$lock"

  set +e
  FM_TREEHOUSE_RETURN_LOCK_RETRIES=2 \
  FM_TREEHOUSE_RETURN_LOCK_RETRY_WAIT_SECS=0 \
  FM_STALE_WORKTREE_LOCK_AGE_SECS=3600 \
    run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "persistent-index-lock: teardown should refuse when the lock never clears"
  assert_grep "persisted across" "$case_dir/stderr" \
    "persistent-index-lock: teardown did not mention the exhausted retry window"
  assert_grep "not provably stale" "$case_dir/stderr" \
    "persistent-index-lock: teardown did not explain the refusal"
  assert_not_contains "$(cat "$case_dir/stderr")" "removed provably-stale git lock" \
    "persistent-index-lock: teardown removed a non-stale lock"
  [ -e "$lock" ] || fail "persistent-index-lock: lock file was removed"
  [ -f "$case_dir/state/task-x1.meta" ] \
    || fail "persistent-index-lock: teardown completed despite persistent lock"
  pass "persistent index.lock exhausts retries and refuses without force-removing the lock"
}

test_empty_retry_wait_uses_default_without_aborting() {
  local case_dir rc lock attempt_file
  case_dir=$(make_case empty-retry-wait)
  write_meta "$case_dir" no-mistakes ship
  wt_commit "$case_dir" "shippable work"
  git -C "$case_dir/wt" push -q origin fm/task-x1
  git -C "$case_dir/project" fetch -q origin

  add_transient_lock_treehouse "$case_dir"
  add_lsof_no_holder "$case_dir"

  lock=$(git_index_lock_path "$case_dir/wt")
  mkdir -p "$(dirname "$lock")"
  : > "$lock"

  attempt_file="$case_dir/treehouse-attempts"
  : > "$attempt_file"

  set +e
  TREEHOUSE_ATTEMPT_FILE="$attempt_file" \
  FM_TREEHOUSE_RETURN_LOCK_RETRIES=1 \
  FM_TREEHOUSE_RETURN_LOCK_RETRY_WAIT_SECS='' \
  FM_STALE_WORKTREE_LOCK_RETRY_WAIT_SECS='' \
  FM_STALE_WORKTREE_LOCK_AGE_SECS=3600 \
    run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 0 "$rc" "empty-retry-wait: teardown should fall back to the default wait"
  assert_grep "waiting 1s and retrying" "$case_dir/stderr" \
    "empty-retry-wait: teardown did not use the default retry wait"
  [ "$(cat "$attempt_file")" = 2 ] \
    || fail "empty-retry-wait: expected exactly 2 treehouse return attempts, got $(cat "$attempt_file")"
  pass "empty retry wait overrides use the default without aborting teardown"
}

test_fractional_legacy_retry_wait_refuses_without_arithmetic_error() {
  local case_dir rc lock
  case_dir=$(make_case fractional-legacy-retry-wait)
  write_meta "$case_dir" no-mistakes ship
  wt_commit "$case_dir" "shippable work"
  git -C "$case_dir/wt" push -q origin fm/task-x1
  git -C "$case_dir/project" fetch -q origin

  add_persistent_lock_treehouse "$case_dir"
  add_lsof_live_holder "$case_dir"

  lock=$(git_index_lock_path "$case_dir/wt")
  mkdir -p "$(dirname "$lock")"
  : > "$lock"

  set +e
  FM_TREEHOUSE_RETURN_LOCK_RETRIES=1 \
  FM_TREEHOUSE_RETURN_LOCK_RETRY_WAIT_SECS='' \
  FM_STALE_WORKTREE_LOCK_RETRY_WAIT_SECS=0.1 \
  FM_STALE_WORKTREE_LOCK_AGE_SECS=3600 \
    run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "fractional-legacy-retry-wait: teardown should fail only for the persistent lock"
  assert_grep "waiting 0.1s each" "$case_dir/stderr" \
    "fractional-legacy-retry-wait: teardown did not preserve the legacy fractional wait"
  assert_not_contains "$(cat "$case_dir/stderr")" "syntax error" \
    "fractional-legacy-retry-wait: teardown hit an arithmetic error"
  pass "fractional legacy retry wait remains supported without arithmetic"
}

test_local_only_force_overrides_unpushed() {
  local case_dir rc
  case_dir=$(make_case force-override)
  write_meta "$case_dir" local-only ship
  wt_commit "$case_dir" "unpushed work"

  set +e
  run_teardown "$case_dir" --force > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 0 "$rc" "force-override: --force should bypass the unpushed-work check"
  ! grep -q REFUSED "$case_dir/stderr" || fail "force-override: REFUSED printed despite --force"
  pass "local-only worktree with unpushed work is torn down under --force (escape hatch)"
}

test_teardown_missing_busy_sidecar_completes() {
  local case_dir gen rc
  case_dir=$(make_case missing-busy-sidecar)
  write_meta "$case_dir" local-only ship
  gen=$("$ROOT/bin/fm-busy-event.sh" arm "$case_dir/state" task-x1)
  printf 'busy_gen=%s\n' "$gen" >> "$case_dir/state/task-x1.meta"
  rm -f "$case_dir/state/task-x1.busy-gen"

  set +e
  run_teardown "$case_dir" --force > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 0 "$rc" "missing-busy-sidecar: teardown should treat the incarnation as already retired"
  assert_absent "$case_dir/state/task-x1.busy-state" \
    "missing-busy-sidecar: teardown left the orphan busy record"
  assert_absent "$case_dir/state/task-x1.meta" \
    "missing-busy-sidecar: teardown remained incomplete"
  pass "teardown completes when an exact busy-state sidecar is already absent"
}

test_herdr_teardown_clears_escalation_marker() {
  local case_dir marker closed
  case_dir=$(make_case herdr-marker-cleanup)
  write_meta "$case_dir" local-only ship
  sed -i.bak 's/^window=.*/window=default:wG:pQ/' "$case_dir/state/task-x1.meta"
  rm -f "$case_dir/state/task-x1.meta.bak"
  printf '%s\n' \
    'backend=herdr' \
    'herdr_session=default' \
    'herdr_workspace_id=wG' \
    'herdr_tab_id=wG:tQ' \
    'herdr_pane_id=wG:pQ' >> "$case_dir/state/task-x1.meta"
  # A reachable session whose exact pane is already structurally gone: the
  # locked close is a no-op and the record gate sees a confirmed-gone pane.
  cat > "$case_dir/fakebin/herdr" <<SH
#!/usr/bin/env bash
case "\${1:-} \${2:-}" in
  "session list") printf '%s\n' '{"sessions":[{"name":"default","running":true,"socket_path":"$case_dir/herdr.sock"}]}' ;;
  "status --json") printf '%s\n' '{"server":{"running":true}}' ;;
  "pane get") printf '%s\n' '{"error":{"code":"pane_not_found"}}'; exit 1 ;;
  *) exit 0 ;;
esac
SH
  chmod +x "$case_dir/fakebin/herdr"
  marker="$case_dir/state/.herdr-escalated-default_wG_pQ"
  closed="$case_dir/herdr-closed"
  : > "$marker"

  run_teardown "$case_dir" --force > "$case_dir/stdout" 2> "$case_dir/stderr" \
    || fail "herdr-marker-cleanup: forced teardown failed: $(cat "$case_dir/stderr")"
  [ ! -e "$marker" ] || fail "herdr-marker-cleanup: teardown left the pane's escalation marker behind"
  pass "herdr teardown removes pane-owned escalation dedupe state"
}

# Flat (non-projected) Herdr endpoint whose fake pane exists until a locked
# close removes it. The socket path is case-local so the derived presentation
# lock never collides with another test or a real fleet session.
configure_flat_herdr_teardown_case() {  # <case-dir>
  local case_dir=$1
  sed -i.bak 's/^window=.*/window=default:wG:pQ/' "$case_dir/state/task-x1.meta"
  rm -f "$case_dir/state/task-x1.meta.bak"
  printf '%s\n' \
    'backend=herdr' \
    'herdr_session=default' \
    'herdr_workspace_id=wG' \
    'herdr_tab_id=wG:tQ' \
    'herdr_pane_id=wG:pQ' >> "$case_dir/state/task-x1.meta"
  cat > "$case_dir/fakebin/herdr" <<SH
#!/usr/bin/env bash
set -u
printf '%s\n' "\$*" >> "\${FM_FAKE_HERDR_LOG:?}"
case "\${1:-} \${2:-}" in
  "workspace list")
    printf '%s\n' '{"result":{"workspaces":[{"workspace_id":"wH","active_tab_id":"wH:t1","focused":true},{"workspace_id":"wG","active_tab_id":"wG:tQ","focused":false}]}}'
    ;;
  "tab list")
    case "\$*" in
      *"--workspace wH"*) printf '%s\n' '{"result":{"tabs":[{"tab_id":"wH:t1","focused":true}]}}' ;;
      *"--workspace wG"*) printf '%s\n' '{"result":{"tabs":[{"tab_id":"wG:tQ","workspace_id":"wG"}]}}' ;;
      *) printf '%s\n' '{"result":{"tabs":[]}}' ;;
    esac
    ;;
  "pane list")
    printf '%s\n' '{"result":{"panes":[{"pane_id":"wG:pQ","tab_id":"wG:tQ"}]}}'
    ;;
  "status --json")
    printf '%s\n' '{"server":{"running":true}}'
    ;;
  "session list")
    if [ "\${FM_FAKE_HERDR_SESSION_LIST_GARBAGE:-0}" = 1 ]; then
      printf '%s\n' 'not-json'
    else
      printf '%s\n' '{"sessions":[{"name":"default","running":true,"socket_path":"$case_dir/herdr.sock"}]}'
    fi
    ;;
  "pane close")
    : > "\${FM_FAKE_HERDR_CLOSED:?}"
    ;;
  "pane get")
    if [ "\${FM_FAKE_HERDR_PANE_GET_GARBAGE:-0}" = 1 ]; then
      printf '%s\n' 'not-json'
      exit 0
    fi
    if [ -e "\${FM_FAKE_HERDR_CLOSED:?}" ]; then
      printf '%s\n' '{"error":{"code":"pane_not_found"}}' >&2
      exit 1
    fi
    printf '%s\n' '{"result":{"pane":{"pane_id":"wG:pQ","tab_id":"wG:tQ","workspace_id":"wG"}}}'
    ;;
  "agent get")
    printf '%s\n' '{"error":{"code":"agent_not_found"}}' >&2
    exit 1
    ;;
esac
SH
  chmod +x "$case_dir/fakebin/herdr"
}

test_herdr_flat_teardown_refuses_orphaning_records_then_retry_completes() {
  local case_dir log closed lock ready release holder_pid rc thlog
  case_dir=$(make_case herdr-orphan-refusal)
  write_meta "$case_dir" local-only ship
  configure_flat_herdr_teardown_case "$case_dir"
  log="$case_dir/herdr.log"; : > "$log"
  closed="$case_dir/closed"
  : > "$case_dir/state/task-x1.status"
  : > "$case_dir/state/task-x1.turn-ended"
  # Record every treehouse invocation: the contended-lock refusal must fire
  # BEFORE the isolated copy is returned, so phase 1 may not invoke it at all.
  thlog="$case_dir/treehouse.log"; : > "$thlog"
  cat > "$case_dir/fakebin/treehouse" <<SH
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$thlog"
exit 0
SH
  chmod +x "$case_dir/fakebin/treehouse"

  lock=$(FM_FAKE_HERDR_LOG="$log" FM_FAKE_HERDR_CLOSED="$closed" PATH="$case_dir/fakebin:$PATH" \
    bash -c '. "$0/bin/backends/herdr.sh"; fm_backend_herdr_presentation_session_lock_path default' "$ROOT") \
    || fail "herdr-orphan-refusal: could not resolve the fixture presentation lock path"
  ready="$case_dir/lock-ready"; release="$case_dir/lock-release"
  ROOT="$ROOT" LOCK="$lock" READY="$ready" RELEASE="$release" bash -c '
    . "$ROOT/bin/fm-wake-lib.sh"
    fm_lock_try_acquire "$LOCK" || exit 1
    : > "$READY"
    while [ ! -e "$RELEASE" ]; do sleep 0.1; done
    fm_lock_release "$LOCK"
  ' &
  holder_pid=$!
  local waited=0
  while [ ! -e "$ready" ] && [ "$waited" -lt 50 ]; do sleep 0.1; waited=$((waited + 1)); done
  [ -e "$ready" ] || fail "herdr-orphan-refusal: the contending lock holder never started"

  rc=0
  FM_FAKE_HERDR_LOG="$log" FM_FAKE_HERDR_CLOSED="$closed" \
    run_teardown "$case_dir" --force > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?
  if [ "$rc" -eq 0 ]; then
    : > "$release"; wait "$holder_pid" 2>/dev/null || true
    fail "herdr-orphan-refusal: teardown reported success while the exact pane still existed under lock contention"
  fi
  [ -e "$case_dir/state/task-x1.meta" ] || { : > "$release"; fail "herdr-orphan-refusal: refusal erased the durable endpoint metadata"; }
  [ -e "$case_dir/state/task-x1.status" ] || { : > "$release"; fail "herdr-orphan-refusal: refusal erased the task status record"; }
  [ -e "$case_dir/state/task-x1.turn-ended" ] || { : > "$release"; fail "herdr-orphan-refusal: refusal erased the turn-end record"; }
  assert_grep "presentation lock is contended" "$case_dir/stderr" \
    "herdr-orphan-refusal: the pre-return refusal was not explained visibly"
  if [ -s "$thlog" ]; then
    : > "$release"; fail "herdr-orphan-refusal: the contended refusal still returned the isolated copy: $(cat "$thlog")"
  fi
  [ -d "$case_dir/wt" ] || { : > "$release"; fail "herdr-orphan-refusal: the contended refusal removed the isolated copy"; }
  if [ "$(git -C "$case_dir/wt" rev-parse --abbrev-ref HEAD 2>/dev/null)" != "fm/task-x1" ]; then
    : > "$release"; fail "herdr-orphan-refusal: the contended refusal dropped the task branch before refusing"
  fi
  if grep -q "teardown task-x1 complete" "$case_dir/stdout"; then
    : > "$release"; fail "herdr-orphan-refusal: refusal still reported cleanup complete"
  fi
  if grep -q "^pane close" "$log"; then
    : > "$release"; fail "herdr-orphan-refusal: an unlocked pane close was attempted under contention"
  fi

  : > "$release"
  wait "$holder_pid" 2>/dev/null || true
  FM_FAKE_HERDR_LOG="$log" FM_FAKE_HERDR_CLOSED="$closed" FM_BACKEND_HERDR_IDLE_SHELL_PROOF_POLLS=1 \
    run_teardown "$case_dir" --force > "$case_dir/stdout2" 2> "$case_dir/stderr2" \
    || fail "herdr-orphan-refusal: the retry after lock release failed: $(cat "$case_dir/stderr2")"
  [ -e "$closed" ] || fail "herdr-orphan-refusal: the retry never closed the pane under the lock"
  [ -s "$thlog" ] || fail "herdr-orphan-refusal: the successful retry never returned the isolated copy"
  [ ! -e "$case_dir/state/task-x1.meta" ] || fail "herdr-orphan-refusal: the successful retry left the metadata behind"
  [ ! -e "$case_dir/state/task-x1.status" ] || fail "herdr-orphan-refusal: the successful retry left the status record behind"
  grep -q "teardown task-x1 complete" "$case_dir/stdout2" \
    || fail "herdr-orphan-refusal: the successful retry did not report completion"
  pass "herdr flat teardown refuses before returning the isolated copy under lock contention and the retry completes cleanly"
}

test_herdr_flat_teardown_refuses_records_on_unparseable_presence() {
  local case_dir log closed rc
  case_dir=$(make_case herdr-garbage-presence)
  write_meta "$case_dir" local-only ship
  configure_flat_herdr_teardown_case "$case_dir"
  log="$case_dir/herdr.log"; : > "$log"
  closed="$case_dir/closed"
  : > "$case_dir/state/task-x1.status"
  rc=0
  FM_FAKE_HERDR_LOG="$log" FM_FAKE_HERDR_CLOSED="$closed" FM_FAKE_HERDR_PANE_GET_GARBAGE=1 \
    FM_BACKEND_HERDR_IDLE_SHELL_PROOF_POLLS=1 \
    run_teardown "$case_dir" --force > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?
  [ "$rc" -ne 0 ] \
    || fail "herdr-garbage-presence: teardown erased records on an unparseable pane presence"
  [ -e "$case_dir/state/task-x1.meta" ] \
    || fail "herdr-garbage-presence: ambiguous presence erased the durable endpoint metadata"
  [ -e "$case_dir/state/task-x1.status" ] \
    || fail "herdr-garbage-presence: ambiguous presence erased the task status record"
  assert_grep "ambiguous structured presence" "$case_dir/stderr" \
    "herdr-garbage-presence: the ambiguity refusal was not explained visibly"
  pass "herdr flat teardown never erases records when pane presence is unparseable"
}

assert_herdr_teardown_preflight_refuses_before_changes() {
  local mode=$1 case_dir log closed rc thlog teardown_bin
  case_dir=$(make_case "herdr-preflight-$mode")
  write_meta "$case_dir" local-only ship
  configure_flat_herdr_teardown_case "$case_dir"
  log="$case_dir/herdr.log"; : > "$log"
  closed="$case_dir/closed"
  : > "$case_dir/state/task-x1.status"
  : > "$case_dir/state/task-x1.turn-ended"
  thlog="$case_dir/treehouse.log"; : > "$thlog"
  cat > "$case_dir/fakebin/treehouse" <<SH
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$thlog"
exit 0
SH
  chmod +x "$case_dir/fakebin/treehouse"

  teardown_bin=$TEARDOWN
  case "$mode" in
    missing-adapter|missing-parser|missing-explicit-close-helper)
      mkdir -p "$case_dir/test-root"
      cp -R "$ROOT/bin" "$case_dir/test-root/bin"
      if [ "$mode" = missing-adapter ]; then
        rm -f "$case_dir/test-root/bin/backends/herdr.sh"
      elif [ "$mode" = missing-explicit-close-helper ]; then
        sed -i.bak 's/^fm_backend_herdr_explicit_close_pane_confirmed()/fm_backend_herdr_explicit_close_pane_confirmed_unavailable()/' \
          "$case_dir/test-root/bin/backends/herdr.sh"
        rm -f "$case_dir/test-root/bin/backends/herdr.sh.bak"
      else
        sed -i.bak 's/^fm_backend_herdr_parse_target()/fm_backend_herdr_parse_target_unavailable()/' \
          "$case_dir/test-root/bin/backends/herdr.sh"
        rm -f "$case_dir/test-root/bin/backends/herdr.sh.bak"
      fi
      teardown_bin="$case_dir/test-root/bin/fm-teardown.sh"
      ;;
  esac
  rc=0
  FM_ROOT_OVERRIDE="$ROOT" FM_STATE_OVERRIDE="$case_dir/state" FM_CONFIG_OVERRIDE="$case_dir/config" \
    FM_FAKE_HERDR_LOG="$log" FM_FAKE_HERDR_CLOSED="$closed" \
    FM_FAKE_HERDR_SESSION_LIST_GARBAGE="$([ "$mode" = unresolvable-lock ] && printf 1 || printf 0)" \
    PATH="$case_dir/fakebin:$PATH" \
    "$teardown_bin" task-x1 --force > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?
  [ "$rc" -ne 0 ] || fail "herdr-preflight-$mode: teardown continued without its required preflight"
  assert_grep "nothing was changed" "$case_dir/stderr" \
    "herdr-preflight-$mode: the retryable pre-return refusal was not explained visibly"
  [ -d "$case_dir/wt" ] || fail "herdr-preflight-$mode: refusal removed the isolated copy"
  [ "$(git -C "$case_dir/wt" rev-parse --abbrev-ref HEAD 2>/dev/null)" = "fm/task-x1" ] \
    || fail "herdr-preflight-$mode: refusal dropped the task branch"
  [ -e "$case_dir/state/task-x1.meta" ] \
    || fail "herdr-preflight-$mode: refusal erased the durable endpoint metadata"
  [ -e "$case_dir/state/task-x1.status" ] \
    || fail "herdr-preflight-$mode: refusal erased the task status record"
  [ -e "$case_dir/state/task-x1.turn-ended" ] \
    || fail "herdr-preflight-$mode: refusal erased the turn-end record"
  [ ! -s "$thlog" ] || fail "herdr-preflight-$mode: refusal returned the isolated copy"
  [ ! -e "$closed" ] || fail "herdr-preflight-$mode: refusal attempted an unlocked pane close"
}

test_herdr_flat_teardown_preflight_refuses_before_changes() {
  assert_herdr_teardown_preflight_refuses_before_changes unresolvable-lock
  assert_herdr_teardown_preflight_refuses_before_changes missing-adapter
  assert_herdr_teardown_preflight_refuses_before_changes missing-parser
  assert_herdr_teardown_preflight_refuses_before_changes missing-explicit-close-helper
  pass "herdr flat teardown preflight refuses before every destructive change"
}

configure_secondmate_with_herdr_child() {  # <case-dir>
  local case_dir=$1 home="$1/secondmate-home"
  mkdir -p "$home/state" "$home/data" "$home/config" "$home/projects"
  printf '%s\n' task-x1 > "$home/.fm-secondmate-home"
  printf '%s\n' "home=$home" >> "$case_dir/state/task-x1.meta"
  fm_write_meta "$home/state/child-herdr.meta" \
    "window=childsession:wC:p1" \
    "endpoint_task_id=child-herdr" \
    "worktree=$case_dir/wt" \
    "project=$case_dir/project" \
    "kind=ship" \
    "mode=local-only" \
    "backend=herdr" \
    "herdr_session=childsession" \
    "herdr_workspace_id=wC" \
    "herdr_tab_id=wC:t1" \
    "herdr_pane_id=wC:p1"
  : > "$home/state/child-herdr.status"
  : > "$home/state/child-herdr.turn-ended"
  cat > "$case_dir/fakebin/herdr" <<SH
#!/usr/bin/env bash
set -u
printf '%s\n' "\$*" >> "\${FM_FAKE_HERDR_LOG:?}"
case "\${1:-} \${2:-}" in
  "session list")
    if [ "\${FM_FAKE_HERDR_SESSION_LIST_GARBAGE:-0}" = 1 ]; then
      printf '%s\n' 'not-json'
    else
      printf '%s\n' '{"sessions":[{"name":"childsession","running":true,"socket_path":"$case_dir/child.sock"}]}'
    fi
    ;;
  "workspace list") exit 1 ;;
  "pane get")
    if [ -e "\${FM_FAKE_HERDR_CLOSED:?}" ]; then
      if [ "\${FM_FAKE_HERDR_PRESENCE_UNKNOWN:-0}" = 1 ]; then
        printf '%s\n' 'not-json'
      else
        printf '%s\n' '{"error":{"code":"pane_not_found"}}' >&2
        exit 1
      fi
    else
      printf '%s\n' '{"result":{"pane":{"pane_id":"wC:p1","tab_id":"wC:t1","workspace_id":"wC"}}}'
    fi
    ;;
  "pane close") : > "\${FM_FAKE_HERDR_CLOSED:?}" ;;
esac
SH
  chmod +x "$case_dir/fakebin/herdr"
}

test_forced_secondmate_herdr_child_preflight_refuses_before_changes() {
  local case_dir home log closed rc thlog
  case_dir=$(make_case herdr-child-preflight)
  write_meta "$case_dir" local-only secondmate
  configure_secondmate_with_herdr_child "$case_dir"
  home="$case_dir/secondmate-home"
  log="$case_dir/herdr.log"; closed="$case_dir/closed"; thlog="$case_dir/treehouse.log"
  : > "$log"; : > "$thlog"
  cat > "$case_dir/fakebin/treehouse" <<SH
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$thlog"
exit 0
SH
  chmod +x "$case_dir/fakebin/treehouse"
  rc=0
  FM_FAKE_HERDR_LOG="$log" FM_FAKE_HERDR_CLOSED="$closed" \
    FM_FAKE_HERDR_SESSION_LIST_GARBAGE=1 \
    run_teardown "$case_dir" --force > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?
  [ "$rc" -ne 0 ] || fail "herdr-child-preflight: teardown continued through an unresolvable child lock"
  [ -e "$case_dir/state/task-x1.meta" ] || fail "herdr-child-preflight: refusal erased the parent record"
  [ -e "$home/state/child-herdr.meta" ] || fail "herdr-child-preflight: refusal erased the child record"
  [ -e "$home/state/child-herdr.status" ] || fail "herdr-child-preflight: refusal erased child status"
  [ -d "$home" ] || fail "herdr-child-preflight: refusal removed the secondmate home"
  [ ! -s "$thlog" ] || fail "herdr-child-preflight: refusal returned work before child preflight"
  [ ! -e "$closed" ] || fail "herdr-child-preflight: refusal attempted a child close"
  assert_grep "nothing was changed" "$case_dir/stderr" \
    "herdr-child-preflight: refusal did not explain its non-mutating boundary"
  pass "forced secondmate teardown preflights every Herdr child before cleanup mutation"
}

test_forced_secondmate_herdr_child_retains_records_when_close_unconfirmed() {
  local case_dir home log closed rc
  case_dir=$(make_case herdr-child-unconfirmed-close)
  write_meta "$case_dir" local-only secondmate
  configure_secondmate_with_herdr_child "$case_dir"
  home="$case_dir/secondmate-home"
  log="$case_dir/herdr.log"; closed="$case_dir/closed"; : > "$log"
  rc=0
  FM_FAKE_HERDR_LOG="$log" FM_FAKE_HERDR_CLOSED="$closed" FM_FAKE_HERDR_PRESENCE_UNKNOWN=1 \
    run_teardown "$case_dir" --force > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?
  [ "$rc" -ne 0 ] || fail "herdr-child-unconfirmed-close: teardown erased records after an ambiguous close"
  [ -e "$closed" ] || fail "herdr-child-unconfirmed-close: fixture did not attempt the child close"
  [ -e "$home/state/child-herdr.meta" ] || fail "herdr-child-unconfirmed-close: ambiguous close erased child metadata"
  [ -e "$home/state/child-herdr.status" ] || fail "herdr-child-unconfirmed-close: ambiguous close erased child status"
  [ -e "$case_dir/state/task-x1.meta" ] || fail "herdr-child-unconfirmed-close: failed child cleanup erased parent metadata"
  [ -d "$home" ] || fail "herdr-child-unconfirmed-close: failed child cleanup removed the secondmate home"
  assert_grep "retaining that child's durable identity records" "$case_dir/stderr" \
    "herdr-child-unconfirmed-close: refusal did not explain child record retention"
  pass "forced secondmate teardown retains Herdr child identity until exact pane disappearance"
}

configure_nested_secondmate_with_herdr_grandchild() {  # <case-dir>
  local case_dir=$1 home="$1/secondmate-home" nested_home="$1/secondmate-home/nested-home"
  mkdir -p "$home/state" "$home/data" "$home/config" "$home/projects"
  mkdir -p "$nested_home/state" "$nested_home/data" "$nested_home/config" "$nested_home/projects"
  printf '%s\n' task-x1 > "$home/.fm-secondmate-home"
  printf '%s\n' nested-sm > "$nested_home/.fm-secondmate-home"
  printf '%s\n' "home=$home" >> "$case_dir/state/task-x1.meta"
  fm_write_meta "$home/state/nested-sm.meta" \
    "window=firstmate:fm-nested-sm" \
    "endpoint_task_id=nested-sm" \
    "worktree=$case_dir/wt" \
    "project=$case_dir/project" \
    "kind=secondmate" \
    "mode=local-only" \
    "home=$nested_home"
  fm_write_meta "$nested_home/state/grandchild-herdr.meta" \
    "window=grandchildsession:wG:p1" \
    "endpoint_task_id=grandchild-herdr" \
    "worktree=$case_dir/wt" \
    "project=$case_dir/project" \
    "kind=ship" \
    "mode=local-only" \
    "backend=herdr" \
    "herdr_session=grandchildsession" \
    "herdr_workspace_id=wG" \
    "herdr_tab_id=wG:t1" \
    "herdr_pane_id=wG:p1"
  : > "$nested_home/state/grandchild-herdr.status"
  : > "$nested_home/state/grandchild-herdr.turn-ended"
  cat > "$case_dir/fakebin/herdr" <<SH
#!/usr/bin/env bash
set -u
printf '%s\n' "\$*" >> "\${FM_FAKE_HERDR_LOG:?}"
case "\${1:-} \${2:-}" in
  "session list")
    printf '%s\n' '{"sessions":[{"name":"grandchildsession","running":true,"socket_path":"$case_dir/grandchild.sock"}]}'
    ;;
  "workspace list") exit 1 ;;
  "pane get")
    if [ -e "\${FM_FAKE_HERDR_CLOSED:?}" ]; then
      printf '%s\n' 'not-json'
    else
      printf '%s\n' '{"result":{"pane":{"pane_id":"wG:p1","tab_id":"wG:t1","workspace_id":"wG"}}}'
    fi
    ;;
  "pane close") : > "\${FM_FAKE_HERDR_CLOSED:?}" ;;
esac
SH
  chmod +x "$case_dir/fakebin/herdr"
}

test_forced_teardown_retains_nested_secondmate_home_when_grandchild_close_unconfirmed() {
  local case_dir home nested_home log closed rc
  case_dir=$(make_case herdr-grandchild-unconfirmed-close)
  write_meta "$case_dir" local-only secondmate
  configure_nested_secondmate_with_herdr_grandchild "$case_dir"
  home="$case_dir/secondmate-home"; nested_home="$home/nested-home"
  log="$case_dir/herdr.log"; closed="$case_dir/closed"; : > "$log"
  rc=0
  FM_FAKE_HERDR_LOG="$log" FM_FAKE_HERDR_CLOSED="$closed" \
    run_teardown "$case_dir" --force > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?
  [ "$rc" -ne 0 ] \
    || fail "herdr-grandchild-unconfirmed-close: teardown erased records after an ambiguous grandchild close"
  [ -e "$closed" ] \
    || fail "herdr-grandchild-unconfirmed-close: fixture did not attempt the grandchild close"
  [ -d "$nested_home" ] \
    || fail "herdr-grandchild-unconfirmed-close: the recursive failure still removed the nested secondmate home"
  [ -e "$nested_home/state/grandchild-herdr.meta" ] \
    || fail "herdr-grandchild-unconfirmed-close: ambiguous close erased the grandchild's metadata"
  [ -e "$nested_home/state/grandchild-herdr.status" ] \
    || fail "herdr-grandchild-unconfirmed-close: ambiguous close erased the grandchild's status record"
  [ -e "$home/state/nested-sm.meta" ] \
    || fail "herdr-grandchild-unconfirmed-close: the recursive failure erased the nested secondmate's own record"
  [ -e "$case_dir/state/task-x1.meta" ] \
    || fail "herdr-grandchild-unconfirmed-close: the recursive failure erased the top-level secondmate's record"
  pass "forced teardown retains a nested secondmate home and its grandchild's Herdr identity when the grandchild close is unconfirmed"
}

configure_herdr_projection_teardown_case() {  # <case-dir>
  local case_dir=$1 token=AbCdEfGhIjKlMnOpQrStUv
  sed -i.bak 's/^window=.*/window=fmtest:w1:p2/' "$case_dir/state/task-x1.meta"
  rm -f "$case_dir/state/task-x1.meta.bak"
  printf '%s\n' \
    'backend=herdr' \
    'herdr_session=fmtest' \
    'herdr_workspace_id=w1' \
    'herdr_tab_id=w1:t2' \
    'herdr_pane_id=w1:p2' >> "$case_dir/state/task-x1.meta"
  printf '%s\n' \
    'version=1' \
    'task_id=task-x1' \
    "projection_id=$token" > "$case_dir/state/task-x1.herdr-presentation"
  cat > "$case_dir/fakebin/herdr" <<'SH'
#!/usr/bin/env bash
set -u
printf '%s\n' "$*" >> "${FM_FAKE_HERDR_LOG:?}"
case "${1:-} ${2:-}" in
  "workspace list")
    if [ -e "${FM_FAKE_HERDR_RESTORED:?}" ]; then
      printf '%s\n' '{"result":{"workspaces":[{"workspace_id":"w2","active_tab_id":"w2:t2","label":"2ndmate-bravo","focused":true},{"workspace_id":"w3","active_tab_id":"w3:t1","label":"2ndmate-alpha","focused":false}]}}'
    elif [ -e "${FM_FAKE_HERDR_CLOSED:?}" ]; then
      printf '%s\n' '{"result":{"workspaces":[{"workspace_id":"w2","active_tab_id":"w2:t2","label":"2ndmate-bravo","focused":false},{"workspace_id":"w3","active_tab_id":"w3:t1","label":"2ndmate-alpha","focused":true}]}}'
    else
      printf '%s\n' '{"result":{"workspaces":[{"workspace_id":"w1","active_tab_id":"w1:t2","label":"firstmate/task-x1 · p:AbCdEfGhIjKlMnOpQrStUv","focused":false},{"workspace_id":"w2","active_tab_id":"w2:t2","label":"2ndmate-bravo","focused":true},{"workspace_id":"w3","active_tab_id":"w3:t1","label":"2ndmate-alpha","focused":false}]}}'
    fi
    ;;
  "tab list")
    case "$*" in
      *"--workspace w2"*) printf '%s\n' '{"result":{"tabs":[{"tab_id":"w2:t2","focused":true}]}}' ;;
      *"--workspace w3"*) printf '%s\n' '{"result":{"tabs":[{"tab_id":"w3:t1","focused":true}]}}' ;;
      *) printf '%s\n' '{"result":{"tabs":[]}}' ;;
    esac
    ;;
  "status --json")
    printf '%s\n' '{"server":{"running":true}}'
    ;;
  "session list")
    printf '%s\n' '{"sessions":[{"name":"fmtest","running":true,"socket_path":"/tmp/fmtest.sock"}]}'
    ;;
  "pane close")
    if [ "${FM_FAKE_HERDR_CLOSE_FAIL:-0}" = 1 ]; then
      exit 1
    fi
    : > "${FM_FAKE_HERDR_CLOSED:?}"
    ;;
  "pane get")
    if [ -e "${FM_FAKE_HERDR_CLOSED:?}" ]; then
      if [ "${FM_FAKE_HERDR_PRESENCE_UNKNOWN:-0}" = 1 ]; then
        printf '%s\n' '{"error":{"code":"internal"}}' >&2
        exit 1
      fi
      printf '%s\n' '{"error":{"code":"pane_not_found"}}' >&2
      exit 1
    fi
    printf '%s\n' '{"result":{"pane":{"pane_id":"w1:p2","tab_id":"w1:t2","workspace_id":"w1"}}}'
    ;;
  "tab get")
    printf '%s\n' '{"result":{"tab":{"tab_id":"w2:t2","workspace_id":"w2"}}}'
    ;;
  "tab focus")
    : > "${FM_FAKE_HERDR_RESTORED:?}"
    printf '%s\n' '{"result":{"tab":{"tab_id":"w2:t2","workspace_id":"w2","focused":true}}}'
    ;;
  "agent get")
    printf '%s\n' '{"error":{"code":"agent_not_found"}}' >&2
    exit 1
    ;;
esac
SH
  chmod +x "$case_dir/fakebin/herdr"
}

test_herdr_projection_teardown_retires_journal_only_after_confirmed_close() {
  local case_dir log closed restored
  case_dir=$(make_case herdr-projection-confirmed-close)
  write_meta "$case_dir" local-only ship
  configure_herdr_projection_teardown_case "$case_dir"
  log="$case_dir/herdr.log"; closed="$case_dir/closed"; restored="$case_dir/restored"; : > "$log"

  FM_FAKE_HERDR_LOG="$log" FM_FAKE_HERDR_CLOSED="$closed" FM_FAKE_HERDR_RESTORED="$restored" \
    run_teardown "$case_dir" --force > "$case_dir/stdout" 2> "$case_dir/stderr" \
    || fail "herdr-projection-confirmed-close: forced teardown failed"
  [ ! -e "$case_dir/state/task-x1.herdr-presentation" ] \
    || fail "confirmed exact-pane close did not retire the presentation journal"
  assert_not_contains "$(cat "$log")" "workspace close" \
    "projected teardown must never call workspace close"
  assert_contains "$(cat "$log")" "tab focus w2:t2" \
    "projected teardown did not restore the exact pre-close active tab"
  pass "herdr projection teardown retires its journal only after confirming the exact recorded pane is gone"
}

test_herdr_projection_teardown_retains_journal_when_close_unconfirmed() {
  local case_dir log closed restored rc
  case_dir=$(make_case herdr-projection-unconfirmed-close)
  write_meta "$case_dir" local-only ship
  configure_herdr_projection_teardown_case "$case_dir"
  log="$case_dir/herdr.log"; closed="$case_dir/closed"; restored="$case_dir/restored"; : > "$log"

  rc=0
  FM_FAKE_HERDR_LOG="$log" FM_FAKE_HERDR_CLOSED="$closed" FM_FAKE_HERDR_RESTORED="$restored" FM_FAKE_HERDR_PRESENCE_UNKNOWN=1 \
    run_teardown "$case_dir" --force > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?
  [ "$rc" -ne 0 ] \
    || fail "herdr-projection-unconfirmed-close: teardown reported success after an unknown post-close presence read"
  [ -e "$closed" ] \
    || fail "herdr-projection-unconfirmed-close: regression did not exercise an attempted close"
  [ -e "$case_dir/state/task-x1.herdr-presentation" ] \
    || fail "unconfirmed task-pane close incorrectly retired the presentation journal"
  [ -e "$case_dir/state/task-x1.meta" ] \
    || fail "unconfirmed task-pane close erased the durable endpoint metadata"
  assert_grep "close could not be confirmed" "$case_dir/stderr" \
    "unconfirmed projected close did not explain why the journal was retained"
  assert_grep "not confirmed gone" "$case_dir/stderr" \
    "unconfirmed projected close did not explain why the records were retained"
  assert_not_contains "$(cat "$log")" "workspace close" \
    "unconfirmed projected close must not escalate to workspace cleanup"
  pass "herdr projection teardown retains every record when post-close presence is unknown"
}

test_local_only_fork_remote_allows
test_teardown_prompts_tasks_axi_done_when_compatible
test_teardown_manual_backend_prompts_hand_edit_even_when_tasks_axi_present
test_local_only_truly_unpushed_refuses
test_local_only_merged_to_local_main_allows
test_no_mistakes_origin_remote_allows
test_no_mistakes_truly_unpushed_refuses
test_local_only_force_overrides_unpushed
test_teardown_missing_busy_sidecar_completes
test_herdr_teardown_clears_escalation_marker
test_herdr_flat_teardown_refuses_orphaning_records_then_retry_completes
test_herdr_flat_teardown_refuses_records_on_unparseable_presence
test_herdr_flat_teardown_preflight_refuses_before_changes
test_forced_secondmate_herdr_child_preflight_refuses_before_changes
test_forced_secondmate_herdr_child_retains_records_when_close_unconfirmed
test_forced_teardown_retains_nested_secondmate_home_when_grandchild_close_unconfirmed
test_herdr_projection_teardown_retires_journal_only_after_confirmed_close
test_herdr_projection_teardown_retains_journal_when_close_unconfirmed
test_open_auto_merge_pr_refuses_teardown
test_squash_merged_branch_deleted_allows
test_squash_merged_pr_allows_when_head_ancestor_of_pr_head
test_no_pr_recorded_discovers_merged_pr_by_branch_allows
test_squash_merged_pr_allows_replayed_unpushed_patch
test_merged_pr_with_later_local_commit_refuses
test_pr_check_does_not_refresh_stale_pr_head
test_pr_check_records_remote_head_when_local_lags
test_content_in_default_fallback_allows
test_content_fallback_refreshes_stale_origin_ref
test_ignored_infrastructure_from_standard_excludes_allows
test_untracked_non_ignored_file_refuses
test_generic_helper_independently_refuses_untracked_non_ignored_file
test_dirty_worktree_refuses
test_provider_refusal_preserves_task_records
test_late_dirty_mutation_after_quiesce_refuses
test_late_unlanded_commit_after_quiesce_refuses
test_endpoint_close_must_be_confirmed_before_return
test_endpoint_query_error_preserves_worktree
test_only_exact_generated_artifacts_are_exempt
test_exact_generated_artifact_is_removed_before_final_validation
test_switched_branch_refuses_without_deleting_acquisition_branch
test_generic_return_removes_exact_worktree_without_force
test_explicit_current_main_capability_gap_preserves_managed_return
test_router_failures_preserve_generic_worktrees
test_generic_postcondition_failure_restores_worktree
test_report_gated_scout_cleanup_remains_supported
test_legacy_branchless_scout_metadata_remains_supported
test_attached_branchless_scout_refuses_on_both_routes
test_generic_helper_independently_refuses_attached_branchless_scout
test_scout_promotion_records_exact_acquisition_branch
test_scout_promotion_refuses_unproven_branch_identity
test_scout_promotion_accepts_registered_symlink_project
test_scout_promotion_refuses_aliased_identity
test_scout_promotion_failure_preserves_metadata
test_generic_return_retries_guarded_branch_cleanup
test_gh_error_and_content_absent_refuses
test_stale_index_lock_cleared_and_teardown_succeeds
test_live_index_lock_is_never_removed_and_teardown_refuses
test_lsof_error_never_clears_index_lock
test_stale_index_lock_cleanup_rechecks_dirty_worktree
test_non_linked_index_lock_path_is_checked_from_worktree
test_index_lock_mtime_read_failure_refuses
test_transient_index_lock_clears_after_first_attempt_and_retry_succeeds
test_persistent_index_lock_exhausts_retries_and_refuses_loudly
test_empty_retry_wait_uses_default_without_aborting
test_fractional_legacy_retry_wait_refuses_without_arithmetic_error
