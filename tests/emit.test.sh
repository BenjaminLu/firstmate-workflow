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
finish
