#!/usr/bin/env bash
# Promote a scout task to a ship task in place: the crewmate keeps its window,
# worktree, and loaded context. After promoting, send the crewmate its ship
# instructions via fm-send.sh
# (inventory scratch state, reset to a clean default-branch base, carry over only
# intended fix changes on branch fm/<task-id>, implement, then report done
# according to this task's delivery mode).
# A scout records no delivery posture, so promotion is where this task's delivery
# contract is decided: --mode and --yolo are REQUIRED and written into the meta
# alongside the kind= flip. Firstmate resolves both at promotion time, having just
# read the scout's report (AGENTS.md section 7); data/projects.md holds the
# captain's standing posture as context, and this script never looks it up.
# no-mistakes-prod-only is a registry policy rather than a task mode and is refused.
# Promotion also acquires the ship task's branch here rather than leaving it to the
# worker, because teardown's acquisition provenance (acquisition_branch= in the meta)
# is what lets a returned worktree prove which branch it owned. The recorded project
# and worktree paths are proven by resolving them, not by requiring the stored strings
# to already be physical: a project clone is legitimately registered through a
# symlink. Every Git operation then uses the resolved paths, and the stored strings
# are preserved exactly as recorded.
# Usage: fm-promote.sh <task-id> --mode <no-mistakes|direct-PR|local-only> --yolo <on|off>
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"

MODE=
YOLO=
MODE_SET=0
YOLO_SET=0
POS=()
want_value=
for a in "$@"; do
  if [ -n "$want_value" ]; then
    case "$a" in
      --*) echo "error: --$want_value requires a value" >&2; exit 1 ;;
    esac
    case "$want_value" in
      mode) MODE=$a; MODE_SET=1 ;;
      yolo) YOLO=$a; YOLO_SET=1 ;;
    esac
    want_value=
    continue
  fi
  case "$a" in
    --mode) want_value=mode ;;
    --mode=*) MODE=${a#--mode=}; MODE_SET=1 ;;
    --yolo) want_value=yolo ;;
    --yolo=*) YOLO=${a#--yolo=}; YOLO_SET=1 ;;
    *) POS+=("$a") ;;
  esac
done
[ -z "$want_value" ] || { echo "error: --$want_value requires a value" >&2; exit 1; }
[ "${#POS[@]}" -ge 1 ] || { echo "usage: fm-promote.sh <task-id> --mode <no-mistakes|direct-PR|local-only> --yolo <on|off>" >&2; exit 1; }
[ "$MODE_SET" -eq 1 ] || {
  echo "error: promotion requires --mode <no-mistakes|direct-PR|local-only>; decide it now from the scout's findings and the project's registered posture in data/projects.md" >&2
  exit 1
}
[ "$YOLO_SET" -eq 1 ] || {
  echo "error: promotion requires --yolo <on|off>; it is this task's routine approval authority, not a project lookup" >&2
  exit 1
}
case "$MODE" in
  no-mistakes|direct-PR|local-only) ;;
  no-mistakes-prod-only)
    echo "error: no-mistakes-prod-only is a registry policy, not a task mode; classify this task's surface and resolve it to no-mistakes or direct-PR" >&2
    exit 1 ;;
  *) echo "error: --mode must be one of no-mistakes, direct-PR, local-only (got '$MODE')" >&2; exit 1 ;;
esac
case "$YOLO" in
  on|off) ;;
  *) echo "error: --yolo must be on or off (got '$YOLO')" >&2; exit 1 ;;
esac

