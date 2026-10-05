#!/usr/bin/env bash
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=tests/lib/project-storage.sh
. "$ROOT/tests/lib/project-storage.sh"
# shellcheck source=tests/lib/board.sh
. "$ROOT/tests/lib/board.sh"
XDG_CONFIG_HOME="$(safe_tmpdir)"; export XDG_CONFIG_HOME
f="$(safe_tmpdir)"
mkdir -p "$f/bin" "$f/state/pins" "$f/state/skill-updates" "$f/design" "$f/board/public"
cp "$ROOT/bin/fm-emit.sh" "$ROOT/bin/fm-config.sh" "$ROOT/bin/fm-herdr.py" "$f/bin/"
project_storage_fixture "$f/bin/"
cp -R "$ROOT/bin/lib" "$f/bin/"
cp "$ROOT/board/server.ts" "$f/board/"
cp "$ROOT/board/public/index.html" "$f/board/public/"
fm_tasks_write /dev/stdin "$f/design/tasks" <<'J'
{"tasks":[{"id":"T-D1","title":"from the plan","depends_on":[]}]}
J
em() { FM_ROOT="$f" "$f/bin/fm-emit.sh" --actor captain --task "$1" --type "$2" --en "$3" --tw "$4" >/dev/null; }
pin() {
  mkdir -p "$f/state/pins/$1"
  jq -cn --arg title "$3" '{snapshots:{spec:{text:({title:$title}|tojson)}}}' > "$f/state/pins/$1/$2.json"
}
pin T-D1 1 'from a pin'
pin T-PIN 9 'pin nine'
pin T-PIN 10 'pin ten'
em T-PIN dispatched 'pin task' '釘選任務'
mkdir -p "$f/state/pins/T-BAD"
printf 'not JSON\n' > "$f/state/pins/T-BAD/1.json"
em T-BAD decision_requested 'T-BAD: from the decision' 'T-BAD：決定裡的標題'
printf '%s\n' '{"title":"skill-update: worker"}' > "$f/state/skill-updates/SK-901.json"
em SK-901 dispatched 'skill task' '技能任務'
em T-DEC decision_requested 'Dispatch T-DEC: the first thing' '派工 T-DEC：第一件事'
em T-DEC decision_requested 'Merge #9: something else' '合併 #9：別的事'
long="$(python3 -c 'print("x" * 250 + "\nsecond line")')"
em T-LONG decision_requested "$long" "$(python3 -c 'print("字" * 250 + "\n第二行")')"
em T-LOG dispatched 'no title source' '沒有標題來源'
# These are exactly the paths an unsafe join with ../escape would reach.
mkdir -p "$f/state/escape"
jq -cn '{snapshots:{spec:{text:({title:"from outside"}|tojson)}}}' > "$f/state/escape/1.json"
printf '%s\n' '{"title":"from outside"}' > "$f/state/escape.json"
printf '%s\n' '{"ts":"2026-10-05T00:00:00Z","actor":"captain","task":"../escape","type":"decision_requested","summary":{"en":"from the log"}}' >> "$f/state/events.jsonl"
pin T-TARGET 1 'linked pin'
ln -s "$f/state/pins/T-TARGET" "$f/state/pins/T-LINK"
em T-LINK decision_requested 'T-LINK: from the decision' 'T-LINK：決定裡的標題'
# Symlinked files, as well as directories, must never supply a title.
mkdir -p "$f/state/pins/T-LINKFILE"
ln -s "$f/state/pins/T-TARGET/1.json" "$f/state/pins/T-LINKFILE/1.json"
em T-LINKFILE decision_requested 'T-LINKFILE: safe pin file fallback' 'T-LINKFILE：安全的釘選檔案備援'
ln -s "$f/state/skill-updates/SK-901.json" "$f/state/skill-updates/SK-902.json"
em SK-902 decision_requested 'SK-902: safe skill fallback' 'SK-902：安全的技能備援'
# Invalid newest pins go on to the next source, not an older pin.
pin T-INVALID 1 'old pin'
pin T-INVALID 2 ''
printf '%s\n' '{"title":"proposal after empty pin"}' > "$f/state/skill-updates/T-INVALID.json"
em T-INVALID dispatched 'invalid newest pin' '最新釘選無效'
printf '%s\n' '{"title":42}' > "$f/state/skill-updates/T-NONSTRING.json"
pin T-DOTS..ID 1 'must skip double dots'
em T-DOTS..ID decision_requested 'T-DOTS..ID: safe double-dot fallback' 'T-DOTS..ID：安全的雙點備援'
pin T-BADSPEC 1 'overwritten'
printf '%s\n' '{"snapshots":{"spec":{"text":"not JSON"}}}' > "$f/state/pins/T-BADSPEC/1.json"
em T-BADSPEC decision_requested 'T-BADSPEC: after malformed spec' 'T-BADSPEC：規格無效時的備援'
em T-NONSTRING decision_requested 'T-NONSTRING: after non-string title' 'T-NONSTRING：標題不是字串時的備援'

