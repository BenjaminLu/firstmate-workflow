#!/usr/bin/env bash
# A decision lands as a file and firstmate wakes. Both paths - bun's fs.watch
# and the poll - have to behave the same, because the poll is what runs on a
# machine that never installed bun.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=tests/lib.sh
. "$ROOT/tests/lib.sh"

fixture() {
  local d; d="$(mktemp -d)"; mkdir -p "$d/bin" "$d/state" "$d/i18n" "$d/board/public"
  # the generator and the dictionaries it cannot render without: requesting a
  # decision draws it, so a fixture without them is not a fixture for
  # --request at all
  cp "$ROOT/bin/fm-emit.sh" "$ROOT/bin/fm-decide.sh" "$ROOT/bin/fm-diagram.sh" "$d/bin/"
  cp "$ROOT/i18n/ui.en.json" "$ROOT/i18n/ui.zh-TW.json" "$ROOT/i18n/tw2cn.tsv" "$d/i18n/"
  [ -f "$ROOT/bin/watch-decisions.ts" ] && cp "$ROOT/bin/watch-decisions.ts" "$d/bin/"
  jq -n '{en:{title:"Cache index",explanation:"Read once",before:"Repeated reads",after:"One read",outcome:"Choice recorded",options:{A:{description:"Cache",pros:"Fast",cons:"Memory"},B:{description:"Read",pros:"Simple",cons:"Slow"},C:{description:"Wait",pros:"Measure",cons:"Delay"}}},"zh-TW":{title:"快取索引",explanation:"讀取一次",before:"重複讀取",after:"讀取一次",outcome:"已記錄選擇",options:{A:{description:"快取",pros:"快速",cons:"記憶體"},B:{description:"讀取",pros:"簡單",cons:"較慢"},C:{description:"等待",pros:"測量",cons:"延後"}}}}' > "$d/details.json"
  printf '%s' "$d"
}
elapsed() { local s e; s=$(date +%s); "$@" >/dev/null 2>&1; e=$(date +%s); echo $(( e - s )); }

d="$(fixture)"
bad="$(FM_ROOT="$d" "$d/bin/fm-decide.sh" --request D-99 --task T-1 --title 'missing' 2>&1)"
assert_eq "64" "$?" "numeric title-only new requests fail"
assert_contains "$bad" '--details requires complete authored' 'missing details have actionable feedback'
assert_fail "test -f '$d/state/pending/D-99.json'" "missing authored input creates no card"
jq 'del(."zh-TW".options.B.cons)' "$d/details.json" > "$d/invalid.json"
assert_fail "FM_ROOT='$d' '$d/bin/fm-decide.sh' --request D-98 --task T-1 --details '$d/invalid.json'" "incomplete localized tradeoffs fail"
assert_fail "test -f '$d/state/pending/D-98.json'" "invalid payload creates no partial card"

# Legacy skill-update path: D-SK-* + matching SK-* + --title, no invented details.
dleg="$(fixture)"
leg_title='skill-update: worker - say the round-three rule once (A adopt it, B leave it)'
leg="$(FM_ROOT="$dleg" "$dleg/bin/fm-decide.sh" --request D-SK-001 --task SK-001 --kind choice --title "$leg_title")"
assert_ok "test -f '$leg'" "legacy skill-update request writes a pending file"
assert_eq "$leg_title" "$(jq -r .title "$leg")" "legacy request persists the given --title"
assert_eq "SK-001" "$(jq -r .task "$leg")" "legacy request records the matching skill task"
assert_eq "null" "$(jq -r .details "$leg")" "legacy request invents no details object"
assert_eq "choice" "$(jq -r .kind "$leg")" "legacy request records kind"
assert_contains "$(jq -r .type < "$dleg/state/events.jsonl")" "decision_requested" \
  "legacy request still emits decision_requested"
assert_fail "FM_ROOT='$dleg' '$dleg/bin/fm-decide.sh' --request D-SK-001 --task SK-001 --title 'again'" \
  "legacy replacement is refused"
assert_fail "FM_ROOT='$dleg' '$dleg/bin/fm-decide.sh' --request D-SK-002 --task SK-999 --title 'mismatch'" \
  "legacy rejects a task that does not match D-SK id"
