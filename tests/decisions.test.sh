#!/usr/bin/env bash
# The captain answers on the board and the answer reaches firstmate. For a
# merge the board does not merge: it calls the one script that may.
set -uo pipefail
# This suite raises a card through fm-decide.sh --request (T-112), so an
# inherited HERDR_ENV would page the captain from a fixture. Same guard as
# board.test.sh: unset every FM_* and HERDR_* before anything runs.
for _fm_k in $(env | sed -E -n 's/^(FM_[^=]*|HERDR_[^=]*)=.*$/\1/p'); do
  unset "$_fm_k" || true
done
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=tests/lib.sh
. "$ROOT/tests/lib.sh"
command -v bun >/dev/null 2>&1 || { echo "    bun not installed - decisions suite skipped"; exit 0; }

d="$(mktemp -d)"; mkdir -p "$d/bin" "$d/state" "$d/design" "$d/board/public"
cp "$ROOT/bin/fm-config.sh" "$ROOT/bin/fm-herdr.py" "$ROOT/bin/fm-emit.sh" "$ROOT/bin/fm-decide.sh" "$d/bin/"
# two projects, so a card can name one that is not the default (T-047)
cat > "$d/config.yaml" <<'Y'
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
cp "$ROOT/bin/watch-decisions.ts" "$d/bin/" 2>/dev/null || true
cp "$ROOT/board/server.ts" "$d/board/"; cp "$ROOT/board/public/index.html" "$d/board/public/"
mkdir -p "$d/design/tasks"
printf '{"id":"T-A","title":"first","milestone":"M0","depends_on":[]}\n' > "$d/design/tasks/T-A.json"

# fm-merge is the only thing allowed to merge, so the test records that it ran
cat > "$d/bin/fm-merge.sh" <<'M'
#!/usr/bin/env bash
echo "$*" >> "${FM_ROOT}/state/merge-calls"
echo "fm-merge: merged"
M
chmod +x "$d/bin/fm-merge.sh"

# Explicit legacy fixture: the route must keep old pending records readable.
mkdir -p "$d/state/pending"
printf '%s\n' '{"id":"D-1","task":"T-A","kind":"merge","title":"merge it?","pr":16}' > "$d/state/pending/D-1.json"
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
FM_ROOT="$d" FM_PORT=0 bun run "$d/board/server.ts" >"$d/out" 2>&1 </dev/null &
pid=$!; trap 'kill "$pid" 2>/dev/null' EXIT
PORT="$(board_port "$d/out" "$pid")"
for _ in $(seq 1 40); do curl -sf "http://127.0.0.1:$PORT/api/state" >/dev/null 2>&1 && break; sleep 0.25; done

s="$(curl -sf "http://127.0.0.1:$PORT/api/state")"
assert_eq "D-1" "$(jq -r '.pending[0].id' <<<"$s")" "the pending decision reaches the board"
assert_eq "merge" "$(jq -r '.pending[0].kind' <<<"$s")" "with its kind"
# the heading is filled from the dictionary at runtime, so assert on the
# element the deck renders into rather than on a string that is no longer there
assert_contains "$(curl -sf "http://127.0.0.1:$PORT/")" 'id="deck"' "the page has a decision deck"

# no -f here: a rejection is a 400 with a body, and -f throws the body away
post() { curl -s -X POST "http://127.0.0.1:$PORT/decisions" -H 'content-type: application/json' -d "$1"; }
assert_contains "$(post '{"id":"nope","chosen":"A"}')" "bad decision id" "it rejects an id that is not a decision id"
assert_contains "$(post '{"id":"D-1","chosen":"rm -rf /"}')" "bad choice" "it rejects a choice that is not a letter"
assert_contains "$(post '{"id":"D-1","chosen":["A"]}')" "bad choice" "it never coerces an array into merge authorization"
assert_fail "test -f '$d/state/merge-calls'" "neither attempt reached the merge script"
# The board answers a merge at once and runs fm-merge.sh in the background
# (design 5.2), so the record says running until the helper exits. Only then
# does merge-calls hold everything it ever will.
settled() {   # settled <id>: the record's merge once it is no longer running
  local f="$d/state/decisions/$1.json" end=$(( $(date +%s) + 30 )) m=""
  while [ "$(date +%s)" -le "$end" ]; do
    m="$(jq -r '.merge // empty' "$f" 2>/dev/null)"
    [ -n "$m" ] && [ "$m" != running ] && break
    sleep 0.05
  done
  printf '%s' "$m"
}

