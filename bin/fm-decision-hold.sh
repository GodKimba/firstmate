#!/usr/bin/env bash
# fm-decision-hold.sh - deterministic mechanics for durable captain decisions.
#
# The semantic policy is owned once by
# .agents/skills/decision-hold-lifecycle/SKILL.md. This script never reads report,
# visual-review, chat, or terminal prose to guess whether a decision exists.
# The invoking agent inventories unresolved decisions, assigns stable keys, and
# routes dependent work. This script supplies deterministic identities, creates
# and verifies structured tasks-axi captain holds, records completion attestation
# in the originating task's metadata, and closes a hold only after a durable
# decision record has been linked to existing dependent work.
#
# A hold identity is <origin-id>-decision-<decision-key>. Origin ids and decision
# keys must already be privacy-safe slugs. For an existing identity, an exact
# TOON-decoded title retry is idempotent, presentation quotes are not content,
# and literal quote characters remain content. A non-captain identity collision,
# changed title, or unreadable, duplicate, malformed, or otherwise ambiguous
# rendered title refuses. An already-resolved identity also refuses. A different
# decision key creates a different backlog identity.
# All backlog mutations run in the active FM_HOME, which keeps main-home and
# secondmate-home ownership aligned with the work that discovered the decision.
#
# One identity, two durable stores. Backlog retention moves a completed record
# out of the active backlog into the tasks-axi archive, so every lookup here
# reads the active backlog and that archive under the same identity: a resolved
# decision stays verifiable after retention without rehydrating the archived
# task and without copying one decision into both stores. The archive is only
# ever read; its rows are projected into a private temporary Done section so
# tasks-axi stays the single record parser. A record present in both stores is
# accepted only while the two copies are identical, which is the bounded window
# a prune can expose. An unreadable store, unsupported TOML escape syntax in
# the archive path, any other duplicate, a second archived row for the same
# identity, a non-completed or non-canonical archived row, or a symlinked or
# non-regular archive refuses instead of choosing silently. Mutating
# subcommands still require the active backlog.
#
# Usage:
#   fm-decision-hold.sh id <origin-id> <decision-key>
#   fm-decision-hold.sh hold <origin-id> <decision-key> \
#     --title <title> --reason <reason> [--repo <repo>]
#   fm-decision-hold.sh complete <origin-id> (--none | <decision-key>...)
#   fm-decision-hold.sh verify <origin-id>
#   fm-decision-hold.sh resolve <origin-id> <decision-key> \
#     --decision-file <path> --routed-to <task-id> [--routed-to <task-id>...]
#
# `complete` is the shared investigation and visual-review completion gate.
# `--none` is an explicit semantic attestation that the just-reviewed surface has
# no unresolved captain decision. Later review passes may add keys; a live task's
# metadata inventory is unioned idempotently. A post-teardown visual review can
# complete against the surviving report and holds without recreating task state.
# `verify` is read-only and is called by scout teardown so teardown cannot erase a
# source before this gate has succeeded.
#
# `resolve` requires every --routed-to task to exist and to be blocked by the hold.
# It writes the captain decision and routed identities into the hold body, clears
# those dependency edges, and only then marks the hold Done. A failure before the
# final step leaves the captain hold open.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"

# shellcheck source=bin/fm-classify-lib.sh
# shellcheck disable=SC1091
. "$SCRIPT_DIR/fm-classify-lib.sh"
# shellcheck source=bin/fm-tasks-axi-lib.sh
# shellcheck disable=SC1091
. "$SCRIPT_DIR/fm-tasks-axi-lib.sh"

usage() {
  awk '
    NR == 1 { next }
    /^#/ { sub(/^# ?/, ""); print; next }
    { exit }
  ' "$0"
}

fail() {
  printf 'fm-decision-hold: %s\n' "$*" >&2
  exit 1
}

validate_slug() {  # <label> <value>
  local label=$1 value=$2
  case "$value" in
    ''|*[!A-Za-z0-9._-]*) fail "$label must be a non-empty privacy-safe slug: $value" ;;
  esac
}

