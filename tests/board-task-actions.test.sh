#!/usr/bin/env bash
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=tests/lib/project-storage.sh
. "$ROOT/tests/lib/project-storage.sh"
# shellcheck source=tests/lib/board.sh
. "$ROOT/tests/lib/board.sh"
XDG_CONFIG_HOME="$(safe_tmpdir)"; export XDG_CONFIG_HOME
# --- T-058: the captain parks or drops a task --------------------------------
# Its own fixture: every action here writes to the log, and the counts below
# are lines in that log, so nothing else may be writing to it.
f="$(safe_tmpdir)"; mkdir -p "$f/bin" "$f/state" "$f/design" "$f/board/public"
# fm-herdr.py: the stop path park and drop run (T-144)
cp "$ROOT/bin/fm-emit.sh" "$ROOT/bin/fm-config.sh" "$ROOT/bin/fm-herdr.py" "$f/bin/"; project_storage_fixture "$f/bin/"
cp -R "$ROOT/bin/lib" "$f/bin/"   # the lifeline the board starts merges and rounds under (T-151)
cp "$ROOT/board/server.ts" "$f/board/"
cp "$ROOT/board/public/index.html" "$f/board/public/"
fm_tasks_write /dev/stdin "$f/design/tasks" <<'J'
{"tasks":[{"id":"T-P1","title":"ready one","milestone":"M2","depends_on":[]},
          {"id":"T-P2","title":"waits on P1","milestone":"M2","depends_on":["T-P1"]},
          {"id":"T-P3","title":"at work","milestone":"M2","depends_on":[]},
          {"id":"T-P4","title":"ready two","milestone":"M2","depends_on":[]},
          {"id":"T-P5","title":"waits on P4","milestone":"M2","depends_on":["T-P4"]},
          {"id":"T-P6","title":"merged","milestone":"M2","depends_on":[]}]}
J
FM_ROOT="$f" "$f/bin/fm-emit.sh" --actor captain --type greenlit --en "go" --tw "開工" >/dev/null
FM_ROOT="$f" "$f/bin/fm-emit.sh" --actor worker-p --task T-P3 --type dispatched --en "on it" --tw "接下" >/dev/null
FM_ROOT="$f" "$f/bin/fm-emit.sh" --actor github --task T-P6 --type merged --pr 60 --en "merged" --tw "已合併" >/dev/null
plan() { ( cd "$f/design/tasks" && ls -A && cat -- *.json ) | cksum; }
plan_before="$(plan)"
FM_ROOT="$f" FM_PORT=0 bun run "$f/board/server.ts" > "$f/out" 2>&1 < /dev/null &
pidf=$!
PORTF="$(board_port "$f/out" "$pidf")"
# wait for the state it serves, not for a count of sleeps: the gate's pool
# can stretch a start well past ten seconds
endf=$(( $(date +%s) + 60 ))
until curl -sf "http://127.0.0.1:$PORTF/api/state" >/dev/null 2>&1; do
  [ "$(date +%s)" -le "$endf" ] && kill -0 "$pidf" 2>/dev/null || break
  sleep 0.05
done
sf() { curl -sf "http://127.0.0.1:$PORTF/api/state"; }
lines() { wc -l < "$f/state/events.jsonl" | tr -d ' '; }
# act TASK ACTION -> the HTTP status; the body lands in $f/resp
act() { wcurl "$PORTF" -s -o "$f/resp" -w '%{http_code}' -X POST -H 'content-type: application/json' \
  -d "{\"task\":\"$1\",\"action\":\"$2\"}" "http://127.0.0.1:$PORTF/tasks"; }
field() { jq -r --arg t "$1" ".tasks[]|select(.id==\$t)|$2" <<<"$(sf)"; }
last_event() { tail -1 "$f/state/events.jsonl"; }

# the server says which actions a card offers, so the page never guesses
assert_eq "park,drop" "$(field T-P1 '.actions|join(",")')" "a ready card offers park and drop"
assert_eq "park,drop" "$(field T-P2 '.actions|join(",")')" "a backlog card offers park and drop"
# T-118: any unfinished task can be set aside; a finished one only reopened
assert_eq "park,drop" "$(field T-P3 '.actions|join(",")')" "a card in flight offers park and drop too"
assert_eq "reopen" "$(field T-P6 '.actions|join(",")')" "a merged one offers only reopening"
assert_eq "false" "$(field T-P1 .confirm)" "untouched work with nobody aboard sets aside without asking"
assert_eq "true" "$(field T-P3 .confirm)" "a task with crew aboard asks first"

# park: a parked event from the captain, and the card leaves the lanes.
# With nobody aboard, the stop park runs stops nothing, and that is success.
assert_eq '{"stopped":[],"failed":[]}' "$(python3 "$f/bin/fm-herdr.py" stop "$f" --task T-P1 | jq -c .)" \
  "with no crew on the task, the stop park and drop run stops nothing and fails nothing"
n0="$(lines)"
assert_eq "200" "$(act T-P1 park)" "park answers 200 for a ready task"
assert_eq "$((n0 + 1))" "$(lines)" "park writes exactly one event"
assert_eq "parked captain T-P1" "$(jq -r '"\(.type) \(.actor) \(.task)"' <<<"$(last_event)")" \
  "it is a parked event, written by the captain, about that task"
