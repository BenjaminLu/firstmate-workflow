#!/usr/bin/env bash
# Nothing starts before the captain has seen it, nothing starts before its
# dependencies land, and never more than the limit at once.
set -uo pipefail
# A live managed worker exports FM_RUN_DIR / FM_ENTRY_* / FM_WORKER_TASK_LOCK_FD
# and Herdr pane ids into this shell. Suites must not inherit them or freeze,
# identity, locks and pushes bind to the outer run instead of the fixture.
for _fm_k in $(env | sed -E -n 's/^(FM_[^=]*|HERDR_[^=]*)=.*$/\1/p'); do
  unset "$_fm_k" || true
done
export HERDR_ENV=0 FM_TRANSPORT=direct
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=tests/lib.sh
. "$ROOT/tests/lib.sh"
# shellcheck source=bin/fm-config.sh
. "$ROOT/bin/fm-config.sh"   # fm_tasks_write: a fixture's tasks, one file each

fixture() {
  local d; d="$(mktemp -d)"
  mkdir -p "$d/bin" "$d/design" "$d/state"
  cp "$ROOT/bin/fm-config.sh" "$ROOT/bin/fm-emit.sh" "$ROOT/bin/fm-dispatch.sh" "$d/bin/"
  cp "$ROOT/bin/fm-herdr.py" "$ROOT/bin/fm-ready.sh" "$d/bin/"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$d/bin/fm-worker.sh"; chmod +x "$d/bin/fm-worker.sh"
  printf 'concurrency: 2\n' > "$d/config.yaml"
  fm_tasks_write /dev/stdin "$d/design/tasks" <<'JSON'
{"tasks":[
 {"id":"A","depends_on":[]},
 {"id":"B","depends_on":["A"]},
 {"id":"C","depends_on":[]},
 {"id":"D","depends_on":[]}
]}
JSON
  printf '%s' "$d"
}
say() { FM_ROOT="$1" "$1/bin/fm-emit.sh" --actor firstmate --type "$2" ${3:+--task "$3"} >/dev/null; }
# A detached worker's file appears a moment after the dispatcher returns. The
# wait is for that file, against a deadline wide enough for a loaded machine:
# a count of short sleeps ran out under the gate's parallel pool. It returns
# the moment the file is there, so the width costs nothing on a quiet one.
WAIT_SECS=60
eventually() {   # eventually <command...>: 0 once the command is, 1 at the deadline
  local end=$(( $(date +%s) + WAIT_SECS ))
  until "$@"; do [ "$(date +%s)" -le "$end" ] || return 1; sleep 0.05; done
}
# Firstmate judges each task that turns ready and the captain answers the
# card (T-059). The checks about dependencies and capacity are not about
# that, so they clear every ready task first: judged, then answered A, in
# the shape the board writes an answer.
judge() {                       # judge <repo> <task> <D-n> [A|B|C|D]; no answer = card still open
  bash "$1/bin/fm-ready.sh" judged --task "$2" --decision "$3" --repo "$1" >/dev/null 2>&1
  [ -n "${4-}" ] || return 0
  mkdir -p "$1/state/decisions"
  # the shape the board writes (tests/board.test.sh pins it), kind included
  printf '{"id":"%s","chosen":"%s","task":"%s","kind":"choice"}\n' "$3" "$4" "$2" > "$1/state/decisions/$3.json"
}
approve() {                     # approve <repo>: answer A for every unjudged ready task
  local id mark _
  while IFS=$'\t' read -r id mark _; do
    [ "$mark" = unjudged ] || continue
    judge "$1" "$id" "D-$((1000 + $(find "$1/state/decisions" -name 'D-*.json' 2>/dev/null | wc -l)))" A
  done <<< "$(bash "$1/bin/fm-ready.sh" list --repo "$1" 2>/dev/null)"
}
ready() { approve "$1"; FM_ROOT="$1" "$1/bin/fm-dispatch.sh" --repo "$1" --dry-run 2>/dev/null | sed '/^fm-dispatch/d'; }

d="$(fixture)"
assert_fail "FM_ROOT='$d' '$d/bin/fm-dispatch.sh' --repo '$d' --dry-run" \
  "nothing is dispatched before a greenlit event"
say "$d" greenlit
assert_eq "A
C" "$(ready "$d")" "only tasks with no unmet dependency, up to the limit"

