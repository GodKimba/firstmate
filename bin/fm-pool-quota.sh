#!/usr/bin/env bash
# fm-pool-quota.sh - read-only quota and health view for the local CLIProxyAPI
# subscription pool.
#
# This script is a thin ADAPTER, not a second quota implementation. It discovers
# the pool's OAuth account files generically, presents each enabled account to
# `quota-axi` one at a time, and projects the normalized answers into one view.
# Provider quota semantics - window kinds, percentages, effective availability,
# and reset timing - stay owned by quota-axi; this script never recomputes them.
#
# It never contacts the local CLIProxyAPI service, never needs its Management
# API, never writes to the pool directory, and never changes dispatch, account
# selection, or routing. It only reads.
#
# Account discovery is generic: every `*.json` directory entry is a candidate,
# and each file's own `type` field selects the provider. No
# identity, account count, or file name is assumed.
#
# Credential files are treated as hostile input. Every candidate must be a
# regular file (symlinks and non-regular entries are refused), must be non-empty
# and within FM_POOL_QUOTA_MAX_BYTES, must parse as a JSON object, and must carry
# a boolean `disabled`, a supported `type`, and a non-empty string
# `access_token`. Anything else is refused with a reason and a masked file label
# instead of being read further.
#
# Secret handling contract:
#   - Tokens move file-to-file through jq and never enter argv, an environment
#     variable, a shell variable, stdout, stderr, the panel, or any log.
#   - Each account is measured inside its own mode-0700 private temp directory
#     under one mode-0700 private root, removed deterministically on every exit
#     path including interrupt.
#   - quota-axi runs with a scrubbed environment and a private HOME, TMPDIR, and
#     XDG_CACHE_HOME, so the operator's real credential stores and the shared
#     quota cache are neither read nor written.
#   - Codex CLI fallback is pinned to a nonexistent absolute path so a pool
#     account can never be silently measured against an ambient direct login.
#   - quota-axi's own account block is dropped, and every surviving string is
#     scrubbed of the private root path, so no path or identity escapes.
#   - Account identity is always masked: two leading characters of the local
#     part, two of the domain, the public suffix, and a short digest for
#     disambiguation. A full address is never printed or written.
#
# Output: TOON by default, `--json` for the identical model as JSON. The default
# projection is the concise provider-level view; `--accounts` reveals the masked
# per-account and per-window rows, and `omitted` always discloses what was
# dropped. By default, every run also regenerates a self-contained local HTML
# panel with the complete detail from that same fresh read. Programmatic callers
# can pass `--no-panel` to skip that durable artifact.
#
# The panel is deliberately self-contained with inline CSS and zero external
# requests: this artifact renders subscription health next to credential-derived
# state, so it must not pull third-party script or style at view time and must
# never be published or shared.
#
# GitHub stays out of scope: `gh-axi` already owns the GitHub dashboard.
#
# Usage:
#   fm-pool-quota.sh                      concise provider view plus panel, TOON
#   fm-pool-quota.sh --json               the same model as JSON
#   fm-pool-quota.sh --accounts           also reveal masked account/window rows
#   fm-pool-quota.sh --panel              explicitly request the default panel
#   fm-pool-quota.sh --no-panel           do not create or replace the panel
#   fm-pool-quota.sh --help               print this usage
#
# Environment:
#   FM_POOL_QUOTA_DIR        pool account directory (default ~/.cli-proxy-api)
#   FM_POOL_QUOTA_MAX_BYTES  per-file size bound in bytes (default 65536)
#   FM_POOL_QUOTA_TIMEOUT    seconds allowed per account read (default 25)
#   FM_POOL_QUOTA_NOW        pin "now" to an epoch for deterministic output
#   FM_POOL_QUOTA_BIN        quota-axi command name (default quota-axi)
#
# Output contract: `fm-pool-quota.v1`. Pool and routing read-only; no locks.
set -u
export LC_ALL=C

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"

