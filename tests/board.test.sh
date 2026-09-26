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

# Merges run in the background (T-054), so their outcome is something to wait
# for, with a bound: a helper that never finishes fails the assertion after it
# rather than hanging the suite.
wait_for() {   # wait_for <seconds> <command...>: 0 once the command succeeds, 1 at the deadline
  local end=$(( $(date +%s) + $1 )); shift
  until "$@" >/dev/null 2>&1; do
    [ "$(date +%s)" -le "$end" ] || return 1
    sleep 0.1
  done
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
assert_eq "true" "$(curl -s -X POST -H 'content-type: application/json' \
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
  grep -qxF "$t" <<<"$known" || unknown="$unknown $t"
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
cp "$ROOT/bin/fm-emit.sh" "$ROOT/bin/fm-config.sh" "$ROOT/bin/fm-ready.sh" "$e/bin/"
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
assert_eq "Wren" "$(jq -r '.tasks[]|select(.id=="T-E4")|.crew|map(.name)|join(",")' <<<"$sb0")" \
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

# a refused merge is flagged as overtaken once that task is merged afterwards.
# The merge runs after the answer (T-054): the record says how it ended once
# the helper has exited.
curl -sf -X POST -H 'content-type: application/json' -d '{"id":"D-401","chosen":"A"}' \
  "http://127.0.0.1:$PORTE/decisions" > "$e/post" || true
assert_eq "true" "$(jq -r '.ok' "$e/post")" "the merge answer is recorded"
wait_for 20 jq -e '.merge=="failed"' "$e/state/decisions/D-401.json"
assert_eq "failed refused" "$(jq -r '"\(.merge) \(.merge_reason)"' "$e/state/decisions/D-401.json")" \
  "the helper refused the merge, and the record says so with its reason"
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
# D-404 is a record written before merges ran in the background: merged.ok is
# how it says it went through
jq '.id="D-404"|.task="T-E6"|.pr=46|.ts="2026-01-01T00:00:00Z"|del(.merge,.merge_reason)|.merged={ok:true}' "$e/state/decisions/D-401.json" \
  > "$e/state/decisions/D-404.json"
assert_eq "false" "$(jq -r '.responses[]|select(.id=="D-403")|.superseded' <<<"$(st)")" \
  "a success recorded before the refusal does not clear it"
jq '.ts="2026-01-01T00:01:00Z"' "$e/state/decisions/D-404.json" > "$e/d404" && mv "$e/d404" "$e/state/decisions/D-404.json"
assert_eq "true" "$(jq -r '.responses[]|select(.id=="D-403")|.superseded' <<<"$(st)")" \
  "a later successful merge response for the same task clears the refusal"

# --- T-059: the readiness card ----------------------------------------------
# T-E6 is ready (above). Firstmate raises its readiness card with the real
# fm-decide.sh, which writes the pending card and emits decision_requested,
# and records the card with the real fm-ready.sh. No card or answer below is
# written by hand, so what the board reads is what those scripts write.
cp "$ROOT/bin/fm-decide.sh" "$ROOT/bin/fm-config.sh" "$ROOT/bin/fm-herdr.py" "$e/bin/"
card4() {   # card4 <id> <task> <option keys, e.g. ABCD>: raise a choice card through fm-decide.sh
  jq -n --arg keys "$3" '
    ($keys | split("") | map({key: ., value: {description: ("do " + .), pros: "p", cons: "c"}})
      | from_entries) as $o
    | {title: "judge", explanation: "e", before: "b", after: "a", outcome: "o", options: $o} as $l
    | {en: $l, "zh-TW": $l}' > "$e/details-$1.json"
  FM_ROOT="$e" FM_PROJECT='' bash "$e/bin/fm-decide.sh" --request "$1" --task "$2" \
    --details "$e/details-$1.json" --repo "$e" > "$e/decide-$1.out" 2>&1
}
card4 D-406 T-E6 ABCD
assert_eq "do D|do D" \
  "$(jq -r '"\(.details.en.options.D.description)|\(.details."zh-TW".options.D.description)"' \
     "$e/state/pending/D-406.json" 2>/dev/null)" \
  "fm-decide.sh accepts a card that offers D and keeps D in both locales"
assert_eq "captain" "$(jq -r '.tasks[]|select(.id=="T-E6")|.stage' <<<"$(st)")" \
  "the control: a card on a task with no readiness record is the captain's"
bash "$e/bin/fm-ready.sh" judged --task T-E6 --decision D-406 --repo "$e" >/dev/null 2>&1
sj="$(st)"
assert_eq "ready" "$(jq -r '.tasks[]|select(.id=="T-E6")|.stage' <<<"$sj")" \
  "a ready task whose only open card is its readiness card stays in the ready lane"
assert_eq "D-406" "$(jq -r '.tasks[]|select(.id=="T-E6")|.badges[]|select(.kind=="decision")|.id' <<<"$sj")" \
  "and still carries the card's badge"
card4 D-407 T-E6 ABC
assert_eq "captain" "$(jq -r '.tasks[]|select(.id=="T-E6")|.stage' <<<"$(st)")" \
  "any other open card on it puts it at the captain's"
# D is a choice only on a card that offers it
code="$(curl -s -o "$e/post" -w '%{http_code}' -X POST -H 'content-type: application/json' \
  -d '{"id":"D-407","chosen":"D"}' "http://127.0.0.1:$PORTE/decisions")"
assert_eq "400" "$code" "D on a card that offers A to C is refused"
assert_fail "test -e '$e/state/decisions/D-407.json'" "and nothing is recorded"
rm -f "$e/state/pending/D-407.json"
code="$(curl -s -o "$e/post" -w '%{http_code}' -X POST -H 'content-type: application/json' \
  -d '{"id":"D-406","chosen":"D"}' "http://127.0.0.1:$PORTE/decisions")"
assert_eq "200" "$code" "D on a card that offers it is accepted"
assert_eq "D" "$(jq -r '.chosen' "$e/state/decisions/D-406.json" 2>/dev/null)" "and recorded as D"
assert_eq "T-E6 choice" "$(jq -r '"\(.task) \(.kind)"' "$e/state/decisions/D-406.json" 2>/dev/null)" \
  "the record names the card's task and kind, which fm-ready.sh cleared reads"
assert_eq "D" "$(FM_ROOT="$e" bash "$e/bin/fm-decide.sh" --await D-406 --timeout 5 --repo "$e" 2>/dev/null \
  | jq -r '.chosen' 2>/dev/null)" \
  "and fm-decide.sh --await hands firstmate the D the captain chose"
# The contract end to end, with no hand-written answer, under an id taken the
# way the skill takes it: fm-decide.sh allocates and raises the card,
# fm-ready.sh records the judgment, the board records the captain's A, and
# fm-ready.sh reads it back.
id8="$(FM_ROOT="$e" FM_PROJECT='' bash "$e/bin/fm-decide.sh" --allocate --task T-E6 --repo "$e" 2>"$e/alloc.err")"
assert_eq "D-firstmate-workflow-TE6-1" "$id8" "fm-decide.sh allocates the readiness card's owned id"
card4 "$id8" T-E6 ABCD
bash "$e/bin/fm-ready.sh" judged --task T-E6 --decision "$id8" --repo "$e" >/dev/null 2>&1
assert_eq "" "$(bash "$e/bin/fm-ready.sh" cleared --repo "$e" 2>&1)" \
  "the control: while the card is open, nothing is cleared"
code="$(curl -s -o "$e/post" -w '%{http_code}' -X POST -H 'content-type: application/json' \
  -d "$(jq -cn --arg id "$id8" '{id:$id,chosen:"A"}')" "http://127.0.0.1:$PORTE/decisions")"
assert_eq "200" "$code" "the captain answers A on the board"
assert_eq "T-E6" "$(bash "$e/bin/fm-ready.sh" cleared --repo "$e" 2>&1)" \
  "and the answer the board wrote clears the task for fm-dispatch.sh"
FM_ROOT="$e" "$e/bin/fm-emit.sh" --actor worker-e --task T-E6 --type dispatched \
  --en "on it" --tw "接下" >/dev/null
assert_eq "working" "$(jq -r '.tasks[]|select(.id=="T-E6")|.stage' <<<"$(st)")" \
  "once work moves the task, the readiness record no longer holds it in ready"

# and the page renders the D button only where the card offers D. The
# options markup is lifted out of index.html and run as written, because
# the e2e spec is out of this task's scope.
dbtn="$(cd "$e" && bun -e '
const src = require("fs").readFileSync("board/public/index.html", "utf8");
const at = src.indexOf("const options = [");
const end = src.indexOf(".join(\x27\x27);", at);
if (at < 0 || end < 0) { console.log("FAIL no options markup"); process.exit(1); }
const expr = src.slice(at + "const options = ".length, end + ".join(\x27\x27)".length);
const render = new Function("d", "content", "pick", "sent", "esc", "words", "t", "said", "return " + expr);
const opts = (keys) => Object.fromEntries(keys.map(k => [k, { description: "do " + k, pros: "p", cons: "c" }]));
const card = (keys) => ({ id: "D-1", kind: "choice", details: { en: { options: opts(keys) } } });
const out = (keys) => render(card(keys), { options: opts(keys) }, undefined, new Set(), String, String, String, String);
const four = out(["A", "B", "C", "D"]), three = out(["A", "B", "C"]);
if (!/data-c="D"[^>]*>D · do D</.test(four)) { console.log("FAIL no D button: " + four); process.exit(1); }
if (/data-c="D"/.test(three)) { console.log("FAIL invented D"); process.exit(1); }
console.log("ok");
')"
assert_eq "ok" "$dbtn" "the page shows a D button on a card that offers D, and only there"

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
# server is started with FM_PROJECT naming the other project: an event or
# card naming no project is the default project's, whatever the shell that
# started the board exported (T-054 covers events that name one, below).
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
assert_eq "9" "$(grep -c '=https://github\.com/example-org/beta-app/pull/' <<<"$(urls)")" \
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

# --- T-054: two projects live on one board -----------------------------------
# Two registered projects with the same task ids and the same pull request
# number, both at work at once. Everything the board shows is keyed by
# (project, id): two T-001s are two cards, two #7s are two links, and a merge
# in one project neither waits for nor frees the other's.
h="$(mktemp -d)"; mkdir -p "$h/bin" "$h/state/pending" "$h/state/decisions" "$h/design" "$h/projects/beta" "$h/board/public"
cp "$ROOT/bin/fm-emit.sh" "$ROOT/bin/fm-config.sh" "$ROOT/bin/fm-herdr.py" "$h/bin/"
cp "$ROOT/board/server.ts" "$h/board/"
cp "$ROOT/board/public/index.html" "$h/board/public/"
two_projects() {   # the registry: alpha hosts itself and is the default, beta is a target
  cat > "$h/config.yaml" <<'Y'
vendor: claude
default_project: alpha
projects:
  alpha:
    repo: .
    github: example-org/alpha-app
    base: main
    required_check: ci
  beta:
    github: example-org/beta-app
    base: main
    required_check: check
Y
}
two_projects
# each project's task list is a directory of task files (T-090): the
# default's design/tasks/, beta's at the registry's default projects/beta/tasks/
fm_tasks_write /dev/stdin "$h/design/tasks" <<'J'
{"tasks":[{"id":"T-001","title":"alpha one","milestone":"M3","depends_on":[]},
          {"id":"T-002","title":"alpha two","milestone":"M3","depends_on":[]},
          {"id":"T-003","title":"alpha three","milestone":"M3","depends_on":["T-002"]},
          {"id":"T-004","title":"alpha four","milestone":"M3","depends_on":[]}]}
J
fm_tasks_write /dev/stdin "$h/projects/beta/tasks" <<'J'
{"tasks":[{"id":"T-001","title":"beta one","milestone":"M1","depends_on":[]},
          {"id":"T-002","title":"beta two","milestone":"M1","depends_on":[]},
          {"id":"T-004","title":"beta four","milestone":"M1","depends_on":[]}]}
J
# The helper the board runs for a merge: it notes how it was called and the
# FM_PROJECT it was handed, holds while told to, and refuses when told to. Its
# output is what fm-merge.sh prints, one line saying what happened.
cat > "$h/bin/fm-merge.sh" <<'S'
#!/usr/bin/env bash
root="$(cd "$(dirname "$0")/.." && pwd)"
printf '%s FM_PROJECT=%s\n' "$*" "${FM_PROJECT-}" >> "$root/merge-calls"
pr=''; project=''
while [ $# -gt 0 ]; do
  case "$1" in --pr) pr="$2"; shift 2 ;; --project) project="$2"; shift 2 ;; *) shift ;; esac
