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
# There are two documented exceptions. The absorb classification
# (crew_absorb_class and its working/paused wrappers) is NOT a pure status-file
# read: it reuses bin/fm-crew-state.sh, which may make a bounded no-mistakes call,
# to decide whether a crew that just stopped its turn or went stale is working,
# deliberately paused, or neither. Callers run it ONLY on no-verb signal handling
# and first sighting of a stale hash, never on every wake, so the per-wake triage
# stays cheap. status_open_decisions_incremental (see "incremental (cursor-backed)
# open-decisions fold" below) also writes: it persists a per-status-file byte
# cursor and folded open-set as a side effect, so a per-drain fleet-wide scan
# stays bounded by new appends instead of re-reading each task's whole lifetime
# log every time.

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

# The one-time stream marker that makes the answer-correlation rule
# forward-compatible: openings recorded BEFORE it keep legacy plain keyed
# closure, every opening after it requires a correlated token. Its stream id is
# also the identity every occurrence instance is derived from.
FM_CLASSIFY_DECISION_CUTOVER_MARK_PREFIX_DEFAULT='[fm-decision-answer-cutover:v1 stream='
# The verb firstmate uses to carry an authorized answer back to a worker.
FM_CLASSIFY_DECISION_VERB_DEFAULT='decision'

# A capture the backend could not read has no pane identity of its own, so the
# stale path uses this stable placeholder rather than an empty hash that would
# compare equal to every other unreadable capture.
capture_unreadable_stale_identity() { printf 'endpoint-unreadable'; }

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
# The three parsers are pure reads of a single line; the verb parser strips any
# key token before the colon so the leading word is recovered cleanly.
status_line_verb() {  # <status-line> -> leading verb word
  local v=${1%%:*}
  v=${v%%\[key=*}
  # A malformed answer token with no preceding key token must not be read as
  # part of the verb, or the line would classify as an unknown verb instead of
  # an uncorrelated resolution the fold can refuse.
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
  local prefix=${1%%:*} k
  case "$prefix" in
    *\[key=*\]*)
      k=${prefix#*\[key=}
      k=${k%%\]*}
      case "$k" in
        ''|*[!A-Za-z0-9._-]*) return 1 ;;
        *) printf '%s' "$k" ;;
      esac
      ;;
    *) printf 'default' ;;
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
# every answer token for that occurrence. Token-era streams bind it to their
# self-described stream identity; legacy streams retain the historical position.
fm_decision_hash_text() {
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 2>/dev/null | awk '{print $1}'
  elif command -v sha256sum >/dev/null 2>&1; then
    sha256sum 2>/dev/null | awk '{print $1}'
  elif command -v openssl >/dev/null 2>&1; then
    openssl dgst -sha256 2>/dev/null | awk '{print $NF}'
  else
    return 1
  fi
}

fm_decision_instance_id() {  # <physical-line-number> [stream-id] -> 16 hex chars
  local position=$1 stream=${2:-} raw
  case "$position" in
    ''|*[!0-9]*) return 1 ;;
  esac
  [ "$position" -gt 0 ] 2>/dev/null || return 1
  if [ -n "$stream" ]; then
    [ "${#stream}" -eq 32 ] || return 1
    case "$stream" in *[!a-f0-9]*) return 1 ;; esac
    raw=$(printf '%s:%s' "$stream" "$position" | fm_decision_hash_text) || return 1
    raw=$(printf '%s' "$raw" | cut -c1-16)
    [ "${#raw}" -eq 16 ] || return 1
    printf '%s' "$raw"
    return 0
  fi
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

# Revoke a minted token whose answer was NOT confirmed delivered, so a failed or
# unconfirmed decision send leaves no standing authority behind. Without this, a
# resend after an unconfirmed send mints a SECOND valid token for the same
# request instance, and both remain able to close it - a retry would mint
# duplicate authority (task fm-herdr-send-busy-duplicate, required work 4).
#
# Revoking is the safe direction even when the send may in fact have landed: an
# answer that arrives carrying a revoked token simply fails to correlate, so the
# request stays open and gets surfaced, which is this contract's established
# preference over silently advancing past it.
#
# Rewrites the record file without the matching line. A missing file is success
# (nothing to revoke). Returns non-zero only when a present file could not be
# rewritten, which the caller must surface rather than ignore.
fm_decision_revoke_answer() {  # <answers-file> <token> <key> <instance>
  local f=$1 token=$2 key=$3 instance=$4 tmp rt rk ri
  [ -f "$f" ] || return 0
  tmp="$f.revoke.$$"
  : > "$tmp" || return 1
  while IFS=$'\t' read -r rt rk ri || [ -n "$rt" ]; do
    [ -n "$rt" ] || continue
    if [ "$rt" = "$token" ] && [ "$rk" = "$key" ] && [ "$ri" = "$instance" ]; then
      continue
    fi
    printf '%s\t%s\t%s\n' "$rt" "$rk" "$ri" >> "$tmp" || { rm -f "$tmp"; return 1; }
  done < "$f"
  mv -f "$tmp" "$f" || { rm -f "$tmp"; return 1; }
}

