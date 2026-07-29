#!/usr/bin/env bash
# Behavior tests for bin/fm-pool-quota.sh, the read-only subscription-pool quota
# adapter.
#
# Every fixture here is sanitized: the "credentials" are literal marker strings
# that never existed as real tokens, and the fake quota-axi answers are hand
# written. No test reads the operator's real pool directory, and each run asserts
# that no marker string reaches stdout, the panel, or any surviving temp file.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

CMD="$ROOT/bin/fm-pool-quota.sh"
# Distinctive markers. If any of these appears in output, the panel, or a
# leftover file, the secret-containment contract is broken.
TOKEN_MARK='SECRETTOKENMARKER'
EMAIL_A='alpha@example.com'
EMAIL_B='bravo@example.org'
ACCOUNT_ID_MARK='ACCOUNTIDMARKER'
# A pinned clock keeps every relative reset string deterministic.
PINNED_NOW=1785265200  # 2026-07-28T19:00:00Z

# --- fixtures ---------------------------------------------------------------

# make_pool <dir>: a pool with one enabled Claude account, one enabled Codex
# account, one disabled account, malformed disabled flags, one malformed file,
# one symlink, one oversized file, one empty file, one wrong-type file, and a
# logs subdirectory.
make_pool() {
  local dir=$1
  mkdir -p "$dir/logs"
  cat > "$dir/alpha.json" <<JSON
{"access_token":"$TOKEN_MARK-CLAUDE","disabled":false,"email":"$EMAIL_A","expired":"2026-08-01T10:00:00-03:00","id_token":"$TOKEN_MARK-ID","refresh_token":"$TOKEN_MARK-REFRESH","type":"claude"}
JSON
  cat > "$dir/bravo.json" <<JSON
{"access_token":"$TOKEN_MARK-CODEX","account_id":"$ACCOUNT_ID_MARK","disabled":false,"email":"$EMAIL_B","expired":"2026-08-01T10:00:00-03:00","id_token":"$TOKEN_MARK-ID","refresh_token":"$TOKEN_MARK-REFRESH","type":"codex"}
JSON
  cat > "$dir/charlie.json" <<JSON
{"disabled":true,"email":"charlie@example.com","expired":"2026-08-01T10:00:00-03:00","type":"claude"}
JSON
  printf 'this is not json' > "$dir/delta.json"
  ln -s alpha.json "$dir/echo.json"
  : > "$dir/foxtrot.json"
  cat > "$dir/golf.json" <<JSON
{"access_token":"$TOKEN_MARK-OTHER","disabled":false,"email":"golf@example.net","expired":"2026-08-01T10:00:00-03:00","type":"gemini"}
JSON
  # Oversized: valid JSON in shape, but padded past the byte bound.
  {
    printf '{"access_token":"%s-BIG","disabled":false,"email":"hotel@example.com","expired":"2026-08-01T10:00:00-03:00","type":"claude","pad":"' "$TOKEN_MARK"
    head -c 70000 /dev/zero | tr '\0' 'x'
    printf '"}\n'
  } > "$dir/hotel.json"
  printf '["not","an","object"]\n' > "$dir/india.json"
  printf '{"disabled":false,"email":"juliet@example.com","expired":"2026-08-01T10:00:00-03:00","type":"claude"}\n' > "$dir/juliet.json"
  printf '{"access_token":"%s-STRING-DISABLED","disabled":"true","type":"claude"}\n' "$TOKEN_MARK" > "$dir/kilo.json"
  printf '{"access_token":"%s-NUMBER-DISABLED","disabled":1,"type":"claude"}\n' "$TOKEN_MARK" > "$dir/lima.json"
  printf '{"access_token":"%s-OBJECT-DISABLED","disabled":{},"type":"claude"}\n' "$TOKEN_MARK" > "$dir/mike.json"
  printf '{"access_token":"%s-MISSING-DISABLED","type":"claude"}\n' "$TOKEN_MARK" > "$dir/november.json"
}

