#!/usr/bin/env bash
# The board's contract is HTTP, so the suite speaks HTTP. No browser download
# in CI: a headless Chromium is a minute of install to assert what curl can.
set -uo pipefail
# A live managed worker exports FM_RUN_DIR / FM_ENTRY_* / FM_WORKER_TASK_LOCK_FD
# and Herdr pane ids into this shell. Suites must not inherit them or freeze,
# identity, locks and pushes bind to the outer run instead of the fixture.
for _fm_k in $(env | sed -E -n 's/^(FM_[^=]*|HERDR_[^=]*)=.*$/\1/p'); do
  unset "$_fm_k" || true
done
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=tests/lib.sh
. "$ROOT/tests/lib.sh"
# shellcheck source=bin/fm-config.sh
. "$ROOT/bin/fm-config.sh"   # fm_tasks_write: a fixture's tasks, one file each

command -v bun >/dev/null 2>&1 || { echo "    bun not installed - board suite skipped"; exit 0; }

# the board reads design/tasks/ through bin/fm-config.sh (T-090), so every
# fixture carries the library
d="$(mktemp -d)"; mkdir -p "$d/bin" "$d/state" "$d/design" "$d/board/public"
cp "$ROOT/bin/fm-emit.sh" "$ROOT/bin/fm-config.sh" "$d/bin/"
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

# The kernel picks the port and the server says which one it got. A RANDOM
# range overlapped the other suites' ranges, and with the gate running suites
# side by side a readiness loop could be answered by somebody else's board.
board_port() {   # board_port <log> <pid>: the port the server printed; 1 if it died first
  local log="$1" pid="$2" end=$(( $(date +%s) + 60 )) port
  while [ "$(date +%s)" -le "$end" ]; do
    port="$(sed -n 's|^board on http://127\.0\.0\.1:\([0-9][0-9]*\).*|\1|p' "$log" 2>/dev/null | head -1)"
    [ -n "$port" ] && { printf '%s' "$port"; return 0; }
    kill -0 "$pid" 2>/dev/null || return 1
    sleep 0.05
  done
  return 1
}

# detach every descriptor: ci.sh runs suites inside $(...), and a child that
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
assert_eq "true" "$(curl -s -X POST -H 'content-type: application/json' \
  -d "$body" "http://127.0.0.1:$PORT/decisions" | jq -r .ok)" "the board answers it"
assert_eq "B" "$(jq -r .chosen "$d/state/decisions/$nid.json")" "and the answer lands under its id"
assert_eq "B" "$(curl -sf "http://127.0.0.1:$PORT/api/state" | jq -r --arg i "$nid" '.responses[]|select(.id==$i)|.chosen')" \
  "and is read back among the responses"
rm -f "$d/state/pending/D-5.json"

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
# Do not pipe grep -q under pipefail: early close makes sed SIGPIPE and flakes red.
_bind_src="$(sed 's|//.*||' "$ROOT/board/server.ts")"
assert_matches "$_bind_src" 'hostname:[[:space:]]*"127\.0\.0\.1"' \
  "the bind option is 127.0.0.1"
# strip from // onward: a trailing comment is still a comment
assert_lacks "$_bind_src" '0.0.0.0' \
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

# --- T-036: truthful mid-run crew progress ---------------------------------
# Separate fixture: the crowd above floods the deck and would drown these.
p="$(mktemp -d)"; mkdir -p "$p/bin" "$p/state" "$p/design" "$p/board/public"
cp "$ROOT/bin/fm-emit.sh" "$ROOT/bin/fm-config.sh" "$p/bin/"
cp "$ROOT/board/server.ts" "$p/board/"
cp "$ROOT/board/public/index.html" "$p/board/public/"
fm_tasks_write /dev/stdin "$p/design/tasks" <<'J'
{"tasks":[
  {"id":"T-P","title":"Scalar English title is not activity","milestone":"M0","depends_on":[],
   "activity":{"en":"Authored task activity","zh-TW":"已撰寫的任務活動"}},
  {"id":"T-Q","title":"no authored activity here","milestone":"M0","depends_on":[]}
]}
J
FM_ROOT="$p" "$p/bin/fm-emit.sh" --actor captain --type greenlit --en "go" --tw "開工" >/dev/null
# Disable coalesce so successive crew_status fixtures are not dropped.
FM_ROOT="$p" FM_PORT=0 FM_CREW_STATUS_SECS=0 bun run "$p/board/server.ts" > "$p/out" 2>&1 < /dev/null &
pidp=$!
PORTP="$(board_port "$p/out" "$pidp")"
for _ in $(seq 1 40); do curl -sf "http://127.0.0.1:$PORTP/api/state" >/dev/null 2>&1 && break; sleep 0.25; done

# Activity: emitted/event activity wins over static task.activity; titles are
# never invented as translations.
FM_ROOT="$p" FM_CREW_STATUS_SECS=0 "$p/bin/fm-emit.sh" --actor worker-act --task T-P --type dispatched \
  --data '{"role":"worker","crew_name":"worker-act","activity":{"en":"Running the adapter","zh-TW":"正在跑 adapter"}}' \
  --en "picked up" --tw "接下" >/dev/null