validate_one_line() {  # <label> <value>
  local label=$1 value=$2
  [ -n "$value" ] || fail "$label must not be empty"
  case "$value" in
    *$'\n'*|*$'\r'*) fail "$label must be one line" ;;
  esac
}

sha256_text() {  # <text>
  if command -v shasum >/dev/null 2>&1; then
    printf '%s' "$1" | shasum -a 256 | awk '{print $1}'
  elif command -v sha256sum >/dev/null 2>&1; then
    printf '%s' "$1" | sha256sum | awk '{print $1}'
  else
    fail "shasum or sha256sum is required"
  fi
}

hold_id() {  # <origin-id> <decision-key>
  validate_slug origin-id "$1"
  validate_slug decision-key "$2"
  printf '%s-decision-%s\n' "$1" "$2"
}

tasks_axi() {
  (cd "$FM_HOME" && tasks-axi "$@")
}

require_tasks_axi() {
  fm_tasks_axi_compatible || fail "compatible tasks-axi is required"
  tasks-axi hold --help 2>&1 | grep -F -- '--kind captain' >/dev/null \
    || fail "tasks-axi does not expose the captain-hold contract"
}

active_show() {  # <id> - the active backlog alone; every mutation requires this
  tasks_axi show "$1" --full 2>/dev/null
}

