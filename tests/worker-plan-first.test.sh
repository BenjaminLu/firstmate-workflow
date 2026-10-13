#!/usr/bin/env bash
# T-302: a self worker's first round on a spec's bytes changes no file and
# returns one plan with a proof row for every done line; the next round
# builds only after firstmate accepts the plan; a round that fixes a problem
# lists the places it checked for the same cause. Nothing else is published.
# Feature dependencies: bin/fm-worker.sh bin/lib/fm_plan.py
# bin/lib/fm_evidence.py bin/lib/fm_first_round.py skills/worker/SKILL.md
# Shared fixtures: tests/lib/worker.sh tests/lib.sh
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=tests/lib/worker.sh
. "$ROOT/tests/lib/worker.sh"
unset FM_PLAN_FIRST   # tests/lib.sh keeps the older suites build-first
d="$(fixture)"; repo="$d/repo"; GH="$(ghstub "$d")"
printf '%s\n' '{"type":"greenlit","actor":"captain","ts":"2026-10-12T00:00:00Z"}' > "$repo/state/events.jsonl"
jq '.acceptance = ["Why. it exists", "Done, tests. it is proven"]' "$repo/design/tasks/T-Z.json" > "$d/spec.json"
cp "$d/spec.json" "$repo/design/tasks/T-Z.json"
seed_self_pr_authoring "$repo" T-Z
# The mock does what $FM_SEEN/mode says: plan, plan-short, plan-edit,
# build (with its SWEPT block), build-bare (without it) or report (the
# SWEPT block alone, for the report-only round after a refused report).
cat > "$repo/bin/adapters/mock.sh" <<'M'
#!/usr/bin/env bash
[ "$1" = run ] || exit 64
n=$(( $(find "$FM_SEEN" -maxdepth 1 -name 'prompt-*' | wc -l) + 1 ))
cp "$2" "$FM_SEEN/prompt-$n"
mode="$(cat "$FM_SEEN/mode")"
case "$mode" in plan-edit|build|build-bare)
  mkdir -p "$3/src"; printf 'round %s\n' "$n" > "$3/src/round-$n" ;;
esac
case "$mode" in
  plan|plan-edit)
    printf 'Files: src/x\n\n| 1 | see 2 | - | - |\n| 2 | tests/x.test.sh | ci | no file |\n' > "$3/.fm-say.md" ;;
  plan-short) printf 'Files: src/x\n\n| 1 | see 2 | - | - |\n' > "$3/.fm-say.md" ;;
  build|report) printf 'Built.\n\nSWEPT:T-Z missing files\n  searched: ls src\n  found 1, fixed 1\n' > "$3/.fm-say.md" ;;
  build-bare) printf 'Built.\n' > "$3/.fm-say.md" ;;
esac
M
chmod +x "$repo/bin/adapters/mock.sh"
run_worker() {   # run_worker <mode>
  printf '%s' "$1" > "$d/mode"
  (cd "$repo" && FM_ROOT="$repo" FM_GH="$GH" FM_SEEN="$d" bin/fm-worker.sh --task T-Z) > "$d/out" 2>&1
  worker_rc=$?
}
heading() {   # heading <prompt file> <line>: yes when the prompt has that exact line;
  # the worker skill in every prompt names the same sections one level down
  if grep -qxF -- "$2" "$1" 2>/dev/null; then echo yes; else echo no; fi
}
prompts() { find "$d" -maxdepth 1 -name 'prompt-*' | wc -l | tr -d ' '; }
remote_head() { git --git-dir="$d/remote.git" for-each-ref --format='%(objectname)' 'refs/heads/t-z-*'; }
evidence() {   # evidence <fm_evidence arguments...>, as firstmate runs it
  (cd "$repo" && unset FM_RUN_DIR && . bin/fm-config.sh && fm_storage_init "$repo" && TASK=T-Z fm_evidence "$@")
}

# --- worker: first round changes nothing ---------------------------------
run_worker plan-edit
# Fail-first: main builds in the first round and pushes the branch.
assert_eq '' "$(remote_head)" 'worker: first round changes nothing'
assert_ne 0 "$worker_rc" 'a first round that changes a file is refused'
assert_contains "$(cat "$d/out")" 'a first round changes no file' 'the refusal says why'
assert_eq yes "$(heading "$d/prompt-1" '# Read first, then return one plan')" 'the first round is told to return one plan'
assert_contains "$(cat "$d/prompt-1")" '2. Done, tests. it is proven' 'the prompt numbers the done lines'
patch="$(find "$d" -path '*/rescued/*.patch' | head -1)"
assert_ok "test -s '$patch'" 'the change is saved as a patch'
assert_contains "$(cat "$patch" 2>/dev/null)" 'src/round-1' 'the patch holds the new file'
tree="$(git -C "$repo" worktree list --porcelain | sed -n 's/^worktree //p' | grep -v "^$repo\$" | head -1)"
assert_fail "test -e '$tree/src/round-1'" 'the tree is restored'
assert_lacks "$(cat "$d/ghcalls" 2>/dev/null)" 'pr create' 'no pull request is opened'

