#!/usr/bin/env bash
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=tests/lib/project-storage.sh
. "$ROOT/tests/lib/project-storage.sh"
# shellcheck source=tests/lib/board.sh
. "$ROOT/tests/lib/board.sh"
export HERDR_ENV=0
XDG_CONFIG_HOME="$(safe_tmpdir)"; export XDG_CONFIG_HOME
# --- T-040: layout parity data ---------------------------------------------
# Its own fixture again: the engine badge reads config.yaml, which the other
# two fixtures do not have, and the merge refusal needs a helper that says no.
e="$(safe_tmpdir)"; mkdir -p "$e/bin" "$e/state/pending" "$e/design" "$e/board/public"
cp "$ROOT/bin/fm-emit.sh" "$ROOT/bin/fm-config.sh" "$ROOT/bin/fm-ready.sh" "$e/bin/"; project_storage_fixture "$e/bin/"
cp -R "$ROOT/bin/lib" "$e/bin/"   # the lifeline the board starts merges and rounds under (T-151)
mkdir -p "$e/i18n"; cp "$ROOT/i18n/glossary.json" "$e/i18n/"   # the glossary fm-decide reads (T-270)
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

# T-192: resolve the rule from the recorded host, without any running crew.
assert_eq "0" "$(jq '[.crew[] | select(.role != "firstmate")]|length' <<<"$(st)")" "rule fixture has no running crew"
printf 'vendor: opposite-of-host\nfallback:\n  - vendor-first\n  - vendor-second\n' > "$e/config.yaml"
mkdir -p "$e/state/session"
printf '{"harness":"claude"}\n' > "$e/state/session/host.json"
assert_eq "codex opposite-of-host claude null false" "$(jq -r '.engine|"\(.vendor) \(.rule) \(.host) \(.reviewer) \(.cross)"' <<<"$(st)")" "Claude host resolves to Codex and retains absent reviewer semantics"
printf '{"harness":"codex"}\n' > "$e/state/session/host.json"
assert_eq "claude" "$(jq -r '.engine.vendor' <<<"$(st)")" "Codex host resolves to Claude on the next request"
printf '{"harness":"other-host"}\n' > "$e/state/session/host.json"
assert_eq "vendor-first other-host" "$(jq -r '.engine|"\(.vendor) \(.host)"' <<<"$(st)")" "unknown host uses the first configured fallback"
rm "$e/state/session/host.json"
assert_eq "vendor-first null" "$(jq -r '.engine|"\(.vendor) \(.host)"' <<<"$(st)")" "missing host uses the first configured fallback"
printf 'vendor: opposite-of-host\n' > "$e/config.yaml"
assert_eq "mock" "$(jq -r '.engine.vendor' <<<"$(st)")" "missing host and fallback resolve to mock"
printf '{"harness":"claude"}\n' > "$e/state/session/host.json"
printf 'vendor: claude\nreviewer:\n  vendor: opposite-of-host\n' > "$e/config.yaml"
assert_eq "claude codex true null opposite-of-host" "$(jq -r '.engine|"\(.vendor) \(.reviewer) \(.cross) \(.rule) \(.reviewer_rule)"' <<<"$(st)")" "reviewer rule resolves before comparing vendors"
printf 'vendor: opposite-of-host\nreviewer:\n  vendor: opposite-of-host\n' > "$e/config.yaml"
assert_eq "codex codex false" "$(jq -r '.engine|"\(.vendor) \(.reviewer) \(.cross)"' <<<"$(st)")" "two rules resolving to the same vendor are not cross-vendor"

# A default external project uses its own session ahead of the engine session.
rule_home="$(safe_tmpdir)"
cat > "$e/config.yaml" <<Y
home: $rule_home
vendor: opposite-of-host
default_project: rule-project
projects:
  rule-project:
    github: fixture/rule-project
    base: main
    required_check: ci
Y
if ! rule_state="$(project_fixture_state "$e" rule-project)" || [[ -z "$rule_state" ]]; then
  echo "FAIL: rule-project fixture could not resolve a nonempty project state path" >&2
  exit 1
fi
mkdir -p "$rule_state/session"
printf '{"harness":"codex"}\n' > "$rule_state/session/host.json"
rule_project_state="$(st)"
assert_eq "rule-project" "$(jq -r '.default_project' <<<"$rule_project_state")" "project host precedence resolves the registered project"
assert_eq "claude codex" "$(jq -r '.engine|"\(.vendor) \(.host)"' <<<"$rule_project_state")" "project host wins over the engine host"
rm "$rule_state/session/host.json"
rule_project_state="$(st)"
assert_eq "rule-project" "$(jq -r '.default_project' <<<"$rule_project_state")" "engine host fallback resolves the registered project"
assert_eq "codex claude" "$(jq -r '.engine|"\(.vendor) \(.host)"' <<<"$rule_project_state")" "absent project host falls back to the engine record"
printf 'vendor: vendor-delta\n' > "$e/config.yaml"
rm "$e/state/session/host.json"
safe_rm_rf "$rule_home"

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
FM_EMIT_LEGACY_GATE=1 FM_ROOT="$e" "$e/bin/fm-emit.sh" --actor worker-e --task T-E4 --type gate_failed \
  --data '{"gate":5}' --en "gate 4" --tw "第 4 道" >/dev/null