# .tasks.toml owns the backlog schema; this reads only the two keys needed to
# locate the archive tasks-axi prunes into, using the same FM_HOME-relative
# resolution tasks_axi() gets by running in FM_HOME.
toml_value() {  # <section> <key> [reject-basic-escapes]
  local file="$FM_HOME/.tasks.toml"
  [ -f "$file" ] || return 0
  awk -v want="$1" -v key="$2" -v reject_basic_escapes="${3:-0}" '
    /^[[:space:]]*\[/ {
      section = $0
      sub(/^[[:space:]]*\[[[:space:]]*/, "", section)
      sub(/[[:space:]]*\].*$/, "", section)
      next
    }
    section != want { next }
    {
      line = $0
      sub(/^[[:space:]]*/, "", line)
      if (line !~ "^" key "[[:space:]]*=") next
      sub("^" key "[[:space:]]*=[[:space:]]*", "", line)
      quote = substr(line, 1, 1)
      if (quote == "\"" || quote == sprintf("%c", 39)) {
        line = substr(line, 2)
        closing_quote = index(line, quote)
        if (closing_quote == 0) next
        line = substr(line, 1, closing_quote - 1)
        if (reject_basic_escapes && quote == "\"" && index(line, sprintf("%c", 92))) {
          exit 3
        }
      } else {
        sub(/[[:space:]].*$/, "", line)
      }
      print line
      exit
    }
  ' "$file"
}

archive_file() {  # prints the archive path, or nothing when this home has none
  local backend archive backlog dir
  backend=$(toml_value '' backend)
  [ -z "$backend" ] || [ "$backend" = markdown ] || return 0
  archive=$(toml_value markdown archive 1) || return 3
  if [ -z "$archive" ]; then
    backlog=$(backlog_file)
    dir=$(dirname "$backlog")
    if [ "$dir" = . ]; then archive=done-archive.md; else archive="$dir/done-archive.md"; fi
  fi
  case "$archive" in
    /*) printf '%s\n' "$archive" ;;
    *) printf '%s\n' "$FM_HOME/$archive" ;;
  esac
}

backlog_file() {  # prints the active markdown backlog path
  local backend backlog
  backend=$(toml_value '' backend)
  [ -z "$backend" ] || [ "$backend" = markdown ] || return 0
  backlog=$(toml_value markdown path)
  if [ -z "$backlog" ]; then
    if [ -e "$FM_HOME/backlog.md" ]; then
      backlog=backlog.md
    elif [ -e "$FM_HOME/data/backlog.md" ]; then
      backlog=data/backlog.md
    else
      backlog=backlog.md
    fi
  fi
  case "$backlog" in
    /*) printf '%s\n' "$backlog" ;;
    *) printf '%s\n' "$FM_HOME/$backlog" ;;
  esac
}

record_rows() {  # <store-file> <id> <active|archive>
  awk -v id="$2" -v store="$3" '
    function is_top_row(line) {
      return line ~ /^-[[:space:]]/ || line ~ /^-\[/ || line ~ /^-\*\*/
    }
    function has_identity(text,   rest, offset, pos, absolute, before, after) {
      rest = text
      offset = 0
      while ((pos = index(rest, id)) > 0) {
        absolute = offset + pos
        before = absolute > 1 ? substr(text, absolute - 1, 1) : ""
        after = substr(text, absolute + length(id), 1)
        if (before !~ /[A-Za-z0-9._-]/ && after !~ /[A-Za-z0-9._-]/) {
          return 1
        }
        offset = absolute + length(id) - 1
        rest = substr(text, offset + 1)
      }
      return 0
    }
    function is_candidate(line,   rest, closing_bracket, suffix, separator, prefix) {
      if (!is_top_row(line)) return 0
      rest = line
      sub(/^-[[:space:]]*/, "", rest)
      prefix = rest
      if (substr(rest, 1, 1) == "[") {
        closing_bracket = index(rest, "]")
        if (closing_bracket == 0) return has_identity(rest)
        suffix = substr(rest, closing_bracket + 1)
        separator = index(suffix, " - ")
        if (separator > 0) {
          prefix = substr(rest, 1, closing_bracket + separator - 1)
        }
      }
      return has_identity(prefix)
    }
    function refuse(message) {
      printf "refuse: %s\n", message
      refused = 1
      exit
    }
    {
      if (is_candidate($0)) {
        if (index($0, "- [x] " id " - ") == 1) {
          starts++
          capture = 1
          block = block $0 "\n"
          next
        }
        if (index($0, "- [ ] " id " - ") == 1) {
          if (store == "archive") {
            refuse("archived record " id " is not a completed record")
          }
          starts++
          capture = 1
          block = block $0 "\n"
          next
        }
        refuse(store " record " id " is not in canonical form")
      }
      if (capture && (is_top_row($0) || $0 ~ /^##/)) { capture = 0 }
      if (capture) { block = block $0 "\n" }
    }
    END {
      if (!refused && starts > 1) {
        printf "refuse: %s holds %d conflicting records for %s\n", store, starts, id
      }
      if (!refused && starts == 1) { printf "%s", block }
    }
  ' "$1"
}

record_source() {  # <store-file> <id> <active|archive> <raw-output>
  local file=$1 id=$2 store=$3 raw=$4 first
  (umask 077; record_rows "$file" "$id" "$store" > "$raw") 2>/dev/null || {
    printf '%s decision store could not be read: %s\n' "$store" "$file"
    return 3
  }
  first=$(sed -n '1p' "$raw")
  case "$first" in
    'refuse: '*) printf '%s\n' "${first#refuse: }"; return 3 ;;
  esac
  [ -s "$raw" ] || return 1
}

active_record() {  # <id> <raw-output>
  local id=$1 raw=$2 backlog
  backlog=$(backlog_file)
  [ -n "$backlog" ] || {
    printf 'active decision store could not be located for %s\n' "$id"
    return 3
  }
  [ -e "$backlog" ] || return 1
  if [ ! -f "$backlog" ]; then
    printf 'active decision store is not a regular file: %s\n' "$backlog"
    return 3
  fi
  record_source "$backlog" "$id" active "$raw"
}

archive_record() {  # <id> <raw-output>
  local id=$1 raw=$2 archive rc=0
  archive=$(archive_file) || rc=$?
  if [ "$rc" -eq 3 ]; then
    printf 'archived decision store configuration uses unsupported TOML escape syntax\n'
    return 3
  fi
  [ -n "$archive" ] || return 1
  if [ -L "$archive" ]; then
    printf 'archived decision store is a symlink: %s\n' "$archive"
    return 3
  fi
  [ -e "$archive" ] || return 1
  if [ ! -f "$archive" ]; then
    printf 'archived decision store is not a regular file: %s\n' "$archive"
    return 3
  fi
  record_source "$archive" "$id" archive "$raw"
}

archive_show() {  # <id> <raw-record> <projected-file>
  local id=$1 raw=$2 projected=$3 show rc=0
  (umask 077; { printf '## In flight\n\n## Queued\n\n## Done\n'; awk '{ print }' "$raw"; } > "$projected") || {
    printf 'could not stage the archived record for %s\n' "$id"
    return 3
  }
  show=$(tasks_axi show "$id" --file "$projected" --full 2>&1) || rc=$?
  if [ "$rc" -ne 0 ]; then
    printf 'archived record %s could not be parsed by tasks-axi\n' "$id"
    return 3
  fi
  printf '%s\n' "$show"
}

active_lookup() {  # <id>
  local id=$1 show rc=0
  show=$(tasks_axi show "$id" --full 2>&1) || rc=$?
  if [ "$rc" -eq 0 ]; then
    printf '%s\n' "$show"
    return 0
  fi
  if printf '%s\n' "$show" | grep -Fx 'code: NOT_FOUND' >/dev/null; then
    return 1
  fi
  printf 'active decision store could not be read for %s\n' "$id"
  return 3
}

# The one identity lookup for this script: a decision is durable whether it is
# still in the active backlog or has already been archived by retention.
# 0 = found (stdout is the record), 1 = absent, 3 = refused (stdout is why).
lookup_task() {  # <id>
  local id=$1 active archived active_message archive_message tmp active_raw archived_raw projected
  local active_rc=0 archived_record_rc=0 archived_rc=1 active_record_rc=1 result_rc=1 result=
  tmp=$(umask 077; mktemp -d "${TMPDIR:-/tmp}/fm-decision-lookup.XXXXXX") || {
    printf 'could not stage durable record lookup for %s\n' "$id"
    return 3
  }
  active_raw="$tmp/active"
  archived_raw="$tmp/archive"
  projected="$tmp/projected"
  active=$(active_lookup "$id") || active_rc=$?
  archive_message=$(archive_record "$id" "$archived_raw") || archived_record_rc=$?

  if [ "$active_rc" -eq 1 ]; then
    active_record_rc=0
    active_message=$(active_record "$id" "$active_raw") || active_record_rc=$?
    if [ "$active_record_rc" -eq 0 ]; then
      active="active record $id could not be parsed by tasks-axi"
      active_rc=3
    elif [ "$active_record_rc" -eq 3 ]; then
      active=$active_message
      active_rc=3
    fi
  elif [ "$active_rc" -eq 0 ] && [ "$archived_record_rc" -eq 0 ]; then
    active_record_rc=0
    active_message=$(active_record "$id" "$active_raw") || active_record_rc=$?
    if [ "$active_record_rc" -ne 0 ]; then
      if [ "$active_record_rc" -eq 3 ]; then
        active=$active_message
      else
        active="active record $id could not be located for duplicate comparison"
      fi
      active_rc=3
    elif ! cmp -s "$active_raw" "$archived_raw"; then
      active="durable record $id differs between the active backlog and the archive"
      active_rc=3
    fi
  fi

  if [ "$active_rc" -eq 3 ]; then
    result=$active
    result_rc=3
  elif [ "$archived_record_rc" -eq 3 ]; then
    result=$archive_message
    result_rc=3
  else
    if [ "$archived_record_rc" -eq 0 ]; then
      archived_rc=0
      archived=$(archive_show "$id" "$archived_raw" "$projected") || archived_rc=$?
    fi
    if [ "$archived_rc" -eq 3 ]; then
      result=$archived
      result_rc=3
    elif [ "$active_rc" -eq 0 ]; then
      result=$active
      result_rc=0
    elif [ "$archived_rc" -eq 0 ]; then
      result=$archived
      result_rc=0
    fi
  fi

  rm -f "$active_raw" "$archived_raw" "$projected"
  rmdir "$tmp"
  [ "$result_rc" -eq 1 ] || printf '%s\n' "$result"
  return "$result_rc"
}

show_field() {  # <show-output> <field>
  local output=$1 field=$2
  printf '%s\n' "$output" | sed -n "s/^  $field: //p" | head -1
}

origin_exists_here() {  # <origin-id>
  local out rc=0
  [ -f "$STATE/$1.meta" ] && return 0
  [ -f "$DATA/$1/report.md" ] && return 0
  out=$(lookup_task "$1") || rc=$?
  [ "$rc" -ne 3 ] || fail "$out"
  [ "$rc" -eq 0 ]
}

list_has_key() {  # <comma-list> <key>
  case ",$1," in
    *",$2,"*) return 0 ;;
    *) return 1 ;;
  esac
}

