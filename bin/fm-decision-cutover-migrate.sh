#!/usr/bin/env bash
# Bounded, explicitly invoked migration of one home's legacy decision histories
# onto the token-era answer-correlation authority.
#
# Background. bin/fm-classify-lib.sh is the single owner of the decision data
# format and its state machine, including the one-time
# "[fm-decision-answer-cutover:v1 stream=<id>]" marker and what it means: an
# opening recorded BEFORE the marker keeps legacy plain keyed closure even when
# its resolution arrives later, while every opening recorded after it requires a
# correlated answer token. Read that header first. This script adds no format
# knowledge of its own: it derives no instance identifier, parses no decision
# line by hand, and reaches every judgement through that owner's helpers.
#
# The gap this closes. fm_decision_cutover_ensure_status deliberately marks a
# status stream only when it CREATES the file, so a task whose status file
# already existed when its current-instruction brief was scaffolded stays on
# legacy authority forever. That is the only history this migration upgrades,
# and it upgrades it the only way an append-only log can be upgraded safely: by
# appending the marker at the end. Every existing byte, every settled decision,
# and every still-open legacy opening keeps the exact meaning it had, because
# the fold reads the marker positionally and everything already written stays
# before it.
#
# Authority is explicit and bounded, by construction:
#   - It runs only when someone runs it. No session start, bootstrap, spawn, or
#     watcher path calls it, and it is not a fleet rollout controller.
#   - It acts on exactly ONE home, the one named by FM_HOME. It never reads the
#     secondmate registry, never walks into another home, and never infers a
#     target. A secondmate home is migrated by invoking this script with that
#     home's FM_HOME. That is also what keeps two homes from ever being
#     conflated: identity is per stream, and each upgraded stream mints its own
#     fresh random identity, so no two streams in any home share one.
#   - It reports by default and mutates only with --apply.
#
# It refuses rather than guesses. A stream is upgraded only when every one of
# the eligibility tests below passes; anything ambiguous, unreadable, or not
# provably safe is refused BY NAME in the report, so the set of histories it
# declined is explicit rather than implied by silence. It never rewrites,
# truncates, reorders, or removes a byte, never edits an answer record, and
# never writes a resolution: a path that only ever appends one marker line
# cannot fabricate a captain answer.
#
# Stale queued input cannot close a future decision, and that is structural
# rather than defended. An opening's instance identifier comes from its physical
# position in an append-only stream, so positions strictly increase and no later
# opening can ever reuse an earlier one. A token minted before the migration
# therefore embeds an instance no post-migration opening can hold, and the
# owner's exact three-field match rejects it.
#
# Idempotence and crash safety are the marker's own, not a side ledger. The
# marker IS the migrated state, so a rerun sees an already-marked stream and
# reports it as already current. The append is a single small O_APPEND write,
# so a concurrent worker append can never be lost the way a copy-and-replace
# would lose it; this migration therefore needs no watcher pause, unlike the
# executable-file migration in bin/fm-pr-check-migrate.sh. An interrupted write
# cannot be silently compounded either: a leftover partial marker fails marker
# validation, is detected as an ambiguous marker line, and is refused instead of
# being marked again or repaired by destroying bytes.
#
# The only thing it writes besides the marker is a private best-effort record of
# "<task><TAB><stream id>" per upgraded stream in
# state/.decision-cutover-migration.log. That log is an operator diagnostic, not
# an input: nothing reads it back, no eligibility test consults it, and a failed
# write never turns a landed marker into a reported failure, because the marker
# in the stream is already the whole migrated state.
#
# Usage: fm-decision-cutover-migrate.sh [--apply] [--task <id>]
#   (no flags)     report what would change; makes no modification at all
#   --apply        append the marker to every eligible stream
#   --task <id>    restrict to one task's stream instead of the whole home
# Exit: 0 every stream reached a definite accounted outcome (refusals included);
#       1 the home is unusable or a stream could not be accounted for;
#       2 invalid usage.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
LOG="$STATE/.decision-cutover-migration.log"

# shellcheck source=bin/fm-classify-lib.sh
. "$SCRIPT_DIR/fm-classify-lib.sh"
# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"

# The literal the current brief scaffold writes into a worker's answer protocol
# (bin/fm-brief.sh owns that prose). Its presence in a task's instructions is
# the evidence that the worker was launched knowing it must copy an answer token
# onto its closing line; its absence is the evidence that the worker cannot.
BRIEF_ANSWER_PROTOCOL='[ans='

APPLY=0
ONLY_TASK=

