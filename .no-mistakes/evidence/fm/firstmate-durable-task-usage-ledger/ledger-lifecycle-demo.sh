#!/usr/bin/env bash
# Operator-level demonstration of the durable task-usage ledger.
#
# It drives the REAL executables (bin/fm-spawn.sh, bin/fm-pr-check.sh,
# bin/fm-merge-local.sh, bin/fm-teardown.sh, bin/fm-usage-ledger.sh) through two
# whole task lifecycles in a scratch $FM_HOME, then answers - from the ledger
# alone, after ordinary cleanup has deleted state/<id>.meta - the question the
# forensic audit could not answer for any of 138 merged PRs:
#
#     "which model produced this merged PR?"
#
# Usage: DEMO_OUT_DIR=<dir> ledger-lifecycle-demo.sh <path-to-firstmate-worktree>
set -u

ROOT=${1:?usage: ledger-lifecycle-demo.sh <firstmate-worktree>}
cd "$ROOT" || exit 1
# shellcheck source=/dev/null
. "$ROOT/tests/lib.sh"
fm_git_identity fmdemo fmdemo@example.invalid

LEDGER="$ROOT/bin/fm-usage-ledger.sh"
SPAWN="$ROOT/bin/fm-spawn.sh"
TEARDOWN="$ROOT/bin/fm-teardown.sh"
PR_CHECK="$ROOT/bin/fm-pr-check.sh"
MERGE_LOCAL="$ROOT/bin/fm-merge-local.sh"
TMP_ROOT=$(fm_test_tmproot fm-ledger-demo)

say()  { printf '\n== %s\n' "$*"; }
echo_cmd() { printf '$ %s\n' "$*"; }

HOME_DIR="$TMP_ROOT/home"
PROJ="$TMP_ROOT/nutricheck"
FAKE="$TMP_ROOT/fake/fakebin"
STORE="$HOME_DIR/data/task-usage.jsonl"
mkdir -p "$HOME_DIR/data" "$HOME_DIR/state" "$HOME_DIR/config" "$HOME_DIR/projects" "$FAKE"
printf 'claude\n' > "$HOME_DIR/config/crew-harness"
touch "$HOME_DIR/state/.last-watcher-beat"

# Fake session/forge toolchain, exactly as the behavior suite stubs it.
cat > "$FAKE/tmux" <<'SH'
#!/usr/bin/env bash
set -u
case "$*" in *"#{pane_current_path}"*) printf '%s\n' "${FM_FAKE_PANE_PATH:-}"; exit 0 ;; esac
case "${1:-}" in display-message) printf 'firstmate\n'; exit 0 ;; list-windows) exit 0 ;; esac
exit 0
SH
cat > "$FAKE/gh-axi" <<'SH'
#!/usr/bin/env bash
case "${1:-} ${2:-}" in
  "pr list") printf '%s\n' "count: 0 (showing first 0)" "pull_requests[]: []"; exit 0 ;;
  "pr view") echo "error: pull request not found" >&2; exit 1 ;;
esac
exit 0
SH
cat > "$FAKE/gh" <<'SH'
#!/usr/bin/env bash
[ -z "${FM_FAKE_PR_HEAD:-}" ] || { printf '%s\n' "$FM_FAKE_PR_HEAD"; exit 0; }
echo "error: pull request not found" >&2
exit 1
SH
cat > "$FAKE/no-mistakes" <<'SH'
#!/usr/bin/env bash
exit 0
SH
chmod +x "$FAKE/tmux" "$FAKE/gh-axi" "$FAKE/gh" "$FAKE/no-mistakes"
fm_fake_exit0 "$FAKE" treehouse

