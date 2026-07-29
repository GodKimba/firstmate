#!/usr/bin/env bash
# Behavior tests for bin/fm-herdr-lab.sh using a stateful fake Herdr client.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-herdr-lab)
FAKEBIN=$(fm_fakebin "$TMP_ROOT")
FAKE_STATE="$TMP_ROOT/herdr-state"
FAKE_LOG="$TMP_ROOT/herdr.log"
TRIPWIRES="$TMP_ROOT/tripwires"
REAL_SLEEP=$(command -v sleep)
mkdir -p "$FAKE_STATE"
printf '%s\n' default > "$FAKE_STATE/fleet-name"
printf '%s\n' true > "$FAKE_STATE/fleet-default"
printf '%s\n' true > "$FAKE_STATE/fleet-running"
printf '%s\n' '/home/test/.config/herdr/herdr.sock' > "$FAKE_STATE/fleet-socket"
printf '%s\n' '/home/test/.config/herdr' > "$FAKE_STATE/fleet-session-dir"
printf '%s\n' 'w0:p0' > "$FAKE_STATE/fleet-pane"
: > "$FAKE_LOG"

cat > "$FAKEBIN/herdr" <<'SH'
#!/usr/bin/env bash
set -eu
printf '%s\n' "$*" >> "$FM_FAKE_HERDR_LOG"
state=$FM_FAKE_HERDR_STATE
last=
for arg in "$@"; do
  previous=$last
  last=$arg
done
[ "${previous:-}" = --session ] || { echo "fake herdr: missing trailing --session" >&2; exit 90; }
session=$last
fleet_name=$(cat "$state/fleet-name")
fleet_default=$(cat "$state/fleet-default")
fleet_running=$(cat "$state/fleet-running")
fleet_socket=$(cat "$state/fleet-socket")
fleet_session_dir=$(cat "$state/fleet-session-dir")
fleet_pane=$(cat "$state/fleet-pane")
lab_state=absent
[ ! -f "$state/$session" ] || lab_state=$(cat "$state/$session")

case "$1 ${2:-}" in
  "session list")
    lab_json='[]'
    if [ "$lab_state" != absent ] && [ "$lab_state" != deleted ]; then
      running=false
      [ "$lab_state" = running ] && running=true
      lab_json=$(jq -nc --arg name "$session" --argjson running "$running" \
        '[{default:false,name:$name,running:$running,session_dir:("/tmp/" + $name),socket_path:("/tmp/" + $name + ".sock")}]')
    fi
    jq -nc --arg name "$fleet_name" --argjson default "$fleet_default" \
      --argjson running "$fleet_running" --arg socket "$fleet_socket" \
      --arg session_dir "$fleet_session_dir" --argjson labs "$lab_json" \
      '{sessions:([{default:$default,name:$name,running:$running,session_dir:$session_dir,socket_path:$socket}] + $labs)}'
    ;;
  "pane get")
    pane=${3:-}
    if [ "$session" = "$fleet_name" ] && [ "$fleet_running" = true ] && [ "$pane" = "$fleet_pane" ]; then
      jq -nc --arg pane "$pane" '{result:{pane:{pane_id:$pane}}}'
    else
      exit 94
    fi
    ;;
  "server --session")
    if [ "${FM_FAKE_HERDR_SERVER_DELAY:-0}" != 0 ]; then
      "$FM_FAKE_HERDR_REAL_SLEEP" "$FM_FAKE_HERDR_SERVER_DELAY"
    fi
    printf '%s\n' running > "$state/$session"
    ;;
  "status --json")
    if [ "$lab_state" = running ]; then
      printf '%s\n' '{"server":{"running":true}}'
    else
      printf '%s\n' '{"server":{"running":false}}'
    fi
    ;;
  "session stop")
    [ "$3" = "$session" ] || exit 91
    printf '%s\n' stopped > "$state/$session"
    ;;
  "session delete")
    [ "$3" = "$session" ] || exit 92
    [ "${FM_FAKE_HERDR_DELETE_FAIL:-}" != 1 ] || exit 93
    printf '%s\n' deleted > "$state/$session"
    ;;
  *)
    printf '%s\n' '{"ok":true}'
    ;;
