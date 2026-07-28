#!/usr/bin/env bash
# Shared owner of the watcher's native push-transition escalation.
#
# The watcher and event-wait smoke tests source this library instead of loading
# the whole watcher to obtain handle_push_transition. Its source list is limited
# to the four production boundaries the transition handler actually calls.

FM_PUSH_TRANSITION_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=bin/fm-wake-lib.sh
. "$FM_PUSH_TRANSITION_LIB_DIR/fm-wake-lib.sh"
# shellcheck source=bin/fm-classify-lib.sh
. "$FM_PUSH_TRANSITION_LIB_DIR/fm-classify-lib.sh"
# shellcheck source=bin/fm-backend.sh
. "$FM_PUSH_TRANSITION_LIB_DIR/fm-backend.sh"
# shellcheck source=bin/fm-transition-lib.sh
. "$FM_PUSH_TRANSITION_LIB_DIR/fm-transition-lib.sh"

TRIAGE_LOG="$STATE/.watch-triage.log"
TRIAGE_LOG_MAX_BYTES=${FM_WATCH_TRIAGE_LOG_MAX_BYTES:-262144}

# Append one bounded best-effort line for an absorbed supervision event.
triage_log() {
  local sz
  printf '[%s] %s\n' "$(date '+%Y-%m-%dT%H:%M:%S%z')" "$1" >> "$TRIAGE_LOG" 2>/dev/null || return 0
  sz=$(wc -c < "$TRIAGE_LOG" 2>/dev/null | tr -d '[:space:]')
  case "$sz" in ''|*[!0-9]*) return 0 ;; esac
  if [ "$sz" -ge "$TRIAGE_LOG_MAX_BYTES" ]; then
    tail -n 2000 "$TRIAGE_LOG" > "$TRIAGE_LOG.tmp" 2>/dev/null && mv -f "$TRIAGE_LOG.tmp" "$TRIAGE_LOG" 2>/dev/null
    rm -f "$TRIAGE_LOG.tmp" 2>/dev/null || true
  fi
}

# Exit after reporting one actionable wake. Tests override this callback.
wake() {
  case "$1" in
    heartbeat*) echo $(( $(cat "$STATE/.heartbeat-streak" 2>/dev/null || echo 0) + 1 )) > "$STATE/.heartbeat-streak" ;;
    *) echo 0 > "$STATE/.heartbeat-streak" ;;
  esac
  echo "$1"
  exit 0
}

_hb_surfaced_path() {
  printf '%s/.hb-surfaced-%s' "$STATE" "$(printf '%s' "$1" | tr ':/.' '___')"
}

_hb_decision_surfaced_path() {  # <stream-id>.<instance>
  local occurrence=$1 stream instance
  stream=${occurrence%%.*}
  instance=${occurrence#*.}
  [ "${#stream}" -eq 32 ] && [ "${#instance}" -eq 16 ] || return 1
  case "$stream$instance" in *[!a-f0-9]*) return 1 ;; esac
  printf '%s/.hb-surfaced-decision-%s' "$STATE" "$occurrence"
}

decision_occurrence_is_surfaced() {  # <stream-id>.<instance>
  local occurrence=$1 path
  path=$(_hb_decision_surfaced_path "$occurrence") || return 1
  [ "$(cat "$path" 2>/dev/null || true)" = "$occurrence" ]
}

mark_decision_occurrence_surfaced() {  # <stream-id>.<instance>
  local occurrence=$1 path
  path=$(_hb_decision_surfaced_path "$occurrence") || return 1
  printf '%s' "$occurrence" > "$path"
}

pending_open_decisions() {  # <status-file>
  local f=$1 key occurrence summary
  while IFS=$'\t' read -r key occurrence summary || [ -n "$key" ]; do
    [ -n "$key" ] || continue
    decision_occurrence_is_surfaced "$occurrence" && continue
    printf '%s\t%s\t%s\n' "$key" "$occurrence" "$summary"
  done <<EOF
$(status_open_token_needs_decisions "$f")
EOF
}

enqueue_pending_open_decisions() {  # <status-file>
  local f=$1 key occurrence summary found=1 payload
  while IFS=$'\t' read -r key occurrence summary || [ -n "$key" ]; do
    [ -n "$key" ] || continue
    payload="decision: $(basename "$f") [key=$key] [occurrence=$occurrence]: $summary"
    fm_wake_append decision "$occurrence" "$payload" || return 2
    mark_decision_occurrence_surfaced "$occurrence" || return 2
    found=0
  done <<EOF
$(pending_open_decisions "$f")
EOF
  return "$found"
}

# Record a captain-relevant status after its durable wake has been enqueued.
mark_surfaced() {  # <status-file>
  local f=$1 task last
  task=$(basename "$f"); task="${task%.status}"
  last=$(last_status_line "$f")
  [ -n "$last" ] || return 0
  status_is_captain_relevant "$last" || return 0
  printf '%s' "$last" > "$(_hb_surfaced_path "$task")"
}

# Act on a fresh actionable transition from a push-capable backend.
handle_push_transition() {  # <backend> <session> <record>
  local backend=$1 session=$2 record=$3 pane_id to window task reason
  pane_id=$(fm_transition_pane_id "$record")
  to=$(fm_transition_to_status "$record")
  [ -n "$pane_id" ] || { sleep 1; return; }
  window="$session:$pane_id"
  task=$(window_to_task "$window" "$STATE")
  if status_is_paused "$(last_status_line "$STATE/$task.status")"; then
    triage_log "absorbed push $to (declared pause, awaiting external): $window"
    fm_backend_commit_transition "$backend" "$STATE" "$session" "$record" || exit 1
    return
  fi
  reason="stale: $window (herdr: agent $to - waiting on human, escalated immediately, not via wedge timer)"
  fm_wake_append stale "$window" "$reason" || exit 1
  fm_backend_commit_transition "$backend" "$STATE" "$session" "$record" || exit 1
  mark_surfaced "$STATE/$task.status"
  wake "$reason"
}