sp="$(curl -sf "http://127.0.0.1:$PORTP/api/state")"
assert_eq "Running the adapter" \
  "$(jq -r '.crew[]|select(.id=="worker-act")|.activity.en' <<<"$sp")" \
  "crew activity en prefers emitted activity over static task.activity"
assert_eq "正在跑 adapter" \
  "$(jq -r '.crew[]|select(.id=="worker-act")|.activity["zh-TW"]' <<<"$sp")" \
  "crew activity zh-TW prefers emitted activity over static task.activity"
FM_ROOT="$p" FM_CREW_STATUS_SECS=0 "$p/bin/fm-emit.sh" --actor worker-act --task T-P --type crew_status \
  --data '{"role":"worker","activity":{"en":"Running focused checks","zh-TW":"正在跑聚焦檢查"}}' \
  --en "heartbeat" --tw "心跳" >/dev/null
sp="$(curl -sf "http://127.0.0.1:$PORTP/api/state")"
assert_eq "Running focused checks" \
  "$(jq -r '.crew[]|select(.id=="worker-act")|.activity.en' <<<"$sp")" \
  "crew_status refreshes activity when the task also has static task.activity"
assert_eq "worker-act" \
  "$(jq -r '.crew[]|select(.id=="worker-act")|.crew_name' <<<"$sp")" \
  "crew_name is carried on the crew payload"

# Static task.activity is the fallback when the event carries no activity.
FM_ROOT="$p" FM_CREW_STATUS_SECS=0 "$p/bin/fm-emit.sh" --actor worker-fallback --task T-P --type dispatched \
  --data '{"role":"worker","crew_name":"worker-fallback"}' >/dev/null
ss="$(curl -sf "http://127.0.0.1:$PORTP/api/state")"
assert_eq "Authored task activity" \
  "$(jq -r '.crew[]|select(.id=="worker-fallback")|.activity.en' <<<"$ss")" \
  "static task.activity fills in when the event carries no activity"

# When the task has no authored activity, event/mid-run activity still shows.
FM_ROOT="$p" FM_CREW_STATUS_SECS=0 "$p/bin/fm-emit.sh" --actor worker-q --task T-Q --type dispatched \
  --data '{"role":"worker","crew_name":"worker-q","activity":{"en":"Running the adapter","zh-TW":"正在跑 adapter"}}' \
  --en "picked up" --tw "接下" >/dev/null
sq="$(curl -sf "http://127.0.0.1:$PORTP/api/state")"
assert_eq "Running the adapter" \
  "$(jq -r '.crew[]|select(.id=="worker-q")|.activity.en' <<<"$sq")" \
  "event activity fills in when the task has no authored activity"
assert_eq "正在跑 adapter" \
  "$(jq -r '.crew[]|select(.id=="worker-q")|.activity["zh-TW"]' <<<"$sq")" \
  "event activity zh-TW fills in when the task has no authored activity"

# Missing progress is not a percentage; no bar input without a true denominator.
assert_eq "null" \
  "$(jq -c '.crew[]|select(.id=="worker-act")|.progress' <<<"$sp")" \
  "missing progress stays null on the crew payload"
# A bare number is refused: only {done,total} with a real denominator counts.
FM_ROOT="$p" "$p/bin/fm-emit.sh" --actor worker-act --task T-P --type crew_status \
  --data '{"role":"worker","progress":67}' \
  --en "fake percent" --tw "假百分比" >/dev/null
sp2="$(curl -sf "http://127.0.0.1:$PORTP/api/state")"
assert_eq "null" \
  "$(jq -c '.crew[]|select(.id=="worker-act")|.progress' <<<"$sp2")" \
  "a bare progress number is refused, not treated as a percentage"

# Bounded progress when a true denominator exists.
FM_ROOT="$p" "$p/bin/fm-emit.sh" --actor worker-act --task T-P --type crew_status \
  --data '{"role":"worker","progress":{"done":3,"total":7}}' \
  --en "gates 3/7" --tw "關卡 3/7" >/dev/null
sp3="$(curl -sf "http://127.0.0.1:$PORTP/api/state")"
assert_eq '{"done":3,"total":7}' \
  "$(jq -c '.crew[]|select(.id=="worker-act")|.progress' <<<"$sp3")" \
  "bounded done/total progress round-trips onto the crew payload"

# Phase retention across technical crew_status events (activity may refresh;
# lifecycle phase from review_opened must stick).
FM_ROOT="$p" "$p/bin/fm-emit.sh" --actor reviewer-ph --task T-Q --type review_opened \
  --data '{"role":"reviewer","crew_name":"reviewer-ph","activity":{"en":"Reading the diff","zh-TW":"閱讀 diff"}}' \
  --en "opened" --tw "開審" >/dev/null
# Flood past the recent-40 window with unrelated events, then a heartbeat.
i=0
while [ "$i" -lt 45 ]; do
  FM_ROOT="$p" "$p/bin/fm-emit.sh" --actor github --task T-P --type commit_pushed \
    --en "noise $i" --tw "雜訊 $i" >/dev/null
  i=$(( i + 1 ))
