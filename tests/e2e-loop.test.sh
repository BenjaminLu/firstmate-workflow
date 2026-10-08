#!/usr/bin/env bash
# The whole loop, once, with nothing real behind it: mock adapter, a bare
# remote on disk, and a gh that remembers. Dispatch to merged pull request.
set -uo pipefail
# A live managed worker exports FM_RUN_DIR / FM_ENTRY_* / FM_WORKER_TASK_LOCK_FD
# and Herdr pane ids into this shell. Suites must not inherit them or freeze,
# identity, locks and pushes bind to the outer run instead of the fixture.
for _fm_k in $(env | sed -E -n 's/^(FM_[^=]*|HERDR_[^=]*)=.*$/\1/p'); do
  unset "$_fm_k" || true
done
export HERDR_ENV=0 FM_TRANSPORT=direct
# the loop below runs the real fm-gate.sh through the autopilot: on a lock of its
# own it neither waits on a real gate run on this machine nor holds one up
FM_GATE_LOCK="$(mktemp -d)/gate.lock"; export FM_GATE_LOCK
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=tests/lib.sh
. "$ROOT/tests/lib.sh"
. "$ROOT/tests/lib/binding-fixture.sh"
# shellcheck source=tests/lib/local-verdict.sh
. "$ROOT/tests/lib/local-verdict.sh"
# shellcheck source=tests/lib/project-storage.sh
. "$ROOT/tests/lib/project-storage.sh"
# shellcheck source=tests/lib/spec-preflight.sh
. "$ROOT/tests/lib/spec-preflight.sh"

# Caller card cases moved to tests/lib/autopilot_loop.py and
# tests/lib/run_project_turns.py; this suite retains the real launcher chain.
DETAILS="$(mktemp)"
cat > "$DETAILS" <<'JSON'
{"en":{"title":"Merge fixture cache","explanation":"Cache file reads","before":"Repeated reads","after":"One read","outcome":"Cache decision recorded","options":{"A":{"description":"Merge cache","pros":"Less IO","cons":"More memory"},"B":{"description":"Revise cache","pros":"Improve design","cons":"Delay"},"C":{"description":"Hold cache","pros":"Measure","cons":"No improvement"}}},"zh-TW":{"title":"合併快取","explanation":"快取檔案讀取","before":"重複讀取","after":"讀取一次","outcome":"已記錄快取決策","options":{"A":{"description":"合併快取","pros":"減少讀取","cons":"增加記憶體"},"B":{"description":"修訂快取","pros":"改善設計","cons":"延後"},"C":{"description":"保留快取","pros":"測量","cons":"尚未改善"}}}}
JSON
d="$(mktemp -d)"; bare="$d/remote.git"; r="$d/repo"
git init -q --bare "$bare"
git init -q -b main "$r"
cd "$r" || exit 1
git config user.email a@b.c; git config user.name t
mkdir -p bin design skills/worker skills/reviewer state src tests
cp "$ROOT"/bin/fm-*.sh bin/
cp "$ROOT/bin/fm-herdr.py" bin/; project_storage_fixture bin/
cp -r "$ROOT/bin/adapters" bin/
cp -r "$ROOT/bin/lib" bin/
binding_service_fixture "$r"
cp "$ROOT/skills/worker/SKILL.md" skills/worker/
cp "$ROOT/skills/reviewer/SKILL.md" skills/reviewer/
# exactly the config.yaml this loop had before projects existed: no registry.
# The whole loop still runs to a merged pull request in such a tree.
printf 'vendor: mock\nconcurrency: 2\nfallback:\n  - mock\nproject:\n  check: bin/ci.sh\n  test: bash {file}\n' > config.yaml
printf '#!/usr/bin/env bash\nexit 0\n' > bin/ci.sh; chmod +x bin/ci.sh
mkdir -p design/tasks
cat > design/tasks/T-101.json <<'J'
{"id":"T-101","title":"a task the loop can finish","milestone":"M0",
 "depends_on":[],"scope":["src/**","tests/**"],"acceptance":["it lands"]}