# Print the message shape that carries an authorized answer to a worker. The
# worker copies the same key and token onto its closing resolved line.
fm_decision_answer_message() {  # <key> <token> <text>
  printf '%s [key=%s] [ans=%s]: %s' \
    "${FM_CLASSIFY_DECISION_VERB:-$FM_CLASSIFY_DECISION_VERB_DEFAULT}" "$1" "$2" "$3"
}

fm_decision_marker_line_id() {  # <marker-line>
  local line=$1 prefix id
  prefix=$FM_CLASSIFY_DECISION_CUTOVER_MARK_PREFIX_DEFAULT
  case "$line" in "$prefix"*\]) ;; *) return 1 ;; esac
  id=${line#"$prefix"}
  id=${id%\]}
  [ "${#id}" -eq 32 ] || return 1
  case "$id" in *[!a-f0-9]*) return 1 ;; esac
  printf '%s' "$id"
}

_fm_decision_stream_id_stream() {
  local line id stream='' count=0
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      "$FM_CLASSIFY_DECISION_CUTOVER_MARK_PREFIX_DEFAULT"*) ;;
      *) continue ;;
    esac
    id=$(fm_decision_marker_line_id "$line") || return 2
    count=$((count + 1))
    [ "$count" -eq 1 ] || return 2
    stream=$id
  done
  [ "$count" -eq 1 ] || return 1
  printf '%s' "$stream"
}

fm_decision_stream_id() {  # <status-file>
  local f=$1
  [ -f "$f" ] && [ ! -L "$f" ] || return 1
  _fm_decision_stream_id_stream < "$f"
}

fm_decision_status_marker() {
  local raw
  raw=$(openssl rand -hex 16 2>/dev/null || true)
  case "$raw" in
    [a-f0-9][a-f0-9][a-f0-9][a-f0-9]*) ;;
    *)
      raw=$(printf '%s' "${BASHPID:-$$}-$(date +%s 2>/dev/null)-$RANDOM$RANDOM$RANDOM" \
        | fm_decision_hash_text)
      ;;
  esac
  raw=$(printf '%s' "$raw" | tr 'A-F' 'a-f' | tr -cd 'a-f0-9' | cut -c1-32)
  [ "${#raw}" -eq 32 ] || return 1
  printf '%s%s]\n' "$FM_CLASSIFY_DECISION_CUTOVER_MARK_PREFIX_DEFAULT" "$raw"
}

fm_decision_cutover_append_status() {  # <status-file> <marker-line> <state-device>
  local f=$1 marker=$2 state_device=$3 marker_id
  marker_id=$(fm_decision_marker_line_id "$marker") || return 1
  # shellcheck disable=SC2016
  perl -MFcntl=:DEFAULT,:flock,:mode -e '
    my ($path, $marker, $expected_device, $lib, $bash, $marker_id) = @ARGV;
    sysopen(my $file, $path, O_RDWR | O_APPEND | O_NOFOLLOW) or do {
      print "identity-refused\n";
      exit 0;
    };
    flock($file, LOCK_EX) or do {
      print "identity-refused\n";
      exit 0;
    };

    sub identity_ok {
      my @descriptor = stat($file);
      my @path = lstat($path);
      return 0 unless @descriptor && @path;
      return 0 unless S_ISREG($descriptor[2]) && S_ISREG($path[2]);
      return 0 unless $descriptor[3] == 1 && $path[3] == 1;
      return 0 unless "$descriptor[0]" eq "$expected_device";
      return 0 unless $descriptor[0] == $path[0] && $descriptor[1] == $path[1];
      return 1;
    }

    sub classifier {
      my ($function) = @_;
      sysseek($file, 0, 0) or die "seek";
      pipe(my $reader, my $writer) or die "pipe";
      my $pid = fork();
      die "fork" unless defined $pid;
      if ($pid == 0) {
        close $reader;
        open(STDIN, "<&", fileno($file)) or exit 125;
        open(STDOUT, ">&", fileno($writer)) or exit 125;
        close $writer;
        exec $bash, "-c", q{. "$1"; "$2"}, "_", $lib, $function;
        exit 125;
      }
      close $writer;
      local $/;
      my $output = <$reader>;
      close $reader;
      waitpid($pid, 0);
      return ($? >> 8, defined($output) ? $output : "");
    }

    identity_ok() or do {
      print "identity-refused\n";
      exit 0;
    };

    for (1 .. 16) {
      my @before = stat($file);
      @before or die "stat";
      my ($marker_status, $stream) = classifier("_fm_decision_stream_id_stream");
      $stream =~ s/\n+\z//;
      if ($marker_status == 0) {
        print "current\t$stream\n";
        exit 0;
      }
      if ($marker_status == 2) {
        print "ambiguous\n";
        exit 0;
      }
      $marker_status == 1 or die "marker classifier";

      if ($before[7] > 0) {
        sysseek($file, -1, 2) or die "tail seek";
        sysread($file, my $last, 1) == 1 or die "tail read";
        if ($last ne "\n") {
          print "unterminated\n";
          exit 0;
        }
      }

      my ($decision_status) = classifier("_fm_status_stream_has_open_needs_decision");
      if ($decision_status == 0) {
        print "open-decision\n";
        exit 0;
      }
      $decision_status == 1 or die "decision classifier";

      my @after = stat($file);
      @after or die "stat";
      next unless $before[7] == $after[7];
      identity_ok() or do {
        print "identity-refused\n";
        exit 0;
      };

      my $record = "$marker\n";
      my $written = syswrite($file, $record);
      unless (defined($written) && $written == length($record)) {
        print "append-failed\n";
        exit 1;
      }
      my ($confirm_status, $confirmed) = classifier("_fm_decision_stream_id_stream");
      $confirmed =~ s/\n+\z//;
      unless ($confirm_status == 0 && $confirmed eq $marker_id) {
        print "append-unverified\n";
        exit 1;
      }
      print "appended\t$confirmed\n";
      exit 0;
    }
    print "busy\n";
    exit 0;
  ' "$f" "$marker" "$state_device" \
    "$_FM_CLASSIFY_LIB_DIR/fm-classify-lib.sh" "${BASH:-bash}" "$marker_id" 2>/dev/null
}

