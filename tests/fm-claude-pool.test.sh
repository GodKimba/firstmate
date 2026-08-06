#!/usr/bin/env bash
# Behavior tests for the claude-pool worker route: the Claude CLI launched
# against the captain's local CLIProxyAPI pool instead of the ambient native
# Claude login.
#
# Four capabilities are under test:
#   A) Route validation (bin/fm-claude-pool.sh). The pool serves Anthropic AND
#      OpenAI models on the same Anthropic-shaped endpoint, so "the pool
#      answered" is not evidence that a Claude model is running. Validation
#      reads the pool's own /v1/models catalog and requires the requested id to
#      be present with owned_by anthropic. Every other outcome is a distinct,
#      terminal refusal.
#   B) Secret containment. The credential is read by PARSING an operator-owned
#      source file, never by sourcing it, and it reaches curl through a config
#      file rather than argv. No decision output, launch command, or task record
#      may carry it.
#   C) Launch construction (bin/fm-spawn.sh). Selecting claude-pool is explicit;
#      it refuses before any endpoint exists when the model, pool, or credential
#      is wrong, and it never rewrites itself into the native claude adapter.
#      The native claude launch must stay byte-identical.
#   D) Non-interactive and secondmate propagation. The route must work from the
#      same launch path a remote second mate uses, which means it may not depend
#      on interactive shell state, and its local configuration must be inherited
#      into secondmate homes.
#
# NO REAL POOL AND NO REAL ENDPOINT. curl is faked so the catalog is controlled
# and the suite is hermetic; tmux is faked and pinned with --backend tmux so no
# spawn can reach a live runtime.
#
# The fixture credential below is a visibly fake literal. A real pool key must
# never appear in this file, in any fixture it writes, or in any assertion.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

POOL_SH="$ROOT/bin/fm-claude-pool.sh"
SPAWN="$ROOT/bin/fm-spawn.sh"
TMP_ROOT=$(fm_test_tmproot fm-claude-pool)

# A visibly fake credential. Length and shape are irrelevant to every assertion;
# what matters is that the tests can prove where it does and does not travel.
FIXTURE_KEY='fixture-pool-key-not-a-real-credential'

# --- fixtures ---------------------------------------------------------------

# A credential source in the operator's real shape: an exported variable plus
# shell code around it. The `touch` is the non-execution probe - if anything
# sources this file instead of parsing it, the sentinel appears and the test
# that checks for it fails.
write_secret_source() {  # <path> <sentinel> [varname]
  local path=$1 sentinel=$2 var=${3:-CLIPROXY_API_KEY}
  mkdir -p "$(dirname "$path")"
  cat > "$path" <<EOF
# Local-only CLIProxyAPI access key.
touch '$sentinel'
export $var='$FIXTURE_KEY'

claude-sol() {
  env ANTHROPIC_BASE_URL='http://127.0.0.1:8317' claude --model opus "\$@"
}
EOF
  chmod 600 "$path"
}

# A fake curl that answers /v1/models from a controlled catalog and records how
# it was invoked. Recording argv is what lets a test prove the credential
# travelled in the --config file and never on the command line.
#
# FM_FAKE_CURL_CODE pins the HTTP status; 000 also makes curl exit non-zero, the
# transport-failure shape.
make_fake_curl() {  # <fakebin>
  local fakebin=$1
  cat > "$fakebin/curl" <<'SH'
#!/usr/bin/env bash
set -u
[ -n "${FM_FAKE_CURL_ARGV_LOG:-}" ] && printf '%s\n' "$*" >> "$FM_FAKE_CURL_ARGV_LOG"
dest=; cfg=; prev=
for a in "$@"; do
  case "$prev" in
    -o) dest=$a ;;
    --config) cfg=$a ;;
  esac
  prev=$a
done
if [ -n "$cfg" ] && [ -n "${FM_FAKE_CURL_CONFIG_LOG:-}" ] && [ -f "$cfg" ]; then
  cat "$cfg" >> "$FM_FAKE_CURL_CONFIG_LOG"
fi
code=${FM_FAKE_CURL_CODE:-200}
if [ "$code" = 000 ]; then
  printf '000'
  exit 7
fi
if [ -n "$dest" ]; then
  cat "${FM_FAKE_CURL_CATALOG:-/dev/null}" > "$dest"
fi
printf '%s' "$code"
exit 0
SH
  chmod +x "$fakebin/curl"
}

