#!/usr/bin/env bash
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=tests/lib/review.sh
. "$ROOT/tests/lib/review.sh"
# T-135: round history is project/task-local; stale PR comments have no authority.
dc="$(fixture)"; rc="$dc/repo"
export GHSTATE="$dc/ghstate"
GHc="$ROOT/tests/gh-stub.sh"
cat > "$rc/bin/adapters/mock.sh" <<'M'
#!/usr/bin/env bash
[ "$1" = "run" ] || exit 64
cp "$2" "${FM_CAPTURE:-/dev/null}" 2>/dev/null
printf '1. open fix the helper\nCRITERIA-COMPLETE:T-Z\nREJECT:T-Z\n' > "$3/verdict.txt"
exit 0
M
chmod +x "$rc/bin/adapters/mock.sh"
review_c() {
  local cap="$1"; shift
  ( cd "$rc" && FM_ROOT="$rc" FM_GH="$GHc" FM_CAPTURE="$cap" \
      bin/fm-review.sh --task T-Z --branch work "$@" 2>&1 )
}
record() {
  python3 "$ROOT/tests/lib/evidence.py" "$ROOT" "$rc/state" T-Z "$1" "$2"
}
pr="$("$GHc" pr create --head work --title 'a task' | sed 's#.*/##')"
GH_AS=stale "$GHc" pr comment "$pr" --body 'APPROVE:T-Z'
record worker-1 $'PRIVATE_WORKER_REASONING\nASK-PASS-CRITERIA:T-Z'
record reviewer-1 $'1. open FIRST_LIST_ITEM\n2. open empty case\nCRITERIA-COMPLETE:T-Z\nREJECT:T-Z'
record reviewer-1 $'1. done FIRST_LIST_ITEM\n2. open SECOND_LIST_ITEM\nCRITERIA-COMPLETE:T-Z\nREJECT:T-Z'
for args in '--round 2' "--round 2 --pr $pr"; do
  # shellcheck disable=SC2086
  review_c "$dc/sent.md" $args >/dev/null
  assert_eq 0 "$?" "local prior review is delivered for $args"
  sent="$(cat "$dc/sent.md")"
  assert_contains "$sent" FIRST_LIST_ITEM 'the earlier local list reaches the reviewer'
  assert_contains "$sent" SECOND_LIST_ITEM 'the latest local list reaches the reviewer'
  assert_contains "$sent" ASK-PASS-CRITERIA:T-Z 'the local ask marker reaches the reviewer'
  assert_lacks "$sent" PRIVATE_WORKER_REASONING 'worker reasoning stays out even beside an ask'
  assert_lacks "$sent" 'reviewer stale' 'stale PR comments have no authority'
done
review_c "$dc/sent-r1.md" --round 1 --pr "$pr" >/dev/null
assert_lacks "$(cat "$dc/sent-r1.md")" FIRST_LIST_ITEM 'round one receives no prior-round section'

