#!/usr/bin/env bash
# The worker runs an adapter and then does all the git itself. The adapter
# must never be near a repository operation.
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

# A simulated fetch failure must reject malformed arguments too: its normal
# nonzero status alone cannot distinguish the fixture response from rejection.
check_strict_run_stub() (
  local stub="$1" id="$2" response rc
  # Earlier fixture assertions may leave the caller in a removed worktree.
  cd "$ROOT" || return 1
  response="$("$stub" run view "$id" --log-failed --job 999 2>&1)"; rc=$?
  assert_eq "1" "$rc" "run $id stub rejects extra job selector"
  assert_eq "could not find any workflow run" "$response" "run $id extra selector cannot return fixture output"
  response="$("$stub" run view --job "$id" --log-failed 2>&1)"; rc=$?
  assert_eq "1" "$rc" "run $id stub rejects job namespace"
  assert_eq "could not find any workflow run" "$response" "run $id job namespace cannot return fixture output"
  response="$("$stub" run view "$id" 2>&1)"; rc=$?
  assert_eq "1" "$rc" "run $id stub requires log-failed flag"
  assert_eq "could not find any workflow run" "$response" "run $id missing flag cannot return fixture output"
)

fixture() {                     # a repo with a remote, a task, and the real scripts
  local d; d="$(mktemp -d)"; local bare="$d/remote.git" task="${1:-T-Z}"
  git init -q --bare "$bare"
  git init -q -b main "$d/repo"
  # Never leave the suite cwd inside a disposable fixture: later asserts use
  # `git --git-dir=...` and fail with "Unable to read current working directory"
  # once the fixture is rm -rf'd.
  (
  cd "$d/repo" || exit 1
  git config user.email a@b.c; git config user.name t
  mkdir -p bin design/tasks skills/worker state
  cp "$ROOT/bin/fm-config.sh" "$ROOT/bin/fm-emit.sh" "$ROOT/bin/fm-worker.sh" \
     "$ROOT/bin/fm-checkpoint.sh" "$ROOT/bin/fm-guard.sh" "$ROOT/bin/fm-herdr.py" bin/
  cp -r "$ROOT/bin/adapters" bin/
  cp "$ROOT/skills/worker/SKILL.md" skills/worker/
  printf 'vendor: mock\nfallback:\n  - mock\n' > config.yaml
  jq -n --arg task "$task" '{id:$task,title:"a mock task",scope:["src/**"],acceptance:["it exists"]}' \
    > "design/tasks/$task.json"
  printf '# design\n## 6. gates\nseven of them\n## 8. board\n' > design/design.md
  git add -A; git commit -qm base; git remote add origin "$bare"; git push -q -u origin main
  ) || return 1
  printf '%s' "$d"
}

ghstub() {                      # records what it was asked, invents a pull request url
  # `pr list` has to answer the way gh does: through `--jq
  # '.[0].number'` a branch with no open pull request is the literal
  # `null`, not silence, and the worker normalises it. A stub that
  # answers with nothing leaves that normalisation untested - and a
  # stub that answers every question with a url tells the worker a
  # pull request already exists and it never opens one.
  mkdir -p "$1/stub"
  cat > "$1/stub/gh" <<G
#!/usr/bin/env bash
echo "gh \$*" >> "$1/ghcalls"
case " \$* " in
  *" pr list "*) echo null; exit 0 ;;
esac
echo "https://example.invalid/pull/42"
G
  chmod +x "$1/stub/gh"; printf '%s' "$1/stub/gh"
}

if [ "${FM_WORKER_LIVENESS_ONLY:-0}" != 1 ]; then
d="$(fixture)"; r="$d/repo"; GH="$(ghstub "$d")"
out="$(cd "$r" && FM_ROOT="$r" FM_GH="$GH" bin/fm-worker.sh --task T-Z --name worker-1 2>&1)"; rc=$?
assert_eq "0" "$rc" "a clean run exits 0"
branch="$(printf '%s' "$out" | tail -1)"
assert_contains "$branch" "t-z" "it names the branch after the task"
assert_ok "test -d '$r/state/worktrees/T-Z'" "it made a worktree of its own"
assert_ok "git -C '$r' rev-parse --verify '$branch'" "the branch exists"
assert_eq "1" "$(git -C "$r" rev-list --count "main..$branch")" "exactly one commit"
assert_ok "git -C '$r/state/worktrees/T-Z' show --stat HEAD | grep -q mock.txt" "the adapter's file is in it"
assert_ok "cd '$ROOT' && git --git-dir='$d/remote.git' rev-parse --verify '$branch'" "it pushed to the remote"
assert_contains "$(cat "$d/ghcalls")" "pr create" "it opened a pull request"

log="$r/state/events.jsonl"
assert_contains "$(jq -r .type < "$log" | tr '\n' ' ')" "commit_pushed" "it emitted commit_pushed"
assert_contains "$(jq -r .type < "$log" | tr '\n' ' ')" "pr_opened" "it emitted pr_opened"
assert_eq "$(jq -r 'select(.type=="dispatched")|.actor' "$log")" \
  "$(jq -r 'select(.type=="dispatched")|.data.crew_name' "$log")" \
  "the worker publishes its exact canonical actor as crew_name"
assert_ne "null" "$(jq -r 'select(.type=="dispatched")|.data.activity.en' "$log")" \
  "the worker emits authored activity.en (never invents from a missing field as null-only)"
assert_ne "null" "$(jq -r 'select(.type=="dispatched")|.data.activity["zh-TW"]' "$log")" \
  "the worker emits authored activity.zh-TW"
assert_contains "$(jq -r .type < "$log" | tr '\n' ' ')" "crew_status" \
  "the worker emits mid-run crew_status at a script-known node"
assert_eq "0" "$(jq -c 'select(.type=="crew_status" and (.data.progress!=null))' "$log" | wc -l | tr -d ' ')" \
  "ordinary mid-run status does not invent a percentage without a denominator"

# the prompt carries the task and the skill, and is not left lying around
assert_fail "test -f '$r/state/worktrees/T-Z/.fm-prompt.md'" "the prompt is cleaned up"

# an adapter that cannot reach its vendor falls through to the next one
d2="$(fixture)"; r2="$d2/repo"; GH2="$(ghstub "$d2")"
( cd "$r2" && FM_ROOT="$r2" FM_GH="$GH2" FM_MOCK_EXIT=2 bin/fm-worker.sh --task T-Z >/dev/null 2>&1 )
assert_eq "2" "$?" "every vendor unavailable exits 2"
assert_contains "$(jq -r .type < "$r2/state/events.jsonl" | tr '\n' ' ')" "vendor_unavailable" \
  "it emitted vendor_unavailable"
assert_eq "" "$(cat "$d2/ghcalls" 2>/dev/null)" "an unavailable vendor opens no pull request"

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

# The worker cannot run gh, so the only way its question reaches the
# reviewer is this file. Without it the round-three protocol cannot happen:
# ASK-PASS-CRITERIA sits in a log nobody reads while fm-protocol reports a
# violation every turn, which looks exactly like a worker that stopped.
d6="$(fixture)"; r6="$d6/repo"; GH6="$(ghstub "$d6")"
cat > "$r6/bin/adapters/mock.sh" <<'M'
#!/usr/bin/env bash
[ "$1" = "run" ] || exit 64
printf 'ASK-PASS-CRITERIA:T-Z\n' > "$3/.fm-say.md"
M
chmod +x "$r6/bin/adapters/mock.sh"
out6="$(cd "$r6" && FM_ROOT="$r6" FM_GH="$GH6" bin/fm-worker.sh --task T-Z --pr 9 2>&1)"
assert_eq "0" "$?" "a round in which the worker only asks is a complete round"
assert_contains "$out6" "asked rather than changed" "and says so rather than looking idle"
assert_contains "$(cat "$d6/ghcalls")" "pr comment" "the question is posted to the pull request"
assert_contains "$(jq -r .type < "$r6/state/events.jsonl" | tr '\n' ' ')" "ask_pass_criteria" \
  "and the log records that the worker spoke"
assert_lacks "$(cat "$d6/ghcalls")" "push" "asking pushes nothing"
b6="$(cd "$r6" && git for-each-ref --format='%(refname:short)' refs/heads | grep -v '^main$' | head -1)"
assert_fail "git -C '$r6' cat-file -e '$b6:.fm-say.md'" "and the file never reaches the diff"
rm -rf "$d6"

# A question that went nowhere leaves the task deadlocked: the reviewer
# waits for a question it will never see and the next round asks it
# again. That used to be a line on standard error and an exit 0 - the
# run reported a complete round and the log said nothing at all. It is
# the run's outcome now.
d7="$(fixture)"; r7="$d7/repo"; GH7="$(ghstub "$d7")"
cat > "$r7/bin/adapters/mock.sh" <<'M'
#!/usr/bin/env bash
[ "$1" = "run" ] || exit 64
printf 'ASK-PASS-CRITERIA:T-Z\n' > "$3/.fm-say.md"
M
chmod +x "$r7/bin/adapters/mock.sh"
# a gh that refuses the comment and nothing else
cat > "$d7/stub/gh" <<'G'
#!/usr/bin/env bash
echo "gh $*" >> "$(dirname "$0")/../ghcalls"
case " $* " in *" pr comment "*) echo "could not post" >&2; exit 1 ;; esac
echo "https://example.invalid/pull/42"
G
chmod +x "$d7/stub/gh"
out7="$(cd "$r7" && FM_ROOT="$r7" FM_GH="$GH7" bin/fm-worker.sh --task T-Z --pr 9 2>&1)"; rc7=$?
assert_eq "73" "$rc7" "a question that could not be posted fails the run"
assert_contains "$out7" "nowhere to put it" "and says what happened"
assert_contains "$out7" "#9" "naming the pull request that would not take it"
# and WHY, which is the only thing that tells the person picking this
# up by hand whether to retry, ask for access, or fix the number
assert_contains "$out7" "could not post" "and passing on what gh said about it"
assert_eq "9" "$(jq -r 'select(.type=="worker_crashed")|.pr' < "$r7/state/events.jsonl" | tail -1)" \
  "and the event carries it, so the board can link the failed round to the pull request"
# the FILE, not the length: with nullglob off bash leaves an unmatched
# pattern in place, so the array has one element either way
unsent7=("$r7"/state/unsent/T-Z-*.md)
assert_ok "test -s '${unsent7[0]}'" "and the question itself is kept, outside the worktree"
assert_contains "$(jq -r .type < "$r7/state/events.jsonl" | tr '\n' ' ')" "worker_crashed" \
  "and the log carries it, so the board is not showing a round that went fine"
# d9 above emits ask_pass_criteria on a round where the post succeeded,
# so this absence is about the post failing and not about a type the
# log never carries
assert_lacks "$(jq -r .type < "$r7/state/events.jsonl" | tr '\n' ' ')" "ask_pass_criteria" \
  "and does not claim the worker spoke"
rm -rf "$d7"

# and the same with no pull request at all to say it on
d8="$(fixture)"; r8="$d8/repo"; GH8="$(ghstub "$d8")"
# written out, not copied from $r7: that fixture was removed four lines
# up, so the cp failed every run and the `||` fallback was the whole
# implementation wearing a conditional
cat > "$r8/bin/adapters/mock.sh" <<'M'
#!/usr/bin/env bash
[ "$1" = "run" ] || exit 64
printf 'ASK-PASS-CRITERIA:T-Z\n' > "$3/.fm-say.md"
M
chmod +x "$r8/bin/adapters/mock.sh"
out8="$(cd "$r8" && FM_ROOT="$r8" FM_GH="$GH8" bin/fm-worker.sh --task T-Z 2>&1)"; rc8=$?
assert_eq "73" "$rc8" "so does a question with no pull request to put it on"
assert_contains "$out8" "no pull request to say it on - asking is premature" \
  "and it says what was actually checked - there is no pull request"
# the payload survives, or the only copy of the question is gone and
# nobody can post it by hand either
# OUT of the worktree: the next round removes and recreates that, so
# the file where it was written is gone as soon as anything runs again
# - and the design says the text survives for a human to post
unsent8=("$r8"/state/unsent/T-Z-*.md)
assert_ok "test -s '${unsent8[0]}'" \
  "what the worker wrote is kept where the next round will not delete it"
assert_contains "$out8" "state/unsent/T-Z" "and the run says where"
assert_contains "$(jq -r 'select(.type=="worker_crashed")|.summary.en // .en' \
  < "$r8/state/events.jsonl" | tail -1)" "before there was a pull request" \
  "and the log says which of the two it was"
assert_lacks "$(cat "$d8/ghcalls" 2>/dev/null)" "pr create" \
  "a note with no work behind it opens no pull request"
rm -rf "$d8"

# A note is not only a question. An adapter that may edit but not execute
# (claude under acceptEdits) finishes the work and says which checks it
# could not run - and on a first round the old block read that note as a
# premature question, kept it in state/unsent/, exited 73 and opened no
# pull request for work that was sitting in the worktree. Work plus a
# note is a round that pushes, opens its pull request, and then speaks.
d8w="$(fixture)"; r8w="$d8w/repo"; GH8w="$(ghstub "$d8w")"
cat > "$r8w/bin/adapters/mock.sh" <<'M'
#!/usr/bin/env bash
[ "$1" = "run" ] || exit 64
mkdir -p "$3/src"; printf 'the work\n' > "$3/src/done.txt"
printf 'COULD NOT RUN: tests/worker.test.sh\n' > "$3/.fm-say.md"
M
chmod +x "$r8w/bin/adapters/mock.sh"
# the stub records the body it was handed, so the assertion is about
# what the reviewer reads and not only that a comment was attempted
cat > "$d8w/stub/gh" <<G
#!/usr/bin/env bash
echo "gh \$*" >> "$d8w/ghcalls"
case " \$* " in
  *" pr list "*) echo null; exit 0 ;;
  *" pr comment "*)
    while [ \$# -gt 0 ]; do
      [ "\$1" = --body-file ] && cat "\$2" >> "$d8w/commented"; shift
    done
    exit 0 ;;
esac
echo "https://example.invalid/pull/42"
G
chmod +x "$d8w/stub/gh"
out8w="$(cd "$r8w" && FM_ROOT="$r8w" FM_GH="$GH8w" bin/fm-worker.sh --task T-Z 2>&1)"; rc8w=$?
assert_eq "0" "$rc8w" "a first round that changed files and left a note is a complete round"
assert_contains "$(cat "$d8w/ghcalls" 2>/dev/null)" "pr create" "it opens the pull request"
calls8w="$(cat "$d8w/ghcalls" 2>/dev/null)"
assert_contains "$calls8w" "pr comment 42" "and the note goes to the pull request it just opened"
# order, not presence: a comment attempted before the pull request exists
# has nowhere to land
assert_eq "pr create" "$(grep -o 'pr create\|pr comment' "$d8w/ghcalls" 2>/dev/null | head -1)" \
  "the pull request is opened before the note is posted"
assert_eq "COULD NOT RUN: tests/worker.test.sh" "$(cat "$d8w/commented" 2>/dev/null)" \
  "with the worker's own words as the comment body"
b8w="$(cd "$r8w" && git for-each-ref --format='%(refname:short)' refs/heads | grep -v '^main$' | head -1)"
assert_ok "cd '$ROOT' && git --git-dir='$d8w/remote.git' cat-file -e '$b8w:src/done.txt'" \
  "the work was committed and pushed"
assert_fail "cd '$ROOT' && git --git-dir='$d8w/remote.git' cat-file -e '$b8w:.fm-say.md'" \
  "and the note never reaches the diff"
assert_lacks "$out8w" "asking is premature" "a note beside real work is not a premature question"
assert_fail "ls '$r8w'/state/unsent/T-Z-*.md" "nothing is left unsent"
types8w="$(jq -r .type < "$r8w/state/events.jsonl" | tr '\n' ' ')"
assert_contains "$types8w" "pr_opened" "the log records the pull request"
assert_lacks "$types8w" "worker_crashed" "and no crash"
assert_eq "42" "$(jq -r 'select(.type=="ask_pass_criteria")|.pr' < "$r8w/state/events.jsonl" | tail -1)" \
  "and that the worker spoke on it"
rm -rf "$d8w"

# The same round when the new pull request will not take the comment: the
# work is already pushed and the pull request open, so those stand - but
# the note is kept where a human can post it and the run says so, exactly
# as a refused comment on an existing pull request does.
d8x="$(fixture)"; r8x="$d8x/repo"
cat > "$r8x/bin/adapters/mock.sh" <<'M'
#!/usr/bin/env bash
[ "$1" = "run" ] || exit 64
mkdir -p "$3/src"; printf 'the work\n' > "$3/src/done.txt"
printf 'COULD NOT RUN: anything\n' > "$3/.fm-say.md"
M
chmod +x "$r8x/bin/adapters/mock.sh"
mkdir -p "$d8x/stub"
cat > "$d8x/stub/gh" <<G
#!/usr/bin/env bash
echo "gh \$*" >> "$d8x/ghcalls"
case " \$* " in
  *" pr list "*) echo null; exit 0 ;;
  *" pr comment "*) echo "refused by the stub" >&2; exit 1 ;;
esac
echo "https://example.invalid/pull/42"
G
chmod +x "$d8x/stub/gh"
out8x="$(cd "$r8x" && FM_ROOT="$r8x" FM_GH="$d8x/stub/gh" bin/fm-worker.sh --task T-Z 2>&1)"; rc8x=$?
assert_eq "73" "$rc8x" "a note the new pull request refused still fails the run"
assert_contains "$(cat "$d8x/ghcalls" 2>/dev/null)" "pr create" "after the pull request was opened"
assert_contains "$out8x" "#42 would not take the comment" "naming the pull request that refused it"
assert_contains "$out8x" "refused by the stub" "and passing on what gh said"
unsent8x=("$r8x"/state/unsent/T-Z-*.md)
assert_eq "COULD NOT RUN: anything" "$(cat "${unsent8x[0]}" 2>/dev/null)" \
  "and the note is kept outside the worktree"
assert_eq "42" "$(jq -r 'select(.type=="worker_crashed")|.pr' < "$r8x/state/events.jsonl" | tail -1)" \
  "the crash event carries the number"
rm -rf "$d8x"

# Every other way out between setting the note aside and posting it. The
# note left the worktree before the commit, so the scratch copy is the
# only one; a push the remote refuses (71), a url with no number in it
# (72) or a TERM while the pull request is being opened (143) used to
# remove that copy with the rest of the scratch files. Each keeps it
# under state/unsent/ and says so, and each keeps its own exit status.
held_note_case() {   # held_note_case <label> <want-rc> <gh-create-body> [pre-receive]
  local d r out rc
  d="$(fixture)"; r="$d/repo"
  cat > "$r/bin/adapters/mock.sh" <<'M'
#!/usr/bin/env bash
[ "$1" = "run" ] || exit 64
mkdir -p "$3/src"; printf 'the work\n' > "$3/src/done.txt"
printf 'COULD NOT RUN: anything\n' > "$3/.fm-say.md"
M
  chmod +x "$r/bin/adapters/mock.sh"
  mkdir -p "$d/stub"
  cat > "$d/stub/gh" <<G
#!/usr/bin/env bash
echo "gh \$*" >> "$d/ghcalls"
case " \$* " in
  *" pr list "*) echo null; exit 0 ;;
  *" pr create "*) $3 ;;
esac
exit 0
G
  chmod +x "$d/stub/gh"
  if [ -n "${4:-}" ]; then
    printf '#!/bin/sh\necho "%s" >&2\nexit 1\n' "$4" > "$d/remote.git/hooks/pre-receive"
    chmod +x "$d/remote.git/hooks/pre-receive"
  fi
  out="$(cd "$r" && FM_ROOT="$r" FM_GH="$d/stub/gh" bin/fm-worker.sh --task T-Z 2>&1)"; rc=$?
  assert_eq "$2" "$rc" "$1: the run keeps its own exit status"
  local kept=("$r"/state/unsent/T-Z-*.md)
  assert_eq "COULD NOT RUN: anything" "$(cat "${kept[0]}" 2>/dev/null)" \
    "$1: the note that never reached a pull request is kept outside the worktree"
  assert_contains "$out" "state/unsent/T-Z" "$1: and the run says where"
  assert_lacks "$(cat "$d/ghcalls" 2>/dev/null)" "pr comment" "$1: no comment was attempted"
  assert_contains "$(jq -r 'select(.type=="worker_crashed")|.summary.en // .en' \
    < "$r/state/events.jsonl" | tail -1)" "note" "$1: and the log records the note was not posted"
  rm -rf "$d"
}
held_note_case "push refused" 71 'echo https://example.invalid/pull/42' "refused by the remote"
held_note_case "no pull request number" 72 'echo "something went wrong"'
# the stub TERMs the worker while it waits on `pr create`; bash runs the
# trap when the command substitution returns. Single-quoted: the stub
# reads the pid file through the FM_ROOT the worker handed down
held_note_case "TERM while opening the pull request" 143 \
  'kill -TERM "$(cat "$FM_ROOT/state/worktrees/T-Z.pid")"; echo https://example.invalid/pull/42'

# A later round whose lookup could not answer. "No pull request" and
# "gh did not answer" used to be the same empty string, and they are
# opposite instructions: the first means open one, the second means the
# prompt would carry no review and the push would collide with a pull
# request nobody looked for. So the run stops BEFORE the engine - which
# is what this asserts, rather than that it printed a warning.
d10="$(fixture)"; r10="$d10/repo"; GH10="$(ghstub "$d10")"
# the counter is OUTSIDE the worktree, because the worktree is recreated
# from the branch each round - a file the first round committed is back
# on disk before the second one starts, so it cannot say whether the
# engine ran
runs="$d10/engine-runs"
cat > "$r10/bin/adapters/mock.sh" <<'M'
#!/usr/bin/env bash
[ "$1" = "run" ] || exit 64
echo ran >> "${FM_RUNS:?}"
mkdir -p "$3/src"
printf '%s\n' "$RANDOM$$" > "$3/src/work"
M
chmod +x "$r10/bin/adapters/mock.sh"
( cd "$r10" && FM_ROOT="$r10" FM_GH="$GH10" FM_RUNS="$runs" bin/fm-worker.sh --task T-Z >/dev/null 2>&1 )
assert_eq "1" "$(grep -c . "$runs" 2>/dev/null || true)" "the first round ran the engine once"
# a gh that cannot answer, which is what a rate limit or an outage is
printf '#!/usr/bin/env bash\necho "HTTP 503" >&2\nexit 1\n' > "$d10/stub/gh"
chmod +x "$d10/stub/gh"
out10="$(cd "$r10" && FM_ROOT="$r10" FM_GH="$GH10" FM_RUNS="$runs" bin/fm-worker.sh --task T-Z 2>&1)"; rc10=$?
assert_eq "74" "$rc10" "a later round whose lookup cannot answer stops"
# what it DID, not what it said
assert_eq "1" "$(grep -c . "$runs" 2>/dev/null || true)" \
  "and stops before the engine, rather than running blind"
assert_contains "$out10" "could not ask which pull request" "it says what it could not do"
assert_contains "$out10" "HTTP 503" "and passes on what gh said, instead of swallowing it"
rm -rf "$d10"

