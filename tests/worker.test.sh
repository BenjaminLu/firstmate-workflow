#!/usr/bin/env bash
# The worker runs an adapter and then does all the git itself. The adapter
# must never be near a repository operation.
set -uo pipefail
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
  local d; d="$(mktemp -d)"; local bare="$d/remote.git"
  git init -q --bare "$bare"
  git init -q -b main "$d/repo"
  cd "$d/repo" || return 1
  git config user.email a@b.c; git config user.name t
  mkdir -p bin design skills/worker state
  cp "$ROOT/bin/fm-config.sh" "$ROOT/bin/fm-emit.sh" "$ROOT/bin/fm-worker.sh" bin/
  cp -r "$ROOT/bin/adapters" bin/
  cp "$ROOT/skills/worker/SKILL.md" skills/worker/
  printf 'vendor: mock\nfallback:\n  - mock\n' > config.yaml
  cat > design/tasks.json <<'JSON'
{"tasks":[{"id":"T-Z","title":"a mock task","scope":["src/**"],"acceptance":["it exists"]}]}
JSON
  printf '# design\n## 6. gates\nseven of them\n## 8. board\n' > design/design.md
  git add -A; git commit -qm base; git remote add origin "$bare"; git push -q -u origin main
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

d="$(fixture)"; r="$d/repo"; GH="$(ghstub "$d")"
out="$(cd "$r" && FM_ROOT="$r" FM_GH="$GH" bin/fm-worker.sh --task T-Z --name worker-1 2>&1)"; rc=$?
assert_eq "0" "$rc" "a clean run exits 0"
branch="$(printf '%s' "$out" | tail -1)"
assert_contains "$branch" "t-z" "it names the branch after the task"
assert_ok "test -d '$r/state/worktrees/T-Z'" "it made a worktree of its own"
assert_ok "git -C '$r' rev-parse --verify '$branch'" "the branch exists"
assert_eq "1" "$(git -C "$r" rev-list --count "main..$branch")" "exactly one commit"
assert_ok "git -C '$r/state/worktrees/T-Z' show --stat HEAD | grep -q mock.txt" "the adapter's file is in it"
assert_ok "git --git-dir='$d/remote.git' rev-parse --verify '$branch'" "it pushed to the remote"
assert_contains "$(cat "$d/ghcalls")" "pr create" "it opened a pull request"

log="$r/state/events.jsonl"
assert_contains "$(jq -r .type < "$log" | tr '\n' ' ')" "commit_pushed" "it emitted commit_pushed"
assert_contains "$(jq -r .type < "$log" | tr '\n' ' ')" "pr_opened" "it emitted pr_opened"

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
assert_ok "cd '$r5' && git cat-file -e '$branch:src/round-one'" "and committed its work"

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
assert_ok "cd '$r5' && git cat-file -e '$branch:src/round-one'" "the second round keeps the first round's work"
assert_ok "cd '$r5' && git cat-file -e '$branch:src/round-two'" "and adds its own"
assert_ok "cd '$r5' && git cat-file -e '$branch:src/saw-review'" "and was given the review to answer"
assert_ok "cd '$r5' && git cat-file -e '$branch:src/saw-ci'" "and why the required check is red"
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
assert_ok "cd '$r9' && git cat-file -e '$b9:src/round-one'" \
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
assert_fail "cd '$r6' && git cat-file -e '$b6:.fm-say.md'" "and the file never reaches the diff"
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
rm -rf "$d8"

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
# A TMPDIR that is a file: mktemp cannot mint into it, whatever the
# uid. `--pr 25` so the LOOKUP's scratch file is never wanted - that
# one is a hard refusal by design (exit 70, T-031), and the run would
# stop before it ever reached the block under test.
: > "$d19/nodir"
cap19="$d19/sent.md"
( cd "$r19" && TMPDIR="$d19/nodir" FM_ROOT="$r19" FM_GH="$GH19" FM_CAPTURE="$cap19" \
    bin/fm-worker.sh --task T-Z --pr 25 >/dev/null 2>&1 )
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
sleep 5
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
( cd "$r15" && TMPDIR="$d15/tmp" FM_ROOT="$r15" FM_GH="$GH15" FM_STARTED="$started15" \
    exec bin/fm-worker.sh --task T-Z >/dev/null 2>&1 ) &
kp15=$!
for _ in $(seq 1 60); do [ -e "$started15" ] && break; sleep 0.2; done
assert_ok "test -e '$started15'" "the engine was running, so the scratch file is open"
kill -TERM "$kp15" 2>/dev/null
wait "$kp15" 2>/dev/null
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
assert_ok "cd '$r12' && git cat-file -e '$b12:src/round-one'" "the first round pushed a branch"
# the local trace is gone: the worktree, the branch, the whole of state/
( cd "$r12" && git worktree remove --force "state/worktrees/T-Z" >/dev/null 2>&1; true )
( cd "$r12" && git branch -D "$b12" >/dev/null 2>&1 )
assert_fail "cd '$r12' && git show-ref --verify --quiet 'refs/heads/$b12'" \
  "and nothing local remembers it"
assert_ok "cd '$r12' && git ls-remote --exit-code --heads origin '$b12'" "but origin does"
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
# The adapter sleeps and THEN does the work, so the two runs differ. A
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
sleep 2
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
( cd "$rk" && FM_ROOT="$rk" FM_GH="$GHk" FM_STARTED="$started" \
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
wait "$killme" 2>/dev/null; krc=$?
for _ in $(seq 1 40); do
  [ "$(jq -r .type < "$rk/state/events.jsonl" 2>/dev/null | tail -1)" = "agent_finished" ] && break
  sleep 0.2
done
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
# sleep finishes and the work lands - and the run still never reached
# `pr create`. Work present, pull request absent, is something only an
# interrupted run produces.
assert_ok "test -f '$rk/state/worktrees/T-Z/src/thing'" \
  "the adapter had finished its work, so a run left alone would have gone on"
rm -rf "$dk"

# the same fixture, left alone: this is what the four assertions above
# are the absence of, and without it they are satisfied by a run that
# was never interrupted
dl="$(fixture)"; rl="$dl/repo"; GHl="$(ghstub "$dl")"
killable_adapter "$rl"
( cd "$rl" && FM_ROOT="$rl" FM_GH="$GHl" FM_STARTED="$dl/started" \
    bin/fm-worker.sh --task T-Z >/dev/null 2>&1 )
assert_eq "0" "$?" "the same run, not killed, exits 0"
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
finish
