#!/usr/bin/env bash
# Merge a task's PR after recording pr= and any available pr_head= through
# bin/fm-pr-check.sh, so teardown can verify landed work after squash merges.
# The full canonical GitHub PR URL is parsed by bin/fm-pr-lib.sh and the derived
# host, owner/repository, and PR number are passed to gh-axi.
#
# Merge method defaults to --squash when the caller passes none of --squash,
# --merge, --rebase, or --method after the optional -- separator. Extra args
# must not include --repo, -R, or --hostname because the target comes only from
# the URL.
# After gh-axi returns, the helper reads the current GitHub REST state. Exit 0
# means GitHub verifies the PR is merged; exit 3 means auto-merge is enabled on
# an open PR and the existing merge poll must keep watching; every unreadable or
# contradictory result exits 1 and preserves the task work.
# The shared gh-axi compatibility probe must pass immediately before mutation.
# Usage: fm-pr-merge.sh <task-id> <pr-url> [-- <extra gh-axi pr merge args>]
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"

# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"
# shellcheck source=bin/fm-gh-axi-lib.sh
. "$SCRIPT_DIR/fm-gh-axi-lib.sh"

if [ "$#" -lt 2 ]; then
  echo "error: invalid PR merge request" >&2
  exit 2
fi
ID=$1
RAW_URL=$2
# bin/fm-pr-lib.sh parses GitLab merge request URLs so the watcher can follow
# them, but this path still addresses only GitHub by owner/repository. The
# provider check holds that refusal exactly as it was until merge parity lands.
if ! fm_pr_task_id_valid "$ID" || ! fm_pr_url_parse "$RAW_URL" \
  || [ "$FM_PR_PROVIDER" != github ]; then
  echo "error: invalid PR merge request" >&2
  exit 2
fi
URL=$FM_PR_URL
PR_HOST=$FM_PR_HOST
PR_OWNER=$FM_PR_OWNER
PR_REPO=$FM_PR_REPO
PR_NUMBER=$FM_PR_NUMBER
shift 2
[ "${1:-}" = "--" ] && shift

caller_has_merge_method() {
  local arg
  for arg in "$@"; do
    case "$arg" in
      --squash|--merge|--rebase|--method|--method=*) return 0 ;;
    esac
  done
  return 1
}

state_field() {
  local output=$1 key=$2 count
  count=$(printf '%s\n' "$output" | awk -F': ' -v key="$key" '$1 == key { count++ } END { print count + 0 }')
  [ "$count" -eq 1 ] || return 1
  printf '%s\n' "$output" | awk -F': ' -v key="$key" '$1 == key { sub(/^[^:]*: /, ""); print }'
}

reject_target_overrides() {
  local arg
  for arg in "$@"; do
    case "$arg" in
      --repo|--repo=*|-R|-R?*)
        echo "error: extra merge arguments must not override the repository" >&2
        return 1
        ;;
      --hostname|--hostname=*)
        echo "error: extra merge arguments must not override the hostname" >&2
        return 1
        ;;
    esac
  done
}

reject_target_overrides "$@" || exit 1

# Task-derived paths are constructed only after the canonical ID validation.
META="$STATE/$ID.meta"
if [ ! -f "$META" ] || [ -L "$META" ]; then
  echo "error: task metadata is unavailable" >&2
  exit 1
fi

"$SCRIPT_DIR/fm-pr-check.sh" "$ID" "$URL"
grep -qxF "pr=$URL" "$META" || {
  echo "error: PR metadata recording failed" >&2
  exit 1
}

merge_args=()
if ! caller_has_merge_method "$@"; then
  merge_args=(--squash)
fi

if ! fm_gh_axi_compatible; then
  echo "error: gh-axi $(fm_gh_axi_min_version) or newer with api --jq support is required before PR merge; approve the gh-axi update and retry" >&2
  exit 1
fi

# gh-axi 0.1.28 labels every successful `gh pr merge` invocation as `merged`,
# including one that only enables auto-merge. Suppress that human-oriented label
# and establish the result from a fresh authoritative GitHub read instead.
MERGE_STATUS=0
GH_HOST="$PR_HOST" gh-axi pr merge "$PR_NUMBER" --repo "$PR_OWNER/$PR_REPO" \
  "${merge_args[@]+"${merge_args[@]}"}" "$@" >/dev/null || MERGE_STATUS=$?

if ! PR_STATE_OUTPUT=$(GH_HOST="$PR_HOST" gh-axi api "/repos/$PR_OWNER/$PR_REPO/pulls/$PR_NUMBER" --jq \
  '{state: .state, merged: .merged, merged_at: .merged_at, auto_merge_enabled: (.auto_merge != null)}'); then
  echo "error: GitHub PR state could not be verified after the merge request; task work is preserved" >&2
  exit 1
fi
PR_STATE=$(state_field "$PR_STATE_OUTPUT" state) || PR_STATE=
PR_MERGED=$(state_field "$PR_STATE_OUTPUT" merged) || PR_MERGED=
PR_MERGED_AT=$(state_field "$PR_STATE_OUTPUT" merged_at) || PR_MERGED_AT=
PR_AUTO_MERGE=$(state_field "$PR_STATE_OUTPUT" auto_merge_enabled) || PR_AUTO_MERGE=

case "$PR_STATE:$PR_MERGED:$PR_MERGED_AT" in
  closed:true:\"????-??-??T??:??:??Z\")
    printf 'merged: %s\n' "$URL"
    exit 0
    ;;
esac

if [ "$MERGE_STATUS" -ne 0 ]; then
  echo "error: GitHub merge command failed and the PR was not verified as merged; task work is preserved" >&2
  exit 1
fi

if [ "$PR_STATE" = open ] && [ "$PR_MERGED" = false ] \
  && [ "$PR_MERGED_AT" = null ] \
  && [ "$PR_AUTO_MERGE" = true ]; then
  printf 'auto-merge enabled: %s; waiting on checks\n' "$URL"
  exit 3
fi

echo "error: GitHub PR state was unreadable or contradicted the requested merge outcome; task work is preserved" >&2
exit 1