done
FM_ROOT="$p" "$p/bin/fm-emit.sh" --actor reviewer-ph --task T-Q --type crew_status \
  --data '{"role":"reviewer","activity":{"en":"Still reading","zh-TW":"仍在閱讀"}}' \
  --en "heartbeat" --tw "心跳" >/dev/null
sp4="$(curl -sf "http://127.0.0.1:$PORTP/api/state")"
assert_eq "review" \
  "$(jq -r '.crew[]|select(.id=="reviewer-ph")|.state' <<<"$sp4")" \
  "phase from review_opened is retained across technical crew_status events"
assert_eq "Still reading" \
  "$(jq -r '.crew[]|select(.id=="reviewer-ph")|.activity.en' <<<"$sp4")" \
  "authored activity is retained beyond the recent-event window"
# Scalar title must never become activity.
assert_ne "no authored activity here" \
  "$(jq -r '.crew[]|select(.id=="reviewer-ph")|.activity.en' <<<"$sp4")" \
  "missing activity is never invented from the scalar task title"

# Client: bubbles/roster get a bar only when bounded progress is present.
# ship.spec.ts is out of this task's scope; exercise crewOf the same way.
cp "$ROOT/board/public/ship.js" "$p/board/public/"
nobar="$(cd "$p" && bun -e '
const SHIP = require("./board/public/ship.js");
const T = (k) => k;
const L = (a) => a && a.en;
const s = { deckLimit: 24, greenlit: true, crew: [
  { id: "w", role: "worker", state: "working", task: "T-P", title: "x",
    activity: { en: "a", "zh-TW": "b" }, progress: null },
  { id: "g", role: "worker", state: "gate", task: "T-P", title: "x",
    activity: { en: "a", "zh-TW": "b" }, progress: { done: 2, total: 5 } },
]};
const crew = SHIP.crewOf(s, T, L);
const none = crew.find(c => c.id === "w");
const yes = crew.find(c => c.id === "g");
if (none.pct != null) { console.log("FAIL bare:"+none.pct); process.exit(1); }
if (yes.pct == null || yes.pct < 1) { console.log("FAIL bound:"+yes.pct); process.exit(1); }
// fixed stage→pct map must stay gone
const fake = SHIP.crewOf({ deckLimit: 24, greenlit: true, crew: [
  { id: "w", role: "worker", state: "working", task: "T-P" },
  { id: "r", role: "worker", state: "review", task: "T-P" },
  { id: "c", role: "worker", state: "captain", task: "T-P" },
]}, T, L);
if (fake.some(c => c.pct === 45 || c.pct === 70 || c.pct === 85 || c.pct === 95)) {
  console.log("FAIL invented pct"); process.exit(1);
}
console.log("ok");
')"
assert_eq "ok" "$nobar" "no bar without bounded progress; stage→pct map stays disabled"

# Roster markup likewise: only bounded progress gets a .pb.
# Assert per <li>: a cross-sibling regex matched gate's bar from working.
roster="$(cd "$p" && bun -e '
const SHIP = require("./board/public/ship.js");
const T = (k) => k;
const L = (a) => a && a.en;
const host = { innerHTML: "", ownerDocument: null };
const crew = SHIP.crewOf({ deckLimit: 24, greenlit: true, crew: [
  { id: "w", role: "worker", state: "working", task: "T-P",
    activity: { en: "a", "zh-TW": "b" }, progress: null },
  { id: "g", role: "worker", state: "gate", task: "T-P",
    activity: { en: "a", "zh-TW": "b" }, progress: { done: 1, total: 2 } },
]}, T, L);
SHIP.roster(host, crew, T);
const working = host.innerHTML.match(/<li class="rrow st-working"[\s\S]*?<\/li>/);
const gate = host.innerHTML.match(/<li class="rrow st-gate"[\s\S]*?<\/li>/);
if (!working || !gate) { console.log("FAIL roster missing li"); process.exit(1); }
if (/class="pb"/.test(working[0]) || !/class="pb"/.test(gate[0])) {
  console.log("FAIL roster"); process.exit(1);
}
console.log("ok");
')"
assert_eq "ok" "$roster" "roster shows a progress bar only with bounded progress"

kill "$pidp" 2>/dev/null
wait "$pidp" 2>/dev/null || true
rm -rf "$p"

# --- T-040: layout parity data ---------------------------------------------
# Its own fixture again: the engine badge reads config.yaml, which the other
# two fixtures do not have, and the merge refusal needs a helper that says no.
e="$(mktemp -d)"; mkdir -p "$e/bin" "$e/state/pending" "$e/design" "$e/board/public"
cp "$ROOT/bin/fm-emit.sh" "$ROOT/bin/fm-config.sh" "$e/bin/"
cp "$ROOT/board/server.ts" "$e/board/"
cp "$ROOT/board/public/index.html" "$e/board/public/"
printf '#!/usr/bin/env bash\necho refused\nexit 1\n' > "$e/bin/fm-merge.sh"
chmod +x "$e/bin/fm-merge.sh"
# names nobody would hard-code, so a badge that did cannot pass
cat > "$e/config.yaml" <<'Y'
vendor: vendor-alpha      # the top-level engine
model:  m1
reviewer:                 # a different engine for review
  vendor: vendor-beta     # not the same one
  model:  m2
