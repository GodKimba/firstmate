#!/usr/bin/env bash
# Behavior tests for bin/fm-crew-state.sh - the deterministic crew-current-state
# helper.
#
# The status file (state/<id>.status) is a best-effort append-only EVENT LOG, so
# `tail -1` of it reports the last event, not the current state. fm-crew-state
# reads the AUTHORITATIVE source (a matching no-mistakes run-step, else the
# semantic busy-state contract) and reconciles the possibly-stale log against it. These
# cases pin every branch of that logic, hermetically, over real throwaway git
# repos with a fake `no-mistakes` (run-step source) and a fake `tmux` (pane
# source):
#   (a) active run-step is authoritative                          -> run-step
#   (b) needs-decision/blocked log + resumed run = SUPERSEDED     -> run-step
#   (c) genuine parked run + needs-decision log = NOT superseded  -> run-step
#   (d) terminal run-step (passed/failed) is authoritative        -> run-step
#   (e) coarse and cross-branch run attribution retain the correct fallback
#   (f) no run + semantic busy                                    -> busy source
#   (g) no run + semantic idle falls to the status-log verb       -> status-log
#   (h) dead pane: no run -> unknown/none; with a run -> run-step (not the shell)
#   (i) kind=scout skips the run lookup                           -> pane/status-log
#   (j) torn-down worktree / missing meta                         -> unknown/none
#   (k) crew_is_provably_working end-to-end over the REAL helper (not a canned
#       fake fm-crew-state.sh verdict): detailed active status -> absorbed;
#       coarse running status or genuinely no run + idle pane -> surfaced.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=/dev/null
. "$ROOT/bin/fm-classify-lib.sh"

CREW_STATE="$ROOT/bin/fm-crew-state.sh"
TMP_ROOT=$(fm_test_tmproot fm-crew-state)
fm_git_identity fmtest fmtest@example.invalid

# A real git repo checked out on <branch>, so the helper's branch attribution
# (git symbolic-ref) resolves like it would for a live crew worktree.
make_repo_on_branch() {  # <dir> <branch>
  local dir=$1 branch=$2
  mkdir -p "$dir"
  git -C "$dir" init -q
  git -C "$dir" commit -q --allow-empty -m init
  git -C "$dir" checkout -q -b "$branch"
  # Real worktree HEAD for run head-binding (fixtures read FM_FAKE_RUN_HEAD).
  FM_FAKE_RUN_HEAD=$(git -C "$dir" rev-parse HEAD)
  export FM_FAKE_RUN_HEAD
}

set_no_mistakes_submission_ref() {  # <repo> <branch> [commit]
  local repo=$1 branch=$2 commit=${3:-HEAD}
  git -C "$repo" update-ref "refs/remotes/no-mistakes/$branch" "$commit"
}

# A fakebin with a fake `no-mistakes` (serves the env-driven run output) and a
# fake `tmux` (serves a busy or idle pane). The fake no-mistakes mirrors the real
# command surface the helper uses: `axi status`, `axi status --run <id>` (the
# `axi` surface - no runs-listing subcommand exists under it, verified against
# the real CLI), and the actual top-level run-listing command, `no-mistakes
# runs --limit N`, which is plain text - no run id, no quoting - serving
# FM_FAKE_RUNS_LIST verbatim.
make_fakebin() {  # <dir> -> echoes fakebin path
  local dir=$1 fb="$1/fakebin"
  mkdir -p "$fb"
  cat > "$fb/no-mistakes" <<'SH'
#!/usr/bin/env bash
set -u
case "${1:-}" in
  axi)
    shift
    case "${1:-}" in
      status)
        shift
        if [ "${1:-}" = --run ]; then printf '%s\n' "${FM_FAKE_AXI_STATUS_RUN:-}"
        else printf '%s\n' "${FM_FAKE_AXI_STATUS:-}"; fi ;;
      logs)
        printf '%s\n' "${FM_FAKE_CI_LOGS:-}" ;;
    esac
    ;;
  runs)
    printf '%s\n' "${FM_FAKE_RUNS_LIST:-}" ;;
esac
exit 0
SH
  cat > "$fb/tmux" <<'SH'
#!/usr/bin/env bash
set -u
case "${1:-}" in
  display-message)
    [ "${FM_FAKE_TMUX_MISSING:-0}" = 1 ] && exit 1
    printf '%%1\n' ;;
  capture-pane)
    [ "${FM_FAKE_TMUX_MISSING:-0}" = 1 ] && exit 1
    if [ "${FM_FAKE_BUSY:-0}" = 1 ]; then printf 'work in progress\n%s\n' "${FM_FAKE_BUSY_TEXT:-esc to interrupt}"
    else printf 'all quiet\n> \n'; fi ;;
esac
exit 0
SH
  cat > "$fb/herdr" <<'SH'
#!/usr/bin/env bash
set -u
case "${1:-}" in
  status)
    [ "${2:-}" = --json ] && {
      printf '{"client":{"version":"0.7.1","protocol":14},"server":{"running":true}}\n'
      exit 0
    } ;;
  server)
    exit 0 ;;
  pane)
    case "${2:-}" in
      read)
        [ "${FM_FAKE_HERDR_MISSING:-0}" = 1 ] && exit 1
        if [ "${FM_FAKE_HERDR_BUSY:-0}" = 1 ]; then printf 'work in progress\nesc to interrupt\n'
        else printf 'all quiet\n> \n'; fi
        exit 0 ;;
    esac ;;
  agent)
    case "${2:-}" in
      get)
        [ -n "${FM_FAKE_HERDR_AGENT_STATUS:-}" ] || exit 1
        printf '{"result":{"agent":{"agent_status":"%s"}}}\n' "$FM_FAKE_HERDR_AGENT_STATUS"
        exit 0 ;;
    esac ;;
esac
exit 0
SH
  # Fake `gh` for the forge check-run probe behind every green-ready verdict.
  # Mirrors the real surface the helper uses - `gh pr view <url> --json
  # statusCheckRollup -q <jq>` with gh's builtin jq evaluating the classifier.
  # FM_FAKE_GH_CONCLUSION verifies that the query classifies one raw conclusion;
  # otherwise FM_FAKE_GH_CHECKS serves an already-classified token. Empty means
  # the probe itself fails, which must read as unreadable rather than green.
  cat > "$fb/gh" <<'SH'
#!/usr/bin/env bash
set -u
printf '%s\n' "$*" >> "${FM_FAKE_GH_CALLS:-/dev/null}"
[ "${FM_FAKE_GH_SLEEP:-0}" = 1 ] && sleep 30
if [ -n "${FM_FAKE_GH_CONCLUSION:-}" ]; then
  case "$*" in
    *"$FM_FAKE_GH_CONCLUSION"*) printf 'failing\n' ;;
    *) printf 'passing\n' ;;
  esac
  exit 0
fi
[ -n "${FM_FAKE_GH_CHECKS:-}" ] || exit 1
printf '%s\n' "$FM_FAKE_GH_CHECKS"
SH
  chmod +x "$fb/no-mistakes" "$fb/tmux" "$fb/herdr" "$fb/gh"
  printf '%s\n' "$fb"
}

make_no_timeout_toolbin() {  # <dir> -> echoes toolbin path
  local dir=$1 tb="$1/notimeoutbin" tool real
  mkdir -p "$tb"
  for tool in bash git grep sed head cut tail dirname perl; do
    real=$(command -v "$tool" || true)
    [ -n "$real" ] || fail "missing tool for no-timeout path: $tool"
    ln -s "$real" "$tb/$tool"
  done
  printf '%s\n' "$tb"
}

# Run the helper for one case dir. FM_FAKE_* env (run output, busy flag) are read
# from the caller's environment by the fakes above.
run_crew_state() {  # <case-dir> <id>
  PATH="$1/fakebin:$PATH" FM_STATE_OVERRIDE="$1/state" "$CREW_STATE" "$2"
}

new_case() {  # <name> -> echoes case dir with an empty state/
  local d="$TMP_ROOT/$1"
  mkdir -p "$d/state"
  printf '%s\n' "$d"
}

arm_idle_record() {  # <state-dir> <id>
  local state=$1 id=$2 gen
  gen=$("$ROOT/bin/fm-busy-event.sh" arm "$state" "$id")
  "$ROOT/bin/fm-busy-event.sh" apply "$state" "$id" idle --gen "$gen" \
    --source claude-hook --event stop
}

# Clear the fake-driver vars and (re-)mark them exported, so the per-test plain
# assignments below stay exported into the fakes without an `export VAR=$(...)`
# command-substitution assignment (SC2155).
reset_fakes() {
  FM_FAKE_AXI_STATUS=""
  FM_FAKE_AXI_STATUS_RUN=""
  FM_FAKE_RUNS_LIST=""
  FM_FAKE_BUSY=0
  FM_FAKE_BUSY_TEXT=
  FM_FAKE_TMUX_MISSING=0
  FM_FAKE_HERDR_BUSY=0
  FM_FAKE_HERDR_MISSING=0
  FM_FAKE_HERDR_AGENT_STATUS=""
  FM_FAKE_CI_LOGS=""
  # Green checks by default, so the many pre-existing cases that only exercise
  # run-step logic keep reading the pipeline signal they were written for. Each
  # zero-check/pending/failing/unreadable case sets its own value.
  FM_FAKE_GH_CHECKS=passing
  FM_FAKE_GH_CALLS=""
  FM_FAKE_GH_SLEEP=0
  FM_FAKE_GH_CONCLUSION=""
  export FM_FAKE_AXI_STATUS FM_FAKE_AXI_STATUS_RUN FM_FAKE_RUNS_LIST FM_FAKE_BUSY FM_FAKE_BUSY_TEXT FM_FAKE_TMUX_MISSING
  export FM_FAKE_HERDR_BUSY FM_FAKE_HERDR_MISSING FM_FAKE_HERDR_AGENT_STATUS FM_FAKE_CI_LOGS
  export FM_FAKE_GH_CHECKS FM_FAKE_GH_CALLS FM_FAKE_GH_SLEEP FM_FAKE_GH_CONCLUSION
}

# --- run-object fixtures (TOON, as `no-mistakes axi status` emits) -----------

run_running() {  # <branch>
  cat <<EOF
run:
  id: "01RUN"
  branch: $1
  status: running
  head: "${FM_FAKE_RUN_HEAD:-abc1234}"
  pr: ""
  findings: none
  steps[2]{step,status,findings,duration_ms}:
    intent,completed,0,0
    review,running,0,0
EOF
}

run_fixing() {  # <branch>
  cat <<EOF
run:
  id: "01RUN"
  branch: $1
  status: fixing
  head: "${FM_FAKE_RUN_HEAD:-abc1234}"
  pr: ""
  findings: none
EOF
}

run_top_level_ci() {  # <branch>
  cat <<EOF
run:
  id: "01RUN"
  branch: $1
  status: ci
  head: "${FM_FAKE_RUN_HEAD:-abc1234}"
  pr: "https://github.com/o/r/pull/2"
  findings: none
EOF
}

run_parked() {  # <branch>
  cat <<EOF
run:
  id: "01RUN"
  branch: $1
  status: awaiting_approval
  awaiting_agent: parked 2m10s
  head: "${FM_FAKE_RUN_HEAD:-abc1234}"
  pr: ""
  findings[2]{id,severity,file,line,action,description}:
    r1,warning,a.go,,auto-fix,ignored error
    r2,error,b.go,,ask-user,changes product behavior
gate: review
EOF
}

run_parked_scalar_gate_running() {  # <branch>
  cat <<EOF
run:
  id: "01RUN"
  branch: $1
  status: running
  head: "${FM_FAKE_RUN_HEAD:-abc1234}"
  pr: ""
  findings[1]{id,severity,file,line,action,description}:
    r1,error,b.go,,ask-user,changes product behavior
gate: review
EOF
}

run_parked_in_gate_block() {  # <branch>
  cat <<EOF
run:
  id: "01RUN"
  branch: $1
  status: running
  head: "${FM_FAKE_RUN_HEAD:-abc1234}"
  pr: ""
  findings[1]{id,severity,file,line,action,description}:
    r1,error,b.go,,ask-user,changes product behavior
gate:
  step: review
  status: fix_review
steps[3]{step,status,findings,duration_ms}:
  intent,completed,0,0
  review,fix_review,1,0
  test,pending,0,0
EOF
}

run_passed() {  # <branch>
  cat <<EOF
run:
  id: "01RUN"
  branch: $1
  status: completed
  head: "${FM_FAKE_RUN_HEAD:-abc1234}"
  pr: "https://github.com/o/r/pull/1"
  findings: none
outcome: passed
EOF
}

run_failed() {  # <branch>
  cat <<EOF
run:
  id: "01RUN"
  branch: $1
  status: completed
  head: "${FM_FAKE_RUN_HEAD:-abc1234}"
  pr: ""
  findings: none
outcome: failed
EOF
}