sorted_key_union() {  # <comma-list> <newline-or-space-separated-new-keys>
  local existing=$1 new=$2
  {
    printf '%s\n' "$existing" | tr ',' '\n'
    printf '%s\n' "$new" | tr ' ' '\n'
  } | sed '/^$/d' | LC_ALL=C sort -u | paste -sd, -
}

meta_value() {  # <meta> <key>
  grep "^$2=" "$1" 2>/dev/null | tail -1 | cut -d= -f2- || true
}

origin_open_decisions() {  # <origin-id>
  local origin=$1 meta="$STATE/$1.meta" status_file="$STATE/$1.status" open kind last verb
  open=$(status_open_decisions "$status_file")
  [ -n "$open" ] || return 0
  [ -f "$meta" ] || { printf '%s' "$open"; return 0; }
  kind=$(meta_value "$meta" kind)
  [ -n "$kind" ] || kind=ship
  if [ "$kind" != secondmate ]; then
    last=$(last_status_line "$status_file")
    verb=$(status_line_verb "$last")
    case "$verb" in
      done|failed) return 0 ;;
    esac
  fi
  printf '%s' "$open"
}

# Activating or closing a hold writes to the active backlog, so this deliberately
# never accepts an archived record: retention durability is a read guarantee.
verify_hold_active() {  # <hold-id>
  local id=$1 show state held kind hold_kind
  show=$(active_show "$id") || fail "captain hold $id is absent from $FM_HOME/data/backlog.md"
  state=$(show_field "$show" state)
  held=$(show_field "$show" held)
  kind=$(show_field "$show" kind)
  hold_kind=$(show_field "$show" hold_kind)
  [ "$state" = queued ] || fail "captain hold $id is not queued (state=$state)"
  [ "$held" = yes ] || fail "captain hold $id is not active"
  [ "$kind" = captain ] || fail "backlog item $id is not kind captain"
  [ "$hold_kind" = captain ] || fail "backlog item $id is not held for the captain"
}