fm_decision_cutover_ensure_status() {  # <status-file>
  local f=$1 parent marker
  parent=${f%/*}
  [ "$parent" != "$f" ] || return 1
  if [ ! -e "$parent" ] && [ ! -L "$parent" ]; then
    mkdir -p "$parent" || return 1
  fi
  [ -d "$parent" ] && [ ! -L "$parent" ] || return 1
  if [ -e "$f" ] || [ -L "$f" ]; then
    [ -f "$f" ] && [ ! -L "$f" ] || return 1
    return 0
  fi
  marker=$(fm_decision_status_marker) || return 1
  if ( set -C; printf '%s\n' "$marker" > "$f" ) 2>/dev/null; then
    fm_decision_stream_id "$f" >/dev/null || return 1
    return 0
  fi
  [ -f "$f" ] && [ ! -L "$f" ] || return 1
  return 0
}

# Drop the record for <key> from a newline-terminated
# "<key>\t<verb>\t<instance>\t<authority>\t<note>" set.
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
# Print the internal record currently held for <key>, or nothing.
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
# answer-issuance boundary. The internal "--with-authority" view also exposes
# whether the opening sits before or after the cutover marker. Pure read of the
# file and of the paired answer records; no mutation.
# This is the durable open-set the fleet snapshot and any point-in-time consumer must use
# instead of trusting the last status line.
#
# A post-cutover needs-decision request additionally requires a correlated
# answer token to close (see the answer-correlation contract above), so an
# uncorrelated resolution leaves it open. A blocked line still closes on a
# plain keyed resolution: clearing a blocker is work, not an exercise of
# authority.
# Fold ONE status line into an existing open set, applying the same
# needs-decision/blocked-opens, resolved/captain-held-closes rule
# status_open_decisions documents above, plus the answer-correlation rule.
# This is the ONE place the per-line open/resolved rule is written; the
# whole-file fold (status_open_decisions) and the incremental cursor-backed fold
# (status_open_decisions_incremental) both call this instead of re-deriving the
# rule, so the two consumption strategies can never drift apart on semantics.
#
# The internal record is "<key>\t<verb>\t<instance>\t<authority>\t<note>". The
# caller owns the cross-line state the rule needs - the physical line <position>,
# the stream id assigned by a marker line, and whether that marker has been seen
# (<authority> legacy or correlated) - because those are the only three facts a
# resumable fold has to carry across a byte cursor. Reading them as arguments is
# what lets the incremental fold reach byte-identical results to the whole-file
# fold from a persisted checkpoint.
#
# Not a pure text transform in one respect: closing a correlated needs-decision
# consults <answers-file> through fm_decision_answer_matches, because only that
# record can prove a resolution carried authority minted for this exact opening.
_fm_decision_fold_line() {  # <open-set> <line> <resolve> <held> <answers> <position> <stream-id> <authority>
  local open=$1 line=$2 resolve=$3 held=$4 answers=$5 position=$6 stream=$7 authority=$8
  local verb key note stripped instance ans
  local held_rec held_fields held_verb held_instance held_authority
  stripped=${line//[[:space:]]/}
  [ -n "$stripped" ] || { printf '%s' "$open"; return 0; }
  verb=$(status_line_verb "$line")
  key=$(_fm_decision_key "$line") || { printf '%s' "$open"; return 0; }
  case "$verb" in
    needs-decision|blocked)
      note=$(status_line_note "$line")
      instance=$(fm_decision_instance_id "$position" "$stream") || {
        printf '%s' "$open"; return 0
      }
      open=$(_fm_decision_drop "$open" "$key")
      [ -n "$open" ] && open="${open}"$'\n'
      open="${open}${key}"$'\t'"${verb}"$'\t'"${instance}"$'\t'"${authority}"$'\t'"${note}"$'\n'
      ;;
    "$resolve")
      # Only a correlated answer closes a request for AUTHORITY. A blocked line
      # still closes on a plain keyed resolution: clearing a blocker is work,
      # not an exercise of authority.
      if held_rec=$(_fm_decision_get "$open" "$key"); then
        held_fields=${held_rec#*$'\t'}
        held_verb=${held_fields%%$'\t'*}
        held_fields=${held_fields#*$'\t'}
        held_instance=${held_fields%%$'\t'*}
        held_fields=${held_fields#*$'\t'}
        held_authority=${held_fields%%$'\t'*}
        if [ "$held_verb" = needs-decision ] && [ "$held_authority" = correlated ]; then
          ans=$(_fm_decision_answer "$line")
          fm_decision_answer_matches "$answers" "$ans" "$key" "$held_instance" || {
            printf '%s' "$open"; return 0
          }
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
  printf '%s' "$open"
}

# Project the internal 5-field open set onto a caller-chosen view.
# Default is the historical "<key>\t<verb>\t<note>" shape every existing
# consumer and both scan wrappers already read.
_fm_decision_project() {  # <open-set> [--with-instance|--with-authority]
  local open=$1 view=${2:-} k v i a n
  while IFS=$'\t' read -r k v i a n || [ -n "$k" ]; do
    [ -n "$k" ] || continue
    case "$view" in
      --with-instance)  printf '%s\t%s\t%s\t%s\n' "$k" "$v" "$i" "$n" ;;
      --with-authority) printf '%s\t%s\t%s\t%s\t%s\n' "$k" "$v" "$i" "$a" "$n" ;;
      *)                printf '%s\t%s\t%s\n' "$k" "$v" "$n" ;;
    esac
  done <<EOF
$open
EOF
}

# Fold the WHOLE status stream into the set of decisions still open. Prints one
# TAB-separated "<key>\t<verb>\t<summary>" line per still-open decision, in
# most-recently-opened-last order; prints nothing when none are open. Pure read of
# the file, no globals beyond the optional FM_CLASSIFY_RESOLVE_VERB override. This
# is the durable open-set the fleet snapshot and any point-in-time consumer must use
# instead of trusting the last status line.
# The scan_open_decisions wrapper below enumerates a whole directory rather than
# a single caller-chosen path, so a status file that is itself a symlink (e.g.
# escaping the state directory) is rejected outright with a plain [ -L ] check
# before any read - a cheap builtin, unlike fm_wake_latest_event's O_NOFOLLOW
# subprocess read, which exists for that function's much narrower payload-driven
# path resolution rather than this directory-local glob.
# Fold a status STREAM (stdin) into the still-open set. Separate from the
# file-path entry point below because the cutover writer folds the very file
# descriptor it holds locked, so it cannot reopen the path by name.
_fm_status_open_decisions_stream() {  # <answers-file> [--with-instance|--with-authority]
  local answers=$1 view=${2:-} line resolve held open=''
  local position=0 stream='' authority=legacy marker_id
  case "$view" in
    ''|--with-instance|--with-authority) ;;
    *) return 2 ;;
  esac
  resolve=${FM_CLASSIFY_RESOLVE_VERB:-$FM_CLASSIFY_RESOLVE_VERB_DEFAULT}
  held=${FM_CLASSIFY_CAPTAIN_HELD_VERB:-$FM_CLASSIFY_CAPTAIN_HELD_VERB_DEFAULT}
  while IFS= read -r line || [ -n "$line" ]; do
    position=$((position + 1))
    # Assign the stream id only from a VALID marker. Assigning the command
    # substitution unconditionally would clear it on every ordinary line,
    # because a failed fm_decision_marker_line_id still substitutes empty -
    # which silently demoted every post-cutover opening to a legacy positional
    # instance while authority stayed correlated.
    if marker_id=$(fm_decision_marker_line_id "$line"); then
      stream=$marker_id
      authority=correlated
      continue
    fi
    open=$(_fm_decision_fold_line "$open" "$line" "$resolve" "$held" \
      "$answers" "$position" "$stream" "$authority")
  done
  _fm_decision_project "$open" "$view"
}

status_open_decisions() {  # <status-file> [--with-instance|--with-authority]
  local f=$1 view=${2:-} answers
  [ -f "$f" ] && [ -r "$f" ] && [ ! -L "$f" ] || return 0
  answers=$(fm_decision_answers_file "$f")
  _fm_status_open_decisions_stream "$answers" "$view" < "$f"
}

# Print one row per folded open token-era needs-decision occurrence:
# "<file>\t<task>\t<instance>\t<key>\t<summary>".
scan_open_needs_decisions() {  # <state>
  local state=$1 f task key instance summary
  for f in "$state"/*.status; do
    [ -e "$f" ] || continue
    task=$(basename "$f"); task="${task%.status}"
    while IFS=$'\t' read -r key instance summary || [ -n "$key" ]; do
      [ -n "$key" ] || continue
      printf '%s\t%s\t%s\t%s\t%s\n' "$f" "$task" "$instance" "$key" "$summary"
    done <<EOF
$(status_open_token_needs_decisions "$f")
EOF
  done
  return 0
}

# Print one row per folded open decision or blocker supervision occurrence:
# "<file>\t<task>\t<verb>\t<instance>\t<key>\t<summary>".
# Fleet-wide wrapper around status_open_decisions: scans every task's status
# log under <state> and prefixes each still-open decision with its owning task
# id, so a per-wake or per-session surface can print the consolidated open set
# without re-walking the fold itself. A thin directory scan only - the fold
# above remains the ONE place the open/resolved semantics are decided. Prints
# one "<task>\t<key>\t<verb>\t<note>" line per open decision, in glob (task id)
# order; prints nothing when none are open.
scan_open_decisions() {  # <state>
  local state=$1 f task open line
  for f in "$state"/*.status; do
    [ -e "$f" ] || continue
    task=$(basename "$f"); task="${task%.status}"
    open=$(status_open_decisions "$f") || continue
    [ -n "$open" ] || continue
    while IFS= read -r line; do
      [ -n "$line" ] || continue
      printf '%s\t%s\n' "$task" "$line"
    done <<EOF
$open
EOF
  done
  return 0
}

# --- incremental (cursor-backed) open-decisions fold ------------------------
#
# status_open_decisions above re-reads and re-folds a status file's ENTIRE
# lifetime on every call, so its cost grows with total log size. A per-drain
# fleet-wide scan using that whole-file function would pay that cost for every
# task on every wake, which grows unbounded as tasks run longer and accumulate
# status history. status_open_decisions_incremental and scan_open_decisions_incremental
# below are the bounded-cost siblings used for that per-drain path: each call
# reads only the bytes appended to a status file since its own last call (a
# persisted per-file byte cursor) and folds just those new lines into a
# persisted running open-set, via the exact same _fm_decision_fold_line rule
# status_open_decisions uses - so the two strategies can never disagree on what
# is open. Cost is bounded by NEW appends since the last drain, not by the
# status file's total lifetime size.
#
# Correctness invariant (unchanged from the whole-file fold): an open decision
# is dropped ONLY by an explicit resolved/captain-held line for its exact key,
# never by cursor advancement, age, or being buried under later appends - the
# persisted open-set carries every still-open key forward across calls
# regardless of how much new unrelated log content has since been folded in.
#
# Cursor invalidation is deliberately minimal, matching how status files are
# ACTUALLY used in this repo: every one is created once (`>`) and only ever
# appended to (`>>`) - never replaced, renamed, or rewritten in place. So the
# only two ways a cursor can go stale are a shrink (truncated) or the file at
# this path being a different file than before (replaced/rotated/recreated),
# which a changed device+inode makes an O(1) check via a single `stat` call -
# no content hashing, no re-reading the consumed prefix. Either signal falls
# back to a full re-fold of the whole current file from byte 0 - byte for byte
# what status_open_decisions itself would compute - and rewrites the cursor
# from that clean baseline. A same-inode, same-size, in-place byte edit is NOT
# detected; that is a deliberately accepted gap because no code path in this
# repo ever does that to a status file.
#
# The other real failure mode is OUR OWN read failing (a stat/wc/tail I/O
# error), not a malformed writer: every such read here is checked, and on
# failure this reports the already-trusted persisted set unchanged rather than
# risking a silent invalidation that would wipe it - never a bare "empty" as if
# nothing were open.
#
# Not a pure status-file read: this writes/rewrites the sibling cursor file as a
# side effect (state/.<task>.open-decisions-cursor), the library's second
# documented exception to the pure-read rule after crew_absorb_class. The write
# is atomic (temp file + rename), so a crash between calls leaves either the
# prior cursor or the new one, never a partial one. bin/fm-wake-drain.sh calls
# this only after releasing the wake-queue lock, so a hypothetical race between
# two overlapping drains can at worst redo a little folding work twice - never
# drop an open decision - because a losing writer's offset can only ever be
# equal to or behind an already-recorded byte position, and the next call
# re-derives from whatever offset actually landed on disk.
_fm_open_decisions_cursor_path() {  # <status-file>
  local f=$1 dir base
  dir=$(dirname "$f")
  base=$(basename "$f")
  printf '%s/.%s.open-decisions-cursor' "$dir" "${base%.status}"
}

# Portable device:inode identity for the rotation/recreation check below.
_fm_open_decisions_file_ident() {  # <file> -> "dev:inode", empty on I/O failure
  local f=$1
  if [ "$(uname -s 2>/dev/null)" = Darwin ]; then
    LC_ALL=C stat -f '%d:%i' "$f" 2>/dev/null
  else
    LC_ALL=C stat -c '%d:%i' "$f" 2>/dev/null
  fi
}

status_open_decisions_incremental() {  # <status-file>
  local f=$1 cf offset ident open='' trusted_open='' cursor_data rest header
  local size cur_ident resolve held answers chunk_file chunk_size line
  local position stream authority marker_id have_offset have_ident have_position
  local have_stream have_authority
  [ -f "$f" ] && [ -r "$f" ] && [ ! -L "$f" ] || return 0
  cf=$(_fm_open_decisions_cursor_path "$f")
  offset=0
  ident=''
  position=0
  stream=''
  authority=legacy
  # The cursor header carries every piece of cross-line state the fold needs to
  # resume: the byte offset and file identity, plus the physical line position,
  # the stream id, and the legacy/correlated authority the marker established.
  # A cursor missing any of them (for example one written before correlation was
  # folded here) is treated as absent and re-folded from byte 0 rather than
  # resumed against unknown state, because guessing a position would mint the
  # wrong occurrence instance for every later opening.
  if [ -f "$cf" ] && [ -r "$cf" ] && [ ! -L "$cf" ]; then
    if cursor_data=$(LC_ALL=C command cat "$cf" 2>/dev/null); then
      have_offset=0; have_ident=0; have_position=0; have_stream=0; have_authority=0
      rest=$cursor_data
      while [ -n "$rest" ]; do
        header=${rest%%$'\n'*}
        case "$header" in
          offset=*)
            offset=${header#offset=}
            case "$offset" in ''|*[!0-9]*) offset=0 ;; *) have_offset=1 ;; esac
            ;;
          ident=*)    ident=${header#ident=};    have_ident=1 ;;
          position=*)
            position=${header#position=}
            case "$position" in ''|*[!0-9]*) position=0 ;; *) have_position=1 ;; esac
            ;;
          stream=*)   stream=${header#stream=};  have_stream=1 ;;
          authority=*)
            authority=${header#authority=}
            case "$authority" in legacy|correlated) have_authority=1 ;; esac
            ;;
          *) break ;;
        esac
        case "$rest" in
          *$'\n'*) rest=${rest#*$'\n'} ;;
          *) rest=''; break ;;
        esac
      done
      if [ "$have_offset" = 1 ] && [ "$have_ident" = 1 ] && [ "$have_position" = 1 ] \
        && [ "$have_stream" = 1 ] && [ "$have_authority" = 1 ]; then
        open=$rest
        trusted_open=$open
      else
        offset=0; ident=''; position=0; stream=''; authority=legacy; open=''
      fi
    fi
  fi

  # A stat/size-read failure is a genuine I/O error, not "the file is empty" -
  # report the already-trusted persisted set unchanged rather than risking a
  # silent invalidation that would wipe it.
  cur_ident=$(_fm_open_decisions_file_ident "$f") \
    || { _fm_decision_project "$trusted_open"; return 0; }
  [ -n "$cur_ident" ] || { _fm_decision_project "$trusted_open"; return 0; }
  size=$(LC_ALL=C wc -c < "$f" 2>/dev/null) \
    || { _fm_decision_project "$trusted_open"; return 0; }
  size=${size//[[:space:]]/}
  case "$size" in ''|*[!0-9]*) _fm_decision_project "$trusted_open"; return 0 ;; esac

  if [ -z "$ident" ] || [ "$ident" != "$cur_ident" ] || [ "$offset" -gt "$size" ]; then
    offset=0
    open=''
    position=0
    stream=''
    authority=legacy
  fi

  if [ "$offset" -lt "$size" ]; then
    chunk_file="$cf.read.$$"
    tail -c "+$((offset + 1))" "$f" > "$chunk_file" 2>/dev/null \
      || { rm -f "$chunk_file"; _fm_decision_project "$trusted_open"; return 0; }
    chunk_size=$(LC_ALL=C wc -c < "$chunk_file" 2>/dev/null) \
      || { rm -f "$chunk_file"; _fm_decision_project "$trusted_open"; return 0; }
    chunk_size=${chunk_size//[[:space:]]/}
    case "$chunk_size" in
      ''|*[!0-9]*) rm -f "$chunk_file"; _fm_decision_project "$trusted_open"; return 0 ;;
    esac
    # Test-only observability seam (off by default, no production behavior
    # change): when set, records exactly how many bytes THIS call folded, so a
    # test can assert the incremental path stays bounded by new appends rather
    # than re-reading the whole file, without relying on timing or source text.
    [ -n "${FM_OPEN_DECISIONS_READ_PROBE:-}" ] \
      && printf '%s\t%s\n' "$f" "$chunk_size" >> "$FM_OPEN_DECISIONS_READ_PROBE"
    resolve=${FM_CLASSIFY_RESOLVE_VERB:-$FM_CLASSIFY_RESOLVE_VERB_DEFAULT}
    held=${FM_CLASSIFY_CAPTAIN_HELD_VERB:-$FM_CLASSIFY_CAPTAIN_HELD_VERB_DEFAULT}
    answers=$(fm_decision_answers_file "$f")
    while IFS= read -r line || [ -n "$line" ]; do
      position=$((position + 1))
      if marker_id=$(fm_decision_marker_line_id "$line"); then
        stream=$marker_id
        authority=correlated
        continue
      fi
      open=$(_fm_decision_fold_line "$open" "$line" "$resolve" "$held" \
        "$answers" "$position" "$stream" "$authority")
    done < "$chunk_file"
    rm -f "$chunk_file"
    {
      printf 'offset=%s\n' "$size"
      printf 'ident=%s\n' "$cur_ident"
      printf 'position=%s\n' "$position"
      printf 'stream=%s\n' "$stream"
      printf 'authority=%s\n' "$authority"
      # An `if` (not `[ -n "$open" ] && printf ...`) so the group's exit status
      # is always 0 even when open is empty (fully resolved) - a bare `&&`
      # there would make the whole group fail on that condition, silently
      # skipping the mv below and leaving the cursor stuck on the OLD offset.
      if [ -n "$open" ]; then printf '%s' "$open"; fi
    } > "$cf.tmp.$$" && mv -f "$cf.tmp.$$" "$cf"
  fi
  _fm_decision_project "$open"
}

# Incremental sibling of scan_open_decisions: same fleet-wide directory walk and
# output shape ("<task>\t<key>\t<verb>\t<note>" per open decision), but folds
# each task's status log through status_open_decisions_incremental instead of
# the whole-file status_open_decisions, so a fleet-wide per-drain scan stays
# bounded by new appends rather than total lifetime log size across every task.
scan_open_decisions_incremental() {  # <state>
  local state=$1 f task open line
  for f in "$state"/*.status; do
    [ -e "$f" ] || continue
    task=$(basename "$f"); task="${task%.status}"
    open=$(status_open_decisions_incremental "$f") || continue
    [ -n "$open" ] || continue
    while IFS= read -r line; do
      [ -n "$line" ] || continue
      printf '%s\t%s\n' "$task" "$line"
    done <<EOF
$open
EOF
  done
  return 0
}

status_open_needs_decisions() {  # <status-file>
  local f=$1 key verb instance summary
  while IFS=$'\t' read -r key verb instance summary || [ -n "$key" ]; do
    [ "$verb" = needs-decision ] || continue
    printf '%s\t%s\t%s\n' "$key" "$instance" "$summary"
  done <<EOF
$(status_open_decisions "$f" --with-instance)
EOF
}

status_open_token_needs_decisions() {  # <status-file>
  local f=$1 stream answers key verb instance authority summary
  stream=$(fm_decision_stream_id "$f") || return 0
  answers=$(fm_decision_answers_file "$f")
  while IFS=$'\t' read -r key verb instance authority summary || [ -n "$key" ]; do
    [ -n "$key" ] || continue
    [ "$verb" = needs-decision ] || continue
    [ "$authority" = correlated ] || continue
    printf '%s\t%s.%s\t%s\n' "$key" "$stream" "$instance" "$summary"
  done <<EOF
$(_fm_status_open_decisions_stream "$answers" --with-authority < "$f")
EOF
}

status_open_supervision_decisions() {  # <status-file>
  local f=$1 stream raw key verb instance summary
  stream=$(fm_decision_stream_id "$f" 2>/dev/null || true)
  if [ -z "$stream" ]; then
    [ -f "$f" ] && [ ! -L "$f" ] || return 0
    raw=$(printf 'legacy-status:%s' "$f" | fm_decision_hash_text) || return 0
    stream=$(printf '%s' "$raw" | cut -c1-32)
    [ "${#stream}" -eq 32 ] || return 0
  fi
  while IFS=$'\t' read -r key verb instance summary || [ -n "$key" ]; do
    [ -n "$key" ] || continue
    printf '%s\t%s\t%s.%s\t%s\n' "$key" "$verb" "$stream" "$instance" "$summary"
  done <<EOF
$(status_open_decisions "$f" --with-instance)
EOF
}

status_has_open_token_needs_decision() {  # <status-file>
  local key _occurrence _summary
  while IFS=$'\t' read -r key _occurrence _summary || [ -n "$key" ]; do
    [ -n "$key" ] && return 0
  done <<EOF
$(status_open_token_needs_decisions "$1")
EOF
  return 1
}

status_latest_decision_is_open_occurrence() {  # <status-file> [needs-decision|blocked]
  local f=$1 line marker stripped latest='' position=0 latest_position=0
  local expected=${2:-} stream='' latest_stream='' key verb instance
  local open_key open_verb open_instance _summary
  [ -f "$f" ] && [ ! -L "$f" ] || return 1
  while IFS= read -r line || [ -n "$line" ]; do
    position=$((position + 1))
    if marker=$(fm_decision_marker_line_id "$line"); then
      stream=$marker
      continue
    fi
    stripped=${line//[[:space:]]/}
    [ -n "$stripped" ] || continue
    latest=$line
    latest_position=$position
    latest_stream=$stream
  done < "$f"
  verb=$(status_line_verb "$latest")
  case "$verb" in needs-decision|blocked) ;; *) return 1 ;; esac
  [ -z "$expected" ] || [ "$verb" = "$expected" ] || return 1
  [ "$expected" != needs-decision ] || [ -n "$latest_stream" ] || return 1
  key=$(_fm_decision_key "$latest") || return 1
  instance=$(fm_decision_instance_id "$latest_position" "$latest_stream") || return 1
  while IFS=$'\t' read -r open_key open_verb open_instance _summary || [ -n "$open_key" ]; do
    [ "$open_key" = "$key" ] || continue
    [ "$open_verb" = "$verb" ] || continue
    [ "$open_instance" = "$instance" ] || continue
    return 0
  done <<EOF
$(status_open_decisions "$f" --with-instance)
EOF
  return 1
}

status_latest_needs_decision_is_open_token_occurrence() {  # <status-file>
  fm_decision_stream_id "$1" >/dev/null || return 1
  status_latest_decision_is_open_occurrence "$1" needs-decision
}

status_has_open_needs_decision() {  # <status-file>
  local key _instance _summary
  while IFS=$'\t' read -r key _instance _summary || [ -n "$key" ]; do
    [ -n "$key" ] && return 0
  done <<EOF
$(status_open_needs_decisions "$1")
EOF
  return 1
}

_fm_status_stream_has_open_needs_decision() {
  local open key _verb _instance _summary
  open=$(_fm_status_open_decisions_stream /dev/null --with-instance)
  while IFS=$'\t' read -r key _verb _instance _summary || [ -n "$key" ]; do
    [ "$_verb" = needs-decision ] || continue
    [ -n "$key" ] && return 0
  done <<EOF
$open
EOF
  return 1
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
# Fold structured status, authoritative current state, and endpoint liveness into
# one idle-supervision precedence verdict. Callers supply crew_absorb_class's
# current verdict and the backend-neutral fm_backend_agent_alive verdict so this
# owner stays independent of runtime adapters. Prints exactly one token:
#   actionable - an open needs-decision/blocked event or current terminal status;
#   working    - authoritative run-step/pane work outranks an old pause line;
#   paused     - a current declared pause on a live endpoint, or a verified
#                captain-held transfer whose agent has exited;
#   none       - no safe absorb proof, including dead/unknown ordinary endpoints.
# Open structured decisions outrank every later unrelated pause event. A plain
# paused: declaration outranks a visual human-block label only while current
# state still confirms paused and the endpoint is live; it never hides a dead or
# unreadable endpoint.
crew_supervision_precedence() {  # <status-file> <crew-absorb-class> <alive|dead|unknown>
  local f=$1 current=${2:-none} endpoint=${3:-unknown} last verb key _verb _instance _summary
  while IFS=$'\t' read -r key _verb _instance _summary || [ -n "$key" ]; do
    [ -n "$key" ] || continue
    printf 'actionable'
    return
  done <<EOF
$(status_open_decisions "$f" --with-instance)
EOF
  last=$(last_status_line "$f")
  if [ -n "$last" ] && status_is_captain_relevant "$last"; then
    printf 'actionable'
    return
  fi
  if status_is_paused "$last"; then
    if [ "$endpoint" != alive ]; then
      printf 'none'
    elif [ "$current" = working ]; then
      printf 'working'
    elif [ "$current" = paused ]; then
      printf 'paused'
    else
      printf 'none'
    fi
    return
  fi
  if [ "$current" = working ]; then
    printf 'working'
    return
  fi
  verb=$(status_line_verb "$last")
  if [ "$verb" = "${FM_CLASSIFY_CAPTAIN_HELD_VERB:-$FM_CLASSIFY_CAPTAIN_HELD_VERB_DEFAULT}" ] \
    && [ "$endpoint" = dead ]; then
    printf 'paused'
    return
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
