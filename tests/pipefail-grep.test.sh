#!/usr/bin/env bash
# fm:lint-source  # this file runs the shape bin/ci.sh forbids, on purpose
# `producer | grep -q` under pipefail, shown rather than argued (T-103).
#
# tests/adapter-contract.test.sh's completeness loop was written this way
# and reported a signature that matched as unread - a different one on each
# CI run, because there it came down to whether printf had finished writing
# before grep left. Here the producer is made to still be writing when grep
# leaves, so the old shape misreports every time, and the here-string that
# replaced it is run against the same input.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=tests/lib.sh
. "$ROOT/tests/lib.sh"

d="$(mktemp -d)"
sigs='status 429|network error while|expired api key'
# every signature on the first three lines, then 8 MB more: far past what a
# pipe holds and what grep reads before it has its match, so the producer
# has most of its writing still to do when grep -q leaves
{ printf 'Error: status 429\nnetwork error while fetching\nexpired api key\n'
  head -c 8000000 /dev/zero | tr '\0' 'n'; printf '\n'
} > "$d/transcript"
broken_lines="$(cat "$d/transcript")"

# The loop as it was, with an external producer. bash's builtin printf
# only lost the race some of the time; cat on a file this size always does.
piped_unread() {
  local alt unread='' saved_ifs="$IFS"; IFS='|'
  for alt in $sigs; do
    cat "$d/transcript" 2>/dev/null | grep -qiE "$alt" || unread="$unread [$alt]"
  done
  IFS="$saved_ifs"; printf '%s' "$unread"
}
# the loop as it is now
herestring_unread() {
  local alt unread='' saved_ifs="$IFS"; IFS='|'
  for alt in $sigs; do
    grep -qiE "$alt" <<<"$broken_lines" || unread="$unread [$alt]"
  done
  IFS="$saved_ifs"; printf '%s' "$unread"
}

# the mechanism itself: a producer that never stops on its own is still
# writing when grep leaves, and pipefail reports the producer's death (141
# by SIGPIPE; a runner that ignores SIGPIPE gets a write error instead,
# which is just as much a failure, so only the zero is ruled out)
rc=0; yes 'status 429' 2>/dev/null | grep -qiE 'status 429' || rc=$?
assert_ne "0" "$rc" "yes | grep -q fails under pipefail although grep matched"

for run in 1 2 3; do
  assert_eq " [status 429] [network error while] [expired api key]" "$(piped_unread)" \
    "run $run: the piped loop calls every matching signature unread"
  assert_eq "" "$(herestring_unread)" \
    "run $run: the here-string loop finds every one"
done

rm -rf "$d"
finish
