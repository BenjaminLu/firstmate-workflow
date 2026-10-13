#!/usr/bin/env bash
# T-303: every self task spec names its door, and the door picks the path. A
# two-way pin's first round builds, with no plan round and no fail-first gate;
# a one-way pin and a two-way spec or diff that touches a path on the
# sensitive list keep the full path; a round that finds the door wrong stops
# its pin. A spec with no door waits on a captain card (T-305,
# tests/door-projects.test.sh).
# Feature dependencies: bin/lib/fm_door.py bin/fm-worker.sh bin/fm-gate.sh
# bin/fm-failfirst.sh bin/lib/fm_spec_pins.py bin/lib/fm_card_spec.py
# bin/lib/fm_autopilot_loop.py bin/lib/fm_ste.py
# bin/lib/fm_self_pr.py config.yaml i18n/glossary.json
# Shared fixtures: tests/lib/worker.sh tests/lib/spec-pins.sh tests/lib.sh
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=tests/lib/worker.sh
. "$ROOT/tests/lib/worker.sh"
# shellcheck source=tests/lib/spec-pins.sh
. "$ROOT/tests/lib/spec-pins.sh"
unset FM_PLAN_FIRST   # tests/lib.sh keeps the older suites build-first
TWO='{"kind":"two-way","reason":"A revert of the merge undoes it."}'
ONE='{"kind":"one-way","reason":"It changes a stored record format."}'

# worker_fixture <door JSON or null> [scope JSON]: a self repo whose task T-Z
# has that door; the mock does what $FM_SEEN/mode says
worker_fixture() {
  d="$(fixture)"; repo="$d/repo"; GH="$(ghstub "$d")"
  # the base list puts the engine on the T-305 rules (tests/door-projects.test.sh)
  printf 'door:\n  base:\n    - "*.sql"\n  sensitive:\n    - ".github/**"\n' >> "$repo/config.yaml"
  # src/ is on the base, so a round's src/ file is no new top-level path (T-305)
  mkdir -p "$repo/src"; printf 'base\n' > "$repo/src/base"; git -C "$repo" add src
  git -C "$repo" commit -qam 'the sensitive list'; git -C "$repo" push -q origin main
  printf '%s\n' '{"type":"greenlit","actor":"captain","ts":"2026-10-13T00:00:00Z"}' > "$repo/state/events.jsonl"
  jq --argjson door "$1" --argjson scope "${2:-[\"src/**\"]}" \
    '.acceptance = ["Why. it exists", "Done, tests. it is proven"] | .scope = $scope
     | if $door == null then del(.door) else .door = $door end' "$repo/design/tasks/T-Z.json" > "$d/spec.json"
  cp "$d/spec.json" "$repo/design/tasks/T-Z.json"
  seed_self_pr_authoring "$repo" T-Z
  cat > "$repo/bin/adapters/mock.sh" <<'M'
#!/usr/bin/env bash
[ "$1" = run ] || exit 64
n=$(( $(find "$FM_SEEN" -maxdepth 1 -name 'prompt-*' | wc -l) + 1 ))
cp "$2" "$FM_SEEN/prompt-$n"
mkdir -p "$3/src"; printf 'round %s\n' "$n" > "$3/src/round-$n"
case "$(cat "$FM_SEEN/mode")" in
  door-change) printf 'This needs a stored format change.\n\nDOOR-CHANGE:T-Z\n' > "$3/.fm-say.md" ;;
  sensitive) mkdir -p "$3/.github/workflows"; printf 'on: push\n' > "$3/.github/workflows/new.yml"
             printf 'Built.\n' > "$3/.fm-say.md" ;;
  *) printf 'Built.\n' > "$3/.fm-say.md" ;;
esac
M
  chmod +x "$repo/bin/adapters/mock.sh"
}
run_worker() {   # run_worker <mode>
  printf '%s' "$1" > "$d/mode"
  (cd "$repo" && FM_ROOT="$repo" FM_GH="$GH" FM_SEEN="$d" bin/fm-worker.sh --task T-Z) > "$d/out" 2>&1
  worker_rc=$?
}
heading() { if grep -qxF -- "$2" "$1" 2>/dev/null; then echo yes; else echo no; fi; }
prompts() { find "$d" -maxdepth 1 -name 'prompt-*' | wc -l | tr -d ' '; }
remote_head() { git --git-dir="$d/remote.git" for-each-ref --format='%(objectname)' 'refs/heads/t-z-*'; }
pin_door() { jq -c '.door' "$repo/state/pins/T-Z/1.json" 2>/dev/null; }

