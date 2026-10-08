#!/usr/bin/env bash
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=tests/lib/project-storage.sh
. "$ROOT/tests/lib/project-storage.sh"
# shellcheck source=tests/lib/board.sh
. "$ROOT/tests/lib/board.sh"
# fixture carries the library
d="$(safe_tmpdir)"; mkdir -p "$d/bin" "$d/state" "$d/design" "$d/board/public"
cp "$ROOT/bin/fm-emit.sh" "$ROOT/bin/fm-config.sh" "$d/bin/"; project_storage_fixture "$d/bin/"
cp -R "$ROOT/bin/lib" "$d/bin/"   # the lifeline the board starts merges and rounds under (T-151)
cp "$ROOT/board/server.ts" "$d/board/"
cp "$ROOT/board/public/index.html" "$d/board/public/"
fm_tasks_write /dev/stdin "$d/design/tasks" <<'J'
{"tasks":[{"id":"T-A","title":"first","milestone":"M0","depends_on":[]},
          {"id":"T-B","title":"second","milestone":"M0","depends_on":["T-A"]},
          {"id":"T-C","title":"third","milestone":"M0","depends_on":[]},
          {"id":"T-D","title":"fourth","milestone":"M0","depends_on":[]}]}
J
FM_ROOT="$d" "$d/bin/fm-emit.sh" --actor captain --type greenlit --en "go" --tw "開工" >/dev/null
FM_ROOT="$d" "$d/bin/fm-emit.sh" --actor worker-1 --task T-A --type dispatched --en "picked up T-A" --tw "領走 T-A" >/dev/null
XDG_CONFIG_HOME="$(safe_tmpdir)"; export XDG_CONFIG_HOME
starts_board='bun run .*server\.ts|"run", join\(.*server\.ts'
sets_config='XDG_CONFIG_HOME["'\'']?[[:space:]]*[=:]'
starters=''
for f in $(git -C "$ROOT" ls-files -- 'tests/*.sh' 'tests/*.ts' ':!tests/lib/fixtures/'); do
  # a here-string, not a pipe: under pipefail, grep -q leaving early fails the writer
  grep -qE "$starts_board" <<< "$(code_of "$ROOT/$f")" && starters="$starters $f"
done
assert_contains "$starters " " tests/crew-end-to-end.test.sh " "the sweep finds the suites that start a board"
unset_config=''
for f in $starters; do
  grep -qE "$sets_config" <<< "$(code_of "$ROOT/$f")" || unset_config="$unset_config $f"
done
assert_eq "" "$unset_config" "every suite that starts a board gives it a config directory of its own"
# the control: a comment alone neither starts a board nor sets the variable
printf '#!/usr/bin/env bash\n# bun run board/server.ts\n# XDG_CONFIG_HOME="$d"\n' > "$d/commented.sh"
assert_eq "" "$(code_of "$d/commented.sh" | grep -E "$starts_board|$sets_config" || true)" \
  "a suite that only names them in comments is neither found nor passed"
printf '// XDG_CONFIG_HOME: config\nspawn("bun", ["run", join(root, "board/server.ts")])\n' > "$d/commented.ts"
assert_eq "spawn" "$(code_of "$d/commented.ts" | grep -oE "^spawn" || true)$(code_of "$d/commented.ts" | grep -E "$sets_config" || true)" \
  "and in TypeScript, the call is found and the comment is not"
rm -f "$d/commented.sh" "$d/commented.ts"
# keeps stdout open holds the command substitution open with it
FM_ROOT="$d" FM_PORT=0 bun run "$d/board/server.ts" > "$d/out" 2>&1 < /dev/null &
pid=$!
PORT="$(board_port "$d/out" "$pid")"
for _ in $(seq 1 40); do curl -sf "http://127.0.0.1:$PORT/api/state" >/dev/null 2>&1 && break; sleep 0.25; done
trap 'kill "$pid" 2>/dev/null' EXIT

s="$(curl -sf "http://127.0.0.1:$PORT/api/state")"
assert_ok "[ -n '$s' ]" "the state endpoint answers"
assert_eq "true" "$(jq -r .greenlit <<<"$s")" "it reports the green light"
assert_eq "working" "$(jq -r '.tasks[]|select(.id=="T-A")|.stage' <<<"$s")" "a dispatched task reads as working"
# an untouched task is ready once every dependency has merged and backlog
# while any has not; T-B waits on T-A, which is only being worked on
assert_eq "backlog" "$(jq -r '.tasks[]|select(.id=="T-B")|.stage' <<<"$s")" "an untouched task waiting on unmerged work reads as backlog"
assert_eq "ready"   "$(jq -r '.tasks[]|select(.id=="T-C")|.stage' <<<"$s")" "an untouched task with nothing to wait on reads as ready"
assert_eq "1" "$(jq -r .counts.inflight <<<"$s")" "the counts follow the log"

# T-164: the board must see the same committed batch as session/watch readers.
python3 - "$d" <<'PYACK'
import sys
from pathlib import Path
sys.path.insert(0, str(Path(sys.argv[1]) / 'bin/lib'))
import fm_lifeline as life
root = Path(sys.argv[1])
life.push(root, 'D-interrupted-first', 'test', 'first')
life.push(root, 'D-interrupted-second', 'test', 'second')
import json
items = [json.loads(line) for line in (root / life.WAKE_QUEUE).read_text().splitlines()]
real = life._write_ack
def interrupt(path, record):
    if str(path).endswith('/D-interrupted-second.json'):
        raise OSError('second write interrupted')
    real(path, record)
life._write_ack = interrupt
try:
    life.acknowledge_batch(root, items)
except OSError:
    pass
else:
    raise AssertionError('fixture must interrupt after the first durable write')
PYACK
s="$(curl -sf "http://127.0.0.1:$PORT/api/state")"
assert_eq "2" "$(jq -r .watch.waiting <<<"$s")" "board counts both unreturned wakes after partial acknowledgement"
python3 - "$d" <<'PYACK'
import json, sys
from pathlib import Path
sys.path.insert(0, str(Path(sys.argv[1]) / 'bin/lib'))
import fm_lifeline as life
root = Path(sys.argv[1])
life.acknowledge_batch(root, [json.loads(line) for line in (root / life.WAKE_QUEUE).read_text().splitlines()])
PYACK
s="$(curl -sf "http://127.0.0.1:$PORT/api/state")"
assert_eq "0" "$(jq -r .watch.waiting <<<"$s")" "board hides wakes only after the recovered batch commits"
printf '{' > "$d/state/session/.ack-transaction.json"
s="$(curl -sf "http://127.0.0.1:$PORT/api/state")"
assert_eq "2" "$(jq -r .watch.waiting <<<"$s")" "board retains wakes when transaction visibility is unknown"
rm "$d/state/session/.ack-transaction.json"
s="$(curl -sf "http://127.0.0.1:$PORT/api/state")"
# Restore the empty queue expected by the existing watch lifecycle fixture.
rm "$d/state/session/wake.jsonl"

