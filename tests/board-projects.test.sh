#!/usr/bin/env bash
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=tests/lib/project-storage.sh
. "$ROOT/tests/lib/project-storage.sh"
# shellcheck source=tests/lib/board.sh
. "$ROOT/tests/lib/board.sh"
XDG_CONFIG_HOME="$(safe_tmpdir)"; export XDG_CONFIG_HOME
# --- T-054: two projects live on one board -----------------------------------
# Two registered projects with the same task ids and the same pull request
# number, both at work at once. Everything the board shows is keyed by
# (project, id): two T-001s are two cards, two #7s are two links, and a merge
# in one project neither waits for nor frees the other's.
h="$(safe_tmpdir)"; mkdir -p "$h/bin" "$h/state/pending" "$h/state/decisions" "$h/design" "$h/projects/beta" "$h/board/public"
cp "$ROOT/bin/fm-emit.sh" "$ROOT/bin/fm-config.sh" "$ROOT/bin/fm-herdr.py" "$h/bin/"; project_storage_fixture "$h/bin/"
cp -R "$ROOT/bin/lib" "$h/bin/"   # the lifeline the board starts merges and rounds under (T-151)
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
project_fixture_config "$h"
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
fm_tasks_write /dev/stdin "$(dirname "$(project_fixture_state "$h" beta)")/tasks" <<'J'
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
  > "$(project_fixture_state "$h" beta)/pending/D-beta-T001-1.json"
printf '{"id":"D-alpha-T001-1","project":"alpha","task":"T-001","kind":"merge","pr":7,"title":"merge alpha #7"}\n' \
  > "$h/state/pending/D-alpha-T001-1.json"
# this one records no project, so it is the default's, alpha's, whatever the
# shell that started the board exported
printf '{"id":"D-alpha-T002-1","task":"T-002","kind":"merge","pr":8,"title":"merge alpha #8"}\n' \
  > "$h/state/pending/D-alpha-T002-1.json"