# The pool's real catalog shape, reduced to the ids these tests reason about.
# claude-opus-5 and gpt-5.6-sol are both really served by the captain's pool, on
# the same endpoint - that co-tenancy is the reason family validation exists.
write_catalog() {  # <path>
  cat > "$1" <<'JSON'
{"object":"list","data":[
  {"id":"claude-opus-5","object":"model","owned_by":"anthropic","created":1784038800},
  {"id":"claude-sonnet-5","object":"model","owned_by":"anthropic","created":1782777600},
  {"id":"gpt-5.6-sol","object":"model","owned_by":"openai","created":1783616400}
]}
JSON
}

# One self-contained case directory: fakebin with curl, a catalog, a credential
# source, and the logs the assertions read.
make_pool_case() {  # <name>
  local name=$1 dir fakebin
  dir="$TMP_ROOT/$name"
  fakebin=$(fm_fakebin "$dir")
  mkdir -p "$dir/home/config"
  make_fake_curl "$fakebin"
  write_catalog "$dir/catalog.json"
  write_secret_source "$dir/secret-source.zsh" "$dir/SOURCED-SENTINEL"
  printf '%s\n' "$dir|$fakebin"
}

read_pool_case() {  # <record>
  IFS='|' read -r CASE_DIR FAKEBIN <<EOF
$1
EOF
}

# Run bin/fm-claude-pool.sh inside a case, with the fake curl on PATH and the
# route pointed at that case's fixtures.
run_pool() {  # <case-dir> <fakebin> <args...>
  local dir=$1 fakebin=$2
  shift 2
  PATH="$fakebin:$PATH" \
    FM_HOME="$dir/home" FM_CONFIG_OVERRIDE="$dir/home/config" \
    FM_CLAUDE_POOL_SECRET_FILE="${FM_TEST_SECRET_FILE:-$dir/secret-source.zsh}" \
    FM_CLAUDE_POOL_BASE_URL="${FM_TEST_BASE_URL:-http://127.0.0.1:8317}" \
    FM_FAKE_CURL_CATALOG="$dir/catalog.json" \
    FM_FAKE_CURL_CODE="${FM_TEST_CURL_CODE:-200}" \
    FM_FAKE_CURL_ARGV_LOG="$dir/curl-argv.log" \
    FM_FAKE_CURL_CONFIG_LOG="$dir/curl-config.log" \
    "$POOL_SH" "$@" 2>&1
}

# --- A) route validation ----------------------------------------------------

test_check_accepts_an_anthropic_model_the_pool_serves() {
  local rec out status
  rec=$(make_pool_case accept); read_pool_case "$rec"
  out=$(run_pool "$CASE_DIR" "$FAKEBIN" check --model claude-opus-5)
  status=$?
  expect_code 0 "$status" "a pool-served Anthropic model should pass validation"
  assert_contains "$out" "result:  ok" "check did not report ok"
  assert_contains "$out" "owned_by anthropic" "check did not report the catalog family"
  pass "check accepts an Anthropic model the pool actually serves"
}

test_check_rejects_a_non_anthropic_model_served_by_the_same_pool() {
  local rec out status
  rec=$(make_pool_case wrong-family); read_pool_case "$rec"
  out=$(run_pool "$CASE_DIR" "$FAKEBIN" check --model gpt-5.6-sol)
  status=$?
  # The decisive case: the pool really does serve this id, and really does
  # answer it on the Anthropic endpoint. Reachability is not the question.
  expect_code 5 "$status" "an OpenAI model must be refused with the wrong-family code"
  assert_contains "$out" "result:  wrong-family" "check did not classify the family mismatch"
  assert_contains "$out" "not Anthropic" "check did not explain the family mismatch"
  assert_not_contains "$out" "result:  ok" "a non-Anthropic model must never validate"
  pass "check refuses a non-Anthropic model the same pool serves"
}

test_check_rejects_a_model_the_pool_does_not_serve() {
  local rec out status
  rec=$(make_pool_case unknown-model); read_pool_case "$rec"
  out=$(run_pool "$CASE_DIR" "$FAKEBIN" check --model claude-not-in-this-pool)
  status=$?
  expect_code 4 "$status" "an absent model must be refused with the unknown-model code"
  assert_contains "$out" "does not serve a model named" "check did not name the absent model"
  pass "check refuses a model absent from the pool catalog"
}

