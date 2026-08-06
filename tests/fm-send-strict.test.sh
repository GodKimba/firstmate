#!/usr/bin/env bash
# fm-send strict target resolution.
#
# A send that cannot be tied to a recorded task/lane or to an explicit
# well-formed backend target must fail loudly. These tests pin the historical
# silent-fallback failures: missing FM_HOME, unresolved selectors, prefixless
# herdr pane ids, dead explicit endpoints, and the healthy exact/fm-id paths.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=/dev/null
. "$ROOT/bin/fm-classify-lib.sh"

SEND="$ROOT/bin/fm-send.sh"
TMP_ROOT=$(fm_test_tmproot fm-send-strict)

make_stubs() {  # <dir> -> echoes fakebin dir
  local dir=$1 fb="$1/fakebin"
  mkdir -p "$fb"
  cat > "$fb/tmux" <<'SH'
#!/usr/bin/env bash
set -u
case "${1:-}" in
  send-keys)
    shift
    literal=0
    target=
    while [ $# -gt 0 ]; do
      case "$1" in
        -t) target=$2; shift 2 ;;
        -l) literal=1; shift ;;
        *) break ;;
      esac
    done
    printf 'send-keys target=%s literal=%s arg=%s\n' "$target" "$literal" "${1:-}" >> "$FM_TMUX_LOG"
    exit 0 ;;
  display-message)
    target=
    cursor=0
    while [ $# -gt 0 ]; do
      case "$1" in
        -t) target=$2; shift 2 ;;
        *cursor_y*) cursor=1; shift ;;
        *) shift ;;
      esac
    done
    if [ -n "${FM_FAKE_TMUX_DEAD_TARGET:-}" ] && [ "$target" = "$FM_FAKE_TMUX_DEAD_TARGET" ]; then
      exit 1
    fi
    [ "$cursor" = 1 ] && { printf '1\n'; exit 0; }
    printf '%%1\n'
    exit 0 ;;
  capture-pane)
    # FM_FAKE_TMUX_UNSENT keeps the typed text in the composer, so submit
    # confirmation reports the message as genuinely unsent.
    if [ -n "${FM_FAKE_TMUX_UNSENT:-}" ]; then
      printf '╭──────────────────────╮\n│ > still in the box   │\n╰──────────────────────╯\n'
    else
      printf '╭────╮\n│    │\n╰────╯\n'
    fi
    exit 0 ;;
  list-windows)
    printf 'foreign:%s\n' "${FM_FAKE_TMUX_WINDOW:-fm-lost}"
    exit 0 ;;
esac
exit 0
SH
  chmod +x "$fb/tmux"
  cat > "$fb/herdr" <<'SH'
#!/usr/bin/env bash
set -u
printf '%s\n' "$*" >> "$FM_HERDR_LOG"
case "${1:-} ${2:-}" in
  "status --json") printf '{"client":{"version":"0.7.5","protocol":16},"server":{"running":true}}\n' ;;
  "pane get") printf '{"result":{"pane":{"pane_id":"%s"}}}\n' "${3:-}" ;;
  "pane send-keys") : ;;
esac
SH
  chmod +x "$fb/herdr"
  cat > "$fb/sleep" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  chmod +x "$fb/sleep"
  printf '%s\n' "$fb"
}

setup_home() {  # <name> -> echoes home dir
  local home="$TMP_ROOT/$1-$RANDOM"
  mkdir -p "$home/state"
  printf '%s\n' "$home"
}

test_exact_lane_id_send_still_works() {
  local dir fb home err log rc got
  dir="$TMP_ROOT/exact"; mkdir -p "$dir"
  fb=$(make_stubs "$dir"); home=$(setup_home exact); err="$dir/send.err"; log="$dir/tmux.log"; : > "$log"
  fm_write_meta "$home/state/mpf-lane-m8.meta" "window=sess:fm-mpf-lane-m8" "kind=ship"

  PATH="$fb:$PATH" FM_HOME="$home" FM_ROOT_OVERRIDE="$home" FM_TMUX_LOG="$log" FM_SEND_SETTLE=0 \
    "$SEND" mpf-lane-m8 "lost dispatch" >/dev/null 2>"$err"; rc=$?
  expect_code 0 "$rc" "exact task id send should succeed when metadata exists"
  got=$(cat "$log")
  assert_contains "$got" "target=sess:fm-mpf-lane-m8 literal=1 arg=lost dispatch" "exact id should type literal text to the meta target"
  assert_contains "$got" "target=sess:fm-mpf-lane-m8 literal=0 arg=Enter" "exact id should submit with Enter"
  pass "fm-send strict: exact task/lane ids resolve through home metadata"
}

