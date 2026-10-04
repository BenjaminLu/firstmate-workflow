#!/usr/bin/env bash
# T-183: real card writers and renderer, no network or background processes.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
. "$ROOT/tests/lib.sh"
for k in $(env | sed -nE 's/^(FM_[^=]*|HERDR_[^=]*)=.*/\1/p'); do unset "$k"; done
export HERDR_ENV=0 FM_IN_ROUND=1
work="$(safe_tmpdir)"
trap 'rm -rf "$work"' EXIT
fixture() {
  local d="$work/$1"
  mkdir -p "$d/bin" "$d/design/tasks" "$d/skills/worker" "$d/i18n" "$d/state/pending" "$d/state/decisions"
  cp "$ROOT/bin/fm.sh" "$ROOT/bin/fm-config.sh" "$ROOT/bin/fm-decide.sh" \
    "$ROOT/bin/fm-ready.sh" "$ROOT/bin/fm-diagram.sh" "$ROOT/bin/fm-emit.sh" "$d/bin/"
  cp -R "$ROOT/bin/lib" "$d/bin/"
  cp "$ROOT/i18n/ui.en.json" "$ROOT/i18n/ui.zh-TW.json" "$ROOT/i18n/tw2cn.tsv" "$d/i18n/"
  printf '# Worker\nOriginal instructions.\n' > "$d/skills/worker/SKILL.md"
  printf '{"id":"SK-009","depends_on":[],"title":"Skill proposal"}\n' > "$d/design/tasks/SK-009.json"
  printf 'concurrency: 3\n' > "$d/config.yaml"
  printf '%s' "$d"
}
d="$(fixture proposal)"
FM_ROOT="$d" bash "$d/bin/fm.sh" self-update --skill worker --why 'State the evidence before editing.' > "$d/out" 2>&1
assert_eq 0 "$?" 'self-update raises a complete card'
card="$d/state/pending/D-SK-010.json"
assert_ok "jq -e 'all(.details.en,.details[\"zh-TW\"]; all(.title,.explanation,.before,.after,.outcome; type == \"string\" and length > 0) and all(.options.A,.options.B,.options.C; all(.description,.pros,.cons; type == \"string\" and length > 0)))' '$card'" 'every field and A/B/C tradeoff exists in both languages'
assert_eq 'State the evidence before editing.' "$(jq -r '.details.en.explanation' "$card")" 'card preserves the proposal reason'
assert_contains "$(jq -r '.details.en.title' "$card")" worker 'card names the proposed skill'
assert_contains "$(jq -r '.details.en.before' "$card")" 'not provided' 'missing before text is disclosed'
assert_contains "$(jq -r '.details.en.after' "$card")" 'not provided' 'missing proposed text is disclosed'
assert_contains "$(jq -r '.details["zh-TW"].after' "$card")" '未提供' 'missing proposed text is disclosed in Traditional Chinese'
assert_eq 'Revise: the captain names what to change, and firstmate revises the proposal and raises it again for a new decision.' "$(jq -r '.details.en.options.C.description' "$card")" 'revise names firstmate and a new decision in English'
assert_eq '修訂：由船長指出要改什麼，firstmate 修訂提案後重新提出，供船長作出新的決策。' "$(jq -r '.details["zh-TW"].options.C.description' "$card")" 'revise names firstmate and a new decision in Traditional Chinese'
assert_ok "jq -e 'all(.details.en.options.C[],.details[\"zh-TW\"].options.C[]; type == \"string\" and (test(\"same decision id|相同決策編號\"; \"i\") | not))' '$card'" 'revise makes no same-id promise in either language'
assert_eq '# Worker
Original instructions.' "$(cat "$d/skills/worker/SKILL.md")" 'proposal does not edit the skill'
jq '.details' "$card" > "$d/details.json"
# All command helpers disable desktop notification explicitly.
request() { HERDR_ENV=0 FM_ROOT="$d" bash "$d/bin/fm-decide.sh" --request "$1" --task "$2" --details "$d/details.json"; }
request D-SK-009 SK-009 > "$d/request" 2>&1
assert_eq 0 "$?" 'fm-decide accepts authored D-SK-009 details'
for lang in en zh-TW zh-CN; do
  assert_ok "test -s '$d/board/public/diagrams/D-SK-009.$lang.html'" "SK request renders $lang diagram"
