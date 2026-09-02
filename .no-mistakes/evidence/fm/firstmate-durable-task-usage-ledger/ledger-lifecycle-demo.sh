#!/usr/bin/env bash
# Manual end-to-end demonstration of Firstmate's durable task-usage ledger.
#
# Drives the REAL lifecycle scripts (bin/fm-spawn.sh, bin/fm-pr-check.sh,
# bin/fm-merge-local.sh, bin/fm-teardown.sh) against a hermetic FM_HOME with a
# real git project, then shows that the forensic join the change exists for
# ("which model produced this merged PR?") still answers AFTER ordinary
# successful cleanup has deleted state/<task>.meta.
#
# Usage: ledger-lifecycle-demo.sh <path-to-firstmate-worktree>
set -eu

ROOT=${1:?usage: ledger-lifecycle-demo.sh <firstmate-worktree>}
ROOT=$(cd "$ROOT" && pwd)
# The same escape hatch firstmate's own tests/lib.sh exports: this demo drives
# the real lifecycle scripts against a temp-sandbox fleet from a gate worktree.
export FM_GATE_REFUSE_BYPASS=1
BASE=$(mktemp -d "${TMPDIR:-/tmp}/fm-ledger-demo.XXXXXX")
trap 'rm -rf "$BASE"' EXIT

HOME_DIR="$BASE/home"
FAKEBIN="$BASE/fakebin"
LEDGER="$ROOT/bin/fm-usage-ledger.sh"
STORE="$HOME_DIR/data/task-usage.jsonl"
PANE=

say() { printf '\n== %s\n' "$*"; }
run() { printf '$ %s\n' "$*"; "$@"; }
pretty() { sed 's/","/",\n     "/g'; }

mkdir -p "$HOME_DIR/data" "$HOME_DIR/projects" "$HOME_DIR/state" "$HOME_DIR/config" "$FAKEBIN"
printf 'claude\n' > "$HOME_DIR/config/crew-harness"
touch "$HOME_DIR/state/.last-watcher-beat"

# --- fake toolchain: no real agent, no real forge, no real terminal ---------
cat > "$FAKEBIN/tmux" <<'SH'
#!/usr/bin/env bash
set -u
case "$*" in *"#{pane_current_path}"*) printf '%s\n' "${FM_FAKE_PANE_PATH:-}"; exit 0 ;; esac
case "${1:-}" in display-message) printf 'firstmate\n'; exit 0 ;; list-windows) exit 0 ;; esac
exit 0
SH
cat > "$FAKEBIN/gh-axi" <<'SH'
#!/usr/bin/env bash
case "${1:-} ${2:-}" in
  "pr list") printf '%s\n' "count: 0 (showing first 0)" "pull_requests[]: []"; exit 0 ;;
  "pr view") echo "error: pull request not found" >&2; exit 1 ;;