# worker:
#   vendor: vendor-gamma
concurrency: 3
Y
fm_tasks_write /dev/stdin "$e/design/tasks" <<'J'
{"tasks":[{"id":"T-E1","title":"first","milestone":"M2","depends_on":[]},
          {"id":"T-E2","title":"second","milestone":"M2","depends_on":["T-E1"]},
          {"id":"T-E3","title":"third","milestone":"M2","depends_on":["T-E9"]},
          {"id":"T-E4","title":"fourth","milestone":"M2","depends_on":[]},
          {"id":"T-E5","title":"fifth","milestone":"M2","depends_on":[]},
          {"id":"T-E6","title":"sixth","milestone":"M2","depends_on":["T-E1","T-E5"]}]}
J
FM_ROOT="$e" "$e/bin/fm-emit.sh" --actor captain --type greenlit --en "go" --tw "開工" >/dev/null
FM_ROOT="$e" FM_PORT=0 bun run "$e/board/server.ts" > "$e/out" 2>&1 < /dev/null &
pide=$!
PORTE="$(board_port "$e/out" "$pide")"
for _ in $(seq 1 40); do curl -sf "http://127.0.0.1:$PORTE/api/state" >/dev/null 2>&1 && break; sleep 0.25; done
st() { curl -sf "http://127.0.0.1:$PORTE/api/state"; }

# V7: the engine as config.yaml says it, marked when the reviewer differs
se="$(st)"
assert_eq "vendor-alpha" "$(jq -r '.engine.vendor' <<<"$se")" "the badge names the top-level vendor from config.yaml"
assert_eq "vendor-beta" "$(jq -r '.engine.reviewer' <<<"$se")" "and the reviewer's vendor"
assert_eq "true" "$(jq -r '.engine.cross' <<<"$se")" "marked as cross-vendor when they differ"
# read at request time: an edit shows on the next request, no restart
cat > "$e/config.yaml" <<'Y'
vendor: vendor-delta
reviewer:
  vendor: vendor-delta
Y
se2="$(st)"
assert_eq "vendor-delta" "$(jq -r '.engine.vendor' <<<"$se2")" "config.yaml is read per request, not at start"
assert_eq "false" "$(jq -r '.engine.cross' <<<"$se2")" "a reviewer on the same vendor is not marked"
printf 'vendor: vendor-delta\n' > "$e/config.yaml"
se3="$(st)"
assert_eq "null" "$(jq -r '.engine.reviewer' <<<"$se3")" "no reviewer block, no reviewer vendor"
assert_eq "false" "$(jq -r '.engine.cross' <<<"$se3")" "and nothing is marked"

# seven lanes, left to right, in lifecycle order; closed is not a lane
assert_eq "backlog ready working gate review captain merged" "$(jq -r '.lanes|join(" ")' <<<"$se")" \
  "the lanes are backlog, ready, work, gate, review, captain, merged in that order"
assert_eq "null" "$(jq -r '.counts.queued' <<<"$se")" "there is no single queued count any more"

# ready: every dependency has merged, so the task could be dispatched now;
# backlog: at least one has not. The replay that fills blocked_on decides it.
assert_eq "backlog" "$(jq -r '.tasks[]|select(.id=="T-E2")|.stage' <<<"$se")" \
  "a task with an unmerged dependency is backlog"
assert_eq "backlog" "$(jq -r '.tasks[]|select(.id=="T-E3")|.stage' <<<"$se")" \
  "a task whose dependency the log has never heard of is backlog"
assert_eq "ready" "$(jq -r '.tasks[]|select(.id=="T-E1")|.stage' <<<"$se")" \
  "a task with no dependencies is ready"
assert_eq "3 ready, 3 backlog" "$(jq -r '"\(.counts.ready) ready, \(.counts.backlog) backlog"' <<<"$se")" \
  "the header counts ready and backlog separately"

# a backlog task names the dependencies that have not merged, and only those
assert_eq "T-E1" "$(jq -r '.tasks[]|select(.id=="T-E2")|.blocked_on|join(",")' <<<"$se")" \
  "a backlog task is blocked on its unmerged dependency"
assert_eq "T-E9" "$(jq -r '.tasks[]|select(.id=="T-E3")|.blocked_on|join(",")' <<<"$se")" \
  "a dependency the log has never heard of is not merged either"
assert_eq "" "$(jq -r '.tasks[]|select(.id=="T-E4")|.blocked_on|join(",")' <<<"$se")" \
  "a task with no dependencies is blocked on nothing"
FM_ROOT="$e" "$e/bin/fm-emit.sh" --actor github --task T-E1 --type merged --pr 41 \
  --en "merged" --tw "已合併" >/dev/null
sm1="$(st)"
assert_eq "" "$(jq -r '.tasks[]|select(.id=="T-E2")|.blocked_on|join(",")' <<<"$sm1")" \
  "and is unblocked once that dependency merges"
assert_eq "ready" "$(jq -r '.tasks[]|select(.id=="T-E2")|.stage' <<<"$sm1")" \
  "its last dependency merging moves the card from backlog to ready"
