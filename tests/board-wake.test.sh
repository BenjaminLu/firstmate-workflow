#!/usr/bin/env bash
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=tests/lib/board.sh
. "$ROOT/tests/lib/board.sh"
XDG_CONFIG_HOME="$(safe_tmpdir)"; export XDG_CONFIG_HOME
# --- T-151: the board pushes the wake, and owns what it starts ---------------
# Whoever writes a decision delivers the wake: the item on the wake queue,
# and a ring of every waiter's own doorbell under state/session/wake.d. And
# nothing the board starts outlives its owner: a merge belongs to the
# session the board names (FM_SESSION_PID), and to the board itself when it
# names none, and ends when that owner does - even a SIGKILLed one.
make_w() {   # make_w: a fixture with three merge cards, D-51..D-53, its path on stdout
  local w; w="$(safe_tmpdir)"; mkdir -p "$w/bin" "$w/state/pending" "$w/design" "$w/board/public"
  cp "$ROOT/bin/fm-emit.sh" "$ROOT/bin/fm-config.sh" "$w/bin/"
  cp -R "$ROOT/bin/lib" "$w/bin/"
  cp "$ROOT/board/server.ts" "$w/board/"; cp "$ROOT/board/public/index.html" "$w/board/public/"
  mkdir -p "$w/design/tasks"
  printf '{"id":"T-A","title":"first","milestone":"M0","depends_on":[]}\n' > "$w/design/tasks/T-A.json"
  # the merge helper says who it is and holds while told to
  printf '%s\n' '#!/usr/bin/env bash' \
    'root="$(cd "$(dirname "$0")/.." && pwd)"' \
    'pr=""; while [ $# -gt 0 ]; do case "$1" in --pr) pr="$2"; shift 2 ;; *) shift ;; esac; done' \
    'echo $$ > "$root/merge-$pr.pid"' \
    'while [ -e "$root/hold-$pr" ]; do sleep 0.1; done' \
    'echo "fm-merge: merged #$pr"' > "$w/bin/fm-merge.sh"
  chmod +x "$w/bin/fm-merge.sh"
  for n in 1 2 3; do
    printf '{"id":"D-5%s","task":"T-A","kind":"merge","pr":%s,"title":"merge #%s"}\n' "$n" "$n" "$n" > "$w/state/pending/D-5$n.json"
  done
  printf '%s' "$w"
}
start_w() {   # start_w <root> <session pid or empty>: the board, its pid in pidw and port in PORTW
  FM_SESSION_PID="$2" FM_ROOT="$1" FM_PORT=0 bun run "$1/board/server.ts" > "$1/out" 2>&1 < /dev/null &
  pidw=$!
  PORTW="$(board_port "$1/out" "$pidw")"
  wait_for 60 curl -sf "http://127.0.0.1:$PORTW/api/state"
}
postw() {   # postw <id> <choice>: the HTTP status
  wcurl "$PORTW" -s -m 5 -o /dev/null -w '%{http_code}' -X POST -H 'content-type: application/json' \
    -d "$(jq -cn --arg i "$1" --arg c "$2" '{id:$i,chosen:$c}')" "http://127.0.0.1:$PORTW/decisions"
}
alive() { kill -0 "$1" 2>/dev/null; }
dead() { ! kill -0 "$1" 2>/dev/null; }

# the wake, pushed by the writer
w="$(make_w)"
sleep 300 & sess=$!
start_w "$w" "$sess"
# One writer integration check; lifeline owns fan-out and dead-bell cleanup.
bells="$w/state/session/wake.d"; mkdir -p "$bells"
mkfifo "$bells/1-a.fifo"
exec 7<> "$bells/1-a.fifo"
assert_eq "200" "$(postw D-51 A)" "the captain answers a merge card"
line=''; IFS= read -r -t 10 -u 7 line || true
assert_eq "D-51" "$line" "the board rings the waiter's bell at once"
assert_eq "D-51 answered A" "$(jq -r 'select(.reason=="answered")|"\(.id) \(.reason) \(.decision.chosen)"' "$w/state/session/wake.jsonl" 2>/dev/null)" \
  "and the item onto the durable wake queue"
