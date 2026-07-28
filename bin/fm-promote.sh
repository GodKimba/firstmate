#!/usr/bin/env bash
# Promote a scout task to a ship task in place: the crewmate keeps its window,
# worktree, and loaded context. After promoting, send the crewmate its ship
# instructions via fm-send.sh
# (inventory scratch state, reset to a clean default-branch base, carry over only
# intended fix changes on branch fm/<task-id>, implement, then report done
# according to the project's delivery mode).
# Usage: fm-promote.sh <task-id>
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
"$FM_ROOT/bin/fm-guard.sh" || true
ID=$1
META="$STATE/$ID.meta"
BRANCH="fm/$ID"
BRANCH_REF="refs/heads/$BRANCH"
[ -f "$META" ] && [ ! -L "$META" ] \
  || { echo "error: no safe meta for task $ID at $META" >&2; exit 1; }

ORIGINAL=
TMP=
BRANCH_CREATED=0
cleanup_promote() {
  local rc=$? current_branch branch_head
  trap - EXIT
  set +e
  if [ "$BRANCH_CREATED" = 1 ]; then
    current_branch=$(git -C "$WT" symbolic-ref --quiet --short HEAD 2>/dev/null || true)
    branch_head=$(git -C "$PROJ" rev-parse --verify "$BRANCH_REF^{commit}" 2>/dev/null || true)
    if [ "$current_branch" = "$BRANCH" ] && [ "$branch_head" = "$PROMOTION_HEAD" ]; then
      git -C "$WT" checkout --detach -q "$PROMOTION_HEAD" 2>/dev/null \
        || echo "error: could not restore detached scout worktree after failed promotion" >&2
    fi
    current_branch=$(git -C "$WT" symbolic-ref --quiet --short HEAD 2>/dev/null || true)
    branch_head=$(git -C "$PROJ" rev-parse --verify "$BRANCH_REF^{commit}" 2>/dev/null || true)
    if [ "$current_branch" != "$BRANCH" ] && [ "$branch_head" = "$PROMOTION_HEAD" ]; then
      git -C "$PROJ" update-ref -d "$BRANCH_REF" "$PROMOTION_HEAD" 2>/dev/null \
        || echo "error: could not remove incomplete acquisition branch $BRANCH" >&2
    fi
  fi
  [ -z "$TMP" ] || rm -f "$TMP"
  [ -z "$ORIGINAL" ] || rm -f "$ORIGINAL"
  exit "$rc"
}
trap cleanup_promote EXIT
ORIGINAL=$(mktemp "$STATE/.fm-promote-original.XXXXXXXX")
cp "$META" "$ORIGINAL"

if [ "$(grep -c '^kind=' "$ORIGINAL" 2>/dev/null || true)" != 1 ] \
   || ! grep -qx 'kind=scout' "$ORIGINAL"; then
  echo "error: task $ID is not an unambiguous scout task" >&2
  exit 1
fi
ACQUISITION_COUNT=$(grep -c '^acquisition_branch=' "$ORIGINAL" 2>/dev/null || true)
[ "$ACQUISITION_COUNT" -le 1 ] \
  || { echo "error: task $ID has ambiguous acquisition provenance" >&2; exit 1; }
ACQUISITION_BRANCH=$(grep '^acquisition_branch=' "$ORIGINAL" 2>/dev/null \
  | cut -d= -f2- || true)
case "$ACQUISITION_BRANCH" in
  ''|-|"$BRANCH") ;;
  *)
    echo "error: task $ID has unexpected acquisition provenance $ACQUISITION_BRANCH" >&2
    exit 1
    ;;
esac

meta_value_unique() {
  local key=$1 count
  count=$(grep -c "^${key}=" "$ORIGINAL" 2>/dev/null || true)
  [ "$count" = 1 ] || {
    echo "error: task $ID has no unique recorded $key" >&2
    return 1
  }
  grep "^${key}=" "$ORIGINAL" | cut -d= -f2-
}

canonical_dir() {
  [ -d "$1" ] || return 1
  (cd "$1" && pwd -P)
}

canonical_git_common_dir() {
  local dir=$1 common
  common=$(git -C "$dir" rev-parse --path-format=absolute --git-common-dir 2>/dev/null) \
    || return 1
  canonical_dir "$common"
}

WT=$(meta_value_unique worktree) || exit 1
PROJ=$(meta_value_unique project) || exit 1
WT_REAL=$(canonical_dir "$WT") \
  || { echo "error: recorded scout worktree is not an existing directory: $WT" >&2; exit 1; }
PROJ_REAL=$(canonical_dir "$PROJ") \
  || { echo "error: recorded scout project is not an existing directory: $PROJ" >&2; exit 1; }