# and the other half of the same status, which must NOT stop: a lookup
# that succeeded and said there is none. A round that pushed and then
# died before opening a pull request leaves exactly that, and the right
# thing is to carry on and open one.
d13="$(fixture)"; r13="$d13/repo"; GH13="$(ghstub "$d13")"
cat > "$r13/bin/adapters/mock.sh" <<'M'
#!/usr/bin/env bash
[ "$1" = "run" ] || exit 64
mkdir -p "$3/src"
printf '%s\n' "$RANDOM$$" > "$3/src/work"
M
chmod +x "$r13/bin/adapters/mock.sh"
( cd "$r13" && FM_ROOT="$r13" FM_GH="$GH13" bin/fm-worker.sh --task T-Z >/dev/null 2>&1 )
# a gh that answers, and answers "none"
cat > "$d13/stub/gh" <<'G'
#!/usr/bin/env bash
echo "gh $*" >> "$(dirname "$0")/../ghcalls"
case " $* " in
  # what gh really prints for a branch with no open pull request,
  # through `--jq '.[0].number'`: the literal four characters, not
  # silence. A stub that answers with nothing tests the code's
  # expectation rather than the vendor.
  *" pr list "*) echo null; exit 0 ;;
  *" pr view "*|*" pr checks "*) exit 0 ;;
esac
echo "https://example.invalid/pull/61"
G
chmod +x "$d13/stub/gh"; : > "$d13/ghcalls"
out14="$(cd "$r13" && FM_ROOT="$r13" FM_GH="$GH13" bin/fm-worker.sh --task T-Z 2>&1)"; rc14=$?
assert_eq "0" "$rc14" "a lookup that answers \"none\" is not a failure"
assert_contains "$out14" "will open one" "and the run says it is opening one"
# d9 counts this on an asking round, which never reaches the post-push
# site at all. This one does - it goes all the way to `pr create` - so
# it is the fixture that can see a second lookup if one comes back
assert_eq "1" "$(grep -c 'pr list' "$d13/ghcalls" || true)" \
  "and asked which pull request exactly once, on a round that runs to the end"
assert_lacks "$out14" "#null" "and never carries gh's four characters through as a number"
assert_contains "$(cat "$d13/ghcalls")" "pr create" "and it does open one"
rm -rf "$d13"

# A log that cannot be fetched must SAY so. An empty block reads to the
# worker exactly like a green run - it cannot run gh, so that block is
# its only view of the runner - and a round was spent asking why the
# check was red when the block was simply blank.
d16="$(fixture)"; r16="$d16/repo"; GH16="$(ghstub "$d16")"
cat > "$r16/bin/adapters/mock.sh" <<'M'
#!/usr/bin/env bash
[ "$1" = "run" ] || exit 64
cp "$2" "${FM_CAPTURE:-/dev/null}" 2>/dev/null
mkdir -p "$3/src"
if [ -f "$3/src/round-one" ]; then printf 'two\n' > "$3/src/round-two"
else printf 'one\n' > "$3/src/round-one"; fi
M
chmod +x "$r16/bin/adapters/mock.sh"
( cd "$r16" && FM_ROOT="$r16" FM_GH="$GH16" FM_CAPTURE=/dev/null \
    bin/fm-worker.sh --task T-Z >/dev/null 2>&1 )
# a red check whose log gh will not hand over
cat > "$d16/stub/gh" <<'G'
#!/usr/bin/env bash
case " $* " in
  *" pr list "*) echo 21; exit 0 ;;
  # the run id is NOT in gh's message: `404` in both would make
  # "names the run" pass off the echoed gh line alone
  *" pr checks "*) echo "https://example.invalid/actions/runs/51/job/1"; exit 0 ;;
  " run view 51 --log-failed ") echo "HTTP 404: Not Found" >&2; exit 1 ;;
  *" run view "*) echo "could not find any workflow run" >&2; exit 1 ;;
  *" pr view "*" comments "*) printf '## reviewer-1

something
' ;;
esac
exit 0
G
chmod +x "$d16/stub/gh"
check_strict_run_stub "$d16/stub/gh" 51
cap16="$d16/sent.md"
( cd "$r16" && FM_ROOT="$r16" FM_GH="$GH16" FM_CAPTURE="$cap16" \
    bin/fm-worker.sh --task T-Z >/dev/null 2>&1 )
sent16="$(cat "$cap16" 2>/dev/null)"
assert_contains "$sent16" "The required check is red" "the prompt still says the check is red"
# the whole phrase, so a mis-parsed run id fails it: `run 51/job/1`
# would satisfy a bare "51" and so would gh's own message
assert_contains "$sent16" "The log for run 51 could not be fetched" \
  "and says the log could not be fetched, naming the run it asked for"
assert_contains "$sent16" "gh: HTTP 404" "and passing on what gh said about it"
rm -rf "$d16"

# and a required check that is not an Actions run at all - Buildkite,
# CircleCI - whose link has no /actions/runs/ in it. Reading the tail
# of that leaves the whole URL, which the run-id trim reduces to
# `https:`, and the worker is told "the log for run https: could not be
# fetched".
d17="$(fixture)"; r17="$d17/repo"; GH17="$(ghstub "$d17")"
cat > "$r17/bin/adapters/mock.sh" <<'M'
#!/usr/bin/env bash
[ "$1" = "run" ] || exit 64
cp "$2" "${FM_CAPTURE:-/dev/null}" 2>/dev/null
mkdir -p "$3/src"
if [ -f "$3/src/round-one" ]; then printf 'two\n' > "$3/src/round-two"
else printf 'one\n' > "$3/src/round-one"; fi
M
chmod +x "$r17/bin/adapters/mock.sh"
( cd "$r17" && FM_ROOT="$r17" FM_GH="$GH17" bin/fm-worker.sh --task T-Z >/dev/null 2>&1 )
cat > "$d17/stub/gh" <<'G'
#!/usr/bin/env bash
echo "gh $*" >> "$(dirname "$0")/../ghcalls"
case " $* " in
  *" pr list "*) echo 22; exit 0 ;;
  *" pr checks "*) echo "https://buildkite.com/acme/pipeline/builds/1234"; exit 0 ;;
  *" pr view "*" comments "*) printf '## reviewer-1\n\nsomething\n' ;;
esac
exit 0
G
chmod +x "$d17/stub/gh"; : > "$d17/ghcalls"
cap17="$d17/sent.md"
( cd "$r17" && FM_ROOT="$r17" FM_GH="$GH17" FM_CAPTURE="$cap17" \
    bin/fm-worker.sh --task T-Z >/dev/null 2>&1 )
sent17="$(cat "$cap17" 2>/dev/null)"
assert_contains "$sent17" "The required check is red" "the prompt still says the check is red"
assert_contains "$sent17" "No run id could be read out of" "and says what it could not do"
assert_contains "$sent17" "buildkite.com/acme/pipeline/builds/1234" "naming the check it means"
assert_lacks "$sent17" "run https:" "rather than asking for a run called https:"
assert_lacks "$sent17" "is not a GitHub Actions run" \
  "and does not claim to know which CI produced the link, which it cannot"
assert_lacks "$(cat "$d17/ghcalls")" "run view" "and it does not ask gh for a run that is not one"
rm -rf "$d17"

# The three ways the block can come out empty, each said differently,
# because to the worker they mean different things. A run id that is
# not a number; a fetch that failed; and a fetch that SUCCEEDED and
# had nothing, which "could not be fetched" would misreport as gh's
# fault in the one block the worker cannot check.
# <id> is the run or job ID the code must compute out of <link>:
# the stub answers that and refuses anything else, so a mis-parse is a
# failure here rather than a pass. A stub that answers `run view` for
# any argument cannot see the bug this task exists for.
redcheck() {   # redcheck <label> <check link> <id> <run view body> <want> [job]
  # Optional seventh/eighth arguments assert retained log and stderr content.
  local d r g cap sent
  d="$(fixture)"; r="$d/repo"; g="$(ghstub "$d")"
  cat > "$r/bin/adapters/mock.sh" <<'M'
#!/usr/bin/env bash
[ "$1" = "run" ] || exit 64
cp "$2" "${FM_CAPTURE:-/dev/null}" 2>/dev/null
mkdir -p "$3/src"
if [ -f "$3/src/round-one" ]; then printf 'two\n' > "$3/src/round-two"
else printf 'one\n' > "$3/src/round-one"; fi
M
  chmod +x "$r/bin/adapters/mock.sh"
  ( cd "$r" && FM_ROOT="$r" FM_GH="$g" bin/fm-worker.sh --task T-Z >/dev/null 2>&1 )
  { printf '#!/usr/bin/env bash\n'
    printf 'echo "gh $*" >> "$(dirname "$0")/../ghcalls"\n'
    printf 'case " $* " in\n'
    printf '  *" pr list "*) echo 23; exit 0 ;;\n'
    printf '  *" pr checks "*) echo "%s"; exit 0 ;;\n' "$2"
    # Exact arguments keep job IDs and workflow run IDs in separate namespaces.
    printf '  " run view %s%s --log-failed ") %s ;;\n' "${6:+--job }" "$3" "$4"
    printf '  *" run view "*) echo "could not find any workflow run" >&2; exit 1 ;;\n'
    printf '  *" pr view "*" comments "*) printf %s ;;\n' "'## r\n\nsomething\n'"
    printf 'esac\nexit 0\n'
  } > "$d/stub/gh"
  chmod +x "$d/stub/gh"
  cap="$d/sent.md"
  ( cd "$r" && FM_ROOT="$r" FM_GH="$g" FM_CAPTURE="$cap" \
      bin/fm-worker.sh --task T-Z >/dev/null 2>&1 )
  sent="$(cat "$cap" 2>/dev/null)"
  assert_contains "$sent" "The required check is red" "$1: the section is there"
  assert_contains "$sent" "$5" "$1"
  [ -z "${7:-}" ] || assert_contains "$sent" "$7" "$1: log content survives"
  [ -z "${8:-}" ] || assert_contains "$sent" "$8" "$1: fetch diagnostic survives"
  rm -rf "$d"
}
redcheck "a run id that is not a number says what the SCRIPT could not do" \
  "https://github.com/o/r/actions/runs/latest/job/1" "NONE" "exit 0" \
  "No run id could be read out of"
# Legacy details URLs identify jobs, not workflow runs. The stub refuses
# the same numeric ID when passed as a positional workflow run ID.
redcheck "an old-style /runs/<id> link selects a job" \
  "https://github.com/o/r/runs/6789123" "6789123" \
  "printf 'ci\tbin/ci.sh\tOLD STYLE LOG\n'; exit 0" \
  "OLD STYLE LOG" job
# and that link is served with a query on the job segment in the wild
redcheck "even with a query string after the id" \
  "https://github.com/o/r/runs/6789124?check_suite_focus=true" "6789124" \
  "printf 'ci\tbin/ci.sh\tQUERY STRING LOG\n'; exit 0" \
  "QUERY STRING LOG" job
redcheck "a legacy fragment also selects the job" \
  "https://github.com/o/r/runs/6789125#step:2:1" "6789125" \
  "printf 'ci\tx\tFRAGMENT LOG\n'; exit 0" \
  "FRAGMENT LOG" job
redcheck "modern links keep the workflow run namespace" \
  "https://github.com/o/r/actions/runs/72/job/6789125?check_suite_focus=true#step:2:1" "72" \
  "printf 'ci\tx\tWORKFLOW RUN LOG\n'; exit 0" \
  "WORKFLOW RUN LOG"
redcheck "a legacy job fetch failure names the job" \
  "https://github.com/o/r/runs/6789126" "6789126" "exit 1" \
  "The log for job 6789126 could not be fetched" job
redcheck "an empty legacy job log names the job" \
  "https://github.com/o/r/runs/6789127" "6789127" "exit 0" \
  "Job 6789127 reported no failing step log" job
redcheck "a partial legacy job log retains the failure context" \
  "https://github.com/o/r/runs/6789128" "6789128" \
  "printf 'ci\tx\tLEGACY PARTIAL LOG\nci\tx\t\nci\tx\tAFTER BLANK\n'; echo 'job log unavailable' >&2; exit 1" \
  "this log is incomplete: gh exited 1 while fetching job 6789128" job \
  $'LEGACY PARTIAL LOG\n\nAFTER BLANK' "gh: job log unavailable"
# but digits followed by more id are not an id
redcheck "while digits with letters after them fail closed" \
  "https://github.com/o/r/runs/12ab" "12ab" \
  "printf 'ci\tbin/ci.sh\tSHOULD NOT APPEAR\n'; exit 0" \
  "No run id could be read out of"
# Some of it came back and gh still failed - a multi-job run with one
# job's log gone. A partial log printed alone reads as the whole of
# the failure, which is the same lie as a blank block wearing a green
# run's face.
redcheck "a partial log says it is partial" \
  "https://github.com/o/r/actions/runs/64/job/1" "64" \
  "printf 'ci\tx\tHALF THE LOG\n'; echo 'one job log is gone' >&2; exit 1" \
  "this log is incomplete"
redcheck "and still shows what did come back" \
  "https://github.com/o/r/actions/runs/64/job/1" "64" \
  "printf 'ci\tx\tHALF THE LOG\n'; echo 'one job log is gone' >&2; exit 1" \
  "HALF THE LOG"
redcheck "and passes on why the rest did not" \
  "https://github.com/o/r/actions/runs/64/job/1" "64" \
  "printf 'ci\tx\tHALF THE LOG\n'; echo 'one job log is gone' >&2; exit 1" \
  "gh: one job log is gone"
redcheck "a fetch that failed says so" \
  "https://github.com/o/r/actions/runs/61/job/1" "61" "exit 1" \
  "The log for run 61 could not be fetched"
redcheck "a fetch that succeeded with nothing says THAT, not that gh failed" \
  "https://github.com/o/r/actions/runs/62/job/1" "62" "exit 0" \
  "Run 62 reported no failing step log"
redcheck "and a log the column trim empties is the same case" \
  "https://github.com/o/r/actions/runs/63/job/1" "63" \
  "printf 'ci\tbin/ci.sh\t\nci\tbin/ci.sh\t   \n'; exit 0" \
  "Run 63 reported no failing step log"

# A blank line inside a real log is part of the log. The emptiness
# filter is for DECIDING; printing it deleted every separator in a
# traceback, and spent the 120-line budget on lines it then dropped.
d18="$(fixture)"; r18="$d18/repo"; GH18="$(ghstub "$d18")"
cat > "$r18/bin/adapters/mock.sh" <<'M'
#!/usr/bin/env bash
[ "$1" = "run" ] || exit 64
cp "$2" "${FM_CAPTURE:-/dev/null}" 2>/dev/null
mkdir -p "$3/src"
if [ -f "$3/src/round-one" ]; then printf 'two\n' > "$3/src/round-two"
else printf 'one\n' > "$3/src/round-one"; fi
M
chmod +x "$r18/bin/adapters/mock.sh"
( cd "$r18" && FM_ROOT="$r18" FM_GH="$GH18" bin/fm-worker.sh --task T-Z >/dev/null 2>&1 )
cat > "$d18/stub/gh" <<'G'
#!/usr/bin/env bash
case " $* " in
  *" pr list "*) echo 24; exit 0 ;;
  *" pr checks "*) echo "https://github.com/o/r/actions/runs/71/job/1"; exit 0 ;;
  " run view 71 --log-failed ") printf 'ci\tx\tTraceback ABOVE\nci\tx\t\nci\tx\tAssertionError BELOW\n'; exit 0 ;;
  *" run view "*) echo "could not find any workflow run" >&2; exit 1 ;;
  *" pr view "*" comments "*) printf '## r\n\nsomething\n' ;;
esac
exit 0
G
chmod +x "$d18/stub/gh"
check_strict_run_stub "$d18/stub/gh" 71
cap18="$d18/sent.md"
( cd "$r18" && FM_ROOT="$r18" FM_GH="$GH18" FM_CAPTURE="$cap18" \
    bin/fm-worker.sh --task T-Z >/dev/null 2>&1 )
sent18="$(cat "$cap18" 2>/dev/null)"
assert_contains "$sent18" "Traceback ABOVE" "the line above a blank one reaches the prompt"
assert_contains "$sent18" "AssertionError BELOW" "and the line below it"
assert_contains "$sent18" "Traceback ABOVE

AssertionError BELOW" "with the blank line still between them"
rm -rf "$d18"

# The failed-fetch branch with no scratch file to capture gh into: the
# `:-/dev/null` fallback has to hold, the run still has to be told the
# log could not be fetched, and there must be no `gh:` lines claiming
# to quote something nothing captured.
d19="$(fixture)"; r19="$d19/repo"; GH19="$(ghstub "$d19")"
cat > "$r19/bin/adapters/mock.sh" <<'M'
#!/usr/bin/env bash
[ "$1" = "run" ] || exit 64
cp "$2" "${FM_CAPTURE:-/dev/null}" 2>/dev/null
mkdir -p "$3/src"
if [ -f "$3/src/round-one" ]; then printf 'two\n' > "$3/src/round-two"
else printf 'one\n' > "$3/src/round-one"; fi
M
chmod +x "$r19/bin/adapters/mock.sh"
( cd "$r19" && FM_ROOT="$r19" FM_GH="$GH19" bin/fm-worker.sh --task T-Z >/dev/null 2>&1 )
cat > "$d19/stub/gh" <<'G'
#!/usr/bin/env bash
case " $* " in
  *" pr list "*) echo 25; exit 0 ;;
  *" pr checks "*) echo "https://github.com/o/r/actions/runs/81/job/1"; exit 0 ;;
  " run view 81 --log-failed ") echo "boom" >&2; exit 1 ;;
  *" run view "*) echo "could not find any workflow run" >&2; exit 1 ;;
  *" pr view "*" comments "*) printf '## r\n\nsomething\n' ;;
esac
exit 0
G
chmod +x "$d19/stub/gh"
check_strict_run_stub "$d19/stub/gh" 81
# Fail only the optional log capture. `--pr 25` skips lookup_err, so
# the first worker allocation is log_err; chain_result must still succeed
# before the adapter can capture the prompt. Keep state outside the shim's
# process because scratch_new runs in command substitutions.
mkdir -p "$d19/tmp"
real_mktemp19="$(command -v mktemp)"
cat > "$d19/stub/mktemp" <<'M'
#!/usr/bin/env bash
if [ "$#" -eq 1 ] && [ "$1" = "$TMPDIR/fm-worker-XXXXXX" ]; then
  if [ ! -e "$FM_MKTEMP_FAILED" ]; then
    : > "$FM_MKTEMP_FAILED"
    exit 1
  fi
fi
exec "$FM_REAL_MKTEMP" "$@"
M
chmod +x "$d19/stub/mktemp"
cap19="$d19/sent.md"
( cd "$r19" && PATH="$d19/stub:$PATH" TMPDIR="$d19/tmp" \
    FM_REAL_MKTEMP="$real_mktemp19" FM_MKTEMP_FAILED="$d19/mktemp-failed" \
    FM_ROOT="$r19" FM_GH="$GH19" FM_CAPTURE="$cap19" \
    bin/fm-worker.sh --task T-Z --pr 25 >/dev/null 2>&1 )
rc19=$?
assert_eq "0" "$rc19" "optional log allocation failure still completes the worker run"
assert_ok "test -f '$d19/mktemp-failed'" "the optional log allocation failure was exercised"
assert_ok "test -s '$cap19'" "the adapter ran and captured the prompt after allocation failure"
sent19="$(cat "$cap19" 2>/dev/null)"
assert_contains "$sent19" "The log for run 81 could not be fetched" \
  "with no scratch file, the failed fetch is still reported"
assert_lacks "$sent19" "gh: " "and nothing is quoted that nothing captured"
assert_lacks "$sent19" "No such file or directory" \
  "and the redirection did not fall over on an empty path"
rm -rf "$d19"

# gh's stderr is bounded like the log above it: everything that reaches
# that fence has to be, and a runner that dies noisily can say a great
# deal on stderr
d20="$(fixture)"; r20="$d20/repo"; GH20="$(ghstub "$d20")"
cp "$r19/bin/adapters/mock.sh" "$r20/bin/adapters/mock.sh" 2>/dev/null || true
cat > "$r20/bin/adapters/mock.sh" <<'M'
#!/usr/bin/env bash
[ "$1" = "run" ] || exit 64
cp "$2" "${FM_CAPTURE:-/dev/null}" 2>/dev/null
mkdir -p "$3/src"
if [ -f "$3/src/round-one" ]; then printf 'two\n' > "$3/src/round-two"
else printf 'one\n' > "$3/src/round-one"; fi
M
chmod +x "$r20/bin/adapters/mock.sh"
( cd "$r20" && FM_ROOT="$r20" FM_GH="$GH20" bin/fm-worker.sh --task T-Z >/dev/null 2>&1 )
cat > "$d20/stub/gh" <<'G'
#!/usr/bin/env bash
case " $* " in
  *" pr list "*) echo 26; exit 0 ;;
  *" pr checks "*) echo "https://github.com/o/r/actions/runs/91/job/1"; exit 0 ;;
  " run view 91 --log-failed ") i=0; while [ "$i" -lt 200 ]; do echo "noise $i" >&2; i=$((i+1)); done; exit 1 ;;
  *" run view "*) echo "could not find any workflow run" >&2; exit 1 ;;
  *" pr view "*" comments "*) printf '## r\n\nsomething\n' ;;
esac
exit 0
G
chmod +x "$d20/stub/gh"
check_strict_run_stub "$d20/stub/gh" 91
cap20="$d20/sent.md"
( cd "$r20" && FM_ROOT="$r20" FM_GH="$GH20" FM_CAPTURE="$cap20" \
    bin/fm-worker.sh --task T-Z >/dev/null 2>&1 )
lines20="$(grep -c '^gh: noise' "$cap20" 2>/dev/null || true)"
assert_contains "$(cat "$cap20")" "gh: noise 0" "gh's first words reach the prompt"
assert_ok "[ '$lines20' -le 20 ]" "and 200 lines of them do not: the splice is bounded"
rm -rf "$d20"

