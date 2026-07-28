#!/usr/bin/env bash
# Shared wake classifier: the common source of truth for captain-relevant status
# tests, declared-external-wait vocabulary, and the working/paused absorb
# classification that makes no-verb signal and stale-pane wakes safe to absorb.
# Sourced by BOTH the always-on watcher
# (bin/fm-watch.sh) and the away-mode daemon (bin/fm-supervise-daemon.sh) so the
# overlapping triage policy lives in one place instead of two copies that can
# drift apart.
#
# Most functions are pure, side-effect-free reads of status files: each takes
# what it needs as arguments and touches no globals beyond the optional
# FM_CAPTAIN_RE override. Consumers layer their own dedup/marker state on top (the
# daemon keeps its escalation-digest seen-markers; the watcher keeps its .seen-*
# signatures).
#
# The one exception is the absorb classification (crew_absorb_class and its
# working/paused wrappers). It is NOT a pure status-file read: it reuses
# bin/fm-crew-state.sh, which may make a bounded no-mistakes call, to decide
# whether a crew that just stopped its turn or went stale is working, deliberately
# paused, or neither. Callers run it ONLY on no-verb signal handling and first
# sighting of a stale hash, never on every wake, so the per-wake triage stays
# cheap.

# Directory of this library, used to locate the sibling fm-crew-state.sh reader.
# Resolved at source time from BASH_SOURCE so it works whether sourced by a
# bin/ script (which sets its own SCRIPT_DIR) or directly by a test.
_FM_CLASSIFY_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd 2>/dev/null)" || _FM_CLASSIFY_LIB_DIR="."

# The crew current-state reader used for the "provably working" decision.
# Overridable so tests can stub the run-step/pane verdict without a real worktree
# or no-mistakes install; absent, it points at the real sibling script.
FM_CREW_STATE_BIN="${FM_CREW_STATE_BIN:-$_FM_CLASSIFY_LIB_DIR/fm-crew-state.sh}"

# Captain-relevant status verbs. A status line carrying any of these is work
# firstmate must see. Lines without these verbs are no-verb signals: the watcher
# absorbs them only with positive provably-working evidence, while the daemon uses
# its away-mode classification. FM_CAPTAIN_RE overrides the whole set when a home
# needs a custom verb vocabulary; absent, this default applies.
#
# Free-text tokens (PR ready, checks green, ready in branch, merged) exist only for
# legacy lines that lack a standard terminal verb. status_is_captain_relevant is
# verb-aware: a nonterminal working: or paused: line never becomes captain-relevant
# merely because its prose contains one of those tokens (for example
# "working: rebased onto merged #76").
FM_CLASSIFY_CAPTAIN_RE_DEFAULT='done:|needs-decision:|blocked:|failed:|PR ready|checks green|ready in branch|merged'

# The deliberate-external-wait verb. A crew (or firstmate steering it) appends
#   paused: <reason>
# to declare it is intentionally idling on a KNOWN external dependency - an
# upstream release, a vendor rate-limit reset, a scheduled window. Unlike
# `blocked:` (stuck, firstmate must help) an idle `paused:` pane is EXPECTED, so
# the stale path absorbs it instead of escalating a possible wedge. It is
# deliberately NOT in the captain-relevant set above: a pause is a "stop
# wedge-nagging this idle pane" signal, not work to keep surfacing. This constant
# is the ONE definition of the verb; both the watcher and the daemon read it here
# (status_is_paused) rather than hardcoding the literal, so the vocabulary cannot
# drift between the two consumers. FM_CLASSIFY_PAUSED_VERB overrides it.
FM_CLASSIFY_PAUSED_VERB_DEFAULT='paused'

# Bounded re-surface cadence for a declared pause or a dead-agent captain hold.
# Far longer than the wedge threshold (FM_STALE_ESCALATE_SECS, default 240s), it
# avoids nagging a deliberate wait while ensuring a forgotten hold cannot rot
# invisibly - it re-surfaces once for a recheck every window. One hour by default;
# both consumers read FM_PAUSE_RESURFACE_SECS with this default so the cadence has
# one owner.
# shellcheck disable=SC2034 # Read by the watcher and daemon (fm-watch.sh, fm-supervise-daemon.sh), not this lib.
FM_PAUSE_RESURFACE_SECS_DEFAULT=3600

