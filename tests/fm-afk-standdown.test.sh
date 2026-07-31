#!/usr/bin/env bash
# Tests for the away-mode stand-down contract shared by every continuity path.
#
# While state/.afk exists the away supervisor owns the one watcher cycle as its
# own child, so an arm is a terminal non-failure rather than a cycle to retry.
# The reproduced failure class is that a stand-down gets reclassified as an
# unexplained empty cycle: the adapter burns its retry ladder and injects a
# spurious watcher: FAILED wake against the daemon's own healthy watcher. These
# tests cover the arm layer, the Codex checkpoint, the Pi and OpenCode adapters,
# the daemon-owned lock tag, and the stop path's shutdown reconciliation.
#
# docs/watcher-continuity.md "Away-mode stand-down" owns the contract itself.
# Coverage that lives elsewhere and is deliberately not repeated here: Claude's
# already-correct afk boundary (tests/fm-claude-stop-autoarm.test.sh), the
# watcher's own afk triage (tests/fm-watch-triage.test.sh), the Pi and OpenCode
# ordinary cycle shapes (tests/fm-pi-watch-extension.test.sh), afk lifecycle
# state (tests/fm-afk-launch.test.sh), and return catch-up evidence
# (tests/fm-afk-return.test.sh).
#
# shellcheck disable=SC2030,SC2031 # every FM_HOME export is deliberately confined to its own probe subshell, because a leak into this shell would silently retarget the assertions that follow
# shellcheck disable=SC2016 # single quotes are deliberate: the bash -c fixtures expand their own positional arguments, not this shell's
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=tests/pi-fixture-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/pi-fixture-helpers.sh"

TMP_ROOT=$(fm_test_tmproot fm-afk-standdown)
# Resolve the temp root exactly the way bin/fm-watch-arm.sh resolves its own
# script directory (cd then logical pwd, no -P). A TMPDIR with a trailing slash
# makes mktemp return a doubled slash that the arm's cd collapses, so an
# unresolved fixture path never string-matches the recorded watcher-path and the
# arm clears the lock as stale instead of exercising the eviction branch under
# test. -P would introduce the opposite mismatch by resolving /var to /private/var.
# mkdir first: fm_test_tmproot registers its cleanup trap inside the command
# substitution, so the directory is removed as that subshell exits and only comes
# back when a later mkdir -p recreates it.
mkdir -p "$TMP_ROOT"
TMP_ROOT=$(cd "$TMP_ROOT" && pwd)
ARM="$ROOT/bin/fm-watch-arm.sh"
WATCH="$ROOT/bin/fm-watch.sh"
CHECKPOINT="$ROOT/bin/fm-watch-checkpoint.sh"
LAUNCH="$ROOT/bin/fm-afk-launch.sh"
DRAIN="$ROOT/bin/fm-wake-drain.sh"
TURNEND_GUARD="$ROOT/bin/fm-turnend-guard.sh"
OPENCODE_PLUGIN="$ROOT/.opencode/plugins/fm-primary-watch-arm.js"
# Node warns when these test-only dynamic imports load tracked ESM plugins from a
# checkout with no tracked .opencode/package.json; the assertions require the
# adapters' own output to stay empty, so keep the unrelated warning out.
export NODE_NO_WARNINGS=1
# Collapse the adapters' retry ladders so a wrongly-classified stand-down would
# have finished retrying and injected inside every observation window below.
export FM_WATCH_REARM_RETRY_BASE_MS=20
export FM_WATCH_REARM_RETRY_MAX_MS=40
export FM_WATCH_REARM_RETRY_LIMIT=2

make_home() {
  local home="$TMP_ROOT/$1"
  mkdir -p "$home/state" "$home/data" "$home/config"
  printf '%s\n' "$home"
}

make_guard_home() {
  local home
  home=$(make_home "$1")
  mkdir -p "$home/bin"
  git init -q "$home"
  : > "$home/AGENTS.md"
  printf '%s\n' "$home"
}

pid_identity_of() {
  ( export FM_HOME="$1"; . "$ROOT/bin/fm-wake-lib.sh"; fm_pid_identity "$2" )
}

# A private copy of the arm and its libs beside a stub watcher, so a --restart
# test can exercise the real eviction path without ever starting a real watcher.
# fm_watcher_lock_matches_pid compares the lock's watcher-path against
# $SCRIPT_DIR/fm-watch.sh, so the stub has to sit next to the copied arm.
install_arm_fixture() {
  local dir=$1
  mkdir -p "$dir/bin"
  cp "$ROOT/bin/fm-watch-arm.sh" "$dir/bin/fm-watch-arm.sh"
  cp "$ROOT/bin/fm-wake-lib.sh" "$dir/bin/fm-wake-lib.sh"
  cp "$ROOT/bin/fm-classify-lib.sh" "$dir/bin/fm-classify-lib.sh"
  cat > "$dir/bin/fm-watch.sh" <<'SH'
#!/usr/bin/env bash
printf 'watch=%s\n' "$$" >> "${FM_STUB_WATCH_LOG:?}"
printf 'signal: stub cycle\n'
SH
  chmod +x "$dir/bin/fm-watch-arm.sh" "$dir/bin/fm-watch.sh"
}

# Start a fixture process as a GRANDCHILD of this test shell so its own parent
# reaps it the instant it exits. A direct child would linger as a zombie that
# still answers kill -0, which reads as "still running" both to the assertions
# here and to the liveness polls inside the code under test - an eviction would
# look like a refusal, and a finished shutdown would look like a hung daemon.
FM_BG_PID=""
FM_BG_REAPER=""
start_reaped_bg() {
  local pidfile="$TMP_ROOT/reaped-bg.pid" i=0
  rm -f "$pidfile"
  ( "$@" & printf '%s\n' "$!" > "$pidfile"; wait ) &
  FM_BG_REAPER=$!
  while [ ! -s "$pidfile" ] && [ "$i" -lt 100 ]; do
    sleep 0.05
    i=$((i + 1))
  done
  FM_BG_PID=$(cat "$pidfile" 2>/dev/null || true)
  [ -n "$FM_BG_PID" ] || fail "could not start the background fixture process"
}

fm_bg_alive() {
  [ -n "$FM_BG_PID" ] && kill -0 "$FM_BG_PID" 2>/dev/null
}

stop_reaped_bg() {
  [ -z "$FM_BG_PID" ] || kill -KILL "$FM_BG_PID" 2>/dev/null || true
  if [ -n "$FM_BG_REAPER" ]; then
    kill "$FM_BG_REAPER" 2>/dev/null || true
    wait "$FM_BG_REAPER" 2>/dev/null || true
  fi
  FM_BG_PID=""
  FM_BG_REAPER=""
}

