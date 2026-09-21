#!/usr/bin/env bash
# The whole loop, once, with nothing real behind it: mock adapter, a bare
# remote on disk, and a gh that remembers. Dispatch to merged pull request.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=tests/lib.sh
. "$ROOT/tests/lib.sh"

# The production caller in a fixture with all orchestration stubbed. This
# focused path never invokes git, gh, engines or a live board.
caller="$(mktemp -d)"
mkdir -p "$caller/bin" "$caller/state/decision-details"
cp "$ROOT/bin/fm-run.sh" "$ROOT/bin/fm-config.sh" "$ROOT/bin/fm-decide.sh" "$ROOT/bin/fm-emit.sh" "$caller/bin/"
for script in fm-sync-prs fm-dispatch fm-gate; do
  printf '#!/usr/bin/env bash\nexit 0\n' > "$caller/bin/$script.sh"
  chmod +x "$caller/bin/$script.sh"
done
printf '#!/usr/bin/env bash\nprintf "t-991-fixture\\n"\n' > "$caller/bin/git"
chmod +x "$caller/bin/git"
printf '%s\n' '{"type":"pr_opened","task":"T-991","pr":991}' > "$caller/state/events.jsonl"
missing="$(PATH="$caller/bin:$PATH" bash "$caller/bin/fm-run.sh" once --repo "$caller" 2>&1)"
assert_contains "$missing" 'no captain card created' 'missing authored details reported truthfully'
assert_fail "test -f '$caller/state/pending/D-991.json'" 'missing input never produces a card'
printf '{}\n' > "$caller/state/decision-details/D-991.json"
invalid="$(PATH="$caller/bin:$PATH" bash "$caller/bin/fm-run.sh" once --repo "$caller" 2>&1)"
assert_contains "$invalid" 'no captain card created' 'invalid authored details reported truthfully'
assert_fail "test -f '$caller/state/pending/D-991.json'" 'invalid input never produces a card'
jq -n '{en:{title:"Merge fixture cache",explanation:"Cache file reads",before:"Repeated reads",after:"One read",outcome:"Cache decision recorded",options:{A:{description:"Merge cache",pros:"Less IO",cons:"More memory"},B:{description:"Revise cache",pros:"Improve design",cons:"Delay"},C:{description:"Hold cache",pros:"Measure",cons:"No improvement"}}},"zh-TW":{title:"合併快取",explanation:"快取檔案讀取",before:"重複讀取",after:"讀取一次",outcome:"已記錄快取決策",options:{A:{description:"合併快取",pros:"減少讀取",cons:"增加記憶體"},B:{description:"修訂快取",pros:"改善設計",cons:"延後"},C:{description:"保留快取",pros:"測量",cons:"尚未改善"}}}}' > "$caller/state/decision-details/D-991.json"
valid="$(PATH="$caller/bin:$PATH" bash "$caller/bin/fm-run.sh" once --repo "$caller" 2>&1)"
assert_contains "$valid" 'asking the captain (D-991)' 'valid authored details create an announced card'
assert_eq '合併快取' "$(jq -r '.details."zh-TW".title' "$caller/state/pending/D-991.json")" 'caller preserves authored translation'
if [ "${FM_CALLER_ONLY:-0}" = 1 ]; then rm -rf "$caller"; finish; exit $?; fi

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
{"tasks":[{"id":"T-1","title":"a task the loop can finish","milestone":"M0",
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
  printf '%s\nREJECT:T-1\n' "${FM_VERDICT:-round one: name the helper and cover the empty case}" > "$3/verdict.txt"
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
assert_contains "$out1" "dispatched: T-1" "turn one dispatches the ready task"
for _ in $(seq 1 40); do [ -s "$GHSTATE/prs" ] && break; sleep 0.25; done
assert_ok "test -s '$GHSTATE/prs'" "a pull request exists"
pr="$(awk -F'\t' 'NR==1{print $1}' "$GHSTATE/prs")"
branch="$(awk -F'\t' 'NR==1{print $2}' "$GHSTATE/prs")"
assert_contains "$branch" "t-1" "on a branch named after the task"
assert_ok "git --git-dir='$bare' rev-parse --verify '$branch'" "and it was pushed"

# --- turn two: the gates run, gate seven sends it to review -------------
out2="$(run bin/fm-run.sh once --repo "$r" 2>&1)"
assert_contains "$out2" "sending it to review" "gates one to six pass and it goes to review"
assert_ok "test -s '$GHSTATE/comments.$pr'" "the reviewer commented"

# fm-run must not swallow a review round that produced no verdict. The
# reviewer is stubbed rather than crashed for real, so the round counter is
# untouched and the scenario after this point is the one it was before.
# the stub says where its log is, the way the real fm-review does, so the
# turn output can be checked against what the child actually reported
# rather than against a path fm-run reconstructed
stub_script "$r/bin/fm-review.sh" <<'S'
#!/usr/bin/env bash
echo "fm-review: nothing to show; its log is at state/reviews/T-1-r1.7.log" >&2
exit 3
S
outX="$(run bin/fm-run.sh once --repo "$r" 2>&1)"
assert_contains "$outX" "produced no verdict" "a review round with no verdict is reported, not counted"
assert_contains "$outX" "T-1-r1.7.log" "and the path it prints is the one the reviewer wrote"
stub_script "$r/bin/fm-review.sh" <<'S'
#!/usr/bin/env bash
echo "fm-review: every reviewer vendor was unavailable; their log is at state/reviews/T-1-r1.9.log" >&2
exit 2
S
outY="$(run bin/fm-run.sh once --repo "$r" 2>&1)"
assert_contains "$outY" "no reviewer engine was available" "and so is a reviewer with no engine"
assert_contains "$outY" "T-1-r1.9.log" "which also carries the log the reviewer kept"
stub_script "$r/bin/fm-review.sh" <<'S'
#!/usr/bin/env bash
exit 64
S
outZ="$(run bin/fm-run.sh once --repo "$r" 2>&1)"
assert_contains "$outZ" "review round failed" "and so is a reviewer that failed some other way"

# a dispatched child inherits fm-run's stdin. If that is the caller's open
# pipe and the child reads it, the turn never ends - which is how the
# advance loop once ate its own input. The advance loop happens to be fed
# by a here-string, so the child that proves this has to be one called
# outside it: the sync at the top of the turn.
stub_script "$r/bin/fm-sync-prs.sh" <<'S'
#!/usr/bin/env bash
cat > /dev/null
exit 0
S
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
restore_scripts

# a real review body has newlines, quotes and backslashes in it. The stub
# used to interpolate one into JSON by hand, which put a raw control
# character in the document, and gate 7 then read an approval sitting right
# there as nothing at all.
body="$(printf 'Two findings:\n1. the "helper" is unnamed\n2. a path like C:\\tmp is unhandled\nREJECT:T-1')"
run "$GH" pr comment "$pr" --body "$body" >/dev/null 2>&1
back="$(run "$GH" pr view "$pr" --json comments --jq '.comments[-1].body')"
assert_eq "$body" "$back" "a review body with newlines and quotes comes back byte for byte"
assert_eq "reviewer-1" "$(run "$GH" pr view "$pr" --json comments --jq '.comments[-1].author.login')" \
  "and the author is not split off by one of its newlines"

# the reviewer in this fixture signs off
printf 'reviewer-1\tAPPROVE:T-1\n' >> "$GHSTATE/comments.$pr"

# The fixture's reviewer signs REJECT before it signs APPROVE, and the round
# counter is what decides whether the next turn runs the round-three
# protocol instead of asking for a decision. Pin it, or a later edit to the
# reviewer's output silently changes which branch turn three takes.
rounds="$(jq -r 'select(.type=="review_opened")|.task' "$r/state/events.jsonl" | wc -l | tr -d ' ')"
assert_eq "1" "$rounds" "one review round has happened when the approval lands"

# --- turn three: all seven green, so the captain is asked ---------------
mkdir -p "$r/state/decision-details"
cp "$caller/state/decision-details/D-991.json" "$r/state/decision-details/D-1.json"
rm -rf "$caller"
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
printf '{"id":"%s","task":"T-1","kind":"merge","chosen":"A"}\n' "$id" > "$r/state/decisions/$id.json"
run bin/fm-merge.sh --pr "$pr" --task T-1 --repo "$r" >/dev/null 2>&1
assert_eq "MERGED" "$(awk -F'\t' -v n="$pr" '$1==n{print $4}' "$GHSTATE/prs")" "the pull request is merged"

types="$(jq -r .type < "$r/state/events.jsonl" | tr '\n' ' ')"
for want in greenlit dispatched commit_pushed pr_opened review_opened decision_requested merged; do
  assert_contains "$types" "$want" "the log records $want"
done
assert_fail "test -d '$r/state/worktrees/T-1'" "the worktree is cleaned up after the merge"

cd "$ROOT" || exit 1
rm -rf "$d"
finish