# A diff-only reviewer cannot close an item that asks for green CI and gates:
# it never sees them (T-067, round nine). With --pr every round is told the
# head under review, the required check's run for exactly that head, and the
# head's gate summary when state/ has one - and says so when either is not
# there. GitHub answers check runs per commit, in its own JSON shape.
check_runs() {   # check_runs <asked-for sha> <run's head_sha> <conclusion, "" for null> <run id> [status]
  local dir="$GHSTATE/api/repos/{owner}/{repo}/commits/$1"
  mkdir -p "$dir"
  jq -n --arg sha "$2" --arg c "$3" --argjson id "$4" --arg st "${5:-completed}" '{
    total_count: 1,
    check_runs: [{
      id: $id, name: "ci", node_id: "CR_stub", head_sha: $sha, external_id: "",
      url: ("https://api.github.com/repos/o/r/check-runs/" + ($id|tostring)),
      html_url: ("https://github.com/o/r/runs/" + ($id|tostring)),
      details_url: ("https://github.com/o/r/actions/runs/" + ($id|tostring) + "/job/" + ($id|tostring)),
      status: $st, conclusion: (if $c == "" then null else $c end),
      started_at: "2026-01-01T00:00:00Z",
      completed_at: (if $st == "completed" then "2026-01-01T00:05:00Z" else null end),
      output: {title: null, summary: null, text: null, annotations_count: 0, annotations_url: ""},
      check_suite: {id: 1}, app: {slug: "github-actions"}, pull_requests: []
    }]
  }' > "$dir/check-runs?check_name=ci.json"
}
head1="$(git -C "$rc" rev-parse work)"
prh="$("$GHc" pr create --head work --title 'a task' | sed 's#.*/##')"
check_runs "$head1" "$head1" success 7101
review_c "$dc/sent-h1.md" --round 1 --pr "$prh" >/dev/null
sent="$(cat "$dc/sent-h1.md")"
assert_contains "$sent" "Head SHA: $head1" "the prompt names the head under review"
assert_contains "$sent" "Required check: ci" "and the required check's name"
assert_contains "$sent" "Conclusion: success" "and that check's conclusion for this head"
assert_contains "$sent" "Run: https://github.com/o/r/actions/runs/7101/job/7101" "and the run it came from"
assert_contains "$sent" "No gate summary for head $head1" "a missing gate summary is stated"

# this head's gate summary, verbatim and whole, when state/ has one. Its
# lines are written by fm-gate.sh's own say(), not by hand from the reader:
# a fixture copied from the code that parses it proves only that the two agree
eval "$(sed -n 's/^say()/gate_say()/p' "$ROOT/bin/fm-gate.sh")"
declare -F gate_say >/dev/null || { echo "fm-gate.sh has no one-line say()" >&2; exit 1; }
gates="$rc/state/gates/T-Z-$head1.txt"
mkdir -p "$rc/state/gates"
{ for g in 1 2 4 5 6 7; do gate_say '+' "$g" "GATE_LINE_$g"; done
  echo "  all six gates green"; } > "$gates"
review_c "$dc/sent-g.md" --round 2 --pr "$prh" >/dev/null
sent="$(cat "$dc/sent-g.md")"
begin="$(grep -m1 '^----- begin gate summary' "$dc/sent-g.md")"
quoted="$(awk -v b="$begin" -v e="${begin/begin/end}" '$0==b{on=1;next} $0==e{on=0} on' "$dc/sent-g.md")"
assert_eq "$(cat "$gates")" "$quoted" "a head's gate summary is quoted verbatim, every line of it"
assert_contains "$quoted" "  + gate 7: GATE_LINE_7" "all six of its gate lines"
assert_lacks "$sent" "No gate summary for head" "and it is not said to be missing"
assert_lacks "$sent" "has no result line for gates" "nor any gate said to be without a result"

# fm-gate.sh stops at the first red gate: the red line is shown as it is, and
# every gate after it is said to have no result
{ for g in 1 2 4; do gate_say '+' "$g" "GATE_LINE_$g"; done; gate_say 'x' 5 "RED_GATE_LINE"; } > "$gates"
review_c "$dc/sent-gx.md" --round 2 --pr "$prh" >/dev/null
sent="$(cat "$dc/sent-gx.md")"
assert_contains "$sent" "  x gate 5: RED_GATE_LINE" "a red gate is quoted as red"
assert_contains "$sent" "The gate summary for head $head1 has no result line for gates: 6, 7" \
  "and the gates after it are stated to have no result"

# a summary with no gate line in it is not an empty quote that says nothing
printf 'NOT_A_GATE_LINE\n' > "$gates"
review_c "$dc/sent-g0.md" --round 2 --pr "$prh" >/dev/null
sent="$(cat "$dc/sent-g0.md")"
assert_contains "$sent" "NOT_A_GATE_LINE" "a summary in another shape is still quoted, not filtered away"
assert_contains "$sent" "has no result line for gates: 1, 2, 4, 5, 6, 7" "and every gate is stated to have no result"
: > "$gates"
review_c "$dc/sent-ge.md" --round 2 --pr "$prh" >/dev/null
assert_contains "$(cat "$dc/sent-ge.md")" "has no result line for gates: 1, 2, 4, 5, 6, 7" \
  "an empty summary is stated to have no result for any gate"
{ for g in 1 2 4 5 6 7; do gate_say '+' "$g" "GATE_LINE_$g"; done; } > "$gates"