run_checks_passed() {  # <branch>
  cat <<EOF
run:
  id: "01RUN"
  branch: $1
  status: completed
  head: "${FM_FAKE_RUN_HEAD:-abc1234}"
  pr: "https://github.com/o/r/pull/2"
  findings: none
outcome: checks-passed
EOF
}

run_ci_monitoring() {  # <branch>
  cat <<EOF
run:
  id: "01RUN"
  branch: $1
  status: running
  head: "${FM_FAKE_RUN_HEAD:-abc1234}"
  pr: "https://github.com/o/r/pull/2"
  findings: none
  steps[4]{step,status,findings,duration_ms}:
    intent,completed,0,0
    review,completed,0,0
    push,completed,0,0
    ci,running,0,0
EOF
}

run_fixing_ci_running() {  # <branch>
  cat <<EOF
run:
  id: "01RUN"
  branch: $1
  status: fixing
  head: "${FM_FAKE_RUN_HEAD:-abc1234}"
  pr: "https://github.com/o/r/pull/2"
  findings: none
  steps[4]{step,status,findings,duration_ms}:
    intent,completed,0,0
    review,completed,0,0
    push,completed,0,0
    ci,running,0,0
EOF
}

run_ci_fixing() {  # <branch>
  cat <<EOF
run:
  id: "01RUN"
  branch: $1
  status: fixing
  head: "${FM_FAKE_RUN_HEAD:-abc1234}"
  pr: "https://github.com/o/r/pull/2"
  findings: none
  steps[4]{step,status,findings,duration_ms}:
    intent,completed,0,0
    review,completed,0,0
    push,completed,0,0
    ci,fixing,0,0
EOF
}

# ---------------------------------------------------------------------------
# (a) active run-step is authoritative
test_active_run_is_authoritative() {
  reset_fakes
  local d; d=$(new_case active)
  make_repo_on_branch "$d/wt" fm/feat-a
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/feat-a.meta" "window=fm:fm-feat-a" "worktree=$d/wt" "kind=ship"
  FM_FAKE_AXI_STATUS="$(run_running fm/feat-a)"
  local out; out=$(run_crew_state "$d" feat-a)
  assert_contains "$out" "state: working" "active run -> working"
  assert_contains "$out" "source: run-step" "active run -> run-step source"
  assert_contains "$out" "validating (running)" "active run reports the step"
  pass "active run-step is authoritative"
}

# (b) needs-decision log + a resumed (running/fixing) run = SUPERSEDED
test_stale_needs_decision_superseded() {
  reset_fakes
  local d; d=$(new_case superseded)
  make_repo_on_branch "$d/wt" fm/feat-b
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/feat-b.meta" "window=fm:fm-feat-b" "worktree=$d/wt" "kind=ship"
  printf 'working: started\nneeds-decision: pick A or B\n' > "$d/state/feat-b.status"
  FM_FAKE_AXI_STATUS="$(run_fixing fm/feat-b)"
  local out; out=$(run_crew_state "$d" feat-b)
  assert_contains "$out" "state: working" "resumed run -> working despite needs-decision log"
  assert_contains "$out" "source: run-step" "resumed run -> run-step source"
  assert_contains "$out" "superseded" "stale needs-decision log flagged superseded"
  pass "stale needs-decision over active run is superseded"
}

# blocked log + a resumed run is also superseded
test_stale_blocked_superseded() {
  reset_fakes
  local d; d=$(new_case superseded-blocked)
  make_repo_on_branch "$d/wt" fm/feat-bb
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/feat-bb.meta" "window=fm:fm-feat-bb" "worktree=$d/wt" "kind=ship"
  printf 'blocked: waiting on review answer\n' > "$d/state/feat-bb.status"
  FM_FAKE_AXI_STATUS="$(run_running fm/feat-bb)"
  local out; out=$(run_crew_state "$d" feat-bb)
  assert_contains "$out" "state: working" "resumed run -> working despite blocked log"
  assert_contains "$out" "superseded" "stale blocked log flagged superseded"
  pass "stale blocked over active run is superseded"
}

# (c) genuine parked run + needs-decision log AGREE -> parked, NOT superseded
test_genuine_parked_not_superseded() {
  reset_fakes
  local d; d=$(new_case parked)
  make_repo_on_branch "$d/wt" fm/feat-c
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/feat-c.meta" "window=fm:fm-feat-c" "worktree=$d/wt" "kind=ship"
  printf 'needs-decision: review gate\n' > "$d/state/feat-c.status"
  FM_FAKE_AXI_STATUS="$(run_parked fm/feat-c)"
  local out; out=$(run_crew_state "$d" feat-c)
  assert_contains "$out" "state: parked" "genuine parked run -> parked"
  assert_contains "$out" "source: run-step" "parked -> run-step source"
  assert_contains "$out" "2 finding(s)" "parked includes gate finding count"
  assert_contains "$out" "ask-user" "parked surfaces ask-user finding"
  assert_not_contains "$out" "superseded" "agreeing parked+needs-decision not flagged stale"
  pass "genuine parked run is not flagged superseded"
}

test_scalar_gate_parked_not_superseded() {
  reset_fakes
  local d; d=$(new_case parked-scalar-gate)
  make_repo_on_branch "$d/wt" fm/feat-cs
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/feat-cs.meta" "window=fm:fm-feat-cs" "worktree=$d/wt" "kind=ship"
  printf 'needs-decision: review gate\n' > "$d/state/feat-cs.status"
  FM_FAKE_AXI_STATUS="$(run_parked_scalar_gate_running fm/feat-cs)"
  local out; out=$(run_crew_state "$d" feat-cs)
  assert_contains "$out" "state: parked" "scalar gate wait -> parked"
  assert_contains "$out" "source: run-step" "scalar gate wait -> run-step source"
  assert_contains "$out" "parked at review" "scalar gate wait names the gate"
  assert_contains "$out" "1 finding(s)" "scalar gate wait includes finding count"
  assert_not_contains "$out" "superseded" "scalar gate wait not flagged stale"
  pass "scalar gate parked run is not flagged superseded"
}

test_gate_block_parked_not_superseded() {
  reset_fakes
  local d; d=$(new_case parked-gate-block)
  make_repo_on_branch "$d/wt" fm/feat-cb
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/feat-cb.meta" "window=fm:fm-feat-cb" "worktree=$d/wt" "kind=ship"
  printf 'needs-decision: review gate\n' > "$d/state/feat-cb.status"
  FM_FAKE_AXI_STATUS="$(run_parked_in_gate_block fm/feat-cb)"
  local out; out=$(run_crew_state "$d" feat-cb)
  assert_contains "$out" "state: parked" "gate block wait -> parked"
  assert_contains "$out" "source: run-step" "gate block wait -> run-step source"
  assert_contains "$out" "parked at review" "gate block wait names the gate"
  assert_contains "$out" "1 finding(s)" "gate block wait includes finding count"
  assert_not_contains "$out" "superseded" "gate block wait not flagged stale"
  pass "gate block parked run is not flagged superseded"
}

test_ci_ready_done_log_beats_monitoring_run() {
  reset_fakes
  local d; d=$(new_case ci-ready)
  make_repo_on_branch "$d/wt" fm/feat-ci
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/feat-ci.meta" "window=fm:fm-feat-ci" "worktree=$d/wt" "kind=ship"
  printf 'done: PR https://github.com/o/r/pull/2 checks green\n' > "$d/state/feat-ci.status"
  FM_FAKE_AXI_STATUS="$(run_ci_monitoring fm/feat-ci)"
  local out; out=$(run_crew_state "$d" feat-ci)
  assert_contains "$out" "state: done" "ci-ready status log -> done"
  assert_contains "$out" "source: status-log" "ci-ready state comes from the status log"
  assert_contains "$out" "checks green" "ci-ready detail preserves the report"
  assert_not_contains "$out" "state: working" "ci-ready is not hidden by monitoring run"
  pass "ci-ready status log beats monitoring run"
}

# Regression for the PR #252 incident: the crew's own status log never got a
# "done: ... checks green" line (log_reports_ci_ready above does not apply),
# but the ci step's log tail shows CI is actually green and only waiting on
# merge/close. fm-crew-state must surface this as done, not "validating
# (running)", so a green PR is never silently absorbed as still-in-progress.
test_ci_monitoring_checks_green_surfaces_done() {
  reset_fakes
  local d; d=$(new_case ci-green)
  make_repo_on_branch "$d/wt" fm/feat-cigreen
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/feat-cigreen.meta" "window=fm:fm-feat-cigreen" "worktree=$d/wt" "kind=ship"
  # No status-log line at all: the crew never reported its own checks-green line.
  FM_FAKE_AXI_STATUS="$(run_ci_monitoring fm/feat-cigreen)"
  FM_FAKE_CI_LOGS=$(cat <<'EOF'
CI checks running, waiting for results...
all CI checks passed - still monitoring until merged or closed
EOF
)
  local out; out=$(run_crew_state "$d" feat-cigreen)
  assert_contains "$out" "state: done" "green ci-monitor run -> done"
  assert_contains "$out" "source: run-step" "green ci-monitor -> run-step source"
  assert_contains "$out" "checks green" "green ci-monitor detail mentions checks green"
  assert_not_contains "$out" "state: working" "green ci-monitor must not read as still validating"
  pass "ci-monitoring run with checks already green surfaces done"
}

test_top_level_ci_checks_green_surfaces_done() {
  reset_fakes
  local d; d=$(new_case top-level-ci-green)
  make_repo_on_branch "$d/wt" fm/feat-topcigreen
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/feat-topcigreen.meta" "window=fm:fm-feat-topcigreen" "worktree=$d/wt" "kind=ship"
  FM_FAKE_AXI_STATUS="$(run_top_level_ci fm/feat-topcigreen)"
  FM_FAKE_CI_LOGS="all CI checks passed - still monitoring until merged or closed"
  local out; out=$(run_crew_state "$d" feat-topcigreen)
  assert_contains "$out" "state: done" "top-level ci with green log -> done"
  assert_contains "$out" "source: run-step" "top-level ci green -> run-step source"
  assert_contains "$out" "checks green" "top-level ci green detail mentions checks green"
  assert_not_contains "$out" "state: working" "top-level ci green must not stay working"
  pass "top-level ci status uses ci log green marker"
}

# Firstmate PRs #7 and #8 (2026-07) were reported as checks green while GitHub
# held zero check-runs: no-mistakes enters its merge-monitor phase on the
# "no CI checks reported" marker exactly as it does on a real green one, so
# that marker alone read as green here. It states the opposite of green, and
# must never produce a ready verdict.
test_ci_monitoring_no_checks_marker_stays_working() {
  reset_fakes
  local d; d=$(new_case ci-nochecks)
  make_repo_on_branch "$d/wt" fm/feat-cinochecks
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/feat-cinochecks.meta" "window=fm:fm-feat-cinochecks" "worktree=$d/wt" "kind=ship" "mode=no-mistakes"
  FM_FAKE_AXI_STATUS="$(run_ci_monitoring fm/feat-cinochecks)"
  FM_FAKE_CI_LOGS="no CI checks reported - still monitoring until merged or closed"
  local out; out=$(run_crew_state "$d" feat-cinochecks)
  assert_contains "$out" "state: working" "no-checks ci-monitor marker -> working"
  assert_not_contains "$out" "state: done" "no-checks ci-monitor marker must not read as done"
  assert_not_contains "$out" "checks green" "no-checks ci-monitor marker must not claim checks green"
  pass "the no-checks ci-monitor marker never surfaces as a green-ready done"
}

# The forge is the evidence, not the pipeline's reading of it. A green ci
# marker with zero check-runs on GitHub is the same contradiction reached from
# the other side, and stays working.
test_ci_green_marker_with_zero_check_runs_stays_working() {
  reset_fakes
  local d; d=$(new_case ci-green-zero-runs)
  make_repo_on_branch "$d/wt" fm/feat-cizeroruns
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/feat-cizeroruns.meta" "window=fm:fm-feat-cizeroruns" "worktree=$d/wt" "kind=ship" "mode=no-mistakes"
  FM_FAKE_AXI_STATUS="$(run_ci_monitoring fm/feat-cizeroruns)"
  FM_FAKE_CI_LOGS="all CI checks passed - still monitoring until merged or closed"
  FM_FAKE_GH_CHECKS=none
  local out; out=$(run_crew_state "$d" feat-cizeroruns)
  assert_contains "$out" "state: working" "zero check runs -> working"
  assert_not_contains "$out" "state: done" "zero check runs must not read as done"
  assert_not_contains "$out" "checks green" "zero check runs must not claim checks green"
  assert_contains "$out" "no check runs reported" "zero check runs names the missing evidence"
  pass "a green ci marker with zero forge check runs stays working"
}

