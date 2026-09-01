#!/usr/bin/env bash
# fm-usage-ledger-lib.sh - the single owner of HOW firstmate's lifecycle scripts
# call the task-usage ledger.
#
# bin/fm-usage-ledger.sh owns the ledger's schema, safety, identity, and
# retention. This file owns only the call policy the lifecycle scripts share, so
# that policy is stated once instead of copied into every call site:
#
#   - The effective home is passed explicitly (home, state, and data), never
#     inherited, so a secondmate home or an override-driven test home always
#     records into its own ledger rather than resolving a different one.
#   - Recording is INSTRUMENTATION, never a gate. A launch that already
#     succeeded, a merge that already landed, and a cleanup whose safety checks
#     already passed must not be turned into a failure because an observability
#     record could not be written. So this helper always returns 0 and reports a
#     failure as a loud stderr warning naming the concrete consequence; the
#     ledger's own diagnostic is left on stderr underneath it.
#   - The spawn record is the durable anchor. It is written first, so a task
#     that is abandoned, preserved indefinitely, or whose later enrichment fails
#     is still attributable to a harness and model.
#
# Sourced by bin/fm-spawn.sh, bin/fm-teardown.sh, bin/fm-pr-check.sh,
# bin/fm-merge-local.sh, and bin/fm-merge-outcome-lib.sh. No side effects on
# source.

_FM_USAGE_LEDGER_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# fm_usage_ledger_record <home> <state> <data> <event> <task-id> [record args...]
# Always returns 0; see the call policy above.
fm_usage_ledger_record() {
  local home=$1 state=$2 data=$3 event=$4 task=$5
  shift 5
  if FM_HOME="$home" FM_STATE_OVERRIDE="$state" FM_DATA_OVERRIDE="$data" \
    "$_FM_USAGE_LEDGER_LIB_DIR/fm-usage-ledger.sh" record \
    --event "$event" --task "$task" "$@" >/dev/null; then
    return 0
  fi
  printf 'warning: the task-usage ledger did not record the %s event for %s; model and workflow analysis will be missing it\n' \
    "$event" "$task" >&2
  return 0
}
