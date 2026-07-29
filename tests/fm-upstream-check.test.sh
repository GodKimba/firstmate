#!/usr/bin/env bash
# Behavior tests for fm-upstream-check.sh, the read-only detection half of
# /syncfirstmate.
#
# The guarantees pinned here are the ones the workflow's safety rests on:
#   - the run is read-only: HEAD, the index, the working tree, and every local
#     branch are identical before and after, including on the conflict path
#   - a missing upstream remote is refused with the exact commands to fix it,
#     never added silently
#   - an already-integrated upstream (ancestry preserved) reports in-sync and
#     exits 0 without proposing anything
#   - conflicts are predicted and named without a trial merge, exit 1
#   - a clean divergence reports no conflicts, exit 0
#   - the per-commit review summary accounts for every upstream-only commit and
#     flags file-level collisions with fork-only work
#   - the landing instruction naming the true merge commit is always present
#     when work is outstanding, because squash-landing silently breaks the
#     convergence invariant this whole workflow depends on
#
# Every case runs against synthetic local fixtures. This suite never touches the
# real origin or upstream remotes and never reaches the network.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

fm_git_identity fmtest fmtest@example.invalid

CHECK="$ROOT/bin/fm-upstream-check.sh"
TMP_ROOT=$(fm_test_tmproot fm-upstream-check-tests)
# fm_test_tmproot registers its cleanup trap inside a command substitution, so
# the directory it just made is removed when that subshell exits. Suites that
# only ever `mkdir -p` deeper paths never notice; this one writes directly into
# the root, so recreate it before use.
mkdir -p "$TMP_ROOT"
# Physical form of the same directory. On macOS the temp root reaches us through
# /var -> /private/var, and git always reports the resolved path, so the guard
# below has to compare like with like.
TMP_ROOT_PHYS=$(cd "$TMP_ROOT" && pwd -P)
CASE_N=0

# --- fixtures ---------------------------------------------------------------

commit_file() {
  local dir=$1 file=$2 content=$3 msg=$4
  mkdir -p "$(dirname "$dir/$file")"
  printf '%s\n' "$content" > "$dir/$file"
  git -C "$dir" add "$file"
  git -C "$dir" commit -qm "$msg"
}

# new_case: build a fork repo with an "origin" and "upstream" remote, both bare
# and local. Layout mirrors the real topology: upstream is the parent project,
# origin is the fork, and the fork's checkout tracks origin/main.
#
# Sets FORK and UPSTREAM_WORK in the CALLER's shell rather than echoing a path.
# It must not be called as `f=$(new_case)`: that runs it in a subshell, where the
# case counter never increments, every case reuses one directory, and the clones
# fail. A `git -C` against a path that failed to become a repo walks up to the
# enclosing repository - which is firstmate's own checkout when this suite runs
# from the repo - so a fixture bug of that shape commits to the repo under test.
# assert_fixture_repo below makes that failure loud instead.
new_case() {
  CASE_N=$((CASE_N + 1))
  local base="$TMP_ROOT/case-$CASE_N"
  local up_src="$base/upstream-src" up_bare="$base/upstream.git"
  local origin_bare="$base/origin.git"

  FORK="$base/fork"
  UPSTREAM_WORK="$base/upstream-work"

  mkdir -p "$base"

  # Shared history both sides descend from.
  fm_git_init_commit "$up_src"
  git -C "$up_src" branch -M main >/dev/null 2>&1 || true
  commit_file "$up_src" shared.txt base "shared base"

  git clone --quiet --bare "$up_src" "$up_bare" || fail "fixture: bare upstream clone failed"
  git clone --quiet --bare "$up_src" "$origin_bare" || fail "fixture: bare origin clone failed"

  git clone --quiet "$origin_bare" "$FORK" || fail "fixture: fork clone failed"
  git -C "$FORK" remote add upstream "$up_bare"
  git -C "$FORK" config user.name 'Firstmate Tests'
  git -C "$FORK" config user.email 'tests@example.invalid'

  # A working checkout for advancing upstream independently of the fork.
  git clone --quiet "$up_bare" "$UPSTREAM_WORK" || fail "fixture: upstream-work clone failed"
  git -C "$UPSTREAM_WORK" config user.name 'Firstmate Tests'
  git -C "$UPSTREAM_WORK" config user.email 'tests@example.invalid'

  assert_fixture_repo "$FORK"
  assert_fixture_repo "$UPSTREAM_WORK"
}