done
tag="${project:-none}-$pr"
while [ -e "$root/hold-$tag" ]; do sleep 0.1; done
if [ -e "$root/refuse-$tag" ]; then echo "fm-merge: GitHub refused the merge of #$pr"; exit 1; fi
echo "merged #$pr"
S
chmod +x "$h/bin/fm-merge.sh"
emh() { FM_ROOT="$h" "$h/bin/fm-emit.sh" "$@" >/dev/null; }
emh --actor captain --type greenlit --en "go" --tw "開工"
emh --actor worker-a1 --task T-001 --type dispatched --data '{"role":"worker","crew_name":"Ada"}' --en "alpha T-001" --tw "alpha T-001"
emh --actor worker-b1 --task T-001 --type dispatched --project beta --data '{"role":"worker","crew_name":"Bo"}' --en "beta T-001" --tw "beta T-001"
emh --actor worker-b1 --task T-001 --type pr_opened --project beta --pr 7 --en "opened #7" --tw "開了 #7"
# the default project named explicitly is the same project as naming none
emh --actor worker-a1 --task T-001 --type pr_opened --project alpha --pr 7 --en "opened #7" --tw "開了 #7"
# beta's T-002 merges; alpha's T-003 waits on alpha's T-002, which has not
emh --actor github --task T-002 --type merged --project beta --en "beta merged" --tw "beta 已合併"
# decision cards of both projects, in the order they were asked for: an old
# numeric card, an old skill-update card, and cards whose ids name their owner
printf '{"id":"D-7","task":"T-002","kind":"choice","title":"old numeric"}\n' > "$h/state/pending/D-7.json"
printf '{"id":"D-SK-003","task":"SK-003","kind":"choice","title":"skill update"}\n' > "$h/state/pending/D-SK-003.json"
printf '{"id":"D-beta-T001-1","project":"beta","task":"T-001","kind":"merge","pr":7,"title":"merge beta #7"}\n' \
  > "$h/state/pending/D-beta-T001-1.json"
