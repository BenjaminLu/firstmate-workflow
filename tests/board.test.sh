#!/usr/bin/env bash
# The board's contract is HTTP, so the suite speaks HTTP. No browser download
# in CI: a headless Chromium is a minute of install to assert what curl can.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=tests/lib.sh
. "$ROOT/tests/lib.sh"

command -v bun >/dev/null 2>&1 || { echo "    bun not installed - board suite skipped"; exit 0; }

d="$(mktemp -d)"; mkdir -p "$d/bin" "$d/state" "$d/design" "$d/board/public"
cp "$ROOT/bin/fm-emit.sh" "$d/bin/"
cp "$ROOT/board/server.ts" "$d/board/"
cp "$ROOT/board/public/index.html" "$d/board/public/"
cat > "$d/design/tasks.json" <<'J'
{"tasks":[{"id":"T-A","title":"first","milestone":"M0","depends_on":[]},
          {"id":"T-B","title":"second","milestone":"M0","depends_on":["T-A"]},
          {"id":"T-C","title":"third","milestone":"M0","depends_on":[]},
          {"id":"T-D","title":"fourth","milestone":"M0","depends_on":[]}]}
J
FM_ROOT="$d" "$d/bin/fm-emit.sh" --actor captain --type greenlit --en "go" --tw "開工" >/dev/null
FM_ROOT="$d" "$d/bin/fm-emit.sh" --actor worker-1 --task T-A --type dispatched --en "picked up T-A" --tw "領走 T-A" >/dev/null

PORT=$(( 14000 + RANDOM % 900 ))
# detach every descriptor: ci.sh runs suites inside $(...), and a child that
# keeps stdout open holds the command substitution open with it
FM_ROOT="$d" FM_PORT="$PORT" bun run "$d/board/server.ts" > "$d/out" 2>&1 < /dev/null &
pid=$!
for _ in $(seq 1 40); do curl -sf "http://127.0.0.1:$PORT/api/state" >/dev/null 2>&1 && break; sleep 0.25; done
trap 'kill "$pid" 2>/dev/null' EXIT

s="$(curl -sf "http://127.0.0.1:$PORT/api/state")"
assert_ok "[ -n '$s' ]" "the state endpoint answers"
assert_eq "true" "$(jq -r .greenlit <<<"$s")" "it reports the green light"
assert_eq "working" "$(jq -r '.tasks[]|select(.id=="T-A")|.stage' <<<"$s")" "a dispatched task reads as working"
assert_eq "queued"  "$(jq -r '.tasks[]|select(.id=="T-B")|.stage' <<<"$s")" "an untouched task reads as queued"
assert_eq "1" "$(jq -r .counts.inflight <<<"$s")" "the counts follow the log"


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
# a task the captain has been asked about is the captain's, whatever was
# said about it before. It was reading as "working" because a dispatch
# that should never have happened was the last thing in the log.
FM_ROOT="$d" "$d/bin/fm-emit.sh" --actor worker-1 --task T-C --type dispatched \
  --en "picked up" --tw "接下" >/dev/null
FM_ROOT="$d" "$d/bin/fm-emit.sh" --actor firstmate --task T-C --type decision_requested \
  --pr 12 --en "asked the captain" --tw "請示船長" >/dev/null
sc="$(curl -sf "http://127.0.0.1:$PORT/api/state")"
assert_ne "" "$sc" "the board is answering"
assert_eq "captain" "$(jq -r '.tasks[]|select(.id=="T-C")|.stage' <<<"$sc")" \
  "a task the captain has been asked about waits on the captain"
# and it keeps waiting: while the card is up, nothing said afterwards
# moves the task out of the captain's lane
mkdir -p "$d/state/pending"
printf '{"id":"D-12","task":"T-C","kind":"merge","pr":12,"title":"ready"}\n' > "$d/state/pending/D-12.json"
FM_ROOT="$d" "$d/bin/fm-emit.sh" --actor worker-1 --task T-C --type dispatched \
  --en "a stray dispatch" --tw "多餘的派工" >/dev/null
sc2="$(curl -sf "http://127.0.0.1:$PORT/api/state")"
assert_eq "captain" "$(jq -r '.tasks[]|select(.id=="T-C")|.stage' <<<"$sc2")" \
  "and stays there while the card is up, whatever is said after"
rm -f "$d/state/pending/D-12.json"

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
  assert_contains "$css_rules" ".fig.s-$st" "the page can draw state $st"
done
# and the animation each of them names actually exists: a --baseAnim
# pointing at a keyframe nobody defined resolves to nothing, silently,
# and a check that greps only for the selector cannot tell
for anim in $(printf '%s' "$css_rules" | grep -oE '\-\-baseAnim:[a-zA-Z0-9_-]+' | cut -d: -f2 | sort -u); do
  assert_contains "$css_rules" "@keyframes $anim" "the keyframe $anim is defined"
done
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
# dispatched minus merged-or-closed, fm-run on pr_opened and merged,
# fm-sync-prs on type and pr - none of them has a default branch that
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
assert_lacks "$(jq -r '.pending[].id' <<<"$sterm" | tr '\n' ' ')" "D-88" \
  "pending for a terminal task is not offered"
assert_eq "merged" "$(jq -r '.tasks[]|select(.id=="T-999")|.stage' <<<"$sterm")" \
  "completed identity from events reaches state without a current definition"
assert_eq "999" "$(jq -r '.tasks[]|select(.id=="T-999")|.pr' <<<"$sterm")" \
  "and keeps the event PR on that completed identity"
rm -f "$d/state/pending/D-88.json"

# Pending list order must not follow readdirSync: write higher ids first so a
# filesystem that returns creation/lexicographic order still yields numeric id
# order. T-A is still open here (T-B merged, T-C closed); settled tasks filter.
mkdir -p "$d/state/pending"
printf '{"id":"D-100","task":"T-A","kind":"choice","title":"hundred"}\n' > "$d/state/pending/D-100.json"
printf '{"id":"D-20","task":"T-A","kind":"choice","title":"twenty"}\n' > "$d/state/pending/D-20.json"
printf '{"id":"D-3","task":"T-A","kind":"choice","title":"three"}\n' > "$d/state/pending/D-3.json"
sord="$(curl -sf "http://127.0.0.1:$PORT/api/state")"
assert_eq "D-3 D-20 D-100" "$(jq -r '[.pending[].id]|join(" ")' <<<"$sord")" \
  "pending cards are ordered by decision id, not filesystem readdir order"
rm -f "$d/state/pending/D-100.json" "$d/state/pending/D-20.json" "$d/state/pending/D-3.json"

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
( sleep 1; FM_ROOT="$d" "$d/bin/fm-emit.sh" --actor worker-1 --task T-A --type merged \
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
assert_ok "sed 's|//.*||' '$ROOT/board/server.ts' | grep -qE 'hostname:[[:space:]]*\"127\\.0\\.0\\.1\"'" \
  "the bind option is 127.0.0.1"
# strip from // onward: a trailing comment is still a comment
assert_fail "sed 's|//.*||' '$ROOT/board/server.ts' | grep -qF '0.0.0.0'" \
  "no code binds 0.0.0.0"

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
  printf '%s\n' "$known" | grep -qxF "$t" || unknown="$unknown $t"
done
assert_eq "" "$unknown" "every stage the board maps is a type fm-emit will write"


finish
