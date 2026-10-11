#!/usr/bin/env bash
# The rule inventory stage of the gate (T-279): every rule sentence of the
# firstmate skill has an inventory entry. Each case runs the repository's own
# bin/ci.sh --stage fast on a small fixture tree; the checker is reached only
# through the gate.
# Feature dependencies: bin/ci.sh bin/lib/fm_rules.py
# tests/fixtures/rule-inventory/SKILL.md tests/fixtures/rule-inventory/rule-inventory.json
# tests/fixtures/rule-inventory/guard.py tests/fixtures/rule-inventory/merge.txt
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=tests/lib.sh
. "$ROOT/tests/lib.sh"
# nothing inherited: an FM_EXTERNAL or FM_ROOT from the gate running this
# suite would change what the gate under test judges
for _fm_k in $(env | sed -E -n 's/^(FM_[^=]*|HERDR_[^=]*)=.*$/\1/p'); do
  unset "$_fm_k"
done

fx="$ROOT/tests/fixtures/rule-inventory"
work="$(safe_tmpdir)"
trap 'safe_rm_rf "$work"' EXIT
make_tree() {  # make_tree: a fresh fixture tree, its path printed
  local t
  t="$(mktemp -d "$work/tree.XXXXXX")" || exit 70
  mkdir -p "$t/skills/firstmate" "$t/tools" "$t/bin" "$t/tests"
  cp "$fx/SKILL.md" "$fx/rule-inventory.json" "$t/skills/firstmate/"
  cp "$fx/guard.py" "$fx/merge.txt" "$t/tools/"
  # bash 3.2 reads an empty array as unbound under set -u: one script in bin/
  # and one suite keep every list a fast stage builds non-empty
  printf '#!/usr/bin/env bash\nexit 0\n' > "$t/bin/placeholder.sh"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$t/tests/green.test.sh"
  printf '%s' "$t"
}
gate() {  # gate <tree> [NAME=value...]: the fast stages of this repository's gate on <tree>
  local t="$1"
  shift
  env "$@" FM_ROOT="$t" bash "$ROOT/bin/ci.sh" --stage fast 2>&1
}
mutate() {  # mutate <tree> <python>: rewrite the tree's inventory; inv is the document, rule maps ids to entries
  python3 - "$1/skills/firstmate/rule-inventory.json" "$2" <<'PY'
import json, sys
path, code = sys.argv[1], sys.argv[2]
with open(path, encoding='utf-8') as handle:
    inv = json.load(handle)
rule = {entry['id']: entry for entry in inv['rules']}
SKILL = 'skills/firstmate/SKILL.md'
exec(code)
with open(path, 'w', encoding='utf-8') as handle:
    json.dump(inv, handle, indent=2)
PY
}
skill_line() {  # skill_line <tree> <text>: the line number of the first line holding <text>
  grep -nF -- "$2" "$1/skills/firstmate/SKILL.md" | sed -n '1s/:.*//p'
}

# --- a matching inventory -----------------------------------------------
t="$(make_tree)"
out="$(gate "$t")"; rc=$?
assert_contains "$out" "+ rule inventory: 5 rules: 2 enforced, 1 enforceable, 2 judgement" \
  "a matching inventory passes with the number of rules in each class"
assert_eq 0 "$rc" "and the gate exits 0, every other fast stage passing or skipping"
assert_lacks "$out" "no inventory entry" \
  "rules before the first heading and under the top-level heading are covered by entries"
assert_lacks "$out" "you must not run this" "the word must inside a fenced code block is not a rule sentence"

# --- a rule sentence with no entry --------------------------------------
printf '\nPlanted here: the gate must stay green.\n' >> "$t/skills/firstmate/SKILL.md"
planted="$(skill_line "$t" 'Planted here:')"
out="$(gate "$t")"; rc=$?
assert_ne 0 "$rc" "a planted rule sentence with no entry turns the gate red"
assert_contains "$out" "x rule inventory" "in the rule inventory stage"
assert_contains "$out" "skills/firstmate/SKILL.md:$planted: a rule sentence with no inventory entry: Planted here: the gate must stay green." \
  "the refusal names the sentence's line and its text"
assert_contains "$out" '{"id": "", "file": "skills/firstmate/SKILL.md", "heading": "Details", "quote": "Planted here: the gate must stay green.", "class": ""}' \
  "and prints a stub entry to paste, with its heading and an empty class"

# --- the rules above the first ## heading -------------------------------
t="$(make_tree)"
mutate "$t" "inv['rules'] = [e for e in inv['rules'] if e['id'] not in ('R-001', 'R-002')]"
out="$(gate "$t")"
assert_contains "$out" "skills/firstmate/SKILL.md:$(skill_line "$t" 'A rule before any heading'): a rule sentence with no inventory entry: A rule before any heading: the crew must read this line first." \
  "a rule before the first heading needs an entry of its own"
assert_contains "$out" '"heading": "", "quote": "A rule before any heading: the crew must read this line first."' \
  "and its stub has the empty heading"