printf '{"id":"D-alpha-T001-1","project":"alpha","task":"T-001","kind":"merge","pr":7,"title":"merge alpha #7"}\n' \
  > "$h/state/pending/D-alpha-T001-1.json"
# this one records no project, so it is the default's, alpha's, whatever the
# shell that started the board exported
printf '{"id":"D-alpha-T002-1","task":"T-002","kind":"merge","pr":8,"title":"merge alpha #8"}\n' \
  > "$h/state/pending/D-alpha-T002-1.json"
touch -t 202609240900.00 "$h/state/pending/D-7.json"
touch -t 202609240901.00 "$h/state/pending/D-SK-003.json"
touch -t 202609240902.00 "$h/state/pending/D-beta-T001-1.json"
touch -t 202609240903.00 "$h/state/pending/D-alpha-T001-1.json"
touch -t 202609240904.00 "$h/state/pending/D-alpha-T002-1.json"
# started from a shell that exports FM_PROJECT naming beta: nothing the board
# starts may inherit it
start_h() {   # start_h: the board on $h, its pid in pidh and port in PORTH
  FM_PROJECT=beta FM_ROOT="$h" FM_PORT=0 FM_GH="$h/bin/gh" bun run "$h/board/server.ts" > "$h/out" 2>&1 < /dev/null &
  pidh=$!
  PORTH="$(board_port "$h/out" "$pidh")"
  wait_for 60 curl -sf "http://127.0.0.1:$PORTH/api/state"
}
start_h
sh_() { curl -sf -m 5 "http://127.0.0.1:$PORTH/api/state${1-}"; }
posth() {   # posth <id> <choice>: the HTTP status, the body in $h/post
  local body; body="$(jq -cn --arg i "$1" --arg c "$2" '{id:$i,chosen:$c}')"
  curl -s -m 5 -o "$h/post" -w '%{http_code}' -X POST -H 'content-type: application/json' \
    -d "$body" "http://127.0.0.1:$PORTH/decisions"
}
sh1="$(sh_)"
field_h() { jq -r --arg p "$1" --arg i "$2" ".tasks[]|select(.project==\$p and .id==\$i)|$3" <<<"$sh1"; }

# lane cards: two T-001s, each its own project's, title and pull request
assert_eq "2" "$(jq '[.tasks[]|select(.id=="T-001")]|length' <<<"$sh1")" "two projects' T-001 are two lane cards, not one"
assert_eq "alpha one|beta one" "$(field_h alpha T-001 .title)|$(field_h beta T-001 .title)" \
  "each titled from its own project's task list"
# each T-001 has its own project's merge card up, and carries only that one
assert_eq "captain|captain" "$(field_h alpha T-001 .stage)|$(field_h beta T-001 .stage)" "each waits on the captain for its own card"
assert_eq "D-alpha-T001-1|D-beta-T001-1" \
  "$(field_h alpha T-001 '[.badges[]|select(.kind=="decision")|.id]|join(",")')|$(field_h beta T-001 '[.badges[]|select(.kind=="decision")|.id]|join(",")')" \
  "and its badge names its own project's card, not the other's"
assert_eq "https://github.com/example-org/alpha-app/pull/7|https://github.com/example-org/beta-app/pull/7" \
  "$(field_h alpha T-001 .pr_url)|$(field_h beta T-001 .pr_url)" "each #7 links to its own project's pull request"
assert_eq "Ada|Bo" "$(field_h alpha T-001 '.crew|map(.name)|join(",")')|$(field_h beta T-001 '.crew|map(.name)|join(",")')" \
  "each card names only its own project's crew"
# alpha's T-002 waits on the captain (D-7 below is its card), not merged
assert_eq "merged|captain|backlog T-002" \
  "$(field_h beta T-002 .stage)|$(field_h alpha T-002 .stage)|$(field_h alpha T-003 '"\(.stage) \(.blocked_on|join(","))"')" \
  "another project's T-002 merging unblocks nothing here"
assert_eq "alpha,beta" "$(jq -r '.projects|join(",")' <<<"$sh1")" "the board says which projects it holds, so the page puts chips on"
# crew bubbles: each crewman carries the project of the task it is on
assert_eq "alpha T-001|beta T-001" \
  "$(jq -r '[.crew[]|select(.id=="worker-a1" or .id=="worker-b1")|"\(.project) \(.task)"]|sort|join("|")' <<<"$sh1")" \
  "each crewman carries the project of the task it is on"
# text: a #7 in beta's log line links to beta's #7
assert_eq "https://github.com/example-org/beta-app/pull/7" "$(jq -r '.pr_urls_by_project.beta["7"]' <<<"$sh1")" \
  "a #7 written in beta's text links to beta's pull request"
assert_eq "https://github.com/example-org/alpha-app/pull/7" "$(jq -r '.pr_urls_by_project.alpha["7"]' <<<"$sh1")" \
  "and one in alpha's to alpha's"
assert_eq "https://github.com/example-org/beta-app/pull/7" \
  "$(jq -r '.recent[]|select(.type=="pr_opened" and .project=="beta")|.pr_url' <<<"$sh1")" "a log line links its own project's pull request"
# decision cards: every project's pending card in one list, oldest request first
assert_eq "D-7 D-SK-003 D-beta-T001-1 D-alpha-T001-1 D-alpha-T002-1" "$(jq -r '[.pending[].id]|join(" ")' <<<"$sh1")" \
  "every project's pending cards, old ids and owned ids alike, in one list, oldest request first"
