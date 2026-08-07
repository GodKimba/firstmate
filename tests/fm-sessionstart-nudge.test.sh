#!/usr/bin/env bash
# Behavior tests for both native session-open tiers: the nudge wrapper that
# only asks the agent to take the helm, and the run wrapper that takes it.
#
# The run-wrapper cases drive the REAL bin/fm-session-start.sh against a
# throwaway home, so they prove routing by the digest that actually appears,
# not by inspecting the wrapper's source. docs/sessionstart-nudge.md owns the
# tier assignment and the source table these pin.
set -u

# Run the whole suite beneath one long-lived fixture harness, matching the real
# lifecycle in which startup and later clear/compact hooks share one harness
# ancestor. This also prevents a developer's ambient harness from making the
# portable regression pass locally while failing on a harness-free CI runner.
if [ "${FM_SESSIONSTART_TEST_HARNESS:-0}" != 1 ]; then
  HARNESS_FIXTURE=$(mktemp -d "${TMPDIR:-/tmp}/fm-sessionstart-harness.XXXXXX") || exit 1
  ln -s /bin/bash "$HARNESS_FIXTURE/codex" || exit 1
  # shellcheck disable=SC2016 # Expand in the fixture shell, not this parent.
  FM_SESSIONSTART_TEST_HARNESS=1 "$HARNESS_FIXTURE/codex" \
    -c '"$@"; rc=$?; :; exit "$rc"' _ "$0" "$@"
  HARNESS_STATUS=$?
  rm -rf "$HARNESS_FIXTURE"
  exit "$HARNESS_STATUS"
fi

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

unset NO_MISTAKES_GATE

TMP_ROOT=$(fm_test_tmproot fm-sessionstart-nudge)
NUDGE="$ROOT/bin/fm-sessionstart-nudge.sh"
RUN="$ROOT/bin/fm-sessionstart-run.sh"
# shellcheck source=/dev/null
. "$ROOT/bin/fm-operational-input.sh"
NUDGE_TEXT="Run \`bin/fm-session-start.sh\` now, exactly once, before executing any other instructions."
fm_operational_input_encode session-start "$NUDGE_TEXT" NUDGE_LINE \
  || fail "could not construct expected session-start nudge"
fm_git_identity fmtest fmtest@example.invalid

make_primary() {
  local dir=$1
  mkdir -p "$dir/bin" "$dir/state"
  git init -q "$dir"
  git -C "$dir" commit -q --allow-empty -m init
  : > "$dir/AGENTS.md"
}

run_nudge() {
  local root=$1
  FM_GATE_REFUSE_BYPASS=0 FM_ROOT_OVERRIDE="$root" FM_HOME="$root" "$NUDGE"
}

# Run the wrapper with the launch identity bin/fm-spawn.sh stamps on an ordinary
# kind=ship or kind=scout direct report.
run_nudge_as_crewmate() {
  local root=$1 task=$2
  FM_CREW_TASK="$task" FM_GATE_REFUSE_BYPASS=0 FM_ROOT_OVERRIDE="$root" FM_HOME="$root" "$NUDGE"
}

expect_silent_zero() {
  local label=$1
  shift
  local out status=0
  out=$("$@" 2>&1) || status=$?
  expect_code 0 "$status" "$label must exit 0"
  [ -z "$out" ] || fail "$label must be silent, got: $out"
}

test_genuine_primary_nudges() {
  local root="$TMP_ROOT/primary" out prefix_hex status=0
  make_primary "$root"
  out=$(run_nudge "$root") || status=$?
  expect_code 0 "$status" "genuine primary nudge"
  [ "$out" = "$NUDGE_LINE" ] || fail "genuine primary printed unexpected output: $out"
  prefix_hex=$(printf '%s' "$out" | head -c 3 | od -An -tx1 | tr -d ' \n')
  [ "$prefix_hex" = e281a3 ] || fail "genuine primary nudge lost its U+2063 operational marker: $prefix_hex"
  pass "fm-sessionstart-nudge: a genuine primary gets one explicitly marked instruction line"
}