"$FM_ROOT/bin/fm-guard.sh" || true
ID=${POS[0]}
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
    current_branch=$(git -C "$WT_REAL" symbolic-ref --quiet --short HEAD 2>/dev/null || true)
    branch_head=$(git -C "$PROJ_REAL" rev-parse --verify "$BRANCH_REF^{commit}" 2>/dev/null || true)
    if [ "$current_branch" = "$BRANCH" ] && [ "$branch_head" = "$PROMOTION_HEAD" ]; then
      git -C "$WT_REAL" checkout --detach -q "$PROMOTION_HEAD" 2>/dev/null \
        || echo "error: could not restore detached scout worktree after failed promotion" >&2
    fi
    current_branch=$(git -C "$WT_REAL" symbolic-ref --quiet --short HEAD 2>/dev/null || true)
    branch_head=$(git -C "$PROJ_REAL" rev-parse --verify "$BRANCH_REF^{commit}" 2>/dev/null || true)
    if [ "$current_branch" != "$BRANCH" ] && [ "$branch_head" = "$PROMOTION_HEAD" ]; then
      git -C "$PROJ_REAL" update-ref -d "$BRANCH_REF" "$PROMOTION_HEAD" 2>/dev/null \
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
  (cd -- "$1" && pwd -P)
}

canonical_git_common_dir() {
  local dir=$1 common
  common=$(git -C "$dir" rev-parse --path-format=absolute --git-common-dir 2>/dev/null) \
    || return 1
  canonical_dir "$common"
}