r="$(post '{"id":"D-1","chosen":"A"}')"
assert_eq "true" "$(jq -r .ok <<<"$r")" "a valid answer is accepted"
assert_ok "test -f '$d/state/decisions/D-1.json'" "the answer lands as a file, which is what firstmate waits on"
assert_eq "A" "$(jq -r .chosen "$d/state/decisions/D-1.json")" "with the choice"
assert_eq "T-A" "$(jq -r .task "$d/state/decisions/D-1.json")" "and the task it belongs to"
assert_eq "merged" "$(settled D-1)" "the record says merged once the merge script exits"
assert_contains "$(cat "$d/state/merge-calls")" "--pr 16" "merge called the merge script with the pull request"
assert_contains "$(cat "$d/state/merge-calls")" "--task T-A" "and the task"
assert_fail "test -f '$d/state/pending/D-1.json'" "the pending decision is cleared"

# firstmate, blocked on that decision, is released by it
got="$(FM_ROOT="$d" "$d/bin/fm-decide.sh" --await D-1 --timeout 5)"
assert_eq "A" "$(jq -r .chosen <<<"$got")" "fm-decide returns what the board wrote"

# answering twice does not merge twice
before="$(wc -l < "$d/state/merge-calls" | tr -d ' ')"
post '{"id":"D-1","chosen":"A"}' >/dev/null
assert_eq "$before" "$(wc -l < "$d/state/merge-calls" | tr -d ' ')" "answering again is idempotent"

# a non-merge answer never touches the merge script
printf '%s\n' '{"id":"D-2","task":"T-A","kind":"merge","title":"again?","pr":17}' > "$d/state/pending/D-2.json"
post '{"id":"D-2","chosen":"B"}' >/dev/null
assert_fail "grep -q 'pr 17' '$d/state/merge-calls'" "sending it back does not merge"

printf '%s\n' '{"id":"D-3","task":"T-A","kind":"merge","pr":18}' > "$d/state/pending/D-3.json"
for value in '""' '"   "' 'null' '123'; do
  payload="$(jq -cn --argjson text "$value" '{id:"D-3",chosen:"custom",text:$text}')"
  response="$(post "$payload")"
  assert_contains "$response" 'invalid custom text' 'empty and non-string custom responses fail'
done
large="$(jq -cn '{id:"D-3",chosen:"custom",text:("🚢" * 1001)}')"
assert_contains "$(post "$large")" 'invalid custom text' 'Unicode code point limit enforced'
for pair in '127 007F' '133 0085' '159 009F'; do
  set -- $pair
  payload="$(jq -cn --argjson cp "$1" '{id:"D-3",chosen:"custom",text:("captain" + ([$cp]|implode) + "order")}')"
  assert_contains "$(post "$payload")" 'invalid custom text' "Unicode control U+$2 is rejected"
done
assert_fail "test -f '$d/state/decisions/D-3.json'" 'invalid custom responses leave no record'
literal='  船長 🚢 <script>oops()</script> $(touch forbidden)  '
r="$(post "$(jq -cn --arg text "$literal" '{id:"D-3",chosen:"custom",text:$text}')")"
assert_eq 'true' "$(jq -r .ok <<<"$r")" 'literal custom response accepted'
got="$(FM_ROOT="$d" "$d/bin/fm-decide.sh" --await D-3 --timeout 5)"
assert_eq 'custom' "$(jq -r .chosen <<<"$got")" 'watch returns distinct custom semantics'
assert_eq "$literal" "$(jq -r .text <<<"$got")" 'watch preserves literal response'
state_text="$(curl -sf "http://127.0.0.1:$PORT/api/state" | jq -r '.responses[]|select(.id=="D-3")|.text')"
assert_eq "$literal" "$state_text" 'state roundtrip preserves literal response'
assert_fail "grep -q 'pr 18' '$d/state/merge-calls'" 'custom never authorizes merge'
assert_eq '3' "$(jq -s 'map(select(.type=="decision_made"))|length' "$d/state/events.jsonl")" 'one event per decision, none from await or duplicate'
assert_contains "$(post '{"id":"D-3","chosen":"A"}')" 'already recorded differently' 'conflicting repeat is truthful'
assert_contains "$(post '{"id":"D-404","chosen":"A"}')" 'no pending decision' 'unknown decision cannot be invented'