test_crewmate_identity_is_silent_in_primary_shaped_checkout() {
  local root="$TMP_ROOT/crewmate-plain"
  make_primary "$root"
  expect_silent_zero "crewmate in a plain checkout" \
    run_nudge_as_crewmate "$root" ship-task-1
  pass "fm-sessionstart-nudge: an ordinary worker is silent even in a primary-shaped checkout"
}

test_crewmate_identity_is_silent_with_coordinator_state() {
  local worker="$TMP_ROOT/crewmate-leaked-home" home="$TMP_ROOT/crewmate-leaked-coordinator"
  make_primary "$worker"
  make_primary "$home"
  # The exact leak this fix closes: the worker's own copy of the firstmate repo
  # supplies FM_ROOT while an inherited FM_HOME still names a real coordinator
  # home, so the checkout-shape test alone would resolve a valid primary.
  expect_silent_zero "crewmate with an inherited coordinator home" \
    env FM_CREW_TASK=ship-task-2 FM_GATE_REFUSE_BYPASS=0 \
    FM_ROOT_OVERRIDE="$worker" FM_HOME="$home" "$NUDGE"
  pass "fm-sessionstart-nudge: an inherited coordinator home does not make a worker a primary"
}

test_crewmate_identity_outranks_secondmate_marker() {
  local base="$TMP_ROOT/crewmate-marked-base" root="$TMP_ROOT/crewmate-marked-home"
  fm_git_worktree "$base" "$root" fm/sessionstart-crew-marked
  mkdir -p "$root/bin" "$root/state"
  : > "$root/AGENTS.md"
  printf 'sessionstart-sm\n' > "$root/.fm-secondmate-home"
  # A secondmate marker force-includes an otherwise-exempt linked worktree, so
  # the identity has to refuse ahead of it rather than beside it.
  expect_silent_zero "crewmate in a marked secondmate home" \
    run_nudge_as_crewmate "$root" scout-task-3
  pass "fm-sessionstart-nudge: the worker identity refuses ahead of the secondmate marker"
}

test_secondmate_cleared_identity_still_nudges() {
  local base="$TMP_ROOT/secondmate-cleared-base" root="$TMP_ROOT/secondmate-cleared-home"
  local out status=0
  fm_git_worktree "$base" "$root" fm/sessionstart-secondmate-cleared
  mkdir -p "$root/bin" "$root/state"
  : > "$root/AGENTS.md"
  printf 'sessionstart-sm-cleared\n' > "$root/.fm-secondmate-home"
  # bin/fm-spawn.sh sheds an inherited identity with
  # `export FM_CREW_TASK=; ...`, which leaves the variable SET AND EMPTY.
  # A presence test would read that as a worker and strip every secondmate
  # coordinator's own startup instruction. Written as '' here so the empty
  # assignment is unambiguous to a reader and to the linter. The exact shape is
  # pinned in tests/fm-spawn-dispatch-profile.test.sh.
  out=$(FM_CREW_TASK='' FM_GATE_REFUSE_BYPASS=0 FM_ROOT_OVERRIDE="$root" \
    FM_HOME="$root" "$NUDGE") || status=$?
  expect_code 0 "$status" "secondmate with a cleared identity"
  [ "$out" = "$NUDGE_LINE" ] \
    || fail "a secondmate coordinator that cleared the identity lost its nudge: $out"
  pass "fm-sessionstart-nudge: an explicitly cleared identity is a coordinator, not a worker"
}

test_gate_env_is_silent() {
  local root="$TMP_ROOT/gate-env"
  make_primary "$root"
  expect_silent_zero "gate env nudge" env NO_MISTAKES_GATE=1 FM_GATE_REFUSE_BYPASS=0 \
    FM_ROOT_OVERRIDE="$root" FM_HOME="$root" "$NUDGE"
  pass "fm-sessionstart-nudge: NO_MISTAKES_GATE is silent"
}