usage() {
  echo "usage: fm-decision-cutover-migrate.sh [--apply] [--task <id>]" >&2
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --apply) APPLY=1 ;;
    --task)
      shift
      [ "$#" -gt 0 ] || { usage; exit 2; }
      [ -z "$ONLY_TASK" ] || { usage; exit 2; }
      ONLY_TASK=$1
      case "$ONLY_TASK" in
        ''|.|..|-*|*[!A-Za-z0-9._-]*)
          echo "DECISION_CUTOVER: task id '$ONLY_TASK' is not a valid task slug" >&2
          exit 2 ;;
      esac
      ;;
    --help|-h) usage; exit 0 ;;
    *) usage; exit 2 ;;
  esac
  shift
done

umask 077

if [ ! -d "$STATE" ] || [ -L "$STATE" ]; then
  echo "DECISION_CUTOVER: '$STATE' is not an ordinary private state directory of this home; no history was inspected" >&2
  exit 1
fi
STATE_DEVICE=$(fm_pr_file_device "$STATE") || STATE_DEVICE=
if [ -z "$STATE_DEVICE" ]; then
  echo "DECISION_CUTOVER: could not read the identity of '$STATE'; no history was inspected" >&2
  exit 1
fi

# --- eligibility ------------------------------------------------------------
# Every test below answers one question: can appending a single marker line to
# the end of this file change the meaning of anything already in it, or land in
# a stream whose identity this home cannot vouch for? Any "yes" or "cannot tell"
# refuses.

# 0 when the stream is an ordinary private file of this state directory: a real
# file, readable, not a symlink, not a hard link shared with somewhere else, and
# on this device. Anything else is a stream whose identity cannot be trusted -
# a symlink or extra hard link could carry the append into another home's or
# another task's history - so it is never appended to.
stream_identity_ok() {  # <status-file>
  local f=$1
  [ -f "$f" ] && [ ! -L "$f" ] && [ -r "$f" ] || return 1
  [ "$(fm_pr_file_link_count "$f")" = 1 ] || return 1
  [ "$(fm_pr_file_device "$f")" = "$STATE_DEVICE" ]
}

# 0 when the file ends with a newline, or is empty. Appending to a file whose
# last line has no terminator would splice the marker onto that line, rewriting
# an existing status event - never allowed.
stream_ends_cleanly() {  # <status-file>
  local f=$1
  [ -s "$f" ] || return 0
  [ -z "$(tail -c 1 "$f")" ]
}

# 0 when some line carries the cutover marker prefix but is NOT a valid marker:
# a truncated marker from an interrupted append, a hand-edited one, or a status
# note that happens to start with the prefix. Marking such a stream would leave
# two conflicting claims about where its authority boundary sits, so it is
# refused and left byte-for-byte intact for recovery.
stream_has_ambiguous_marker() {  # <status-file>
  local f=$1 line prefix
  prefix=$FM_CLASSIFY_DECISION_CUTOVER_MARK_PREFIX_DEFAULT
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      "$prefix"*) ;;
      *) continue ;;
    esac
    fm_decision_marker_line_id "$line" >/dev/null && continue
    return 0
  done < "$f"
  return 1
}

# 0 when the owner's fold still holds an open needs-decision. Such a request is
# already being tracked and escalated under the legacy protocol. Marking would
# not change how it closes - it sits before the marker and keeps legacy closure -
# but it WOULD change which wake surfaces carry it, so the migration leaves a
# live escalation entirely alone rather than reshaping the fleet's view of a
# decision the captain may already be holding. Only needs-decision matters here:
# an open blocked event closes on a plain keyed resolution on either side of the
# marker, so the marker cannot affect it.
stream_has_open_decision() {  # <status-file>
  status_has_open_needs_decision "$1"
}

# 0 when this task's instructions prove its worker was launched with the
# correlated-answer protocol. A worker running on pre-cutover instructions was
# never told to copy an answer token onto its resolved line, so a decision it
# opened after the marker could never be closed by it and would resurface
# forever. That is the "currently active worker launched from old instructions"
# case, and it is refused, not upgraded. Missing instructions are not evidence
# of safety either: with no brief there is nothing to prove the protocol is
# understood, so that stream is refused the same way.
stream_worker_knows_protocol() {  # <task-id>
  local brief="$DATA/$1/brief.md"
  [ -f "$brief" ] && [ ! -L "$brief" ] && [ -r "$brief" ] || return 1
  grep -Fq -- "$BRIEF_ANSWER_PROTOCOL" "$brief" 2>/dev/null
}

# --- reporting --------------------------------------------------------------

