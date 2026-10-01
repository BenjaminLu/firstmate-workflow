#!/usr/bin/env bash
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=tests/lib/board.sh
. "$ROOT/tests/lib/board.sh"
XDG_CONFIG_HOME="$(safe_tmpdir)"; export XDG_CONFIG_HOME
# --- T-116: each crew member's fields, separately ---------------------------
# The server reads name, project, round and attempt from the identity a run
# sends (data.identity) and never parses them out of the actor; a run from
# before them still renders, its name read from its old actor once and its
# round unknown, since that actor's r<n> was the global run counter.
q="$(safe_tmpdir)"; mkdir -p "$q/bin" "$q/state" "$q/design" "$q/board/public"
cp "$ROOT/bin/fm-emit.sh" "$ROOT/bin/fm-config.sh" "$q/bin/"
cp -R "$ROOT/bin/lib" "$q/bin/"   # the lifeline the board starts merges and rounds under (T-151)
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
    identity:{name:"shira",role:"worker",project:null,task:"T-Q1",round:3,attempt:2,
      vendor:"claude",model_requested:"claude-opus-5-5",model:"claude-sonnet-5",
      cli_version:"2.1.0",model_mismatch:true}}')" --en "on it" --tw "接下"
emq --actor reviewer-quinn-tq1-r3 --task T-Q1 --type review_opened \
  --data "$(jq -cn '{role:"reviewer",crew_name:"reviewer-quinn-tq1-r3",
    identity:{name:"quinn",role:"reviewer",project:null,task:"T-Q1",round:3,attempt:1,
      vendor:"claude",model_requested:"claude-opus-5-5",model:"claude-opus-5-5",
      cli_version:"2.1.0",model_mismatch:false}}')" --en "round 3" --tw "第 3 輪"
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
# T-127: vendor, model, model_requested, cli_version and model_mismatch reach
# the board as separate fields too, read from the run's own identity
assert_eq 'claude claude-opus-5-5 claude-sonnet-5 2.1.0 true' \
  "$(jq -r '.crew[]|select(.id=="worker-shira-tq1-r3b")|"\(.vendor) \(.model_requested) \(.model) \(.cli_version) \(.model_mismatch)"' <<<"$sq")" \
  "a run's vendor, requested model, actual model, CLI version and mismatch flag are separate fields"
assert_eq 'null null null null false' \
  "$(jq -r '.crew[]|select(.id=="worker-mira-tq2-r465")|"\(.vendor) \(.model_requested) \(.model) \(.cli_version) \(.model_mismatch)"' <<<"$sq")" \
  "a run recorded before T-127 shows them as unknown, never guessed"
# the header's engine badge shows the vendors actually aboard: two claude
# crewmen (shira and quinn), grouped into one count
assert_eq '[{"vendor":"claude","count":2}]' "$(jq -c '.engineLive' <<<"$sq")" \
  "the engine badge counts the vendors actually running now"
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
      vendor: "claude", model: "claude-sonnet-5", model_requested: "claude-opus-5-5",
      cli_version: "2.1.0", model_mismatch: true,
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
  cstate: ["crewState", "laneWorking"], job: ["crewActivity", "Writing the roster"],
  cvendor: ["crewVendor", "claude"], ccli: ["crewCli", "2.1.0"] };
