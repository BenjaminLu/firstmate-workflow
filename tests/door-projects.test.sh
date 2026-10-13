#!/usr/bin/env bash
# T-305: every project decides each task's door from the engine's base list
# plus its own approved list, and a task whose door cannot be decided waits
# on a captain card that names the reason, in en and zh-TW.
# Feature dependencies: bin/lib/fm_door.py bin/fm-worker.sh bin/fm-gate.sh
# bin/fm-decide.sh bin/lib/fm_spec_pins.py bin/lib/fm_card_spec.py
# bin/lib/fm_registry.py bin/lib/fm_onboard.py config.yaml i18n/glossary.json
# Shared fixtures: tests/lib/worker.sh tests/lib/spec-pins.sh tests/lib.sh
# tests/lib/door_projects.py
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=tests/lib/worker.sh
. "$ROOT/tests/lib/worker.sh"
# shellcheck source=tests/lib/spec-pins.sh
. "$ROOT/tests/lib/spec-pins.sh"
unset FM_PLAN_FIRST   # tests/lib.sh keeps the older suites build-first
TWO='{"kind":"two-way","reason":"A revert of the merge undoes it."}'

# --- door: missing door asks the captain (the self project) ----------------
d="$(fixture)"; repo="$d/repo"; GH="$(ghstub "$d")"
cp "$ROOT/bin/fm-decide.sh" "$repo/bin/"
# an engine whose config declares door.base takes the T-305 rules
printf 'door:\n  base:\n    - "*.sql"\n' >> "$repo/config.yaml"
git -C "$repo" commit -qam 'the base list'; git -C "$repo" push -q origin main
seed_self_pr_authoring "$repo" T-Z
printf '%s\n' '{"type":"greenlit","actor":"captain","ts":"2026-10-13T00:00:00Z"}' > "$repo/state/events.jsonl"
cat > "$repo/bin/adapters/mock.sh" <<'M'
#!/usr/bin/env bash
[ "$1" = run ] || exit 64
cp "$2" "$FM_SEEN/prompt"; printf 'The plan.\n' > "$3/.fm-say.md"
M
chmod +x "$repo/bin/adapters/mock.sh"
run_worker() {
  rm -f "$d/prompt"
  (cd "$repo" && FM_ROOT="$repo" FM_GH="$GH" FM_SEEN="$d" bin/fm-worker.sh --task T-Z) > "$d/out" 2>&1
  worker_rc=$?
}
run_worker
# Fail-first: main pins a spec with no door one-way and starts its round.
assert_eq 65 "$worker_rc" 'door: missing door asks the captain'
assert_eq no "$([ -f "$d/prompt" ] && echo yes || echo no)" 'no round starts on a pin with no door'
assert_eq no-door "$(jq -r '.door_ask.signal' "$repo/state/pins/T-Z/1.json" 2>/dev/null)" 'the pin records why it cannot decide'
assert_contains "$(cat "$d/out")" 'cannot decide its door: The spec names no door.' 'the launcher says why'
card="$(jq -r '.card // empty' "$repo/state/door-stops/T-Z/1.pin.json" 2>/dev/null)"
assert_ne '' "$card" 'the launcher raises a captain card'
pending="$repo/state/pending/$card.json"
assert_eq 'The spec names no door.' "$(jq -r '.details.en.why[0].text' "$pending" 2>/dev/null)" 'the card names the signal'
assert_eq 'spec 沒寫 door。' "$(jq -r '.details."zh-TW".why[0].text' "$pending" 2>/dev/null)" 'and names it in zh-TW'
assert_eq 'Take the one-way path.|Revise the spec.' \
  "$(jq -r '.details.en.options | .A.description + "|" + .B.description' "$pending" 2>/dev/null)" \
  'A takes the one-way path and B revises the spec'
printf '{"id":"%s","task":"T-Z","kind":"choice","chosen":"A","ts":"2026-10-13T01:00:00Z"}\n' "$card" \
  > "$repo/state/decisions/$card.json"
run_worker
assert_eq yes "$(grep -qxF '# Read first, then return one plan' "$d/prompt" 2>/dev/null && echo yes || echo no)" \
  'after A the task takes the one-way path, plan round first'
safe_rm_rf "$d"

# A dispatch card refuses a spec without a door: firstmate writes the spec.
c="$(safe_tmpdir)"; mkdir -p "$c/tasks"
jq -n '{id:"T-Z",scope:["src/**"],explain:{en:{intent:[],done:[],before_nodes:[],after_nodes:[]},
  "zh-TW":{intent:[],done:[],before_nodes:[],after_nodes:[]}}}' > "$c/tasks/T-Z.json"
jq -n '{en:{glossary:[]},"zh-TW":{glossary:[]}}' > "$c/details.json"
python3 "$ROOT/bin/lib/fm_card_spec.py" --task T-Z --tasks-dir "$c/tasks" --details "$c/details.json" \
  --config "$ROOT/config.yaml" --purpose dispatch > "$c/out" 2>&1
assert_eq 65 "$?" 'a dispatch card refuses a spec with no door'
assert_contains "$(cat "$c/out")" 'the spec names no door' 'and says which'
jq '.door = "two-way"' "$c/tasks/T-Z.json" > "$c/bad.json"; mv "$c/bad.json" "$c/tasks/T-Z.json"
python3 "$ROOT/bin/lib/fm_card_spec.py" --task T-Z --tasks-dir "$c/tasks" --details "$c/details.json" \
  --config "$ROOT/config.yaml" --purpose dispatch > "$c/out" 2>&1
assert_contains "$(cat "$c/out")" 'the spec door is not a kind and a reason' 'a malformed door is refused by name'
safe_rm_rf "$c"