# The resolution verb and durable-backlog-transfer verb that CLOSE a keyed
# status decision opened by needs-decision or blocked. See status_open_decisions
# below for the status-fold contract. The transfer verb is written only after
# fm-decision-hold.sh has verified the corresponding captain-held backlog item.
FM_CLASSIFY_RESOLVE_VERB_DEFAULT='resolved'
FM_CLASSIFY_CAPTAIN_HELD_VERB_DEFAULT='captain-held'

# The verb firstmate uses when it issues a correlated answer to an open decision.
# It names the decision-answer message shape owned by bin/fm-send.sh --decision;
# it is not a status verb and never appears in a status stream.
FM_CLASSIFY_DECISION_VERB_DEFAULT='decision'

# Return the last non-blank line of a status file (empty if missing/blank).
last_status_line() {
  local f=$1
  [ -e "$f" ] || return 0
  grep -v '^[[:space:]]*$' "$f" 2>/dev/null | tail -1
}

# 0 if the given (last) status line's leading verb is a real terminal captain verb
# (done, needs-decision, blocked, failed). Free-text tokens alone never count here;
# callers that need legacy free-text matching use status_is_captain_relevant.
status_is_terminal_verb() {
  local line=$1 verb
  [ -n "$line" ] || return 1
  verb=$(status_line_verb "$line")
  case "$verb" in
    done|needs-decision|blocked|failed) return 0 ;;
    *) return 1 ;;
  esac
}

# 0 if the given (last) status line matches a captain-relevant verb.
# Verb-aware by default: terminal verbs always match; nonterminal progress verbs
# (working, resolved, captain-held) and paused never match from free-text prose;
# only lines without those leading verbs may still match free-text tokens for
# legacy bare lines such as "merged" or "PR ready".
status_is_captain_relevant() {
  local line=$1 verb
  [ -n "$line" ] || return 1
  status_is_paused "$line" && return 1
  verb=$(status_line_verb "$line")
  case "$verb" in
    working|resolved|captain-held|"${FM_CLASSIFY_PAUSED_VERB:-$FM_CLASSIFY_PAUSED_VERB_DEFAULT}")
      return 1
      ;;
  esac
  if [ -z "${FM_CAPTAIN_RE+x}" ]; then
    case "$verb" in
      done|needs-decision|blocked|failed) return 0 ;;
    esac
  fi
  printf '%s' "$line" | grep -qiE "${FM_CAPTAIN_RE:-$FM_CLASSIFY_CAPTAIN_RE_DEFAULT}"
}

# 0 if a status line's leading verb is the pause verb (paused: <reason>). A pure
# read of the line itself, so the daemon's classify_stale can reuse the last line
# it already read without a fm-crew-state.sh call. Matches only the verb before the
# first colon, so a reason mentioning "paused" elsewhere does not false-match.
status_is_paused() {  # <status-line>
  local line=$1 verb
  [ -n "$line" ] || return 1
  verb=$(status_line_verb "$line")
  [ "$verb" = "${FM_CLASSIFY_PAUSED_VERB:-$FM_CLASSIFY_PAUSED_VERB_DEFAULT}" ]
}

# 0 if a status line declares either an external-wait pause or a verified
# captain-held transfer.
# Both declarations can intentionally leave an exited crew's endpoint idle, so
# the watcher applies its bounded pause cadence when agent death confirms that
# no live decision gate is being silenced.
status_is_paused_or_captain_held() {  # <status-line>
  local line=$1 verb
  status_is_paused "$line" && return 0
  [ -n "$line" ] || return 1
  verb=$(status_line_verb "$line")
  [ "$verb" = "${FM_CLASSIFY_CAPTAIN_HELD_VERB:-$FM_CLASSIFY_CAPTAIN_HELD_VERB_DEFAULT}" ]
}