assert_ne "" "$(jq -r '.summary.en // empty' <<<"$(last_event)")" "it carries an en summary"
assert_ne "" "$(jq -r '.summary["zh-TW"] // empty' <<<"$(last_event)")" "and a zh-TW one"
spk="$(sf)"
assert_eq "parked" "$(jq -r '.tasks[]|select(.id=="T-P1")|.stage' <<<"$spk")" "a parked task is in no lane"
assert_eq "unpark,drop" "$(jq -r '.tasks[]|select(.id=="T-P1")|.actions|join(",")' <<<"$spk")" \
  "a parked card offers unpark and drop"
assert_eq "1" "$(jq -r '.counts.parked' <<<"$spk")" "the parked group is counted"
assert_eq "T-P4" "$(jq -r '[.tasks[]|select(.stage=="ready")|.id]|join(",")' <<<"$spk")" \
  "and it is no longer counted as ready"
# its dependent names why it waits
assert_eq "T-P1:parked" "$(jq -r '.tasks[]|select(.id=="T-P2")|.blocked_by|map("\(.id):\(.stage)")|join(",")' <<<"$spk")" \
  "a task that depends on a parked task shows the parked task as its blocker"

# a second park is refused: nothing to park, nothing written
n1="$(lines)"
assert_eq "409" "$(act T-P1 park)" "parking a parked task is refused"
assert_eq "$n1" "$(lines)" "and writes nothing"

# unpark: an unparked event, and the card returns where its dependencies say
assert_eq "200" "$(act T-P1 unpark)" "unpark answers 200 for a parked task"
assert_eq "unparked captain T-P1" "$(jq -r '"\(.type) \(.actor) \(.task)"' <<<"$(last_event)")" \
  "it is an unparked event from the captain"
assert_eq "ready" "$(field T-P1 .stage)" "an unparked task with nothing to wait on is ready again"
assert_eq "" "$(field T-P2 '.blocked_by|map(select(.stage=="parked"))|map(.id)|join(",")')" \
  "and its dependent no longer names a parked blocker"
n2="$(lines)"
assert_eq "409" "$(act T-P1 unpark)" "unparking a task that is not parked is refused"
assert_eq "$n2" "$(lines)" "and writes nothing"
# a backlog card parks and unparks back to backlog
assert_eq "200" "$(act T-P2 park)" "a backlog task can be parked"
assert_eq "parked" "$(field T-P2 .stage)" "and is parked"
assert_eq "200" "$(act T-P2 unpark)" "and unparked"
assert_eq "backlog" "$(field T-P2 .stage)" "back to backlog, as its dependency says"

# T-118: a task in flight is set aside only once the captain confirms it, and
# a merged task is never parked, unparked or dropped
n3="$(lines)"
for a in park drop; do
  assert_eq "409" "$(act T-P3 "$a")" "$a without confirming is refused for a task with crew aboard"
  assert_eq "confirmRequired" "$(jq -r .code "$f/resp")" "and the refusal says to confirm first"
done
assert_eq "409" "$(act T-P3 unpark)" "unpark is refused for a task that is not parked"
for a in park unpark drop; do
  assert_eq "409" "$(act T-P6 "$a")" "$a is refused for a merged task"
done
assert_eq "$n3" "$(lines)" "a refused action writes nothing"
assert_eq "working" "$(field T-P3 .stage)" "and the task in flight is untouched"

# drop: the existing closed event, from the captain; the task leaves the lanes
assert_eq "200" "$(act T-P4 drop)" "drop answers 200 for a ready task"
assert_eq "closed captain T-P4" "$(jq -r '"\(.type) \(.actor) \(.task)"' <<<"$(last_event)")" \
  "a drop is the closed event, from the captain"
assert_eq "closed" "$(field T-P4 .stage)" "a dropped task is closed, in no lane"
# a closed task is final: no park, unpark or drop, only the reopening a
# wrong final state needs (T-118), behind its confirm step
assert_eq "reopen" "$(field T-P4 '.actions|join(",")')" "and offers nothing more than reopening"
assert_eq "T-P4:closed" "$(field T-P5 '.blocked_by|map("\(.id):\(.stage)")|join(",")')" \
  "a task that depends on a dropped task shows the dropped task as its blocker"
n4="$(lines)"
for a in park unpark drop; do
  assert_eq "409" "$(act T-P4 "$a")" "$a is refused for a dropped task"
done
assert_eq "$n4" "$(lines)" "and writes nothing"
# a parked task can be dropped
act T-P2 park >/dev/null
assert_eq "200" "$(act T-P2 drop)" "a parked task can be dropped"
assert_eq "closed" "$(field T-P2 .stage)" "and is closed"

# malformed requests are not actions
n5="$(lines)"
assert_eq "404" "$(act T-NOPE park)" "a task the plan does not list is 404"
assert_eq "400" "$(act T-P1 sink)" "an action that is not park, unpark or drop is 400"
assert_eq "403" "$(wcurl "$PORTF" -s -o /dev/null -w '%{http_code}' -X POST -H 'content-type: text/plain' \
  -d '{"task":"T-P1","action":"park"}' "http://127.0.0.1:$PORTF/tasks")" \
  "a body that is not declared JSON is refused, even with the credential, so a cross-site form cannot post it"
assert_eq "$n5" "$(lines)" "and none of them writes anything"

# the board never edits the plan
assert_eq "$plan_before" "$(plan)" "design/tasks/ is untouched"

kill "$pidf" 2>/dev/null
wait "$pidf" 2>/dev/null || true
rm -rf "$f"


safe_rm_rf "$XDG_CONFIG_HOME"
finish
