#!/usr/bin/env bash
# fm-pool-preflight.sh - decide whether a long validation run may START on the
# capacity that will actually serve it.
#
# WHY THIS IS AN ADMISSION CHECK AND NOT A SELECTOR
#
# The local CLIProxyAPI already owns account selection: its `routing.strategy`
# (round-robin or fill-first), `routing.session-affinity`, and its post-failure
# cooldown subsystem choose the account, and failover is always on. It exposes
# NO per-request account-pin interface - the only client-controllable routing
# inputs are session-affinity keys, which bind related requests to each other
# rather than naming an account. The Management API that could enumerate or
# steer accounts is disabled and must stay disabled.
#
# So firstmate cannot make an account choice take effect, and a second selector
# here would race the proxy's own rather than extend it. What firstmate CAN do
# is refuse to begin a long, expensive validation when the capacity that will
# serve it is already too tight to finish, which needs only measurement.
# docs/verification/pool-account-routing.md owns that evidence in full.
#
# CONSEQUENCE FOR CALLERS: a `go` result is not a reservation.
# This is an admission check and it binds no account.
# It cannot promise the account that answers is the one that was measured; it is
# a start-line judgement about available headroom, nothing more. The output says
# so in `binds_account`, which is always false.
#
# MODES, because the two paths have genuinely different capacity:
#   --direct  measure the ambient direct login
#   --pool    measure the pooled accounts through bin/fm-pool-quota.sh
# `--pool` reports the pool's BEST account, because the proxy routes to a healthy
# account and fails over, so the best account is the honest upper bound on what a
# run can expect. It is a bound, not a binding.
#
# WHICH MODE MATCHES A no-mistakes VALIDATION: `--pool`, because the machine-wide
# Codex agent now runs through the CLIProxyAPI pool profile rather than one
# ambient direct account. `--direct` still measures that ambient login, which
# serves whatever has not been pool-routed.
# docs/verification/pool-account-routing.md records that cutover and its proof.
#
# DECISION
#
#   go       headroom at or above the floor; a long run may start
#   hold     headroom below the floor; starting risks exhausting mid-run
#   unknown  quota could not be established - reported, never guessed
#
# `unknown` is deliberately NOT `go`. A run that starts blind on an exhausted
# account is the exact failure this script exists to prevent, so an unreadable
# quota is surfaced for a decision instead of being optimistically waved through.
# It is also not `hold`: the caller may still choose to proceed knowingly.
#
# ALL-TIGHT BEHAVIOUR: when every candidate is below the floor this reports
# `hold` with the best observed headroom attached. It never silently downgrades a
# requested strongest-reasoning model to a weaker one to conserve quota; that
# trade belongs to the captain, so the tight state is reported instead.
#
# QUOTA SEMANTICS stay owned by quota-axi. This script compares an already
# normalized effective-percent-remaining against a floor and performs no quota
# arithmetic of its own.
#
# MODEL SCOPE is reported rather than assumed, because a model window can be
# tighter than the all-models window and quoting the looser number would be the
# guess this check exists to avoid. `scope_kind` states which bound was used:
#   model               the named model's own window was found and used
#   all_models          no model was named; the all-models window was used
#   all_models_fallback a model was named but the report does not scope it, so
#                       the all-models bound was used and this says so - note
#                       that quota-axi scopes by provider-internal model ids
#                       (`model:codex_bengalfox`), not by the id configured for
#                       a Codex profile, so a configured name usually lands here
#                       rather than matching
#   all_models_only     pool mode, where the per-account view exposes only the
#                       all-models bound
# The fallback is a disclosed coarser bound, never an invented number.
#
# SECRETS: no credential is read, printed, or passed. --direct shells out to
# quota-axi, which reads the ambient login itself; --pool delegates to
# fm-pool-quota.sh, which owns the private-workspace and masking contract. Only
# masked account labels ever appear in output.
#
# NOT A ROUTING CHANGE: this script writes nothing, locks nothing, and mutates no
# configuration. It cannot alter live pool routing.
#
# Usage:
#   fm-pool-preflight.sh --direct [--model <id>] [--floor <pct>] [--json]
#   fm-pool-preflight.sh --pool   [--model <id>] [--floor <pct>] [--json]
#   fm-pool-preflight.sh --help
#
# Exit status: 0 go, 3 hold, 4 unknown, 2 usage or environment error.
# The distinct codes let a caller branch without parsing output.
#
# Environment:
#   FM_POOL_PREFLIGHT_FLOOR   default floor percent (default 20)
#   FM_POOL_PREFLIGHT_BIN     quota-axi command name (default quota-axi)
#   FM_POOL_QUOTA_SH          path to fm-pool-quota.sh (default alongside this)
#
# Output contract: `fm-pool-preflight.v1`. Read-only; no locks, no mutation.
set -u
export LC_ALL=C

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