# --- durable keyed decisions ------------------------------------------------
#
# The status stream is an append-only EVENT log. Reading it last-event-wins
# (last_status_line above) cannot represent "an earlier decision is still open
# after a later, unrelated event": a subsequent done/paused/working line silently
# masks a still-open needs-decision. status_open_decisions is the ONE authoritative
# statement of the status-fold contract that fixes this - a needs-decision/blocked
# line OPENS a keyed decision, and only an explicit resolution or a verified
# captain-held backlog transfer referencing that key CLOSES it; a later unrelated
# terminal line never clears an open captain decision.
#
# Decision key grammar (backward-compatible with the existing "<verb>: <note>"
# format): an OPTIONAL "[key=<slug>]" token sits between the verb and the colon,
#   needs-decision [key=api-shape]: <summary>
#   resolved       [key=api-shape]: <how it was decided>
# A line with no token uses the key "default", preserving the historical
# one-open-decision-per-task behavior (a bare "resolved:" closes "default").
# A key-like token after the colon is invalid rather than a default-key event,
# so the late form can neither open nor close the wrong decision silently.
# The three parsers are pure reads of a single line; the verb parser strips any
# key token before the colon so the leading word is recovered cleanly.
#
# Answer correlation (the authority-ordering boundary): a needs-decision asks for
# authority the worker does not hold, so its closure additionally requires an
# "[ans=<token>]" token placed AFTER the key token,
#   needs-decision [key=api-shape]: <summary>
#   resolved [key=api-shape] [ans=00000000000000013f2a91c07b4d6e58]: <how it was decided>
# The token is minted by bin/fm-send.sh --decision, which refuses to mint one
# until that keyed request is already open, and is recorded next to the status
# stream in "<task>.decision-answers". A resolution closes the request only when
# its token was minted for that key AND for that request instance, so a generic
# command, an unkeyed message, and any input composed before the request opened
# can never become its approval. An uncorrelated resolution leaves the request
# open, which surfaces it rather than silently advancing past it. Closure of a
# blocked line is unchanged: a blocker clears by being fixed, not by authority.
# The verified captain-held transfer written by bin/fm-decision-hold.sh is also
# unchanged, and remains the durable path for a request whose answer never
# arrived through the correlated channel.
#
# Each opening receives an immutable instance identifier from its physical
# position in this append-only stream. The identifier is included in the answer
# token, while a random suffix makes the complete token unguessable. Keys and
# summaries remain human-readable grouping rather than instance authority.
status_line_verb() {  # <status-line> -> leading verb word
  local v=${1%%:*}
  v=${v%%\[key=*}
  v=${v%%\[ans=*}
  v=${v#"${v%%[![:space:]]*}"}
  v=${v%"${v##*[![:space:]]}"}
  printf '%s' "$v"
}
status_line_note() {  # <status-line> -> text after the first colon, trimmed
  case "$1" in
    *:*) local n=${1#*:}; printf '%s' "${n#"${n%%[![:space:]]*}"}" ;;
    *) printf '%s' "$1" ;;
  esac
}
_fm_decision_key() {  # <status-line> -> key slug, or "default" when no token
  local line=$1 prefix=${1%%:*} k
  case "$prefix" in
    *\[key=*\]*)
      k=${prefix#*\[key=}
      k=${k%%\]*}
      case "$k" in
        ''|*[!A-Za-z0-9._-]*) return 1 ;;
        *) printf '%s' "$k" ;;
      esac
      ;;
    *)
      case "$line" in
        *\[key=*) return 1 ;;
        *) printf 'default' ;;
      esac
      ;;
  esac
}
# Print the answer token of a status line, or nothing when it carries none.
# The token sits after the key token, so a line that carries "[ans=...]" without a
# preceding "[key=...]" is malformed and prints nothing rather than correlating.
_fm_decision_answer() {  # <status-line> -> answer token, or empty
  local prefix=${1%%:*} a
  case "$prefix" in
    *\[key=*\]*\[ans=*\]*) : ;;
    *) return 0 ;;
  esac
  a=${prefix#*\[ans=}
  a=${a%%\]*}
  case "$a" in
    ''|*[!A-Za-z0-9]*) return 0 ;;
    *) printf '%s' "$a" ;;
  esac
}

# Format one opening-event position as the fixed-width identifier carried by
# every answer token for that occurrence.
fm_decision_instance_id() {  # <physical-line-number> -> 16 hex chars
  local position=$1
  case "$position" in
    ''|*[!0-9]*) return 1 ;;
  esac
  [ "$position" -gt 0 ] 2>/dev/null || return 1
  printf '%016x' "$position"
}