test_ci_green_marker_with_pending_checks_stays_working() {
  reset_fakes
  local d; d=$(new_case ci-green-pending)
  make_repo_on_branch "$d/wt" fm/feat-cipending
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/feat-cipending.meta" "window=fm:fm-feat-cipending" "worktree=$d/wt" "kind=ship" "mode=no-mistakes"
  FM_FAKE_AXI_STATUS="$(run_ci_monitoring fm/feat-cipending)"
  FM_FAKE_CI_LOGS="all CI checks passed - still monitoring until merged or closed"
  FM_FAKE_GH_CHECKS=pending
  local out; out=$(run_crew_state "$d" feat-cipending)
  assert_contains "$out" "state: working" "pending checks -> working"
  assert_not_contains "$out" "state: done" "pending checks must not read as done"
  assert_contains "$out" "checks still running" "pending checks name the wait"
  pass "a green ci marker with still-running forge checks stays working"
}

test_ci_green_marker_with_failing_checks_stays_working() {
  reset_fakes
  local d; d=$(new_case ci-green-failing)
  make_repo_on_branch "$d/wt" fm/feat-cifailing
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/feat-cifailing.meta" "window=fm:fm-feat-cifailing" "worktree=$d/wt" "kind=ship" "mode=no-mistakes"
  FM_FAKE_AXI_STATUS="$(run_ci_monitoring fm/feat-cifailing)"
  FM_FAKE_CI_LOGS="all CI checks passed - still monitoring until merged or closed"
  FM_FAKE_GH_CHECKS=failing
  local out; out=$(run_crew_state "$d" feat-cifailing)
  assert_contains "$out" "state: working" "failing checks -> working"
  assert_not_contains "$out" "state: done" "failing checks must not read as done"
  assert_contains "$out" "a check failed" "failing checks name the failure"
  pass "a green ci marker with a failing forge check stays working"
}

test_ci_green_marker_with_startup_failure_stays_working() {
  reset_fakes
  local d; d=$(new_case ci-green-startup-failure)
  make_repo_on_branch "$d/wt" fm/feat-cistartupfailure
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/feat-cistartupfailure.meta" "window=fm:fm-feat-cistartupfailure" "worktree=$d/wt" "kind=ship" "mode=no-mistakes"
  FM_FAKE_AXI_STATUS="$(run_ci_monitoring fm/feat-cistartupfailure)"
  FM_FAKE_CI_LOGS="all CI checks passed - still monitoring until merged or closed"
  FM_FAKE_GH_CONCLUSION=STARTUP_FAILURE
  local out; out=$(run_crew_state "$d" feat-cistartupfailure)
  assert_contains "$out" "state: working" "startup-failed check -> working"
  assert_not_contains "$out" "state: done" "startup-failed check must not read as done"
  assert_contains "$out" "a check failed" "startup-failed check names the failure"
  pass "a startup-failed forge check stays working"
}

test_ci_green_marker_with_stale_check_stays_working() {
  reset_fakes
  local d; d=$(new_case ci-green-stale)
  make_repo_on_branch "$d/wt" fm/feat-cistale
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/feat-cistale.meta" "window=fm:fm-feat-cistale" "worktree=$d/wt" "kind=ship" "mode=no-mistakes"
  FM_FAKE_AXI_STATUS="$(run_ci_monitoring fm/feat-cistale)"
  FM_FAKE_CI_LOGS="all CI checks passed - still monitoring until merged or closed"
  FM_FAKE_GH_CONCLUSION=STALE
  local out; out=$(run_crew_state "$d" feat-cistale)
  assert_contains "$out" "state: working" "stale check -> working"
  assert_not_contains "$out" "state: done" "stale check must not read as done"
  assert_contains "$out" "a check failed" "stale check names the failure"
  pass "a stale forge check stays working"
}

# An unreadable probe (auth expired, network down, the PR gone) is not evidence
# either. Absence of a verdict must never become a green one.
test_ci_green_marker_with_unreadable_checks_stays_working() {
  reset_fakes
  local d; d=$(new_case ci-green-unreadable)
  make_repo_on_branch "$d/wt" fm/feat-ciunreadable
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/feat-ciunreadable.meta" "window=fm:fm-feat-ciunreadable" "worktree=$d/wt" "kind=ship" "mode=no-mistakes"
  FM_FAKE_AXI_STATUS="$(run_ci_monitoring fm/feat-ciunreadable)"
  FM_FAKE_CI_LOGS="all CI checks passed - still monitoring until merged or closed"
  FM_FAKE_GH_CHECKS=""   # the probe itself fails
  local out; out=$(run_crew_state "$d" feat-ciunreadable)
  assert_contains "$out" "state: working" "unreadable checks -> working"
  assert_not_contains "$out" "state: done" "unreadable checks must not read as done"
  assert_contains "$out" "check state unreadable" "unreadable checks name the missing read"
  pass "a green ci marker with an unreadable forge answer stays working"
}

# The crew's own "done: PR ... checks green" line is a report written from the
# same reading, so it cannot stand alone either.
test_ci_ready_done_log_with_zero_check_runs_stays_working() {
  reset_fakes
  local d; d=$(new_case ci-ready-zero-runs)
  make_repo_on_branch "$d/wt" fm/feat-cireadyzero
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/feat-cireadyzero.meta" "window=fm:fm-feat-cireadyzero" "worktree=$d/wt" "kind=ship" "mode=no-mistakes"
  printf 'done: PR https://github.com/o/r/pull/2 checks green\n' > "$d/state/feat-cireadyzero.status"
  FM_FAKE_AXI_STATUS="$(run_ci_monitoring fm/feat-cireadyzero)"
  FM_FAKE_CI_LOGS="all CI checks passed - still monitoring until merged or closed"
  FM_FAKE_GH_CHECKS=none
  local out; out=$(run_crew_state "$d" feat-cireadyzero)
  assert_contains "$out" "state: working" "a checks-green report with zero check runs -> working"
  assert_contains "$out" "source: run-step" "the withheld report remains run-step sourced"
  assert_not_contains "$out" "state: done" "a status line alone must not claim green"
  assert_contains "$out" "no check runs reported" "the withheld report names the missing evidence"
  pass "a checks-green status line cannot claim green without forge evidence"
}

# Same for the coarse path, where no run detail exists to corroborate at all.
test_coarse_ci_ready_done_log_with_zero_check_runs_stays_working() {
  reset_fakes
  local d short; d=$(new_case coarse-ready-zero-runs)
  make_repo_on_branch "$d/wt" fm/feat-coarsezero
  short=$(git -C "$d/wt" rev-parse --short=7 HEAD)
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/feat-coarsezero.meta" "window=fm:fm-feat-coarsezero" "worktree=$d/wt" "kind=ship" "mode=no-mistakes" "pr=https://github.com/o/r/pull/4"
  printf 'done: PR https://github.com/o/r/pull/4 checks green\n' > "$d/state/feat-coarsezero.status"
  FM_FAKE_AXI_STATUS="$(run_ci_monitoring fm/other-crew)"
  FM_FAKE_RUNS_LIST="$(cat <<EOF
  running    fm/other-crew aaaaaaa  2026-07-02 22:10
  running    fm/feat-coarsezero ${short}  2026-07-02 22:05
EOF
)"
  FM_FAKE_GH_CHECKS=none
  local out; out=$(run_crew_state "$d" feat-coarsezero)
  assert_contains "$out" "state: working" "coarse checks-green report with zero check runs -> working"
  assert_not_contains "$out" "state: done" "coarse path must not claim green from the log alone"
  assert_contains "$out" "no check runs reported" "coarse withheld report names the missing evidence"
  pass "the coarse ready path also requires forge evidence"
}

test_no_run_ci_ready_done_log_with_zero_check_runs_stays_working() {
  reset_fakes
  local d absorb; d=$(new_case no-run-ready-zero-runs)
  make_repo_on_branch "$d/wt" fm/feat-norunzero
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/feat-norunzero.meta" "window=fm:fm-feat-norunzero" "worktree=$d/wt" "kind=ship" "mode=no-mistakes"
  printf 'done: PR https://github.com/o/r/pull/5 checks green\n' > "$d/state/feat-norunzero.status"
  FM_FAKE_GH_CHECKS=none
  local out; out=$(run_crew_state "$d" feat-norunzero)
  assert_contains "$out" "state: working" "no-run checks-green report with zero check runs -> working"
  assert_contains "$out" "source: ci-withheld" "no-run withheld report uses its trusted wait source"
  assert_not_contains "$out" "state: done" "no-run status line must not claim green without evidence"
  assert_contains "$out" "no check runs reported" "no-run withheld report names the missing evidence"
  absorb=$(PATH="$d/fakebin:$PATH" FM_STATE_OVERRIDE="$d/state" crew_absorb_class feat-norunzero)
  [ "$absorb" = working ] || fail "no-run withheld CI wait was not classed absorbable"
  printf 'working: ordinary uncorroborated progress note\n' > "$d/state/feat-norunzero.status"
  absorb=$(PATH="$d/fakebin:$PATH" FM_STATE_OVERRIDE="$d/state" crew_absorb_class feat-norunzero)
  [ "$absorb" = none ] || fail "plain status-log working event became absorbable"
  pass "the no-run ready path requires evidence and remains wedge-monitored"
}

test_cross_branch_no_run_ci_ready_uses_task_pr() {
  reset_fakes
  local d calls; d=$(new_case cross-branch-ready-task-pr)
  make_repo_on_branch "$d/wt" fm/feat-taskpr
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/feat-taskpr.meta" "window=fm:fm-feat-taskpr" "worktree=$d/wt" "kind=ship" "mode=no-mistakes" "pr=https://github.com/o/r/pull/8"
  printf 'done: PR https://github.com/o/r/pull/8 checks green\n' > "$d/state/feat-taskpr.status"
  FM_FAKE_AXI_STATUS="$(run_ci_monitoring fm/other-crew | sed 's#https://github.com/o/r/pull/2#https://gitlab.example.com/other/repo/-/merge_requests/2#')"
  FM_FAKE_RUNS_LIST="  running    fm/other-crew aaaaaaa  2026-07-02 22:10"
  FM_FAKE_GH_CHECKS=none
  FM_FAKE_GH_CALLS="$d/gh.calls"
  : > "$FM_FAKE_GH_CALLS"
  local out; out=$(run_crew_state "$d" feat-taskpr)
  assert_contains "$out" "state: working" "cross-branch no-run task with zero checks -> working"
  assert_contains "$out" "source: ci-withheld" "cross-branch withheld task remains wedge-monitored"
  calls=$(cat "$FM_FAKE_GH_CALLS")
  assert_contains "$calls" "pr view https://github.com/o/r/pull/8" "probe did not use this task's metadata PR"
  assert_not_contains "$calls" "gitlab.example.com/other/repo" "probe used another task's PR"
  pass "cross-branch fallback corroborates only this task's PR"
}

test_no_run_direct_pr_mode_keeps_its_ready_signal() {
  reset_fakes
  local d calls; d=$(new_case no-run-direct-pr-ready)
  make_repo_on_branch "$d/wt" fm/feat-norundirectpr
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/feat-norundirectpr.meta" "window=fm:fm-feat-norundirectpr" "worktree=$d/wt" "kind=ship" "mode=direct-PR"
  printf 'done: PR https://github.com/o/r/pull/5 checks green\n' > "$d/state/feat-norundirectpr.status"
  FM_FAKE_GH_CHECKS=none
  FM_FAKE_GH_CALLS="$d/gh.calls"
  : > "$FM_FAKE_GH_CALLS"
  local out; out=$(run_crew_state "$d" feat-norundirectpr)
  assert_contains "$out" "state: done" "no-run direct-PR ready signal is unchanged"
  assert_contains "$out" "source: status-log" "no-run direct-PR remains status-log sourced"
  assert_contains "$out" "checks green" "no-run direct-PR keeps its reported detail"
  calls=$(awk 'END { print NR + 0 }' "$FM_FAKE_GH_CALLS" 2>/dev/null || echo 0)
  [ "$calls" -eq 0 ] || fail "no-run direct-PR mode probed the forge for checks ($calls calls)"
  pass "no-run direct-PR keeps its ready signal and makes no forge call"
}

test_no_run_current_busy_supersedes_old_ready_signal() {
  reset_fakes
  local d gen out; d=$(new_case no-run-busy-after-ready)
  make_repo_on_branch "$d/wt" fm/feat-norunbusyready
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/feat-norunbusyready.meta" \
    "window=fm:fm-feat-norunbusyready" "worktree=$d/wt" "kind=ship" \
    "mode=direct-PR" "harness=claude"
  printf 'done: PR https://github.com/o/r/pull/5 checks green\n' > "$d/state/feat-norunbusyready.status"
  gen=$("$ROOT/bin/fm-busy-event.sh" arm "$d/state" feat-norunbusyready)
  "$ROOT/bin/fm-busy-event.sh" apply "$d/state" feat-norunbusyready busy --gen "$gen" \
    --source claude-hook --event user-prompt-submit
  out=$(run_crew_state "$d" feat-norunbusyready)
  assert_contains "$out" "state: working" "current semantic busy state -> working"
  assert_contains "$out" "source: pane" "current semantic busy state remains the source"
  assert_not_contains "$out" "state: done" "old ready report must not supersede current busy state"
  pass "a current exact busy transition supersedes an old ready report"
}

