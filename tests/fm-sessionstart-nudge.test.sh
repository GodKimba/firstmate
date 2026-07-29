#!/usr/bin/env bash
# Behavior and tracked-registration tests for the native session-start nudge.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

unset NO_MISTAKES_GATE

TMP_ROOT=$(fm_test_tmproot fm-sessionstart-nudge)
NUDGE="$ROOT/bin/fm-sessionstart-nudge.sh"
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
  local repo="$TMP_ROOT/$1-repo" home="$TMP_ROOT/$1-home"
  mkdir -p "$repo/.pi/extensions/lib" "$repo/bin" "$home/state"
  cp "$ROOT/.pi/extensions/fm-primary-turnend-guard.ts" "$repo/.pi/extensions/"
  cp "$ROOT/.pi/extensions/lib/fm-operational-input.ts" \
    "$ROOT/.pi/extensions/lib/fm-pi-tool-result-images.ts" "$repo/.pi/extensions/lib/"
  cat > "$repo/bin/fm-sessionstart-nudge.sh" <<'SH'
#!/usr/bin/env bash
printf 'spawned\n' >> "${FM_HOME:?}/wrapper.log"
cat "${FM_HOME:?}/nudge-line"
SH
  chmod +x "$repo/bin/fm-sessionstart-nudge.sh"
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

test_tracked_harness_registration() {
  local command pi_plugin opencode_plugin
  jq -e '.hooks.SessionStart | length == 1' "$ROOT/.claude/settings.json" >/dev/null \
    || fail "Claude SessionStart hook is not registered exactly once"
  jq -e '.hooks.SessionStart[0].matcher == "startup|resume|clear"' "$ROOT/.claude/settings.json" >/dev/null \
    || fail "Claude SessionStart matcher must include startup/resume/clear and exclude compact"
  jq -e 'any(.hooks.SessionStart[]?.hooks[]?.command?; contains("fm-sessionstart-nudge.sh"))' \
    "$ROOT/.claude/settings.json" >/dev/null || fail "Claude SessionStart hook does not invoke the wrapper"

  command=$(jq -r '.hooks.SessionStart[0].hooks[0].command' "$ROOT/.codex/hooks.json")
  # shellcheck disable=SC2016
  assert_contains "$command" 'payload=$(cat' "Codex SessionStart hook does not read its payload"
  # shellcheck disable=SC2016
  assert_contains "$command" 'root=$(pwd -P)' "Codex SessionStart hook is not pwd-anchored"
  assert_contains "$command" 'fm-sessionstart-nudge.sh' "Codex SessionStart hook does not invoke the wrapper"

  command=$(jq -r '.hooks.SessionStart[0].hooks[0].command' "$ROOT/.grok/hooks/fm-primary-sessionstart-nudge.json")
  # shellcheck disable=SC2016
  assert_contains "$command" '${GROK_WORKSPACE_ROOT:-}' "Grok SessionStart hook lacks an inline-default workspace root"
  # shellcheck disable=SC2016
  assert_not_contains "$command" '${GROK_WORKSPACE_ROOT}' "Grok SessionStart hook contains a bare variable expansion"
  assert_contains "$command" 'fm-sessionstart-nudge.sh' "Grok SessionStart hook does not invoke the wrapper"

  pi_plugin=$(cat "$ROOT/.pi/extensions/fm-primary-turnend-guard.ts")
  assert_contains "$pi_plugin" '["startup", "new", "resume"]' "Pi SessionStart handler has the wrong reason allowlist"
  assert_contains "$pi_plugin" 'fm-sessionstart-nudge.sh' "Pi SessionStart handler does not invoke the wrapper"
  assert_contains "$pi_plugin" 'firstmate-sessionstart-nudge' "Pi SessionStart handler does not inject a custom context message"
  assert_contains "$pi_plugin" 'details: { kind: "session-start" }' "Pi SessionStart context does not retain its exact structured kind"
  assert_contains "$pi_plugin" 'pi.sendMessage' "Pi SessionStart handler does not use the context-safe message API"
  assert_contains "$pi_plugin" 'if (launchedAsCrewmate()) return ""' \
    "Pi SessionStart handler no longer refuses before spawning the wrapper for a worker"
  assert_contains "$pi_plugin" '(process.env.FM_CREW_TASK ?? "") !== ""' \
    "Pi launch-identity check drifted from the non-empty contract in bin/fm-primary-scope-lib.sh"

  opencode_plugin=$(cat "$ROOT/.opencode/plugins/fm-primary-sessionstart-nudge.js")
  assert_contains "$opencode_plugin" 'session.created' "OpenCode plugin does not listen for session.created"
  assert_contains "$opencode_plugin" 'fm-sessionstart-nudge.sh' "OpenCode plugin does not invoke the wrapper"
  assert_contains "$opencode_plugin" 'promptAsync' "OpenCode plugin does not prompt the nudge turn"

  pass "all five verified harnesses register the shared session-start nudge"
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
test_tracked_harness_registration