assert_eq "5" "$(jq -r .counts.waiting <<<"$sh1")" "the pending count covers every project"
assert_eq "https://github.com/example-org/beta-app/pull/7" \
  "$(jq -r '.pending[]|select(.id=="D-beta-T001-1")|.pr_url' <<<"$sh1")" "a merge card links the pull request on its own project's repository"

# ?project= filters; without it, or with no project's name, every project shows
sb="$(sh_ '?project=beta')"
assert_eq "beta" "$(jq -r '[.tasks[].project]|unique|join(",")' <<<"$sb")" "?project=beta shows only beta's lane cards"
assert_eq "firstmate worker-b1" "$(jq -r '[.crew[].id]|join(" ")' <<<"$sb")" "and beta's crew, with firstmate, who is every project's"
assert_eq "D-beta-T001-1|1" "$(jq -r '"\([.pending[].id]|join(" "))|\(.counts.waiting)"' <<<"$sb")" \
  "and beta's pending card, counted alone"
assert_eq "4" "$(jq -r .counts.waiting <<<"$(sh_ '?project=alpha')")" "alpha's count is alpha's cards, the old ones included"
assert_eq "5" "$(jq -r .counts.waiting <<<"$(sh_ '?project=..%2Fetc')")" "a filter that is no project's name filters nothing"

# answering one project's card leaves every other card pending and in place
assert_eq "200" "$(posth D-7 B)" "an old numeric card is answered"
assert_eq "200" "$(posth D-SK-003 B)" "an old skill-update card is answered"
assert_eq "D-beta-T001-1 D-alpha-T001-1 D-alpha-T002-1" "$(jq -r '[.pending[].id]|join(" ")' <<<"$(sh_)")" \
  "and the other cards keep their places"

# a merge runs after the answer: the POST comes back while the helper holds
touch "$h/hold-alpha-7"
assert_eq "200" "$(posth D-alpha-T001-1 A)" "the merge answer comes back while its helper is still running"
assert_eq "running" "$(jq -r .merge "$h/post")" "and says the merge is running"
assert_ne "" "$(sh_)" "the board keeps serving while a merge runs"
assert_eq "running" "$(jq -r .merge "$h/state/decisions/D-alpha-T001-1.json")" "the stored record says merge running"
assert_eq "running" "$(jq -r '.responses[]|select(.id=="D-alpha-T001-1")|.merge' <<<"$(sh_)")" "and so does the board"
wait_for 20 grep -q -- '--project alpha' "$h/merge-calls"
assert_contains "$(cat "$h/merge-calls" 2>/dev/null)" "--pr 7 --task T-001 --project alpha" "the helper is given the card's project"
assert_eq "D-alpha-T001-1" "$(jq -r .decision "$h/state/merging/alpha.json" 2>/dev/null)" "the project's merge marker names the decision"
assert_ok "kill -0 \"\$(jq -r .pid '$h/state/merging/alpha.json')\"" "and the pid of the helper that is running"
assert_eq "1" "$(grep -c '"decision":"D-alpha-T001-1"' "$h/state/events.jsonl")" "decision_made is emitted once"
assert_eq "D-beta-T001-1 D-alpha-T002-1" "$(jq -r '[.pending[].id]|join(" ")' <<<"$(sh_)")" "the other project's card is still pending, in place"

# a second merge in the same project is refused before anything is written
assert_eq "409" "$(posth D-alpha-T002-1 A)" "a second merge in the same project is refused while one runs"
assert_eq "no" "$(test -e "$h/state/decisions/D-alpha-T002-1.json" && echo yes || echo no)" "and no response file is written"
assert_eq "0" "$(grep -c '"decision":"D-alpha-T002-1"' "$h/state/events.jsonl")" "and no decision_made is emitted"
assert_eq "D-beta-T001-1 D-alpha-T002-1" "$(jq -r '[.pending[].id]|join(" ")' <<<"$(sh_)")" "and the card stays pending, in place"

# another project's merge runs alongside it and completes
assert_eq "200" "$(posth D-beta-T001-1 A)" "another project's merge is not held behind it"
wait_for 20 jq -e '.merge=="merged"' "$h/state/decisions/D-beta-T001-1.json"
assert_eq "merged" "$(jq -r .merge "$h/state/decisions/D-beta-T001-1.json")" "and completes while the first still runs"
assert_contains "$(cat "$h/merge-calls")" "--pr 7 --task T-001 --project beta" "on its own project"
assert_eq "running" "$(jq -r .merge "$h/state/decisions/D-alpha-T001-1.json")" "the first is still running"
assert_eq "beta" "$(jq -r 'select(.type=="decision_made" and .data.decision=="D-beta-T001-1")|.project' "$h/state/events.jsonl")" \
  "the answer's event names the card's project"

# the helper exits: the record says how, and the project's turn is free
touch "$h/refuse-alpha-7"; rm -f "$h/hold-alpha-7"
wait_for 20 jq -e '.merge=="failed"' "$h/state/decisions/D-alpha-T001-1.json"
assert_eq "failed|fm-merge: GitHub refused the merge of #7" \
  "$(jq -r '"\(.merge)|\(.merge_reason)"' "$h/state/decisions/D-alpha-T001-1.json")" "a refused merge is recorded failed, with the helper's reason"
assert_eq "no" "$(test -e "$h/state/merging/alpha.json" && echo yes || echo no)" "and its marker is gone"
assert_eq "200" "$(posth D-alpha-T001-1 A)" "answering it again returns the stored record"
assert_eq "true failed" "$(jq -r '"\(.already) \(.decision.merge)"' "$h/post")" "with the merge it holds by now"
assert_eq "1" "$(grep -c -- '--pr 7 --task T-001 --project alpha' "$h/merge-calls")" "a failed merge is never retried"
assert_eq "200" "$(posth D-alpha-T002-1 A)" "the next merge in that project is no longer refused"
wait_for 20 jq -e '.merge=="merged"' "$h/state/decisions/D-alpha-T002-1.json"
assert_eq "merged" "$(jq -r .merge "$h/state/decisions/D-alpha-T002-1.json")" "and runs to the end"
# a card naming no project is merged in the default project, with no
# --project, and the helper is not handed the FM_PROJECT the board started with
merge8="$(grep -- '--pr 8 ' "$h/merge-calls")"
assert_lacks "$merge8" "--project" "a card naming no project is merged with no --project"
assert_eq "FM_PROJECT=" "${merge8##* }" "and its helper does not inherit the FM_PROJECT of the shell that started the board"
assert_eq "null" "$(jq -r 'select(.type=="decision_made" and .data.decision=="D-alpha-T002-1")|.project' "$h/state/events.jsonl")" \
  "and its answer's event names no project: it is the default's"
