#!/usr/bin/env bash
# T-276: every task gets a review round budget that stops for the captain.
# Feature dependencies: bin/lib/fm_round_budget.py bin/lib/fm_autopilot_loop.py bin/fm-worker.sh bin/fm-decide.sh
# Shared fixtures: tests/lib/round_budget.py tests/lib/autopilot_branch_fixture.py tests/lib/worker.sh
#   tests/lib/spec-preflight.sh tests/lib/binding-fixture.sh tests/lib/project-storage.sh
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=tests/lib/worker.sh
. "$ROOT/tests/lib/worker.sh"
# shellcheck source=tests/lib/binding-fixture.sh
. "$ROOT/tests/lib/binding-fixture.sh"
# shellcheck source=tests/lib/project-storage.sh
. "$ROOT/tests/lib/project-storage.sh"

PYTHONDONTWRITEBYTECODE=1 python3 "$ROOT/tests/lib/round_budget.py" "$ROOT"
assert_eq 0 "$?" 'budget state, cards, answers, holds, autopilot, privacy and tw2cn cases pass'

# --- the worker launcher refuses a stopped task before it allocates a round ---
d="$(fixture)"; repo="$d/repo"; GH="$(ghstub "$d")"
cat > "$repo/bin/adapters/mock.sh" <<'M'
#!/usr/bin/env bash
[ "$1" = run ] || exit 64
printf 'called\n' > "$FM_SEEN/called"
exit 1
M
chmod +x "$repo/bin/adapters/mock.sh"
run_worker() {
  rm -f "$d/called"
  (cd "$repo" && FM_ROOT="$repo" FM_GH="$GH" FM_SEEN="$d" bin/fm-worker.sh --task T-Z) > "$d/out" 2>&1
  worker_rc=$?
}
snapshot() {   # what a refused launch must leave exactly as it was
  {
    cat "$repo/state/events.jsonl" 2>/dev/null
    find "$repo/state" -name identity.json 2>/dev/null | sort
    git -C "$repo" status --porcelain --untracked-files=all -- . ':!state' ':(exclude,glob)**/__pycache__/**'
    [ -d "$repo/state/worktrees/T-Z" ] && git -C "$repo/state/worktrees/T-Z" status --porcelain 2>/dev/null
    find "$repo/state/worktrees" -maxdepth 1 2>/dev/null | sort
    git -C "$repo" for-each-ref --format='%(refname) %(objectname)'
  } > "$1"
}
seed() { python3 "$ROOT/tests/lib/round_budget.py" "$ROOT" seed "$repo/state" self T-Z "$1" "$2"; }

# A configuration error is refused before any round, like a stopped task.
commit_config() { git -C "$repo" commit -qam "$1" && git -C "$repo" push -q origin main; }
printf 'review_budget:\n  rounds: 0\n' >> "$repo/config.yaml"
commit_config 'invalid budget'
snapshot "$d/before"
run_worker
assert_eq 65 "$worker_rc" 'an invalid review_budget refuses the launch'
assert_contains "$(cat "$d/out")" 'review_budget.rounds must be a whole number from 1 to 99' 'the error names the key'
snapshot "$d/after"
assert_ok "cmp '$d/before' '$d/after'" 'a refused launch writes no identity, event, worktree or ref'
assert_ok "test ! -e '$d/called'" 'a refused launch starts no vendor'

# The same non-default values, set once in the engine config, reach both consumers.
sed -i.bak '/^review_budget:/,$d' "$repo/config.yaml"; rm -f "$repo/config.yaml.bak"
printf 'review_budget:\n  rounds: 4\n  stall: 3\n  extend: 5\n' >> "$repo/config.yaml"
commit_config 'budget'
seed_self_pr_authoring "$repo" T-Z
for n in 1 2 3; do seed "$n" "$(printf '%040d' "$n")"; done
consumer="$(python3 "$ROOT/tests/lib/round_budget.py" "$ROOT" consumer "$repo" "$repo/state" self T-Z)"
assert_eq '{"rounds":4,"stall":3,"extend":5}' "$(jq -c '.config' <<<"$consumer")" \
  'the autopilot reads the engine config.yaml'
assert_eq within "$(jq -r '.state' <<<"$consumer")" 'three of four rounds are within the budget'
run_worker
assert_ok "test -s '$d/called'" 'the worker check reads rounds: 4 and starts round four'
seed 4 "$(printf '%040d' 4)"
assert_eq stop "$(python3 "$ROOT/tests/lib/round_budget.py" "$ROOT" consumer "$repo" "$repo/state" self T-Z | jq -r .state)" \
  'the autopilot stops at the fourth marked REJECT'
snapshot "$d/before"
run_worker
# Fail-first: main starts the round.
assert_eq 65 "$worker_rc" 'the worker launcher refuses a stopped task'
assert_contains "$(cat "$d/out")" 'no card was raised yet' 'the refusal says no card was raised yet'
snapshot "$d/after"
assert_ok "cmp '$d/before' '$d/after'" 'the refusal writes no identity, emits no event and changes no worktree'
assert_ok "test ! -e '$d/called'" 'the refusal starts no vendor'
safe_rm_rf "$d"

# --- built card details pass the STE check and a real fm-decide.sh request ---
o="$(safe_tmpdir)"; mkdir -p "$o/bin" "$o/state" "$o/i18n" "$o/board/public"
cp "$ROOT/bin/fm-emit.sh" "$ROOT/bin/fm-decide.sh" "$ROOT/bin/fm-diagram.sh" "$o/bin/"
project_storage_fixture "$o/bin/"
cp -R "$ROOT/bin/lib" "$o/bin/"
binding_service_fixture "$o"
cp "$ROOT/i18n/ui.en.json" "$ROOT/i18n/ui.zh-TW.json" "$ROOT/i18n/tw2cn.tsv" "$ROOT/i18n/glossary.json" "$o/i18n/"
printf 'concurrency: 3\n' > "$o/config.yaml"
python3 "$ROOT/tests/lib/round_budget.py" "$ROOT" details T-001 "$o/details.json"
python3 "$ROOT/bin/lib/fm_ste.py" check-details --kind choice "$o/details.json" > "$o/ste.json" 2> "$o/ste.err"
assert_eq 0 "$?" '30 open items in 12 rounds pass check-details --kind choice'
assert_eq true "$(jq '.ok' "$o/ste.json")" 'no failing STE rule'
id="$(FM_ROOT="$o" bash "$o/bin/fm-decide.sh" --allocate --task T-001 --project firstmate-workflow 2>"$o/allocate.err")"
assert_eq D-firstmate-workflow-T001-1 "$id" 'the card id is allocated for the task'
FM_ROOT="$o" "$o/bin/fm-decide.sh" --request "$id" --task T-001 --project firstmate-workflow --purpose decision \
  --details "$o/details.json" > "$o/request.out" 2> "$o/request.err"
assert_eq 0 "$?" 'a real fm-decide.sh request accepts the built details'
assert_ok "test -s '$o/state/pending/$id.json'" 'the card is pending for the captain'
safe_rm_rf "$o"
finish