FLOOR=${FM_POOL_PREFLIGHT_FLOOR:-20}
QUOTA_BIN=${FM_POOL_PREFLIGHT_BIN:-quota-axi}
POOL_SH=${FM_POOL_QUOTA_SH:-$SCRIPT_DIR/fm-pool-quota.sh}

usage() {
  awk '
    NR == 1 { next }
    /^#/ { sub(/^# ?/, ""); print; next }
    { exit }
  ' "$0"
}

die() { printf 'fm-pool-preflight: %s\n' "$1" >&2; exit 2; }

MODE=
MODEL=
FORMAT=text
while [ $# -gt 0 ]; do
  case "$1" in
    --direct) [ -z "$MODE" ] || die "choose either --direct or --pool"; MODE=direct ;;
    --pool)   [ -z "$MODE" ] || die "choose either --direct or --pool"; MODE=pool ;;
    --model)  shift; [ $# -gt 0 ] || die "--model needs a model id"; MODEL=$1 ;;
    --floor)  shift; [ $# -gt 0 ] || die "--floor needs a percent"; FLOOR=$1 ;;
    --json)   FORMAT=json ;;
    -h|--help) usage; exit 0 ;;
    *) die "unknown argument '$1' (see --help)" ;;
  esac
  shift
done

[ -n "$MODE" ] || die "choose --direct or --pool (see --help)"
case "$FLOOR" in
  ''|*[!0-9]*) die "--floor must be an integer percent between 0 and 100" ;;
esac
[ "$FLOOR" -le 100 ] || die "--floor must be an integer percent between 0 and 100"

command -v jq >/dev/null 2>&1 || die "jq is required"

