#!/usr/bin/env bash
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=tests/lib/project-storage.sh
. "$ROOT/tests/lib/project-storage.sh"
# shellcheck source=tests/lib/board.sh
. "$ROOT/tests/lib/board.sh"
XDG_CONFIG_HOME="$(safe_tmpdir)"; export XDG_CONFIG_HOME
# --- T-036: truthful mid-run crew progress ---------------------------------
# Separate fixture: the crowd above floods the deck and would drown these.
p="$(safe_tmpdir)"; mkdir -p "$p/bin" "$p/state" "$p/design" "$p/board/public"
cp "$ROOT/bin/fm-emit.sh" "$ROOT/bin/fm-config.sh" "$p/bin/"; project_storage_fixture "$p/bin/"
cp -R "$ROOT/bin/lib" "$p/bin/"   # the lifeline the board starts merges and rounds under (T-151)
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
# T-159: the launcher explicitly marks a pre-window CI wait. Ordinary
# heartbeats retain it; an explicit return to review restores the window.
FM_ROOT="$p" FM_CREW_STATUS_SECS=0 "$p/bin/fm-emit.sh" --actor reviewer-ph --task T-Q --type crew_status \
  --data '{"role":"reviewer","phase":"waiting_ci","window_expected":false,"activity":{"en":"Waiting for CI: ci","zh-TW":"等待 CI：ci"}}' >/dev/null
FM_ROOT="$p" FM_CREW_STATUS_SECS=0 "$p/bin/fm-emit.sh" --actor reviewer-ph --task T-Q --type crew_status \
  --data '{"role":"reviewer"}' >/dev/null
waiting_state="$(curl -sf "http://127.0.0.1:$PORTP/api/state")"
assert_eq 'waiting_ci' "$(jq -r '.crew[]|select(.id=="reviewer-ph")|.state' <<<"$waiting_state")" \
  "CI waiting survives a technical heartbeat"
assert_eq 'false' "$(jq -r '.crew[]|select(.id=="reviewer-ph")|.window_expected' <<<"$waiting_state")" \
  "a reviewer waiting for CI needs no window"
FM_ROOT="$p" FM_CREW_STATUS_SECS=0 "$p/bin/fm-emit.sh" --actor reviewer-ph --task T-Q --type crew_status \
  --data '{"role":"reviewer","phase":"review","window_expected":true}' >/dev/null
assert_eq 'true' "$(curl -sf "http://127.0.0.1:$PORTP/api/state" | jq -r '.crew[]|select(.id=="reviewer-ph")|.window_expected')" \
  "starting the review restores the window expectation"
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


safe_rm_rf "$XDG_CONFIG_HOME"
finish
