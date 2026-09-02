#!/usr/bin/env bash
# End-to-end demo of the accepted change: a forced secondmate retirement now
# records every task it discards, at every nesting depth, into the ledger of the
# home that survives the operation.
#
# It drives the REAL bin/fm-teardown.sh and reads the result back through the
# REAL bin/fm-usage-ledger.sh operator surface. The only fakes are the ones the
# repo's own lifecycle tests use for tmux/gh/treehouse.
#
# Usage: forced-retirement-ledger-demo.sh <path-to-firstmate-worktree>
set -u
ROOT_REPO=${1:?usage: $0 <firstmate-repo-root>}
ROOT_REPO=$(cd "$ROOT_REPO" && pwd)

# Reuse the suite's fixture helpers without running its assertions: everything
# above the trailing invocation list is helper definitions.
HELPERS=$(mktemp -d)/ledger-helpers.sh
mkdir -p "$(dirname "$HELPERS")"
sed -e '/^test_ledger_opens_with_an_explicit_first_observed_record$/,$d' \
  -e "s#\$(dirname \"\${BASH_SOURCE\[0\]}\")/lib.sh#$ROOT_REPO/tests/lib.sh#" \
  "$ROOT_REPO/tests/fm-usage-ledger.test.sh" > "$HELPERS"
# shellcheck disable=SC1090
. "$HELPERS"

rule() { printf '\n=== %s ===\n' "$1"; }

make_lifecycle_case swept-demo
id="swept-demo-x1"
home_path="$TMP_ROOT/swept-demo/secondmate-home"
ctl="$home_path/control-state"
nested="$home_path/nested-home"
mkdir -p "$home_path/state" "$home_path/data" "$home_path/config" \
  "$home_path/projects" "$ctl" \
  "$nested/state" "$nested/data" "$nested/config" "$nested/projects"
printf '%s\n' "$id" > "$home_path/.fm-secondmate-home"
printf '%s\n' swept-child-sm > "$nested/.fm-secondmate-home"
touch "$ctl/.last-watcher-beat"

fm_write_meta "$ctl/$id.meta" \
  "window=firstmate:fm-$id" "endpoint_task_id=$id" "worktree=$CASE_WT" \
  "project=$CASE_PROJ" "harness=claude" "kind=secondmate" "mode=secondmate" \
  "yolo=off" "model=opus" "effort=high" "home=$home_path" "spawn_gen=g-mate"
printf '%s\n' 'done: handed back' > "$ctl/$id.status"

git -C "$CASE_PROJ" worktree add -q -b fm/swept-child "$TMP_ROOT/swept-demo/child-wt"
fm_write_meta "$home_path/state/swept-child.meta" \
  "window=firstmate:fm-swept-child" "endpoint_task_id=swept-child" \
  "worktree=$TMP_ROOT/swept-demo/child-wt" "project=$CASE_PROJ" \
  "harness=codex" "kind=ship" "mode=no-mistakes" "yolo=off" \
  "model=gpt-5" "effort=low" "spawn_gen=g-child"
printf '%s\n' 'working: mid-flight' 'blocked: waiting, captain notes were sensitive' \
  > "$home_path/state/swept-child.status"

fm_write_meta "$home_path/state/swept-child-sm.meta" \
  "window=firstmate:fm-swept-child-sm" "endpoint_task_id=swept-child-sm" \
  "worktree=$nested" "project=$CASE_PROJ" "harness=pi" "kind=secondmate" \
  "mode=secondmate" "yolo=off" "model=sonnet" "effort=medium" \
  "home=$nested" "spawn_gen=g-child-sm"

git -C "$CASE_PROJ" worktree add -q -b fm/swept-grandchild "$TMP_ROOT/swept-demo/grandchild-wt"
fm_write_meta "$nested/state/swept-grandchild.meta" \
  "window=firstmate:fm-swept-grandchild" "endpoint_task_id=swept-grandchild" \
  "worktree=$TMP_ROOT/swept-demo/grandchild-wt" "project=$CASE_PROJ" \
  "harness=cursor" "kind=scout" "model=composer" "effort=xhigh" \
  "spawn_gen=g-grandchild"
printf '%s\n' 'done: reported' > "$nested/state/swept-grandchild.status"

