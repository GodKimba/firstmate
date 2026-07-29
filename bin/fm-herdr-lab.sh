#!/usr/bin/env bash
# Provision and operate an isolated Herdr lab session without risking the live
# fleet session.
#
# Usage:
#   fm-herdr-lab.sh name <label>
#   fm-herdr-lab.sh prepare <session>
#   fm-herdr-lab.sh provision <session>
#   fm-herdr-lab.sh run <session> <herdr arguments...>
#   fm-herdr-lab.sh stop <session>
#   fm-herdr-lab.sh teardown <session>
#
# Session names must begin with "fm-lab-" and can never be "default".
# The name command sanitizes the label, caps it at 16 characters, and appends
# process/random suffixes to keep generated socket paths short.
# Every Herdr call made here carries a trailing --session <session>.
# The run command rejects caller-supplied --session flags, any leading option
# before the subcommand, all session lifecycle operations, and every server
# operation.
# Session stop is available only through guarded stop or teardown, and session
# delete is available only through teardown.
# Both paths perform a fresh refuse-default check immediately before each
# destructive call.
# Provision identifies the live fleet session from the caller's Herdr pane
# identity when available, with a compatibility fallback to a running default
# session only outside Herdr, and records that exact session as a tripwire.
# Teardown requires the same named session identity to remain byte-identical.
set -u

fm_herdr_lab_error() {
  echo "fm-herdr-lab: $*" >&2
}

fm_herdr_lab_validate_name() { # <session>
  local name=${1:-}
  [[ "$name" =~ ^fm-lab-[a-zA-Z0-9][a-zA-Z0-9_-]*$ ]] && return 0
  case "$name" in
    default) fm_herdr_lab_error "refusing session name 'default'" ;;
    '') fm_herdr_lab_error "refusing an empty session name" ;;
    *) fm_herdr_lab_error "session name must start with 'fm-lab-' and contain only letters, digits, underscores, or dashes: $name" ;;
  esac
  return 1
}

fm_herdr_lab_state_dir() {
  printf '%s' "${FM_HERDR_LAB_STATE_DIR:-${TMPDIR:-/tmp}/fm-herdr-lab-${UID}}"
}

fm_herdr_lab_tripwire_path() { # <session>
  printf '%s/%s.fleet-state.json' "$(fm_herdr_lab_state_dir)" "$1"
}

fm_herdr_lab_raw() { # <session> <herdr arguments...>
  local name=$1
  shift
  HERDR_SESSION="$name" herdr "$@" --session "$name"
}

fm_herdr_lab_session_list() { # <session>
  fm_herdr_lab_raw "$1" session list --json
}

fm_herdr_lab_normalize_session() {
  jq -c '{name, default, running, session_dir, socket_path}' 2>/dev/null
}

fm_herdr_lab_pane_identity_matches() { # <session> <pane>
  local session=$1 pane=$2 pane_info actual
  pane_info=$(fm_herdr_lab_raw "$session" pane get "$pane" 2>/dev/null) || return 1
  actual=$(printf '%s' "$pane_info" | jq -er \
    '.result.pane.pane_id | select(type == "string" and length > 0)' 2>/dev/null) || return 1
  [ "$actual" = "$pane" ]
}

