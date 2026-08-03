#!/usr/bin/env bash
# Shared lifecycle notification owner.
#
# bin/fm-crew-state.sh remains the authority for a task's current state.
# This library owns the supervision reduction, the one per-task lifecycle memo,
# and the one mode-free, endpoint-free occurrence ledger used by every emitter.
#
# The memo format is state/<task>.lifecycle:
#   <working|paused|parked|terminal|unknown><TAB><identity|none><TAB><epoch>
#
# The surfaced ledger format is state/<task>.surfaced:
#   <occurrence-identity><TAB><epoch>
#
# Occurrence identity inputs are closed by contract.
# Decisions use the immutable status-stream occurrence id.
# Full no-mistakes runs use run id, head, status, outcome, gate step, and the
# ordered step-status vector.
# Coarse run rows use branch, short head, and terminal status.
# Captain-relevant status fallback uses the exact last status line.
# Finding counts, durations, dates, PR URLs, elapsed strings, reconciliation
# prose, rendered pane hashes, endpoints, supervision modes, and human detail
# are never identity inputs.
#
# Rendered pane hashes may detect inactivity but never identify or suppress a
# lifecycle occurrence.
# Every notification must be enqueued before fm_mark_surfaced records it.
# A malformed memo triggers a fresh authoritative read.
# A malformed surfaced ledger reads as pending so failure points toward visibility.

_FM_LIFECYCLE_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd 2>/dev/null)" || _FM_LIFECYCLE_LIB_DIR="."
# shellcheck source=bin/fm-classify-lib.sh
. "$_FM_LIFECYCLE_LIB_DIR/fm-classify-lib.sh"
# shellcheck source=bin/fm-backend.sh
if ! declare -F fm_backend_target_of_meta >/dev/null; then
  . "$_FM_LIFECYCLE_LIB_DIR/fm-backend.sh"
fi

FM_LIFECYCLE_TTL_DEFAULT=300

fm_lifecycle_task_valid() {
  case "${1:-}" in
    ''|*[!A-Za-z0-9._-]*) return 1 ;;
    *) return 0 ;;
  esac
}

fm_lifecycle_state_root() {  # [explicit-state]
  if [ -n "${1:-}" ]; then
    printf '%s' "$1"
  elif [ -n "${FM_STATE_OVERRIDE:-}" ]; then
    printf '%s' "$FM_STATE_OVERRIDE"
  elif [ -n "${STATE:-}" ]; then
    printf '%s' "$STATE"
  else
    printf '%s/state' "${FM_HOME:-${FM_ROOT_OVERRIDE:-$(cd "$_FM_LIFECYCLE_LIB_DIR/.." && pwd)}}"
  fi
}

fm_lifecycle_memo_path() {  # <task> [state]
  fm_lifecycle_task_valid "$1" || return 2
  printf '%s/%s.lifecycle' "$(fm_lifecycle_state_root "${2:-}")" "$1"
}

fm_lifecycle_surfaced_path() {  # <task> [state]
  fm_lifecycle_task_valid "$1" || return 2
  printf '%s/%s.surfaced' "$(fm_lifecycle_state_root "${2:-}")" "$1"
}

fm_lifecycle_epoch() {
  date +%s
}

fm_lifecycle_memo_parse() {  # <memo-line>
  local line=$1 class identity epoch extra
  IFS=$'\t' read -r class identity epoch extra <<EOF
$line
EOF
  [ -z "$extra" ] || return 1
  case "$class" in working|paused|parked|terminal|unknown) ;; *) return 1 ;; esac
  case "$identity" in
    none|decision:*|run:parked:*|run:terminal:*|status:*) ;;
    *) return 1 ;;
  esac
  case "$epoch" in ''|*[!0-9]*) return 1 ;; esac
  printf '%s\t%s\t%s\n' "$class" "$identity" "$epoch"
}

fm_lifecycle_memo_read() {  # <task> [state]
  local task=$1 state=${2:-} path line
  path=$(fm_lifecycle_memo_path "$task" "$state") || return
  line=$(cat "$path" 2>/dev/null) || return 1
  fm_lifecycle_memo_parse "$line"
}

