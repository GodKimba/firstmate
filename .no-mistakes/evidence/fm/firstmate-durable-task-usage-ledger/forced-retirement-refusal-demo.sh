#!/usr/bin/env bash
# Companion to forced-retirement-ledger-demo.sh: proves the append sits PAST
# every refusal, so a child whose cleanup is refused leaves no row at all.
#
# Same scenario, one difference: the ship child's worktree is a plain directory
# that is not a registered git worktree of the project, so the sweep refuses
# that child before it can retire anything.
set -u
ROOT_REPO=${1:?usage: $0 <firstmate-repo-root>}
ROOT_REPO=$(cd "$ROOT_REPO" && pwd)
HELPERS=$(mktemp -d)/ledger-helpers.sh
sed -e '/^test_ledger_opens_with_an_explicit_first_observed_record$/,$d' \
  -e "s#\$(dirname \"\${BASH_SOURCE\[0\]}\")/lib.sh#$ROOT_REPO/tests/lib.sh#" \
  "$ROOT_REPO/tests/fm-usage-ledger.test.sh" > "$HELPERS"
# shellcheck disable=SC1090
. "$HELPERS"

rule() { printf '\n=== %s ===\n' "$1"; }

make_lifecycle_case refuse-demo
id="refuse-demo-x1"
home_path="$TMP_ROOT/refuse-demo/secondmate-home"
ctl="$home_path/control-state"
mkdir -p "$home_path/state" "$home_path/data" "$home_path/config" "$home_path/projects" "$ctl"
printf '%s\n' "$id" > "$home_path/.fm-secondmate-home"
touch "$ctl/.last-watcher-beat"
fm_write_meta "$ctl/$id.meta" \
  "window=firstmate:fm-$id" "endpoint_task_id=$id" "worktree=$CASE_WT" \
  "project=$CASE_PROJ" "harness=claude" "kind=secondmate" "mode=secondmate" \
  "yolo=off" "model=opus" "effort=high" "home=$home_path" "spawn_gen=g-mate"
printf '%s\n' 'done: handed back' > "$ctl/$id.status"

# The refusal: a worktree path that is NOT a git worktree of the project.
mkdir -p "$TMP_ROOT/refuse-demo/not-a-worktree"
fm_write_meta "$home_path/state/refused-child.meta" \
  "window=firstmate:fm-refused-child" "endpoint_task_id=refused-child" \
  "worktree=$TMP_ROOT/refuse-demo/not-a-worktree" "project=$CASE_PROJ" \
  "harness=codex" "kind=ship" "mode=no-mistakes" "yolo=off" \
  "model=gpt-5" "effort=low" "spawn_gen=g-refused"
printf '%s\n' 'working: still live' > "$home_path/state/refused-child.status"

rule "RUN: fm-teardown.sh $id --force (child worktree is unsafe to remove)"
FM_ROOT_OVERRIDE="$ROOT_REPO" FM_HOME="$CASE_HOME" \
  FM_STATE_OVERRIDE="$ctl" FM_DATA_OVERRIDE="$CASE_HOME/data" \
  FM_PROJECTS_OVERRIDE="$CASE_HOME/projects" FM_CONFIG_OVERRIDE="$CASE_HOME/config" \
  FM_TEARDOWN_GUARD_DONE=1 PATH="$CASE_FAKEBIN:$PATH" \
  "$ROOT_REPO/bin/fm-teardown.sh" "$id" --force 2>&1 | sed 's/^/  /'
printf '  exit=%s\n' "${PIPESTATUS[0]}"

rule "The refused child is still live: its task record and home survive"
for p in "$home_path" "$home_path/state/refused-child.meta" "$home_path/state/refused-child.status"; do
  if [ -e "$p" ]; then printf '  still present  %s\n' "$p"; else printf '  REMOVED        %s\n' "$p"; fi
done

rule "Surviving parent ledger: no cleanup row for a task that is still live"
if [ -e "$CASE_HOME/data/task-usage.jsonl" ]; then
  FM_ROOT_OVERRIDE="$ROOT_REPO" FM_HOME="$CASE_HOME" \
    FM_STATE_OVERRIDE="$CASE_HOME/state" FM_DATA_OVERRIDE="$CASE_HOME/data" \
    "$ROOT_REPO/bin/fm-usage-ledger.sh" list
else
  printf '  the ledger was never even created\n'
fi
printf '\n  rows mentioning refused-child: %s (expected 0)\n' \
  "$(grep -c 'refused-child' "$CASE_HOME/data/task-usage.jsonl" 2>/dev/null || printf 0)"
