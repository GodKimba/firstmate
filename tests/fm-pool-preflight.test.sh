#!/usr/bin/env bash
# tests/fm-pool-preflight.test.sh - behavior tests for the quota-aware admission
# check.
#
# Every case runs against isolated fakes: a stub quota-axi and a stub
# fm-pool-quota.sh, both fed from fixture JSON. No test contacts the real
# quota-axi, the real pool directory, or the local proxy, so running this suite
# cannot read a credential or disturb live routing.
#
# The cases encode the properties the admission check has to hold: a tight
# account is refused rather than admitted, an unreadable quota is reported rather
# than guessed, false is not confused with missing, ties do not award an account
# that cannot be bound, hostile account metadata cannot fake headroom, and the
# absent-configuration path still behaves.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

PREFLIGHT="$ROOT/bin/fm-pool-preflight.sh"
TMP=$(fm_test_tmproot fm-pool-preflight)
BIN="$TMP/bin"
mkdir -p "$BIN"

# --- fakes -------------------------------------------------------------------

# A stub quota-axi that prints whatever fixture the case selected. It also
# records its argv, so a test can prove no credential or account identity was
# ever passed on a command line.
cat > "$BIN/quota-axi" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FM_FAKE_QUOTA_ARGV"
[ -n "${FM_FAKE_QUOTA_DOC:-}" ] || exit 1
[ -s "$FM_FAKE_QUOTA_DOC" ] || exit 1
cat "$FM_FAKE_QUOTA_DOC"
SH
chmod +x "$BIN/quota-axi"

# A stub fm-pool-quota.sh standing in for the real adapter's --json --accounts
# projection. The real script owns credential handling; this fake only replays a
# fixture of its output contract.
cat > "$BIN/fm-pool-quota.sh" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FM_FAKE_POOL_ARGV"
[ -n "${FM_FAKE_POOL_DOC:-}" ] || exit 1
[ -s "$FM_FAKE_POOL_DOC" ] || exit 1
cat "$FM_FAKE_POOL_DOC"
SH
chmod +x "$BIN/fm-pool-quota.sh"

export FM_FAKE_QUOTA_ARGV="$TMP/quota.argv"
export FM_FAKE_POOL_ARGV="$TMP/pool.argv"
: > "$FM_FAKE_QUOTA_ARGV"
: > "$FM_FAKE_POOL_ARGV"

export FM_POOL_PREFLIGHT_BIN="$BIN/quota-axi"
export FM_POOL_QUOTA_SH="$BIN/fm-pool-quota.sh"

# --- fixture builders --------------------------------------------------------

# direct_doc <file> <status> <pct> <stale> [extra-availability-json]
# Builds a quota-axi provider document with an all_models availability entry.
direct_doc() {
  local file=$1 status=$2 pct=$3 stale=$4 extra=${5:-}
  jq -n --arg status "$status" --argjson pct "$pct" --argjson stale "$stale" \
        --argjson extra "${extra:-[]}" '
    {providers: [
      {provider: "codex", plan: "pro", source: "cli-rpc",
       state: {status: (if $stale then "stale" else "fresh" end), stale: $stale},
       quotaSemantics: {effectiveAvailability:
         ([{scope: "all_models", status: $status,
            effectivePercentRemaining: $pct, limitingWindowIds: ["weekly"]}]
          + $extra)}}]}' > "$file"
}

# pool_doc <file> <accounts-json>: build an fm-pool-quota.v1 --accounts payload.
pool_doc() {
  local file=$1 accounts=$2
  jq -n --argjson accounts "$accounts" \
    '{schema: "fm-pool-quota.v1", accounts: $accounts}' > "$file"
}

# pool_account <label> <status> <pct> <stale>: one masked account row.
pool_account() {
  jq -nc --arg account "$1" --arg status "$2" --argjson pct "$3" --argjson stale "$4" \
    '{account: $account, provider: "codex", status: "fresh",
      quota_status: $status, effective_remaining: $pct,
      bounded_by: "weekly", stale: $stale}'
}

# run_preflight <args...>: run and capture stdout plus exit code into RUN_OUT
# and RUN_CODE. stderr is captured separately so secret-leak assertions can
# check both streams.
RUN_OUT=; RUN_CODE=; RUN_ERR=
run_preflight() {
  RUN_OUT=$("$PREFLIGHT" "$@" 2>"$TMP/stderr") && RUN_CODE=0 || RUN_CODE=$?
  RUN_ERR=$(cat "$TMP/stderr")
}

# --- healthy account is admitted --------------------------------------------