verify_hold_resolved() {  # <hold-id>
  local id=$1 show state kind body rc=0
  show=$(lookup_task "$id") || rc=$?
  [ "$rc" -ne 3 ] || fail "$show"
  [ "$rc" -eq 0 ] || return 1
  state=$(show_field "$show" state)
  kind=$(show_field "$show" kind)
  body=$(show_field "$show" body)
  [ "$state" = "done" ] || return 1
  [ "$kind" = captain ] || return 1
  case "$body" in
    *"Resolution recorded by fm-decision-hold."*"Routed work:"*) return 0 ;;
  esac
  return 1
}

# The completion check: durable means actively held in the backlog, or durably
# resolved in either store, so normal retention cannot make a decision unverifiable.
verify_hold_durable() {  # <hold-id>
  local id=$1 show state held kind hold_kind body rc=0
  show=$(lookup_task "$id") || rc=$?
  [ "$rc" -ne 3 ] || fail "$show"
  [ "$rc" -eq 0 ] \
    || fail "captain decision $id is absent from the durable records of $FM_HOME"
  state=$(show_field "$show" state)
  held=$(show_field "$show" held)
  kind=$(show_field "$show" kind)
  hold_kind=$(show_field "$show" hold_kind)
  body=$(show_field "$show" body)
  if [ "$state" = queued ] && [ "$held" = yes ] && [ "$kind" = captain ] && [ "$hold_kind" = captain ]; then
    return 0
  fi
  if [ "$state" = "done" ] && [ "$kind" = captain ]; then
    case "$body" in
      *"Resolution recorded by fm-decision-hold."*"Routed work:"*) return 0 ;;
    esac
  fi
  fail "captain decision $id is neither actively held nor durably resolved"
}

