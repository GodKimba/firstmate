#!/usr/bin/env bash
# Send one line of literal text to a crewmate endpoint, then Enter.
# Usage: fm-send.sh <target> <text...>
#        fm-send.sh <target> --decision <key> <text...>
#   <target> may be an exact task id, a legacy fm-<id> task label resolved
#   through this home's state/<id>.meta, or an explicit well-formed backend
#   target. fm-send refuses unresolved guesses rather than falling back to a
#   tmux window search, because a "successful" send to the wrong endpoint is
#   worse than a loud failure.
# Special keys instead of text: fm-send.sh <target> --key Enter
# Verified Claude Vim recovery: fm-send.sh <task-selector> --recover-claude-vim
# The recovery command is intentionally separate from raw --key Escape. It
# sends at most two targeted Escapes, requires a fresh rendered
# `Interrupted · What should Claude do instead?` proof before succeeding, and
# refuses if the composer becomes unreadable or changes empty/pending state.
# If text was already pending, it preserves those bytes by never typing or
# deleting anything and continues with Enter only after interruption proof.
# If the composer was empty, it requires an initial Insert-mode marker and
# restores proven Insert mode after interruption before a corrective line may be
# sent normally. Only recorded Claude tasks on tmux or Herdr support this
# stronger contract; every other harness/backend is refused before a key lands.
#
# --decision <key> answers one open keyed decision. It requires a task selector,
# refuses unless that exact decision is open right now in the task's status
# stream, and only then mints and records the answer token that lets the worker's
# resolved line close the request (bin/fm-classify-lib.sh owns the correlation
# contract). Because the token cannot exist before the request opened, no queued
# generic command, unkeyed message, or earlier input can close it. Plain sends
# are unchanged and still reach a busy worker's queue.
# The token remains live only after confirmed delivery.
# Every pre-submit failure or unconfirmed send revokes it, and a revocation
# failure is reported loudly because retrying could otherwise duplicate answer
# authority for one request.
# Key support is backend-specific: tmux/herdr support Escape, Enter, and C-c;
# Orca currently supports Enter and C-c only, and rejects Escape.
#
# Text submission is verified: the line is typed ONCE, then Enter is sent and
# retried (Enter only, never retyped) until the target backend confirms a
# submit or reports an inconclusive send. If a swallowed Enter is positively
# confirmed, fm-send exits NON-ZERO so the caller knows the steer did not land
# instead of silently leaving an unsubmitted instruction.
# Submission dispatches through the target's recorded backend; the tmux adapter
# shares its composer/submit core with the away-mode daemon via bin/fm-tmux-lib.sh.
# Tune with FM_SEND_RETRIES (default 3) / FM_SEND_SLEEP (0.4).
# Slash commands, and codex `$...` skill invocations resolved through harness
# meta, get a longer pre-Enter settle so completion popups do not swallow Enter.
#
# From-firstmate marker: when the resolved target is a task selector whose meta
# records kind=secondmate, the text uses the live-charter-compatible
# from-firstmate carrier owned by bin/fm-operational-input.sh so the secondmate
# routes its reply via its status file or a status-pointed doc instead of
# stranding it in chat the main firstmate never reads. A crewmate/scout target,
# an explicit backend-target escape-hatch target, and the --key path are never
# marked - their behavior is unchanged.
#
# Parent-owned pending-reply expectation: every newly marked secondmate request
# also receives a privacy-safe correlation id and a durable parent record under
# state/pending-replies/ before delivery (bin/fm-pending-reply-lib.sh). Delivery
# success and reply success are separate facts: a successful submit never
# resolves the expectation. Set FM_PENDING_REPLY_EXISTING_CORR=<id> when
# re-sending a recovery request for an already-open expectation so a second
# record is not created. Direct unmarked captain input never creates one.
#
# After a successful text submit fm-send pauses FM_SEND_SETTLE seconds (default 1,
# 0 disables) before returning: submit confirmation only proves the text was
# accepted, but the harness needs a beat to spin up the turn before its busy
# footer appears, so an immediate peek would otherwise see the stale idle pane.
# The pause is fm-send-only; the shared submit core (used by the away-mode daemon,
# which only needs "submitted") does not pay it, and the --key path is unaffected.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"