esac
SH
chmod +x "$FAKEBIN/herdr"

# shellcheck source=/dev/null
. "$ROOT/bin/fm-herdr-lab.sh"

run_with_fake() {
  PATH="$FAKEBIN:$PATH" \
    FM_FAKE_HERDR_STATE="$FAKE_STATE" \
    FM_FAKE_HERDR_LOG="$FAKE_LOG" \
    FM_FAKE_HERDR_REAL_SLEEP="$REAL_SLEEP" \
    FM_FAKE_HERDR_SERVER_DELAY="${FM_FAKE_HERDR_SERVER_DELAY:-0}" \
    FM_FAKE_HERDR_FAST_POLL="${FM_FAKE_HERDR_FAST_POLL:-}" \
    FM_FAKE_HERDR_DELETE_FAIL="${FM_FAKE_HERDR_DELETE_FAIL:-}" \
    FM_HERDR_LAB_STATE_DIR="$TRIPWIRES" \
    HERDR_ENV="${FM_FAKE_AMBIENT_HERDR_ENV:-}" \
    HERDR_SESSION="${FM_FAKE_AMBIENT_HERDR_SESSION:-}" \
    HERDR_PANE_ID="${FM_FAKE_AMBIENT_HERDR_PANE_ID:-}" \
    HERDR_SOCKET_PATH="${FM_FAKE_AMBIENT_HERDR_SOCKET_PATH:-}" \
    "$@"
}

test_refuses_unsafe_names() {
  local status=0 generated
  fm_herdr_lab_validate_name default >/dev/null 2>&1 || status=$?
  expect_code 1 "$status" "literal default must be refused"
  status=0
  fm_herdr_lab_validate_name arbitrary-session >/dev/null 2>&1 || status=$?
  expect_code 1 "$status" "non-lab prefix must be refused"
  fm_herdr_lab_validate_name fm-lab-safe-123 || fail "valid lab session name was refused"
  generated=$(fm_herdr_lab_name fm-autodetect-smoke-concurrency-h3)
  fm_herdr_lab_validate_name "$generated" || fail "generated lab session name was refused"
  [ "${#generated}" -le 40 ] || fail "generated lab session name is too long for Herdr socket paths: $generated"
  pass "fm-herdr-lab: names fail closed and require the lab prefix"
}

