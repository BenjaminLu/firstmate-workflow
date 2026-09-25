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
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=tests/lib.sh
. "$ROOT/tests/lib.sh"

# The production caller in a fixture with all orchestration stubbed. This
# focused path never invokes git, gh, engines or a live board.
REGISTRY='default_project: firstmate-workflow
projects:
  firstmate-workflow:
    repo: .
    github: owner/engine
    base: main
    required_check: ci
'
caller_fixture() {   # caller_fixture <task branch> <event lines> [registry] -> a fixture root
  local c; c="$(mktemp -d)"
  mkdir -p "$c/bin" "$c/state/decision-details"
  cp "$ROOT/bin/fm-run.sh" "$ROOT/bin/fm-config.sh" "$ROOT/bin/fm-decide.sh" \
     "$ROOT/bin/fm-emit.sh" "$ROOT/bin/fm-herdr.py" "$c/bin/"
  # each stub notes that it ran, so a test can say what a turn touched
  for script in fm-sync-prs fm-dispatch fm-gate; do
    printf '#!/usr/bin/env bash\necho "%s $*" >> "%s/calls"\nexit 0\n' "$script" "$c" > "$c/bin/$script.sh"
    chmod +x "$c/bin/$script.sh"
  done
  printf '#!/usr/bin/env bash\nprintf "%s\\n"\n' "$1" > "$c/bin/git"
  chmod +x "$c/bin/git"
  printf '%s' "${3-$REGISTRY}" > "$c/config.yaml"
  printf '%s\n' "$2" > "$c/state/events.jsonl"
  printf '%s' "$c"
}
caller="$(caller_fixture t-991-fixture '{"type":"pr_opened","task":"T-991","pr":991}')"
# T-047: the card's id is allocated by fm-decide.sh and names its owner. It
# is never derived from the task's digits again.
card=D-firstmate-workflow-T991-1
missing="$(PATH="$caller/bin:$PATH" bash "$caller/bin/fm-run.sh" once --repo "$caller" 2>&1)"
assert_contains "$missing" 'no captain card created' 'missing authored details reported truthfully'
assert_contains "$missing" "state/decision-details/$card.json" 'and it names the path for the id it allocated'
assert_fail "test -f '$caller/state/pending/$card.json'" 'missing input never produces a card'
assert_fail "test -e '$caller/state/pending/D-991.json' || test -e '$caller/state/decisions/D-991.json'" \
  'and no D-<task digits> id is derived'
printf '{}\n' > "$caller/state/decision-details/$card.json"
invalid="$(PATH="$caller/bin:$PATH" bash "$caller/bin/fm-run.sh" once --repo "$caller" 2>&1)"
assert_contains "$invalid" 'no captain card created' 'invalid authored details reported truthfully'
assert_contains "$invalid" "$card" 'a later turn keeps the id it allocated rather than taking another'
assert_fail "test -f '$caller/state/pending/$card.json'" 'invalid input never produces a card'
jq -n '{en:{title:"Merge fixture cache",explanation:"Cache file reads",before:"Repeated reads",after:"One read",outcome:"Cache decision recorded",options:{A:{description:"Merge cache",pros:"Less IO",cons:"More memory"},B:{description:"Revise cache",pros:"Improve design",cons:"Delay"},C:{description:"Hold cache",pros:"Measure",cons:"No improvement"}}},"zh-TW":{title:"合併快取",explanation:"快取檔案讀取",before:"重複讀取",after:"讀取一次",outcome:"已記錄快取決策",options:{A:{description:"合併快取",pros:"減少讀取",cons:"增加記憶體"},B:{description:"修訂快取",pros:"改善設計",cons:"延後"},C:{description:"保留快取",pros:"測量",cons:"尚未改善"}}}}' > "$caller/state/decision-details/$card.json"
valid="$(PATH="$caller/bin:$PATH" bash "$caller/bin/fm-run.sh" once --repo "$caller" 2>&1)"
assert_contains "$valid" "asking the captain ($card)" 'valid authored details create an announced card'
assert_eq '合併快取' "$(jq -r '.details."zh-TW".title' "$caller/state/pending/$card.json")" 'caller preserves authored translation'
assert_eq 'firstmate-workflow' "$(jq -r .project "$caller/state/pending/$card.json")" 'the card names its project'
waiting="$(PATH="$caller/bin:$PATH" bash "$caller/bin/fm-run.sh" once --repo "$caller" 2>&1)"
assert_contains "$waiting" 'waiting on the captain' 'a pending card for the task is found under its new id'
assert_eq '1' "$(find "$caller/state/pending" -name '*.json' | wc -l | tr -d ' ')" 'and no second card is raised'
DETAILS="$caller/state/decision-details/$card.json"