# T-137: whether firstmate is watched, read from the real watch
# (bin/fm-watch-arm.sh, bin/lib/fm_watch.py). Nothing has ever watched this
# fixture, and worker-1 is aboard T-A: the board says firstmate is not
# watched, with an open gap that began when worker-1 did. A cycle holding
# the watch reads as watched, with no gap; a wake claimed is the last wake,
# with its reason; a wake no arm has taken yet is waiting; and once the
# cycle's owner is gone the gap is open again, from when the cycle ended.
began="$(jq -r 'select(.actor=="worker-1")|.ts' "$d/state/events.jsonl" | head -1)"
assert_eq "false" "$(jq -r .watch.alive <<<"$s")" "with no watcher the board says firstmate is not watched"
assert_eq "1 $began" "$(jq -r '"\(.watch.gap.inflight) \(.watch.gap.since)"' <<<"$s")" \
  "work in flight with nothing ever watching is an open gap, from when the work began"
# the stand-in session that owns the cycle, ended and awaited below
sleep 300 & watch_owner=$!
# run from the fixture: a checkout under state/worktrees is a crew round's,
# and never arms
watchcli() { (cd "$d" && FM_SESSION_PID="$watch_owner" FM_LIFELINE_GRACE=1 "$ROOT/bin/fm-watch-arm.sh" --repo "$d" "$@"); }
wake_written() {
  local wake
  for wake in "$d/state/watch/wake/"*.json; do
    [ -f "$wake" ] && return 0
  done
  return 1
}
unwatched() { [ "$(watchcli --status 2>/dev/null | jq -r .watched)" = false ]; }
watchcli --ensure >/dev/null 2>&1
sw="$(curl -sf "http://127.0.0.1:$PORT/api/state")"
assert_eq "true 1 null" "$(jq -r '"\(.watch.alive) \(.watch.gen) \(.watch.gap)"' <<<"$sw")" \
  "a cycle holding the watch reads as watched, with no gap"
python3 "$ROOT/bin/lib/fm_lifeline.py" push "$d" reviewer-1 verdict "review: T-A APPROVE 4ea1ec2" >/dev/null
assert_eq "review: T-A APPROVE 4ea1ec2" "$(watchcli --max-wait 10 2>/dev/null)" "an arm claims the wake"
python3 "$ROOT/bin/lib/fm_lifeline.py" push "$d" worker-1 round_end "finished: T-A worker-1 ok" >/dev/null
wait_for 10 wake_written
sw="$(curl -sf "http://127.0.0.1:$PORT/api/state")"
assert_eq "review: T-A APPROVE 4ea1ec2" "$(jq -r .watch.lastWake.reason <<<"$sw")" "the last wake and its reason are shown"
assert_eq "1" "$(jq -r .watch.waiting <<<"$sw")" "and a wake no arm has taken yet is waiting"
assert_eq "$(watchcli --status | jq -r .waiting)" "$(jq -r .watch.waiting <<<"$sw")" \
  "the board and watch count the same unacknowledged wake once"
assert_eq "false" "$(python3 - "$ROOT" "$d" <<'PY'
import sys
sys.dont_write_bytecode = True
sys.path.insert(0, sys.argv[1] + '/bin/lib')
import fm_watch as W
items = W._queue_from(sys.argv[2], 0)[0]
item = next(i for i in reversed(items) if i['id'] == 'worker-1')
print(str(W.delivered(sys.argv[2], item)).lower())
PY
)" "writing a wake for an arm does not acknowledge delivery"
kill "$watch_owner" 2>/dev/null; wait "$watch_owner" 2>/dev/null
wait_for 15 unwatched
sw="$(curl -sf "http://127.0.0.1:$PORT/api/state")"
ended="$(jq -r .ended "$d/state/watch/owner.json" 2>/dev/null)"
assert_ne "null" "$ended" "the cycle says when it ended"
assert_eq "false $ended" "$(jq -r '"\(.watch.alive) \(.watch.gap.since)"' <<<"$sw")" \
  "with its owner gone the board is not watched, and the gap runs from when the cycle ended"
assert_eq "1" "$(grep -c 'data-watch' "$d/board/public/index.html")" "the page carries the watch line"
rm -rf "$d/state/watch" "$d/state/session"


# a task whose review never happened, or whose worker died, must not keep
# reading as work in progress
# reset between iterations, or the second type is asserted against a stage
# the first one already set and its absence from the map would go unnoticed
for pair in review_failed worker_crashed; do
  FM_ROOT="$d" "$d/bin/fm-emit.sh" --actor worker-1 --task T-A --type dispatched \
    --en "back to work" --tw "回去做" >/dev/null
  assert_eq "working" "$(jq -r '.tasks[]|select(.id=="T-A")|.stage' \
    <<<"$(curl -sf "http://127.0.0.1:$PORT/api/state")")" "T-A is working again before $pair"
  FM_ROOT="$d" "$d/bin/fm-emit.sh" --actor worker-1 --task T-A --type "$pair" \
    --en "stuck" --tw "卡住" >/dev/null
  s2="$(curl -sf "http://127.0.0.1:$PORT/api/state")"
  assert_eq "gate" "$(jq -r '.tasks[]|select(.id=="T-A")|.stage' <<<"$s2")" \
    "$pair leaves the task blocked, not working"
  # the stage is what the lane shows; inflight is the number a human reads to
  # decide whether anything is moving, and it is the one that must not lie
  assert_eq "0" "$(jq -r .counts.inflight <<<"$s2")" "$pair stops counting as in flight"
  assert_eq "1" "$(jq -r .counts.blocked <<<"$s2")" "$pair counts as blocked"
done


page="$(curl -sf "http://127.0.0.1:$PORT/")"
# T-118: a task is the captain's only while a card for it is pending. The
# request event on its own is not a card: once the card is answered or gone,
# the request left behind in the log must not keep the task in his lane.
FM_ROOT="$d" "$d/bin/fm-emit.sh" --actor worker-1 --task T-C --type dispatched \
  --en "picked up" --tw "接下" >/dev/null
FM_ROOT="$d" "$d/bin/fm-emit.sh" --actor firstmate --task T-C --type decision_requested \
  --pr 12 --en "asked the captain" --tw "請示船長" >/dev/null
sc="$(curl -sf "http://127.0.0.1:$PORT/api/state")"
assert_ne "" "$sc" "the board is answering"
assert_eq "working" "$(jq -r '.tasks[]|select(.id=="T-C")|.stage' <<<"$sc")" \
  "a request with no card pending does not hold the captain's lane"
# a task the captain has been asked about is the captain's, whatever was
# said about it before, and it keeps waiting: while the card is up, nothing
# said afterwards moves the task out of the captain's lane. It was reading as
# "working" because a dispatch that should never have happened was the last
# thing in the log.
mkdir -p "$d/state/pending"
printf '{"id":"D-12","task":"T-C","kind":"merge","pr":12,"title":"ready"}\n' > "$d/state/pending/D-12.json"
assert_eq "captain" "$(jq -r '.tasks[]|select(.id=="T-C")|.stage' <<<"$(curl -sf "http://127.0.0.1:$PORT/api/state")")" \
  "a task with a card pending waits on the captain"
FM_ROOT="$d" "$d/bin/fm-emit.sh" --actor worker-1 --task T-C --type dispatched \
  --en "a stray dispatch" --tw "多餘的派工" >/dev/null
sc2="$(curl -sf "http://127.0.0.1:$PORT/api/state")"
assert_eq "captain" "$(jq -r '.tasks[]|select(.id=="T-C")|.stage' <<<"$sc2")" \
  "and stays there while the card is up, whatever is said after"