say "$d" dispatched A; say "$d" dispatched C
assert_eq "" "$(ready "$d")" "the limit is respected while work is in flight"

say "$d" merged A
assert_eq "B" "$(ready "$d")" "a merged dependency unblocks its dependent, one slot free"

say "$d" merged C
assert_eq "B
D" "$(ready "$d")" "both slots free again"

# a closed task frees its slot without unblocking anything downstream
d2="$(fixture)"; say "$d2" greenlit; say "$d2" dispatched A; say "$d2" closed A
assert_eq "C
D" "$(ready "$d2")" "a closed task frees a slot but does not count as done"
assert_fail "ready '$d2' | grep -qx B" "a closed dependency does not unblock its dependent"

# T-058: a parked task is never started until the captain unparks it, and a
# dropped one (closed, never dispatched) is never started at all
dp="$(fixture)"; say "$dp" greenlit
assert_eq "A
C" "$(ready "$dp")" "the control: A and C would start"
say "$dp" parked A
assert_eq "C
D" "$(ready "$dp")" "a parked task is skipped and its slot goes to the next"
say "$dp" dispatched C; say "$dp" merged C
assert_eq "D" "$(ready "$dp")" "and it stays skipped when a slot is free"
say "$dp" unparked A
assert_eq "A
D" "$(ready "$dp")" "an unparked task is dispatchable again"
say "$dp" parked A; say "$dp" unparked A; say "$dp" parked A
assert_eq "D" "$(ready "$dp")" "the last word wins: parked again is skipped again"
say "$dp" closed D
assert_eq "" "$(ready "$dp")" "a dropped task is never started"
say "$dp" unparked D
assert_eq "" "$(ready "$dp")" "and unparking a dropped task does not bring it back"
rm -rf "$dp"

# the limit comes from config.yaml and can be overridden
d3="$(fixture)"; say "$d3" greenlit; approve "$d3"
assert_eq "1" "$(FM_ROOT="$d3" "$d3/bin/fm-dispatch.sh" --repo "$d3" --dry-run --limit 1 | sed '/^fm-dispatch/d' | wc -l | tr -d ' ')" \
  "--limit overrides the configured concurrency"

# T-090: the order ready tasks take free slots in is fm_tasks' order, ids
# compared as versions. Ids of one width sort the same as text or as
# versions, so these do not: as text T-10 would come first.
dv="$(fixture)"; rm -f "$dv/design/tasks/"*.json
for id in T-10 T-9 T-2; do printf '{"id":"%s","depends_on":[]}\n' "$id" > "$dv/design/tasks/$id.json"; done
say "$dv" greenlit
assert_eq "T-2
T-9" "$(ready "$dv")" "with two slots and T-10, T-9, T-2 ready, T-2 and T-9 start"

# A file that does not read is no task list: nothing is dispatched from the
# files that did, and the file is named. The worker stub leaves a mark, and
# the dispatcher refuses before it would start one, so no mark is final.
db="$(fixture)"; say "$db" greenlit
printf '#!/usr/bin/env bash\necho x >> "%s/started"\n' "$db" > "$db/bin/fm-worker.sh"
printf '{"id":"E",\n' > "$db/design/tasks/E.json"
out="$(FM_ROOT="$db" "$db/bin/fm-dispatch.sh" --repo "$db" 2>&1)"; rc=$?
assert_eq "65" "$rc" "a task file that does not parse stops the dispatch"
assert_contains "$out" "E.json" "and the file is named"
assert_eq "" "$(printf '%s\n' "$out" | grep -xE '[A-E]' || true)" "and no task is printed as started"
assert_fail "test -e '$db/started'" "and no worker was started from the half that did read"
rm -rf "$db/design/tasks"
out="$(FM_ROOT="$db" "$db/bin/fm-dispatch.sh" --repo "$db" --dry-run 2>&1)"; rc=$?
assert_eq "65" "$rc" "a missing task directory is no task list either"
assert_lacks "$out" "nothing is ready" "(not 'nothing is ready')"
rm -rf "$dv" "$db"