test_gate_common_dir_is_silent() {
  local source="$TMP_ROOT/gate-source" bare="$TMP_ROOT/.no-mistakes/repos/gate.git"
  local root="$TMP_ROOT/gate-worktree"
  fm_git_init_commit "$source"
  mkdir -p "$(dirname "$bare")"
  git clone --quiet --bare "$source" "$bare"
  git --git-dir="$bare" worktree add --quiet -b gate-test "$root" HEAD
  mkdir -p "$root/bin" "$root/state"
  : > "$root/AGENTS.md"
  printf 'gate-test\n' > "$root/.fm-secondmate-home"
  expect_silent_zero "gate common-dir nudge" env FM_GATE_REFUSE_BYPASS=0 \
    FM_ROOT_OVERRIDE="$root" FM_HOME="$root" "$NUDGE"
  pass "fm-sessionstart-nudge: .no-mistakes gate common-dir is silent"
}

test_unmarked_linked_worktree_is_silent() {
  local base="$TMP_ROOT/worktree-base" root="$TMP_ROOT/worktree-child"
  fm_git_worktree "$base" "$root" fm/sessionstart-linked
  mkdir -p "$root/bin" "$root/state"
  : > "$root/AGENTS.md"
  expect_silent_zero "linked worktree nudge" run_nudge "$root"
  pass "fm-sessionstart-nudge: an unmarked linked task worktree is silent"
}

test_linked_secondmate_primary_nudges() {
  local base="$TMP_ROOT/secondmate-base" root="$TMP_ROOT/secondmate-home" out status=0
  fm_git_worktree "$base" "$root" fm/sessionstart-secondmate
  mkdir -p "$root/bin" "$root/state"
  : > "$root/AGENTS.md"
  printf 'sessionstart-sm\n' > "$root/.fm-secondmate-home"
  out=$(run_nudge "$root") || status=$?
  expect_code 0 "$status" "linked secondmate nudge"
  [ "$out" = "$NUDGE_LINE" ] || fail "linked secondmate printed unexpected output: $out"
  pass "fm-sessionstart-nudge: a marked linked secondmate home is a primary"
}

test_missing_state_is_silent() {
  local root="$TMP_ROOT/missing-state"
  make_primary "$root"
  rmdir "$root/state"
  expect_silent_zero "missing state nudge" run_nudge "$root"
  pass "fm-sessionstart-nudge: a checkout without state is silent"
}

test_owned_lock_is_silent() {
  local root="$TMP_ROOT/already-ran"
  make_primary "$root"
  printf '%s\n' "$$" > "$root/state/.lock"
  expect_silent_zero "owned lock nudge" run_nudge "$root"
  pass "fm-sessionstart-nudge: a lock holder in process ancestry is already run"
}

# Build a firstmate-shaped repo carrying the tracked Pi extension, plus a home,
# and echo "<repo>|<home>". The wrapper is replaced with a recorder so a test can
# distinguish "the extension did not spawn it" from "it ran and printed nothing".
# The recorder resolves both paths from FM_HOME, which the extension always
# passes down, so this heredoc stays QUOTED. An unquoted one would command-
# substitute the backticks in the nudge text and really run session start.
make_pi_extension_fixture() {
  local repo="$TMP_ROOT/$1-repo" home="$TMP_ROOT/$1-home" wrapper
  mkdir -p "$repo/.pi/extensions/lib" "$repo/bin" "$home/state"
  cp "$ROOT/.pi/extensions/fm-primary-turnend-guard.ts" "$repo/.pi/extensions/"
  cp "$ROOT/.pi/extensions/lib/fm-operational-input.ts" \
    "$ROOT/.pi/extensions/lib/fm-pi-tool-result-images.ts" "$repo/.pi/extensions/lib/"
  # The operational-input library shells out to this script to classify and
  # encode what the extension injects, resolving it relative to the extension's
  # own location. Without it in the fixture repo, every injection fails silently
  # inside the extension's own catch and the case reads as "no nudge".
  cp "$ROOT/bin/fm-operational-input.sh" "$repo/bin/fm-operational-input.sh"
  # The extension calls the RUN wrapper for every session-open reason it maps,
  # and that wrapper delegates to the nudge on the context-preserving ones. Both
  # are stubbed to the same observable shape so these cases stay about the
  # extension's own gate - whether it spawns a wrapper at all - rather than
  # about which wrapper the run tier happens to route to.
  for wrapper in fm-sessionstart-run.sh fm-sessionstart-nudge.sh; do
    cat > "$repo/bin/$wrapper" <<'SH'
#!/usr/bin/env bash
printf 'spawned\n' >> "${FM_HOME:?}/wrapper.log"
cat "${FM_HOME:?}/nudge-line"
SH
    chmod +x "$repo/bin/$wrapper"
  done
  printf '%s\n' "$NUDGE_LINE" > "$home/nudge-line"
  : > "$home/wrapper.log"
  printf '%s|%s\n' "$repo" "$home"
}