rm -f "$d/state/pending/D-12.json"
assert_eq "working" "$(jq -r '.tasks[]|select(.id=="T-C")|.stage' <<<"$(curl -sf "http://127.0.0.1:$PORT/api/state")")" \
  "and once the card is gone the task is where its other events put it"

# firstmate's own state, which nothing read: on a green-lit board with
# nothing assigned it is the most visible crewman, and an earlier version
# drew it slumped and grey while its bubble said "dispatching"
sq="$(curl -sf "http://127.0.0.1:$PORT/api/state")"
assert_eq "captain" "$(jq -r '.crew[]|select(.id=="firstmate")|.state' <<<"$sq")" \
  "firstmate retains its recorded decision-request phase without task metadata"

# firstmate is an agent too, and it does work of its own. Reporting it as
# "dispatching" whatever it was actually doing was the board saying what
# the role is for rather than what the agent is on - and firstmate is the
# crewman a reader most needs the truth about, because it is the one that
# works outside the board.
FM_ROOT="$d" "$d/bin/fm-emit.sh" --actor firstmate --task T-A --type dispatched \
  --en "firstmate took it itself" --tw "大副自己做" >/dev/null
sf="$(curl -sf "http://127.0.0.1:$PORT/api/state")"
assert_ne "" "$sf" "the board is answering"
assert_eq "T-A" "$(jq -r '.crew[]|select(.id=="firstmate")|.task' <<<"$sf")" \
  "firstmate carries the task it is on"
assert_eq "1" "$(jq -r '[.crew[]|select(.id=="firstmate")]|length' <<<"$sf")" \
  "and appears once, not twice"

# The crew are AGENTS, not tasks. One worker that has moved between three
# tasks is one crewman, and github - which is the sync, not an agent - is
# never aboard. Drawing one figure per in-flight task put pull requests on
# the deck and made the ship grow with the backlog.
FM_ROOT="$d" "$d/bin/fm-emit.sh" --actor worker-2 --task T-A --type dispatched \
  --en "on T-A" --tw "在做 T-A" >/dev/null
FM_ROOT="$d" "$d/bin/fm-emit.sh" --actor worker-2 --task T-B --type dispatched \
  --en "on T-B now" --tw "改做 T-B" >/dev/null
FM_ROOT="$d" "$d/bin/fm-emit.sh" --actor github --task T-A --type pr_opened --pr 3 \
  --en "sync" --tw "同步" >/dev/null
sk="$(curl -sf "http://127.0.0.1:$PORT/api/state")"
assert_ne "" "$sk" "the board is answering"
ids="$(jq -r '.crew[].id' <<<"$sk" | sort | tr '\n' ' ')"
assert_contains "$ids" "firstmate" "firstmate is always aboard"
assert_contains "$ids" "worker-2" "an agent that is working is aboard"
assert_lacks "$ids" "github" "the sync is not an agent and is never aboard"
assert_eq "1" "$(jq -r '[.crew[]|select(.id=="worker-2")]|length' <<<"$sk")" \
  "one agent on three tasks is one crewman, not three"
assert_eq "T-B" "$(jq -r '.crew[]|select(.id=="worker-2")|.task' <<<"$sk")" \
  "and it is on the task it moved to"
# jq -r renders null as the four characters "null", so `assert_ne ""`
# over jq output is green for a field that is not there at all
assert_eq "second" "$(jq -r '.crew[]|select(.id=="worker-2")|.title' <<<"$sk")" \
  "with the task's own title beside it"
assert_eq "worker" "$(jq -r '.crew[]|select(.id=="worker-2")|.role' <<<"$sk")" \
  "a worker is a worker"


# An agent that has finished its run has gone home, whatever became of
# the task. Without this "aboard" meant "ever touched a task that is not
# finished yet": a worker that died at a gate was drawn working for ever,
# and the rate followed the history rather than what is happening now.
FM_ROOT="$d" "$d/bin/fm-emit.sh" --actor worker-9 --task T-A --type dispatched \
  --en "started" --tw "開工" >/dev/null
sr="$(curl -sf "http://127.0.0.1:$PORT/api/state")"
assert_contains "$(jq -r '.crew[].id' <<<"$sr" | tr '\n' ' ')" "worker-9" \
  "an agent that started is aboard"
FM_ROOT="$d" "$d/bin/fm-emit.sh" --actor worker-9 --task T-A --type agent_finished \
  --en "run finished" --tw "執行結束" >/dev/null
sr2="$(curl -sf "http://127.0.0.1:$PORT/api/state")"
assert_lacks "$(jq -r '.crew[].id' <<<"$sr2" | tr '\n' ' ')" "worker-9" \
  "and is not aboard once its run has ended, though T-A is still open"
assert_eq "working" "$(jq -r '.tasks[]|select(.id=="T-A")|.stage' <<<"$sr2")" \
  "which did not change the task"


# every state the server sends is one the page can draw: it becomes a
# class name, a dictionary key and a progress number, so an open set means
# a crewman with no style and no label
FM_ROOT="$d" "$d/bin/fm-emit.sh" --actor worker-7 --task T-B --type dispatched \
  --en "on a queued task" --tw "在排隊的任務上" >/dev/null
sv="$(curl -sf "http://127.0.0.1:$PORT/api/state")"
# Comments stripped across the whole file, not line by line: CSS block
# comments span lines, and a line-oriented sed leaves lines 2..n of every
# block behind. A rule named on the second line of a comment would have
# satisfied this check with nothing in the sheet - which is exactly what
# the check exists to prevent.
css_rules="$(perl -0777 -pe 's{/\*.*?\*/}{}gs' "$ROOT/board/public/ship.css")"
# a loop over server-derived data is green when the data is empty, which
# is green for a check that read nothing
# every state the server's own closed set can produce, not the ones this
# fixture happened to produce: a sixth added without a rule has to fail
declared="$(sed -n 's/^type CrewState = //p' "$ROOT/board/server.ts" \
  | tr -d ';"' | tr '|' '\n' | tr -d ' ' | sed '/^$/d')"
assert_ne "" "$declared" "the crew states are declared in one place"
for st in $declared; do
  assert_contains "$css_rules" ".roster li.st-$st" "the page can draw state $st"
done
# and the animation each of them names actually exists: a --baseAnim
# pointing at a keyframe nobody defined resolves to nothing, silently,
# and a check that greps only for the selector cannot tell
animations="$(printf '%s' "$css_rules" | grep -oE '\-\-baseAnim:[a-zA-Z0-9_-]+' | cut -d: -f2 | sort -u)"
if [ -z "$animations" ]; then
  assert_lacks "$css_rules" "--baseAnim" "the roster has no scene animation references"
else
  for anim in $animations; do
    assert_contains "$css_rules" "@keyframes $anim" "the keyframe $anim is defined"
  done
fi
# and what the fixture produced is inside that set
for st in $(jq -r '.crew[].state' <<<"$sv" | sort -u); do
  assert_contains "$declared" "$st" "state $st is one the server declares"
done

# the captain is not crew: nothing in the server's list is him, and the
# page draws him from the same pending deck the cards come from
assert_lacks "$(jq -r '.crew[].role' <<<"$sr2" | tr '\n' ' ')" "captain" \
  "the server does not put the captain in the crew"

# The role is STATED, and the test has to be able to tell that from the
# name fallback - so the actor is called something the fallback would get
# wrong. Deleting the two data.role lines turns this red; before, every
# fixture used a name the fallback happened to read correctly.
FM_ROOT="$d" "$d/bin/fm-emit.sh" --actor rev-9 --task T-A --type review_opened \
  --data '{"role":"reviewer"}' --en "a reviewer by another name" --tw "換個名字的檢查官" >/dev/null
