#!/usr/bin/env bash
# Evidence driver for the honesty/safety boundaries this round hardened: an
# identity-bearing input is refused rather than rewritten, a remote endpoint's
# backend is read from its own writer, an unreadable status class is announced
# rather than silently substituted, and `record` vs `verify` behave exactly as
# the schema owner's SAFETY block now claims.
set -u

WORKTREE=/home/rafaelfadel/.no-mistakes/worktrees/052f7dfaa44d/01M1F122YY3Y6DVV341K260825
. "$WORKTREE/tests/lib.sh"
fm_git_identity fmtest fmtest@example.invalid

TMP_ROOT=$(fm_test_tmproot fm-ledger-honesty)
LEDGER="$WORKTREE/bin/fm-usage-ledger.sh"

home() {  # home <name> -> path to a bare sandbox home
  local h="$TMP_ROOT/$1"
  mkdir -p "$h/data" "$h/state"
  printf '%s\n' "$h"
}
ledger() {  # ledger <home> <args...>
  local h=$1; shift
  FM_ROOT_OVERRIDE="$WORKTREE" FM_HOME="$h" \
    FM_STATE_OVERRIDE="$h/state" FM_DATA_OVERRIDE="$h/data" "$LEDGER" "$@"
}
say() { printf '\n=== %s ===\n\n' "$1"; }
note() { printf '# %s\n' "$1"; }

scrub() { sed -e "s#$TMP_ROOT#\$DEMO#g" -e "s#$WORKTREE#\$FM#g"; }

