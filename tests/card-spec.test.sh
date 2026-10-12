#!/usr/bin/env bash
# T-301: a dispatch or repin card takes its spec fields from the task spec.
# Feature dependencies: bin/fm-decide.sh bin/lib/fm_card_spec.py bin/lib/fm_ste.py
# Shared fixtures: tests/lib/ste_cases.py tests/decide.test.sh (its fixture prefix)
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export HERDR_ENV=0

# The stock decide fixture (scripts, dictionaries, gh stub, binding service);
# it also sources tests/lib.sh.
eval "$(python3 -c 'import sys; print(open(sys.argv[1]).read().split("\nd=\"$(fixture)\"", 1)[0])' "$ROOT/tests/decide.test.sh")"

d="$(fixture)"
request() { FM_GH="$d/gh" FM_ROOT="$d" "$d/bin/fm-decide.sh" "$@"; }
ste() { python3 "$ROOT/tests/lib/ste_cases.py" fixture "$1"; }
FIELDS='["intent","why","scope_in","scope_out","done","notes","before_nodes","after_nodes"]'
mkdir -p "$d/design/tasks"

# spec <task> <en flow label> <zh-TW flow label>: a local task spec whose
# explain holds the eight spec fields, with flow labels of its own
spec() {
  ste pass | jq --arg id "$1" --arg en "$2" --arg tw "$3" --argjson f "$FIELDS" '
    {id:$id, title:"x", scope:["src/**"], acceptance:["The check passes."],
     explain:(with_entries(.value |= with_entries(select(.key as $k | $f | index($k)))))}
    | .explain.en.after_nodes=[{state:"new",label:$en}]
    | .explain["zh-TW"].after_nodes=[{state:"new",label:$tw}]' > "$d/design/tasks/$1.json"
}
# a card that leaves out every spec field; firstmate writes only the rest
ste pass | jq --argjson f "$FIELDS" 'with_entries(.value |= with_entries(select(.key as $k | $f | index($k) | not)))' > "$d/bare.json"
assert_eq '[]' "$(jq -c --argjson f "$FIELDS" '[.en, ."zh-TW" | keys[] | select(. as $k | $f | index($k))]' "$d/bare.json")" \
  'the bare card carries no spec field'

# --- card: dispatch takes spec fields ----------------------------------------
spec T-301 'Card reads the spec' '卡片讀 spec'
id="$(FM_ROOT="$d" "$d/bin/fm-decide.sh" --allocate --task T-301)"
out="$(request --request "$id" --task T-301 --purpose dispatch --details "$d/bare.json" 2>&1)"
assert_eq 0 "$?" "card: dispatch takes spec fields: the card is raised ($out)"
pending="$d/state/pending/$id.json"
for lang in en zh-TW; do
  for field in intent 'done' before_nodes after_nodes why scope_in scope_out notes; do
    assert_eq "$(jq -c --arg l "$lang" --arg k "$field" '.explain[$l][$k]' "$d/design/tasks/T-301.json")" \
      "$(jq -c --arg l "$lang" --arg k "$field" '.details[$l][$k]' "$pending" 2>/dev/null)" \
      "card: dispatch takes spec fields: $lang.$field comes from the spec"
  done
done
assert_eq '卡片讀 spec' "$(jq -r '.details["zh-TW"].after_nodes[0].label' "$pending" 2>/dev/null)" \
  'card: dispatch takes spec fields: the zh-TW flow is the spec flow'
assert_eq '[]' "$(jq -c --argjson f "$FIELDS" '[.en, ."zh-TW" | keys[] | select(. as $k | $f | index($k))]' "$d/bare.json")" \
  "card: dispatch takes spec fields: the author's details file is not changed"

# --- card: repin takes spec fields --------------------------------------------
# A repin card approves the task's new spec: the fields of the spec as it is now
spec T-302 'Old flow' '舊流程'
spec T-302 'New flow' '新流程'
id="$(FM_ROOT="$d" "$d/bin/fm-decide.sh" --allocate --task T-302)"
out="$(request --request "$id" --task T-302 --purpose repin --details "$d/bare.json" 2>&1)"
assert_eq 0 "$?" "card: repin takes spec fields: the card is raised ($out)"
pending="$d/state/pending/$id.json"
assert_eq 'New flow|新流程' "$(jq -r '[.details.en.after_nodes[0].label, .details["zh-TW"].after_nodes[0].label] | join("|")' "$pending" 2>/dev/null)" \
  'card: repin takes spec fields: the flow is the new spec flow in both languages'
