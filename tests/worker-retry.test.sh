#!/usr/bin/env bash
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=tests/lib/worker.sh
. "$ROOT/tests/lib/worker.sh"
# A second round continues the first. Starting over from main would throw
# away the work the review is about, and the worker would answer a review
# of something that no longer exists.
d5="$(fixture)"; r5="$d5/repo"; GH5="$(ghstub "$d5")"
cat > "$r5/bin/adapters/mock.sh" <<'M'
#!/usr/bin/env bash
[ "$1" = "run" ] || exit 64
mkdir -p "$3/src"
if [ -f "$3/src/round-one" ]; then
  printf 'the second round\n' > "$3/src/round-two"
  grep -q 'REVIEWER SAID' "$2" && printf 'saw the review\n' > "$3/src/saw-review"
  grep -q 'THE RUNNER SAID' "$2" && printf 'saw the failure\n' > "$3/src/saw-ci"
else
  printf 'the first round\n' > "$3/src/round-one"
fi
M
chmod +x "$r5/bin/adapters/mock.sh"
( cd "$r5" && FM_ROOT="$r5" FM_GH="$GH5" bin/fm-worker.sh --task T-Z >/dev/null 2>&1 )
branch="$(cd "$r5" && git for-each-ref --format='%(refname:short)' refs/heads | grep -v '^main$' | head -1)"
assert_ne "" "$branch" "the first round made a branch"
assert_ok "git -C '$r5' cat-file -e '$branch:src/round-one'" "and committed its work"

# the recorder stub answers a comments query for this round, because what
# the worker is given to answer is the point of the assertion
cat > "$d5/stub/gh" <<'G'
#!/usr/bin/env bash
echo "gh $*" >> "$(dirname "$0")/../ghcalls"
case " $* " in
  *" pr list "*) echo 9; exit 0 ;;
  *" pr checks "*) echo "https://example.invalid/actions/runs/777/job/1"; exit 0 ;;
  # gh refuses an id it does not recognise, and the link carries a job
  # path after the run - so a stub that answers any argument is a stub
  # that cannot see a run id read out of the link wrongly
  " run view 777 --log-failed ") printf 'ci\tbin/ci.sh\tTHE RUNNER SAID: a title with markup is not escaped\n'; exit 0 ;;
  *" run view "*) echo "could not find any workflow run" >&2; exit 1 ;;
  *" pr view "*" comments "*)
    jq -cn '{author:{login:"reviewer-1"},body:"REVIEWER SAID: fix the helper"}' \
      | jq -r '"## " + .author.login + "\n\n" + .body + "\n"' ;;
esac
exit 0
G
chmod +x "$d5/stub/gh"
check_strict_run_stub "$d5/stub/gh" 777
: > "$d5/ghcalls"      # so "did it create one?" is about THIS round
( cd "$r5" && FM_ROOT="$r5" FM_GH="$GH5" bin/fm-worker.sh --task T-Z --pr 9 >/dev/null 2>&1 )
assert_ok "git -C '$r5' cat-file -e '$branch:src/round-one'" "the second round keeps the first round's work"
assert_ok "git -C '$r5' cat-file -e '$branch:src/round-two'" "and adds its own"
assert_ok "git -C '$r5' cat-file -e '$branch:src/saw-review'" "and was given the review to answer"
assert_ok "git -C '$r5' cat-file -e '$branch:src/saw-ci'" "and why the required check is red"
# and it does not try to open a second pull request for the same branch:
# on a later round `pr create` fails, and a worker that could only ever
# open a new one fails at the last step with its work already pushed
assert_lacks "$(cat "$d5/ghcalls" 2>/dev/null)" "pr create" \
  "the second round reuses the pull request it already opened"
# the last event is now agent_finished, so look for the push itself
assert_contains "$(jq -r 'select(.type=="commit_pushed")|.pr|tostring' < "$r5/state/events.jsonl" | tail -1)" "9" \
  "and its event points at that number"

rm -rf "$d5"

# The round this task exists for, and the join the two halves above do
# not make: dispatched from a task id ALONE, on a branch that already
# has a pull request, the worker asks - and the question has to land on
# the number it found for itself. That is the path that broke, and what
# it printed was `its question is on #`, with nothing after the hash.
#
# A fresh fixture, not surgery on the one above: the previous version
# rewound a branch with five silenced git commands and then asserted on
# files the old commit already carried, so it could not tell a round
# that produced them from one that did nothing.
d9="$(fixture)"; r9="$d9/repo"
cat > "$r9/bin/adapters/mock.sh" <<'M'
#!/usr/bin/env bash
[ "$1" = "run" ] || exit 64
cp "$2" "${FM_CAPTURE:-/dev/null}" 2>/dev/null
if [ -f "$3/src/round-one" ]; then
  # BOTH halves of the criterion, one condition each: the question is
  # only written if the prompt carried the review AND the failing check
  grep -q 'REVIEWER SAID' "$2" || exit 1
  grep -q 'THE RUNNER SAID' "$2" || exit 1
  printf 'ASK-PASS-CRITERIA:T-Z\n' > "$3/.fm-say.md"