# --- T-047: a card whose id names its owner ------------------------------
# listed with the project and task parsed out of its id, answered, and for a
# merge handed to fm-merge.sh with the card's project
nid=D-example-app-T004-1
printf '{"id":"%s","task":"T-004","project":"example-app","kind":"merge","title":"merge app","pr":7}\n' "$nid" \
  > "$d/state/pending/$nid.json"
printf '%s\n' '{"id":"D-9","task":"T-A","kind":"choice"}' > "$d/state/pending/D-9.json"
s="$(curl -sf "http://127.0.0.1:$PORT/api/state")"
assert_eq "$nid" "$(jq -r --arg i "$nid" '.pending[]|select(.id==$i)|.id' <<<"$s")" "a new-form card is listed"
assert_eq "example-app T-004 1" \
  "$(jq -r --arg i "$nid" '.pending[]|select(.id==$i)|.owner|"\(.project) \(.task) \(.n)"' <<<"$s")" \
  "with the project, task and n parsed out of its id"
assert_eq "null" "$(jq -r '.pending[]|select(.id=="D-9")|.owner' <<<"$s")" "an old id names no owner"
rm -f "$d/state/pending/D-9.json"
# bodies are built by jq, never as "{\"a\":1,\"b\":2}" inside "$(...)": bash
# 3.2 brace-expands that {a,b} and runs the substitution once per half
answer() { jq -cn --arg i "$1" --arg c "$2" '{id:$i,chosen:$c}'; }
r="$(post "$(answer "$nid" A)")"
assert_eq "true" "$(jq -r .ok <<<"$r")" "a new-form card is answered"
assert_ok "test -f '$d/state/decisions/$nid.json'" "its answer lands under its own id"
assert_eq "merged" "$(settled "$nid")" "its record says merged once the merge script exits"
assert_contains "$(tail -1 "$d/state/merge-calls")" "--pr 7" "a merge answer calls the merge script"
assert_contains "$(tail -1 "$d/state/merge-calls")" "--project example-app" "with the card's project"
assert_eq "example-app" \
  "$(jq -r --arg i "$nid" 'select(.type=="decision_made" and .data.decision==$i)|.project' "$d/state/events.jsonl")" \
  "and its decision_made event names the project"
assert_eq "$nid" "$(curl -sf "http://127.0.0.1:$PORT/api/state" | jq -r --arg i "$nid" '.responses[]|select(.id==$i)|.id')" \
  "the answered new-form card is read back among the responses"
assert_lacks "$(grep -F -- '--pr 16' "$d/state/merge-calls")" "--project" \
  "an old card with no project merges with no --project, as before"
# a tree with no registry names its cards by the self project but records no
# project on them; the id's owner is not a registry name there, so a merge
# answer passes none, exactly as an old card does
sid=D-firstmate-workflow-T005-1
printf '{"id":"%s","task":"T-005","kind":"merge","title":"merge self","pr":17}\n' "$sid" \
  > "$d/state/pending/$sid.json"
assert_eq "true" "$(post "$(answer "$sid" A)" | jq -r .ok)" "a new-form card with no project is answered"
assert_eq "merged" "$(settled "$sid")" "its record says merged once the merge script exits"
assert_contains "$(tail -1 "$d/state/merge-calls")" "--pr 17" "and its merge is called"
assert_lacks "$(tail -1 "$d/state/merge-calls")" "--project" \
  "with no --project read out of its id"
# A card is settled by its own project's merge only. example-app merging its
# #21 for its T-021 leaves the engine's card for #21 up; the engine's own
# merge, written with no project and so the default's, takes it down.
kid=D-firstmate-workflow-T021-1
printf '{"id":"%s","task":"T-021","project":"firstmate-workflow","kind":"merge","title":"merge 21","pr":21}\n' "$kid" \
  > "$d/state/pending/$kid.json"
FM_ROOT="$d" bash "$d/bin/fm-emit.sh" --actor github --type merged --task T-021 --pr 21 --project example-app \
  --en "#21 merged" --tw "#21 已合併" >/dev/null 2>&1