assert_eq "3 ready, 2 backlog" "$(jq -r '"\(.counts.ready) ready, \(.counts.backlog) backlog"' <<<"$sm1")" \
  "and the counts follow it"
assert_eq "backlog T-E5" "$(jq -r '.tasks[]|select(.id=="T-E6")|"\(.stage) \(.blocked_on|join(","))"' <<<"$sm1")" \
  "one of two dependencies merging leaves the card in backlog, waiting on the other"
assert_eq "merged" "$(jq -r '.tasks[]|select(.id=="T-E1")|.stage' <<<"$sm1")" "merged is a stage the merged lane shows"

# card badges come from events: the failing gate when the event names it,
# an open ASK-PASS-CRITERIA, and nothing invented otherwise
FM_ROOT="$e" "$e/bin/fm-emit.sh" --actor worker-e --task T-E4 --type dispatched \
  --data '{"role":"worker","crew_name":"Wren"}' --en "on it" --tw "接下" >/dev/null
sb0="$(st)"
assert_eq "Wren" "$(jq -r '.tasks[]|select(.id=="T-E4")|.crew|join(",")' <<<"$sb0")" \
  "a card names the crew aboard on it"
assert_eq "0" "$(jq -r '.tasks[]|select(.id=="T-E4")|.badges|length' <<<"$sb0")" \
  "a task at work with nothing to report carries no badge"
FM_ROOT="$e" "$e/bin/fm-emit.sh" --actor worker-e --task T-E4 --type gate_failed \
  --data '{"gate":5}' --en "gate 5" --tw "第 5 道" >/dev/null
FM_ROOT="$e" "$e/bin/fm-emit.sh" --actor worker-e --task T-E4 --type ask_pass_criteria \
  --en "asked" --tw "已詢問" >/dev/null
sb1="$(st)"
assert_eq "5" "$(jq -r '.tasks[]|select(.id=="T-E4")|.badges[]|select(.kind=="gate")|.gate' <<<"$sb1")" \
  "the failing gate's number comes from the event"
assert_eq "1" "$(jq -r '[.tasks[]|select(.id=="T-E4")|.badges[]|select(.kind=="ask")]|length' <<<"$sb1")" \
  "an open ASK-PASS-CRITERIA is a badge"
FM_ROOT="$e" "$e/bin/fm-emit.sh" --actor worker-e --task T-E4 --type criteria_returned \
  --en "listed" --tw "已列出" >/dev/null
FM_ROOT="$e" "$e/bin/fm-emit.sh" --actor worker-e --task T-E4 --type gate_failed \
  --en "no number" --tw "沒有編號" >/dev/null
sb2="$(st)"
assert_eq "0" "$(jq -r '[.tasks[]|select(.id=="T-E4")|.badges[]|select(.kind=="ask")]|length' <<<"$sb2")" \
  "and it is gone once the criteria are returned"
assert_eq "null" "$(jq -r '.tasks[]|select(.id=="T-E4")|.badges[]|select(.kind=="gate")|.gate' <<<"$sb2")" \
  "a failure that names no gate gets no invented number"

# waiting on you is the number of pending decisions, whatever their stage
assert_eq "0" "$(jq -r '.counts.waiting' <<<"$sb2")" "nothing pending, nobody waiting on the captain"
printf '{"id":"D-401","task":"T-E5","kind":"merge","pr":45,"title":"merge it","details":{"en":{"options":{"A":{},"B":{},"C":{}}}}}\n' \
  > "$e/state/pending/D-401.json"
printf '{"id":"D-402","task":"T-E4","kind":"choice","title":"which"}\n' > "$e/state/pending/D-402.json"
sw="$(st)"
assert_eq "2" "$(jq -r '.counts.waiting' <<<"$sw")" "waiting on you counts each pending decision"
assert_eq "3" "$(jq -r '.tasks[]|select(.id=="T-E5")|.badges[]|select(.kind=="decision")|.options' <<<"$sw")" \
  "a pending decision's badge carries the options it actually offers"
assert_eq "null" "$(jq -r '.tasks[]|select(.id=="T-E4")|.badges[]|select(.kind=="decision")|.options' <<<"$sw")" \
  "and a record that lists none gets no invented count"
rm -f "$e/state/pending/D-402.json"

# a refused merge is flagged as overtaken once that task is merged afterwards
curl -sf -X POST -H 'content-type: application/json' -d '{"id":"D-401","chosen":"A"}' \
  "http://127.0.0.1:$PORTE/decisions" > "$e/post" || true
assert_eq "false" "$(jq -r '.merged.ok' "$e/post")" "the helper refused the merge"
sr1="$(st)"
assert_eq "false" "$(jq -r '.responses[]|select(.id=="D-401")|.superseded' <<<"$sr1")" \
  "a refusal with nothing merged since is still news"
assert_eq "45" "$(jq -r '.responses[]|select(.id=="D-401")|.pr' <<<"$sr1")" \
  "the decision record keeps the pull request it was about"
