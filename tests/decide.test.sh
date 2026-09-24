#!/usr/bin/env bash
# A decision lands as a file and firstmate wakes. Both paths - bun's fs.watch
# and the poll - have to behave the same, because the poll is what runs on a
# machine that never installed bun.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=tests/lib.sh
. "$ROOT/tests/lib.sh"
# a suite run inside Herdr must not ring the captain for every fixture card;
# the T-096 cases below put HERDR_ENV back, with a stub, where they mean it
unset HERDR_ENV HERDR_STUB FM_NOTIFY_SECONDS

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

# ------------------ T-096: a card the captain must answer raises a Herdr notice
#
# Only a decision request notifies, once per id, in the captain's language,
# and only inside Herdr. Everything the stub answers was captured from the
# real CLI, herdr 0.8.0, on the captain's machine:
#   HERDR_ENV=1   `herdr --skill`: "Requires HERDR_ENV=1", and the check it
#                 teaches is  test "${HERDR_ENV:-}" = 1
#   a call        `herdr notification show <title> --body <text> --sound
#                 request` in a Herdr with notifications disabled: the JSON
#                 line at the end of the stub on stdout, exit 0
#   a bad sound   `herdr notification show t --body b --sound loud`: the
#                 refusal below on stderr, exit 2
#   no server     `herdr --session t096-capture-none notification show t
#                 --body b --sound none`: the error line below on stderr,
#                 exit 1; HERDR_STUB=no-server answers that to any call
# HERDR_STUB=hang is a Herdr that never answers. It prints nothing and does
# not exit, which is all a hang shows, so nothing in it is made up. The stub
# logs every call's argv, one JSON array per call, without handing it to an
# option parser, and fails out loud when it cannot log.
hstub="$(mktemp -d)"; hlog="$hstub/calls.jsonl"
cat > "$hstub/herdr" <<'X'
#!/usr/bin/env bash
set -o pipefail
printf '%s\0' "$@" | jq -sRc 'split("\u0000")[:-1]' >> "$HERDR_LOG" || {
  echo "herdr stub: could not log this call to ${HERDR_LOG:-nowhere}" >&2; exit 70; }
case "${HERDR_STUB:-}" in
  hang) exec sleep 30 ;;
  no-server)
    echo '{"id":"cli:notification:show","error":{"code":"server_not_running","message":"no herdr server is running at /Users/benjamin/.config/herdr/sessions/t096-capture-none/herdr.sock; run `herdr session attach t096-capture-none` to start or attach it"}}' >&2
    exit 1 ;;
esac
prev=''
for a in "$@"; do
  if [ "$prev" = --sound ]; then
    case "$a" in none|done|request) ;;
      *) echo "invalid sound: $a (expected none, done, or request)" >&2; exit 2 ;; esac
  fi
  prev="$a"