# make_quota_axi <fakebin> <mode> [probe-log]: a fake quota-axi that answers from
# its own fixture data and records the environment and argv it was handed.
# Modes: healthy, tight, unknown, partial (codex fails hard), authfail.
make_quota_axi() {
  local fakebin=$1 mode=$2 PROBE_LOG=${3:-$1/../probe.log}
  mkdir -p "$fakebin"
  cat > "$fakebin/quota-axi" <<SH
#!/usr/bin/env bash
# Fake quota-axi. Records the credential shim it was pointed at so tests can
# assert isolation, then prints a fixed normalized answer.
prov=""
while [ \$# -gt 0 ]; do
  case "\$1" in --provider) prov=\$2; shift ;; esac
  shift
done
# The reader scrubs the environment, so the probe cannot be switched on by an
# exported variable; it always records what this fake actually received.
{
  printf 'provider=%s\n' "\$prov"
  printf 'argv_had_token=%s\n' "\$(printf '%s ' "\$0" "\$@" | grep -c "$TOKEN_MARK" || true)"
  printf 'env_had_token=%s\n' "\$(env | grep -c "$TOKEN_MARK" || true)"
  printf 'home=%s\n' "\${HOME:-unset}"
  printf 'cache=%s\n' "\${XDG_CACHE_HOME:-unset}"
  printf 'claude_dir=%s\n' "\${CLAUDE_CONFIG_DIR:-unset}"
  printf 'codex_home=%s\n' "\${CODEX_HOME:-unset}"
  printf 'codex_binary=%s\n' "\${QUOTA_AXI_CODEX_BINARY:-unset}"
  if [ -n "\${CODEX_HOME:-}" ] && [ -f "\$CODEX_HOME/auth.json" ]; then
    printf 'codex_shim_has_id_token=%s\n' "\$(grep -c id_token "\$CODEX_HOME/auth.json" || true)"
  fi
} >> "$PROBE_LOG"
mode="$mode"
if [ "\$prov" = claude ]; then
  case "\$mode" in
    tight)
      cat <<'J'
{"generatedAt":"2026-07-28T19:00:00Z","schemaVersion":2,"providers":[{"provider":"claude","label":"Claude","source":"oauth","plan":"max","account":{"email":"alpha@example.com","organization":"Acme"},"windows":[{"id":"five_hour","label":"5-hour session","kind":"session","percentUsed":97,"percentRemaining":3,"resetsAt":"2026-07-28T20:30:00Z","resetText":"in 1h 30m"}],"quotaSemantics":{"effectiveAvailability":[{"scope":"all_models","status":"known","effectivePercentRemaining":3,"limitingWindowIds":["five_hour"]}]},"state":{"status":"fresh","stale":false,"sourcesTried":["oauth"]}}]}
J
      ;;
    unknown)
      cat <<'J'
{"generatedAt":"2026-07-28T19:00:00Z","schemaVersion":2,"providers":[{"provider":"claude","label":"Claude","source":"oauth","plan":"max","account":{"email":"alpha@example.com","organization":"Acme"},"windows":[{"id":"five_hour","label":"5-hour session","kind":"session","percentUsed":35,"resetsAt":"2026-07-28T21:00:00Z","resetText":"in 2 hours"}],"quotaSemantics":{"effectiveAvailability":[{"scope":"all_models","status":"unknown","limitingWindowIds":[]}]},"state":{"status":"fresh","stale":false,"sourcesTried":["oauth"]}}]}
J
      ;;
    authfail)
      cat <<J
{"generatedAt":"2026-07-28T19:00:00Z","schemaVersion":2,"providers":[{"provider":"claude","label":"Claude","source":"unavailable","account":{"email":"alpha@example.com"},"windows":[],"state":{"status":"auth_required","stale":true,"error":"rejected credential at \$CLAUDE_CONFIG_DIR","sourcesTried":["oauth"]}}]}
J
      ;;
    *)
      cat <<'J'
{"generatedAt":"2026-07-28T19:00:00Z","schemaVersion":2,"providers":[{"provider":"claude","label":"Claude","source":"oauth","plan":"max","account":{"email":"alpha@example.com","organization":"Acme"},"windows":[{"id":"five_hour","label":"5-hour session","kind":"session","percentUsed":30,"percentRemaining":70,"resetsAt":"2026-07-28T22:00:00Z","resetText":"in 3 hours"},{"id":"seven_day","label":"Weekly","kind":"weekly","percentUsed":55,"percentRemaining":45,"resetsAt":"2026-08-02T00:00:00Z","resetText":"in 4d 5h"},{"id":"model:opus","label":"Opus weekly","kind":"model","percentUsed":80,"resetsAt":"2026-08-02T00:00:00Z","resetText":"in 4d 5h"}],"quotaSemantics":{"description":"per provider","effectiveAvailability":[{"scope":"all_models","status":"known","effectivePercentRemaining":45,"limitingWindowIds":["seven_day"]}]},"state":{"status":"fresh","stale":false,"sourcesTried":["oauth"]}}]}
J
      ;;
  esac
  exit 0
