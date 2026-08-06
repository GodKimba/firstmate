#!/usr/bin/env bash
# fm-claude-pool.sh - the supported Claude-on-CLIProxyAPI-pool worker route.
#
# WHAT THIS IS
#
# `claude-pool` is a worker harness adapter: the ordinary `claude` executable
# pointed at the captain's local CLIProxyAPI pool instead of the ambient native
# Claude login. It exists so a worker can spend pooled Claude subscription
# capacity while the native login stays untouched for the primary session.
#
# It is a launch route, not a control plane. This script resolves the route's
# NON-SECRET configuration, proves the requested model is really a Claude model
# the pool serves, and hands the Claude CLI a credential without that credential
# ever entering argv. It selects no account, mutates no proxy state, and holds
# no lock.
#
# WHY IT IS AN ADAPTER AND NOT A SECOND DISPATCH AXIS
#
# `pi-signed` is the precedent: a distinct adapter identity that launches a
# specific executable route and refuses to fall back to its sibling. Firstmate's
# existing harness contracts - config/crew-harness, config/secondmate-harness,
# config/crew-dispatch.json profiles, and `fm-spawn.sh --harness` - already carry
# an adapter name end to end, so `claude-pool` needs no new selection axis, no
# wrapper, and no second dispatch architecture. Selecting the pool route is
# exactly naming this adapter, and naming any other adapter leaves native Claude
# behavior byte-for-byte unchanged.
#
# THE PROXY OWNS ACCOUNT SELECTION
#
# docs/verification/pool-account-routing.md is the owner of that evidence: the
# proxy's own `routing` strategy, session affinity, failover, and cooldown choose
# the account, and no per-request account-pin interface exists. This script
# therefore never names, reserves, pins, or reports an account, and no output it
# produces may be read as binding one worker to one pooled account.
#
# SECRET HANDLING CONTRACT
#
#   - The credential is read from an operator-owned source file that is PARSED,
#     never executed. No shell profile is sourced, so a route launch cannot
#     inherit or run arbitrary interactive shell configuration.
#   - The credential reaches the Claude CLI through its `apiKeyHelper` setting,
#     which invokes `fm-claude-pool.sh secret` and reads stdout. It is therefore
#     never an `env VAR=value` argument, never a launch-command word, never a
#     process-table entry, and never part of any recorded task metadata.
#   - The credential reaches curl through a mode-0600 config file inside a
#     mode-0700 private temp directory removed on every exit path, so it is
#     absent from argv there too.
#   - `check` prints decisions, never the credential, and its diagnostics name
#     the source FILE and VARIABLE, never a value or a fragment of one.
#   - The source file's own contents are never echoed, logged, or copied
#     anywhere; only the single requested variable's value is extracted.
#
# MODEL VALIDATION IS A FAMILY CHECK, NOT A NAME CHECK
#
# The pool serves both Anthropic and OpenAI models on the SAME Anthropic-shaped
# `/v1/messages` endpoint, and it answers 200 for an OpenAI model there. A launch
# that merely reached the pool could therefore be a GPT model wearing the Claude
# CLI, which is the exact failure this route exists to prevent. So `check` reads
# the pool's own `/v1/models` catalog and requires the requested id to be present
# AND to carry `owned_by: anthropic`. The catalog is the authority; no name
# prefix, alias, or local table is consulted.
#
# `/v1/models` refuses an unauthenticated read, so a successful catalog fetch is
# simultaneously the credential check. There is no separate credential probe and
# no request that spends model quota.
#
# NO SILENT FALLBACK
#
# Every failure below is terminal for this route. Nothing here degrades to the
# native Claude login, to Pi, or to another model family: a caller that cannot
# get a `check` pass must surface the refusal, not select around it.
#
# Usage:
#   fm-claude-pool.sh check --model <id> [--json]   validate the route end to end
#   fm-claude-pool.sh secret                        print the credential (apiKeyHelper target)
#   fm-claude-pool.sh base-url                      print the resolved pool base URL
#   fm-claude-pool.sh settings-json                 print the Claude --settings payload
#   fm-claude-pool.sh source                        print "<secret-file>\t<secret-var>"
#   fm-claude-pool.sh --help
#
# `secret`, `settings-json`, and `source` accept explicit `--secret-file <path>`
# and `--secret-var <name>` so a launched worker's helper command is fully
# self-describing and needs no config lookup of its own. Both are paths and
# names, never values.
#
# Exit status:
#   0  ok
#   2  usage or environment error
#   3  the pool did not serve its model catalog (unreachable, or it refused the
#      credential - both are route configuration faults, never a fallback cue)
#   4  the requested model is not in the pool catalog
#   5  the requested model is in the catalog but is not an Anthropic model
#   6  the credential source is missing, unreadable, or does not define the variable
#
# Configuration: config/claude-pool, `key = value` lines, `#` comments.
#   base-url     pool base URL           (default http://127.0.0.1:8317)
#   secret-file  credential source file  (default ~/.config/cliproxy/shell.zsh)
#   secret-var   variable to extract     (default CLIPROXY_API_KEY)
# The file holds only paths, names, and a URL. It must never hold a credential,
# and this script refuses a value that looks like one.
#
# Environment:
#   FM_CLAUDE_POOL_CONFIG       override the config file path
#   FM_CLAUDE_POOL_BASE_URL     override base-url
#   FM_CLAUDE_POOL_SECRET_FILE  override secret-file
#   FM_CLAUDE_POOL_SECRET_VAR   override secret-var
#   FM_CLAUDE_POOL_TIMEOUT      catalog fetch bound in seconds (default 15)
#
# Output contract: `fm-claude-pool.v1`. Pool and routing read-only; no locks.
set -u
set +x  # defensive: never let an inherited trace mode echo credential handling
export LC_ALL=C

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
CONFIG_DIR="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
CONFIG_FILE="${FM_CLAUDE_POOL_CONFIG:-$CONFIG_DIR/claude-pool}"