sn="$(curl -sf "http://127.0.0.1:$PORT/api/state")"
assert_eq "reviewer" "$(jq -r '.crew[]|select(.id=="rev-9")|.role' <<<"$sn")" \
  "an actor named rev-9 is a reviewer because the run said so"

# a log written before the role was stated: the fallback that reads the
# actor's name is what every existing log looks like
FM_ROOT="$d" "$d/bin/fm-emit.sh" --actor reviewer-old --task T-A --type review_opened \
  --en "an old event with no role" --tw "沒有 role 的舊事件" >/dev/null
so="$(curl -sf "http://127.0.0.1:$PORT/api/state")"
assert_eq "reviewer" "$(jq -r '.crew[]|select(.id=="reviewer-old")|.role' <<<"$so")" \
  "an event with no stated role falls back to the actor's name"

# a task that was closed rather than merged also sends its agent home
FM_ROOT="$d" "$d/bin/fm-emit.sh" --actor worker-closed --task T-C --type dispatched \
  --en "on T-C" --tw "在做 T-C" >/dev/null
FM_ROOT="$d" "$d/bin/fm-emit.sh" --actor captain --task T-C --type closed \
  --en "abandoned" --tw "放棄" >/dev/null
sclosed="$(curl -sf "http://127.0.0.1:$PORT/api/state")"
assert_lacks "$(jq -r '.crew[].id' <<<"$sclosed" | tr '\n' ' ')" "worker-closed" \
  "a closed task sends its agent home too, not only a merged one"

# A new event type has readers beyond this one. fm-dispatch keys on
# dispatched minus merged-or-closed, the autopilot on pr_opened and merged,
# the autopilot on type and pr - none of them has a default branch that
# does anything with an unknown type, and this asserts that rather than
# asserting it in prose: the same log, before and after an
# agent_finished, has to give the dispatcher the same answer.
before="$(cd "$d" && FM_ROOT="$d" "$ROOT/bin/fm-dispatch.sh" --dry-run --repo "$d" 2>&1 | sort)"
FM_ROOT="$d" "$d/bin/fm-emit.sh" --actor worker-2 --task T-A --type agent_finished \
  --en "ended" --tw "結束" >/dev/null
after="$(cd "$d" && FM_ROOT="$d" "$ROOT/bin/fm-dispatch.sh" --dry-run --repo "$d" 2>&1 | sort)"
assert_eq "$before" "$after" "an ending does not change what the dispatcher would start"

# 24 is one number, and the page is told what it was
assert_eq "24" "$(jq -r '.deckLimit' <<<"$sv")" "the server says what the deck holds"

# An agent whose task is finished has gone home. The backstop for a run
# that never got to say it ended, and the merged half of it: the closed
# half is covered above by worker-closed.
#
# On worker-7, and not on worker-2, which is what this asserted before:
# worker-2 said agent_finished ten lines up, the ending is checked first
# and had already taken it off the deck, so the assertion was green with
# `merged` deleted from the server's FINAL set. worker-7 was dispatched
# on T-B and has never said anything since.
sbefore="$(curl -sf "http://127.0.0.1:$PORT/api/state")"
assert_contains "$(jq -r '.crew[].id' <<<"$sbefore" | tr '\n' ' ')" "worker-7" \
  "an agent on an open task, which has not said it ended, is aboard"
FM_ROOT="$d" "$d/bin/fm-emit.sh" --actor captain --task T-B --type merged --pr 3 \
  --en "merged" --tw "已合併" >/dev/null
sk2="$(curl -sf "http://127.0.0.1:$PORT/api/state")"
assert_lacks "$(jq -r '.crew[].id' <<<"$sk2" | tr '\n' ' ')" "worker-7" \
  "and is not aboard once that task is merged"

# merged is where a task stops. A review round run against the branch
# afterwards would otherwise move it back to "in review", which reads as
# work in progress that nobody is doing.
FM_ROOT="$d" "$d/bin/fm-emit.sh" --actor captain --task T-B --type merged \
  --en "merged" --tw "已合併" >/dev/null
FM_ROOT="$d" "$d/bin/fm-emit.sh" --actor reviewer-1 --task T-B --type review_opened \
  --en "a late round" --tw "遲到的一輪" >/dev/null
sm="$(curl -sf "http://127.0.0.1:$PORT/api/state")"
assert_ne "" "$sm" "the board is answering"
assert_eq "merged" "$(jq -r '.tasks[]|select(.id=="T-B")|.stage' <<<"$sm")" \
  "a merged task stays merged whatever is said about it afterwards"
# Pending must not override a terminal stage, and history identity comes from
# events even when the task is absent from current definitions.
mkdir -p "$d/state/pending"
printf '{"id":"D-88","task":"T-B","kind":"choice","title":"late card"}\n' > "$d/state/pending/D-88.json"
FM_ROOT="$d" "$d/bin/fm-emit.sh" --actor github --task T-999 --type merged --pr 999 \
  --en "external merge" --tw "外部合併" >/dev/null
sterm="$(curl -sf "http://127.0.0.1:$PORT/api/state")"
assert_eq "merged" "$(jq -r '.tasks[]|select(.id=="T-B")|.stage' <<<"$sterm")" \
  "a pending card cannot move a merged task back to captain"
# T-118: never hidden - a card raised under the wrong task must stay where the
# captain can see it - and it says its task is final
assert_eq "merged" "$(jq -r '.pending[]|select(.id=="D-88")|.task_final' <<<"$sterm")" \
  "a pending card for a merged task is shown, marked as on a final task"
assert_eq "merged" "$(jq -r '.tasks[]|select(.id=="T-999")|.stage' <<<"$sterm")" \
  "completed identity from events reaches state without a current definition"
assert_eq "999" "$(jq -r '.tasks[]|select(.id=="T-999")|.pr' <<<"$sterm")" \
  "and keeps the event PR on that completed identity"
rm -f "$d/state/pending/D-88.json"

# Pending list order is oldest request first (T-054, design section 15.10
# point 4), never readdirSync's, which differs between filesystems, and never
# the id's: a card asked for later does not jump ahead because its number is
# smaller. A card is requested once, so its file's time is when it was asked;
# two asked at the same moment fall back to the id, numerically. T-A is still
# open here (T-B merged, T-C closed); settled tasks filter.
mkdir -p "$d/state/pending"
printf '{"id":"D-100","task":"T-A","kind":"choice","title":"hundred"}\n' > "$d/state/pending/D-100.json"
printf '{"id":"D-20","task":"T-A","kind":"choice","title":"twenty"}\n' > "$d/state/pending/D-20.json"
printf '{"id":"D-3","task":"T-A","kind":"choice","title":"three"}\n' > "$d/state/pending/D-3.json"
touch -t 202601010000.00 "$d/state/pending/D-20.json"
touch -t 202601010100.00 "$d/state/pending/D-100.json" "$d/state/pending/D-3.json"
sord="$(curl -sf "http://127.0.0.1:$PORT/api/state")"
assert_eq "D-20 D-3 D-100" "$(jq -r '[.pending[].id]|join(" ")' <<<"$sord")" \
  "pending cards are listed oldest request first, a tie by id, never readdir order"