wait_for 20 jq -e '.merge=="merged"' "$w/state/decisions/D-51.json"
line=''; IFS= read -r -t 10 -u 7 line || true
assert_eq "D-51" "$line" "the merge settling wakes firstmate again"
assert_eq "merged" "$(jq -r 'select(.reason=="merge_settled")|.decision.merge' "$w/state/session/wake.jsonl" 2>/dev/null)" \
  "with the outcome on the queue"
exec 7<&-
rm -f "$bells/1-a.fifo"
# no waiter: ringing never blocks the answer, and the queue carries it
assert_eq "200" "$(postw D-52 B)" "an answer with nobody waiting is not held up"
assert_eq "1" "$(grep -c '"id":"D-52"' "$w/state/session/wake.jsonl")" "and still reaches the queue"

# a merge the captain clicked belongs to the session, not to the board
touch "$w/hold-3"
assert_eq "200" "$(postw D-53 A)" "a merge starts and holds"
wait_for 20 test -s "$w/merge-3.pid"
m3="$(cat "$w/merge-3.pid" 2>/dev/null)"
assert_ok "alive '$m3'" "the merge helper runs"
kill -9 "$pidw" 2>/dev/null; wait "$pidw" 2>/dev/null
sleep 1
assert_ok "alive '$m3'" "a board that dies does not take the session's merge with it"
kill "$sess" 2>/dev/null; wait "$sess" 2>/dev/null
wait_for 10 dead "$m3"
assert_ok "dead '$m3'" "the session ends, and the merge ends with it"
rm -f "$w/hold-3"
rm -rf "$w"

# a board with no session owns what it starts, and a SIGKILL to it is enough
w="$(make_w)"
# a round sent back: the worker says who it is and holds while told to
printf '%s\n' '#!/usr/bin/env bash' 'root="$(cd "$(dirname "$0")/.." && pwd)"' \
  'echo $$ > "$root/worker.pid"' 'while [ -e "$root/hold-worker" ]; do sleep 0.1; done' > "$w/bin/fm-worker.sh"
chmod +x "$w/bin/fm-worker.sh"
jq -cn '({A:{description:"send back",pros:"p",cons:"c"},B:{description:"hold",pros:"p",cons:"c"},C:{description:"wait",pros:"p",cons:"c"}}) as $o
  | {title:"send it back",explanation:"e",before:"b",after:"a",outcome:"o",options:$o} as $l
  | {id:"D-54",task:"T-A",kind:"choice",pr:4,title:"send it back",details:{en:$l,"zh-TW":$l,effect:{A:"send_back"}}}' \
  > "$w/state/pending/D-54.json"
start_w "$w" ""
touch "$w/hold-1" "$w/hold-worker"
assert_eq "200" "$(postw D-51 A)" "a merge starts under a board that names no session"
wait_for 20 test -s "$w/merge-1.pid"
m1="$(cat "$w/merge-1.pid" 2>/dev/null)"
assert_ok "alive '$m1'" "the merge helper runs"
assert_eq "200" "$(postw D-54 A)" "and a round is sent back"
wait_for 20 test -s "$w/worker.pid"
wk="$(cat "$w/worker.pid" 2>/dev/null)"
assert_ok "alive '$wk'" "the round runs"
kill -9 "$pidw" 2>/dev/null; wait "$pidw" 2>/dev/null
wait_for 10 dead "$m1"
assert_ok "dead '$m1'" "the board killed outright, the merge it owned ends with it"
wait_for 10 dead "$wk"
assert_ok "dead '$wk'" "and so does the round it sent back"
rm -f "$w/hold-worker"
assert_eq "" "$(grep -n 'detached' "$w/board/server.ts" | grep -v '//' || true)" "and the board detaches nothing itself"
rm -f "$w/hold-1"
rm -rf "$w"