fi
case "\$mode" in
  partial) printf 'upstream exploded\n' >&2; exit 1 ;;
esac
cat <<'J'
{"generatedAt":"2026-07-28T19:00:00Z","schemaVersion":2,"providers":[{"provider":"codex","label":"Codex","source":"oauth","plan":"pro","account":{"email":"bravo@example.org","accountId":"ACCOUNTIDMARKER"},"windows":[{"id":"weekly","label":"Weekly","kind":"weekly","percentUsed":10,"percentRemaining":90,"resetsAt":"2026-08-03T00:00:00Z","resetText":"in 5d 5h","windowSeconds":604800}],"quotaSemantics":{"effectiveAvailability":[{"scope":"all_models","status":"known","effectivePercentRemaining":90,"limitingWindowIds":["weekly"]}]},"state":{"status":"fresh","stale":false,"sourcesTried":["oauth"]}}]}
J
SH
  chmod +x "$fakebin/quota-axi"
}

# run_pool <pool> <fakebin> [args...]: run the command with a pinned clock and
# the fake quota-axi first on PATH.
run_pool() {
  local pool=$1 fakebin=$2
  shift 2
  PATH="$fakebin:$PATH" \
  FM_HOME="${pool%/*}/home" \
  FM_POOL_QUOTA_DIR="$pool" \
  FM_POOL_QUOTA_NOW="$PINNED_NOW" \
    "$CMD" "$@"
}

# --- tests ------------------------------------------------------------------

test_multi_account_aggregation_is_per_provider() {
  local root pool fakebin out
  root=$(fm_test_tmproot fm-pool-quota-agg)
  pool="$root/pool"
  fakebin="$root/fakebin"
  make_pool "$pool"
  make_quota_axi "$fakebin" healthy

  out=$(run_pool "$pool" "$fakebin" --json) || fail "aggregation run failed"

  assert_contains "$out" '"schema":"fm-pool-quota.v1"' "output lost its schema tag"
  [ "$(printf '%s' "$out" | jq -r '.accounts_enabled')" = 2 ] \
    || fail "expected exactly the two enabled accounts to be measured"
  [ "$(printf '%s' "$out" | jq -r '.accounts_answered')" = 2 ] \
    || fail "expected both enabled accounts to answer"
  [ "$(printf '%s' "$out" | jq -r '.providers | length')" = 2 ] \
    || fail "expected one summary row per provider"
  [ "$(printf '%s' "$out" | jq -r '.providers[] | select(.provider=="claude") | .best_remaining')" = 45 ] \
    || fail "claude headline is not the provider's effective remaining"
  [ "$(printf '%s' "$out" | jq -r '.providers[] | select(.provider=="codex") | .best_remaining')" = 90 ] \
    || fail "codex headline is not the provider's effective remaining"

  # No aggregate field may blend the two providers into one number.
  if printf '%s' "$out" | jq -e 'has("pool_percent") or has("overall_remaining") or has("average_remaining")' >/dev/null; then
    fail "output claims a cross-provider percentage"
  fi
  assert_contains "$out" "never added, averaged, or ranked against each other" \
    "output lost the explicit no-cross-provider-equivalence statement"
  pass "multi-account aggregation stays per provider with no blended percentage"
}