assert_eq "0" "$(jq -r '.counts.waiting' <<<"$sr1")" "an answered decision no longer waits"
# a merge of some other task does not overtake it
FM_ROOT="$e" "$e/bin/fm-emit.sh" --actor github --task T-E2 --type merged --pr 42 \
  --en "merged" --tw "已合併" >/dev/null
assert_eq "false" "$(jq -r '.responses[]|select(.id=="D-401")|.superseded' <<<"$(st)")" \
  "a merge of another task does not clear the refusal"
FM_ROOT="$e" "$e/bin/fm-emit.sh" --actor github --task T-E5 --type merged --pr 45 \
  --en "merged by hand" --tw "手動合併" >/dev/null
assert_eq "true" "$(jq -r '.responses[]|select(.id=="D-401")|.superseded' <<<"$(st)")" \
  "a later merge of the same task clears the refusal"
assert_eq "ready " "$(jq -r '.tasks[]|select(.id=="T-E6")|"\(.stage) \(.blocked_on|join(","))"' <<<"$(st)")" \
  "its last dependency merging moves the two-dependency card to ready, blocked on nothing"

# a later successful merge *response* overtakes a refusal on its own, with no
# merged event in the log; an earlier success does not
jq '.id="D-403"|.task="T-E6"|.pr=46|.ts="2026-01-01T00:00:10Z"' "$e/state/decisions/D-401.json" \
  > "$e/state/decisions/D-403.json"
jq '.id="D-404"|.task="T-E6"|.pr=46|.ts="2026-01-01T00:00:00Z"|.merged={ok:true}' "$e/state/decisions/D-401.json" \
  > "$e/state/decisions/D-404.json"
assert_eq "false" "$(jq -r '.responses[]|select(.id=="D-403")|.superseded' <<<"$(st)")" \
  "a success recorded before the refusal does not clear it"
jq '.ts="2026-01-01T00:01:00Z"' "$e/state/decisions/D-404.json" > "$e/d404" && mv "$e/d404" "$e/state/decisions/D-404.json"
assert_eq "true" "$(jq -r '.responses[]|select(.id=="D-403")|.superseded' <<<"$(st)")" \
  "a later successful merge response for the same task clears the refusal"

kill "$pide" 2>/dev/null
wait "$pide" 2>/dev/null || true
rm -rf "$e"

# --- T-058: the captain parks or drops a task --------------------------------
# Its own fixture: every action here writes to the log, and the counts below
# are lines in that log, so nothing else may be writing to it.
f="$(mktemp -d)"; mkdir -p "$f/bin" "$f/state" "$f/design" "$f/board/public"
cp "$ROOT/bin/fm-emit.sh" "$ROOT/bin/fm-config.sh" "$f/bin/"
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
act() { curl -s -o "$f/resp" -w '%{http_code}' -X POST -H 'content-type: application/json' \
  -d "{\"task\":\"$1\",\"action\":\"$2\"}" "http://127.0.0.1:$PORTF/tasks"; }
field() { jq -r --arg t "$1" ".tasks[]|select(.id==\$t)|$2" <<<"$(sf)"; }
last_event() { tail -1 "$f/state/events.jsonl"; }

# the server says which actions a card offers, so the page never guesses
assert_eq "park,drop" "$(field T-P1 '.actions|join(",")')" "a ready card offers park and drop"
assert_eq "park,drop" "$(field T-P2 '.actions|join(",")')" "a backlog card offers park and drop"
assert_eq "" "$(field T-P3 '.actions|join(",")')" "a card in flight offers neither"
assert_eq "" "$(field T-P6 '.actions|join(",")')" "nor does a merged one"

# park: a parked event from the captain, and the card leaves the lanes
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

# in flight or later: refused, nothing emitted, for all three actions
n3="$(lines)"
for a in park unpark drop; do
  assert_eq "409" "$(act T-P3 "$a")" "$a is refused for a task in flight"
  assert_eq "409" "$(act T-P6 "$a")" "$a is refused for a merged task"
done
assert_eq "$n3" "$(lines)" "a refused action writes nothing"
assert_eq "working" "$(field T-P3 .stage)" "and the task in flight is untouched"

# drop: the existing closed event, from the captain; the task leaves the lanes
assert_eq "200" "$(act T-P4 drop)" "drop answers 200 for a ready task"
assert_eq "closed captain T-P4" "$(jq -r '"\(.type) \(.actor) \(.task)"' <<<"$(last_event)")" \
  "a drop is the closed event, from the captain"
assert_eq "closed" "$(field T-P4 .stage)" "a dropped task is closed, in no lane"
assert_eq "" "$(field T-P4 '.actions|join(",")')" "and offers nothing more"
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
assert_eq "415" "$(curl -s -o /dev/null -w '%{http_code}' -X POST -H 'content-type: text/plain' \
  -d '{"task":"T-P1","action":"park"}' "http://127.0.0.1:$PORTF/tasks")" \
  "a body that is not declared JSON is refused, so a cross-site form cannot post it"
assert_eq "$n5" "$(lines)" "and none of them writes anything"

# the board never edits the plan
assert_eq "$plan_before" "$(plan)" "design/tasks/ is untouched"

