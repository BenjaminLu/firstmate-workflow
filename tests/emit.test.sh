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

# 64 is what the OPTION LOOP exits, and nothing else in this script does
# - not yet. A flag with no value after it, and a flag fm-emit does not
# know: those are what this task owns, and pinning them is what stops
# the guard being removed later. Everything below the loop still exits 1
# and is pinned at 1 here, so the half-converted state is a fact the
# suite states rather than a thing nobody looked at; T-029 is where the
# rest moves, and this block is what will turn red when it does.
u="$(mktemp -d)"; mkdir -p "$u/state"
code() { FM_ROOT="$u" bash "$ROOT/bin/fm-emit.sh" "$@" >/dev/null 2>&1; printf '%s' "$?"; }
assert_eq "64" "$(code --actor x --type greenlit --en a --tw b --nope 1)" \
  "a flag fm-emit does not know is a usage error"
assert_eq "64" "$(code --actor x --type greenlit --en a --tw)" \
  "and so is a flag with nothing after it"
for bad in "--type greenlit --en a --tw b" "--actor x --en a --tw b" \
           "--actor x --type nosuchtype --en a --tw b" \
           "--actor x --type greenlit --data notjson --en a --tw b" \
           "--actor x --type greenlit --tw b" "--actor x --type greenlit --en a"; do
  # shellcheck disable=SC2086   # a command line, deliberately split
  assert_eq "1" "$(code $bad)" "everything below the loop still exits 1: $bad"
done
# and a refusal to write is 1 as well, which is the code the line above
# it shares - telling those two apart is exactly what T-029 is for
assert_eq "1" "$(FM_ROOT=/dev/null/nowhere bash "$ROOT/bin/fm-emit.sh" --actor x \
  --type greenlit --en a --tw b >/dev/null 2>&1; printf '%s' "$?")" \
  "a log it cannot write is 1 too"
rm -rf "$u"

# --- T-036: crew_status throttle coalesces identical heartbeats only -------
c="$(mktemp -d)"; mkdir -p "$c/state"
code_c() { FM_ROOT="$c" FM_CREW_STATUS_SECS=60 bash "$ROOT/bin/fm-emit.sh" "$@" >/dev/null 2>&1; printf '%s' "$?"; }
assert_eq "0" "$(code_c --actor w1 --task T-1 --type crew_status \
  --data '{"activity":{"en":"still running","zh-TW":"仍在跑"}}' \
  --en "heartbeat" --tw "心跳")" "crew_status writes the first heartbeat"
assert_eq "1" "$(wc -l < "$c/state/events.jsonl" | tr -d ' ')" "one crew_status line so far"
assert_eq "0" "$(code_c --actor w1 --task T-1 --type crew_status \
  --data '{"activity":{"en":"still running","zh-TW":"仍在跑"}}' \
  --en "heartbeat" --tw "心跳")" "an identical heartbeat inside the window is a quiet success"
assert_eq "1" "$(wc -l < "$c/state/events.jsonl" | tr -d ' ')" "identical heartbeats do not flood the log"
assert_eq "0" "$(code_c --actor w1 --task T-1 --type crew_status \
  --data '{"activity":{"en":"still running","zh-TW":"仍在跑"},"progress":{"done":2,"total":7}}' \
  --en "gates 2/7" --tw "關卡 2/7")" "a changed progress payload always writes"
assert_eq "2" "$(wc -l < "$c/state/events.jsonl" | tr -d ' ')" "bounded progress is not dropped by the throttle"
assert_eq "0" "$(code_c --actor w1 --task T-1 --type crew_status \
  --data '{"progress":67}' --en "fake" --tw "假")" "a bare percent payload is still accepted as an event"
assert_eq "3" "$(wc -l < "$c/state/events.jsonl" | tr -d ' ')" "refused bare percent is a distinct payload, so it writes"
rm -rf "$c"

finish