assert_fail "FM_ROOT='$dleg' '$dleg/bin/fm-decide.sh' --request D-SK-002 --task SK-002" \
  "legacy without --title fails"
assert_fail "test -f '$dleg/state/pending/D-SK-002.json'" "legacy without title creates no card"
assert_fail "FM_ROOT='$dleg' '$dleg/bin/fm-decide.sh' --request D-SK-002 --task SK-002 --details '$d/details.json'" \
  "skill-update ids cannot take the strict --details path"
dstream="$(fixture)"
{ printf '%s\n' '{}'; cat "$d/details.json"; } > "$dstream/stream.json"
assert_fail "FM_ROOT='$dstream' '$dstream/bin/fm-decide.sh' --request D-97 --task T-1 --details '$dstream/stream.json'" \
  "details require exactly one JSON document"
assert_fail "test -f '$dstream/state/pending/D-97.json'" "a JSON stream leaves no partial card"
# Full prohibited control set, including U+007F, before any pending write.
dctrl="$(fixture)"
for pair in '0 0000' '8 0008' '11 000B' '12 000C' '14 000E' '31 001F' '127 007F' '133 0085' '159 009F'; do
  set -- $pair
  jq --argjson cp "$1" '(.en.title) |= ("Cache" + ([$cp]|implode) + "index")' \
    "$dctrl/details.json" > "$dctrl/ctrl.json"
  assert_fail "FM_ROOT='$dctrl' '$dctrl/bin/fm-decide.sh' --request D-9$1 --task T-1 --details '$dctrl/ctrl.json'" \
    "details reject Unicode control U+$2 before persistence"
  assert_fail "test -f '$dctrl/state/pending/D-9$1.json'" "control U+$2 leaves no pending card"
done
out="$(FM_ROOT="$d" "$d/bin/fm-decide.sh" --request D-1 --task T-1 --kind merge --details "$d/details.json" --pr 9)"
assert_ok "test -f '$out'" "a request writes a pending file"
assert_eq "merge" "$(jq -r .kind "$out")" "it records the kind"
assert_eq "9" "$(jq -r .pr "$out")" "it records the pull request"
original="$(cat "$out")"
assert_fail "FM_ROOT='$d' '$d/bin/fm-decide.sh' --request D-1 --task T-1 --details '$d/invalid.json'" "invalid replacement is rejected"
assert_eq "$original" "$(cat "$out")" "rejection preserves the existing decision"
assert_contains "$(jq -r .type < "$d/state/events.jsonl")" "decision_requested" "it emits decision_requested"

# ------------------------------------------- requesting a decision draws it
#
# The board draws nothing. Every decision card mounts an iframe and HEADs
# board/public/diagrams/D-<n>.<lang>.html before it shows it; if nobody ran
# the generator, that HEAD is answered 404 and the frame deletes itself -
# for every reader and every decision, indefinitely, and looking exactly like
# the case the board is designed for, a decision that legitimately has no
# drawing. Nothing downstream can tell those apart, which is why the
# assertion has to be here, at the moment the file is supposed to appear.
for l in en zh-TW zh-CN; do
  assert_ok "test -s '$d/board/public/diagrams/D-1.$l.html'" "requesting D-1 drew its $l diagram"
done
assert_contains "$(cat "$d/board/public/diagrams/D-1.en.html")" "Repeated reads" \
  "and the drawing is of this decision, not a blank frame"
assert_contains "$(cat "$d/board/public/diagrams/D-1.zh-CN.html")" "读取" \
  "with the derived language derived, the same as any other decision"

# --request answers with one thing, the pending file. The generator prints
# the three paths it wrote; passing its stdout through would put them on the
# same stream the caller reads that answer from.
out4="$(FM_ROOT="$d" "$d/bin/fm-decide.sh" --request D-4 --task T-1 --details "$d/details.json" 2>/dev/null)"
assert_eq "$d/state/pending/D-4.json" "$out4" "the request still prints the pending file and nothing else"