done
echo '{"id":"cli:notification:show","result":{"reason":"disabled","shown":false,"type":"notification_show"}}'
X
chmod +x "$hstub/herdr"
shown='{"id":"cli:notification:show","result":{"reason":"disabled","shown":false,"type":"notification_show"}}'
calls() { [ -s "$hlog" ] && grep -c . "$hlog" || echo 0; }
# FM_PROJECT is taken away so the captain's shell cannot choose a project;
# a case that means one sets it, after this, by name
inherdr() { env -u FM_PROJECT HERDR_ENV=1 HERDR_LOG="$hlog" PATH="$hstub:$PATH" "$@"; }
nfix() { local n; n="$(fixture)"; cp "$ROOT/bin/fm-config.sh" "$n/bin/"; printf '%s' "$n"; }
# ask [NAME=value ...] <fixture> <id> <task> [fm-decide args]: request a card
# inside Herdr and keep its exit code, stdout and stderr
ask() {
  local k=0 f id t
  while [ $((k + 1)) -le $# ] && case "${@:k+1:1}" in [A-Z]*=*) true ;; *) false ;; esac; do k=$((k + 1)); done
  f="${*:k+1:1}"; id="${*:k+2:1}"; t="${*:k+3:1}"
  ask_err="$(inherdr "${@:1:k}" FM_ROOT="$f" "$f/bin/fm-decide.sh" --request "$id" --task "$t" "${@:k+4}" \
    2>&1 >"$hstub/out")"
  ask_rc=$?; ask_out="$(cat "$hstub/out")"
}
# held <fixture> <id> <task> <what>: whatever Herdr did, the request did
# what a request does - exit 0, print only its pending file, leave the card
# pending and write its decision_requested event
held() {
  assert_eq "0" "$ask_rc" "$4: exits 0"
  assert_eq "$1/state/pending/$2.json" "$ask_out" "$4: prints only the pending file"
  assert_ok "test -f '$1/state/pending/$2.json'" "$4: the card is pending"
  assert_eq "1" "$(jq -s --arg t "$3" 'map(select(.type=="decision_requested" and .task==$t))|length' \
    "$1/state/events.jsonl")" "$4: its event is written"
}
argv() {  # argv <title> <body> <sound>: the call notify makes, as the stub logs it
  jq -cn --arg t "$1" --arg b "$2" --arg s "$3" '["notification","show",$t,"--body",$b,"--sound",$s]'
}

# The helper and the stub are checked before anything is concluded from
# them, with the call notify actually makes: flags, a title with spaces and
# ' · ', a CJK body. Every "notifies nothing" below is worth only as much as
# a helper that would have reached a stub that would have logged.
assert_ok "inherdr sh -c 'test \"\$HERDR_ENV\" = 1 && test -n \"\$HERDR_LOG\"'" \
  "the Herdr helper sets HERDR_ENV=1 and the stub's log"
: > "$hlog"
probe="$(inherdr herdr notification show 'example-app · T-047 · merge' --body '快取索引' --sound request 2>&1)"
assert_eq "0" "$?" "the herdr it runs is the stub, which takes notify's own call"
assert_eq "$shown" "$probe" "and answers it with the line the real CLI printed"
assert_eq "1" "$(calls)" "logging it once"
assert_eq "$(argv 'example-app · T-047 · merge' '快取索引' request)" "$(tail -1 "$hlog")" \
  "argument for argument"
refused="$(inherdr herdr notification show 'example-app · T-047 · merge' --body '快取索引' --sound loud 2>&1 >/dev/null)"
assert_eq "2" "$?" "it refuses a sound the real CLI refuses, with its exit code"
assert_eq "invalid sound: loud (expected none, done, or request)" "$refused" "in its words, on stderr"
assert_eq "2" "$(calls)" "and logs that call too"
noserver="$(inherdr HERDR_STUB=no-server herdr notification show t --body b --sound none 2>&1 >/dev/null)"
assert_eq "1" "$?" "with no server it exits as the real CLI did"
assert_contains "$noserver" '"code":"server_not_running"' "and says what the real CLI said"
nolog="$(inherdr HERDR_LOG="$hstub/no/such/dir/calls.jsonl" herdr notification show t --body b --sound none 2>&1 >/dev/null)"
assert_eq "70" "$?" "a stub that cannot log fails"
assert_contains "$nolog" "herdr stub: could not log" "and says so on stderr"
n="$(nfix)"
assert_ok "test -r '$n/bin/fm-config.sh'" "the notification fixture has the config reader"
rm -rf "$n"

# The title names the project the card is filed under - what it records,
# else, as the board reads a card that records none, the default project,
# else the self project - and never whatever FM_PROJECT says beside it.
o="$(owned)"; : > "$hlog"
oid="$(alloc --task T-047 --project example-app)"
ask FM_PROJECT=firstmate-workflow "$o" "$oid" T-047 --project example-app --kind merge --pr 12 --details "$d/details.json"
held "$o" "$oid" T-047 "a merge card of a registered project"
assert_eq "1" "$(calls)" "a merge card raises one notification"
assert_eq "$(argv 'example-app · T-047 · merge' '快取索引' request)" "$(tail -1 "$hlog")" \
  "naming its project over FM_PROJECT, task, kind, the zh-TW question, the request sound"
oid="$(FM_PROJECT=example-app alloc --task T-048)"
ask FM_PROJECT=example-app "$o" "$oid" T-048 --details "$d/details.json"
held "$o" "$oid" T-048 "a card filed under FM_PROJECT"
assert_eq "$(argv 'example-app · T-048 · choice' '快取索引' request)" "$(tail -1 "$hlog")" \
  "is named by the project FM_PROJECT filed it under"
sed 's/^default_project:.*/default_project: example-app/' "$o/config.yaml" > "$o/config.new" && mv "$o/config.new" "$o/config.yaml"
ask FM_PROJECT=firstmate-workflow "$o" D-41 T-41 --details "$d/details.json"
held "$o" D-41 T-41 "default_project present"
assert_eq "false" "$(jq -c 'has("project")' "$o/state/pending/D-41.json")" "a card that records no project"
assert_eq "$(argv 'example-app · T-41 · choice' '快取索引' request)" "$(tail -1 "$hlog")" \
  "is the default project's, whatever FM_PROJECT says"
assert_eq "3" "$(calls)" "one notification per card"

# a tree with no registry is the self project's, whatever FM_PROJECT names
n="$(nfix)"; : > "$hlog"
ask FM_PROJECT=example-app "$n" D-31 T-31 --details "$d/details.json"
held "$n" D-31 T-31 "a choice card with no registry"
assert_eq "$(argv 'firstmate-workflow · T-31 · choice' '快取索引' request)" "$(tail -1 "$hlog")" \
  "a choice card notifies too, under the self project"
assert_eq "1" "$(calls)" "once"
assert_ok "test -f '$n/state/runtime/notified/D-31'" "and marks the id"
first31="$(cat "$n/state/pending/D-31.json")"
# never twice for one id: a refused replacement, and a withdrawn card
# requested again under the same id. Nothing in bin/ or board/ withdraws a
# card; firstmate archives it out of pending by hand, so the test does too.
ask "$n" D-31 T-31 --details "$d/details.json"
assert_eq "65" "$ask_rc" "a second request for the same id is refused"
assert_eq "$first31" "$(cat "$n/state/pending/D-31.json")" "leaving the card as it was"
assert_eq "1" "$(calls)" "and does not notify again"
mkdir -p "$n/state/runtime/archived-pending"; mv "$n/state/pending/D-31.json" "$n/state/runtime/archived-pending/"
ask "$n" D-31 T-31 --details "$d/details.json"
assert_eq "0" "$ask_rc" "a withdrawn id requested again is requested"
assert_eq "$n/state/pending/D-31.json" "$ask_out" "and pending again"
assert_eq "2" "$(jq -s 'map(select(.type=="decision_requested" and .task=="T-31"))|length' "$n/state/events.jsonl")" \
  "with its second event"
assert_eq "1" "$(calls)" "but does not notify again"
# an answered id is never notified: its request is refused, and awaiting it
# returns the answer
mkdir -p "$n/state/decisions"; printf '{"id":"D-32","chosen":"A"}\n' > "$n/state/decisions/D-32.json"
ask "$n" D-32 T-32 --details "$d/details.json"
assert_eq "65" "$ask_rc" "a request for an answered id is refused"
assert_fail "test -e '$n/state/pending/D-32.json'" "and puts no card up"
assert_eq '{"id":"D-32","chosen":"A"}' "$(cat "$n/state/decisions/D-32.json")" "leaving the answer as it was"
assert_eq "1" "$(calls)" "and notifies nothing"
aw="$(inherdr FM_ROOT="$n" "$n/bin/fm-decide.sh" --await D-32 --timeout 1 2>/dev/null)"
assert_eq "0" "$?" "awaiting an answered id returns"
assert_eq "A" "$(jq -r .chosen <<<"$aw")" "with the answer"
assert_eq "1" "$(calls)" "and notifies nothing either"
# the legacy skill-update card is a decision too; its title is its question
ask "$n" D-SK-031 SK-031 --title "$leg_title"
held "$n" D-SK-031 SK-031 "a skill-update card"
assert_eq "$(argv 'firstmate-workflow · SK-031 · choice' "$leg_title" request)" "$(tail -1 "$hlog")" \
  "a skill-update card notifies with its own title"
assert_eq "2" "$(calls)" "so the fixture that stayed quiet for D-31 and D-32 still rings for a new id"

# config: every way config.yaml can be read keeps the request's contract.
# notifications.herdr and .sound default to true when the keys are absent.
printf 'vendor: mock\n' > "$n/config.yaml"; : > "$hlog"
ask "$n" D-42 T-42 --details "$d/details.json"
held "$n" D-42 T-42 "a config.yaml with no notifications"
assert_eq "$(argv 'firstmate-workflow · T-42 · choice' '快取索引' request)" "$(tail -1 "$hlog")" \
  "rings, with the sound"
printf 'notifications:\n  herdr: false\n' > "$n/config.yaml"; : > "$hlog"
ask "$n" D-33 T-33 --details "$d/details.json"
held "$n" D-33 T-33 "notifications.herdr: false"
assert_eq "0" "$(calls)" "notifications.herdr: false raises nothing"
printf 'notifications:\n  herdr: true\n  sound: false   # quiet\n' > "$n/config.yaml"
ask "$n" D-34 T-34 --details "$d/details.json"
held "$n" D-34 T-34 "notifications.sound: false"
assert_eq "1" "$(calls)" "notifications.herdr: true in the same fixture rings"
assert_eq "$(argv 'firstmate-workflow · T-34 · choice' '快取索引' none)" "$(tail -1 "$hlog")" \
  "and notifications.sound: false makes it silent"
cp "$ROOT/config.yaml" "$n/config.yaml"; : > "$hlog"
ask "$n" D-43 T-43 --details "$d/details.json"
held "$n" D-43 T-43 "the real config.yaml"
assert_eq "$(argv 'firstmate-workflow · T-43 · choice' '快取索引' request)" "$(tail -1 "$hlog")" \
  "the real config.yaml rings, under its default project"
# a config.yaml nobody can read fails closed: its herdr: false still holds
rm -f "$n/bin/fm-config.sh"; printf 'notifications:\n  herdr: false\n' > "$n/config.yaml"; : > "$hlog"
ask "$n" D-44 T-44 --details "$d/details.json"
held "$n" D-44 T-44 "a config.yaml without its reader"
assert_eq "0" "$(calls)" "a config.yaml without its reader rings nothing"
assert_contains "$ask_err" "cannot read notifications" "and says why"
rm -f "$n/config.yaml"
ask "$n" D-45 T-45 --details "$d/details.json"
held "$n" D-45 T-45 "no config.yaml and no reader"
assert_eq "1" "$(calls)" "while the same fixture with no config.yaml rings"
cp "$ROOT/bin/fm-config.sh" "$n/bin/"

# a notification that fails never fails the decision, and says how
: > "$hlog"
ask HERDR_STUB=no-server "$n" D-35 T-35 --details "$d/details.json"
held "$n" D-35 T-35 "a Herdr with no server"
assert_eq "1" "$(calls)" "after herdr was really called"
assert_contains "$ask_err" "D-35" "the failure is reported against the decision"
assert_contains "$ask_err" "herdr exited 1" "with how Herdr failed"
assert_contains "$ask_err" "server_not_running" "in Herdr's own words"
ask HERDR_LOG="$hstub/no/such/dir/calls.jsonl" "$n" D-46 T-46 --details "$d/details.json"
held "$n" D-46 T-46 "a stub that cannot log"
assert_contains "$ask_err" "herdr stub: could not log" "a stub that cannot log is heard through the request"
# a Herdr that never answers is given up on at the bound (10s; 1 here)
: > "$hlog"; t0=$(date +%s)
ask HERDR_STUB=hang FM_NOTIFY_SECONDS=1 "$n" D-47 T-47 --details "$d/details.json"
t1=$(date +%s)
held "$n" D-47 T-47 "a Herdr that never answers"
assert_eq "1" "$(calls)" "a hanging herdr was really called"
assert_ok "[ $((t1 - t0)) -le 8 ]" "and given up on at the bound ($((t1 - t0))s; it sleeps 30)"
assert_contains "$ask_err" "herdr timed out after 1s" "and said to have timed out"
assert_lacks "$ask_err" "exited 142" "not reported as an exit code"
# inside Herdr with no herdr on PATH: the same
nohd="$(printf '%s\n' "$PATH" | tr ':' '\n' | while IFS= read -r p; do
  [ -n "$p" ] && [ ! -x "$p/herdr" ] && printf '%s:' "$p"; done)"