# The pipeline's own terminal "validated, CI green, not merged yet" outcome is
# set from that same monitor reading, so it is corroborated too.
test_checks_passed_outcome_with_zero_check_runs_stays_working() {
  reset_fakes
  local d; d=$(new_case checks-passed-zero-runs)
  make_repo_on_branch "$d/wt" fm/feat-cpzero
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/feat-cpzero.meta" "window=fm:fm-feat-cpzero" "worktree=$d/wt" "kind=ship" "mode=no-mistakes"
  FM_FAKE_AXI_STATUS="$(run_checks_passed fm/feat-cpzero)"
  FM_FAKE_GH_CHECKS=none
  local out; out=$(run_crew_state "$d" feat-cpzero)
  assert_contains "$out" "state: working" "checks-passed outcome with zero check runs -> working"
  assert_not_contains "$out" "state: done" "checks-passed outcome must not read as done without evidence"
  assert_contains "$out" "no check runs reported" "checks-passed outcome names the missing evidence"
  pass "a checks-passed outcome with zero forge check runs stays working"
}

test_checks_passed_outcome_with_green_checks_surfaces_done() {
  reset_fakes
  local d; d=$(new_case checks-passed-green)
  make_repo_on_branch "$d/wt" fm/feat-cpgreen
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/feat-cpgreen.meta" "window=fm:fm-feat-cpgreen" "worktree=$d/wt" "kind=ship" "mode=no-mistakes"
  FM_FAKE_AXI_STATUS="$(run_checks_passed fm/feat-cpgreen)"
  FM_FAKE_GH_CHECKS=passing
  local out; out=$(run_crew_state "$d" feat-cpgreen)
  assert_contains "$out" "state: done" "checks-passed outcome with real green checks -> done"
  assert_contains "$out" "source: run-step" "corroborated checks-passed remains run-step sourced"
  assert_contains "$out" "checks green" "corroborated checks-passed reports checks green"
  pass "a checks-passed outcome with real green checks still surfaces done"
}

# direct-PR opens a PR as its ready signal and never runs this pipeline, so the
# gate must not invent a CI requirement for it - or reach the forge at all.
test_direct_pr_mode_keeps_its_ready_signal() {
  reset_fakes
  local d calls; d=$(new_case direct-pr-ready)
  make_repo_on_branch "$d/wt" fm/feat-directpr
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/feat-directpr.meta" "window=fm:fm-feat-directpr" "worktree=$d/wt" "kind=ship" "mode=direct-PR"
  printf 'done: PR https://github.com/o/r/pull/2 checks green\n' > "$d/state/feat-directpr.status"
  FM_FAKE_AXI_STATUS="$(run_ci_monitoring fm/feat-directpr)"
  FM_FAKE_CI_LOGS="all CI checks passed - still monitoring until merged or closed"
  FM_FAKE_GH_CHECKS=none
  FM_FAKE_GH_CALLS="$d/gh.calls"
  : > "$FM_FAKE_GH_CALLS"
  local out; out=$(run_crew_state "$d" feat-directpr)
  assert_contains "$out" "state: done" "direct-PR ready signal is unchanged"
  assert_contains "$out" "checks green" "direct-PR keeps its own reported detail"
  calls=$(awk 'END { print NR + 0 }' "$FM_FAKE_GH_CALLS" 2>/dev/null || echo 0)
  [ "$calls" -eq 0 ] || fail "direct-PR mode probed the forge for checks ($calls calls)"
  pass "direct-PR keeps its ready signal and gains no CI requirement"
}

# local-only lands from a clean branch with no PR at all; same non-requirement.
test_local_only_mode_keeps_its_ready_signal() {
  reset_fakes
  local d calls; d=$(new_case local-only-ready)
  make_repo_on_branch "$d/wt" fm/feat-localonly
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/feat-localonly.meta" "window=fm:fm-feat-localonly" "worktree=$d/wt" "kind=ship" "mode=local-only"
  FM_FAKE_AXI_STATUS="$(run_checks_passed fm/feat-localonly)"
  FM_FAKE_GH_CHECKS=none
  FM_FAKE_GH_CALLS="$d/gh.calls"
  : > "$FM_FAKE_GH_CALLS"
  local out; out=$(run_crew_state "$d" feat-localonly)
  assert_contains "$out" "state: done" "local-only ready signal is unchanged"
  calls=$(awk 'END { print NR + 0 }' "$FM_FAKE_GH_CALLS" 2>/dev/null || echo 0)
  [ "$calls" -eq 0 ] || fail "local-only mode probed the forge for checks ($calls calls)"
  pass "local-only keeps its ready signal and gains no CI requirement"
}

# GitLab merge requests keep their previous behavior: the probe is GitHub-only,
# so a GitLab-hosted run is not judged - or refused - by a GitHub answer.
test_gitlab_merge_request_is_not_judged_by_the_github_probe() {
  reset_fakes
  local d calls; d=$(new_case gitlab-mr)
  make_repo_on_branch "$d/wt" fm/feat-gitlab
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/feat-gitlab.meta" "window=fm:fm-feat-gitlab" "worktree=$d/wt" "kind=ship" "mode=no-mistakes"
  FM_FAKE_AXI_STATUS="$(run_ci_monitoring fm/feat-gitlab | sed 's#https://github.com/o/r/pull/2#https://gitlab.example.com/grp/proj/-/merge_requests/2#')"
  FM_FAKE_CI_LOGS="all CI checks passed - still monitoring until merged or closed"
  FM_FAKE_GH_CHECKS=none
  FM_FAKE_GH_CALLS="$d/gh.calls"
  : > "$FM_FAKE_GH_CALLS"
  local out; out=$(run_crew_state "$d" feat-gitlab)
  assert_contains "$out" "state: done" "a GitLab-hosted green run is unchanged"
  assert_contains "$out" "checks green" "GitLab keeps its previous green detail"
  calls=$(awk 'END { print NR + 0 }' "$FM_FAKE_GH_CALLS" 2>/dev/null || echo 0)
  [ "$calls" -eq 0 ] || fail "a GitLab merge request reached the GitHub check probe ($calls calls)"
  pass "GitLab merge requests are non-regressive and never reach the GitHub probe"
}

# No way to ask the forge is not the same as a green answer from it.
test_missing_gh_makes_a_green_reading_unreadable() {
  reset_fakes
  local d toolbin out; d=$(new_case gh-missing)
  make_repo_on_branch "$d/wt" fm/feat-ghmissing
  make_fakebin "$d" >/dev/null
  rm -f "$d/fakebin/gh"
  toolbin=$(make_no_timeout_toolbin "$d")
  fm_write_meta "$d/state/feat-ghmissing.meta" "window=fm:fm-feat-ghmissing" "worktree=$d/wt" "kind=ship" "mode=no-mistakes"
  FM_FAKE_AXI_STATUS="$(run_ci_monitoring fm/feat-ghmissing)"
  FM_FAKE_CI_LOGS="all CI checks passed - still monitoring until merged or closed"
  out=$(PATH="$d/fakebin:$toolbin" FM_STATE_OVERRIDE="$d/state" "$CREW_STATE" feat-ghmissing)
  assert_contains "$out" "state: working" "no gh available -> working"
  assert_not_contains "$out" "state: done" "no gh available must not read as done"
  assert_contains "$out" "check state unreadable" "no gh available names the missing read"
  pass "a green reading with no way to reach the forge stays working"
}

# The probe is one bounded network call, and a hung forge must not hang a state
# read the watcher makes on every poll.
test_gh_probe_is_time_bounded() {
  reset_fakes
  local d start elapsed out; d=$(new_case gh-hangs)
  make_repo_on_branch "$d/wt" fm/feat-ghhang
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/feat-ghhang.meta" "window=fm:fm-feat-ghhang" "worktree=$d/wt" "kind=ship" "mode=no-mistakes"
  FM_FAKE_AXI_STATUS="$(run_ci_monitoring fm/feat-ghhang)"
  FM_FAKE_CI_LOGS="all CI checks passed - still monitoring until merged or closed"
  FM_FAKE_GH_SLEEP=1
  start=$SECONDS
  out=$(PATH="$d/fakebin:$PATH" FM_STATE_OVERRIDE="$d/state" FM_CREW_STATE_GH_TIMEOUT=1 "$CREW_STATE" feat-ghhang)
  elapsed=$((SECONDS - start))
  [ "$elapsed" -lt 15 ] || fail "the check probe was not time bounded (elapsed ${elapsed}s)"
  assert_contains "$out" "state: working" "a hung check probe -> working"
  assert_contains "$out" "check state unreadable" "a hung check probe reads as unreadable"
  pass "the forge check probe is time bounded and a timeout is never green"
}

test_ci_monitoring_green_then_rearm_stays_working() {
  reset_fakes
  local d; d=$(new_case ci-green-then-rearm)
  make_repo_on_branch "$d/wt" fm/feat-cirearm
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/feat-cirearm.meta" "window=fm:fm-feat-cirearm" "worktree=$d/wt" "kind=ship"
  FM_FAKE_AXI_STATUS="$(run_ci_monitoring fm/feat-cirearm)"
  FM_FAKE_CI_LOGS=$(cat <<'EOF'
all CI checks passed - still monitoring until merged or closed
base branch advanced (aaaaaaa..bbbbbbb), re-arming CI monitor timeout
EOF
)
  local out; out=$(run_crew_state "$d" feat-cirearm)
  assert_contains "$out" "state: working" "base-advance rearm marker -> working"
  assert_not_contains "$out" "state: done" "base-advance rearm marker must not read as done"
  assert_not_contains "$out" "checks green" "base-advance rearm marker must not read as checks green"
  pass "base-advance rearm after green stays working"
}

test_ci_monitoring_no_checks_yet_stays_working() {
  reset_fakes
  local d; d=$(new_case ci-nochecks-yet)
  make_repo_on_branch "$d/wt" fm/feat-cinochecksyet
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/feat-cinochecksyet.meta" "window=fm:fm-feat-cinochecksyet" "worktree=$d/wt" "kind=ship"
  FM_FAKE_AXI_STATUS="$(run_ci_monitoring fm/feat-cinochecksyet)"
  FM_FAKE_CI_LOGS=$(cat <<'EOF'
no CI checks reported - still monitoring until merged or closed
base branch advanced (aaaaaaa..bbbbbbb), re-arming CI monitor timeout
no CI checks reported yet, waiting for checks to register...
EOF
)
  local out; out=$(run_crew_state "$d" feat-cinochecksyet)
  assert_contains "$out" "state: working" "pending no-checks marker -> working"
  assert_not_contains "$out" "state: done" "pending no-checks marker must not read as done"
  assert_not_contains "$out" "checks green" "pending no-checks marker must not read as checks green"
  pass "pending no-checks ci-monitor marker stays working"
}

test_ci_monitoring_still_waiting_stays_working() {
  reset_fakes
  local d; d=$(new_case ci-waiting)
  make_repo_on_branch "$d/wt" fm/feat-ciwait
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/feat-ciwait.meta" "window=fm:fm-feat-ciwait" "worktree=$d/wt" "kind=ship"
  FM_FAKE_AXI_STATUS="$(run_ci_monitoring fm/feat-ciwait)"
  FM_FAKE_CI_LOGS="CI checks running, waiting for results..."
  local out; out=$(run_crew_state "$d" feat-ciwait)
  assert_contains "$out" "state: working" "ci step still red -> working"
  assert_not_contains "$out" "checks green" "no green marker present -> no checks-green detail"
  pass "ci-monitoring run with checks not yet green stays working"
}

# A later merge-conflict auto-fix round after an earlier green reading must
# not be masked: the MOST RECENT marker in the log tail wins.
test_ci_monitoring_green_then_new_issue_stays_working() {
  reset_fakes
  local d; d=$(new_case ci-green-then-issue)
  make_repo_on_branch "$d/wt" fm/feat-cirelapse
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/feat-cirelapse.meta" "window=fm:fm-feat-cirelapse" "worktree=$d/wt" "kind=ship"
  FM_FAKE_AXI_STATUS="$(run_ci_monitoring fm/feat-cirelapse)"
  FM_FAKE_CI_LOGS=$(cat <<'EOF'
all CI checks passed - still monitoring until merged or closed
base branch advanced (aaaaaaa..bbbbbbb), re-arming CI monitor timeout
issues detected: merge conflict - auto-fixing (attempt 2/10)...
EOF
)
  local out; out=$(run_crew_state "$d" feat-cirelapse)
  assert_contains "$out" "state: working" "a later relapse marker must win over an earlier green one"
  assert_not_contains "$out" "state: done" "relapsed ci run must not read as done"
  pass "a fresh issue after an earlier green reading is not masked"
}