# A drawing that cannot be made must not take the decision with it: the
# request is what the captain is waiting on. Silently is the other half -
# a swallowed failure here is a board that is quietly missing a picture and
# a log that says everything went fine.
d5="$(fixture)"
cat > "$d5/bin/fm-diagram.sh" <<'X'
#!/usr/bin/env bash
echo "fm-diagram: the table is on fire" >&2
exit 73
X
chmod +x "$d5/bin/fm-diagram.sh"
err5="$(FM_ROOT="$d5" "$d5/bin/fm-decide.sh" --request D-5 --task T-5 --details "$d/details.json" 2>&1 >/dev/null)"
rc5=$?
assert_eq "0" "$rc5" "a generator that fails does not fail the decision request"
assert_ok "test -f '$d5/state/pending/D-5.json'" "the decision is still pending"
assert_contains "$(jq -r .type < "$d5/state/events.jsonl" | tr '\n' ' ')" "decision_requested" \
  "and decision_requested is still emitted"
assert_contains "$err5" "D-5" "while the drawing that failed is reported rather than swallowed"
assert_contains "$err5" "73"  "with the number the generator exited with"

# "and nothing half-drawn was left behind" used to be asserted here, against
# the stub above - a script that echoes and exits, which could not have
# written a file whatever fm-decide did with it. That assertion was about the
# fixture. The claim is about the REAL generator refusing a bad input before
# the first redirect rather than after one of three, so it is asserted where
# the real generator runs and really does fail: a tree whose zh-TW dictionary
# is not json. It dies 66, and the number reaching stderr is the generator's
# own rather than a number the fixture chose.
d8="$(fixture)"
printf '%s' '{"laneQueued": ' > "$d8/i18n/ui.zh-TW.json"
err8="$(FM_ROOT="$d8" "$d8/bin/fm-decide.sh" --request D-8 --task T-8 --details "$d/details.json" 2>&1 >/dev/null)"
assert_ok "test -f '$d8/state/pending/D-8.json'" "a real generator failure still leaves the decision pending"
assert_contains "$err8" "D-8" "and is reported against the decision it was drawing"
assert_contains "$err8" "66"  "with the generator's own number"
assert_eq "" "$(find "$d8/board/public" -name 'D-8.*' 2>/dev/null)" \
  "and nothing half-drawn was left behind"

# a tree with no generator in it is the same shape: recorded, and said
d6="$(fixture)"; rm -f "$d6/bin/fm-diagram.sh"
err6="$(FM_ROOT="$d6" "$d6/bin/fm-decide.sh" --request D-7 --task T-7 --details "$d/details.json" 2>&1 >/dev/null)"
assert_ok "test -f '$d6/state/pending/D-7.json'" "a tree with no generator still records the decision"
assert_contains "$err6" "D-7" "and still says the diagram was not drawn"

# an answer already on disk returns at once, and survives a restart
mkdir -p "$d/state/decisions"
printf '{"id":"D-1","task":"T-1","chosen":"A"}\n' > "$d/state/decisions/D-1.json"
got="$(FM_ROOT="$d" "$d/bin/fm-decide.sh" --await D-1)"
assert_eq "A" "$(jq -r .chosen <<<"$got")" "an answer already on disk is not missed"
assert_eq "0" "$(jq -s 'map(select(.type=="decision_made"))|length' "$d/state/events.jsonl")" "await never emits duplicate semantic events"
assert_fail "test -f '$d/state/pending/D-1.json'" "answering clears the pending file"

# the interesting case: blocked, then answered from outside
d2="$(fixture)"
( sleep 1; mkdir -p "$d2/state/decisions"
  printf '{"id":"D-2","task":"T-2","chosen":"B"}\n' > "$d2/state/decisions/D-2.json" ) &
t=$(elapsed env FM_ROOT="$d2" "$d2/bin/fm-decide.sh" --await D-2 --timeout 20)
wait
assert_ok "[ '$t' -le 4 ]" "it wakes within seconds of the file appearing (${t}s)"
assert_ok "test -f '$d2/state/decisions/D-2.json'" "the answer is on disk"

# the poll path must behave the same with bun hidden
d3="$(fixture)"
( sleep 1; mkdir -p "$d3/state/decisions"
  printf '{"id":"D-3","chosen":"C"}\n' > "$d3/state/decisions/D-3.json" ) &