# Identify the fleet session without guessing.
# When invoked inside Herdr, HERDR_ENV plus socket and pane identity must
# resolve to one running session and that exact live pane. HERDR_SESSION is not
# identity here because test callers legitimately override it to select the lab
# backend before provisioning; the socket remains the unforgeable live origin.
# Outside Herdr, retain compatibility with the historical single running
# `default` session. Partial or contradictory ambient identity never falls back.
fm_herdr_lab_detect_fleet_state() { # <lab-session>
  local lab=$1 sessions candidate pane socket matched session_snapshot
  sessions=$(fm_herdr_lab_session_list "$lab" 2>/dev/null) || {
    fm_herdr_lab_error "cannot read Herdr sessions for the fleet-state tripwire"
    return 1
  }
  if [ "${HERDR_ENV:-}" = 1 ] || [ -n "${HERDR_PANE_ID:-}" ] \
     || [ -n "${HERDR_SOCKET_PATH:-}" ]; then
    [ "${HERDR_ENV:-}" = 1 ] && [ -n "${HERDR_PANE_ID:-}" ] \
      && [ -n "${HERDR_SOCKET_PATH:-}" ] || {
      fm_herdr_lab_error "fleet identity is incomplete; refusing to guess between an ambient Herdr session and default"
      return 1
    }
    pane=$HERDR_PANE_ID
    socket=$HERDR_SOCKET_PATH
    matched=$(printf '%s' "$sessions" | jq -c --arg socket "$socket" '
      [.sessions[]? | select(.running == true and .socket_path == $socket)]
      | if length == 1 then .[0] else empty end
    ' 2>/dev/null)
    [ -n "$matched" ] || {
      fm_herdr_lab_error "ambient Herdr socket does not identify exactly one running session; refusing to guess"
      return 1
    }
    candidate=$(printf '%s' "$matched" | jq -r '.name // empty' 2>/dev/null)
    case "$candidate" in
      fm-lab-*|'')
        fm_herdr_lab_error "socket-identified fleet session '$candidate' is not a valid non-lab identity"
        return 1
        ;;
    esac
    fm_herdr_lab_pane_identity_matches "$candidate" "$pane" || {
      fm_herdr_lab_error "ambient Herdr pane '$candidate:$pane' is not readable through its explicit session"
      return 1
    }
    session_snapshot=$(printf '%s' "$matched" | fm_herdr_lab_normalize_session) || return 1
    jq -nc --arg source ambient-pane --arg pane_id "$pane" --argjson session "$session_snapshot" \
      '{identity:{source:$source,pane_id:$pane_id},session:$session}'
    return 0
  fi

  matched=$(printf '%s' "$sessions" | jq -c '
    [.sessions[]? | select(.default == true and .name == "default" and .running == true)]
    | if length == 1 then .[0] else empty end
  ' 2>/dev/null)
  [ -n "$matched" ] || {
    fm_herdr_lab_error "fleet-state tripwire requires a complete ambient Herdr pane identity or exactly one running default session"
    return 1
  }
  session_snapshot=$(printf '%s' "$matched" | fm_herdr_lab_normalize_session) || return 1
  jq -nc --arg source default-compat --argjson session "$session_snapshot" \
    '{identity:{source:$source},session:$session}'
}

fm_herdr_lab_fleet_state_for_tripwire() { # <lab-session> <tripwire-json>
  local lab=$1 before=$2 sessions fleet_name matched pane session_snapshot source
  printf '%s' "$before" | jq -e '
    ((.identity | type) == "object")
    and ((.session | type) == "object")
    and ((.identity.source | type) == "string")
    and ((.session.name | type) == "string" and (.session.name | length) > 0)
    and ((.session.default | type) == "boolean")
    and (.session.running == true)
    and ((.session.socket_path | type) == "string" and (.session.socket_path | length) > 0)
    and (
      if .identity.source == "ambient-pane" then
        ((.identity.pane_id | type) == "string" and (.identity.pane_id | length) > 0)
      elif .identity.source == "default-compat" then
        (.session.name == "default" and .session.default == true)
      else
        false
      end
    )
  ' >/dev/null 2>&1 || {
    fm_herdr_lab_error "fleet-state tripwire is malformed"
    return 1
  }
  fleet_name=$(printf '%s' "$before" | jq -r '.session.name // empty' 2>/dev/null)
  source=$(printf '%s' "$before" | jq -r '.identity.source // empty' 2>/dev/null)
  if [ "$source" = ambient-pane ]; then
    pane=$(printf '%s' "$before" | jq -r '.identity.pane_id' 2>/dev/null)
    fm_herdr_lab_pane_identity_matches "$fleet_name" "$pane" || {
      fm_herdr_lab_error "recorded fleet pane '$fleet_name:$pane' is missing or changed"
      return 1
    }
  fi
  sessions=$(fm_herdr_lab_session_list "$lab" 2>/dev/null) || {
    fm_herdr_lab_error "cannot read Herdr sessions for the fleet-state tripwire"
    return 1
  }
  matched=$(printf '%s' "$sessions" | jq -c --arg name "$fleet_name" '
    [.sessions[]? | select(.name == $name)]
    | if length == 1 then .[0] else empty end
  ' 2>/dev/null)
  [ -n "$matched" ] || {
    fm_herdr_lab_error "recorded fleet session '$fleet_name' is missing or ambiguous"
    return 1
  }
  session_snapshot=$(printf '%s' "$matched" | fm_herdr_lab_normalize_session) || return 1
  printf '%s' "$before" | jq -c --argjson session "$session_snapshot" '.session = $session' 2>/dev/null
}

fm_herdr_lab_prepare() { # <session>
  local name=$1 sessions state_dir tripwire
  fm_herdr_lab_validate_name "$name" || return 1
  command -v herdr >/dev/null 2>&1 || { fm_herdr_lab_error "herdr is required"; return 1; }
  command -v jq >/dev/null 2>&1 || { fm_herdr_lab_error "jq is required"; return 1; }

  sessions=$(fm_herdr_lab_session_list "$name" 2>/dev/null) || {
    fm_herdr_lab_error "cannot list Herdr sessions before provisioning '$name'"
    return 1
  }
  if printf '%s' "$sessions" | jq -e --arg name "$name" '.sessions[]? | select(.name == $name)' >/dev/null 2>&1; then
    fm_herdr_lab_error "session '$name' already exists; refusing to adopt or overwrite it"
    return 1
  fi

  state_dir=$(fm_herdr_lab_state_dir)
  tripwire=$(fm_herdr_lab_tripwire_path "$name")
  mkdir -p "$state_dir" || return 1
  [ ! -e "$tripwire" ] || {
    fm_herdr_lab_error "tripwire already exists for '$name'; refusing ambiguous ownership"
    return 1
  }
  fm_herdr_lab_detect_fleet_state "$name" > "$tripwire" || {
    rm -f "$tripwire"
    return 1
  }
}

fm_herdr_lab_refuse_if_default() { # <session>
  local name=$1 info flag
  fm_herdr_lab_validate_name "$name" || return 1
  info=$(fm_herdr_lab_session_list "$name" 2>/dev/null) || {
    fm_herdr_lab_error "refusing destructive call because session list failed"
    return 1
  }
  flag=$(printf '%s' "$info" | jq -r --arg name "$name" \
    '.sessions[]? | select(.name == $name) | .default' 2>/dev/null)
  [ "$flag" = false ] && return 0
  fm_herdr_lab_error "refusing destructive call for '$name': session is absent or default (default=${flag:-<not found>})"
  return 1
}

fm_herdr_lab_cli() { # <session> <herdr arguments...>
  local name=$1 arg
  shift
  fm_herdr_lab_validate_name "$name" || return 1
  [ "$#" -gt 0 ] || { fm_herdr_lab_error "run requires Herdr arguments"; return 1; }
  case "$1" in
    -*)
      fm_herdr_lab_error "run forbids a leading option before the Herdr subcommand; it could shift a server or session lifecycle operation past the guard or subvert session isolation"
      return 1
      ;;
  esac
  for arg in "$@"; do
    case "$arg" in
      --session|--session=*)
        fm_herdr_lab_error "run forbids caller-supplied --session; the helper appends the lab session"
        return 1
        ;;
    esac
  done
  case "$1 ${2:-}" in
    "server "*)
      fm_herdr_lab_error "run forbids server operations; use provision for the named lab server"
      return 1
      ;;
    "session list") ;;
    "session "*)
      fm_herdr_lab_error "run forbids session lifecycle operations; use guarded teardown"
      return 1
      ;;
  esac
  fm_herdr_lab_raw "$name" "$@"
}

