#!/usr/bin/env bash
# Remove one explicitly authorized Firstmate task worktree from a generic
# Treehouse pool without forcing Git worktree removal. The helper independently
# binds canonical project, repository, pool-slot, task-meta, branch/disposition,
# clean-state, and applicable landed-head identities before removal. Clean-state
# excludes standard Git-ignored infrastructure but refuses tracked changes and
# untracked non-ignored paths. The helper updates provider state under its lock
# and reports failed removal or postconditions as non-zero.
# Usage:
#   fm-treehouse-generic-return.sh <project> <worktree> <pool> <branch> <validated-head|-> <landed|discard> <task-meta>
set -eu

die() {
  echo "REFUSED: $*" >&2
  exit 1
}

[ "$#" -eq 7 ] || die "invalid generic Treehouse return request"
[ "${FM_TREEHOUSE_RETURN_AUTHORIZED:-}" = 1 ] \
  || die "generic Treehouse return lacks Firstmate authorization"

PROJECT=$1
WORKTREE=$2
POOL=$3
BRANCH=$4
VALIDATED_HEAD=$5
DISPOSITION=$6
AUTH_META=$7
STATE_FILE="$POOL/treehouse-state.json"
STATE_LOCK="$POOL/treehouse-state.lock"

case "$DISPOSITION" in
  landed|discard) ;;
  *) die "invalid generic Treehouse return disposition" ;;
esac
case "$PROJECT$WORKTREE$POOL$BRANCH$VALIDATED_HEAD$AUTH_META" in
  *$'\n'*) die "generic Treehouse return paths and identities must be single-line values" ;;
esac
BRANCHLESS_SCOUT=0
if [ "$BRANCH" = - ]; then
  [ "$DISPOSITION" = discard ] \
    || die "branchless generic return is limited to disposable scouts"
  BRANCHLESS_SCOUT=1
else
  git check-ref-format --branch "$BRANCH" >/dev/null 2>&1 \
    || die "invalid acquisition branch $BRANCH"
  case "$BRANCH" in
    fm/?*) ;;
    *) die "acquisition branch is not a Firstmate task branch: $BRANCH" ;;
  esac
fi
command -v jq >/dev/null 2>&1 || die "jq is required for generic Treehouse return"
command -v perl >/dev/null 2>&1 || die "perl is required for the Treehouse state lock"

canonical_dir() {
  [ -d "$1" ] || return 1
  ( cd "$1" && pwd -P )
}

canonical_git_common_dir() {
  local dir=$1 common top
  common=$(git -C "$dir" rev-parse --path-format=absolute --git-common-dir 2>/dev/null) || return 1
  case "$common" in
    /*) ;;
    *)
      top=$(git -C "$dir" rev-parse --show-toplevel 2>/dev/null) || return 1
      common="$top/$common"
      ;;
  esac
  canonical_dir "$common"
}

project_real=$(canonical_dir "$PROJECT") || die "project is not an existing directory: $PROJECT"
worktree_real=$(canonical_dir "$WORKTREE") || die "worktree is not an existing directory: $WORKTREE"
pool_real=$(canonical_dir "$POOL") || die "pool is not an existing directory: $POOL"
[ "$PROJECT" = "$project_real" ] || die "project path is not canonical and non-symlinked: $PROJECT"
[ "$WORKTREE" = "$worktree_real" ] || die "worktree path is not canonical and non-symlinked: $WORKTREE"
[ "$POOL" = "$pool_real" ] || die "pool path is not canonical and non-symlinked: $POOL"
[ -f "$AUTH_META" ] && [ ! -L "$AUTH_META" ] \
  || die "Firstmate task authorization record is missing or unsafe"
auth_meta_dir=$(canonical_dir "$(dirname "$AUTH_META")") \
  || die "Firstmate task authorization directory is not canonical"
auth_meta_real="$auth_meta_dir/$(basename "$AUTH_META")"
[ "$AUTH_META" = "$auth_meta_real" ] \
  || die "Firstmate task authorization path is not canonical and non-symlinked"
task_meta_name=$(basename "$AUTH_META")
case "$task_meta_name" in
  ?*.meta) task_id=${task_meta_name%.meta} ;;
  *) die "Firstmate task authorization record has an invalid name" ;;
esac
case "$task_id" in
  ''|*/*|.*) die "Firstmate task authorization record has an invalid task identity" ;;
