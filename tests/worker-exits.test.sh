#!/usr/bin/env bash
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=tests/lib/worker.sh
. "$ROOT/tests/lib/worker.sh"
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
  assert_eq "1" "$(grep -c . <<<"$(jq -r 'select(.type=="agent_finished")|.type' "$ra/state/events.jsonl")" || true)" \
    "exactly once, not once per exit path"
  # T-137: and the end wakes firstmate, pushed by the round itself - one
  # item on the wake queue, under the round's own name, with the line
  # firstmate is woken with. The round's progress and its own gate_failed
  # push nothing: the queue holds that one item and no other.
  actor_a="$(jq -r 'select(.type=="agent_finished")|.actor' "$ra/state/events.jsonl")"
  assert_eq "1" "$(grep -c . "$ra/state/session/wake.jsonl" 2>/dev/null || echo 0)" \
    "a $scenario round's end is one wake on the queue, and nothing else is"
  assert_eq "$actor_a round_end" "$(jq -r '"\(.id) \(.reason)"' "$ra/state/session/wake.jsonl" 2>/dev/null)" \
    "under the round's own name"
  if [ "$scenario" = failed ]; then
    assert_matches "$(jq -r .line "$ra/state/session/wake.jsonl" 2>/dev/null)" "^failed: T-Z $actor_a exit [1-9][0-9]*" \
      "a failed round wakes firstmate saying it failed"
  else
    assert_matches "$(jq -r .line "$ra/state/session/wake.jsonl" 2>/dev/null)" "^(finished: T-Z $actor_a ok|failed: T-Z $actor_a exit [0-9]+)" \
      "a round's wake names its task and itself"
  fi
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
ends="$(grep -c . <<<"$(jq -r 'select(.type=="agent_finished")|.type' "$rk/state/events.jsonl")" || true)"
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
assert_eq "1" "$(grep -c . <<<"$(jq -r 'select(.type=="agent_finished")|.type' "$rl/state/events.jsonl")" || true)" \
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
assert_fail "grep -qE '\\b(git|gh)\\b' <<<\"\$(grep -vE '^[[:space:]]*#' '$ROOT/bin/adapters/mock.sh')\"" \
  "the mock adapter calls no git and no gh"
rm -rf "$d3"


cd "$ROOT" || exit 1
PATH="$suite_original_path"; export PATH
safe_rm_rf "$suite_tools"
finish
