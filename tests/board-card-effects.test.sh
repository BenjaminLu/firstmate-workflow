#!/usr/bin/env bash
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=tests/lib/project-storage.sh
. "$ROOT/tests/lib/project-storage.sh"
# shellcheck source=tests/lib/board.sh
. "$ROOT/tests/lib/board.sh"
. "$ROOT/tests/lib/binding-fixture.sh"
XDG_CONFIG_HOME="$(safe_tmpdir)"; export XDG_CONFIG_HOME
# --- T-118: every card sits where its task really is -------------------------
# An answered card leaves the captain's lane; the effect an answer names is
# carried out by the script that owns it, or said to have failed; a run that
# is not alive leaves the deck; any unfinished task can be set aside; and a
# wrong final state can be reopened. Every outside script is a stub that
# answers the way the real one does: fm-merge.sh writes the merged event and
# says "fm-merge: merged #n"; fm-dispatch.sh prints the id of a task it
# started, or says on stderr what held it and exits 0; fm-worker.sh exits 70
# naming the lock when another round holds the task.
x="$(safe_tmpdir)"; mkdir -p "$x/bin" "$x/state/pending" "$x/state/runs" "$x/state/worktrees" "$x/design" "$x/board/public" "$x/stub"
# fm-herdr.py: the stop path park and drop run (T-144)
cp "$ROOT/bin/fm-emit.sh" "$ROOT/bin/fm-config.sh" "$ROOT/bin/fm-decide.sh" "$ROOT/bin/fm-herdr.py" "$x/bin/"; project_storage_fixture "$x/bin/"
cp -R "$ROOT/bin/lib" "$x/bin/"   # the lifeline the board starts merges and rounds under (T-151)
binding_service_fixture "$x"
cp "$ROOT/board/server.ts" "$x/board/"
cp "$ROOT/board/public/index.html" "$x/board/public/"
fm_tasks_write /dev/stdin "$x/design/tasks" <<'J'
{"tasks":[{"id":"T-030","title":"answered B, park","milestone":"M2","depends_on":[]},
          {"id":"T-031","title":"a merge card answered B, hold","milestone":"M2","depends_on":[]},
          {"id":"T-032","title":"dropped from a card","milestone":"M2","depends_on":[]},
          {"id":"T-033","title":"dispatched from a card","milestone":"M2","depends_on":[]},
          {"id":"T-034","title":"a dispatch the dispatcher holds","milestone":"M2","depends_on":[]},
          {"id":"T-035","title":"sent back","milestone":"M2","depends_on":[]},
          {"id":"T-036","title":"sent back onto a running round","milestone":"M2","depends_on":[]},
          {"id":"T-037","title":"a card withdrawn","milestone":"M2","depends_on":[]},
          {"id":"T-038","title":"answered, no effect","milestone":"M2","depends_on":[]},
          {"id":"T-039","title":"merged from a card","milestone":"M2","depends_on":[]},
          {"id":"T-044","title":"a run that vanished","milestone":"M2","depends_on":[]},
          {"id":"T-045","title":"a run that is alive","milestone":"M2","depends_on":[]},
          {"id":"T-046","title":"redispatched, then the old run found lost","milestone":"M2","depends_on":[]},
          {"id":"T-050","title":"set aside in flight","milestone":"M2","depends_on":[]},
          {"id":"T-051","title":"parked while its card is pending","milestone":"M2","depends_on":[]},
          {"id":"T-117","title":"T-105 again","milestone":"M2","depends_on":[]}]}