# and if it cannot be kept either, the run says so rather than pointing
# at a path inside the worktree as though it were safe - which is what
# the fallback this replaces did
d11="$(fixture)"; r11="$d11/repo"; GH11="$(ghstub "$d11")"
cat > "$r11/bin/adapters/mock.sh" <<'M'
#!/usr/bin/env bash
[ "$1" = "run" ] || exit 64
printf 'ASK-PASS-CRITERIA:T-Z\n' > "$3/.fm-say.md"
M
chmod +x "$r11/bin/adapters/mock.sh"
cat > "$d11/stub/gh" <<'G'
#!/usr/bin/env bash
case " $* " in *" pr comment "*) exit 1 ;; esac
exit 0
G
chmod +x "$d11/stub/gh"
# a directory mode is advisory for root, so the test would silently
# invert under a root runner: it makes the destination a FILE instead,
# which no uid can cp into as if it were a directory
mkdir -p "$r11/state"; : > "$r11/state/unsent"
out12="$(cd "$r11" && FM_ROOT="$r11" FM_GH="$GH11" bin/fm-worker.sh --task T-Z --pr 9 2>&1)"; rc12=$?
rm -f "$r11/state/unsent"
assert_eq "73" "$rc12" "a question that can be neither posted nor kept still fails the run"
assert_contains "$out12" "could not be kept either" "and says the keeping failed too"
assert_lacks "$out12" "it is at state/unsent" "rather than naming a file it did not write"
# Every path that makes a scratch file, in a TMPDIR the test owns.
# Counting what is in the machine's $TMPDIR before and after scored
# every other process against the worker - and would have passed on a
# leak if anything else removed a file in the same window.
# By NAME. An owned TMPDIR settles whose machine, not whose file: git,
# the stub and the adapter all run under it too, and any of them would
# fail this as a worker leak. `scratch_new`'s template exists so a file
# left behind says who left it - so the check reads the name.
leak_check() {   # leak_check <label> <tmpdir> ; the run has already happened
  local left; left="$(find "$2" -name 'fm-worker-*' -type f 2>/dev/null | wc -l | tr -d ' ')"
  assert_eq "0" "$left" "$1"
}

# the exit-73 route, which makes say_err
d14="$(fixture)"; r14="$d14/repo"; GH14="$(ghstub "$d14")"
cat > "$r14/bin/adapters/mock.sh" <<'M'
#!/usr/bin/env bash
[ "$1" = "run" ] || exit 64
printf 'ASK-PASS-CRITERIA:T-Z\n' > "$3/.fm-say.md"
M
chmod +x "$r14/bin/adapters/mock.sh"
cat > "$d14/stub/gh" <<'G'
#!/usr/bin/env bash
case " $* " in *" pr comment "*) echo "refused" >&2; exit 1 ;; esac
exit 0
G
chmod +x "$d14/stub/gh"
mkdir -p "$d14/tmp"
out16="$(cd "$r14" && TMPDIR="$d14/tmp" FM_ROOT="$r14" FM_GH="$GH14" \
    bin/fm-worker.sh --task T-Z --pr 9 2>&1)"; rc16=$?
# The control. "No file left" is also what a run that never made one
# looks like, and say_err has a path where it is not made at all -
# `scratch_new` failing leaves it empty and the run carries on. The
# replayed `gh:` line is printed only from a non-empty $say_err, so it
# is proof the file existed to be cleaned up.
assert_eq "73" "$rc16" "the run took the path that makes say_err"
assert_contains "$out16" "fm-worker: gh: refused" \
  "and it captured what gh said, which it can only do into a file it made"
leak_check "a run that exits 73 leaves no scratch file behind" "$d14/tmp"
rm -rf "$d14"

# the exit-74 route, which makes lookup_err - a different file on a
# different path, and the comment says every one of them
d15="$(fixture)"; r15="$d15/repo"; GH15="$(ghstub "$d15")"
cat > "$r15/bin/adapters/mock.sh" <<'M'
#!/usr/bin/env bash
[ "$1" = "run" ] || exit 64
mkdir -p "$3/src"; printf '%s\n' "$RANDOM$$" > "$3/src/work"
M
chmod +x "$r15/bin/adapters/mock.sh"
( cd "$r15" && FM_ROOT="$r15" FM_GH="$GH15" bin/fm-worker.sh --task T-Z >/dev/null 2>&1 )
printf '#!/usr/bin/env bash\nexit 1\n' > "$d15/stub/gh"; chmod +x "$d15/stub/gh"
mkdir -p "$d15/tmp"
( cd "$r15" && TMPDIR="$d15/tmp" FM_ROOT="$r15" FM_GH="$GH15" \
    bin/fm-worker.sh --task T-Z >/dev/null 2>&1 )
assert_eq "74" "$?" "the lookup failed, as this fixture intends"
leak_check "and a run that exits 74 leaves none either" "$d15/tmp"

# and the half the comment names by name: a signal. The scratch file is
# made at the lookup and is still there while the engine runs, so a run
# killed mid-engine is the case where "removed at the end" and "removed
# on the way out" differ.
cat > "$r15/bin/adapters/mock.sh" <<'M'
#!/usr/bin/env bash
[ "$1" = "run" ] || exit 64
: > "${FM_STARTED:?}"
exec 8<> "${FM_RELEASE:?}"
read -r -t 12 -u 8 || exit 124
M
chmod +x "$r15/bin/adapters/mock.sh"
cat > "$d15/stub/gh" <<'G'
#!/usr/bin/env bash
case " $* " in *" pr list "*) echo 9; exit 0 ;; esac
exit 0
G
chmod +x "$d15/stub/gh"
rm -rf "$d15/tmp"; mkdir -p "$d15/tmp"
started15="$d15/started"
mkfifo "$d15/release"
exec 8<> "$d15/release"
( cd "$r15" && TMPDIR="$d15/tmp" FM_ROOT="$r15" FM_GH="$GH15" FM_STARTED="$started15" FM_RELEASE="$d15/release" \
    exec bin/fm-worker.sh --task T-Z >/dev/null 2>&1 ) &
kp15=$!
for _ in $(seq 1 60); do [ -e "$started15" ] && break; sleep 0.2; done
assert_ok "test -e '$started15'" "the engine was running, so the scratch file is open"
kill -TERM "$kp15" 2>/dev/null
printf "release\n" >&8
wait "$kp15" 2>/dev/null
assert_eq 143 "$?" "scratch cleanup run exits on TERM after adapter release"
exec 8>&-
leak_check "and a run cut short by a signal leaves none" "$d15/tmp"
rm -rf "$d15"

rm -rf "$d11"

# round_two is decided from the local branch OR origin's, so a wiped
# state/ or a second machine is still a later round - which is what
# gates the lookup, and therefore whether a branch that already has a
# pull request reaches `pr create`. The comment the old post-push
# lookup carried said that was the failure it existed to prevent, so
# the replacement has to be shown to cover it.
d12="$(fixture)"; r12="$d12/repo"; GH12="$(ghstub "$d12")"
cat > "$r12/bin/adapters/mock.sh" <<'M'
#!/usr/bin/env bash
[ "$1" = "run" ] || exit 64
mkdir -p "$3/src"
if [ -f "$3/src/round-one" ]; then printf 'two\n' > "$3/src/round-two"
else printf 'one\n' > "$3/src/round-one"; fi
M
chmod +x "$r12/bin/adapters/mock.sh"
( cd "$r12" && FM_ROOT="$r12" FM_GH="$GH12" bin/fm-worker.sh --task T-Z >/dev/null 2>&1 )
b12="$(cd "$r12" && git for-each-ref --format='%(refname:short)' refs/heads | grep -v '^main$' | head -1)"
assert_ok "git -C '$r12' cat-file -e '$b12:src/round-one'" "the first round pushed a branch"
# the local trace is gone: the worktree, the branch, the whole of state/
( cd "$r12" && git worktree remove --force "state/worktrees/T-Z" >/dev/null 2>&1; true )
( cd "$r12" && git branch -D "$b12" >/dev/null 2>&1 )
assert_fail "git -C '$r12' show-ref --verify --quiet 'refs/heads/$b12'" \
  "and nothing local remembers it"
assert_ok "git -C '$r12' ls-remote --exit-code --heads origin '$b12'" "but origin does"
cat > "$d12/stub/gh" <<'G'
#!/usr/bin/env bash
echo "gh $*" >> "$(dirname "$0")/../ghcalls"
case " $* " in
  *" pr list "*) echo 55; exit 0 ;;
  *" pr checks "*) exit 0 ;;
  *" pr view "*" comments "*) printf '## reviewer-1\n\nnothing to add\n' ;;
esac
exit 0
G
chmod +x "$d12/stub/gh"; : > "$d12/ghcalls"
out13="$(cd "$r12" && FM_ROOT="$r12" FM_GH="$GH12" bin/fm-worker.sh --task T-Z 2>&1)"
assert_contains "$out13" "already has #55" "a branch only origin remembers is still a later round"
assert_contains "$(jq -r 'select(.type=="commit_pushed")|.pr|tostring' \
  < "$r12/state/events.jsonl" | tail -1)" "55" "and its push points at the one that is there"
assert_eq "1" "$(grep -c 'pr list' "$d12/ghcalls" || true)" \
  "having asked once, not once at each site that wants the number"
rm -rf "$d12"

# T-037: branch_guess already finds the existing branch for this task; the
# bug was that fm-worker.sh threw that away and recomputed a branch name
# from the CURRENT title on every round anyway. A title is mutable and the
# slug is cut to 28 characters, so a branch made under an older, untruncated
# scheme - or simply named while the title read differently - no longer
# matches a fresh recompute. The old code then fell to the `else` and made
# a SECOND branch from base, stranding the first one's commits and PR.
# Fail-first: this reproduces without a live captain decision, model or
# network API - the fixture's mock adapter and gh stub are all it drives.
d21="$(fixture)"; r21="$d21/repo"; GH21="$(ghstub "$d21")"
long_title='a mock task with a title long enough that slugging it truncates to twenty eight characters'
jq --arg t "$long_title" '.title=$t' "$r21/design/tasks/T-Z.json" > "$r21/design/T-Z.next"
mv "$r21/design/T-Z.next" "$r21/design/tasks/T-Z.json"
( cd "$r21" && git add -A && git commit -qm retitle && git push -q origin main )
cat > "$r21/bin/adapters/mock.sh" <<'M'
#!/usr/bin/env bash
[ "$1" = "run" ] || exit 64
mkdir -p "$3/src"
if [ -f "$3/src/round-one" ]; then printf 'two\n' > "$3/src/round-two"
else printf 'one\n' > "$3/src/round-one"; fi
M
chmod +x "$r21/bin/adapters/mock.sh"
( cd "$r21" && FM_ROOT="$r21" FM_GH="$GH21" bin/fm-worker.sh --task T-Z >/dev/null 2>&1 )
trunc_branch="$(cd "$r21" && git for-each-ref --format='%(refname:short)' refs/heads | grep -v '^main$' | head -1)"
assert_ne "" "$trunc_branch" "the first round made a branch"
assert_ok "cd '$r21' && git cat-file -e '$trunc_branch:src/round-one'" "and committed its work"

# renamed the way a pre-truncation scheme (or an earlier title) would have
# left it: the whole slug, not cut to 28 characters, so a fresh recompute
# from the CURRENT title no longer names it
full_slug="t-z-$(printf '%s' "$long_title" | tr 'A-Z' 'a-z' | tr -cs 'a-z0-9' '-' | sed 's/-*$//')"
assert_ne "$trunc_branch" "$full_slug" "the fixture's title is long enough that truncation actually changes it"
# the round-one worktree still has trunc_branch checked out; a rename has to
# clear that first, same as the origin-only fixture below does
( cd "$r21" && git worktree remove --force "state/worktrees/T-Z" >/dev/null 2>&1; true )
( cd "$r21" && git branch -m "$trunc_branch" "$full_slug" \
    && git push -q origin ":$trunc_branch" "$full_slug" )

: > "$d21/ghcalls"
( cd "$r21" && FM_ROOT="$r21" FM_GH="$GH21" bin/fm-worker.sh --task T-Z >/dev/null 2>&1 )
branches_after="$(cd "$r21" && git for-each-ref --format='%(refname:short)' refs/heads | grep -v '^main$')"
assert_eq "1" "$(printf '%s\n' "$branches_after" | grep -c .)" \
  "a title-mismatched local branch is reused, never doubled"
assert_eq "$full_slug" "$branches_after" "and it is the branch the first round pushed, not a new one from base"
assert_ok "cd '$r21' && git cat-file -e '$full_slug:src/round-one'" "the second round keeps the first round's work"
assert_ok "cd '$r21' && git cat-file -e '$full_slug:src/round-two'" "and adds its own on the same branch"
assert_contains "$(cat "$d21/ghcalls")" "pr list --head $full_slug" \
  "it looked up the pull request for the reused branch, treating this as a later round"
rm -rf "$d21"

# The same mismatch again, but nothing local remembers the branch at all -
# a wiped state/ or a second machine, the way the origin-only case above is
# already covered for a branch whose name never changed. branch_guess has
# to search origin too, or the second-branch bug reappears the moment the
# local ref is gone as well as the name.
d22="$(fixture)"; r22="$d22/repo"; GH22="$(ghstub "$d22")"
long_title='a mock task whose title is long enough that a fresh slug truncates differently'
jq --arg t "$long_title" '.title=$t' "$r22/design/tasks/T-Z.json" > "$r22/design/T-Z.next"
mv "$r22/design/T-Z.next" "$r22/design/tasks/T-Z.json"
( cd "$r22" && git add -A && git commit -qm retitle && git push -q origin main )
cat > "$r22/bin/adapters/mock.sh" <<'M'
#!/usr/bin/env bash
[ "$1" = "run" ] || exit 64
mkdir -p "$3/src"
if [ -f "$3/src/round-one" ]; then printf 'two\n' > "$3/src/round-two"
else printf 'one\n' > "$3/src/round-one"; fi
M
chmod +x "$r22/bin/adapters/mock.sh"
( cd "$r22" && FM_ROOT="$r22" FM_GH="$GH22" bin/fm-worker.sh --task T-Z >/dev/null 2>&1 )
trunc_branch="$(cd "$r22" && git for-each-ref --format='%(refname:short)' refs/heads | grep -v '^main$' | head -1)"
assert_ne "" "$trunc_branch" "the first round made a branch"

full_slug="t-z-$(printf '%s' "$long_title" | tr 'A-Z' 'a-z' | tr -cs 'a-z0-9' '-' | sed 's/-*$//')"
assert_ne "$trunc_branch" "$full_slug" "the fixture's title is long enough that truncation actually changes it"
( cd "$r22" && git worktree remove --force "state/worktrees/T-Z" >/dev/null 2>&1; true )
( cd "$r22" && git branch -m "$trunc_branch" "$full_slug" \
    && git push -q origin ":$trunc_branch" "$full_slug" )
( cd "$r22" && git branch -D "$full_slug" >/dev/null 2>&1 )
assert_fail "cd '$r22' && git show-ref --verify --quiet 'refs/heads/$full_slug'" \
  "nothing local remembers the renamed branch"
assert_ok "cd '$r22' && git ls-remote --exit-code --heads origin '$full_slug'" "but origin does"

( cd "$r22" && FM_ROOT="$r22" FM_GH="$GH22" bin/fm-worker.sh --task T-Z >/dev/null 2>&1 )
branches_after="$(cd "$r22" && git for-each-ref --format='%(refname:short)' refs/heads | grep -v '^main$')"
assert_eq "1" "$(printf '%s\n' "$branches_after" | grep -c .)" \
  "a remote-only, title-mismatched branch is reused, never doubled"
assert_eq "$full_slug" "$branches_after" "and it is the branch origin remembered, not a new one from base"
assert_ok "cd '$r22' && git cat-file -e '$full_slug:src/round-one'" "the second round keeps the first round's work"
assert_ok "cd '$r22' && git cat-file -e '$full_slug:src/round-two'" "and adds its own on the same branch"
rm -rf "$d22"

# And the untouched case: a task with genuinely no existing branch still
# gets a fresh one derived from the title, exactly as before this fix.
d23="$(fixture T-Y)"; r23="$d23/repo"; GH23="$(ghstub "$d23")"
out23="$(cd "$r23" && FM_ROOT="$r23" FM_GH="$GH23" bin/fm-worker.sh --task T-Y 2>&1)"
branch23="$(printf '%s' "$out23" | tail -1)"
assert_contains "$branch23" "t-y" "a task with no existing branch still names one from its id"
assert_ok "cd '$r23' && git show-ref --verify --quiet 'refs/heads/$branch23'" "and creates it fresh from base"
assert_eq "1" "$(cd "$r23" && git rev-list --count "main..$branch23")" "with exactly the one commit from this round"
rm -rf "$d23"

# A run that was interrupted leaves its files uncommitted in the worktree,
# and the next dispatch used to delete them before anything could see
# them. Tonight that nearly cost two finished tasks.
d7="$(fixture)"; r7="$d7/repo"; GH7="$(ghstub "$d7")"
cat > "$r7/bin/adapters/mock.sh" <<'M'
#!/usr/bin/env bash
[ "$1" = "run" ] || exit 64
mkdir -p "$3/src"; printf 'work\n' > "$3/src/thing"
M
chmod +x "$r7/bin/adapters/mock.sh"
( cd "$r7" && FM_ROOT="$r7" FM_GH="$GH7" bin/fm-worker.sh --task T-Z >/dev/null 2>&1 )
# leave something uncommitted behind, the way an interrupted run does
printf 'half finished\n' > "$r7/state/worktrees/T-Z/src/unsaved"
out7="$(cd "$r7" && FM_ROOT="$r7" FM_GH="$GH7" bin/fm-worker.sh --task T-Z 2>&1)"
assert_contains "$out7" "uncommitted work" "an interrupted run's files are noticed"
rescued="$(find "$r7/state/rescued" -name unsaved 2>/dev/null | head -1)"
assert_ne "" "$rescued" "and copied somewhere before the worktree is remade"
assert_contains "$(cat "$rescued" 2>/dev/null)" "half finished" "with what was in them"
assert_contains "$(jq -r .type < "$r7/state/events.jsonl" | tr '\n' ' ')" "worker_crashed" \
  "and the log says it happened"
rm -rf "$d7"

# A run says when it ends, on every exit path - including the ones that
# give up. Without it the board cannot tell a worker that is running from
# one that died at a gate, and draws both.
for scenario in clean failed; do
  da="$(fixture)"; ra="$da/repo"; GHa="$(ghstub "$da")"
  if [ "$scenario" = failed ]; then
    cat > "$ra/bin/adapters/mock.sh" <<'M'
#!/usr/bin/env bash
[ "$1" = "run" ] || exit 64
exit 1
M
    chmod +x "$ra/bin/adapters/mock.sh"
  fi
  ( cd "$ra" && FM_ROOT="$ra" FM_GH="$GHa" bin/fm-worker.sh --task T-Z >/dev/null 2>&1 )
  assert_contains "$(jq -r .type < "$ra/state/events.jsonl" | tr '\n' ' ')" "agent_finished" \
    "a $scenario run says when it ended"
  assert_eq "agent_finished" "$(jq -r .type < "$ra/state/events.jsonl" | tail -1)" \
    "and it is the last thing it says"
  assert_eq "1" "$(jq -r 'select(.type=="agent_finished")|.type' "$ra/state/events.jsonl" | grep -c . || true)" \
    "exactly once, not once per exit path"
  rm -rf "$da"
done

# A killed run is exactly "one that gives up", and the server's backstop
# does not save it - the task is still open, so the dead agent would sit
# aboard for ever and inflate the rate.
#
# Measured, so the claim is not bigger than the evidence: this assertion
# holds with `trap ... EXIT` alone, because bash defers a TERM that
# arrives while it is waiting for a child and then runs the EXIT trap.
# INT/TERM/HUP are listed anyway, for the paths and the shells where
# that is not true; what this test proves is the behaviour the criterion
# names, not the flag list.
# The adapter waits for release and THEN does the work, so the two runs differ. A
# stub that only sleeps writes nothing into the worktree, an untouched
# run therefore produces no diff and never reaches `pr create` either -
# and every assertion below would have held with the kill deleted. The
# control run at the end is what makes the killed one mean something.
killable_adapter() {   # killable_adapter <repo>
  cat > "$1/bin/adapters/mock.sh" <<'M'
#!/usr/bin/env bash
[ "$1" = "run" ] || exit 64
# says it has STARTED, so the killer waits for the engine to be running
# rather than for the script's first event - which is a different moment
# and, on a fast machine, can be after the run is already over
: > "${FM_STARTED:?}"
exec 8<> "${FM_RELEASE:?}"
read -r -t 12 -u 8 || exit 124
mkdir -p "$3/src"
printf 'the work was done\n' > "$3/src/thing"
M
  chmod +x "$1/bin/adapters/mock.sh"
}

dk="$(fixture)"; rk="$dk/repo"; GHk="$(ghstub "$dk")"
killable_adapter "$rk"
# `exec`, so the pid is the SCRIPT and not the subshell around it.
# Without it `$!` is the wrapper, and whether the signal ever reaches
# fm-worker.sh depends on whether this bash elides the last fork - which
# bash 5 does and the 3.2 on this platform does not. On the shell that
# does not, the wrapper dies, the worker is orphaned, runs to its
# natural end, and `kill -0 "$killme"` is false anyway because the
# wrapper was reaped: green, on a run nothing interrupted.
started="$dk/started"
# Keep both FIFO ends open: a failed readiness check cannot hang the writer.
# The adapter has a 12-second safety deadline, not a fixed work duration.
mkfifo "$dk/release"
exec 8<> "$dk/release"
( cd "$rk" && FM_ROOT="$rk" FM_GH="$GHk" FM_STARTED="$started" FM_RELEASE="$dk/release" \
    exec bin/fm-worker.sh --task T-Z >/dev/null 2>&1 ) &
killme=$!
for _ in $(seq 1 60); do
  [ -e "$started" ] && break
  sleep 0.2
done
assert_ok "test -e '$started'" "the engine was running when the signal was sent"
# by pid, not by pattern: pkill -f matches every process on the machine,
# so two suites running at once reap each other's stubs and each sees an
# ending its assertions attribute to the trap
kill -TERM "$killme" 2>/dev/null
printf "release\n" >&8
wait "$killme" 2>/dev/null; krc=$?
exec 8>&-
# wait reaps the actual worker after its synchronous EXIT emitter finishes;
# no event poll is needed after this exit barrier.
# The position of a line in a log is not the behaviour. What matters is
# that the run STOPPED - exactly one ending, and nothing after it - and
# the first version of this asserted `tail -1` alone, which held whether
# the run stopped or carried on to open a pull request.
ends="$(jq -r 'select(.type=="agent_finished")|.type' "$rk/state/events.jsonl" | grep -c . || true)"
assert_eq "1" "$ends" "a run killed mid-flight ends exactly once"
after="$(jq -r .type "$rk/state/events.jsonl" | sed -n '/agent_finished/,$p' | tail -n +2)"
assert_eq "" "$after" "and says nothing after it"
assert_lacks "$(cat "$dk/ghcalls" 2>/dev/null)" "pr create" \
  "a killed run does not go on to open a pull request"
assert_eq "143" "$krc" "and it exits on the signal - 128+TERM, from the signal trap"
assert_fail "kill -0 '$killme' 2>/dev/null" "and the process is gone"
# and the discrimination, stated: the adapter DID write its file - bash
# defers a TERM that arrives while it is waiting for a child, so the
# release arrives and the work lands - and the run still never reached
# `pr create`. Work present, pull request absent, is something only an
# interrupted run produces.
assert_ok "test -f '$rk/state/worktrees/T-Z/src/thing'" \
  "the adapter had finished its work, so a run left alone would have gone on"
# EXIT must publish that dirty work: finishing without a happy-path commit
# used to leave the PR empty even though the worktree had real changes.
branchk="$(cd "$rk" && git for-each-ref --format='%(refname:short)' refs/heads | grep '^t-z-' | head -1)"
assert_ne "" "$branchk" "interrupted run still created its feature branch"
assert_ok "git -C '$rk/state/worktrees/T-Z' cat-file -e HEAD:src/thing" \
  "EXIT committed dirty work into the feature branch HEAD"