esac
if [ "$BRANCHLESS_SCOUT" != 1 ]; then
  [ "$task_meta_name" = "${BRANCH#fm/}.meta" ] \
    || die "Firstmate task authorization does not match acquisition branch $BRANCH"
fi

meta_value() {
  local key=$1
  awk -v key="$key" '
    index($0, key "=") == 1 {
      count++
      value = substr($0, length(key) + 2)
    }
    END {
      if (count != 1) exit 1
      print value
    }
  ' "$AUTH_META"
}

meta_project=$(meta_value project) \
  || die "Firstmate task authorization has no unique project"
meta_worktree=$(meta_value worktree) \
  || die "Firstmate task authorization has no unique worktree"
[ "$meta_project" = "$PROJECT" ] \
  || die "Firstmate task authorization project does not match"
[ "$meta_worktree" = "$WORKTREE" ] \
  || die "Firstmate task authorization worktree does not match"
if [ "$BRANCHLESS_SCOUT" = 1 ]; then
  meta_kind=$(meta_value kind) \
    || die "branchless generic return has no unique task kind"
  [ "$meta_kind" = scout ] \
    || die "branchless generic return is limited to a recorded scout"
  meta_branch_count=$(grep -c '^acquisition_branch=' "$AUTH_META" 2>/dev/null || true)
  [ "$meta_branch_count" -le 1 ] \
    || die "branchless generic return has ambiguous acquisition metadata"
  meta_branch=$(grep '^acquisition_branch=' "$AUTH_META" 2>/dev/null \
    | cut -d= -f2- || true)
  case "$meta_branch" in
    ''|-|"fm/$task_id") ;;
    *) die "branchless scout authorization has an unexpected acquisition branch" ;;
  esac
else
  meta_branch=$(meta_value acquisition_branch) \
    || die "Firstmate task authorization has no unique acquisition branch"
  [ "$meta_branch" = "$BRANCH" ] \
    || die "Firstmate task authorization acquisition branch does not match"
fi

slot_dir=$(dirname "$WORKTREE")
slot=$(basename "$slot_dir")
case "$slot" in
  ''|*[!0-9]*) die "worktree is not inside a numbered generic Treehouse pool slot" ;;
esac
[ "$(dirname "$slot_dir")" = "$POOL" ] \
  || die "worktree is outside the authorized generic Treehouse pool"
[ "$(basename "$WORKTREE")" = "$(basename "$PROJECT")" ] \
  || die "worktree repository name does not match its project"

[ -f "$STATE_FILE" ] && [ ! -L "$STATE_FILE" ] \
  || die "generic Treehouse pool state is missing or unsafe"
[ ! -L "$STATE_LOCK" ] || die "generic Treehouse pool lock is unsafe"
exec 9>>"$STATE_LOCK" || die "cannot open generic Treehouse pool lock"
perl -MFcntl=:flock -e 'flock(STDIN, LOCK_EX) or exit 1' <&9 \
  || die "cannot acquire generic Treehouse pool lock"

