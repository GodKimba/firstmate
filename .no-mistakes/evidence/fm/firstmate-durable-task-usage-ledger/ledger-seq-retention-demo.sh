#!/usr/bin/env bash
# Operator demo for the sequence guarantee the header of bin/fm-usage-ledger.sh
# states, after this round qualified it with the clock-regression condition.
#
# Header (bin/fm-usage-ledger.sh):
#   seq  assigned under the lock, strictly increasing, and not re-issued in a
#        store's lifetime as long as the record clock does not regress.
#        [...] A prune that keeps dated records instead continues from the last
#        record it kept, which is the store's high-water mark only because
#        appends land in increasing time order; a clock that jumps backwards can
#        leave a lower-numbered record behind the horizon of a higher-numbered
#        one it drops.
#
# Both halves below drive the real bin/fm-usage-ledger.sh executable. The only
# thing written by hand is the `at` timestamp of an already-appended record,
# which is exactly the byte a host clock decides; the store's serialized format
# is owned and documented by that same header.
set -u
WT_ROOT=${WT_ROOT:?}
HOME_DIR=$(mktemp -d "${TMPDIR:-/tmp}/fm-ledger-seq.XXXXXX")
mkdir -p "$HOME_DIR/data"
L() { FM_ROOT_OVERRIDE='' FM_HOME="$HOME_DIR" FM_DATA_OVERRIDE="$HOME_DIR/data" \
  "$WT_ROOT/bin/fm-usage-ledger.sh" "$@"; }
say() { printf '\n\033[1m%s\033[0m\n' "$*"; }
run() { printf '$ %s\n' "$*"; eval "$@"; }
seqs() { sed -n 's/.*"seq":\([0-9]*\),"at":\([0-9]*\),"event":"\([a-z-]*\)".*/  seq=\1 at=\2 event=\3/p' "$(L path)"; }

NOW=$(date +%s)
OLD=$((NOW - 500 * 86400))

say "A. MONOTONIC CLOCK - the guarantee as stated: a total prune must not let the next append reuse a pruned number."
L record --event spawn --task alpha-x1 --gen g1 >/dev/null
L record --event spawn --task alpha-x2 --gen g2 >/dev/null
run "seqs"
printf '\n(the whole store now ages past the 400-day horizon - a dormant home)\n'
sed -i "s/\"at\":[0-9]*/\"at\":$OLD/" "$(L path)"
run "L prune --days 400"
run "seqs"
printf '\n(the coverage marker is the one record retention keeps; it carries the high-water mark)\n'
L record --event spawn --task beta-x1 --gen g3 >/dev/null
run "seqs"
printf '\n-> next append is seq 4: neither 2 nor 3, the numbers the pruned records used.\n'

say "B. REGRESSED CLOCK - the condition the header now names."
HOME_DIR=$(mktemp -d "${TMPDIR:-/tmp}/fm-ledger-seq.XXXXXX"); mkdir -p "$HOME_DIR/data"
L record --event spawn --task gamma-x1 --gen g1 >/dev/null
L record --event spawn --task gamma-x2 --gen g2 >/dev/null
printf '(the host clock jumps backwards, so the LAST appended record carries the OLDEST time)\n'
sed -i "3s/\"at\":[0-9]*/\"at\":$OLD/" "$(L path)"
run "seqs"
run "L prune --days 400"
run "seqs"
L record --event spawn --task delta-x1 --gen g4 >/dev/null
run "seqs"
printf '\n-> seq 3 is issued a second time, to a different event. Retention kept two\n'
printf '   dated records, so the marker carried nothing, and the last record kept\n'
printf '   was no longer the high-water mark. `id` stays unique either way:\n'
run "sed -n 's/.*\"seq\":\\([0-9]*\\).*\"id\":\"\\([^\"]*\\)\".*/  seq=\\1 id=\\2/p' \"\$(L path)\""
printf '\n   This is precisely what the header now admits and previously claimed could\n'
printf '   not happen; `id`, the documented cross-export join key, is unaffected.\n'
run "L verify"