assert_eq "$(git -C "$rk/state/worktrees/T-Z" rev-parse HEAD)" \
  "$(git -C "$rk/state/worktrees/T-Z" rev-parse "origin/$branchk")" \
  "EXIT publishes dirty worktree when the happy-path commit never runs"
assert_ok "git -C '$rk/state/worktrees/T-Z' cat-file -e origin/$branchk:src/thing" \
  "origin tip after EXIT contains the adapter's file"
assert_contains "$(jq -r .type < "$rk/state/events.jsonl" | tr '\n' ' ')" "commit_pushed" \
  "EXIT checkpoint emits commit_pushed"
rm -rf "$dk"

# the same fixture, left alone: this is what the four assertions above
# are the absence of, and without it they are satisfied by a run that
# was never interrupted
dl="$(fixture)"; rl="$dl/repo"; GHl="$(ghstub "$dl")"
killable_adapter "$rl"
mkfifo "$dl/release"
exec 8<> "$dl/release"
printf "release\n" >&8
( cd "$rl" && FM_ROOT="$rl" FM_GH="$GHl" FM_STARTED="$dl/started" FM_RELEASE="$dl/release" \
    bin/fm-worker.sh --task T-Z >/dev/null 2>&1 )
assert_eq "0" "$?" "the same run, not killed, exits 0"
exec 8>&-
assert_contains "$(cat "$dl/ghcalls" 2>/dev/null)" "pr create" \
  "the same run, not killed, does reach a pull request"
assert_eq "1" "$(jq -r 'select(.type=="agent_finished")|.type' "$rl/state/events.jsonl" | grep -c . || true)" \
  "and ends exactly once as well"
rm -rf "$dl"

# a vendor named in config.yaml with no adapter behind it is a typo. It has
# to be found before anything runs, or a real vendor does the work and the
# exit 65 throws it away with the worktree.
d4="$(fixture)"; r4="$d4/repo"; GH4="$(ghstub "$d4")"
printf 'vendor: nosuchvendor\nfallback:\n  - mock\n' > "$r4/config.yaml"
out4="$(cd "$r4" && FM_ROOT="$r4" FM_GH="$GH4" bin/fm-worker.sh --task T-Z 2>&1)"
assert_eq "65" "$?" "a vendor with no adapter is a configuration error, not an outage"
assert_contains "$out4" "nosuchvendor" "and the worker names it"
assert_eq "" "$(cat "$d4/ghcalls" 2>/dev/null)" "nothing was pushed"
assert_fail "test -s '$r4/state/worktrees/T-Z.log'" "and no vendor was run at all"
rm -rf "$d4"

# an outage is a judgement about text, and a judgement can be wrong. The
# adapter here reports one having written the work anyway. If the
# worktree has changes, something did the work and it must not be thrown
# away on the strength of a signature match.
d3="$(fixture)"; r3="$d3/repo"; GH3="$(ghstub "$d3")"
cat > "$r3/bin/adapters/mock.sh" <<'M'
#!/usr/bin/env bash
[ "$1" = "run" ] || exit 64
mkdir -p "$3/src"
printf 'the work was done\n' > "$3/src/thing"
printf 'Error: rate limit reached\n' >> "$4"
exit 2
M
chmod +x "$r3/bin/adapters/mock.sh"
out3="$(cd "$r3" && FM_ROOT="$r3" FM_GH="$GH3" bin/fm-worker.sh --task T-Z 2>&1)"
rc3=$?
assert_ne "2" "$rc3" "work in the worktree is never discarded as an outage"
assert_contains "$out3" "keeping them" "and the worker says why it kept it"
assert_contains "$(cat "$d3/ghcalls" 2>/dev/null)" "pr create" "the work reaches a pull request"
rm -rf "$d3"

# an adapter that ran and failed still goes to the gates: commit, push, pull request
d3="$(fixture)"; r3="$d3/repo"; GH3="$(ghstub "$d3")"
( cd "$r3" && FM_ROOT="$r3" FM_GH="$GH3" FM_MOCK_EXIT=1 bin/fm-worker.sh --task T-Z >/dev/null 2>&1 )
assert_eq "1" "$?" "a failed attempt exits 1"
assert_contains "$(cat "$d3/ghcalls")" "pr create" "a failed attempt still opens a pull request"

# The ending is the one emit that is not best-effort. Every other line
# the worker writes to the log is decoration the board can miss; this
# one is what takes the crewman off the deck, and a lost one leaves the
# agent standing there until the task merges - which is the failure the
# `agent_finished` pair exists to remove. So when it cannot be written
# the run says so on stderr instead of ending quietly.
d4="$(fixture)"; r4="$d4/repo"; GH4="$(ghstub "$d4")"
printf '#!/usr/bin/env bash\nexit 1\n' > "$r4/bin/fm-emit.sh"; chmod +x "$r4/bin/fm-emit.sh"
out4="$(cd "$r4" && FM_ROOT="$r4" FM_GH="$GH4" bin/fm-worker.sh --task T-Z --name worker-mute 2>&1)"
assert_contains "$out4" "could not record the end of this run" \
  "a run whose ending cannot be written says so rather than ending in silence"
assert_contains "$out4" "worker-mute" "and names the crewman left on the deck"
# and the ordinary lines stay best-effort: the run still did its work
assert_ok "git -C '$r4' rev-parse --verify t-z-a-mock-task" \
  "a log it cannot write to does not stop the run"
rm -rf "$d4"

# §5.3.2 lists the codes a worker can exit with, and a list in prose
# rots the first time one moves. Every `exit N` in the script has to be
# named there, and every code named there has to be in the script -
# identity, not a count, so adding one correctly is not a failure and
# losing one is.
# Strings first, THEN the comment. `^[^#]*exit N` means "no # anywhere
# to the left", and every message in this script names a pull request
# with one - so `{ echo "fm-worker: #$PR refused" >&2; exit 75; }`, the
# most idiomatic line in the file, would never enter the list and the
# identity would pass without 75 being documented anywhere.
# and the signal traps separately, because their code IS inside the
# quotes the first pass removes - `trap 'exit 143' TERM` is as much an
# exit code as any other, and the first version of this check found it
# only by accident of where the quotes fell
codes="$( { sed -e "s/'[^']*'//g" -e 's/"[^"]*"//g' -e 's/#.*$//' "$ROOT/bin/fm-worker.sh" \
              | grep -oE '\bexit [0-9]+'
            grep -oE "^[[:space:]]*trap[[:space:]]+'exit [0-9]+'" "$ROOT/bin/fm-worker.sh" \
              | grep -oE 'exit [0-9]+'
          } | awk '{print $2}' | sort -un | grep -v '^0$' || true)"
assert_ne "" "$codes" "the worker has exit codes to check"
# the section and NOT the heading that ends it: sed's range includes
# its terminating line, so `### 5.4 ...` was inside the text being
# scanned for a number in backticks
listed="$(awk '/^### 5\.3\.2/ {inside=1; next} /^#{1,6} / {inside=0} inside' \
          "$ROOT/design/design.md" | grep -oE '`[0-9]+`' | tr -d '`' | sort -un)"
assert_eq "$codes" "$listed" "design.md §5.3.2 names exactly the codes fm-worker exits with"

# the adapter never touches the repository
# a comment may mention git; a call may not
assert_fail "grep -vE '^[[:space:]]*#' '$ROOT/bin/adapters/mock.sh' | grep -qE '\\b(git|gh)\\b'" \
  "the mock adapter calls no git and no gh"
rm -rf "$d" "$d2" "$d3"
fi

# Real ordinary-worker evidence must be consumable by recovery. No emitter
# protocol is invented here; only GitHub and the adapter are controlled.
di="$(fixture T-999)"; ri="$di/repo"
cp "$ROOT/bin/fm-reconcile.sh" "$ri/bin/"
mkdir -p "$di/stub"
cat > "$di/stub/gh" <<'SH'
#!/usr/bin/env bash
case " $* " in
  *" --json number,state,title,headRefName "*) echo '[]';;
  *" pr list "*) echo 42;;
esac
SH
chmod +x "$di/stub/gh"
cat > "$ri/bin/adapters/mock.sh" <<'SH'
#!/usr/bin/env bash
echo started >> "$FM_ROOT/starts"
while [ ! -e "$FM_ROOT/release" ]; do sleep 0.1; done
mkdir -p "$3/src"
printf 'completed\n' > "$3/src/recovered"
SH
chmod +x "$ri/bin/adapters/mock.sh"
FM_WORKER_LOCK_PID="$$" FM_ROOT="$ri" FM_GH="$di/stub/gh" "$ri/bin/fm-worker.sh" --task T-999 --pr 42 >"$di/worker.out" 2>&1 &
ordinary=$!
for _ in $(seq 1 100); do [ -s "$ri/starts" ] && break; sleep 0.1; done
assert_ok "test -s '$ri/starts'" "ordinary worker reached its adapter"
assert_ok "jq -se 'any(.[]; .type==\"dispatched\" and (.data.recovery // false)==false)' '$ri/state/events.jsonl'" "ancestor lock environment does not turn an ordinary attempt into recovery"
assert_eq "$ordinary" "$(cat "$ri/state/worktrees/T-999.pid" 2>/dev/null)" "ordinary worker publishes its actual PID"
FM_ROOT="$ri" FM_GH="$di/stub/gh" "$ri/bin/fm-worker.sh" --task T-999 --pr 42 >"$di/duplicate.out" 2>&1
assert_eq 70 "$?" "an overlapping ordinary launch refuses the held lock"
assert_eq "$ordinary" "$(cat "$ri/state/worktrees/T-999.pid" 2>/dev/null)" "a refused duplicate preserves the owner's PID"
FM_ROOT="$ri" FM_GH="$di/stub/gh" "$ri/bin/fm-reconcile.sh" >"$di/live.out" 2>&1
assert_eq 0 "$?" "reconcile accepts live ordinary-worker evidence"
assert_lacks "$(cat "$di/live.out")" "redispatch T-999" "live ordinary worker is not duplicated"
kill -KILL "$ordinary" 2>/dev/null
wait "$ordinary" 2>/dev/null
FM_ROOT="$ri" FM_GH="$di/stub/gh" "$ri/bin/fm-reconcile.sh" >"$di/dead.out" 2>&1
recovery_rc=$?
assert_eq 0 "$recovery_rc" "reconcile revives a killed ordinary worker"
[ "$recovery_rc" = 0 ] || cat "$di/dead.out"
assert_contains "$(cat "$di/dead.out")" "redispatch T-999 on #42" "recovery passes the actual retry PR"
for _ in $(seq 1 100); do [ "$(wc -l < "$ri/starts" | tr -d ' ')" = 2 ] && break; sleep 0.1; done
assert_eq 2 "$(wc -l < "$ri/starts" | tr -d ' ')" "the real replacement reaches its adapter"
assert_ok "jq -se 'any(.[]; .type==\"worker_crashed\" and .pr==42)' '$ri/state/events.jsonl'" "ordinary crash retains its PR association"
assert_eq 42 "$(jq -r 'select(.type=="dispatched")|.pr' "$ri/state/events.jsonl" | tail -1)" "replacement dispatch retains the retry PR"
assert_ok "jq -se 'last(.[]|select(.type==\"dispatched\"))|.data.recovery==true and .data.role==\"worker\"' '$ri/state/events.jsonl'" "real associated replacement preserves recovery semantics"
FM_ROOT="$ri" FM_GH="$di/stub/gh" "$ri/bin/fm-reconcile.sh" >"$di/repeat.out" 2>&1
assert_lacks "$(cat "$di/repeat.out")" "redispatch T-999" "replacement evidence prevents another recovery"
: > "$ri/release"
for _ in $(seq 1 100); do [ ! -e "$ri/state/worktrees/T-999.pid" ] && break; sleep 0.1; done
assert_fail "test -e '$ri/state/worktrees/T-999.pid'" "a completed ordinary run removes its liveness claim"
assert_ok "jq -se 'any(.[]; .type==\"agent_finished\" and .actor!=\"reconcile\")' '$ri/state/events.jsonl'" "the real emitter records worker endings"
rm -rf "$di"

df="$(fixture T-998)"; rf="$df/repo"
mkdir -p "$rf/state/worktrees/T-998.pid.next"
FM_ROOT="$rf" "$rf/bin/fm-worker.sh" --task T-998 >"$df/out" 2>&1
assert_eq 70 "$?" "ordinary PID publication failure refuses to run"
assert_fail "test -d '$rf/state/worktrees/T-998'" "publication failure precedes worktree mutation"
assert_fail "test -e '$rf/state/worktrees/T-998.pid'" "failed publication leaves no false PID claim"
rm -rf "$df"

# --- T-036: mid-run checkpoint (commit then push; never main / never PR) ---
assert_ok "test -x '$ROOT/bin/fm-checkpoint.sh'" "fm-checkpoint.sh is the stock mid-run save helper"

dc="$(mktemp -d)"; barec="$dc/remote.git"; rc="$dc/repo"
cd "$ROOT" || exit 1
git init -q --bare "$barec"
git init -q -b main "$rc"
git -C "$rc" config user.email a@b.c; git -C "$rc" config user.name t
mkdir -p "$rc/bin" "$rc/design" "$rc/state/worktrees"
cp "$ROOT/bin/fm-checkpoint.sh" "$ROOT/bin/fm-guard.sh" "$ROOT/bin/fm-config.sh" \
   "$ROOT/bin/fm-emit.sh" "$rc/bin/"
printf 'base\n' > "$rc/README"; git -C "$rc" add README; git -C "$rc" commit -qm base
git -C "$rc" remote add origin "$barec"; git -C "$rc" push -q -u origin main
git -C "$rc" branch -q t-ck-branch
git -C "$rc" worktree add -q "$rc/state/worktrees/T-CK" t-ck-branch
printf 'unit\n' > "$rc/state/worktrees/T-CK/work.txt"
assert_ok "FM_ROOT='$rc' '$rc/bin/fm-checkpoint.sh' --task T-CK --repo '$rc' --message 'checkpoint unit'" \
  "checkpoint commits dirty work on a feature branch"
assert_ok "cd '$ROOT' && git --git-dir='$barec' rev-parse --verify t-ck-branch" \
  "checkpoint pushes the feature branch immediately"
assert_contains "$(git -C "$rc/state/worktrees/T-CK" log -1 --pretty=%s)" "T-CK: checkpoint unit" \
  "checkpoint commit uses the supplied message"
# --repo may be the worktree itself (not the session root).
printf 'via-repo\n' > "$rc/state/worktrees/T-CK/via.txt"
assert_ok "FM_ROOT='$rc' '$rc/bin/fm-checkpoint.sh' --task T-CK --repo '$rc/state/worktrees/T-CK' --message 'via worktree as repo'" \
  "checkpoint accepts the worktree path as --repo"
assert_ok "cd '$ROOT' && git --git-dir='$barec' cat-file -e t-ck-branch:via.txt" \
  "worktree-as-repo checkpoint pushed the file"
# --dir form (cwd-agnostic).
printf 'via-dir\n' > "$rc/state/worktrees/T-CK/via-dir.txt"
assert_ok "'$rc/bin/fm-checkpoint.sh' --dir '$rc/state/worktrees/T-CK' --message 'via --dir'" \
  "checkpoint --dir commits and pushes"
assert_ok "cd '$ROOT' && git --git-dir='$barec' cat-file -e t-ck-branch:via-dir.txt" \
  "--dir checkpoint reached the remote"
# The identity comes from the repo being committed to, not from the caller's
# cwd: this fixture's a@b.c is local to $rc, so a cwd lookup would sign with
# whatever the caller has (the operator's own address, or nothing on CI).
assert_eq "a@b.c" "$(git -C "$rc/state/worktrees/T-CK" log -1 --pretty=%ae)" \
  "--dir checkpoint signs with the repo's own identity"
# Refuse protected / non-feature tips. main is already the primary checkout,
# so attach a detached worktree at main's tip (refuses as HEAD).
git -C "$rc" worktree remove -f "$rc/state/worktrees/T-CK"
git -C "$rc" worktree add -q --detach "$rc/state/worktrees/T-CK" main
printf 'nope\n' > "$rc/state/worktrees/T-CK/bad.txt"
assert_fail "FM_ROOT='$rc' '$rc/bin/fm-checkpoint.sh' --task T-CK --repo '$rc' --message 'should refuse main'" \
  "checkpoint refuses to write on main"
assert_fail "cd '$ROOT' && git --git-dir='$barec' ls-tree -r main --name-only | grep -qx bad.txt" \
  "refused main checkpoint pushes nothing"
# Unset clears the shared repo local config (worktrees share it). On a CI
# runner with no global fallback that poisons every later commit in this
# fixture unless restored immediately after the negative case.
git -C "$rc/state/worktrees/T-CK" config --unset user.name 2>/dev/null || true
git -C "$rc/state/worktrees/T-CK" config --unset user.email 2>/dev/null || true
unset FM_GIT_NAME FM_GIT_EMAIL
printf 'orphan\n' > "$rc/state/worktrees/T-CK/orphan.txt"
assert_fail "FM_ROOT='$rc' FM_GIT_NAME= FM_GIT_EMAIL= '$rc/bin/fm-checkpoint.sh' --dir '$rc/state/worktrees/T-CK' --message 'no identity'" \
  "checkpoint refuses commit when git identity is missing"
git -C "$rc" config user.email a@b.c
git -C "$rc" config user.name t
# Re-attach a feature worktree: the prior block left T-CK detached on main.
git -C "$rc" worktree remove -f "$rc/state/worktrees/T-CK" 2>/dev/null || true
git -C "$rc" worktree add -q "$rc/state/worktrees/T-CK" t-ck-branch
# A tip that already tracks .fm-say.md must be purgeable: reset must not
# resurrect the file when the working tree deleted it.
printf 'round notes\n' > "$rc/state/worktrees/T-CK/.fm-say.md"
git -C "$rc/state/worktrees/T-CK" add -f .fm-say.md
git -C "$rc/state/worktrees/T-CK" commit -qm 'fixture: tracked say'
git -C "$rc/state/worktrees/T-CK" push -q origin t-ck-branch
rm -f "$rc/state/worktrees/T-CK/.fm-say.md"
printf 'after-purge\n' > "$rc/state/worktrees/T-CK/after.txt"
assert_ok "'$rc/bin/fm-checkpoint.sh' --dir '$rc/state/worktrees/T-CK' --message 'drop tracked say'" \
  "checkpoint commits when a tracked .fm-say.md was deleted"
assert_fail "cd '$ROOT' && git --git-dir='$barec' cat-file -e t-ck-branch:.fm-say.md" \
  "checkpoint removes a mistakenly tracked .fm-say.md from the tip"
assert_ok "cd '$ROOT' && git --git-dir='$barec' cat-file -e t-ck-branch:after.txt" \
  "purge commit still pushes the accompanying work"
# Present on-disk notes still never reach the tip.
printf 'live notes\n' > "$rc/state/worktrees/T-CK/.fm-say.md"
printf 'keep\n' > "$rc/state/worktrees/T-CK/keep.txt"
assert_ok "'$rc/bin/fm-checkpoint.sh' --dir '$rc/state/worktrees/T-CK' --message 'keep notes local'" \
  "checkpoint with a live .fm-say.md still saves other work"
assert_fail "cd '$ROOT' && git --git-dir='$barec' cat-file -e t-ck-branch:.fm-say.md" \
  "live .fm-say.md contents are never re-committed"
assert_ok "cd '$ROOT' && git --git-dir='$barec' cat-file -e t-ck-branch:keep.txt" \
  "non-ephemeral files still checkpoint beside a live .fm-say.md"
rm -rf "$dc"