# Ready is not cleared (T-059). The control is the tree above, where every
# ready task was answered A and A and C started. Here, with nothing touched
# but the answers: A's card is still up, C was answered C, D was answered A.
j="$(fixture)"; say "$j" greenlit
cat > "$j/bin/fm-worker.sh" <<W
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$j/argv"
W
chmod +x "$j/bin/fm-worker.sh"
out="$(FM_ROOT="$j" "$j/bin/fm-dispatch.sh" --repo "$j" --dry-run 2>&1)"
assert_eq "" "$(sed '/^fm-dispatch/d' <<<"$out")" "a ready task nobody has judged is not started"
assert_contains "$out" "A is ready but the captain has not cleared it" "and the dispatcher says which, and why"
judge "$j" A D-1000
judge "$j" C D-1001 C
judge "$j" D D-1002 A
assert_eq "D" "$(FM_ROOT="$j" "$j/bin/fm-dispatch.sh" --repo "$j" --dry-run 2>/dev/null | sed '/^fm-dispatch/d')" \
  "an open card and an answer other than A hold a task; only an A starts one"
FM_ROOT="$j" "$j/bin/fm-dispatch.sh" --repo "$j" >/dev/null 2>&1
eventually test -s "$j/argv"
assert_contains "$(cat "$j/argv" 2>/dev/null)" "--task D" "a real run starts the task the captain cleared"
assert_eq "1" "$(grep -c . "$j/argv" 2>/dev/null)" "and no other"
# A task the captain orders directly (or a B rescope firstmate has carried
# out) is the captain's own word, so it needs no A on a readiness card. It
# lifts that check and no other. C was answered C above and is still held.
rm -f "$j/argv"
dir_out="$(FM_ROOT="$j" "$j/bin/fm-dispatch.sh" --repo "$j" --task C 2>&1)"
assert_eq "C" "$(sed '/^fm-dispatch/d' <<<"$dir_out")" "a direct order starts the task the captain named, uncleared"
eventually test -s "$j/argv"
assert_eq "--task C --repo $(cd "$j" && pwd -P)" "$(cat "$j/argv" 2>/dev/null)" "and only that task"
# a direct order still waits on dependencies, park, drop and capacity
say "$j" dispatched C
out="$(FM_ROOT="$j" "$j/bin/fm-dispatch.sh" --repo "$j" --task B --dry-run 2>&1)"
assert_contains "$out" "B waits on A" "a direct order does not start a task whose dependency has not merged"
assert_eq "" "$(sed '/^fm-dispatch/d' <<<"$out")" "and starts nothing"
say "$j" parked A
out="$(FM_ROOT="$j" "$j/bin/fm-dispatch.sh" --repo "$j" --task A --dry-run 2>&1)"
assert_eq "" "$(sed '/^fm-dispatch/d' <<<"$out")" "a direct order does not start a parked task"
assert_contains "$out" "A is parked" "and says why"
say "$j" unparked A
out="$(FM_ROOT="$j" "$j/bin/fm-dispatch.sh" --repo "$j" --task A --dry-run --limit 1 2>&1)"
assert_eq "" "$(sed '/^fm-dispatch/d' <<<"$out")" "a direct order does not exceed the limit"
assert_contains "$out" "A waits for a slot" "and says why"
assert_eq "A" "$(FM_ROOT="$j" "$j/bin/fm-dispatch.sh" --repo "$j" --task A --dry-run 2>/dev/null)" \
  "the control: with a slot free the same order starts it"
# every other reason it holds a named task is said too
out="$(FM_ROOT="$j" "$j/bin/fm-dispatch.sh" --repo "$j" --task C --dry-run 2>&1)"
assert_eq "" "$(sed '/^fm-dispatch/d' <<<"$out")" "a direct order does not start a task in flight"
assert_contains "$out" "C is already in flight" "and says why"
assert_fail "FM_ROOT='$j' '$j/bin/fm-dispatch.sh' --repo '$j' --task Z --dry-run 2>/dev/null" \
  "a direct order for a task with no file in design/tasks/ is refused"
# an answer nobody can read is not a yes: without fm-ready.sh nothing starts
rm -f "$j/bin/fm-ready.sh" "$j/argv"
assert_fail "FM_ROOT='$j' '$j/bin/fm-dispatch.sh' --repo '$j' >/dev/null 2>&1" \
  "a dispatcher that cannot read the captain's answers fails"