# --- door: two-way builds first ---------------------------------------------
worker_fixture "$TWO"
run_worker build
# Fail-first: main holds every self first round to a plan and pushes nothing.
assert_eq 0 "$worker_rc" 'door: two-way builds first'
assert_ne '' "$(remote_head)" 'the first round of a two-way task is pushed'
assert_eq no "$(heading "$d/prompt-1" '# Read first, then return one plan')" 'it is not asked for a plan'
assert_eq yes "$(heading "$d/prompt-1" '# The door')" 'its prompt names the door'
assert_contains "$(cat "$d/prompt-1")" 'Pin v1 names a two-way door: A revert of the merge undoes it.' 'with the reason the spec gives'
assert_contains "$(tr '\n' ' ' <<<"$(cat "$d/prompt-1")")" 'a REJECT comes back to you under the same round budget as a one-way task' \
  'a two-way REJECT keeps the same round budget'
assert_eq '{"kind":"two-way","reason":"A revert of the merge undoes it.","forced_by":null}' "$(pin_door)" \
  'the pin keeps the door, computed once'
safe_rm_rf "$d"

# --- door: one-way and missing keep the plan -------------------------------
# T-305: a spec with no door no longer keeps the plan; it waits on a captain
# card (door: missing door asks the captain, tests/door-projects.test.sh).
door="$ONE"
worker_fixture "$door"
run_worker build
# Fail-first: main records no door in the pin and names none in the prompt.
assert_eq one-way "$(pin_door | jq -r .kind)" "door: one-way and missing keep the plan ($door)"
assert_eq '' "$(remote_head)" "a first round that builds pushes nothing ($door)"
assert_ne 0 "$worker_rc" "a first round that builds is refused ($door)"
assert_eq yes "$(heading "$d/prompt-1" '# Read first, then return one plan')" "the first round is asked for a plan ($door)"
assert_contains "$(cat "$d/prompt-1")" 'This task takes the one-way path' "the prompt says which path ($door)"
safe_rm_rf "$d"
assert_eq 'The spec names no door, so the task takes the one-way path.' \
  "$(python3 "$ROOT/bin/lib/fm_door.py" effective --spec <(echo '{"id":"T-Z","scope":["src/**"]}') | jq -r .reason)" \
  'a spec with no door is one-way, and says so'
assert_eq one-way "$(python3 "$ROOT/bin/lib/fm_door.py" effective --spec <(echo '{"id":"T-Z","scope":["src/**"],"door":"two-way"}') | jq -r .kind)" \
  'a door that is not a kind and a reason is one-way'
assert_eq one-way "$(jq -n '{external:false, snapshots:{}}' | python3 "$ROOT/bin/lib/fm_door.py" pin | jq -r .kind)" \
  'a pin written before doors is one-way'

# The dispatch card shows the door and its reason, in both languages.
c="$(safe_tmpdir)"; mkdir -p "$c/tasks"
jq -n '{id:"T-Z",scope:["src/**"],explain:{en:{intent:[],done:[],before_nodes:[],after_nodes:[]},
  "zh-TW":{intent:[],done:[],before_nodes:[],after_nodes:[]}}}' > "$c/tasks/T-Z.json"
jq -n '{en:{glossary:[]},"zh-TW":{glossary:[]}}' > "$c/details.json"
card="$(python3 "$ROOT/bin/lib/fm_card_spec.py" --task T-Z --tasks-dir "$c/tasks" --details "$c/details.json" --config "$ROOT/config.yaml")"
assert_eq 'one-way|The spec names no door. The task waits on a captain card and keeps the one-way path.' \
  "$(jq -r '.en.door | .kind + "|" + .reason' <<<"$card")" 'the dispatch card shows the door and its reason'
assert_eq 'one-way|spec 沒寫 door。任務等待決策卡，並走 one-way 流程。' "$(jq -r '."zh-TW".door | .kind + "|" + .reason' <<<"$card")" \
  'and its zh-TW reason'
assert_eq '["door","round"]' "$(jq -c '.en.glossary' <<<"$card")" 'the card explains the terms its door text uses'
jq -n '{en:{intent:[{kind:"fact",text:"It works."}],door:{kind:"two-way",reason:"A revert undoes it.",rollback:"Revert the merge."}},
  "zh-TW":{intent:[{kind:"fact",text:"它可用。"}],door:{kind:"two-way",reason:"還原即可撤銷。",rollback:"還原這次合併。"}}}' > "$c/door-alone.json"
python3 "$ROOT/bin/lib/fm_ste.py" check-details "$c/door-alone.json" > "$c/door-alone.out" 2>&1
assert_lacks "$(cat "$c/door-alone.out")" 'change_points' 'a card may show the door without a change walk'

# --- door: fail-first gate by door -----------------------------------------
# gate_fixture <door JSON> <changed path>: a pinned task whose branch changes
# that path and adds no test
gate_fixture() {
  g="$(safe_tmpdir)"
  export FM_GATE_LOCK="$g/gate.lock"
  git -C "$g" init -q -b main
  git -C "$g" config user.email a@b.c; git -C "$g" config user.name fixture
  mkdir -p "$g/design/tasks" "$g/src/keys"
  echo old > "$g/src/value"; echo old > "$g/src/keys/key"
  echo design > "$g/design/design.md"
  jq -n --argjson door "$1" '{id:"T-X",scope:["src/**"],acceptance:["works"],door:$door}' > "$g/design/tasks/T-X.json"
  printf 'state/\ngate.lock\n' > "$g/.gitignore"
  printf 'door:\n  sensitive:\n    - "src/keys/**"\nproject:\n  check: exit 93\n  tests:\n    - tests/**\n  test: bash {file}\n' > "$g/config.yaml"
  git -C "$g" add -A; git -C "$g" commit -qm base
  seed_spec_pin "$g" T-X
  git -C "$g" checkout -qb work
  echo new > "$g/$2"
  git -C "$g" add -A; git -C "$g" commit -qm feature
  "$ROOT/bin/fm-gate.sh" --repo "$g" --task T-X --branch work --only 4 > "$g.out" 2>&1
  gate_rc=$?
}
gate_fixture "$TWO" src/value
# Fail-first: main runs fail-first on every head; this one adds no test.
assert_eq 0 "$gate_rc" 'door: fail-first gate by door'
assert_contains "$(cat "$g.out")" 'fail-first does not apply to a two-way head' 'the gate says why it passed'
gate_fixture "$ONE" src/value
assert_eq 4 "$gate_rc" 'a one-way head without fail-first evidence is still refused'
assert_contains "$(cat "$g.out")" 'door one-way: It changes a stored record format.' 'the gate names the door it read'

# --- door: sensitive path forces one-way -----------------------------------
gate_fixture "$TWO" src/keys/key
# Fail-first: main reads no sensitive list.
assert_contains "$(cat "$g.out")" 'The diff changes src/keys/key, which is on the sensitive list (src/keys/**)' \
  'door: sensitive path forces one-way'
assert_eq 4 "$gate_rc" 'a two-way head that touches a sensitive path runs fail-first'
worker_fixture "$TWO" '["src/**", ".github/workflows/ci.yml"]'
run_worker build
assert_eq '' "$(remote_head)" 'a two-way spec with a sensitive scope entry keeps the plan'
assert_eq '{"kind":"one-way","forced_by":".github/workflows/ci.yml"}' "$(pin_door | jq -c '{kind,forced_by}')" \
  'its pin is one-way and names the entry'
assert_contains "$(cat "$d/prompt-1")" 'The scope entry .github/workflows/ci.yml is on the sensitive list (.github/**)' \
  'the prompt names the path'
safe_rm_rf "$d"
worker_fixture "$TWO"
run_worker sensitive
# Fail-first: main writes no stop for a two-way round that touches a listed path.
assert_eq '.github/workflows/new.yml' "$(jq -r .forced_by "$repo/state/door-stops/T-Z/1.json" 2>/dev/null)" \
  'door: sensitive diff stops the pin'
assert_eq 0 "$worker_rc" 'the round that touched the path is published'
assert_ne '' "$(remote_head)" 'its work is pushed'
before="$(prompts)"
run_worker build
assert_eq 65 "$worker_rc" 'no further round starts on a pin whose diff touched a listed path'
assert_eq "$before" "$(prompts)" 'no adapter starts on that pin'
assert_contains "$(cat "$d/out")" 'The diff changes .github/workflows/new.yml, which is on the sensitive list (.github/**)' \
  'the refusal names the path'
safe_rm_rf "$d"
worker_fixture "$TWO"
run_worker build
assert_eq '' "$(jq -r '.forced_by // empty' "$repo/state/door-stops/T-Z/1.json" 2>/dev/null)" \
  'a two-way round that touches no listed path writes no stop'
safe_rm_rf "$d"
card="$(jq '.door = {"kind":"two-way","reason":"x"} | .scope = ["bin/fm-merge.sh"]' "$c/tasks/T-Z.json")"
printf '%s\n' "$card" > "$c/tasks/T-Z.json"
assert_contains "$(python3 "$ROOT/bin/lib/fm_card_spec.py" --task T-Z --tasks-dir "$c/tasks" --details "$c/details.json" \
  --config "$ROOT/config.yaml" | jq -r '.en.door.reason')" 'bin/fm-merge.sh is on the sensitive list' \
  'the dispatch card names the sensitive path from the engine list'
# CI reads the door from the pull request body the launcher rendered
ci="$(safe_tmpdir)"
git -C "$ci" init -q -b main; git -C "$ci" config user.email a@b.c; git -C "$ci" config user.name fixture
mkdir -p "$ci/bin/keys"; echo old > "$ci/bin/run.sh"; echo old > "$ci/bin/keys/key"
printf 'door:\n  sensitive:\n    - "bin/keys/**"\nproject:\n  test: bash {file}\n' > "$ci/config.yaml"
git -C "$ci" add -A; git -C "$ci" commit -qm base
jq -n --arg b "$(printf 'Why.\n\n%s\n' "$(python3 -c 'import sys; sys.path.insert(0, sys.argv[1]); import fm_door
print(fm_door.body_line({"kind": "two-way", "reason": "A revert undoes it."}, 1))' "$ROOT/bin/lib")")" \
  '{pull_request:{body:$b}}' > "$ci/event.json"
git -C "$ci" checkout -qb work; echo new > "$ci/bin/run.sh"; git -C "$ci" commit -qam behaviour
out="$(cd "$ci" && GITHUB_EVENT_PATH="$ci/event.json" bash "$ROOT/bin/fm-failfirst.sh" main 2>&1)"
assert_eq 0 "$?" 'CI passes a two-way head without fail-first evidence'
assert_contains "$out" 'door: read two-way from the pull request body' 'the CI line says which door it read'
echo new > "$ci/bin/keys/key"; git -C "$ci" commit -qam key
out="$(cd "$ci" && GITHUB_EVENT_PATH="$ci/event.json" bash "$ROOT/bin/fm-failfirst.sh" main 2>&1)"
assert_eq 1 "$?" 'CI runs fail-first when the diff touches a sensitive path'
assert_contains "$out" 'bin/keys/key is on the sensitive list' 'and names the path'
jq '.pull_request.body = "Door: two-way — not recorded."' "$ci/event.json" > "$ci/old.json"
git -C "$ci" reset -q --hard HEAD~1
out="$(cd "$ci" && GITHUB_EVENT_PATH="$ci/old.json" bash "$ROOT/bin/fm-failfirst.sh" main 2>&1)"
assert_eq 1 "$?" 'a body rendered before doors names no pin, so CI runs fail-first'
safe_rm_rf "$ci"

# --- door: change stops the task -------------------------------------------
worker_fixture "$TWO"
run_worker door-change
# Fail-first: main reads no DOOR-CHANGE line and starts the next round.
assert_eq 0 "$worker_rc" 'the round that finds the door wrong is published'
assert_ne '' "$(remote_head)" 'its work is pushed'
assert_eq 1 "$(jq -r .version "$repo/state/door-stops/T-Z/1.json" 2>/dev/null)" 'the stop names the pin'
before="$(prompts)"
run_worker build
assert_eq 65 "$worker_rc" 'door: change stops the task'
assert_eq "$before" "$(prompts)" 'no adapter starts on the stopped pin'
assert_contains "$(cat "$d/out")" 'found its door wrong; no round starts on pin v1' 'the refusal says why'
held="$(python3 - "$ROOT/bin/lib" "$repo/state" <<'PY'
import sys
from pathlib import Path
from types import SimpleNamespace
sys.path.insert(0, sys.argv[1])
from fm_autopilot_loop import MechanicalLoop as Loop
calls = []
fake = SimpleNamespace(state=Path(sys.argv[2]), queue=lambda ident, *a: calls.append(('event', ident)),
                       start_job=lambda *a, **k: calls.append(('job',)), job_for=lambda *a: None)
fake.door_hold = lambda task: Loop.door_hold(fake, task)
pr = {'number': 7, 'head': {'sha': 'a' * 40}}
Loop.launch_review(fake, 'T-Z', pr)
Loop.launch_design_review(fake, 'T-Z', pr)
Loop.merge_card(fake, 'T-Z', pr, 'b' * 40)
print(len([c for c in calls if c[0] == 'job']), len({c[1] for c in calls if c[0] == 'event'}))
PY
)"
assert_eq '0 1' "$held" 'the autopilot raises no review and no merge card, and says why in one event'
safe_rm_rf "$d"

# --- glossary --------------------------------------------------------------
assert_eq 'door|door' "$(jq -r '.terms[] | select(.id == "door") | [.en.term, (."zh-TW".aliases[] | select(. == "door"))] | join("|")' "$ROOT/i18n/glossary.json")" \
  'the glossary names door in every locale'
safe_rm_rf "$c"; safe_rm_rf "$g"; rm -f "$g.out"
finish