# The caller fixture exactly as it was before projects existed: no
# config.yaml at all. It still raises its merge card - under an id owned by
# the self project, never D-991 - and records no project on it.
bare="$(caller_fixture t-991-fixture '{"type":"pr_opened","task":"T-991","pr":991}' '')"
rm -f "$bare/config.yaml"
cp "$DETAILS" "$bare/state/decision-details/$card.json"
obare="$(PATH="$bare/bin:$PATH" bash "$bare/bin/fm-run.sh" once --repo "$bare" 2>&1)"
assert_contains "$obare" "asking the captain ($card)" 'a tree with no registry still raises its merge card'
assert_eq "false" "$(jq -c 'has("project")' "$bare/state/pending/$card.json")" \
  'and records no project on it, having no registry to name one from'
assert_fail "test -e '$bare/state/pending/D-991.json'" 'and derives no D-<task digits> id there either'
rm -rf "$bare"

# The log is shared by every project, and a pull request number is only a key
# together with its project. Another project's #7 for its own T-004 is not
# this run's to gate, to card or to merge.
REGISTRY2="${REGISTRY}  example-app:
    github: example-org/example-app
    base: main
    required_check: check
"
other="$(caller_fixture t-004-engine '{"type":"pr_opened","task":"T-004","pr":7,"project":"example-app"}' "$REGISTRY2")"
oother="$(PATH="$other/bin:$PATH" bash "$other/bin/fm-run.sh" once --repo "$other" 2>&1)"
assert_lacks "$(cat "$other/calls" 2>/dev/null)" "fm-gate" "another project's pull request is not gated by this run"
assert_lacks "$oother" "T-004" "nor mentioned"
assert_fail "test -d '$other/state/decision-ids/firstmate-workflow/T004'" "and no card id is allocated for it"
rm -rf "$other"
# the engine's own #7 (no project: the default's) is still advanced when the
# other project's #7 for a task of the same name has merged
both="$(caller_fixture t-004-engine "$(printf '%s\n%s' \
  '{"type":"pr_opened","task":"T-004","pr":7}' \
  '{"type":"merged","task":"T-004","pr":7,"project":"example-app"}')" "$REGISTRY2")"
cp "$DETAILS" "$both/state/decision-details/D-firstmate-workflow-T004-1.json"
oboth="$(PATH="$both/bin:$PATH" bash "$both/bin/fm-run.sh" once --repo "$both" 2>&1)"
assert_contains "$(cat "$both/calls")" "fm-gate --task T-004" "the engine's own #7 is still gated"
assert_contains "$oboth" "asking the captain (D-firstmate-workflow-T004-1)" \
  "and carded, another project's merge notwithstanding"
assert_eq "7 firstmate-workflow" \
  "$(jq -r '"\(.pr) \(.project)"' "$both/state/pending/D-firstmate-workflow-T004-1.json")" \
  "the card is the engine's #7"
rm -rf "$both"
# a run for the other project advances that project's #7 and not the engine's
app="$(caller_fixture t-004-app "$(printf '%s\n%s' \
  '{"type":"pr_opened","task":"T-004","pr":7}' \
  '{"type":"pr_opened","task":"T-004","pr":8,"project":"example-app"}')" "$REGISTRY2")"
cp "$DETAILS" "$app/state/decision-details/D-example-app-T004-1.json"
oapp="$(FM_PROJECT=example-app PATH="$app/bin:$PATH" bash "$app/bin/fm-run.sh" once --repo "$app" 2>&1)"
assert_contains "$oapp" "asking the captain (D-example-app-T004-1)" "a run for example-app cards its own pull request"
assert_eq "8 example-app" "$(jq -r '"\(.pr) \(.project)"' "$app/state/pending/D-example-app-T004-1.json")" \
  "with that project's pull request number"
assert_lacks "$(cat "$app/calls")" "--pr 7" "and never gates the engine's #7"
rm -rf "$app"

# An id reserved for the task's merge card and never published is reused by
# the next turn, the lowest first; a choice id reserved for the same task is
# not a merge card and is left alone. No fresh id is taken.
res="$(caller_fixture t-992-fixture '{"type":"pr_opened","task":"T-992","pr":992}')"
for k in choice merge merge; do
  PATH="$res/bin:$PATH" bash "$res/bin/fm-decide.sh" --allocate --task T-992 --kind "$k" --repo "$res" >/dev/null 2>&1
done
ores="$(PATH="$res/bin:$PATH" bash "$res/bin/fm-run.sh" once --repo "$res" 2>&1)"
assert_contains "$ores" "state/decision-details/D-firstmate-workflow-T992-2.json" \
  "the lowest reserved merge id is the one the turn asks details for"
assert_eq "1 2 3" "$(find "$res/state/decision-ids/firstmate-workflow/T992" -name '*.json' -exec basename {} .json \; | sort -n | tr '\n' ' ' | sed 's/ $//')" \
  "and no fresh id is allocated"
rm -rf "$res"