test_ci_ready_done_log_relapse_stays_working() {
  reset_fakes
  local d; d=$(new_case ci-ready-then-relapse)
  make_repo_on_branch "$d/wt" fm/feat-cireadyrelapse
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/feat-cireadyrelapse.meta" "window=fm:fm-feat-cireadyrelapse" "worktree=$d/wt" "kind=ship"
  printf 'done: PR https://github.com/o/r/pull/2 checks green\n' > "$d/state/feat-cireadyrelapse.status"
  FM_FAKE_AXI_STATUS="$(run_ci_monitoring fm/feat-cireadyrelapse)"
  FM_FAKE_CI_LOGS=$(cat <<'EOF'
all CI checks passed - still monitoring until merged or closed
base branch advanced (aaaaaaa..bbbbbbb), re-arming CI monitor timeout
CI checks running, waiting for results...
EOF
)
  local out; out=$(run_crew_state "$d" feat-cireadyrelapse)
  assert_contains "$out" "state: working" "a stale ready status must not mask a later CI relapse"
  assert_contains "$out" "source: run-step" "relapsed ci run remains run-step sourced"
  assert_not_contains "$out" "state: done" "relapsed ci run with stale done log must not read as done"
  pass "stale checks-green status log does not mask CI relapse"
}

test_ci_fixing_after_green_stays_working() {
  reset_fakes
  local d; d=$(new_case ci-fixing-after-green)
  make_repo_on_branch "$d/wt" fm/feat-cifixing
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/feat-cifixing.meta" "window=fm:fm-feat-cifixing" "worktree=$d/wt" "kind=ship"
  printf 'done: PR https://github.com/o/r/pull/2 checks green\n' > "$d/state/feat-cifixing.status"
  FM_FAKE_AXI_STATUS="$(run_ci_fixing fm/feat-cifixing)"
  FM_FAKE_CI_LOGS="all CI checks passed - still monitoring until merged or closed"
  local out; out=$(run_crew_state "$d" feat-cifixing)
  assert_contains "$out" "state: working" "ci fixing step must stay working"
  assert_contains "$out" "source: run-step" "ci fixing remains run-step sourced"
  assert_not_contains "$out" "state: done" "ci fixing must not read as checks-green done"
  pass "ci fixing is not overridden by an earlier green marker"
}

test_top_level_fixing_ci_running_after_green_stays_working() {
  reset_fakes
  local d; d=$(new_case top-level-fixing-ci-running)
  make_repo_on_branch "$d/wt" fm/feat-topfixingci
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/feat-topfixingci.meta" "window=fm:fm-feat-topfixingci" "worktree=$d/wt" "kind=ship"
  FM_FAKE_AXI_STATUS="$(run_fixing_ci_running fm/feat-topfixingci)"
  FM_FAKE_CI_LOGS="all CI checks passed - still monitoring until merged or closed"
  local out; out=$(run_crew_state "$d" feat-topfixingci)
  assert_contains "$out" "state: working" "top-level fixing with ci running must stay working"
  assert_contains "$out" "source: run-step" "top-level fixing with ci running remains run-step sourced"
  assert_contains "$out" "validating (fixing)" "top-level fixing keeps fixing detail"
  assert_not_contains "$out" "state: done" "top-level fixing must not use stale green marker"
  pass "top-level fixing is not overridden by a stale ci running row"
}

test_top_level_fixing_done_log_stays_working() {
  reset_fakes
  local d; d=$(new_case top-level-fixing-done-log)
  make_repo_on_branch "$d/wt" fm/feat-topfixing
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/feat-topfixing.meta" "window=fm:fm-feat-topfixing" "worktree=$d/wt" "kind=ship"
  printf 'done: PR https://github.com/o/r/pull/2 checks green\n' > "$d/state/feat-topfixing.status"
  FM_FAKE_AXI_STATUS="$(run_fixing fm/feat-topfixing)"
  FM_FAKE_CI_LOGS="all CI checks passed - still monitoring until merged or closed"
  local out; out=$(run_crew_state "$d" feat-topfixing)
  assert_contains "$out" "state: working" "top-level fixing must stay working"
  assert_contains "$out" "source: run-step" "top-level fixing remains run-step sourced"
  assert_contains "$out" "validating (fixing)" "top-level fixing keeps fixing detail"
  assert_not_contains "$out" "state: done" "top-level fixing must not read as stale checks-green done"
  pass "top-level fixing is not overridden by a stale done log"
}

# (d) terminal run-step is authoritative
test_terminal_passed() {
  reset_fakes
  local d; d=$(new_case passed)
  make_repo_on_branch "$d/wt" fm/feat-d
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/feat-d.meta" "window=fm:fm-feat-d" "worktree=$d/wt" "kind=ship"
  FM_FAKE_AXI_STATUS="$(run_passed fm/feat-d)"
  local out; out=$(run_crew_state "$d" feat-d)
  assert_contains "$out" "state: done" "passed run -> done"
  assert_contains "$out" "source: run-step" "passed -> run-step source"
  pass "terminal passed run is authoritative"
}

test_terminal_failed() {
  reset_fakes
  local d; d=$(new_case failed)
  make_repo_on_branch "$d/wt" fm/feat-e
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/feat-e.meta" "window=fm:fm-feat-e" "worktree=$d/wt" "kind=ship"
  FM_FAKE_AXI_STATUS="$(run_failed fm/feat-e)"
  local out; out=$(run_crew_state "$d" feat-e)
  assert_contains "$out" "state: failed" "failed run -> failed"
  assert_contains "$out" "source: run-step" "failed -> run-step source"
  pass "terminal failed run is authoritative"
}

# (e) `axi status` can report another branch while the coarse runs list reports
# this branch as running. Even an exact coarse SHA cannot prove the run is not
# parked, so the helper must retain its pane/status-log fallback.
test_coarse_equal_head_requires_detailed_state() {
  reset_fakes
  local d short; d=$(new_case coarse-equal-head)
  make_repo_on_branch "$d/wt" fm/feat-f
  short=$(git -C "$d/wt" rev-parse --short=7 HEAD)
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/feat-f.meta" "window=fm:fm-feat-f" "worktree=$d/wt" "kind=ship"
  printf 'needs-decision: review gate requires approval\n' > "$d/state/feat-f.status"
  FM_FAKE_AXI_STATUS="$(run_running fm/other-crew)"
  FM_FAKE_RUNS_LIST="$(cat <<EOF
  running    fm/other-crew aaaaaaa  2026-07-02 22:10
  running    fm/feat-f ${short}  2026-07-02 22:05
EOF
)"
  FM_FAKE_BUSY=0
  local out; out=$(run_crew_state "$d" feat-f)
  assert_contains "$out" "state: parked" "equal-head coarse running row retains the parked fallback"
  assert_contains "$out" "source: status-log" "equal-head coarse running row is not authoritative"
  assert_not_contains "$out" "source: run-step" "equal-head coarse running row lacks detailed gate state"
  PATH="$d/fakebin:$PATH" FM_STATE_OVERRIDE="$d/state" crew_is_provably_working feat-f \
    && fail "an equal-head coarse running row was treated as provably working"
  pass "equal-head coarse running row requires detailed state"
}

# A resolvable descendant run head is equally ambiguous without detailed gate
# state, and its newer running row must not expose an older terminal row.
test_coarse_descendant_head_requires_detailed_state() {
  reset_fakes
  local d base_head base_short descendant_short; d=$(new_case coarse-descendant-head)
  make_repo_on_branch "$d/wt" fm/feat-fq
  base_head=$(git -C "$d/wt" rev-parse HEAD)
  base_short=$(git -C "$d/wt" rev-parse --short=7 HEAD)
  git -C "$d/wt" commit -q --allow-empty -m 'isolated pipeline fix'
  descendant_short=$(git -C "$d/wt" rev-parse --short=7 HEAD)
  git -C "$d/wt" reset -q --hard "$base_head"
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/feat-fq.meta" "window=fm:fm-feat-fq" "worktree=$d/wt" "kind=ship"
  printf 'needs-decision: review gate requires approval\n' > "$d/state/feat-fq.status"
  FM_FAKE_AXI_STATUS="$(run_running fm/other-crew)"
  FM_FAKE_RUNS_LIST="$(cat <<EOF
  running    fm/other-crew aaaaaaa  2026-07-02 22:10
  running    fm/feat-fq ${descendant_short}  2026-07-02 21:50
  completed  fm/feat-fq ${base_short}  2026-07-02 20:00  https://github.com/o/r/pull/1
EOF
)"
  FM_FAKE_BUSY=0
  local out; out=$(run_crew_state "$d" feat-fq)
  assert_contains "$out" "state: parked" "descendant-head coarse running row retains the parked fallback"
  assert_contains "$out" "source: status-log" "descendant-head coarse running row is not authoritative"
  assert_not_contains "$out" "run completed" "older terminal row does not shadow the newer running row"
  pass "descendant-head coarse running row requires detailed state"
}

test_coarse_run_does_not_probe_other_branch_ci_log_for_ready_status() {
  reset_fakes
  local d short; d=$(new_case coarse-ready-other-log)
  make_repo_on_branch "$d/wt" fm/feat-coarseready
  short=$(git -C "$d/wt" rev-parse --short=7 HEAD)
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/feat-coarseready.meta" "window=fm:fm-feat-coarseready" "worktree=$d/wt" "kind=ship"
  printf 'done: PR https://github.com/o/r/pull/4 checks green\n' > "$d/state/feat-coarseready.status"
  FM_FAKE_AXI_STATUS="$(run_ci_monitoring fm/other-crew)"
  FM_FAKE_RUNS_LIST="$(cat <<EOF
  running    fm/other-crew aaaaaaa  2026-07-02 22:10
  running    fm/feat-coarseready ${short}  2026-07-02 22:05
EOF
)"
  FM_FAKE_CI_LOGS="CI checks running, waiting for results..."
  local out; out=$(run_crew_state "$d" feat-coarseready)
  assert_contains "$out" "state: done" "coarse ready status -> done"
  assert_contains "$out" "source: status-log" "coarse ready status remains status-log sourced"
  assert_not_contains "$out" "state: working" "coarse ready status must not be suppressed by another branch log"
  pass "coarse run does not probe another branch's ci log"
}

# A synchronous run can rebase and apply fixes in no-mistakes' isolated gate
# while the invoking worktree remains at the exact submitted commit. The run
# head is then intentionally absent from (or divergent in) the invoking repo,
# so ancestry against the evolving run head cannot prove ownership. The exact
# no-mistakes submission ref remains bound to the worktree HEAD and is the
# counterfactual that distinguishes this healthy active run from an idle pane.
test_active_rebased_run_uses_exact_submission_ref() {
  reset_fakes
  local d; d=$(new_case active-rebased-submission)
  make_repo_on_branch "$d/wt" fm/feat-rebased
  set_no_mistakes_submission_ref "$d/wt" fm/feat-rebased
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/feat-rebased.meta" "window=fm:fm-feat-rebased" "worktree=$d/wt" "kind=ship"
  FM_FAKE_RUN_HEAD=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
  FM_FAKE_AXI_STATUS="$(run_running fm/feat-rebased)"
  FM_FAKE_BUSY=0
  local out; out=$(run_crew_state "$d" feat-rebased)
  assert_contains "$out" "state: working" "active rebased run -> working"
  assert_contains "$out" "source: run-step" "active rebased run -> run-step source"
  assert_not_contains "$out" "source: pane" "idle pane does not mask the active run"
  pass "active rebased run is tied to the exact submitted code while the pane is idle"
}

# Run attribution precedes every endpoint fallback, so the exact same active
# proof must remain authoritative for every supported session backend.
test_active_rebased_run_precedes_all_backend_fallbacks() {
  reset_fakes
  local d backend id out; d=$(new_case active-rebased-backends)
  make_repo_on_branch "$d/wt" fm/feat-all-backends
  set_no_mistakes_submission_ref "$d/wt" fm/feat-all-backends
  make_fakebin "$d" >/dev/null
  FM_FAKE_RUN_HEAD=eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee
  FM_FAKE_AXI_STATUS="$(run_running fm/feat-all-backends)"
  FM_FAKE_BUSY=0
  for backend in tmux herdr zellij orca cmux; do
    id="all-backends-$backend"
    if [ "$backend" = orca ]; then
      fm_write_meta "$d/state/$id.meta" "terminal=missing-$backend" "worktree=$d/wt" "kind=ship" "backend=$backend"
    else
      fm_write_meta "$d/state/$id.meta" "window=missing-$backend" "worktree=$d/wt" "kind=ship" "backend=$backend"
    fi
    out=$(run_crew_state "$d" "$id")
    assert_contains "$out" "state: working" "$backend active rebased run -> working"
    assert_contains "$out" "source: run-step" "$backend endpoint fallback does not mask the active run"
  done
  pass "active rebased run remains authoritative across every supported session backend"
}