else
  mkdir -p "$3/src"; printf 'the first round\n' > "$3/src/round-one"
fi
M
chmod +x "$r9/bin/adapters/mock.sh"
GH9="$(ghstub "$d9")"
( cd "$r9" && FM_ROOT="$r9" FM_GH="$GH9" bin/fm-worker.sh --task T-Z >/dev/null 2>&1 )
b9="$(cd "$r9" && git for-each-ref --format='%(refname:short)' refs/heads | grep -v '^main$' | head -1)"
# what the first round DID, not that a branch exists: `git worktree add
# -b` makes the branch before the engine runs, so a branch is also what
# a round that died on its first line leaves
assert_ok "git -C '$r9' cat-file -e '$b9:src/round-one'" \
  "the first round committed work for the second to answer for"
# a stub that knows the branch has #31, and records what it is asked
cat > "$d9/stub/gh" <<'G'
#!/usr/bin/env bash
echo "gh $*" >> "$(dirname "$0")/../ghcalls"
case " $* " in
  *" pr list "*) echo 31; exit 0 ;;
  *" pr checks "*) echo "https://example.invalid/actions/runs/9/job/1"; exit 0 ;;
  " run view 9 --log-failed ") printf 'ci\tbin/ci.sh\tTHE RUNNER SAID: the gate is red\n'; exit 0 ;;
  *" run view "*) echo "could not find any workflow run" >&2; exit 1 ;;
  *" pr view "*" comments "*) printf '## reviewer-1\n\nREVIEWER SAID: answer this\n' ;;
esac
exit 0
G
chmod +x "$d9/stub/gh"
check_strict_run_stub "$d9/stub/gh" 9
: > "$d9/ghcalls"
cap9="$d9/sent.md"
out9="$(cd "$r9" && FM_ROOT="$r9" FM_GH="$GH9" FM_CAPTURE="$cap9" \
        bin/fm-worker.sh --task T-Z 2>&1)"; rc9=$?
sent9="$(cat "$cap9" 2>/dev/null)"
assert_eq "0" "$rc9" "a later round dispatched from a task id alone is a complete round"
assert_contains "$out9" "already has #31" "the worker found the pull request itself"
assert_contains "$out9" "its question is on #31" "and says which one it spoke on, with a number after the hash"
# The CONTENT of the block, read off the prompt the worker was handed -
# not gh having been called, and not an adapter's exit code standing in
# for it. That block is the worker's only view of the runner and it
# arrived empty for real; a proxy cannot tell empty from full.
assert_contains "$sent9" "The required check is red" "the prompt carries the red-check section"
assert_contains "$sent9" "THE RUNNER SAID: the gate is red" "with the runner's own log in it"
assert_contains "$sent9" "REVIEWER SAID: answer this" "and what review said, in the same prompt"
assert_lacks "$sent9" "could not be fetched" "and it did not have to say it failed to fetch it"
# and separately, the run id itself: the link carries a job path after
# the run, and reading the whole tail of it is what emptied the block
assert_contains "$(cat "$d9/ghcalls")" "run view 9 " \
  "having asked for the RUN, not the run plus the job path out of the link"
# "there is no second lookup" - once per run, not once per site: the
# post-push branch reuses what this found, and two answers to one
# question can disagree when a pull request is opened while the engine
# is running
assert_eq "1" "$(grep -c 'pr list' "$d9/ghcalls" || true)" "and it asked which pull request exactly once"
assert_contains "$(cat "$d9/ghcalls")" "pr comment 31" "the question reached that pull request"
assert_eq "31" "$(jq -r 'select(.type=="ask_pass_criteria")|.pr' < "$r9/state/events.jsonl" | tail -1)" \
  "and the log records the number it spoke on"
assert_contains "$out9" "asked rather than changed" \
  "an asking round says so - which is the string the stale-signal test below asserts the ABSENCE of"
rm -rf "$d9"


cd "$ROOT" || exit 1
PATH="$suite_original_path"; export PATH
safe_rm_rf "$suite_tools"
finish