test_check_reports_a_pool_that_does_not_answer() {
  local rec out status
  rec=$(make_pool_case unreachable); read_pool_case "$rec"
  out=$(FM_TEST_CURL_CODE=000 run_pool "$CASE_DIR" "$FAKEBIN" check --model claude-opus-5)
  status=$?
  expect_code 3 "$status" "an unreachable pool must be refused with the catalog code"
  assert_contains "$out" "did not serve its model catalog" "check did not explain the transport failure"
  pass "check reports a pool that does not serve its catalog"
}

test_check_reports_a_missing_credential_source() {
  local rec out status
  rec=$(make_pool_case no-source); read_pool_case "$rec"
  out=$(FM_TEST_SECRET_FILE="$CASE_DIR/absent.zsh" run_pool "$CASE_DIR" "$FAKEBIN" check --model claude-opus-5)
  status=$?
  expect_code 6 "$status" "an absent credential source must be refused with the source code"
  assert_contains "$out" "credential source is missing" "check did not report the missing source"
  assert_contains "$out" "$CASE_DIR/absent.zsh" "check did not name the missing source path"
  pass "check reports a missing credential source by path"
}

test_check_reports_a_source_that_lacks_the_variable() {
  local rec out status
  rec=$(make_pool_case no-var); read_pool_case "$rec"
  printf '# no assignment here\nexport SOMETHING_ELSE=1\n' > "$CASE_DIR/empty-source.zsh"
  out=$(FM_TEST_SECRET_FILE="$CASE_DIR/empty-source.zsh" run_pool "$CASE_DIR" "$FAKEBIN" check --model claude-opus-5)
  status=$?
  expect_code 6 "$status" "a source without the variable must be refused"
  assert_contains "$out" "is not defined in" "check did not report the missing variable"
  assert_contains "$out" "never falls back to the native Claude login" "check did not state the no-fallback boundary"
  pass "check reports a credential source that lacks the variable"
}

# --- B) secret containment --------------------------------------------------

test_the_credential_source_is_parsed_and_never_executed() {
  local rec out
  rec=$(make_pool_case no-exec); read_pool_case "$rec"
  out=$(run_pool "$CASE_DIR" "$FAKEBIN" check --model claude-opus-5)
  expect_code 0 "$?" "the fixture source should still validate"
  # The fixture's `touch` runs only if something SOURCED the file. A worker
  # launch must never execute an operator's interactive shell configuration.
  assert_absent "$CASE_DIR/SOURCED-SENTINEL" \
    "the credential source was executed, not parsed: a shell profile must never run during route resolution"
  assert_not_contains "$out" "claude-sol" "unrelated shell content leaked out of the source file"
  pass "the credential source is parsed, never sourced"
}

test_the_credential_never_reaches_curl_argv() {
  local rec
  rec=$(make_pool_case argv); read_pool_case "$rec"
  run_pool "$CASE_DIR" "$FAKEBIN" check --model claude-opus-5 >/dev/null
  expect_code 0 "$?" "validation should pass so curl is actually exercised"
  assert_present "$CASE_DIR/curl-argv.log" "the fake curl was never invoked"
  assert_no_grep "$FIXTURE_KEY" "$CASE_DIR/curl-argv.log" \
    "the credential appeared in curl's argv, where any process table can read it"
  assert_grep "--config" "$CASE_DIR/curl-argv.log" "curl was not given a config file"
  # It must genuinely have travelled: proving absence from argv is only
  # meaningful alongside proving presence in the config file.
  assert_grep "$FIXTURE_KEY" "$CASE_DIR/curl-config.log" \
    "the credential did not reach curl through its config file"
  pass "the credential reaches curl by config file and never through argv"
}

test_check_output_never_carries_the_credential() {
  local rec text json
  rec=$(make_pool_case output); read_pool_case "$rec"
  text=$(run_pool "$CASE_DIR" "$FAKEBIN" check --model claude-opus-5)
  json=$(run_pool "$CASE_DIR" "$FAKEBIN" check --model claude-opus-5 --json)
  assert_not_contains "$text" "$FIXTURE_KEY" "the text decision leaked the credential"
  assert_not_contains "$json" "$FIXTURE_KEY" "the JSON decision leaked the credential"
  # Naming the SOURCE is the point: an operator has to be able to fix the route.
  assert_contains "$text" "CLIPROXY_API_KEY in" "the decision did not name the credential source"
  pass "neither decision format carries the credential"
}