POOL_DIR=${FM_POOL_QUOTA_DIR:-$HOME/.cli-proxy-api}
MAX_BYTES=${FM_POOL_QUOTA_MAX_BYTES:-65536}
READ_TIMEOUT=${FM_POOL_QUOTA_TIMEOUT:-25}
QUOTA_BIN=${FM_POOL_QUOTA_BIN:-quota-axi}
PANEL_DIR="$FM_HOME/.lavish"
PANEL_PATH="$PANEL_DIR/pool-quota.html"

usage() {
  awk '
    NR == 1 { next }
    /^#/ { sub(/^# ?/, ""); print; next }
    { exit }
  ' "$0"
}

die() { printf 'fm-pool-quota: %s\n' "$1" >&2; exit 2; }

validate_bound() {  # <name> <value>
  case "$2" in ''|*[!0-9]*|0) die "$1 must be a positive integer" ;; esac
}
validate_bound FM_POOL_QUOTA_MAX_BYTES "$MAX_BYTES"
validate_bound FM_POOL_QUOTA_TIMEOUT "$READ_TIMEOUT"

FORMAT=toon
SHOW_ACCOUNTS=0
WRITE_PANEL=1
while [ $# -gt 0 ]; do
  case "$1" in
    --json) FORMAT=json ;;
    --accounts) SHOW_ACCOUNTS=1 ;;
    --panel) WRITE_PANEL=1 ;;
    --no-panel) WRITE_PANEL=0 ;;
    -h|--help) usage; exit 0 ;;
    *) die "unknown argument '$1' (see --help)" ;;
  esac
  shift
done

command -v jq >/dev/null 2>&1 || die "jq is required"
[ "$WRITE_PANEL" -eq 0 ] || command -v node >/dev/null 2>&1 || die "node is required"
command -v "$QUOTA_BIN" >/dev/null 2>&1 || die "$QUOTA_BIN is required (it owns provider quota semantics)"

NOW=${FM_POOL_QUOTA_NOW:-$(date -u +%s)}
case "$NOW" in ''|*[!0-9]*) die "FM_POOL_QUOTA_NOW must be an epoch integer" ;; esac
GENERATED=$(date -u -r "$NOW" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null \
  || date -u -d "@$NOW" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null) \
  || die "cannot render the generated timestamp"

# --- private workspace -------------------------------------------------------
# One mode-0700 root holds every per-account shim. It is removed on every exit
# path, including interrupt, so credential copies never outlive the read.
umask 077
PRIVATE_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/fm-pool-quota.XXXXXX") || die "cannot create a private workspace"
chmod 700 "$PRIVATE_ROOT" 2>/dev/null || true
PANEL_TMP=
cleanup_private() {
  [ -z "${PANEL_TMP:-}" ] || rm -f "$PANEL_TMP"
  [ -z "${PRIVATE_ROOT:-}" ] || rm -rf "$PRIVATE_ROOT"
}
trap 'cleanup_private' EXIT
trap 'cleanup_private; exit 130' INT
trap 'cleanup_private; exit 143' TERM
trap 'cleanup_private; exit 129' HUP

RECORDS="$PRIVATE_ROOT/records.ndjson"
: > "$RECORDS"

sha_short() {  # <text> -> 6 hex chars; the text never reaches argv
  local out
  if command -v shasum >/dev/null 2>&1; then
    out=$(printf '%s' "$1" | shasum -a 256 2>/dev/null | awk '{print substr($1,1,6)}')
  elif command -v sha256sum >/dev/null 2>&1; then
    out=$(printf '%s' "$1" | sha256sum 2>/dev/null | awk '{print substr($1,1,6)}')
  fi
  printf '%s' "${out:-000000}"
}

# Mask an account identity down to a stable, non-reversible-at-a-glance label.
mask_identity() {  # <email-or-empty> <fallback-seed>
  local raw=$1 seed=$2 digest local_part domain head tail
  if [ -n "$raw" ]; then
    digest=$(sha_short "$raw")
  else
    digest=$(sha_short "$seed")
    printf 'account-%s' "$digest"
    return 0
  fi
  case "$raw" in
    *@*) local_part=${raw%%@*}; domain=${raw#*@} ;;
    *)   local_part=$raw; domain= ;;
  esac
  head=$(printf '%.2s' "$local_part")
  if [ -z "$domain" ]; then
    printf '%s***#%s' "$head" "$digest"
    return 0
  fi
  case "$domain" in
    *.*) tail=".${domain##*.}" ;;
    *)   tail= ;;
  esac
  printf '%s***@%s***%s#%s' "$head" "$(printf '%.2s' "${domain%%.*}")" "$tail" "$digest"
}