touch -t 202609240900.00 "$h/state/pending/D-7.json"
touch -t 202609240901.00 "$h/state/pending/D-SK-003.json"
touch -t 202609240902.00 "$(project_fixture_state "$h" beta)/pending/D-beta-T001-1.json"
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
  wcurl "$PORTH" -s -m 5 -o "$h/post" -w '%{http_code}' -X POST -H 'content-type: application/json' \
    -d "$body" "http://127.0.0.1:$PORTH/decisions"
}
printf 'private project design\n' > "$(dirname "$(project_fixture_state "$h" beta)")/design.md"
assert_eq 'private project design' "$(curl -sf "http://127.0.0.1:$PORTH/file?project=beta&path=design.md")" "board reads selected external design in place"
assert_eq 403 "$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:$PORTH/file?project=beta&path=../../engine/config.yaml")" "external file reader refuses traversal"
sh1="$(sh_)"
assert_lacks "$sh1" 'beta one' "aggregate exposes metadata without external task descriptions"
assert_contains "$(sh_ '?project=beta')" 'beta one' "selected project reads its private description locally"
field_h() { jq -r --arg p "$1" --arg i "$2" ".tasks[]|select(.project==\$p and .id==\$i)|$3" <<<"$(sh_ "?project=$1")"; }

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
wait_for 20 jq -e '.merge=="merged"' "$(project_fixture_state "$h" beta)/decisions/D-beta-T001-1.json"
assert_eq "merged" "$(jq -r .merge "$(project_fixture_state "$h" beta)/decisions/D-beta-T001-1.json")" "and completes while the first still runs"
assert_contains "$(cat "$h/merge-calls")" "--pr 7 --task T-001 --project beta" "on its own project"
assert_eq "running" "$(jq -r .merge "$h/state/decisions/D-alpha-T001-1.json")" "the first is still running"
assert_eq "beta" "$(jq -r 'select(.type=="decision_made" and .data.decision=="D-beta-T001-1")|.project' "$(project_fixture_state "$h" beta)/events.jsonl")" \
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
  wcurl "$PORTH" -s -m 5 -o "$h/post" -w '%{http_code}' -X POST -H 'content-type: application/json' \
    -d "$body" "http://127.0.0.1:$PORTH/tasks"
}
stage4() { sh_ | jq -r '[.tasks[]|select(.id=="T-004")|"\(.project) \(.stage)"]|sort|join("|")'; }
last4() { jq -r 'select(.task=="T-004")|"\(.type) \(.project)"' "$(project_fixture_state "$h" "${1:-alpha}")/events.jsonl" | tail -n 1; }
assert_eq "alpha ready|beta ready" "$(stage4)" "both projects' T-004 start ready"
assert_eq "200" "$(postt T-004 park beta)" "beta's T-004 is parked by naming beta"
assert_eq "alpha ready|beta parked" "$(stage4)" "only beta's T-004 is parked; alpha's stays ready"
assert_eq "parked beta" "$(last4 beta)" "and the parked event names beta"
assert_eq "200" "$(postt T-004 unpark beta)" "beta's T-004 is unparked"
assert_eq "alpha ready|beta ready" "$(stage4)" "and only beta's comes back"
assert_eq "unparked beta" "$(last4 beta)" "and the unparked event names beta"
assert_eq "200" "$(postt T-004 drop beta)" "beta's T-004 is dropped"
assert_eq "alpha ready|beta closed" "$(stage4)" "only beta's T-004 leaves; alpha's stays ready"
assert_eq "closed beta" "$(last4 beta)" "and the closed event names beta"
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
  | fm_tasks_write /dev/stdin "$(dirname "$(project_fixture_state "$h" theta)")/tasks"
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
project_state() {
  if [ "$1" = omega ]; then printf '%s/state' "$h"
  else project_fixture_state "$h" "$1"; fi
}
running() {   # running <project> <task> <pr> <pid> <started>: a record and its marker
  local id="D-$1-${2/-/}-1" state
  state="$(project_state "$1")"
  jq -cn --arg id "$id" --arg p "$1" --arg t "$2" --argjson n "$3" \
    '{id:$id,chosen:"A",project:$p,task:$t,pr:$n,kind:"merge",ts:"2020-01-01T00:00:00.000Z",identity:"decision:\($id)",merge:"running"}' \
    > "$state/decisions/$id.json"
  mkdir -p "$state/merging"
  jq -cn --arg id "$id" --arg p "$1" --arg t "$2" --argjson n "$3" --argjson pid "$4" --arg s "$5" \
    '{decision:$id,project:$p,pr:$n,task:$t,pid:$pid,started:$s,ts:"2020-01-01T00:00:00.000Z"}' > "$state/merging/$1.json"
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
rec() { jq -r .merge "$(project_state "$1")/decisions/D-$1-T009-1.json"; }
wait_for 20 jq -e '.merge=="merged"' "$h/state/decisions/D-alpha-T009-1.json"
wait_for 20 jq -e '.merge=="merged"' "$(project_fixture_state "$h" beta)/decisions/D-beta-T009-1.json"
wait_for 20 jq -e '.merge=="failed"' "$(project_state gamma)/decisions/D-gamma-T009-1.json"
wait_for 20 jq -e '.merge=="failed"' "$(project_state zeta)/decisions/D-zeta-T009-1.json"
delta_unknown() { [ "$(sh_ | jq -r '.responses[]|select(.id=="D-delta-T009-1")|.merge_unknown')" = true ]; }
wait_for 20 delta_unknown
omega_unknown() { [ "$(sh_ | jq -r '.responses[]|select(.id=="D-omega-T009-1")|.merge_unknown')" = true ]; }
wait_for 20 omega_unknown
assert_eq "merged" "$(rec alpha)" "a dead helper's merge is merged when the log has the merged event after the answer"
assert_lacks "$(cat "$h/gh-calls")" "alpha-app" "and GitHub is not asked when the log already says"
assert_eq "merged" "$(rec beta)" "merged when only GitHub says MERGED"
assert_eq "failed|the merge helper stopped before recording an outcome" \
  "$(jq -r '"\(.merge)|\(.merge_reason)"' "$(project_state gamma)/decisions/D-gamma-T009-1.json")" "failed, with the reason, when GitHub says OPEN"
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
  assert_eq "no" "$(test -e "$(project_state "$p")/merging/$p.json" && echo yes || echo no)" "$p's resolved record takes its marker with it"
done
# each resolved record frees its project; an unknown or live one holds it
for p in alpha beta gamma zeta delta eps omega; do
  printf '{"id":"D-%s-T010-1","project":"%s","task":"T-010","kind":"merge","pr":31,"title":"next"}\n' "$p" "$p" \
    > "$(project_state "$p")/pending/D-$p-T010-1.json"
done
for p in alpha beta gamma zeta; do
  assert_eq "200" "$(posth "D-$p-T010-1" A)" "$p's next merge is no longer refused"
done
assert_eq "409" "$(posth D-delta-T010-1 A)" "a project whose outcome is unknown keeps its turn held"
assert_eq "409" "$(posth D-eps-T010-1 A)" "and so does one whose helper is still running"
assert_eq "409" "$(posth D-omega-T010-1 A)" "and so does one with no repository to read the outcome from"
# the next poll tries again: GitHub answers, and the turn is free
printf 'MERGED\n' > "$h/gh-state-delta-app"
wait_for 20 jq -e '.merge=="merged"' "$(project_state delta)/decisions/D-delta-T009-1.json"
assert_eq "merged" "$(rec delta)" "once GitHub can be read, the unknown merge is resolved"
assert_eq "200" "$(posth D-delta-T010-1 A)" "and its project's next merge goes ahead"
# the live helper exits without a word: its outcome is read, not guessed
kill "$live" 2>/dev/null; wait "$live" 2>/dev/null || true
wait_for 20 jq -e '.merge=="merged"' "$(project_state eps)/decisions/D-eps-T009-1.json"
assert_eq "merged" "$(rec eps)" "a helper that dies later is resolved on a later poll"
assert_eq "200" "$(posth D-eps-T010-1 A)" "and its project's turn is freed"

kill "$pidh" 2>/dev/null
wait "$pidh" 2>/dev/null || true
kill "$live" 2>/dev/null || true
rm -rf "$h"


safe_rm_rf "$XDG_CONFIG_HOME"
finish