test_the_route_claims_no_pooled_account() {
  local rec json
  rec=$(make_pool_case no-pin); read_pool_case "$rec"
  json=$(run_pool "$CASE_DIR" "$FAKEBIN" check --model claude-opus-5 --json)
  # The proxy owns selection and exposes no per-request pin, so a pass must not
  # read as a reserved account (docs/verification/pool-account-routing.md).
  assert_contains "$json" '"binds_account":false' "the result did not disclose that it binds no account"
  assert_contains "$json" '"selects_account":false' "the result did not disclose that it selects no account"
  assert_not_contains "$json" '"account"' "the result named an account, implying a pin the proxy does not offer"
  pass "a passing route claims no pooled account"
}

test_the_config_file_refuses_to_hold_a_credential() {
  local rec out status
  rec=$(make_pool_case config-secret); read_pool_case "$rec"
  printf 'secret-var = %s\n' 'aVeryLongOpaqueTokenValueThatLooksLikeACredential' > "$CASE_DIR/home/config/claude-pool"
  out=$(PATH="$FAKEBIN:$PATH" FM_HOME="$CASE_DIR/home" FM_CONFIG_OVERRIDE="$CASE_DIR/home/config" \
    "$POOL_SH" source 2>&1)
  status=$?
  expect_code 2 "$status" "a credential-shaped config value must be refused"
  assert_contains "$out" "must name a source, not hold one" "the refusal did not explain the boundary"
  pass "the route configuration refuses to hold a credential itself"
}

test_config_file_overrides_the_shipped_defaults() {
  local rec out
  rec=$(make_pool_case config-override); read_pool_case "$rec"
  write_secret_source "$CASE_DIR/alt-source.zsh" "$CASE_DIR/ALT-SENTINEL" ALT_POOL_KEY
  cat > "$CASE_DIR/home/config/claude-pool" <<EOF
# route configuration: paths, names and a URL only
base-url = http://127.0.0.1:9999
secret-file = $CASE_DIR/alt-source.zsh
secret-var = ALT_POOL_KEY
EOF
  out=$(PATH="$FAKEBIN:$PATH" FM_HOME="$CASE_DIR/home" FM_CONFIG_OVERRIDE="$CASE_DIR/home/config" \
    "$POOL_SH" source 2>&1)
  assert_contains "$out" "$CASE_DIR/alt-source.zsh" "config did not override secret-file"
  assert_contains "$out" "ALT_POOL_KEY" "config did not override secret-var"
  out=$(PATH="$FAKEBIN:$PATH" FM_HOME="$CASE_DIR/home" FM_CONFIG_OVERRIDE="$CASE_DIR/home/config" \
    "$POOL_SH" base-url 2>&1)
  assert_contains "$out" "http://127.0.0.1:9999" "config did not override base-url"
  pass "config/claude-pool overrides the shipped defaults"
}

test_secret_command_emits_the_credential_for_the_api_key_helper() {
  local rec out
  rec=$(make_pool_case helper); read_pool_case "$rec"
  # This is the ONE channel the credential is supposed to travel on: the Claude
  # CLI's apiKeyHelper reads it from stdout.
  out=$(PATH="$FAKEBIN:$PATH" "$POOL_SH" secret \
    --secret-file "$CASE_DIR/secret-source.zsh" --secret-var CLIPROXY_API_KEY 2>/dev/null)
  [ "$out" = "$FIXTURE_KEY" ] || fail "the apiKeyHelper channel did not emit the credential (got: '$out')"
  assert_absent "$CASE_DIR/SOURCED-SENTINEL" "the helper executed the source file instead of parsing it"
  pass "the apiKeyHelper channel emits exactly the credential"
}

# --- C) launch construction -------------------------------------------------

make_spawn_fakebin() {  # <dir>
  local dir=$1 fakebin
  fakebin=$(fm_fakebin "$dir")
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
set -u
case "$*" in
  *"#{pane_current_path}"*) printf '%s\n' "${FM_FAKE_PANE_PATH:-}"; exit 0 ;;
esac
case "${1:-}" in
  display-message) printf 'firstmate\n'; exit 0 ;;
  list-windows) exit 0 ;;
  has-session|new-session|new-window|kill-window) exit 0 ;;
  send-keys)
    if [ -n "${FM_FAKE_LAUNCH_LOG:-}" ]; then
      prev=
      for a in "$@"; do
        [ "$prev" = "-l" ] && printf '%s\n' "$a" >> "$FM_FAKE_LAUNCH_LOG"
        prev=$a
      done
    fi
    exit 0
    ;;
esac
exit 0
SH
  chmod +x "$fakebin/tmux"
  fm_fake_exit0 "$fakebin" treehouse
  make_fake_curl "$fakebin"
  printf '%s\n' "$fakebin"
}