test_unset_fm_home_fails() {
  local dir fb err log rc
  dir="$TMP_ROOT/nohome"; mkdir -p "$dir"
  fb=$(make_stubs "$dir"); err="$dir/send.err"; log="$dir/tmux.log"; : > "$log"

  env -u FM_HOME PATH="$fb:$PATH" FM_ROOT_OVERRIDE="$dir" FM_TMUX_LOG="$log" FM_SEND_SETTLE=0 \
    "$SEND" sess:win "hello" >/dev/null 2>"$err"; rc=$?
  [ "$rc" -ne 0 ] || fail "unset FM_HOME should fail"
  assert_contains "$(cat "$err")" "FM_HOME is not set" "unset FM_HOME diagnostic should be explicit"
  [ ! -s "$log" ] || fail "unset FM_HOME still attempted a send"$'\n'"$(cat "$log")"
  pass "fm-send strict: unset FM_HOME fails before target resolution"
}

test_unresolvable_target_does_not_tmux_fallback() {
  local dir fb home err log rc
  dir="$TMP_ROOT/unresolved"; mkdir -p "$dir"
  fb=$(make_stubs "$dir"); home=$(setup_home unresolved); err="$dir/send.err"; log="$dir/tmux.log"; : > "$log"

  PATH="$fb:$PATH" FM_HOME="$home" FM_ROOT_OVERRIDE="$home" FM_TMUX_LOG="$log" FM_FAKE_TMUX_WINDOW=lost-target FM_SEND_SETTLE=0 \
    "$SEND" lost-target "hello" >/dev/null 2>"$err"; rc=$?
  [ "$rc" -ne 0 ] || fail "unresolvable target should fail"
  assert_contains "$(cat "$err")" "not resolvable" "unresolvable diagnostic should be loud"
  assert_contains "$(cat "$err")" "metadata window/terminal lookup" "unresolvable diagnostic should name the attempted lookup"
  assert_contains "$(cat "$err")" "backend=none" "unresolvable diagnostic should name that no backend was assumed"
  [ ! -s "$log" ] || fail "unresolvable target fell through to tmux send"$'\n'"$(cat "$log")"
  pass "fm-send strict: unresolvable selectors do not fall back to tmux"
}

test_prefixless_herdr_pane_id_fails() {
  local dir fb home err log rc
  dir="$TMP_ROOT/herdr-pane"; mkdir -p "$dir"
  fb=$(make_stubs "$dir"); home=$(setup_home herdr); err="$dir/send.err"; log="$dir/tmux.log"; : > "$log"
  fm_write_meta "$home/state/nudge.meta" \
    "window=default:wB:p2" "backend=herdr" "herdr_session=default" "herdr_pane_id=wB:p2" "kind=ship"

  PATH="$fb:$PATH" FM_HOME="$home" FM_ROOT_OVERRIDE="$home" FM_TMUX_LOG="$log" FM_SEND_SETTLE=0 \
    "$SEND" wB:p2 "nudge" >/dev/null 2>"$err"; rc=$?
  [ "$rc" -ne 0 ] || fail "prefixless herdr pane id should fail"
  assert_contains "$(cat "$err")" "matches herdr_pane_id" "herdr pane diagnostic should name the meta match"
  assert_contains "$(cat "$err")" "expected <herdr-session>:<pane-id>" "herdr pane diagnostic should show expected shape"
  assert_contains "$(cat "$err")" "default:wB:p2" "herdr pane diagnostic should show the canonical target"
  [ ! -s "$log" ] || fail "prefixless herdr pane id fell through to tmux send"$'\n'"$(cat "$log")"
  pass "fm-send strict: prefixless herdr pane ids are rejected before tmux fallback"
}