# The coarse runs list cannot distinguish active work from a parked gate, so a
# matching submission ref alone must not make its running row authoritative.
test_cross_branch_coarse_submission_ref_requires_detailed_state() {
  reset_fakes
  local d; d=$(new_case crossbranch-active-rebased)
  make_repo_on_branch "$d/wt" fm/feat-cross-rebased
  set_no_mistakes_submission_ref "$d/wt" fm/feat-cross-rebased
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/feat-cross-rebased.meta" "window=fm:fm-feat-cross-rebased" "worktree=$d/wt" "kind=ship"
  printf 'needs-decision: review gate requires approval\n' > "$d/state/feat-cross-rebased.status"
  FM_FAKE_AXI_STATUS="$(run_running fm/other-crew)"
  FM_FAKE_RUNS_LIST=$(cat <<'EOF'
  running    fm/other-crew aaaaaaa  2026-07-28 16:00
  running    fm/feat-cross-rebased bbbbbbb  2026-07-28 15:59
EOF
)
  FM_FAKE_BUSY=0
  local out; out=$(run_crew_state "$d" feat-cross-rebased)
  assert_contains "$out" "state: parked" "coarse running row retains the parked fallback state"
  assert_contains "$out" "source: status-log" "coarse running row falls back without detailed gate state"
  assert_not_contains "$out" "source: run-step" "submission ref alone does not attribute the coarse row"
  PATH="$d/fakebin:$PATH" FM_STATE_OVERRIDE="$d/state" crew_is_provably_working feat-cross-rebased \
    && fail "a coarse running row with only submission-ref identity was treated as provably working"
  pass "coarse submission-ref identity requires detailed run state"
}

# The submission ref is exact code identity, not a branch-only escape hatch.
# If it names any other commit, the unavailable run head remains unattributed.
test_active_rebased_run_rejects_mismatched_submission_ref() {
  reset_fakes
  local d submitted; d=$(new_case active-rebased-mismatch)
  make_repo_on_branch "$d/wt" fm/feat-rebased-mismatch
  submitted=$(git -C "$d/wt" rev-parse HEAD)
  git -C "$d/wt" commit -q --allow-empty -m 'local work after submitted code'
  set_no_mistakes_submission_ref "$d/wt" fm/feat-rebased-mismatch "$submitted"
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/feat-rebased-mismatch.meta" "window=fm:fm-feat-rebased-mismatch" "worktree=$d/wt" "kind=ship"
  FM_FAKE_RUN_HEAD=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
  FM_FAKE_AXI_STATUS="$(run_running fm/feat-rebased-mismatch)"
  FM_FAKE_RUNS_LIST=""
  FM_FAKE_BUSY=0
  local out; out=$(run_crew_state "$d" feat-rebased-mismatch)
  assert_contains "$out" "state: unknown" "mismatched submitted code -> unknown"
  assert_contains "$out" "source: pane" "mismatched submitted code falls back to the converted harness state"
  assert_not_contains "$out" "source: run-step" "mismatched submitted code is not attributed"
  pass "active rebased run rejects a mismatched submission ref"
}

# A parked run with an unavailable historical head is not flattened into
# working merely because its original submission ref still matches.
test_parked_unresolved_run_head_not_classified_active() {
  reset_fakes
  local d; d=$(new_case parked-submission-ref)
  make_repo_on_branch "$d/wt" fm/feat-old-parked
  set_no_mistakes_submission_ref "$d/wt" fm/feat-old-parked
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/feat-old-parked.meta" "window=fm:fm-feat-old-parked" "worktree=$d/wt" "kind=ship"
  FM_FAKE_RUN_HEAD=dddddddddddddddddddddddddddddddddddddddd
  FM_FAKE_AXI_STATUS="$(run_parked fm/feat-old-parked)"
  FM_FAKE_RUNS_LIST=""
  FM_FAKE_BUSY=0
  local out; out=$(run_crew_state "$d" feat-old-parked)
  assert_not_contains "$out" "state: working" "parked unresolved run is not active"
  assert_not_contains "$out" "source: run-step" "parked unresolved run is not revived by submission ref"
  pass "parked run with an unresolved head is not classified active"
}

# A terminal historical run is not revived merely because its original
# submission ref still equals the worktree HEAD.
test_terminal_unresolved_run_head_not_revived_by_submission_ref() {
  reset_fakes
  local d; d=$(new_case terminal-submission-ref)
  make_repo_on_branch "$d/wt" fm/feat-old-terminal
  set_no_mistakes_submission_ref "$d/wt" fm/feat-old-terminal
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/feat-old-terminal.meta" "window=fm:fm-feat-old-terminal" "worktree=$d/wt" "kind=ship"
  FM_FAKE_RUN_HEAD=cccccccccccccccccccccccccccccccccccccccc
  FM_FAKE_AXI_STATUS="$(run_passed fm/feat-old-terminal)"
  FM_FAKE_RUNS_LIST=""
  FM_FAKE_BUSY=0
  local out; out=$(run_crew_state "$d" feat-old-terminal)
  assert_contains "$out" "state: unknown" "terminal unresolved run head -> unknown"
  assert_contains "$out" "source: pane" "terminal unresolved run falls back to the converted harness state"
  assert_not_contains "$out" "source: run-step" "terminal run is not revived by a stale submission ref"
  pass "terminal run is not revived by the submission-ref fallback"
}

# A different-branch run with NO matching runs-list row must NOT be
# misattributed, and must not be treated as a false "working" verdict either.
test_other_branch_run_ignored() {
  reset_fakes
  local d; d=$(new_case otherbranch)
  make_repo_on_branch "$d/wt" fm/feat-g
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/feat-g.meta" "window=fm:fm-feat-g" "worktree=$d/wt" "kind=ship" "harness=claude"
  printf 'done: implemented, ready to validate\n' > "$d/state/feat-g.status"
  FM_FAKE_AXI_STATUS="$(run_running fm/some-other)"
  FM_FAKE_RUNS_LIST="$(cat <<'EOF'
  running    fm/some-other aaaaaaa  2026-07-02 22:10
EOF
)"
  FM_FAKE_BUSY=0
  arm_idle_record "$d/state" feat-g
  local out; out=$(run_crew_state "$d" feat-g)
  assert_not_contains "$out" "source: run-step" "another branch's run not misattributed"
  assert_contains "$out" "source: status-log" "no own run -> falls back to status-log"
  assert_contains "$out" "state: done" "falls back to the log verb"
  pass "another branch's run is ignored, falls back"
}

# (f) no run for this crew + a busy pane -> working via pane
test_no_run_busy_pane() {
  reset_fakes
  local d; d=$(new_case busy)
  make_repo_on_branch "$d/wt" fm/feat-h
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/feat-h.meta" "window=fm:fm-feat-h" "worktree=$d/wt" "kind=ship" "harness=claude"
  # No matching run anywhere. The busy verdict comes from the crew's own
  # semantic lifecycle record (bin/fm-busy-lib.sh), not from rendered text.
  FM_FAKE_AXI_STATUS=""
  FM_FAKE_RUNS_LIST=""
  FM_FAKE_BUSY=1
  local gen; gen=$("$ROOT/bin/fm-busy-event.sh" arm "$d/state" feat-h)
  "$ROOT/bin/fm-busy-event.sh" apply "$d/state" feat-h busy --gen "$gen" \
    --source claude-hook --event user-prompt-submit
  local out; out=$(run_crew_state "$d" feat-h)
  assert_contains "$out" "state: working" "busy record -> working"
  assert_contains "$out" "source: pane" "busy record -> pane source"
  assert_contains "$out" "claude-hook" "the working verdict names its semantic source"
  pass "no run + a busy semantic record reads working, attributed to its source"
}

# A converted adapter must NOT read working from rendered footer text: the
# redesign removed that dependency, so a pane painting "esc to interrupt" with
# no semantic record is unknown, never working and never silently idle.
test_no_run_footer_text_alone_is_not_working() {
  reset_fakes
  local d; d=$(new_case busy-footer-only)
  make_repo_on_branch "$d/wt" fm/feat-h2
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/feat-h2.meta" "window=fm:fm-feat-h2" "worktree=$d/wt" "kind=ship" "harness=claude"
  FM_FAKE_AXI_STATUS=""
  FM_FAKE_RUNS_LIST=""
  FM_FAKE_BUSY=1
  printf 'done: stale completion event\n' > "$d/state/feat-h2.status"
  local out; out=$(run_crew_state "$d" feat-h2)
  assert_not_contains "$out" "state: working" "a footer alone must not read working for a converted adapter"
  assert_contains "$out" "state: unknown" "no semantic record -> unknown"
  assert_not_contains "$out" "source: status-log" "unknown semantic state must not fall through to a stale log"
  pass "a converted adapter never reads working from rendered footer text"
}

# Grok keeps its isolated temporary rendered-tail fallback until its structured
# lifecycle is live-verified, so a grok crew still reads working from its own
# verified signature.
test_no_run_grok_uses_isolated_fallback() {
  reset_fakes
  local d; d=$(new_case busy-grok)
  make_repo_on_branch "$d/wt" fm/feat-h3
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/feat-h3.meta" "window=fm:fm-feat-h3" "worktree=$d/wt" "kind=ship" "harness=grok"
  FM_FAKE_AXI_STATUS=""
  FM_FAKE_RUNS_LIST=""
  FM_FAKE_BUSY=1
  FM_FAKE_BUSY_TEXT='Ctrl+c:cancel'
  export FM_FAKE_BUSY_TEXT
  local out; out=$(run_crew_state "$d" feat-h3)
  assert_contains "$out" "state: working" "grok busy tail -> working"
  assert_contains "$out" "grok-regex" "the grok verdict names its isolated fallback source"
  pass "grok still reads working through its isolated rendered-tail fallback"
}

test_no_run_herdr_unknown_uses_backend_capture() {
  command -v jq >/dev/null 2>&1 || { pass "herdr pane fallback skipped without jq"; return; }
  reset_fakes
  local d; d=$(new_case herdr-busy)
  make_repo_on_branch "$d/wt" fm/feat-herdr
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/feat-herdr.meta" "window=default:w1:p2" "worktree=$d/wt" "kind=ship" \
    "backend=herdr" "harness=claude"
  FM_FAKE_AXI_STATUS=""
  FM_FAKE_RUNS_LIST=""
  FM_FAKE_TMUX_MISSING=1
  FM_FAKE_HERDR_BUSY=1
  FM_FAKE_HERDR_AGENT_STATUS=working
  local out; out=$(run_crew_state "$d" feat-herdr)
  assert_contains "$out" "state: working" "herdr native busy -> working"
  assert_contains "$out" "source: pane" "herdr native busy -> pane source"
  assert_contains "$out" "herdr-native" "the herdr verdict names its native source"
  pass "herdr's native busy verdict reads working with no record present"
}

# Regression (2026-07 herdr false-surface incident, now solved semantically):
# herdr's agent.get reports generation state ("working" only while the model is
# actively streaming - docs/herdr-backend.md "Busy state"), not "this crew's
# turn is still in progress". A crew blocked on its own long-running foreground
# `no-mistakes axi run` (no --yes; blocks until a gate or outcome) is not
# generating for that whole span, so agent.get reads idle. The crew's own
# semantic lifecycle record still says busy for the whole turn, and it outranks
# the narrower native verdict - so the crew is no longer misread as not-working.
test_no_run_herdr_idle_agent_status_outranked_by_record() {
  command -v jq >/dev/null 2>&1 || { pass "herdr idle corroboration skipped without jq"; return; }
  reset_fakes
  local d; d=$(new_case herdr-idle-busy-record)
  make_repo_on_branch "$d/wt" fm/feat-herdr-idle
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/feat-herdr-idle.meta" "window=default:w1:p3" "worktree=$d/wt" "kind=ship" \
    "backend=herdr" "harness=claude"
  # No run attributable (mirrors a no-mistakes run-step lookup that found no
  # matching row within the configured runs-list window): the crew's semantic
  # busy state is the only remaining signal.
  FM_FAKE_AXI_STATUS=""
  FM_FAKE_RUNS_LIST=""
  FM_FAKE_TMUX_MISSING=1
  FM_FAKE_HERDR_AGENT_STATUS=idle
  FM_FAKE_HERDR_BUSY=0
  local gen; gen=$("$ROOT/bin/fm-busy-event.sh" arm "$d/state" feat-herdr-idle)
  "$ROOT/bin/fm-busy-event.sh" apply "$d/state" feat-herdr-idle busy --gen "$gen" \
    --source claude-hook --event user-prompt-submit
  local out; out=$(run_crew_state "$d" feat-herdr-idle)
  assert_contains "$out" "state: working" "a busy record with herdr idle agent_status -> working"
  assert_contains "$out" "claude-hook" "the record's source outranks herdr's narrower native verdict"
  pass "a mid-tool-call crew stays working because its record outranks herdr's generation state"
}