# Drive the tracked Pi session_start handler for one reason and echo every
# injected nudge, one per line.
drive_pi_session_start() {
  local ext=$1 home=$2 reason=$3 task=${4:-}
  FM_CREW_TASK="$task" PLUGIN="$ext" FM_HOME="$home" REASON="$reason" \
    node --input-type=module <<'EOF'
import { pathToFileURL } from "node:url";

const handlers = new Map();
const pi = {
  on(event, handler) {
    handlers.set(event, handler);
  },
  sendMessage(message) {
    if (message.customType !== "firstmate-sessionstart-nudge") return;
    process.stdout.write(`${message.content}\n`);
  },
};
const mod = await import(pathToFileURL(process.env.PLUGIN).href);
mod.default(pi);
const handler = handlers.get("session_start");
if (!handler) throw new Error("session_start handler was not registered");
await handler({ type: "session_start", reason: process.env.REASON }, {});
EOF
}

test_pi_extension_suppresses_nudge_for_ordinary_worker() {
  local rec repo home out status=0 reason
  rec=$(make_pi_extension_fixture pi-crewmate)
  IFS='|' read -r repo home <<< "$rec"
  for reason in startup new resume; do
    out=$(drive_pi_session_start "$repo/.pi/extensions/fm-primary-turnend-guard.ts" \
      "$home" "$reason" ship-task-pi) || status=$?
    expect_code 0 "$status" "Pi worker session_start reason=$reason"
    [ -z "$out" ] || fail "Pi worker was injected a startup instruction on $reason: $out"
  done
  # The suppression must happen before the wrapper runs, not by discarding its
  # output afterwards: no coordinator instruction may be produced at all.
  [ ! -s "$home/wrapper.log" ] \
    || fail "Pi worker spawned the session-start wrapper: $(cat "$home/wrapper.log")"
  pass ".pi primary extension: an ordinary worker never produces a startup instruction"
}

test_pi_extension_preserves_nudge_for_true_primary() {
  local rec repo home out status=0 reason count
  rec=$(make_pi_extension_fixture pi-primary)
  IFS='|' read -r repo home <<< "$rec"
  for reason in startup new resume; do
    out=$(drive_pi_session_start "$repo/.pi/extensions/fm-primary-turnend-guard.ts" \
      "$home" "$reason") || status=$?
    expect_code 0 "$status" "Pi primary session_start reason=$reason"
    [ "$out" = "$NUDGE_LINE" ] \
      || fail "Pi primary lost its startup instruction on $reason: $out"
  done
  count=$(grep -c spawned "$home/wrapper.log")
  [ "$count" = 3 ] || fail "Pi primary ran the wrapper $count times across three reasons"
  pass ".pi primary extension: startup, new, and resume keep the true primary instruction"
}