test_provision_run_and_guarded_teardown() {
  local name='' line_count status=0 stop_line delete_line
  name="fm-lab-behavior-$$"
  : > "$FAKE_LOG"
  run_with_fake fm_herdr_lab_provision "$name" || fail "provision failed"
  [ "$(cat "$FAKE_STATE/$name")" = running ] || fail "provision did not start the named lab session"
  assert_present "$TRIPWIRES/$name.fleet-state.json" "provision did not record the fleet-state tripwire"

  run_with_fake fm_herdr_lab_cli "$name" workspace list >/dev/null || fail "safe run command failed"
  run_with_fake fm_herdr_lab_cli "$name" server >/dev/null 2>&1 || status=$?
  expect_code 1 "$status" "bare server start outside provision must be refused"
  status=0
  run_with_fake fm_herdr_lab_cli "$name" server stop >/dev/null 2>&1 || status=$?
  expect_code 1 "$status" "server-global stop must be refused"
  status=0
  run_with_fake fm_herdr_lab_cli "$name" session delete "$name" >/dev/null 2>&1 || status=$?
  expect_code 1 "$status" "direct session delete must be refused"
  status=0
  run_with_fake fm_herdr_lab_cli "$name" status --session default >/dev/null 2>&1 || status=$?
  expect_code 1 "$status" "caller-supplied session flag must be refused"
  status=0
  run_with_fake fm_herdr_lab_cli "$name" status --session=default >/dev/null 2>&1 || status=$?
  expect_code 1 "$status" "caller-supplied equals-form session flag must be refused"
  status=0
  run_with_fake fm_herdr_lab_cli "$name" --handoff server stop >/dev/null 2>&1 || status=$?
  expect_code 1 "$status" "a leading option shifting server stop past the guard must be refused"
  status=0
  run_with_fake fm_herdr_lab_cli "$name" --no-session session delete "$name" >/dev/null 2>&1 || status=$?
  expect_code 1 "$status" "a leading option shifting session delete past the guard must be refused"
  status=0
  run_with_fake fm_herdr_lab_cli "$name" --remote host workspace list >/dev/null 2>&1 || status=$?
  expect_code 1 "$status" "a leading option subverting session isolation must be refused"

  run_with_fake fm_herdr_lab_teardown "$name" || fail "guarded teardown failed"
  [ "$(cat "$FAKE_STATE/$name")" = deleted ] || fail "teardown did not delete the lab session"
  assert_absent "$TRIPWIRES/$name.fleet-state.json" "successful teardown left its tripwire behind"

  while IFS= read -r line; do
    case "$line" in
      *"--session $name") : ;;
      *) fail "Herdr call lacks a trailing lab session: $line" ;;
    esac
  done < "$FAKE_LOG"
  line_count=$(wc -l < "$FAKE_LOG" | tr -d ' ')
  stop_line=$(grep -n "^session stop $name --json --session $name$" "$FAKE_LOG" | cut -d: -f1)
  delete_line=$(grep -n "^session delete $name --json --session $name$" "$FAKE_LOG" | cut -d: -f1)
  if [ -z "$stop_line" ] || [ -z "$delete_line" ] || [ "$line_count" -le "$delete_line" ]; then
    fail "teardown did not emit explicit stop/delete followed by the after tripwire"
  fi
  sed -n "$((stop_line - 1))p" "$FAKE_LOG" | grep -F "session list --json --session $name" >/dev/null \
    || fail "stop was not immediately preceded by a fresh refuse-default session list"
  sed -n "$((delete_line - 1))p" "$FAKE_LOG" | grep -F "session list --json --session $name" >/dev/null \
    || fail "delete was not immediately preceded by a fresh refuse-default session list"
  pass "fm-herdr-lab: provisioning, scoped calls, guarded teardown, and fleet tripwire are deterministic"
}

test_missing_tripwire_blocks_destruction() {
  local name="fm-lab-no-tripwire-$$" status=0 before after
  printf '%s\n' running > "$FAKE_STATE/$name"
  : > "$FAKE_LOG"
  before=$(wc -l < "$FAKE_LOG")
  run_with_fake fm_herdr_lab_teardown "$name" >/dev/null 2>&1 || status=$?
  expect_code 1 "$status" "missing tripwire must refuse teardown"
  after=$(wc -l < "$FAKE_LOG")
  [ "$before" = "$after" ] || fail "missing tripwire reached Herdr instead of refusing before destructive calls"
  pass "fm-herdr-lab: missing tripwire refuses teardown before any Herdr call"
}

test_running_default_compatibility_tripwire() {
  local name="fm-lab-default-compat-$$" snapshot
  : > "$FAKE_LOG"
  FM_FAKE_AMBIENT_HERDR_SESSION=untrusted-selection-only \
    run_with_fake fm_herdr_lab_provision "$name" || fail "default compatibility provision failed"
  snapshot=$(cat "$TRIPWIRES/$name.fleet-state.json")
  [ "$(printf '%s' "$snapshot" | jq -r '.identity.source')" = default-compat ] \
    || fail "outside-Herdr compatibility did not select the running default session"
  [ "$(printf '%s' "$snapshot" | jq -r '.session.name')" = default ] \
    || fail "default compatibility tripwire recorded the wrong fleet session"
  run_with_fake fm_herdr_lab_teardown "$name" || fail "default compatibility teardown failed"
  pass "fm-herdr-lab: outside Herdr, the historical running default session remains the fleet tripwire"
}