make_spawn_case() {  # <name> <harness> <id>...
  local name=$1 harness=$2 case_dir home proj wt fakebin launchlog id
  shift 2
  case_dir="$TMP_ROOT/$name"
  home="$case_dir/home"
  proj="$case_dir/project"
  wt="$case_dir/wt"
  launchlog="$case_dir/launch.log"
  fakebin=$(make_spawn_fakebin "$case_dir/fake")
  mkdir -p "$home/data" "$home/projects" "$home/state" "$home/config"
  printf '%s\n' "$harness" > "$home/config/crew-harness"
  fm_git_worktree "$proj" "$wt" "wt-$name"
  touch "$home/state/.last-watcher-beat"
  write_catalog "$case_dir/catalog.json"
  write_secret_source "$case_dir/secret-source.zsh" "$case_dir/SOURCED-SENTINEL"
  for id in "$@"; do
    mkdir -p "$home/data/$id"
    printf 'brief for %s\n' "$id" > "$home/data/$id/brief.md"
  done
  printf '%s\n' "$case_dir|$home|$proj|$wt|$fakebin|$launchlog"
}

read_spawn_case() {  # <record>
  IFS='|' read -r CASE_DIR HOME_DIR PROJ_DIR WT_DIR FAKEBIN_DIR LAUNCH_LOG <<EOF
$1
EOF
}

# --backend tmux is pinned explicitly, and the herdr runtime marker is cleared,
# so this suite cannot be pulled onto a live runtime by the ambient environment
# of whoever runs it.
run_spawn() {  # <home> <wt> <fakebin> <launchlog> <case-dir> <spawn args...>
  local home=$1 wt=$2 fakebin=$3 launchlog=$4 dir=$5
  shift 5
  : > "$launchlog"
  env -u HERDR_ENV -u ANTHROPIC_BASE_URL -u ANTHROPIC_API_KEY -u ANTHROPIC_AUTH_TOKEN \
    FM_ROOT_OVERRIDE='' FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_PROJECTS_OVERRIDE="$home/projects" FM_CONFIG_OVERRIDE="$home/config" \
    FM_SPAWN_NO_GUARD=1 FM_FAKE_PANE_PATH="$wt" TMUX="fake,1,0" \
    CLAUDE_CONFIG_DIR="${FM_TEST_CLAUDE_CONFIG_DIR:-}" \
    FM_CLAUDE_POOL_SECRET_FILE="$dir/secret-source.zsh" \
    FM_CLAUDE_POOL_BASE_URL="${FM_TEST_BASE_URL:-http://127.0.0.1:8317}" \
    FM_FAKE_CURL_CATALOG="$dir/catalog.json" \
    FM_FAKE_CURL_CODE="${FM_TEST_CURL_CODE:-200}" \
    FM_FAKE_LAUNCH_LOG="$launchlog" PATH="$fakebin:$PATH" \
    "$SPAWN" "$@" --backend tmux 2>&1
}

test_claude_pool_launch_carries_the_route_and_no_credential() {
  local rec id out status launch
  id=pool-launch-a1
  rec=$(make_spawn_case pool-launch claude "$id"); read_spawn_case "$rec"

  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$CASE_DIR" \
    "$id" "$PROJ_DIR" --harness claude-pool --model claude-opus-5 --effort high)
  status=$?
  expect_code 0 "$status" "a valid claude-pool spawn should succeed: $out"
  assert_contains "$out" "spawned $id harness=claude-pool" "spawn did not report the pool adapter"

  launch=$(cat "$LAUNCH_LOG")
  assert_contains "$launch" "ANTHROPIC_BASE_URL='http://127.0.0.1:8317'" "launch did not point at the pool"
  assert_contains "$launch" "-u ANTHROPIC_API_KEY" "launch did not drop an inherited ANTHROPIC_API_KEY"
  assert_contains "$launch" "-u ANTHROPIC_AUTH_TOKEN" "launch did not drop an inherited ANTHROPIC_AUTH_TOKEN"
  assert_contains "$launch" "apiKeyHelper" "launch did not install the credential helper"
  assert_contains "$launch" "--model 'claude-opus-5'" "launch did not thread the model"
  assert_contains "$launch" "--effort 'high'" "launch did not thread the effort"
  assert_contains "$launch" "claude --dangerously-skip-permissions" "launch did not run the Claude CLI"
  # The whole point of the helper indirection.
  assert_not_contains "$launch" "$FIXTURE_KEY" \
    "the credential appeared in the launch command, where the process table and pane can read it"
  pass "the pool launch carries the route, the model, and no credential"
}