test_pi_extension_treats_cleared_identity_as_coordinator() {
  local rec repo home out status=0
  rec=$(make_pi_extension_fixture pi-secondmate)
  IFS='|' read -r repo home <<< "$rec"
  # Matches the secondmate launch line's `export FM_CREW_TASK=; ...`: set and empty.
  out=$(drive_pi_session_start "$repo/.pi/extensions/fm-primary-turnend-guard.ts" \
    "$home" startup "") || status=$?
  expect_code 0 "$status" "Pi secondmate coordinator session_start"
  [ "$out" = "$NUDGE_LINE" ] \
    || fail "a Pi secondmate coordinator that cleared the identity lost its nudge: $out"
  pass ".pi primary extension: a cleared identity stays a coordinator"
}

test_opencode_plugin_delivers_exact_nudge_once() {
  local root="$TMP_ROOT/opencode-primary" out status=0
  make_primary "$root"
  cp "$ROOT/bin/fm-sessionstart-nudge.sh" "$ROOT/bin/fm-primary-scope-lib.sh" \
    "$ROOT/bin/fm-gate-refuse-lib.sh" "$ROOT/bin/fm-operational-input.sh" "$root/bin/"
  chmod +x "$root/bin/fm-sessionstart-nudge.sh"
  out=$(PLUGIN="$ROOT/.opencode/plugins/fm-primary-sessionstart-nudge.js" \
    WORKTREE="$root" EXPECTED="$NUDGE_LINE" node --input-type=module 2>&1 <<'EOF'
import { pathToFileURL } from "node:url";

const prompts = [];
const client = {
  session: {
    promptAsync: async (request) => {
      prompts.push(request.body.parts[0].text);
    },
  },
};
const mod = await import(pathToFileURL(process.env.PLUGIN).href);
const hooks = await mod.FmPrimarySessionstartNudge({
  client,
  directory: process.env.WORKTREE,
  worktree: process.env.WORKTREE,
});
const event = {
  type: "session.created",
  properties: { sessionID: "session-nudge-test", info: { id: "session-nudge-test" } },
};
await hooks.event({ event });
await hooks.event({ event });
if (prompts.length !== 1) throw new Error(`expected one prompt, got ${prompts.length}`);
if (prompts[0] !== process.env.EXPECTED) throw new Error(`unexpected prompt: ${prompts[0]}`);
EOF
  ) || status=$?
  expect_code 0 "$status" "OpenCode exact nudge delivery"
  [ -z "$out" ] || fail "OpenCode exact nudge delivery printed output: $out"
  pass "OpenCode session.created delivers the exact wrapper nudge once per session"
}

# --- run tier ----------------------------------------------------------------
#
# make_run_primary builds a primary the run wrapper accepts and the REAL
# fm-session-start.sh can execute: a git repo on main so the tangle check
# behaves, plus the home directories the digest reads. The deliberately bare
# PATH keeps every bootstrap probe fast and hermetic - it reports missing tools
# instead of reaching the host's real gh/tmux/tasks-axi.
RUN_PATH=${FM_TEST_BASE_PATH:-/usr/bin:/bin:/usr/sbin:/sbin}

make_run_primary() {
  local dir=$1
  mkdir -p "$dir/bin" "$dir/state" "$dir/data" "$dir/config"
  git init -q -b main "$dir"
  git -C "$dir" commit -q --allow-empty -m init
  : > "$dir/AGENTS.md"
}

run_hook() {  # <root> [args...]
  local root=$1
  shift
  FM_GATE_REFUSE_BYPASS=0 FM_ROOT_OVERRIDE="$root" FM_HOME="$root" PATH="$RUN_PATH" "$RUN" "$@"
}

# Every run-tier assertion keys off the digest banner, which fm-session-start.sh
# prints before the lock result, so routing is proven whether or not the lock
# was won in the test environment.
FULL_BANNER="SESSION START - "
REEMIT_BANNER="SESSION START (CONTEXT RE-EMIT) - "