TOTAL=0
UPGRADED=0
PENDING=0
CURRENT=0
REFUSED=0
UNACCOUNTED=0

report() {  # <task> <outcome> [<detail>]
  local task=$1 outcome=$2 detail=${3:-}
  if [ -n "$detail" ]; then
    echo "DECISION_CUTOVER: $task $outcome ($detail)"
  else
    echo "DECISION_CUTOVER: $task $outcome"
  fi
}

# Append one durable operator breadcrumb for an applied upgrade. The marker in
# the stream remains the authoritative migrated state, so a log that cannot be
# written never blocks or reverses an upgrade that already succeeded.
record_applied() {  # <task> <stream-id>
  [ ! -L "$LOG" ] || return 0
  printf '%s\t%s\n' "$1" "$2" >> "$LOG" 2>/dev/null || true
}

# --- one stream -------------------------------------------------------------
# Returns non-zero only when a stream could not be accounted for, which is a
# stop-and-investigate result. An ordinary refusal is a definite outcome and
# returns 0.

migrate_stream() {  # <status-file>
  local f=$1 task marker stream
  task=$(basename "$f")
  task=${task%.status}
  TOTAL=$((TOTAL + 1))

  if ! stream_identity_ok "$f"; then
    REFUSED=$((REFUSED + 1))
    report "$task" refused "not a readable ordinary private file of this home's state"
    return 0
  fi
  if stream=$(fm_decision_stream_id "$f"); then
    CURRENT=$((CURRENT + 1))
    report "$task" already-current "stream $stream"
    return 0
  fi
  if stream_has_ambiguous_marker "$f"; then
    REFUSED=$((REFUSED + 1))
    report "$task" refused "an existing line claims the cutover marker but is not a valid one"
    return 0
  fi
  if ! stream_ends_cleanly "$f"; then
    REFUSED=$((REFUSED + 1))
    report "$task" refused "last event has no line terminator; appending would alter it"
    return 0
  fi
  if stream_has_open_decision "$f"; then
    REFUSED=$((REFUSED + 1))
    report "$task" refused "an open decision is still tracked under the legacy protocol"
    return 0
  fi
  if ! stream_worker_knows_protocol "$task"; then
    REFUSED=$((REFUSED + 1))
    report "$task" refused "instructions do not carry the correlated-answer protocol"
    return 0
  fi

  if [ "$APPLY" -ne 1 ]; then
    PENDING=$((PENDING + 1))
    report "$task" would-upgrade
    return 0
  fi

  marker=$(fm_decision_status_marker) || {
    UNACCOUNTED=$((UNACCOUNTED + 1))
    report "$task" refused "no stream identity could be minted; nothing was changed"
    return 1
  }
  if ! printf '%s\n' "$marker" >> "$f" 2>/dev/null; then
    UNACCOUNTED=$((UNACCOUNTED + 1))
    report "$task" refused "the marker could not be appended"
    return 1
  fi
  # Confirm from the file itself, never from the value we meant to write.
  if ! stream=$(fm_decision_stream_id "$f"); then
    UNACCOUNTED=$((UNACCOUNTED + 1))
    report "$task" refused "the appended marker did not validate; history is preserved for recovery"
    return 1
  fi
  UPGRADED=$((UPGRADED + 1))
  record_applied "$task" "$stream"
  report "$task" upgraded "stream $stream"
  return 0
}

# --- sweep ------------------------------------------------------------------

RC=0
if [ -n "$ONLY_TASK" ]; then
  TARGET="$STATE/$ONLY_TASK.status"
  if [ ! -e "$TARGET" ] && [ ! -L "$TARGET" ]; then
    echo "DECISION_CUTOVER: no decision history for task '$ONLY_TASK' in this home" >&2
    exit 1
  fi
  migrate_stream "$TARGET" || RC=1
else
  for status in "$STATE"/*.status; do
    [ -e "$status" ] || [ -L "$status" ] || continue
    migrate_stream "$status" || RC=1
  done
fi

if [ "$TOTAL" -eq 0 ]; then
  echo "DECISION_CUTOVER: no decision histories in this home"
  exit "$RC"
fi

if [ "$APPLY" -eq 1 ]; then
  echo "DECISION_CUTOVER: $TOTAL inspected, $UPGRADED upgraded, $CURRENT already current, $REFUSED refused, $UNACCOUNTED unaccounted"
else
  echo "DECISION_CUTOVER: $TOTAL inspected, $PENDING would upgrade, $CURRENT already current, $REFUSED refused, $UNACCOUNTED unaccounted (report only; rerun with --apply to change anything)"
fi
exit "$RC"