ask_err="$(env HERDR_ENV=1 PATH="${nohd%:}" FM_ROOT="$n" bash "$n/bin/fm-decide.sh" --request D-36 --task T-36 \
  --details "$d/details.json" 2>&1 >"$hstub/out")"; ask_rc=$?; ask_out="$(cat "$hstub/out")"
held "$n" D-36 T-36 "HERDR_ENV with no herdr command"
assert_contains "$ask_err" "no herdr command" "and says why no notification was raised"

# Outside Herdr everything is exactly as it was before T-096. The "before"
# is this fm-decide.sh with notify cut out, run in a twin fixture.
before="$hstub/before.sh"
sed -e '/^notify() {/,/^}/d' -e '/^[[:space:]]*notify "/d' "$ROOT/bin/fm-decide.sh" > "$before"
chmod +x "$before"
assert_eq "0" "$(grep -vE '^[[:space:]]*#' "$before" | grep -cE '(^|[^[:alnum:]_])(notify|herdr)([^[:alnum:]_]|$)')" \
  "the before-script is fm-decide.sh with notify cut out"
assert_fail "cmp -s '$before' '$ROOT/bin/fm-decide.sh'" "and so differs from it"
na="$(nfix)"; nb="$(nfix)"; cp "$before" "$na/bin/fm-decide.sh"; : > "$hlog"
for f in "$na" "$nb"; do
  env -u HERDR_ENV HERDR_LOG="$hlog" PATH="$hstub:$PATH" FM_ROOT="$f" "$f/bin/fm-decide.sh" \
    --request D-37 --task T-37 --details "$d/details.json" >"$f.out" 2>"$f.err"
  echo "$?" > "$f.rc"