# shellcheck source=bin/fm-gate-refuse-lib.sh
. "$SCRIPT_DIR/fm-gate-refuse-lib.sh"
# Fail closed before any fleet mutation: a no-mistakes gate agent must never steer
# a crewmate (see bin/fm-gate-refuse-lib.sh).
fm_refuse_if_gate_agent

if [ -z "${FM_HOME+x}" ] || [ -z "${FM_HOME:-}" ]; then
  echo "error: FM_HOME is not set; fm-send refuses to resolve targets without an explicit firstmate home" >&2
  exit 1
fi

STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
if [ ! -d "$FM_HOME" ]; then
  echo "error: FM_HOME '$FM_HOME' is not a directory; fm-send cannot resolve this home's state" >&2
  exit 1
fi
if [ ! -d "$STATE" ]; then
  echo "error: state dir '$STATE' is missing; fm-send cannot resolve targets for FM_HOME '$FM_HOME'" >&2
  exit 1
fi

# shellcheck source=bin/fm-backend.sh
. "$SCRIPT_DIR/fm-backend.sh"
# shellcheck source=bin/fm-marker-lib.sh
. "$SCRIPT_DIR/fm-marker-lib.sh"
# shellcheck source=bin/fm-pending-reply-lib.sh
. "$SCRIPT_DIR/fm-pending-reply-lib.sh"
# shellcheck source=bin/fm-classify-lib.sh
. "$SCRIPT_DIR/fm-classify-lib.sh"

FM_GUARD_CONTINUE_LINE='This is a supervision warning only; the requested message WILL still be sent.' "$SCRIPT_DIR/fm-guard.sh" || true