# Reduce one quota-axi provider document to the tightest relevant availability.
# Prefers the named model's own window when the report scopes it, because that
# window can be tighter than all_models; otherwise falls back to the all-models
# bound and records which happened in `scope_kind`, so the caller is never handed
# a model-specific number that was not measured.
#
# Emits: {status, remaining, bounded_by, stale, scope_kind}
reduce_availability() {  # <json-doc> <provider> <model-or-empty>
  printf '%s' "$1" | jq -c --arg provider "$2" --arg model "$3" '
    def unknown($scope; $stale):
      {status:"unknown", remaining:null, bounded_by:"", stale:$stale, scope_kind:$scope};
    (.providers // [] | map(select(.provider == $provider)) | .[0]) as $p
    | if $p == null then unknown("all_models"; true)
      else
        ($p.quotaSemantics.effectiveAvailability // []) as $avail
        | (if $model == "" then null
           else ($avail | map(select(.scope == "model:" + $model)) | .[0])
           end) as $scoped
        | ($avail | map(select(.scope == "all_models")) | .[0]) as $all
        | (if $scoped != null then "model"
           elif $model == "" then "all_models"
           else "all_models_fallback" end) as $scope_kind
        | (($scoped // $all)) as $pick
        # Not `// true`: jq treats false as empty, so `false // true` is true and
        # every fresh reading would be reported stale. Test the type instead, and
        # treat a missing or non-boolean flag as stale.
        | (if ($p.state.stale | type) == "boolean" then $p.state.stale
           else true end) as $stale
        | if $pick == null or $pick.status != "known"
             or ($pick.effectivePercentRemaining | type) != "number"
          then unknown($scope_kind; $stale)
          else
            {status:"known",
             remaining:$pick.effectivePercentRemaining,
             bounded_by:(($pick.limitingWindowIds // []) | join(", ")),
             stale:$stale,
             scope_kind:$scope_kind}
          end
      end'
}

CANDIDATES=  # ndjson rows: {account, remaining, status, bounded_by, stale, scope_kind}
NOTE=

unknown_row() {  # <account> <scope-kind>
  jq -nc --arg account "$1" --arg scope "$2" \
    '{account:$account, remaining:null, status:"unknown", bounded_by:"",
      stale:true, scope_kind:$scope}'
}

if [ "$MODE" = direct ]; then
  command -v "$QUOTA_BIN" >/dev/null 2>&1 \
    || die "$QUOTA_BIN is required (it owns provider quota semantics)"
  scope_hint=all_models
  [ -z "$MODEL" ] || scope_hint=all_models_fallback

  raw=$("$QUOTA_BIN" --provider codex --json 2>/dev/null) || raw=
  if [ -z "$raw" ]; then
    CANDIDATES=$(unknown_row "direct login" "$scope_hint")
    NOTE="the direct login did not answer a quota read"
  else
    reduced=$(reduce_availability "$raw" codex "$MODEL" 2>/dev/null) || reduced=
    if [ -z "$reduced" ]; then
      CANDIDATES=$(unknown_row "direct login" "$scope_hint")
      NOTE="the direct login quota answer could not be read"
    else
      CANDIDATES=$(printf '%s' "$reduced" | jq -c '{account:"direct login"} + .')
    fi
  fi
else
  [ -x "$POOL_SH" ] || die "fm-pool-quota.sh is required at $POOL_SH"
  # --accounts reveals the masked per-account rows; identities stay masked. That
  # view carries the all-models bound only, so pool mode cannot honour a model
  # window and says so through scope_kind rather than implying it did.
  pool=$("$POOL_SH" --json --accounts 2>/dev/null) || pool=
  [ -n "$pool" ] || die "the pool quota view did not return a reading"

  # A pooled account counts as measured only when it answered and carries a known
  # effective remaining. Anything else is carried as unknown rather than assumed
  # healthy, so a silent account is never mistaken for a spare one.
  CANDIDATES=$(printf '%s' "$pool" | jq -c '
    (.accounts // [])
    | map(select(.provider == "codex"))
    | map({account,
           remaining:.effective_remaining,
           status:(if .quota_status == "known"
                      and (.effective_remaining | type) == "number"
                   then "known" else "unknown" end),
           bounded_by:(.bounded_by // ""),
           # Type-tested rather than `// true` for the same reason as above, and
           # an absent flag counts as stale rather than fresh.
           stale:(if (.stale | type) == "boolean" then .stale else true end),
           scope_kind:"all_models_only"})
    | .[]') || CANDIDATES=
  [ -n "$CANDIDATES" ] || NOTE="no pooled Codex account could be measured"
fi

# Decide from the candidate set.
#
# Ties: the maximum is taken by value and the winning label is reported only for
# the operator's benefit. Nothing downstream binds to it, so a tie needs no
# ordering rule - there is no account to award. That is a direct consequence of
# the no-pin finding above, not an omission.
DECISION=$(printf '%s\n' "$CANDIDATES" | jq -sc \
  --argjson floor "$FLOOR" --arg note "$NOTE" --arg mode "$MODE" '
  map(select(. != null)) as $rows
  | ($rows | map(select(.status == "known"))) as $known
  | (if ($rows | length) > 0 then $rows[0].scope_kind
     elif $mode == "pool" then "all_models_only"
     else "all_models" end) as $scope_kind
  | if ($known | length) == 0 then
      {decision:"unknown", best:null, best_account:"", bounded_by:"",
       candidates:($rows | length), measured:0, stale:true,
       scope_kind:$scope_kind,
       reason:(if $note == "" then "no candidate reported a usable quota reading"
               else $note end)}
    else
      ($known | max_by(.remaining)) as $best
      | {decision:(if $best.remaining >= $floor then "go" else "hold" end),
         best:$best.remaining,
         best_account:$best.account,
         bounded_by:$best.bounded_by,
         candidates:($rows | length),
         measured:($known | length),
         stale:($known | any(.stale)),
         scope_kind:($best.scope_kind // $scope_kind),
         reason:(if $best.remaining >= $floor
                 then "headroom is at or above the floor"
                 else "every measured candidate is below the floor" end)}
    end') || die "cannot reach a preflight decision"

DECISION=$(printf '%s' "$DECISION" | jq -c \
  --arg mode "$MODE" --arg model "$MODEL" --argjson floor "$FLOOR" \
  '{schema:"fm-pool-preflight.v1", mode:$mode, model:$model, floor:$floor}
   + . + {binds_account:false}') || die "cannot assemble the preflight result"

verdict=$(printf '%s' "$DECISION" | jq -r '.decision')

if [ "$FORMAT" = json ]; then
  printf '%s\n' "$DECISION"
else
  printf '%s' "$DECISION" | jq -r '
    def pct: if . == null then "unknown" else "\(.)%" end;
    def scope_note:
      if . == "model" then "the named model own window"
      elif . == "all_models" then "the all-models window"
      elif . == "all_models_fallback"
      then "the all-models window (the named model is not scoped in this report)"
      else "the all-models window (pool accounts expose no model window)" end;
    "decision: \(.decision)",
    "mode:     \(.mode)\(if .model == "" then "" else " (model \(.model))" end)",
    "headroom: \(.best | pct) against a \(.floor)% floor" +
      (if .best_account == "" then "" else "  [best: \(.best_account)]" end),
    "measured: \(.measured) of \(.candidates) candidate(s)" +
      (if .stale then " (reading is stale)" else "" end),
    "bound:    \(.scope_kind | scope_note)" +
      (if .bounded_by == "" then "" else ", limited by \(.bounded_by)" end),
    "reason:   \(.reason)",
    "note:     this is an admission check, not a reservation; it binds no account"'
fi

case "$verdict" in
  go)      exit 0 ;;
  hold)    exit 3 ;;
  unknown) exit 4 ;;
  *)       exit 2 ;;
esac