stub="$(mktemp -d)"   # a PATH with a shell but no bun
t3=$(elapsed env PATH="/usr/bin:/bin:$stub" FM_ROOT="$d3" bash "$d3/bin/fm-decide.sh" --await D-3 --timeout 20)
wait
assert_ok "test -f '$d3/state/decisions/D-3.json'" "the poll path also returns"
assert_ok "[ '$t3' -le 5 ]" "the poll path wakes within seconds too (${t3}s)"

# it waits for nobody's opinion, but it does give up
d4="$(fixture)"
assert_fail "FM_ROOT='$d4' '$d4/bin/fm-decide.sh' --await D-9 --timeout 2" "it times out rather than hanging forever"

# ------------------------------------ T-047: every new id names its owner
#
# D-<project>-<task>-<n>. The project is the registry name the run resolved
# (--project, then FM_PROJECT, then default_project); the task is its id
# without the hyphen; n counts within that project's task only and is
# allocated here, under that task's own lock. Nothing global is counted.
owned() {   # a fixture with a registry of two projects
  local o; o="$(fixture)"
  cp "$ROOT/bin/fm-config.sh" "$ROOT/bin/fm-herdr.py" "$o/bin/"
  cat > "$o/config.yaml" <<'Y'
default_project: firstmate-workflow
projects:
  firstmate-workflow:
    repo: .
    github: owner/engine
    base: main
    required_check: ci
  example-app:
    github: example-org/example-app
    base: main
    required_check: check
Y
  printf '%s' "$o"
}
alloc() { FM_ROOT="$o" bash "$o/bin/fm-decide.sh" --allocate "$@" 2>/dev/null; }
o="$(owned)"
assert_eq "D-firstmate-workflow-T047-1" "$(alloc --task T-047)" \
  "a first card for a task of the default project is n=1"
assert_eq "D-firstmate-workflow-T047-2" "$(alloc --task T-047)" "and a second card for that task is n=2"
assert_eq "D-example-app-T047-1" "$(alloc --task T-047 --project example-app)" \
  "the same task id in another project is a distinct id, counted from 1"
assert_eq "D-example-app-T047-2" "$(FM_PROJECT=example-app alloc --task T-047)" \
  "FM_PROJECT names the project when no flag does"
assert_eq "D-firstmate-workflow-T047-3" "$(alloc --task T-047 --project firstmate-workflow)" \
  "naming the default project explicitly counts in the same place as naming none"
assert_eq "D-firstmate-workflow-T048-1" "$(alloc --task T-048)" "two tasks never share an id"
FM_ROOT="$o" bash "$o/bin/fm-decide.sh" --allocate --task T-047 --project nosuch-app >/dev/null 2>&1
assert_eq "65" "$?" "a project the registry does not hold exits 65"
for t in T-4.7 X-047 T- 'T-0/1'; do
  FM_ROOT="$o" bash "$o/bin/fm-decide.sh" --allocate --task "$t" >/dev/null 2>&1
  assert_eq "64" "$?" "a task that cannot be written into an id is refused: $t"
done
# a record already on disk is never handed out again, whoever wrote it
mkdir -p "$o/state/decisions"
printf '{"id":"D-example-app-T050-4","task":"T-050","kind":"choice","chosen":"A"}\n' \
  > "$o/state/decisions/D-example-app-T050-4.json"
assert_eq "D-example-app-T050-5" "$(alloc --task T-050 --project example-app)" \
  "the next free n is past every record that task already has"
# the lock is the task's own: ten allocations at once get ten ids
for i in $(seq 1 10); do
  ( alloc --task T-060 > "$o/par.$i" ) &
done
wait
assert_eq "10" "$(cat "$o"/par.* | sort -u | grep -c '^D-firstmate-workflow-T060-')" \
  "ten concurrent allocations for one task get ten distinct ids"
assert_eq "D-firstmate-workflow-T060-10" "$(cat "$o"/par.* | sort -t- -k5 -n | tail -1)" \
  "numbered 1 to 10 with none skipped"

# requesting an allocated id publishes it with its project
id="$(alloc --task T-047 --project example-app)"
out="$(FM_ROOT="$o" "$o/bin/fm-decide.sh" --request "$id" --task T-047 --project example-app \
  --kind merge --pr 12 --details "$d/details.json" 2>/dev/null)"