test_unmatched_single_colon_target_must_exist() {
  local dir fb home err log rc
  dir="$TMP_ROOT/dead-explicit"; mkdir -p "$dir"
  fb=$(make_stubs "$dir"); home=$(setup_home deadexplicit); err="$dir/send.err"; log="$dir/tmux.log"; : > "$log"

  PATH="$fb:$PATH" FM_HOME="$home" FM_ROOT_OVERRIDE="$home" FM_TMUX_LOG="$log" FM_FAKE_TMUX_DEAD_TARGET=sess:missing FM_SEND_SETTLE=0 \
    "$SEND" sess:missing "hello" >/dev/null 2>"$err"; rc=$?
  [ "$rc" -ne 0 ] || fail "dead explicit tmux-shaped target should fail"
  assert_contains "$(cat "$err")" "not a live tmux endpoint" "dead explicit target diagnostic should name the assumed backend"
  assert_contains "$(cat "$err")" "backend=tmux" "dead explicit target diagnostic should name the tried backend"
  [ ! -s "$log" ] || fail "dead explicit target still attempted a send"$'\n'"$(cat "$log")"
  pass "fm-send strict: unmatched single-colon explicit targets must verify live before sending"
}

test_fm_prefixed_herdr_session_is_an_explicit_target() {
  local dir fb home err log herdr_log rc
  dir="$TMP_ROOT/fm-remote-explicit"; mkdir -p "$dir"
  fb=$(make_stubs "$dir"); home=$(setup_home fmremote); err="$dir/send.err"; log="$dir/tmux.log"; herdr_log="$dir/herdr.log"
  : > "$log"
  : > "$herdr_log"

  PATH="$fb:$PATH" FM_HOME="$home" FM_ROOT_OVERRIDE="$home" FM_TMUX_LOG="$log" FM_HERDR_LOG="$herdr_log" FM_SEND_SETTLE=0 \
    "$SEND" fm-remote:w1:p2 --key Enter >/dev/null 2>"$err"; rc=$?
  expect_code 0 "$rc" "an fm-prefixed Herdr session target should be accepted as explicit"
  assert_grep 'pane get w1:p2 --session fm-remote' "$herdr_log" "fm-prefixed Herdr target was not verified in its session"
  assert_grep 'pane send-keys w1:p2 enter --session fm-remote' "$herdr_log" "fm-prefixed Herdr target was not sent its key in its session"
  assert_no_grep '--session default' "$herdr_log" "fm-prefixed Herdr target fell back to the default session"
  pass "fm-send strict: fm-prefixed Herdr sessions remain explicit backend targets"
}

test_healthy_fm_id_send_still_works() {
  local dir fb home err log rc got
  dir="$TMP_ROOT/healthy"; mkdir -p "$dir"
  fb=$(make_stubs "$dir"); home=$(setup_home healthy); err="$dir/send.err"; log="$dir/tmux.log"; : > "$log"
  fm_write_meta "$home/state/lane-ok.meta" "window=sess:fm-lane-ok" "kind=ship" "harness=codex"

  PATH="$fb:$PATH" FM_HOME="$home" FM_ROOT_OVERRIDE="$home" FM_TMUX_LOG="$log" FM_SEND_SETTLE=0 \
    "$SEND" fm-lane-ok "hello captain" >/dev/null 2>"$err"; rc=$?
  expect_code 0 "$rc" "healthy fm-id send should succeed"
  got=$(cat "$log")
  assert_contains "$got" "target=sess:fm-lane-ok literal=1 arg=hello captain" "healthy send should type literal text to the meta target"
  assert_contains "$got" "target=sess:fm-lane-ok literal=0 arg=Enter" "healthy send should submit with Enter"
  assert_contains "$(cat "$err")" "requested message WILL still be sent" "fm-send guard banner should keep send-specific continuation wording"
  pass "fm-send strict: healthy fm-<id> sends still type once and submit"
}

# --- correlated decision answers --------------------------------------------
#
# --decision is the only path that mints the token a worker needs to close a
# keyed decision, and it mints one only against a request that is already open.
# That ordering is what stops a queued generic command from becoming approval
# (bin/fm-classify-lib.sh owns the correlation contract).