verify_resolution_identity() {
  local id=$1 hold_body=$2 decision_digest=$3 routed_csv=$4 resolution_prefix resolution_fields recorded_digest recorded_routes
  resolution_prefix='"Resolution recorded by fm-decision-hold.\nDecision digest: '
  case "$hold_body" in
    "$resolution_prefix"*) resolution_fields=${hold_body#"$resolution_prefix"} ;;
    *) fail "captain hold $id has no retry identity record" ;;
  esac
  case "$resolution_fields" in
    *'\nRouted identities: '*'\n\nCaptain decision:'*) : ;;
    *) fail "captain hold $id has an invalid retry identity record" ;;
  esac
  recorded_digest=${resolution_fields%%\\n*}
  resolution_fields=${resolution_fields#*\\nRouted identities: }
  recorded_routes=${resolution_fields%%\\n*}
  [ "$recorded_digest" = "$decision_digest" ] \
    || fail "captain hold $id records a different captain decision"
  [ "$recorded_routes" = "$routed_csv" ] \
    || fail "captain hold $id records different routed work"
}

command_id() {
  [ "$#" -eq 2 ] || { usage >&2; exit 2; }
  hold_id "$1" "$2"
}

command_hold() {
  local origin=${1:-} key=${2:-} title='' reason='' repo='' id show state kind existing_title body lookup_rc=0
  [ "$#" -ge 2 ] || { usage >&2; exit 2; }
  shift 2
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --title) shift; title=${1:-} ;;
      --reason) shift; reason=${1:-} ;;
      --repo) shift; repo=${1:-} ;;
      *) usage >&2; exit 2 ;;
    esac
    shift
  done
  validate_slug origin-id "$origin"
  validate_slug decision-key "$key"
  validate_one_line title "$title"
  validate_one_line reason "$reason"
  case "$reason" in *'('*|*')'*) fail "reason must not contain parentheses (tasks-axi hold contract)" ;; esac
  require_tasks_axi
  origin_exists_here "$origin" || fail "origin $origin is not owned by the active home $FM_HOME"
  id=$(hold_id "$origin" "$key")
  # Look in both stores so a resolved decision already moved into the archive
  # cannot be re-created as a second live item under the same identity.
  show=$(lookup_task "$id") || lookup_rc=$?
  [ "$lookup_rc" -ne 3 ] || fail "$show"
  if [ "$lookup_rc" -eq 0 ]; then
    state=$(show_field "$show" state)
    kind=$(show_field "$show" kind)
    existing_title=$(fm_tasks_axi_show_string "$show" title) \
      || fail "existing captain hold $id has an unreadable or ambiguous title"
    [ "$state" != "done" ] || fail "captain decision $id is already durably resolved; use a new decision key for a new decision"
    [ "$kind" = captain ] || fail "existing backlog identity $id is not kind captain"
    [ "$existing_title" = "$title" ] || fail "existing captain hold $id has a different title"
  else
    if [ -z "$repo" ] && [ -f "$STATE/$origin.meta" ]; then
      repo=$(meta_value "$STATE/$origin.meta" project)
      repo=${repo%/}
      repo=${repo##*/}
    fi
    [ -n "$repo" ] || repo=firstmate
    validate_one_line repo "$repo"
    body=$(printf 'Origin: %s\nDecision key: %s\nState: awaiting captain decision.' "$origin" "$key")
    tasks_axi add "$id" "$title" --kind captain --repo "$repo" --body "$body" >/dev/null \
      || fail "could not create captain decision item $id"
  fi
  tasks_axi hold "$id" --reason "$reason" --kind captain >/dev/null \
    || fail "could not activate captain hold $id"
  verify_hold_active "$id"
  printf '%s\n' "$id"
}