done
assert_eq "0" "$(cat "$nb.rc")" "without HERDR_ENV the request exits 0"
assert_eq "$(cat "$na.rc")" "$(cat "$nb.rc")" "as it did before T-096"
assert_eq "$nb/state/pending/D-37.json" "$(cat "$nb.out")" "it prints the pending file"
assert_eq "$(sed "s|$na|F|g" "$na.out")" "$(sed "s|$nb|F|g" "$nb.out")" "as before"
assert_eq "$(sed "s|$na|F|g" "$na.err")" "$(sed "s|$nb|F|g" "$nb.err")" "and says what it said before on stderr"
assert_ok "cmp -s '$na/state/pending/D-37.json' '$nb/state/pending/D-37.json'" "it writes the card it wrote before"
assert_eq "$(jq -c 'del(.ts)' "$na/state/events.jsonl")" "$(jq -c 'del(.ts)' "$nb/state/events.jsonl")" \
  "and the event"
assert_eq "$(cd "$na" && find state board -print | sort)" "$(cd "$nb" && find state board -print | sort)" \
  "and nothing else"
assert_fail "test -e '$nb/state/runtime/notified'" "no notified directory is made at all"
assert_eq "0" "$(calls)" "and nothing calls herdr"
ask "$nb" D-39 T-39 --details "$d/details.json"
held "$nb" D-39 T-39 "the same fixture with HERDR_ENV=1"
assert_eq "1" "$(calls)" "the same fixture with HERDR_ENV=1 calls herdr"
assert_ok "test -e '$nb/state/runtime/notified/D-39'" "and writes its marker"