# Mask a pool file name; pool files are named after the account they hold.
mask_file() {  # <basename>
  printf '%s***.json#%s' "$(printf '%.2s' "$1")" "$(sha_short "$1")"
}

emit_record() { printf '%s\n' "$1" >> "$RECORDS"; }

refuse() {  # <masked-file> <reason>
  emit_record "$(jq -nc --arg f "$1" --arg r "$2" '{kind:"refused", file:$f, reason:$r}')"
}

# Bounded quota-axi call with a scrubbed environment. Only file paths are passed.
quota_bounded() {  # <workdir> <provider>
  local w=$1 provider=$2
  local -a env_args
  env_args=(HOME="$w/home" TMPDIR="$w/tmp" XDG_CACHE_HOME="$w/cache" PATH="$PATH")
  case "$provider" in
    claude) env_args+=(CLAUDE_CONFIG_DIR="$w/claude") ;;
    codex)  env_args+=(CODEX_HOME="$w/codex" QUOTA_AXI_CODEX_BINARY="$w/absent-codex-cli") ;;
  esac
  if command -v timeout >/dev/null 2>&1; then
    timeout "$READ_TIMEOUT" env -i "${env_args[@]}" "$QUOTA_BIN" --provider "$provider" --json
  elif command -v gtimeout >/dev/null 2>&1; then
    gtimeout "$READ_TIMEOUT" env -i "${env_args[@]}" "$QUOTA_BIN" --provider "$provider" --json
  else
    env -i "${env_args[@]}" "$QUOTA_BIN" --provider "$provider" --json
  fi
}

# --- discovery and per-account read -----------------------------------------
DISCOVERED=0
ENABLED=0
POOL_STATE=ok
if [ ! -d "$POOL_DIR" ]; then
  POOL_STATE=missing
fi