# Print the answer-record file that pairs with a status file. fm-send writes one
# record per minted token; the fold reads it to decide whether a resolution was
# correlated. Kept beside the status stream so one task's records travel, and are
# torn down, with that task's other per-task state.
fm_decision_answers_file() {  # <status-file> -> answer-record file
  printf '%s' "${1%.status}.decision-answers"
}

# 0 when <token> was minted for exactly this opening occurrence. A record line is
# "<token>\t<key>\t<instance>"; the token embeds the same instance identifier,
# and all three fields must match.
fm_decision_answer_matches() {  # <answers-file> <token> <key> <instance>
  local f=$1 token=$2 key=$3 instance=$4 rt rk ri
  [ "${#instance}" -eq 16 ] || return 1
  [ "${#token}" -eq 32 ] || return 1
  case "$instance$token" in
    *[!a-f0-9]*) return 1 ;;
  esac
  [ "${token:0:16}" = "$instance" ] || return 1
  [ -f "$f" ] || return 1
  while IFS=$'\t' read -r rt rk ri || [ -n "$rt" ]; do
    [ "$rt" = "$token" ] || continue
    [ "$rk" = "$key" ] || continue
    [ "$ri" = "$instance" ] || continue
    return 0
  done < "$f"
  return 1
}

# Mint one answer token: the fixed-width opening instance followed by 16 random
# lowercase hex characters from the best source this host has.
fm_decision_mint_answer_token() {  # <instance>
  local instance=${1:-} raw=''
  [ "${#instance}" -eq 16 ] || return 1
  case "$instance" in
    *[!a-f0-9]*) return 1 ;;
  esac
  raw=$(openssl rand -hex 8 2>/dev/null || true)
  case "$raw" in
    [a-f0-9][a-f0-9][a-f0-9][a-f0-9][a-f0-9][a-f0-9][a-f0-9][a-f0-9]*) : ;;
    *)
      raw=$(printf '%s' "$$-$(date +%s 2>/dev/null)-$RANDOM$RANDOM$RANDOM" \
        | shasum -a 256 2>/dev/null | awk '{print $1}')
      ;;
  esac
  raw=$(printf '%s' "$raw" | tr 'A-F' 'a-f' | tr -cd 'a-f0-9' | cut -c1-16)
  [ "${#raw}" -eq 16 ] || return 1
  printf '%s%s' "$instance" "$raw"
}

# Record a minted token against the open request it answers, then print it.
# Called only after the caller has confirmed that request is open, which is what
# makes an answer necessarily later than its request.
fm_decision_record_answer() {  # <answers-file> <token> <key> <instance>
  local f=$1 token=$2 key=$3 instance=$4 dir
  [ "${#instance}" -eq 16 ] || return 1
  [ "${#token}" -eq 32 ] || return 1
  case "$instance$token" in
    *[!a-f0-9]*) return 1 ;;
  esac
  [ "${token:0:16}" = "$instance" ] || return 1
  dir=$(dirname "$f")
  [ -d "$dir" ] || return 1
  printf '%s\t%s\t%s\n' "$token" "$key" "$instance" >> "$f" \
    || return 1
  printf '%s' "$token"
}

# Print the message shape that carries an authorized answer to a worker. The
# worker copies the same key and token onto its closing resolved line.
fm_decision_answer_message() {  # <key> <token> <text>
  printf '%s [key=%s] [ans=%s]: %s' \
    "${FM_CLASSIFY_DECISION_VERB:-$FM_CLASSIFY_DECISION_VERB_DEFAULT}" "$1" "$2" "$3"
}

# Drop the record for <key> from a newline-terminated
# "<key>\t<verb>\t<instance>\t<note>" set.
# Portable (no associative arrays) so the fold runs on bash 3.2 as well as 4+.
_fm_decision_drop() {  # <open-set> <key>
  local set=$1 key=$2 line out=''
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    case "$line" in
      "$key"$'\t'*) : ;;
      *) out="${out}${line}"$'\n' ;;
    esac
  done <<EOF