# --- a later round brings its branch up to date with the base (T-067) ----
# Firstmate may not run git and the adapter cannot, so when main moves
# under an open task branch and the two conflict, fm-worker.sh is the only
# thing that can bring the branch up to date. Every case below is a real
# repository with a bare remote: round one runs, main moves in a separate
# clone - so the worker has to FETCH the base, its own local main is stale -
# and round two continues the pull request.
rb_fixture() {   # rb_fixture [two-tasks]; prints the fixture dir with round one done
  local d r
  d="$(fixture)" || return 1; r="$d/repo"
  (
    cd "$r" || exit 1
    mkdir -p src
    printf 'line %s\n' 1 2 3 4 5 6 7 8 9 10 > src/app.txt
    # The cases below were written for a base that keeps the one array,
    # design/tasks.json, and a task table, and that path is still a real
    # one - any project not yet split. So that is the layout, in jq's
    # layout, unless RB_SPLIT=1 asks for one file per task (T-090).
    if [ "${RB_SPLIT:-0}" != 1 ]; then
      git rm -q -r design/tasks && mkdir -p design
      jq -n '{tasks: [{id: "T-Z", title: "a mock task", scope: ["src/**"], acceptance: ["it exists"]}]}' \
        > design/tasks.json
    fi
    # a second entry both sides can change, on one line
    [ "${1:-}" != two-tasks ] || printf '%s\n' \
      '{"tasks":[{"id":"T-Z","title":"a mock task","scope":["src/**"],"acceptance":["it exists"]},{"id":"T-1","title":"one","scope":[],"acceptance":[]}]}' \
      > design/tasks.json
    # a line with words in it between the table and the prose: git joins
    # two conflicts separated only by a blank line into one hunk
    printf '%s\n' '# design' '## 6. gates' 'seven of them' '' \
      '| id | title | depends on |' '|---|---|---|' '| T-1 | one | — |' '' \
      'the table ends here' 'prose the two sides may both edit' '## 8. board' > design/design.md
    # RB_HOOKS=1: the repository's own hooks, in the tree and installed the
    # way a real checkout installs them - relative, so every worktree runs
    # the copy it has checked out
    if [ "${RB_HOOKS:-0}" = 1 ]; then
      cp -R "$ROOT/.githooks" .githooks; cp "$ROOT/bin/fm-install-hooks.sh" bin/
    fi
    git add -A; git commit -qm 'app and task table'; git push -q origin main
    [ "${RB_HOOKS:-0}" != 1 ] || bin/fm-install-hooks.sh >/dev/null
  ) || return 1
  # the step a round runs is a file the test writes, so each case can say
  # what its worker does without a second copy of the adapter
  cat > "$r/bin/adapters/mock.sh" <<'M'
#!/usr/bin/env bash
[ "$1" = "run" ] || exit 64
[ -z "${FM_CAPTURE:-}" ] || cp "$2" "$FM_CAPTURE"
cd "$3" || exit 1
# shellcheck disable=SC1090
. "$FM_T_STEP"
M
  chmod +x "$r/bin/adapters/mock.sh"
  # round one: the task changes line 5, edits the prose, adds its own
  # table row and gives its own tasks.json entry a dependency
  cat > "$d/round-one.sh" <<'S'
sed 's/^line 5$/line 5 by the task/' src/app.txt > src/app.next && mv src/app.next src/app.txt
awk '{ if ($0 == "prose the two sides may both edit") print "prose as the task says"; else print }
     /^\| T-1 \|/ { print "| T-Z | a mock task | T-1 |" }' design/design.md > design/d.next
mv design/d.next design/design.md
if [ -f design/tasks.json ]; then
  jq '.tasks[0].depends_on=["T-1"]' design/tasks.json > design/t.next && mv design/t.next design/tasks.json
else
  jq '.depends_on=["T-1"]' design/tasks/T-Z.json > design/t.next && mv design/t.next design/tasks/T-Z.json
fi
S
  ghstub "$d" >/dev/null
  ( cd "$r" && FM_ROOT="$r" FM_GH="$d/stub/gh" FM_T_STEP="$d/round-one.sh" \
      bin/fm-worker.sh --task T-Z >/dev/null 2>&1 ) || return 1
  printf '%s' "$d"
}
rb_branch() { git --git-dir="$1/remote.git" for-each-ref --format='%(refname:short)' refs/heads | grep -v '^main$' | head -1; }
rb_head() { git --git-dir="$1/remote.git" rev-parse "$2" 2>/dev/null; }
rb_move_main() {   # rb_move_main <dir> <script run in a fresh clone of main>
  rm -rf "$1/other"
  git clone -q -b main "$1/remote.git" "$1/other" || return 1
  # shellcheck disable=SC1090
  ( cd "$1/other" && git config user.email a@b.c && git config user.name t \
      && . "$2" && git add -A && git commit -qm 'main moved' && git push -q origin main )
}
rb_round_two() {   # rb_round_two <dir> <step> [pr, '' for none]; sets rb_out and rb_rc
  local pr="${3-42}"
  # a prompt left from an earlier round would answer for this one
  : > "$1/ghcalls"; rm -f "$1/prompt.md"
  rb_out="$(cd "$1/repo" && FM_ROOT="$1/repo" FM_GH="$1/stub/gh" FM_T_STEP="$2" \
    FM_T_DIR="$1" FM_T_BRANCH="$(rb_branch "$1")" FM_CAPTURE="$1/prompt.md" \
    bin/fm-worker.sh --task T-Z ${pr:+--pr "$pr"} 2>&1)"; rb_rc=$?
}
printf 'printf "two\\n" > src/round-two\n' > "${TMPDIR:-/tmp}/fm-rb-add-$$.sh"
rb_add="${TMPDIR:-/tmp}/fm-rb-add-$$.sh"
# What each case sets up has to have happened, or its other assertions
# pass on code that never rebuilds anything: a refused push, an untouched
# branch and a 71 all look the same with or without a rebuild in front.
rb_rebuilt() {   # rb_rebuilt <dir> <case>: this round rebuilt the branch
  assert_contains "$(cat "$1/prompt.md" 2>/dev/null)" "Your branch was rebuilt" "$2: the worker was told of a rebuild"
  assert_contains "$rb_out" "no longer rebases onto main; rebuilt on" "$2: and the run rebuilt the branch"
}
rb_not_rebuilt() {   # rb_not_rebuilt <dir> <case>: this round left the branch as it was
  assert_lacks "$(cat "$1/prompt.md" 2>/dev/null)" "Your branch was rebuilt" "$2: the worker is not told of a rebuild"
  assert_lacks "$rb_out" "rebuilt on" "$2: and the run rebuilt nothing"
}
rb_pushed() { jq -r 'select(.type=="commit_pushed")|.type' "$1/repo/state/events.jsonl" | wc -l | tr -d ' '; }
rb_commit() { git -c user.email=a@b.c -c user.name=t commit -q "$@"; }
# The branch no longer rebases onto main commit by commit, yet its change as
# a whole merges cleanly: two later commits touched line 10 and put it back,
# and main changed line 10. Gate 2 replays commits, so gate 2 is red here -
# while the squashed patch (line 5, three lines of context) still applies.
rb_replay_conflict() {   # rb_replay_conflict <dir>
  ( cd "$1/repo/state/worktrees/T-Z" \
      && sed 's/^line 10$/line 10 for a while/' src/app.txt > n && mv n src/app.txt && rb_commit -am 'touch line 10' \
      && sed 's/^line 10 for a while$/line 10/' src/app.txt > n && mv n src/app.txt && rb_commit -am 'put line 10 back' \
      && git push -q origin HEAD ) || return 1
  printf '%s\n' "sed 's/^line 10\$/line 10 by main/' src/app.txt > n && mv n src/app.txt" > "$1/main.sh"
  rb_move_main "$1" "$1/main.sh"
}
# Fails one git command the worker runs, by the words it is run with, and
# passes every other one through to the real git.
rb_git_real="$(command -v git)"
rb_gitwrap() {   # rb_gitwrap <dir>; prints a PATH entry
  mkdir -p "$1/gitwrap"
  cat > "$1/gitwrap/git" <<W
#!/usr/bin/env bash
if [ -n "\${FM_T_GIT_FAIL:-}" ]; then
  case " \$* " in *"\$FM_T_GIT_FAIL"*) echo "fm-test: refused git \$*" >&2; exit 128 ;; esac
fi
# the run dies during one git command - its leased push unless told which -
# after that command ran, or before
if [ -n "\${FM_T_GIT_KILL:-}" ]; then
  case " \$* " in *"\${FM_T_GIT_KILL_ON:- --force-with-lease=}"*)
    [ "\${FM_T_GIT_LAND:-}" != 1 ] || "$rb_git_real" "\$@"
    kill -"\$FM_T_GIT_KILL" "\$PPID"; exit 128 ;;
  esac
fi
exec "$rb_git_real" "\$@"
W
  chmod +x "$1/gitwrap/git"; printf '%s' "$1/gitwrap"
}

# A: main moved somewhere the task never touched. The branch still applies,
# so it is left exactly as it was: the round adds a commit on top of it.
dA="$(rb_fixture)"; bA="$(rb_branch "$dA")"; oldA="$(rb_head "$dA" "$bA")"
assert_ne "" "$oldA" "round one pushed a branch to continue"
printf 'printf "x\\n" > unrelated.txt\n' > "$dA/main.sh"
rb_move_main "$dA" "$dA/main.sh"
rb_round_two "$dA" "$rb_add"
assert_eq "0" "$rb_rc" "a branch that still applies: the round completes"
rb_not_rebuilt "$dA" "A"
assert_eq "$oldA" "$(rb_head "$dA" "$bA^")" "a branch that still applies is left untouched"

# A2: main changed a line next to the task's. The squashed patch no longer
# applies (its context moved), but the branch still REBASES - which is what
# gate 2 asks - so it is left exactly as it is, the same as gate 2 leaves it.
dA2="$(rb_fixture)"; bA2="$(rb_branch "$dA2")"; oldA2="$(rb_head "$dA2" "$bA2")"
printf '%s\n' "sed 's/^line 3\$/line 3 by main/' src/app.txt > n && mv n src/app.txt" > "$dA2/main.sh"
rb_move_main "$dA2" "$dA2/main.sh"
rb_round_two "$dA2" "$rb_add"
assert_eq "0" "$rb_rc" "a branch that still rebases: the round completes"
rb_not_rebuilt "$dA2" "A2"
assert_eq "$oldA2" "$(rb_head "$dA2" "$bA2^")" "a branch that still rebases is left untouched"

# B: the branch no longer rebases onto main commit by commit - gate 2 is
# red - but its change as a whole merges cleanly three-way: one commit on
# the new base, carrying both changes, and nothing for the worker.
dB="$(rb_fixture)"; bB="$(rb_branch "$dB")"
rb_replay_conflict "$dB"; oldB="$(rb_head "$dB" "$bB")"
mainB="$(rb_head "$dB" main)"
rb_round_two "$dB" "$rb_add"
assert_eq "0" "$rb_rc" "a moved base with a clean apply: the round completes"
rb_rebuilt "$dB" "B"
assert_eq "$mainB" "$(rb_head "$dB" "$bB^")" "a clean rebuild sits on the NEW base"
assert_eq "1" "$(git --git-dir="$dB/remote.git" rev-list --count "main..$bB")" \
  "as exactly one commit"
appB="$(git --git-dir="$dB/remote.git" show "$bB:src/app.txt")"
assert_contains "$appB" "line 10 by main" "the rebuilt branch keeps main's change"
assert_contains "$appB" "line 5 by the task" "and the task's"
assert_ok "git --git-dir='$dB/remote.git' cat-file -e '$bB:src/round-two'" "and this round's work"
assert_lacks "$(cat "$dB/prompt.md")" "These files conflict" "and the worker is told nothing conflicts"
assert_eq "$oldB" "$(jq -r 'select(.type=="commit_pushed" and .data.rebuilt!=null)|.data.rebuilt.previous_head' \
  "$dB/repo/state/events.jsonl" | tail -1)" "the round's result records the previous head"
assert_contains "$(cat "$dB/ghcalls")" "pr comment 42" "the pull request is told, in place"
assert_contains "$(cat "$dB/ghcalls")" "$oldB" "with the previous head for the reviewer"
assert_lacks "$(cat "$dB/ghcalls")" "pr create" "and no second pull request is opened"

# C: main and the task changed the same line, and the same prose. Both
# files reach the worker with markers, listed by name in the prompt, and
# what the worker writes is what is pushed.
rb_conflicting_main() {
  printf '%s\n' "sed 's/^line 5\$/line 5 by main/' src/app.txt > n && mv n src/app.txt" \
    "sed 's/^prose the two sides may both edit\$/prose as main says/' design/design.md > n && mv n design/design.md" \
    > "$1/main.sh"
  rb_move_main "$1" "$1/main.sh"
}
dC="$(rb_fixture)"; bC="$(rb_branch "$dC")"
rb_conflicting_main "$dC"; mainC="$(rb_head "$dC" main)"
cat > "$dC/resolve.sh" <<'S'
grep -q '^<<<<<<< ' src/app.txt && : > src/saw-markers
{ printf 'line %s\n' 1 2 3 4; printf 'line 5 by main and the task\n'; printf 'line %s\n' 6 7 8 9 10; } > src/app.txt
awk '/^<<<<<<< / { skip = 1; print "prose as main and the task say"; next }
     /^>>>>>>> / { skip = 0; next } !skip' design/design.md > design/d.next
mv design/d.next design/design.md
S
rb_round_two "$dC" "$dC/resolve.sh"
rb_rebuilt "$dC" "C"
pC="$(cat "$dC/prompt.md")"
assert_contains "$pC" "These files conflict" "a conflicting rebuild tells the worker"
assert_contains "$pC" '- `src/app.txt`' "and names the conflicting code file"
assert_contains "$pC" '- `design/design.md`' "and a design.md conflict that is not table rows"
assert_ok "git --git-dir='$dC/remote.git' cat-file -e '$bC:src/saw-markers'" \
  "the conflicting file reached the adapter with standard markers"
assert_eq "0" "$rb_rc" "a resolved conflict: the round completes"
assert_eq "$mainC" "$(rb_head "$dC" "$bC^")" "the resolved branch is one commit on the new base"
assert_contains "$(git --git-dir="$dC/remote.git" show "$bC:src/app.txt")" "line 5 by main and the task" \
  "carrying the worker's resolution"
assert_contains "$(git --git-dir="$dC/remote.git" show "$bC:design/design.md")" "prose as main and the task say" \
  "in design.md too - no whole side was taken for it"

# D: the worker leaves a marker behind. Nothing is committed and nothing
# is pushed, and the run says which file.
dD="$(rb_fixture)"; bD="$(rb_branch "$dD")"; oldD="$(rb_head "$dD" "$bD")"
rb_conflicting_main "$dD"
rb_round_two "$dD" "$rb_add"
rb_rebuilt "$dD" "D"
assert_eq "75" "$rb_rc" "a conflict marker left behind refuses the commit"
assert_contains "$rb_out" "conflict marker" "and says why"
assert_contains "$rb_out" "src/app.txt" "and which file"
assert_eq "$oldD" "$(rb_head "$dD" "$bD")" "the remote branch is not touched"
assert_eq "$oldD" "$(git -C "$dD/repo" rev-parse "$bD")" "nor is the local branch"

# E: someone else pushed to the branch while the round ran. The rebuilt
# branch is pushed with a lease on the head it fetched, so the push is
# refused rather than overwriting what arrived.
dE="$(rb_fixture)"; bE="$(rb_branch "$dE")"
rb_replay_conflict "$dE"; oldE="$(rb_head "$dE" "$bE")"; mainE="$(rb_head "$dE" main)"
cat > "$dE/race.sh" <<'S'
printf 'two\n' > src/round-two
git clone -q -b "$FM_T_BRANCH" "$FM_T_DIR/remote.git" "$FM_T_DIR/racer" \
  && git -C "$FM_T_DIR/racer" -c user.email=a@b.c -c user.name=t commit -q --allow-empty -m race \
  && git -C "$FM_T_DIR/racer" push -q origin HEAD
S
pushedE="$(rb_pushed "$dE")"
rb_round_two "$dE" "$dE/race.sh"
rb_rebuilt "$dE" "E"
raceE="$(git -C "$dE/racer" rev-parse HEAD 2>/dev/null)"
assert_ne "$oldE" "$raceE" "the racer pushed a new head"
assert_eq "71" "$rb_rc" "force-with-lease refuses when the remote head moved"
assert_eq "$raceE" "$(rb_head "$dE" "$bE")" "and the concurrent push is not overwritten"
assert_contains "$rb_out" "could not push the rebuilt $bE" "the refusal is the rebuild's lease"
rebuiltE="$(sed -n 's/^fm-worker: the rebuilt commit is \([0-9a-f]*\);.*/\1/p' <<<"$rb_out")"
assert_ne "" "$rebuiltE" "and the run names the rebuilt commit"
assert_fail "git --git-dir='$dE/remote.git' cat-file -e '$rebuiltE^{commit}'" "which never reached origin"
assert_eq "$oldE" "$(git -C "$dE/repo" rev-parse "$bE")" "the local branch is back on its previous head"
assert_eq "$pushedE" "$(rb_pushed "$dE")" "and no commit_pushed says otherwise"
# The commit is made with commit-tree, which moves nothing (T-093): the
# worktree must still be left detached on it and clean, as a commit leaves
# it, or the next round takes the refused rebuild for crashed work.
assert_eq "$rebuiltE" "$(git -C "$dE/repo/state/worktrees/T-Z" rev-parse -q --verify HEAD)" \
  "the refused round leaves the worktree on the rebuilt commit"
# tracked, staged and unmerged changes only: which scratch files a round
# leaves untracked is not what this is about
assert_eq "" "$(git -C "$dE/repo/state/worktrees/T-Z" status --porcelain --untracked-files=no)" \
  "with nothing uncommitted"
assert_ok "git -C '$dE/repo/state/worktrees/T-Z' diff --cached --quiet HEAD" "and nothing staged"
# E, next round: the local branch fast-forwards to what the racer pushed,
# and the rebuild is made again from there and leased on the racer's head.
rb_round_two "$dE" "$rb_add"
assert_eq "0" "$rb_rc" "the round after a refused lease completes"
assert_lacks "$rb_out" "had uncommitted work" "without rescuing the refused rebuild as crashed work"
assert_eq "0" "$(jq -r 'select(.type=="worker_crashed")|.type' "$dE/repo/state/events.jsonl" | wc -l | tr -d ' ')" \
  "and no worker_crashed is recorded"
rb_rebuilt "$dE" "E, next round"
assert_eq "$mainE" "$(rb_head "$dE" "$bE^")" "as one commit on the base"
assert_eq "1" "$(git --git-dir="$dE/remote.git" rev-list --count "main..$bE")" "exactly one"
assert_eq "$raceE" "$(jq -r 'select(.type=="commit_pushed" and .data.rebuilt!=null)|.data.rebuilt.previous_head' \
  "$dE/repo/state/events.jsonl" | tail -1)" "rebuilt from the racer's head, not over it"

# F: both sides appended to the task table and to tasks.json. The rows are
# unioned without the worker, and the task's own entry and row come through
# exactly. A rebuild the worker adds nothing to is still pushed.
dF="$(rb_fixture)"; bF="$(rb_branch "$dF")"; oldF="$(rb_head "$dF" "$bF")"
cat > "$dF/main.sh" <<'S'
jq '.tasks += [{id:"T-W",title:"main work",scope:[],acceptance:[]}]' design/tasks.json > n && mv n design/tasks.json
awk '{ print } /^\| T-1 \|/ { print "| T-W | main work | — |" }' design/design.md > n && mv n design/design.md
S
rb_move_main "$dF" "$dF/main.sh"
mainF="$(rb_head "$dF" main)"
printf ':\n' > "$dF/nothing.sh"
rb_round_two "$dF" "$dF/nothing.sh"
assert_eq "0" "$rb_rc" "appended rows on both sides: the round completes"
rb_rebuilt "$dF" "F"
assert_eq "$mainF" "$(rb_head "$dF" "$bF^")" "on the new base"
pF="$(cat "$dF/prompt.md")"
assert_lacks "$pF" '- `design/design.md`' "the table-row union is not handed to the worker"
assert_lacks "$pF" '- `design/tasks.json`' "nor are the appended task entries"
dmF="$(git --git-dir="$dF/remote.git" show "$bF:design/design.md")"
assert_contains "$dmF" "| T-Z | a mock task | T-1 |" "the task's table row survives exactly"
assert_contains "$dmF" "| T-W | main work | — |" "and main's row is kept beside it"
assert_lacks "$dmF" "=======" "with no marker left in design.md"
assert_eq "$(git --git-dir="$dF/remote.git" show "$oldF:design/tasks.json" | jq -cS '.tasks[]|select(.id=="T-Z")')" \
  "$(git --git-dir="$dF/remote.git" show "$bF:design/tasks.json" | jq -cS '.tasks[]|select(.id=="T-Z")')" \
  "the task's tasks.json entry survives exactly"
assert_eq "T-W" "$(git --git-dir="$dF/remote.git" show "$bF:design/tasks.json" | jq -r '.tasks[]|select(.id=="T-W")|.id')" \
  "and main's new entry is kept"

# G: a commit that fails stops the round, rebuilt or not. The script does
# not run under set -e, so an unchecked commit was stepped over and the
# round pushed and reported work it never committed. A pre-commit hook
# that refuses is the failure: the fixture's own config, nothing ambient.
rb_refusing_hook() {
  mkdir -p "$1/hooks"; printf '#!/bin/sh\nexit 1\n' > "$1/hooks/pre-commit"; chmod +x "$1/hooks/pre-commit"
  git -C "$1/repo" config core.hooksPath "$1/hooks"
}
dG="$(rb_fixture)"; bG="$(rb_branch "$dG")"; oldG="$(rb_head "$dG" "$bG")"
rb_refusing_hook "$dG"
pushedG="$(rb_pushed "$dG")"
rb_round_two "$dG" "$rb_add"
rb_not_rebuilt "$dG" "G"
assert_eq "70" "$rb_rc" "a plain round whose commit fails stops"
assert_contains "$rb_out" "could not commit" "and says so"
assert_eq "$oldG" "$(rb_head "$dG" "$bG")" "nothing is pushed"
assert_eq "$pushedG" "$(rb_pushed "$dG")" "and no commit is reported"
assert_lacks "$(cat "$dG/ghcalls")" "pr comment" "nor is the pull request told of one"
# A rebuilt round's commit is made with commit-tree, which runs no hook
# (T-093), so here the failure is commit-tree's own.
dG2="$(rb_fixture)"; bG2="$(rb_branch "$dG2")"
rb_replay_conflict "$dG2"; oldG2="$(rb_head "$dG2" "$bG2")"; mainG2="$(rb_head "$dG2" main)"
PATH="$(rb_gitwrap "$dG2"):$PATH" FM_T_GIT_FAIL=" commit-tree " rb_round_two "$dG2" "$rb_add"
rb_rebuilt "$dG2" "G2"
assert_eq "70" "$rb_rc" "a rebuilt round whose commit fails stops"
assert_contains "$rb_out" "could not commit" "at the commit"
assert_matches "$rb_out" "fm-test: refused git .* commit-tree " "G2: the failure injected is commit-tree's"
assert_eq "$oldG2" "$(rb_head "$dG2" "$bG2")" "and pushes nothing"
assert_eq "$oldG2" "$(git -C "$dG2/repo" rev-parse "$bG2")" "and the local branch is not moved onto the base"
# G2, next round, with commit-tree working: the staged rebuild the failed
# commit left is rescued, and the branch is rebuilt again and committed once.
rb_round_two "$dG2" "$rb_add"
assert_eq "0" "$rb_rc" "the round after a failed rebuilt commit completes"
rb_rebuilt "$dG2" "G2, next round"
assert_ne "" "$(ls "$dG2/repo/state/rescued" 2>/dev/null)" "after keeping what the failed round left"
assert_eq "$mainG2" "$(rb_head "$dG2" "$bG2^")" "as one commit on the base"
assert_eq "1" "$(git --git-dir="$dG2/remote.git" rev-list --count "main..$bG2")" "exactly one"
assert_eq "$oldG2" "$(jq -r 'select(.type=="commit_pushed" and .data.rebuilt!=null)|.data.rebuilt.previous_head' \
  "$dG2/repo/state/events.jsonl" | tail -1)" "rebuilt from the branch the failed round left alone"
# G3: commit-tree carries fm_git_commit's identity rule - user.name and
# user.email from git's config, or FM_GIT_NAME / FM_GIT_EMAIL - not git's
# own: with neither, a rebuilt round refuses before it commits, as a plain
# round does. Git itself still has an identity, from GIT_AUTHOR_* and
# GIT_COMMITTER_*: the rebuild's merge needs one where the host name gives
# none (a CI runner), and without the rule commit-tree would take it and
# commit. The fixture's identity is local, so it is removed here; the
# caller's global config is kept, less any identity in it.
dG3="$(rb_fixture)"; bG3="$(rb_branch "$dG3")"
rb_replay_conflict "$dG3"; oldG3="$(rb_head "$dG3" "$bG3")"; pushedG3="$(rb_pushed "$dG3")"
git -C "$dG3/repo" config --unset user.name; git -C "$dG3/repo" config --unset user.email
g3cfg="$dG3/global.gitconfig"; : > "$g3cfg"
for g3f in "$HOME/.gitconfig" "${XDG_CONFIG_HOME:-$HOME/.config}/git/config"; do
  [ ! -f "$g3f" ] || cat "$g3f" >> "$g3cfg"
done
git config --file "$g3cfg" --unset-all user.name; git config --file "$g3cfg" --unset-all user.email
assert_eq "" "$(GIT_CONFIG_GLOBAL="$g3cfg" git -C "$dG3/repo" config user.name)" "G3: git's config holds no user.name"
assert_eq "" "$(GIT_CONFIG_GLOBAL="$g3cfg" git -C "$dG3/repo" config user.email)" "G3: nor any user.email"
GIT_CONFIG_GLOBAL="$g3cfg" FM_GIT_NAME='' FM_GIT_EMAIL='' \
  GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=a@b.c GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=a@b.c \
  rb_round_two "$dG3" "$rb_add"