test_decision_answer_requires_an_open_request() {
  local dir fb home err log rc
  dir="$TMP_ROOT/decision-closed"; mkdir -p "$dir"
  fb=$(make_stubs "$dir"); home=$(setup_home decision-closed); err="$dir/send.err"; log="$dir/tmux.log"; : > "$log"
  fm_write_meta "$home/state/lane-d1.meta" "window=sess:fm-lane-d1" "kind=ship"
  printf 'working: still deciding whether to ask\n' > "$home/state/lane-d1.status"

  PATH="$fb:$PATH" FM_HOME="$home" FM_ROOT_OVERRIDE="$home" FM_TMUX_LOG="$log" FM_SEND_SETTLE=0 \
    "$SEND" lane-d1 --decision red-test "go ahead" >/dev/null 2>"$err"; rc=$?
  [ "$rc" -ne 0 ] || fail "answering a decision that is not open should fail"
  assert_contains "$(cat "$err")" "no open decision 'red-test'" \
    "the refusal should name the decision that is not open"
  [ ! -s "$log" ] || fail "a refused decision answer still reached the worker"$'\n'"$(cat "$log")"
  assert_absent "$home/state/lane-d1.decision-answers" \
    "a refused decision answer must not mint a token"
  pass "fm-send strict: --decision refuses to answer a request that has not opened"
}