$set
EOF
  printf '%s' "$out"
}
# Print the "<key>\t<verb>\t<instance>\t<note>" record currently held for
# <key>, or nothing.
_fm_decision_get() {  # <open-set> <key>
  local set=$1 key=$2 line
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    case "$line" in
      "$key"$'\t'*) printf '%s' "$line"; return 0 ;;
    esac
  done <<EOF
$set
EOF
  return 1
}
# Fold the WHOLE status stream into the set of decisions still open. Prints one
# TAB-separated "<key>\t<verb>\t<summary>" line per still-open decision, in
# most-recently-opened-last order; prints nothing when none are open.
# "--with-instance" inserts the occurrence identifier before the summary for the
# answer-issuance boundary. Pure read of the file and of the paired answer
# records, no globals beyond the optional FM_CLASSIFY_RESOLVE_VERB override. This
# is the durable open-set the fleet snapshot and any point-in-time consumer must
# use instead of trusting the last status line.
#
# A needs-decision request additionally requires a correlated answer token to
# close (see the answer-correlation contract above), so an uncorrelated
# resolution leaves it open. A blocked line still closes on a plain keyed
# resolution: clearing a blocker is work, not an exercise of authority.
status_open_decisions() {  # <status-file> [--with-instance]
  local f=$1 view=${2:-} line verb key note resolve held open='' stripped
  local answers held_rec held_fields held_verb held_instance ans
  local position=0 instance out_key out_verb _out_instance out_note
  case "$view" in
    ''|--with-instance) ;;
    *) return 2 ;;
  esac
  [ -f "$f" ] || return 0
  resolve=${FM_CLASSIFY_RESOLVE_VERB:-$FM_CLASSIFY_RESOLVE_VERB_DEFAULT}
  held=${FM_CLASSIFY_CAPTAIN_HELD_VERB:-$FM_CLASSIFY_CAPTAIN_HELD_VERB_DEFAULT}
  answers=$(fm_decision_answers_file "$f")
  while IFS= read -r line || [ -n "$line" ]; do
    position=$((position + 1))
    stripped=${line//[[:space:]]/}
    [ -n "$stripped" ] || continue
    verb=$(status_line_verb "$line")
    key=$(_fm_decision_key "$line") || continue
    case "$verb" in
      needs-decision|blocked)
        note=$(status_line_note "$line")
        instance=$(fm_decision_instance_id "$position") || continue
        open=$(_fm_decision_drop "$open" "$key")
        [ -n "$open" ] && open="${open}"$'\n'
        open="${open}${key}"$'\t'"${verb}"$'\t'"${instance}"$'\t'"${note}"$'\n'
        ;;
      "$resolve")
        # Only a correlated answer closes a request for authority.
        if held_rec=$(_fm_decision_get "$open" "$key"); then
          held_fields=${held_rec#*$'\t'}
          held_verb=${held_fields%%$'\t'*}
          held_fields=${held_fields#*$'\t'}
          held_instance=${held_fields%%$'\t'*}
          if [ "$held_verb" = needs-decision ]; then
            ans=$(_fm_decision_answer "$line")
            fm_decision_answer_matches "$answers" "$ans" "$key" "$held_instance" \
              || continue
          fi
        fi
        open=$(_fm_decision_drop "$open" "$key")
        [ -n "$open" ] && open="${open}"$'\n'
        ;;
      "$held")
        open=$(_fm_decision_drop "$open" "$key")
        [ -n "$open" ] && open="${open}"$'\n'
        ;;
    esac
  done < "$f"
  if [ "$view" = --with-instance ]; then
    printf '%s' "$open"
    return 0
  fi
  while IFS=$'\t' read -r out_key out_verb _out_instance out_note || [ -n "$out_key" ]; do
    [ -n "$out_key" ] || continue
    printf '%s\t%s\t%s\n' "$out_key" "$out_verb" "$out_note"
  done <<EOF
$open
EOF
}