for (const [cls, [label, value]] of Object.entries(want)) {
  const [dt, body] = dd(cls);
  if (dt !== label) fail(`card line ${cls} is labelled ${dt}`);
  if ((body || "").replace(/<[^>]*>/g, "").trim() !== value) fail(`card line ${cls} says [${body}]`);
}
// T-127: a model other than the one requested is the warning class, naming both
const modelLine = (card.match(/<dt>crewModel<\/dt><dd class="cmodel warn">([\s\S]*?)<\/dd>/) || [])[1];
if ((modelLine || "").trim() !== "modelMismatch") fail(`card model line is [${modelLine}]`);
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
  for (const row of rows.slice(1)) for (const cls of ["nm", "rl", "pj", "rv", "rd", "st", "rpr", "jb"])
    if (!row.includes(`class="${cls}"`)) fail(`roster row lacks its ${cls} cell`);
  // rm is checked apart: a mismatched model carries an extra "warn" class
  for (const row of rows.slice(1)) if (!/class="rm( warn)?"/.test(row)) fail("roster row lacks its rm cell");
  const pj = rows.slice(1).map((row) => (row.match(/<span class="pj"[^>]*>([\s\S]*?)<\/span>/) || [])[1].replace(/<[^>]*>/g, ""));
  if (pj.join() !== [projects[0], projects[projects.length - 1]].join()) fail("project column says " + pj.join());
  // T-127: the roster own vendor and model columns, sortable and groupable
  // like the others; the model of shira is the warning class since it mismatches
  if (!/<div class="rhead"[\s\S]*data-sort="vendor"/.test(r.innerHTML)) fail("no vendor column header");
  if (!/<div class="rhead"[\s\S]*data-sort="model"/.test(r.innerHTML)) fail("no model column header");
  if (!(rows[1].match(/<span class="rv"[^>]*>([\s\S]*?)<\/span>/) || [])[1]?.includes("claude"))
    fail("roster vendor cell for shira: " + rows[1]);
  const rmCell = rows[1].match(/<span class="rm warn"[^>]*>([\s\S]*?)<\/span>/);
  if (!rmCell) fail("roster model cell for shira is not the warning class: " + rows[1]);
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

# --- T-146: the board keeps the last known value of each identity field ----
# On 2026-09-29 every crewman's vendor, model and CLI were blank: the board
# read a crewman from its latest event, a crew_status whose data.identity had
# T-116's six fields only. An event without a field, or with the "unknown" a
# silent vendor is recorded as, keeps what an earlier event said; a live
# round shows the model it asked for until the vendor reports one.
qk="$(safe_tmpdir)"; mkdir -p "$qk/bin" "$qk/state" "$qk/design" "$qk/board/public"
cp "$ROOT/bin/fm-emit.sh" "$ROOT/bin/fm-config.sh" "$qk/bin/"
cp "$ROOT/board/server.ts" "$qk/board/"
cp "$ROOT/board/public/index.html" "$ROOT/board/public/ship.js" "$qk/board/public/"
fm_tasks_write /dev/stdin "$qk/design/tasks" <<'J'
{"tasks":[{"id":"T-K1","title":"a reported model","milestone":"M2","depends_on":[]},
          {"id":"T-K2","title":"a model asked for","milestone":"M2","depends_on":[]}]}
J
emk() { FM_ROOT="$qk" "$qk/bin/fm-emit.sh" "$@" >/dev/null; }
six() { jq -cn --arg n "$1" --arg t "$2" '{name:$n,role:"worker",project:null,task:$t,round:1,attempt:1}'; }
emk --actor captain --type greenlit --en "go" --tw "開工"
emk --actor worker-kai-tk1-r1 --task T-K1 --type dispatched \
  --data "$(jq -cn --argjson i "$(six kai T-K1)" '{role:"worker",identity:($i + {vendor:"claude",
    model_requested:"claude-opus-5-5",model:"claude-opus-5-5",cli_version:"2.1.0",model_mismatch:false})}')" \
  --en "on it" --tw "接下"
# the crew_status that blanked the board: T-116's six fields and nothing else
emk --actor worker-kai-tk1-r1 --task T-K1 --type crew_status \
  --data "$(jq -cn --argjson i "$(six kai T-K1)" '{role:"worker",identity:$i,activity:{en:"still",
    "zh-TW":"仍在"}}')" --en "still" --tw "仍在"
# and one that says unknown where it knew nothing
emk --actor worker-kai-tk1-r1 --task T-K1 --type crew_status \
  --data "$(jq -cn --argjson i "$(six kai T-K1)" '{role:"worker",identity:($i + {vendor:"claude",
    model:"unknown",cli_version:"unknown",model_mismatch:null}),activity:{en:"still",
    "zh-TW":"仍在"}}')" --en "still" --tw "仍在"