J
printf '# design\n## 6. gates\nsix of them\n## 8. board\n' > design/design.md
echo base > src/thing
git add -A; git commit -qm base; git remote add origin "$bare"; git push -q -u origin main
seed_spec_preflight "$r" T-101

export GHSTATE="$d/ghstate"
GH="$ROOT/tests/gh-stub.sh"
run() { FM_ROOT="$r" FM_GH="$GH" FM_BASE=main GH_REPO=fixture/project "$@"; }

# the mock writes a real implementation and a test that depends on it, so the
# fail-first gate has something honest to check
export FM_MOCK_FILE=src/thing FM_MOCK_BODY=implemented
cat > bin/adapters/mock.sh <<'M'
#!/usr/bin/env bash
# One mock, two roles. The prompt says which: fm-review prepends the reviewer
# skill, fm-worker the worker one.
[ "$1" = "run" ] || exit 64
echo "mock ran" >> "$4"
if grep -q "Find the reason to reject" "$2"; then
  printf '%s\n1. open name the helper\n2. open cover the empty case\nCRITERIA-COMPLETE:T-101\nREJECT:T-101\n' "${FM_VERDICT:-round one: name the helper and cover the empty case}" > "$3/verdict.txt"
  exit 0
fi
printf 'implemented\n' > "$3/src/thing"
mkdir -p "$3/tests"
printf '#!/usr/bin/env bash\ngrep -q implemented "$(dirname "$0")/../src/thing"\n' > "$3/tests/a.test.sh"
chmod +x "$3/tests/a.test.sh"
exit 0
M
chmod +x bin/adapters/mock.sh

# --- nothing starts before the captain has seen it ----------------------
run python3 "$ROOT/tests/lib/autopilot_turn.py" "$r" >/dev/null 2>&1
assert_fail "test -s '$GHSTATE/prs'" "no green light, no pull request"

run bin/fm-emit.sh --actor captain --type greenlit --en go --tw 開工 >/dev/null
# a ready task is judged and answered A before the dispatcher starts it (T-059)
run bash bin/fm-ready.sh judged --task T-101 --decision D-1000 --repo "$r" >/dev/null 2>&1
mkdir -p "$r/state/decisions"
printf '{"id":"D-1000","task":"T-101","kind":"choice","chosen":"A"}\n' > "$r/state/decisions/D-1000.json"

bash -c '. "$1/bin/fm-config.sh"; fm_storage_init "$2" || exit 65;
  python3 "$1/tests/lib/self_pr_authoring.py" "$1" --seed T-101 self' _ "$ROOT" "$r"

# --- turn one: dispatch, worktree, commit, push, pull request -----------
out1="$(run bin/fm-dispatch.sh --repo "$r" 2>&1)"
assert_contains "$out1" "T-101" "the explicit dispatcher starts the ready task"
for _ in $(seq 1 40); do [ -s "$GHSTATE/prs" ] && break; sleep 0.25; done
assert_ok "test -s '$GHSTATE/prs'" "a pull request exists"
pr="$(awk -F'\t' 'NR==1{print $1}' "$GHSTATE/prs")"
branch="$(awk -F'\t' 'NR==1{print $2}' "$GHSTATE/prs")"
assert_contains "$branch" "t-101" "on a branch named after the task"
assert_ok "git --git-dir='$bare' rev-parse --verify '$branch'" "and it was pushed"

# --- turn two: the gates run, gate 6 sends it to review -----------------
out2="$(run python3 "$ROOT/tests/lib/autopilot_turn.py" "$r" 2>&1)"
assert_contains "$out2" "sending it to review" "every gate before 6 passes and it goes to review"
assert_ok "test -s '$GHSTATE/comments.$pr'" "the reviewer commented"
criteria="$(jq -r 'select(.kind=="verdict") | .text' "$r/state/evidence/self/T-101/"*.json)"
assert_contains "$criteria" '1. open name the helper' 'the mock reviewer supplies numbered round-one criteria'
assert_contains "$criteria" 'CRITERIA-COMPLETE:T-101' 'the mock reviewer closes its round-one standing list'