sleep 0.5
assert_fail "test -e '$j/argv'" "and starts nothing, not even the task that was cleared"
# a direct order reads no answer, so it still runs here, and still holds
# a task that is merged or closed
say "$j" merged D
out="$(FM_ROOT="$j" "$j/bin/fm-dispatch.sh" --repo "$j" --task D --dry-run 2>&1)"
assert_eq "" "$(sed '/^fm-dispatch/d' <<<"$out")" "a direct order does not start a merged task"
assert_contains "$out" "D is already merged" "and says why"
say "$j" closed C
out="$(FM_ROOT="$j" "$j/bin/fm-dispatch.sh" --repo "$j" --task C --dry-run 2>&1)"
assert_eq "" "$(sed '/^fm-dispatch/d' <<<"$out")" "a direct order does not start a closed task"
assert_contains "$out" "C is closed" "and says why"
rm -rf "$j"

# the DAG lint lives in ci.sh; check the lint's logic, not the ambient repo
lintdir="$(mktemp -d)"; mkdir -p "$lintdir/design/tasks"
printf '{"id":"T-405","depends_on":["T-404"]}\n' > "$lintdir/design/tasks/T-405.json"
cp "$ROOT/bin/ci.sh" "$lintdir/"; mkdir -p "$lintdir/bin"
cp "$ROOT/bin/ci.sh" "$ROOT/bin/fm-config.sh" "$lintdir/bin/"
assert_fail "FM_ROOT='$lintdir' bash '$lintdir/bin/ci.sh'" "the gate fails when a task depends on one with no file"
printf '{"id":"T-404","depends_on":[]}\n' > "$lintdir/design/tasks/T-404.json"
assert_ok "FM_ROOT='$lintdir' bash '$lintdir/bin/ci.sh'" "and passes once it has one"
rm -rf "$lintdir"
rm -rf "$d" "$d2" "$d3"

# A task whose pull request is open is being worked on, whoever started
# it. Without this the dispatcher starts a second worker on a branch a
# reviewer has already signed - which is what happened the first time the
# dispatcher ran after a task had been started by hand.
# ONE builder for both trees. The control below has to be the same
# tree as the negative or the comparison is between two different
# things, and two copies of a setup written out by hand agree only
# until one of them is edited.
pr_tree() {                     # pr_tree -> a greenlit repo with T-001 and T-002
  local d; d="$(mktemp -d)"; mkdir -p "$d/bin" "$d/design" "$d/state"
  cp "$ROOT/bin/fm-dispatch.sh" "$ROOT/bin/fm-emit.sh" "$ROOT/bin/fm-config.sh" "$d/bin/"
  cp "$ROOT/bin/fm-herdr.py" "$ROOT/bin/fm-ready.sh" "$d/bin/"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$d/bin/fm-worker.sh"; chmod +x "$d/bin/fm-worker.sh"
  printf 'vendor: mock\nconcurrency: 3\n' > "$d/config.yaml"
  printf '{"tasks":[{"id":"T-001","title":"a","depends_on":[]},{"id":"T-002","title":"b","depends_on":[]}]}\n' \
    | fm_tasks_write /dev/stdin "$d/design/tasks"
  FM_ROOT="$d" "$d/bin/fm-emit.sh" --actor captain --type greenlit --en go --tw 開工 >/dev/null
  approve "$d"
  printf '%s' "$d"
}
p="$(pr_tree)"
# the positive control first, or "it did not appear" is evidence about a
# string rather than about a filter: before anything is said about it,
# T-001 is a task this dispatcher would start
# The control is a SEPARATE tree, because running the dispatcher for
# real emits `dispatched` - so a control run against this fixture would
# leave T-001 in flight and the two assertions below could no longer
# tell "not restarted because its pull request is open" from "not
# restarted because it is already started". Same invocation, same
# output surface, no shared state.
c="$(pr_tree)"
assert_contains "$(cd "$c" && FM_ROOT="$c" bin/fm-dispatch.sh --repo "$c" 2>&1)" "T-001" \
  "the same tree without the pull request event does dispatch T-001"
rm -rf "$c"
# T-001 has a pull request open and no dispatched event: started by hand
FM_ROOT="$p" "$p/bin/fm-emit.sh" --actor worker-1 --task T-001 --type pr_opened --pr 5 \
  --en "opened #5" --tw "已開 #5" >/dev/null
out="$(cd "$p" && FM_ROOT="$p" bin/fm-dispatch.sh --repo "$p" 2>&1)"
assert_lacks "$out" "T-001" "a task with an open pull request is not dispatched again"
assert_contains "$out" "T-002" "and the one that is free still starts"
# once it is merged it is done, not free
FM_ROOT="$p" "$p/bin/fm-emit.sh" --actor captain --task T-001 --type merged --pr 5 \
  --en "merged" --tw "已合併" >/dev/null