test_static_crew_harness_selects_the_pool_route() {
  local rec id out launch
  id=pool-static-k2
  # The other spawn tests select the adapter per spawn. This one selects it the
  # other supported way - the home's static crewmate harness - because that is a
  # different resolution path (fm-harness.sh crew) and it is how a machine that
  # has cut over to pooled capacity would actually be configured.
  rec=$(make_spawn_case pool-static claude-pool "$id"); read_spawn_case "$rec"
  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$CASE_DIR" \
    "$id" "$PROJ_DIR" --model claude-opus-5)
  expect_code 0 "$?" "a statically configured claude-pool spawn should succeed: $out"
  assert_contains "$out" "harness=claude-pool" "config/crew-harness did not select the pool adapter"
  launch=$(cat "$LAUNCH_LOG")
  assert_contains "$launch" "ANTHROPIC_BASE_URL=" "the statically selected route lost its pool endpoint"
  assert_contains "$launch" "apiKeyHelper" "the statically selected route lost its credential helper"
  pass "config/crew-harness selects the pool route through the static resolution path"
}

test_claude_pool_meta_records_the_adapter_without_a_credential() {
  local rec id meta
  id=pool-meta-b2
  rec=$(make_spawn_case pool-meta claude "$id"); read_spawn_case "$rec"
  run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$CASE_DIR" \
    "$id" "$PROJ_DIR" --harness claude-pool --model claude-opus-5 >/dev/null
  meta="$HOME_DIR/state/$id.meta"
  assert_grep "harness=claude-pool" "$meta" "meta did not record the pool adapter"
  assert_grep "model=claude-opus-5" "$meta" "meta did not record the validated model"
  assert_no_grep "$FIXTURE_KEY" "$meta" "the durable task record leaked the credential"
  assert_no_grep "account" "$meta" "the task record named an account, implying a pin the proxy does not offer"
  pass "the task record keeps the adapter and model but no credential or account"
}

test_claude_pool_requires_an_explicit_model() {
  local rec id out status
  id=pool-nomodel-c3
  rec=$(make_spawn_case pool-nomodel claude "$id"); read_spawn_case "$rec"
  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$CASE_DIR" \
    "$id" "$PROJ_DIR" --harness claude-pool)
  status=$?
  [ "$status" -ne 0 ] || fail "claude-pool without --model must refuse rather than guess a default"
  assert_contains "$out" "requires an explicit --model" "the refusal did not explain the missing model"
  assert_absent "$HOME_DIR/state/$id.meta" "a refused spawn must not leave a task record"
  pass "claude-pool refuses to guess a model"
}

test_claude_pool_refuses_a_non_anthropic_model_before_any_endpoint() {
  local rec id out status
  id=pool-family-d4
  rec=$(make_spawn_case pool-family claude "$id"); read_spawn_case "$rec"
  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$CASE_DIR" \
    "$id" "$PROJ_DIR" --harness claude-pool --model gpt-5.6-sol)
  status=$?
  [ "$status" -ne 0 ] || fail "a GPT model behind the Claude CLI must be refused"
  assert_contains "$out" "not usable for model gpt-5.6-sol" "the refusal did not name the rejected model"
  assert_absent "$HOME_DIR/state/$id.meta" "the refusal happened after a task record already existed"
  [ ! -s "$LAUNCH_LOG" ] || fail "the refusal happened after a launch was already typed"
  pass "a non-Anthropic model is refused before any endpoint or record exists"
}