assert_eq "0" "$(jq -r .counts.waiting <<<"$(sh_)")" "nothing is left waiting"

# The captain's park, unpark and drop are writes keyed by (project, id) too.
# Both projects have an untouched T-004; acting on one never moves the other,
# the event names the card's project, and the default project's names none.
postt() {   # postt <task> <action> [project]: the HTTP status, the body in $h/post
  local body
  body="$(jq -cn --arg t "$1" --arg a "$2" --arg p "${3-}" '{task:$t,action:$a} + (if $p == "" then {} else {project:$p} end)')"
  curl -s -m 5 -o "$h/post" -w '%{http_code}' -X POST -H 'content-type: application/json' \
    -d "$body" "http://127.0.0.1:$PORTH/tasks"
}
stage4() { sh_ | jq -r '[.tasks[]|select(.id=="T-004")|"\(.project) \(.stage)"]|sort|join("|")'; }
last4() { jq -r 'select(.task=="T-004")|"\(.type) \(.project)"' "$h/state/events.jsonl" | tail -n 1; }
assert_eq "alpha ready|beta ready" "$(stage4)" "both projects' T-004 start ready"
assert_eq "200" "$(postt T-004 park beta)" "beta's T-004 is parked by naming beta"
assert_eq "alpha ready|beta parked" "$(stage4)" "only beta's T-004 is parked; alpha's stays ready"
assert_eq "parked beta" "$(last4)" "and the parked event names beta"
assert_eq "200" "$(postt T-004 unpark beta)" "beta's T-004 is unparked"
assert_eq "alpha ready|beta ready" "$(stage4)" "and only beta's comes back"
assert_eq "unparked beta" "$(last4)" "and the unparked event names beta"
assert_eq "200" "$(postt T-004 drop beta)" "beta's T-004 is dropped"
assert_eq "alpha ready|beta closed" "$(stage4)" "only beta's T-004 leaves; alpha's stays ready"
assert_eq "closed beta" "$(last4)" "and the closed event names beta"
assert_eq "200" "$(postt T-004 park)" "naming no project parks the default's T-004"
assert_eq "alpha parked|beta closed" "$(stage4)" "alpha's is parked and beta's does not move"
assert_eq "parked null" "$(last4)" "and the event names no project: fm-emit.sh was given no --project"
assert_eq "200" "$(postt T-004 unpark alpha)" "naming the default project explicitly acts on the same card"
assert_eq "alpha ready|beta closed" "$(stage4)" "alpha's comes back and beta's does not move"
assert_eq "unparked null" "$(last4)" "and the default project named explicitly still writes no project"
n4="$(grep -c '"task":"T-004"' "$h/state/events.jsonl")"
assert_eq "404" "$(postt T-004 park nosuch)" "a project no registered project owns has no such task"
assert_eq "$n4" "$(grep -c '"task":"T-004"' "$h/state/events.jsonl")" "and nothing is emitted"
assert_eq "alpha ready|beta closed" "$(stage4)" "and no card moves"

# --- T-054: a merge left running is recovered by the board --------------------
# The board is stopped, and records are left saying merge running, as a board
# that died mid-merge leaves them. On start, and on every poll, it reads each
# one's outcome: from its helper if that is still alive, from a merged event
# for its (project, pr), from GitHub - and when none of those can say, it
# leaves the record running, says the outcome is unknown, and holds the turn.
kill "$pidh" 2>/dev/null; wait "$pidh" 2>/dev/null || true
cat >> "$h/config.yaml" <<'Y'
  gamma:
    github: example-org/gamma-app
    base: main
    required_check: check
  delta:
    github: example-org/delta-app
    base: main
    required_check: check
  eps:
    github: example-org/eps-app
    base: main
    required_check: check
  zeta:
    github: example-org/zeta-app
    base: main
    required_check: check
  theta:
    github: example-org/theta-app
    base: main
    required_check: check
Y
# theta has a task list and nothing else: no crew, no card, no answer. Its
# lane cards alone put it on the board, so they carry its chip.
printf '{"tasks":[{"id":"T-001","title":"theta one","milestone":"M1","depends_on":[]}]}\n' \
  | fm_tasks_write /dev/stdin "$h/projects/theta/tasks"