rb_rebuilt "$dG3" "G3"
assert_eq "70" "$rb_rc" "a rebuilt round with no git identity stops"
assert_contains "$rb_out" "set git user.name and user.email" "and names what is missing"
assert_eq "$oldG3" "$(rb_head "$dG3" "$bG3")" "and pushes nothing"
assert_eq "$pushedG3" "$(rb_pushed "$dG3")" "and no commit is reported"
# G4: a repository that signs its commits gets a signed rebuilt commit, as
# `git commit` would have made it; commit-tree ignores commit.gpgSign. The
# signer is a stand-in that answers the way gpg does, so no key is needed.
dG4="$(rb_fixture)"; bG4="$(rb_branch "$dG4")"
rb_replay_conflict "$dG4"; mainG4="$(rb_head "$dG4" main)"
cat > "$dG4/fake-gpg" <<'P'
#!/usr/bin/env bash
cat > /dev/null
printf '\n[GNUPG:] SIG_CREATED D 1 8 00 0 FAKE\n' >&2
printf '%s\n' '-----BEGIN PGP SIGNATURE-----' '' 'ZmFrZQ==' '-----END PGP SIGNATURE-----'
P
chmod +x "$dG4/fake-gpg"
git -C "$dG4/repo" config commit.gpgSign true
git -C "$dG4/repo" config gpg.program "$dG4/fake-gpg"
git -C "$dG4/repo" config user.signingKey FAKE
assert_eq "true" "$(git -C "$dG4/repo/state/worktrees/T-Z" config --bool commit.gpgSign)" "G4: the fixture signs its commits"
rb_round_two "$dG4" "$rb_add"
rb_rebuilt "$dG4" "G4"
assert_eq "0" "$rb_rc" "G4: a rebuild in a repository that signs completes"
assert_eq "$mainG4" "$(rb_head "$dG4" "$bG4^")" "G4: as one commit on the base"
assert_contains "$(git --git-dir="$dG4/remote.git" cat-file commit "$bG4")" "gpgsig -----BEGIN PGP SIGNATURE-----" \
  "G4: signed, as git commit would have signed it"

# H: design.md has a row-append conflict AND a prose conflict. The rows
# are unioned hunk by hunk; only the prose reaches the worker, as a
# standard conflict with no diff3 base section.
dH="$(rb_fixture)"; bH="$(rb_branch "$dH")"
cat > "$dH/main.sh" <<'S'
awk '{ if ($0 == "prose the two sides may both edit") print "prose as main says"; else print }
     /^\| T-1 \|/ { print "| T-W | main work | — |" }' design/design.md > n && mv n design/design.md
S
rb_move_main "$dH" "$dH/main.sh"; mainH="$(rb_head "$dH" main)"
cat > "$dH/resolve.sh" <<'S'
[ "$(grep -c '^<<<<<<< ' design/design.md)" = 1 ] && : > src/one-hunk
grep '^|||||||' design/design.md > /dev/null && : > src/saw-diff3
awk '/^<<<<<<< / { skip = 1; print "prose as main and the task say"; next }
     /^>>>>>>> / { skip = 0; next } !skip' design/design.md > design/d.next
mv design/d.next design/design.md
S
rb_round_two "$dH" "$dH/resolve.sh"
rb_rebuilt "$dH" "H"
assert_eq "0" "$rb_rc" "rows and prose both conflicting: the round completes"
assert_contains "$(cat "$dH/prompt.md")" '- `design/design.md`' "the prose goes to the worker"
assert_ok "git --git-dir='$dH/remote.git' cat-file -e '$bH:src/one-hunk'" \
  "as the only hunk left: the row union was not handed back with it"
assert_fail "git --git-dir='$dH/remote.git' cat-file -e '$bH:src/saw-diff3'" \
  "and as a standard conflict, with no diff3 base section"
assert_eq "$mainH" "$(rb_head "$dH" "$bH^")" "one commit on the new base"
dmH="$(git --git-dir="$dH/remote.git" show "$bH:design/design.md")"
assert_contains "$dmH" "| T-W | main work | — |" "main's row is kept"
assert_contains "$dmH" "| T-Z | a mock task | T-1 |" "and the task's"
assert_contains "$dmH" "prose as main and the task say" "and the worker's resolution"

# I: the task's entry and row are checked before the commit, on every
# path. A worker that rewrites its own row while resolving is refused.
dI="$(rb_fixture)"; bI="$(rb_branch "$dI")"; oldI="$(rb_head "$dI" "$bI")"
rb_conflicting_main "$dI"
cat > "$dI/resolve.sh" <<'S'
{ printf 'line %s\n' 1 2 3 4; printf 'line 5 by main and the task\n'; printf 'line %s\n' 6 7 8 9 10; } > src/app.txt
awk '/^<<<<<<< / { skip = 1; print "prose as main and the task say"; next }
     /^>>>>>>> / { skip = 0; next } !skip' design/design.md \
  | sed 's/^| T-Z | a mock task |/| T-Z | renamed by the worker |/' > design/d.next
mv design/d.next design/design.md
S
rb_round_two "$dI" "$dI/resolve.sh"
rb_rebuilt "$dI" "I"
assert_eq "75" "$rb_rc" "a rebuilt round that changes the task's own row is refused"
assert_contains "$rb_out" "table row is not as $oldI had it in: design/design.md" "and names the file"
assert_eq "$oldI" "$(rb_head "$dI" "$bI")" "and pushes nothing"

# J: main edited the task's own tasks.json entry, and the file merged
# cleanly. The branch's entry is put back, and main's other change stays.
# Main's edits alone still rebase, so the branch is first made one that
# fails gate 2's replay; otherwise nothing is rebuilt and nothing restored.
dJ="$(rb_fixture)"; bJ="$(rb_branch "$dJ")"
rb_replay_conflict "$dJ"; oldJ="$(rb_head "$dJ" "$bJ")"
cat > "$dJ/main.sh" <<'S'
sed 's/^line 3$/line 3 by main/' src/app.txt > n && mv n src/app.txt
jq '{version: 2} + (.tasks[0].title = "retitled on main")' design/tasks.json > n && mv n design/tasks.json
S
rb_move_main "$dJ" "$dJ/main.sh"; mainJ="$(rb_head "$dJ" main)"
rb_round_two "$dJ" "$rb_add"
rb_rebuilt "$dJ" "J"
assert_eq "0" "$rb_rc" "main edited the task's entry: the round completes"
assert_eq "$mainJ" "$(rb_head "$dJ" "$bJ^")" "on the new base"
tjJ="$(git --git-dir="$dJ/remote.git" show "$bJ:design/tasks.json")"
assert_eq "$(git --git-dir="$dJ/remote.git" show "$oldJ:design/tasks.json" | jq -cS '.tasks[]|select(.id=="T-Z")')" \
  "$(jq -cS '.tasks[]|select(.id=="T-Z")' <<<"$tjJ")" "the task's entry comes through as the branch had it"
assert_eq "2" "$(jq -r .version <<<"$tjJ")" "and main's other change to the file is kept"

# K: the round after one that did not commit its rebuild - a marker left
# (75), or a round that only asked - rescues the worktree, rebuilds from
# the branch, and commits once on the base with that round's resolution.
dK="$(rb_fixture)"; bK="$(rb_branch "$dK")"; oldK="$(rb_head "$dK" "$bK")"
rb_conflicting_main "$dK"; mainK="$(rb_head "$dK" main)"
rb_round_two "$dK" "$rb_add"
rb_rebuilt "$dK" "K"
assert_eq "75" "$rb_rc" "round two leaves a marker"
cp "$dC/resolve.sh" "$dK/resolve.sh" 2>/dev/null || true
rb_round_two "$dK" "$dK/resolve.sh"
rb_rebuilt "$dK" "K, next round"
assert_eq "0" "$rb_rc" "the next round completes"
assert_ne "" "$(ls "$dK/repo/state/rescued" 2>/dev/null)" "and kept the refused round's worktree first"
assert_eq "$mainK" "$(rb_head "$dK" "$bK^")" "one commit on the base"
assert_eq "1" "$(git --git-dir="$dK/remote.git" rev-list --count "main..$bK")" "exactly one"
assert_contains "$(git --git-dir="$dK/remote.git" show "$bK:src/app.txt")" "line 5 by main and the task" \
  "with this round's resolution in it"
assert_lacks "$(git --git-dir="$dK/remote.git" show "$bK:src/app.txt")" "<<<<<<<" "and no marker"
assert_ne "$oldK" "$(git -C "$dK/repo" rev-parse "$bK")" "the local branch is the rebuilt one"
dK2="$(rb_fixture)"; bK2="$(rb_branch "$dK2")"; oldK2="$(rb_head "$dK2" "$bK2")"
rb_conflicting_main "$dK2"; mainK2="$(rb_head "$dK2" main)"
printf 'printf "ASK-PASS-CRITERIA:T-Z\\n" > .fm-say.md\n' > "$dK2/ask.sh"
rb_round_two "$dK2" "$dK2/ask.sh"
rb_rebuilt "$dK2" "K2"
assert_eq "0" "$rb_rc" "a rebuilt round that only asks completes"
assert_eq "$oldK2" "$(rb_head "$dK2" "$bK2")" "and publishes nothing"
cp "$dC/resolve.sh" "$dK2/resolve.sh" 2>/dev/null || true
rb_round_two "$dK2" "$dK2/resolve.sh"
rb_rebuilt "$dK2" "K2, next round"
assert_eq "0" "$rb_rc" "the round after the question completes"
assert_eq "$mainK2" "$(rb_head "$dK2" "$bK2^")" "as one commit on the base"
assert_contains "$(git --git-dir="$dK2/remote.git" show "$bK2:src/app.txt")" "line 5 by main and the task" \
  "carrying the resolution"

# L: a reused branch with no --pr is continued the same way. The lookup
# finds no pull request, the rebuild is pushed, and the one it opens
# records the previous head.
dL="$(rb_fixture)"; bL="$(rb_branch "$dL")"
rb_replay_conflict "$dL"; oldL="$(rb_head "$dL" "$bL")"; mainL="$(rb_head "$dL" main)"
rb_round_two "$dL" "$rb_add" ''
rb_rebuilt "$dL" "L"
assert_eq "0" "$rb_rc" "a reused branch without --pr: the round completes"
assert_eq "$mainL" "$(rb_head "$dL" "$bL^")" "rebuilt on the new base"
assert_contains "$(cat "$dL/ghcalls")" "pr create" "the pull request is opened"
assert_eq "$oldL" "$(jq -r 'select(.type=="pr_opened" and .data.rebuilt!=null)|.data.rebuilt.previous_head' \
  "$dL/repo/state/events.jsonl" | tail -1)" "and the event that opens it records the previous head"

# M: something commits on the detached HEAD mid-round - a checkpoint, or
# the worker's own commit with the markers still in it - and then the
# worker adds more. The checks read the rebuild against its base, so the
# round is refused and nothing with a marker in it is published.
dM="$(rb_fixture)"; bM="$(rb_branch "$dM")"; oldM="$(rb_head "$dM" "$bM")"
rb_conflicting_main "$dM"
cat > "$dM/commit.sh" <<'S'
"$FM_T_DIR/repo/bin/fm-checkpoint.sh" --dir . --message 'mid-round save' >/dev/null 2>&1
echo "$?" > "$FM_T_DIR/checkpoint-rc"
git add -A && git -c user.email=a@b.c -c user.name=t commit -qm 'mid-round, markers and all'
printf 'two\n' > src/round-two
S
rb_round_two "$dM" "$dM/commit.sh"
rb_rebuilt "$dM" "M"
assert_ne "0" "$(cat "$dM/checkpoint-rc" 2>/dev/null)" "a checkpoint on the detached rebuild is refused"
assert_eq "75" "$rb_rc" "a commit made on the rebuild mid-round refuses the round"
assert_contains "$rb_out" "HEAD moved off the rebuild base" "and says why"
assert_eq "$oldM" "$(rb_head "$dM" "$bM")" "nothing is pushed"
assert_eq "$oldM" "$(git -C "$dM/repo" rev-parse "$bM")" "and the local branch is not moved"

# N: a conflict git cannot write markers into. Main deleted the file the
# task changed, so the task's version sits in the worktree looking done.
# It is described as what it is, and a round that leaves it exactly as the
# merge left it is refused; one that decides is committed.
dN="$(rb_fixture)"; bN="$(rb_branch "$dN")"; oldN="$(rb_head "$dN" "$bN")"
printf 'rm src/app.txt\n' > "$dN/main.sh"
rb_move_main "$dN" "$dN/main.sh"; mainN="$(rb_head "$dN" main)"
rb_round_two "$dN" "$rb_add"
rb_rebuilt "$dN" "N"
pN="$(cat "$dN/prompt.md")"
assert_contains "$pN" "git could not write markers into them" "a conflict with no markers is described as one"
assert_contains "$pN" "- \`src/app.txt\`: the worktree holds your task's version; main deleted it" \
  "with the side the merge left in the worktree"
# the worker skill in the same prompt says "carry standard conflict
# markers" too; only the list's own heading is the run's claim
assert_lacks "$pN" "These files conflict and carry standard conflict markers" "and is not called a file with markers"
assert_eq "75" "$rb_rc" "left as the merge left it, the round is refused"
assert_contains "$rb_out" "conflicts with no markers are still as the merge left them: src/app.txt" "and names it"
assert_eq "$oldN" "$(rb_head "$dN" "$bN")" "nothing is pushed"
printf '%s\n' 'rm -f src/app.txt' "printf 'line 5 by the task\\n' > src/line-5.txt" > "$dN/decide.sh"
rb_round_two "$dN" "$dN/decide.sh"
rb_rebuilt "$dN" "N, next round"
assert_eq "0" "$rb_rc" "a round that decides is committed"
assert_eq "$mainN" "$(rb_head "$dN" "$bN^")" "as one commit on the base"
assert_fail "git --git-dir='$dN/remote.git' cat-file -e '$bN:src/app.txt'" "with main's deletion kept"
assert_ok "git --git-dir='$dN/remote.git' cat-file -e '$bN:src/line-5.txt'" "and the task's intent"

# P: each place bring_up_to_date declines to rebuild says so, and leaves
# the branch as it is. Every one is set up where a rebuild would otherwise
# happen, so a guard that is deleted shows.
# P1: origin's branch has a commit the local one lacks, and the local one a
# commit origin lacks: the lease head is not in what would be rebuilt, so
# a rebuild would overwrite it. Not rebuilt; the plain push is refused.
dP1="$(rb_fixture)"; bP1="$(rb_branch "$dP1")"
rb_replay_conflict "$dP1"
( cd "$dP1/repo/state/worktrees/T-Z" && printf 'local\n' > src/local.txt && git add src/local.txt \
    && rb_commit -m 'not pushed' )
git clone -q -b "$bP1" "$dP1/remote.git" "$dP1/racer" \
  && ( cd "$dP1/racer" && rb_commit --allow-empty -m 'pushed from elsewhere' && git push -q origin HEAD )
raceP1="$(git -C "$dP1/racer" rev-parse HEAD)"
rb_round_two "$dP1" "$rb_add"
rb_not_rebuilt "$dP1" "P1"
assert_contains "$rb_out" "origin's $bP1 has commits this worktree lacks" "origin ahead: says why it is not rebuilt"
assert_eq "71" "$rb_rc" "and the plain push is refused"
assert_eq "$raceP1" "$(rb_head "$dP1" "$bP1")" "the commit only origin had is not overwritten"
# P2: the base cannot be fetched.
dP2="$(rb_fixture)"; bP2="$(rb_branch "$dP2")"
rb_replay_conflict "$dP2"; oldP2="$(rb_head "$dP2" "$bP2")"
PATH="$(rb_gitwrap "$dP2"):$PATH" FM_T_GIT_FAIL="fetch -q origin +refs/heads/main:" rb_round_two "$dP2" "$rb_add"
rb_not_rebuilt "$dP2" "P2"
assert_contains "$rb_out" "could not fetch main; $bP2 is not checked against it" "an unfetchable base: says so"
assert_eq "0" "$rb_rc" "and the round goes on without it"
assert_eq "$oldP2" "$(rb_head "$dP2" "$bP2^")" "on the branch as it was"
# P3: origin cannot say where the branch is, so there is no head to lease on.
dP3="$(rb_fixture)"; bP3="$(rb_branch "$dP3")"
rb_replay_conflict "$dP3"; oldP3="$(rb_head "$dP3" "$bP3")"
PATH="$(rb_gitwrap "$dP3"):$PATH" FM_T_GIT_FAIL="ls-remote --exit-code --heads origin refs/heads/" \
  rb_round_two "$dP3" "$rb_add"
rb_not_rebuilt "$dP3" "P3"
assert_contains "$rb_out" "could not read origin's $bP3; not rebuilding it" "an unreadable remote head: says so"
assert_eq "0" "$rb_rc" "and the round goes on without a rebuild"
assert_eq "$oldP3" "$(rb_head "$dP3" "$bP3^")" "on the branch as it was"
# P4: main was replaced by a history the branch shares nothing with.
dP4="$(rb_fixture)"; bP4="$(rb_branch "$dP4")"; oldP4="$(rb_head "$dP4" "$bP4")"
rm -rf "$dP4/other"; git clone -q -b main "$dP4/remote.git" "$dP4/other"
( cd "$dP4/other" && git checkout -q --orphan fresh && git rm -rqf . && printf 'x\n' > x \
    && git add x && rb_commit -m 'unrelated' && git push -q -f origin fresh:main )
rb_round_two "$dP4" "$rb_add"
rb_not_rebuilt "$dP4" "P4"
assert_contains "$rb_out" "$bP4 shares no history with main" "no merge base: says so"
assert_eq "0" "$rb_rc" "and the round goes on without a rebuild"
assert_eq "$oldP4" "$(rb_head "$dP4" "$bP4^")" "on the branch as it was"
# P5: the three-way merge fails without leaving a conflict. The worker is
# never handed the bare base as though it were its branch.
dP5="$(rb_fixture)"; bP5="$(rb_branch "$dP5")"
rb_replay_conflict "$dP5"; oldP5="$(rb_head "$dP5" "$bP5")"
PATH="$(rb_gitwrap "$dP5"):$PATH" FM_T_GIT_FAIL="merge -q --squash" rb_round_two "$dP5" "$rb_add"
assert_eq "70" "$rb_rc" "a merge that fails with no conflict stops the round"
assert_contains "$rb_out" "could not rebuild $bP5 on main" "and says so"
assert_eq "" "$(cat "$dP5/prompt.md" 2>/dev/null)" "before any worker is started"
assert_eq "$oldP5" "$(rb_head "$dP5" "$bP5")" "nothing is pushed"
assert_eq "refs/heads/$bP5" "$(git -C "$dP5/repo/state/worktrees/T-Z" symbolic-ref -q HEAD)" \
  "and the worktree is back on the branch"
assert_eq "$oldP5" "$(git -C "$dP5/repo/state/worktrees/T-Z" rev-parse HEAD)" "at its head"
# P6: the fresh worktree is not clean - here a post-checkout hook of the
# repository's own wrote into it - so the rebuild, whose failure path is a
# hard reset, is not attempted.
dP6="$(rb_fixture)"; bP6="$(rb_branch "$dP6")"
rb_replay_conflict "$dP6"; oldP6="$(rb_head "$dP6" "$bP6")"
mkdir -p "$dP6/hooks"; printf '#!/bin/sh\nprintf "stray\\n" > stray.txt\n' > "$dP6/hooks/post-checkout"
chmod +x "$dP6/hooks/post-checkout"; git -C "$dP6/repo" config core.hooksPath "$dP6/hooks"
rb_round_two "$dP6" "$rb_add"
rb_not_rebuilt "$dP6" "P6"
assert_contains "$rb_out" "is not clean; $bP6 is not rebuilt this round" "a dirty worktree: says so"
assert_eq "0" "$rb_rc" "and the round goes on without a rebuild"
assert_eq "$oldP6" "$(rb_head "$dP6" "$bP6^")" "on the branch as it was"
# P7: both sides changed the same entry in tasks.json, and it is not the
# task's. Merging by id cannot choose, so the file goes to the worker with
# its markers rather than one side's entry being taken.
dP7="$(rb_fixture two-tasks)"; bP7="$(rb_branch "$dP7")"
( cd "$dP7/repo/state/worktrees/T-Z" \
    && jq '(.tasks[]|select(.id=="T-1")|.title)="one, as the task says"' design/tasks.json > n \
    && mv n design/tasks.json && rb_commit -am 'the task retitles T-1' && git push -q origin HEAD )
oldP7="$(rb_head "$dP7" "$bP7")"
printf '%s\n' "jq '(.tasks[]|select(.id==\"T-1\")|.title)=\"one, as main says\"' design/tasks.json > n && mv n design/tasks.json" \
  > "$dP7/main.sh"
rb_move_main "$dP7" "$dP7/main.sh"
printf '%s\n' 'grep -q "^<<<<<<< " design/tasks.json && : > "$FM_T_DIR/saw-tasks-markers"' > "$dP7/look.sh"
rb_round_two "$dP7" "$dP7/look.sh"
rb_rebuilt "$dP7" "P7"
assert_contains "$(cat "$dP7/prompt.md")" '- `design/tasks.json`' "an entry both sides changed goes to the worker"
assert_ok "test -f '$dP7/saw-tasks-markers'" "with its markers"
assert_eq "75" "$rb_rc" "and a round that leaves them is refused"
assert_eq "$oldP7" "$(rb_head "$dP7" "$bP7")" "nothing is pushed"