test_identity_is_masked_everywhere() {
  local root pool fakebin out panel
  root=$(fm_test_tmproot fm-pool-quota-mask)
  pool="$root/pool"
  fakebin="$root/fakebin"
  make_pool "$pool"
  make_quota_axi "$fakebin" healthy

  out=$(run_pool "$pool" "$fakebin" --accounts --panel --json) \
    || fail "masked run failed"
  panel=$(printf '%s' "$out" | jq -r '.panel')

  assert_not_contains "$out" "$EMAIL_A" "a full account address reached stdout"
  assert_not_contains "$out" "$EMAIL_B" "a full account address reached stdout"
  assert_not_contains "$out" "$ACCOUNT_ID_MARK" "a provider account id reached stdout"
  assert_not_contains "$out" "alpha.json" "a raw pool file name reached stdout"
  assert_contains "$out" "al***@ex***.com#" "the masked claude label is missing"
  assert_contains "$out" "br***@ex***.org#" "the masked codex label is missing"

  assert_no_grep "$EMAIL_A" "$panel" "a full account address reached the panel"
  assert_no_grep "$EMAIL_B" "$panel" "a full account address reached the panel"
  assert_no_grep "$ACCOUNT_ID_MARK" "$panel" "a provider account id reached the panel"
  assert_grep 'al***@ex***.com#' "$panel" "the panel lost the masked claude label"

  # Refused and skipped file names are masked too.
  assert_not_contains "$out" "delta.json" "a refused file name was printed unmasked"
  assert_contains "$out" "de***.json#" "the refused file label is not masked"
  pass "account identity and pool file names are masked in every surface"
}

test_hostile_credential_files_are_refused() {
  local root pool fakebin out reasons
  root=$(fm_test_tmproot fm-pool-quota-hostile)
  pool="$root/pool"
  fakebin="$root/fakebin"
  make_pool "$pool"
  make_quota_axi "$fakebin" healthy

  out=$(run_pool "$pool" "$fakebin" --json) || fail "hostile-input run failed"
  reasons=$(printf '%s' "$out" | jq -r '.refused[].reason' | sort | tr '\n' '|')

  assert_contains "$reasons" "symlink refused" "a symlinked credential file was not refused"
  assert_contains "$reasons" "not valid JSON" "a malformed credential file was not refused"
  assert_contains "$reasons" "empty file" "an empty credential file was not refused"
  assert_contains "$reasons" "over the " "an oversized credential file was not refused"
  assert_contains "$reasons" "not a JSON object" "a non-object credential file was not refused"
  assert_contains "$reasons" "unsupported account type" "an unknown provider type was not refused"
  assert_contains "$reasons" "no usable credential" "a credential file with no token was not refused"
  [ "$(printf '%s' "$out" | jq '[.refused[] | select(.reason == "malformed disabled flag")] | length')" = 4 ] \
    || fail "malformed or missing disabled flags were not all refused"

  # A disabled account is skipped, not refused: the pool itself turned it off.
  [ "$(printf '%s' "$out" | jq -r '.accounts_skipped')" = 1 ] \
    || fail "the pool-disabled account was not reported as skipped"
  assert_contains "$out" "disabled in the pool" "the skip reason is missing"

  # Only the two well-formed enabled accounts were ever measured.
  [ "$(printf '%s' "$out" | jq -r '.accounts_enabled')" = 2 ] \
    || fail "a refused file was measured anyway"
  pass "symlinked, malformed, empty, oversized, and unsupported files are refused with reasons"
}

test_quota_axi_semantics_are_preserved_without_local_inference() {
  local root pool fakebin out panel
  root=$(fm_test_tmproot fm-pool-quota-semantics)
  pool="$root/pool"
  fakebin="$root/fakebin"
  make_pool "$pool"
  make_quota_axi "$fakebin" unknown

  out=$(run_pool "$pool" "$fakebin" --accounts --json) || fail "unknown-semantics run failed"
  [ "$(printf '%s' "$out" | jq -r '.providers[] | select(.provider=="claude") | .quota_status')" = unknown ] \
    || fail "the provider lost quota-axi's unknown semantic status"
  [ "$(printf '%s' "$out" | jq -r '.providers[] | select(.provider=="claude") | .health')" = unknown ] \
    || fail "unknown quota semantics were relabeled healthy"
  [ "$(printf '%s' "$out" | jq -r '.providers[] | select(.provider=="claude") | .best_remaining')" = null ] \
    || fail "unknown effective availability was turned into a percentage"
  [ "$(printf '%s' "$out" | jq -r '.windows[] | select(.provider=="claude") | .percent_remaining')" = null ] \
    || fail "percent remaining was recomputed from percent used"
  [ "$(printf '%s' "$out" | jq -r '.providers[] | select(.provider=="claude") | .soonest_reset_in')" = "in 2 hours" ] \
    || fail "quota-axi's reset text was not preserved"

  panel=$(printf '%s' "$out" | jq -r '.panel')
  assert_present "$panel" "the default invocation did not regenerate its panel"
  assert_grep 'unknown' "$panel" "the panel did not represent unavailable quota as unknown"
  pass "quota percentages, reset text, and semantic status stay owned by quota-axi"
}