# The record must not mask a genuinely idle or human-blocked agent: an idle
# record with idle agent_status still reads not-busy.
test_no_run_herdr_idle_agent_status_and_idle_record_stays_idle() {
  command -v jq >/dev/null 2>&1 || { pass "herdr idle+idle-record skipped without jq"; return; }
  reset_fakes
  local d; d=$(new_case herdr-idle-idle-record)
  make_repo_on_branch "$d/wt" fm/feat-herdr-stopped
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/feat-herdr-stopped.meta" "window=default:w1:p4" "worktree=$d/wt" "kind=ship" \
    "backend=herdr" "harness=claude"
  printf 'working: implementing\n' > "$d/state/feat-herdr-stopped.status"
  FM_FAKE_AXI_STATUS=""
  FM_FAKE_RUNS_LIST=""
  FM_FAKE_TMUX_MISSING=1
  FM_FAKE_HERDR_AGENT_STATUS=idle
  FM_FAKE_HERDR_BUSY=0
  local gen; gen=$("$ROOT/bin/fm-busy-event.sh" arm "$d/state" feat-herdr-stopped)
  "$ROOT/bin/fm-busy-event.sh" apply "$d/state" feat-herdr-stopped idle --gen "$gen" \
    --source claude-hook --event stop
  local out; out=$(run_crew_state "$d" feat-herdr-stopped)
  assert_not_contains "$out" "source: pane" "an idle record must not read as busy"
  assert_contains "$out" "source: status-log" "an idle record falls to the status log"
  pass "an idle record with idle agent_status stays not-busy (no regression for a human-blocked agent)"
}

# (g) no run + idle pane -> the status-log verb, as-is
test_no_run_idle_pane_uses_log() {
  reset_fakes
  local d; d=$(new_case idle)
  make_repo_on_branch "$d/wt" fm/feat-i
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/feat-i.meta" "window=fm:fm-feat-i" "worktree=$d/wt" "kind=ship" "harness=claude"
  printf 'needs-decision: which database?\n' > "$d/state/feat-i.status"
  FM_FAKE_AXI_STATUS=""
  FM_FAKE_BUSY=0
  arm_idle_record "$d/state" feat-i
  local out; out=$(run_crew_state "$d" feat-i)
  assert_contains "$out" "state: parked" "needs-decision log -> parked"
  assert_contains "$out" "source: status-log" "idle pane -> status-log source"
  pass "no run + idle pane uses the status-log verb"
}

test_no_run_idle_pane_uses_keyed_log() {
  reset_fakes
  local d; d=$(new_case keyed-idle)
  make_repo_on_branch "$d/wt" fm/feat-keyed
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/feat-keyed.meta" "window=fm:fm-feat-keyed" "worktree=$d/wt" "kind=ship" "harness=claude"
  printf 'needs-decision [key=q1]: which database?\n' > "$d/state/feat-keyed.status"
  FM_FAKE_AXI_STATUS=""
  FM_FAKE_BUSY=0
  arm_idle_record "$d/state" feat-keyed
  local out; out=$(run_crew_state "$d" feat-keyed)
  assert_contains "$out" "state: parked" "keyed needs-decision log -> parked"
  assert_contains "$out" "which database?" "key token is excluded from status detail"
  pass "no run + idle pane parses keyed status syntax"
}

# (g') no run + idle pane on a DECLARED external-wait pause -> state: paused, so a
# supervisor reading the crew sees a distinct pause (and its reason) rather than a
# wedge-suspect idle. This is the reader half the watcher/daemon build on.
test_no_run_idle_pane_paused() {
  reset_fakes
  local d; d=$(new_case paused)
  make_repo_on_branch "$d/wt" fm/feat-pause
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/feat-pause.meta" "window=fm:fm-feat-pause" "worktree=$d/wt" "kind=ship" "harness=claude"
  printf 'paused: holding for the upstream tool release\n' > "$d/state/feat-pause.status"
  FM_FAKE_AXI_STATUS=""
  FM_FAKE_BUSY=0
  arm_idle_record "$d/state" feat-pause
  local out; out=$(run_crew_state "$d" feat-pause)
  assert_contains "$out" "state: paused" "paused log -> paused"
  assert_contains "$out" "source: status-log" "idle pause -> status-log source"
  assert_contains "$out" "holding for the upstream tool release" "the pause reason is carried in the detail"
  pass "no run + idle pane on a paused: status reports state: paused with its reason"
}

test_no_run_idle_pane_custom_paused_verb() {
  reset_fakes
  local d; d=$(new_case custom-paused)
  make_repo_on_branch "$d/wt" fm/feat-custom-pause
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/feat-custom-pause.meta" "window=fm:fm-feat-custom-pause" "worktree=$d/wt" "kind=ship" "harness=claude"
  printf 'awaiting: vendor maintenance window\n' > "$d/state/feat-custom-pause.status"
  FM_FAKE_AXI_STATUS=""
  FM_FAKE_BUSY=0
  arm_idle_record "$d/state" feat-custom-pause
  local out; out=$(FM_CLASSIFY_PAUSED_VERB=awaiting run_crew_state "$d" feat-custom-pause)
  assert_contains "$out" "state: paused" "custom paused verb -> paused"
  assert_contains "$out" "source: status-log" "custom paused verb -> status-log source"
  assert_contains "$out" "vendor maintenance window" "custom pause preserves its reason"
  printf 'paused: default verb no longer selected\n' > "$d/state/feat-custom-pause.status"
  out=$(FM_CLASSIFY_PAUSED_VERB=awaiting run_crew_state "$d" feat-custom-pause)
  assert_contains "$out" "state: unknown" "custom paused verb replaces the default"
  pass "no run + idle pane honors the configured paused verb"
}

# A trailing keyed resolved: event is a decision-CLOSING event, not a run-state
# verb. It must never become the current state or leak its resolution prose as the
# detail: a healthy idle secondmate that just closed a keyed decision falls through
# to the idle default (unknown/none), not `unknown` with the resolution note as its
# `doing`. Regression for the bearings render bug where such a secondmate showed
# state=unknown with resolution prose. The one-owner keyed fold in fm-classify-lib.sh
# is untouched; this only stops the deriver from reading a non-state event as state.
test_no_run_idle_secondmate_resolved_event_not_state() {
  reset_fakes
  local d; d=$(new_case resolved-idle)
  mkdir -p "$d/wt"
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/mate.meta" "window=fm:fm-mate" "worktree=$d/wt" "kind=secondmate" "home=$d/wt"
  printf 'needs-decision [key=race]: pick subscribe order\n' > "$d/state/mate.status"
  printf 'resolved [key=race]: went with subscribe-before-write\n' >> "$d/state/mate.status"
  FM_FAKE_AXI_STATUS=""
  FM_FAKE_BUSY=0
  local out; out=$(run_crew_state "$d" mate)
  assert_contains "$out" "state: unknown" "resolved-then-idle secondmate is not a spurious run-state"
  assert_contains "$out" "source: none" "a resolved event is not treated as a status-log state source"
  assert_not_contains "$out" "subscribe-before-write" "resolution prose must not leak into the detail"
  # A bare (non-keyed) resolved: closes the default key and behaves the same.
  printf 'blocked: waiting on infra\nresolved: infra access granted\n' > "$d/state/mate.status"
  out=$(run_crew_state "$d" mate)
  assert_contains "$out" "source: none" "a bare resolved: is not a state source either"
  assert_not_contains "$out" "infra access granted" "bare resolution prose must not leak into the detail"
  # Control: a genuine trailing state verb still renders from the log.
  printf 'working: reconciling routed items\n' > "$d/state/mate.status"
  out=$(run_crew_state "$d" mate)
  assert_contains "$out" "state: working" "a real trailing state verb still renders"
  assert_contains "$out" "reconciling routed items" "a real state line still carries its detail"
  pass "a trailing resolved: event does not corrupt state render (idle stays idle)"
}

test_dead_window_ignores_stale_status_log() {
  reset_fakes
  local d; d=$(new_case dead-window)
  make_repo_on_branch "$d/wt" fm/feat-dead
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/feat-dead.meta" "window=fm:fm-feat-dead" "worktree=$d/wt" "kind=ship"
  printf 'done: old completion event\n' > "$d/state/feat-dead.status"
  FM_FAKE_AXI_STATUS=""
  FM_FAKE_RUNS_LIST=""
  FM_FAKE_TMUX_MISSING=1
  local out; out=$(run_crew_state "$d" feat-dead)
  assert_contains "$out" "state: unknown" "dead window -> unknown"
  assert_contains "$out" "source: none" "dead window -> none source"
  assert_not_contains "$out" "source: status-log" "dead window does not reuse stale log"
  pass "dead window ignores stale status log"
}

# A closed/unreadable pane must NOT mask an authoritative run-step: judge by the
# run-step, not the shell. The common case is a finished crew whose agent has
# exited and closed its window (the normal gap between completion and teardown) -
# it must still report its terminal run-step state (e.g. done), never unknown.
test_dead_window_still_reports_terminal_run_step() {
  reset_fakes
  local d; d=$(new_case dead-window-done)
  make_repo_on_branch "$d/wt" fm/feat-dead-done
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/feat-dead-done.meta" "window=fm:fm-feat-dead-done" "worktree=$d/wt" "kind=ship"
  printf 'done: PR https://github.com/o/r/pull/3 checks green\n' > "$d/state/feat-dead-done.status"
  FM_FAKE_AXI_STATUS="$(run_passed fm/feat-dead-done)"
  FM_FAKE_TMUX_MISSING=1   # the crew's window has closed
  local out; out=$(run_crew_state "$d" feat-dead-done)
  assert_contains "$out" "state: done" "closed pane still reports terminal run-step done"
  assert_contains "$out" "source: run-step" "closed pane does not mask the run-step"
  assert_not_contains "$out" "state: unknown" "closed pane with a run must never be unknown"
  pass "closed pane still reports a terminal run-step"
}

# The same for an active run: an agent pane that crashed mid-validation while the
# daemon-backed run continues must report the live run-step, not unknown.
test_dead_window_still_reports_active_run_step() {
  reset_fakes
  local d; d=$(new_case dead-window-active)
  make_repo_on_branch "$d/wt" fm/feat-dead-act
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/feat-dead-act.meta" "window=fm:fm-feat-dead-act" "worktree=$d/wt" "kind=ship"
  FM_FAKE_AXI_STATUS="$(run_running fm/feat-dead-act)"
  FM_FAKE_TMUX_MISSING=1
  local out; out=$(run_crew_state "$d" feat-dead-act)
  assert_contains "$out" "state: working" "closed pane still reports active run-step"
  assert_contains "$out" "source: run-step" "closed pane does not mask the active run-step"
  assert_not_contains "$out" "state: unknown" "closed pane with an active run must never be unknown"
  pass "closed pane still reports an active run-step"
}

test_no_timeout_uses_perl_bound() {
  reset_fakes
  local d toolbin out start elapsed calls_file calls
  d=$(new_case no-timeout)
  make_repo_on_branch "$d/wt" fm/feat-timeout
  make_fakebin "$d" >/dev/null
  calls_file="$d/no-mistakes.calls"
  : > "$calls_file"
  cat > "$d/fakebin/no-mistakes" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${FM_FAKE_NM_CALLS:-/dev/null}"
while :; do :; done
SH
  chmod +x "$d/fakebin/no-mistakes"
  toolbin=$(make_no_timeout_toolbin "$d")
  fm_write_meta "$d/state/feat-timeout.meta" "window=fm:fm-feat-timeout" "worktree=$d/wt" "kind=ship" \
    "harness=claude"
  FM_FAKE_BUSY=1
  local gen; gen=$("$ROOT/bin/fm-busy-event.sh" arm "$d/state" feat-timeout)
  "$ROOT/bin/fm-busy-event.sh" apply "$d/state" feat-timeout busy --gen "$gen" \
    --source claude-hook --event user-prompt-submit
  start=$SECONDS
  out=$(FM_FAKE_NM_CALLS="$calls_file" PATH="$d/fakebin:$toolbin" FM_STATE_OVERRIDE="$d/state" FM_CREW_STATE_NM_TIMEOUT=1 "$CREW_STATE" feat-timeout)
  elapsed=$((SECONDS - start))
  assert_contains "$out" "state: working" "timed-out no-mistakes falls back to pane"
  assert_contains "$out" "source: pane" "timed-out no-mistakes -> pane source"
  [ "$elapsed" -lt 5 ] || fail "perl timeout did not bound no-mistakes calls (elapsed ${elapsed}s)"
  calls=$(awk 'END { print NR + 0 }' "$calls_file" 2>/dev/null || echo 0)
  [ "$calls" -eq 1 ] || fail "empty no-mistakes status triggered extra lookups ($calls calls)"
  pass "no timeout command uses perl bound"
}

# (i) kind=scout skips the run lookup entirely (its deliverable is a report).
test_scout_skips_run_lookup() {
  reset_fakes
  local d; d=$(new_case scout)
  make_repo_on_branch "$d/wt" fm/scout-j
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/scout-j.meta" "window=fm:fm-scout-j" "worktree=$d/wt" "kind=scout" \
    "harness=claude"
  # Even if a run existed on this branch, a scout must not read it.
  FM_FAKE_AXI_STATUS="$(run_running fm/scout-j)"
  FM_FAKE_BUSY=1
  local gen; gen=$("$ROOT/bin/fm-busy-event.sh" arm "$d/state" scout-j)
  "$ROOT/bin/fm-busy-event.sh" apply "$d/state" scout-j busy --gen "$gen" \
    --source claude-hook --event user-prompt-submit
  local out; out=$(run_crew_state "$d" scout-j)
  assert_not_contains "$out" "source: run-step" "scout ignores no-mistakes run-step"
  assert_contains "$out" "source: pane" "scout reads its semantic busy state"
  pass "scout skips the run lookup"
}