# --- door: base list applies to every project (the self project) ----------
# gate_head <changed path...>: gate 4 on a two-way self pin whose own list
# leaves out the base list's paths
gate_head() {
  g="$(safe_tmpdir)"
  export FM_GATE_LOCK="$g/gate.lock"
  git -C "$g" init -q -b main
  git -C "$g" config user.email a@b.c; git -C "$g" config user.name fixture
  mkdir -p "$g/design/tasks" "$g/src" "$g/db"
  echo old > "$g/src/value"; echo old > "$g/db/schema"; echo design > "$g/design/design.md"
  jq -n --argjson door "$TWO" '{id:"T-X",scope:["src/**","db/**"],acceptance:["works"],door:$door}' > "$g/design/tasks/T-X.json"
  printf 'state/\ngate.lock\n' > "$g/.gitignore"
  printf 'door:\n  base:\n    - "*.sql"\n  sensitive:\n    - "src/keys/**"\nproject:\n  check: exit 93\n  tests:\n    - tests/**\n  test: bash {file}\n' > "$g/config.yaml"
  git -C "$g" add -A; git -C "$g" commit -qm base
  seed_spec_pin "$g" T-X
  git -C "$g" checkout -qb work
  for path in "$@"; do mkdir -p "$g/$(dirname "$path")"; echo new > "$g/$path"; done
  git -C "$g" add -A; git -C "$g" commit -qm feature
  "$ROOT/bin/fm-gate.sh" --repo "$g" --task T-X --branch work --only 4 > "$g.out" 2>&1
  gate_rc=$?
}
gate_head db/add.sql
# Fail-first: main reads only door.sensitive, so the head stays two-way.
assert_contains "$(cat "$g.out")" 'The diff changes db/add.sql, which is on the sensitive list (*.sql)' \
  'door: base list applies to every project'
assert_eq 4 "$gate_rc" 'a base-list path runs fail-first on the self project'
assert_eq '["*.sql"]' "$(jq -c '.door_lists.base' "$g/state/pins/T-X/1.json")" 'the pin keeps the lists it was decided with'
safe_rm_rf "$g"; rm -f "$g.out"
gate_head src/value2
assert_eq 0 "$gate_rc" 'a two-way head inside its lists skips fail-first'
safe_rm_rf "$g"; rm -f "$g.out"

# --- door: unclassified path asks the captain (what counts) ----------------
# A new top-level path, a rename and a submodule: each makes a two-way head
# one-way at the gate, and the gate names it.
u="$(safe_tmpdir)"
git -C "$u" init -q -b main; git -C "$u" config user.email a@b.c; git -C "$u" config user.name fixture
mkdir -p "$u/src"; printf 'one\ntwo\nthree\nfour\n' > "$u/src/old"
git -C "$u" add -A; git -C "$u" commit -qm base
pin='{"external":true,"door":{"kind":"two-way","reason":"r","forced_by":null},"door_lists":{"base":[],"project":["src/keys/**"]}}'
odd() {   # odd <branch>: the gate's door for that branch
  python3 "$ROOT/bin/lib/fm_door.py" gate --repo "$u" --base main --head "$1" <<<"$pin" | jq -r '.kind + "|" + .en'
}
git -C "$u" checkout -qb top; mkdir -p "$u/tools"; echo x > "$u/tools/run"; git -C "$u" add -A; git -C "$u" commit -qm top
assert_eq 'one-way|The diff adds `tools`, a new top-level path that no list can classify.' "$(odd top)" \
  'a new top-level path is unclassified'
git -C "$u" checkout -q main; git -C "$u" checkout -qb renamed; git -C "$u" mv src/old src/new; git -C "$u" commit -qm mv
assert_eq 'one-way|The diff renames `src/old` to `src/new`, which no list can classify.' "$(odd renamed)" \
  'a renamed file is unclassified'
git -C "$u" checkout -q main; git -C "$u" checkout -qb sub
git -C "$u" update-index --add --cacheinfo 160000,"$(git -C "$u" rev-parse main)",src/vendored
git -C "$u" commit -qm sub
assert_eq 'one-way|The diff changes the submodule `src/vendored`, which no list can classify.' "$(odd sub)" \
  'a submodule is unclassified'
git -C "$u" checkout -q main; git -C "$u" checkout -qb plain; echo y > "$u/src/more"; git -C "$u" add -A; git -C "$u" commit -qm plain
assert_eq two-way "$(odd plain | cut -d'|' -f1)" 'a new file in a known folder stays two-way'
safe_rm_rf "$u"

# --- the external project: real worker rounds ------------------------------
x="$(safe_tmpdir)"
python3 "$ROOT/tests/lib/door_projects.py" "$ROOT" > "$x/out" 2>&1 || true
ran() { if grep -q "^$1 .* ok$" "$x/out"; then echo ok; else echo failed; fi; }
assert_eq ok "$(ran test_external_two_way_builds_first)" 'door: external two-way builds first'
assert_eq ok "$(ran test_no_list_asks_the_captain)" 'door: no list asks the captain'
assert_eq ok "$(ran test_hand_edited_list_counts_as_no_list)" 'a hand-edited list counts as no list'
assert_eq ok "$(ran test_missing_door_asks_the_captain)" 'door: missing door asks the captain (external)'
assert_eq ok "$(ran test_unclassified_path_asks_the_captain)" 'door: unclassified path asks the captain'
assert_eq ok "$(ran test_base_list_applies_to_an_external_project)" 'door: base list applies to every project (external)'
grep -q '^OK$' "$x/out" || tail -60 "$x/out"
safe_rm_rf "$x"
finish