fm_send_id_from_meta() {  # <meta-file>
  local base
  base=${1##*/}
  printf '%s' "${base%.meta}"
}

fm_send_meta_for_key_value() {  # <state-dir> <key> <value>
  local state=$1 key=$2 value=$3 meta got
  for meta in "$state"/*.meta; do
    [ -e "$meta" ] || continue
    got=$(fm_meta_get "$meta" "$key")
    [ "$got" = "$value" ] || continue
    printf '%s' "$meta"
    return 0
  done
  return 1
}

fm_send_count_colons() {  # <string>
  local s=$1 no_colons
  no_colons=${s//:/}
  printf '%s' $(( ${#s} - ${#no_colons} ))
}

fm_send_resolve_target() {  # <raw-target>
  local raw=$1 meta pane_meta target backend assumed colons id session hint

  RESOLVED_TARGET=""
  TARGET_BACKEND=""
  TARGET_HARNESS=""
  EXPECTED_LABEL=""
  TARGET_META=""
  TARGET_SELECTOR=""
  RESOLUTION_TRIED=""

  meta=$(fm_backend_meta_for_selector "$raw" "$STATE" 2>/dev/null || true)
  if [ -n "$meta" ]; then
    RESOLUTION_TRIED="meta=$meta; backend=from-meta"
    target=$(fm_backend_target_of_meta "$meta")
    if [ -z "$target" ]; then
      echo "error: no backend target recorded in $meta (tried $RESOLUTION_TRIED)" >&2
      return 1
    fi
    backend=$(fm_backend_of_meta "$meta")
    RESOLVED_TARGET=$target
    TARGET_BACKEND=$backend
    TARGET_META=$meta
    TARGET_HARNESS=$(fm_meta_get "$meta" harness)
    EXPECTED_LABEL=$(fm_backend_expected_label_of_selector "$raw" "$STATE")
    TARGET_SELECTOR=1
    return 0
  fi

  case "$raw" in
    fm-*)
      RESOLUTION_TRIED="meta=$STATE/$raw.meta; legacy-meta=$STATE/${raw#fm-}.meta; backend=none"
      echo "error: no metadata for $raw in $STATE (tried $RESOLUTION_TRIED); pass a well-formed explicit backend target only when targeting outside this firstmate home" >&2
      return 1
      ;;
  esac

  pane_meta=$(fm_send_meta_for_key_value "$STATE" herdr_pane_id "$raw" 2>/dev/null || true)
  if [ -n "$pane_meta" ]; then
    session=$(fm_meta_get "$pane_meta" herdr_session)
    hint="${session:-<herdr-session>}:$raw"
    id=$(fm_send_id_from_meta "$pane_meta")
    echo "error: target '$raw' matches herdr_pane_id in $pane_meta but is missing its herdr session prefix; expected <herdr-session>:<pane-id> such as '$hint' or use 'fm-$id' (tried meta=$STATE/$raw.meta; backend=herdr)" >&2
    return 1
  fi

  meta=$(fm_backend_meta_for_window "$raw" "$STATE" 2>/dev/null || true)
  if [ -n "$meta" ]; then
    target=$(fm_backend_target_of_meta "$meta")
    if [ -z "$target" ]; then
      echo "error: no backend target recorded in $meta (tried explicit target '$raw' via recorded window/terminal; backend=from-meta)" >&2
      return 1
    fi
    RESOLVED_TARGET=$target
    TARGET_BACKEND=$(fm_backend_of_meta "$meta")
    TARGET_META=$meta
    TARGET_HARNESS=$(fm_meta_get "$meta" harness)
    RESOLUTION_TRIED="explicit target '$raw' matched $meta; backend=$TARGET_BACKEND"
    return 0
  fi

  case "$raw" in
    *:*)
      colons=$(fm_send_count_colons "$raw")
      if [ "$colons" -ge 2 ]; then
        assumed=herdr
      else
        assumed=tmux
      fi
      if ! fm_backend_target_exists "$assumed" "$raw"; then
        echo "error: explicit target '$raw' is not a live $assumed endpoint (tried meta=$STATE/$raw.meta; metadata window/terminal lookup; backend=$assumed). Use fm-<id> for a recorded task/lane, or pass a target whose backend endpoint can be verified." >&2
        return 1
      fi
      RESOLVED_TARGET=$raw
      TARGET_BACKEND=$assumed
      RESOLUTION_TRIED="meta=$STATE/$raw.meta; metadata window/terminal lookup; backend=$assumed; endpoint=verified"
      return 0
      ;;
  esac

  echo "error: target '$raw' is not resolvable (tried meta=$STATE/$raw.meta; metadata window/terminal lookup; backend=none). Use fm-$raw for a recorded task/lane, or pass a well-formed explicit backend target such as session:window." >&2
  return 1
}

RAW_TARGET=$1
fm_send_resolve_target "$RAW_TARGET" || exit 1
T=$RESOLVED_TARGET
shift

fm_backend_validate "$TARGET_BACKEND" || exit 1

# Classify a from-firstmate -> secondmate request. Only a task selector resolved
# through this home's meta whose authoritative kind is secondmate is marked: the
# secondmate then routes its reply via the status path (see fm-marker-lib.sh).
# An explicit backend target (the escape hatch for endpoints outside this home)
# and any crewmate/scout target are left unmarked, and so is the --key path.
MARK_FROM_FIRSTMATE=0
PENDING_REPLY_CORR=
PENDING_REPLY_CREATED=0
TARGET_TASK_ID=
# Set once a --decision answer token has been minted. Any later path that does
# not confirm delivery must revoke its record, so an unconfirmed answer never
# leaves standing authority a later resend could duplicate.
DECISION_MINTED=0
DECISION_KEY=
DECISION_TOKEN=
DECISION_INSTANCE=
DECISION_ANSWERS=

# Revoke an unconfirmed decision answer. Called on every non-delivery exit.
fm_send_revoke_unconfirmed_decision() {
  [ "$DECISION_MINTED" = 1 ] || return 0
  DECISION_MINTED=0
  if ! fm_decision_revoke_answer "$DECISION_ANSWERS" "$DECISION_TOKEN" "$DECISION_KEY" "$DECISION_INSTANCE"; then
    echo "error: could not revoke the unconfirmed decision answer token in $DECISION_ANSWERS; that token can still close decision '$DECISION_KEY'. Inspect it before answering again." >&2
    return 1
  fi
}
fm_send_cleanup_unconfirmed_decision() {
  local exit_status=$1
  trap - EXIT
  fm_send_revoke_unconfirmed_decision || exit_status=1
  exit "$exit_status"
}
fm_send_arm_decision_cleanup() {
  DECISION_MINTED=1
  trap 'fm_send_cleanup_unconfirmed_decision "$?"' EXIT
}
fm_send_disarm_decision_cleanup() {
  [ "$DECISION_MINTED" = 1 ] || return 0
  DECISION_MINTED=0
  trap - EXIT
}
if [ -n "$TARGET_SELECTOR" ] && [ -n "$TARGET_META" ] && [ "$(fm_meta_get "$TARGET_META" kind)" = secondmate ]; then
  MARK_FROM_FIRSTMATE=1
  TARGET_TASK_ID=$(fm_send_id_from_meta "$TARGET_META")
fi

# Resolve the target's harness from its meta (recorded by fm-spawn), used only to
# scope the codex `$<skill>` popup-settle below. A task selector carries
# meta; an explicit backend-target escape hatch has none, so its harness is
# unknown and treated as non-codex (the safe default that keeps the fast path).
# The target's BACKEND comes from selector meta, from matching an explicit target
# back to recorded meta, or from strict explicit-target shape validation.
# Do not add a separate passive liveness preflight here. Active send paths own
# backend readiness: herdr, for example, must route through its session-aware
# target_ready path before sending, while zellij verifies pane labels in its
# send implementation. A failed backend send is still surfaced below as a hard
# error with the attempted resolution attached.

fm_send_claude_interrupt_render_present() {  # <capture>
  printf '%s\n' "$1" | awk '
    function owned_interrupt(line, normalized) {
      normalized = line
      sub(/^[[:space:]]+/, "", normalized)
      sub(/[[:space:]]+$/, "", normalized)
      gsub(/[[:space:]]+/, " ", normalized)
      return normalized == "⎿ Interrupted · What should Claude do instead?"
    }
    function composer(line) {
      return line ~ /^[[:space:]]*([│┃║|][[:space:]]*)?❯([[:space:]]|$)/
    }
    function boundary_space(line, normalized) {
      normalized = line
      sub(/^[[:space:]]+/, "", normalized)
      sub(/[[:space:]]+$/, "", normalized)
      return normalized == "" || normalized ~ /^[-+─━═╭╮┌┐╔╗┏┓]+$/
    }
    {
      if (owned_interrupt($0)) {
        candidate = 1
        gap = 0
        next
      }
      if (composer($0)) {
        proof = candidate && gap <= 3
        candidate = 0
        next
      }
      if (candidate) {
        if (!boundary_space($0) || gap >= 3) candidate = 0
        else gap++
      }
    }
    END { exit(proof ? 0 : 1) }
  '
}

fm_send_claude_insert_footer_present() {
  printf '%s\n' "$1" | awk '
    /[^[:space:]]/ { last = $0 }
    END { exit(last ~ /^[[:space:]]*-- INSERT --[[:space:]]*$/ ? 0 : 1) }
  '
}

fm_send_recover_claude_vim() {
  local initial before after state latest_state verdict
  local attempt=0 poll retries sleep_s proof=0
  [ -n "$TARGET_SELECTOR" ] && [ -n "$TARGET_META" ] || {
    echo "error: --recover-claude-vim requires a recorded task selector" >&2
    return 1
  }
  [ "$TARGET_HARNESS" = claude ] || {
    echo "error: --recover-claude-vim is only valid for a recorded Claude task (target harness=${TARGET_HARNESS:-unknown})" >&2
    return 1
  }
  fm_backend_supports_claude_vim_recovery "$TARGET_BACKEND" || {
    echo "error: --recover-claude-vim is unsupported on backend '$TARGET_BACKEND'; no key was sent" >&2
    return 1
  }
  initial=$(fm_backend_composer_state "$TARGET_BACKEND" "$T" "$EXPECTED_LABEL" 2>/dev/null)
  case "$initial" in
    empty|pending) ;;
    *)
      echo "error: Claude Vim recovery refused because the composer is not positively empty or pending (state=${initial:-unknown}); no key was sent" >&2
      return 1
      ;;
  esac
  before=$(fm_backend_capture "$TARGET_BACKEND" "$T" 80 "$EXPECTED_LABEL" 2>/dev/null) || {
    echo "error: Claude Vim recovery could not read the pre-interrupt pane; no key was sent" >&2
    return 1
  }
  if fm_send_claude_interrupt_render_present "$before"; then
    echo "error: Claude Vim recovery found a current Interrupted render before any Escape; refusing ambiguous proof" >&2
    return 1
  fi
  if [ "$initial" = empty ] && ! fm_send_claude_insert_footer_present "$before"; then
    echo "error: empty-composer Claude Vim recovery requires a positive Insert-mode marker before any key is sent" >&2
    return 1
  fi
  sleep_s=${FM_SEND_INTERRUPT_SLEEP:-0.15}
  while [ "$attempt" -lt 2 ]; do
    if ! fm_backend_send_key "$TARGET_BACKEND" "$T" Escape "$EXPECTED_LABEL"; then
      echo "error: Claude Vim recovery could not send targeted Escape $((attempt + 1))" >&2
      return 1
    fi
    latest_state=unknown
    poll=0
    while [ "$poll" -lt 4 ]; do
      sleep "$sleep_s"
      after=$(fm_backend_capture "$TARGET_BACKEND" "$T" 80 "$EXPECTED_LABEL" 2>/dev/null) || {
        echo "error: Claude Vim recovery lost pane readability after Escape $((attempt + 1)); refusing further keys" >&2
        return 1
      }
      state=$(fm_backend_composer_state "$TARGET_BACKEND" "$T" "$EXPECTED_LABEL" 2>/dev/null)
      latest_state=$state
      case "$state" in
        "$initial"|unknown) ;;
        *)
          echo "error: Claude Vim recovery observed the composer change from '$initial' to '${state:-unknown}'; refusing further keys" >&2
          return 1
          ;;
      esac
      if fm_send_claude_interrupt_render_present "$after"; then
        [ "$state" = "$initial" ] || {
          echo "error: Claude rendered Interrupted but the composer postcondition is ambiguous (state=${state:-unknown})" >&2
          return 1
        }
        proof=1
        break
      fi
      poll=$((poll + 1))
    done
    [ "$proof" -eq 1 ] && break
    [ "$latest_state" = "$initial" ] || {
      echo "error: Claude Vim recovery could not re-verify the '$initial' composer after Escape $((attempt + 1)); refusing further keys" >&2
      return 1
    }
    attempt=$((attempt + 1))
  done
  [ "$proof" -eq 1 ] || {
    echo "error: Claude Vim recovery sent two targeted Escapes without fresh Interrupted proof; composer remains '$initial' and no Enter was sent" >&2
    return 1
  }

  if [ "$initial" = pending ]; then
    retries=${FM_SEND_RETRIES:-3}
    verdict=$(fm_backend_submit_pending "$TARGET_BACKEND" "$T" "$retries" "${FM_SEND_SLEEP:-0.4}" "$EXPECTED_LABEL") || verdict=send-failed
    [ "$verdict" = empty ] || {
      echo "error: Claude was interrupted, but Enter-only continuation of the preserved pending composer is unconfirmed (verdict=${verdict:-unknown}); text was not retyped" >&2
      return 1
    }
    printf 'submitted-pending\n'
  else
    if ! fm_backend_send_key "$TARGET_BACKEND" "$T" i "$EXPECTED_LABEL"; then
      echo "error: Claude was interrupted, but recovery could not restore Insert mode for safe redirection" >&2
      return 1
    fi
    poll=0
    while [ "$poll" -lt 4 ]; do
      sleep "$sleep_s"
      after=$(fm_backend_capture "$TARGET_BACKEND" "$T" 80 "$EXPECTED_LABEL" 2>/dev/null) || {
        echo "error: Claude was interrupted, but Insert-mode restoration became unreadable" >&2
        return 1
      }
      state=$(fm_backend_composer_state "$TARGET_BACKEND" "$T" "$EXPECTED_LABEL" 2>/dev/null)
      if fm_send_claude_insert_footer_present "$after" && [ "$state" = empty ]; then
        printf 'interrupted\n'
        return 0
      fi
      case "$state" in
        empty|unknown) ;;
        *)
          echo "error: Claude was interrupted, but Insert-mode restoration changed the empty composer to '$state'; refusing redirection" >&2
          return 1
          ;;
      esac
      poll=$((poll + 1))
    done
    echo "error: Claude was interrupted, but Insert mode was not positively restored; refusing redirection" >&2
    return 1
  fi
}

if [ "${1:-}" = "--recover-claude-vim" ]; then
  [ "$#" -eq 1 ] || { echo "error: --recover-claude-vim accepts no text; it preserves any existing composer bytes" >&2; exit 1; }
  fm_send_recover_claude_vim || exit 1
elif [ "${1:-}" = "--key" ]; then
  if ! fm_backend_send_key "$TARGET_BACKEND" "$T" "$2" "$EXPECTED_LABEL"; then
    echo "error: key '$2' not sent to $T ($TARGET_BACKEND send failed; tried $RESOLUTION_TRIED)" >&2
    exit 1
  fi
else
  MESSAGE=$*
  if [ "${1:-}" = "--decision" ]; then
    # Answer one open keyed decision. Every refusal below preserves the same
    # boundary: without a token minted against a currently-open request, the
    # worker's resolved line cannot close it, so the decision keeps surfacing
    # instead of being silently advanced past.
    DECISION_KEY=${2:-}
    shift 2 || { echo "error: --decision requires <key> and answer text" >&2; exit 1; }
    DECISION_TEXT=$*
    [ -n "$DECISION_KEY" ] || { echo "error: --decision requires a decision key" >&2; exit 1; }
    [ -n "$DECISION_TEXT" ] || { echo "error: --decision requires answer text" >&2; exit 1; }
    case "$DECISION_KEY" in
      *[!A-Za-z0-9._-]*)
        echo "error: decision key '$DECISION_KEY' is not a valid slug" >&2; exit 1 ;;
    esac
    if [ -z "$TARGET_SELECTOR" ] || [ -z "$TARGET_META" ]; then
      echo "error: --decision needs a task selector; an explicit backend target has no decision stream to correlate against" >&2
      exit 1
    fi
    DECISION_STATUS="$STATE/$(fm_send_id_from_meta "$TARGET_META").status"
    DECISION_INSTANCE=''
    DECISION_FOUND=0
    while IFS=$'\t' read -r d_key _d_verb d_instance _d_summary || [ -n "$d_key" ]; do
      [ "$d_key" = "$DECISION_KEY" ] || continue
      [ "$_d_verb" = needs-decision ] || continue
      DECISION_INSTANCE=$d_instance
      DECISION_FOUND=1
    done <<EOF
$(status_open_decisions "$DECISION_STATUS" --with-instance)
EOF
    if [ "$DECISION_FOUND" != 1 ]; then
      echo "error: no open decision '$DECISION_KEY' in $DECISION_STATUS; an answer cannot precede its request" >&2
      exit 1
    fi
    DECISION_ANSWERS=$(fm_decision_answers_file "$DECISION_STATUS")
    DECISION_TOKEN=$(fm_decision_mint_answer_token "$DECISION_INSTANCE") \
      || { echo "error: could not mint a decision answer token" >&2; exit 1; }
    fm_send_arm_decision_cleanup
    fm_decision_record_answer "$DECISION_ANSWERS" "$DECISION_TOKEN" "$DECISION_KEY" "$DECISION_INSTANCE" >/dev/null \
      || { echo "error: could not record the decision answer token in $DECISION_ANSWERS" >&2; exit 1; }
    MESSAGE=$(fm_decision_answer_message "$DECISION_KEY" "$DECISION_TOKEN" "$DECISION_TEXT")
  fi
  if [ "$MARK_FROM_FIRSTMATE" = 1 ]; then
    # Reuse an existing correlation id for recovery resends; otherwise create a
    # durable parent expectation before delivery. Transport success never
    # resolves that expectation (see fm-pending-reply-lib.sh).
    existing_corr=${FM_PENDING_REPLY_EXISTING_CORR:-$(fm_pending_reply_extract_corr "$MESSAGE")}
    if [ -n "$existing_corr" ] \
      && fm_pending_reply_corr_reusable "$STATE" "$existing_corr" "$TARGET_TASK_ID"; then
      PENDING_REPLY_CORR=$existing_corr
    else
      if [ -z "$TARGET_TASK_ID" ]; then
        echo "error: cannot create pending-reply expectation without a resolvable secondmate task id" >&2
        exit 1
      fi
      PENDING_REPLY_CORR=$(fm_pending_reply_create "$FM_HOME" "$STATE" "$TARGET_TASK_ID" "$MESSAGE") \
        || { echo "error: failed to create parent pending-reply expectation for $TARGET_TASK_ID" >&2; exit 1; }
      PENDING_REPLY_CREATED=1
    fi
    fm_pending_reply_embed_corr "$MESSAGE" "$PENDING_REPLY_CORR" MESSAGE
    if [ "$PENDING_REPLY_CREATED" = 1 ] \
      && ! fm_pending_reply_prepare_delivery "$STATE" "$PENDING_REPLY_CORR"; then
      fm_pending_reply_discard_undelivered "$STATE" "$PENDING_REPLY_CORR" || true
      echo "error: failed to durably prepare pending-reply delivery for $TARGET_TASK_ID" >&2
      exit 1
    fi
  fi
  # Slash commands open a completion popup in some TUIs (verified on codex);
  # submitting too fast selects nothing, so give the popup time to settle before
  # the (retried) Enter. Codex opens the same kind of popup for a `$<skill>`
  # invocation, so a `$...` message to a codex target gets the same settle. That
  # `$` case is scoped to codex on purpose: unlike `/`, a leading `$` commonly
  # starts ordinary text ("$5/month", "$HOME"), so a universal `$` rule would
  # needlessly slow plain text to claude/opencode/pi. The target backend's
  # verified submit retry still backs the settle up either way.
  case "$*" in
    /*) settle=1.2 ;;
    \$*)
      if [ "$TARGET_HARNESS" = codex ]; then settle=1.2; else settle=0.3; fi
      ;;
    *) settle=0.3 ;;
  esac
  retries=${FM_SEND_RETRIES:-3}
  sleep_s=${FM_SEND_SLEEP:-0.4}
  # Type once, submit, verify. Only exact empty confirms delivery; every other
  # verdict preserves the loud refusal boundary.
  if ! verdict=$(fm_backend_send_text_submit "$TARGET_BACKEND" "$T" "$MESSAGE" "$retries" "$sleep_s" "$settle" "$EXPECTED_LABEL"); then
    if [ "$PENDING_REPLY_CREATED" = 1 ] && [ -n "$PENDING_REPLY_CORR" ]; then
      fm_pending_reply_discard_undelivered "$STATE" "$PENDING_REPLY_CORR" || true
    fi
    echo "error: text not sent to $T ($TARGET_BACKEND send failed; tried $RESOLUTION_TRIED)" >&2
    exit 1
  fi
  case "$verdict" in
    empty)
      fm_send_disarm_decision_cleanup
      ;;
    send-failed)
      if [ "$PENDING_REPLY_CREATED" = 1 ] && [ -n "$PENDING_REPLY_CORR" ]; then
        fm_pending_reply_discard_undelivered "$STATE" "$PENDING_REPLY_CORR" || true
      fi
      echo "error: text not sent to $T ($TARGET_BACKEND send failed; tried $RESOLUTION_TRIED)" >&2
      exit 1
      ;;
    *)
      if [ "$PENDING_REPLY_CREATED" = 1 ] && [ -n "$PENDING_REPLY_CORR" ]; then
        fm_pending_reply_discard_undelivered "$STATE" "$PENDING_REPLY_CORR" || true
      fi
      echo "error: text not submitted to $T (delivery unconfirmed; verdict=${verdict:-unknown}; tried $RESOLUTION_TRIED)" >&2
      exit 1
      ;;
  esac
  # Delivery confirmed. Mark the pending expectation delivered without resolving
  # it: only a correlated parent report acknowledges the request.
  if [ -n "$PENDING_REPLY_CORR" ]; then
    if fm_pending_reply_confirm_delivery "$STATE" "$PENDING_REPLY_CORR"; then
      :
    else
      delivery_commit_status=$?
      if [ "$delivery_commit_status" = 2 ]; then
        echo "error: text was delivered to $T, but its pending-reply delivery commit failed; a durable recovery marker was stored and the watcher will reconcile it. Do not resend." >&2
      else
        echo "error: text was delivered to $T, but its pending-reply delivery commit and recovery marker both failed. Do not resend; inspect $STATE manually." >&2
      fi
      exit 1
    fi
  fi
  # Submit landed with exact empty. Confirmation only proves the text was
  # accepted; the harness still needs a beat to spin up the
  # turn before its busy footer shows. Pause so an immediate peek catches the
  # crewmate actually working instead of the stale idle pane. FM_SEND_SETTLE=0
  # disables it. Scoped to this path only, never the shared submit core.
  [ "${FM_SEND_SETTLE:-1}" = 0 ] || sleep "${FM_SEND_SETTLE:-1}"
fi