test_partial_provider_failure_is_reported_not_hidden() {
  local root pool fakebin out
  root=$(fm_test_tmproot fm-pool-quota-partial)
  pool="$root/pool"
  fakebin="$root/fakebin"
  make_pool "$pool"
  make_quota_axi "$fakebin" partial

  out=$(run_pool "$pool" "$fakebin" --accounts --json) \
    || fail "the run must succeed even when one provider fails"

  [ "$(printf '%s' "$out" | jq -r '.providers[] | select(.provider=="claude") | .health')" = healthy ] \
    || fail "the working provider was dragged down by the failing one"
  [ "$(printf '%s' "$out" | jq -r '.providers[] | select(.provider=="codex") | .health')" = down ] \
    || fail "the failing provider was not reported as down"
  [ "$(printf '%s' "$out" | jq -r '.providers[] | select(.provider=="codex") | .best_remaining')" = null ] \
    || fail "a failed read was turned into a capacity number"
  [ "$(printf '%s' "$out" | jq -r '.accounts[] | select(.provider=="codex") | .status')" = unavailable ] \
    || fail "the failing account was not marked unavailable"
  [ "$(printf '%s' "$out" | jq -r '.accounts_answered')" = 1 ] \
    || fail "the answered count includes an account that did not answer"
  pass "one provider failing leaves the other intact and is never scored as zero"
}

test_auth_failure_scrubs_the_private_workspace_path() {
  local root pool fakebin out
  root=$(fm_test_tmproot fm-pool-quota-auth)
  pool="$root/pool"
  fakebin="$root/fakebin"
  make_pool "$pool"
  make_quota_axi "$fakebin" authfail

  out=$(run_pool "$pool" "$fakebin" --accounts --json) || fail "auth-failure run failed"

  assert_contains "$out" 'auth_required' "the auth failure was not surfaced"
  assert_contains "$out" '<private>' "the private workspace path was not scrubbed"
  assert_not_contains "$out" "${TMPDIR:-/tmp}/fm-pool-quota." \
    "the private workspace path leaked through a provider error string"
  pass "a provider error message cannot leak the private workspace path"
}

test_credentials_never_reach_argv_stdout_panel_or_cache() {
  local root pool fakebin out panel probe
  root=$(fm_test_tmproot fm-pool-quota-secret)
  pool="$root/pool"
  fakebin="$root/fakebin"
  probe="$root/probe.log"
  make_pool "$pool"
  make_quota_axi "$fakebin" healthy "$probe"

  out=$(run_pool "$pool" "$fakebin" --accounts --panel --json 2>&1) \
    || fail "secret-containment run failed"
  panel=$(printf '%s' "$out" | jq -r '.panel')

  assert_not_contains "$out" "$TOKEN_MARK" "a credential reached stdout"
  assert_no_grep "$TOKEN_MARK" "$panel" "a credential reached the panel"

  assert_present "$probe" "the quota-axi probe did not run"
  assert_no_grep "$TOKEN_MARK" "$probe" "a credential was passed on the command line"
  assert_grep 'argv_had_token=0' "$probe" "the credential appeared in argv"
  assert_grep 'env_had_token=0' "$probe" "the credential appeared in the environment"

  # The reader must run against a private HOME and cache, never the operator's.
  assert_no_grep "home=$HOME\$" "$probe" "quota-axi ran with the operator's real HOME"
  assert_grep 'cache=/' "$probe" "quota-axi ran without a private cache directory"
  assert_grep 'codex_binary=' "$probe" "the codex CLI fallback was left unpinned"
  # The codex shim must omit id_token: an expired one would mark a live account
  # expired even when its access token is current.
  assert_no_grep 'codex_shim_has_id_token=[1-9]' "$probe" \
    "the codex credential shim carried an id_token"

  # Nothing under the pool directory may be written.
  assert_absent "$pool/.credentials.json" "the reader wrote into the pool directory"
  assert_absent "$pool/auth.json" "the reader wrote into the pool directory"
  pass "credentials stay out of argv, stdout, the panel, the shared cache, and the pool"
}