assert_eq "$kid" "$(curl -sf "http://127.0.0.1:$PORT/api/state" | jq -r --arg i "$kid" '.pending[]|select(.id==$i)|.id')" \
  "another project's merge of the same number and task does not settle the card"
FM_ROOT="$d" bash "$d/bin/fm-emit.sh" --actor github --type merged --task T-021 --pr 21 \
  --en "#21 merged" --tw "#21 已合併" >/dev/null 2>&1
assert_eq "" "$(curl -sf "http://127.0.0.1:$PORT/api/state" | jq -r --arg i "$kid" '.pending[]|select(.id==$i)|.id')" \
  "its own project's merge does"
rm -f "$d/state/pending/$kid.json"
for badid in D-Bad_Name-T047-1 D-firstmate-workflow-1 D-firstmate-workflow-T047-0 'D-../x-T047-1' 'D-a/b-T047-1'; do
  assert_contains "$(post "$(jq -cn --arg i "$badid" '{id:$i,chosen:"A"}')")" "bad decision id" \
    "the route refuses a malformed id: $badid"
done
# the stored answer carries the card's project; a card naming none stores none
assert_eq "example-app" "$(jq -r .project "$d/state/decisions/$nid.json")" "the stored answer names the card's project"
assert_eq "false" "$(jq 'has("project")' "$d/state/decisions/$sid.json")" "an answer to a card naming no project stores none"
# The response listing reads only files named by a decision id, either form. A
# file on disk under a malformed name is not an answer, whatever it holds.
for badid in D-Bad_Name-T047-1 D-firstmate-workflow-T047-0 D-firstmate-workflow-T047-01 \
             D-firstmate-workflow-1 D-firstmate-workflow-T-047-1 D-x.y-T047-1 D-1234567 notes; do
  printf '{"id":"%s","chosen":"A"}\n' "$badid" > "$d/state/decisions/$badid.json"
done
listed="$(curl -sf "http://127.0.0.1:$PORT/api/state" | jq -r '[.responses[].id]|sort|join(" ")')"
for badid in D-Bad_Name-T047-1 D-firstmate-workflow-T047-0 D-firstmate-workflow-T047-01 \
             D-firstmate-workflow-1 D-firstmate-workflow-T-047-1 D-x.y-T047-1 D-1234567 notes; do
  assert_lacks " $listed " " $badid " "the response listing skips a file named $badid"
  rm -f "$d/state/decisions/$badid.json"
done
assert_contains " $listed " " $nid " "while it still lists the owned answer"
assert_contains " $listed " " D-3 " "and an old one"
# an owner is read only out of a well-formed id
printf '{"id":"D-Bad_Name-T047-1","task":"T-047","kind":"choice"}\n' > "$d/state/pending/D-Bad_Name-T047-1.json"
assert_eq "null" "$(curl -sf "http://127.0.0.1:$PORT/api/state" | jq -r '.pending[]|select(.id=="D-Bad_Name-T047-1")|.owner')" \
  "a malformed id names no owner"
rm -f "$d/state/pending/D-Bad_Name-T047-1.json"

# --- T-112: a skill-update card -------------------------------------------
# fm.sh self-update raises D-SK-<n>, which fm-decide.sh and fm-ready.sh take
# with ^D-SK-[0-9]{3,}$. The board answers it through the same route, and the
# answer is read back by fm-decide.sh --await like any other.
FM_ROOT="$d" "$d/bin/fm-decide.sh" --request D-SK-001 --task SK-001 --kind choice --title "adopt SK-001" >/dev/null 2>&1
assert_ok "test -f '$d/state/pending/D-SK-001.json'" "fm-decide.sh raises the skill-update card"
r="$(post "$(answer D-SK-001 A)")"
assert_eq "true" "$(jq -r .ok <<<"$r")" "the board answers a skill-update card"
got="$(FM_ROOT="$d" "$d/bin/fm-decide.sh" --await D-SK-001 --timeout 5)"
assert_eq "A SK-001 choice" "$(jq -r '"\(.chosen) \(.task) \(.kind)"' <<<"$got")" \
  "fm-decide.sh --await reads the board's answer to it"
assert_eq "A" "$(curl -sf "http://127.0.0.1:$PORT/api/state" | jq -r '.responses[]|select(.id=="D-SK-001")|.chosen')" \
  "and the answer is read back among the responses"