# Q: the run dies during the rebuilt push. The local branch must end on
# whatever origin has, or every later round is refused at the plain push
# (71) with nothing in the system allowed to repair it. TERM goes through
# the EXIT trap; KILL leaves it to the next round. Each dies once with the
# push not landed and once with it landed, and the next round is run.
rb_dies_pushing() {   # rb_dies_pushing <dir> <signal> <landed 0|1>
  PATH="$(rb_gitwrap "$1"):$PATH" FM_T_GIT_KILL="$2" FM_T_GIT_LAND="$3" rb_round_two "$1" "$rb_add"
}
rb_pending() { git -C "$1/repo" rev-parse -q --verify "refs/fm-rebuilt/$2" 2>/dev/null; }
# a round after a landed rebuild needs work of its own to commit
rb_more="${TMPDIR:-/tmp}/fm-rb-more-$$.sh"; printf 'printf "three\\n" > src/round-three\n' > "$rb_more"
# Q1: TERM before origin took it. The branch never moved, and stays.
dQ1="$(rb_fixture)"; bQ1="$(rb_branch "$dQ1")"
rb_replay_conflict "$dQ1"; oldQ1="$(rb_head "$dQ1" "$bQ1")"; mainQ1="$(rb_head "$dQ1" main)"
rb_dies_pushing "$dQ1" TERM 0
rb_rebuilt "$dQ1" "Q1"
assert_eq "143" "$rb_rc" "Q1: a run terminated during its rebuilt push stops"
assert_eq "$oldQ1" "$(rb_head "$dQ1" "$bQ1")" "Q1: origin never took the rebuild"
assert_eq "$oldQ1" "$(git -C "$dQ1/repo" rev-parse "$bQ1")" "Q1: so the local branch stays on the previous head"
assert_contains "$rb_out" "never reached origin; $bQ1 stays where it was" "Q1: the exit settles it and says so"
assert_eq "" "$(rb_pending "$dQ1" "$bQ1")" "Q1: and nothing is left pending"
rb_round_two "$dQ1" "$rb_add"
assert_eq "0" "$rb_rc" "Q1, next round: completes rather than being refused"
rb_rebuilt "$dQ1" "Q1, next round"
assert_eq "$mainQ1" "$(rb_head "$dQ1" "$bQ1^")" "Q1, next round: one commit on the base"
assert_eq "1" "$(git --git-dir="$dQ1/remote.git" rev-list --count "main..$bQ1")" "Q1, next round: exactly one"
# Q2: TERM after origin took it. The branch follows origin.
dQ2="$(rb_fixture)"; bQ2="$(rb_branch "$dQ2")"
rb_replay_conflict "$dQ2"; mainQ2="$(rb_head "$dQ2" main)"
rb_dies_pushing "$dQ2" TERM 1
rb_rebuilt "$dQ2" "Q2"
assert_eq "143" "$rb_rc" "Q2: a run terminated as its rebuilt push lands stops"
newQ2="$(rb_head "$dQ2" "$bQ2")"
assert_eq "$mainQ2" "$(rb_head "$dQ2" "$bQ2^")" "Q2: origin took the rebuild"
assert_eq "$newQ2" "$(git -C "$dQ2/repo" rev-parse "$bQ2")" "Q2: so the local branch moves onto it"
assert_contains "$rb_out" "reached origin; $bQ2 now points at it" "Q2: the exit settles it and says so"
assert_eq "" "$(rb_pending "$dQ2" "$bQ2")" "Q2: and nothing is left pending"
rb_round_two "$dQ2" "$rb_more"
assert_eq "0" "$rb_rc" "Q2, next round: completes"
rb_not_rebuilt "$dQ2" "Q2, next round"
assert_eq "$newQ2" "$(rb_head "$dQ2" "$bQ2^")" "Q2, next round: continues the rebuilt commit"
# Q3: KILL before origin took it. No trap runs; the next round asks origin.
dQ3="$(rb_fixture)"; bQ3="$(rb_branch "$dQ3")"
rb_replay_conflict "$dQ3"; oldQ3="$(rb_head "$dQ3" "$bQ3")"; mainQ3="$(rb_head "$dQ3" main)"
rb_dies_pushing "$dQ3" KILL 0
rb_rebuilt "$dQ3" "Q3"
assert_eq "137" "$rb_rc" "Q3: a run killed during its rebuilt push stops"
assert_eq "$oldQ3" "$(rb_head "$dQ3" "$bQ3")" "Q3: origin never took the rebuild"
assert_eq "$oldQ3" "$(git -C "$dQ3/repo" rev-parse "$bQ3")" "Q3: and the local branch never moved"
assert_ne "" "$(rb_pending "$dQ3" "$bQ3")" "Q3: the unconfirmed push is left pending"
rb_round_two "$dQ3" "$rb_add"
assert_eq "0" "$rb_rc" "Q3, next round: completes rather than being refused"
assert_contains "$rb_out" "never reached origin; $bQ3 stays where it was" "Q3, next round: settles it first"
assert_eq "" "$(rb_pending "$dQ3" "$bQ3")" "Q3, next round: and clears it"
rb_rebuilt "$dQ3" "Q3, next round"
assert_eq "$mainQ3" "$(rb_head "$dQ3" "$bQ3^")" "Q3, next round: one commit on the base"
# Q4: KILL after origin took it, before the local branch moved onto it.
dQ4="$(rb_fixture)"; bQ4="$(rb_branch "$dQ4")"
rb_replay_conflict "$dQ4"; oldQ4="$(rb_head "$dQ4" "$bQ4")"; mainQ4="$(rb_head "$dQ4" main)"
rb_dies_pushing "$dQ4" KILL 1
rb_rebuilt "$dQ4" "Q4"
assert_eq "137" "$rb_rc" "Q4: a run killed as its rebuilt push lands stops"
newQ4="$(rb_head "$dQ4" "$bQ4")"
assert_eq "$mainQ4" "$(rb_head "$dQ4" "$bQ4^")" "Q4: origin took the rebuild"
assert_eq "$oldQ4" "$(git -C "$dQ4/repo" rev-parse "$bQ4")" "Q4: the local branch had not moved yet"
rb_round_two "$dQ4" "$rb_more"
assert_eq "0" "$rb_rc" "Q4, next round: completes rather than being refused"
assert_contains "$rb_out" "reached origin; $bQ4 now points at it" "Q4, next round: follows origin first"
rb_not_rebuilt "$dQ4" "Q4, next round"
assert_eq "$newQ4" "$(rb_head "$dQ4" "$bQ4^")" "Q4, next round: continues the rebuilt commit"

# R: a conflict in a file whose name is not ASCII. git's plain path output
# quotes such a name ("src/\346\226\207..."), and that string names no file:
# read as one, the conflict looks deleted, sits under "no markers", and the
# round is refused on every rebuild with nothing allowed to repair it.
# core.quotePath is set to git's default here, not read from this machine.
rb_ascii_conflict() {   # rb_ascii_conflict <dir>: both sides add src/文件.txt
  git -C "$1/repo" config core.quotePath true
  ( cd "$1/repo/state/worktrees/T-Z" && printf 'the task\n' > 'src/文件.txt' && git add -A \
      && rb_commit -m 'the task adds a file' && git push -q origin HEAD ) || return 1
  printf '%s\n' "printf 'main\\n' > 'src/文件.txt'" > "$1/main.sh"
  rb_move_main "$1" "$1/main.sh"
}
# R1: the worker resolves it; one commit on the base, carrying the resolution.
dR1="$(rb_fixture)"; bR1="$(rb_branch "$dR1")"
rb_ascii_conflict "$dR1"; mainR1="$(rb_head "$dR1" main)"
printf '%s\n' "grep -q '^<<<<<<< ' 'src/文件.txt' && : > \"\$FM_T_DIR/saw-markers\"" \
  "printf 'main and the task\\n' > 'src/文件.txt'" > "$dR1/resolve.sh"
rb_round_two "$dR1" "$dR1/resolve.sh"
rb_rebuilt "$dR1" "R1"
pR1="$(cat "$dR1/prompt.md")"
assert_contains "$pR1" '- `src/文件.txt`' "R1: a non-ASCII conflict is listed by its real name"
assert_lacks "$pR1" '\346' "R1: never by git's quoted spelling"
assert_lacks "$pR1" "git could not write markers" "R1: and not as a conflict with no markers"
assert_ok "test -f '$dR1/saw-markers'" "R1: it reached the worker with its markers"
assert_eq "0" "$rb_rc" "R1: once resolved, the round completes"
assert_eq "$mainR1" "$(rb_head "$dR1" "$bR1^")" "R1: as one commit on the base"
assert_eq "main and the task" "$(git --git-dir="$dR1/remote.git" show "$bR1:src/文件.txt")" \
  "R1: carrying the worker's resolution"
# R2: a marker left in it is refused, and the refusal names the real file.
dR2="$(rb_fixture)"; bR2="$(rb_branch "$dR2")"
rb_ascii_conflict "$dR2"; oldR2="$(rb_head "$dR2" "$bR2")"
rb_round_two "$dR2" "$rb_add"
rb_rebuilt "$dR2" "R2"
assert_eq "75" "$rb_rc" "R2: a marker left in a non-ASCII file refuses the commit"
assert_contains "$rb_out" "conflict markers remain in: src/文件.txt" "R2: naming the file as it is"
assert_eq "$oldR2" "$(rb_head "$dR2" "$bR2")" "R2: nothing is pushed"

# S: the rebase probe fails for a reason that is not a conflict. That says
# nothing about gate 2, so the branch is not rebuilt (and force-pushed) on it.
dS="$(rb_fixture)"; bS="$(rb_branch "$dS")"
rb_replay_conflict "$dS"; oldS="$(rb_head "$dS" "$bS")"
PATH="$(rb_gitwrap "$dS"):$PATH" FM_T_GIT_FAIL="rebase refs/remotes/origin/main" rb_round_two "$dS" "$rb_add"
rb_not_rebuilt "$dS" "S"
assert_contains "$rb_out" "could not check whether $bS rebases onto main; not rebuilding it" \
  "S: a probe that failed without a conflict: says so"
assert_eq "0" "$rb_rc" "S: and the round goes on without a rebuild"
assert_eq "$oldS" "$(rb_head "$dS" "$bS^")" "S: on the branch as it was"

# T: TERM right after the squash merge, before the rest of the rebuild. The
# worktree is detached and dirty with the half-made rebuild; the exit must
# know it is one and publish nothing, and the next round rebuilds it.
dT="$(rb_fixture)"; bT="$(rb_branch "$dT")"
rb_replay_conflict "$dT"; oldT="$(rb_head "$dT" "$bT")"; mainT="$(rb_head "$dT" main)"
PATH="$(rb_gitwrap "$dT"):$PATH" FM_T_GIT_KILL=TERM FM_T_GIT_KILL_ON=" merge -q --squash " FM_T_GIT_LAND=1 \
  rb_round_two "$dT" "$rb_add"
assert_eq "143" "$rb_rc" "T: a run terminated mid-rebuild stops"
assert_contains "$rb_out" "the rebuild of $bT was not committed" "T: the exit knows it holds a rebuild"
assert_lacks "$rb_out" "publishing dirty worktree" "T: and publishes nothing from it"
assert_eq "$oldT" "$(rb_head "$dT" "$bT")" "T: origin is untouched"
rb_round_two "$dT" "$rb_add"
assert_eq "0" "$rb_rc" "T, next round: completes"
rb_rebuilt "$dT" "T, next round"
assert_eq "$mainT" "$(rb_head "$dT" "$bT^")" "T, next round: one commit on the base"

# U: rebuilds in a repository running its real hooks, installed by
# bin/fm-install-hooks.sh (T-093). Every fixture above installs none, and
# that is how a rebuild the repository's own pre-commit refused on every
# real checkout - it is made on a detached HEAD - passed here.
dU1="$(RB_HOOKS=1 rb_fixture)"; bU1="$(rb_branch "$dU1")"
assert_ne "" "$bU1" "U1: round one pushed a branch under the real hooks"
assert_eq ".githooks" "$(git -C "$dU1/repo" config --get core.hooksPath)" "U1: the fixture installs the real hooks"
assert_fail "git -C '$dU1/repo' -c user.email=a@b.c -c user.name=t commit -q --allow-empty -m onmain" \
  "U1: and they are live: a commit on main is refused"
rb_replay_conflict "$dU1"; oldU1="$(rb_head "$dU1" "$bU1")"; mainU1="$(rb_head "$dU1" main)"
rb_round_two "$dU1" "$rb_add"
rb_rebuilt "$dU1" "U1"
assert_eq "0" "$rb_rc" "U1: a rebuild under the real hooks completes"
assert_lacks "$rb_out" "detached HEAD" "U1: and no hook refused it"
assert_eq "$mainU1" "$(rb_head "$dU1" "$bU1^")" "U1: one commit on the new base"
assert_eq "1" "$(git --git-dir="$dU1/remote.git" rev-list --count "main..$bU1")" "U1: exactly one"
assert_ok "git --git-dir='$dU1/remote.git' cat-file -e '$bU1:src/round-two'" "U1: carrying this round's work"
# made as fm_git_commit makes a plain round's commit: the fixture's own
# identity as author and committer, and the task's title
assert_eq "t <a@b.c> t <a@b.c>" "$(git --git-dir="$dU1/remote.git" log -1 --format='%an <%ae> %cn <%ce>' "$bU1")" \
  "U1: under the repository's identity, as author and committer"
assert_eq "T-Z: a mock task" "$(git --git-dir="$dU1/remote.git" log -1 --format=%B "$bU1")" \
  "U1: with the message a plain round's commit has"
assert_eq "$(rb_head "$dU1" "$bU1")" "$(git -C "$dU1/repo" rev-parse "$bU1")" "U1: the local branch moved onto what was pushed"
assert_eq "refs/heads/$bU1" "$(git -C "$dU1/repo/state/worktrees/T-Z" symbolic-ref -q HEAD)" \
  "U1: and the worktree is back on the branch"
assert_eq "$oldU1" "$(jq -r 'select(.type=="commit_pushed" and .data.rebuilt!=null)|.data.rebuilt.previous_head' \
  "$dU1/repo/state/events.jsonl" | tail -1)" "U1: the previous head is recorded"
# U2: a marker left behind publishes nothing under the real hooks either;
# the round that resolves it publishes one commit on the base
dU2="$(RB_HOOKS=1 rb_fixture)"; bU2="$(rb_branch "$dU2")"; oldU2="$(rb_head "$dU2" "$bU2")"
assert_eq ".githooks" "$(git -C "$dU2/repo" config --get core.hooksPath)" "U2: the fixture installs the real hooks"
assert_fail "git -C '$dU2/repo' -c user.email=a@b.c -c user.name=t commit -q --allow-empty -m onmain" \
  "U2: and they are live: a commit on main is refused"
rb_conflicting_main "$dU2"; mainU2="$(rb_head "$dU2" main)"
pushedU2="$(rb_pushed "$dU2")"
rb_round_two "$dU2" "$rb_add"
rb_rebuilt "$dU2" "U2"
assert_eq "75" "$rb_rc" "U2: a marker left behind refuses the round"
# both conflicts are left, and git lists them in path order
assert_contains "$rb_out" "conflict markers remain in: design/design.md, src/app.txt" "U2: and names the files"
assert_eq "$oldU2" "$(rb_head "$dU2" "$bU2")" "U2: nothing is pushed"
assert_eq "$oldU2" "$(git -C "$dU2/repo" rev-parse "$bU2")" "U2: the local branch is not moved"
assert_eq "$pushedU2" "$(rb_pushed "$dU2")" "U2: and no commit is reported"
cat > "$dU2/resolve.sh" <<'S'
{ printf 'line %s\n' 1 2 3 4; printf 'line 5 by main and the task\n'; printf 'line %s\n' 6 7 8 9 10; } > src/app.txt
awk '/^<<<<<<< / { skip = 1; print "prose as main and the task say"; next }
     /^>>>>>>> / { skip = 0; next } !skip' design/design.md > design/d.next
mv design/d.next design/design.md
S
rb_round_two "$dU2" "$dU2/resolve.sh"
rb_rebuilt "$dU2" "U2, next round"
assert_eq "0" "$rb_rc" "U2, next round: the resolved rebuild completes under the real hooks"
assert_eq "$mainU2" "$(rb_head "$dU2" "$bU2^")" "U2, next round: one commit on the base"
assert_eq "1" "$(git --git-dir="$dU2/remote.git" rev-list --count "main..$bU2")" "U2, next round: exactly one"
assert_contains "$(git --git-dir="$dU2/remote.git" show "$bU2:src/app.txt")" "line 5 by main and the task" \
  "U2, next round: carrying the resolution"
assert_eq "$(rb_head "$dU2" "$bU2")" "$(git -C "$dU2/repo" rev-parse "$bU2")" "U2, next round: the local branch moved onto it"

# W: one file per task (T-090). main splits design/tasks.json into
# design/tasks/<id>.json under a branch that still carries the array.
rb_split_main() {   # rb_split_main <dir> [extra lines for main to run after the split]
  { printf '%s\n' 'mkdir -p design/tasks' \
      'jq -c ".tasks[]" design/tasks.json | while IFS= read -r t; do jq . <<<"$t" > "design/tasks/$(jq -r .id <<<"$t").json"; done' \
      'git rm -q design/tasks.json'
    [ -z "${2:-}" ] || printf '%s\n' "$2"; } > "$1/main.sh"
  rb_move_main "$1" "$1/main.sh"
}
# W1: the branch changed its own entry in round one and adds a second
# task's entry, as a design task does. The rebuild moves both into files of
# their own and removes the array, with no worker involved.
dW1="$(rb_fixture)"; bW1="$(rb_branch "$dW1")"
( cd "$dW1/repo/state/worktrees/T-Z" \
    && jq '.tasks += [{id: "T-EXTRA", title: "written by the design task", scope: [], acceptance: []}]' design/tasks.json > n \
    && mv n design/tasks.json && rb_commit -am 'a second entry' && git push -q origin HEAD )
oldW1="$(rb_head "$dW1" "$bW1")"
rb_split_main "$dW1"; mainW1="$(rb_head "$dW1" main)"
assert_fail "git --git-dir='$dW1/remote.git' cat-file -e 'main:design/tasks.json'" "W1: main no longer has design/tasks.json"
rb_round_two "$dW1" "$rb_add"
rb_rebuilt "$dW1" "W1"
assert_eq "0" "$rb_rc" "W1: a branch that still carries the array is rebuilt onto the split main"
assert_eq "$mainW1" "$(rb_head "$dW1" "$bW1^")" "W1: one commit on the new base"
assert_fail "git --git-dir='$dW1/remote.git' cat-file -e '$bW1:design/tasks.json'" "W1: the array is gone from the branch"
assert_eq "$(git --git-dir="$dW1/remote.git" show "$oldW1:design/tasks.json" | jq -cS '.tasks[]|select(.id=="T-Z")')" \
  "$(git --git-dir="$dW1/remote.git" show "$bW1:design/tasks/T-Z.json" | jq -cS .)" \
  "W1: the task's own entry, as the branch had it, is now its own file"
assert_eq '["T-1"]' "$(git --git-dir="$dW1/remote.git" show "$bW1:design/tasks/T-Z.json" | jq -c .depends_on)" \
  "W1: (the branch's revision, not main's text)"
assert_eq "written by the design task" \
  "$(git --git-dir="$dW1/remote.git" show "$bW1:design/tasks/T-EXTRA.json" 2>/dev/null | jq -r .title)" \
  "W1: and another task's entry the branch added is moved too, not dropped"
assert_contains "$(cat "$dW1/prompt.md")" "keeps one file per task" "W1: the worker is told the layout"
assert_lacks "$(cat "$dW1/prompt.md")" '- `design/tasks.json`' "W1: and is not handed the array to resolve"
# W1b: the branch and main both changed one other entry; that file is handed
# over with markers, the round is refused until it is resolved, and neither
# side's text is lost on the way
dW1b="$(rb_fixture two-tasks)"; bW1b="$(rb_branch "$dW1b")"
( cd "$dW1b/repo/state/worktrees/T-Z" \
    && jq '(.tasks[]|select(.id=="T-1")|.title)="one, as the task says"' design/tasks.json > n \
    && mv n design/tasks.json && rb_commit -am 'the task retitles T-1' && git push -q origin HEAD )
oldW1b="$(rb_head "$dW1b" "$bW1b")"
rb_split_main "$dW1b" "jq '.title=\"one, as main says\"' design/tasks/T-1.json > n && mv n design/tasks/T-1.json"
printf '%s\n' 'cp design/tasks/T-1.json "$FM_T_DIR/t1-seen"' "$(cat "$rb_add")" > "$dW1b/look.sh"
rb_round_two "$dW1b" "$dW1b/look.sh"
rb_rebuilt "$dW1b" "W1b"
assert_contains "$(cat "$dW1b/prompt.md")" '- `design/tasks/T-1.json`' "W1b: an entry both sides changed goes to the worker by its file"
assert_contains "$(cat "$dW1b/t1-seen" 2>/dev/null)" "one, as main says" "W1b: with main's text"
assert_contains "$(cat "$dW1b/t1-seen" 2>/dev/null)" "one, as the task says" "W1b: and the branch's"
assert_eq "75" "$rb_rc" "W1b: left unresolved, the round is refused"
assert_contains "$rb_out" "design/tasks/T-1.json" "W1b: naming the file"
assert_eq "$oldW1b" "$(rb_head "$dW1b" "$bW1b")" "W1b: and nothing is pushed"
# W2: a branch already in the one-file layout; main edits the task's own
# file. The rebuild puts the branch's file back, byte for byte.
dW2="$(RB_SPLIT=1 rb_fixture)"; bW2="$(rb_branch "$dW2")"
assert_fail "git --git-dir='$dW2/remote.git' cat-file -e 'main:design/tasks.json'" "W2: (main keeps one file per task)"
( cd "$dW2/repo/state/worktrees/T-Z" \
    && sed 's/^line 10$/line 10 for a while/' src/app.txt > n && mv n src/app.txt && rb_commit -am 'touch line 10' \
    && sed 's/^line 10 for a while$/line 10/' src/app.txt > n && mv n src/app.txt && rb_commit -am 'put line 10 back' \
    && git push -q origin HEAD )
oldW2="$(rb_head "$dW2" "$bW2")"
printf '%s\n' "sed 's/^line 10\$/line 10 by main/' src/app.txt > n && mv n src/app.txt" \
  "jq '.title=\"retitled on main\"' design/tasks/T-Z.json > n && mv n design/tasks/T-Z.json" > "$dW2/main.sh"
rb_move_main "$dW2" "$dW2/main.sh"
rb_round_two "$dW2" "$rb_add"
rb_rebuilt "$dW2" "W2"
assert_eq "0" "$rb_rc" "W2: the rebuild completes"
assert_eq "$(git --git-dir="$dW2/remote.git" rev-parse "$oldW2:design/tasks/T-Z.json")" \
  "$(git --git-dir="$dW2/remote.git" rev-parse "$bW2:design/tasks/T-Z.json" 2>/dev/null)" \
  "W2: the task's own file comes through byte for byte as the branch had it"
assert_contains "$(git --git-dir="$dW2/remote.git" show "$bW2:src/app.txt")" "line 10 by main" "W2: and main's other change is kept"
assert_contains "$(cat "$dW2/prompt.md")" 'design/tasks/T-Z.json' "W2: the worker is told its own file is frozen"
# W3: the worker starts on a task that exists only in its branch's old
# design/tasks.json - a new task, opened before main split the list
dW3="$(RB_SPLIT=1 rb_fixture)"
( cd "$dW3/repo" && git checkout -q -b t-q-old-list main && git rm -q -r design/tasks && mkdir -p design \
    && printf '%s\n' '{"tasks":[{"id":"T-Q","title":"a task only its old branch has","scope":["src/**"],"acceptance":["it exists"]}]}' \
       > design/tasks.json \
    && git add design/tasks.json && rb_commit -m 'T-Q on its own branch' && git push -q origin HEAD && git checkout -q main )
: > "$dW3/ghcalls"; rm -f "$dW3/prompt.md"
outW3="$(cd "$dW3/repo" && FM_ROOT="$dW3/repo" FM_GH="$dW3/stub/gh" FM_T_STEP="$rb_add" FM_T_DIR="$dW3" \
  FM_CAPTURE="$dW3/prompt.md" bin/fm-worker.sh --task T-Q 2>&1)"; rcW3=$?
assert_ne "65" "$rcW3" "W3: a task only in its branch's old design/tasks.json is found"
assert_lacks "$outW3" "no task T-Q" "W3: and not reported as missing"
assert_eq "0" "$rcW3" "W3: the round completes"
[ "$rcW3" = 0 ] || printf '%s\n' "$outW3" | sed 's/^/      W3 run: /'
assert_contains "$(cat "$dW3/prompt.md" 2>/dev/null)" "a task only its old branch has" "W3: the worker is handed its spec"

