#!/usr/bin/env bash
# A task that turns ready is put before the captain once, against main as it
# now stands, before anything dispatches it. fm-ready.sh is what tells
# firstmate which ready tasks have not been judged yet, and what remembers
# that one has.
set -uo pipefail
# A live managed worker exports FM_* and Herdr ids into this shell; the
# fixture must not bind to the outer run.
for _fm_k in $(env | sed -E -n 's/^(FM_[^=]*|HERDR_[^=]*)=.*$/\1/p'); do
  unset "$_fm_k" || true
done
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=tests/lib.sh
. "$ROOT/tests/lib.sh"
# shellcheck source=bin/fm-config.sh
. "$ROOT/bin/fm-config.sh"   # fm_tasks_write: a fixture's tasks, one file each

# tj <repo> <jq filter>: edit the task list as one {"tasks":[...]} and write
# it back one file per task (T-090), so a task the filter drops is gone too
tj() {
  local all
  all="$(jq -n '{tasks: [inputs]}' "$1"/design/tasks/*.json)" || return 1
  rm -f "$1"/design/tasks/*.json
  jq "$2" <<< "$all" | fm_tasks_write /dev/stdin "$1/design/tasks"
}

# T-1 depends on nothing; T-2 on T-1; T-3 on a task the log has never heard
# of; T-4 is in flight; T-5 was closed; T-6 merged; T-7 is parked.
fixture() {
  local d; d="$(mktemp -d)"
  mkdir -p "$d/bin" "$d/design" "$d/state"
  cp "$ROOT/bin/fm-ready.sh" "$d/bin/"; chmod +x "$d/bin/fm-ready.sh"
  fm_tasks_write /dev/stdin "$d/design/tasks" <<'JSON'
{"tasks":[
 {"id":"T-1","title":"one","depends_on":[]},
 {"id":"T-2","title":"two","depends_on":["T-1"]},
 {"id":"T-3","title":"three","depends_on":["T-9"]},
 {"id":"T-4","title":"four","depends_on":[]},
 {"id":"T-5","title":"five","depends_on":[]},
 {"id":"T-6","title":"six","depends_on":[]},
 {"id":"T-7","title":"seven","depends_on":[]}
]}
JSON
  : > "$d/state/events.jsonl"
  printf '%s' "$d"
}
# One event in the shape fm-emit.sh writes, written by hand so the fixture
# needs no copy of fm-emit.sh.
ev() { printf '{"ts":"2026-09-24T00:00:00Z","actor":"firstmate","type":"%s","task":"%s"}\n' \
  "$2" "$3" >> "$1/state/events.jsonl"; }
ready() { "$1/bin/fm-ready.sh" list --repo "$1" 2>/dev/null; }

# fm-ready.sh keeps its own copy of the board's stage vocabulary. Read the
# board's STAGE map out of board/server.ts and replay each event type against
# an untouched ready task: every one of them moves the task off the list,
# except decision_requested, which is its own judgment card. A type the board
# gains and fm-ready.sh does not know fails here, not as a spurious card.
stage_types="$(sed -n '/^const STAGE/,/^};/p' "$ROOT/board/server.ts" | sed 's://.*$::' \
  | grep -oE '[a-z_]+:' | tr -d ':' | sort -u)"
assert_ne "" "$(grep -x dispatched <<<"$stage_types")" "the board's STAGE map is found and read"
while IFS= read -r t; do
  [ -n "$t" ] || continue
  sd="$(fixture)"; ev "$sd" "$t" T-1
  if [ "$t" = decision_requested ]; then
    assert_contains "$(ready "$sd")" "T-1" "board stage event $t leaves a ready task on the list"
  else
    assert_lacks "$(ready "$sd")" "T-1" "board stage event $t takes a ready task off the list"
  fi
  rm -rf "$sd"
done <<< "$stage_types"
# id and mark only, one per line
marks() { ready "$1" | cut -f1,2; }

# --- ready versus backlog ---------------------------------------------------
d="$(fixture)"
ev "$d" dispatched T-4
ev "$d" closed T-5
ev "$d" merged T-6
ev "$d" parked T-7
out="$(marks "$d")"
assert_eq "T-1	unjudged" "$out" \
  "only the task whose deps are all merged and that nobody touched is ready"
assert_lacks "$out" "T-2" "a task whose dependency has not merged is backlog"
assert_lacks "$out" "T-3" "a dependency the log never heard of is not merged"
assert_lacks "$out" "T-4" "a task in flight is not ready"
assert_lacks "$out" "T-5" "a closed task is not ready"
assert_lacks "$out" "T-6" "a merged task is not ready"
assert_lacks "$out" "T-7" "a parked task is not ready"
assert_contains "$(ready "$d")" "one" "the listing carries the title"

# the task list is one file per task (T-090), read all or nothing: a file
# that does not read is no task list, not a list without that task
bad="$(fixture)"
printf '{"id":"T-8",\n' > "$bad/design/tasks/T-8.json"
assert_fail "'$bad/bin/fm-ready.sh' list --repo '$bad' >/dev/null 2>&1" \
  "a task file that does not parse fails the listing"
assert_fail "'$bad/bin/fm-ready.sh' cleared --repo '$bad' >/dev/null 2>&1" "and the cleared list"
rm -rf "$bad/design/tasks"
assert_fail "'$bad/bin/fm-ready.sh' list --repo '$bad' >/dev/null 2>&1" "and so does a missing design/tasks/"
rm -rf "$bad"

ev "$d" dispatched T-1
ev "$d" merged T-1
assert_eq "T-2	unjudged" "$(marks "$d")" "a dependency merging makes its dependant ready"

# a card about the task is not the task moving: raising the judgment card
# must not take the task off the list it was raised from
ev "$d" decision_requested T-2
assert_eq "T-2	unjudged" "$(marks "$d")" "a decision card about a task leaves it ready"

# --- judged marking ---------------------------------------------------------
"$d/bin/fm-ready.sh" judged --task T-2 --decision D-1000 --repo "$d" >/dev/null 2>&1
assert_eq "0" "$?" "judged records a ready task"
assert_eq "T-2	judged	D-1000" "$(ready "$d" | cut -f1-3)" "a judged task is listed as judged, with its card"
assert_ok "test -f '$d/state/ready/T-2.json'" "the record lives under state/"
assert_eq "D-1000" "$(jq -r .decision "$d/state/ready/T-2.json")" "the record names the decision"
assert_fail "'$d/bin/fm-ready.sh' judged --task T-3 --decision D-1001 --repo '$d'" \
  "a backlog task cannot be marked judged"
assert_fail "test -e '$d/state/ready/T-3.json'" "a refused mark writes nothing"

# --- re-judging after going back to backlog ---------------------------------
# The task gains a dependency that has not merged: back to backlog.
tj "$d" '(.tasks[]|select(.id=="T-2")|.depends_on) = ["T-1","T-8"]
    | .tasks += [{"id":"T-8","title":"eight","depends_on":[]}]'
assert_lacks "$(marks "$d")" "T-2" "a task that gained an unmerged dependency is backlog again"
ev "$d" dispatched T-8
ev "$d" merged T-8
assert_eq "T-2	unjudged" "$(marks "$d")" "a task that returns from backlog is judged again"
"$d/bin/fm-ready.sh" judged --task T-2 --decision D-1002 --repo "$d" >/dev/null 2>&1
assert_eq "T-2	judged	D-1002" "$(ready "$d" | cut -f1-3)" "the second judgment is the one that counts"

# --- a trip to backlog that leaves no mark in the log -----------------------
# A dependency added and then removed before it merges puts the task back
# where it was: same dependencies, same merge, no unpark. fm-ready.sh saw it
# out of ready in between, and that sighting is what ends the judgment.
b="$(fixture)"
setdeps() { tj "$1" "(.tasks[]|select(.id==\"$2\")|.depends_on) = $3"; }
bcleared() { "$1/bin/fm-ready.sh" cleared --repo "$1" 2>/dev/null; }
bans() { mkdir -p "$1/state/decisions"
  printf '{"id":"%s","chosen":"A","task":"%s","kind":"choice"}\n' "$2" "$3" > "$1/state/decisions/$2.json"; }
"$b/bin/fm-ready.sh" judged --task T-1 --decision D-1020 --repo "$b" >/dev/null 2>&1
bans "$b" D-1020 T-1
assert_eq "T-1" "$(bcleared "$b")" "the control: T-1 is judged and answered A"
setdeps "$b" T-1 '["T-9"]'
assert_lacks "$(marks "$b")" "T-1" "a dependency that has not merged puts it back in backlog"
setdeps "$b" T-1 '[]'
assert_contains "$(marks "$b")" "T-1	unjudged" "the dependency taken away again, it is ready and judged again"
assert_eq "" "$(bcleared "$b")" "and the A from before the trip does not clear it"
# the same trip seen only as a different episode: a dependency that had
# already merged is added and removed, and the task never left ready
ev "$b" merged T-6
"$b/bin/fm-ready.sh" judged --task T-1 --decision D-1021 --repo "$b" >/dev/null 2>&1
bans "$b" D-1021 T-1
assert_eq "T-1" "$(bcleared "$b")" "the control: T-1 is judged again and answered A"
setdeps "$b" T-1 '["T-6"]'
assert_contains "$(marks "$b")" "T-1	unjudged" "a dependency added that had merged is a new time it is ready"
setdeps "$b" T-1 '[]'
assert_contains "$(marks "$b")" "T-1	unjudged" "and taking it away again does not bring the old judgment back"
assert_eq "" "$(bcleared "$b")" "nor the old A"
assert_eq "null" "$(jq -r '.decision // "null"' "$b/state/ready/T-1.json")" \
  "the ended judgment names no card, so the board no longer reads it as the task's readiness card"

# --- atomic writes ----------------------------------------------------------
# A rename that fails must leave the earlier record whole and no temporary
# behind; a write straight into the record would have clobbered it.
before="$(cat "$d/state/ready/T-2.json")"
mkdir -p "$d/stub"
printf '#!/bin/sh\nexit 1\n' > "$d/stub/mv"; chmod +x "$d/stub/mv"
PATH="$d/stub:$PATH" "$d/bin/fm-ready.sh" judged --task T-2 --decision D-1003 --repo "$d" >/dev/null 2>&1
assert_ne "0" "$?" "a record that could not be put in place is a failure"
assert_eq "$before" "$(cat "$d/state/ready/T-2.json")" "a failed write leaves the earlier record intact"
assert_eq "T-2.json" "$(ls -A "$d/state/ready")" "a failed write leaves no temporary behind"
"$d/bin/fm-ready.sh" judged --task T-2 --decision D-1004 --repo "$d" >/dev/null 2>&1
assert_eq "T-2.json" "$(ls -A "$d/state/ready")" "a successful write leaves no temporary behind"
assert_eq "D-1004" "$(jq -r .decision "$d/state/ready/T-2.json")" "a successful write replaces the record"

# --- cleared: only the captain's A lets fm-dispatch.sh start it ------------
c="$(fixture)"
cleared() { "$1/bin/fm-ready.sh" cleared --repo "$1" 2>/dev/null; }
# the board's record of an answer, in the shape POST /decisions writes it:
# answer <repo> <D-n> <chosen> [task, default T-1] [kind, default choice]
answer() { mkdir -p "$1/state/decisions"
  printf '{"id":"%s","chosen":"%s","task":"%s","kind":"%s"}\n' \
    "$2" "$3" "${4:-T-1}" "${5:-choice}" > "$1/state/decisions/$2.json"; }
assert_contains "$(marks "$c")" "T-1	unjudged" "the control: T-1 is ready"
assert_eq "" "$(cleared "$c")" "an unjudged ready task is not cleared"
"$c/bin/fm-ready.sh" judged --task T-1 --decision D-1010 --repo "$c" >/dev/null 2>&1
assert_eq "" "$(cleared "$c")" "a card the captain has not answered is not a go-ahead"
answer "$c" D-1010 C
assert_eq "" "$(cleared "$c")" "an answer other than A does not clear it"
answer "$c" D-1010 A T-2
assert_eq "" "$(cleared "$c")" "an A recorded for another task's card does not clear it"
answer "$c" D-1010 A T-1 merge
assert_eq "" "$(cleared "$c")" "an A on a merge card does not clear it"
answer "$c" D-1010 A
assert_eq "T-1" "$(cleared "$c")" "the captain's A clears it"
# the answer belongs to the time the task became ready, like the judgment
tj "$c" '(.tasks[]|select(.id=="T-1")|.depends_on) = ["T-8"]
    | .tasks += [{"id":"T-8","title":"eight","depends_on":[]}]'
ev "$c" dispatched T-8
ev "$c" merged T-8
assert_contains "$(marks "$c")" "T-1	unjudged" "back from backlog, T-1 is ready again"
assert_eq "" "$(cleared "$c")" "and the A it had before does not clear it this time"
# a skill update's id is a task id too: SK-001 can be judged like T-001
tj "$c" '.tasks += [{"id":"SK-001","title":"skill","depends_on":[]}]'
assert_ok "'$c/bin/fm-ready.sh' judged --task SK-001 --decision D-1011 --repo '$c'" \
  "a ready skill update can be judged"

# --- a card id allocated by fm-decide.sh (T-047) ----------------------------
# Every new card takes D-<project>-<task>-<n>; a readiness card is no exception.
o="$(fixture)"
assert_ok "'$o/bin/fm-ready.sh' judged --task T-1 --decision D-firstmate-workflow-T1-1 --repo '$o'" \
  "a card id fm-decide.sh --allocate hands out can be recorded"
assert_eq "T-1	judged	D-firstmate-workflow-T1-1" "$(ready "$o" | grep '^T-1' | cut -f1-3)" \
  "and the task is judged by it"
answer "$o" D-firstmate-workflow-T1-1 A
assert_eq "T-1" "$(cleared "$o")" "and the captain's A on that card clears it"

# --- park, as the board reads it (T-058) ------------------------------------
# Parking takes an untouched task off the list; unparking brings it back as a
# new time it became ready, so the A it had before no longer clears it.
ev "$o" parked T-1
assert_lacks "$(marks "$o")" "T-1" "a parked task is not ready"
ev "$o" unparked T-1
assert_contains "$(marks "$o")" "T-1	unjudged" "an unparked task is ready again and judged again"
assert_eq "" "$(cleared "$o")" "and the A from before it was parked does not clear it"
# a park is the captain's word on untouched work only: a task in flight that
# is parked and unparked is still in flight, not ready
ev "$o" dispatched T-4
ev "$o" parked T-4
ev "$o" unparked T-4
assert_lacks "$(marks "$o")" "T-4" "parking and unparking a task in flight does not make it ready"

# --- an adopted skill update was judged by its adoption card ---------------
# bin/fm.sh self-update --adopt puts SK-* into design/tasks/ only after the
# captain answered D-SK-* with A. That card is the judgment: no second one.
s="$(fixture)"
tj "$s" '.tasks += [{"id":"SK-002","title":"adopted","depends_on":[]},
               {"id":"SK-003","title":"refused","depends_on":[]},
               {"id":"SK-004","title":"borrowed","depends_on":[]}]'
# the proposal each was adopted from, as bin/fm.sh self-update writes it
mkdir -p "$s/state/skill-updates"
for k in SK-002 SK-003 SK-004; do
  printf '{"id":"%s","depends_on":[]}\n' "$k" > "$s/state/skill-updates/$k.json"
done
answer "$s" D-SK-002 A SK-002
answer "$s" D-SK-003 B SK-003
answer "$s" D-SK-004 A SK-002
out="$(ready "$s")"
assert_contains "$out" "SK-002	judged	D-SK-002" "its adoption decision answered A judges the skill update"
assert_contains "$out" "SK-003	unjudged" "an adoption card answered otherwise does not"
assert_contains "$out" "SK-004	unjudged" "nor does an A recorded for another skill update"
assert_eq "SK-002" "$(cleared "$s")" "and only the adopted one is cleared"
assert_fail "test -e '$s/state/ready/SK-002.json'" "without a readiness record being written"
# The adoption card judged the time the skill update first turned ready, not
# every later one: parked and unparked, it is unjudged again and held.
ev "$s" parked SK-002
ev "$s" unparked SK-002
assert_contains "$(marks "$s")" "SK-002	unjudged" "an adopted skill update parked and unparked is judged again"
assert_eq "" "$(cleared "$s")" "and its adoption answer no longer clears it"
# and so is one that went back to backlog on a dependency it gained after
# adoption, and returned when that dependency merged
tj "$s" '.tasks += [{"id":"SK-005","title":"grew","depends_on":["T-1"]}]'
printf '{"id":"SK-005","depends_on":[]}\n' > "$s/state/skill-updates/SK-005.json"
answer "$s" D-SK-005 A SK-005
ev "$s" merged T-1
assert_contains "$(marks "$s")" "SK-005	unjudged" "an adopted skill update back from backlog is judged again"
assert_eq "" "$(cleared "$s")" "and is not cleared by its adoption answer"
# the control: the same dependency, there when it was adopted
tj "$s" '.tasks += [{"id":"SK-006","title":"born with it","depends_on":["T-2"]}]'
printf '{"id":"SK-006","depends_on":["T-2"]}\n' > "$s/state/skill-updates/SK-006.json"
answer "$s" D-SK-006 A SK-006
assert_lacks "$(marks "$s")" "SK-006" "the control: SK-006 waits on T-2"
ev "$s" merged T-2
assert_contains "$(ready "$s")" "SK-006	judged	D-SK-006" "a dependency it was adopted with keeps the adoption as its judgment"
assert_eq "SK-006" "$(cleared "$s")" "and its adoption answer still clears it"
# a dependency gained and lost again, never merged, leaves no mark in the log;
# fm-ready.sh saw it differ from the proposal, and that ends the adoption
tj "$s" '(.tasks[]|select(.id=="SK-006")|.depends_on) = ["T-2","T-9"]'
assert_lacks "$(marks "$s")" "SK-006" "SK-006 is back in backlog on T-9"
tj "$s" '(.tasks[]|select(.id=="SK-006")|.depends_on) = ["T-2"]'
assert_contains "$(marks "$s")" "SK-006	unjudged" "an adopted skill update back from that trip is judged again"
assert_eq "" "$(cleared "$s")" "and is not cleared by its adoption answer"

# --- usage errors exit 64 ---------------------------------------------------
u="$(fixture)"
usage() { FM_ROOT="$u" "$u/bin/fm-ready.sh" "$@" >/dev/null 2>&1; echo "$?"; }
assert_eq "64" "$(usage)" "no subcommand is a usage error"
assert_eq "64" "$(usage nonsense)" "an unknown subcommand is a usage error"
assert_eq "64" "$(usage list --bogus)" "an unknown flag is a usage error"
assert_eq "64" "$(usage judged --task)" "a flag with no value is a usage error"
assert_eq "64" "$(usage judged --task T-1)" "judged without --decision is a usage error"
assert_eq "64" "$(usage judged --decision D-1000)" "judged without --task is a usage error"
assert_eq "64" "$(usage judged --task T-1 --decision 1000)" "a decision that is not D-<n> is a usage error"
assert_eq "64" "$(usage judged --task ../x --decision D-1000)" "a task that is not T-<id> is a usage error"
assert_eq "64" "$(usage judged --task T-1 --decision D-Firstmate-T1-1)" \
  "a card id outside fm-decide.sh's grammar is a usage error"
assert_fail "test -e '$u/state/ready'" "a usage error writes nothing"
"$u/bin/fm-ready.sh" list --repo "$u" --task T-1 >/dev/null 2>&1
assert_eq "64" "$?" "list takes no --task"
assert_eq "64" "$(usage cleared --decision D-1000)" "cleared takes no --decision"

finish