# Crew events are weather. Every type fm-emit.sh accepts but
# decision_requested - which only a request writes, the path above - is
# emitted through the same helper, and none rings. The spec's examples are
# among them: CI red is gate_failed, a worker blocking or crashing is
# agent_finished, worker_crashed or vendor_unavailable, a rejecting review
# is review_failed.
types="$(sed -n '/^TYPES="/,/"$/p' "$n/bin/fm-emit.sh" | tr -d '\\"' | sed 's/^TYPES=//' | tr ' ' '\n' \
  | grep -v '^decision_requested$' | grep .)"
for want in gate_failed agent_finished worker_crashed vendor_unavailable review_failed protocol_violation crew_status; do
  assert_contains " $(printf '%s ' $types)" " $want " "the weather read from fm-emit.sh holds $want"
done
: > "$hlog"; wbefore="$(grep -c . "$n/state/events.jsonl")"; wn=0
for t in $types; do
  inherdr FM_CREW_STATUS_SECS=0 FM_ROOT="$n" "$n/bin/fm-emit.sh" --actor worker-1 --type "$t" --task T-38 \
    --en x --tw x >/dev/null 2>&1
  wrc=$?
  assert_eq "0 $t" "$wrc $(tail -1 "$n/state/events.jsonl" | jq -r .type)" "weather $t is emitted and written"
  wn=$((wn + 1))