# Write a complete watcher lock for <pid>, optionally tagged with an owner.
write_watch_lock() {
  local home=$1 watch_path=$2 pid=$3 owner=${4:-} owner_pid=${5:-}
  local lock="$home/state/.watch.lock" daemon_lock="$home/state/.supervise-daemon.lock"
  mkdir -p "$lock"
  printf '%s\n' "$pid" > "$lock/pid"
  printf '%s\n' "$home" > "$lock/fm-home"
  printf '%s\n' "$watch_path" > "$lock/watcher-path"
  pid_identity_of "$home" "$pid" > "$lock/pid-identity"
  [ -z "$owner" ] || printf '%s\n' "$owner" > "$lock/owner"
  if [ -n "$owner_pid" ]; then
    printf '%s\n' "$owner_pid" > "$lock/owner-pid"
    pid_identity_of "$home" "$owner_pid" > "$lock/owner-pid-identity"
    mkdir -p "$daemon_lock"
    printf '%s\n' "$owner_pid" > "$daemon_lock/pid"
    pid_identity_of "$home" "$owner_pid" > "$daemon_lock/pid-identity"
  fi
}

# --- arm layer --------------------------------------------------------------

test_arm_stands_down_while_away_mode_is_active() {
  local home out status
  home=$(make_home arm-standdown)
  : > "$home/state/.afk"

  out=$(FM_HOME="$home" "$ARM" 2>&1)
  status=$?
  expect_code 0 "$status" "an away-mode arm must end clean, not as a failed cycle"
  assert_contains "$out" "watcher: stood-down" "arm did not report an away-mode stand-down"
  assert_not_contains "$out" "watcher: FAILED" "arm reported a stand-down as a failure"
  assert_not_contains "$out" "watcher: started" "arm started a watcher against the away supervisor"

  # --restart is the adapters' actual invocation, so it must stand down too.
  out=$(FM_HOME="$home" "$ARM" --restart 2>&1)
  status=$?
  expect_code 0 "$status" "an away-mode --restart arm must end clean"
  assert_contains "$out" "watcher: stood-down" "--restart did not report an away-mode stand-down"

  assert_absent "$home/state/.watch.lock" "away-mode arm claimed the watcher singleton"
  assert_absent "$home/state/.last-watcher-beat" "away-mode arm started a watcher anyway"
  pass "arm stands down clean in both modes while away mode is active"
}

test_checkpoint_stands_down_while_away_mode_is_active() {
  local home out status
  home=$(make_home checkpoint-standdown)
  : > "$home/state/.afk"

  out=$(FM_HOME="$home" FM_POLL=1 FM_CHECK_INTERVAL=999999 "$CHECKPOINT" --seconds 1 2>&1)
  status=$?
  # Exit 3, not the quiet-checkpoint 124: a stand-down returns immediately, so a
  # protocol that started the next checkpoint on 124 would spin instead of wait.
  expect_code 3 "$status" "away-mode checkpoint must use its own stop-checkpointing code"
  assert_contains "$out" "checkpoint: stood-down" "checkpoint did not report an away-mode stand-down"
  assert_not_contains "$out" "checkpoint: no actionable wake" "stand-down was reported as a quiet checkpoint"
  assert_absent "$home/state/.watch.lock" "away-mode checkpoint ran a watcher anyway"
  pass "checkpoint stands down with a distinct stop-checkpointing code"
}

# --- daemon-owned lock ------------------------------------------------------

test_owner_tag_requires_verified_daemon_parent() {
  local home watch_path
  home=$(make_home owner-tag)
  watch_path="$ROOT/bin/fm-watch.sh"
  start_reaped_bg sleep 20
  write_watch_lock "$home" "$watch_path" "$FM_BG_PID" away-supervisor "$FM_BG_REAPER"
  ( export FM_HOME="$home"
    . "$ROOT/bin/fm-wake-lib.sh"

    fm_watcher_lock_away_supervised "$home/state" "$watch_path" "$FM_BG_PID" "$home" \
      || fail "an owner=away-supervisor lock was not recognized as daemon-owned"

    printf '%s\n' stale-watcher-identity > "$home/state/.watch.lock/pid-identity"
    ! fm_watcher_lock_away_supervised "$home/state" "$watch_path" "$FM_BG_PID" "$home" \
      || fail "a stale tagged watcher identity was treated as daemon-owned"
    fm_pid_identity "$FM_BG_PID" > "$home/state/.watch.lock/pid-identity"

    printf '%s\n' stale-daemon-identity > "$home/state/.supervise-daemon.lock/pid-identity"
    ! fm_watcher_lock_away_supervised "$home/state" "$watch_path" "$FM_BG_PID" "$home" \
      || fail "a stale daemon identity protected its recorded watcher"
    fm_pid_identity "$FM_BG_REAPER" > "$home/state/.supervise-daemon.lock/pid-identity"

    printf '%s\n' some-other-owner > "$home/state/.watch.lock/owner"
    : > "$home/state/.afk"
    ! fm_watcher_lock_away_supervised "$home/state" "$watch_path" "$FM_BG_PID" "$home" \
      || fail "a foreign owner tag was treated as the away supervisor's lock"
  ) || { stop_reaped_bg; exit 1; }
  stop_reaped_bg

  home=$(make_home forged-owner-tag)
  start_reaped_bg sleep 20
  write_watch_lock "$home" "$watch_path" "$FM_BG_PID" away-supervisor
  ( export FM_HOME="$home"
    . "$ROOT/bin/fm-wake-lib.sh"
    ! fm_watcher_lock_away_supervised "$home/state" "$watch_path" "$FM_BG_PID" "$home" \
      || fail "an unverified owner tag protected an arbitrary watcher"
  ) || { stop_reaped_bg; exit 1; }
  stop_reaped_bg
  pass "owner protection requires exact watcher and live daemon-parent identities"
}

test_owner_environment_requires_verified_daemon() {
  local home output watcher_pid i=0 observed=0 tagged=0
  home=$(make_home owner-env)
  output="$TMP_ROOT/owner-env.out"
  FM_HOME="$home" FM_WATCH_OWNER=away-supervisor FM_POLL=1 FM_HEARTBEAT=999999 \
    FM_CHECK_INTERVAL=999999 "$WATCH" > "$output" 2>&1 &
  watcher_pid=$!
  while [ ! -s "$home/state/.watch.lock/pid" ] && kill -0 "$watcher_pid" 2>/dev/null \
    && [ "$i" -lt 200 ]; do
    sleep 0.02
    i=$((i + 1))
  done
  [ -s "$home/state/.watch.lock/pid" ] && observed=1
  [ -e "$home/state/.watch.lock/owner" ] && tagged=1
  kill -TERM "$watcher_pid" 2>/dev/null || true
  wait "$watcher_pid" 2>/dev/null || true
  [ "$observed" -eq 1 ] || fail "the unverified owner probe never acquired its watcher lock: $(cat "$output" 2>/dev/null || true)"
  [ "$tagged" -eq 0 ] || fail "FM_WATCH_OWNER alone created a protected watcher tag"
  pass "the owner environment value alone cannot claim daemon protection"
}