# Exit 2/3/65, child-log quoting and detached stdin are covered by
# tests/lib/autopilot_loop.py and tests/lib/autopilot_jobs.py.

# a real review body has newlines, quotes and backslashes in it. The stub
# used to interpolate one into JSON by hand, which put a raw control
# character in the document, and gate 6 then read an approval sitting right
# there as nothing at all.
body="$(printf 'Two findings:\n1. open the "helper" is unnamed\n2. open a path like C:\\tmp is unhandled\nCRITERIA-COMPLETE:T-101\nREJECT:T-101')"
run "$GH" pr comment "$pr" --body "$body" >/dev/null 2>&1
back="$(run "$GH" pr view "$pr" --json comments --jq '.comments[-1].body')"
assert_eq "$body" "$back" "a review body with newlines and quotes comes back byte for byte"
assert_eq "reviewer-1" "$(run "$GH" pr view "$pr" --json comments --jq '.comments[-1].author.login')" \
  "and the author is not split off by one of its newlines"

# the reviewer in this fixture signs off
seed_local_approval "$r" T-101 "$branch" reviewer-1

# The fixture's reviewer signs REJECT before it signs APPROVE, and the round
# counter is what decides whether the next turn runs the round-three
# protocol instead of asking for a decision. Pin it, or a later edit to the
# reviewer's output silently changes which branch turn three takes.
rounds="$(jq -r 'select(.type=="review_opened")|.task' "$r/state/events.jsonl" | wc -l | tr -d ' ')"
assert_eq "1" "$rounds" "one review round has happened when the approval lands"

# --- turn three: every gate green, so the captain is asked --------------
# firstmate allocates the card's id before it authors the details, so the
# details and any drawing are written under the id the card will carry
mkdir -p "$r/state/decision-details"
card1="$(run bin/fm-decide.sh --allocate --task T-101 --kind merge --repo "$r" 2>/dev/null)"
assert_eq "D-firstmate-workflow-T101-1" "$card1" \
  "firstmate allocates the merge card's id; a tree with no registry is the self project"
cp "$DETAILS" "$r/state/decision-details/$card1.json"

run python3 "$ROOT/tests/lib/autopilot_turn.py" "$r"
assert_ok "test -f '$r/state/pending/$card1.json'" "every gate green means a decision, not a merge"
pend="$(ls "$r/state/pending" 2>/dev/null | head -1)"
assert_ok "[ -n \"$pend\" ]" "a decision is pending on disk"
id="${pend%.json}"
assert_eq "$card1" "$id" "the pending card is the one allocated"
assert_eq "false" "$(jq -c 'has("project")' "$r/state/pending/$pend")" \
  "and, with no registry to validate one against, it records no project"

# nothing merged while the captain has not answered
assert_eq "OPEN" "$(awk -F'\t' -v n="$pr" '$1==n{print $4}' "$GHSTATE/prs")" \
  "nothing merges before the captain answers"

# --- the captain answers, and only then does it merge -------------------
mkdir -p "$r/state/decisions"
printf '{"id":"%s","task":"T-101","kind":"merge","chosen":"A"}\n' "$id" > "$r/state/decisions/$id.json"
run bin/fm-merge.sh --pr "$pr" --task T-101 --expected-head "$(git -C "$r" rev-parse "$branch")" --repo "$r" >/dev/null 2>&1
assert_eq "MERGED" "$(awk -F'\t' -v n="$pr" '$1==n{print $4}' "$GHSTATE/prs")" "the pull request is merged"

types="$(jq -r .type < "$r/state/events.jsonl" | tr '\n' ' ')"
for want in greenlit dispatched commit_pushed pr_opened review_opened decision_requested merged; do
  assert_contains "$types" "$want" "the log records $want"
done
assert_fail "test -d '$r/state/worktrees/T-101'" "the worktree is cleaned up after the merge"

cd "$ROOT" || exit 1
rm -rf "$d"
rm -f "$DETAILS"
finish