DEFAULT_BASE_URL='http://127.0.0.1:8317'
DEFAULT_SECRET_FILE="${HOME:-}/.config/cliproxy/shell.zsh"
DEFAULT_SECRET_VAR='CLIPROXY_API_KEY'
FETCH_TIMEOUT=${FM_CLAUDE_POOL_TIMEOUT:-15}

usage() {
  awk '
    NR == 1 { next }
    /^#/ { sub(/^# ?/, ""); print; next }
    { exit }
  ' "$0"
}

die() { printf 'fm-claude-pool: %s\n' "$1" >&2; exit 2; }

# Read one `key = value` setting from config/claude-pool. Absent file, absent
# key, and a comment-only file are all "unset" and defer to the default; they are
# never an error, because the shipped defaults are the captain's real layout.
config_value() {  # <key>
  local key=$1
  [ -f "$CONFIG_FILE" ] || return 0
  awk -v key="$key" '
    /^[[:space:]]*#/ { next }
    {
      line = $0
      sub(/[[:space:]]*#.*$/, "", line)
      eq = index(line, "=")
      if (eq == 0) next
      k = substr(line, 1, eq - 1)
      v = substr(line, eq + 1)
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", k)
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", v)
      if (k == key && v != "") { print v; exit }
    }
  ' "$CONFIG_FILE"
}

# A config file is for paths, names, and a URL only. A long opaque token there
# would be a credential committed to a config surface, so refuse rather than
# quietly accept it.
refuse_secret_shaped() {  # <key> <value>
  case "$2" in
    *[!A-Za-z0-9_.:/~-]*) return 0 ;;
  esac
  if [ "${#2}" -ge 32 ] && [ "${2#*/}" = "$2" ] && [ "${2#*:}" = "$2" ]; then
    die "config/claude-pool '$1' looks like a credential; it must name a source, not hold one"
  fi
}

resolve_setting() {  # <key> <env-override-value> <default>
  local key=$1 override=$2 default=$3 value
  if [ -n "$override" ]; then
    printf '%s\n' "$override"
    return 0
  fi
  value=$(config_value "$key")
  if [ -n "$value" ]; then
    refuse_secret_shaped "$key" "$value"
    printf '%s\n' "$value"
    return 0
  fi
  printf '%s\n' "$default"
}

# Expand a leading `~/` against HOME. A config file is edited by hand, so it may
# carry the tilde form; nothing else about the path is interpreted.
# The `[~]` character class keeps the pattern a literal tilde match without
# writing a quoted tilde, which reads as an unexpanded home shorthand.
expand_home() {  # <path>
  case "$1" in
    [~]/*) printf '%s/%s\n' "${HOME:-}" "${1#*/}" ;;
    *) printf '%s\n' "$1" ;;
  esac
}

BASE_URL=$(resolve_setting base-url "${FM_CLAUDE_POOL_BASE_URL:-}" "$DEFAULT_BASE_URL") || exit 2
SECRET_FILE=$(resolve_setting secret-file "${FM_CLAUDE_POOL_SECRET_FILE:-}" "$DEFAULT_SECRET_FILE") || exit 2
SECRET_VAR=$(resolve_setting secret-var "${FM_CLAUDE_POOL_SECRET_VAR:-}" "$DEFAULT_SECRET_VAR") || exit 2
BASE_URL=${BASE_URL%/}
SECRET_FILE=$(expand_home "$SECRET_FILE")