test_untagged_lock_is_conservative_only_while_away() {
  local home watch_path
  home=$(make_home untagged-lock)
  watch_path="$ROOT/bin/fm-watch.sh"
  start_reaped_bg sleep 20
  write_watch_lock "$home" "$watch_path" "$FM_BG_PID"
  ( export FM_HOME="$home"
    . "$ROOT/bin/fm-wake-lib.sh"

    # Backward compatibility: a lock written before owner tagging carries no tag
    # and is not assumed claimable. While away mode is active the daemon is this
    # home's only legitimate watcher owner, so that evidence decides.
    : > "$home/state/.afk"
    fm_watcher_lock_away_supervised "$home/state" "$watch_path" "$FM_BG_PID" "$home" \
      || fail "an untagged legacy lock was silently claimable during away mode"

    # Outside away mode there is no away supervisor to protect, so an untagged
    # lock stays an ordinary watcher and normal restart recovery is unchanged.
    rm -f "$home/state/.afk"
    ! fm_watcher_lock_away_supervised "$home/state" "$watch_path" "$FM_BG_PID" "$home" \
      || fail "an untagged lock outside away mode blocked ordinary restart recovery"
  ) || { stop_reaped_bg; exit 1; }
  stop_reaped_bg
  pass "an untagged legacy lock is conservative during away mode and evictable outside it"
}

test_daemon_owned_watcher_still_reads_healthy() {
  local home watch_path
  home=$(make_home owner-healthy)
  watch_path="$ROOT/bin/fm-watch.sh"
  start_reaped_bg sleep 20
  write_watch_lock "$home" "$watch_path" "$FM_BG_PID" away-supervisor "$FM_BG_REAPER"
  : > "$home/state/.last-watcher-beat"

  # The owner tag must not leak into the shared liveness predicate. If it did,
  # the turn-end guard, fm-guard.sh, and the session-start digest would all read
  # the daemon's own watcher as down and a fresh watcher could steal the
  # singleton, which is exactly the two-watchers state the tag exists to prevent.
  ( export FM_HOME="$home"
    . "$ROOT/bin/fm-wake-lib.sh"
    fm_watcher_lock_matches_pid "$home/state" "$watch_path" "$FM_BG_PID" "$home" \
      || fail "the owner tag broke identity matching for a daemon-owned lock"
    fm_watcher_healthy "$home/state" "$watch_path" 300 "$home" \
      || fail "a daemon-owned watcher reads unhealthy to the guards"
  ) || { stop_reaped_bg; exit 1; }

  stop_reaped_bg
  pass "a daemon-owned watcher still reads healthy to every shared liveness check"
}

test_turnend_guard_accepts_exact_daemon_handoff() {
  local home lock out status
  home=$(make_guard_home guard-daemon-handoff)
  lock="$home/state/.supervise-daemon.lock"
  : > "$home/state/task.meta"
  : > "$home/state/.afk"
  start_reaped_bg sleep 20
  mkdir -p "$lock"
  printf '%s\n' "$FM_BG_PID" > "$lock/pid"
  pid_identity_of "$home" "$FM_BG_PID" > "$lock/pid-identity"

  out=$(printf '%s\n' '{"stop_hook_active":false}' \
    | FM_ROOT_OVERRIDE="$home" FM_HOME="$home" bash "$TURNEND_GUARD" 2>&1)
  status=$?
  expect_code 0 "$status" "an exact live away daemon must own the watcher-start handoff: $out"
  [ -z "$out" ] || fail "the passive guard alarmed during an exact daemon handoff: $out"

  out=$(printf '%s\n' '{"stop_hook_active":false,"session_id":"afk-handoff"}' \
    | FM_ROOT_OVERRIDE="$home" FM_HOME="$home" bash "$TURNEND_GUARD" --claude 2>&1)
  status=$?
  expect_code 0 "$status" "the Claude guard must accept the same exact daemon handoff: $out"
  [ -z "$out" ] || fail "the Claude guard alarmed during an exact daemon handoff: $out"
  assert_absent "$home/state/.turnend-claude-blocks" "the exact daemon handoff consumed Claude's block budget"

  stop_reaped_bg
  pass "the shared turn-end guard accepts an exact live away-daemon handoff"
}

test_turnend_guard_rejects_missing_or_ambiguous_daemon() {
  local home lock out status
  home=$(make_guard_home guard-ambiguous-daemon)
  lock="$home/state/.supervise-daemon.lock"
  : > "$home/state/task.meta"
  : > "$home/state/.afk"
  start_reaped_bg sleep 20
  mkdir -p "$lock"
  printf '%s\n' "$FM_BG_PID" > "$lock/pid"
  printf '%s\n' stale-daemon-identity > "$lock/pid-identity"

  out=$(printf '%s\n' '{"stop_hook_active":false}' \
    | FM_ROOT_OVERRIDE="$home" FM_HOME="$home" bash "$TURNEND_GUARD" 2>&1)
  status=$?
  expect_code 2 "$status" "a stale daemon identity must retain the guard alarm"
  assert_contains "$out" "TURN WOULD END BLIND" "the stale daemon identity did not surface the guard alarm"
  stop_reaped_bg

  home=$(make_guard_home guard-missing-daemon)
  : > "$home/state/task.meta"
  : > "$home/state/.afk"
  out=$(printf '%s\n' '{"stop_hook_active":false}' \
    | FM_ROOT_OVERRIDE="$home" FM_HOME="$home" bash "$TURNEND_GUARD" 2>&1)
  status=$?
  expect_code 2 "$status" "a missing daemon lock must retain the guard alarm"
  assert_contains "$out" "TURN WOULD END BLIND" "the missing daemon did not surface the guard alarm"
  pass "the shared turn-end guard rejects missing and ambiguous away daemons"
}

test_restart_refuses_to_evict_the_away_supervisors_watcher() {
  local dir home log out status
  dir="$TMP_ROOT/restart-refuse-root"
  home=$(make_home restart-refuse)
  log="$TMP_ROOT/restart-refuse.log"
  install_arm_fixture "$dir"
  start_reaped_bg sleep 20
  # No .afk: this is the window where the flag is already cleared but the daemon
  # has not finished reaping its child. The tag has to hold on its own.
  write_watch_lock "$home" "$dir/bin/fm-watch.sh" "$FM_BG_PID" away-supervisor "$FM_BG_REAPER"

  out=$(FM_HOME="$home" FM_STUB_WATCH_LOG="$log" "$dir/bin/fm-watch-arm.sh" --restart 2>&1)
  status=$?
  expect_code 0 "$status" "refusing to evict the away supervisor's watcher must not be a failure"
  assert_contains "$out" "watcher: stood-down" "--restart did not report the ownership stand-down"
  assert_contains "$out" "$FM_BG_PID" "the stand-down did not name the protected watcher"
  assert_absent "$log" "--restart started a replacement watcher anyway"
  fm_bg_alive || fail "--restart terminated the away supervisor's watcher child"

  stop_reaped_bg
  pass "--restart refuses to signal a daemon-owned watcher"
}