kill "$pidf" 2>/dev/null
wait "$pidf" 2>/dev/null || true
rm -rf "$f"

# --- T-069: every pull request number links to its project's pull request ----
# The URL comes from the project registry through bin/fm-config.sh, the one
# resolver every script uses, so the fixture carries it and its parser. The
# server is started with FM_PROJECT naming the other project: until T-054 the
# board is the default project's, whatever the shell that started it exported.
g="$(mktemp -d)"; mkdir -p "$g/bin" "$g/state/pending" "$g/state/decisions" "$g/design" "$g/board/public"
cp "$ROOT/bin/fm-emit.sh" "$ROOT/bin/fm-config.sh" "$ROOT/bin/fm-herdr.py" "$g/bin/"
cp "$ROOT/board/server.ts" "$g/board/"
cp "$ROOT/board/public/index.html" "$g/board/public/"
fm_tasks_write /dev/stdin "$g/design/tasks" <<'J'
{"tasks":[{"id":"T-G1","title":"in review","milestone":"M2","depends_on":[]},
          {"id":"T-G2","title":"merged","milestone":"M2","depends_on":[]},
          {"id":"T-G3","title":"no pull request","milestone":"M2","depends_on":[]},
          {"id":"T-G4","title":"a string pr, follows #46","milestone":"M2","depends_on":[]}]}
J
FM_ROOT="$g" "$g/bin/fm-emit.sh" --actor captain --type greenlit --en "go" --tw "開工" >/dev/null
FM_ROOT="$g" "$g/bin/fm-emit.sh" --actor worker-g --task T-G1 --type dispatched --en "on it" --tw "接下" >/dev/null
FM_ROOT="$g" "$g/bin/fm-emit.sh" --actor worker-g --task T-G1 --type pr_opened --pr 41 \
  --en "opened #41" --tw "開了 #41" >/dev/null
FM_ROOT="$g" "$g/bin/fm-emit.sh" --actor github --task T-G2 --type merged --pr 42 --en "merged #42" --tw "已合併 #42" >/dev/null
# numbers named in text that are no record's own pr: a summary on a line with
# no pr, a decision's title, a task title (T-G4's), and one that is not a
# pull request number at all
FM_ROOT="$g" "$g/bin/fm-emit.sh" --actor github --task T-G1 --type commit_pushed \
  --en "pushed to #41, replacing #44 (not #044, not T#9)" --tw "推到 #41，取代 #44" >/dev/null
# another tool writes pr as a string: the same number to the board, and a
# pr that is not a number is not linked at all
printf '%s\n' '{"ts":"2026-09-21T10:00:00Z","actor":"other","task":"T-G4","type":"pr_seen","pr":"43","summary":{"en":"saw #43"}}' \
  '{"ts":"2026-09-21T10:00:01Z","actor":"stranger","task":"T-G3","type":"pr_seen","pr":"043","summary":{"en":"odd"}}' \
  >> "$g/state/events.jsonl"
printf '{"id":"D-41","task":"T-G1","kind":"merge","pr":41,"title":"ready, after #45"}\n' > "$g/state/pending/D-41.json"
printf '{"id":"D-40","task":"T-G2","kind":"merge","pr":42,"chosen":"A","merged":{"ok":true}}\n' > "$g/state/decisions/D-40.json"
FM_ROOT="$g" FM_PORT=0 FM_PROJECT=alpha bun run "$g/board/server.ts" > "$g/out" 2>&1 < /dev/null &
pidg=$!
PORTG="$(board_port "$g/out" "$pidg")"
endg=$(( $(date +%s) + 60 ))
until curl -sf "http://127.0.0.1:$PORTG/api/state" >/dev/null 2>&1; do
  [ "$(date +%s)" -le "$endg" ] && kill -0 "$pidg" 2>/dev/null || break
  sleep 0.05
done
sg() { curl -sf "http://127.0.0.1:$PORTG/api/state"; }
# every place /api/state returns a pr number, as "pr=url" per line; a url
# the server leaves out reads as null
urls() {
  jq -r '[(.tasks[]|select(.pr!=null)), .pending[], .responses[],
          (.recent[]|select(.pr!=null and .actor!="stranger")),
          (.outcomes[]|select(.pr!=null))] | map("\(.pr)=\(.pr_url)") | .[]' <<<"$(sg)"
}
# every #n written in text anywhere in /api/state, and the URL beside it
mentions() { jq -r '.pr_urls | to_entries | map("\(.key)=\(.value)") | .[]' <<<"$(sg)"; }
registry() {   # registry <default> <alpha github line> <beta github line>
  cat > "$g/config.yaml" <<Y
vendor: claude
default_project: $1
projects:
  alpha:
    repo: .
$2
    base: main
    required_check: ci
  beta:
$3
    base: main
    required_check: check
Y
}

# no registry at all: no URL anywhere, and never a guessed one
assert_eq "9" "$(urls | wc -l | tr -d ' ')" "the fixture puts a pr number in tasks, decisions, responses, the log and outcomes"
assert_eq "" "$(urls | grep -v '=null$')" "without a registry no pr number carries a URL"
assert_eq "{}" "$(jq -c '.pr_urls' <<<"$(sg)")" "without a registry no #n in any text carries a URL"
assert_eq "null" "$(jq -r '.tasks[]|select(.id=="T-G3")|.pr_url' <<<"$(sg)")" "a task with no pull request has no URL"