test_private_workspace_is_cleaned_up() {
  local root pool fakebin before after
  root=$(fm_test_tmproot fm-pool-quota-cleanup)
  pool="$root/pool"
  fakebin="$root/fakebin"
  make_pool "$pool"
  make_quota_axi "$fakebin" healthy

  before=$(find "${TMPDIR:-/tmp}" -maxdepth 1 -name 'fm-pool-quota.*' 2>/dev/null | wc -l | tr -d ' ')
  run_pool "$pool" "$fakebin" --json >/dev/null || fail "cleanup run failed"
  after=$(find "${TMPDIR:-/tmp}" -maxdepth 1 -name 'fm-pool-quota.*' 2>/dev/null | wc -l | tr -d ' ')
  [ "$before" = "$after" ] || fail "the private workspace outlived the run"

  # An interrupt must clean up too.
  PATH="$fakebin:$PATH" FM_HOME="$root/home" FM_POOL_QUOTA_DIR="$pool" FM_POOL_QUOTA_NOW="$PINNED_NOW" \
    "$CMD" --json >/dev/null 2>&1 &
  local pid=$!
  kill -TERM "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
  after=$(find "${TMPDIR:-/tmp}" -maxdepth 1 -name 'fm-pool-quota.*' 2>/dev/null | wc -l | tr -d ' ')
  [ "$before" = "$after" ] || fail "the private workspace survived an interrupt"
  pass "the private credential workspace is removed on normal exit and on interrupt"
}

test_output_is_deterministic_and_panel_is_regenerated() {
  local root pool fakebin first second changed panel first_panel second_panel
  root=$(fm_test_tmproot fm-pool-quota-determinism)
  pool="$root/pool"
  fakebin="$root/fakebin"
  make_pool "$pool"
  make_quota_axi "$fakebin" healthy

  first=$(run_pool "$pool" "$fakebin" --accounts --json) || fail "first run failed"
  second=$(run_pool "$pool" "$fakebin" --accounts --json) || fail "second run failed"
  [ "$first" = "$second" ] || fail "two identical reads produced different output"

  panel=$(printf '%s' "$first" | jq -r '.panel')
  assert_present "$panel" "an ordinary invocation did not write its panel"
  first_panel=$(cat "$panel")

  # A changed pool must produce a changed panel: the artifact is rebuilt, never
  # reused from the previous run.
  make_quota_axi "$fakebin" tight
  changed=$(run_pool "$pool" "$fakebin" --json) || fail "second panel run failed"
  second_panel=$(cat "$panel")
  [ "$first_panel" != "$second_panel" ] || fail "the panel was not regenerated from a fresh read"
  assert_contains "$second_panel" "3%" "the regenerated panel does not show the new reading"
  [ "$(printf '%s' "$changed" | jq -r '.providers[] | select(.provider=="claude") | .health')" = healthy ] \
    || fail "a local percentage threshold replaced quota-axi's semantic status"
  pass "identical reads are byte-identical and the panel is rebuilt every run"
}