test_restart_evicts_an_unverified_tagged_watcher() {
  local dir home log out status
  dir="$TMP_ROOT/restart-forged-root"
  home=$(make_home restart-forged)
  log="$TMP_ROOT/restart-forged.log"
  install_arm_fixture "$dir"
  start_reaped_bg sleep 20
  write_watch_lock "$home" "$dir/bin/fm-watch.sh" "$FM_BG_PID" away-supervisor

  out=$(FM_HOME="$home" FM_STUB_WATCH_LOG="$log" "$dir/bin/fm-watch-arm.sh" --restart 2>&1)
  status=$?
  expect_code 0 "$status" "an unverified tag must remain recoverable"
  assert_contains "$out" "signal: stub cycle" "an unverified tag blocked replacement startup"
  assert_not_contains "$out" "watcher: stood-down" "an unverified tag claimed daemon protection"
  assert_present "$log" "an unverified tagged watcher was not replaced"
  ! fm_bg_alive || fail "an unverified tagged watcher was not evicted"

  stop_reaped_bg
  pass "--restart evicts a watcher whose owner tag is unverified"
}

test_restart_still_evicts_an_ordinary_watcher() {
  local dir home log out status
  dir="$TMP_ROOT/restart-evict-root"
  home=$(make_home restart-evict)
  log="$TMP_ROOT/restart-evict.log"
  install_arm_fixture "$dir"
  start_reaped_bg sleep 20
  # Untagged and no away mode: an ordinary watcher, so recovery is unchanged.
  write_watch_lock "$home" "$dir/bin/fm-watch.sh" "$FM_BG_PID"

  out=$(FM_HOME="$home" FM_STUB_WATCH_LOG="$log" "$dir/bin/fm-watch-arm.sh" --restart 2>&1)
  status=$?
  expect_code 0 "$status" "ordinary --restart recovery must still complete its cycle"
  assert_contains "$out" "signal: stub cycle" "ordinary --restart did not start a replacement cycle"
  assert_not_contains "$out" "watcher: stood-down" "ordinary --restart was refused as daemon-owned"
  assert_present "$log" "ordinary --restart never launched the replacement watcher"
  # The arm waits for the evicted pid to actually exit before relaunching, so by
  # the time it returns the previous watcher must already be gone.
  ! fm_bg_alive || fail "ordinary --restart left the previous watcher running"

  stop_reaped_bg
  pass "--restart still evicts an ordinary watcher"
}

# --- Pi adapter -------------------------------------------------------------

test_pi_extension_does_not_arm_while_away_mode_is_active() {
  local repo home plugin log out status
  repo="$TMP_ROOT/pi-away-root"
  home=$(make_home pi-away)
  log="$TMP_ROOT/pi-away.log"
  mkdir -p "$repo/bin"
  install_pi_watch_extension_fixture "$repo"
  plugin="$repo/.pi/extensions/fm-primary-pi-watch.ts"
  : > "$home/state/.afk"
  : > "$home/state/task.meta"
  cat > "$repo/bin/fm-watch-arm.sh" <<'SH'
#!/usr/bin/env bash
printf 'arm=%s\n' "$$" >> "${FM_ARM_LOG:?}"
printf 'watcher: started pid=%s (beacon fresh)\n' "$$"
SH
  chmod +x "$repo/bin/fm-watch-arm.sh"

  out=$(PLUGIN="$plugin" FM_HOME="$home" FM_ROOT_OVERRIDE="$repo" FM_ARM_LOG="$log" node --input-type=module 2>&1 <<'EOF'
import { existsSync, writeFileSync } from "node:fs";
import { pathToFileURL } from "node:url";

let tool = null;
let injections = 0;
const pi = {
  on() {},
  registerCommand() {},
  registerTool(candidate) {
    if (candidate.name === "fm_watch_arm_pi") tool = candidate;
  },
  sendUserMessage: async () => {
    injections += 1;
  },
};
writeFileSync(`${process.env.FM_HOME}/state/.lock`, `${process.pid}\n`);
const mod = await import(pathToFileURL(process.env.PLUGIN).href);
mod.default(pi);
const result = await tool.execute("tool-call-away", {}, undefined, undefined, {});
const text = result.content[0]?.text ?? "";
if (!/^watcher: stood-down\b/.test(text)) throw new Error(`expected a stand-down, got: ${text}`);
if (result.details?.ok !== true) throw new Error("a stand-down was reported as a failed arm");
await new Promise((resolve) => setTimeout(resolve, 300));
if (existsSync(process.env.FM_ARM_LOG)) throw new Error("the extension armed during away mode");
if (injections !== 0) throw new Error(`the extension injected ${injections} wakes during away mode`);
EOF
  )
  status=$?
  expect_code 0 "$status" "Pi extension must not arm or inject while away mode is active: $out"
  [ -z "$out" ] || fail "Pi away-mode test printed output: $out"
  pass "Pi extension arms nothing and injects nothing while away mode is active"
}

test_pi_stand_down_is_terminal_not_a_failure() {
  local repo home plugin log out status
  repo="$TMP_ROOT/pi-standdown-root"
  home=$(make_home pi-standdown)
  log="$TMP_ROOT/pi-standdown.log"
  mkdir -p "$repo/bin"
  install_pi_watch_extension_fixture "$repo"
  plugin="$repo/.pi/extensions/fm-primary-pi-watch.ts"
  : > "$home/state/task.meta"
  # The flag is deliberately absent so nothing but classification can save this:
  # the arm layer alone reports the stand-down, exactly as it does when away mode
  # starts inside the arm's own lifetime. An adapter that reads the clean exit as
  # an unexplained empty cycle retries and injects a spurious failure instead.
  cat > "$repo/bin/fm-watch-arm.sh" <<'SH'
#!/usr/bin/env bash
printf 'arm=%s\n' "$$" >> "${FM_ARM_LOG:?}"
printf 'watcher: stood-down - away mode is active; the away supervisor owns the watcher\n'
SH
  chmod +x "$repo/bin/fm-watch-arm.sh"

  out=$(PLUGIN="$plugin" FM_HOME="$home" FM_ROOT_OVERRIDE="$repo" FM_ARM_LOG="$log" node --input-type=module 2>&1 <<'EOF'
import { existsSync, readFileSync, writeFileSync } from "node:fs";
import { pathToFileURL } from "node:url";

let tool = null;
const injected = [];
const pi = {
  on() {},
  registerCommand() {},
  registerTool(candidate) {
    if (candidate.name === "fm_watch_arm_pi") tool = candidate;
  },
  sendUserMessage: async (content) => {
    injected.push(typeof content === "string" ? content : JSON.stringify(content));
  },
};
writeFileSync(`${process.env.FM_HOME}/state/.lock`, `${process.pid}\n`);
const mod = await import(pathToFileURL(process.env.PLUGIN).href);
mod.default(pi);
await tool.execute("tool-call-standdown", {}, undefined, undefined, {});
for (let i = 0; i < 250 && !existsSync(process.env.FM_ARM_LOG); i += 1) {
  await new Promise((resolve) => setTimeout(resolve, 10));
}
// Long enough for the collapsed retry ladder to have run to exhaustion.
await new Promise((resolve) => setTimeout(resolve, 300));
const rows = readFileSync(process.env.FM_ARM_LOG, "utf8").trim().split("\n");
if (rows.length !== 1) throw new Error(`stand-down opened a retry ladder: ${rows.length} arms`);
if (injected.length !== 0) throw new Error(`stand-down injected a wake: ${injected.join(" | ")}`);
EOF
  )
  status=$?
  expect_code 0 "$status" "Pi must treat a stand-down as terminal, with no retry and no failure wake: $out"
  [ -z "$out" ] || fail "Pi stand-down test printed output: $out"
  pass "Pi treats an arm-layer stand-down as terminal, not as an empty-cycle failure"
}