# Fold material routed-work phases in the same keyed event stream.
# A working or declared-pause event opens or replaces one phase for its key.
# A later done, failed, needs-decision, blocked, or resolved event carrying that
# key closes the phase, because it has moved to a terminal or separately tracked
# state.
# A bare legacy event uses the default key, preserving one-phase behavior.
# This fold is evidence about whether a parent event was explicitly superseded.
# It is never authoritative current crew state, and consumers must not let an open
# phase outrank a structured home snapshot or fm-crew-state result.
_fm_status_open_activities_stream() {
  local line verb key note resolve held open='' stripped pause
  resolve=${FM_CLASSIFY_RESOLVE_VERB:-$FM_CLASSIFY_RESOLVE_VERB_DEFAULT}
  held=${FM_CLASSIFY_CAPTAIN_HELD_VERB:-$FM_CLASSIFY_CAPTAIN_HELD_VERB_DEFAULT}
  pause=${FM_CLASSIFY_PAUSED_VERB:-$FM_CLASSIFY_PAUSED_VERB_DEFAULT}
  while IFS= read -r line || [ -n "$line" ]; do
    stripped=${line//[[:space:]]/}
    [ -n "$stripped" ] || continue
    verb=$(status_line_verb "$line")
    key=$(_fm_decision_key "$line") || continue
    case "$verb" in
      working|"$pause")
        note=$(status_line_note "$line")
        open=$(_fm_decision_drop "$open" "$key")
        [ -n "$open" ] && open="${open}"$'\n'
        open="${open}${key}"$'\t'"${verb}"$'\t'"${note}"$'\n'
        ;;
      done|failed|needs-decision|blocked|"$resolve"|"$held")
        open=$(_fm_decision_drop "$open" "$key")
        [ -n "$open" ] && open="${open}"$'\n'
        ;;
    esac
  done
  printf '%s' "$open"
}

status_open_activities() {  # <status-file-or-dash>
  local f=$1
  if [ "$f" = - ]; then
    _fm_status_open_activities_stream
    return 0
  fi
  [ -f "$f" ] || return 0
  _fm_status_open_activities_stream < "$f"
}