esac
exit 0
SH
cat > "$FAKEBIN/gh" <<'SH'
#!/usr/bin/env bash
[ -z "${FM_FAKE_PR_HEAD:-}" ] || { printf '%s\n' "$FM_FAKE_PR_HEAD"; exit 0; }
echo "error: pull request not found" >&2
exit 1
SH
printf '#!/usr/bin/env bash\nexit 0\n' > "$FAKEBIN/no-mistakes"
printf '#!/usr/bin/env bash\nexit 0\n' > "$FAKEBIN/treehouse"
chmod +x "$FAKEBIN"/*

new_project() { # <name> <task-id> -> project path, worktree at <name>-wt
  local proj="$BASE/$1"
  git init -q "$proj"
  printf '# %s\n' "$1" > "$proj/README.md"
  git -C "$proj" add README.md
  git -C "$proj" -c user.name=demo -c user.email=demo@example.invalid commit -qm initial
  git clone --quiet --bare "$proj" "$proj.origin.git"
  git -C "$proj" remote add origin "file://$proj.origin.git"
  git -C "$proj" worktree add --quiet -b "fm/$2" "$BASE/$1-wt"
  printf '%s\n' "$proj"
}

spawn() {
  FM_ROOT_OVERRIDE='' FM_HOME="$HOME_DIR" \
    FM_STATE_OVERRIDE="$HOME_DIR/state" FM_DATA_OVERRIDE="$HOME_DIR/data" \
    FM_PROJECTS_OVERRIDE="$HOME_DIR/projects" FM_CONFIG_OVERRIDE="$HOME_DIR/config" \
    FM_BACKEND=tmux FM_SPAWN_NO_GUARD=1 FM_FAKE_PANE_PATH="$PANE" TMUX="fake,1,0" \
    PATH="$FAKEBIN:$PATH" "$ROOT/bin/fm-spawn.sh" "$@" 2>&1
}
in_home() {
  FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$HOME_DIR" \
    FM_STATE_OVERRIDE="$HOME_DIR/state" FM_DATA_OVERRIDE="$HOME_DIR/data" \
    FM_PROJECTS_OVERRIDE="$HOME_DIR/projects" FM_CONFIG_OVERRIDE="$HOME_DIR/config" \
    FM_TEARDOWN_GUARD_DONE=1 FM_FAKE_PR_HEAD="${FM_FAKE_PR_HEAD:-}" \
    PATH="$FAKEBIN:$PATH" "$@" 2>&1
}
ledger()   { in_home "$LEDGER" "$@"; }
pr_check() { in_home "$ROOT/bin/fm-pr-check.sh" "$@"; }
teardown() { in_home "$ROOT/bin/fm-teardown.sh" "$@"; }
merge_local() { in_home "$ROOT/bin/fm-merge-local.sh" "$@"; }
gone() { [ ! -e "$1" ] && printf '  %s: deleted by cleanup\n' "$1" || printf '  %s: STILL PRESENT\n' "$1"; }

say "0. a home that has never recorded anything has no ledger at all"
run ls -A "$HOME_DIR/data"

# ---------------------------------------------------------------------------
say "1. a real ship task is spawned, pinned to a model and an effort"
SHIP=demoship-x1
PROJ=$(new_project demoship "$SHIP"); PANE="$BASE/demoship-wt"
mkdir -p "$HOME_DIR/data/$SHIP"
printf 'Delivery contract: mode=no-mistakes\nbrief\n' > "$HOME_DIR/data/$SHIP/brief.md"
run spawn "$SHIP" "$PROJ" --mode no-mistakes --yolo off --model opus --effort high

say "1a. the volatile task record firstmate has always had"
run cat "$HOME_DIR/state/$SHIP.meta"

say "1b. and now, durably, the ledger's first two records"
run ledger list
printf '\nthis incarnation is %s\n' "$(sed -n 's/^spawn_gen=//p' "$HOME_DIR/state/$SHIP.meta")"

# ---------------------------------------------------------------------------
say "2. the task's PR is registered (real bin/fm-pr-check.sh)"
PR_URL=https://github.com/example/repo/pull/4242
export FM_FAKE_PR_HEAD=8f2c1d4e6b7a90c3d5e2f14b6a8c0d9e3f5a7b12
run pr_check "$SHIP" "$PR_URL"
run ledger list --recent 1

say "2a. the poll re-arms more than once - a repeat is idempotent, not a second row"
run pr_check "$SHIP" "$PR_URL"
printf 'pr rows in the store: %s\n' "$(grep -cF '"event":"pr"' "$STORE")"

# ---------------------------------------------------------------------------
say "3. the task ends and ordinary SUCCESSFUL cleanup runs (real bin/fm-teardown.sh)"
printf '%s\n' 'working: implementing the change' \
  'done: landed; captain said the client PHI export was wrong' > "$HOME_DIR/state/$SHIP.status"
printf 'the status log cleanup is about to delete:\n'; sed 's/^/  /' "$HOME_DIR/state/$SHIP.status"
run teardown "$SHIP"

say "3a. every volatile trace of the task is gone - this is the forensic gap"
gone "$HOME_DIR/state/$SHIP.meta"
gone "$HOME_DIR/state/$SHIP.status"

# ---------------------------------------------------------------------------
say "4. a local-only task lands through the real merge gate-action"
LOCAL=demolocal-x1
PROJ2=$(new_project demolocal "$LOCAL"); PANE="$BASE/demolocal-wt"
mkdir -p "$HOME_DIR/data/$LOCAL"
printf 'Delivery contract: mode=local-only\nbrief\n' > "$HOME_DIR/data/$LOCAL/brief.md"
run spawn "$LOCAL" "$PROJ2" --mode local-only --yolo on --harness codex --model gpt-5 --effort medium
git -C "$BASE/demolocal-wt" -c user.name=demo -c user.email=demo@example.invalid \
  commit -q --allow-empty -m "the work this task landed"
run merge_local "$LOCAL"
run ledger list --recent 1

# ---------------------------------------------------------------------------
say "5. THE POINT: after cleanup deleted the task record, the outcome still joins to its model"
printf '%-28s %-8s %-8s %-7s %-12s %-8s %s\n' 'TASK [EVENT]' HARNESS MODEL EFFORT MODE OUTCOME 'PR / LANDING'
while IFS= read -r line; do
  f() { printf '%s' "$line" | sed -n "s/.*\"$1\":\"\([^\"]*\)\".*/\1/p"; }
  ev=$(f event); [ "$ev" != ledger-open ] || continue
  ref=$(f pr); [ -n "$ref" ] || ref=$(f landing)
  printf '%-28s %-8s %-8s %-7s %-12s %-8s %s\n' \
    "$(f task) [$ev]" "$(f harness)" "$(f model)" "$(f effort)" "$(f mode)" "$(f outcome)" "${ref:--}"