state_count=$(jq -er --arg path "$WORKTREE" --arg name "$slot" '
  [.worktrees[]? | select(.path == $path)] as $matches
  | select(($matches | length) == 1)
  | [$matches[]?
      | select((.name | tostring) == $name)
      | select((.leased // false) == false)
      | select((.destroying // false) == false)]
    | length
' "$STATE_FILE" 2>/dev/null) || die "generic Treehouse pool state is unreadable"
[ "$state_count" = 1 ] \
  || die "worktree is not the exact available entry in the generic Treehouse pool"

project_top=$(git -C "$PROJECT" rev-parse --show-toplevel 2>/dev/null) \
  || die "project is not a Git repository"
worktree_top=$(git -C "$WORKTREE" rev-parse --show-toplevel 2>/dev/null) \
  || die "worktree is not a Git worktree"
[ "$project_top" = "$PROJECT" ] || die "project path is not its repository root"
[ "$worktree_top" = "$WORKTREE" ] || die "worktree path is not its worktree root"
project_common=$(canonical_git_common_dir "$PROJECT") \
  || die "cannot resolve project repository ownership"
worktree_common=$(canonical_git_common_dir "$WORKTREE") \
  || die "cannot resolve worktree repository ownership"
[ "$project_common" = "$worktree_common" ] \
  || die "worktree does not belong to the recorded project repository"
git -C "$PROJECT" worktree list --porcelain \
  | grep -Fx "worktree $WORKTREE" >/dev/null \
  || die "worktree is not registered to the recorded project"

current_head=$(git -C "$WORKTREE" rev-parse --verify "HEAD^{commit}" 2>/dev/null) \
  || die "cannot resolve worktree HEAD"
current_branch=$(git -C "$WORKTREE" symbolic-ref --quiet --short HEAD 2>/dev/null || true)
branch_head=
if [ "$BRANCHLESS_SCOUT" = 1 ]; then
  [ -z "$current_branch" ] \
    || die "branchless scout worktree is attached to branch $current_branch"
  if git -C "$PROJECT" show-ref --verify --quiet "refs/heads/fm/$task_id"; then
    die "branchless scout unexpectedly owns acquisition branch fm/$task_id"
  fi
else
  branch_head=$(git -C "$PROJECT" rev-parse --verify \
    "refs/heads/$BRANCH^{commit}" 2>/dev/null) \
    || die "acquisition branch $BRANCH is missing"
fi

if [ "$DISPOSITION" = landed ]; then
  [ "$current_branch" = "$BRANCH" ] \
    || die "worktree is not on its exact acquisition branch $BRANCH"
  [ "$VALIDATED_HEAD" = "$current_head" ] && [ "$branch_head" = "$current_head" ] \
    || die "landed-work authorization does not match the acquisition branch tip"
else
  git -C "$WORKTREE" reset --hard HEAD >/dev/null 2>&1 \
    || die "could not reset the authorized disposable worktree"
  git -C "$WORKTREE" clean -fd >/dev/null 2>&1 \
    || die "could not clean the authorized disposable worktree"
fi
git -C "$WORKTREE" clean -fdX >/dev/null 2>&1 \
  || die "could not clean ignored files from the authorized disposable worktree"

tracked=$(git -C "$WORKTREE" status --porcelain --untracked-files=no 2>/dev/null) \
  || die "cannot inspect tracked worktree state"
untracked=$(git -C "$WORKTREE" ls-files --others --exclude-standard 2>/dev/null) \
  || die "cannot inspect untracked worktree state"
[ -z "$tracked" ] && [ -z "$untracked" ] \
  || die "generic Treehouse worktree is not clean"

state_count=$(jq -er --arg path "$WORKTREE" --arg name "$slot" '
  [.worktrees[]? | select(.path == $path)] as $matches
  | select(($matches | length) == 1)
  | [$matches[]?
      | select((.name | tostring) == $name)
      | select((.leased // false) == false)
      | select((.destroying // false) == false)]
    | length
' "$STATE_FILE" 2>/dev/null) || die "generic Treehouse pool state changed or became unreadable"
[ "$state_count" = 1 ] \
  || die "generic Treehouse pool authorization changed before removal"
owner_pid=$(jq -er --arg path "$WORKTREE" '
  [.worktrees[]? | select(.path == $path)][0].owner_pid // 0
  | select(type == "number" and floor == .)
  | tostring
' "$STATE_FILE" 2>/dev/null) \
  || die "generic Treehouse owner reservation is unreadable"
case "$owner_pid" in
  ''|*[!0-9]*) die "generic Treehouse owner reservation is invalid" ;;
  0) ;;
  *)
    if kill -0 "$owner_pid" 2>/dev/null; then
      die "generic Treehouse worktree still has a live provider owner"
    fi
    ;;
esac

STATE_BACKUP=
STATE_MARKED=
STATE_REMOVED=
cleanup_state_temps() {
  [ -z "${STATE_BACKUP:-}" ] || rm -f -- "$STATE_BACKUP"
  [ -z "${STATE_MARKED:-}" ] || rm -f -- "$STATE_MARKED"
  [ -z "${STATE_REMOVED:-}" ] || rm -f -- "$STATE_REMOVED"
}
trap cleanup_state_temps EXIT
STATE_BACKUP=$(mktemp "$POOL/.fm-treehouse-state.backup.XXXXXXXX") \
  || die "cannot prepare generic Treehouse state rollback"
STATE_MARKED=$(mktemp "$POOL/.fm-treehouse-state.marked.XXXXXXXX") \
  || die "cannot prepare generic Treehouse destroy reservation"
STATE_REMOVED=$(mktemp "$POOL/.fm-treehouse-state.removed.XXXXXXXX") \
  || die "cannot prepare generic Treehouse state postcondition"
cp -p "$STATE_FILE" "$STATE_BACKUP" \
  || die "cannot snapshot generic Treehouse pool state"
state_mode=$(stat -f '%Lp' "$STATE_FILE" 2>/dev/null \
  || stat -c '%a' "$STATE_FILE" 2>/dev/null) \
  || die "cannot inspect generic Treehouse pool state mode"
jq --arg path "$WORKTREE" '
  .worktrees |= map(if .path == $path then . + {destroying: true} else . end)
' "$STATE_FILE" >"$STATE_MARKED" \
  || die "cannot reserve generic Treehouse worktree removal"
chmod "$state_mode" "$STATE_MARKED" \
  || die "cannot preserve generic Treehouse pool state mode"
mv -f -- "$STATE_MARKED" "$STATE_FILE" \
  || die "cannot reserve generic Treehouse worktree removal"
STATE_MARKED=

restore_state_backup() {
  [ -n "${STATE_BACKUP:-}" ] && [ -f "$STATE_BACKUP" ] || return 1
  mv -f -- "$STATE_BACKUP" "$STATE_FILE" || return 1
  STATE_BACKUP=
}

restore_removed_worktree() {
  if [ -n "$current_branch" ]; then
    git -C "$PROJECT" worktree add -q "$WORKTREE" "$current_branch" >/dev/null 2>&1
  else
    git -C "$PROJECT" worktree add -q --detach "$WORKTREE" "$current_head" >/dev/null 2>&1
  fi
}

remove_output=
if ! remove_output=$(git -C "$PROJECT" worktree remove -- "$WORKTREE" 2>&1); then
  restore_state_backup \
    || echo "REFUSED: could not roll back the generic Treehouse destroy reservation" >&2
  [ -z "$remove_output" ] || printf '%s\n' "$remove_output" >&2
  die "Git refused the non-forced worktree removal"
fi
if [ -e "$WORKTREE" ] || [ -L "$WORKTREE" ] \
   || git -C "$PROJECT" worktree list --porcelain \
        | grep -Fx "worktree $WORKTREE" >/dev/null; then
  restore_state_backup \
    || echo "REFUSED: could not roll back the generic Treehouse destroy reservation" >&2
  die "generic worktree removal postcondition failed"
fi

jq --arg path "$WORKTREE" \
  '.worktrees |= map(select(.path != $path))' \
  "$STATE_FILE" >"$STATE_REMOVED" \
  || {
    restore_removed_worktree || true
    restore_state_backup || true
    die "generic Treehouse state update failed; restored recovery state when possible"
  }
chmod "$state_mode" "$STATE_REMOVED" \
  || {
    restore_removed_worktree || true
    restore_state_backup || true
    die "generic Treehouse state mode update failed; restored recovery state when possible"
  }
if ! mv -f -- "$STATE_REMOVED" "$STATE_FILE"; then
  restore_removed_worktree || true
  restore_state_backup || true
  die "generic Treehouse state commit failed; restored recovery state when possible"
fi
STATE_REMOVED=
remaining=$(jq -er --arg path "$WORKTREE" \
  '[.worktrees[]? | select(.path == $path)] | length' "$STATE_FILE" 2>/dev/null || printf 'unreadable')
if [ "$remaining" != 0 ]; then
  restore_removed_worktree || true
  restore_state_backup || true
  die "generic Treehouse state postcondition failed; restored recovery state when possible"
fi
rm -f -- "$STATE_BACKUP"
STATE_BACKUP=

printf 'generic worktree removed: %s\n' "$WORKTREE"