# Extract exactly one variable's value from the credential source by PARSING it.
# The file is never executed and never sourced, so an operator's shell file
# cannot run code, define functions, or export anything as a side effect of a
# worker launch. Accepts `VAR=value` and `export VAR=value`, with the value
# optionally wrapped in one matching pair of single or double quotes.
#
# The value is written to the caller-named FILE, never to stdout of this helper,
# so it cannot be captured into a shell variable by accident here.
extract_secret_to_file() {  # <source> <var> <dest>
  awk -v var="$2" '
    BEGIN { plain = var "="; exported = "export " var "="; found = 0 }
    found { next }
    index($0, exported) == 1 { v = substr($0, length(exported) + 1); found = 1 }
    !found && index($0, plain) == 1 { v = substr($0, length(plain) + 1); found = 1 }
    found {
      sub(/[[:space:]]+$/, "", v)
      if (length(v) >= 2) {
        first = substr(v, 1, 1)
        last = substr(v, length(v), 1)
        if ((first == "'"'"'" && last == "'"'"'") || (first == "\"" && last == "\"")) {
          v = substr(v, 2, length(v) - 2)
        }
      }
      printf "%s", v
    }
  ' "$1" > "$3"
}

# Resolve the credential into a private file. Prints nothing on success; the
# caller reads the file. Diagnostics name the file and variable only.
SECRET_TMP=
cleanup_secret_tmp() {
  [ -n "$SECRET_TMP" ] && [ -d "$SECRET_TMP" ] && rm -rf "$SECRET_TMP"
  SECRET_TMP=
}
trap cleanup_secret_tmp EXIT INT TERM HUP

private_dir() {
  local d
  d=$(umask 077; mktemp -d "${TMPDIR:-/tmp}/fm-claude-pool.XXXXXX") || return 1
  chmod 700 "$d" 2>/dev/null || true
  printf '%s\n' "$d"
}

# Sets SECRET_TMP and writes "$SECRET_TMP/key". Returns 6 on any source fault.
load_secret() {
  if [ ! -f "$SECRET_FILE" ]; then
    printf 'fm-claude-pool: the pool credential source is missing: %s\n' "$SECRET_FILE" >&2
    printf 'fm-claude-pool: set secret-file in %s, or create that file with %s=<pool key>\n' \
      "$CONFIG_FILE" "$SECRET_VAR" >&2
    return 6
  fi
  if [ ! -r "$SECRET_FILE" ]; then
    printf 'fm-claude-pool: the pool credential source is not readable: %s\n' "$SECRET_FILE" >&2
    return 6
  fi
  SECRET_TMP=$(private_dir) || { printf 'fm-claude-pool: cannot create a private working directory\n' >&2; return 2; }
  ( umask 077; extract_secret_to_file "$SECRET_FILE" "$SECRET_VAR" "$SECRET_TMP/key" ) || {
    printf 'fm-claude-pool: could not read %s from %s\n' "$SECRET_VAR" "$SECRET_FILE" >&2
    return 6
  }
  if [ ! -s "$SECRET_TMP/key" ]; then
    printf 'fm-claude-pool: %s is not defined in %s\n' "$SECRET_VAR" "$SECRET_FILE" >&2
    printf 'fm-claude-pool: the pool route needs that variable; it never falls back to the native Claude login\n' >&2
    return 6
  fi
  return 0
}

# Fetch the pool's model catalog with the credential supplied through a curl
# config file, so it never appears in argv. Writes the catalog to <dest>.
fetch_catalog() {  # <dest>
  local dest=$1 code
  ( umask 077; printf 'header = "Authorization: Bearer %s"\n' "$(cat "$SECRET_TMP/key")" > "$SECRET_TMP/curlrc" ) || return 1
  code=$(curl -sS --max-time "$FETCH_TIMEOUT" --config "$SECRET_TMP/curlrc" \
    -o "$dest" -w '%{http_code}' "$BASE_URL/v1/models" 2>"$SECRET_TMP/curl.err") || code=000
  rm -f "$SECRET_TMP/curlrc"
  printf '%s\n' "$code"
}