test_panel_is_self_contained_local_and_private() {
  local root pool fakebin panel body out code
  root=$(fm_test_tmproot fm-pool-quota-panel)
  pool="$root/pool"
  fakebin="$root/fakebin"
  make_pool "$pool"
  make_quota_axi "$fakebin" healthy

  out=$(run_pool "$pool" "$fakebin" --panel --json) || fail "panel run failed"
  panel=$(printf '%s' "$out" | jq -r '.panel')
  body=$(cat "$panel")

  # No external fetch at view time: this artifact renders credential-derived
  # state, so it must not pull third-party script or style.
  assert_not_contains "$body" "http://" "the panel fetches an external resource"
  assert_not_contains "$body" "https://" "the panel fetches an external resource"
  assert_not_contains "$body" "<script" "the panel embeds script"

  assert_contains "$body" "5-hour session" "the panel lost the Claude session window"
  assert_contains "$body" "Weekly" "the panel lost a weekly window"
  assert_contains "$body" "Opus weekly" "the panel lost the per-model window"
  assert_contains "$body" "Resets in" "the panel lost reset timing"
  assert_contains "$body" "Not measured" "the panel does not disclose unmeasured files"
  assert_contains "$body" "never added, averaged, or ranked" \
    "the panel lost its no-cross-provider-equivalence explanation"
  assert_contains "$body" "Do not publish or share it" "the panel lost its privacy notice"

  [ "$(stat -f '%Lp' "$panel" 2>/dev/null || stat -c '%a' "$panel")" = 600 ] \
    || fail "the panel is not written with private permissions"

  mkdir "$root/outside"
  rm "$panel"
  ln -s "$root/outside" "$panel"
  run_pool "$pool" "$fakebin" --json >/dev/null || fail "panel leaf-symlink replacement failed"
  [ ! -L "$panel" ] || fail "the canonical panel remained a symlink"
  [ -f "$panel" ] || fail "the canonical panel was not atomically installed"
  [ -z "$(find "$root/outside" -mindepth 1 -maxdepth 1 -print -quit)" ] \
    || fail "the panel followed a directory symlink outside its private directory"
  [ -z "$(find "$root/home/.lavish" -name '.pool-quota.*' -print -quit)" ] \
    || fail "a private panel artifact survived successful installation"

  rm "$panel"
  mkdir "$panel"
  code=0
  out=$(run_pool "$pool" "$fakebin" --json 2>&1) || code=$?
  expect_code 2 "$code" "a panel installation collision must fail closed"
  assert_contains "$out" "cannot install the panel" "the panel installation failure is not explained"
  [ -z "$(find "$root/home/.lavish" -name '.pool-quota.*' -print -quit)" ] \
    || fail "a failed panel installation left its private artifact behind"
  rmdir "$panel"

  rmdir "$root/home/.lavish"
  ln -s "$root/outside" "$root/home/.lavish"
  code=0
  out=$(run_pool "$pool" "$fakebin" --json 2>&1) || code=$?
  expect_code 2 "$code" "a symlinked panel directory must be refused"
  assert_contains "$out" "panel directory must not be a symlink" "the panel-directory refusal is not explained"
  assert_absent "$root/outside/pool-quota.html" "the panel escaped through a symlinked private directory"
  pass "the panel is self-contained, complete, and marked private"
}

test_concise_view_hides_account_rows_but_discloses_the_omission() {
  local root pool fakebin concise detailed
  root=$(fm_test_tmproot fm-pool-quota-concise)
  pool="$root/pool"
  fakebin="$root/fakebin"
  make_pool "$pool"
  make_quota_axi "$fakebin" healthy

  concise=$(run_pool "$pool" "$fakebin" --json) || fail "concise run failed"
  detailed=$(run_pool "$pool" "$fakebin" --accounts --json) || fail "detailed run failed"

  printf '%s' "$concise" | jq -e 'has("accounts") | not' >/dev/null \
    || fail "the concise view exposed per-account rows"
  assert_contains "$concise" '"reveal":"--accounts"' \
    "the concise view hides account rows without disclosing how to reveal them"
  printf '%s' "$detailed" | jq -e '.accounts | length == 2' >/dev/null \
    || fail "the detailed view is missing account rows"
  printf '%s' "$detailed" | jq -e '.windows | length == 4' >/dev/null \
    || fail "the detailed view is missing window rows"
  pass "the concise view omits detail explicitly and --accounts reveals it"
}

