#!/usr/bin/env bash
# The whole loop, once, with nothing real behind it: mock adapter, a bare
# remote on disk, and a gh that remembers. Dispatch to merged pull request.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=tests/lib.sh
. "$ROOT/tests/lib.sh"

d="$(mktemp -d)"; bare="$d/remote.git"; r="$d/repo"
git init -q --bare "$bare"
git init -q -b main "$r"
cd "$r" || exit 1
git config user.email a@b.c; git config user.name t
mkdir -p bin design skills/worker skills/reviewer state src tests
cp "$ROOT"/bin/fm-*.sh bin/
cp -r "$ROOT/bin/adapters" bin/
cp "$ROOT/bin/watch-decisions.ts" bin/ 2>/dev/null || true
cp "$ROOT/skills/worker/SKILL.md" skills/worker/
cp "$ROOT/skills/reviewer/SKILL.md" skills/reviewer/
printf 'vendor: mock\nconcurrency: 2\nfallback:\n  - mock\n' > config.yaml
printf '#!/usr/bin/env bash\nexit 0\n' > bin/ci.sh; chmod +x bin/ci.sh
cat > design/tasks.json <<'J'
{"tasks":[{"id":"T-A","title":"a task the loop can finish","milestone":"M0",
           "depends_on":[],"scope":["src/**","tests/**"],"acceptance":["it lands"]}]}
J
printf '# design\n## 6. gates\nseven\n## 8. board\n' > design/design.md
echo base > src/thing
git add -A; git commit -qm base; git remote add origin "$bare"; git push -q -u origin main

export GHSTATE="$d/ghstate"
GH="$ROOT/tests/gh-stub.sh"
run() { FM_ROOT="$r" FM_GH="$GH" FM_BASE=main "$@"; }

# the mock writes a real implementation and a test that depends on it, so the
# fifth gate has something honest to check
export FM_MOCK_FILE=src/thing FM_MOCK_BODY=implemented
cat > bin/adapters/mock.sh <<'M'
#!/usr/bin/env bash
# One mock, two roles. The prompt says which: fm-review prepends the reviewer
# skill, fm-worker the worker one.
[ "$1" = "run" ] || exit 64
echo "mock ran" >> "$4"
if grep -q "Find the reason to reject" "$2"; then
  printf '%s\nREJECT:T-A\n' "${FM_VERDICT:-round one: name the helper and cover the empty case}" > "$3/verdict.txt"
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
run bin/fm-run.sh once --repo "$r" >/dev/null 2>&1
assert_fail "test -s '$GHSTATE/prs'" "no green light, no pull request"

run bin/fm-emit.sh --actor captain --type greenlit --en go --tw 開工 >/dev/null

# --- turn one: dispatch, worktree, commit, push, pull request -----------
out1="$(run bin/fm-run.sh once --repo "$r" 2>&1)"
assert_contains "$out1" "dispatched: T-A" "turn one dispatches the ready task"
for _ in $(seq 1 40); do [ -s "$GHSTATE/prs" ] && break; sleep 0.25; done
assert_ok "test -s '$GHSTATE/prs'" "a pull request exists"
pr="$(awk -F'\t' 'NR==1{print $1}' "$GHSTATE/prs")"
branch="$(awk -F'\t' 'NR==1{print $2}' "$GHSTATE/prs")"
assert_contains "$branch" "t-a" "on a branch named after the task"
assert_ok "git --git-dir='$bare' rev-parse --verify '$branch'" "and it was pushed"

# --- turn two: the gates run, gate seven sends it to review -------------
out2="$(run bin/fm-run.sh once --repo "$r" 2>&1)"
assert_contains "$out2" "sending it to review" "gates one to six pass and it goes to review"
assert_ok "test -s '$GHSTATE/comments.$pr'" "the reviewer commented"

# fm-run must not swallow a review round that produced no verdict. The
# reviewer is stubbed rather than crashed for real, so the round counter is
# untouched and the scenario after this point is the one it was before.
cp "$r/bin/fm-review.sh" "$r/review.keep"
printf '#!/usr/bin/env bash\nexit 3\n' > "$r/bin/fm-review.sh"; chmod +x "$r/bin/fm-review.sh"
outX="$(run bin/fm-run.sh once --repo "$r" 2>&1)"
assert_contains "$outX" "produced no verdict" "a review round with no verdict is reported, not counted"
printf '#!/usr/bin/env bash\nexit 2\n' > "$r/bin/fm-review.sh"; chmod +x "$r/bin/fm-review.sh"
outY="$(run bin/fm-run.sh once --repo "$r" 2>&1)"
assert_contains "$outY" "no reviewer engine was available" "and so is a reviewer with no engine"
printf '#!/usr/bin/env bash\nexit 64\n' > "$r/bin/fm-review.sh"; chmod +x "$r/bin/fm-review.sh"
outZ="$(run bin/fm-run.sh once --repo "$r" 2>&1)"
assert_contains "$outZ" "review round failed" "and so is a reviewer that failed some other way"