test_run_startup_runs_the_full_digest() {
  local root="$TMP_ROOT/run-startup" out status=0
  make_run_primary "$root"
  out=$(run_hook "$root" --source startup </dev/null) || status=$?
  expect_code 0 "$status" "run wrapper startup"
  assert_contains "$out" "$FULL_BANNER$root" "startup did not run the full digest"
  assert_contains "$out" "lock acquired: harness pid" \
    "the portable startup fixture did not supply a real harness process"
  assert_not_contains "$out" "$REEMIT_BANNER" "startup was misrouted to a context re-emit"
  assert_not_contains "$out" "FIRSTMATE_OP" "a run-tier open also emitted the nudge instruction"
  assert_contains "$out" "NEXT STEP" "the run wrapper did not deliver a complete digest"
  pass "run wrapper: startup runs the full digest and never also nudges"
}

test_run_clear_and_compact_reemit() {
  local root out source status
  for source in clear compact; do
    root="$TMP_ROOT/run-$source"
    make_run_primary "$root"
    run_hook "$root" --source startup </dev/null >/dev/null
    assert_present "$root/state/.session-start-complete" \
      "startup did not publish the completion proof needed by $source"
    status=0
    out=$(run_hook "$root" --source "$source" </dev/null) || status=$?
    expect_code 0 "$status" "run wrapper $source"
    assert_contains "$out" "$REEMIT_BANNER$root" "$source did not re-emit the digest"
    assert_contains "$out" "are NOT repeated" "$source did not report the skipped startup sweeps"
    assert_contains "$out" "Queued wakes ARE still drained" "$source did not preserve the wake-queue drain"
    assert_not_contains "$out" "FIRSTMATE_OP" "a $source open also emitted the nudge instruction"
  done
  pass "run wrapper: clear and compact re-emit the digest without repeating startup sweeps"
}

test_run_clear_without_completion_finishes_startup() {
  local root="$TMP_ROOT/run-clear-incomplete" out status=0
  make_run_primary "$root"
  out=$(run_hook "$root" --source clear </dev/null) || status=$?
  expect_code 0 "$status" "run wrapper clear without completion proof"
  assert_contains "$out" "$FULL_BANNER$root" \
    "clear skipped full startup when no completed startup could be proven"
  assert_not_contains "$out" "$REEMIT_BANNER" \
    "clear trusted lock ownership as proof that startup completed"
  assert_present "$root/state/.session-start-complete" \
    "the recovery full startup did not publish completion proof"
  pass "run wrapper: clear falls back to full startup when completion is unproven"
}

test_run_clear_rejects_previous_owner_completion() {
  local root="$TMP_ROOT/run-clear-previous-owner" out status=0 previous_pid
  make_run_primary "$root"
  sleep 0 &
  previous_pid=$!
  wait "$previous_pid"
  printf '%s\n' "$previous_pid" > "$root/state/.lock"
  printf '%s\n' "$previous_pid" > "$root/state/.session-start-complete"

  out=$(run_hook "$root" --source clear </dev/null) || status=$?
  expect_code 0 "$status" "run wrapper clear with previous owner completion"
  assert_contains "$out" "$FULL_BANNER$root" \
    "clear treated a previous session's completion as current"
  assert_not_contains "$out" "$REEMIT_BANNER" \
    "clear skipped startup sweeps completed only by a previous session"
  [ "$(cat "$root/state/.lock")" != "$previous_pid" ] \
    || fail "the recovery startup did not replace the previous session's stale lock"
  pass "run wrapper: clear accepts completion only from the current harness"
}