if [ "$POOL_STATE" = ok ]; then
  for candidate in "$POOL_DIR"/*.json; do
    [ -e "$candidate" ] || [ -L "$candidate" ] || continue
    DISCOVERED=$((DISCOVERED + 1))
    base=${candidate##*/}
    label=$(mask_file "$base")

    if [ -L "$candidate" ]; then
      refuse "$label" "symlink refused"
      continue
    fi
    if [ ! -f "$candidate" ]; then
      refuse "$label" "not a regular file"
      continue
    fi
    if [ ! -r "$candidate" ]; then
      refuse "$label" "unreadable"
      continue
    fi
    size=$(wc -c < "$candidate" 2>/dev/null | tr -d ' ')
    case "$size" in ''|*[!0-9]*) refuse "$label" "unmeasurable size"; continue ;; esac
    if [ "$size" -eq 0 ]; then
      refuse "$label" "empty file"
      continue
    fi
    if [ "$size" -gt "$MAX_BYTES" ]; then
      refuse "$label" "over the ${MAX_BYTES}-byte bound"
      continue
    fi

    shape=$(jq -r '
      if type != "object" then "not-an-object"
      elif (has("disabled") | not) or (.disabled | type) != "boolean" then "bad-disabled"
      elif .disabled == true then "disabled"
      elif (.type | type) != "string" or (.type | length) == 0 then "missing-type"
      elif (.type != "claude" and .type != "codex") then "unsupported-type"
      elif (.access_token | type) != "string" or (.access_token | length) == 0 then "missing-token"
      elif (.expired // "" | type) != "string" then "bad-expiry"
      else "ok:" + .type
      end
    ' "$candidate" 2>/dev/null) || shape=malformed
    [ -n "$shape" ] || shape=malformed

    case "$shape" in
      malformed)        refuse "$label" "not valid JSON"; continue ;;
      not-an-object)    refuse "$label" "not a JSON object"; continue ;;
      bad-disabled)     refuse "$label" "malformed disabled flag"; continue ;;
      missing-type)     refuse "$label" "no account type"; continue ;;
      unsupported-type) refuse "$label" "unsupported account type"; continue ;;
      missing-token)    refuse "$label" "no usable credential"; continue ;;
      bad-expiry)       refuse "$label" "malformed expiry"; continue ;;
      disabled)
        emit_record "$(jq -nc --arg f "$label" '{kind:"skipped", file:$f, reason:"disabled in the pool"}')"
        continue
        ;;
    esac
    provider=${shape#ok:}
    ENABLED=$((ENABLED + 1))

    email=$(jq -r '.email // "" | if type == "string" then . else "" end' "$candidate" 2>/dev/null) || email=
    account=$(mask_identity "$email" "$base")
    email=

    work="$PRIVATE_ROOT/acct-$ENABLED"
    mkdir -p "$work/home" "$work/tmp" "$work/cache" "$work/$provider" || die "cannot prepare the private workspace"
    chmod 700 "$work" "$work/home" "$work/tmp" "$work/cache" "$work/$provider" 2>/dev/null || true

    shim_ok=1
    case "$provider" in
      claude)
        jq '{claudeAiOauth: {accessToken: .access_token, expiresAt: .expired}}' \
          "$candidate" > "$work/claude/.credentials.json" 2>/dev/null || shim_ok=0
        ;;
      codex)
        # id_token is deliberately omitted: quota-axi treats an expired id_token
        # as an expired credential, and pool accounts routinely carry one while
        # their access token is still current.
        jq '{tokens: ({access_token: .access_token}
              + (if (.account_id | type) == "string" and (.account_id | length) > 0
                 then {account_id: .account_id} else {} end))}' \
          "$candidate" > "$work/codex/auth.json" 2>/dev/null || shim_ok=0
        ;;
    esac
    if [ "$shim_ok" -ne 1 ]; then
      rm -rf "$work"
      refuse "$label" "credential could not be prepared"
      continue
    fi
    chmod 600 "$work/$provider"/* 2>/dev/null || true

    raw="$work/out.json"
    rc=0
    quota_bounded "$work" "$provider" > "$raw" 2>"$work/err" || rc=$?

    record=$(jq -nc \
      --slurpfile got "$raw" \
      --arg account "$account" \
      --arg provider "$provider" \
      --arg root "$PRIVATE_ROOT" \
      --arg rc "$rc" '
      def scrub: walk(if type == "string" then (split($root) | join("<private>")) else . end);
      ($got[0] // null) as $doc
      | ($doc.providers // [] | map(select(.provider == $provider)) | .[0] // null) as $p
      | ($p | if . == null then null else (del(.account) | scrub) end) as $q
      | if $q == null then
          {kind:"account", account:$account, provider:$provider,
           status:(if $rc == "124" then "timed_out" else "unavailable" end),
           source:"none", plan:"", stale:true,
           detail:(if $rc == "124" then "the quota read timed out" else "no quota answer for this account" end),
           quota_status:"unknown", effective_remaining:null, bounded_by:"", windows:[]}
        else
          ($q.quotaSemantics.effectiveAvailability // []
           | map(select(.scope == "all_models"))
           | .[0] // null) as $availability
          |
          {kind:"account", account:$account, provider:$provider,
           status:($q.state.status // "unavailable"),
           source:($q.source // "none"),
           plan:($q.plan // ""),
           stale:($q.state.stale // false),
           detail:(($q.state.error // "") | .[0:180]),
           quota_status:($availability.status // "unknown"),
           effective_remaining:(
             if $availability.status == "known"
                and ($availability.effectivePercentRemaining | type) == "number"
             then $availability.effectivePercentRemaining
             else null
             end),
           bounded_by:(
             $availability.limitingWindowIds // [] | join(", ")),
           windows:(
             $q.windows // []
             | map({id:(.id // ""), label:(.label // ""), kind:(.kind // "unknown"),
                    percent_remaining:(if (.percentRemaining | type) == "number"
                                       then .percentRemaining else null end),
                    resets_at:(.resetsAt // ""), reset_text:(.resetText // "")}))}
        end
    ' 2>/dev/null)
    if [ -z "$record" ]; then
      record=$(jq -nc --arg account "$account" --arg provider "$provider" '
        {kind:"account", account:$account, provider:$provider, status:"error",
         source:"none", plan:"", stale:true, detail:"the quota answer could not be read",
         quota_status:"unknown", effective_remaining:null, bounded_by:"", windows:[]}')
    fi
    emit_record "$record"
    rm -rf "$work"
  done
fi

# --- model assembly ----------------------------------------------------------
DISPLAY_DIR=$POOL_DIR
case "$DISPLAY_DIR" in "$HOME"/*) DISPLAY_DIR="~${DISPLAY_DIR#"$HOME"}" ;; esac

MODEL=$(jq -sc \
  --arg generated "$GENERATED" \
  --arg dir "$DISPLAY_DIR" \
  --arg pool_state "$POOL_STATE" \
  --argjson discovered "$DISCOVERED" \
  --argjson enabled "$ENABLED" \
  '
  def usable: (.status == "fresh" or .status == "stale");

  (map(select(.kind == "account"))
   | sort_by(.provider, .account)) as $accounts
  | (map(select(.kind == "refused")) | sort_by(.file)) as $refused
  | (map(select(.kind == "skipped")) | sort_by(.file)) as $skipped
  | ($accounts | map(.provider) | unique) as $provider_ids
  | ($provider_ids | map(. as $p
      | ($accounts | map(select(.provider == $p))) as $rows
      | ($rows | map(select(usable and (.effective_remaining != null)))) as $known
      | ($rows | map(select(usable)) | map(.quota_status) | unique) as $semantic_statuses
      | ($known | max_by(.effective_remaining)) as $best
      | ($rows | map(.windows[]) | map(select(.resets_at != ""))
         | sort_by(.resets_at) | .[0] // null) as $soonest
      | {provider: $p,
         accounts: ($rows | length),
         ok: ($rows | map(select(.status == "fresh")) | length),
         degraded: ($rows | map(select(.status == "stale" or .status == "rate_limited")) | length),
         unavailable: ($rows | map(select(.status != "fresh" and .status != "stale" and .status != "rate_limited")) | length),
         quota_status: (if ($semantic_statuses | length) == 1
                        then $semantic_statuses[0]
                        elif ($semantic_statuses | length) == 0 then "unknown"
                        else "mixed" end),
         best_remaining: ($best.effective_remaining // null),
         best_account: ($best.account // ""),
         best_bounded_by: ($best.bounded_by // ""),
         worst_remaining: (($known | min_by(.effective_remaining)).effective_remaining // null),
         soonest_reset: ($soonest.resets_at // ""),
         soonest_reset_in: ($soonest.reset_text // ""),
         health: (if ($rows | map(select(.status == "fresh")) | length) == 0 then "down"
                  elif ($rows | map(select(.status != "fresh")) | length) > 0 then "partial"
                  elif ($semantic_statuses | all(.[]; . == "known")) then "healthy"
                  elif ($semantic_statuses | length) == 1 then $semantic_statuses[0]
                  else "partial" end)})) as $providers
  | {schema: "fm-pool-quota.v1",
     generated: $generated,
     pool_dir: $dir,
     pool_state: $pool_state,
     accounts_discovered: $discovered,
     accounts_enabled: $enabled,
     accounts_answered: ($accounts | map(select(usable)) | length),
     accounts_refused: ($refused | length),
     accounts_skipped: ($skipped | length),
     comparability: "Percentages are per provider. Claude and Codex windows measure different things, so they are never added, averaged, or ranked against each other.",
     github: "GitHub dashboards stay with gh-axi; this view is subscription quota only.",
     providers: $providers,
     accounts: $accounts | map(del(.kind, .windows)),
     windows: ($accounts | map(. as $a | .windows[] | {account: $a.account, provider: $a.provider,
                window: .id, label: .label, kind: .kind,
                percent_remaining: .percent_remaining, resets_at: .resets_at, resets_in: .reset_text})),
     refused: $refused | map(del(.kind)),
     skipped: $skipped | map(del(.kind))}
' "$RECORDS") || die "cannot assemble the pool model"

# --- local panel -------------------------------------------------------------
render_panel() {
  local out=$PANEL_PATH tmp
  if [ -L "$PANEL_DIR" ]; then
    die "panel directory must not be a symlink"
  fi
  if [ -e "$PANEL_DIR" ] && [ ! -d "$PANEL_DIR" ]; then
    die "panel directory is not a directory"
  fi
  mkdir -p "$PANEL_DIR" || die "cannot create the panel directory"
  if [ -L "$PANEL_DIR" ] || [ ! -d "$PANEL_DIR" ]; then
    die "panel directory is not a private local directory"
  fi
  chmod 700 "$PANEL_DIR" 2>/dev/null || die "cannot make the panel directory private"
  PANEL_TMP=$(mktemp "$PANEL_DIR/.pool-quota.XXXXXX") || die "cannot create a private panel artifact"
  tmp=$PANEL_TMP
  chmod 600 "$tmp" 2>/dev/null || die "cannot make the panel artifact private"
  {
    cat <<'HTML_HEAD'
<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<meta name="robots" content="noindex, nofollow">
<title>Subscription pool quota</title>
<style>
  :root { color-scheme: dark; --bg:#10131a; --card:#171b24; --line:#252b38; --ink:#e6e9f0;
          --muted:#98a2b8; --ok:#4ade80; --warn:#fbbf24; --bad:#f87171; --accent:#7dd3fc; }
  *, *::before, *::after { box-sizing: border-box; }
  body { margin:0; padding:32px 24px 56px; background:var(--bg); color:var(--ink);
         font:15px/1.55 -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, Helvetica, Arial, sans-serif; }
  main { max-width:1080px; margin:0 auto; }
  h1 { font-size:26px; margin:0 0 6px; letter-spacing:-0.01em; }
  h2 { font-size:17px; margin:34px 0 12px; letter-spacing:-0.005em; }
  p { margin:0 0 10px; }
  .sub { color:var(--muted); font-size:13px; margin-bottom:22px; }
  .grid { display:grid; grid-template-columns:repeat(auto-fit, minmax(240px, 1fr)); gap:14px; }
  .card { background:var(--card); border:1px solid var(--line); border-radius:12px; padding:16px 18px; min-width:0; }
  .card h3 { margin:0 0 10px; font-size:15px; text-transform:capitalize; }
  .metric { font-size:30px; font-weight:600; letter-spacing:-0.02em; }
  .metric span { font-size:14px; font-weight:400; color:var(--muted); margin-left:6px; }
  .kv { display:flex; justify-content:space-between; gap:12px; font-size:13px; color:var(--muted);
        padding:3px 0; border-top:1px solid var(--line); margin-top:8px; }
  .kv:first-of-type { border-top:0; margin-top:10px; }
  .kv b { color:var(--ink); font-weight:500; text-align:right; overflow-wrap:anywhere; }
  table { width:100%; border-collapse:collapse; font-size:13px; }
  th, td { text-align:left; padding:8px 10px; border-bottom:1px solid var(--line); vertical-align:top;
           overflow-wrap:anywhere; }
  th { color:var(--muted); font-weight:500; font-size:12px; text-transform:uppercase; letter-spacing:0.04em; }
  td.num { text-align:right; font-variant-numeric:tabular-nums; }
  .wrap { background:var(--card); border:1px solid var(--line); border-radius:12px; overflow-x:auto; }
  .tag { display:inline-block; padding:1px 8px; border-radius:999px; font-size:12px; border:1px solid var(--line); }
  .t-healthy, .t-fresh, .t-known { color:var(--ok); border-color:rgba(74,222,128,.35); }
  .t-partial, .t-stale, .t-rate_limited, .t-unknown, .t-mixed { color:var(--warn); border-color:rgba(251,191,36,.35); }
  .t-down, .t-unavailable, .t-error, .t-auth_required, .t-timed_out { color:var(--bad); border-color:rgba(248,113,113,.35); }
  .note { color:var(--muted); font-size:13px; }
  .bar { height:6px; border-radius:999px; background:#222836; overflow:hidden; margin-top:8px; }
  .bar i { display:block; height:100%; background:var(--accent); }
  footer { margin-top:40px; color:var(--muted); font-size:12px; border-top:1px solid var(--line); padding-top:16px; }
  footer p { margin:0 0 6px; }
</style>
</head>
<body>
<main>
HTML_HEAD
    printf '%s' "$MODEL" | jq -r '
      def esc: tostring | @html;
      def pct: if . == null then "unknown" else "\(.)%" end;
      def dash: if . == null or . == "" then "-" else (. | esc) end;
      [
        "<h1>Subscription pool quota</h1>",
        "<p class=\"sub\">Fresh read of \(.pool_dir | esc) at \(.generated | esc). Display only - nothing here changes dispatch, account selection, or routing.</p>",
        (if .pool_state != "ok" then
           "<p class=\"note\">The pool directory was not found, so no accounts could be read.</p>"
         else empty end),
        "<h2>Pool summary</h2>",
        "<div class=\"grid\">",
        "<div class=\"card\"><h3>Accounts</h3><div class=\"metric\">\(.accounts_enabled)<span>enabled of \(.accounts_discovered) found</span></div>",
        "<div class=\"kv\"><span>Answered</span><b>\(.accounts_answered)</b></div>",
        "<div class=\"kv\"><span>Refused as unsafe</span><b>\(.accounts_refused)</b></div>",
        "<div class=\"kv\"><span>Skipped</span><b>\(.accounts_skipped)</b></div></div>",
        (.providers[] |
          "<div class=\"card\"><h3>\(.provider | esc)</h3>"
          + "<div class=\"metric\">\(.best_remaining | pct)<span>best account left</span></div>"
          + (if .best_remaining == null then "" else "<div class=\"bar\"><i style=\"width:\(.best_remaining)%\"></i></div>" end)
          + "<div class=\"kv\"><span>Health</span><b><span class=\"tag t-\(.health)\">\(.health | esc)</span></b></div>"
          + "<div class=\"kv\"><span>Quota status</span><b><span class=\"tag t-\(.quota_status)\">\(.quota_status | esc)</span></b></div>"
          + "<div class=\"kv\"><span>Accounts responding</span><b>\(.ok) of \(.accounts)</b></div>"
          + "<div class=\"kv\"><span>Most constrained account</span><b>\(.worst_remaining | pct)</b></div>"
          + "<div class=\"kv\"><span>Bounded by</span><b>\(.best_bounded_by | dash)</b></div>"
          + "<div class=\"kv\"><span>Next window reset</span><b>\(.soonest_reset_in | dash)</b></div></div>"),
        "</div>",
        "<h2>Accounts</h2>",
        (if (.accounts | length) == 0 then "<p class=\"note\">No enabled account could be measured.</p>"
         else
          "<div class=\"wrap\"><table><thead><tr><th>Account</th><th>Provider</th><th>State</th><th>Quota status</th><th>Plan</th><th class=\"num\">Effective left</th><th>Bounded by</th><th>Detail</th></tr></thead><tbody>"
          + ([.accounts[] |
              "<tr><td>\(.account | esc)</td><td>\(.provider | esc)</td>"
              + "<td><span class=\"tag t-\(.status)\">\(.status | esc)</span>\(if .stale then " <span class=\"note\">stale</span>" else "" end)</td>"
              + "<td><span class=\"tag t-\(.quota_status)\">\(.quota_status | esc)</span></td>"
              + "<td>\(.plan | dash)</td><td class=\"num\">\(.effective_remaining | pct)</td>"
              + "<td>\(.bounded_by | dash)</td><td class=\"note\">\(.detail | dash)</td></tr>"] | join(""))
          + "</tbody></table></div>"
         end),
        "<h2>Windows</h2>",
        (if (.windows | length) == 0 then "<p class=\"note\">No provider window was reported.</p>"
         else
          "<div class=\"wrap\"><table><thead><tr><th>Account</th><th>Window</th><th>Kind</th><th class=\"num\">Remaining</th><th>Resets at</th><th>Resets in</th></tr></thead><tbody>"
          + ([.windows[] |
              "<tr><td>\(.account | esc)</td><td>\(.label | dash) <span class=\"note\">\(.window | esc)</span></td>"
              + "<td>\(.kind | esc)</td><td class=\"num\">\(.percent_remaining | pct)</td>"
              + "<td class=\"note\">\(.resets_at | dash)</td><td>\(.resets_in | dash)</td></tr>"] | join(""))
          + "</tbody></table></div>"
         end),
        (if ((.refused | length) + (.skipped | length)) == 0 then empty
         else
          "<h2>Not measured</h2><div class=\"wrap\"><table><thead><tr><th>File</th><th>Why</th></tr></thead><tbody>"
          + ([(.refused[] | {file, reason, why:"refused"}), (.skipped[] | {file, reason, why:"skipped"})]
             | map("<tr><td>\(.file | esc)</td><td>\(.why | esc): \(.reason | esc)</td></tr>") | join(""))
          + "</tbody></table></div>"
         end),
        "<footer>",
        "<p>\(.comparability | esc)</p>",
        "<p>\(.github | esc)</p>",
        "<p>This panel is rebuilt from a fresh read every time it is generated, stays on this machine, and holds no credential or full account address. Do not publish or share it.</p>",
        "</footer>"
      ] | join("\n")
    ' || die "cannot render the panel"
    cat <<'HTML_TAIL'
</main>
</body>
</html>
HTML_TAIL
  } > "$tmp" || die "cannot write the panel"
  node -e 'require("node:fs").renameSync(process.argv[1], process.argv[2])' \
    "$tmp" "$out" 2>/dev/null || die "cannot install the panel at $out"
  PANEL_TMP=
  [ -f "$out" ] && [ ! -L "$out" ] || die "the installed panel is not a regular file"
}

if [ "$WRITE_PANEL" -eq 1 ]; then
  render_panel
  MODEL=$(printf '%s' "$MODEL" | jq -c --arg p "$PANEL_PATH" '. + {panel: $p}') \
    || die "cannot record the panel path"
fi

if [ "$SHOW_ACCOUNTS" -eq 1 ]; then
  PRINTED=$(printf '%s' "$MODEL" | jq -c '. + {omitted: []}')
else
  PRINTED=$(printf '%s' "$MODEL" | jq -c '
    . as $m
    | del(.accounts, .windows)
    | . + {omitted: [{surface: "masked per-account and per-window rows",
                      reveal: (if ($m.accounts | length) == 0 then "--accounts (no rows to reveal)" else "--accounts" end)}]}')
fi
[ -n "$PRINTED" ] || die "cannot project the pool model"

if [ "$FORMAT" = json ]; then
  printf '%s\n' "$PRINTED"
  exit 0
fi

# --- TOON renderer (output boundary; parity with the JSON model) ------------
TOON=$(printf '%s\n' "$PRINTED" | jq -r '
  def q:
    tostring
    | if (. == "")
        or test("^\\s|\\s$")
        or (. == "true" or . == "false" or . == "null")
        or test("^-?[0-9]+(\\.[0-9]+)?([eE][+-]?[0-9]+)?$")
        or test("[:\"\\\\\\[\\]{},]")
        or test("[[:cntrl:]]")
        or test("^-")
      then "\"" + (gsub("\\\\"; "\\\\") | gsub("\""; "\\\"") | gsub("\n"; "\\n") | gsub("\r"; "\\r") | gsub("\t"; "\\t")) + "\""
      else . end;
  def scal:
    if . == null then "null"
    elif type == "boolean" then (if . then "true" else "false" end)
    elif type == "number" then tostring
    else q end;
  def emit($k; $v):
    if ($v | type) == "array" then
      if ($v | length) == 0 then "\($k): []"
      else
        ($v[0] | keys_unsorted) as $ks
        | ( "\($k)[\($v | length)]{\($ks | map(q) | join(","))}:",
            ($v[] as $row | "  " + ([ $ks[] as $kk | ($row[$kk] | scal) ] | join(","))) )
      end
    else "\($k): " + ($v | scal)
    end;
  [ to_entries[] | emit(.key; .value) ] | join("\n")
') || die "TOON rendering failed"
printf '%s\n' "$TOON"