# gh as gh answers `pr view <n> --repo <owner/repo> --json state`: a JSON
# object on stdout, or a message on stderr and a non-zero exit
cat > "$h/bin/gh" <<'S'
#!/usr/bin/env bash
root="$(cd "$(dirname "$0")/.." && pwd)"
printf '%s\n' "$*" >> "$root/gh-calls"
repo=''
while [ $# -gt 0 ]; do case "$1" in --repo) repo="$2"; shift 2 ;; *) shift ;; esac; done
f="$root/gh-state-${repo#*/}"
[ -f "$f" ] || { echo 'HTTP 502: Bad Gateway (https://api.github.com/graphql)' >&2; exit 1; }
printf '{"state":"%s"}\n' "$(cat "$f")"
S
chmod +x "$h/bin/gh"
printf 'MERGED\n' > "$h/gh-state-beta-app"
printf 'OPEN\n' > "$h/gh-state-gamma-app"
printf 'CLOSED\n' > "$h/gh-state-zeta-app"
printf 'MERGED\n' > "$h/gh-state-eps-app"
# asked with no --repo, gh answers for the checkout it runs in, and here that
# checkout's #27 is merged: a board that asked would settle omega's merge
# from some other repository's pull request
printf 'MERGED\n' > "$h/gh-state-"
# a helper that is gone, and one that is still going
sleep 0 & dead=$!; wait "$dead" 2>/dev/null
sleep 120 & live=$!
live_start="$(ps -o lstart= -p "$live" | awk '{$1=$1; print}')"
running() {   # running <project> <task> <pr> <pid> <started>: a record and its marker
  local id="D-$1-${2/-/}-1"
  jq -cn --arg id "$id" --arg p "$1" --arg t "$2" --argjson n "$3" \
    '{id:$id,chosen:"A",project:$p,task:$t,pr:$n,kind:"merge",ts:"2020-01-01T00:00:00.000Z",identity:"decision:\($id)",merge:"running"}' \
    > "$h/state/decisions/$id.json"
  mkdir -p "$h/state/merging"
  jq -cn --arg id "$id" --arg p "$1" --arg t "$2" --argjson n "$3" --argjson pid "$4" --arg s "$5" \
    '{decision:$id,project:$p,pr:$n,task:$t,pid:$pid,started:$s,ts:"2020-01-01T00:00:00.000Z"}' > "$h/state/merging/$1.json"
}
running alpha T-009 21 "$dead" "Thu Jan 1 00:00:00 2026"
running beta  T-009 22 "$dead" "Thu Jan 1 00:00:00 2026"
running gamma T-009 23 "$dead" "Thu Jan 1 00:00:00 2026"
running delta T-009 24 "$dead" "Thu Jan 1 00:00:00 2026"
running eps   T-009 25 "$live" "$live_start"
running zeta  T-009 26 "$dead" "Thu Jan 1 00:00:00 2026"
# a project the registry no longer names has no repository to ask
running omega T-009 27 "$dead" "Thu Jan 1 00:00:00 2026"
# alpha's merge went through and said so in the log, after the answer
emh --actor captain --type merged --task T-009 --pr 21 --en "merged #21" --tw "已合併 #21"
: > "$h/gh-calls"
start_h
rec() { jq -r .merge "$h/state/decisions/D-$1-T009-1.json"; }
wait_for 20 jq -e '.merge=="merged"' "$h/state/decisions/D-alpha-T009-1.json"
wait_for 20 jq -e '.merge=="merged"' "$h/state/decisions/D-beta-T009-1.json"
wait_for 20 jq -e '.merge=="failed"' "$h/state/decisions/D-gamma-T009-1.json"
wait_for 20 jq -e '.merge=="failed"' "$h/state/decisions/D-zeta-T009-1.json"
delta_unknown() { [ "$(sh_ | jq -r '.responses[]|select(.id=="D-delta-T009-1")|.merge_unknown')" = true ]; }
wait_for 20 delta_unknown
omega_unknown() { [ "$(sh_ | jq -r '.responses[]|select(.id=="D-omega-T009-1")|.merge_unknown')" = true ]; }
wait_for 20 omega_unknown
assert_eq "merged" "$(rec alpha)" "a dead helper's merge is merged when the log has the merged event after the answer"
assert_lacks "$(cat "$h/gh-calls")" "alpha-app" "and GitHub is not asked when the log already says"
assert_eq "merged" "$(rec beta)" "merged when only GitHub says MERGED"
assert_eq "failed|the merge helper stopped before recording an outcome" \
  "$(jq -r '"\(.merge)|\(.merge_reason)"' "$h/state/decisions/D-gamma-T009-1.json")" "failed, with the reason, when GitHub says OPEN"
assert_eq "failed" "$(rec zeta)" "and when GitHub says CLOSED"
assert_eq "running" "$(rec delta)" "a merge whose outcome GitHub cannot tell stays running"
assert_eq "true" "$(sh_ | jq -r '.responses[]|select(.id=="D-delta-T009-1")|.merge_unknown')" "and the board marks its outcome unknown"
assert_eq "running|false" "$(rec eps)|$(sh_ | jq -r '.responses[]|select(.id=="D-eps-T009-1")|.merge_unknown')" \
  "a merge whose helper is alive is left running, not unknown"
assert_lacks "$(cat "$h/gh-calls")" "eps-app" "and GitHub is not asked while its helper is alive"
assert_eq "running|true" "$(rec omega)|$(sh_ | jq -r '.responses[]|select(.id=="D-omega-T009-1")|.merge_unknown')" \
  "a merge in a project the registry does not name stays running, its outcome unknown"
assert_lacks "$(cat "$h/gh-calls")" "view 27" "and gh is never asked without the project's repository"
assert_eq "theta one" "$(sh_ | jq -r '.tasks[]|select(.project=="theta" and .id=="T-001")|.title')" \
  "a project with only lane cards has its own lane card"
assert_eq "true" "$(sh_ | jq -r '.projects|index("theta") != null')" \
  "and is one of the projects on the board, so its cards carry a chip"
for p in alpha beta gamma zeta; do
  assert_eq "no" "$(test -e "$h/state/merging/$p.json" && echo yes || echo no)" "$p's resolved record takes its marker with it"
done
# each resolved record frees its project; an unknown or live one holds it
for p in alpha beta gamma zeta delta eps omega; do
  printf '{"id":"D-%s-T010-1","project":"%s","task":"T-010","kind":"merge","pr":31,"title":"next"}\n' "$p" "$p" \
    > "$h/state/pending/D-$p-T010-1.json"
done
for p in alpha beta gamma zeta; do
  assert_eq "200" "$(posth "D-$p-T010-1" A)" "$p's next merge is no longer refused"
done
assert_eq "409" "$(posth D-delta-T010-1 A)" "a project whose outcome is unknown keeps its turn held"
assert_eq "409" "$(posth D-eps-T010-1 A)" "and so does one whose helper is still running"
assert_eq "409" "$(posth D-omega-T010-1 A)" "and so does one with no repository to read the outcome from"
# the next poll tries again: GitHub answers, and the turn is free
printf 'MERGED\n' > "$h/gh-state-delta-app"
wait_for 20 jq -e '.merge=="merged"' "$h/state/decisions/D-delta-T009-1.json"
assert_eq "merged" "$(rec delta)" "once GitHub can be read, the unknown merge is resolved"
assert_eq "200" "$(posth D-delta-T010-1 A)" "and its project's next merge goes ahead"
# the live helper exits without a word: its outcome is read, not guessed
kill "$live" 2>/dev/null; wait "$live" 2>/dev/null || true
wait_for 20 jq -e '.merge=="merged"' "$h/state/decisions/D-eps-T009-1.json"
assert_eq "merged" "$(rec eps)" "a helper that dies later is resolved on a later poll"
assert_eq "200" "$(posth D-eps-T010-1 A)" "and its project's turn is freed"

kill "$pidh" 2>/dev/null
wait "$pidh" 2>/dev/null || true
kill "$live" 2>/dev/null || true
rm -rf "$h"

# --- T-116: each crew member's fields, separately ---------------------------
# The server reads name, project, round and attempt from the identity a run
# sends (data.identity) and never parses them out of the actor; a run from
# before them still renders, its name read from its old actor once and its
# round unknown, since that actor's r<n> was the global run counter.
q="$(mktemp -d)"; mkdir -p "$q/bin" "$q/state" "$q/design" "$q/board/public"
cp "$ROOT/bin/fm-emit.sh" "$ROOT/bin/fm-config.sh" "$q/bin/"
cp "$ROOT/board/server.ts" "$q/board/"
cp "$ROOT/board/public/index.html" "$ROOT/board/public/ship.js" "$q/board/public/"
fm_tasks_write /dev/stdin "$q/design/tasks" <<'J'
{"tasks":[{"id":"T-Q1","title":"structured crew","milestone":"M2","depends_on":[]},
          {"id":"T-Q2","title":"an old run","milestone":"M2","depends_on":[]}]}
J
emq() { FM_ROOT="$q" "$q/bin/fm-emit.sh" "$@" >/dev/null; }
emq --actor captain --type greenlit --en "go" --tw "開工"
emq --actor worker-shira-tq1-r3b --task T-Q1 --type dispatched \
  --data "$(jq -cn '{role:"worker",crew_name:"worker-shira-tq1-r3b",
    identity:{name:"shira",role:"worker",project:null,task:"T-Q1",round:3,attempt:2}}')" --en "on it" --tw "接下"