test_claude_pool_refuses_an_unreachable_pool_before_any_endpoint() {
  local rec id out status
  id=pool-down-e5
  rec=$(make_spawn_case pool-down claude "$id"); read_spawn_case "$rec"
  out=$(FM_TEST_CURL_CODE=000 run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$CASE_DIR" \
    "$id" "$PROJ_DIR" --harness claude-pool --model claude-opus-5)
  status=$?
  [ "$status" -ne 0 ] || fail "an unreachable pool must refuse the spawn"
  assert_contains "$out" "did not serve its model catalog" "the refusal did not explain the pool fault"
  assert_absent "$HOME_DIR/state/$id.meta" "the refusal happened after a task record already existed"
  pass "an unreachable pool is refused before any endpoint or record exists"
}

test_a_refused_pool_route_never_falls_back_to_native_claude() {
  local rec id out
  id=pool-nofallback-f6
  rec=$(make_spawn_case pool-nofallback claude "$id"); read_spawn_case "$rec"
  # config/crew-harness says plain claude, which is exactly the adapter a silent
  # fallback would reach for. It must not be reached.
  out=$(FM_TEST_CURL_CODE=000 run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$CASE_DIR" \
    "$id" "$PROJ_DIR" --harness claude-pool --model claude-opus-5)
  assert_not_contains "$out" "spawned $id" "a broken pool route silently spawned something"
  assert_not_contains "$out" "harness=claude " "the pool route degraded into the native claude adapter"
  assert_absent "$HOME_DIR/state/$id.meta" "a fallback wrote a task record"
  assert_contains "$out" "correct the pool route or select a different harness explicitly" \
    "the refusal did not put the choice back with the operator"
  pass "a refused pool route never degrades to the native Claude login"
}

test_native_claude_launch_is_unchanged_by_the_pool_adapter() {
  local rec id out launch expected
  id=native-claude-g7
  rec=$(make_spawn_case native-claude claude "$id"); read_spawn_case "$rec"
  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$CASE_DIR" "$id" "$PROJ_DIR")
  expect_code 0 "$?" "the native claude spawn should still succeed: $out"
  launch=$(cat "$LAUNCH_LOG")
  # Byte-identical to the canonical claude launch: adding the pool adapter must
  # not perturb the route that spends the captain's native subscription.
  expected="export FM_CREW_TASK='$id'; CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION=false claude --dangerously-skip-permissions \"\$('${ROOT}/bin/fm-operational-input.sh' encode launch-brief < '$HOME_DIR/data/$id/brief.md')\""
  [ "$launch" = "$expected" ] || fail "the native claude launch changed"$'\n'"expected: $expected"$'\n'"actual:   $launch"
  assert_not_contains "$launch" "ANTHROPIC_BASE_URL" "the native launch acquired pool routing"
  assert_not_contains "$launch" "apiKeyHelper" "the native launch acquired a pool credential helper"
  pass "the native claude launch is byte-identical with the pool adapter present"
}

test_claude_pool_forwards_the_firstmate_config_dir() {
  local rec id launch
  id=pool-configdir-h8
  rec=$(make_spawn_case pool-configdir claude "$id"); read_spawn_case "$rec"
  FM_TEST_CLAUDE_CONFIG_DIR="$CASE_DIR/claude-store" \
    run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$CASE_DIR" \
      "$id" "$PROJ_DIR" --harness claude-pool --model claude-opus-5 >/dev/null
  launch=$(cat "$LAUNCH_LOG")
  # Same executable, so the same non-credential store (settings, history).
  assert_contains "$launch" "CLAUDE_CONFIG_DIR='$CASE_DIR/claude-store'" \
    "the pool route did not inherit firstmate's Claude store"
  pass "the pool route forwards firstmate's Claude config store"
}

# --- D) non-interactive and secondmate propagation --------------------------

test_the_pool_launch_depends_on_no_interactive_shell_state() {
  local rec id launch
  id=pool-noninteractive-i9
  rec=$(make_spawn_case pool-noninteractive claude "$id"); read_spawn_case "$rec"
  run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$CASE_DIR" \
    "$id" "$PROJ_DIR" --harness claude-pool --model claude-opus-5 >/dev/null
  launch=$(cat "$LAUNCH_LOG")
  # A remote second mate launches non-interactively, so the route may not
  # depend on .zshrc, a sourced profile, or a shell function like claude-sol.
  assert_not_contains "$launch" "zshrc" "the launch depends on interactive shell configuration"
  assert_not_contains "$launch" "source " "the launch sources a shell profile"
  assert_not_contains "$launch" "claude-sol" "the launch depends on an interactive shell function"
  assert_not_contains "$launch" "\$CLIPROXY_API_KEY" \
    "the launch expands an ambient credential variable that a non-interactive shell does not have"
  # The helper must be an absolute path for the same reason.
  assert_contains "$launch" "$ROOT/bin/fm-claude-pool.sh secret" \
    "the credential helper is not an absolute, self-describing command"
  pass "the pool launch carries everything it needs and reads no interactive shell state"
}

test_secondmate_launch_uses_the_pool_route() {
  local rec id sm_home sm_home_real launch out
  id=pool-secondmate-j1
  rec=$(make_spawn_case pool-secondmate claude "$id"); read_spawn_case "$rec"
  sm_home="$CASE_DIR/sm-home"
  mkdir -p "$sm_home/bin" "$sm_home/data"
  # fm-spawn records the home by its real path, which on macOS resolves the
  # /var -> /private/var symlink the temp root sits under.
  sm_home_real=$(cd "$sm_home" && pwd -P)
  printf '# Firstmate\n' > "$sm_home/AGENTS.md"
  printf '%s\n' "$id" > "$sm_home/.fm-secondmate-home"
  printf 'charter for %s\n' "$id" > "$sm_home/data/charter.md"
  printf 'claude-pool\n' > "$HOME_DIR/config/secondmate-harness"

  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$CASE_DIR" \
    "$id" "$sm_home" --model claude-opus-5 --secondmate)
  expect_code 0 "$?" "a claude-pool secondmate launch should succeed: $out"
  assert_contains "$out" "harness=claude-pool" "the secondmate did not launch on the pool adapter"
  launch=$(cat "$LAUNCH_LOG")
  assert_contains "$launch" "ANTHROPIC_BASE_URL='http://127.0.0.1:8317'" "the secondmate launch lost the pool route"
  assert_contains "$launch" "apiKeyHelper" "the secondmate launch lost the credential helper"
  assert_contains "$launch" "FM_HOME='$sm_home_real'" "the secondmate launch lost its own home"
  assert_not_contains "$launch" "$FIXTURE_KEY" "the secondmate launch leaked the credential"
  pass "a secondmate launches on the pool route through the same non-interactive path"
}

test_the_route_configuration_is_inherited_by_secondmate_homes() {
  # A secondmate's own crewmates must be able to use the pool route, which means
  # the primary's local route configuration has to travel with the home.
  # shellcheck source=/dev/null
  . "$ROOT/bin/fm-config-inherit-lib.sh"
  case " $FM_INHERITABLE_CONFIG " in
    *" claude-pool "*) : ;;
    *) fail "config/claude-pool is not in the declared inheritable set: $FM_INHERITABLE_CONFIG" ;;
  esac
  pass "config/claude-pool is inherited into secondmate homes"
}

