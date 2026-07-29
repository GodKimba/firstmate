#!/usr/bin/env bash
# Read-only upstream divergence report for the /syncfirstmate skill.
#
# Mechanical half of /syncfirstmate check. Reports how this firstmate fork has
# diverged from its upstream, and emits a per-commit review summary the captain
# reads before deciding what to accept, adapt, or reject. The skill owns the
# review conversation and the preparation procedure; this script owns detection.
#
# READ-ONLY apart from constrained `git fetch` calls, which update remote-tracking
# refs only. It never checks out, merges, resets, commits, stashes, cleans,
# creates or deletes a branch, or writes any tracked file. The conflict preview uses
# `git merge-tree --write-tree`, which computes a merge in the object database
# and leaves HEAD, the index, and the working tree untouched. That form needs
# Git >= 2.38; an older Git is refused rather than downgraded to a trial merge,
# because every fallback that predicts conflicts accurately has to mutate
# something.
#
# The report is ordered so the reader sees the shape before the detail:
#   remotes / divergence / merge base / ancestry / conflict preview / per commit.
#
# ANCESTRY is why this exists as a recurring workflow rather than a one-off. A
# synchronization PR must land as a true merge commit so `upstream/<branch>`
# becomes an ancestor of the fork's default branch. Squashing produces the same
# files but a single-parent commit, so every later run of this script still
# reports the same already-integrated commits as outstanding, forever. This
# script only reports that state; bin/fm-pr-merge.sh's ancestry guard plus
# `-- --merge` form preserves it at landing, and the skill carries that as a
# non-optional step.
#
# Per-commit review lines are evidence, not a verdict. Each review line is
# derived only from mechanical file-collision signals. Added files and touched
# surfaces are separate inputs that let a human check cross-commit dependencies.
# A human reads the summary and decides; nothing here selects, filters, or omits
# a commit.
#
# Usage: fm-upstream-check.sh [--upstream <remote>] [--branch <branch>] [--no-fetch] [--help]
#
# Options:
#   --upstream <remote>  upstream remote name (default: upstream)
#   --branch <branch>    upstream branch to compare (default: the upstream
#                        remote's HEAD, falling back to the local default branch)
#   --no-fetch           skip the fetch and read existing remote-tracking refs;
#                        makes the run fully read-only at the cost of freshness
#   --help               print this header
#
# Exit codes:
#   0  report produced; fork is in sync or a clean merge is predicted
#   1  report produced; a merge is predicted to conflict (expected, not an error)
#   2  refused: missing remote, Git too old, not a repo, or bad usage
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"

UPSTREAM_REMOTE=upstream
UPSTREAM_BRANCH=
DO_FETCH=yes

usage() {
  echo "usage: fm-upstream-check.sh [--upstream <remote>] [--branch <branch>] [--no-fetch] [--help]" >&2
}

die() {
  echo "fm-upstream-check: $1" >&2
  exit 2
}

while [ $# -gt 0 ]; do
  case "$1" in
    --help | -h)
      usage
      exit 0
      ;;
    --upstream)
      [ $# -ge 2 ] || die "--upstream needs a remote name"
      UPSTREAM_REMOTE=$2
      shift 2
      ;;
    --branch)
      [ $# -ge 2 ] || die "--branch needs a branch name"
      UPSTREAM_BRANCH=$2
      shift 2
      ;;
    --no-fetch)
      DO_FETCH=no
      shift
      ;;
    *)
      usage
      exit 2
      ;;
  esac
done

git -C "$FM_ROOT" rev-parse --git-dir >/dev/null 2>&1 \
  || die "not a git repository: $FM_ROOT"

# --- preconditions ----------------------------------------------------------

# merge-tree's --write-tree form is the whole reason this script can predict
# conflicts without touching the working tree. Refuse rather than fall back.
git_version=$(git --version | awk '{print $3}')
git_major=${git_version%%.*}
git_rest=${git_version#*.}
git_minor=${git_rest%%.*}
case "$git_major$git_minor" in
  *[!0-9]*) die "cannot parse git version '$git_version'" ;;
esac
if [ "$git_major" -lt 2 ] || { [ "$git_major" -eq 2 ] && [ "$git_minor" -lt 38 ]; }; then
  echo "fm-upstream-check: git $git_version is too old for a non-mutating conflict preview" >&2
  echo "  'git merge-tree --write-tree' needs git >= 2.38; this run would have to" >&2
  echo "  mutate the working tree to predict conflicts, so it is refused instead." >&2
  echo "  Upgrade git, then re-run." >&2
  exit 2
fi

if ! git -C "$FM_ROOT" remote get-url "$UPSTREAM_REMOTE" >/dev/null 2>&1; then
  echo "fm-upstream-check: no '$UPSTREAM_REMOTE' remote is configured" >&2
  echo "  Add it read-only, then re-run:" >&2
  echo "    git -C $FM_ROOT remote add $UPSTREAM_REMOTE <upstream-url>" >&2
  echo "    git -C $FM_ROOT remote set-url --push $UPSTREAM_REMOTE DISABLED" >&2
  echo "  The second command blocks pushes to upstream; this workflow never writes there." >&2
  exit 2
