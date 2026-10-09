#!/usr/bin/env bash
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
. "$ROOT/tests/lib.sh"
d="$(safe_tmpdir)"
trap 'safe_rm_rf "$d"' EXIT
python3 "$ROOT/tests/lib/ste_cases.py" observations > "$d/observations"
assert_eq 0 "$?" 'STE observations load the production checker'
while IFS=$'\t' read -r actual name; do
  assert_eq true "$actual" "$name"
done < "$d/observations"
for mode in pass fail missing counts state control surrogate pair legacy; do
  python3 "$ROOT/tests/lib/ste_cases.py" fixture "$mode" > "$d/details.json"
  python3 "$ROOT/bin/lib/fm_ste.py" check-details "$d/details.json" > "$d/report" 2> "$d/error"
  rc=$?
  expected=64
  case "$mode" in pass|legacy) expected=0;; fail) expected=65;; esac
  assert_eq "$expected" "$rc" "check-details exit: $mode"
  case "$mode" in
    pass) assert_eq true "$(jq -r '.intent_card and .ok' "$d/report")" 'passing report';;
    fail) assert_contains "$(cat "$d/error")" 'en intent: Ensure the check passes. -> R6 Ensure -> make sure' 'sentence diagnostic';;
    legacy) assert_eq '{"intent_card":false}' "$(jq -c . "$d/report")" 'legacy bypass report';;
  esac
done
# T-228: malformed authoring is a shape error, before the STE prose report.
for mode in align-missing align-zh merge-full merge-label merge-missing legacy no-done; do
  python3 "$ROOT/tests/lib/ste_cases.py" fixture "$mode" > "$d/details.json"
  kind_args=()
  case "$mode" in
    merge-full|merge-label|legacy) kind_args=(--kind merge);;
    merge-missing) kind_args=(--kind merge-untracked);;
  esac
  python3 "$ROOT/bin/lib/fm_ste.py" check-details ${kind_args[@]+"${kind_args[@]}"} "$d/details.json" > "$d/report" 2> "$d/error"
  rc=$?
  expected=64
  case "$mode" in align-zh|merge-full|legacy) expected=0;; esac
  assert_eq "$expected" "$rc" "card authoring exit: $mode"
  case "$mode" in
    align-missing)
      assert_contains "$(cat "$d/error")" 'en.done' 'alignment names locale and field'
      assert_contains "$(cat "$d/error")" 'Intent 2' 'alignment names missing intent';;
    align-zh|merge-full)
      assert_eq true "$(jq -r '.intent_card and .ok' "$d/report")" "valid authored card: $mode";;
    merge-label) assert_contains "$(cat "$d/error")" 'zh-TW.title' 'merge label names locale';;
    merge-missing)
      assert_contains "$(cat "$d/error")" 'en.change_table' 'merge requires the full field set'
      python3 "$ROOT/bin/lib/fm_ste.py" check-details "$d/details.json" > "$d/report" 2> "$d/error"
      assert_eq 0 "$?" 'choice allows omitted change table'
      assert_eq true "$(jq -r '.intent_card and .ok' "$d/report")" 'choice still checks prose';;
    legacy) assert_eq '{"intent_card":false}' "$(jq -c . "$d/report")" 'legacy merge bypass report';;
    no-done) assert_contains "$(cat "$d/error")" 'en.done: required on an intent card' 'intent cards require done';;
  esac
done
python3 "$ROOT/bin/lib/fm_ste.py" check-details --kind > "$d/report" 2> "$d/error"
assert_eq 64 "$?" 'kind requires a value and file'
assert_contains "$(cat "$d/error")" 'check-details [--kind <kind>] <file>' 'usage shows optional kind'
# T-244: an unhashable scene reference is a named field error, never a traceback,
# through check-explain and spec preflight. Fixture: tests/lib/ste_cases.py card().
for mutation in 'nodes.change:n["state"]="new";n["change"]=[]' 'edges.change:e["state"]="new";e["change"]=[]' \
  'edges.from:e["from"]=[]' 'edges.to:e["to"]={}'; do
  field="${mutation%%:*}"
  python3 - "$ROOT" "${mutation#*:}" > "$d/scene-spec.json" <<'PY_SCENE'
import json, sys
sys.path.insert(0, sys.argv[1] + '/tests/lib')
from ste_cases import card
fields = ('intent', 'why', 'scope_in', 'scope_out', 'done', 'notes', 'before_nodes', 'after_nodes')
explain = {lang: {k: v for k, v in loc.items() if k in fields} for lang, loc in card().items()}
for loc in explain.values():
    loc['scene'] = dict(lanes=[dict(label='Flow')], nodes=[
        dict(id='input', label='Input', lane=0, kind='input', state='same'),
        dict(id='output', label='Output', lane=0, kind='step', state='same')],
        edges=[dict(id='path', **{'from': 'input', 'to': 'output'}, state='same')],
        tokens=dict(before=['path'], after=['path']),
        changes=[dict(id='c1', text='The path carries the input.', intents=[1])])
scene = explain['en']['scene']
n, e = scene['nodes'][0], scene['edges'][0]
exec(sys.argv[2])
print(json.dumps(dict(id='T-001', title='The task works.', scope=['tests/ste.test.sh'],
                      acceptance=['The path works.'], explain=explain)))
PY_SCENE
  python3 "$ROOT/bin/lib/fm_ste.py" check-explain "$d/scene-spec.json" > "$d/report" 2> "$d/error"
  rc=$?
  assert_eq 64 "$rc" "check-explain refuses malformed $field"
  assert_contains "$(cat "$d/error")" "en.scene.$field" "check-explain names $field"
  assert_lacks "$(cat "$d/error")" Traceback "check-explain has no traceback for $field"
  python3 "$ROOT/bin/lib/fm_spec_preflight.py" prompt --task T-001 --spec "$d/scene-spec.json" --base base > "$d/report" 2> "$d/error"
  rc=$?
  assert_eq 65 "$rc" "preflight refuses malformed $field"
  assert_contains "$(cat "$d/error")" "en.scene.$field" "preflight names $field"
  assert_lacks "$(cat "$d/error")" Traceback "preflight has no traceback for $field"
done
python3 "$ROOT/bin/lib/fm_ste.py" rules > "$d/rules"
assert_eq 0 "$?" 'rules CLI succeeds'
for id in R{1..10} Z{1..8}; do
  assert_eq true "$(jq --arg id "$id" 'any(.rules[]; .id == $id and (.text.en|length>0) and (.text["zh-TW"]|length>0))' "$d/rules")" "bilingual rule $id"
done
finish