test_decision_answer_mints_a_correlated_token() {
  local dir fb home err log rc got token record_key record_instance expected_instance _key _verb _summary
  dir="$TMP_ROOT/decision-open"; mkdir -p "$dir"
  fb=$(make_stubs "$dir"); home=$(setup_home decision-open); err="$dir/send.err"; log="$dir/tmux.log"; : > "$log"
  fm_write_meta "$home/state/lane-d2.meta" "window=sess:fm-lane-d2" "kind=ship"
  fm_decision_cutover_ensure_status "$home/state/lane-d2.status" \
    || fail "could not establish a post-cutover send fixture"
  printf 'needs-decision [key=red-test]: accept the red test, or keep fixing?\n' \
    >> "$home/state/lane-d2.status"

  PATH="$fb:$PATH" FM_HOME="$home" FM_ROOT_OVERRIDE="$home" FM_TMUX_LOG="$log" FM_SEND_SETTLE=0 \
    "$SEND" lane-d2 --decision red-test "keep fixing" >/dev/null 2>"$err"; rc=$?
  expect_code 0 "$rc" "answering an open decision should succeed"
  assert_present "$home/state/lane-d2.decision-answers" \
    "an answered decision should record its minted token"
  IFS=$'\t' read -r token record_key record_instance < "$home/state/lane-d2.decision-answers"
  IFS=$'\t' read -r _key _verb expected_instance _summary <<EOF
$(bash -c '. "$1/bin/fm-classify-lib.sh"; status_open_decisions "$2" --with-instance' \
  _ "$ROOT" "$home/state/lane-d2.status")
EOF
  [ "$record_key" = red-test ] || fail "the answer record lost its decision key"
  [ "$record_instance" = "$expected_instance" ] \
    || fail "the answer record was not bound to the opening occurrence"
  [ "${token:0:16}" = "$expected_instance" ] \
    || fail "the answer token did not carry the opening occurrence identifier"
  got=$(cat "$log")
  assert_contains "$got" "decision [key=red-test] [ans=$token]: keep fixing" \
    "the worker should receive the key and token it must copy onto its resolution"
  assert_contains "$got" "target=sess:fm-lane-d2 literal=0 arg=Enter" \
    "a decision answer should submit like any other message"

  # The worker's correlated resolution closes it; an uncorrelated one would not.
  printf 'resolved [key=red-test] [ans=%s]: kept fixing\n' "$token" >> "$home/state/lane-d2.status"
  got=$(bash -c '
    . "$1/bin/fm-classify-lib.sh"; status_open_decisions "$2"' _ "$ROOT" "$home/state/lane-d2.status")
  [ -z "$got" ] || fail "the minted token failed to close its own decision: $got"
  pass "fm-send strict: --decision mints one token bound to the open request"
}

test_decision_answer_requires_strict_stream_identity() {
  local dir fb home err log rc answers before marker token record_key record_instance stream
  dir="$TMP_ROOT/decision-stream-identity"; mkdir -p "$dir"
  fb=$(make_stubs "$dir")

  home=$(setup_home decision-malformed); err="$dir/malformed.err"; log="$dir/malformed.log"; : > "$log"
  fm_write_meta "$home/state/lane-d6.meta" "window=sess:fm-lane-d6" "kind=ship"
  {
    printf '[fm-decision-answer-cutover:v1 stream=not-hex]\n'
    printf 'needs-decision [key=red-test]: accept the red test, or keep fixing?\n'
  } > "$home/state/lane-d6.status"
  answers="$home/state/lane-d6.decision-answers"
  printf '0000000000000000aaaaaaaaaaaaaaaa\tprior\t0000000000000000\n' > "$answers"
  before=$(cat "$answers")
  PATH="$fb:$PATH" FM_HOME="$home" FM_ROOT_OVERRIDE="$home" FM_TMUX_LOG="$log" FM_SEND_SETTLE=0 \
    "$SEND" lane-d6 --decision red-test "keep fixing" >/dev/null 2>"$err"; rc=$?
  [ "$rc" -ne 0 ] || fail "a malformed marker stream should refuse a decision answer"
  assert_contains "$(cat "$err")" "decision status stream $home/state/lane-d6.status is malformed or ambiguous" \
    "the malformed-stream refusal should name the invalid decision stream"
  [ "$(cat "$answers")" = "$before" ] \
    || fail "a malformed marker stream appended a decision answer record"
  [ ! -s "$log" ] || fail "a malformed marker stream still sent a decision answer"$'\n'"$(cat "$log")"

  home=$(setup_home decision-ambiguous); err="$dir/ambiguous.err"; log="$dir/ambiguous.log"; : > "$log"
  fm_write_meta "$home/state/lane-d7.meta" "window=sess:fm-lane-d7" "kind=ship"
  fm_decision_cutover_ensure_status "$home/state/lane-d7.status" \
    || fail "could not establish an ambiguous-stream send fixture"
  marker=$(fm_decision_status_marker) || fail "could not create the second stream marker"
  printf '%s\n' "$marker" >> "$home/state/lane-d7.status"
  printf 'needs-decision [key=red-test]: accept the red test, or keep fixing?\n' \
    >> "$home/state/lane-d7.status"
  answers="$home/state/lane-d7.decision-answers"
  printf '0000000000000000aaaaaaaaaaaaaaaa\tprior\t0000000000000000\n' > "$answers"
  before=$(cat "$answers")
  PATH="$fb:$PATH" FM_HOME="$home" FM_ROOT_OVERRIDE="$home" FM_TMUX_LOG="$log" FM_SEND_SETTLE=0 \
    "$SEND" lane-d7 --decision red-test "keep fixing" >/dev/null 2>"$err"; rc=$?
  [ "$rc" -ne 0 ] || fail "a two-marker stream should refuse a decision answer"
  assert_contains "$(cat "$err")" "decision status stream $home/state/lane-d7.status is malformed or ambiguous" \
    "the ambiguous-stream refusal should name the invalid decision stream"
  [ "$(cat "$answers")" = "$before" ] \
    || fail "an ambiguous marker stream appended a decision answer record"
  [ ! -s "$log" ] || fail "an ambiguous marker stream still sent a decision answer"$'\n'"$(cat "$log")"

  home=$(setup_home decision-legacy); err="$dir/legacy.err"; log="$dir/legacy.log"; : > "$log"
  fm_write_meta "$home/state/lane-d8.meta" "window=sess:fm-lane-d8" "kind=ship"
  printf 'needs-decision [key=red-test]: accept the red test, or keep fixing?\n' \
    > "$home/state/lane-d8.status"
  PATH="$fb:$PATH" FM_HOME="$home" FM_ROOT_OVERRIDE="$home" FM_TMUX_LOG="$log" FM_SEND_SETTLE=0 \
    "$SEND" lane-d8 --decision red-test "keep fixing" >/dev/null 2>"$err"; rc=$?
  expect_code 0 "$rc" "an unmarked legacy stream should still accept a decision answer"
  IFS=$'\t' read -r token record_key record_instance < "$home/state/lane-d8.decision-answers"
  [ "$record_key" = red-test ] || fail "the legacy answer record lost its decision key"
  [ "$record_instance" = "$(fm_decision_instance_id 1)" ] \
    || fail "the legacy answer record lost its positional instance"
  [ "${token:0:16}" = "$record_instance" ] \
    || fail "the legacy answer token was not bound to its opening"

  home=$(setup_home decision-valid-marker); err="$dir/valid.err"; log="$dir/valid.log"; : > "$log"
  fm_write_meta "$home/state/lane-d9.meta" "window=sess:fm-lane-d9" "kind=ship"
  fm_decision_cutover_ensure_status "$home/state/lane-d9.status" \
    || fail "could not establish a valid-marker send fixture"
  stream=$(fm_decision_stream_id "$home/state/lane-d9.status") \
    || fail "the valid-marker fixture is not self-describing"
  printf 'needs-decision [key=red-test]: accept the red test, or keep fixing?\n' \
    >> "$home/state/lane-d9.status"
  PATH="$fb:$PATH" FM_HOME="$home" FM_ROOT_OVERRIDE="$home" FM_TMUX_LOG="$log" FM_SEND_SETTLE=0 \
    "$SEND" lane-d9 --decision red-test "keep fixing" >/dev/null 2>"$err"; rc=$?
  expect_code 0 "$rc" "a single valid marker stream should accept a decision answer"
  IFS=$'\t' read -r token record_key record_instance < "$home/state/lane-d9.decision-answers"
  [ "$record_key" = red-test ] || fail "the valid-marker answer record lost its decision key"
  [ "$record_instance" = "$(fm_decision_instance_id 2 "$stream")" ] \
    || fail "the valid-marker answer record lost its stream-bound instance"
  [ "${token:0:16}" = "$record_instance" ] \
    || fail "the valid-marker answer token was not bound to its opening"
  pass "fm-send strict: --decision requires one valid marker or a true legacy stream"
}

# An unconfirmed decision send is the duplicate-authority hazard: the token was
# already recorded before the text was submitted, so if delivery cannot be
# confirmed and the answer is later re-sent, TWO live tokens exist for the same
# request and either can close it. Revoking on every non-delivery exit keeps
# exactly one live token per answer attempt; the safe direction is losing a
# token (the request stays open and surfaced) rather than keeping a spare.

test_unconfirmed_decision_answer_revokes_its_token() {
  local dir fb home err rc log
  dir="$TMP_ROOT/decision-unconfirmed"; mkdir -p "$dir"
  fb=$(make_stubs "$dir"); home=$(setup_home decision-unconfirmed); err="$dir/send.err"; log="$dir/tmux.log"; : > "$log"
  fm_write_meta "$home/state/lane-d3.meta" "window=sess:fm-lane-d3" "kind=ship"
  fm_decision_cutover_ensure_status "$home/state/lane-d3.status" \
    || fail "could not establish a post-cutover send fixture"
  printf 'needs-decision [key=red-test]: accept the red test, or keep fixing?\n' \
    >> "$home/state/lane-d3.status"

  # The composer never drains: delivery is genuinely unconfirmed.
  PATH="$fb:$PATH" FM_HOME="$home" FM_ROOT_OVERRIDE="$home" FM_TMUX_LOG="$log" FM_SEND_SETTLE=0 \
    FM_SEND_RETRIES=1 FM_FAKE_TMUX_UNSENT=1 \
    "$SEND" lane-d3 --decision red-test "keep fixing" >/dev/null 2>"$err"; rc=$?
  [ "$rc" -ne 0 ] || fail "an unconfirmed decision send must not report success"
  [ ! -s "$home/state/lane-d3.decision-answers" ] \
    || fail "an unconfirmed decision answer left a live token behind:"$'\n'"$(cat "$home/state/lane-d3.decision-answers")"
  pass "fm-send strict: an unconfirmed decision send revokes its answer token, so a resend cannot leave two tokens able to close one request"
}

test_secondmate_pre_submit_failure_revokes_its_decision_token() {
  local dir fb home err rc log
  dir="$TMP_ROOT/decision-secondmate-prepare"; mkdir -p "$dir"
  fb=$(make_stubs "$dir"); home=$(setup_home decision-secondmate-prepare); err="$dir/send.err"; log="$dir/tmux.log"; : > "$log"
  fm_write_meta "$home/state/lane-d5.meta" "window=sess:fm-lane-d5" "kind=secondmate"
  fm_decision_cutover_ensure_status "$home/state/lane-d5.status" \
    || fail "could not establish a post-cutover secondmate send fixture"
  printf 'needs-decision [key=red-test]: accept the red test, or keep fixing?\n' \
    >> "$home/state/lane-d5.status"
  cat > "$fb/mv" <<'SH'
#!/usr/bin/env bash
set -u
last=
for last do :; done
case "$last" in
  */.delivery-confirmed-*) exit 1 ;;
esac
exec /bin/mv "$@"
SH
  chmod +x "$fb/mv"

  PATH="$fb:$PATH" FM_HOME="$home" FM_ROOT_OVERRIDE="$home" FM_TMUX_LOG="$log" FM_SEND_SETTLE=0 \
    "$SEND" lane-d5 --decision red-test "keep fixing" >/dev/null 2>"$err"; rc=$?
  [ "$rc" -ne 0 ] || fail "a failed pending-reply delivery preparation must stop the decision send"
  assert_contains "$(cat "$err")" "failed to durably prepare pending-reply delivery" \
    "the pre-submit failure should identify pending-reply preparation"
  [ ! -s "$home/state/lane-d5.decision-answers" ] \
    || fail "a pre-submit secondmate failure left a live decision token behind:"$'\n'"$(cat "$home/state/lane-d5.decision-answers")"
  [ ! -s "$log" ] || fail "a failed secondmate preparation still typed the decision answer"$'\n'"$(cat "$log")"
  pass "fm-send strict: a pre-submit secondmate preparation failure revokes its decision token"
}