emq --actor reviewer-quinn-tq1-r3 --task T-Q1 --type review_opened \
  --data "$(jq -cn '{role:"reviewer",crew_name:"reviewer-quinn-tq1-r3",
    identity:{name:"quinn",role:"reviewer",project:null,task:"T-Q1",round:3,attempt:1}}')" --en "round 3" --tw "第 3 輪"
# recorded before T-116: the actor's r465 is the global counter, not a round
emq --actor worker-mira-tq2-r465 --task T-Q2 --type dispatched \
  --data '{"role":"worker","crew_name":"worker-mira-tq2-r465"}' --en "on it" --tw "接下"
FM_ROOT="$q" FM_PORT=0 bun run "$q/board/server.ts" > "$q/out" 2>&1 < /dev/null &
pidq=$!
PORTQ="$(board_port "$q/out" "$pidq")"
for _ in $(seq 1 40); do curl -sf "http://127.0.0.1:$PORTQ/api/state" >/dev/null 2>&1 && break; sleep 0.25; done
sq="$(curl -sf "http://127.0.0.1:$PORTQ/api/state")"
assert_eq "shira 3 2" "$(jq -r '.crew[]|select(.id=="worker-shira-tq1-r3b")|"\(.name) \(.round) \(.attempt)"' <<<"$sq")" \
  "a run's name, round and attempt reach the board as separate fields"
assert_eq "mira null null" "$(jq -r '.crew[]|select(.id=="worker-mira-tq2-r465")|"\(.name) \(.round) \(.attempt)"' <<<"$sq")" \
  "an old run without the fields still loads: its name from the old actor, its round unknown, never 465"
assert_eq '[{"name":"quinn","role":"reviewer","round":3},{"name":"shira","role":"worker","round":3}]' \
  "$(jq -c '[.tasks[]|select(.id=="T-Q1")|.crew[]|{name,role,round}]|sort_by(.name)' <<<"$sq")" \
  "a task card's crew are separate chips of name, role and round, not a joined string"
kill "$pidq" 2>/dev/null; wait "$pidq" 2>/dev/null || true

# The page, through ship.js itself: the tag, the card, the roster, the deck.
t116="$(cd "$q" && bun -e '
const SHIP = require("./board/public/ship.js");
const T = (k) => k, L = (a) => a && a.en;
const stub = () => ({ onclick: null, textContent: "", style: {}, classList: { add() {}, remove() {} },
  setAttribute() {}, querySelectorAll: () => [] });
const host = () => ({ dataset: {}, innerHTML: "", style: { setProperty() {} },
  querySelector: () => stub(), querySelectorAll: () => [] });
const fail = (m) => { console.log("FAIL " + m); process.exit(1); };
const url = "https://github.com/example-org/app/pull/41";
const state = (projects) => ({ greenlit: true, deckLimit: 24, projects, default_project: projects[0],
  tasks: [{ id: "T-Q1", title: "structured crew", project: projects[0], pr: 41, pr_url: url },
          { id: "T-Q2", title: "an old run", project: projects[projects.length - 1] }],
  crew: [{ id: "firstmate", role: "firstmate", state: "working", task: null },
    { id: "worker-shira-tq1-r3b", role: "worker", state: "working", task: "T-Q1", title: "structured crew",
      project: projects[0], name: "shira", round: 3, attempt: 2, crew_name: "worker-shira-tq1-r3b",
      activity: { en: "Writing the roster" } },
    { id: "worker-mira-tq2-r465", role: "worker", state: "review", task: "T-Q2", title: "an old run",
      project: projects[projects.length - 1], name: "mira", round: null, attempt: null,
      activity: { en: "Reading" } }] });
const h = host();
const crew = SHIP.render(h, state(["alpha"]), T, L);
const tag = (id) => (h.innerHTML.match(new RegExp(`<div class="bub[^"]*" data-bubble="${id}"[^>]*>([\\s\\S]*?)<div class="crewcard`)) || [])[1];
// the tag: the name and a pennant in the project colour, and nothing else
const shira = tag("worker-shira-tq1-r3b");
if (!shira) fail("no tag for shira");
const pennant = shira.match(/<i class="pennant"[^>]*style="--pc:([^"]*)"[^>]*data-project="alpha"/);
if (!pennant) fail("no alpha pennant on the tag: " + shira);
if (pennant[1] !== SHIP.projectColor("alpha")) fail("pennant colour is not the project colour");
const said = shira.replace(/<[^>]*>/g, "");
if (said !== "shira") fail("the tag says more than the name: [" + said + "]");
for (const extra of ["T-Q1", "#41", "Writing", "structured", "crewRound"]) if (shira.includes(extra)) fail("tag carries " + extra);
if (tag("worker-mira-tq2-r465").replace(/<[^>]*>/g, "") !== "mira") fail("an old run is not named on its tag");
// a board of one project has no .pchip (T-054); with two the pennant is the
// chip of the tag, naming its project in hidden text and drawing only the name
if (/pchip/.test(h.innerHTML)) fail("a one-project board draws a project chip");
const h3 = host(); SHIP.render(h3, state(["alpha", "beta"]), T, L);
const tag2 = (id) => (h3.innerHTML.match(new RegExp(`<div class="bub[^"]*" data-bubble="${id}"[^>]*>([\\s\\S]*?)<div class="crewcard`)) || [])[1] || "";
for (const [id, p, n] of [["worker-shira-tq1-r3b", "alpha", "shira"], ["worker-mira-tq2-r465", "beta", "mira"]]) {
  const chips = tag2(id).match(/<i class="pennant pchip"[^>]*>[\s\S]*?<\/i>/g) || [];
  if (chips.length !== 1) fail(`${id} has ${chips.length} project chips on its tag`);
  if (chips[0].replace(/<[^>]*>/g, "") !== p || !/<span class="sr">/.test(chips[0])) fail(`${id} chip says [${chips[0]}]`);
  if (tag2(id).replace(/<span class="sr">[^<]*<\/span>/g, "").replace(/<[^>]*>/g, "") !== n) fail(`${id} tag draws more than its name`);
}
const card2 = (h3.innerHTML.match(/<div class="crewcard" id="crewcard-worker-shira-tq1-r3b"[\s\S]*?<\/dl><\/div>/) || [])[0];
if (/pchip/.test(card2)) fail("the card carries a second project chip inside the bubble");
// the card: one labelled line per field, each on its own
const card = (h.innerHTML.match(/<div class="crewcard" id="crewcard-worker-shira-tq1-r3b"[\s\S]*?<\/dl><\/div>/) || [])[0];
if (!card) fail("no card for shira");
if (!/ hidden[ >]/.test(card.slice(0, card.indexOf(">") + 1))) fail("a card is open before anyone asked");
const dd = (cls) => ((card.match(new RegExp(`<dt>([^<]*)</dt><dd class="${cls}">([\\s\\S]*?)</dd>`)) || []).slice(1));
const want = { cname: ["crewName", "shira"], crole: ["crewRole", "roleWorker"], cproject: ["projectChip", "alpha"],
  ctask: ["crewTask", "T-Q1 structured crew"], cround: ["crewRound", "3 crewAttempt 2"], cpr: ["crewPr", "#41"],
  cstate: ["crewState", "laneWorking"], job: ["crewActivity", "Writing the roster"] };