export FM_FAKE_QUOTA_DOC="$TMP/fresh.json"
direct_doc "$FM_FAKE_QUOTA_DOC" known 91 false
run_preflight --direct --json
expect_code 0 "$RUN_CODE" "healthy direct account exits go"
assert_contains "$RUN_OUT" '"decision":"go"' "healthy account is admitted"
assert_contains "$RUN_OUT" '"binds_account":false' "result discloses it binds no account"
pass "a healthy account is admitted and the result denies binding an account"

# --- a fresh reading is not reported stale -----------------------------------
#
# Regression: jq's `//` treats false as empty, so `.stale // true` turns every
# fresh reading stale. That would make the honest case look degraded.
assert_contains "$RUN_OUT" '"stale":false' "a fresh reading stays fresh"
pass "a fresh reading is not misreported as stale"

# --- a tight account is refused before a long run starts ---------------------

direct_doc "$FM_FAKE_QUOTA_DOC" known 4 false
run_preflight --direct --json
expect_code 3 "$RUN_CODE" "tight direct account exits hold"
assert_contains "$RUN_OUT" '"decision":"hold"' "a tight account is held"
assert_contains "$RUN_OUT" '"best":4' "the tight headroom is reported, not hidden"
pass "a tight account is refused and its actual headroom is reported"

# --- the floor boundary is inclusive ----------------------------------------

direct_doc "$FM_FAKE_QUOTA_DOC" known 20 false
run_preflight --direct --floor 20 --json
expect_code 0 "$RUN_CODE" "headroom exactly at the floor is admitted"
pass "the floor is inclusive: exactly-at-floor headroom is admitted"

# --- unknown quota is reported, never guessed --------------------------------

direct_doc "$FM_FAKE_QUOTA_DOC" unknown null false
run_preflight --direct --json
expect_code 4 "$RUN_CODE" "unknown quota exits unknown"
assert_contains "$RUN_OUT" '"decision":"unknown"' "unknown quota is reported as unknown"
assert_not_contains "$RUN_OUT" '"decision":"go"' "unknown quota is never silently admitted"
pass "unknown quota is reported rather than guessed, and is not treated as go"

# --- a quota read that fails outright is unknown, not go ---------------------

FM_FAKE_QUOTA_DOC="$TMP/missing.json"
export FM_FAKE_QUOTA_DOC
rm -f "$FM_FAKE_QUOTA_DOC"
run_preflight --direct --json
expect_code 4 "$RUN_CODE" "a failed quota read exits unknown"
assert_contains "$RUN_OUT" '"measured":0' "a failed read measures nothing"
pass "a quota read that fails is unknown rather than admitted"

# --- malformed quota output cannot fake headroom -----------------------------

FM_FAKE_QUOTA_DOC="$TMP/garbage.json"
export FM_FAKE_QUOTA_DOC
printf 'not json at all\n' > "$FM_FAKE_QUOTA_DOC"
run_preflight --direct --json
expect_code 4 "$RUN_CODE" "malformed quota output exits unknown"
assert_contains "$RUN_OUT" '"decision":"unknown"' "malformed output is unknown"
pass "malformed quota output cannot produce a go"

# --- a hostile percentage type cannot fake headroom --------------------------
#
# A string percentage must not compare as a number and slip past the floor.
FM_FAKE_QUOTA_DOC="$TMP/hostile.json"
export FM_FAKE_QUOTA_DOC
jq -n '{providers: [{provider: "codex", state: {status: "fresh", stale: false},
        quotaSemantics: {effectiveAvailability: [
          {scope: "all_models", status: "known",
           effectivePercentRemaining: "100", limitingWindowIds: []}]}}]}' \
  > "$FM_FAKE_QUOTA_DOC"
run_preflight --direct --json
expect_code 4 "$RUN_CODE" "a non-numeric percentage exits unknown"
assert_not_contains "$RUN_OUT" '"decision":"go"' "a string percentage cannot be admitted"
pass "hostile non-numeric quota metadata cannot fake headroom"

# --- a model window tighter than all_models is honoured ----------------------

FM_FAKE_QUOTA_DOC="$TMP/model.json"
export FM_FAKE_QUOTA_DOC
direct_doc "$FM_FAKE_QUOTA_DOC" known 90 false \
  '[{"scope":"model:codex_bengalfox","status":"known","effectivePercentRemaining":3,"limitingWindowIds":["weekly"]}]'
run_preflight --direct --model codex_bengalfox --json
expect_code 3 "$RUN_CODE" "a tight model window holds even when all_models is roomy"
assert_contains "$RUN_OUT" '"best":3' "the model window is the bound that is used"
assert_contains "$RUN_OUT" '"scope_kind":"model"' "the model scope is disclosed"
pass "a model window tighter than all_models decides the outcome"