fm_herdr_lab_cancel_provision() { # <pid>
  local pid=$1 attempt=0
  if kill -0 "$pid" 2>/dev/null; then
    kill -TERM "$pid" 2>/dev/null || true
    while kill -0 "$pid" 2>/dev/null && [ "$attempt" -lt 10 ]; do
      sleep 0.1
      attempt=$((attempt + 1))
    done
    if kill -0 "$pid" 2>/dev/null; then
      kill -KILL "$pid" 2>/dev/null || true
    fi
  fi
  wait "$pid" 2>/dev/null || true
}

fm_herdr_lab_provision() { # <session>
  local name=$1 sessions tripwire running attempt server_pid max_attempts timeout_seconds
  fm_herdr_lab_validate_name "$name" || return 1
  command -v herdr >/dev/null 2>&1 || { fm_herdr_lab_error "herdr is required"; return 1; }
  command -v jq >/dev/null 2>&1 || { fm_herdr_lab_error "jq is required"; return 1; }

  sessions=$(fm_herdr_lab_session_list "$name" 2>/dev/null) || {
    fm_herdr_lab_error "cannot list Herdr sessions before provisioning '$name'"
    return 1
  }
  if printf '%s' "$sessions" | jq -e --arg name "$name" '.sessions[]? | select(.name == $name)' >/dev/null 2>&1; then
    tripwire=$(fm_herdr_lab_tripwire_path "$name")
    [ -f "$tripwire" ] || {
      fm_herdr_lab_error "missing fleet-state tripwire for existing session '$name'; refusing to adopt it"
      return 1
    }
    fm_herdr_lab_refuse_if_default "$name" || return 1
    running=$(printf '%s' "$sessions" | jq -r --arg name "$name" \
      '.sessions[]? | select(.name == $name) | .running' 2>/dev/null)
    [ "$running" = false ] || {
      fm_herdr_lab_error "session '$name' is not stopped; refusing to re-provision it"
      return 1
    }
    fm_herdr_lab_check_tripwire "$name" || return 1
  else
    fm_herdr_lab_prepare "$name" || return 1
  fi
  fm_herdr_lab_raw "$name" server >/dev/null 2>&1 &
  server_pid=$!
  attempt=0
  max_attempts=300
  timeout_seconds=60
  while [ "$attempt" -lt "$max_attempts" ]; do
    running=$(fm_herdr_lab_cli "$name" status --json 2>/dev/null | jq -r '.server.running // false' 2>/dev/null) || running=false
    if [ "$running" = true ]; then
      fm_herdr_lab_refuse_if_default "$name" || {
        fm_herdr_lab_cancel_provision "$server_pid"
        return 1
      }
      return 0
    fi
    sleep 0.2
    attempt=$((attempt + 1))
  done
  fm_herdr_lab_cancel_provision "$server_pid"
  fm_herdr_lab_error "lab session '$name' did not report running within $timeout_seconds seconds"
  return 1
}