command_complete() {
  local origin=${1:-} meta previous='' supplied='' keys='' key status_file open raw_open key_seen=0 has_meta=0
  [ "$#" -ge 2 ] || { usage >&2; exit 2; }
  validate_slug origin-id "$origin"
  shift
  meta="$STATE/$origin.meta"
  [ -f "$meta" ] && has_meta=1
  require_tasks_axi
  origin_exists_here "$origin" || fail "origin $origin is not owned by the active home $FM_HOME"
  if [ "$#" -eq 1 ] && [ "$1" = --none ]; then
    supplied=''
  else
    while [ "$#" -gt 0 ]; do
      [ "$1" != --none ] || fail "--none cannot be combined with decision keys"
      validate_slug decision-key "$1"
      supplied="${supplied}${supplied:+ }$1"
      shift
    done
  fi
  if [ "$has_meta" = 1 ]; then
    previous=$(meta_value "$meta" decision_keys)
  fi
  keys=$(sorted_key_union "$previous" "$supplied")
  if [ -n "$keys" ]; then
    while IFS= read -r key; do
      [ -n "$key" ] || continue
      verify_hold_durable "$(hold_id "$origin" "$key")"
    done <<EOF
$(printf '%s\n' "$keys" | tr ',' '\n')
EOF
  fi

  status_file="$STATE/$origin.status"
  raw_open=$(status_open_decisions "$status_file")
  open=$(origin_open_decisions "$origin")
  while IFS=$'\t' read -r key _verb _summary; do
    [ -n "$key" ] || continue
    list_has_key "$keys" "$key" \
      || fail "open structured decision $origin/$key has no captain-held inventory entry"
  done <<EOF
$open
EOF

  if [ "$has_meta" = 1 ]; then
    if [ "$(meta_value "$meta" decisions_reviewed)" != 1 ] || [ "$previous" != "$keys" ]; then
      printf 'decisions_reviewed=1\ndecision_keys=%s\n' "$keys" >> "$meta"
    fi

    # Transfer any still-open status decision to its durable backlog owner so the
    # live status fold does not duplicate the same Captain's Call item.
    while IFS=$'\t' read -r key _verb _summary; do
      [ -n "$key" ] || continue
      list_has_key "$keys" "$key" || continue
      printf 'captain-held [key=%s]: tracked by %s\n' "$key" "$(hold_id "$origin" "$key")" >> "$status_file"
      key_seen=1
    done <<EOF
$raw_open
EOF
  fi
  : "$key_seen"
  printf 'complete: %s decision inventory reviewed%s\n' "$origin" "${keys:+ ($keys)}"
}

command_verify() {
  local origin=${1:-} meta reviewed keys key open
  [ "$#" -eq 1 ] || { usage >&2; exit 2; }
  validate_slug origin-id "$origin"
  meta="$STATE/$origin.meta"
  [ -f "$meta" ] || fail "origin metadata is absent: $meta"
  require_tasks_axi
  reviewed=$(meta_value "$meta" decisions_reviewed)
  [ "$reviewed" = 1 ] || fail "origin $origin has no completed unresolved-decision inventory"
  keys=$(meta_value "$meta" decision_keys)
  if [ -n "$keys" ]; then
    while IFS= read -r key; do
      [ -n "$key" ] || continue
      verify_hold_durable "$(hold_id "$origin" "$key")"
    done <<EOF
$(printf '%s\n' "$keys" | tr ',' '\n')
EOF
  fi
  open=$(origin_open_decisions "$origin")
  while IFS=$'\t' read -r key _verb _summary; do
    [ -n "$key" ] || continue
    list_has_key "$keys" "$key" \
      || fail "open structured decision $origin/$key is outside the reviewed inventory"
    verify_hold_durable "$(hold_id "$origin" "$key")"
  done <<EOF
$open
EOF
  printf 'verified: %s unresolved-decision inventory\n' "$origin"
}