# Count worktree inventory entries that resolve to <canonical-dir>. Git records a
# physical path when it registers a worktree itself, but a hand-written or aliased
# registration can list a symlinked path for the same directory, so every entry is
# resolved before it is compared. Two entries resolving to one directory stay
# ambiguous and still refuse promotion. An entry whose directory no longer exists
# keeps its recorded string, which cannot equal an existing canonical target.
count_worktree_inventory_matches() {  # <canonical-dir> ; inventory on stdin
  local target=$1 line entry matches=0
  while IFS= read -r line; do
    case "$line" in
      worktree\ *)
        entry=${line#worktree }
        entry=$(canonical_dir "$entry") || entry=${line#worktree }
        if [ "$entry" = "$target" ]; then
          matches=$((matches + 1))
        fi
        ;;
    esac
  done
  printf '%s\n' "$matches"
}

# A project is registered by the path the captain chose, which is legitimately a
# symlink to the Git root (bin/fm-spawn.sh persists that registry path verbatim).
# Identity is therefore proven on the resolved physical paths rather than by
# demanding that the recorded strings already be physical, and every later Git
# operation uses those resolved paths so a symlink re-pointed mid-promotion cannot
# redirect branch creation. The recorded strings themselves are never rewritten.
WT=$(meta_value_unique worktree) || exit 1
PROJ=$(meta_value_unique project) || exit 1
# Both recorded paths must be absolute before anything resolves them: a relative
# string would otherwise resolve against this script's own working directory, and a
# leading dash would reach `cd` as an option instead of a path.
case "$WT" in
  /*) ;;
  *) echo "error: recorded scout worktree path is not absolute: $WT" >&2; exit 1 ;;
esac
case "$PROJ" in
  /*) ;;
  *) echo "error: recorded scout project path is not absolute: $PROJ" >&2; exit 1 ;;
esac
WT_REAL=$(canonical_dir "$WT") \
  || { echo "error: recorded scout worktree is not an existing directory: $WT" >&2; exit 1; }
PROJ_REAL=$(canonical_dir "$PROJ") \
  || { echo "error: recorded scout project is not an existing directory: $PROJ" >&2; exit 1; }
[ "$WT_REAL" != "$PROJ_REAL" ] \
  || { echo "error: recorded scout worktree resolves to its own project: $WT" >&2; exit 1; }

WT_TOP=$(git -C "$WT_REAL" rev-parse --show-toplevel 2>/dev/null) \
  || { echo "error: recorded scout worktree is not inspectable" >&2; exit 1; }
PROJ_TOP=$(git -C "$PROJ_REAL" rev-parse --show-toplevel 2>/dev/null) \
  || { echo "error: recorded scout project is not inspectable" >&2; exit 1; }
WT_TOP=$(canonical_dir "$WT_TOP") \
  || { echo "error: recorded scout worktree root is unreadable" >&2; exit 1; }
PROJ_TOP=$(canonical_dir "$PROJ_TOP") \
  || { echo "error: recorded scout project root is unreadable" >&2; exit 1; }
[ "$WT_TOP" = "$WT_REAL" ] && [ "$PROJ_TOP" = "$PROJ_REAL" ] \
  || { echo "error: recorded scout project/worktree is not at its Git root" >&2; exit 1; }

WT_COMMON=$(canonical_git_common_dir "$WT_REAL") \
  || { echo "error: cannot resolve recorded scout worktree ownership" >&2; exit 1; }
PROJ_COMMON=$(canonical_git_common_dir "$PROJ_REAL") \
  || { echo "error: cannot resolve recorded scout project ownership" >&2; exit 1; }
[ "$WT_COMMON" = "$PROJ_COMMON" ] \
  || { echo "error: recorded scout worktree does not belong to its project" >&2; exit 1; }
WORKTREES=$(git -C "$PROJ_REAL" -c core.quotePath=false worktree list --porcelain 2>/dev/null) \
  || { echo "error: cannot inspect recorded project worktrees" >&2; exit 1; }
WT_REGISTERED=$(count_worktree_inventory_matches "$WT_REAL" <<EOF
$WORKTREES
EOF
)
[ "$WT_REGISTERED" = 1 ] \
  || { echo "error: recorded scout worktree is not uniquely registered to its project" >&2; exit 1; }

if CURRENT_BRANCH=$(git -C "$WT_REAL" symbolic-ref --quiet --short HEAD 2>/dev/null); then
  echo "error: recorded scout worktree is attached to branch $CURRENT_BRANCH" >&2
  exit 1
else
  STATUS=$?
fi
[ "$STATUS" = 1 ] \
  || { echo "error: cannot prove recorded scout worktree is detached" >&2; exit 1; }
PROMOTION_HEAD=$(git -C "$WT_REAL" rev-parse --verify "HEAD^{commit}" 2>/dev/null) \
  || { echo "error: cannot resolve recorded scout worktree HEAD" >&2; exit 1; }

if git -C "$PROJ_REAL" show-ref --verify --quiet "$BRANCH_REF"; then
  echo "error: acquisition branch $BRANCH already exists; refusing promotion" >&2
  exit 1
else
  STATUS=$?
fi
[ "$STATUS" = 1 ] \
  || { echo "error: cannot prove acquisition branch $BRANCH is absent" >&2; exit 1; }

TMP=$(mktemp "$STATE/.fm-promote.XXXXXXXX")
awk '!/^kind=/ && !/^acquisition_branch=/ && !/^mode=/ && !/^yolo=/' "$ORIGINAL" > "$TMP"
printf 'kind=ship\nacquisition_branch=%s\nmode=%s\nyolo=%s\n' "$BRANCH" "$MODE" "$YOLO" >> "$TMP"

if [ ! -f "$META" ] || [ -L "$META" ] || ! cmp -s "$ORIGINAL" "$META"; then
  echo "error: task $ID metadata changed during promotion" >&2
  exit 1
fi
git -C "$WT_REAL" checkout -q -b "$BRANCH" "$PROMOTION_HEAD"
BRANCH_CREATED=1
[ "$(git -C "$WT_REAL" symbolic-ref --quiet --short HEAD 2>/dev/null || true)" = "$BRANCH" ] \
  && [ "$(git -C "$PROJ_REAL" rev-parse --verify "$BRANCH_REF^{commit}" 2>/dev/null || true)" = "$PROMOTION_HEAD" ] \
  || { echo "error: acquisition branch $BRANCH was not created at the proven scout HEAD" >&2; exit 1; }
if [ ! -f "$META" ] || [ -L "$META" ] || ! cmp -s "$ORIGINAL" "$META"; then
  echo "error: task $ID metadata changed during branch acquisition" >&2
  exit 1
fi
mv "$TMP" "$META"
TMP=
BRANCH_CREATED=0

HOME_Q=$(printf '%q' "$FM_HOME")
echo "promoted $ID to ship mode=$MODE yolo=$YOLO (teardown protection restored)"
echo "next: FM_HOME=$HOME_Q bin/fm-send.sh fm-$ID '<ship instructions for mode=$MODE: review scratch state with git status and git log; reset the prepared fm/$ID branch to a clean default-branch base; carry over only intended fix changes; implement; report done>'"