pid="$(FM_ROOT="$f" FM_PORT=0 bash "$ROOT/bin/lib/fm-lifeline.sh" --owner-pid "$$" --log "$f/out" -- bun run "$f/board/server.ts")"
printf '%s\n' "$pid" > "$f/keepers"
cleanup() { stop_pids "$f/keepers"; safe_rm_rf "$f"; safe_rm_rf "$XDG_CONFIG_HOME"; }
trap cleanup EXIT
if ! port="$(board_port "$f/out" "$pid")" || [[ ! "$port" =~ ^[0-9]+$ ]]; then
  assert_eq 'listening port' 'none' 'board starts before title assertions'
  cat "$f/out" >&2
  finish
  exit 1
fi
wait_for 60 curl -sf "http://127.0.0.1:$port/api/state"
state="$(curl -sf "http://127.0.0.1:$port/api/state")"
field() { jq -r --arg id "$1" ".tasks[]|select(.id==\$id)|$2" <<<"$state"; }
# Regression guards: definitions win and a dispatch alone invents no title.
assert_eq 'from the plan' "$(field T-D1 .title)" 'definitions win (regression guard)'
assert_eq null "$(field T-D1 .title_tw)" 'definition has no translated summary title'
assert_eq null "$(field T-LOG .title)" 'dispatch alone stays untitled (regression guard)'
assert_eq null "$(field T-LOG .title_tw)" 'dispatch alone has no Chinese title'
# Fail-first: base returns null for every fallback title below.
assert_eq 'pin ten' "$(field T-PIN .title)" 'newest pin is ordered numerically'
assert_eq null "$(field T-PIN .title_tw)" 'pin title has no Chinese summary title'
assert_eq 'from the decision' "$(field T-BAD .title)" 'broken pin falls through to decision'
assert_eq '決定裡的標題' "$(field T-BAD .title_tw)" 'decision supplies Chinese title'
assert_eq 'skill-update: worker' "$(field SK-901 .title)" 'skill proposal supplies title'
assert_eq null "$(field SK-901 .title_tw)" 'skill proposal has no Chinese summary title'
assert_eq 'the first thing' "$(field T-DEC .title)" 'earliest decision wins with prefixes stripped'
assert_eq '第一件事' "$(field T-DEC .title_tw)" 'Chinese prefixes stripped too'
assert_eq "$(python3 -c 'print("x" * 200 + "…")')" "$(field T-LONG .title)" 'only first line, bounded to 200 characters plus ellipsis'
assert_eq 'from the log' "$(field ../escape .title)" 'hostile id skips filesystem title sources'
assert_eq null "$(field ../escape .title_tw)" 'absent Chinese summary stays null'
assert_eq 'from the decision' "$(field T-LINK .title)" 'symlinked pin directory skipped'
assert_eq 'safe pin file fallback' "$(field T-LINKFILE .title)" 'symlinked pin file skipped'
assert_eq 'safe skill fallback' "$(field SK-902 .title)" 'symlinked skill file skipped'
assert_eq 'proposal after empty pin' "$(field T-INVALID .title)" 'empty newest pin advances to skill proposal'
assert_eq 'after non-string title' "$(field T-NONSTRING .title)" 'non-string proposal skipped'
assert_eq 'safe double-dot fallback' "$(field T-DOTS..ID .title)" 'double dots skip files even with otherwise valid id'
assert_eq 'after malformed spec' "$(field T-BADSPEC .title)" 'malformed nested spec skipped'
pin T-PIN 11 'new pin next request'
state="$(curl -sf "http://127.0.0.1:$port/api/state")"
assert_eq 'new pin next request' "$(field T-PIN .title)" 'title reads refresh on the next request'
assert_ne '' "$(curl -sf "http://127.0.0.1:$port/api/state")" 'board keeps serving after hostile records'
cleanup
trap - EXIT
finish