assert_eq "null" "$(jq -r '.pending[]|select(.id=="D-3")|.task_final' <<<"$sord")" \
  "a card on open work carries no final-task mark"
# bin/fm-decide.sh creates a card once and nothing rewrites one; a card that
# is rewritten anyway keeps the place it was asked for
touch -t 202601010200.00 "$d/state/pending/D-20.json"
assert_eq "D-20 D-3 D-100" "$(curl -sf "http://127.0.0.1:$PORT/api/state" | jq -r '[.pending[].id]|join(" ")')" \
  "a card rewritten after it was asked for keeps its place"
rm -f "$d/state/pending/D-100.json" "$d/state/pending/D-20.json" "$d/state/pending/D-3.json"

# T-047: a card whose id names its owner is listed beside the old ones, with
# the project and task parsed from its id, has its diagram served under that
# id, and is answered like any other
nid=D-firstmate-workflow-T047-2
mkdir -p "$d/i18n"
cp "$ROOT/bin/fm-diagram.sh" "$d/bin/"
cp "$ROOT/i18n/ui.en.json" "$ROOT/i18n/ui.zh-TW.json" "$ROOT/i18n/tw2cn.tsv" "$d/i18n/"
printf '{"id":"D-5","task":"T-A","kind":"choice","title":"old"}\n' > "$d/state/pending/D-5.json"
jq -n --arg id "$nid" '{id:$id,task:"T-A",kind:"choice",title:"owned",
  details:{en:{before:"one",after:"two"},"zh-TW":{before:"一",after:"二"}}}' > "$d/state/pending/$nid.json"
assert_ok "FM_ROOT='$d' bash '$d/bin/fm-diagram.sh' --decision '$nid' --repo '$d'" "the new-form card is drawn"
snew="$(curl -sf "http://127.0.0.1:$PORT/api/state")"
assert_eq "D-5 $nid" "$(jq -r '[.pending[].id]|join(" ")' <<<"$snew")" "the board lists it beside an old card"
assert_eq "firstmate-workflow T-047" \
  "$(jq -r --arg i "$nid" '.pending[]|select(.id==$i)|.owner|"\(.project) \(.task)"' <<<"$snew")" \
  "with its project and task parsed from the id"
for l in en zh-TW zh-CN; do
  assert_eq "200" "$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:$PORT/diagrams/$nid.$l.html")" \
    "and serves its $l diagram under that id"
done
# the body is built outside the substitution: bash 3.2 brace-expands a
# {a,b} inside "$(...)" that only escaped quotes protect, and runs it twice
body="$(jq -cn --arg i "$nid" '{id:$i,chosen:"B"}')"
assert_eq "true" "$(wcurl "$PORT" -s -X POST -H 'content-type: application/json' \
  -d "$body" "http://127.0.0.1:$PORT/decisions" | jq -r .ok)" "the board answers it"
assert_eq "B" "$(jq -r .chosen "$d/state/decisions/$nid.json")" "and the answer lands under its id"
assert_eq "B" "$(curl -sf "http://127.0.0.1:$PORT/api/state" | jq -r --arg i "$nid" '.responses[]|select(.id==$i)|.chosen')" \
  "and is read back among the responses"
rm -f "$d/state/pending/D-5.json"

# T-112: a skill-update card, D-SK-<n>, is listed as one the board will answer,
# with fm-decide.sh's pattern; an id no route accepts is listed as not answerable
printf '{"id":"D-SK-001","task":"SK-001","kind":"choice","title":"adopt SK-001"}\n' > "$d/state/pending/D-SK-001.json"
printf '{"id":"D-SK-01","task":"SK-01","kind":"choice","title":"malformed"}\n' > "$d/state/pending/D-SK-01.json"
ssk="$(curl -sf "http://127.0.0.1:$PORT/api/state")"
assert_eq "true" "$(jq -r '.pending[]|select(.id=="D-SK-001")|.answerable' <<<"$ssk")" \
  "a skill-update card is listed as answerable"
assert_eq "null" "$(jq -r '.pending[]|select(.id=="D-SK-001")|.owner' <<<"$ssk")" "and names no owner"
assert_eq "false" "$(jq -r '.pending[]|select(.id=="D-SK-01")|.answerable' <<<"$ssk")" \
  "a card under an id the route refuses is listed as not answerable"
rm -f "$d/state/pending/D-SK-001.json" "$d/state/pending/D-SK-01.json"

# review_failed without review_outcome is missing-review/error, never a
# directed rejection. The additive datum makes a substantive reject handoff.
FM_ROOT="$d" "$d/bin/fm-emit.sh" --actor worker-real --task T-D --type dispatched \
  --data '{"role":"worker"}' --en "Build" --tw "實作" >/dev/null
FM_ROOT="$d" "$d/bin/fm-emit.sh" --actor reviewer-real --task T-D --type dispatched \
  --data '{"role":"reviewer"}' --en "Review" --tw "審查" >/dev/null
FM_ROOT="$d" "$d/bin/fm-emit.sh" --actor reviewer-real --task T-D --type review_failed \
  --en "No review produced" --tw "未產生審查" >/dev/null
sno="$(curl -sf "http://127.0.0.1:$PORT/api/state")"
assert_eq "0" "$(jq -r '[.handoffs[]|select(.kind=="reject")]|length' <<<"$sno")" \
  "legacy review_failed is not a substantive rejection handoff"
FM_ROOT="$d" "$d/bin/fm-emit.sh" --actor reviewer-real --task T-D --type review_failed \
  --data '{"review_outcome":"rejected"}' --en "Changes requested" --tw "要求修改" >/dev/null
syes="$(curl -sf "http://127.0.0.1:$PORT/api/state")"
assert_eq "1" "$(jq -r '[.handoffs[]|select(.kind=="reject")]|length' <<<"$syes")" \
  "review_outcome rejected yields one directed rejection"
assert_eq "worker-real" "$(jq -r '.handoffs[]|select(.kind=="reject")|.to' <<<"$syes")" \
  "and targets the real worker on the same task"
# T-145: each named end carries the role the board knows it by - what it said
# it is, or was dispatched as - never one read from its name. An actor that
# said nothing and was never dispatched is one the board cannot place.
assert_eq "reviewer>worker" "$(jq -r '.handoffs[]|select(.kind=="reject")|"\(.from_role)>\(.to_role)"' <<<"$syes")" \
  "a hand-off names the role of each end"
FM_ROOT="$d" "$d/bin/fm-emit.sh" --actor secondmate --task T-E --type dispatched \
  --en "Odd job" --tw "怪差事" >/dev/null
FM_ROOT="$d" "$d/bin/fm-emit.sh" --actor mystery --task T-E --type approved \
  --en "Approved" --tw "通過" >/dev/null
FM_ROOT="$d" "$d/bin/fm-emit.sh" --actor reviewer-odd --task T-E --type approved \
  --en "Approved" --tw "通過" >/dev/null
FM_ROOT="$d" "$d/bin/fm-emit.sh" --actor invalid-role --task T-E --type approved \
  --data '{"role":"mystery"}' --en "Unknown role" --tw "未知角色" >/dev/null
sodd="$(curl -sf "http://127.0.0.1:$PORT/api/state")"
assert_eq "firstmate>worker" "$(jq -r '.handoffs[]|select(.kind=="order" and .to=="secondmate")|"\(.from_role)>\(.to_role)"' <<<"$sodd")" \
  "a crewman dispatched under any name is placed by what it was dispatched as"