done
assert_eq "$((wbefore + wn))" "$(grep -c . "$n/state/events.jsonl")" "all $wn of them"
assert_eq "0" "$(calls)" "CI red, a blocked worker, a rejecting review and the rest notify nothing"
ask "$n" D-38 T-38 --details "$d/details.json"
held "$n" D-38 T-38 "a decision request after the weather"
assert_eq "1" "$(calls)" "while a decision request through the same helper does"
callers="$(git -C "$ROOT" grep -lE 'notification[[:space:]]+show' -- . ':!tests/' ':!design/' ':!*.md' 2>/dev/null)"
assert_eq "bin/fm-decide.sh" "$callers" \
  "no tracked file but fm-decide.sh, outside tests and prose, raises a notification"

# No other suite rings the captain. The gate runs every suite inside Herdr, so
# a suite that reaches a card with HERDR_ENV=1 inherited would call the real
# herdr for its fixture cards. The suites are what bin/ci.sh runs, read from
# its own selectors, in any language. A file raises a card if it names
# fm-decide and --request anywhere in it, in any spelling: a shell line, an
# argv array, a variable holding the path.
# Without -q: under pipefail a grep that stops at its first match can SIGPIPE
# the reader and turn a hit into a miss, and the empty-list check would pass.
code() { grep -vE '^[[:space:]]*(#|//)' "$ROOT/$1"; }
has() { code "$1" | grep -E -- "$2" >/dev/null; }
both() { grep -E -- 'fm-decide' "$ROOT/$1" >/dev/null && grep -E -- '--request' "$ROOT/$1" >/dev/null; }
names='fm-run|(^|[^A-Za-z0-9_-])fm\.sh'
# What bin/ci.sh runs: the bash suites, bun on every *.test.ts and *.spec.ts
# outside tests/e2e, playwright on its testDir, and its own stages. Each
# selector is pinned, so a new place ci.sh runs from turns this red first.
cisrc="$(code bin/ci.sh)"
assert_contains "$cisrc" 'suites=(tests/*.test.sh)' "ci.sh runs the bash suites under tests/"
assert_contains "$cisrc" "-name '*.test.ts' -o -name '*.spec.ts'" "ci.sh runs bun on every *.test.ts and *.spec.ts"
assert_contains "$cisrc" 'bunx playwright test' "ci.sh runs playwright"
assert_contains "$(code playwright.config.ts)" 'testDir: "tests/e2e"' "playwright runs tests/e2e"
suites="$(git -C "$ROOT" ls-files -- tests '*.test.ts' '*.spec.ts' 'playwright.config.*' bin/ci.sh | sort -u)"
for f in tests/decide.test.sh tests/lib.sh tests/ship.spec.ts tests/e2e/board.spec.ts tests/e2e/fixture.ts bin/ci.sh; do
  assert_contains " $(printf '%s ' $suites) " " $f " "the suites hold $f"