test_dispatch_profile_validation_accepts_the_pool_adapter() {
  local dir out
  dir="$TMP_ROOT/dispatch"
  mkdir -p "$dir/home/config" "$dir/home/state" "$dir/home/data" "$dir/home/projects"
  printf '%s\n' '{"rules":[{"when":"claude work on pooled capacity","use":{"harness":"claude-pool","model":"claude-opus-5","effort":"xhigh"}}],"default":{"harness":"claude"}}' \
    > "$dir/home/config/crew-dispatch.json"
  out=$(FM_HOME="$dir/home" FM_CONFIG_OVERRIDE="$dir/home/config" \
    FM_STATE_OVERRIDE="$dir/home/state" FM_DATA_OVERRIDE="$dir/home/data" \
    "$ROOT/bin/fm-bootstrap.sh" 2>&1 || true)
  assert_not_contains "$out" "CREW_DISPATCH: invalid" \
    "bootstrap rejected a valid claude-pool dispatch profile"
  pass "dispatch profile validation accepts claude-pool with a full effort range"
}

test_check_accepts_an_anthropic_model_the_pool_serves
test_check_rejects_a_non_anthropic_model_served_by_the_same_pool
test_check_rejects_a_model_the_pool_does_not_serve
test_check_reports_a_pool_that_does_not_answer
test_check_reports_a_missing_credential_source
test_check_reports_a_source_that_lacks_the_variable
test_the_credential_source_is_parsed_and_never_executed
test_the_credential_never_reaches_curl_argv
test_check_output_never_carries_the_credential
test_the_route_claims_no_pooled_account
test_the_config_file_refuses_to_hold_a_credential
test_config_file_overrides_the_shipped_defaults
test_secret_command_emits_the_credential_for_the_api_key_helper
test_claude_pool_launch_carries_the_route_and_no_credential
test_static_crew_harness_selects_the_pool_route
test_claude_pool_meta_records_the_adapter_without_a_credential
test_claude_pool_requires_an_explicit_model
test_claude_pool_refuses_a_non_anthropic_model_before_any_endpoint
test_claude_pool_refuses_an_unreachable_pool_before_any_endpoint
test_a_refused_pool_route_never_falls_back_to_native_claude
test_native_claude_launch_is_unchanged_by_the_pool_adapter
test_claude_pool_forwards_the_firstmate_config_dir
test_the_pool_launch_depends_on_no_interactive_shell_state
test_secondmate_launch_uses_the_pool_route
test_the_route_configuration_is_inherited_by_secondmate_homes
test_dispatch_profile_validation_accepts_the_pool_adapter

echo "# all fm-claude-pool tests passed"
