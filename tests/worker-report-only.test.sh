#!/usr/bin/env bash
# T-304: a fix round refused only for its report keeps its work in the tree
# and pushes nothing; the next round is report-only: it is shown the refusal
# and its own report, fixes the report and changes no file, and the launcher
# publishes the kept work with it. A launch keeps that work in place whether
# or not the task has a pull request.
# Feature dependencies: bin/fm-worker.sh bin/lib/fm_plan.py
# bin/lib/fm_evidence.py skills/worker/SKILL.md tests/gh-stub.sh
# Shared fixtures: tests/lib/worker.sh tests/lib.sh
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=tests/lib/worker.sh
. "$ROOT/tests/lib/worker.sh"
unset FM_PLAN_FIRST   # tests/lib.sh keeps the older suites build-first
# The mock does what $FM_SEEN/mode says: plan; build or build-bare (a new
# file, with or without its SWEPT block); report (the SWEPT block alone,
# with a detail line); report-edit (the block and a code change). It lists
# the tree's src/ as it found it, so a suite sees what the round was given.
setup() {   # setup: a fresh fixture whose plan is accepted with answers, so its build round is a fix round
  d="$(fixture)"; repo="$d/repo"; tree="$repo/state/worktrees/T-Z"
  # A gh that remembers: the pull request the first push opens is found again.
  export GHSTATE="$d/ghstate"
  printf '%s\n' '{"type":"greenlit","actor":"captain","ts":"2026-10-13T00:00:00Z"}' > "$repo/state/events.jsonl"
  jq '.acceptance = ["Why. it exists", "Done, tests. it is proven"]' "$repo/design/tasks/T-Z.json" > "$d/spec.json"
  cp "$d/spec.json" "$repo/design/tasks/T-Z.json"
  seed_self_pr_authoring "$repo" T-Z
  cat > "$repo/bin/adapters/mock.sh" <<'M'
#!/usr/bin/env bash
[ "$1" = run ] || exit 64
n=$(( $(find "$FM_SEEN" -maxdepth 1 -name 'prompt-*' | wc -l) + 1 ))
cp "$2" "$FM_SEEN/prompt-$n"
ls "$3/src" > "$FM_SEEN/seen-$n" 2>/dev/null
mode="$(cat "$FM_SEEN/mode")"
case "$mode" in build|build-bare|report-edit)
  mkdir -p "$3/src"; printf 'round %s\n' "$n" > "$3/src/round-$n" ;;
esac
case "$mode" in
  plan) printf 'Files: src/x\n\n| 1 | see 2 | - | - |\n| 2 | tests/x.test.sh | ci | no file |\n' > "$3/.fm-say.md" ;;
  build) printf 'Built.\n\nSWEPT:T-Z missing files\n  searched: ls src\n  found 1, fixed 1\n' > "$3/.fm-say.md" ;;
  report|report-edit)
    printf 'Built.\n\nSWEPT:T-Z missing files\n  searched: ls src\n  found 1 (src/), fixed 1\n' > "$3/.fm-say.md" ;;
  build-bare) printf 'Built.\n' > "$3/.fm-say.md" ;;
esac
M
  chmod +x "$repo/bin/adapters/mock.sh"
  run_worker plan
  assert_eq 0 "$worker_rc" 'the fixture returns a plan'
  plan_row="$(evidence summary | jq -c '[.[] | select(.kind == "worker-report" or .kind == "ask")] | last')"
  printf 'Answer 1: use src/.\n' > "$d/answers.md"
  evidence accept-plan --round "$(jq -r .round <<<"$plan_row")" --head "$(jq -r .head <<<"$plan_row")" \
    --file "$d/answers.md" > "$d/accept" 2>&1
  assert_eq 0 "$?" 'the fixture accepts the plan'
}
GH="$ROOT/tests/gh-stub.sh"
run_worker() {   # run_worker <mode>
  printf '%s' "$1" > "$d/mode"
  (cd "$repo" && FM_ROOT="$repo" FM_GH="$GH" FM_SEEN="$d" bin/fm-worker.sh --task T-Z) > "$d/out" 2>&1
  worker_rc=$?
}
heading() {   # heading <prompt file> <line>: yes when the prompt has that exact line
  if grep -qxF -- "$2" "$1" 2>/dev/null; then echo yes; else echo no; fi
}
prompts() { find "$d" -maxdepth 1 -name 'prompt-*' | wc -l | tr -d ' '; }
remote_head() { git --git-dir="$d/remote.git" for-each-ref --format='%(objectname)' 'refs/heads/t-z-*'; }
remote_has() { git --git-dir="$d/remote.git" cat-file -e "$(remote_head):$1" 2>/dev/null && echo yes || echo no; }
evidence() {   # evidence <fm_evidence arguments...>, as firstmate runs it
  (cd "$repo" && unset FM_RUN_DIR && . bin/fm-config.sh && fm_storage_init "$repo" && TASK=T-Z fm_evidence "$@")
}
reject() {   # reject: a REJECT on the pushed head, so the next round is a fix round
  (cd "$repo" && . bin/fm-config.sh && fm_storage_init "$repo" && python3 - "$FM_STATE_DIR" "$(fm_evidence_project)" "$(remote_head)" <<'PY'
import sys
sys.path.insert(0, 'bin/lib')
from fm_evidence import Store
Store(sys.argv[1], sys.argv[2], 'T-Z', external=False).append(
    'verdict', 1, 'reviewer-x', sys.argv[3], 'REJECT:T-Z\n1. fix it\nCRITERIA-COMPLETE:T-Z',
    provenance={'level': 'legacy'}, verdict='REJECT')
PY
  ) > "$d/verdict" 2>&1
}