done
# What raises a card: every tracked file outside the suites and the prose that
# names both. Nothing else names those two outside a comment, so a suite
# reaches a card only by naming fm-decide with --request, or one of them.
raisers="$(git -C "$ROOT" ls-files -- . ':!tests/' ':!design/' ':!*.md' ':!bin/fm-decide.sh' \
  | while read -r f; do [ -f "$ROOT/$f" ] && both "$f" && printf '%s ' "$f"; done)"
assert_eq "bin/fm-run.sh bin/fm.sh " "$raisers" "fm-run.sh and fm.sh are the only files that raise a card"
# A line that is one quoted message and nothing else only prints the name: it
# tells a reader what to run (fm-config.sh's "bin/fm.sh tasks split"), it
# does not run it. Any other non-comment line naming them counts as a call.
said='^[[:space:]]*(echo|printf)[[:space:]]+"[^"]*"[[:space:]]*(>&2)?[[:space:]]*$'
runs() { code "$1" | grep -E -- "$names" | grep -vE -- "$said" | grep . >/dev/null; }
assert_fail "grep -qE -- '$said' <<<'bin/fm.sh tasks split x'" "a bare call is still a call"
assert_ok "grep -qE -- '$said' <<<'    echo \"bring it over: bin/fm.sh tasks split \$id\" >&2'" \
  "a printed message is not a call"
named="$(git -C "$ROOT" grep -lE "$names" -- . ':!tests/' ':!design/' ':!*.md' \
  ':!bin/fm-run.sh' ':!bin/fm.sh' ':!bin/fm-decide.sh' \
  | while read -r f; do has "$f" "$names" && printf '%s ' "$f"; done)"
assert_contains " $named" " bin/fm-config.sh " "the sweep sees fm-config.sh name fm.sh in its messages"
via="$(for f in $named; do runs "$f" && printf '%s ' "$f"; done)"
assert_eq "" "$via" "nothing else in the repository calls them outside a comment or a message"
direct="$(for f in $suites; do [ -f "$ROOT/$f" ] && both "$f" && printf '%s ' "$f"; done)"
assert_eq "tests/decide.test.sh " "$direct" "no suite but decide.test.sh names fm-decide with --request"
reach="$(for f in $suites; do
  [ "$f" != tests/decide.test.sh ] && [ -f "$ROOT/$f" ] && has "$f" "$names" && printf '%s\n' "$f"; done)"
assert_contains " $(printf '%s ' $reach)" " tests/e2e-loop.test.sh " "the sweep finds a suite that runs fm-run.sh"
assert_contains " $(printf '%s ' $reach)" " tests/selfupdate.test.sh " "and one that runs fm.sh self-update"
# Each suite that reaches one is held to a guard it carries, whatever its
# name: the shared loop that unsets every HERDR_* (and FM_*) before anything
# runs, HERDR_ENV=0 exported, or its own herdr first on PATH.
for f in $reach; do
  src="$(code "$f")"
  # shellcheck disable=SC2016
  if grep -qF 'HERDR_[^=]*)=' <<<"$src" && grep -qF 'unset "$_fm_k"' <<<"$src"; then
    ok=0; how="unsets every HERDR_* before it runs anything"
  elif grep -qE '^export HERDR_ENV=0' <<<"$src"; then
    ok=0; how="exports HERDR_ENV=0"
  elif grep -qE "executable\\('herdr'" <<<"$src" && grep -qF 'PATH=str(self.fake)' <<<"$src"; then
    ok=0; how="puts its own herdr first on PATH"
  else
    ok=1; how="runs a script that raises a card, with no guard against an inherited HERDR_ENV"
  fi
  assert_eq "0" "$ok" "$f $how"
done
rm -rf "$o" "$n" "$na" "$nb" "$na".* "$nb".* "$hstub"

# no dependency on a watcher that has to be installed
# the words may appear in a comment explaining the absence; a call may not
assert_fail "grep -vE '^[[:space:]]*#' '$ROOT/bin/fm-decide.sh' | grep -qE '\\b(fswatch|watchexec|entr)\\b'" \
  "it calls neither fswatch, watchexec nor entr"
rm -rf "$d" "$d2" "$d3" "$d4" "$d5" "$d6" "$d8" "$dstream" "$dctrl" "$dleg" "$stub"
finish