# --- an unscoped model name discloses the coarser bound ----------------------
#
# quota-axi scopes by provider-internal ids, so a configured model name usually
# has no window of its own. Falling back is fine; doing it silently is not.
run_preflight --direct --model gpt-5.6-sol --json
assert_contains "$RUN_OUT" '"scope_kind":"all_models_fallback"' \
  "an unscoped model name discloses that a coarser bound was used"
pass "an unscoped model name discloses the coarser bound instead of implying a match"

# --- pool mode: the best account bounds the decision -------------------------

export FM_FAKE_POOL_DOC="$TMP/pool.json"
pool_doc "$FM_FAKE_POOL_DOC" "[$(pool_account 'ra..@ex..le.com#a1' known 12 false),
                               $(pool_account 'jo..@ex..le.com#b2' known 77 false),
                               $(pool_account 'sa..@ex..le.com#c3' known 41 false)]"
run_preflight --pool --json
expect_code 0 "$RUN_CODE" "pool mode admits when the best account has headroom"
assert_contains "$RUN_OUT" '"best":77' "the best account bounds the decision"
assert_contains "$RUN_OUT" '"measured":3' "every candidate is accounted for"
pass "pool mode bounds the decision by the best account and counts every candidate"

# --- pool mode: all tight holds, and reports the best it saw -----------------

pool_doc "$FM_FAKE_POOL_DOC" "[$(pool_account 'ra..@ex..le.com#a1' known 5 false),
                               $(pool_account 'jo..@ex..le.com#b2' known 9 false)]"
run_preflight --pool --json
expect_code 3 "$RUN_CODE" "an all-tight pool holds"
assert_contains "$RUN_OUT" '"best":9' "the best observed headroom is attached to the hold"
assert_contains "$RUN_OUT" '"measured":2' "all-tight still accounts for every candidate"
pass "an all-tight pool holds and reports the best headroom rather than downgrading"

# --- pool mode: unmeasured accounts are counted, not assumed healthy ---------

pool_doc "$FM_FAKE_POOL_DOC" "[$(pool_account 'ra..@ex..le.com#a1' known 55 false),
                               $(pool_account 'jo..@ex..le.com#b2' unknown null false),
                               $(pool_account 'sa..@ex..le.com#c3' unknown null true)]"
run_preflight --pool --json
expect_code 0 "$RUN_CODE" "a measurable account still decides"
assert_contains "$RUN_OUT" '"candidates":3' "unmeasured accounts are still counted"
assert_contains "$RUN_OUT" '"measured":1' "only measured accounts count as measured"
pass "unmeasured pool accounts are disclosed rather than assumed healthy"

# --- pool mode: every account silent is unknown, not go ----------------------

pool_doc "$FM_FAKE_POOL_DOC" "[$(pool_account 'ra..@ex..le.com#a1' unknown null true),
                               $(pool_account 'jo..@ex..le.com#b2' unknown null true)]"
run_preflight --pool --json
expect_code 4 "$RUN_CODE" "an entirely unmeasurable pool exits unknown"
assert_contains "$RUN_OUT" '"decision":"unknown"' "a silent pool is unknown"
pass "a pool where no account can be measured is unknown, never admitted"

# --- pool mode: an empty pool is unknown ------------------------------------

pool_doc "$FM_FAKE_POOL_DOC" '[]'
run_preflight --pool --json
expect_code 4 "$RUN_CODE" "an empty pool exits unknown"
assert_contains "$RUN_OUT" '"candidates":0' "an empty pool reports no candidates"
pass "an empty pool is unknown rather than admitted"

# --- pool mode: a tie is resolved by value and awards no binding -------------
#
# There is no account to award, because no interface can pin one. The tie must
# still produce a stable decision and must keep denying that it bound anything.
pool_doc "$FM_FAKE_POOL_DOC" "[$(pool_account 'aa..@ex..le.com#a1' known 50 false),
                               $(pool_account 'bb..@ex..le.com#b2' known 50 false)]"
run_preflight --pool --json
expect_code 0 "$RUN_CODE" "a tie still reaches a decision"
assert_contains "$RUN_OUT" '"best":50' "a tie resolves on value"
assert_contains "$RUN_OUT" '"binds_account":false' "a tie awards no account binding"
first=$RUN_OUT
run_preflight --pool --json
[ "$RUN_OUT" = "$first" ] || fail "a tie must decide identically on repeat runs"
pass "a tie decides on value, repeats deterministically, and binds no account"

# --- pool mode: non-codex accounts are excluded -----------------------------

pool_doc "$FM_FAKE_POOL_DOC" '[{"account":"cl..@ex..le.com#d4","provider":"claude",
  "status":"fresh","quota_status":"known","effective_remaining":99,
  "bounded_by":"weekly","stale":false}]'