assert_eq "null>firstmate" "$(jq -r '.handoffs[]|select(.kind=="approve" and .from=="mystery")|"\(.from_role)>\(.to_role)"' <<<"$sodd")" \
  "an actor that never said what it is has no role"
assert_eq "null" "$(jq -r '.handoffs[]|select(.kind=="approve" and .from=="reviewer-odd")|.from_role' <<<"$sodd")" \
  "nor does one whose name merely starts like a role"
assert_eq "0" "$(jq -r '[.crew[]|select(.id=="mystery" or .id=="reviewer-odd" or .id=="invalid-role")]|length' <<<"$sodd")" \
  "an unplaced verdict actor never boards, even before its finish event"
# Roleless activity is still crew evidence, including when followed by a verdict.
for kind in criteria_returned approved; do
  expected_state=unknown
  [ "$kind" != approved ] || expected_state=captain
  FM_ROOT="$d" "$d/bin/fm-emit.sh" --actor worker-unknown --task T-E --type "$kind" \
    --en "Unclassified activity" --tw "未分類活動" >/dev/null
  sroleless="$(curl -sf "http://127.0.0.1:$PORT/api/state")"
  assert_eq "$expected_state" "$(jq -r '.crew[]|select(.id=="worker-unknown")|.state' <<<"$sroleless")" \
    "roleless activity stays aboard with its event state after $kind"
done
for a in secondmate mystery reviewer-odd invalid-role worker-unknown; do   # off the deck again, for what reads the crew below
  FM_ROOT="$d" "$d/bin/fm-emit.sh" --actor "$a" --task T-E --type agent_finished >/dev/null
done

# a card for a pull request that has already been merged is the board
# lying: the captain is offered a choice that cannot be made
mkdir -p "$d/state/pending"
printf '{"id":"D-77","task":"T-A","kind":"merge","pr":77,"title":"stale"}\n' > "$d/state/pending/D-77.json"
s3="$(curl -sf "http://127.0.0.1:$PORT/api/state")"
assert_ne "" "$s3" "the board is still answering at this point"
assert_contains "$(jq -r '.pending[].id' <<<"$s3" | tr '\n' ' ')" "D-77" "an open decision is on the board"
FM_ROOT="$d" "$d/bin/fm-emit.sh" --actor captain --task T-A --type merged --pr 77 \
  --en "merged" --tw "已合併" >/dev/null
s4="$(curl -sf "http://127.0.0.1:$PORT/api/state")"
assert_lacks "$(jq -r '.pending[].id' <<<"$s4" | tr '\n' ' ')" "D-77" \
  "and it is gone once the pull request is merged"
rm -f "$d/state/pending/D-77.json"

assert_contains "$page" "Captain" "the page is served"
assert_contains "$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:$PORT/../../etc/passwd")" "40" \
  "it will not serve a path climbing out of board/public"

# the stream carries the state, and a new event reaches an open stream
( wait_for 10 grep -q "event: state" "$d/stream" || exit 1
  FM_ROOT="$d" "$d/bin/fm-emit.sh" --actor worker-1 --task T-A --type merged \
    --en "merged T-A" --tw "T-A 已合併" >/dev/null ) &
writer=$!
# --max-time bounds the read; a bare wait here would also wait on the server,
# which never exits
curl -sN --max-time 4 "http://127.0.0.1:$PORT/events" > "$d/stream" 2>/dev/null || true
wait "$writer" 2>/dev/null || true
stream="$(cat "$d/stream")"
assert_contains "$stream" "event: state" "the stream opens with the state"
assert_contains "$stream" "merged" "an event written while the stream is open reaches it"

# The captain is not an agent and is never aboard. Not covered by the
# assertion above it, which reads roles rather than ids, nor by anything
# else here: every captain event in this fixture until now has been on a
# task that is merged or closed, so `done.has(task)` would have dropped
# him anyway and deleting the clause changed nothing.
FM_ROOT="$d" "$d/bin/fm-emit.sh" --actor captain --task T-D --type dispatched \
  --en "the captain says something about an open task" --tw "船長對未完成的任務說話" >/dev/null
scap="$(curl -sf "http://127.0.0.1:$PORT/api/state")"
assert_lacks "$(jq -r '.crew[].id' <<<"$scap" | tr '\n' ' ')" "captain" \
  "the captain is not crew even when he speaks about an open task"

# The role is what the run SAID, and the fallback that reads the name is
# only for logs written before it said anything. An actor named like a
# reviewer that states worker is the only case the stated-role branch
# decides on its own - rev-9 covers the mirror of it.
FM_ROOT="$d" "$d/bin/fm-emit.sh" --actor reviewer-really-a-worker --task T-D \
  --data '{"role":"worker"}' --type dispatched \
  --en "named like a reviewer, says it is a worker" --tw "名字像 reviewer，說自己是 worker" >/dev/null
srw="$(curl -sf "http://127.0.0.1:$PORT/api/state")"
assert_eq "worker" "$(jq -r '.crew[]|select(.id=="reviewer-really-a-worker")|.role' <<<"$srw")" \
  "an actor named like a reviewer that states worker is a worker"

# The deck holds a fixed number, and when more agents are aboard than it
# holds the server has to decide which ones are shown. It keeps the ones
# that spoke most recently. The first version kept the oldest without
# meaning to: `Map.set` on a key that is already present keeps its
# original position, so the map was ordered by each actor's FIRST event
# and a full deck showed the stalest crew while agents that had just
# boarded fell off the end. Last in this fixture, because it fills the
# deck and every assertion above reads the crew. On T-D, which exists in
# this fixture for exactly this and is the only task nothing above has
# merged or closed - an agent on a finished task is not aboard at all,
# so a crowd on T-A would have left the deck empty and every assertion
# here green for the wrong reason.
limit="$(jq -r '.deckLimit' <<<"$(curl -sf "http://127.0.0.1:$PORT/api/state")")"
assert_matches "$limit" '^[0-9]+$' "the server states the deck limit"
n=$(( limit + 6 ))
i=0
while [ "$i" -lt "$n" ]; do
  FM_ROOT="$d" "$d/bin/fm-emit.sh" --actor "crowd-$i" --task T-D --type dispatched \
    --en "aboard" --tw "上船" >/dev/null
  i=$(( i + 1 ))
done
sd="$(curl -sf "http://127.0.0.1:$PORT/api/state")"
assert_eq "$limit" "$(jq -r '.crew|length' <<<"$sd")" "the deck holds its limit and no more"
# Ordered by each actor's LAST event, which is the whole of the fix and
# is invisible in a crowd where everyone spoke once: with one event each,
# first and last are the same event and the order is the same with the
# `delete` and without it. So the oldest crewman aboard speaks again, and
# has to come back to the head.
FM_ROOT="$d" "$d/bin/fm-emit.sh" --actor crowd-0 --task T-D --type gate_failed \
  --en "still here" --tw "還在" >/dev/null