# assert_fixture_repo <dir>: <dir> must be its own git repo inside TMP_ROOT.
# Guards the failure mode described above: if the fixture is not a repo, every
# later `git -C "$dir"` silently targets whatever repository encloses it.
assert_fixture_repo() {
  local dir=$1 top
  top=$(git -C "$dir" rev-parse --show-toplevel 2>/dev/null) \
    || fail "fixture is not a git repo: $dir"
  case "$top" in
    "$TMP_ROOT"/* | "$TMP_ROOT_PHYS"/*) : ;;
    *) fail "fixture repo escaped the temp root: $dir resolved to $top" ;;
  esac
}

push_upstream() {
  git -C "$1" push --quiet origin main
}

push_fork() {
  git -C "$1" push --quiet origin main
}

# run_check <fork> [args...]: run the checker, capturing both streams and the
# exit code. Echoes output; sets RC.
#
# Callers use it as `out=$(run_check ...)`, which runs the function in a
# subshell, so RC cannot be assigned directly - it is routed through a file the
# parent shell reads back.
RC_FILE="$TMP_ROOT/.rc"
run_check() {
  local fork=$1 rc=0
  shift
  FM_ROOT_OVERRIDE="$fork" "$CHECK" "$@" 2>&1 || rc=$?
  printf '%s' "$rc" > "$RC_FILE"
}

# check_rc: exit code of the most recent run_check.
check_rc() {
  cat "$RC_FILE"
}

# snapshot_repo <dir>: everything the checker must not disturb.
snapshot_repo() {
  local dir=$1
  printf 'head=%s\n' "$(git -C "$dir" rev-parse HEAD)"
  printf 'branch=%s\n' "$(git -C "$dir" symbolic-ref -q HEAD || echo detached)"
  printf 'tree=%s\n' "$(git -C "$dir" rev-parse 'HEAD^{tree}')"
  printf 'status=%s\n' "$(git -C "$dir" status --porcelain=v1 -uall)"
  printf 'branches=%s\n' "$(git -C "$dir" for-each-ref --format='%(refname) %(objectname)' refs/heads)"
  printf 'stash=%s\n' "$(git -C "$dir" stash list)"
}

# --- case: missing upstream remote is refused with guidance -----------------

new_case
fork="$FORK"
git -C "$fork" remote remove upstream
out=$(run_check "$fork")
expect_code 2 "$(check_rc)" "missing upstream remote must refuse"
assert_contains "$out" "no 'upstream' remote is configured" "refusal names the missing remote"
assert_contains "$out" "remote add upstream" "refusal gives the add command"
assert_contains "$out" "set-url --push upstream DISABLED" "refusal gives the push-disable command"
[ -z "$(git -C "$fork" remote get-url upstream 2>/dev/null)" ] \
  || fail "refusal must not add the remote itself"
pass "missing upstream remote refuses with the exact fix commands and adds nothing"

# --- case: already-integrated upstream reports in-sync ----------------------
#
# Ancestry preserved: the fork merged upstream with a real merge commit. This is
# the state a correctly-landed sync PR leaves behind, and the state a squashed
# one never reaches.

new_case
fork="$FORK"
up="$UPSTREAM_WORK"
commit_file "$up" upstream-feature.txt one "upstream: add feature"
push_upstream "$up"
commit_file "$fork" fork-work.txt one "fork: local work"
git -C "$fork" fetch --quiet upstream
git -C "$fork" merge --quiet --no-ff -m "merge upstream" upstream/main
push_fork "$fork"

out=$(run_check "$fork")
expect_code 0 "$(check_rc)" "already-integrated upstream must exit 0"
assert_contains "$out" "in-sync" "in-sync state is reported"
assert_contains "$out" "nothing to prepare" "in-sync state proposes no work"
assert_not_contains "$out" "== upstream-only commits ==" "in-sync state lists no commits"
pass "an ancestry-preserving merge reports in-sync and proposes nothing"

# --- case: squashed integration still reports outstanding -------------------
#
# The convergence invariant, stated as a test. Same file content as the case
# above, but landed without a merge commit: the checker must still report the
# upstream commit as outstanding, which is exactly why the skill's landing step
# is non-optional.

new_case
fork="$FORK"
up="$UPSTREAM_WORK"
commit_file "$up" upstream-feature.txt one "upstream: add feature"
push_upstream "$up"
git -C "$fork" fetch --quiet upstream
git -C "$fork" merge --quiet --squash upstream/main >/dev/null
git -C "$fork" commit -qm "squashed upstream integration"
push_fork "$fork"

out=$(run_check "$fork")
expect_code 0 "$(check_rc)" "squashed integration with no conflicts still exits 0"
assert_contains "$out" "outstanding" "squashed integration is still outstanding"
assert_contains "$out" "-- --merge" "landing instruction names the true merge form"
assert_contains "$out" "re-propose" "output explains why squashing repeats forever"
pass "a squashed integration still reports outstanding and explains the merge-commit requirement"

# --- case: clean divergence, no conflicts predicted -------------------------

new_case
fork="$FORK"
up="$UPSTREAM_WORK"
commit_file "$up" upstream-only.txt alpha "upstream: independent change"
push_upstream "$up"
commit_file "$fork" fork-only.txt beta "fork: independent change"
push_fork "$fork"

before=$(snapshot_repo "$fork")
out=$(run_check "$fork")
expect_code 0 "$(check_rc)" "clean divergence must exit 0"
assert_contains "$out" "clean: no conflicts predicted" "clean preview is reported"
assert_contains "$out" "upstream-only-commits  1" "divergence counts upstream work"
assert_contains "$out" "fork-only-commits      1" "divergence counts fork work"
assert_contains "$out" "no overlap with fork-only work" "non-colliding commit is marked"
assert_contains "$out" "review     accept" "non-colliding commit recommends accept"
after=$(snapshot_repo "$fork")
[ "$before" = "$after" ] || fail "clean run must not disturb the repo"$'\n'"--- before ---"$'\n'"$before"$'\n'"--- after ---"$'\n'"$after"
pass "a clean divergence predicts no conflicts and leaves the repo untouched"

# --- case: conflicts predicted without a trial merge ------------------------
#
# The core read-only guarantee. Both sides edit the same line, so a real merge
# would leave conflict markers in the working tree; merge-tree must find the
# same collision with nothing on disk changed.

new_case
fork="$FORK"
up="$UPSTREAM_WORK"
commit_file "$up" shared.txt "upstream version" "upstream: rewrite shared"
commit_file "$up" upstream-extra.txt x "upstream: unrelated addition"
push_upstream "$up"
commit_file "$fork" shared.txt "fork version" "fork: rewrite shared"
push_fork "$fork"

before=$(snapshot_repo "$fork")
out=$(run_check "$fork")
expect_code 1 "$(check_rc)" "predicted conflicts must exit 1"
assert_contains "$out" "shared.txt" "conflicted file is named"
assert_contains "$out" "conflict and need a human resolution" "conflict result is reported"
assert_contains "$out" "adapt: resolve by hand" "colliding commit recommends adapt"

after=$(snapshot_repo "$fork")
[ "$before" = "$after" ] || fail "conflict run must not disturb the repo"$'\n'"--- before ---"$'\n'"$before"$'\n'"--- after ---"$'\n'"$after"

# No conflict markers anywhere, and no merge left in progress.
if grep -rq '^<<<<<<< ' "$fork" --exclude-dir=.git 2>/dev/null; then
  fail "conflict preview must not write conflict markers into the working tree"
fi
[ ! -e "$fork/.git/MERGE_HEAD" ] || fail "conflict preview must not leave a merge in progress"
pass "conflicts are predicted and named with no trial merge and no working-tree change"

# --- case: every upstream-only commit appears in the review summary ---------
#
# The captain's accept/adapt/reject decision is only as good as the inventory it
# is made from, so a silently dropped commit is a correctness bug, not cosmetics.

new_case
fork="$FORK"
up="$UPSTREAM_WORK"
commit_file "$up" a.txt 1 "upstream: first change"
commit_file "$up" b.txt 2 "upstream: second change"
commit_file "$up" c.txt 3 "upstream: third change"
push_upstream "$up"
commit_file "$fork" fork.txt f "fork: local work"
push_fork "$fork"

out=$(run_check "$fork")
expect_code 0 "$(check_rc)" "multi-commit clean divergence exits 0"
assert_contains "$out" "upstream: first change" "first upstream commit is summarized"
assert_contains "$out" "upstream: second change" "second upstream commit is summarized"
assert_contains "$out" "upstream: third change" "third upstream commit is summarized"
assert_contains "$out" "reviewing 3 commit(s)" "summary states the review count"
assert_contains "$out" "adds       a.txt" "added files are surfaced for dependency review"
blocks=$(printf '%s\n' "$out" | grep -c '^--- ' || true)
[ "$blocks" -eq 3 ] || fail "expected 3 review blocks, got $blocks"
pass "every upstream-only commit gets its own review block with added files"

# --- case: --no-fetch does not reach the remotes ----------------------------
#
# The fully-offline form. Upstream advances but the fork's remote-tracking ref
# is deliberately stale, so a run that refuses to fetch must report the old
# state rather than silently refreshing it.

new_case
fork="$FORK"
up="$UPSTREAM_WORK"
# Establish the ref an earlier fetch would have left behind, then move upstream
# past it without telling the fork.
git -C "$fork" fetch --quiet upstream
commit_file "$up" late.txt z "upstream: change after last fetch"
push_upstream "$up"

out=$(run_check "$fork" --no-fetch)
expect_code 0 "$(check_rc)" "--no-fetch on an unfetched divergence exits 0"
assert_contains "$out" "in-sync" "--no-fetch reads the stale ref rather than fetching"
assert_not_contains "$out" "change after last fetch" "--no-fetch must not see unfetched work"
pass "--no-fetch reads existing refs and never reaches the remote"

# --- case: usage and help ---------------------------------------------------

new_case
fork="$FORK"
out=$(run_check "$fork" --bogus)
expect_code 2 "$(check_rc)" "unknown option must refuse"
assert_contains "$out" "usage: fm-upstream-check.sh" "unknown option prints usage"

out=$(run_check "$fork" --upstream)
expect_code 2 "$(check_rc)" "--upstream without a value must refuse"
assert_contains "$out" "--upstream needs a remote name" "missing value is named"

out=$(FM_ROOT_OVERRIDE="$fork" "$CHECK" --help 2>&1); printf %s "$?" > "$RC_FILE"
expect_code 0 "$(check_rc)" "--help must exit 0"
assert_contains "$out" "usage: fm-upstream-check.sh" "--help prints usage"
pass "usage errors refuse with the missing requirement and --help exits clean"

# --- case: a nonexistent upstream branch is refused, not guessed ------------

new_case
fork="$FORK"
out=$(run_check "$fork" --branch no-such-branch)
expect_code 2 "$(check_rc)" "nonexistent upstream branch must refuse"
assert_contains "$out" "does not exist" "refusal names the missing branch"
pass "a nonexistent upstream branch refuses instead of falling back"

printf 'ok - fm-upstream-check: all cases passed\n'