fi

origin_branch=$(git -C "$FM_ROOT" symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null || true)
origin_branch=${origin_branch#origin/}
[ -n "$origin_branch" ] || origin_branch=main
ORIGIN_REF="origin/$origin_branch"

# --- fetch (remote-tracking refs only) --------------------------------------

if [ "$DO_FETCH" = yes ]; then
  git -C "$FM_ROOT" fetch --quiet --prune --no-tags --no-prune-tags \
    --no-write-fetch-head --no-recurse-submodules --refmap= "$UPSTREAM_REMOTE" \
    "+refs/heads/*:refs/remotes/$UPSTREAM_REMOTE/*" >/dev/null 2>&1 \
    || die "fetch from '$UPSTREAM_REMOTE' failed"
  git -C "$FM_ROOT" fetch --quiet --prune --no-tags --no-prune-tags \
    --no-write-fetch-head --no-recurse-submodules --refmap= origin \
    "+refs/heads/*:refs/remotes/origin/*" >/dev/null 2>&1 \
    || die "fetch from 'origin' failed"
fi

if [ -z "$UPSTREAM_BRANCH" ]; then
  UPSTREAM_BRANCH=$(git -C "$FM_ROOT" symbolic-ref --quiet --short \
    "refs/remotes/$UPSTREAM_REMOTE/HEAD" 2>/dev/null || true)
  UPSTREAM_BRANCH=${UPSTREAM_BRANCH#"$UPSTREAM_REMOTE"/}
  [ -n "$UPSTREAM_BRANCH" ] || UPSTREAM_BRANCH=$origin_branch
fi
UPSTREAM_REF="$UPSTREAM_REMOTE/$UPSTREAM_BRANCH"

git -C "$FM_ROOT" rev-parse --verify --quiet "$UPSTREAM_REF^{commit}" >/dev/null \
  || die "'$UPSTREAM_REF' does not exist (try --branch, or fetch first)"
git -C "$FM_ROOT" rev-parse --verify --quiet "$ORIGIN_REF^{commit}" >/dev/null \
  || die "'$ORIGIN_REF' does not exist"

upstream_tip=$(git -C "$FM_ROOT" rev-parse "$UPSTREAM_REF")
origin_tip=$(git -C "$FM_ROOT" rev-parse "$ORIGIN_REF")

# --- divergence -------------------------------------------------------------

echo "== remotes =="
printf 'origin        %s\n' "$ORIGIN_REF"
printf 'upstream      %s\n' "$UPSTREAM_REF"
printf 'upstream-tip  %s\n' "$upstream_tip"
printf 'origin-tip    %s\n' "$origin_tip"
echo

counts=$(git -C "$FM_ROOT" rev-list --left-right --count "$upstream_tip...$origin_tip")
upstream_only=$(printf '%s\n' "$counts" | awk '{print $1}')
fork_only=$(printf '%s\n' "$counts" | awk '{print $2}')
if ! merge_base=$(git -C "$FM_ROOT" merge-base "$origin_tip" "$upstream_tip"); then
  echo "fm-upstream-check: '$ORIGIN_REF' and '$UPSTREAM_REF' have no common ancestor" >&2
  echo "  Refusing because the configured remotes do not describe related histories." >&2
  echo "  Verify the upstream remote and branch, then re-run." >&2
  exit 2
fi

echo "== divergence =="
printf 'upstream-only-commits  %s\n' "$upstream_only"
printf 'fork-only-commits      %s\n' "$fork_only"
printf 'merge-base             %s  %s\n' \
  "$(git -C "$FM_ROOT" rev-parse --short "$merge_base")" \
  "$(git -C "$FM_ROOT" log -1 --format=%s "$merge_base")"
echo

# --- ancestry ---------------------------------------------------------------
#
# The convergence invariant. When upstream is already an ancestor, prior
# synchronizations preserved ancestry and there is nothing outstanding. A
# non-zero upstream-only count combined with a prior sync that was squashed
# looks identical to a genuinely new backlog, which is why the landing method
# is called out here and not only in the skill.

echo "== ancestry =="
if git -C "$FM_ROOT" merge-base --is-ancestor "$upstream_tip" "$origin_tip"; then
  echo "status  in-sync: the recorded upstream tip is an ancestor of the recorded origin tip"
  echo "action  nothing to prepare"
  echo
  echo "== summary =="
  echo "result  in-sync"
  exit 0
fi
echo "status  outstanding: $upstream_only upstream commit(s) are not in the recorded origin tip"
echo "action  a true merge commit is required at landing so this count reaches 0"
printf 'landing bin/fm-pr-merge.sh <task-id> <pr-url> --require-ancestor %s -- --merge\n' \
  "$upstream_tip"
echo "warning squashing this PR keeps the files but drops upstream ancestry,"
echo "warning so every later check would re-propose these same commits"
echo

# --- conflict preview (non-mutating) ----------------------------------------

echo "== conflict preview =="
conflict_rc=0
preview=$(git -C "$FM_ROOT" merge-tree --write-tree --name-only \
  "$origin_tip" "$upstream_tip" 2>/dev/null) || conflict_rc=$?

conflicted_files=
if [ "$conflict_rc" -eq 0 ]; then
  echo "result  clean: no conflicts predicted"
elif [ "$conflict_rc" -eq 1 ]; then
  # --name-only output is: the merged tree oid on line 1, then one conflicted
  # path per line, then a blank line, then human-readable merge messages. Only
  # the paths between line 1 and the blank line are the machine-readable set.
  conflicted_files=$(printf '%s\n' "$preview" | awk 'NR > 1 { if ($0 == "") exit; print }')
  n=$(printf '%s\n' "$conflicted_files" | grep -c . || true)
  printf 'result  %s file(s) conflict and need a human resolution\n' "$n"
  printf '%s\n' "$conflicted_files" | sed 's/^/  /'
else
  echo "fm-upstream-check: conflict preview failed" >&2
  git -C "$FM_ROOT" merge-tree --write-tree --name-only \
    "$origin_tip" "$upstream_tip" >/dev/null || true
  exit 2
fi
echo

# --- per-commit review summary ----------------------------------------------
#
# One block per upstream-only commit, oldest first, so the captain can accept,
# adapt, or reject with the collision evidence in front of them.

fork_files=$(git -C "$FM_ROOT" diff --name-only "$merge_base" "$origin_tip" | sort -u)

echo "== upstream-only commits =="
printf 'reviewing %s commit(s), oldest first\n\n' "$upstream_only"

git -C "$FM_ROOT" rev-list --reverse "$upstream_tip" "^$origin_tip" | while IFS= read -r sha; do
  short=$(git -C "$FM_ROOT" rev-parse --short "$sha")
  subject=$(git -C "$FM_ROOT" log -1 --format=%s "$sha")
  files=$(git -C "$FM_ROOT" show --pretty=format: --name-only "$sha" | grep . | sort -u || true)
  stat=$(git -C "$FM_ROOT" show --shortstat --pretty=format: "$sha" | grep . | sed 's/^ *//' || true)

  overlap=$(printf '%s\n' "$files" | comm -12 - <(printf '%s\n' "$fork_files") || true)
  overlap_n=$(printf '%s\n' "$overlap" | grep -c . || true)

  in_conflict=
  if [ -n "$conflicted_files" ]; then
    in_conflict=$(printf '%s\n' "$files" | comm -12 - <(printf '%s\n' "$conflicted_files" | sort -u) || true)
  fi
  conflict_n=$(printf '%s\n' "$in_conflict" | grep -c . || true)

  # Added files are surfaced so a human can check whether later upstream commits
  # depend on them; the script does not infer or enforce that relationship.
  added=$(git -C "$FM_ROOT" show --pretty=format: --name-status --diff-filter=A "$sha" \
    | awk 'NF {print $2}' | sort -u || true)

  printf -- '--- %s  %s\n' "$short" "$subject"
  printf '    changes    %s\n' "${stat:-(no file changes)}"
  printf '    surfaces   %s\n' "$(printf '%s\n' "$files" | head -6 | tr '\n' ' ' | sed 's/ *$//')"
  if [ "$(printf '%s\n' "$files" | grep -c .)" -gt 6 ]; then
    printf '               (+%s more)\n' "$(( $(printf '%s\n' "$files" | grep -c .) - 6 ))"
  fi
  [ -n "$added" ] && printf '    adds       %s\n' "$(printf '%s\n' "$added" | tr '\n' ' ' | sed 's/ *$//')"

  if [ "$conflict_n" -gt 0 ]; then
    printf '    risk       conflicts with fork work in: %s\n' \
      "$(printf '%s\n' "$in_conflict" | tr '\n' ' ' | sed 's/ *$//')"
    printf '    review     adapt: resolve by hand, then keep or reverse deliberately\n'
  elif [ "$overlap_n" -gt 0 ]; then
    printf '    risk       touches %s file(s) the fork also changed, merges clean\n' "$overlap_n"
    printf '               overlapping paths: %s\n' \
      "$(printf '%s\n' "$overlap" | tr '\n' ' ' | sed 's/ *$//')"
    printf '    review     accept, but re-read the merged result: a clean merge can still\n'
    printf '               leave two independent solutions to the same problem side by side\n'
  else
    printf '    risk       no overlap with fork-only work\n'
    printf '    review     accept\n'
  fi
  echo
done

echo "== summary =="
printf 'result           outstanding\n'
printf 'upstream-only    %s\n' "$upstream_only"
printf 'fork-only        %s\n' "$fork_only"
if [ -n "$conflicted_files" ]; then
  printf 'conflicts        %s file(s)\n' "$(printf '%s\n' "$conflicted_files" | grep -c . || true)"
else
  printf 'conflicts        none predicted\n'
fi
printf 'recorded-upstream-tip %s\n' "$upstream_tip"
printf 'recorded-origin-tip   %s\n' "$origin_tip"
echo 'next             review the commits above, decide accept/adapt/reject, then /syncfirstmate prepare'

[ -z "$conflicted_files" ] || exit 1
exit 0