# --- worker: plan covers every done line ---------------------------------
run_worker plan-short
# Fail-first: main does not read the plan at all.
assert_contains "$(cat "$d/out")" 'the plan has no row for done line 2' 'worker: plan covers every done line'
assert_ne 0 "$worker_rc" 'a plan with a missing row is refused'
assert_eq yes "$(heading "$d/prompt-2" '# Read first, then return one plan')" 'a refused plan is asked for again'
run_worker plan
assert_eq 0 "$worker_rc" 'a plan with every row is returned'
assert_contains "$(cat "$d/out")" 'nothing is pushed until firstmate accepts it' 'the plan round says it waits'
assert_eq '' "$(remote_head)" 'a plan round pushes nothing'
plan_row="$(evidence summary | jq -c '[.[] | select(.kind == "worker-report" or .kind == "ask")] | last')"
plan_r="$(jq -r .round <<<"$plan_row")"; plan_h="$(jq -r .head <<<"$plan_row")"

# --- worker: build after accepted plan -----------------------------------
before="$(prompts)"
run_worker build
# Fail-first: main starts the build round on any plan.
assert_eq 65 "$worker_rc" 'worker: build after accepted plan'
assert_eq "$before" "$(prompts)" 'no adapter starts on an unaccepted plan'
assert_contains "$(cat "$d/out")" "accept-plan --round $plan_r --head $plan_h" 'the refusal says how firstmate accepts it'
printf 'Answer 1: use src/.\n' > "$d/answers.md"
evidence accept-plan --round "$plan_r" --head "$plan_h" --file "$d/answers.md" > "$d/accept" 2>&1
assert_eq 0 "$?" 'firstmate accepts the plan'
assert_fail "evidence accept-plan --round 99 --head '$plan_h' --file '$d/answers.md'" 'a round with no plan cannot be accepted'
run_worker build
assert_eq 0 "$worker_rc" 'the build round starts on an accepted plan'
assert_ne "$before" "$(prompts)" 'its adapter ran'
build_prompt="$d/prompt-$(prompts)"
assert_eq yes "$(heading "$build_prompt" '# Your plan was accepted')" 'the build round is told its plan was accepted'
assert_eq yes "$(heading "$build_prompt" 'Answer 1: use src/.')" 'and is given the answers'
assert_eq yes "$(heading "$build_prompt" '# Fix the whole class')" 'an answer is fixed as a class'
assert_ne '' "$(remote_head)" 'the build is pushed'

# --- worker: fix lists its class -----------------------------------------
pushed="$(remote_head)"
(cd "$repo" && . bin/fm-config.sh && fm_storage_init "$repo" && python3 - "$FM_STATE_DIR" "$(fm_evidence_project)" "$pushed" <<'PY'
import sys
sys.path.insert(0, 'bin/lib')
from fm_evidence import Store
Store(sys.argv[1], sys.argv[2], 'T-Z', external=False).append(
    'verdict', 1, 'reviewer-x', sys.argv[3], 'REJECT:T-Z\n1. fix it\nCRITERIA-COMPLETE:T-Z',
    provenance={'level': 'legacy'}, verdict='REJECT')
PY
) > "$d/verdict" 2>&1
assert_eq 0 "$?" 'the fixture records a REJECT'
run_worker build-bare
# Fail-first: main publishes a fix whatever its report says.
assert_eq "$pushed" "$(remote_head)" 'worker: fix lists its class'
assert_ne 0 "$worker_rc" 'a fix report without its class is refused'
assert_contains "$(cat "$d/out")" 'no complete SWEPT:T-Z block' 'the refusal names the missing block'
assert_contains "$(cat "$d/prompt-$(prompts)")" 'This round fixes a problem (reject)' 'the round after a REJECT is told to fix the class'
run_worker report
assert_eq 0 "$worker_rc" 'a fix report with its class is published'
# T-304: the round after a refused report fixes only the report.
assert_eq yes "$(heading "$d/prompt-$(prompts)" '# Fix only your report')" 'a refused fix does not end the fix round'
assert_ne "$pushed" "$(remote_head)" 'the fix is pushed'
safe_rm_rf "$d"

# --- a task already in flight goes on as before ---------------------------
d="$(fixture)"; repo="$d/repo"; GH="$(ghstub "$d")"
printf '%s\n' '{"type":"greenlit","actor":"captain","ts":"2026-10-12T00:00:00Z"}' > "$repo/state/events.jsonl"
cat > "$repo/bin/adapters/mock.sh" <<'M'
#!/usr/bin/env bash
[ "$1" = run ] || exit 64
n=$(( $(find "$FM_SEEN" -maxdepth 1 -name 'prompt-*' | wc -l) + 1 ))
cp "$2" "$FM_SEEN/prompt-$n"
mkdir -p "$3/src"; printf 'round %s\n' "$n" > "$3/src/round-$n"
M
chmod +x "$repo/bin/adapters/mock.sh"
(cd "$repo" && FM_PLAN_FIRST=0 FM_ROOT="$repo" FM_GH="$GH" FM_SEEN="$d" bin/fm-worker.sh --task T-Z) > "$d/out" 2>&1
assert_eq 0 "$?" 'a first round from an older launcher builds'
(cd "$repo" && FM_ROOT="$repo" FM_GH="$GH" FM_SEEN="$d" bin/fm-worker.sh --task T-Z) > "$d/out" 2>&1
assert_eq 0 "$?" 'its next round builds as before, with no plan'
assert_eq no "$(heading "$d/prompt-2" '# Read first, then return one plan')" 'and is not asked for one'
safe_rm_rf "$d"
finish