test_pi_large_sessionstart_digest_is_delivered_loudly() {
  local fixture out status=0
  command -v node >/dev/null 2>&1 || {
    echo "skip: node not found for Pi large session-start delivery test"
    return 0
  }
  fixture="$TMP_ROOT/pi-large-digest"
  mkdir -p "$fixture/.pi/extensions/lib" "$fixture/bin" "$fixture/state" "$fixture/data" "$fixture/config"
  git init -q -b main "$fixture"
  git -C "$fixture" commit -q --allow-empty -m init
  : > "$fixture/AGENTS.md"
  cp "$ROOT/.pi/extensions/fm-primary-turnend-guard.ts" "$fixture/.pi/extensions/"
  # Both libs the extension imports: the tool-result image normalizer comes with
  # the operational-input helper, or the extension cannot load at all.
  cp "$ROOT/.pi/extensions/lib/fm-operational-input.ts" \
    "$ROOT/.pi/extensions/lib/fm-pi-tool-result-images.ts" "$fixture/.pi/extensions/lib/"
  cp "$ROOT/bin/fm-sessionstart-run.sh" "$ROOT/bin/fm-sessionstart-nudge.sh" \
    "$ROOT/bin/fm-primary-scope-lib.sh" "$ROOT/bin/fm-gate-refuse-lib.sh" \
    "$ROOT/bin/fm-operational-input.sh" "$fixture/bin/"
  cat > "$fixture/bin/fm-session-start.sh" <<'SH'
#!/usr/bin/env bash
printf 'PI_LARGE_DIGEST_PREFIX\n'
i=0
while [ "$i" -lt 700 ]; do
  printf '%01024d' 0
  i=$((i + 1))
done
printf '\nPI_LARGE_DIGEST_SUFFIX\n'
SH
  chmod +x "$fixture/bin/"*.sh

  out=$(EXT="$fixture/.pi/extensions/fm-primary-turnend-guard.ts" \
    FM_HOME="$fixture" FM_ROOT_OVERRIDE="$fixture" FM_GATE_REFUSE_BYPASS=1 \
    node --input-type=module 2>&1 <<'JS'
import { pathToFileURL } from "node:url";
const handlers = new Map();
const messages = [];
const pi = {
  on(event, handler) { handlers.set(event, handler); },
  sendMessage(message) { messages.push(message); },
};
const extension = await import(`${pathToFileURL(process.env.EXT).href}?large=${Date.now()}`);
extension.default(pi);
await handlers.get("session_start")({ reason: "startup" });
if (messages.length !== 1) throw new Error(`expected one message, got ${messages.length}`);
const content = messages[0].content;
if (!content.includes("PI_LARGE_DIGEST_PREFIX")) throw new Error("digest prefix was lost");
if (!content.includes("PI SESSION-START DELIVERY TRUNCATED")) throw new Error("truncation marker was lost");
if (content.includes("PI_LARGE_DIGEST_SUFFIX")) throw new Error("delivery exceeded its declared bound");
if (!content.includes("FIRSTMATE_OP: v1 session-start:")) throw new Error("operational provenance was lost");
JS
  ) || status=$?
  expect_code 0 "$status" "Pi large session-start delivery"
  [ -z "$out" ] || fail "Pi large session-start delivery printed output: $out"
  pass "Pi retains a bounded digest prefix and loudly marks oversized delivery"
}

test_run_resume_delegates_to_the_nudge() {
  local root="$TMP_ROOT/run-resume" out status=0
  make_run_primary "$root"
  out=$(run_hook "$root" --source resume </dev/null) || status=$?
  expect_code 0 "$status" "run wrapper resume"
  [ "$out" = "$NUDGE_LINE" ] || fail "resume did not delegate to the exact nudge line, got: $out"
  assert_absent "$root/state/.lock" "resume acquired the fleet lock instead of delegating"
  pass "run wrapper: resume delegates to the nudge instead of re-running the digest"
}

test_run_reads_source_from_the_hook_payload() {
  local root="$TMP_ROOT/run-payload" out status=0
  make_run_primary "$root"
  run_hook "$root" --source startup </dev/null >/dev/null
  out=$(printf '{"session_id":"s1","hook_event_name":"SessionStart","source":"compact"}' |
    run_hook "$root") || status=$?
  expect_code 0 "$status" "run wrapper payload compact"
  assert_contains "$out" "$REEMIT_BANNER$root" "a compact hook payload was not routed to a re-emit"

  # A fresh root, because the compact case above legitimately took the lock and
  # an owned lock is exactly when the nudge is supposed to stay silent.
  root="$TMP_ROOT/run-payload-resume"
  make_run_primary "$root"
  status=0
  out=$(printf '{"source":"resume","cwd":"/nowhere"}' | run_hook "$root") || status=$?
  expect_code 0 "$status" "run wrapper payload resume"
  assert_contains "$out" "FIRSTMATE_OP" "a resume hook payload did not delegate to the nudge"
  assert_not_contains "$out" "SESSION START" "a resume hook payload still ran the digest"
  pass "run wrapper: the hook payload's source field drives routing with no explicit argument"
}