test_pi_rechecks_away_mode_at_final_delivery() {
  local repo home plugin log encoder out status
  repo="$TMP_ROOT/pi-delivery-race-root"
  home=$(make_home pi-delivery-race)
  log="$TMP_ROOT/pi-delivery-race.log"
  encoder="$repo/bin/fm-operational-input-delayed.sh"
  mkdir -p "$repo/bin"
  install_pi_watch_extension_fixture "$repo"
  plugin="$repo/.pi/extensions/fm-primary-pi-watch.ts"
  : > "$home/state/task.meta"
  cat > "$encoder" <<'SH'
#!/usr/bin/env bash
: > "${FM_HOME:?}/state/.afk"
exec "${FM_ROOT_OVERRIDE:?}/bin/fm-operational-input.sh" "$@"
SH
  cat > "$repo/bin/fm-watch-arm.sh" <<'SH'
#!/usr/bin/env bash
printf 'arm=%s\n' "$$" >> "${FM_ARM_LOG:?}"
count=$(wc -l < "$FM_ARM_LOG" | tr -d '[:space:]')
if [ "$count" -eq 1 ]; then
  printf 'signal: delivery race\n'
  exit 0
fi
printf 'watcher: started pid=%s (beacon fresh)\n' "$$"
trap 'exit 0' TERM INT
while [ ! -e "$FM_HOME/state/.afk" ]; do sleep 0.02; done
SH
  chmod +x "$encoder" "$repo/bin/fm-watch-arm.sh"

  out=$(PLUGIN="$plugin" FM_HOME="$home" FM_ROOT_OVERRIDE="$repo" FM_ARM_LOG="$log" \
    FM_OPERATIONAL_INPUT_SCRIPT="$encoder" node --input-type=module 2>&1 <<'EOF'
import { existsSync, readFileSync, writeFileSync } from "node:fs";
import { pathToFileURL } from "node:url";

let tool = null;
let injections = 0;
const pi = {
  on() {},
  registerCommand() {},
  registerTool(candidate) {
    if (candidate.name === "fm_watch_arm_pi") tool = candidate;
  },
  sendUserMessage: async () => {
    injections += 1;
  },
};
writeFileSync(`${process.env.FM_HOME}/state/.lock`, `${process.pid}\n`);
const mod = await import(pathToFileURL(process.env.PLUGIN).href);
mod.default(pi);
await tool.execute("tool-call-delivery-race", {}, undefined, undefined, {});
for (let i = 0; i < 250 && !existsSync(`${process.env.FM_HOME}/state/.afk`); i += 1) {
  await new Promise((resolve) => setTimeout(resolve, 10));
}
if (!existsSync(`${process.env.FM_HOME}/state/.afk`)) throw new Error("the delivery encoder never activated away mode");
await new Promise((resolve) => setTimeout(resolve, 100));
const rows = readFileSync(process.env.FM_ARM_LOG, "utf8").trim().split("\n");
if (rows.length !== 2) throw new Error(`delivery race launched ${rows.length} arm cycles`);
if (injections !== 0) throw new Error(`Pi injected ${injections} wakes after away mode became active`);
process.exit(0);
EOF
  )
  status=$?
  expect_code 0 "$status" "Pi must suppress delivery when away mode starts after successor readiness: $out"
  [ -z "$out" ] || fail "Pi final-delivery test printed output: $out"
  pass "Pi rechecks away mode at its final wake-delivery boundary"
}