test_ambient_named_fleet_session_tripwire() {
  local name="fm-lab-named-fleet-$$" snapshot
  printf '%s\n' firstmate > "$FAKE_STATE/fleet-name"
  printf '%s\n' false > "$FAKE_STATE/fleet-default"
  printf '%s\n' true > "$FAKE_STATE/fleet-running"
  printf '%s\n' '/home/test/.config/herdr/sessions/firstmate/herdr.sock' > "$FAKE_STATE/fleet-socket"
  printf '%s\n' '/home/test/.config/herdr/sessions/firstmate' > "$FAKE_STATE/fleet-session-dir"
  printf '%s\n' 'w2:p2P' > "$FAKE_STATE/fleet-pane"
  : > "$FAKE_LOG"
  FM_FAKE_AMBIENT_HERDR_ENV=1 FM_FAKE_AMBIENT_HERDR_SESSION=fm-lab-selection-only \
    FM_FAKE_AMBIENT_HERDR_PANE_ID=w2:p2P \
    FM_FAKE_AMBIENT_HERDR_SOCKET_PATH='/home/test/.config/herdr/sessions/firstmate/herdr.sock' \
    run_with_fake fm_herdr_lab_provision "$name" || fail "ambient named-fleet provision failed"
  snapshot=$(cat "$TRIPWIRES/$name.fleet-state.json")
  [ "$(printf '%s' "$snapshot" | jq -r '.identity.source')" = ambient-pane ] \
    || fail "ambient Herdr identity did not select the pane-proven path"
  [ "$(printf '%s' "$snapshot" | jq -r '.identity.pane_id')" = w2:p2P ] \
    || fail "ambient tripwire lost the proving pane identity"
  [ "$(printf '%s' "$snapshot" | jq -r '.session.name')" = firstmate ] \
    || fail "ambient tripwire did not preserve the named firstmate session"
  FM_FAKE_AMBIENT_HERDR_ENV=1 FM_FAKE_AMBIENT_HERDR_SESSION=fm-lab-selection-only \
    FM_FAKE_AMBIENT_HERDR_PANE_ID=w2:p2P \
    FM_FAKE_AMBIENT_HERDR_SOCKET_PATH='/home/test/.config/herdr/sessions/firstmate/herdr.sock' \
    run_with_fake fm_herdr_lab_teardown "$name" || fail "ambient named-fleet teardown failed"
  printf '%s\n' default > "$FAKE_STATE/fleet-name"
  printf '%s\n' true > "$FAKE_STATE/fleet-default"
  printf '%s\n' '/home/test/.config/herdr/herdr.sock' > "$FAKE_STATE/fleet-socket"
  printf '%s\n' '/home/test/.config/herdr' > "$FAKE_STATE/fleet-session-dir"
  printf '%s\n' 'w0:p0' > "$FAKE_STATE/fleet-pane"
  pass "fm-herdr-lab: a live named firstmate session is selected by explicit pane identity and preserved exactly"
}

test_incomplete_ambient_identity_refuses_default_fallback() {
  local name="fm-lab-incomplete-ambient-$$" status=0
  : > "$FAKE_LOG"
  FM_FAKE_AMBIENT_HERDR_ENV=1 FM_FAKE_AMBIENT_HERDR_SESSION=firstmate \
    FM_FAKE_AMBIENT_HERDR_PANE_ID='' FM_FAKE_AMBIENT_HERDR_SOCKET_PATH='' \
    run_with_fake fm_herdr_lab_provision "$name" >/dev/null 2>&1 || status=$?
  expect_code 1 "$status" "incomplete ambient identity must not fall back to default"
  assert_absent "$TRIPWIRES/$name.fleet-state.json" \
    "incomplete ambient identity left a fleet ownership tripwire"
  [ ! -e "$FAKE_STATE/$name" ] || fail "incomplete ambient identity started a lab server"
  pass "fm-herdr-lab: incomplete ambient identity refuses rather than guessing or falling back"
}

test_changed_fleet_session_trips_after_teardown() {
  local name="fm-lab-tripwire-change-$$" status=0
  : > "$FAKE_LOG"
  run_with_fake fm_herdr_lab_provision "$name" || fail "tripwire fixture provision failed"
  printf '%s\n' '/changed/default.sock' > "$FAKE_STATE/fleet-socket"
  run_with_fake fm_herdr_lab_teardown "$name" >/dev/null 2>&1 || status=$?
  expect_code 1 "$status" "changed fleet session must fail teardown"
  assert_present "$TRIPWIRES/$name.fleet-state.json" "failed tripwire should retain evidence"
  printf '%s\n' '/home/test/.config/herdr/herdr.sock' > "$FAKE_STATE/fleet-socket"
  rm -f "$TRIPWIRES/$name.fleet-state.json"
  pass "fm-herdr-lab: changed recorded fleet session is a hard failure"
}