command_resolve() {
  local origin=${1:-} key=${2:-} decision_file='' id='' decision='' decision_digest='' body='' routed='' routed_csv='' dep show blocked state hold_show hold_body resolution_recorded=0
  [ "$#" -ge 2 ] || { usage >&2; exit 2; }
  shift 2
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --decision-file) shift; decision_file=${1:-} ;;
      --routed-to) shift; validate_slug routed-task "${1:-}"; routed="${routed}${routed:+ }${1:-}" ;;
      *) usage >&2; exit 2 ;;
    esac
    shift
  done
  validate_slug origin-id "$origin"
  validate_slug decision-key "$key"
  [ -n "$decision_file" ] || fail "--decision-file is required"
  [ -f "$decision_file" ] || fail "decision file does not exist: $decision_file"
  decision=$(cat "$decision_file")
  [ -n "$decision" ] || fail "decision file must not be empty"
  [ "$(printf '%s' "$decision" | LC_ALL=C wc -c | tr -d ' ')" -le 8192 ] \
    || fail "decision file exceeds 8192 bytes"
  [ -n "$routed" ] || fail "at least one --routed-to task is required"
  routed=$(printf '%s\n' "$routed" | tr ' ' '\n' | sed '/^$/d' | LC_ALL=C sort -u | paste -sd' ' -)
  routed_csv=$(printf '%s\n' "$routed" | tr ' ' ',')
  decision_digest=$(sha256_text "$decision")
  require_tasks_axi
  id=$(hold_id "$origin" "$key")
  if verify_hold_resolved "$id"; then
    # Read from the same durable pair the resolved check used, so an identical
    # retry stays idempotent after retention archived the closed hold.
    hold_show=$(lookup_task "$id")
    hold_body=$(show_field "$hold_show" body)
    verify_resolution_identity "$id" "$hold_body" "$decision_digest" "$routed_csv"
    printf 'resolved: %s\n' "$id"
    return 0
  fi
  verify_hold_active "$id"
  hold_show=$(active_show "$id")
  hold_body=$(show_field "$hold_show" body)
  case "$hold_body" in
    *"Resolution recorded by fm-decision-hold."*)
      verify_resolution_identity "$id" "$hold_body" "$decision_digest" "$routed_csv"
      resolution_recorded=1
      ;;
  esac

  for dep in $routed; do
    show=$(active_show "$dep") || fail "routed task $dep does not exist in the active home"
    state=$(show_field "$show" state)
    [ "$state" != "done" ] || [ "$resolution_recorded" = 1 ] \
      || fail "routed task $dep is already done"
    # tasks-axi quotes multi-entry blocked_by as "a,b,c"; strip so edge ids match.
    blocked=$(show_field "$show" blocked_by | tr -d '[:space:]')
    blocked=${blocked#\"}
    blocked=${blocked%\"}
    case ",$blocked," in
      *",$id,"*) : ;;
      *)
        case "$hold_body" in
          *"Resolution recorded by fm-decision-hold."*"- $dep"*) : ;;
          *) fail "routed task $dep is not durably blocked by $id" ;;
        esac
        ;;
    esac
  done

  body=$(printf 'Resolution recorded by fm-decision-hold.\nDecision digest: %s\nRouted identities: %s\n\nCaptain decision:\n%s\n\nRouted work:\n' "$decision_digest" "$routed_csv" "$decision")
  for dep in $routed; do
    body="${body}- ${dep}"$'\n'
  done
  tasks_axi update "$id" --body "$body" >/dev/null \
    || fail "could not record the captain decision on $id"
  for dep in $routed; do
    show=$(active_show "$dep") || fail "routed task $dep disappeared before routing"
    blocked=$(show_field "$show" blocked_by | tr -d '[:space:]')
    blocked=${blocked#\"}
    blocked=${blocked%\"}
    case ",$blocked," in
      *",$id,"*)
        tasks_axi unblock "$dep" --by "$id" >/dev/null \
          || fail "could not route the recorded decision to $dep"
        ;;
    esac
  done
  tasks_axi "done" "$id" >/dev/null || fail "could not close resolved captain hold $id"
  verify_hold_resolved "$id" || fail "captain hold $id did not retain its durable resolution record"
  printf 'resolved: %s -> %s\n' "$id" "$routed"
}

case "${1:-}" in
  id) shift; command_id "$@" ;;
  hold) shift; command_hold "$@" ;;
  complete) shift; command_complete "$@" ;;
  verify) shift; command_verify "$@" ;;
  resolve) shift; command_resolve "$@" ;;
  -h|--help) usage ;;
  *) usage >&2; exit 2 ;;
esac