sd2="$(curl -sf "http://127.0.0.1:$PORT/api/state")"
crowd2="$(jq -r '.crew[].id' <<<"$sd2" | tr '\n' ' ')"
assert_contains "$crowd2" "crowd-0 " "the agent that has been aboard longest, having just spoken, is on the deck"
assert_lacks "$crowd2" "crowd-1 " "and the one that has now been quiet longest is the one dropped"
crowd="$(jq -r '.crew[].id' <<<"$sd" | tr '\n' ' ')"
assert_contains "$crowd" "firstmate " "firstmate keeps its place at the head"
assert_eq "firstmate" "$(jq -r '.crew[0].id' <<<"$sd")" "and it is the head"
assert_contains "$crowd" "crowd-$(( n - 1 )) " "the agent that boarded last is on the deck"
assert_lacks "$crowd" "crowd-0 " "and the one that has been aboard longest is the one dropped"

# loopback only - on the option that binds, not on the file's prose
# Do not pipe grep -q under pipefail: early close makes sed SIGPIPE and flakes red.
_bind_src="$(sed 's|//.*||' "$ROOT/board/server.ts")"
assert_matches "$_bind_src" 'hostname:[[:space:]]*"127\.0\.0\.1"' \
  "the bind option is 127.0.0.1"
# strip from // onward: a trailing comment is still a comment
assert_lacks "$_bind_src" '0.0.0.0' \
  "no code binds 0.0.0.0"

# T-242: confirmation validates before writes, and a check never records.
mkdir -p "$d/state/pending"
cp -R "$ROOT/i18n" "$d/"
jq -n '{id:"D-9242",task:"T-B",kind:"merge",pr:9242,check_answer:0,
 details:{en:{intent:[{text:"Read this"},{text:"Read that"}],door:{kind:"one-way"},check:{options:["Keep","Lose"],why:"Read each intent and choose Keep."}},
 "zh-TW":{check:{why:"確認每條意圖並選擇保留。"}}},effect:{A:"hold"}}' > "$d/door-template"
# The explicit effect is in details, as in a real card. A is nonmerge here.
jq '.details.effect={A:"hold",B:"merge"} | del(.effect)' "$d/door-template" > "$d/state/pending/D-9242.json"
door_post() {
  wcurl "$PORT" -s -o "$d/door-result" -w '%{http_code}' -H 'Content-Type: application/json' \
    -d "$2" "http://127.0.0.1:$PORT$1"
}
assert_eq 403 "$(curl -s -o /dev/null -w '%{http_code}' -H 'Content-Type: application/json' -d '{"id":"D-9242"}' "http://127.0.0.1:$PORT/decisions/check-door")" 'door check uses captain guard'
door_events_before="$(cat "$d/state/events.jsonl")"
for origin in '' https://evil.test; do
  door_body='{"id":"D-9242","reviewed_intents":[1,2],"check_answer":0}'
  assert_eq 403 "$(curl -s -o "$d/door-result" -w '%{http_code}' -H "Authorization: Bearer $(secret_of "$PORT")" -H "Origin: $origin" -H 'Content-Type: application/json' -d "$door_body" "http://127.0.0.1:$PORT/decisions/check-door")" 'check rejects absent or foreign origin'
  assert_eq writeOrigin "$(jq -r .code "$d/door-result")" 'check shares origin guard'
done
assert_eq 403 "$(wcurl "$PORT" -s -o "$d/door-result" -w '%{http_code}' -H 'Content-Type: text/plain' -d '{}' "http://127.0.0.1:$PORT/decisions/check-door")" 'check shares JSON guard'
assert_eq writeJson "$(jq -r .code "$d/door-result")" 'check JSON refusal code'
for malformed in '{' null '[]' '{}' '{"id":true}' '{"id":"../D-9242"}'; do
  assert_eq 400 "$(door_post /decisions/check-door "$malformed")" 'malformed check envelope'
  assert_eq doorUnconfirmed "$(jq -r .code "$d/door-result")" 'malformed check envelope is JSON'
done
door_body='{"id":"D-999242","reviewed_intents":[1,2],"check_answer":0}'
assert_eq 404 "$(door_post /decisions/check-door "$door_body")" 'unknown check id'
assert_eq decisionMissing "$(jq -r .code "$d/door-result")" 'unknown check id code'
for route in /decisions/check-door /decisions; do
  suffix=''; [ "$route" = /decisions ] && suffix=',"chosen":"B"'
  for fields in '' ',"reviewed_intents":[1,2]' ',"reviewed_intents":[1,1],"check_answer":0' ',"reviewed_intents":[true],"check_answer":0' ',"reviewed_intents":[3],"check_answer":0' ',"reviewed_intents":[1.5],"check_answer":0' ',"reviewed_intents":null,"check_answer":0' ',"reviewed_intents":[1,2],"check_answer":true' ',"reviewed_intents":[1,2],"check_answer":2' ',"reviewed_intents":[1,2],"check_answer":0,"locale":"xx"' ',"reviewed_intents":{},"check_answer":0' ',"reviewed_intents":[0],"check_answer":0' ',"reviewed_intents":[1,2],"check_answer":null' ',"reviewed_intents":[1,2],"check_answer":1.5' ',"reviewed_intents":[1,2],"check_answer":-1' ',"reviewed_intents":[1,2],"check_answer":0,"locale":null' ',"reviewed_intents":[1,2],"check_answer":"0"' ',"reviewed_intents":[1,2],"check_answer":0,"locale":true' ',"reviewed_intents":[1,2],"check_answer":0,"locale":[]' ',"reviewed_intents":["1",2],"check_answer":0' ',"reviewed_intents":true,"check_answer":0'; do
    door_body="{\"id\":\"D-9242\"$suffix$fields}"
    assert_eq 400 "$(door_post "$route" "$door_body")" "$route malformed confirmation: $fields"
    assert_eq doorUnconfirmed "$(jq -r .code "$d/door-result")" 'malformed door refusal code'
  done
  for fields in ',"reviewed_intents":[1],"check_answer":0' ',"reviewed_intents":[1,2],"check_answer":1'; do
    door_body="{\"id\":\"D-9242\"$suffix$fields}"
    assert_eq 409 "$(door_post "$route" "$door_body")" "$route incomplete or wrong confirmation"
  done
  for stored in missing null true false '"0"' 1.5 -1 9; do
    if [ "$stored" = missing ]; then jq 'del(.check_answer)' "$d/door-template" > "$d/state/pending/D-9242.json"
    else jq --argjson answer "$stored" '.check_answer=$answer' "$d/door-template" > "$d/state/pending/D-9242.json"; fi
    jq '.details.effect={A:"hold",B:"merge"}' "$d/state/pending/D-9242.json" > "$d/fixed-door"
    mv "$d/fixed-door" "$d/state/pending/D-9242.json"
    door_body="{\"id\":\"D-9242\"$suffix,\"reviewed_intents\":[1,2],\"check_answer\":0}"
    assert_eq 409 "$(door_post "$route" "$door_body")" "$route invalid stored answer: $stored"
    door_body="{\"id\":\"D-9242\"$suffix,\"reviewed_intents\":[1,2]}"
    assert_eq 400 "$(door_post "$route" "$door_body")" "$route omitted submitted answer with stored $stored"
  done
  jq '.details.effect={A:"hold",B:"merge"} | del(.effect)' "$d/door-template" > "$d/state/pending/D-9242.json"