assert_contains "$out" "skills/firstmate/SKILL.md:$(skill_line "$t" 'Under the top-level heading'): a rule sentence with no inventory entry: Under the top-level heading, a worker never pushes to the main branch." \
  "a rule under the top-level heading needs an entry of its own"
assert_contains "$out" '"heading": "Sample startup contract", "quote": "Under the top-level heading' \
  "and its stub names the top-level heading"

# --- a fenced code block ------------------------------------------------
t="$(make_tree)"
grep -v '^```' "$t/skills/firstmate/SKILL.md" > "$t/unfenced" && mv "$t/unfenced" "$t/skills/firstmate/SKILL.md"
out="$(gate "$t")"
assert_contains "$out" 'a rule sentence with no inventory entry: echo "you must not run this"' \
  "the same line outside its fence is a rule sentence"

# --- quotes -------------------------------------------------------------
t="$(make_tree)"
printf '\nAgain, the reviewer must read the whole diff.\n' >> "$t/skills/firstmate/SKILL.md"
mutate "$t" "rule['R-001']['quote'] = 'the crew must read this line second'; rule['R-003']['heading'] = 'Details'"
out="$(gate "$t")"; rc=$?
assert_ne 0 "$rc" "a quote that does not match the skill turns the gate red"
assert_contains "$out" "R-001: quote not found in skills/firstmate/SKILL.md" "a missing quote is refused with its rule ID"
assert_contains "$out" "R-004: quote appears 2 times in skills/firstmate/SKILL.md; it must appear once" \
  "a quote that appears twice is refused with its rule ID"
assert_contains "$out" "R-003: quote is not under heading 'Details' (under another heading)" \
  "a quote under the wrong heading is refused with its rule ID"

# --- evidence -----------------------------------------------------------
t="$(make_tree)"
mutate "$t" "
rule['R-002']['evidence'] = [{'file': 'tools/missing.py', 'text': 'refusing a push'},
                             {'file': 'tools/guard.py', 'text': 'comment only marker'}]
rule['R-005']['evidence'] = [{'file': 'tools/merge.txt', 'text': 'shell comment marker'},
                             {'file': 'tools/merge.txt', 'text': 'slash comment marker'}]"
out="$(gate "$t")"; rc=$?
assert_ne 0 "$rc" "evidence the gate cannot find in code turns it red"
assert_contains "$out" "R-002: evidence tools/missing.py does not exist" "an evidence file that is missing is refused"
assert_contains "$out" "R-002: evidence tools/guard.py: text found only outside a string: 'comment only marker'" \
  "Python evidence found only in a comment is refused"
assert_contains "$out" "R-005: evidence tools/merge.txt: text found only in a comment: 'shell comment marker'" \
  "evidence found only on a # comment line is refused"
assert_contains "$out" "R-005: evidence tools/merge.txt: text found only in a comment: 'slash comment marker'" \
  "evidence found only on a // comment line is refused"

# --- an inventory that cannot be read -----------------------------------
inventory_case() {  # inventory_case <content> <message> <name>: the check stops at the file
  local t out rc
  t="$(make_tree)"
  printf '%s' "$1" > "$t/skills/firstmate/rule-inventory.json"
  out="$(gate "$t")"; rc=$?
  assert_ne 0 "$rc" "$3 turns the gate red"
  assert_contains "$out" "$2" "$3 is refused, naming the inventory file"
  assert_lacks "$out" "no inventory entry" "and the check stops there: $3"
}
inventory_case '{"version": 1, "rules": [' "skills/firstmate/rule-inventory.json: not valid JSON" "invalid JSON"
inventory_case '[]' "skills/firstmate/rule-inventory.json: the top level is not an object" "a top level that is not an object"
inventory_case '{"version": 2, "rules": [], "retired": []}' "skills/firstmate/rule-inventory.json: version is not the integer 1" "version 2"
inventory_case '{"version": "1", "rules": [], "retired": []}' "skills/firstmate/rule-inventory.json: version is not the integer 1" "a version that is a string"
inventory_case '{"version": 1, "retired": []}' "skills/firstmate/rule-inventory.json: rules is missing or not an array" "missing rules"
inventory_case '{"version": 1, "rules": [], "retired": {}}' "skills/firstmate/rule-inventory.json: retired is missing or not an array" "retired that is not an array"
t="$(make_tree)"
rm "$t/skills/firstmate/rule-inventory.json"
out="$(gate "$t")"; rc=$?
assert_ne 0 "$rc" "a missing inventory turns the gate red"
assert_contains "$out" "the inventory: skills/firstmate/rule-inventory.json does not exist" "and is refused, naming the inventory file"

