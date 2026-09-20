#!/usr/bin/env bash
# Round three is where a review either converges or turns into nine rounds.
# Driven from recorded comment payloads, so the suite makes no network call.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=tests/lib.sh
. "$ROOT/tests/lib.sh"

fixture() {
  local d; d="$(mktemp -d)"; mkdir -p "$d/bin" "$d/state"
  cp "$ROOT/bin/fm-config.sh" "$ROOT/bin/fm-emit.sh" "$ROOT/bin/fm-protocol.sh" "$d/bin/"
  printf '%s' "$d"
}
# a gh that replays comments; one directory per recording so none overwrites another
# payloads below carry real carriage returns, because fm-protocol folds a
# multi-line review onto one record and unfolds it again
rec() { local dir="$1/gh-$2"; mkdir -p "$dir"
  { printf '#!/usr/bin/env bash\ncat <<%s\n' "'JSONX'"; cat; printf 'JSONX\n'; } > "$dir/gh"
  chmod +x "$dir/gh"; printf '%s' "$dir/gh"; }

run() { FM_ROOT="$1" FM_GH="$2" "$1/bin/fm-protocol.sh" check --task T-Z --pr 9 --round "${3:-3}" --repo "$1"; }
code() { run "$@" >/dev/null 2>&1; printf '%s' "$?"; }

d="$(fixture)"

# rounds one and two have nothing to enforce
NONE="$(rec "$d" none <<'J'
worker-1	nothing to see
J
)"
assert_eq "0" "$(code "$d" "$NONE" 1)" "round one is not policed"

# the worker starting round three without asking
assert_eq "3" "$(code "$d" "$NONE" 3)" "round three without the question is a violation"
assert_contains "$(jq -r 'select(.type=="protocol_violation")|.summary.en' "$d/state/events.jsonl")" \
  "without asking" "and it is recorded"

# asked, but the reviewer never closed the list
d2="$(fixture)"
ASKED="$(rec "$d2" asked <<'J'
worker-1	ASK-PASS-CRITERIA:T-Z
reviewer-1	a few things are wrong, I will tell you as I find them
J
)"
assert_eq "4" "$(code "$d2" "$ASKED")" "an unclosed list is a violation"

# the good path: asked, closed with a numbered list, then only numbered replies
d3="$(fixture)"
GOOD="$(rec "$d3" good <<'J'
worker-1	ASK-PASS-CRITERIA:T-Z
reviewer-1	Here is everything:1. name the helper2. cover the empty case3. drop the dead branchCRITERIA-COMPLETE:T-Z
reviewer-1	2. still not covered when the list is empty
reviewer-1	APPROVE:T-Z
J
)"
assert_eq "0" "$(code "$d3" "$GOOD")" "asking, closing, and citing items is clean"
assert_contains "$(jq -r 'select(.type=="criteria_returned")|.summary.en' "$d3/state/events.jsonl")" \
  "3 closed items" "it counts the items on the list"

# the thing this whole protocol exists to stop
d4="$(fixture)"
DRIP="$(rec "$d4" drip <<'J'
worker-1	ASK-PASS-CRITERIA:T-Z
reviewer-1	Everything:1. name the helper2. cover the empty caseCRITERIA-COMPLETE:T-Z
reviewer-1	while I am here, the logging is also wrong
J
)"
assert_eq "5" "$(code "$d4" "$DRIP")" "an off-list complaint after the list closes is a violation"
assert_contains "$(jq -r 'select(.type=="protocol_violation")|.summary.en' "$d4/state/events.jsonl")" \
  "off-list" "and the captain is told"

# a genuine regression is exempt, by name
d5="$(fixture)"
REG="$(rec "$d5" reg <<'J'
worker-1	ASK-PASS-CRITERIA:T-Z
reviewer-1	Everything:1. name the helperCRITERIA-COMPLETE:T-Z
reviewer-1	REGRESSION:T-Z the rename broke the caller in two places
J
)"
assert_eq "0" "$(code "$d5" "$REG")" "a marked regression is allowed off the list"

# and someone who is not the reviewer cannot trip it
d6="$(fixture)"
BYSTANDER="$(rec "$d6" bystander <<'J'
worker-1	ASK-PASS-CRITERIA:T-Z
reviewer-1	Everything:1. name the helperCRITERIA-COMPLETE:T-Z
passer-by	drive-by opinion with no numbers in it
J
)"
assert_eq "0" "$(FM_REVIEWER_LOGIN=reviewer-1 code "$d6" "$BYSTANDER")" \
  "a comment from anyone but the reviewer does not count"

rm -rf "$d" "$d2" "$d3" "$d4" "$d5" "$d6"
finish
