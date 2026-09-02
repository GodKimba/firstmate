#!/usr/bin/env bash
# End-to-end operator demo of the durable task-usage ledger.
# Drives the REAL fm-spawn.sh, fm-pr-check.sh and fm-teardown.sh in a throwaway
# firstmate home, then shows the ledger surviving the cleanup that deletes
# state/<id>.meta - the exact gap the change closes.
set -u
WT_ROOT=${WT_ROOT:?}
. "$WT_ROOT/tests/lib.sh"
fm_git_identity fmtest fmtest@example.invalid
TMP_ROOT=$(fm_test_tmproot fm-ledger-demo)

say() { printf '\n\033[1m%s\033[0m\n' "$*"; }
run() { printf '$ %s\n' "$*"; eval "$@"; }

BASE="$TMP_ROOT/demo"
HOME_DIR="$BASE/home"; PROJ="$BASE/project"; WT="$BASE/wt"
FB=$(fm_fakebin "$BASE/fake")
cat > "$FB/tmux" <<'SH'
#!/usr/bin/env bash
set -u
case "$*" in *"#{pane_current_path}"*) printf '%s\n' "${FM_FAKE_PANE_PATH:-}"; exit 0 ;; esac
case "${1:-}" in display-message) printf 'firstmate\n'; exit 0 ;; list-windows) exit 0 ;; esac
exit 0
SH
cat > "$FB/gh-axi" <<'SH'
#!/usr/bin/env bash
case "${1:-} ${2:-}" in
  "pr list") printf '%s\n' "count: 0 (showing first 0)" "pull_requests[]: []"; exit 0 ;;
  "pr view") echo "error: pull request not found" >&2; exit 1 ;;
esac
exit 0
SH
cat > "$FB/gh" <<'SH'
#!/usr/bin/env bash
[ -z "${FM_FAKE_PR_HEAD:-}" ] || { printf '%s\n' "$FM_FAKE_PR_HEAD"; exit 0; }
echo "error: pull request not found" >&2
exit 1
SH
cat > "$FB/no-mistakes" <<'SH'
#!/usr/bin/env bash
exit 0
SH
chmod +x "$FB/tmux" "$FB/gh-axi" "$FB/gh" "$FB/no-mistakes"
fm_fake_exit0 "$FB" treehouse
mkdir -p "$HOME_DIR/data" "$HOME_DIR/projects" "$HOME_DIR/state" "$HOME_DIR/config"
printf 'claude\n' > "$HOME_DIR/config/crew-harness"
touch "$HOME_DIR/state/.last-watcher-beat"
ID=ledger-demo-x1
fm_git_worktree "$PROJ" "$WT" "fm/$ID"
mkdir -p "$HOME_DIR/data/$ID"
printf 'Delivery contract: mode=no-mistakes\nbrief\n' > "$HOME_DIR/data/$ID/brief.md"

L() { FM_ROOT_OVERRIDE='' FM_HOME="$HOME_DIR" FM_STATE_OVERRIDE="$HOME_DIR/state" \
  FM_DATA_OVERRIDE="$HOME_DIR/data" "$WT_ROOT/bin/fm-usage-ledger.sh" "$@"; }

say "0. A brand-new home has no ledger yet; the store lives under FM_HOME/data/, which teardown never touches."
run "L path"
run "ls -l \"\$(L path)\" 2>&1 || true"

say "1. Real fm-spawn.sh launches a ship task pinned to a model and effort."
FM_ROOT_OVERRIDE='' FM_HOME="$HOME_DIR" FM_STATE_OVERRIDE="$HOME_DIR/state" \
  FM_DATA_OVERRIDE="$HOME_DIR/data" FM_PROJECTS_OVERRIDE="$HOME_DIR/projects" \
  FM_CONFIG_OVERRIDE="$HOME_DIR/config" FM_BACKEND=tmux FM_SPAWN_NO_GUARD=1 \
  FM_FAKE_PANE_PATH="$WT" TMUX="fake,1,0" PATH="$FB:$PATH" \
  "$WT_ROOT/bin/fm-spawn.sh" "$ID" "$PROJ" --mode no-mistakes --yolo off \
  --model opus --effort high 2>&1 | sed -n '/spawned/p;/^ *harness/p' || exit 1
GEN=$(sed -n 's/^spawn_gen=//p' "$HOME_DIR/state/$ID.meta")

say "2. The volatile task record - the ONLY place the axes used to live."
run "sed -n 's/^\\(harness\\|model\\|effort\\|kind\\|mode\\|yolo\\|spawn_gen\\)=/  &/p' '$HOME_DIR/state/$ID.meta'"

say "3. The durable ledger opened with an explicit first-observed marker, then the spawn row."
run "L list"

say "4. Real fm-pr-check.sh registers the PR the task pushed; the forge reports its head."
FM_ROOT_OVERRIDE="$WT_ROOT" FM_HOME="$HOME_DIR" FM_STATE_OVERRIDE="$HOME_DIR/state" \
  FM_DATA_OVERRIDE="$HOME_DIR/data" PATH="$FB:$PATH" \
  FM_FAKE_PR_HEAD=3333333333333333333333333333333333333333 \
  "$WT_ROOT/bin/fm-pr-check.sh" "$ID" https://github.com/example/repo/pull/11 2>&1 | tail -3