done
assert_ok "[ ! -f '$d/state/decisions/D-9242.json' ]" 'door refusals write no decision'
door_body='{"id":"D-9242","reviewed_intents":[2,1],"check_answer":0}'
assert_eq 200 "$(door_post /decisions/check-door "$door_body")" 'reordered complete check succeeds'
assert_eq '{"ok":true,"id":"D-9242"}' "$(jq -c . "$d/door-result")" 'check exposes no answer'
assert_ok "[ ! -f '$d/state/decisions/D-9242.json' ]" 'successful check records nothing'
assert_eq "$door_events_before" "$(cat "$d/state/events.jsonl")" 'checks and refusals emit no event'
door_stream="$(curl -s --max-time 1 "http://127.0.0.1:$PORT/events" || true)"
assert_contains "$door_stream" 'D-9242' 'SSE snapshot includes pending door'
assert_lacks "$door_stream" check_answer 'SSE strips stored answer'
assert_lacks "$door_stream" door_confirmation_fingerprint 'SSE strips fingerprint'
assert_lacks "$(curl -sf "http://127.0.0.1:$PORT/api/state")" check_answer 'pending state strips answer'
for locale in en zh-TW zh-CN; do
  door_body="{\"id\":\"D-9242\",\"reviewed_intents\":[1,2],\"check_answer\":1,\"locale\":\"$locale\"}"
  assert_eq 409 "$(door_post /decisions/check-door "$door_body")" "$locale wrong answer"
  case "$locale" in en) why='Read each intent and choose Keep.';; zh-TW) why='確認每條意圖並選擇保留。';; zh-CN) why='确认每条意图并选择保留。';; esac
  assert_eq "$why" "$(jq -r .why "$d/door-result")" "$locale feedback"
done
door_body='{"id":"D-9242","reviewed_intents":[1,2],"check_answer":1}'
assert_eq 409 "$(door_post /decisions/check-door "$door_body")" 'omitted locale uses configured English default'
assert_eq 'Read each intent and choose Keep.' "$(jq -r .why "$d/door-result")" 'default locale feedback'
jq '.id="D-9244" | .details.effect={A:"hold",B:"merge"}' "$d/door-template" > "$d/state/pending/D-9244.json"
door_body='{"id":"D-9244","chosen":"A"}'
assert_eq 200 "$(door_post /decisions "$door_body")" 'A with nonmerge effect needs no confirmation'
assert_eq false "$(jq 'has("check_ok")' "$d/state/decisions/D-9244.json")" 'nonmerge answer has no door confirmation'
jq '.id="D-9245" | .details.effect={A:"hold",B:"merge"} | .details.en.questions=[{kind:"fact",text:"The scope is correct."}]' "$d/door-template" > "$d/state/pending/D-9245.json"
door_body='{"id":"D-9245","chosen":"B","answers":[{"index":0,"ok":false,"text":"Change the scope."}]}'
assert_eq 200 "$(door_post /decisions "$door_body")" 'No changes a merge choice without confirmation'
assert_eq change "$(jq -r .chosen "$d/state/decisions/D-9245.json")" 'No records change'
assert_eq false "$(jq 'has("check_ok")' "$d/state/decisions/D-9245.json")" 'No answer has no confirmation fingerprint'
# Successful merge-effect confirmation is private and idempotent after pending removal.
cat > "$d/bin/fm-merge.sh" <<'SH'
#!/usr/bin/env bash
printf 'merge\n' >> "$FM_ROOT/door-effects"
SH
chmod +x "$d/bin/fm-merge.sh"
door_body='{"id":"D-9242","chosen":"B","reviewed_intents":[2,1],"check_answer":0}'
assert_eq 200 "$(door_post /decisions "$door_body")" 'non-A merge effect requires and records confirmation'
assert_eq '[1,2]' "$(jq -c .reviewed_intents "$d/state/decisions/D-9242.json")" 'record normalizes reviewed intents'
assert_eq true "$(jq .check_ok "$d/state/decisions/D-9242.json")" 'record retains successful check'
assert_eq 64 "$(jq '.door_confirmation_fingerprint|length' "$d/state/decisions/D-9242.json")" 'record has private fingerprint'
assert_lacks "$(cat "$d/door-result")" door_confirmation_fingerprint 'public final omits fingerprint'
door_body='{"id":"D-9242","chosen":"B","reviewed_intents":[1,2],"check_answer":0}'
assert_eq 200 "$(door_post /decisions "$door_body")" 'reordered identical retry succeeds'
assert_eq true "$(jq .already "$d/door-result")" 'retry returns already success'
rm -f "$d/state/pending/D-9242.json"
for reviewed in '[1,2]' '[2,1]'; do
  door_body="{\"id\":\"D-9242\",\"chosen\":\"B\",\"reviewed_intents\":$reviewed,\"check_answer\":0}"
  assert_eq 200 "$(door_post /decisions "$door_body")" 'identical and reordered retries need no pending record'
  assert_eq true "$(jq .already "$d/door-result")" 'no-pending retry is already success'
  assert_lacks "$(cat "$d/door-result")" door_confirmation_fingerprint 'no-pending retry strips fingerprint'
done
for fields in '' ',"reviewed_intents":[1],"check_answer":0' ',"reviewed_intents":[1,2],"check_answer":1' ',"reviewed_intents":[1,1],"check_answer":0' ',"reviewed_intents":[1,2],"check_answer":true'; do
  door_body="{\"id\":\"D-9242\",\"chosen\":\"B\"$fields}"
  assert_eq 409 "$(door_post /decisions "$door_body")" 'changed or absent replay confirmation refuses'
  assert_eq doorUnconfirmed "$(jq -r .code "$d/door-result")" 'replay has door refusal code'
done
door_body='{"id":"D-9242","reviewed_intents":[1,2],"check_answer":0}'
assert_eq 409 "$(door_post /decisions/check-door "$door_body")" 'check on recorded id refuses'
assert_eq decisionAlreadyRecorded "$(jq -r .code "$d/door-result")" 'recorded check refusal code'
assert_lacks "$(curl -sf "http://127.0.0.1:$PORT/api/state")" door_confirmation_fingerprint 'state omits private fingerprint'
assert_lacks "$(curl -sf "http://127.0.0.1:$PORT/api/task?id=T-B")" check_answer 'task detail omits private answer'
assert_lacks "$(curl -sf "http://127.0.0.1:$PORT/api/task?id=T-B")" door_confirmation_fingerprint 'task detail omits private fingerprint'
assert_ok "wait_for 10 test -f '$d/door-effects'" 'merge helper runs once'
assert_eq 1 "$(wc -l < "$d/door-effects" | tr -d ' ')" 'retries never repeat the merge effect'

kill "$pid" 2>/dev/null
wait "$pid" 2>/dev/null || true

rm -rf "$d"

# the event types the board maps and the types fm-emit will write are two
# halves of one list. T-010's rule - shared things have one source - applies
# to these as much as to the ship's geometry.
# strip the comments first, the way the sibling assertion above does: a
# type named only in a comment is not a type the board maps
mapped="$(sed -n '/^const STAGE/,/^};/p' "$ROOT/board/server.ts" \
  | sed 's|//.*||' | grep -oE '[a-z_]+:' | tr -d ':' | sort -u)"
known="$(sed -n '/^TYPES=/,/"$/p' "$ROOT/bin/fm-emit.sh" | tr ' \\"' '\n\n\n' | grep -E '^[a-z_]+$' | sort -u)"
unknown=''
for t in $mapped; do
  grep -qxF "$t" <<<"$known" || unknown="$unknown $t"
done
assert_eq "" "$unknown" "every stage the board maps is a type fm-emit will write"


safe_rm_rf "$XDG_CONFIG_HOME"
finish