assert_eq "$o/state/pending/$id.json" "$out" "an allocated id is requested like any other"
assert_eq "example-app" "$(jq -r .project "$out")" "and the card records its project"
assert_eq "example-app" "$(jq -r 'select(.type=="decision_requested")|.project' "$o/state/events.jsonl" | tail -1)" \
  "and so does its decision_requested event"
assert_ok "test -s '$o/board/public/diagrams/$id.en.html'" "and its diagram is drawn under the new id"
FM_ROOT="$o" bash "$o/bin/fm-decide.sh" --request D-example-app-T047-9 --task T-047 --project example-app \
  --details "$d/details.json" >/dev/null 2>&1
assert_eq "65" "$?" "an id nobody allocated is refused"
assert_fail "test -f '$o/state/pending/D-example-app-T047-9.json'" "and publishes nothing"
id2="$(alloc --task T-047)"
FM_ROOT="$o" bash "$o/bin/fm-decide.sh" --request "$id2" --task T-048 --details "$d/details.json" >/dev/null 2>&1
assert_eq "64" "$?" "an id whose task is not the card's task is refused"
FM_ROOT="$o" bash "$o/bin/fm-decide.sh" --request "$id2" --task T-047 --project example-app \
  --details "$d/details.json" >/dev/null 2>&1
assert_eq "64" "$?" "an id whose project is not the card's project is refused"
assert_fail "test -f '$o/state/pending/$id2.json'" "and neither publishes anything"
# request refuses a malformed id before any path is built from it, with
# details or without, and writes nothing for it
for badid in D-Bad_Name-T047-1 D-firstmate-workflow-1 D-firstmate-workflow-T047-0 \
  D-firstmate-workflow-T047-01 'D-../x-T047-1' 'D-a/b-T047-1' "$(printf 'D-a-T047-1\nx')"; do
  FM_ROOT="$o" bash "$o/bin/fm-decide.sh" --request "$badid" --task T-047 --details "$d/details.json" >/dev/null 2>&1
  assert_eq "64" "$?" "request refuses a malformed id: $(printf '%s' "$badid" | tr '\n' '~')"
  FM_ROOT="$o" bash "$o/bin/fm-decide.sh" --request "$badid" --task T-047 --title t >/dev/null 2>&1
  assert_eq "64" "$?" "and refuses it without details too: $(printf '%s' "$badid" | tr '\n' '~')"
done
assert_eq "" "$(find "$o/state/pending" "$o/state/decisions" \( -name '*Bad_Name*' -o -name '*T047-0*' \) | tr '\n' ' ')" \
  "and nothing is written under a malformed id"
# the allocator's scan reaches every store a card can be in: a pending card
# and an archived one each push the next n past them
mkdir -p "$o/state/runtime/archived-pending"
printf '{"id":"D-example-app-T051-3","task":"T-051"}\n' > "$o/state/pending/D-example-app-T051-3.json"
assert_eq "D-example-app-T051-4" "$(alloc --task T-051 --project example-app)" \
  "a pending card nobody reserved here is past the next n"
printf '{"id":"D-example-app-T052-7","task":"T-052"}\n' > "$o/state/runtime/archived-pending/D-example-app-T052-7.json"
assert_eq "D-example-app-T052-8" "$(alloc --task T-052 --project example-app)" \
  "and so is an archived one"
assert_eq "D-firstmate-workflow-T052-1" "$(alloc --task T-052)" \
  "while another project's cards for the same task count nothing"

# await reads both forms and refuses anything else before touching a path
printf '{"id":"%s","task":"T-047","chosen":"B"}\n' "$id" > "$o/state/decisions/$id.json"
assert_eq "B" "$(FM_ROOT="$o" "$o/bin/fm-decide.sh" --await "$id" --timeout 2 | jq -r .chosen)" \
  "await returns a new-form answer"
printf '{"id":"D-056","task":"T-043","chosen":"A"}\n' > "$o/state/decisions/D-056.json"
assert_eq "A" "$(FM_ROOT="$o" "$o/bin/fm-decide.sh" --await D-056 --timeout 2 | jq -r .chosen)" \
  "and still returns an old numeric one"