rm -rf "$dW1" "$dW1b" "$dW2" "$dW3"

# --- a clean rebuild is always published (T-098) ------------------------
# A rebuild with nothing handed to the worker is the round's work whether
# or not the worker adds to it. A worker that changed nothing and left a
# note - or only asked, which from round three is the protocol - ended the
# round on the exit path, and the EXIT trap said "the rebuild ... was not
# committed (exit-0)": the branch stayed on its old head, DIRTY on GitHub,
# until the captain pushed it by hand (T-089, T-086). Under the real hooks.
rb_published_alone() {   # rb_published_alone <dir> <branch> <old head> <main head> <case>
  assert_eq "0" "$rb_rc" "$5: the round completes"
  assert_lacks "$rb_out" "was not committed" "$5: and the exit publishes nothing of its own"
  assert_eq "$4" "$(rb_head "$1" "$2^")" "$5: the branch is one commit on the new base"
  assert_eq "1" "$(git --git-dir="$1/remote.git" rev-list --count "main..$2")" "$5: exactly one"
  # the rebuild alone: the task's own change, and nothing else
  assert_eq "$(git --git-dir="$1/remote.git" diff --name-only "$(git --git-dir="$1/remote.git" merge-base main "$3")" "$3")" \
    "$(git --git-dir="$1/remote.git" diff --name-only main "$2")" "$5: carrying the task's change and nothing more"
  assert_contains "$(git --git-dir="$1/remote.git" show "$2:src/app.txt")" "line 10 by main" "$5: with main's change"
  assert_contains "$(git --git-dir="$1/remote.git" show "$2:src/app.txt")" "line 5 by the task" "$5: and the task's"
  assert_eq "$(rb_head "$1" "$2")" "$(git -C "$1/repo" rev-parse "$2")" "$5: the local branch moved onto what was pushed"
  # on the event that reports the push: pr_opened when this round opened
  # the pull request, commit_pushed when it was already there
  assert_eq "$3" "$(jq -r 'select((.type=="commit_pushed" or .type=="pr_opened") and .data.rebuilt!=null)|.data.rebuilt.previous_head' \
    "$1/repo/state/events.jsonl" | tail -1)" "$5: the pushed round records the previous head"
}
# V0: the worker changes nothing and says nothing. Already published before
# T-098 (case F is the same with appended rows); a guard, not fail-first.
dV0="$(RB_HOOKS=1 rb_fixture)"; bV0="$(rb_branch "$dV0")"
rb_replay_conflict "$dV0"; oldV0="$(rb_head "$dV0" "$bV0")"; mainV0="$(rb_head "$dV0" main)"
printf ':\n' > "$dV0/nothing.sh"
rb_round_two "$dV0" "$dV0/nothing.sh"
rb_rebuilt "$dV0" "V0"
rb_published_alone "$dV0" "$bV0" "$oldV0" "$mainV0" "V0"
# V1: the worker changes nothing and says so in a note
dV1="$(RB_HOOKS=1 rb_fixture)"; bV1="$(rb_branch "$dV1")"
rb_replay_conflict "$dV1"; oldV1="$(rb_head "$dV1" "$bV1")"; mainV1="$(rb_head "$dV1" main)"
printf 'printf "Nothing to change: the rebuild is clean.\\n" > .fm-say.md\n' > "$dV1/note.sh"
rb_round_two "$dV1" "$dV1/note.sh"
rb_rebuilt "$dV1" "V1"
rb_published_alone "$dV1" "$bV1" "$oldV1" "$mainV1" "V1"
assert_contains "$(cat "$dV1/ghcalls")" "pr comment 42 --body-file" "V1: the note is on the pull request"
# V2: the worker only asks. The rebuild is pushed; the round still reports
# that it asked, and the question is on the pull request.
dV2="$(RB_HOOKS=1 rb_fixture)"; bV2="$(rb_branch "$dV2")"
rb_replay_conflict "$dV2"; oldV2="$(rb_head "$dV2" "$bV2")"; mainV2="$(rb_head "$dV2" main)"
printf 'printf "ASK-PASS-CRITERIA:T-Z\\n" > .fm-say.md\n' > "$dV2/ask.sh"
rb_round_two "$dV2" "$dV2/ask.sh"
rb_rebuilt "$dV2" "V2"
rb_published_alone "$dV2" "$bV2" "$oldV2" "$mainV2" "V2"
assert_contains "$rb_out" "the worker asked rather than changed anything; its question is on #42" \
  "V2: the round is reported as asked"
assert_contains "$(cat "$dV2/ghcalls")" "pr comment 42 --body-file" "V2: and the question is on the pull request"
assert_eq "1" "$(jq -r 'select(.type=="ask_pass_criteria")|.type' "$dV2/repo/state/events.jsonl" | wc -l | tr -d ' ')" \
  "V2: posted once"
# V3: the same with no pull request yet. The rebuild opens one, and the
# question waits for it rather than being kept as premature.
dV3="$(RB_HOOKS=1 rb_fixture)"; bV3="$(rb_branch "$dV3")"
rb_replay_conflict "$dV3"; oldV3="$(rb_head "$dV3" "$bV3")"; mainV3="$(rb_head "$dV3" main)"
rb_round_two "$dV3" "$dV2/ask.sh" ''
rb_rebuilt "$dV3" "V3"
rb_published_alone "$dV3" "$bV3" "$oldV3" "$mainV3" "V3"
assert_contains "$rb_out" "the worker asked rather than changed anything; its question waits for the pull request this round opens" \
  "V3: the round is reported as asked"
assert_contains "$(cat "$dV3/ghcalls")" "pr create" "V3: the pull request is opened"
assert_contains "$(cat "$dV3/ghcalls")" "pr comment 42 --body-file" "V3: and the question goes on it"
assert_eq "" "$(ls "$dV3/repo/state/unsent" 2>/dev/null)" "V3: nothing is kept as unsent"
# V5: the pull request refuses the worker's note. The round still fails as
# a refused note does, and keeps it once, where it was refused - and the
# rebuild is pushed all the same. The note is never posted a second time.
rb_refusing_gh() {   # rb_refusing_gh <dir> [once]: --body-file is refused, every time or the first
  cat > "$1/stub/gh" <<G
#!/usr/bin/env bash
echo "gh \$*" >> "$1/ghcalls"
case " \$* " in *" --body-file "*)
  if [ "${2:-}" != once ] || [ ! -e "$1/refused-once" ]; then
    : > "$1/refused-once"; echo "could not post" >&2; exit 1
  fi ;;
esac
echo "https://example.invalid/pull/42"
G
}
rb_note_kept_once() {   # rb_note_kept_once <dir> <case>
  assert_contains "$rb_out" "#42 would not take the comment" "$2: the refusal is said"
  assert_eq "1" "$(grep -c -- '--body-file' "$1/ghcalls")" "$2: the note is offered to the pull request once"
  assert_eq "1" "$(ls "$1/repo/state/unsent" 2>/dev/null | wc -l | tr -d ' ')" "$2: and kept once"
  local kept=("$1"/repo/state/unsent/T-Z-*.md)
  assert_contains "$(cat "${kept[0]}" 2>/dev/null)" "ASK-PASS-CRITERIA:T-Z" "$2: with the worker's text"
  assert_lacks "$rb_out" "before the worker's note reached a pull request" "$2: and never said to be lost"
  assert_contains "$rb_out" "the worker asked rather than changed anything; #42 would not take its question" \
    "$2: the round is reported as asked"
}
dV5="$(RB_HOOKS=1 rb_fixture)"; bV5="$(rb_branch "$dV5")"
rb_replay_conflict "$dV5"; oldV5="$(rb_head "$dV5" "$bV5")"; mainV5="$(rb_head "$dV5" main)"
rb_refusing_gh "$dV5"
rb_round_two "$dV5" "$dV2/ask.sh"
rb_rebuilt "$dV5" "V5"
assert_eq "73" "$rb_rc" "V5: a refused note still fails the round"
rb_note_kept_once "$dV5" "V5"
assert_lacks "$rb_out" "was not committed" "V5: and the rebuild is not left behind"
assert_eq "$mainV5" "$(rb_head "$dV5" "$bV5^")" "V5: the branch is one commit on the new base"
assert_ne "$oldV5" "$(rb_head "$dV5" "$bV5")" "V5: off its old head"
assert_eq "$(rb_head "$dV5" "$bV5")" "$(git -C "$dV5/repo" rev-parse "$bV5")" \
  "V5: the local branch moved onto what was pushed"
# V5b: the pull request refuses the first post and would take a later one.
# There is no later one: the round is 73, and the note is in one place.
dV5b="$(RB_HOOKS=1 rb_fixture)"; bV5b="$(rb_branch "$dV5b")"
rb_replay_conflict "$dV5b"; mainV5b="$(rb_head "$dV5b" main)"
rb_refusing_gh "$dV5b" once
rb_round_two "$dV5b" "$dV2/ask.sh"
rb_rebuilt "$dV5b" "V5b"
assert_eq "73" "$rb_rc" "V5b: a note refused once still fails the round"
rb_note_kept_once "$dV5b" "V5b"
assert_eq "$mainV5b" "$(rb_head "$dV5b" "$bV5b^")" "V5b: and the rebuild is pushed"
# V5c: the note is refused, then so is the push. The note was kept where it
# was refused, so the failed push neither loses it nor keeps it again.
dV5c="$(RB_HOOKS=1 rb_fixture)"; bV5c="$(rb_branch "$dV5c")"
rb_replay_conflict "$dV5c"; oldV5c="$(rb_head "$dV5c" "$bV5c")"
rb_refusing_gh "$dV5c"
PATH="$(rb_gitwrap "$dV5c"):$PATH" FM_T_GIT_FAIL=" --force-with-lease=" rb_round_two "$dV5c" "$dV2/ask.sh"
rb_rebuilt "$dV5c" "V5c"
assert_eq "71" "$rb_rc" "V5c: a refused push ends the round with its own code"
assert_contains "$rb_out" "could not push the rebuilt $bV5c" "V5c: the refusal is the rebuild's push"
rb_note_kept_once "$dV5c" "V5c"
assert_eq "$oldV5c" "$(rb_head "$dV5c" "$bV5c")" "V5c: and the branch stays where it was"
# V4: a conflicting rebuild the worker only asks about is still not
# published: the markers are the worker's to resolve, next round.
dV4="$(RB_HOOKS=1 rb_fixture)"; bV4="$(rb_branch "$dV4")"; oldV4="$(rb_head "$dV4" "$bV4")"
rb_conflicting_main "$dV4"; pushedV4="$(rb_pushed "$dV4")"
rb_round_two "$dV4" "$dV2/ask.sh"
rb_rebuilt "$dV4" "V4"
assert_eq "0" "$rb_rc" "V4: an asking round on a conflicting rebuild completes"
assert_contains "$rb_out" "the worker asked rather than changed anything" "V4: as asked"
assert_contains "$rb_out" "the rebuild of $bV4 was not committed" "V4: and says the rebuild is not published"
assert_eq "$oldV4" "$(rb_head "$dV4" "$bV4")" "V4: the remote branch is not touched"
assert_eq "$oldV4" "$(git -C "$dV4/repo" rev-parse "$bV4")" "V4: nor the local one"
assert_eq "$pushedV4" "$(rb_pushed "$dV4")" "V4: and no commit is reported"
# V6: every file merges, but main's own row for the task leaves the task's
# row not as the branch had it, and the rebuild cannot put it back. That is
# unresolved like a marker - the check before the commit refuses it as it
# stands - so an asking round on it publishes nothing, as in V4.
dV6="$(RB_HOOKS=1 rb_fixture)"; bV6="$(rb_branch "$dV6")"
rb_replay_conflict "$dV6"
cat > "$dV6/main.sh" <<'S'
awk '{ print } NR == 1 { print "| T-Z | a row main wrote for it | — |" }' design/design.md > n && mv n design/design.md
S
rb_move_main "$dV6" "$dV6/main.sh"
oldV6="$(rb_head "$dV6" "$bV6")"; pushedV6="$(rb_pushed "$dV6")"
rb_round_two "$dV6" "$dV2/ask.sh"
rb_rebuilt "$dV6" "V6"
pV6="$(cat "$dV6/prompt.md")"
assert_contains "$pV6" "Every file applied cleanly" "V6: nothing conflicts"
assert_contains "$pV6" "The rebuild could not keep your task's own entry or table row in" \
  "V6: but the task's row is handed to the worker to put back"
assert_eq "0" "$rb_rc" "V6: an asking round on it completes"
assert_contains "$rb_out" "the worker asked rather than changed anything; its question is on #42" "V6: as asked"
assert_contains "$rb_out" "the rebuild of $bV6 was not committed" "V6: and says the rebuild is not published"
assert_eq "$oldV6" "$(rb_head "$dV6" "$bV6")" "V6: the remote branch is not touched"
assert_eq "$oldV6" "$(git -C "$dV6/repo" rev-parse "$bV6")" "V6: nor the local one"
assert_eq "$pushedV6" "$(rb_pushed "$dV6")" "V6: and no commit is reported"

# --- a new script keeps its executable bit (T-098) -----------------------
# The claude worker's sandbox refuses chmod, so every script a worker added
# was committed 100644 and a suite running it by path failed with 126
# (T-048, T-059). fm-worker.sh sets the bit in the index itself: on a file
# the round adds under bin/ or tests/, with a shebang, in a directory whose
# existing scripts are executable. Never removed, never on another file.
dX="$(RB_HOOKS=1 rb_fixture)"; bX="$(rb_branch "$dX")"
( cd "$dX/repo/state/worktrees/T-Z" && mkdir -p tests \
    && printf '#!/usr/bin/env bash\nexit 0\n' > tests/old.test.sh && chmod +x tests/old.test.sh \
    && printf '#!/usr/bin/env bash\n: kept 100644\n' > bin/sourced.sh && chmod -x bin/sourced.sh \
    && mkdir -p tests/lib && printf '#!/usr/bin/env bash\n: sourced\n' > tests/lib/common.sh \
    && chmod -x tests/lib/common.sh \
    && git add -A && rb_commit -m 'an executable test and a sourced script' && git push -q origin HEAD ) \
  || echo "fm-test: could not set up X" >&2
assert_eq "100644" "$(git --git-dir="$dX/remote.git" ls-tree "$bX" bin/sourced.sh | cut -c1-6)" \
  "X: the fixture's existing sourced script is 100644"
cat > "$dX/scripts.sh" <<'S'
printf '#!/usr/bin/env bash\necho tool\n' > bin/fm-tool
printf '#!/usr/bin/env bash\necho new\n' > tests/new.test.sh
printf '#!/usr/bin/env python3\nprint(1)\n' > tests/helper.py
printf 'plain notes\n' > bin/notes.txt
printf 'echo no shebang\n' > tests/plain.sh
printf '#!/usr/bin/env bash\necho elsewhere\n' > src/run.sh
printf '#!/usr/bin/env bash\n: still 100644\n' > bin/sourced.sh
printf '#!/usr/bin/env bash\n: sourced too\n' > tests/lib/more.sh
mkdir -p tests/fresh && printf '#!/usr/bin/env bash\necho fresh\n' > tests/fresh/run.sh
chmod -x tests/lib/more.sh tests/fresh/run.sh 2>/dev/null || true
chmod -x bin/fm-tool tests/new.test.sh tests/helper.py 2>/dev/null || true
S
rb_round_two "$dX" "$dX/scripts.sh"
assert_eq "0" "$rb_rc" "X: the round completes"
rb_not_rebuilt "$dX" "X"
x_mode() { git --git-dir="$dX/remote.git" ls-tree "$bX" -- "$1" | cut -c1-6; }
assert_eq "100755" "$(x_mode bin/fm-tool)" "X: a new script under bin/ is committed 100755"
assert_eq "100755" "$(x_mode tests/new.test.sh)" "X: and one under tests/"
assert_eq "100755" "$(x_mode tests/helper.py)" "X: a .py with a shebang too"
assert_eq "100644" "$(x_mode bin/notes.txt)" "X: a new file that is no script stays 100644"
assert_eq "100644" "$(x_mode tests/plain.sh)" "X: and a .sh with no shebang line"
assert_eq "100644" "$(x_mode src/run.sh)" "X: a new script outside bin/ and tests/ is left as added"
assert_eq "100644" "$(x_mode bin/sourced.sh)" "X: an existing file's mode is untouched"
assert_eq "100755" "$(x_mode tests/old.test.sh)" "X: and an existing bit is never removed"
# the directory decides as well as the file: one whose scripts are all
# sourced, and one with no script before this round, run nothing by path
assert_eq "100644" "$(x_mode tests/lib/more.sh)" "X: a new script beside only sourced ones stays 100644"
assert_eq "100644" "$(x_mode tests/fresh/run.sh)" "X: and one in a new directory"
assert_eq "" "$(git -C "$dX/repo/state/worktrees/T-Z" status --porcelain --untracked-files=no)" \
  "X: the worktree agrees with what was committed"
# the run names each file it marked, and only those
for f in bin/fm-tool tests/new.test.sh tests/helper.py; do
  assert_contains "$rb_out" "fm-worker: $f is a new script; it is committed executable" "X: the run names $f"
done
assert_eq "3" "$(grep -c 'is a new script; it is committed executable' <<<"$rb_out")" "X: and no other file"
# X2: the same in a rebuilt round, read against the base it is made on
dX2="$(RB_HOOKS=1 rb_fixture)"; bX2="$(rb_branch "$dX2")"
rb_replay_conflict "$dX2"
printf 'printf "#!/usr/bin/env bash\\necho tool\\n" > bin/fm-tool\n' > "$dX2/tool.sh"
rb_round_two "$dX2" "$dX2/tool.sh"
rb_rebuilt "$dX2" "X2"
assert_eq "0" "$rb_rc" "X2: the rebuilt round completes"
assert_eq "100755" "$(git --git-dir="$dX2/remote.git" ls-tree "$bX2" -- bin/fm-tool | cut -c1-6)" \
  "X2: a new script in a rebuilt round is committed 100755"
# X4: a script an earlier round added without the bit is not this round's
# to change, though a rebuild puts it on a base that never had it
dX4="$(RB_HOOKS=1 rb_fixture)"; bX4="$(rb_branch "$dX4")"
( cd "$dX4/repo/state/worktrees/T-Z" && printf '#!/usr/bin/env bash\necho old\n' > bin/fm-earlier \
    && chmod -x bin/fm-earlier && git add bin/fm-earlier && rb_commit -m 'an earlier round' \
    && git push -q origin HEAD ) || echo "fm-test: could not set up X4" >&2
rb_replay_conflict "$dX4"
rb_round_two "$dX4" "$dX2/tool.sh"
rb_rebuilt "$dX4" "X4"
assert_eq "0" "$rb_rc" "X4: the rebuilt round completes"
assert_eq "100755" "$(git --git-dir="$dX4/remote.git" ls-tree "$bX4" -- bin/fm-tool | cut -c1-6)" \
  "X4: this round's new script is committed 100755"
assert_eq "100644" "$(git --git-dir="$dX4/remote.git" ls-tree "$bX4" -- bin/fm-earlier | cut -c1-6)" \
  "X4: one the previous head already had keeps its mode"
# X5: the index will not take the bit. The round's commit is not made
# without it; on a rebuild, which the exit never publishes, nothing is.
dX5="$(RB_HOOKS=1 rb_fixture)"; bX5="$(rb_branch "$dX5")"
rb_replay_conflict "$dX5"; oldX5="$(rb_head "$dX5" "$bX5")"
PATH="$(rb_gitwrap "$dX5"):$PATH" FM_T_GIT_FAIL=" update-index --chmod=+x " rb_round_two "$dX5" "$dX2/tool.sh"
rb_rebuilt "$dX5" "X5"
assert_eq "70" "$rb_rc" "X5: a bit the index refuses stops the round"
assert_contains "$rb_out" "could not set the executable bit on a new script" "X5: and says why"
assert_eq "$oldX5" "$(rb_head "$dX5" "$bX5")" "X5: nothing is pushed"
# X6: the same refusal in a plain round. Its commit is not made either, and
# the exit's checkpoint saves the worktree as it does after any exit before
# that commit - through fm-checkpoint.sh, so without the bit.
dX6="$(RB_HOOKS=1 rb_fixture)"; bX6="$(rb_branch "$dX6")"; oldX6="$(rb_head "$dX6" "$bX6")"
PATH="$(rb_gitwrap "$dX6"):$PATH" FM_T_GIT_FAIL=" update-index --chmod=+x " rb_round_two "$dX6" "$dX2/tool.sh"
rb_not_rebuilt "$dX6" "X6"
assert_eq "70" "$rb_rc" "X6: a bit the index refuses stops a plain round"
assert_contains "$rb_out" "could not set the executable bit on a new script on $bX6; the round is not committed" \
  "X6: and says why"
assert_contains "$rb_out" "publishing dirty worktree (exit-70)" "X6: the exit's checkpoint runs"
assert_eq "$oldX6" "$(rb_head "$dX6" "$bX6^")" "X6: and saves the worktree as one commit on the branch"
assert_eq "100644" "$(git --git-dir="$dX6/remote.git" ls-tree "$bX6" -- bin/fm-tool | cut -c1-6)" \
  "X6: carrying the script without its bit"
# X3: the worker saves mid-run, as its skill requires, and fm-checkpoint.sh
# commits the new script without the bit. It is still one the round added.
dX3="$(RB_HOOKS=1 rb_fixture)"; bX3="$(rb_branch "$dX3")"
cat > "$dX3/save.sh" <<'S'
printf '#!/usr/bin/env bash\necho mid\n' > bin/fm-mid
"$FM_T_DIR/repo/bin/fm-checkpoint.sh" --dir . --message 'mid-round save' >/dev/null 2>&1
echo "$?" > "$FM_T_DIR/checkpoint-rc"
printf 'more\n' > src/more
S
rb_round_two "$dX3" "$dX3/save.sh"
assert_eq "0" "$(cat "$dX3/checkpoint-rc" 2>/dev/null)" "X3: the mid-run checkpoint landed"
assert_eq "0" "$rb_rc" "X3: the round completes"
assert_eq "100755" "$(git --git-dir="$dX3/remote.git" ls-tree "$bX3" -- bin/fm-mid | cut -c1-6)" \
  "X3: a new script a checkpoint committed without the bit is committed 100755"

rm -rf "$dA" "$dA2" "$dB" "$dC" "$dD" "$dE" "$dF" "$dG" "$dG2" "$dG3" "$dG4" "$dH" "$dI" "$dJ" "$dK" "$dK2" "$dL" \
  "$dM" "$dN" "$dP1" "$dP2" "$dP3" "$dP4" "$dP5" "$dP6" "$dP7" "$dQ1" "$dQ2" "$dQ3" "$dQ4" \
  "$dR1" "$dR2" "$dS" "$dT" "$dU1" "$dU2" "$dV0" "$dV1" "$dV2" "$dV3" "$dV4" "$dV5" "$dV5b" "$dV5c" "$dV6" \
  "$dX" "$dX2" "$dX3" "$dX4" "$dX5" "$dX6" "$rb_add" "$rb_more"

finish