test_stopped_owned_lab_can_reprovision() {
  local name="fm-lab-reprovision-$$"
  : > "$FAKE_LOG"
  run_with_fake fm_herdr_lab_provision "$name" || fail "initial provision failed"
  run_with_fake fm_herdr_lab_stop "$name" || fail "guarded stop failed"
  [ "$(cat "$FAKE_STATE/$name")" = stopped ] || fail "guarded stop did not stop the lab session"
  assert_present "$TRIPWIRES/$name.fleet-state.json" "stop removed the lab ownership tripwire"
  run_with_fake fm_herdr_lab_provision "$name" || fail "re-provision after guarded stop failed"
  [ "$(cat "$FAKE_STATE/$name")" = running ] || fail "re-provision did not restart the stopped lab session"
  assert_present "$TRIPWIRES/$name.fleet-state.json" "re-provision removed the lab ownership tripwire"
  run_with_fake fm_herdr_lab_teardown "$name" || fail "teardown after re-provision failed"
  pass "fm-herdr-lab: an owned stopped lab can re-provision safely"
}

test_failed_delete_retains_tripwire() {
  local name="fm-lab-delete-failure-$$" status=0
  : > "$FAKE_LOG"
  run_with_fake fm_herdr_lab_provision "$name" || fail "delete-failure fixture provision failed"
  FM_FAKE_HERDR_DELETE_FAIL=1 run_with_fake fm_herdr_lab_teardown "$name" >/dev/null 2>&1 || status=$?
  expect_code 1 "$status" "failed delete must fail teardown"
  [ "$(cat "$FAKE_STATE/$name")" = stopped ] || fail "failed delete unexpectedly removed the lab session"
  assert_present "$TRIPWIRES/$name.fleet-state.json" "failed delete removed the ownership tripwire"
  run_with_fake fm_herdr_lab_teardown "$name" || fail "retry after failed delete did not clean up the lab session"
  assert_absent "$TRIPWIRES/$name.fleet-state.json" "successful retry left the ownership tripwire behind"
  pass "fm-herdr-lab: failed deletion retains ownership until absence is confirmed"
}

test_timed_out_provision_cancels_late_launch() {
  local name="fm-lab-late-launch-$$" status=0
  cat > "$FAKEBIN/sleep" <<'SH'
#!/usr/bin/env bash
if [ "${FM_FAKE_HERDR_FAST_POLL:-}" = 1 ]; then
  exit 0
fi
exec "$FM_FAKE_HERDR_REAL_SLEEP" "$@"
SH
  chmod +x "$FAKEBIN/sleep"
  : > "$FAKE_LOG"
  FM_FAKE_HERDR_FAST_POLL=1 FM_FAKE_HERDR_SERVER_DELAY=30 \
    run_with_fake fm_herdr_lab_provision "$name" >/dev/null 2>&1 || status=$?
  expect_code 1 "$status" "timed-out provision must fail"
  assert_present "$TRIPWIRES/$name.fleet-state.json" \
    "timed-out provision must retain its tripwire until teardown"
  run_with_fake fm_herdr_lab_teardown "$name" || fail "teardown after timed-out provision failed"
  assert_absent "$TRIPWIRES/$name.fleet-state.json" \
    "teardown after timed-out provision did not remove its tripwire"
  "$REAL_SLEEP" 1.1
  if [ -f "$FAKE_STATE/$name" ] && [ "$(cat "$FAKE_STATE/$name")" = running ]; then
    fail "timed-out provision left a late-starting lab session after teardown"
  fi
  pass "fm-herdr-lab: timed-out provisioning cancels the launch before teardown"
}

test_refuses_unsafe_names
test_provision_run_and_guarded_teardown
test_missing_tripwire_blocks_destruction
test_running_default_compatibility_tripwire
test_ambient_named_fleet_session_tripwire
test_incomplete_ambient_identity_refuses_default_fallback
test_changed_fleet_session_trips_after_teardown
test_stopped_owned_lab_can_reprovision
test_failed_delete_retains_tripwire
test_timed_out_provision_cancels_late_launch