# --- the entries --------------------------------------------------------
t="$(make_tree)"
mutate "$t" "
rule['R-001']['quote'] = 'too short'
rule['R-002']['class'] = 'maybe'
rule['R-003'].pop('proposal')
rule['R-004']['heading'] = 7
rule['R-005'].pop('evidence')
quote = {'file': SKILL, 'heading': 'Duties', 'quote': 'Every round always ends with a written report'}
inv['rules'] += [
    'not an object',
    dict(quote, **{'class': 'judgement'}),
    dict(quote, id='R-12', **{'class': 'judgement'}),
    dict(quote, id='R-003', **{'class': 'judgement'}),
    dict(quote, id='R-007', proposal='', **{'class': 'enforceable'}),
    dict(quote, id='R-008', evidence='tools/guard.py', **{'class': 'enforced'}),
    dict(quote, id=9, **{'class': 'judgement'}),
    {'id': 'R-010', 'file': SKILL, 'heading': 'Duties', 'class': 'judgement'},
    dict(quote, id='R-011', **{'class': 'judgement'}),
]
inv['retired'] = ['R-006', 'X-1', 'R-006', 'R-011']"
out="$(gate "$t")"; rc=$?
assert_ne 0 "$rc" "schema refusals turn the gate red"
assert_contains "$out" "R-001: quote is shorter than 20 characters" "a quote shorter than 20 characters is refused"
assert_contains "$out" "R-002: class 'maybe' is not one of enforced, enforceable, judgement" "an unknown class is refused"
assert_contains "$out" "R-003: an enforceable rule needs a proposal" "an enforceable entry with no proposal is refused"
assert_contains "$out" "R-004: heading must be a string" "a field of the wrong type is refused"
assert_contains "$out" "R-005: an enforced rule needs evidence" "an enforced entry with no evidence is refused"
assert_contains "$out" "rules[5]: not an object" "an entry that is not an object is named by its position"
assert_contains "$out" "rules[6]: missing field id" "an entry without an ID is named by its position"
assert_contains "$out" "rules[7]: id 'R-12' is not R- followed by three or more digits" "an ID of the wrong form is named by its position"
assert_contains "$out" "R-003: id appears more than once in rules" "two entries with the same ID are refused"
assert_contains "$out" "R-007: proposal must be a non-empty string" "an empty proposal is refused"
assert_contains "$out" "R-008: evidence must be a list of objects with string file and text" "evidence that is not a list of objects is refused"
assert_contains "$out" "rules[11]: id must be a string" "an ID that is not a string is named by its position"
assert_contains "$out" "R-010: missing field quote" "a missing field is refused"
assert_contains "$out" "retired[1]: not a rule ID of the form R-001" "a malformed retired item is named by its position"
assert_contains "$out" "retired[2]: R-006 appears more than once in retired" "a repeated retired item is named by its position"
assert_contains "$out" "R-011: id is also in retired" "an ID that is also retired is refused"

# --- paths that leave the tree ------------------------------------------
outside="$work/outside"
mkdir -p "$outside"
printf 'OUTSIDE-SECRET: a reader must never see this line.\n' > "$outside/SKILL.md"
printf 'OUTSIDE-SECRET refusing a push\n' > "$outside/guard.txt"
t="$(make_tree)"
ln -s "$outside/SKILL.md" "$t/skills/firstmate/linked.md"
ln -s "$outside/guard.txt" "$t/tools/linked.txt"
mutate "$t" "
rule['R-001']['file'] = '$outside/SKILL.md'
rule['R-003']['file'] = 'skills/../skills/firstmate/SKILL.md'
rule['R-004']['file'] = 'skills/firstmate/linked.md'
rule['R-002']['evidence'] = [{'file': '$outside/guard.txt', 'text': 'refusing a push'},
                             {'file': 'tools/../tools/guard.py', 'text': 'refusing a push'},
                             {'file': 'tools/linked.txt', 'text': 'refusing a push'}]"
out="$(gate "$t")"; rc=$?
assert_ne 0 "$rc" "a path that leaves the tree turns the gate red"
assert_contains "$out" "R-001: file $outside/SKILL.md is an absolute path" "an absolute inventory file is refused"
assert_contains "$out" "R-003: file skills/../skills/firstmate/SKILL.md holds .." "an inventory file holding .. is refused"
assert_contains "$out" "R-004: file skills/firstmate/linked.md resolves outside the tree" \
  "an inventory file that links outside the tree is refused"
assert_contains "$out" "R-002: evidence $outside/guard.txt is an absolute path" "an absolute evidence file is refused"
assert_contains "$out" "R-002: evidence tools/../tools/guard.py holds .." "an evidence file holding .. is refused"
assert_contains "$out" "R-002: evidence tools/linked.txt resolves outside the tree" \
  "an evidence file that links outside the tree is refused"
assert_lacks "$out" "OUTSIDE-SECRET" "and nothing outside the tree is printed"

# --- when the stage skips -----------------------------------------------
t="$(make_tree)"
rm "$t/skills/firstmate/SKILL.md"
out="$(gate "$t")"
assert_contains "$out" "- rule inventory: no skills/firstmate/SKILL.md (skipped)" \
  "a tree without skills/firstmate/SKILL.md reports the stage as skipped"
t="$(make_tree)"
printf '\nPlanted here: the gate must stay green.\n' >> "$t/skills/firstmate/SKILL.md"
out="$(gate "$t" FM_EXTERNAL=1)"
assert_contains "$out" "- rule inventory: an external project's gate run (skipped)" \
  "with FM_EXTERNAL=1 the stage reports skipped"
assert_lacks "$out" "Planted here" "and prints no text of the skill file"
assert_lacks "$out" "the crew must read this line first" "not even a covered rule"

finish