# a dispatched child inherits fm-run's stdin. If that is the caller's open
# pipe and the child reads it, the turn never ends - which is how the
# advance loop once ate its own input. The advance loop happens to be fed
# by a here-string, so the child that proves this has to be one called
# outside it: the sync at the top of the turn.
cp "$r/bin/fm-sync-prs.sh" "$r/sync.keep"
printf '#!/usr/bin/env bash\ncat > /dev/null\nexit 0\n' > "$r/bin/fm-sync-prs.sh"
chmod +x "$r/bin/fm-sync-prs.sh"
# a fifo held open read-write never reaches EOF and needs no writer
# process, so a child that reads it blocks for good and the probe leaves
# nothing running behind it
mkfifo "$r/openpipe"
exec 9<> "$r/openpipe"
( run bin/fm-run.sh once --repo "$r" >/dev/null 2>&1 <&9; touch "$r/turn-done" ) &
probe=$!
deadline=$(( $(date +%s) + 30 ))
while [ ! -f "$r/turn-done" ] && [ "$(date +%s)" -lt "$deadline" ]; do sleep 0.3; done
assert_ok "test -f '$r/turn-done'" "a turn finishes even when a child would read standard input"
kill -9 "$probe" 2>/dev/null; wait "$probe" 2>/dev/null
pkill -f "$r/bin/fm-sync-prs.sh" 2>/dev/null
exec 9>&-; rm -f "$r/openpipe"
cp "$r/review.keep" "$r/bin/fm-review.sh"; chmod +x "$r/bin/fm-review.sh"
cp "$r/review.keep" "$r/bin/fm-review.sh"; chmod +x "$r/bin/fm-review.sh"

# a real review body has newlines, quotes and backslashes in it. The stub
# used to interpolate one into JSON by hand, which put a raw control
# character in the document, and gate 7 then read an approval sitting right
# there as nothing at all.
body="$(printf 'Two findings:\n1. the "helper" is unnamed\n2. a path like C:\\tmp is unhandled\nREJECT:T-A')"
run "$GH" pr comment "$pr" --body "$body" >/dev/null 2>&1
back="$(run "$GH" pr view "$pr" --json comments --jq '.comments[-1].body')"
assert_eq "$body" "$back" "a review body with newlines and quotes comes back byte for byte"
assert_eq "reviewer-1" "$(run "$GH" pr view "$pr" --json comments --jq '.comments[-1].author.login')" \
  "and the author is not split off by one of its newlines"

# the reviewer in this fixture signs off
printf 'reviewer-1\tAPPROVE:T-A\n' >> "$GHSTATE/comments.$pr"

# --- turn three: all seven green, so the captain is asked ---------------
out3="$(run bin/fm-run.sh once --repo "$r" 2>&1)"
assert_contains "$out3" "asking the captain" "seven green means a decision, not a merge"
pend="$(ls "$r/state/pending" 2>/dev/null | head -1)"
assert_ok "[ -n \"$pend\" ]" "a decision is pending on disk"
id="${pend%.json}"

# nothing merged while the captain has not answered
assert_eq "OPEN" "$(awk -F'\t' -v n="$pr" '$1==n{print $4}' "$GHSTATE/prs")" \
  "nothing merges before the captain answers"

# --- the captain answers, and only then does it merge -------------------
mkdir -p "$r/state/decisions"
printf '{"id":"%s","task":"T-A","kind":"merge","chosen":"A"}\n' "$id" > "$r/state/decisions/$id.json"
run bin/fm-merge.sh --pr "$pr" --task T-A --repo "$r" >/dev/null 2>&1
assert_eq "MERGED" "$(awk -F'\t' -v n="$pr" '$1==n{print $4}' "$GHSTATE/prs")" "the pull request is merged"

types="$(jq -r .type < "$r/state/events.jsonl" | tr '\n' ' ')"
for want in greenlit dispatched commit_pushed pr_opened review_opened decision_requested merged; do
  assert_contains "$types" "$want" "the log records $want"
done
assert_fail "test -d '$r/state/worktrees/T-A'" "the worktree is cleaned up after the merge"

cd "$ROOT" || exit 1
rm -rf "$d"
finish