for badid in D-SK-01 D-SK-1a D-sk-001 D-SK- D-SK-001-1; do
  assert_contains "$(post "$(answer "$badid" A)")" "bad decision id" "the route still refuses $badid"
done

# --- T-119: a card merges only as what it is -------------------------------
# An untracked merge card (a revert, a hotfix: fm-decide.sh --kind
# merge-untracked) hands the merge script --untracked and no task, even when
# its file carries one; a skill update's owned merge card is answered like
# any task's and hands its SK task; a task's card never hands a task the
# grammar does not hold.
printf '%s\n' '{"id":"D-1096","kind":"merge-untracked","title":"merge the revert","pr":96}' > "$d/state/pending/D-1096.json"
assert_eq "true" "$(post "$(answer D-1096 A)" | jq -r .ok)" "an untracked merge card is answered"
assert_eq "merged" "$(settled D-1096)" "and its merge is run"
assert_contains "$(tail -1 "$d/state/merge-calls")" "--pr 96 --untracked" "with --untracked"
assert_lacks "$(tail -1 "$d/state/merge-calls")" "--task" "and no task"
assert_eq "merge-untracked null" "$(jq -r '"\(.kind) \(.task)"' "$d/state/decisions/D-1096.json")" \
  "the record keeps its kind and names no task"
printf '%s\n' '{"id":"D-1099","task":"T-A","kind":"merge-untracked","title":"merge a hotfix","pr":99}' > "$d/state/pending/D-1099.json"
post "$(answer D-1099 A)" >/dev/null
assert_eq "merged" "$(settled D-1099)" "an untracked card whose file names a task is merged"
assert_contains "$(tail -1 "$d/state/merge-calls")" "--pr 99 --untracked" "as untracked"
assert_lacks "$(tail -1 "$d/state/merge-calls")" "--task" "handing the merge script no task"
skid='D-firstmate-workflow-SK001-1'
printf '{"id":"%s","task":"SK-001","kind":"merge","title":"merge SK-001","pr":94}\n' "$skid" > "$d/state/pending/$skid.json"
s="$(curl -sf "http://127.0.0.1:$PORT/api/state")"
assert_eq "true firstmate-workflow SK-001 1" \
  "$(jq -r --arg i "$skid" '.pending[]|select(.id==$i)|"\(.answerable) \(.owner.project) \(.owner.task) \(.owner.n)"' <<<"$s")" \
  "a skill update's owned merge card is answerable, its owner read out of its id"
post "$(answer "$skid" A)" >/dev/null
assert_eq "merged" "$(settled "$skid")" "and its merge is run"
assert_contains "$(tail -1 "$d/state/merge-calls")" "--pr 94 --task SK-001" "for SK-001"
printf '%s\n' '{"id":"D-1100","task":"revert of T-105","kind":"merge","title":"merge?","pr":100}' > "$d/state/pending/D-1100.json"
assert_contains "$(post "$(answer D-1100 A)")" "names a task id" "a merge card whose task is no task id is refused"
assert_fail "test -e '$d/state/decisions/D-1100.json'" "and nothing is recorded"
assert_fail "grep -q -- '--pr 100' '$d/state/merge-calls'" "or merged"
rm -f "$d/state/pending/D-1100.json"

printf '%s\n' '{"id":"D-4","task":"T-A","kind":"choice"}' > "$d/state/pending/D-4.json"
assert_eq 'true' "$(post "$(jq -cn '{id:"D-4",chosen:"custom",text:("🚢" * 1000)}')" | jq -r .ok)" '1000 Unicode code points accepted'

printf '%s\n' '{"id":"D-5","task":"T-A","kind":"choice"}' > "$d/state/pending/D-5.json"
printf '#!/usr/bin/env bash\nexit 1\n' > "$d/bin/fm-emit.sh"
r="$(post '{"id":"D-5","chosen":"C"}')"
assert_eq 'true' "$(jq -r .ok <<<"$r")" 'event failure cannot hide a recorded decision'
assert_eq 'false' "$(jq -r .eventRecorded <<<"$r")" 'event failure is disclosed'
assert_eq 'decision:D-5' "$(jq -r .decision.identity <<<"$r")" 'recording has an observable stable identity without an awaiter'

kill "$pid" 2>/dev/null; wait "$pid" 2>/dev/null || true
rm -rf "$d"
finish