fm_herdr_lab_check_tripwire() { # <session>
  local name=$1 tripwire before after
  tripwire=$(fm_herdr_lab_tripwire_path "$name")
  [ -f "$tripwire" ] || {
    fm_herdr_lab_error "missing fleet-state tripwire for '$name'; refusing unverified teardown"
    return 1
  }
  before=$(cat "$tripwire")
  after=$(fm_herdr_lab_fleet_state_for_tripwire "$name" "$before") || return 1
  [ "$before" = "$after" ] || {
    fm_herdr_lab_error "FLEET-STATE TRIPWIRE FAILED: recorded fleet session changed during lab work"
    fm_herdr_lab_error "before: $before"
    fm_herdr_lab_error "after:  $after"
    return 1
  }
}

fm_herdr_lab_verify_tripwire() { # <session>
  local name=$1 tripwire
  fm_herdr_lab_check_tripwire "$name" || return 1
  tripwire=$(fm_herdr_lab_tripwire_path "$name")
  rm -f "$tripwire"
}

fm_herdr_lab_stop() { # <session>
  local name=$1 tripwire
  fm_herdr_lab_validate_name "$name" || return 1
  tripwire=$(fm_herdr_lab_tripwire_path "$name")
  [ -f "$tripwire" ] || {
    fm_herdr_lab_error "missing fleet-state tripwire for '$name'; refusing stop"
    return 1
  }
  fm_herdr_lab_refuse_if_default "$name" || return 1
  fm_herdr_lab_raw "$name" session stop "$name" --json
}