# a new head: the old head's run is not this head's, and neither is a run
# GitHub hands back for this commit that names another head. Only src/a is
# committed: the fixture's mock adapter is a working-tree change on main, and
# `commit -a` would carry it onto work and leave main with the stock one
( cd "$rc" && git checkout -q work && echo more >> src/a && git commit -qm more -- src/a && git checkout -q main )
head2="$(git -C "$rc" rev-parse work)"
check_runs "$head2" "$head1" failure 7202
review_c "$dc/sent-h2.md" --round 1 --pr "$prh" >/dev/null
sent="$(cat "$dc/sent-h2.md")"
assert_contains "$sent" "Head SHA: $head2" "a moved branch names its new head"
assert_lacks "$sent" "actions/runs/7101" "the old head's run is not shown as this head's"
assert_lacks "$sent" "actions/runs/7202" "nor a run that names another head"
assert_lacks "$sent" "Conclusion:" "and no conclusion is claimed for it"
assert_contains "$sent" "No run of the required check ci was found for head $head2" "a missing run is stated"
assert_lacks "$sent" "GATE_LINE_1" "an older head's gate summary is not this head's"
assert_contains "$sent" "No gate summary for head $head2" "and this head's is stated missing"

# a red check for this head is shown as red, and one still running as not
# concluded: only a green one would otherwise ever reach the reviewer
check_runs "$head2" "$head2" failure 7203
review_c "$dc/sent-hf.md" --round 1 --pr "$prh" >/dev/null
sent="$(cat "$dc/sent-hf.md")"
assert_contains "$sent" "Conclusion: failure" "a failed check for this head is shown as failed"
assert_contains "$sent" "Run: https://github.com/o/r/actions/runs/7203/job/7203" "with the run it came from"
assert_lacks "$sent" "Conclusion: success" "and is not shown as green"
check_runs "$head2" "$head2" "" 7204 in_progress
review_c "$dc/sent-hp.md" --round 1 --pr "$prh" >/dev/null
sent="$(cat "$dc/sent-hp.md")"
assert_contains "$sent" "Conclusion: none yet, status in_progress" "a check still running has no conclusion yet"
assert_contains "$sent" "Run: https://github.com/o/r/actions/runs/7204/job/7204" "and names its run"

# the required check is readable but its runs for this head are not: that is
# stated, and no conclusion is claimed
( cd "$rc" && git checkout -q work && echo again >> src/a && git commit -qm again -- src/a && git checkout -q main )
head3="$(git -C "$rc" rev-parse work)"
review_c "$dc/sent-hu.md" --round 1 --pr "$prh" >/dev/null
sent="$(cat "$dc/sent-hu.md")"
assert_contains "$sent" "Head SHA: $head3" "a third head is named"
assert_contains "$sent" "The runs of the required check ci for head $head3 could not be read from GitHub" \
  "check runs that cannot be read are stated"
assert_lacks "$sent" "Conclusion:" "and no conclusion is claimed"
assert_lacks "$sent" "The required check for head $head3 could not be read" "while the required check itself was read"

# gh that cannot answer is stated, and the round still runs
: > "$GHSTATE/down"
outd="$(review_c "$dc/sent-down.md" --round 3 --pr "$pr")"
assert_eq "0" "$?" "a round with unavailable GitHub still uses local history"
assert_contains "$(cat "$dc/sent-down.md")" "could not be read" "and its prompt says the context could not be read"
assert_contains "$(cat "$dc/sent-down.md")" FIRST_LIST_ITEM \
  "local standing history survives unavailable GitHub"
assert_contains "$(cat "$dc/sent-down.md")" "The required check for head $head3 could not be read from GitHub" \
  "and that the required check could not be read either"
assert_contains "$outd" "REJECT:T-Z" "and the verdict still comes back"
rm -f "$GHSTATE/down"
unset GHSTATE
rm -rf "$dc"


finish