# T-043's hand-raised record sits at D-056, the id T-056's merge card used to
# be derived as. It is not T-056's and new ids never look at it: T-056 gets
# its own card, and the old record is not read, moved or overwritten.
old='{"id":"D-056","task":"T-043","kind":"choice","chosen":"A","ts":"2026-09-01T00:00:00Z"}'
own="$(caller_fixture t-056-own '{"type":"pr_opened","task":"T-056","pr":56}')"
mkdir -p "$own/state/decisions" "$own/state/pending"
printf '%s\n' "$old" > "$own/state/decisions/D-056.json"
printf '%s\n' "$old" > "$own/state/pending/D-056.json"
cp "$DETAILS" "$own/state/decision-details/D-056.json"
keyed() { cksum "$own/state/decisions/D-056.json" "$own/state/pending/D-056.json" \
  "$own/state/decision-details/D-056.json"; }
before56="$(keyed)"
out56="$(PATH="$own/bin:$PATH" bash "$own/bin/fm-run.sh" once --repo "$own" 2>&1)"
assert_contains "$out56" 'D-firstmate-workflow-T056-1' 'T-056 is allocated its own id beside the old D-056'
assert_lacks "$out56" 'waiting on the captain' 'the old pending D-056 is not read as T-056 waiting'
cp "$DETAILS" "$own/state/decision-details/D-firstmate-workflow-T056-1.json"
out56="$(PATH="$own/bin:$PATH" bash "$own/bin/fm-run.sh" once --repo "$own" 2>&1)"
assert_contains "$out56" 'asking the captain (D-firstmate-workflow-T056-1)' 'and its merge card is raised there'
assert_eq 'T-056' "$(jq -r .task "$own/state/pending/D-firstmate-workflow-T056-1.json")" 'for T-056'
assert_eq "$before56" "$(keyed)" 'and D-056 and everything keyed by it are exactly as they were'
assert_eq 'D-056.json D-firstmate-workflow-T056-1.json' \
  "$(find "$own/state/pending" -name '*.json' -exec basename {} \; | sort | tr '\n' ' ' | sed 's/ $//')" \
  'with nothing moved in or out of the pending cards'
rm -rf "$own"
if [ "${FM_CALLER_ONLY:-0}" = 1 ]; then rm -rf "$caller"; finish; exit $?; fi

d="$(mktemp -d)"; bare="$d/remote.git"; r="$d/repo"
git init -q --bare "$bare"
git init -q -b main "$r"
cd "$r" || exit 1
git config user.email a@b.c; git config user.name t
mkdir -p bin design skills/worker skills/reviewer state src tests
cp "$ROOT"/bin/fm-*.sh bin/
cp "$ROOT/bin/fm-herdr.py" bin/
cp -r "$ROOT/bin/adapters" bin/
cp "$ROOT/bin/watch-decisions.ts" bin/ 2>/dev/null || true
cp "$ROOT/skills/worker/SKILL.md" skills/worker/
cp "$ROOT/skills/reviewer/SKILL.md" skills/reviewer/
# exactly the config.yaml this loop had before projects existed: no registry.
# The whole loop still runs to a merged pull request in such a tree.
printf 'vendor: mock\nconcurrency: 2\nfallback:\n  - mock\nproject:\n  check: bin/ci.sh\n  test: bash {file}\n' > config.yaml
printf '#!/usr/bin/env bash\nexit 0\n' > bin/ci.sh; chmod +x bin/ci.sh
mkdir -p design/tasks
cat > design/tasks/T-1.json <<'J'
{"id":"T-1","title":"a task the loop can finish","milestone":"M0",
 "depends_on":[],"scope":["src/**","tests/**"],"acceptance":["it lands"]}
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
# a ready task is judged and answered A before the dispatcher starts it (T-059)
run bash bin/fm-ready.sh judged --task T-1 --decision D-1000 --repo "$r" >/dev/null 2>&1
mkdir -p "$r/state/decisions"
printf '{"id":"D-1000","task":"T-1","kind":"choice","chosen":"A"}\n' > "$r/state/decisions/D-1000.json"

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

# --- turn three: every gate green, so the captain is asked --------------
# firstmate allocates the card's id before it authors the details, so the
# details and any drawing are written under the id the card will carry
mkdir -p "$r/state/decision-details"
card1="$(run bin/fm-decide.sh --allocate --task T-1 --kind merge --repo "$r" 2>/dev/null)"
assert_eq "D-firstmate-workflow-T1-1" "$card1" \
  "firstmate allocates the merge card's id; a tree with no registry is the self project"
cp "$DETAILS" "$r/state/decision-details/$card1.json"
rm -rf "$caller"
out3="$(run bin/fm-run.sh once --repo "$r" 2>&1)"
assert_contains "$out3" "asking the captain" "seven green means a decision, not a merge"
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