FM_ROOT="$e" "$e/bin/fm-emit.sh" --actor worker-e --task T-E4 --type ask_pass_criteria \
  --en "asked" --tw "已詢問" >/dev/null
sb1="$(st)"
assert_eq '{"n":4,"name":"fail-first"}' "$(jq -c '.tasks[]|select(.id=="T-E4")|.badges[]|select(.kind=="gate")|.gate' <<<"$sb1")" \
  "the failing gate's number comes from the event"
assert_eq "1" "$(jq -r '[.tasks[]|select(.id=="T-E4")|.badges[]|select(.kind=="ask")]|length' <<<"$sb1")" \
  "an open ASK-PASS-CRITERIA is a badge"
FM_ROOT="$e" "$e/bin/fm-emit.sh" --actor worker-e --task T-E4 --type criteria_returned \
  --en "listed" --tw "已列出" >/dev/null
FM_EMIT_LEGACY_GATE=1 FM_ROOT="$e" "$e/bin/fm-emit.sh" --actor worker-e --task T-E4 --type gate_failed \
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
wcurl "$PORTE" -sf -X POST -H 'content-type: application/json' -d '{"id":"D-401","chosen":"A"}' \
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
cp "$ROOT/bin/fm-decide.sh" "$ROOT/bin/fm-config.sh" "$ROOT/bin/fm-herdr.py" "$e/bin/"; project_storage_fixture "$e/bin/"
card4() {   # card4 <id> <task> <option keys, e.g. ABCD>: raise a choice card through fm-decide.sh
  jq -n --arg keys "$3" '
    ($keys | split("") | map({key: ., value: {description: ("do " + .), pros: "p", cons: "c"}})
      | from_entries) as $o
    | {title: "judge", explanation: "e", before: "b", after: "a", outcome: "o", options: $o,
       why: [{kind: "fact", text: "e"}], how: [{kind: "fact", text: "a"}], glossary: []} as $l
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
code="$(wcurl "$PORTE" -s -o "$e/post" -w '%{http_code}' -X POST -H 'content-type: application/json' \
  -d '{"id":"D-407","chosen":"D"}' "http://127.0.0.1:$PORTE/decisions")"
assert_eq "400" "$code" "D on a card that offers A to C is refused"
assert_fail "test -e '$e/state/decisions/D-407.json'" "and nothing is recorded"
rm -f "$e/state/pending/D-407.json"
code="$(wcurl "$PORTE" -s -o "$e/post" -w '%{http_code}' -X POST -H 'content-type: application/json' \
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
code="$(wcurl "$PORTE" -s -o "$e/post" -w '%{http_code}' -X POST -H 'content-type: application/json' \
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
// tipAttr is the read-only tooltip (T-145): nothing in a tab that can write,
// the reason as a title in one that cannot
const render = new Function("d", "content", "pick", "locked", "esc", "words", "t", "said", "tipAttr", "return " + expr);
const opts = (keys) => Object.fromEntries(keys.map(k => [k, { description: "do " + k, pros: "p", cons: "c" }]));
const card = (keys) => ({ id: "D-1", kind: "choice", details: { en: { options: opts(keys) } } });
const out = (keys, locked = false) => render(card(keys), { options: opts(keys) }, undefined, locked, String, String, String, String,
  locked ? () => " title=\"readOnlyTip\"" : () => "");
const four = out(["A", "B", "C", "D"]), three = out(["A", "B", "C"]);
if (!/data-c="D"[^>]*>D · do D</.test(four)) { console.log("FAIL no D button: " + four); process.exit(1); }
if (/data-c="D"/.test(three)) { console.log("FAIL invented D"); process.exit(1); }
// a card that is answered, or in a tab that cannot write (T-122), is drawn
// with every option disabled; one that can still be answered with none
if (/disabled/.test(four)) { console.log("FAIL an open card is disabled: " + four); process.exit(1); }
const shut = out(["A", "B", "C", "D"], true);
if ((shut.match(/<button[^>]*\sdisabled title="readOnlyTip">/g) || []).length !== 4) { console.log("FAIL a locked card still takes a choice: " + shut); process.exit(1); }
console.log("ok");
')"
assert_eq "ok" "$dbtn" "the page shows a D button on a card that offers D, and only there, and disables every option on a card that is locked"

kill "$pide" 2>/dev/null
wait "$pide" 2>/dev/null || true
rm -rf "$e"


safe_rm_rf "$XDG_CONFIG_HOME"
finish