done < "$STORE"

say "5a. one whole cleanup record, exactly as stored"
grep -F '"event":"cleanup"' "$STORE" | pretty

# ---------------------------------------------------------------------------
say "6. the privacy boundary"
if grep -q 'PHI export was wrong' "$STORE"; then
  echo "  LEAK: the captain's free-form note is in the ledger"
else
  echo "  absent: the captain's free-form status note is nowhere in the ledger"
fi
printf '  only the closed status class was kept: status_class=%s\n' \
  "$(grep -F '"event":"cleanup"' "$STORE" | sed -n 's/.*"status_class":"\([^"]*\)".*/\1/p')"
printf '  worktree / home / tasktmp paths in the store: %s\n' "$(grep -c -F "$BASE" "$STORE" || true)"
printf '  project recorded as its joinable directory name, never its path: %s\n' \
  "$(grep -F '"event":"spawn"' "$STORE" | sed -n 's/.*"project":"\([^"]*\)".*/\1/p' | tr '\n' ' ')"

say "7. the store is private, verifiable, and honest about when coverage began"
run ledger path
run stat -c '%A %U %n' "$STORE"
run ledger verify
printf 'the first-observed marker - nothing before it is backfilled:\n'
head -1 "$STORE" | pretty

say "8. retention is an explicit operator command, never an automatic rewrite"
printf 'ageing the two demoship rows to 500 days ago, past the 400-day default horizon...\n'
OLD=$(( $(date +%s) - 500*86400 ))
sed -i "s/\(\"seq\":[23],\)\"at\":[0-9]*/\1\"at\":$OLD/" "$STORE"
run ledger prune
run ledger list
printf '\nand the next append does not re-issue a sequence number a pruned record used:\n'
in_home "$LEDGER" record --event spawn --task after-prune-x1 --gen g-after >/dev/null
run ledger list --recent 1

say "done"
[ -z "${DEMO_STORE_COPY:-}" ] || cp "$STORE" "$DEMO_STORE_COPY"