J
cat > "$x/bin/fm-merge.sh" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FM_ROOT/merge-calls"
pr=''; task=''
while [ $# -gt 0 ]; do case "$1" in --pr) pr="$2"; shift 2 ;; --task) task="$2"; shift 2 ;; *) shift ;; esac; done
"$FM_ROOT/bin/fm-emit.sh" --actor captain --type merged --pr "$pr" ${task:+--task "$task"} \
  --en "merged #$pr from the board" --tw "從看板合併 #$pr" >/dev/null 2>&1 </dev/null
echo "fm-merge: merged #$pr"
SH
cat > "$x/bin/fm-dispatch.sh" <<'SH'
#!/usr/bin/env bash
task=''
while [ $# -gt 0 ]; do case "$1" in --task) task="$2"; shift 2 ;; *) shift ;; esac; done
printf '%s\n' "$task" >> "$FM_ROOT/dispatch-calls"
if [ -e "$FM_ROOT/hold-$task" ]; then
  echo "fm-dispatch: $task waits for a slot: 3 in flight, limit 3" >&2
  echo "fm-dispatch: 3 in flight, limit 3 - nothing to start"
  exit 0
fi
# the worker it starts says it started, as a real one does
"$FM_ROOT/bin/fm-emit.sh" --actor "worker-$task" --task "$task" --type dispatched \
  --data '{"role":"worker"}' --en "picked up $task" --tw "接下 $task" >/dev/null 2>&1 </dev/null
echo "$task"
SH
cat > "$x/bin/fm-worker.sh" <<'SH'
#!/usr/bin/env bash
# the arguments as given, before the loop below shifts them all away
args="$*"
task=''
while [ $# -gt 0 ]; do case "$1" in --task) task="$2"; shift 2 ;; *) shift ;; esac; done
if [ -e "$FM_ROOT/locked-$task" ]; then
  echo "fm-worker: cannot lock $task; another worker may be running" >&2; exit 70
fi
printf '%s\n' "$args" >> "$FM_ROOT/worker-calls"
printf '%s\n' "$$" > "$FM_ROOT/worker-pid"
printf '%s\n' "$$" >> "$FM_ROOT/worker-pids"
exec sleep 30
SH
# A merge card's pull request is read from GitHub before the card exists
# (T-119). gh as gh answers `pr view <n> --json a,b`: an object of exactly
# those fields, keys sorted, and for a number with no pull request GraphQL's
# error on stderr, exit 1. What GitHub holds is prs.jsonl.
cat > "$x/bin/gh" <<'SH'
#!/usr/bin/env bash
here="$(cd "$(dirname "$0")/.." && pwd)"
arg() { local w="$1"; shift; while [ $# -gt 0 ]; do [ "$1" = "$w" ] && { printf '%s' "${2-}"; return; }; shift; done; }
case "${1-}:${2-}" in
  pr:view)
    doc="$(jq -c --arg n "$3" 'select((.number|tostring)==$n)' "$here/prs.jsonl" 2>/dev/null | tail -1)"
    [ -n "$doc" ] || {
      echo "GraphQL: Could not resolve to a PullRequest with the number of $3. (repository.pullRequest)" >&2; exit 1; }
    out="$(jq -cS --arg f "$(arg --json "$@")" '. as $d | reduce ($f|split(","))[] as $k ({}; .[$k] = $d[$k])' <<<"$doc")"
    q="$(arg --jq "$@")"
    if [ -n "$q" ]; then jq -r "$q" <<<"$out"; else printf '%s\n' "$out"; fi ;;
  *) echo "gh stub: fm-decide asks nothing but pr view" >&2; exit 1 ;;
esac
SH
for pair in '31 T-031' '35 T-035' '39 T-039' '97 T-117'; do
  set -- $pair
  jq -cn --argjson n "$1" --arg b "$(tr 'T' 't' <<<"$2")-branch" --arg t "$2: title" \
    '{number:$n,state:"OPEN",headRefName:$b,title:$t}' >> "$x/prs.jsonl"
done
chmod +x "$x/bin/fm-merge.sh" "$x/bin/fm-dispatch.sh" "$x/bin/fm-worker.sh" "$x/bin/gh"
emx() { FM_ROOT="$x" "$x/bin/fm-emit.sh" "$@" >/dev/null; }
emx --actor captain --type greenlit --en "go" --tw "開工"
FM_ROOT="$x" FM_PORT=0 bun run "$x/board/server.ts" > "$x/out" 2>&1 < /dev/null &
pidx=$!
PORTX="$(board_port "$x/out" "$pidx")"
for _ in $(seq 1 40); do curl -sf "http://127.0.0.1:$PORTX/api/state" >/dev/null 2>&1 && break; sleep 0.25; done
sx() { curl -sf -m 10 "http://127.0.0.1:$PORTX/api/state"; }
lane() { jq -r --arg t "$1" '.tasks[]|select(.id==$t)|.stage' <<<"$(sx)"; }
record() { jq -r "$2" "$x/state/decisions/$1.json" 2>/dev/null; }
made() { jq -rs --arg d "$1" "map(select(.type==\"decision_made\" and .data.decision==\$d))|last|$2" "$x/state/events.jsonl"; }
# a card raised the way firstmate raises one, through the real fm-decide.sh,
# which validates the effect it names
card() {   # card <id> <task> <kind> <effect JSON or null> [pr]
  jq -n --argjson effect "$4" '
    ({A:{description:"do A",pros:"p",cons:"c"},B:{description:"do B",pros:"p",cons:"c"},C:{description:"do C",pros:"p",cons:"c"}}) as $o
    | {title:"judge",explanation:"e",before:"b",after:"a",outcome:"o",options:$o} as $l
    | {en:$l,"zh-TW":$l} + (if $effect == null then {} else {effect:$effect} end)' > "$x/details-$1.json"
  local head_args=(); [ "$3" = choice ] || head_args=(--expected-head aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa)
  FM_GH="$x/bin/gh" FM_ROOT="$x" FM_PROJECT='' bash "$x/bin/fm-decide.sh" ${head_args[@]+"${head_args[@]}"} --request "$1" --task "$2" --kind "$3" ${5:+--pr "$5"} \
    --details "$x/details-$1.json" --repo "$x" > "$x/decide-$1.out" 2>&1
}
answer() {   # answer <id> <choice>: the HTTP status, the body in $x/post
  local body; body="$(jq -cn --arg i "$1" --arg c "$2" '{id:$i,chosen:$c}')"
  wcurl "$PORTX" -s -m 30 -o "$x/post" -w '%{http_code}' -X POST -H 'content-type: application/json' \
    -d "$body" "http://127.0.0.1:$PORTX/decisions"
}
setaside() {   # setaside <task> <action> [extra JSON]: the HTTP status, the body in $x/resp
  local body extra="${3-}"
  [ -n "$extra" ] || extra='{}'
  body="$(jq -cn --arg t "$1" --arg a "$2" --argjson e "$extra" '{task:$t,action:$a} + $e')"
  wcurl "$PORTX" -s -m 30 -o "$x/resp" -w '%{http_code}' -X POST -H 'content-type: application/json' \
    -d "$body" "http://127.0.0.1:$PORTX/tasks"
}

# T-030's real sequence: a dispatch in its history, a card asking for a
# decision, the captain's B. The card names B's effect, park, as a card now
# does; the answer is carried out, and the task leaves the captain's lane
emx --actor worker-30 --task T-030 --type dispatched --data '{"role":"worker"}' --en "on it" --tw "接下"
card D-1020 T-030 choice '{"B":"park"}'
assert_ok "test -f '$x/state/pending/D-1020.json'" "fm-decide.sh raises a card that names an effect"
assert_eq "park" "$(jq -r '.details.effect.B' "$x/state/pending/D-1020.json")" "and keeps the effect on the card"
assert_eq "captain" "$(lane T-030)" "while the card is pending, the task is the captain's"
assert_eq "200" "$(answer D-1020 B)" "the captain answers B"
assert_eq "park done" "$(jq -r '"\(.effect) \(.outcome)"' "$x/post")" "the answer says its effect was carried out"
assert_eq "parked" "$(lane T-030)" "a chosen park parks the task: it does not stay in the captain's lane"
assert_eq "parked captain D-1020" "$(jq -rs 'map(select(.task=="T-030" and .type=="parked"))|last|"\(.type) \(.actor) \(.data.decision)"' "$x/state/events.jsonl")" \
  "the park is the parked event, from the captain, naming the card"
assert_eq "done park" "$(made D-1020 '"\(.data.outcome) \(.data.effect)"')" "decision_made records the effect and that it was done"
assert_eq "done" "$(record D-1020 .effect_outcome)" "and so does the decision record"

# the same, with no effect named: the task is where its other events put it
emx --actor worker-38 --task T-038 --type dispatched --data '{"role":"worker"}' --en "on it" --tw "接下"
card D-1038 T-038 choice null
assert_eq "200" "$(answer D-1038 B)" "an answer with no effect is recorded"
assert_eq "working" "$(lane T-038)" "and the task goes back to the lane its events give it"
assert_eq "recorded" "$(made D-1038 .data.outcome)" "decision_made says it was only recorded"

# a merge card answered B: hold. It leaves the captain's lane for where its
# events put it, review after an approval, and nothing is merged
emx --actor worker-31 --task T-031 --type dispatched --data '{"role":"worker"}' --en "on it" --tw "接下"
emx --actor worker-31 --task T-031 --type pr_opened --pr 31 --en "opened #31" --tw "開了 #31"
emx --actor reviewer-31 --task T-031 --type approved --data '{"role":"reviewer"}' --en "approved" --tw "通過"
assert_eq "review" "$(lane T-031)" "an approval with no card up waits in review, not at the captain's"
card D-1031 T-031 merge null 31
assert_eq "captain" "$(lane T-031)" "its merge card puts it at the captain's"
assert_eq "200" "$(answer D-1031 B)" "the captain answers B"
assert_eq "hold done" "$(jq -r '"\(.effect) \(.outcome)"' "$x/post")" "a merge card's B holds"
assert_eq "review" "$(lane T-031)" "and the task leaves the captain's lane for review"
assert_fail "test -e '$x/merge-calls'" "and nothing was merged"

# drop from a card: the closed event
card D-1032 T-032 choice '{"C":"drop"}'
assert_eq "200" "$(answer D-1032 C)" "the captain answers C, drop"
assert_eq "drop done" "$(jq -r '"\(.effect) \(.outcome)"' "$x/post")" "the drop is carried out"
assert_eq "closed" "$(lane T-032)" "and the task is closed"
assert_eq "closed captain" "$(jq -rs 'map(select(.task=="T-032" and .type=="closed"))|last|"\(.type) \(.actor)"' "$x/state/events.jsonl")" \
  "by the captain's closed event"

# dispatch from a card, through fm-dispatch.sh --task
card D-1033 T-033 choice '{"A":"dispatch"}'
assert_eq "200" "$(answer D-1033 A)" "the captain answers A, dispatch"
assert_eq "dispatch done" "$(jq -r '"\(.effect) \(.outcome)"' "$x/post")" "the dispatcher started it"
assert_eq "T-033" "$(cat "$x/dispatch-calls")" "through fm-dispatch.sh --task, the captain's order"
assert_eq "working" "$(lane T-033)" "and the task is at work"
# a dispatch the dispatcher holds is a failure, with the dispatcher's reason
: > "$x/hold-T-034"
card D-1034 T-034 choice '{"A":"dispatch"}'
assert_eq "200" "$(answer D-1034 A)" "the answer itself is recorded"
assert_eq "dispatch failed" "$(jq -r '"\(.effect) \(.outcome)"' "$x/post")" "a held dispatch is not reported done"
assert_contains "$(jq -r .reason "$x/post")" "waits for a slot" "it says why, in the dispatcher's words"
assert_eq "failed" "$(made D-1034 .data.outcome)" "decision_made records the failure"
assert_contains "$(made D-1034 .data.reason)" "waits for a slot" "with its reason"
sfx="$(sx)"
assert_eq "failed false" "$(jq -r '.responses[]|select(.id=="D-1034")|"\(.effect_outcome) \(.effect_superseded)"' <<<"$sfx")" \
  "the board keeps the failed effect up"
assert_contains "$(jq -r '.responses[]|select(.id=="D-1034")|.effect_reason' <<<"$sfx")" "waits for a slot" "with its reason"
assert_eq "ready" "$(lane T-034)" "and the task stays where it was, not in the captain's lane"
# once the task is dispatched some other way, the failure is overtaken
emx --actor worker-T-034 --task T-034 --type dispatched --data '{"role":"worker"}' --en "picked up T-034" --tw "接下 T-034"
assert_eq "failed true" "$(jq -r '.responses[]|select(.id=="D-1034")|"\(.effect_outcome) \(.effect_superseded)"' <<<"$(sx)")" \
  "a failed dispatch is superseded once the task is dispatched after it"

# send back: another worker round on the same pull request, by fm-worker.sh
emx --actor worker-35 --task T-035 --type dispatched --data '{"role":"worker"}' --en "on it" --tw "接下"
emx --actor worker-35 --task T-035 --type pr_opened --pr 35 --en "opened #35" --tw "開了 #35"
emx --actor worker-35 --task T-035 --type agent_finished --en "done" --tw "完成"
card D-1035 T-035 merge '{"A":"merge","B":"send_back"}' 35
assert_eq "200" "$(answer D-1035 B)" "the captain answers B, send back"
assert_eq "send_back done" "$(jq -r '"\(.effect) \(.outcome)"' "$x/post")" "the round was started"
assert_contains "$(cat "$x/worker-calls" 2>/dev/null)" "--task T-035" "by fm-worker.sh, for the task"
assert_contains "$(cat "$x/worker-calls" 2>/dev/null)" "--pr 35" "on its pull request"
# the round it started is stopped, and gone, before the block moves on:
# a stub left sleeping outlives the suite, which bin/ci.sh turns red (T-151)
wait_for 10 test -s "$x/worker-pid"
stop_pids "$x/worker-pids"
# and a round that refuses, because another holds the task, is a failure
emx --actor worker-36 --task T-036 --type dispatched --data '{"role":"worker"}' --en "on it" --tw "接下"
: > "$x/locked-T-036"
card D-1036 T-036 choice '{"B":"send_back"}'
assert_eq "200" "$(answer D-1036 B)" "the answer is recorded"
assert_eq "send_back failed" "$(jq -r '"\(.effect) \(.outcome)"' "$x/post")" "a refused round is not reported done"
assert_contains "$(jq -r .reason "$x/post")" "cannot lock T-036" "it says why, in the worker's words"

# merge from a card, as before, now with the effect recorded
emx --actor worker-39 --task T-039 --type pr_opened --pr 39 --en "opened #39" --tw "開了 #39"
card D-1039 T-039 merge null 39
assert_eq "200" "$(answer D-1039 A)" "the captain answers A, merge"
assert_eq "merge running" "$(jq -r '"\(.effect) \(.outcome)"' "$x/post")" "a merge runs in the background"
wait_for 20 jq -e '.merge=="merged"' "$x/state/decisions/D-1039.json"
assert_eq "merged done" "$(record D-1039 '"\(.merge) \(.effect_outcome)"')" "and its record says it was done once it merged"
assert_eq "merged" "$(lane T-039)" "the task is merged"

# --- set aside in flight: confirmed, crew stopped, the pull request left open
emx --actor worker-50 --task T-050 --type dispatched --data '{"role":"worker"}' --en "on it" --tw "接下"
emx --actor worker-50 --task T-050 --type pr_opened --pr 50 --en "opened #50" --tw "開了 #50"
# on TERM it ends its sleep too, so stopping the worker leaves nothing (T-151)
printf '#!/usr/bin/env bash\ntrap '"'"'kill $! 2>/dev/null; exit 143'"'"' TERM\nsleep 30 &\nwait\n' > "$x/stub/fm-worker.sh"
# every descriptor detached: while it runs, its sleep must not hold the
# suite's output open
bash "$x/stub/fm-worker.sh" >/dev/null 2>&1 </dev/null &
fake=$!
printf '%s\n' "$fake" > "$x/state/worktrees/T-050.pid"
# and a headless round of it (T-144): a process group of its own, led by a
# runner ps shows as fm-herdr.py, with the vendor CLI inside the group. Only
# the group's leader is on file; the stop must reach the rest through it.
mkdir -p "$x/state/runs/worker-ada-t050-r1/codex-a"
printf '{"actor":"worker-ada-t050-r1","task":"T-050","role":"worker"}\n' > "$x/state/runs/worker-ada-t050-r1/identity.json"
printf 'import subprocess,sys\nc=subprocess.Popen(["sleep","60"])\nopen(sys.argv[1],"w").write(str(c.pid))\nc.wait()\n' > "$x/stub/fm-herdr.py"
python3 -c 'import os,sys; os.setsid(); os.execvp(sys.argv[1], sys.argv[1:])' \
  python3 "$x/stub/fm-herdr.py" "$x/stub/cli.pid" >/dev/null 2>&1 </dev/null &
runner=$!
printf '%s\n' "$runner" > "$x/state/runs/worker-ada-t050-r1/codex-a/runner.pid"
wait_for 10 test -s "$x/stub/cli.pid"
cli="$(cat "$x/stub/cli.pid")"
assert_eq "park,drop true" "$(jq -r '.tasks[]|select(.id=="T-050")|"\(.actions|join(",")) \(.confirm)"' <<<"$(sx)")" \
  "a task in review offers park and drop, and asks first"
n50="$(wc -l < "$x/state/events.jsonl")"
assert_eq "409" "$(setaside T-050 park)" "parking it without confirming is refused"
assert_eq "$n50" "$(wc -l < "$x/state/events.jsonl")" "and writes nothing"
assert_ok "kill -0 $fake" "and stops nobody"
assert_eq "200" "$(setaside T-050 park '{"confirm":true}')" "confirmed, it is parked"
assert_eq "parked" "$(lane T-050)" "and leaves its lane"
assert_contains "$(jq -r '.stopped|join(" ")' "$x/resp")" "worker $fake" "its worker is stopped by the stop path"
assert_eq "50" "$(jq -r .pr_left_open "$x/resp")" "and its pull request is left open, and said so"
wait "$fake" 2>/dev/null; rc=$?
assert_eq "143" "$rc" "the worker got SIGTERM"
assert_contains "$(jq -r '.stopped|join(" ")' "$x/resp")" "worker-ada-t050-r1 $runner" "its round is stopped by the same path"
wait "$runner" 2>/dev/null
wait_for 10 bash -c "! kill -0 $cli 2>/dev/null"
assert_fail "kill -0 $cli" "and the vendor CLI inside the round's process group is gone with it"
assert_eq "200" "$(setaside T-050 unpark)" "unparked"
assert_eq "review" "$(lane T-050)" "it returns to the lane its events give it"
assert_eq "200" "$(setaside T-050 drop '{"confirm":true}')" "and a confirmed drop closes it"
assert_eq "closed" "$(lane T-050)" "closed"

# --- parked while its card is pending: the card outranks the park, so the
# task stays in the captain's lane, says it is parked, and offers unpark
# rather than a second park; answered or withdrawn, the park shows
emx --actor worker-51 --task T-051 --type dispatched --data '{"role":"worker"}' --en "on it" --tw "接下"
card D-1051 T-051 choice null
t51() { jq -r '.tasks[]|select(.id=="T-051")|"\(.stage) \(.actions|join(",")) \([.badges[]|select(.kind=="parked")]|length)"' <<<"$(sx)"; }
assert_eq "captain park,drop 0" "$(t51)" "a task whose card is pending offers park and drop"
assert_eq "200" "$(setaside T-051 park '{"confirm":true}')" "confirmed, it is parked"
assert_eq "captain unpark,drop 1" "$(t51)" \
  "it stays in the captain's lane while its card is pending, marked parked, and offers unpark, not park"
n51="$(wc -l < "$x/state/events.jsonl")"
assert_eq "409" "$(setaside T-051 park '{"confirm":true}')" "a second park is refused"
assert_eq "$n51" "$(wc -l < "$x/state/events.jsonl")" "and writes nothing"
assert_eq "200" "$(setaside T-051 unpark)" "unparking it is accepted"
assert_eq "captain park,drop 0" "$(t51)" "unparked, it is the captain's card again, with nothing parked"
assert_eq "200" "$(setaside T-051 park '{"confirm":true}')" "parked again"
rm -f "$x/state/pending/D-1051.json"
assert_eq "parked unpark,drop 0" "$(t51)" "once no card is pending, the park is what places it"

# --- a card withdrawn unanswered: the task is where its events put it
emx --actor worker-37 --task T-037 --type dispatched --data '{"role":"worker"}' --en "on it" --tw "接下"
card D-1037 T-037 choice null
assert_eq "captain" "$(lane T-037)" "while its card is pending, the task is the captain's"
rm -f "$x/state/pending/D-1037.json"
assert_eq "working" "$(lane T-037)" "withdrawn, the card no longer holds it there"

# --- liveness: a run the launcher side found lost leaves the deck. The
# events are the ones bin/fm-herdr.py's deck reconcile writes for a run whose
# process is gone: agent_lost, then the agent_finished that closes it.
crew_ids() { jq -r '[.crew[].id]|join(" ")' <<<"$1"; }
lost_by_reconcile() {   # lost_by_reconcile <actor> <task>
  emx --actor "$1" --task "$2" --type agent_lost --data '{"role":"worker","status":"process_gone"}' \
    --en "$1 was lost on $2: its process is gone and it never said it finished" \
    --tw "$1 在 $2 上失聯：行程已不在，也從未回報完成"
  emx --actor "$1" --task "$2" --type agent_finished --data '{"role":"worker","status":"process_gone"}' \
    --en "deck reconcile: $1 has no live process" --tw "甲板對帳：$1 無活進程"
}
emx --actor worker-gone --task T-044 --type dispatched --data '{"role":"worker"}' --en "on it" --tw "接下"
emx --actor worker-live --task T-045 --type dispatched --data '{"role":"worker"}' --en "on it" --tw "接下"
assert_contains "$(crew_ids "$(sx)")" "worker-gone" "before it is found lost, the run is aboard"
lost_by_reconcile worker-gone T-044
sl="$(sx)"
assert_lacks "$(crew_ids "$sl")" "worker-gone" "a vanished run is off the deck"
assert_contains "$(crew_ids "$sl")" "worker-live" "a live one stays aboard"
assert_eq "working" "$(jq -r '.tasks[]|select(.id=="T-045")|.stage' <<<"$sl")" "and its task stays at work"
assert_eq "gate lost worker-gone" "$(jq -r '.tasks[]|select(.id=="T-044")|"\(.stage) \(.badges|map(.kind)|join(",")) \(.badges[0].actor)"' <<<"$sl")" \
  "the lost run's task is blocked, and the card names who was lost"
assert_eq "agent_lost" "$(jq -r '[.recent[]|select(.actor=="worker-gone" and (.type=="agent_lost" or .type=="agent_finished"))|.type]|join(",")' <<<"$sl")" \
  "the log shows it lost, once, and not also the close that follows"
assert_contains "$(jq -r '.recent[]|select(.type=="agent_lost")|.summary.en' <<<"$sl")" "lost" "in English"
assert_contains "$(jq -r '.recent[]|select(.type=="agent_lost")|.summary["zh-TW"]' <<<"$sl")" "失聯" "and in Traditional Chinese"
# agent_finished arriving after lost: still off the deck, the task where its
# events put it, and the loss still shown once
emx --actor worker-gone --task T-044 --type agent_finished --data '{"role":"worker"}' --en "finished" --tw "結束"
sa="$(sx)"
assert_lacks "$(crew_ids "$sa")" "worker-gone" "agent_finished after lost does not bring it back"
assert_eq "gate" "$(jq -r '.tasks[]|select(.id=="T-044")|.stage' <<<"$sa")" "and its task stays blocked"
assert_eq "1" "$(jq -r '[.recent[]|select(.type=="agent_lost" and .actor=="worker-gone")]|length' <<<"$sa")" "the loss is still shown once"

# --- a vendor that is not authenticated shows as unavailable (T-121): the
# probe's own reason reaches the board the same generic way any other event's
# authored en/tw summary does, in both languages. One line and no crewman
# put aboard, so the fixture's deck is left as the tests below expect it
emx --actor worker-auth --task T-047 --type vendor_unavailable \
  --en "claude: expired: claude's login has expired; run \`claude\` once outside a round and sign in" \
  --tw "claude：expired：claude 的登入已過期；請在裝置外執行一次 \`claude\` 並登入"
sv="$(sx)"
assert_contains "$(jq -r '.recent[]|select(.type=="vendor_unavailable")|.summary.en' <<<"$sv")" \
  "claude's login has expired" "the board shows the probe's own reason for an unauthenticated vendor, in English"
assert_contains "$(jq -r '.recent[]|select(.type=="vendor_unavailable")|.summary["zh-TW"]' <<<"$sv")" \
  "登入已過期" "and in Traditional Chinese"

# a task redispatched before its old crewman was found lost is not blocked
emx --actor worker-old --task T-046 --type dispatched --data '{"role":"worker"}' --en "on it" --tw "接下"
emx --actor worker-new --task T-046 --type dispatched --data '{"role":"worker","recovery":true}' --en "again" --tw "再來"
lost_by_reconcile worker-old T-046
sr="$(sx)"
assert_eq "working" "$(jq -r '.tasks[]|select(.id=="T-046")|.stage' <<<"$sr")" "a redispatched task stays at work when the old run is found lost"
assert_contains "$(crew_ids "$sr")" "worker-new" "with its new crewman aboard"
# and a redispatch after the loss unblocks it, with the crewman aboard again
emx --actor worker-gone --task T-044 --type dispatched --data '{"role":"worker"}' --en "back" --tw "回來"
sb="$(sx)"
assert_eq "working" "$(jq -r '.tasks[]|select(.id=="T-044")|.stage' <<<"$sb")" "a redispatch after the loss moves the task on"
assert_contains "$(crew_ids "$sb")" "worker-gone" "and a dispatched run is aboard again"

# --- reopening a wrong final state: T-117's exact sequence (events 3945-3947)
emx --actor worker-117 --task T-117 --type dispatched --data '{"role":"worker"}' --en "on it" --tw "接下"
emx --actor worker-117 --task T-117 --type pr_opened --pr 97 --en "opened #97" --tw "開了 #97"
emx --actor worker-117 --task T-117 --type agent_finished --en "done" --tw "完成"
emx --actor firstmate --task T-117 --type decision_requested --pr 96 --en "merge #96, the revert of T-105" --tw "合併 #96"
emx --actor captain --task T-117 --type decision_made --data '{"decision":"D-3946","chosen":"A","outcome":"recorded"}' \
  --en "D-3946 recorded A" --tw "D-3946 已記錄 A"
emx --actor captain --task T-117 --type merged --pr 96 --en "merged #96 from the board" --tw "從看板合併 #96"
assert_eq "merged 96 reopen" "$(jq -r '.tasks[]|select(.id=="T-117")|"\(.stage) \(.pr) \(.actions|join(","))"' <<<"$(sx)")" \
  "T-117 shows as merged with #96, and offers reopening"
# a card raised under a final task is shown, and says the task is final
card D-1118 T-117 choice null
assert_eq "merged" "$(jq -r '.pending[]|select(.id=="D-1118")|.task_final' <<<"$(sx)")" \
  "a pending card under a merged task is shown, marked final"
assert_eq "merged" "$(lane T-117)" "and does not move the task"
assert_eq "200" "$(answer D-1118 B)" "and it can be answered"
# reopening asks first and needs a reason; only the captain's counts
n117="$(wc -l < "$x/state/events.jsonl")"
assert_eq "409" "$(setaside T-117 reopen '{"reason":"wrong card"}')" "a reopening not confirmed is refused"
assert_eq "confirmRequired" "$(jq -r .code "$x/resp")" "with the code that asks to confirm"
assert_eq "400" "$(setaside T-117 reopen '{"confirm":true}')" "and one with no reason"
assert_eq "reopenNeedsReason" "$(jq -r .code "$x/resp")" \
  "with a refusal code of its own, not the reason box's label key"
assert_eq "$n117" "$(wc -l < "$x/state/events.jsonl")" "neither writes anything"
emx --actor firstmate --task T-117 --type reopened --data '{"reason":"not mine to reopen"}' --en "reopened" --tw "重新開啟"
assert_eq "merged" "$(lane T-117)" "a reopened event from anyone but the captain moves nothing"
assert_eq "200" "$(setaside T-117 reopen '{"confirm":true,"reason":"the merge card for #96 was raised under T-117"}')" \
  "the captain reopens T-117"
assert_eq "reopened captain" "$(tail -1 "$x/state/events.jsonl" | jq -r '"\(.type) \(.actor)"')" \
  "as a reopened event from the captain"
assert_contains "$(tail -1 "$x/state/events.jsonl" | jq -r .data.reason)" "raised under T-117" "with its reason"
s117="$(sx)"
assert_eq "ready 97" "$(jq -r '.tasks[]|select(.id=="T-117")|"\(.stage) \(.pr)"' <<<"$s117")" \
  "T-117 leaves merged: with no later events it is untouched work again, showing its own #97"
assert_eq "reopened" "$(jq -r 'first(.recent[]|select(.task=="T-117")|.type)' <<<"$s117")" "the log shows the reopening"
# a later merge card for #97 is shown and answerable, and later events move
# the task as they always do
card D-1119 T-117 merge null 97
s119="$(sx)"
assert_eq "null true" "$(jq -r '.pending[]|select(.id=="D-1119")|"\(.task_final) \(.answerable)"' <<<"$s119")" \
  "the merge card for #97 is shown and answerable"
assert_eq "captain" "$(jq -r '.tasks[]|select(.id=="T-117")|.stage' <<<"$s119")" "and the task waits on the captain for it"
assert_eq "200" "$(answer D-1119 A)" "the captain merges #97"
wait_for 20 jq -e '.merge=="merged"' "$x/state/decisions/D-1119.json"
assert_contains "$(cat "$x/merge-calls")" "--pr 97 --task T-117" "through fm-merge.sh, for #97"
assert_eq "merged 97" "$(jq -r '.tasks[]|select(.id=="T-117")|"\(.stage) \(.pr)"' <<<"$(sx)")" "and T-117 is merged with #97"

kill "$pidx" 2>/dev/null
wait "$pidx" 2>/dev/null || true
# every round a send back started here, stopped and gone (T-151)
stop_pids "$x/worker-pids"
rm -rf "$x"

# the repository is data in the registry, never a literal in the board: no
# registered owner or repository name appears anywhere under board/
gh_repos="$(sed -n 's/^[[:space:]]*github:[[:space:]]*\([^[:space:]#]*\).*/\1/p' "$ROOT/config.yaml")"
assert_ne "" "$gh_repos" "config.yaml registers at least one github repository to look for"
for repo in $gh_repos; do
  for part in "${repo%%/*}" "${repo#*/}"; do
    assert_eq "" "$(grep -rnF -- "$part" "$ROOT/board" || true)" "board/ holds no literal '${part}' from the registry"
  done
done


safe_rm_rf "$XDG_CONFIG_HOME"
finish
