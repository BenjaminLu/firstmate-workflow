#!/usr/bin/env bash
# The captain merging in a browser has to reach the system by the system
# looking. Driven from recorded gh output, so the suite makes no network call.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=tests/lib.sh
. "$ROOT/tests/lib.sh"

fixture() {
  local d; d="$(mktemp -d)"; mkdir -p "$d/bin" "$d/state"
  cp "$ROOT/bin/fm-emit.sh" "$ROOT/bin/fm-sync-prs.sh" "$d/bin/"
  printf '%s' "$d"
}
# a gh that replays a recorded payload; one directory per recording
rec() { local dir="$1/gh-$2"; mkdir -p "$dir"
  { printf '#!/usr/bin/env bash\ncat <<'\''JSON'\''\n'; cat; printf 'JSON\n'; } > "$dir/gh"
  chmod +x "$dir/gh"; printf '%s' "$dir/gh"; }

d="$(fixture)"
MERGED="$(rec "$d" merged <<'J'
[{"number":8,"state":"MERGED","title":"T-005: the worker","headRefName":"t-005-worker","mergedAt":"2026-09-20T16:00:00Z"},
 {"number":9,"state":"OPEN","title":"T-006: the reviewer","headRefName":"t-006-review","mergedAt":null}]
J
)"
out="$(FM_ROOT="$d" FM_GH="$MERGED" "$d/bin/fm-sync-prs.sh" --repo "$d" 2>&1)"
assert_eq "0" "$?" "a sync exits 0"
assert_contains "$out" "merged #8" "it noticed the merge nobody told it about"
assert_contains "$out" "pr_opened #9" "and the open pull request"

log="$d/state/events.jsonl"
assert_eq "merged" "$(jq -r 'select(.pr==8)|.type' "$log")" "the merge is in the log"
assert_eq "T-005" "$(jq -r 'select(.pr==8)|.task' "$log")" "the task is derived from the branch name"
assert_eq "github" "$(jq -r 'select(.pr==8)|.actor' "$log")" "attributed to github, not to a person"
assert_ok "jq -e 'select(.pr==8)|.summary[\"zh-TW\"]' '$log' >/dev/null" "it carries both languages"

before="$(wc -l < "$log" | tr -d ' ')"
FM_ROOT="$d" FM_GH="$MERGED" "$d/bin/fm-sync-prs.sh" --repo "$d" >/dev/null 2>&1
assert_eq "$before" "$(wc -l < "$log" | tr -d ' ')" "running it twice writes nothing new"

# the same pull request moving on is a new event, not a duplicate
NOW="$(rec "$d" later <<'J'
[{"number":9,"state":"MERGED","title":"T-006: the reviewer","headRefName":"t-006-review","mergedAt":"2026-09-20T17:00:00Z"}]
J
)"
FM_ROOT="$d" FM_GH="$NOW" "$d/bin/fm-sync-prs.sh" --repo "$d" >/dev/null 2>&1
assert_eq "merged" "$(jq -r 'select(.pr==9 and .type=="merged")|.type' "$log")" "a pull request that later merges is recorded"

# failure must not poison the log
d2="$(fixture)"
BROKEN="$(mkdir -p "$d2/ghx" && printf '#!/usr/bin/env bash\nexit 1\n' > "$d2/ghx/gh" && chmod +x "$d2/ghx/gh" && printf '%s' "$d2/ghx/gh")"
assert_fail "FM_ROOT='$d2' FM_GH='$BROKEN' '$d2/bin/fm-sync-prs.sh' --repo '$d2'" "it exits non-zero when gh fails"
assert_fail "test -s '$d2/state/events.jsonl'" "and writes nothing"

d3="$(fixture)"
JUNK="$(rec "$d3" junk <<'J'
not json at all
J
)"
assert_fail "FM_ROOT='$d3' FM_GH='$JUNK' '$d3/bin/fm-sync-prs.sh' --repo '$d3'" "it rejects an unexpected response"
assert_fail "test -s '$d3/state/events.jsonl'" "and writes nothing then either"

# it goes through the one writer like everyone else
assert_ok "grep -q 'fm-emit.sh' '$ROOT/bin/fm-sync-prs.sh'" "it writes through fm-emit.sh"
rm -rf "$d" "$d2" "$d3"
finish