for (const [cls, [label, value]] of Object.entries(want)) {
  const [dt, body] = dd(cls);
  if (dt !== label) fail(`card line ${cls} is labelled ${dt}`);
  if ((body || "").replace(/<[^>]*>/g, "").trim() !== value) fail(`card line ${cls} says [${body}]`);
}
if (!card.includes(`href="${url}"`)) fail("the card does not link the pull request");
const old = (h.innerHTML.match(/<div class="crewcard" id="crewcard-worker-mira-tq2-r465"[\s\S]*?<\/dl><\/div>/) || [])[0];
if (!old || !/<dd class="cround">crewUnknown<\/dd>/.test(old)) fail("the round of an old run is not shown as unknown");
// one card at a time: the open one is the one SHIP names, and only it
SHIP.openCard = "worker-mira-tq2-r465";
const h2 = host(); SHIP.render(h2, state(["alpha"]), T, L);
const shown = [...h2.innerHTML.matchAll(/<div class="crewcard" id="crewcard-([^"]*)"[^>]*>/g)].filter((m) => !/ hidden/.test(m[0])).map((m) => m[1]);
if (shown.join() !== "worker-mira-tq2-r465") fail("open cards: " + shown.join());
SHIP.openCard = null;
// the roster: a project column with one project and with two
for (const projects of [["alpha"], ["alpha", "beta"]]) {
  const r = { innerHTML: "", ownerDocument: null };
  SHIP.roster(r, SHIP.crewOf(state(projects), T, L), T);
  if (!/<div class="rhead"[\s\S]*data-sort="project"/.test(r.innerHTML)) fail("no project column header with " + projects.length);
  const rows = [...r.innerHTML.matchAll(/<li class="rrow [^"]*"[\s\S]*?<\/li>/g)].map((m) => m[0]);
  if (rows.length !== 3) fail("roster rows " + rows.length);
  for (const row of rows.slice(1)) for (const cls of ["nm", "rl", "pj", "rd", "st", "rpr", "jb"])
    if (!row.includes(`class="${cls}"`)) fail(`roster row lacks its ${cls} cell`);
  const pj = rows.slice(1).map((row) => (row.match(/<span class="pj"[^>]*>([\s\S]*?)<\/span>/) || [])[1].replace(/<[^>]*>/g, ""));
  if (pj.join() !== [projects[0], projects[projects.length - 1]].join()) fail("project column says " + pj.join());
  const rd = (rows[1].match(/<span class="rd"[^>]*>([\s\S]*?)<\/span><span class="st"/) || [])[1].replace(/<[^>]*>/g, "");
  if (rd !== "3 crewAttempt 2") fail("round column says " + rd);
  if (!rows[1].includes(`style="--pc:${SHIP.projectColor(projects[0])}"`)) fail("the roster project colour differs");
  SHIP.rosterGroup = true;
  const g = { innerHTML: "", ownerDocument: null };
  SHIP.roster(g, SHIP.crewOf(state(projects), T, L), T);
  const groups = [...g.innerHTML.matchAll(/<h4 class="rgroup"/g)].length;
  if (groups !== projects.length + 1) fail(`grouped by project: ${groups} groups for ${projects.length} projects and a taskless firstmate`);
  SHIP.rosterGroup = false;
  SHIP.rosterSort = "project";
  const s = { innerHTML: "", ownerDocument: null };
  SHIP.roster(s, SHIP.crewOf(state(projects), T, L), T);
  if (!s.innerHTML.includes(`data-sort="project" aria-pressed="true"`)) fail("sorting by project is not shown");
  SHIP.rosterSort = null;
}
// 24 aboard: no two tags on one deck and one level can reach each other
const full = { greenlit: true, deckLimit: 24, tasks: [], crew: Array.from({ length: 24 }, (_, i) =>
  ({ id: i ? "worker-" + i : "firstmate", role: i ? "worker" : "firstmate", state: "working", task: i ? "T-" + i : null,
     name: "abcdefghijkl".slice(0, 1 + (i % 12)) })) };
const deck = SHIP.render(host(), full, T, L);
for (const a of deck) for (const b of deck) {
  if (a === b || a.row !== b.row || !!a.alt !== !!b.alt) continue;
  if (Math.abs(a.x - b.x) < (a.tagW + b.tagW) / 2 - 1e-6) fail(`tags ${a.id} and ${b.id} overlap`);
}
console.log("ok");
')"
assert_eq "ok" "$t116" "the ship tag holds the name and project pennant only, the card and the roster hold every field apart, and 24 tags do not overlap"

# the card's crew chips, as index.html draws them
chips="$(cd "$q" && bun -e '
const html = require("fs").readFileSync("board/public/index.html", "utf8");
const src = (html.match(/const crewChip = [\s\S]*?<\/span><\/span>`;/) || [])[0];
if (!src) { console.log("FAIL no crewChip in index.html"); process.exit(1); }
if (/task\.crew\.join/.test(html)) { console.log("FAIL a card still joins its crew"); process.exit(1); }
const esc = (s) => String(s ?? ""), t = (k) => k;
const crewChip = eval(src.replace(/^const crewChip = /, "").replace(/;$/, ""));
const out = [{ id: "a", name: "shira", role: "worker", round: 3, attempt: 2 },
             { id: "b", name: "quinn", role: "reviewer", round: null, attempt: null }].map(crewChip);
const text = (m) => m.replace(/<[^>]*>/g, "|").split("|").filter(Boolean);
console.log(JSON.stringify(out.map(text)));
')"
assert_eq '[["shira","roleWorker","crewRound 3 · crewAttempt 2"],["quinn","roleReviewer","crewRound crewUnknown"]]' "$chips" \
  "each crew member on a card is a chip of its own, with name, role and round apart"
rm -rf "$q"

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