# task id from a recorded window target, falling back to the tmux-shaped
# "<session>:fm-<id>" form when no metadata state is available.
window_to_task() {
  local w=$1 state=${2:-${STATE:-${FM_STATE_OVERRIDE:-}}} meta mw mt t
  if [ -n "$state" ]; then
    for meta in "$state"/*.meta; do
      [ -e "$meta" ] || continue
      mw=$(grep '^window=' "$meta" 2>/dev/null | tail -1 | cut -d= -f2- || true)
      mt=$(grep '^terminal=' "$meta" 2>/dev/null | tail -1 | cut -d= -f2- || true)
      [ "$mw" = "$w" ] || [ "$mt" = "$w" ] || continue
      t=$(basename "$meta")
      t=${t%.meta}
      printf '%s' "$t"
      return 0
    done
  fi
  t="${w##*:}"; t="${t#fm-}"; printf '%s' "$t"
}

# 0 (actionable) if ANY status file listed in a "signal:" wake carries a
# captain-relevant last line; 1 otherwise. Pass the space-separated file list that
# follows the "signal:" prefix. Non-.status arguments (e.g. .turn-ended markers,
# which never carry a verb) are skipped. A 1 here is NOT "benign" on its own: a
# no-verb signal (a bare turn-end, a working: note) is only benign when the crew is
# also provably working (signal_crew_provably_working below); otherwise it surfaces.
signal_reason_is_actionable() {  # <file> ...
  local f last
  for f in "$@"; do
    [ -e "$f" ] || continue
    case "$f" in *.status) ;; *) continue ;; esac
    last=$(last_status_line "$f")
    [ -n "$last" ] || continue
    status_is_captain_relevant "$last" && return 0
  done
  return 1
}

# Classify WHY an idle/stale crew MIGHT be safely absorbed instead of surfaced,
# from bin/fm-crew-state.sh's one authoritative current-state line
# ("state: <s> · source: <src> · <detail>"). Prints exactly one token:
#   working - an actively-running no-mistakes step (running/fixing/ci) or a busy
#             pane; the crew is legitimately mid-work on a static-looking pane
#             (e.g. waiting on CI);
#   paused  - the crew's authoritative current state is a declared external-wait
#             pause (paused:), which is EXPECTED to idle;
#   none    - neither, so the wake must surface (a stopped/finished/parked/failed/
#             torn-down/unknown crew, or an unreadable verdict).
# One fm-crew-state.sh read serves BOTH absorb reasons at once. Reading the state
# authoritatively (not the status log) is what keeps run-step precedence: a crew
# that appended paused: but then STARTED a run reports working, never paused.
# NOT a pure read: fm-crew-state.sh may make a bounded no-mistakes call, so callers
# run it only on no-verb signal and first-sighting stale paths, never every wake.
# FM_CREW_STATE_BIN lets tests stub the verdict.
crew_absorb_class() {  # <id>
  local id=$1 line state src
  [ -n "$id" ] || { printf 'none'; return; }
  line=$("$FM_CREW_STATE_BIN" "$id" 2>/dev/null) || true
  case "$line" in state:*) ;; *) printf 'none'; return ;; esac
  state=${line#state: }; state=${state%% *}
  if [ "$state" = paused ]; then printf 'paused'; return; fi
  if [ "$state" = working ]; then
    src=${line#*source: }; src=${src%% *}
    case "$src" in run-step|pane) printf 'working'; return ;; esac
  fi
  printf 'none'
}

# 0 if crew <id> shows POSITIVE evidence it is still working (crew_absorb_class
# reports `working`). This is the "provably working" predicate at the heart of
# absorb-only-when-provably-working: a no-verb turn-end or stale wake is absorbed
# ONLY when this returns 0, and SURFACED otherwise (the crew may be done, waiting
# on a decision, or wedged). For stale panes it is checked before trusting the
# status log so a pre-validation captain-relevant line does not override an active
# run. See crew_absorb_class for the exact working/paused/none decision.
crew_is_provably_working() {  # <id>
  [ "$(crew_absorb_class "$1")" = working ]
}

# 0 if crew <id>'s authoritative current state is a declared external-wait pause.
# The stale path absorbs such a crew (on a long re-surface cadence) instead of
# escalating a possible wedge.
crew_is_paused() {  # <id>
  [ "$(crew_absorb_class "$1")" = paused ]
}

# 0 (benign/absorb) if EVERY task referenced by a no-verb "signal:" wake is provably
# working; 1 (actionable/surface) if any is not, or no task can be resolved. Pass the
# same space-separated file list as signal_reason_is_actionable. Files are mapped to
# task ids by stripping the .status / .turn-ended suffix; a no-verb wake with nothing
# provably working must surface, so an empty/unresolvable list returns 1.
signal_crew_provably_working() {  # <file> ...
  local f base task seen=""
  for f in "$@"; do
    base=${f##*/}
    case "$base" in
      *.status)     task=${base%.status} ;;
      *.turn-ended) task=${base%.turn-ended} ;;
      *)            continue ;;
    esac
    [ -n "$task" ] || continue
    case " $seen " in *" $task "*) continue ;; esac
    seen="$seen $task"
    crew_is_provably_working "$task" || return 1
  done
  [ -n "$seen" ] || return 1
  return 0
}

# 0 (terminal/actionable) if a stale window's last status line is
# captain-relevant; 1 otherwise, including the no-status case. A 1 only means
# "non-terminal"; the always-on watcher then applies crew_is_provably_working,
# while the away-mode daemon applies its persistence recheck.
stale_is_terminal() {  # <window> <state>
  local win=$1 state=$2 last
  last=$(last_status_line "$state/$(window_to_task "$win" "$state").status")
  [ -n "$last" ] && status_is_captain_relevant "$last"
}

# Print "<file>\t<task>\t<last-line>" for every state/*.status whose last line is
# captain-relevant. This is the cheap fleet-scan both supervisors run as a
# catch-all backstop for a captain-relevant status the per-wake path might miss.
# No dedup is applied here: each consumer dedupes against its own seen-state (the
# daemon against .subsuper-seen-status-*, the watcher against .seen-* signatures).
scan_captain_relevant_statuses() {  # <state>
  local state=$1 f last task
  for f in "$state"/*.status; do
    [ -e "$f" ] || continue
    last=$(last_status_line "$f")
    status_is_captain_relevant "$last" || continue
    task=$(basename "$f"); task="${task%.status}"
    printf '%s\t%s\t%s\n' "$f" "$task" "$last"
  done
  return 0
}
