#!/usr/bin/env bash
# Evidence driver: drives Firstmate's REAL lifecycle scripts against a sandbox
# home and prints an operator transcript showing that a merged PR can still be
# joined to the model that produced it after ordinary cleanup deleted
# state/<id>.meta.  Nothing here re-implements the ledger; every step is a real
# bin/fm-*.sh invocation.
set -u

. "/home/rafaelfadel/.no-mistakes/worktrees/052f7dfaa44d/01M1F122YY3Y6DVV341K260825/tests/lib.sh"
fm_git_identity fmtest fmtest@example.invalid

TMP_ROOT=$(fm_test_tmproot fm-ledger-evidence)
BASE="$TMP_ROOT/demo"
H="$BASE/home"
PROJ="$BASE/acme-api"
WT="$BASE/wt"
FAKE="$BASE/fake/fakebin"
ID=ledger-demo-x1
PR_URL=https://github.com/acme/acme-api/pull/138
PR_HEAD=3f1c0aa9d2b4e6f8901122334455667788990011
STORE="$H/data/task-usage.jsonl"

mkdir -p "$H/data" "$H/state" "$H/projects" "$H/config" "$FAKE"
printf 'claude\n' > "$H/config/crew-harness"
touch "$H/state/.last-watcher-beat"
fm_git_worktree "$PROJ" "$WT" "fm/$ID"

# --- fake forge + backend toolchain (the sandbox stands in for tmux/GitHub) ---
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
  "pr merge") printf 'merged:\n  number: %s\n  status: ok\n' "${3:-}"; exit 0 ;;
  "pr view")
    [ "$#" -eq 5 ] && [ "${4:-}" = --repo ] || exit 2
    printf 'pull_request:\n  number: %s\n  state: merged\n' "$3"; exit 0 ;;
esac
exit 0
SH
cat > "$FAKE/gh" <<SH
#!/usr/bin/env bash
case "\${1:-} \${2:-}" in
  "pr view") case " \$* " in *headRefOid*) printf '%s\n' '$PR_HEAD'; exit 0 ;; esac ;;
  "api graphql") printf '%s\n' state=MERGED merged=true queued=false base=main; exit 0 ;;
  api\ *) exit 0 ;;
esac
exit 0
SH
cat > "$FAKE/no-mistakes" <<'SH'
#!/usr/bin/env bash
exit 0
SH
chmod +x "$FAKE/tmux" "$FAKE/gh-axi" "$FAKE/gh" "$FAKE/no-mistakes"
fm_fake_exit0 "$FAKE" treehouse

export FM_HOME="$H" FM_STATE_OVERRIDE="$H/state" FM_DATA_OVERRIDE="$H/data" \
  FM_PROJECTS_OVERRIDE="$H/projects" FM_CONFIG_OVERRIDE="$H/config" \
  FM_BACKEND=tmux FM_SPAWN_NO_GUARD=1 FM_FAKE_PANE_PATH="$WT" TMUX="fake,1,0" \
  FM_TEARDOWN_GUARD_DONE=1 PATH="$FAKE:$PATH"

cd "$ROOT"

say() { printf '\n=== %s ===\n\n' "$1"; }
note() { printf '# %s\n' "$1"; }
run() { printf '$ %s\n' "$*"; eval "$@" 2>&1; printf '\n'; }
rows() { wc -l < "$STORE" 2>/dev/null || printf '0\n'; }

# Sandbox paths are long and machine-specific; shorten them for the reader.
scrub() { sed -e "s#$BASE#\$DEMO#g" -e "s#$ROOT#\$FM#g"; }