say "   A re-armed poll repeats the same call - it must not duplicate the row."
FM_ROOT_OVERRIDE="$WT_ROOT" FM_HOME="$HOME_DIR" FM_STATE_OVERRIDE="$HOME_DIR/state" \
  FM_DATA_OVERRIDE="$HOME_DIR/data" PATH="$FB:$PATH" \
  FM_FAKE_PR_HEAD=3333333333333333333333333333333333333333 \
  "$WT_ROOT/bin/fm-pr-check.sh" "$ID" https://github.com/example/repo/pull/11 >/dev/null 2>&1
run "L list | grep -c '\"event\":\"pr\"'"

say "5. The task ends on a status log whose free-form note must NEVER be stored."
printf '%s\n' 'working: implementing' \
  'done: landed; captain said the patient chart PHI stays out of this' \
  > "$HOME_DIR/state/$ID.status"
run "cat '$HOME_DIR/state/$ID.status'"

say "6. Real fm-teardown.sh performs ORDINARY SUCCESSFUL CLEANUP."
FM_ROOT_OVERRIDE="$WT_ROOT" FM_HOME="$HOME_DIR" FM_STATE_OVERRIDE="$HOME_DIR/state" \
  FM_DATA_OVERRIDE="$HOME_DIR/data" FM_PROJECTS_OVERRIDE="$HOME_DIR/projects" \
  FM_CONFIG_OVERRIDE="$HOME_DIR/config" FM_TEARDOWN_GUARD_DONE=1 PATH="$FB:$PATH" \
  "$WT_ROOT/bin/fm-teardown.sh" "$ID" 2>&1 | tail -4

say "7. The volatile task record and status log are GONE - the old attribution gap."
run "ls '$HOME_DIR/state/$ID.meta' '$HOME_DIR/state/$ID.status' 2>&1"

say "8. The durable ledger outlived cleanup and still verifies."
run "L verify"
run "L list"

say "9. THE JOIN THE AUDIT COULD NOT MAKE: merged PR -> the model that produced it."
awk -F'"' '
  /"event":"pr"/    { for(i=1;i<NF;i++){ if($i=="pr:"){}; }
                      match($0,/"pr":"[^"]*"/); pr=substr($0,RSTART+6,RLENGTH-7)
                      match($0,/"model":"[^"]*"/); m=substr($0,RSTART+9,RLENGTH-10)
                      match($0,/"harness":"[^"]*"/); h=substr($0,RSTART+11,RLENGTH-12)
                      match($0,/"effort":"[^"]*"/); e=substr($0,RSTART+10,RLENGTH-11)
                      match($0,/"pr_head":"[^"]*"/); s=substr($0,RSTART+11,RLENGTH-12)
                      printf "  PR %s\n    head     %s\n    harness  %s\n    model    %s\n    effort   %s\n", pr,s,h,m,e }
  /"event":"cleanup"/ { match($0,/"outcome":"[^"]*"/); o=substr($0,RSTART+11,RLENGTH-12)
                      match($0,/"status_class":"[^"]*"/); c=substr($0,RSTART+16,RLENGTH-17)
                      match($0,/"mode":"[^"]*"/); d=substr($0,RSTART+8,RLENGTH-9)
                      match($0,/"yolo":"[^"]*"/); y=substr($0,RSTART+8,RLENGTH-9)
                      printf "    outcome  %s (final status class: %s)\n    delivery %s, yolo %s\n", o,c,d,y }
' "$(L path)"

say "10. Privacy boundary: no status note, no path, no token in the store; mode 0600."
run "grep -c 'PHI\\|patient chart\\|$WT\\|$HOME_DIR/state' '$(L path)' || echo '  0 private values found'"
run "stat -c '%a %n' '$(L path)'"

say "11. Retention is explicit-only and never rewrites history behind a task."
run "L prune --days 400"
run "L verify"

say "12. A local-only landing records the commit it landed, through the real fm-merge-local.sh."
LID=ledger-demo-x2
LWT="$BASE/wt2"
fm_git_worktree "$BASE/project2" "$LWT" "fm/$LID"
git -C "$LWT" -c user.email=t@t -c user.name=t commit -q --allow-empty -m "landed change"
fm_write_meta "$HOME_DIR/state/$LID.meta" "window=firstmate:fm-$LID" "endpoint_task_id=$LID" \
  "worktree=$LWT" "project=$BASE/project2" "harness=codex" "kind=ship" "mode=local-only" \
  "yolo=off" "model=gpt-5" "effort=medium" "spawn_gen=g-land"
FM_ROOT_OVERRIDE="$WT_ROOT" FM_HOME="$HOME_DIR" FM_STATE_OVERRIDE="$HOME_DIR/state" \
  FM_DATA_OVERRIDE="$HOME_DIR/data" PATH="$FB:$PATH" \
  "$WT_ROOT/bin/fm-merge-local.sh" "$LID" 2>&1 | tail -2
run "L list --recent 1"