rule "BEFORE: the mate's home holds live work at two nesting depths"
printf 'retiring mate      %-18s harness=claude  model=opus     effort=high   kind=secondmate\n' "$id"
printf '  child task       %-18s harness=codex   model=gpt-5    effort=low    kind=ship        (blocked)\n' swept-child
printf '  nested mate      %-18s harness=pi      model=sonnet   effort=medium kind=secondmate\n' swept-child-sm
printf '    grandchild     %-18s harness=cursor  model=composer effort=xhigh  kind=scout       (done)\n' swept-grandchild
printf '\neach of those three tasks owns a ledger INSIDE a home this retirement deletes:\n'
printf '  %s\n' "$home_path/data/task-usage.jsonl" "$nested/data/task-usage.jsonl"
printf 'the surviving parent ledger is: %s\n' "$CASE_HOME/data/task-usage.jsonl"

rule "RUN: fm-teardown.sh $id --force"
FM_ROOT_OVERRIDE="$ROOT_REPO" FM_HOME="$CASE_HOME" \
  FM_STATE_OVERRIDE="$ctl" FM_DATA_OVERRIDE="$CASE_HOME/data" \
  FM_PROJECTS_OVERRIDE="$CASE_HOME/projects" FM_CONFIG_OVERRIDE="$CASE_HOME/config" \
  FM_TEARDOWN_GUARD_DONE=1 PATH="$CASE_FAKEBIN:$PATH" \
  "$ROOT_REPO/bin/fm-teardown.sh" "$id" --force 2>&1 | sed 's/^/  /'
teardown_rc=${PIPESTATUS[0]}
printf '  exit=%s\n' "$teardown_rc"

rule "AFTER: every home the sweep walked is gone, with its own ledger"
for p in "$home_path" "$nested" "$home_path/data/task-usage.jsonl" "$nested/data/task-usage.jsonl"; do
  if [ -e "$p" ]; then printf '  STILL PRESENT  %s\n' "$p"; else printf '  removed        %s\n' "$p"; fi
done

rule "OPERATOR READ SURFACE: fm-usage-ledger.sh list (surviving parent home)"
FM_ROOT_OVERRIDE="$ROOT_REPO" FM_HOME="$CASE_HOME" \
  FM_STATE_OVERRIDE="$CASE_HOME/state" FM_DATA_OVERRIDE="$CASE_HOME/data" \
  "$ROOT_REPO/bin/fm-usage-ledger.sh" list

rule "The question the audit could not answer, answered per discarded task"
FM_ROOT_OVERRIDE="$ROOT_REPO" FM_HOME="$CASE_HOME" \
  FM_STATE_OVERRIDE="$CASE_HOME/state" FM_DATA_OVERRIDE="$CASE_HOME/data" \
  "$ROOT_REPO/bin/fm-usage-ledger.sh" list \
  | grep '"event":"cleanup"' \
  | sed -n 's/.*"task":"\([^"]*\)".*"kind":"\([^"]*\)","harness":"\([^"]*\)","model":"\([^"]*\)","effort":"\([^"]*\)".*"outcome":"\([^"]*\)","status_class":"\([^"]*\)".*/  task=\1 kind=\2 harness=\3 model=\4 effort=\5 outcome=\6 last_status=\7/p'

rule "PRIVACY + INTEGRITY of the surviving store"
if grep -q "captain notes were sensitive" "$CASE_HOME/data/task-usage.jsonl"; then
  printf '  LEAK: a free-form status note reached the ledger\n'
else
  printf '  no free-form status text reached the ledger\n'
fi
if grep -qF "$home_path" "$CASE_HOME/data/task-usage.jsonl"; then
  printf '  LEAK: a discarded home path reached the ledger\n'
else
  printf '  no discarded home path reached the ledger\n'
fi
printf '  mode: %s\n' "$(ls -l "$CASE_HOME/data/task-usage.jsonl" | awk '{print $1}')"
printf '  verify: '
FM_ROOT_OVERRIDE="$ROOT_REPO" FM_HOME="$CASE_HOME" \
  FM_STATE_OVERRIDE="$CASE_HOME/state" FM_DATA_OVERRIDE="$CASE_HOME/data" \
  "$ROOT_REPO/bin/fm-usage-ledger.sh" verify

if [ -n "${DEMO_COPY_LEDGER:-}" ]; then
  cp "$CASE_HOME/data/task-usage.jsonl" "$DEMO_COPY_LEDGER"
  printf '\nsurviving ledger copied to %s\n' "$DEMO_COPY_LEDGER"
fi