out="$(cd "$p" && FM_ROOT="$p" bin/fm-dispatch.sh --repo "$p" 2>&1)"
assert_lacks "$out" "T-001" "and a merged task is not dispatched either"
# Which is why a worker has to find its own pull request: there is no
# state in which this script starts a task that has one. It is in flight
# while the pull request is open and done once it is settled, so the
# number it reads off the log is never a number it can hand to a worker.
# A later round started by hand therefore arrives with nothing, and
# bin/fm-worker.sh looks the number up before it builds the prompt.
rm -rf "$p"

# §5.3.2 says nothing reads the worker's exit status, which is why one
# failed round is one card on the board and not two. Behaviour, not a
# grep for `&` - which is also `2>&1` and `&&`, and would have been
# satisfied by a line with the background operator deleted.
#
# A worker that takes its time: if the dispatcher waited, this would
# take as long as the worker does.
b="$(pr_tree)"
cat > "$b/bin/fm-worker.sh" <<W
#!/usr/bin/env bash
echo \$\$ > "$b/worker-pid"
sleep 5
echo done >> "$b/worker-finished"
W
chmod +x "$b/bin/fm-worker.sh"
FM_ROOT="$b" "$b/bin/fm-dispatch.sh" --repo "$b" >/dev/null 2>&1
# The control first: a dispatcher that started NOTHING also returns at
# once and also leaves no worker-finished, so the absence below means
# nothing without proof that a worker is there to be waited for.
eventually test -s "$b/worker-pid"
wpid="$(cat "$b/worker-pid" 2>/dev/null)"
assert_ne "" "$wpid" "a worker was started, and said which process it is"
# and it is STILL running, which is the property - the dispatcher
# returned while its child was in the middle of a five-second sleep.
# No clock: "is it still alive" is the same question without a
# threshold to tune against whatever the runner is doing.
assert_ok "kill -0 '$wpid' 2>/dev/null" "and the dispatcher returned while it was still running"
assert_fail "test -e '$b/worker-finished'" "so the worker had not finished when the dispatcher did"
kill -TERM "$wpid" 2>/dev/null

# and the conclusion criterion 6 rests on, rather than the premise: the
# worker the dispatcher starts is not handed a number. The two states
# above are WHY there is never one to hand; this reads the argv of the
# worker that actually ran, on a tree where the other task does have a
# pull request - so it is the conclusion observed once, not proved for
# every path.
a="$(pr_tree)"
cat > "$a/bin/fm-worker.sh" <<W
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$a/argv"
W
chmod +x "$a/bin/fm-worker.sh"
FM_ROOT="$a" "$a/bin/fm-emit.sh" --actor firstmate --type pr_opened --task T-001 --pr 5 \
  --en "opened #5" --tw "已開 #5" >/dev/null
FM_ROOT="$a" "$a/bin/fm-dispatch.sh" --repo "$a" >/dev/null 2>&1
eventually test -s "$a/argv"
assert_ne "" "$(cat "$a/argv" 2>/dev/null)" "a worker was started, so there is an argv to read"
assert_lacks "$(cat "$a/argv")" "--pr" "and no worker is ever started with a pull request number"
rm -rf "$a"

# and it does not read what the worker exits with: a worker that fails
# immediately leaves the dispatcher's own status untouched, so a failed
# round writes the one event the worker wrote and no second one
e="$(pr_tree)"
# a worker that records that it HAS exited, so the absence below is
# read after the thing that could have caused it, not after a sleep
printf '#!/usr/bin/env bash\necho x > "%s/worker-done"\nexit 9\n' "$e" > "$e/bin/fm-worker.sh"
chmod +x "$e/bin/fm-worker.sh"
FM_ROOT="$e" "$e/bin/fm-dispatch.sh" --repo "$e" >/dev/null 2>&1
assert_eq "0" "$?" "a worker that fails does not fail the dispatcher"
eventually test -e "$e/worker-done"
assert_ok "test -e '$e/worker-done'" "the failing worker has run and exited"
assert_eq "0" "$(jq -r 'select(.type=="worker_crashed")|.type' "$e/state/events.jsonl" \
  | grep -c . || true)" "and the dispatcher writes no event about it"
rm -rf "$b" "$e"

finish