fm_herdr_lab_teardown() { # <session>
  local name=$1 tripwire sessions delete_status=0
  fm_herdr_lab_validate_name "$name" || return 1
  tripwire=$(fm_herdr_lab_tripwire_path "$name")
  [ -f "$tripwire" ] || {
    fm_herdr_lab_error "missing fleet-state tripwire for '$name'; refusing destructive calls"
    return 1
  }
  sessions=$(fm_herdr_lab_session_list "$name" 2>/dev/null) || {
    fm_herdr_lab_error "cannot list Herdr sessions before teardown"
    return 1
  }
  if ! printf '%s' "$sessions" | jq -e --arg name "$name" '.sessions[]? | select(.name == $name)' >/dev/null 2>&1; then
    fm_herdr_lab_verify_tripwire "$name"
    return
  fi
  fm_herdr_lab_stop "$name" >/dev/null 2>&1 || true
  sleep 0.5
  fm_herdr_lab_refuse_if_default "$name" || return 1
  fm_herdr_lab_raw "$name" session delete "$name" --json >/dev/null 2>&1 || delete_status=$?
  sessions=$(fm_herdr_lab_session_list "$name" 2>/dev/null) || {
    fm_herdr_lab_error "cannot confirm removal of lab session '$name' after teardown"
    return 1
  }
  if printf '%s' "$sessions" | jq -e --arg name "$name" '.sessions[]? | select(.name == $name)' >/dev/null 2>&1; then
    if [ "$delete_status" -ne 0 ]; then
      fm_herdr_lab_error "session delete failed for '$name' and the lab session remains"
    else
      fm_herdr_lab_error "lab session '$name' remains after teardown"
    fi
    return 1
  fi
  fm_herdr_lab_verify_tripwire "$name"
}

fm_herdr_lab_name() { # <label>
  local label=${1:-lab}
  label=$(printf '%s' "$label" | tr -cd 'a-zA-Z0-9_-' | sed 's/^[^a-zA-Z0-9]*//; s/-*$//')
  [ -n "$label" ] || label=lab
  label=${label:0:16}
  label=${label%-}
  [ -n "$label" ] || label=lab
  printf 'fm-lab-%s-%s-%s\n' "$label" "$$" "$RANDOM"
}

fm_herdr_lab_usage() {
  sed -n '2,13p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
}

fm_herdr_lab_main() {
  local command=${1:-}
  case "$command" in
    name)
      [ "$#" -eq 2 ] || { fm_herdr_lab_usage >&2; return 2; }
      fm_herdr_lab_name "$2"
      ;;
    prepare)
      [ "$#" -eq 2 ] || { fm_herdr_lab_usage >&2; return 2; }
      fm_herdr_lab_prepare "$2"
      ;;
    provision)
      [ "$#" -eq 2 ] || { fm_herdr_lab_usage >&2; return 2; }
      fm_herdr_lab_provision "$2"
      ;;
    run)
      [ "$#" -ge 3 ] || { fm_herdr_lab_usage >&2; return 2; }
      shift
      fm_herdr_lab_cli "$@"
      ;;
    stop)
      [ "$#" -eq 2 ] || { fm_herdr_lab_usage >&2; return 2; }
      fm_herdr_lab_stop "$2"
      ;;
    teardown)
      [ "$#" -eq 2 ] || { fm_herdr_lab_usage >&2; return 2; }
      fm_herdr_lab_teardown "$2"
      ;;
    -h|--help|help)
      fm_herdr_lab_usage
      ;;
    *)
      fm_herdr_lab_usage >&2
      return 2
      ;;
  esac
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  set -e
  fm_herdr_lab_main "$@"
fi