[ "$WT" = "$WT_REAL" ] && [ "$PROJ" = "$PROJ_REAL" ] && [ "$WT" != "$PROJ" ] \
  || { echo "error: recorded scout project/worktree identity is not canonical" >&2; exit 1; }

WT_TOP=$(git -C "$WT" rev-parse --show-toplevel 2>/dev/null) \
  || { echo "error: recorded scout worktree is not inspectable" >&2; exit 1; }
PROJ_TOP=$(git -C "$PROJ" rev-parse --show-toplevel 2>/dev/null) \
  || { echo "error: recorded scout project is not inspectable" >&2; exit 1; }
WT_TOP=$(canonical_dir "$WT_TOP") \
  || { echo "error: recorded scout worktree root is unreadable" >&2; exit 1; }
PROJ_TOP=$(canonical_dir "$PROJ_TOP") \
  || { echo "error: recorded scout project root is unreadable" >&2; exit 1; }
[ "$WT_TOP" = "$WT" ] && [ "$PROJ_TOP" = "$PROJ" ] \
  || { echo "error: recorded scout project/worktree is not at its Git root" >&2; exit 1; }

WT_COMMON=$(canonical_git_common_dir "$WT") \
  || { echo "error: cannot resolve recorded scout worktree ownership" >&2; exit 1; }
PROJ_COMMON=$(canonical_git_common_dir "$PROJ") \
  || { echo "error: cannot resolve recorded scout project ownership" >&2; exit 1; }
[ "$WT_COMMON" = "$PROJ_COMMON" ] \
  || { echo "error: recorded scout worktree does not belong to its project" >&2; exit 1; }
WORKTREES=$(git -C "$PROJ" -c core.quotePath=false worktree list --porcelain 2>/dev/null) \
  || { echo "error: cannot inspect recorded project worktrees" >&2; exit 1; }
[ "$(printf '%s\n' "$WORKTREES" | grep -Fxc "worktree $WT" || true)" = 1 ] \
  || { echo "error: recorded scout worktree is not uniquely registered to its project" >&2; exit 1; }

if CURRENT_BRANCH=$(git -C "$WT" symbolic-ref --quiet --short HEAD 2>/dev/null); then
  echo "error: recorded scout worktree is attached to branch $CURRENT_BRANCH" >&2
  exit 1
else
  STATUS=$?
fi
[ "$STATUS" = 1 ] \
  || { echo "error: cannot prove recorded scout worktree is detached" >&2; exit 1; }
PROMOTION_HEAD=$(git -C "$WT" rev-parse --verify "HEAD^{commit}" 2>/dev/null) \
  || { echo "error: cannot resolve recorded scout worktree HEAD" >&2; exit 1; }

if git -C "$PROJ" show-ref --verify --quiet "$BRANCH_REF"; then
  echo "error: acquisition branch $BRANCH already exists; refusing promotion" >&2
  exit 1
else
  STATUS=$?
fi
[ "$STATUS" = 1 ] \
  || { echo "error: cannot prove acquisition branch $BRANCH is absent" >&2; exit 1; }

TMP=$(mktemp "$STATE/.fm-promote.XXXXXXXX")
awk '!/^kind=/ && !/^acquisition_branch=/' "$ORIGINAL" > "$TMP"
printf 'kind=ship\nacquisition_branch=%s\n' "$BRANCH" >> "$TMP"

if [ ! -f "$META" ] || [ -L "$META" ] || ! cmp -s "$ORIGINAL" "$META"; then
  echo "error: task $ID metadata changed during promotion" >&2
  exit 1
fi
git -C "$WT" checkout -q -b "$BRANCH" "$PROMOTION_HEAD"
BRANCH_CREATED=1
[ "$(git -C "$WT" symbolic-ref --quiet --short HEAD 2>/dev/null || true)" = "$BRANCH" ] \
  && [ "$(git -C "$PROJ" rev-parse --verify "$BRANCH_REF^{commit}" 2>/dev/null || true)" = "$PROMOTION_HEAD" ] \
  || { echo "error: acquisition branch $BRANCH was not created at the proven scout HEAD" >&2; exit 1; }
if [ ! -f "$META" ] || [ -L "$META" ] || ! cmp -s "$ORIGINAL" "$META"; then
  echo "error: task $ID metadata changed during branch acquisition" >&2
  exit 1
fi
mv "$TMP" "$META"
TMP=
BRANCH_CREATED=0

HOME_Q=$(printf '%q' "$FM_HOME")
echo "promoted $ID to ship (teardown protection restored)"
echo "next: FM_HOME=$HOME_Q bin/fm-send.sh fm-$ID '<ship instructions: review scratch state with git status and git log; reset the prepared fm/$ID branch to a clean default-branch base; carry over only intended fix changes; implement; report done>'"