test_decision_answer_resend_leaves_exactly_one_live_token() {
  local dir fb home rc token count
  dir="$TMP_ROOT/decision-resend"; mkdir -p "$dir"
  fb=$(make_stubs "$dir"); home=$(setup_home decision-resend)
  fm_write_meta "$home/state/lane-d4.meta" "window=sess:fm-lane-d4" "kind=ship"
  fm_decision_cutover_ensure_status "$home/state/lane-d4.status" \
    || fail "could not establish a post-cutover send fixture"
  printf 'needs-decision [key=red-test]: accept the red test, or keep fixing?\n' \
    >> "$home/state/lane-d4.status"

  PATH="$fb:$PATH" FM_HOME="$home" FM_ROOT_OVERRIDE="$home" FM_TMUX_LOG="$dir/t1.log" FM_SEND_SETTLE=0 \
    FM_SEND_RETRIES=1 FM_FAKE_TMUX_UNSENT=1 \
    "$SEND" lane-d4 --decision red-test "keep fixing" >/dev/null 2>&1; rc=$?
  [ "$rc" -ne 0 ] || fail "pre-check: the first attempt should have failed unconfirmed"

  # The captain re-sends the same answer; this one lands.
  PATH="$fb:$PATH" FM_HOME="$home" FM_ROOT_OVERRIDE="$home" FM_TMUX_LOG="$dir/t2.log" FM_SEND_SETTLE=0 \
    "$SEND" lane-d4 --decision red-test "keep fixing" >/dev/null 2>&1; rc=$?
  expect_code 0 "$rc" "the resend should succeed"
  count=$(grep -c . "$home/state/lane-d4.decision-answers")
  [ "$count" -eq 1 ] \
    || fail "a resend after an unconfirmed decision send left $count live tokens for one request; only the delivered one may remain"
  IFS=$'\t' read -r token _ _ < "$home/state/lane-d4.decision-answers"
  printf 'resolved [key=red-test] [ans=%s]: kept fixing\n' "$token" >> "$home/state/lane-d4.status"
  [ -z "$(bash -c '. "$1/bin/fm-classify-lib.sh"; status_open_decisions "$2"' _ "$ROOT" "$home/state/lane-d4.status")" ] \
    || fail "the surviving token could not close its own decision"
  pass "fm-send strict: resending an unconfirmed decision answer mints authority once, not twice"
}

test_exact_lane_id_send_still_works
test_unset_fm_home_fails
test_decision_answer_requires_an_open_request
test_decision_answer_mints_a_correlated_token
test_decision_answer_requires_strict_stream_identity
test_unconfirmed_decision_answer_revokes_its_token
test_secondmate_pre_submit_failure_revokes_its_decision_token
test_decision_answer_resend_leaves_exactly_one_live_token
test_unresolvable_target_does_not_tmux_fallback
test_prefixless_herdr_pane_id_fails
test_unmatched_single_colon_target_must_exist
test_fm_prefixed_herdr_session_is_an_explicit_target
test_healthy_fm_id_send_still_works
