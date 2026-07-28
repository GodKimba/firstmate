#!/usr/bin/env bash
# Promote a scout task to a ship task in place: the crewmate keeps its window,
# worktree, and loaded context. After promoting, send the crewmate its ship
# instructions via fm-send.sh
# (inventory scratch state, reset to a clean default-branch base, carry over only
# intended fix changes, create branch fm/<task-id>, implement, then report done
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
[ -f "$META" ] && [ ! -L "$META" ] \
  || { echo "error: no safe meta for task $ID at $META" >&2; exit 1; }
[ "$(grep -c '^kind=' "$META" 2>/dev/null || true)" = 1 ] \
  && grep -qx 'kind=scout' "$META" \
  || { echo "error: task $ID is not an unambiguous scout task" >&2; exit 1; }
ACQUISITION_COUNT=$(grep -c '^acquisition_branch=' "$META" 2>/dev/null || true)
[ "$ACQUISITION_COUNT" -le 1 ] \
  || { echo "error: task $ID has ambiguous acquisition provenance" >&2; exit 1; }
ACQUISITION_BRANCH=$(grep '^acquisition_branch=' "$META" 2>/dev/null \
  | cut -d= -f2- || true)
case "$ACQUISITION_BRANCH" in
  ''|-|"$BRANCH") ;;
  *)
    echo "error: task $ID has unexpected acquisition provenance $ACQUISITION_BRANCH" >&2
    exit 1
    ;;
esac

TMP=$(mktemp "$STATE/.fm-promote.XXXXXXXX")
cleanup_promote_tmp() {
  [ -z "${TMP:-}" ] || rm -f "$TMP"
}
trap cleanup_promote_tmp EXIT
awk '!/^kind=/ && !/^acquisition_branch=/' "$META" > "$TMP"
printf 'kind=ship\nacquisition_branch=%s\n' "$BRANCH" >> "$TMP"
mv "$TMP" "$META"
TMP=

HOME_Q=$(printf '%q' "$FM_HOME")
echo "promoted $ID to ship (teardown protection restored)"
echo "next: FM_HOME=$HOME_Q bin/fm-send.sh fm-$ID '<ship instructions: review scratch state with git status and git log; reset to a clean default-branch base; carry over only intended fix changes; create branch fm/$ID; implement; report done>'"