ledger() {
  FM_ROOT_OVERRIDE='' FM_HOME="$HOME_DIR" FM_STATE_OVERRIDE="$HOME_DIR/state" \
    FM_DATA_OVERRIDE="$HOME_DIR/data" "$LEDGER" "$@"
}
spawn() {  # <id> <worktree> [spawn flags...]
  local id=$1 wt=$2; shift 2
  echo_cmd "fm-spawn.sh $id <project> $*"
  FM_ROOT_OVERRIDE='' FM_HOME="$HOME_DIR" FM_STATE_OVERRIDE="$HOME_DIR/state" \
    FM_DATA_OVERRIDE="$HOME_DIR/data" FM_PROJECTS_OVERRIDE="$HOME_DIR/projects" \
    FM_CONFIG_OVERRIDE="$HOME_DIR/config" FM_BACKEND=tmux FM_SPAWN_NO_GUARD=1 \
    FM_FAKE_PANE_PATH="$wt" TMUX="fake,1,0" PATH="$FAKE:$PATH" \
    "$SPAWN" "$id" "$PROJ" "$@" 2>&1
}
pr_check() {  # <id> <url> <head>
  echo_cmd "fm-pr-check.sh $1 $2"
  FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$HOME_DIR" FM_STATE_OVERRIDE="$HOME_DIR/state" \
    FM_DATA_OVERRIDE="$HOME_DIR/data" FM_FAKE_PR_HEAD="$3" PATH="$FAKE:$PATH" \
    "$PR_CHECK" "$1" "$2" 2>&1 | sed 's/^/  /'
  printf '  -> exit %s\n' "${PIPESTATUS[0]}"
}
merge_local() {  # <id>
  echo_cmd "fm-merge-local.sh $1"
  FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$HOME_DIR" FM_STATE_OVERRIDE="$HOME_DIR/state" \
    FM_DATA_OVERRIDE="$HOME_DIR/data" PATH="$FAKE:$PATH" \
    "$MERGE_LOCAL" "$1" 2>&1 | sed 's/^/  /'
  printf '  -> exit %s\n' "${PIPESTATUS[0]}"
}
teardown() {  # <id> [flags]
  echo_cmd "fm-teardown.sh $*"
  FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$HOME_DIR" FM_STATE_OVERRIDE="$HOME_DIR/state" \
    FM_DATA_OVERRIDE="$HOME_DIR/data" FM_PROJECTS_OVERRIDE="$HOME_DIR/projects" \
    FM_CONFIG_OVERRIDE="$HOME_DIR/config" FM_TEARDOWN_GUARD_DONE=1 PATH="$FAKE:$PATH" \
    "$TEARDOWN" "$@" 2>&1 | sed 's/^/  /'
}

printf 'firstmate %s\n' "$(git -C "$ROOT" rev-parse --short HEAD)"
printf 'FM_HOME    %s\n' "$HOME_DIR"

# ---------------------------------------------------------------------------
say "1. A brand new home has NO ledger and no fabricated history"
echo_cmd "fm-usage-ledger.sh path";   ledger path
echo_cmd "fm-usage-ledger.sh verify"; ledger verify

# ---------------------------------------------------------------------------
say "2. Launch a real ship task: claude / opus / high, delivered through no-mistakes"
SHIP=nutricheck-import-x1
WT1="$TMP_ROOT/wt-ship"
fm_git_worktree "$PROJ" "$WT1" "fm/$SHIP"
mkdir -p "$HOME_DIR/data/$SHIP"
printf 'Delivery contract: mode=no-mistakes\nimport staged module\n' > "$HOME_DIR/data/$SHIP/brief.md"
spawn "$SHIP" "$WT1" --mode no-mistakes --yolo off --model opus --effort high

say "   the volatile task record - this is what ordinary cleanup deletes"
echo_cmd "cat state/$SHIP.meta"
sed -n 's/^\(window\|project\|harness\|kind\|mode\|yolo\|model\|effort\|spawn_gen\|worktree\|tasktmp\)=/  &/p' \
  "$HOME_DIR/state/$SHIP.meta"

say "   the ledger already carries the spawn axes (record 1 is the coverage marker)"
echo_cmd "fm-usage-ledger.sh list | jq -c ."; ledger list | jq -c .

# ---------------------------------------------------------------------------
say "3. The task opens its PR - fm-pr-check registers it and the forge's head"
PR_URL=https://github.com/kunchenguid/nutricheck/pull/138
PR_HEAD=3d1f9b0a77c4e5661b2d8f0a9c3e4d5f60718293
pr_check "$SHIP" "$PR_URL" "$PR_HEAD"
echo_cmd "fm-usage-ledger.sh list --recent 1 | jq -c ."; ledger list --recent 1 | jq -c .

say "   the armed poll calls it again - the repeat must not duplicate the row"
pr_check "$SHIP" "$PR_URL" "$PR_HEAD"
printf '  pr rows in the store: %s\n' "$(grep -c '"event":"pr"' "$STORE")"

# ---------------------------------------------------------------------------
say "4. The task ends. Ordinary successful cleanup DELETES its state records"
printf '%s\n' 'working: implementing' 'done: landed; captain notes were sensitive' \
  > "$HOME_DIR/state/$SHIP.status"
echo_cmd "ls state/ | grep $SHIP"; ls "$HOME_DIR/state/" | grep "$SHIP" | sed 's/^/  /'
teardown "$SHIP"
echo_cmd "ls state/ | grep $SHIP"
ls "$HOME_DIR/state/" | grep "$SHIP" | sed 's/^/  /' \
  || printf '  (nothing left: the model, effort and project this task ran on are gone from the home)\n'

