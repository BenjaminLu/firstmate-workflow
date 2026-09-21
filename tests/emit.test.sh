#!/usr/bin/env bash
# fm-emit.sh is the only thing allowed to touch state/events.jsonl.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=tests/lib.sh
. "$ROOT/tests/lib.sh"
EMIT="$ROOT/bin/fm-emit.sh"

t="$(mktemp -d)"; export FM_ROOT="$t"
log="$t/state/events.jsonl"

assert_ok "'$EMIT' --actor firstmate --type dispatched --task T-004" "writes a minimal event"
assert_eq "1" "$(wc -l < "$log" | tr -d ' ')" "one line per event"
assert_ok "jq -e . '$log' >/dev/null" "the line is valid JSON"
assert_eq "dispatched" "$(jq -r .type "$log")" "carries the type"
ts="$(jq -r .ts "$log")"
assert_matches "$ts" '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9:]+Z$' "stamps an ISO timestamp"

assert_fail "'$EMIT' --actor firstmate --type teleported --task T-004" "rejects an unknown type"
assert_eq "1" "$(wc -l < "$log" | tr -d ' ')" "a rejected event is not written"

assert_fail "'$EMIT' --actor worker-1 --type merged --task T-001 --en 'only english'" \
  "rejects a summary that is missing zh-TW"
assert_fail "'$EMIT' --actor worker-1 --type merged --task T-001 --tw '只有中文'" \
  "rejects a summary that is missing en"
assert_ok "'$EMIT' --actor worker-1 --type merged --task T-001 --pr 1 --en 'merged' --tw '已合併'" \
  "accepts a complete bilingual summary"
assert_eq "merged" "$(jq -r 'select(.task=="T-001") | .summary.en' "$log" | head -1)" "keeps the en summary"
assert_eq "已合併" "$(jq -r 'select(.task=="T-001") | .summary["zh-TW"]' "$log" | head -1)" "keeps the zh-TW summary"
assert_eq "1" "$(jq -r 'select(.task=="T-001") | .pr' "$log" | head -1)" "keeps the pr number"

# the reason the lock exists
before=$(wc -l < "$log" | tr -d ' ')
for i in $(seq 1 20); do
  "$EMIT" --actor "worker-$i" --type commit_pushed --task "T-0$i" &
done
wait
after=$(wc -l < "$log" | tr -d ' ')
assert_eq "20" "$((after - before))" "20 concurrent writers lose no lines"
assert_ok "jq -e . '$log' >/dev/null" "every line is still valid JSON after the race"
assert_eq "20" "$(jq -r 'select(.type=="commit_pushed") | .actor' "$log" | sort -u | wc -l | tr -d ' ')" \
  "all 20 actors are present exactly once"

assert_fail "'$EMIT' --type dispatched --task T-1" "requires an actor"
assert_fail "'$EMIT' --actor x" "requires a type"

# nobody may write around it
cd "$ROOT" || exit 1
strays=$(grep -rnE '>>[[:space:]]*.*events\.jsonl' bin board 2>/dev/null | grep -v 'fm-emit.sh' | wc -l | tr -d ' ')
assert_eq "0" "$strays" "nothing appends to the log except fm-emit.sh"
rm -rf "$t"

# Two kinds of failure, two codes: 64 is "you called it wrong" and 1 is
# "it could not write". A caller that cannot tell them apart cannot react
# to either - one is fixed by a human, the other by trying again. No suite
# pinned these before, so the conversion could have gone either way
# unnoticed; `grep -n 'assert_eq \"1\"' tests/emit.test.sh` before this
# change returned only line-count and pr-number assertions.
u="$(mktemp -d)"; mkdir -p "$u/state"
code() { FM_ROOT="$u" bash "$ROOT/bin/fm-emit.sh" "$@" >/dev/null 2>&1; printf '%s' "$?"; }
assert_eq "64" "$(code --type greenlit --en a --tw b)" "no --actor is a usage error"
assert_eq "64" "$(code --actor x --en a --tw b)" "no --type is one too"
assert_eq "64" "$(code --actor x --type nosuchtype --en a --tw b)" "an unknown type is one"
assert_eq "64" "$(code --actor x --type greenlit --data 'not json' --en a --tw b)" \
  "so is --data that is not JSON"
assert_eq "64" "$(code --actor x --type greenlit --tw b)" "so is a summary with only zh-TW"
assert_eq "64" "$(code --actor x --type greenlit --en a)" "and one with only English"
assert_eq "64" "$(code --actor x --type greenlit --en a --tw b --nope 1)" "and an unknown flag"
# and a refusal to write is still 1, or the two codes would say one thing
assert_eq "1" "$(FM_ROOT=/dev/null/nowhere bash "$ROOT/bin/fm-emit.sh" --actor x \
  --type greenlit --en a --tw b >/dev/null 2>&1; printf '%s' "$?")" \
  "but a log it cannot write is not a usage error"
rm -rf "$u"

finish