test_missing_pool_and_bad_arguments_stop_safely() {
  local root fakebin out code
  root=$(fm_test_tmproot fm-pool-quota-guard)
  fakebin="$root/fakebin"
  make_quota_axi "$fakebin" healthy

  out=$(run_pool "$root/absent-pool" "$fakebin" --json) || fail "a missing pool must not be an error exit"
  assert_contains "$out" '"pool_state":"missing"' "an absent pool directory was not reported"
  [ "$(printf '%s' "$out" | jq -r '.accounts_discovered')" = 0 ] \
    || fail "an absent pool reported accounts"

  code=0
  out=$(run_pool "$root/absent-pool" "$fakebin" --nonsense 2>&1) || code=$?
  expect_code 2 "$code" "an unknown argument must be refused"
  assert_contains "$out" "unknown argument" "the refusal did not name the bad argument"

  code=0
  out=$(run_pool "$root/absent-pool" "$fakebin" --panel-path "$root/escaped.html" 2>&1) || code=$?
  expect_code 2 "$code" "the removed panel-path option must be refused"
  assert_contains "$out" "unknown argument" "the removed panel-path option was not rejected"
  assert_absent "$root/escaped.html" "the removed panel-path option wrote outside the private panel directory"

  code=0
  out=$(PATH="$fakebin:$PATH" FM_POOL_QUOTA_DIR="$root/absent-pool" \
    FM_POOL_QUOTA_MAX_BYTES=0 "$CMD" --json 2>&1) || code=$?
  expect_code 2 "$code" "a zero size bound must be refused"
  assert_contains "$out" "must be a positive integer" "the bound refusal is not explained"
  pass "an absent pool reports plainly and bad inputs stop with a reason"
}

test_the_reader_never_writes_to_the_pool() {
  local root pool fakebin before after
  root=$(fm_test_tmproot fm-pool-quota-readonly)
  pool="$root/pool"
  fakebin="$root/fakebin"
  make_pool "$pool"
  make_quota_axi "$fakebin" healthy

  before=$(cd "$pool" && find . | sort | while read -r f; do printf '%s %s\n' "$f" "$(wc -c < "$f" 2>/dev/null || echo dir)"; done)
  run_pool "$pool" "$fakebin" --accounts --panel >/dev/null \
    || fail "read-only run failed"
  after=$(cd "$pool" && find . | sort | while read -r f; do printf '%s %s\n' "$f" "$(wc -c < "$f" 2>/dev/null || echo dir)"; done)
  [ "$before" = "$after" ] || fail "the pool directory changed during a read"
  pass "reading the pool leaves every account file untouched"
}

test_skill_owns_the_platform_aware_nonblocking_panel_open() {
  local docs="$ROOT/docs/configuration.md"
  local skill="$ROOT/.agents/skills/poolquota/SKILL.md"

  assert_grep "On macOS (\`uname -s\` reports \`Darwin\`), run \`open \"\$panel\"\`" "$skill" \
    "the poolquota skill does not define the macOS nonblocking opener"
  assert_grep "On Linux, require \`xdg-open\`, then launch \`nohup xdg-open \"\$panel\" </dev/null >/dev/null 2>&1 &\`" "$skill" \
    "the poolquota skill does not detach the Linux opener"
  assert_grep "On Linux, \`xdg-open\` must be available for the skill to open the freshly regenerated panel." "$docs" \
    "the authoritative configuration guide omits the Linux opener prerequisite"
  assert_no_grep 'Nothing else is required.' "$docs" \
    "the authoritative configuration guide contradicts the Linux opener prerequisite"
  assert_grep "Do not use \`lavish-axi\` for this display-only dashboard" "$skill" \
    "the poolquota skill does not distinguish dashboards from review surfaces"
  assert_no_grep 'lavish-axi' "$CMD" \
    "the quota adapter still assigns the dashboard opener to lavish-axi"
  assert_no_grep 'xdg-open' "$CMD" \
    "the quota adapter competes with the skill for Linux opener ownership"
  assert_no_grep '`open ' "$CMD" \
    "the quota adapter competes with the skill for macOS opener ownership"
  pass "the poolquota skill alone owns nonblocking panel opening on macOS and Linux"
}

test_multi_account_aggregation_is_per_provider
test_identity_is_masked_everywhere
test_hostile_credential_files_are_refused
test_quota_axi_semantics_are_preserved_without_local_inference
test_partial_provider_failure_is_reported_not_hidden
test_auth_failure_scrubs_the_private_workspace_path
test_credentials_never_reach_argv_stdout_panel_or_cache
test_private_workspace_is_cleaned_up
test_output_is_deterministic_and_panel_is_regenerated
test_panel_is_self_contained_local_and_private
test_concise_view_hides_account_rows_but_discloses_the_omission
test_missing_pool_and_bad_arguments_stop_safely
test_the_reader_never_writes_to_the_pool
test_skill_owns_the_platform_aware_nonblocking_panel_open