test_run_unknown_source_takes_the_helm() {
  local root="$TMP_ROOT/run-unknown" out status=0
  make_run_primary "$root"
  out=$(run_hook "$root" --source somethingnew </dev/null) || status=$?
  expect_code 0 "$status" "run wrapper unknown source"
  assert_contains "$out" "$FULL_BANNER$root" "an unrecognized source did not fall through to the full digest"

  status=0
  out=$(printf '{"hook_event_name":"SessionStart"}' | run_hook "$root") || status=$?
  expect_code 0 "$status" "run wrapper sourceless payload"
  assert_contains "$out" "$FULL_BANNER$root" "a payload with no source did not fall through to the full digest"
  pass "run wrapper: an unrecognized or absent source takes the helm rather than skipping it"
}

test_run_gate_and_scope_are_silent() {
  local root="$TMP_ROOT/run-gate" base="$TMP_ROOT/run-linked-base" linked="$TMP_ROOT/run-linked"
  make_run_primary "$root"
  expect_silent_zero "gate env run" env NO_MISTAKES_GATE=1 FM_GATE_REFUSE_BYPASS=0 \
    FM_ROOT_OVERRIDE="$root" FM_HOME="$root" PATH="$RUN_PATH" "$RUN" --source startup
  assert_absent "$root/state/.lock" "a gate agent's session open still took the fleet lock"

  fm_git_worktree "$base" "$linked" fm/run-linked
  mkdir -p "$linked/bin" "$linked/state"
  : > "$linked/AGENTS.md"
  expect_silent_zero "linked worktree run" run_hook "$linked" --source startup
  assert_absent "$linked/state/.lock" "an unmarked task worktree still took the fleet lock"
  pass "run wrapper: a gate agent and an unmarked task worktree never run a session start"
}

test_run_reports_a_failed_session_start_as_digest_text() {
  local root="$TMP_ROOT/run-unwritable" out status=0
  make_run_primary "$root"
  chmod 0500 "$root/state"
  out=$(run_hook "$root" --source startup </dev/null) || status=$?
  chmod 0700 "$root/state"
  expect_code 0 "$status" "run wrapper with an unwritable state directory"
  assert_contains "$out" "READ-ONLY SESSION" "a failed lock did not reach the agent as digest text"
  pass "run wrapper: a session start that cannot take the lock still opens the session and says so"
}

test_genuine_primary_nudges
test_crewmate_identity_is_silent_in_primary_shaped_checkout
test_crewmate_identity_is_silent_with_coordinator_state
test_crewmate_identity_outranks_secondmate_marker
test_secondmate_cleared_identity_still_nudges
test_pi_extension_suppresses_nudge_for_ordinary_worker
test_pi_extension_preserves_nudge_for_true_primary
test_pi_extension_treats_cleared_identity_as_coordinator
test_gate_env_is_silent
test_gate_common_dir_is_silent
test_unmarked_linked_worktree_is_silent
test_linked_secondmate_primary_nudges
test_missing_state_is_silent
test_owned_lock_is_silent
test_opencode_plugin_delivers_exact_nudge_once
test_run_startup_runs_the_full_digest
test_run_clear_and_compact_reemit
test_run_clear_without_completion_finishes_startup
test_run_clear_rejects_previous_owner_completion
test_run_resume_delegates_to_the_nudge
test_run_reads_source_from_the_hook_payload
test_run_unknown_source_takes_the_helm
test_run_gate_and_scope_are_silent
test_run_reports_a_failed_session_start_as_digest_text
test_pi_large_sessionstart_digest_is_delivered_loudly
