#!/usr/bin/env bash
# The worker runs an adapter and then does all the git itself. The adapter
# must never be near a repository operation.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=tests/lib.sh
. "$ROOT/tests/lib.sh"

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
  # `pr list` has to answer emptily: the worker asks it first, and a stub
  # that answers every question with a url tells the worker a pull request
  # already exists and it never opens one
  mkdir -p "$1/stub"
  cat > "$1/stub/gh" <<G
#!/usr/bin/env bash
echo "gh \$*" >> "$1/ghcalls"
case " \$* " in
  *" pr list "*) exit 0 ;;
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
  *" run view "*) printf 'ci\tbin/ci.sh\tTHE RUNNER SAID: a title with markup is not escaped\n'; exit 0 ;;
  *" pr view "*" comments "*)
    jq -cn '{author:{login:"reviewer-1"},body:"REVIEWER SAID: fix the helper"}' \
      | jq -r '"## " + .author.login + "\n\n" + .body + "\n"' ;;
esac
exit 0
G
chmod +x "$d5/stub/gh"
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
  *" run view "*) printf 'ci\tbin/ci.sh\tTHE RUNNER SAID: the gate is red\n'; exit 0 ;;
  *" pr view "*" comments "*) printf '## reviewer-1\n\nREVIEWER SAID: answer this\n' ;;
esac
exit 0
G
chmod +x "$d9/stub/gh"
: > "$d9/ghcalls"
out9="$(cd "$r9" && FM_ROOT="$r9" FM_GH="$GH9" bin/fm-worker.sh --task T-Z 2>&1)"; rc9=$?
assert_eq "0" "$rc9" "a later round dispatched from a task id alone is a complete round"
assert_contains "$out9" "already has #31" "the worker found the pull request itself"
assert_contains "$out9" "its question is on #31" "and says which one it spoke on, with a number after the hash"
# the question exists only if BOTH halves reached the prompt: the
# adapter exits 1 without either, so this assertion is the conjunction
assert_contains "$(cat "$d9/ghcalls")" "run view" "and the prompt carried the failing check as well as the review"
assert_contains "$(cat "$d9/ghcalls")" "pr comment 31" "the question reached that pull request"
assert_eq "31" "$(jq -r 'select(.type=="ask_pass_criteria")|.pr' < "$r9/state/events.jsonl" | tail -1)" \
  "and the log records the number it spoke on"
assert_contains "$out9" "asked rather than changed" \
  "an asking round says so - which is the string the stale-signal test below asserts the ABSENCE of"
assert_lacks "$(cat "$d9/ghcalls")" "pr create" "and it opened no second pull request"
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
assert_contains "$out8" "is new - this is a first round" \
  "and it says what was actually checked - that there is no branch yet"
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
  < "$r8/state/events.jsonl" | tail -1)" "first round" "and the log says which of the three it was"
rm -rf "$d8"

# the third cause, which the two branches above could not tell apart: a
# LATER round whose lookup came back empty. `gh` swallowed its errors,
# so an unreachable one looked exactly like a new branch - and the run
# said "this branch is new" about a branch with commits on it.
d10="$(fixture)"; r10="$d10/repo"; GH10="$(ghstub "$d10")"
cat > "$r10/bin/adapters/mock.sh" <<'M'
#!/usr/bin/env bash
[ "$1" = "run" ] || exit 64
if [ -f "$3/src/round-one" ]; then
  printf 'ASK-PASS-CRITERIA:T-Z\n' > "$3/.fm-say.md"
else
  mkdir -p "$3/src"; printf 'the first round\n' > "$3/src/round-one"
fi
M
chmod +x "$r10/bin/adapters/mock.sh"
( cd "$r10" && FM_ROOT="$r10" FM_GH="$GH10" bin/fm-worker.sh --task T-Z >/dev/null 2>&1 )
b10="$(cd "$r10" && git for-each-ref --format='%(refname:short)' refs/heads | grep -v '^main$' | head -1)"
assert_ok "cd '$r10' && git cat-file -e '$b10:src/round-one'" "the first round committed something"
# a gh that cannot answer, which is what a rate limit or an outage is
printf '#!/usr/bin/env bash\nexit 1\n' > "$d10/stub/gh"; chmod +x "$d10/stub/gh"
out10="$(cd "$r10" && FM_ROOT="$r10" FM_GH="$GH10" bin/fm-worker.sh --task T-Z 2>&1)"; rc10=$?
assert_eq "73" "$rc10" "a later round that cannot find its pull request fails too"
assert_contains "$out10" "exists but no open pull request was found" \
  "and does not call a branch with commits on it new"
assert_contains "$out10" "gh that did not answer" "naming the cause it could not rule out"

# And that keeping it does not leave a stale signal behind: the
# worktree is removed and recreated from the branch on every round, so
# `[ -s .fm-say.md ]` can only ever be this round's question. If it
# were not - if the file were kept where it was written - the next
# round would read it, report itself an asking round whatever the
# engine did, and never commit the work.
cat > "$r10/bin/adapters/mock.sh" <<'M'
#!/usr/bin/env bash
[ "$1" = "run" ] || exit 64
mkdir -p "$3/src"; printf 'the round after the failure\n' > "$3/src/round-three"
M
chmod +x "$r10/bin/adapters/mock.sh"
assert_ok "test -s '$r10/state/worktrees/T-Z/.fm-say.md'" \
  "the failed round's question is still in the worktree it was written in"
cat > "$d10/stub/gh" <<'G'
#!/usr/bin/env bash
echo "gh $*" >> "$(dirname "$0")/../ghcalls"
case " $* " in *" pr list "*) echo 31; exit 0 ;; esac
exit 0
G
chmod +x "$d10/stub/gh"; : > "$d10/ghcalls"
out11="$(cd "$r10" && FM_ROOT="$r10" FM_GH="$GH10" bin/fm-worker.sh --task T-Z 2>&1)"
# the phrase is one the script does emit - asserted on out9 above, on a
# round that really did ask - so its absence here is evidence
assert_lacks "$out11" "asked rather than changed" \
  "a question left by an earlier round is not this round's question"
assert_ok "cd '$r10' && git cat-file -e '$b10:src/round-three'" \
  "and the work this round did is committed, not thrown away"
assert_fail "test -e '$r10/state/worktrees/T-Z/.fm-say.md'" \
  "the recreated worktree does not carry it"
rm -rf "$d10"

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
mkdir -p "$r11/state/unsent"; chmod 500 "$r11/state/unsent"
out12="$(cd "$r11" && FM_ROOT="$r11" FM_GH="$GH11" bin/fm-worker.sh --task T-Z --pr 9 2>&1)"; rc12=$?
chmod 700 "$r11/state/unsent"
assert_eq "73" "$rc12" "a question that can be neither posted nor kept still fails the run"
assert_contains "$out12" "could not be kept either" "and says the keeping failed too"
assert_lacks "$out12" "it is at state/unsent" "rather than naming a file it did not write"
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
assert_lacks "$(cat "$d12/ghcalls")" "pr create" \
  "so it does not try to open a second pull request for it"
assert_contains "$(jq -r 'select(.type=="commit_pushed")|.pr|tostring' \
  < "$r12/state/events.jsonl" | tail -1)" "55" "and its push points at the one that is there"
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

# the adapter never touches the repository
# a comment may mention git; a call may not
assert_fail "grep -vE '^[[:space:]]*#' '$ROOT/bin/adapters/mock.sh' | grep -qE '\\b(git|gh)\\b'" \
  "the mock adapter calls no git and no gh"
rm -rf "$d" "$d2" "$d3"
finish
