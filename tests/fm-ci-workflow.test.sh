#!/usr/bin/env bash
# Deterministic structural regression tests for the proportional CI workflow.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

WORKFLOW="$ROOT/.github/workflows/ci.yml"
FULL_IF="github.event_name == 'schedule' || github.event_name == 'workflow_dispatch'"

assert_count() {
  local expected=$1 pattern=$2 message=$3 actual
  actual=$(grep -F -c -- "$pattern" "$WORKFLOW" || true)
  [ "$actual" -eq "$expected" ] || fail "$message (expected $expected, got $actual)"
}

assert_regex() {
  grep -E -- "$1" "$2" >/dev/null || fail "$3"
}

assert_not_regex() {
  ! grep -E -- "$1" "$2" >/dev/null || fail "$3"
}

test_triggers_permissions_and_concurrency() {
  assert_regex '^  pull_request:$' "$WORKFLOW" "pull requests do not trigger CI"
  assert_regex '^  push:$' "$WORKFLOW" "main pushes do not trigger CI"
  assert_regex '^  schedule:$' "$WORKFLOW" "nightly full-suite trigger is missing"
  assert_regex '^  workflow_dispatch:$' "$WORKFLOW" "manual full-suite trigger is missing"
  assert_not_regex 'pull_request_target' "$WORKFLOW" "public PRs must not use pull_request_target"
  assert_regex '^permissions:$' "$WORKFLOW" "workflow permissions are not explicit"
  assert_regex '^  contents: read$' "$WORKFLOW" "workflow must retain read-only contents permission"
  assert_not_regex 'secrets\.' "$WORKFLOW" "workflow must not consume repository secrets"
  assert_regex '^concurrency:$' "$WORKFLOW" "workflow concurrency control is missing"
  assert_regex 'github\.workflow.*github\.event_name.*github\.event\.pull_request\.number \|\| github\.ref' \
    "$WORKFLOW" "concurrency group is not scoped by workflow, event, and ref or PR"
  assert_regex "cancel-in-progress:.*github.event_name != 'workflow_dispatch'" \
    "$WORKFLOW" "superseded routine runs are not cancelled safely"
  pass "CI triggers, public-PR permissions, and ref-scoped cancellation stay constrained"
}

test_fast_proof() {
  assert_count 1 '  pr-fast-1:' "routine proof lane 1 must be defined once"
  assert_count 1 '  pr-fast-2:' "routine proof lane 2 must be defined once"
  assert_grep "if: github.event_name == 'pull_request' || github.event_name == 'push'" \
    "$WORKFLOW" "fast proof is not isolated to routine PR and push events"
  assert_regex '^    timeout-minutes: 5$' "$WORKFLOW" "fast proof lost its five-minute tripwire"
  assert_grep 'run: bin/fm-lint.sh' "$WORKFLOW" "fast proof does not use the lint owner"
  assert_grep 'run: bin/fm-test-run.sh --check-coverage' "$WORKFLOW" \
    "fast proof does not validate complete-suite composition"
  assert_grep 'bash tests/fm-ci-workflow.test.sh' "$WORKFLOW" \
    "fast proof does not validate its own routing contract"
  assert_count 2 "if: github.event_name == 'pull_request' || github.event_name == 'push'" \
    "only the two fast proof jobs may run on routine events"
  assert_count 2 'timeout-minutes: 5' "both fast proof jobs need five-minute tripwires"
  assert_grep 'run: bin/fm-test-run.sh --lane portable-parallel-1' "$WORKFLOW" \
    "fast proof does not use measured portable shard 1"
  assert_grep 'run: bin/fm-test-run.sh --lane portable-parallel-2' "$WORKFLOW" \
    "fast proof does not use measured portable shard 2"
  pass "routine CI remains two bounded Ubuntu proofs using existing composition owners"
}

test_complete_suite_routing() {
  assert_count 8 "if: $FULL_IF" "every complete-suite job must be nightly or manual only"
  assert_grep 'run: bin/fm-test-run.sh --lane portable-parallel-1' "$WORKFLOW" \
    "complete suite lost portable parallel shard 1"
  assert_grep 'run: bin/fm-test-run.sh --lane portable-parallel-2' "$WORKFLOW" \
    "complete suite lost portable parallel shard 2"
  assert_grep 'run: bin/fm-test-run.sh --lane portable-serial' "$WORKFLOW" \
    "complete suite lost the portable serial remainder"
  assert_grep 'bin/fm-test-run.sh --family real-herdr-gated' "$WORKFLOW" \
    "complete suite lost the real-Herdr family"
  assert_grep 'name: Full suite - stock macOS Bash compatibility' "$WORKFLOW" \
    "complete suite lost stock macOS Bash compatibility"
  assert_grep 'name: Full suite - lint shell scripts' "$WORKFLOW" \
    "complete suite lost lint"
  assert_grep 'name: Full suite - test coverage guard' "$WORKFLOW" \
    "complete suite lost the coverage guard"
  assert_grep 'name: Full suite - repo invariants' "$WORKFLOW" \
    "complete suite lost repository invariants"
  pass "nightly and manual runs retain every prior regression family and platform guard"
}

test_standard_runners_and_minimal_artifacts() {
  local runner invalid=0
  while IFS= read -r runner; do
    case "$runner" in
      ubuntu-latest|macos-latest) ;;
      *) invalid=1 ;;
    esac
  done < <(awk '/^[[:space:]]+runs-on:/ { print $2 }' "$WORKFLOW")
  [ "$invalid" -eq 0 ] || fail "workflow uses a non-standard runner"
  assert_count 1 'uses: actions/upload-artifact@v4' \
    "only failure diagnostics may use artifact storage"
  assert_regex '^        if: failure\(\)$' "$WORKFLOW" \
    "diagnostic artifact must upload only on failure"
  assert_regex '^          retention-days: 1$' "$WORKFLOW" \
    "diagnostic artifact must use minimum retention"
  assert_not_regex 'download-artifact' "$WORKFLOW" \
    "routine timing transport or aggregation must not consume artifact storage"
  pass "CI uses standard runners and one short-lived failure-only diagnostic artifact"
}

test_triggers_permissions_and_concurrency
test_fast_proof
test_complete_suite_routing
test_standard_runners_and_minimal_artifacts