assert_eq "$(jq -c '.explain | map_values({intent,done})' "$d/design/tasks/T-302.json")" \
  "$(jq -c '.details | {en:{intent:.en.intent,done:.en.done},"zh-TW":{intent:.["zh-TW"].intent,done:.["zh-TW"].done}}' "$pending" 2>/dev/null)" \
  'card: repin takes spec fields: intent and done lines come from the spec'

# --- card: differing spec field refused ---------------------------------------
# The same card as above, except that it supplies its own flow
jq '."zh-TW".after_nodes=[{state:"new",label:"別的流程"}]' "$d/bare.json" > "$d/differs.json"
id="$(FM_ROOT="$d" "$d/bin/fm-decide.sh" --allocate --task T-301)"
out="$(request --request "$id" --task T-301 --purpose dispatch --details "$d/differs.json" 2>&1)"
assert_eq 65 "$?" 'card: differing spec field refused: the card is refused'
assert_contains "$out" 'zh-TW.after_nodes differs from the task spec' 'card: differing spec field refused: the refusal names the field'
assert_fail "test -e '$d/state/pending/$id.json'" 'card: differing spec field refused: no card is written'
# a supplied field equal to the spec passes
jq --slurpfile s "$d/design/tasks/T-301.json" '."zh-TW".after_nodes=$s[0].explain["zh-TW"].after_nodes' "$d/bare.json" > "$d/equal.json"
id="$(FM_ROOT="$d" "$d/bin/fm-decide.sh" --allocate --task T-301)"
request --request "$id" --task T-301 --purpose dispatch --details "$d/equal.json" >/dev/null 2>&1
assert_eq 0 "$?" 'card: differing spec field refused: a field equal to the spec is accepted'
# a spec with no explain: the card must carry the flow, intent and done itself
jq -n '{id:"T-304",scope:["src/**"],acceptance:["x"]}' > "$d/design/tasks/T-304.json"
id="$(FM_ROOT="$d" "$d/bin/fm-decide.sh" --allocate --task T-304)"
out="$(request --request "$id" --task T-304 --purpose repin --details "$d/bare.json" 2>&1)"
assert_eq 65 "$?" 'card: differing spec field refused: a card without flow, intent and done is refused'
assert_contains "$out" 'en.intent: a dispatch or repin card needs it' 'card: differing spec field refused: the refusal names the missing intent'
ste pass > "$d/full.json"
request --request "$id" --task T-304 --purpose repin --details "$d/full.json" >/dev/null 2>&1
assert_eq 0 "$?" 'card: differing spec field refused: a spec without explain takes the authored fields'
# a missing spec file, and a spec of another task
for how in missing another-task; do
  id="$(FM_ROOT="$d" "$d/bin/fm-decide.sh" --allocate --task T-305)"
  rm -f "$d/design/tasks/T-305.json"
  [ "$how" = another-task ] && jq '.id="T-301"' "$d/design/tasks/T-301.json" > "$d/design/tasks/T-305.json"
  out="$(request --request "$id" --task T-305 --purpose dispatch --details "$d/full.json" 2>&1)"
  assert_eq 65 "$?" "card: differing spec field refused: task spec ($how) is refused"
  assert_fail "test -e '$d/state/pending/$id.json'" "card: differing spec field refused: task spec ($how) writes no card"
done

# --- card: merge unchanged ------------------------------------------------------
# A merge card keeps its authored flow even when the spec's differs, and a
# scope card takes nothing from the spec.
spec T-303 'Spec flow' 'spec 流程'
pr_is "$d" 33 t-303-merge 'T-303: merge'
ste pass | jq '.en.title="MERGE CARD — merge PR #33: The check passes." | ."zh-TW".title="【合併卡】合併 PR #33：檢查通過。"' > "$d/merge.json"
out="$(request --expected-head aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa --request D-30101 --task T-303 --kind merge --pr 33 --details "$d/merge.json" 2>&1)"
assert_eq 0 "$?" "card: merge unchanged: the merge card is raised ($out)"
assert_eq "$(jq -c '.en.after_nodes' "$d/merge.json")" "$(jq -c '.details.en.after_nodes' "$d/state/pending/D-30101.json" 2>/dev/null)" \
  'card: merge unchanged: the merge card keeps its authored flow'
request --request D-30102 --task T-303 --purpose scope --details "$d/full.json" >/dev/null 2>&1
assert_eq 0 "$?" 'card: merge unchanged: a scope card is raised as before'
assert_eq "$(jq -c '.en.after_nodes' "$d/full.json")" "$(jq -c '.details.en.after_nodes' "$d/state/pending/D-30102.json" 2>/dev/null)" \
  'card: merge unchanged: a scope card keeps its authored flow'
rm -rf "$d"

finish