# (j) torn-down worktree and missing meta are graceful (unknown/none, exit 0)
test_torn_down_worktree() {
  reset_fakes
  local d; d=$(new_case torndown)
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/gone-k.meta" "window=fm:fm-gone-k" "worktree=$d/no-such-worktree" "kind=ship"
  local out rc
  out=$(run_crew_state "$d" gone-k); rc=$?
  expect_code 0 "$rc" "torn-down worktree exits 0"
  assert_contains "$out" "state: unknown" "torn-down -> unknown"
  assert_contains "$out" "source: none" "torn-down -> none source"
  pass "torn-down worktree is handled gracefully"
}

test_missing_meta() {
  reset_fakes
  local d; d=$(new_case nometa)
  make_fakebin "$d" >/dev/null
  local out rc
  out=$(run_crew_state "$d" ghost-z); rc=$?
  expect_code 0 "$rc" "missing meta exits 0"
  assert_contains "$out" "state: unknown" "missing meta -> unknown"
  assert_contains "$out" "source: none" "missing meta -> none source"
  pass "missing meta is handled gracefully"
}

# (k) crew_is_provably_working end-to-end over the REAL fm-crew-state.sh (not a
# canned fake verdict, unlike tests/fm-watch-triage.test.sh's classifier
# coverage). Detailed active status remains authoritative when its exact
# submitted-code ref binds an unavailable isolated run head.
test_provably_working_via_detailed_submission_state() {
  reset_fakes
  local d; d=$(new_case provably-working-detailed)
  make_repo_on_branch "$d/wt" fm/feat-provable
  set_no_mistakes_submission_ref "$d/wt" fm/feat-provable
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/feat-provable.meta" "window=fm:fm-feat-provable" "worktree=$d/wt" "kind=ship"
  FM_FAKE_RUN_HEAD=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
  FM_FAKE_AXI_STATUS="$(run_running fm/feat-provable)"
  FM_FAKE_BUSY=0
  PATH="$d/fakebin:$PATH" FM_STATE_OVERRIDE="$d/state" crew_is_provably_working feat-provable \
    || fail "detailed active submission state was not treated as provably working"
  pass "crew_is_provably_working trusts detailed active submission state"
}

test_not_provably_working_when_stopped() {
  reset_fakes
  local d; d=$(new_case provably-working-stopped)
  make_repo_on_branch "$d/wt" fm/feat-stopped
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/feat-stopped.meta" "window=fm:fm-feat-stopped" "worktree=$d/wt" "kind=ship"
  # Repo-wide run belongs to someone else, and this branch has no row in the
  # runs list either (it never validated, or genuinely finished/stopped) - the
  # only remaining signal is the pane, which is idle.
  FM_FAKE_AXI_STATUS="$(run_running fm/other-crew)"
  FM_FAKE_RUNS_LIST="$(cat <<'EOF'
  running    fm/other-crew aaaaaaa  2026-07-02 22:10
EOF
)"
  FM_FAKE_BUSY=0
  PATH="$d/fakebin:$PATH" FM_STATE_OVERRIDE="$d/state" crew_is_provably_working feat-stopped \
    && fail "a stopped crew with no run anywhere and an idle pane was treated as provably working"
  pass "crew_is_provably_working still surfaces a genuinely stopped crew (safety property preserved)"
}

# Usage error (no id) is the one non-zero exit.
test_usage_error() {
  reset_fakes
  local rc
  "$CREW_STATE" >/dev/null 2>&1; rc=$?
  expect_code 2 "$rc" "no-arg usage error exits 2"
  pass "usage error exits 2"
}

# Head-binding: same branch name with a rewritten/diverged worktree tip must not
# attribute a historical no-mistakes run (multi-stage branch reuse incident).
test_historical_same_branch_rewritten_head_not_current() {
  reset_fakes
  local d old_head new_head out
  d=$(new_case rewritten-head)
  make_repo_on_branch "$d/wt" fm/todo-flag
  old_head=$(git -C "$d/wt" rev-parse HEAD)
  # Simulate a rebase rewrite: orphan new history on the same branch name.
  git -C "$d/wt" checkout -q --orphan tmp-rewrite
  git -C "$d/wt" commit -q --allow-empty -m 'rewritten tip'
  git -C "$d/wt" branch -q -M fm/todo-flag
  new_head=$(git -C "$d/wt" rev-parse HEAD)
  [ "$old_head" != "$new_head" ] || fail "rewrite did not produce a new head"
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/wishlist.meta" "window=fm:fm-wishlist" "worktree=$d/wt" "kind=ship" "harness=claude"
  printf 'working: stage 2 setup complete rebased onto merged #76\n' > "$d/state/wishlist.status"
  # Historical run still reports the pre-rewrite head on the reused branch.
  FM_FAKE_RUN_HEAD="$old_head"
  FM_FAKE_AXI_STATUS="$(run_parked fm/todo-flag)"
  FM_FAKE_BUSY=0
  arm_idle_record "$d/state" wishlist
  out=$(run_crew_state "$d" wishlist)
  assert_not_contains "$out" "source: run-step" "historical rewritten head must not use run-step"
  assert_not_contains "$out" "parked at" "historical parked run must not mask current state"
  assert_contains "$out" "source: status-log" "falls back to status-log after head mismatch"
  assert_contains "$out" "state: working" "status-log working: remains current"
  pass "historical same-branch rewritten head is not attributed as current"
}

# Head-binding: an active pipeline whose run head is a descendant of the local
# tip (fix commits on the same history) remains current.
test_active_run_descendant_fix_head_remains_current() {
  reset_fakes
  local d base_head fix_head out
  d=$(new_case pipeline-descendant)
  make_repo_on_branch "$d/wt" fm/feat-pipeline
  base_head=$(git -C "$d/wt" rev-parse HEAD)
  git -C "$d/wt" commit -q --allow-empty -m 'pipeline fix commit'
  fix_head=$(git -C "$d/wt" rev-parse HEAD)
  # Worktree still at the pre-fix tip; run reports the pipeline fix head.
  git -C "$d/wt" reset -q --hard "$base_head"
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/pipe.meta" "window=fm:fm-pipe" "worktree=$d/wt" "kind=ship"
  FM_FAKE_RUN_HEAD="$fix_head"
  FM_FAKE_AXI_STATUS="$(run_fixing fm/feat-pipeline)"
  out=$(run_crew_state "$d" pipe)
  assert_contains "$out" "source: run-step" "descendant pipeline fix head remains run-step"
  assert_contains "$out" "state: working" "active fixing run remains working"
  pass "active run with valid descendant fix head remains current"
}

# Head-binding: local work that advanced past the run head invalidates the run.
test_local_advanced_past_run_head_invalidates() {
  reset_fakes
  local d run_head out
  d=$(new_case local-advanced)
  make_repo_on_branch "$d/wt" fm/feat-adv
  run_head=$(git -C "$d/wt" rev-parse HEAD)
  git -C "$d/wt" commit -q --allow-empty -m 'local stage-2 work after prior run'
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/adv.meta" "window=fm:fm-adv" "worktree=$d/wt" "kind=ship" "harness=claude"
  printf 'working: stage 2 implementation in progress\n' > "$d/state/adv.status"
  FM_FAKE_RUN_HEAD="$run_head"
  FM_FAKE_AXI_STATUS="$(run_parked fm/feat-adv)"
  FM_FAKE_BUSY=0
  arm_idle_record "$d/state" adv
  out=$(run_crew_state "$d" adv)
  assert_not_contains "$out" "source: run-step" "local-advanced tip must not use historical run"
  assert_contains "$out" "source: status-log" "falls back after local advanced past run"
  assert_contains "$out" "state: working" "status-log working: is current"
  pass "local work advanced past run head invalidates attribution"
}

test_missing_run_head_falls_back_to_current_state() {
  reset_fakes
  local d out
  d=$(new_case missing-run-head)
  make_repo_on_branch "$d/wt" fm/feat-no-head
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/no-head.meta" "window=fm:fm-no-head" "worktree=$d/wt" "kind=ship" "harness=claude"
  printf 'working: current stage still in progress\n' > "$d/state/no-head.status"
  FM_FAKE_AXI_STATUS=$(run_parked fm/feat-no-head | grep -v '^  head:')
  FM_FAKE_RUNS_LIST=""
  FM_FAKE_BUSY=0
  arm_idle_record "$d/state" no-head
  out=$(run_crew_state "$d" no-head)
  assert_not_contains "$out" "source: run-step" "missing run head must not permit branch-only attribution"
  assert_contains "$out" "source: status-log" "missing run head falls back to current state sources"
  assert_contains "$out" "state: working" "status-log remains current after missing run head"
  pass "missing run head falls back instead of matching by branch"
}

test_active_run_is_authoritative
test_stale_needs_decision_superseded
test_stale_blocked_superseded
test_genuine_parked_not_superseded
test_scalar_gate_parked_not_superseded
test_gate_block_parked_not_superseded
test_ci_ready_done_log_beats_monitoring_run
test_ci_monitoring_checks_green_surfaces_done
test_top_level_ci_checks_green_surfaces_done
test_ci_monitoring_no_checks_marker_stays_working
test_ci_green_marker_with_zero_check_runs_stays_working
test_ci_green_marker_with_pending_checks_stays_working
test_ci_green_marker_with_failing_checks_stays_working
test_ci_green_marker_with_startup_failure_stays_working
test_ci_green_marker_with_stale_check_stays_working
test_ci_green_marker_with_unreadable_checks_stays_working
test_ci_ready_done_log_with_zero_check_runs_stays_working
test_coarse_ci_ready_done_log_with_zero_check_runs_stays_working
test_no_run_ci_ready_done_log_with_zero_check_runs_stays_working
test_cross_branch_no_run_ci_ready_uses_task_pr
test_no_run_direct_pr_mode_keeps_its_ready_signal
test_no_run_current_busy_supersedes_old_ready_signal
test_checks_passed_outcome_with_zero_check_runs_stays_working
test_checks_passed_outcome_with_green_checks_surfaces_done
test_direct_pr_mode_keeps_its_ready_signal
test_local_only_mode_keeps_its_ready_signal
test_gitlab_merge_request_is_not_judged_by_the_github_probe
test_missing_gh_makes_a_green_reading_unreadable
test_gh_probe_is_time_bounded
test_ci_monitoring_green_then_rearm_stays_working
test_ci_monitoring_no_checks_yet_stays_working
test_ci_monitoring_still_waiting_stays_working
test_ci_monitoring_green_then_new_issue_stays_working
test_ci_ready_done_log_relapse_stays_working
test_ci_fixing_after_green_stays_working
test_top_level_fixing_ci_running_after_green_stays_working
test_top_level_fixing_done_log_stays_working
test_terminal_passed
test_terminal_failed
test_coarse_equal_head_requires_detailed_state
test_coarse_descendant_head_requires_detailed_state
test_coarse_run_does_not_probe_other_branch_ci_log_for_ready_status
test_active_rebased_run_uses_exact_submission_ref
test_active_rebased_run_precedes_all_backend_fallbacks
test_cross_branch_coarse_submission_ref_requires_detailed_state
test_active_rebased_run_rejects_mismatched_submission_ref
test_parked_unresolved_run_head_not_classified_active
test_terminal_unresolved_run_head_not_revived_by_submission_ref
test_other_branch_run_ignored
test_no_run_busy_pane
test_no_run_footer_text_alone_is_not_working
test_no_run_grok_uses_isolated_fallback
test_no_run_herdr_unknown_uses_backend_capture
test_no_run_herdr_idle_agent_status_outranked_by_record
test_no_run_herdr_idle_agent_status_and_idle_record_stays_idle
test_no_run_idle_pane_uses_log
test_no_run_idle_pane_uses_keyed_log
test_no_run_idle_pane_paused
test_no_run_idle_pane_custom_paused_verb
test_no_run_idle_secondmate_resolved_event_not_state
test_dead_window_ignores_stale_status_log
test_dead_window_still_reports_terminal_run_step
test_dead_window_still_reports_active_run_step
test_no_timeout_uses_perl_bound
test_scout_skips_run_lookup
test_torn_down_worktree
test_missing_meta
test_provably_working_via_detailed_submission_state
test_not_provably_working_when_stopped
test_usage_error
test_historical_same_branch_rewritten_head_not_current
test_active_run_descendant_fix_head_remains_current
test_local_advanced_past_run_head_invalidates
test_missing_run_head_falls_back_to_current_state

echo "all fm-crew-state tests passed"