# a live round from its start: the vendor it is on and the model it asked for
emk --actor worker-lin-tk2-r1 --task T-K2 --type dispatched \
  --data "$(jq -cn --argjson i "$(six lin T-K2)" '{role:"worker",identity:($i + {vendor:"codex",
    model_requested:"gpt-6-astra",model:null,cli_version:null,model_mismatch:null})}')" \
  --en "on it" --tw "接下"
FM_ROOT="$qk" FM_PORT=0 bun run "$qk/board/server.ts" > "$qk/out" 2>&1 < /dev/null &
pidk=$!
PORTK="$(board_port "$qk/out" "$pidk")"
for _ in $(seq 1 40); do curl -sf "http://127.0.0.1:$PORTK/api/state" >/dev/null 2>&1 && break; sleep 0.25; done
sk="$(curl -sf "http://127.0.0.1:$PORTK/api/state")"
assert_eq 'claude claude-opus-5-5 claude-opus-5-5 2.1.0 false reported' \
  "$(jq -r '.crew[]|select(.id=="worker-kai-tk1-r1")|"\(.vendor) \(.model_requested) \(.model) \(.cli_version) \(.model_mismatch) \(.model_source)"' <<<"$sk")" \
  "a crew_status without the fields, or saying unknown, never blanks what an earlier event said"
assert_eq 'codex gpt-6-astra gpt-6-astra requested' \
  "$(jq -r '.crew[]|select(.id=="worker-lin-tk2-r1")|"\(.vendor) \(.model_requested) \(.model) \(.model_source)"' <<<"$sk")" \
  "a live round shows its vendor, and the model it asked for until the vendor reports one"
assert_eq '[{"vendor":"claude","count":1},{"vendor":"codex","count":1}]' "$(jq -c '.engineLive' <<<"$sk")" \
  "so the engine badge counts a round's vendor from its start"
kill "$pidk" 2>/dev/null; wait "$pidk" 2>/dev/null || true
rm -rf "$qk"

# --- T-146: a change of vendor resets what belongs to the vendor ------------
# The last known value holds within one vendor only. When a fallback starts,
# record_requested clears model, cli_version and model_mismatch and names the
# new vendor's model_requested ("" for a vendor config names none for), and
# fm_crew_identity sends them as null: the board must take them as cleared,
# never keep the vendor before's. record-model's "unknown" vendor (every
# vendor unavailable) is such a change too. One actor per step of one round,
# each carrying the events up to that step, as fm_crew_identity sends them.
qv="$(safe_tmpdir)"; mkdir -p "$qv/bin" "$qv/state" "$qv/design" "$qv/board/public"
cp "$ROOT/bin/fm-emit.sh" "$ROOT/bin/fm-config.sh" "$qv/bin/"
cp "$ROOT/board/server.ts" "$qv/board/"
cp "$ROOT/board/public/index.html" "$ROOT/board/public/ship.js" "$qv/board/public/"
fm_tasks_write /dev/stdin "$qv/design/tasks" <<'J'
{"tasks":[{"id":"T-V1","title":"claude then codex","milestone":"M2","depends_on":[]},
          {"id":"T-V2","title":"then an unmodelled vendor","milestone":"M2","depends_on":[]},
          {"id":"T-V3","title":"then a bare status","milestone":"M2","depends_on":[]},
          {"id":"T-V4","title":"then no vendor at all","milestone":"M2","depends_on":[]}]}