done
jq 'del(."zh-TW".options.C.cons)' "$d/details.json" > "$d/bad.json"
HERDR_ENV=0 FM_ROOT="$d" bash "$d/bin/fm-decide.sh" --request D-SK-011 --task SK-011 --details "$d/bad.json" >/dev/null 2>&1
assert_eq 64 "$?" 'SK details require complete localized tradeoffs'
request D-SK-012 SK-999 >/dev/null 2>&1
assert_eq 64 "$?" 'SK details must name the matching task'
# Card creation and rendering must not depend on the optional config reader.
saved_details="$d/details.json"
d="$(fixture no-reader)"
cp "$saved_details" "$d/details.json"
rm "$d/bin/fm-config.sh"
for pair in 'D-44 T-44' 'D-SK-009 SK-009'; do
  read -r id task <<<"$pair"
  request "$id" "$task" > "$d/request" 2>&1
  assert_eq 0 "$?" "request $id works without the config reader"
  assert_ok "test -s '$d/state/pending/$id.json'" "request $id persists without the config reader"
  for lang in en zh-TW zh-CN; do
    assert_ok "test -s '$d/board/public/diagrams/$id.$lang.html'" "$id renders $lang without the config reader"
  done
done
HERDR_ENV=0 FM_ROOT="$d" bash "$d/bin/fm-ready.sh" judged --task SK-009 --decision D-SK-009 >/dev/null 2>&1
assert_eq 0 "$?" 'ready validates skill decisions without the config reader'
d="$(fixture grammar)"
# The shared grammar and all three consumers agree at the input boundary.
. "$ROOT/bin/fm-emit.sh"
for id in D-1 D-123456 D-SK-009 D-SK-1234 D-firstmate-workflow-SK009-1; do
  fm_decision_id "$id"
  assert_eq 0 "$?" "shared grammar accepts $id"
  HERDR_ENV=0 FM_ROOT="$d" bash "$d/bin/fm-ready.sh" judged --task SK-009 --decision "$id" >/dev/null 2>&1
  assert_eq 0 "$?" "ready accepts $id"
  printf '{"id":"%s","task":"SK-009","kind":"choice","title":"Skill proposal"}\n' "$id" > "$d/state/decisions/$id.json"
  HERDR_ENV=0 FM_ROOT="$d" bash "$d/bin/fm-decide.sh" --await "$id" --timeout 1 >/dev/null 2>&1
  assert_eq 0 "$?" "decide accepts $id"
  HERDR_ENV=0 FM_ROOT="$d" bash "$d/bin/fm-diagram.sh" --decision "$id" >/dev/null 2>&1
  assert_eq 0 "$?" "diagram accepts $id"
done
for id in D-SK-9 D-SK-09 D-SK-009x D-1234567 D-a-SK09-1 D-a-SK009-0 '../D-SK-009' $'D-SK-009\nx'; do
  fm_decision_id "$id"
  assert_ne 0 "$?" "shared grammar refuses $id"
  HERDR_ENV=0 FM_ROOT="$d" bash "$d/bin/fm-ready.sh" judged --task SK-009 --decision "$id" >/dev/null 2>&1
  assert_eq 64 "$?" "ready refuses $id"
  HERDR_ENV=0 FM_ROOT="$d" bash "$d/bin/fm-decide.sh" --await "$id" --timeout 1 >/dev/null 2>&1
  assert_eq 64 "$?" "decide refuses $id"
  HERDR_ENV=0 FM_ROOT="$d" bash "$d/bin/fm-diagram.sh" --decision "$id" >/dev/null 2>&1
  assert_eq 64 "$?" "diagram refuses $id"
done
# Replace the shared predicate in a disposable fixture: every consumer must
# obey it, rather than merely happen to agree on the examples above.
d="$(fixture shared)"
# Put the override before fm-emit's source-only return.
python3 - "$d/bin/fm-emit.sh" <<'PYGRAMMAR'
from pathlib import Path
import sys
p = Path(sys.argv[1])
p.write_text(p.read_text().replace(
    '# sourced for the grammar alone: stop here',
    'fm_decision_id() { return 1; }\n# sourced for the grammar alone: stop here'))
PYGRAMMAR
HERDR_ENV=0 FM_ROOT="$d" bash "$d/bin/fm-ready.sh" judged --task SK-009 --decision D-SK-009 >/dev/null 2>&1
assert_eq 64 "$?" 'ready uses the shared predicate'
HERDR_ENV=0 FM_ROOT="$d" bash "$d/bin/fm-decide.sh" --await D-SK-009 --timeout 1 >/dev/null 2>&1
assert_eq 64 "$?" 'decide uses the shared predicate'
HERDR_ENV=0 FM_ROOT="$d" bash "$d/bin/fm-diagram.sh" --decision D-SK-009 >/dev/null 2>&1
assert_eq 64 "$?" 'diagram uses the shared predicate'
finish