# T-153: a review round's wall-clock, from the log. The latest round of each
# task, from its reviewer's review_opened to that reviewer's own verdict
# event; nothing for a round still running or a verdict nobody opened.
w="$(make_w)"
cat >> "$w/state/events.jsonl" <<'J'
{"ts":"2026-09-29T10:00:00Z","type":"review_opened","actor":"reviewer-a-tr1-r1","task":"T-R1"}
{"ts":"2026-09-29T10:17:30Z","type":"review_failed","actor":"reviewer-a-tr1-r1","task":"T-R1","data":{"review_outcome":"rejected"}}
{"ts":"2026-09-29T11:00:00Z","type":"review_opened","actor":"reviewer-a-tr1-r2","task":"T-R1"}
{"ts":"2026-09-29T11:00:10Z","type":"review_opened","actor":"reviewer-b-tr2-r1","task":"T-R2"}
{"ts":"2026-09-29T11:05:00Z","type":"approved","actor":"reviewer-a-tr1-r2","task":"T-R1"}
{"ts":"2026-09-29T11:06:00Z","type":"approved","actor":"reviewer-c-tr3-r1","task":"T-R3"}
{"ts":"2026-09-29T12:00:00Z","type":"review_opened","actor":"reviewer-d-tr4-r1","task":"T-R4"}
{"ts":"2026-09-29T12:41:00Z","type":"review_failed","actor":"reviewer-d-tr4-r1","task":"T-R4","data":{"review_outcome":"rejected"}}
{"ts":"2026-09-29T13:00:00Z","type":"review_opened","actor":"reviewer-e-tr5-r1","task":"T-R5"}
{"ts":"2026-09-29T13:20:00Z","type":"approved","actor":"reviewer-e-tr5-r1","task":"T-R5","data":{"wall_clock":{"started":1790686805,"ended":1790687825,"seconds":1020}}}
{"ts":"2026-09-29T13:30:00Z","type":"review_failed","actor":"reviewer-f-tr6-r1","task":"T-R6","data":{"review_outcome":"infrastructure_error","wall_clock":{"started":1790688540,"ended":1790688600,"seconds":60}}}
J
start_w "$w" ""
sw="$(curl -sf "http://127.0.0.1:$PORTW/api/state")"
assert_eq '{"actor":"reviewer-a-tr1-r2","seconds":300,"outcome":"approved"}' \
  "$(jq -c '.tasks[]|select(.id=="T-R1")|.last_review' <<<"$sw")" \
  "a task's card carries its latest review round's wall-clock, reviewer and outcome"
assert_eq '2460 rejected' "$(jq -r '.tasks[]|select(.id=="T-R4")|.last_review|"\(.seconds) \(.outcome)"' <<<"$sw")" \
  "a rejecting round is timed the same way (41 minutes)"
assert_eq "null null" "$(jq -r '[.tasks[]|select(.id=="T-R2" or .id=="T-R3")|.last_review]|map(tostring)|join(" ")' <<<"$sw")" \
  "a round still running, or a verdict with no review_opened of its own, has no wall-clock"
# the round's own record (fm-review.sh's data.wall_clock) is its wall-clock
# where the verdict carries one: 17 minutes, not the 20 between the events
assert_eq '1020 approved' "$(jq -r '.tasks[]|select(.id=="T-R5")|.last_review|"\(.seconds) \(.outcome)"' <<<"$sw")" \
  "a round's own recorded wall-clock is the one the card carries"
assert_eq '60 infrastructure_error' "$(jq -r '.tasks[]|select(.id=="T-R6")|.last_review|"\(.seconds) \(.outcome)"' <<<"$sw")" \
  "and a verdict that records its own needs no review_opened to be timed"
kill "$pidw" 2>/dev/null; wait "$pidw" 2>/dev/null
rm -rf "$w"


safe_rm_rf "$XDG_CONFIG_HOME"
finish