# ---------------------------------------------------------------------------
say "5. A second task on a different harness and model, landed locally"
LAND=nutricheck-pdf-x1
WT2="$TMP_ROOT/wt-land"
git -C "$PROJ" worktree add --quiet -b "fm/$LAND" "$WT2"
mkdir -p "$HOME_DIR/data/$LAND"
printf 'Delivery contract: mode=local-only\npdf export\n' > "$HOME_DIR/data/$LAND/brief.md"
spawn "$LAND" "$WT2" --mode local-only --yolo on --model gpt-5 --effort medium
git -C "$WT2" commit -q --allow-empty -m "pdf export"
merge_local "$LAND"
printf '%s\n' 'done: landed locally' > "$HOME_DIR/state/$LAND.status"
teardown "$LAND"

# ---------------------------------------------------------------------------
say "6. THE DURABLE LEDGER - everything those deleted task records used to hold"
echo_cmd "fm-usage-ledger.sh verify"; ledger verify
echo_cmd "stat -c '%n mode=%a' \$(fm-usage-ledger.sh path)"
stat -c '  %n mode=%a owner=%U' "$STORE"
echo_cmd "fm-usage-ledger.sh list | jq -c ."; ledger list | jq -c .

[ -n "${DEMO_OUT_DIR:-}" ] && cp "$STORE" "$DEMO_OUT_DIR/task-usage.jsonl"

# ---------------------------------------------------------------------------
say "7. THE AUDIT QUESTION: join a delivered change back to the model that produced it"
printf '\n'
jq -rs '
  (map(select(.event=="cleanup")) | INDEX(.task)) as $clean |
  (map(select((.pr|length)>0 or (.landing|length)>0))) as $out |
  ["DELIVERED","TASK","HARNESS","MODEL","EFFORT","PROJECT","MODE","YOLO","OUTCOME","STATUS"],
  ["---------","----","-------","-----","------","-------","----","----","-------","------"],
  ($out[] | [ (if (.pr|length)>0 then .pr else ("local commit " + .landing[0:12]) end),
              .task, .harness, .model, .effort, .project, .mode, .yolo,
              ($clean[.task].outcome // "unknown"),
              ($clean[.task].status_class // "unknown") ])
  | @tsv' "$STORE" | column -t -s "$(printf '\t')" | sed 's/^/  /'

# ---------------------------------------------------------------------------
say "8. PRIVACY BOUNDARY: nothing private ever reached the store"
for probe in "$WT1" "$WT2" "/tmp/fm-$SHIP" "captain notes were sensitive" "$PROJ" "$HOME_DIR"; do
  if grep -qF -- "$probe" "$STORE" 2>/dev/null; then
    printf '  LEAKED: %s\n' "$probe"
  else
    printf '  absent from the ledger: %s\n' "$probe"
  fi
done

# ---------------------------------------------------------------------------
say "9. RETENTION is explicit, bounded, and never re-issues a sequence number"
echo_cmd "fm-usage-ledger.sh prune            # nothing is past the 400-day horizon yet"
ledger prune | sed 's/^/  /'
# Simulate a dormant home whose every dated record has aged past the horizon.
OLD=$(( $(date +%s) - 500 * 86400 ))
sed -i "s/^\({\"v\":1,\"seq\":[0-9]*,\)\"at\":[0-9]*/\1\"at\":$OLD/" "$STORE"
sed -i "1s/\"at\":[0-9]*/\"at\":$OLD/" "$STORE"
echo_cmd "# ... 500 days pass ..."
echo_cmd "fm-usage-ledger.sh prune"; ledger prune | sed 's/^/  /'
echo_cmd "fm-usage-ledger.sh list | jq -c '{seq,event,id}'"; ledger list | jq -c '{seq,event,id}' | sed 's/^/  /'
echo_cmd "fm-usage-ledger.sh record --event spawn --task next-x1 --gen g-next"
ledger record --event spawn --task next-x1 --gen g-next | sed 's/^/  /'
echo_cmd "fm-usage-ledger.sh list --recent 1 | jq -c '{seq,event,id}'   # continues past every pruned seq"
ledger list --recent 1 | jq -c '{seq,event,id}' | sed 's/^/  /'
echo_cmd "fm-usage-ledger.sh verify"; ledger verify

[ -n "${DEMO_OUT_DIR:-}" ] && printf '\nstore copied to %s/task-usage.jsonl\n' "$DEMO_OUT_DIR"
exit 0