fm_lifecycle_atomic_write() {  # <path> <content>
  local path=$1 content=$2 dir tmp
  dir=${path%/*}
  mkdir -p "$dir" || return 1
  tmp="$path.tmp.${BASHPID:-$$}.${RANDOM:-0}"
  ( umask 077; printf '%s\n' "$content" > "$tmp" ) || { rm -f "$tmp"; return 1; }
  mv -f "$tmp" "$path" || { rm -f "$tmp"; return 1; }
}

fm_lifecycle_status_identity() {  # <status-line>
  [ -n "$1" ] || { printf 'none'; return 0; }
  printf 'status:%s' "$(printf '%s' "$1" | fm_decision_hash_text)"
}

fm_lifecycle_supplemental_status_identity() {  # <status-file> <lifecycle-identity> [last-line]
  local f=$1 identity=$2 last=${3:-}
  case "$identity" in decision:*) ;; *) printf 'none'; return 0 ;; esac
  [ -n "$last" ] || last=$(last_status_line "$f")
  if status_is_captain_relevant "$last" \
    && ! status_latest_decision_is_open_occurrence "$f"; then
    fm_lifecycle_status_identity "$last"
  else
    printf 'none'
  fi
}

fm_lifecycle_status_line_for_identity() {  # <status-file> <status-identity>
  local f=$1 identity=$2 wanted line hash match=
  case "$identity" in status:*) wanted=${identity#status:} ;; *) return 1 ;; esac
  [ -f "$f" ] || return 1
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in *[![:space:]]*) ;; *) continue ;; esac
    fm_decision_marker_line_id "$line" >/dev/null 2>&1 && continue
    hash=$(printf '%s' "$line" | fm_decision_hash_text) || continue
    [ "$hash" = "$wanted" ] && match=$line
  done < "$f"
  [ -n "$match" ] || return 1
  printf '%s' "$match"
}

fm_lifecycle_legacy_identity() {  # <identity> <status-line> [include-paused]
  local identity=$1 line=${2:-} include_paused=${3:-0}
  case "$identity" in
    decision:*|status:*) printf '%s' "$identity"; return 0 ;;
  esac
  if [ "$identity" = none ] && [ -n "$line" ] \
    && { status_is_captain_relevant "$line" \
      || { [ "$include_paused" = 1 ] && status_is_paused "$line"; }; }; then
    fm_lifecycle_status_identity "$line"
    return
  fi
  printf 'none'
}

fm_lifecycle_clear_working_timers() {  # <task> [state] [class]
  local task=$1 state=${2:-} class=${3:-} root meta target target_key task_key
  [ "$class" = unknown ] && return 0
  root=$(fm_lifecycle_state_root "$state")
  meta="$root/$task.meta"
  [ -e "$meta" ] || return 0
  target=$(fm_backend_target_of_meta "$meta")
  target_key=$(printf '%s' "$target" | tr ':/.' '___')
  task_key=$(printf '%s' "$task" | tr ':/.' '___')
  if [ -n "$target_key" ]; then
    rm -f "$root/.stale-since-$target_key" "$root/.wedge-escalations-$target_key"
  fi
  rm -f "$root/.subsuper-stale-$task_key"
}

fm_lifecycle_memo_write() {  # <task> <class> <identity> [state]
  local task=$1 class=$2 identity=$3 state=${4:-} path epoch
  fm_lifecycle_memo_parse "$class"$'\t'"$identity"$'\t'"$(fm_lifecycle_epoch)" >/dev/null || return 2
  path=$(fm_lifecycle_memo_path "$task" "$state") || return
  epoch=$(fm_lifecycle_epoch)
  fm_lifecycle_atomic_write "$path" "$class"$'\t'"$identity"$'\t'"$epoch"
}

fm_lifecycle_read() {  # <task> [cached|force] [state]
  local task=$1 mode=${2:-cached} state=${3:-} root memo line class identity epoch now ttl statusf key _verb instance _summary
  fm_lifecycle_task_valid "$task" || { printf 'unknown\tnone\n'; return 2; }
  root=$(fm_lifecycle_state_root "$state")
  memo=$(fm_lifecycle_memo_path "$task" "$root") || { printf 'unknown\tnone\n'; return 2; }
  ttl=${FM_LIFECYCLE_TTL:-$FM_LIFECYCLE_TTL_DEFAULT}
  case "$ttl" in ''|*[!0-9]*) ttl=$FM_LIFECYCLE_TTL_DEFAULT ;; esac
  if [ "$mode" != force ]; then
    line=$(fm_lifecycle_memo_read "$task" "$root" 2>/dev/null || true)
    if [ -n "$line" ]; then
      IFS=$'\t' read -r class identity epoch <<EOF
$line
EOF
      now=$(fm_lifecycle_epoch)
      statusf="$root/$task.status"
      if [ "$class" != unknown ] \
        && [ $((now - epoch)) -lt "$ttl" ] \
        && { [ ! -e "$statusf" ] || [ ! "$statusf" -nt "$memo" ]; }; then
        [ "$class" = working ] || fm_lifecycle_clear_working_timers "$task" "$root" "$class"
        printf '%s\t%s\n' "$class" "$identity"
        return 0
      fi
    fi
  fi
  line=$(FM_STATE_OVERRIDE="$root" "$FM_CREW_STATE_BIN" --supervision "$task" 2>/dev/null || true)
  IFS=$'\t' read -r class identity extra <<EOF
$line
EOF
  [ -z "${extra:-}" ] || { class=; identity=; }
  case "$class" in working|paused|parked|terminal|unknown) ;; *) class= ;; esac
  case "$identity" in none|decision:*|run:parked:*|run:terminal:*|status:*) ;; *) identity= ;; esac
  if [ -z "$class" ] || [ -z "$identity" ]; then
    line=$(FM_STATE_OVERRIDE="$root" "$FM_CREW_STATE_BIN" "$task" 2>/dev/null || true)
    case "$line" in
      state:\ working*)
        case "$line" in *"source: run-step"*|*"source: pane"*|*"source: ci-withheld"*) class=working ;; *) class=unknown ;; esac
        ;;
      state:\ paused*) class=paused ;;
      state:\ parked*|state:\ blocked*) class=parked ;;
      state:\ done*|state:\ failed*) class=terminal ;;
      *) class=unknown ;;
    esac
    identity=none
  fi
  while IFS=$'\t' read -r key _verb instance _summary || [ -n "$key" ]; do
    [ -n "$key" ] || continue
    class=parked
    identity="decision:$instance"
    break
  done <<EOF
$(status_open_supervision_decisions "$root/$task.status")
EOF
  fm_lifecycle_memo_write "$task" "$class" "$identity" "$root" || return 2
  [ "$class" = working ] || fm_lifecycle_clear_working_timers "$task" "$root" "$class"
  printf '%s\t%s\n' "$class" "$identity"
}

fm_lifecycle_class() {  # <task> [cached|force] [state]
  local line
  line=$(fm_lifecycle_read "$@") || true
  printf '%s' "${line%%$'\t'*}"
}

fm_lifecycle_occurrence() {  # <task> [cached|force] [state]
  local line
  line=$(fm_lifecycle_read "$@") || true
  case "$line" in *$'\t'*) printf '%s' "${line#*$'\t'}" ;; *) printf 'none' ;; esac
}

fm_lifecycle_turn_end_mode() {  # <task> [state]
  local memo class
  memo=$(fm_lifecycle_memo_read "$1" "${2:-}" 2>/dev/null || true)
  class=${memo%%$'\t'*}
  case "$class" in parked|terminal) printf 'cached' ;; *) printf 'force' ;; esac
}

fm_lifecycle_identity_prefix() {  # <identity>
  local suffix=${1##*:}
  printf '%.8s' "$suffix"
}

fm_surfaced_state() {  # <task> <identity> [state]
  local task=$1 identity=$2 state=${3:-} root path line recorded epoch extra memo class _memo_identity _memo_epoch now window
  [ "$identity" != none ] || { printf 'none'; return 0; }
  fm_lifecycle_task_valid "$task" || { printf 'pending'; return 0; }
  root=$(fm_lifecycle_state_root "$state")
  path=$(fm_lifecycle_surfaced_path "$task" "$root") || { printf 'pending'; return 0; }
  line=$(cat "$path" 2>/dev/null) || { printf 'pending'; return 0; }
  IFS=$'\t' read -r recorded epoch extra <<EOF
$line
EOF
  [ -z "$extra" ] || { printf 'pending'; return 0; }
  case "$epoch" in ''|*[!0-9]*) printf 'pending'; return 0 ;; esac
  [ "$recorded" = "$identity" ] || { printf 'pending'; return 0; }

  memo=$(fm_lifecycle_memo_read "$task" "$root" 2>/dev/null || true)
  if [ -n "$memo" ]; then
    IFS=$'\t' read -r class _memo_identity _memo_epoch <<EOF
$memo
EOF
    if [ "$class" = parked ]; then
      window=${FM_PAUSE_RESURFACE_SECS:-$FM_PAUSE_RESURFACE_SECS_DEFAULT}
      case "$window" in ''|*[!0-9]*) window=$FM_PAUSE_RESURFACE_SECS_DEFAULT ;; esac
      now=$(fm_lifecycle_epoch)
      [ $((now - epoch)) -lt "$window" ] || { printf 'pending'; return 0; }
    fi
  fi
  printf 'surfaced'
}

fm_mark_surfaced() {  # <task> <identity> [state]
  local task=$1 identity=$2 state=${3:-} path epoch
  [ "$identity" != none ] || return 1
  case "$identity" in decision:*|run:parked:*|run:terminal:*|status:*) ;; *) return 2 ;; esac
  path=$(fm_lifecycle_surfaced_path "$task" "$state") || return
  epoch=$(fm_lifecycle_epoch)
  fm_lifecycle_atomic_write "$path" "$identity"$'\t'"$epoch"
}