for badid in D-Bad_Name-T047-1 D-abcdefghijklmnopqrstuvwxy-T047-1 D-firstmate-workflow-1 \
  D-firstmate-workflow-T047-0 D-firstmate-workflow-T047-01 D-firstmate-workflow-T047 \
  'D-../x-T047-1' 'D-a/b-T047-1' 'D-firstmate-workflow-T0.47-1' "$(printf 'D-a-T047-1\nx')"; do
  FM_ROOT="$o" bash "$o/bin/fm-decide.sh" --await "$badid" --timeout 1 >/dev/null 2>&1
  assert_eq "64" "$?" "await refuses a malformed id: $(printf '%s' "$badid" | tr '\n' '~')"
done
# an old record for another task at an old id is never read, moved or touched
before_sum="$(cksum < "$o/state/decisions/D-056.json")"
assert_eq "D-firstmate-workflow-T056-1" "$(alloc --task T-056)" \
  "with T-043's old D-056 on disk, T-056's first card is its own id"
assert_eq "$before_sum" "$(cksum < "$o/state/decisions/D-056.json")" "and D-056 is left exactly as it was"
# A lock left by a process killed outright (KILL: no trap runs) blocks that
# task's allocations. They time out rather than hang, name the lock and say
# what to do; nothing clears it on a guess. Other tasks are not blocked.
mkdir -p "$o/state/decision-ids/firstmate-workflow/T070.lock"
lk="$(FM_ROOT="$o" bash "$o/bin/fm-decide.sh" --allocate --task T-070 2>&1)"
assert_eq "1" "$?" "an allocation behind a stale lock times out"
assert_contains "$lk" "decision-ids/firstmate-workflow/T070.lock" "naming the lock"
assert_contains "$lk" "remove it (rmdir) and allocate again" "and saying what a human does about it"
assert_fail "test -e '$o/state/decision-ids/firstmate-workflow/T070/1.json'" "and reserving nothing"
assert_eq "D-firstmate-workflow-T071-1" "$(alloc --task T-071)" "another task's allocation is not blocked by it"
rmdir "$o/state/decision-ids/firstmate-workflow/T070.lock"
assert_eq "D-firstmate-workflow-T070-1" "$(alloc --task T-070)" "once it is removed, the task allocates again"
rm -rf "$o"

# A tree with no `projects:` map - every fixture before projects existed - is
# the engine hosting itself: its ids are the self project's, and nothing
# records a project, because there is no registry to validate one against.
u="$(fixture)"; cp "$ROOT/bin/fm-config.sh" "$ROOT/bin/fm-herdr.py" "$u/bin/"
printf 'vendor: mock\n' > "$u/config.yaml"
uid="$(FM_ROOT="$u" bash "$u/bin/fm-decide.sh" --allocate --task T-047 --kind merge 2>/dev/null)"
assert_eq "D-firstmate-workflow-T047-1" "$uid" "an unregistered tree allocates under the self project"
assert_eq "D-firstmate-workflow-T047-2" \
  "$(FM_ROOT="$u" bash "$u/bin/fm-decide.sh" --allocate --task T-047 --project firstmate-workflow 2>/dev/null)" \
  "naming the self project there is the same"
FM_ROOT="$u" bash "$u/bin/fm-decide.sh" --allocate --task T-047 --project example-app >/dev/null 2>&1
assert_eq "65" "$?" "naming any other project there is refused"
upend="$(FM_ROOT="$u" bash "$u/bin/fm-decide.sh" --request "$uid" --task T-047 --kind merge --pr 3 \
  --details "$d/details.json" 2>/dev/null)"
assert_eq "$u/state/pending/$uid.json" "$upend" "and the id is requested there"
assert_eq "false" "$(jq -c 'has("project")' "$upend")" "with no project on the card"
assert_eq "false" "$(jq -c 'select(.type=="decision_requested")|has("project")' "$u/state/events.jsonl")" \
  "and its decision_requested event is written, with no project"
rm -rf "$u"

# no dependency on a watcher that has to be installed
# the words may appear in a comment explaining the absence; a call may not
assert_fail "grep -vE '^[[:space:]]*#' '$ROOT/bin/fm-decide.sh' | grep -qE '\\b(fswatch|watchexec|entr)\\b'" \
  "it calls neither fswatch, watchexec nor entr"
rm -rf "$d" "$d2" "$d3" "$d4" "$d5" "$d6" "$d8" "$dstream" "$dctrl" "$dleg" "$stub"
finish