cmd_check() {
  local model='' format=text catalog code owner present
  while [ $# -gt 0 ]; do
    case "$1" in
      --model) shift; [ $# -gt 0 ] || die "--model needs a model id"; model=$1 ;;
      --json) format=json ;;
      *) die "unknown argument '$1' (see --help)" ;;
    esac
    shift
  done
  [ -n "$model" ] || die "check needs --model <id>"
  command -v curl >/dev/null 2>&1 || die "curl is required"
  command -v jq >/dev/null 2>&1 || die "jq is required"

  load_secret || return $?
  catalog="$SECRET_TMP/models.json"
  code=$(fetch_catalog "$catalog")

  if [ "$code" != 200 ]; then
    report "$format" unreachable "$model" "" \
      "the pool at $BASE_URL did not serve its model catalog (HTTP $code); start the local CLIProxyAPI or correct base-url in $CONFIG_FILE"
    return 3
  fi
  if ! jq -e '.data | type == "array"' "$catalog" >/dev/null 2>&1; then
    report "$format" unreachable "$model" "" \
      "the pool at $BASE_URL returned a model catalog this route cannot read"
    return 3
  fi

  present=$(jq -r --arg m "$model" '[.data[] | select(.id == $m)] | length' "$catalog")
  if [ "$present" = 0 ]; then
    report "$format" unknown-model "$model" "" \
      "the pool at $BASE_URL does not serve a model named '$model'"
    return 4
  fi
  owner=$(jq -r --arg m "$model" 'first(.data[] | select(.id == $m) | .owned_by) // ""' "$catalog")
  if [ "$owner" != anthropic ]; then
    report "$format" wrong-family "$model" "$owner" \
      "'$model' is served by the pool but belongs to the '${owner:-unknown}' family, not Anthropic; the claude-pool route runs the Claude CLI and must not point it at a non-Claude model"
    return 5
  fi
  report "$format" ok "$model" "$owner" \
    "'$model' is an Anthropic model served by the pool at $BASE_URL"
  return 0
}

# Every result discloses that the proxy owns account selection, so no consumer
# can read a pass as a reserved or pinned account.
report() {  # <format> <result> <model> <owner> <reason>
  if [ "$1" = json ]; then
    jq -nc --arg result "$2" --arg model "$3" --arg owner "$4" --arg reason "$5" \
      --arg base_url "$BASE_URL" --arg source "$SECRET_FILE" --arg var "$SECRET_VAR" \
      '{schema:"fm-claude-pool.v1", result:$result, model:$model, owned_by:$owner,
        base_url:$base_url, secret_file:$source, secret_var:$var, reason:$reason,
        binds_account:false, selects_account:false}'
  else
    printf 'result:  %s\n' "$2"
    printf 'model:   %s%s\n' "$3" "$([ -n "$4" ] && printf ' (owned_by %s)' "$4")"
    printf 'pool:    %s\n' "$BASE_URL"
    printf 'secret:  %s in %s\n' "$SECRET_VAR" "$SECRET_FILE"
    printf 'reason:  %s\n' "$5"
    printf 'note:    the proxy selects the pooled account; this binds none\n'
  fi
}

cmd_secret() {
  while [ $# -gt 0 ]; do
    case "$1" in
      --secret-file) shift; [ $# -gt 0 ] || die "--secret-file needs a path"; SECRET_FILE=$(expand_home "$1") ;;
      --secret-var) shift; [ $# -gt 0 ] || die "--secret-var needs a name"; SECRET_VAR=$1 ;;
      *) die "unknown argument '$1' (see --help)" ;;
    esac
    shift
  done
  load_secret || return $?
  # stdout is the apiKeyHelper channel and the only place the value is written.
  cat "$SECRET_TMP/key"
  printf '\n'
}

# The exact `apiKeyHelper` payload for `claude --settings`. It names this script,
# the source file, and the variable - all non-secret - so a launched worker can
# obtain the credential without one ever being embedded in the launch command.
cmd_settings_json() {
  local secret_file=$SECRET_FILE secret_var=$SECRET_VAR
  while [ $# -gt 0 ]; do
    case "$1" in
      --secret-file) shift; [ $# -gt 0 ] || die "--secret-file needs a path"; secret_file=$(expand_home "$1") ;;
      --secret-var) shift; [ $# -gt 0 ] || die "--secret-var needs a name"; secret_var=$1 ;;
      *) die "unknown argument '$1' (see --help)" ;;
    esac
    shift
  done
  command -v jq >/dev/null 2>&1 || die "jq is required"
  jq -nc --arg helper "$SCRIPT_DIR/fm-claude-pool.sh" --arg f "$secret_file" --arg v "$secret_var" \
    '{apiKeyHelper: ($helper + " secret --secret-file " + ($f|@sh) + " --secret-var " + ($v|@sh))}'
}

cmd_source() {
  printf '%s\t%s\n' "$SECRET_FILE" "$SECRET_VAR"
}

case "${1:-}" in
  check) shift; cmd_check "$@" ;;
  secret) shift; cmd_secret "$@" ;;
  base-url) printf '%s\n' "$BASE_URL" ;;
  settings-json) shift; cmd_settings_json "$@" ;;
  source) cmd_source ;;
  -h|--help) usage ;;
  '') die "choose a command (see --help)" ;;
  *) die "unknown command '$1' (see --help)" ;;
esac