setup
# --- worker: report-only refusal keeps work -------------------------------
run_worker build-bare
built="$(prompts)"
assert_ne 0 "$worker_rc" 'a fix report without its class is refused'
assert_eq '' "$(remote_head)" 'nothing is pushed'
assert_contains "$(cat "$d/out")" 'the next round fixes only the report' 'the refusal says the work is kept'
assert_ok "test -s '$tree/src/round-$built'" 'the round'"'"'s work stays in the tree'
run_worker report-edit
edit_round="$(prompts)"
# Fail-first: main starts the next round as a build round, not a report-only one.
assert_eq yes "$(heading "$d/prompt-$edit_round" '# Fix only your report')" 'worker: report-only refusal keeps work'
assert_eq no "$(heading "$d/prompt-$edit_round" '# Fix the whole class')" 'the report-only round is not asked to build'
assert_contains "$(cat "$d/prompt-$edit_round")" 'no complete SWEPT:T-Z block' 'it is given the refusal reason'
assert_contains "$(cat "$d/prompt-$edit_round")" 'Built.' 'and its own report'
assert_contains "$(cat "$d/seen-$edit_round")" "round-$built" 'it starts on the kept work'
assert_ne 0 "$worker_rc" 'a report-only round that changes a file is refused'
assert_contains "$(cat "$d/out")" 'a report-only round changes no file' 'the refusal says why'
assert_fail "test -e '$tree/src/round-$edit_round'" 'its change is taken out of the tree'
assert_ok "test -s '$tree/src/round-$built'" 'and the kept work is put back'
assert_contains "$(cat "$repo/state/rescued/"*"-r"*".patch" 2>/dev/null)" "src/round-$edit_round" 'its change is saved under state/rescued'
assert_eq '' "$(remote_head)" 'still nothing is pushed'
run_worker report
assert_eq 0 "$worker_rc" 'a fixed report is accepted'
assert_eq yes "$(heading "$d/prompt-$(prompts)" '# Fix only your report')" 'the round after a refused report-only round is report-only again'
assert_eq yes "$(remote_has "src/round-$built")" 'the kept work is published with the fixed report'
assert_eq no "$(remote_has "src/round-$edit_round")" 'the refused change is not'
assert_fail "test -e '$repo/state/worktrees/T-Z.kept'" 'the kept record is gone once published'
pr="$(awk -F'\t' 'NR==1{print $1}' "$GHSTATE/prs" 2>/dev/null)"
assert_ne '' "$pr" 'the publication opens the pull request'

safe_rm_rf "$d"

# --- worker: kept work survives a launch with a PR ------------------------
setup
run_worker build
assert_eq 0 "$worker_rc" 'the build is published'
assert_ne '' "$(awk -F'\t' 'NR==1{print $1}' "$GHSTATE/prs" 2>/dev/null)" 'and the task has a pull request'
pushed="$(remote_head)"
reject
assert_eq 0 "$?" 'the fixture records a REJECT'
run_worker build-bare
fixed="$(prompts)"
assert_ne 0 "$worker_rc" 'a fix report without its class is refused on a task with a PR'
assert_eq "$pushed" "$(remote_head)" 'nothing is pushed'
assert_ok "test -s '$tree/src/round-$fixed'" 'its work stays in the tree'
run_worker report
# Fail-first: main removes the tree of a task with a PR and remakes it from the branch.
assert_contains "$(cat "$d/seen-$(prompts)")" "round-$fixed" 'worker: kept work survives a launch with a PR'
assert_eq 0 "$worker_rc" 'the fixed report is accepted'
assert_eq yes "$(remote_has "src/round-$fixed")" 'the kept work is published to the pull request branch'
assert_ne '' "$(find "$repo/state/rescued" -maxdepth 1 -name 'T-Z-2*' 2>/dev/null | head -1)" 'a copy in state/rescued stays as a backup'

# --- a repin drops the kept record and says so -----------------------------
reject
run_worker build-bare
assert_ok "test -f '$repo/state/worktrees/T-Z.kept'" 'the fixture leaves a kept record'
jq '.pin = "0"' "$repo/state/worktrees/T-Z.kept" > "$d/kept" && cp "$d/kept" "$repo/state/worktrees/T-Z.kept"
run_worker report
assert_contains "$(cat "$d/out")" 'is not kept in place: the pin moved' 'a repin falls back to the usual rescue'
assert_eq no "$(heading "$d/prompt-$(prompts)" '# Fix only your report')" 'and the round is not report-only'
safe_rm_rf "$d"
finish