test_pi_stand_down_clears_retry_state() {
  local repo home plugin log out status
  repo="$TMP_ROOT/pi-retry-standdown-root"
  home=$(make_home pi-retry-standdown)
  log="$TMP_ROOT/pi-retry-standdown.log"
  mkdir -p "$repo/bin"
  install_pi_watch_extension_fixture "$repo"
  plugin="$repo/.pi/extensions/fm-primary-pi-watch.ts"
  : > "$home/state/task.meta"
  cat > "$repo/bin/fm-watch-arm.sh" <<'SH'
#!/usr/bin/env bash
printf 'arm=%s\n' "$$" >> "${FM_ARM_LOG:?}"
SH
  chmod +x "$repo/bin/fm-watch-arm.sh"

  out=$(PLUGIN="$plugin" FM_HOME="$home" FM_ROOT_OVERRIDE="$repo" FM_ARM_LOG="$log" \
    FM_WATCH_REARM_RETRY_BASE_MS=500 FM_WATCH_REARM_RETRY_MAX_MS=500 \
    FM_WATCH_REARM_RETRY_LIMIT=1 node --input-type=module 2>&1 <<'EOF'
import { existsSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { pathToFileURL } from "node:url";

let tool = null;
let injections = 0;
const pi = {
  on() {},
  registerCommand() {},
  registerTool(candidate) {
    if (candidate.name === "fm_watch_arm_pi") tool = candidate;
  },
  sendUserMessage: async () => {
    injections += 1;
  },
};
const rows = () => existsSync(process.env.FM_ARM_LOG)
  ? readFileSync(process.env.FM_ARM_LOG, "utf8").trim().split("\n")
  : [];
async function waitForRows(count, message) {
  for (let i = 0; i < 250; i += 1) {
    if (rows().length >= count) return;
    await new Promise((resolve) => setTimeout(resolve, 10));
  }
  throw new Error(message);
}
writeFileSync(`${process.env.FM_HOME}/state/.lock`, `${process.pid}\n`);
const mod = await import(pathToFileURL(process.env.PLUGIN).href);
mod.default(pi);
await tool.execute("retry-epoch-1", {}, undefined, undefined, {});
await waitForRows(1, "the first retry epoch did not start");
await new Promise((resolve) => setTimeout(resolve, 150));
writeFileSync(`${process.env.FM_HOME}/state/.afk`, "away\n");
const stoodDown = await tool.execute("retry-standdown", {}, undefined, undefined, {});
if (stoodDown.details?.stoodDown !== true) throw new Error("the pending retry did not enter stand-down");
rmSync(`${process.env.FM_HOME}/state/.afk`);
await new Promise((resolve) => setTimeout(resolve, 600));
if (rows().length !== 1) throw new Error(`a retry timer survived stand-down: ${rows().join(" | ")}`);
await tool.execute("retry-epoch-2", {}, undefined, undefined, {});
await waitForRows(2, "the post-stand-down retry epoch did not start");
await new Promise((resolve) => setTimeout(resolve, 150));
if (injections !== 0) throw new Error(`the post-stand-down failure inherited retry exhaustion: ${injections}`);
EOF
  )
  status=$?
  expect_code 0 "$status" "Pi stand-down must cancel its retry timer and reset its retry count: $out"
  [ -z "$out" ] || fail "Pi retry-state test printed output: $out"
  pass "Pi stand-down cancels pending retries and resets retry exhaustion"
}

# --- OpenCode adapter -------------------------------------------------------

test_opencode_stand_down_is_a_clean_break() {
  local repo home log out status
  repo="$TMP_ROOT/opencode-standdown-root"
  home=$(make_home opencode-standdown)
  log="$TMP_ROOT/opencode-standdown.log"
  mkdir -p "$repo/bin"
  git init -q "$repo"
  : > "$repo/AGENTS.md"
  : > "$home/state/task.meta"
  cat > "$repo/bin/fm-watch-arm.sh" <<'SH'
#!/usr/bin/env bash
printf 'arm=%s\n' "$$" >> "${FM_ARM_LOG:?}"
printf 'watcher: stood-down - away mode is active; the away supervisor owns the watcher\n'
SH
  chmod +x "$repo/bin/fm-watch-arm.sh"

  out=$(PLUGIN="$OPENCODE_PLUGIN" WORKTREE="$repo" FM_HOME="$home" FM_ARM_LOG="$log" node 2>&1 <<'EOF'
import { existsSync, readFileSync, writeFileSync } from "node:fs";
import { pathToFileURL } from "node:url";

const mod = await import(pathToFileURL(process.env.PLUGIN).href);
let prompts = 0;
const client = { session: { promptAsync: async () => { prompts += 1; } } };
const hooks = await mod.FmPrimaryWatchArm({
  client,
  directory: process.env.WORKTREE,
  worktree: process.env.WORKTREE,
});
writeFileSync(`${process.env.FM_HOME}/state/.lock`, `${process.pid}\n`);
await hooks.event({ event: { type: "session.idle", properties: { sessionID: "session-standdown" } } });
for (let i = 0; i < 250 && !existsSync(process.env.FM_ARM_LOG); i += 1) {
  await new Promise((resolve) => setTimeout(resolve, 10));
}
await new Promise((resolve) => setTimeout(resolve, 300));
const rows = readFileSync(process.env.FM_ARM_LOG, "utf8").trim().split("\n");
if (rows.length !== 1) throw new Error(`stand-down opened a retry ladder: ${rows.length} arms`);
if (prompts !== 0) throw new Error(`stand-down delivered ${prompts} wake prompts`);
EOF
  )
  status=$?
  expect_code 0 "$status" "OpenCode must treat a stand-down as a clean break with no delivery: $out"
  [ -z "$out" ] || fail "OpenCode stand-down test printed output: $out"
  pass "OpenCode treats an arm-layer stand-down as a clean break"
}

test_opencode_not_needed_is_a_clean_break() {
  local repo home log out status
  repo="$TMP_ROOT/opencode-not-needed-root"
  home=$(make_home opencode-not-needed)
  log="$TMP_ROOT/opencode-not-needed.log"
  mkdir -p "$repo/bin"
  git init -q "$repo"
  : > "$repo/AGENTS.md"
  : > "$home/state/task.meta"
  # The last task's record disappears while the arm is closing, so restoration
  # finds no supervision need at all. That is a clean break like a stand-down,
  # not a continuity failure worth a retry ladder and a wake.
  cat > "$repo/bin/fm-watch-arm.sh" <<'SH'
#!/usr/bin/env bash
printf 'arm=%s\n' "$$" >> "${FM_ARM_LOG:?}"
rm -f "${FM_META_FILE:?}"
printf 'watcher: started pid=%s (beacon fresh)\n' "$$"
printf 'signal: last task finished\n'
SH
  chmod +x "$repo/bin/fm-watch-arm.sh"

  out=$(PLUGIN="$OPENCODE_PLUGIN" WORKTREE="$repo" FM_HOME="$home" FM_ARM_LOG="$log" \
    FM_META_FILE="$home/state/task.meta" node 2>&1 <<'EOF'
import { existsSync, readFileSync, writeFileSync } from "node:fs";
import { pathToFileURL } from "node:url";

const mod = await import(pathToFileURL(process.env.PLUGIN).href);
let prompts = 0;
const client = { session: { promptAsync: async () => { prompts += 1; } } };
const hooks = await mod.FmPrimaryWatchArm({
  client,
  directory: process.env.WORKTREE,
  worktree: process.env.WORKTREE,
});
writeFileSync(`${process.env.FM_HOME}/state/.lock`, `${process.pid}\n`);
await hooks.event({ event: { type: "session.idle", properties: { sessionID: "session-not-needed" } } });
for (let i = 0; i < 250 && !existsSync(process.env.FM_ARM_LOG); i += 1) {
  await new Promise((resolve) => setTimeout(resolve, 10));
}
await new Promise((resolve) => setTimeout(resolve, 300));
const rows = readFileSync(process.env.FM_ARM_LOG, "utf8").trim().split("\n");
if (rows.length !== 1) throw new Error(`not-needed opened a retry ladder: ${rows.length} arms`);
if (prompts !== 0) throw new Error(`not-needed delivered ${prompts} wake prompts`);
EOF
  )
  status=$?
  expect_code 0 "$status" "OpenCode must treat not-needed as a clean break with no delivery: $out"
  [ -z "$out" ] || fail "OpenCode not-needed test printed output: $out"
  pass "OpenCode treats a not-needed restoration as a clean break"
}

test_opencode_rechecks_away_mode_at_final_delivery() {
  local repo home log out status
  repo="$TMP_ROOT/opencode-delivery-race-root"
  home=$(make_home opencode-delivery-race)
  log="$TMP_ROOT/opencode-delivery-race.log"
  mkdir -p "$repo/bin"
  git init -q "$repo"
  : > "$repo/AGENTS.md"
  : > "$home/state/task.meta"
  cat > "$repo/bin/fm-operational-input.sh" <<'SH'
#!/usr/bin/env bash
: > "${FM_HOME:?}/state/.afk"
exec "${FM_REAL_OPERATIONAL_INPUT_SCRIPT:?}" "$@"
SH
  cat > "$repo/bin/fm-watch-arm.sh" <<'SH'
#!/usr/bin/env bash
printf 'arm=%s\n' "$$" >> "${FM_ARM_LOG:?}"
count=$(wc -l < "$FM_ARM_LOG" | tr -d '[:space:]')
if [ "$count" -eq 1 ]; then
  printf 'signal: delivery race\n'
  exit 0
fi
printf 'watcher: started pid=%s (beacon fresh)\n' "$$"
trap 'exit 0' TERM INT
while [ ! -e "$FM_HOME/state/.afk" ]; do sleep 0.02; done
SH
  chmod +x "$repo/bin/fm-operational-input.sh" "$repo/bin/fm-watch-arm.sh"

  out=$(PLUGIN="$OPENCODE_PLUGIN" WORKTREE="$repo" FM_HOME="$home" FM_ARM_LOG="$log" \
    FM_REAL_OPERATIONAL_INPUT_SCRIPT="$ROOT/bin/fm-operational-input.sh" node 2>&1 <<'EOF'
import { existsSync, readFileSync, writeFileSync } from "node:fs";
import { pathToFileURL } from "node:url";

const mod = await import(pathToFileURL(process.env.PLUGIN).href);
let prompts = 0;
const client = { session: { promptAsync: async () => { prompts += 1; } } };
const hooks = await mod.FmPrimaryWatchArm({
  client,
  directory: process.env.WORKTREE,
  worktree: process.env.WORKTREE,
});
writeFileSync(`${process.env.FM_HOME}/state/.lock`, `${process.pid}\n`);
await hooks.event({ event: { type: "session.idle", properties: { sessionID: "session-delivery-race" } } });
for (let i = 0; i < 250 && !existsSync(`${process.env.FM_HOME}/state/.afk`); i += 1) {
  await new Promise((resolve) => setTimeout(resolve, 10));
}
if (!existsSync(`${process.env.FM_HOME}/state/.afk`)) throw new Error("the delivery encoder never activated away mode");
await new Promise((resolve) => setTimeout(resolve, 100));
const rows = readFileSync(process.env.FM_ARM_LOG, "utf8").trim().split("\n");
if (rows.length !== 2) throw new Error(`delivery race launched ${rows.length} arm cycles`);
if (prompts !== 0) throw new Error(`OpenCode delivered ${prompts} prompts after away mode became active`);
EOF
  )
  status=$?
  expect_code 0 "$status" "OpenCode must suppress delivery when away mode starts during encoding: $out"
  [ -z "$out" ] || fail "OpenCode final-delivery test printed output: $out"
  pass "OpenCode rechecks away mode at its final prompt-delivery boundary"
}

test_opencode_clean_breaks_clear_retry_state() {
  local repo home log out status
  repo="$TMP_ROOT/opencode-retry-standdown-root"
  home=$(make_home opencode-retry-standdown)
  log="$TMP_ROOT/opencode-retry-standdown.log"
  mkdir -p "$repo/bin"
  git init -q "$repo"
  : > "$repo/AGENTS.md"
  : > "$home/state/task.meta"
  cat > "$repo/bin/fm-watch-arm.sh" <<'SH'
#!/usr/bin/env bash
printf 'arm=%s\n' "$$" >> "${FM_ARM_LOG:?}"
SH
  chmod +x "$repo/bin/fm-watch-arm.sh"

  out=$(PLUGIN="$OPENCODE_PLUGIN" WORKTREE="$repo" FM_HOME="$home" FM_ARM_LOG="$log" \
    FM_WATCH_REARM_RETRY_BASE_MS=500 FM_WATCH_REARM_RETRY_MAX_MS=500 \
    FM_WATCH_REARM_RETRY_LIMIT=1 node 2>&1 <<'EOF'
import { existsSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { pathToFileURL } from "node:url";

const mod = await import(pathToFileURL(process.env.PLUGIN).href);
let prompts = 0;
const client = { session: { promptAsync: async () => { prompts += 1; } } };
const hooks = await mod.FmPrimaryWatchArm({
  client,
  directory: process.env.WORKTREE,
  worktree: process.env.WORKTREE,
});
const rows = () => existsSync(process.env.FM_ARM_LOG)
  ? readFileSync(process.env.FM_ARM_LOG, "utf8").trim().split("\n")
  : [];
async function waitForRows(count, message) {
  for (let i = 0; i < 250; i += 1) {
    if (rows().length >= count) return;
    await new Promise((resolve) => setTimeout(resolve, 10));
  }
  throw new Error(message);
}
writeFileSync(`${process.env.FM_HOME}/state/.lock`, `${process.pid}\n`);
await hooks.event({ event: { type: "session.idle", properties: { sessionID: "retry-epoch-1" } } });
await waitForRows(1, "the first retry epoch did not start");
await new Promise((resolve) => setTimeout(resolve, 150));
writeFileSync(`${process.env.FM_HOME}/state/.afk`, "away\n");
const stoodDown = await globalThis.__firstmateOpenCodeWatchArm.ensureArmed("retry-standdown", client);
if (stoodDown !== "stood-down") throw new Error(`the pending retry did not enter stand-down: ${stoodDown}`);
rmSync(`${process.env.FM_HOME}/state/.afk`);
await new Promise((resolve) => setTimeout(resolve, 600));
if (rows().length !== 1) throw new Error(`a retry timer survived stand-down: ${rows().join(" | ")}`);

await globalThis.__firstmateOpenCodeWatchArm.ensureArmed("retry-epoch-2", client);
await waitForRows(2, "the post-stand-down retry epoch did not start");
await new Promise((resolve) => setTimeout(resolve, 150));
rmSync(`${process.env.FM_HOME}/state/task.meta`);
await new Promise((resolve) => setTimeout(resolve, 600));
if (rows().length !== 2) throw new Error(`a not-needed clean break launched another arm: ${rows().join(" | ")}`);

writeFileSync(`${process.env.FM_HOME}/state/task.meta`, "task\n");
await globalThis.__firstmateOpenCodeWatchArm.ensureArmed("retry-epoch-3", client);
await waitForRows(3, "the post-not-needed retry epoch did not start");
await new Promise((resolve) => setTimeout(resolve, 150));
if (prompts !== 0) throw new Error(`a clean break inherited retry exhaustion: ${prompts}`);
EOF
  )
  status=$?
  expect_code 0 "$status" "OpenCode clean breaks must cancel retry timers and reset retry counts: $out"
  [ -z "$out" ] || fail "OpenCode retry-state test printed output: $out"
  pass "OpenCode clean breaks cancel pending retries and reset retry exhaustion"
}

# --- shutdown reconciliation ------------------------------------------------

stop_ticks_with() {
  local home=$1
  shift
  # fm-afk-launch.sh sources fm-afk-start.sh, which sets -eu, so drive it from a
  # child shell rather than leaking that into this test file.
  env FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" "$@" \
    bash -c '. "$1"; fm_afk_launch_stop_ticks' _ "$LAUNCH"
}

test_stop_timeout_encodes_the_measured_shutdown_floor() {
  local home ticks
  home=$(make_home stop-ticks)
  # The wait is expressed in 0.25s ticks and defaults to the daemon's measured
  # shutdown floor with margin, not to a round guess.
  ticks=$(stop_ticks_with "$home")
  [ "$ticks" = 180 ] || fail "default stop wait is $ticks ticks, expected 45 seconds (180)"
  ticks=$(stop_ticks_with "$home" FM_AFK_STOP_TIMEOUT=2)
  [ "$ticks" = 8 ] || fail "FM_AFK_STOP_TIMEOUT=2 produced $ticks ticks, expected 8"
  # A malformed or zero override falls back to the derived default instead of
  # collapsing the wait to nothing, which would make expiry the common case.
  ticks=$(stop_ticks_with "$home" FM_AFK_STOP_TIMEOUT=nonsense)
  [ "$ticks" = 180 ] || fail "a malformed stop timeout produced $ticks ticks instead of the default"
  ticks=$(stop_ticks_with "$home" FM_AFK_STOP_TIMEOUT=0)
  [ "$ticks" = 180 ] || fail "a zero stop timeout produced $ticks ticks instead of the default"
  pass "the shutdown wait is a bounded, overridable derivation of the measured floor"
}

# Stage an away-mode daemon whose TERM trap is DEFERRED behind a foreground
# command, the shape measured in the reproduction: bash runs a trap only once the
# command it is waiting on returns, so shutdown always costs at least that long
# no matter when the signal lands. It then exits cleanly.
stage_deferred_daemon() {
  local home=$1 defer=$2 lock="$1/state/.supervise-daemon.lock"
  date '+%s' > "$home/state/.afk"
  printf 'none\t-\tnative\n' > "$home/state/.afk-daemon-terminal"
  start_reaped_bg bash -c 'trap "exit 0" TERM; sleep "$1"; exit 0' _ "$defer"
  mkdir -p "$lock"
  printf '%s' "$FM_BG_PID" > "$lock/pid"
  pid_identity_of "$home" "$FM_BG_PID" > "$lock/pid-identity"
}

test_stop_wait_absorbs_a_deferred_shutdown_trap() {
  local home out status
  # The reproduced regression: a bound below the daemon's real shutdown floor
  # turns an ordinary shutdown into a reported failure on every busy home.
  home=$(make_home stop-short-bound)
  stage_deferred_daemon "$home" 3
  out=$(FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_AFK_STOP_TIMEOUT=1 "$LAUNCH" stop 2>&1)
  status=$?
  expect_code 1 "$status" "a bound under the shutdown floor must not claim success: $out"
  assert_present "$home/state/.afk" "away mode was cleared before the daemon finished shutting down"
  stop_reaped_bg

  # The same daemon under a bound that covers the floor: the wait absorbs the
  # deferral, the daemon exits inside it, and the stop reports the ordinary
  # success it always was.
  home=$(make_home stop-derived-bound)
  stage_deferred_daemon "$home" 2
  out=$(FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_AFK_STOP_TIMEOUT=15 "$LAUNCH" stop 2>&1)
  status=$?
  expect_code 0 "$status" "a deferred shutdown trap inside the bound must not be a failure: $out"
  assert_not_contains "$out" "preserving lifecycle state" "an ordinary shutdown was reported as unconfirmed"
  assert_absent "$home/state/.afk" "away mode stayed on after a completed shutdown"
  stop_reaped_bg
  pass "the shutdown wait absorbs a deferred trap instead of reporting a failure"
}

test_stop_preserves_state_for_a_genuinely_live_daemon() {
  local home lock daemon_pid out status
  home=$(make_home stop-preserve)
  date '+%s' > "$home/state/.afk"
  printf 'none\t-\tnative\n' > "$home/state/.afk-daemon-terminal"
  : > "$home/state/.subsuper-escalations"
  lock="$home/state/.supervise-daemon.lock"
  # A daemon that ignores the signal entirely and keeps its lock. Nothing proves
  # it stopped injecting, so every piece of lifecycle and catch-up evidence has
  # to survive.
  bash -c 'trap "" TERM; while :; do sleep 0.2; done' &
  daemon_pid=$!
  mkdir -p "$lock"
  printf '%s' "$daemon_pid" > "$lock/pid"
  pid_identity_of "$home" "$daemon_pid" > "$lock/pid-identity"

  out=$(FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_AFK_STOP_TIMEOUT=1 "$LAUNCH" stop 2>&1)
  status=$?
  expect_code 1 "$status" "a live daemon holding its lock must not be reported as stopped: $out"
  assert_contains "$out" "preserving lifecycle state" "the stop path did not report preservation"
  assert_present "$home/state/.afk" "away mode was cleared while the daemon was still live"
  assert_present "$home/state/.afk-daemon-terminal" "the daemon terminal record was dropped"
  assert_present "$home/state/.subsuper-escalations" "buffered catch-up evidence was dropped"

  kill -KILL "$daemon_pid" 2>/dev/null || true
  wait "$daemon_pid" 2>/dev/null || true
  pass "a genuinely live daemon preserves away mode and all catch-up evidence"
}

# --- durable queue ----------------------------------------------------------

test_stand_down_leaves_queued_wakes_for_return_catch_up() {
  local home before after drained
  home=$(make_home standdown-queue)
  : > "$home/state/.afk"
  ( export FM_HOME="$home"
    . "$ROOT/bin/fm-wake-lib.sh"
    fm_wake_append signal task-a 'done: fix landed'
  ) || fail "could not seed the durable wake queue"
  before=$(cat "$home/state/.wake-queue")

  FM_HOME="$home" "$ARM" >/dev/null 2>&1
  FM_HOME="$home" FM_POLL=1 FM_CHECK_INTERVAL=999999 "$CHECKPOINT" --seconds 1 >/dev/null 2>&1

  # Suppressing delivery is not the same as consuming the wake: the away
  # supervisor triages from the queue and return catch-up replays it, so a
  # stand-down must never drain it out of band.
  after=$(cat "$home/state/.wake-queue")
  [ "$before" = "$after" ] || fail "a stand-down changed the durable wake queue"
  drained=$(FM_HOME="$home" "$DRAIN" 2>&1)
  assert_contains "$drained" "done: fix landed" "the away-mode wake was lost before return catch-up"
  pass "stand-downs leave queued wakes intact for the daemon and return catch-up"
}

test_arm_stands_down_while_away_mode_is_active
test_checkpoint_stands_down_while_away_mode_is_active
test_owner_tag_requires_verified_daemon_parent
test_owner_environment_requires_verified_daemon
test_untagged_lock_is_conservative_only_while_away
test_daemon_owned_watcher_still_reads_healthy
test_turnend_guard_accepts_exact_daemon_handoff
test_turnend_guard_rejects_missing_or_ambiguous_daemon
test_restart_refuses_to_evict_the_away_supervisors_watcher
test_restart_evicts_an_unverified_tagged_watcher
test_restart_still_evicts_an_ordinary_watcher
test_pi_extension_does_not_arm_while_away_mode_is_active
test_pi_stand_down_is_terminal_not_a_failure
test_pi_rechecks_away_mode_at_final_delivery
test_pi_stand_down_clears_retry_state
test_opencode_stand_down_is_a_clean_break
test_opencode_not_needed_is_a_clean_break
test_opencode_rechecks_away_mode_at_final_delivery
test_opencode_clean_breaks_clear_retry_state
test_stop_timeout_encodes_the_measured_shutdown_floor
test_stop_wait_absorbs_a_deferred_shutdown_trap
test_stop_preserves_state_for_a_genuinely_live_daemon
test_stand_down_leaves_queued_wakes_for_return_catch_up