J
emv() { FM_ROOT="$qv" "$qv/bin/fm-emit.sh" "$@" >/dev/null; }
# <actor> <task> <type> <identity beyond the six, as jq>
# The program is single-quoted and the extra identity passed as --argjson:
# bash 3.2 brace-expands a {a,b} inside "$(...)" that only escaped quotes protect.
said() {
  local six prog data
  six="$(jq -cn --arg t "$2" '{name:"vic",role:"worker",project:null,task:$t,round:1,attempt:1}')"
  prog='{role:"worker",identity:($i + $x),activity:{en:"on","zh-TW":"進行"}}'
  data="$(jq -cn --argjson i "$six" --argjson x "$(jq -cn "$4")" "$prog")"
  emv --actor "$1" --task "$2" --type "$3" --data "$data" --en "on" --tw "進行"
}
claude_ran='{vendor:"claude",model_requested:"claude-opus-5-5",model:"claude-opus-5-5",cli_version:"2.1.0",model_mismatch:false}'
codex_starts='{vendor:"codex",model_requested:"gpt-6-astra",model:null,cli_version:null,model_mismatch:null}'
cursor_starts='{vendor:"cursor-agent",model_requested:"",model:null,cli_version:null,model_mismatch:null}'
none_ran='{vendor:"unknown",model_requested:"",model:"unknown",cli_version:"unknown",model_mismatch:false}'
emv --actor captain --type greenlit --en "go" --tw "開工"
for n in 1 2 3 4; do
  a="worker-vic-tv$n-r1"
  said "$a" "T-V$n" dispatched "$claude_ran"
  said "$a" "T-V$n" crew_status "$codex_starts"
  [ "$n" -ge 2 ] && said "$a" "T-V$n" crew_status "$cursor_starts"
  [ "$n" -ge 3 ] && said "$a" "T-V$n" crew_status '{}'
  [ "$n" -ge 4 ] && said "$a" "T-V$n" crew_status "$none_ran"
done
FM_ROOT="$qv" FM_PORT=0 bun run "$qv/board/server.ts" > "$qv/out" 2>&1 < /dev/null &
pidv=$!
PORTV="$(board_port "$qv/out" "$pidv")"
for _ in $(seq 1 40); do curl -sf "http://127.0.0.1:$PORTV/api/state" >/dev/null 2>&1 && break; sleep 0.25; done
sv="$(curl -sf "http://127.0.0.1:$PORTV/api/state")"
card() { jq -c --arg a "$1" '.crew[]|select(.id==$a)|{vendor,model_requested,model,model_source,cli_version,model_mismatch}' <<<"$sv"; }
assert_eq '{"vendor":"codex","model_requested":"gpt-6-astra","model":"gpt-6-astra","model_source":"requested","cli_version":null,"model_mismatch":false}' \
  "$(card worker-vic-tv1-r1)" \
  "(a) claude reported, then a codex start: codex asking for gpt-6-astra, never claude's model or CLI version"
assert_eq '{"vendor":"cursor-agent","model_requested":null,"model":null,"model_source":null,"cli_version":null,"model_mismatch":false}' \
  "$(card worker-vic-tv2-r1)" \
  "(b) then a start on a vendor config names no model for: that vendor, with no model and no model_source"
assert_eq '{"vendor":"cursor-agent","model_requested":null,"model":null,"model_source":null,"cli_version":null,"model_mismatch":false}' \
  "$(card worker-vic-tv3-r1)" \
  "(c) a later crew_status with only T-116's six fields keeps (b): the vendor it is on, still with no model"
assert_eq '{"vendor":null,"model_requested":null,"model":null,"model_source":null,"cli_version":null,"model_mismatch":false}' \
  "$(card worker-vic-tv4-r1)" \
  "(d) a final vendor \"unknown\" shows the vendor as unknown (null), with no model, never the last vendor tried"
assert_eq '0' \
  "$(jq -c '[.crew[]|select(.id|startswith("worker-vic-tv"))|select(.id!="worker-vic-tv1-r1")|tostring|select(test("gpt-6-astra|claude-opus-5-5|2\\.1\\.0"))]|length' <<<"$sv")" \
  "(b)-(d) no card after the vendor changed carries an earlier vendor's model or CLI version anywhere"
assert_eq '0' \
  "$(jq -c '[.crew[]|select(.id=="worker-vic-tv1-r1")|tostring|select(test("claude-opus-5-5|2\\.1\\.0"))]|length' <<<"$sv")" \
  "(a) the codex card carries claude's model and CLI version nowhere"
assert_eq '[{"vendor":"cursor-agent","count":2},{"vendor":"codex","count":1}]' "$(jq -c '.engineLive' <<<"$sv")" \
  "(d) the engine badge counts each round on the vendor it is on now, and none on \"unknown\""
kill "$pidv" 2>/dev/null; wait "$pidv" 2>/dev/null || true
rm -rf "$qv"


safe_rm_rf "$XDG_CONFIG_HOME"
finish