run_preflight --pool --json
expect_code 4 "$RUN_CODE" "a claude-only pool offers no codex candidate"
assert_not_contains "$RUN_OUT" '"best":99' "claude headroom never stands in for codex"
pass "provider-incompatible accounts are excluded rather than counted as capacity"

# --- concurrent runs agree and never interfere -------------------------------
#
# The check is read-only, so parallel callers must reach the same verdict and
# leave nothing behind that could serialize or corrupt them.
pool_doc "$FM_FAKE_POOL_DOC" "[$(pool_account 'ra..@ex..le.com#a1' known 64 false)]"
pids=(); : > "$TMP/concurrent.out"
for _ in 1 2 3 4 5; do
  ( "$PREFLIGHT" --pool --json >> "$TMP/concurrent.out" 2>/dev/null ) &
  pids+=($!)
done
for p in "${pids[@]}"; do wait "$p"; done
distinct=$(sort -u "$TMP/concurrent.out" | grep -c . || true)
[ "$distinct" = 1 ] || fail "concurrent runs disagreed: $distinct distinct results"
[ "$(grep -c . "$TMP/concurrent.out")" = 5 ] || fail "not every concurrent run produced a result"
pass "concurrent runs reach one identical verdict and do not interfere"

# --- no credential reaches argv, stdout, or stderr ---------------------------
#
# The fakes record their own argv. Nothing the check passes may look like a
# credential, and no account file path may appear in any output stream.
assert_no_grep "access_token" "$FM_FAKE_QUOTA_ARGV" "no token reached quota-axi argv"
assert_no_grep "Bearer" "$FM_FAKE_QUOTA_ARGV" "no bearer credential reached quota-axi argv"
assert_no_grep ".cli-proxy-api" "$FM_FAKE_POOL_ARGV" "no pool path reached the adapter argv"
assert_not_contains "$RUN_OUT" "access_token" "no token appears on stdout"
assert_not_contains "$RUN_ERR" "access_token" "no token appears on stderr"
pass "no credential material reaches argv, stdout, or stderr"

# --- the check mutates nothing ----------------------------------------------
#
# An admission check that wrote state could not be run freely before a decision.
before=$(find "$TMP" -type f | sort)
run_preflight --pool --json
after=$(find "$TMP" -type f | sort)
[ "$before" = "$after" ] || fail "the preflight created or removed files"
pass "the check mutates nothing: no file is created, moved, or removed"

# --- usage errors are refused, not defaulted ---------------------------------

run_preflight
expect_code 2 "$RUN_CODE" "a missing mode is a usage error"
run_preflight --direct --pool
expect_code 2 "$RUN_CODE" "two modes is a usage error"
run_preflight --direct --floor 101
expect_code 2 "$RUN_CODE" "an out-of-range floor is a usage error"
run_preflight --direct --floor abc
expect_code 2 "$RUN_CODE" "a non-numeric floor is a usage error"
run_preflight --direct --model
expect_code 2 "$RUN_CODE" "a model flag with no value is a usage error"
run_preflight --bogus
expect_code 2 "$RUN_CODE" "an unknown flag is a usage error"
pass "usage errors are refused rather than silently defaulted"

# --- a missing pool adapter is an error, not a go ----------------------------

FM_POOL_QUOTA_SH="$TMP/absent-adapter.sh"
export FM_POOL_QUOTA_SH
run_preflight --pool
expect_code 2 "$RUN_CODE" "an absent pool adapter is refused"
assert_not_contains "$RUN_OUT" 'decision: go' "an absent adapter never yields go"
export FM_POOL_QUOTA_SH="$BIN/fm-pool-quota.sh"
pass "an absent pool adapter is refused rather than admitted"

# --- backward compatibility: no configuration is required --------------------
#
# Absent FM_POOL_PREFLIGHT_* configuration must still work off the defaults.
unset FM_POOL_PREFLIGHT_FLOOR
export FM_FAKE_QUOTA_DOC="$TMP/compat.json"
direct_doc "$FM_FAKE_QUOTA_DOC" known 88 false
out=$(PATH="$BIN:$PATH" FM_POOL_PREFLIGHT_BIN=quota-axi "$PREFLIGHT" --direct --json) || fail "default configuration failed"
assert_contains "$out" '"floor":20' "the default floor applies with no configuration"
assert_contains "$out" '"decision":"go"' "the default path still decides"
pass "the check works with no configuration set, using documented defaults"

# --- help works without any environment -------------------------------------

"$PREFLIGHT" --help > "$TMP/help.txt" 2>&1 || fail "--help must exit 0"
assert_grep "admission check" "$TMP/help.txt" "help explains it is an admission check"
assert_grep "binds no account" "$TMP/help.txt" "help states it binds no account"
pass "help is available and states the admission-not-reservation contract"

printf '\nall fm-pool-preflight tests passed\n'