{
printf 'Firstmate task-usage ledger - refusal and honesty boundaries\n'
printf 'Real bin/fm-usage-ledger.sh runs against throwaway sandbox homes.\n'

# --- 1. an identity is never rewritten to fit a bound ------------------------
say "1. An over-long merge-request URL is refused, not truncated into another one"
H=$(home over-long)
printf '%s\n' 'window=w' 'worktree=/w' 'project=/p/acme-api' 'harness=claude' \
  'kind=ship' 'mode=no-mistakes' 'yolo=off' 'model=opus' 'effort=high' \
  'spawn_gen=g1' > "$H/state/alpha-x1.meta"
A63=$(printf '%063d' 0 | tr 0 a); A61=$(printf '%061d' 0 | tr 0 a)
HOST="$A63.$A63.$A63.$A61"
SEG=$(printf '%0204d' 0 | tr 0 b)
PATHP="$SEG/$SEG/$SEG/$SEG/$SEG"
URL="https://$HOST/$PATHP/-/merge_requests/12345678901"
printf '  a self-hosted GitLab merge request, %s characters long\n' "${#URL}"
printf '  it ends at merge request  ...%s\n' "${URL: -30}"
printf '  cut to the field bound it would end at ...%s\n' "$(printf '%s' "${URL:0:1314}" | tail -c 30)"
note "That shorter number is a DIFFERENT merge request that also parses."
printf '\n$ fm-usage-ledger.sh record --event pr --task alpha-x1 --pr <that URL> ...\n'
set +e
ledger "$H" record --event pr --task alpha-x1 --meta "$H/state/alpha-x1.meta" \
  --pr "$URL" --pr-head 1111111111111111111111111111111111111111 2>&1
printf '  exit=%s\n' "$?"
set -e
printf '\n$ ls %s/data\n' '$DEMO/over-long'
ls -A "$H/data" | sed 's/^/  /'
note "Nothing was written: an invalid request is refused before any append."
printf '\n'
note "A merge request that DOES fit is recorded in full:"
OKURL="https://gitlab.example.invalid/group/sub/project/-/merge_requests/4212"
printf '$ fm-usage-ledger.sh record --event merge --task alpha-x1 --pr %s --outcome merged\n' "$OKURL"
ledger "$H" record --event merge --task alpha-x1 --meta "$H/state/alpha-x1.meta" \
  --pr "$OKURL" --outcome merged 2>&1 | sed 's/^/  /'
ledger "$H" list | sed -n 's/.*\("event":"merge".*"pr":"[^"]*"\).*/  \1/p'
printf '\n'

# --- 2. a remote endpoint's own backend --------------------------------------
say "2. A remote secondmate records the endpoint's backend, never the local default"
H=$(home remote-backend)
printf '%s\n' 'window=remote:sm-x1' 'endpoint_task_id=sm-x1' 'worktree=/w' \
  'project=/p/nutricheck' 'harness=claude' 'kind=secondmate' 'mode=secondmate' \
  'yolo=off' 'model=opus' 'effort=high' 'home=/h' \
  'remote_host=box.example.invalid' 'remote_backend=herdr' \
  > "$H/state/sm-x1.meta"
note "The remote writer records the endpoint's backend under remote_backend=,"
note "and never writes backend= at all:"
grep -E '^(kind|mode|remote_backend|backend)=' "$H/state/sm-x1.meta" | sed 's/^/  /'
printf '\n$ fm-usage-ledger.sh record --event spawn --task sm-x1 --meta <that record>\n'
ledger "$H" record --event spawn --task sm-x1 --meta "$H/state/sm-x1.meta" 2>&1 | sed 's/^/  /'
ledger "$H" list | sed -n 's/.*"task":"sm-x1".*\("backend":"[^"]*"\).*/  recorded \1  (the endpoint runs herdr, not this fleet'"'"'s tmux)/p'
printf '\n'
H=$(home remote-backend-unproven)
printf '%s\n' 'window=remote:sm-x2' 'endpoint_task_id=sm-x2' 'worktree=/w' \
  'project=/p/nutricheck' 'harness=claude' 'kind=secondmate' 'mode=secondmate' \
  'yolo=off' 'model=opus' 'effort=high' 'home=/h' \
  'remote_host=box.example.invalid' > "$H/state/sm-x2.meta"
note "And when the remote writer proved no backend at all:"
ledger "$H" record --event spawn --task sm-x2 --meta "$H/state/sm-x2.meta" >/dev/null 2>&1
ledger "$H" list | sed -n 's/.*"task":"sm-x2".*\("backend":"[^"]*"\).*/  recorded \1  (unproven is stated, not guessed)/p'
printf '\n'

# --- 3. a status class that cannot be read is announced ----------------------
say "3. A status class that cannot be read is announced, never silently substituted"
D="$TMP_ROOT/status-class"; mkdir -p "$D"
cp "$WORKTREE/bin/fm-usage-ledger-lib.sh" "$D/"
cat > "$D/fm-usage-ledger.sh" <<'STUB'
#!/usr/bin/env bash
printf 'error: the task-usage ledger could not be started\n' >&2
exit 1
STUB
chmod 0755 "$D/fm-usage-ledger.sh"
H=$(home status-class); printf 'done: finished\n' > "$H/state/alpha-x1.status"
note "The schema owner is broken, so teardown's class lookup cannot run."
printf '$ fm_usage_ledger_status_class <home> <state> <data> <status log>\n'
set +e
( . "$D/fm-usage-ledger-lib.sh"
  fm_usage_ledger_status_class "$H" "$H/state" "$H/data" "$H/state/alpha-x1.status" \
) > "$D/out" 2> "$D/err"
printf '  exit=%s\n' "$?"
set -e
printf '  stdout: %s\n' "$(cat "$D/out")"
printf '  stderr:\n'
sed 's/^/    /' "$D/err"
note "The caller is never failed, the class reads unknown rather than a guess,"
note "the consequence is named, and the ledger's own diagnostic survives."
printf '\n'

# --- 4. what record reads vs what verify proves ------------------------------
say "4. The SAFETY contract: record reads what one append needs, verify proves the rest"
H=$(home malformed-middle)
printf '%s\n' 'window=w' 'worktree=/w' 'project=/p/acme-api' 'harness=codex' \
  'kind=ship' 'mode=direct-PR' 'yolo=on' 'model=gpt-5' 'effort=medium' \
  'spawn_gen=g9' > "$H/state/beta-x1.meta"
ledger "$H" record --event spawn --task beta-x1 --meta "$H/state/beta-x1.meta" >/dev/null
ledger "$H" record --event pr --task beta-x1 --meta "$H/state/beta-x1.meta" \
  --pr https://github.com/acme/acme-api/pull/7 >/dev/null
note "Something outside the ledger damages a record in the MIDDLE of the store:"
sed -i '2s/.*/{"v":1,"seq":2,"event":"spawn" TRUNCATED BY SOMETHING ELSE/' "$H/data/task-usage.jsonl"
printf '  line 2 is now: %s\n' "$(sed -n 2p "$H/data/task-usage.jsonl")"
printf '\n$ fm-usage-ledger.sh record --event cleanup --task beta-x1 ...\n'
set +e
ledger "$H" record --event cleanup --task beta-x1 --meta "$H/state/beta-x1.meta" \
  --outcome landed --status-class done 2>&1 | sed 's/^/  /'
printf '  exit=%s\n' "${PIPESTATUS[0]}"
printf '\n$ fm-usage-ledger.sh verify\n'
ledger "$H" verify 2>&1 | sed 's/^/  /'
printf '  exit=%s\n' "${PIPESTATUS[0]}"
set -e
note "record never reads that record, so the append still lands; verify is the"
note "verb that reads every record and finds the damage - exactly what the"
note "schema owner's SAFETY block now states."
printf '\n$ tail -c 400 of the store, showing the damaged line kept byte-for-byte\n'
sed -n '2p;$p' "$H/data/task-usage.jsonl" | cut -c1-140 | sed 's/^/  /'
} 2>&1 | scrub