{
printf 'Firstmate durable task-usage ledger - end-to-end operator transcript\n'
printf 'Every command below is a real bin/fm-*.sh run against a sandbox home\n'
printf '($DEMO/home). The forge and the terminal backend are stubbed; the spawn,\n'
printf 'PR-check, merge, teardown and ledger code paths are the real ones.\n'

say "0. The home before any task ran"
run "ls -A '$H/data'"
note "No ledger file yet. Nothing is backfilled: coverage starts at the first"
note "lifecycle point that records."

say "1. A real spawn - bin/fm-spawn.sh"
mkdir -p "$H/data/$ID"
printf 'Delivery contract: mode=no-mistakes\nShip the importer.\n' > "$H/data/$ID/brief.md"
run "bin/fm-spawn.sh '$ID' '$PROJ' --mode no-mistakes --yolo off --model opus --effort high"
note "The volatile task record that ordinary cleanup will later delete:"
run "grep -E '^(harness|model|effort|kind|mode|yolo|project|spawn_gen)=' '$H/state/$ID.meta'"

say "2. The PR is published - bin/fm-pr-check.sh"
run "bin/fm-pr-check.sh '$ID' '$PR_URL'"

say "3. The PR is merged - bin/fm-pr-merge.sh"
run "bin/fm-pr-merge.sh '$ID' '$PR_URL'"

say "4. Replaying those calls is idempotent by event identity"
BEFORE=$(rows)
run "bin/fm-pr-check.sh '$ID' '$PR_URL' >/dev/null 2>&1; bin/fm-pr-merge.sh '$ID' '$PR_URL' >/dev/null 2>&1; echo 'replayed the PR registration and the merge notification'"
printf '  ledger rows before the replay: %s\n  ledger rows after  the replay: %s\n\n' \
  "$BEFORE" "$(rows)"

say "5. The task ends and is cleaned up - bin/fm-teardown.sh"
printf '%s\n' 'working: implementing the importer' \
  'done: landed; captain said the client roster is confidential' \
  > "$H/state/$ID.status"
note "The final status log, whose free-form note must never reach the ledger:"
run "cat '$H/state/$ID.status'"
run "bin/fm-teardown.sh '$ID'"

say "6. Ordinary cleanup deleted the task's volatile record"
run "ls '$H/state/$ID.meta' '$H/state/$ID.status'"
note "This was the instrumentation gap: nothing else held the harness, model or"
note "effort, so the merged PR above could not be joined back to a model."

say "7. The durable ledger outlived it - bin/fm-usage-ledger.sh"
run "bin/fm-usage-ledger.sh path"
run "bin/fm-usage-ledger.sh verify"
run "ls -l '$STORE'"
note "The store, one JSON object per line, oldest first:"
run "bin/fm-usage-ledger.sh list"

say "8. The forensic question the audit could not answer"
printf '$ %s\n' "which model produced merged PR $PR_URL ?"
awk -v url="$PR_URL" '
  index($0, "\"pr\":\"" url "\"") {
    ev = $0; sub(/.*"event":"/, "", ev); sub(/".*/, "", ev)
    tk = $0; sub(/.*"task":"/, "", tk); sub(/".*/, "", tk)
    hs = $0; sub(/.*"harness":"/, "", hs); sub(/".*/, "", hs)
    md = $0; sub(/.*"model":"/, "", md); sub(/".*/, "", md)
    ef = $0; sub(/.*"effort":"/, "", ef); sub(/".*/, "", ef)
    pj = $0; sub(/.*"project":"/, "", pj); sub(/".*/, "", pj)
    printf "  event=%-6s task=%s project=%s harness=%s model=%s effort=%s\n", \
      ev, tk, pj, hs, md, ef
  }' "$STORE"
printf '\n'
printf '$ %s\n' "how did that task end, and who validated it ?"
awk '/"event":"cleanup"/ {
    tk = $0; sub(/.*"task":"/, "", tk); sub(/".*/, "", tk)
    oc = $0; sub(/.*"outcome":"/, "", oc); sub(/".*/, "", oc)
    sc = $0; sub(/.*"status_class":"/, "", sc); sub(/".*/, "", sc)
    vh = $0; sub(/.*"validator_harness":"/, "", vh); sub(/".*/, "", vh)
    vm = $0; sub(/.*"validator_model":"/, "", vm); sub(/".*/, "", vm)
    printf "  task=%s outcome=%s status_class=%s validator_harness=%s validator_model=%s\n", \
      tk, oc, sc, vh, vm
  }' "$STORE"
note "The validator identity is the literal \"unknown\": Firstmate cannot prove"
note "which agent the no-mistakes pipeline ran, so it says so instead of guessing."
printf '\n'

say "9. Privacy boundary: what never reaches the store"
for secret in "confidential" "client roster" "$WT" "$H" "brief.md"; do
  if grep -qF -- "$secret" "$STORE" 2>/dev/null; then
    printf '  LEAKED : %s\n' "$(printf '%s' "$secret" | scrub)"
  else
    printf '  absent : %s\n' "$(printf '%s' "$secret" | scrub)"
  fi
done
printf '\n'
note "The free-form status note, the worktree path, the home path and the brief"
note "have no field to land in; only the allowlisted axes are ever read."

say "10. Retention is an explicit operator verb, never a lifecycle side effect"
run "bin/fm-usage-ledger.sh prune --days 400"
run "bin/fm-usage-ledger.sh verify"
} 2>&1 | scrub