# the default project's github, next to every pr number
registry beta "    github: example-org/alpha-app" "    github: example-org/beta-app"
assert_eq "" "$(urls | grep -vE '^(41|42|43)=https://github\.com/example-org/beta-app/pull/(41|42|43)$')" \
  "every pr number carries the default project's pull request URL"
assert_eq "" "$(urls | awk -F= '$2 !~ ("/pull/" $1 "$")')" "and each URL is its own number's"
# one reading of a pr number: the string "43" another tool wrote is 43 on
# the card and on the log line, and "043" is no pull request anywhere
assert_eq "number=https://github.com/example-org/beta-app/pull/43" \
  "$(jq -r '.tasks[]|select(.id=="T-G4")|"\(.pr|type)=\(.pr_url)"' <<<"$(sg)")" "a string pr is the same number on its card"
assert_eq "string=https://github.com/example-org/beta-app/pull/43" \
  "$(jq -r '.recent[]|select(.actor=="other")|"\(.pr|type)=\(.pr_url)"' <<<"$(sg)")" "and carries its URL on its log line"
assert_eq "null=null" "$(jq -r '(.tasks[]|select(.id=="T-G3")|.pr), (.recent[]|select(.actor=="stranger")|.pr_url)' <<<"$(sg)" | paste -sd= -)" \
  "a pr that is not a pull request number is neither a card's number nor a link"
# every #n in any text, whoever's it is: a line with no pr, a title, a
# decision, and never #044 or T#9
assert_eq "41 42 43 44 45 46" "$(mentions | cut -d= -f1 | sort -n | paste -sd' ' -)" \
  "every #n written anywhere in the state is mapped, and nothing else"
assert_eq "" "$(mentions | awk -F= '$2 != ("https://github.com/example-org/beta-app/pull/" $1)')" \
  "each to its own pull request on the registered repository"
assert_eq "https://github.com/example-org/beta-app/pull/41" \
  "$(jq -r '.tasks[]|select(.id=="T-G1")|.pr_url' <<<"$(sg)")" "a lane card's #41 links to pull 41 on the registered repository"
assert_eq "https://github.com/example-org/beta-app/pull/41" \
  "$(jq -r '.pending[]|select(.id=="D-41")|.pr_url' <<<"$(sg)")" "and so does its decision card"
assert_eq "https://github.com/example-org/beta-app/pull/42" \
  "$(jq -r '.recent[]|select(.type=="merged")|.pr_url' <<<"$(sg)")" "and a log line's #42"
assert_eq "9" "$(urls | grep -c '=https://github\.com/example-org/beta-app/pull/')" \
  "not one of them is left without it"

# the registry changes, the URL follows on the next request
registry beta "    github: example-org/alpha-app" "    github: other-org/renamed-app"
assert_eq "https://github.com/other-org/renamed-app/pull/41" \
  "$(jq -r '.tasks[]|select(.id=="T-G1")|.pr_url' <<<"$(sg)")" "the URL follows the registry's github when it changes"
assert_eq "" "$(urls | grep -v '=https://github\.com/other-org/renamed-app/pull/')" "everywhere at once"
assert_eq "" "$(mentions | grep -v '=https://github\.com/other-org/renamed-app/pull/')" "in text as well"
# the default project decides, not the first entry or the shell's FM_PROJECT
registry alpha "    github: example-org/alpha-app" "    github: other-org/renamed-app"
assert_eq "https://github.com/example-org/alpha-app/pull/41" \
  "$(jq -r '.tasks[]|select(.id=="T-G1")|.pr_url' <<<"$(sg)")" "the default project is the one whose repository is linked"

# the default project has no github: the registry refuses it, and the page
# gets no URL rather than some other project's
registry alpha "" "    github: other-org/renamed-app"
assert_eq "" "$(urls | grep -v '=null$')" "a default project with no github entry yields no URL"
assert_eq "{}" "$(jq -c '.pr_urls' <<<"$(sg)")" "and no #n in text is linked either"
# a config with no projects map registers nothing, so nothing is linked
printf 'vendor: claude\n' > "$g/config.yaml"
assert_eq "" "$(urls | grep -v '=null$')" "a config.yaml without a registry yields no URL"

kill "$pidg" 2>/dev/null
wait "$pidg" 2>/dev/null || true
rm -rf "$g"

# the repository is data in the registry, never a literal in the board: no
# registered owner or repository name appears anywhere under board/
gh_repos="$(sed -n 's/^[[:space:]]*github:[[:space:]]*\([^[:space:]#]*\).*/\1/p' "$ROOT/config.yaml")"
assert_ne "" "$gh_repos" "config.yaml registers at least one github repository to look for"
for repo in $gh_repos; do
  for part in "${repo%%/*}" "${repo#*/}"; do
    assert_eq "" "$(grep -rnF -- "$part" "$ROOT/board" || true)" "board/ holds no literal '${part}' from the registry"
  done
done

finish
