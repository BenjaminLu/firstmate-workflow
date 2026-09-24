#!/usr/bin/env bash
# Reconciling after a crash. Every fixture is a temp directory with a log, a
# recorded `gh pr list` and some files on disk - no network,
# and no assumption about the machine the suite runs on.
#
# Several fixtures below exist to make ONE section's repair the input to the
# next section's decision. A suite where every fixture triggers exactly one
# repair is green and blind: it cannot see a run that repairs a merge and then
# redispatches the task it just declared merged.
set -uo pipefail
# A live managed worker exports FM_RUN_DIR / FM_ENTRY_* / FM_WORKER_TASK_LOCK_FD
# and Herdr pane ids into this shell. Suites must not inherit them or freeze,
# identity, locks and pushes bind to the outer run instead of the fixture.
for _fm_k in $(env | sed -E -n 's/^(FM_[^=]*|HERDR_[^=]*)=.*$/\1/p'); do
  unset "$_fm_k" || true
done
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=tests/lib.sh
. "$ROOT/tests/lib.sh"

RC="$ROOT/bin/fm-reconcile.sh"

fixture() {
  local d; d="$(mktemp -d)"; mkdir -p "$d/bin" "$d/state/worktrees"
  cp "$ROOT/bin/fm-emit.sh" "$d/bin/"
  cp "$RC" "$d/bin/"
  printf '%s' "$d"
}

# a gh that replays one recorded `pr list` payload; one directory per recording
rec() { local dir="$1/gh-$2"; mkdir -p "$dir"
  { printf '#!/usr/bin/env bash\ncat <<'\''JSON'\''\n'; cat; printf 'JSON\n'; } > "$dir/gh"
  chmod +x "$dir/gh"; printf '%s' "$dir/gh"; }

none() { rec "$1" none <<'J'
[]
J
}

# a worker that records how it was called and then stays alive, so the run
# after this one sees a pid that answers
worker_stub() {
  printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$*" >> "%s/worker-args"\nexec sleep 30\n' "$1" \
    > "$1/bin/fm-worker.sh"
  chmod +x "$1/bin/fm-worker.sh"
}
# fm-cleanup.sh is the one script allowed to delete a worktree, and it has its
# own suite. Here it only has to record that it was asked, and for which task -
# the real one needs a git repository with the worktree registered in it.
cleanup_stub() {
  printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$*" >> "%s/cleanup-args"\nrm -rf "%s/state/worktrees/$2"\n' \
    "$1" "$1" > "$1/bin/fm-cleanup.sh"
  chmod +x "$1/bin/fm-cleanup.sh"
}

# a pid that is certainly nobody: started, reaped, and never reused in the
# handful of milliseconds this suite needs
dead_pid() { local p; ( exec true ) & p=$!; wait "$p" 2>/dev/null; printf '%s' "$p"; }
# and its opposite: a process that is really running, so that `kill -0` says
# yes for as long as the fixture needs it to. The caller kills it.
#
# It sets LIVE rather than printing, because `$!` inside `$( )` is the pid of
# a child of the command substitution's own subshell and does not outlive it:
# the fixture gets a number that is already nobody, and every assertion about
# a live worker quietly becomes an assertion about a dead one. Both fixtures
# below still went green on the wrong pid until this was measured.
live_pid() { ( exec sleep 30 ) & LIVE=$!; }
# reaped here rather than asynchronously, so the shell does not print
# "Terminated" into the middle of the suite's transcript
kill_live() { { kill "$LIVE"; wait "$LIVE"; } 2>/dev/null; return 0; }
# reconcile starts the replacement worker detached and exits; the file it
# writes therefore appears a moment after the run returns.
# A positive wait is for the real condition, against a deadline wide enough
# for a loaded machine. It used to be a count of short sleeps, and under the
# gate's parallel pool the count could run out before a worker that really
# was started had written anything. Waiting longer costs nothing when the
# condition comes true: the loop returns the moment it does.
WAIT_SECS=60
eventually() {   # eventually <command...>: 0 once the command is, 1 at the deadline
  local end=$(( $(date +%s) + WAIT_SECS ))
  until "$@"; do [ "$(date +%s)" -le "$end" ] || return 1; sleep 0.05; done
}
wait_for() { eventually test -s "$1"; }
# The negative form, and the reason it is not `test -e`. At the instant
# fm-reconcile.sh returns, a worker it really did start has not been scheduled
# yet - measured absent 5 times out of 5 - so `assert_fail "test -e ..."`
# passes on timing rather than on behaviour. A negative assertion about a
# detached child has to give the child the same window the positive one gives
# it, and only call absence a fact afterwards.
# The window is wall clock, not a count of sleeps: a count stretches or
# shrinks with the machine, and under the gate's parallel pool a worker that
# really was started could miss a two-second window and pass the check
# falsely. Five seconds, never less: the deadline is whole seconds read with
# `-le`, so the loop only gives up once more than WINDOW_SECS have passed.
WINDOW_SECS=5
appears() {
  local end=$(( $(date +%s) + WINDOW_SECS ))
  until [ -e "$1" ]; do [ "$(date +%s)" -le "$end" ] || return 1; sleep 0.1; done
}
kill_pidfile() { [ -f "$1" ] && kill "$(cat "$1")" 2>/dev/null; return 0; }

lines() { wc -l < "$1" | tr -d ' '; }

echo "  replay"
# ---------------------------------------------------------------------------
# The whole state comes out of the log. The fixture has nothing else in
# state/ for it to read, and must still have nothing else there afterwards.
d="$(fixture)"
cat > "$d/state/events.jsonl" <<'J'
{"ts":"2026-09-20T10:00:00Z","actor":"firstmate","type":"greenlit","task":"T-004"}
{"ts":"2026-09-20T10:01:00Z","actor":"firstmate","type":"dispatched","task":"T-004"}
{"ts":"2026-09-20T10:02:00Z","actor":"worker-1","type":"pr_opened","task":"T-004","pr":8}
{"ts":"2026-09-20T10:03:00Z","actor":"github","type":"merged","task":"T-004","pr":8}
{"ts":"2026-09-20T10:04:00Z","actor":"firstmate","type":"dispatched","task":"T-006"}
{"ts":"2026-09-20T10:05:00Z","actor":"worker-2","type":"pr_opened","task":"T-006","pr":9}
J
out="$(FM_ROOT="$d" FM_GH="$(none "$d")" "$d/bin/fm-reconcile.sh" --repo "$d" 2>&1)"
rc=$?
assert_eq "0" "$rc" "a reconcile of a healthy tree exits 0"
assert_contains "$out" "replayed 6 events" "it says how much log it replayed"
assert_contains "$out" "into 2 tasks" "and how many tasks came out of it"
assert_contains "$out" "no snapshot" "and that it used no snapshot"
assert_matches "$out" "T-004 +merged +#8" "T-004 is rebuilt as merged on #8"
assert_matches "$out" "T-006 +pr_opened +#9" "T-006 is rebuilt as open on #9"
assert_contains "$out" "nothing to reconcile" "a healthy tree needs no repair"
assert_eq "$d/state/events.jsonl" "$(find "$d/state" -maxdepth 1 -type f)" \
  "the log is the only file in state/ - it wrote no snapshot beside it"
rm -rf "$d"

echo "  a merged pull request whose event carried no task"
# ---------------------------------------------------------------------------
# The shape that left four finished tasks reading as work in flight: the
# merge is in the log, but without a task nothing downstream can use it.
d="$(fixture)"
cat > "$d/state/events.jsonl" <<'J'
{"ts":"2026-09-20T10:00:00Z","actor":"firstmate","type":"dispatched","task":"T-017"}
{"ts":"2026-09-20T11:00:00Z","actor":"github","type":"merged","pr":36}
J
G="$(rec "$d" prs <<'J'
[{"number":36,"state":"MERGED","title":"T-017: reconcile","headRefName":"t-017-fm-reconcile-sh-reconciling"},
 {"number":40,"state":"OPEN","title":"T-021: something new","headRefName":"t-021-something-new"}]
J
)"
out="$(FM_ROOT="$d" FM_GH="$G" "$d/bin/fm-reconcile.sh" --repo "$d" 2>&1)"
log="$d/state/events.jsonl"
assert_contains "$out" "#36" "it names the pull request it repaired"
assert_contains "$out" "t-017-fm-reconcile-sh-reconciling" "and the branch it read the task from"
assert_eq "T-017" "$(jq -r 'select(.type=="merged" and .pr==36)|.task // empty' "$log")" \
  "the merge now carries the task, recovered from the branch name"
assert_eq "reconcile" "$(jq -r 'select(.type=="merged" and .pr==36 and (.task//"")!="")|.actor' "$log")" \
  "attributed to reconcile, not to github"
assert_ok "jq -e 'select(.pr==36 and (.task//\"\")!=\"\")|.summary[\"zh-TW\"]' '$log' >/dev/null" \
  "the repair carries both languages"
# the orphan on the other side: a pull request the log never heard of at all
assert_eq "T-021" "$(jq -r 'select(.type=="pr_opened" and .pr==40)|.task // empty' "$log")" \
  "a pull request the log never saw is adopted too"

before="$(lines "$log")"
out2="$(FM_ROOT="$d" FM_GH="$G" "$d/bin/fm-reconcile.sh" --repo "$d" 2>&1)"
assert_eq "$before" "$(lines "$log")" "a second run repairs nothing again"
assert_contains "$out2" "nothing to reconcile" "and says so"
rm -rf "$d"

echo "  one run closes the whole gap"
# ---------------------------------------------------------------------------
# Section 2 repairs the merge; sections 3 and 4 must then read the picture
# section 2 has just changed. Reading the fold taken before it means the dead
# pid of a task that merged is a crash, the merged task is redispatched, and
# the worktree is left for a second run to find - three wrong answers from one
# stale picture, and this is the fixture that sees all three.
d="$(fixture)"; worker_stub "$d"; cleanup_stub "$d"
DEAD="$(dead_pid)"
cat > "$d/state/events.jsonl" <<'J'
{"ts":"2026-09-20T10:00:00Z","actor":"firstmate","type":"dispatched","task":"T-004"}
{"ts":"2026-09-20T10:02:00Z","actor":"worker-1","type":"pr_opened","task":"T-004","pr":8}
{"ts":"2026-09-20T10:03:00Z","actor":"github","type":"merged","pr":8}
J
printf '%s\n' "$DEAD" > "$d/state/worktrees/T-004.pid"
mkdir -p "$d/state/worktrees/T-004"
G="$(rec "$d" gap <<'J'
[{"number":8,"state":"MERGED","title":"T-004: the thing","headRefName":"t-004-the-thing"}]
J
)"
# the rehearsal first, and it must reach the same three conclusions - which it
# can only do if the repair amends the fold in memory rather than by re-reading
# a log --dry-run never wrote to
cp "$d/state/events.jsonl" "$d/before.jsonl"
dry="$(FM_ROOT="$d" FM_GH="$G" "$d/bin/fm-reconcile.sh" --repo "$d" --dry-run 2>&1)"
assert_contains "$dry" "would emit merged #8 for T-004" "the rehearsal repairs the taskless merge"
assert_contains "$dry" "would remove the stale pid file for T-004" "and reads the dead pid against that repair"
assert_contains "$dry" "would remove the orphan worktree for T-004" "and the worktree against it too"
assert_lacks "$dry" "worker_crashed" "a task the rehearsal has just declared merged is not a crashed worker"
assert_ok "cmp -s '$d/before.jsonl' '$d/state/events.jsonl'" "and it wrote none of it"

out="$(FM_ROOT="$d" FM_GH="$G" "$d/bin/fm-reconcile.sh" --repo "$d" 2>&1)"
log="$d/state/events.jsonl"
assert_contains "$out" "emit merged #8 for T-004" "the real run repairs the merge"
assert_contains "$out" "remove the stale pid file for T-004" "the dead pid of a task that has now merged is stale, not a crash"
assert_lacks "$out" "worker_crashed" "a task this very run declared merged is not put back in flight"
assert_eq "" "$(jq -r 'select(.type=="worker_crashed")|.task' "$log")" "no crash reaches the log"
assert_eq "" "$(jq -r 'select(.type=="dispatched" and .actor=="reconcile")|.task' "$log")" \
  "and no redispatch either"
assert_fail "appears '$d/worker-args'" "no worker was started"
assert_contains "$out" "orphan worktree for T-004" "the worktree goes in the same run"
assert_contains "$(cat "$d/cleanup-args")" "--task T-004" "through fm-cleanup.sh"
assert_fail "test -e '$d/state/worktrees/T-004.pid'" "and the pid file is consumed"
assert_contains "$out" "3 change(s) applied" "three repairs, all of them in run one"

out2="$(FM_ROOT="$d" FM_GH="$G" "$d/bin/fm-reconcile.sh" --repo "$d" 2>&1)"
assert_contains "$out2" "nothing to reconcile" "the second run finds nothing left over from the first"
assert_eq "1" "$(lines "$d/cleanup-args")" "and cleanup was asked exactly once"
rm -rf "$d"

echo "  a worker whose pid is gone"
# ---------------------------------------------------------------------------
d="$(fixture)"; worker_stub "$d"
DEAD="$(dead_pid)"
cat > "$d/state/events.jsonl" <<'J'
{"ts":"2026-09-20T10:00:00Z","actor":"firstmate","type":"dispatched","task":"T-011"}
{"ts":"2026-09-20T10:02:00Z","actor":"worker-1","type":"pr_opened","task":"T-011","pr":11}
J
printf '%s\n' "$DEAD" > "$d/state/worktrees/T-011.pid"
mkdir -p "$d/state/worktrees/T-011"
out="$(FM_ROOT="$d" FM_GH="$(none "$d")" "$d/bin/fm-reconcile.sh" --repo "$d" 2>&1)"
log="$d/state/events.jsonl"
assert_contains "$out" "T-011 worker_crashed" "it names the dead worker"
assert_contains "$out" "$DEAD" "and the pid that is gone"
assert_contains "$out" "redispatch T-011" "and says it is putting it back to work"
assert_eq "T-011" "$(jq -r 'select(.type=="worker_crashed")|.task' "$log")" "worker_crashed is in the log"
assert_eq "$DEAD" "$(jq -r 'select(.type=="worker_crashed")|.data.pid' "$log")" "carrying the pid it tested"
assert_eq "2" "$(jq -r 'select(.type=="dispatched" and .task=="T-011")|.task' "$log" | wc -l | tr -d ' ')" \
  "and the redispatch is recorded as a dispatch of its own"

assert_ok "wait_for '$d/worker-args'" "the worker really was started"
assert_contains "$(cat "$d/worker-args")" "--task T-011" "on its own task"
assert_contains "$(cat "$d/worker-args")" "--pr 11" "and on the pull request it was in the middle of"
assert_ok "kill -0 \$(cat '$d/state/worktrees/T-011.pid')" "the pid file now points at the live replacement"
# section 3 revived it, so section 4 must not then read its worktree as wreckage
assert_contains "$out" "T-011 has a worktree and a worker still at work in it" \
  "the worktree it was revived into is left alone in the same run"
assert_ok "test -d '$d/state/worktrees/T-011'" "and it is still there"

# idempotence: the replacement is alive, so a second pass has nothing to do
before="$(lines "$log")"
out2="$(FM_ROOT="$d" FM_GH="$(none "$d")" "$d/bin/fm-reconcile.sh" --repo "$d" 2>&1)"
assert_eq "$before" "$(lines "$log")" "a live worker is not crashed a second time"
assert_contains "$out2" "nothing to reconcile" "the second pass is a no-op"
assert_eq "1" "$(wc -l < "$d/worker-args" | tr -d ' ')" "and it did not start a second worker"
kill_pidfile "$d/state/worktrees/T-011.pid"
rm -rf "$d"

echo "  a task that was retried"
# ---------------------------------------------------------------------------
# "Ever seen on a merged or closed event" and "over" are not the same task for
# anything that was retried. T-011's first pull request was closed and its
# second is open with a worker on it; asking the weaker question deletes that
# worker's worktree, and asks nothing about the pid file before doing it.
d="$(fixture)"; worker_stub "$d"; cleanup_stub "$d"
cat > "$d/state/events.jsonl" <<'J'
{"ts":"2026-09-20T10:00:00Z","actor":"firstmate","type":"dispatched","task":"T-011"}
{"ts":"2026-09-20T10:01:00Z","actor":"worker-1","type":"pr_opened","task":"T-011","pr":10}
{"ts":"2026-09-20T10:02:00Z","actor":"github","type":"closed","task":"T-011","pr":10}
{"ts":"2026-09-20T10:03:00Z","actor":"firstmate","type":"dispatched","task":"T-011"}
{"ts":"2026-09-20T10:04:00Z","actor":"worker-2","type":"pr_opened","task":"T-011","pr":11}
J
live_pid; printf '%s\n' "$LIVE" > "$d/state/worktrees/T-011.pid"
mkdir -p "$d/state/worktrees/T-011"
assert_ok "kill -0 $LIVE" "the fixture's worker really is running"
out="$(FM_ROOT="$d" FM_GH="$(none "$d")" "$d/bin/fm-reconcile.sh" --repo "$d" 2>&1)"
assert_matches "$out" "T-011 +pr_opened +#11" "the replay puts the retry on its second pull request"
assert_ok "test -d '$d/state/worktrees/T-011'" "a task that merely closed one pull request keeps its worktree"
assert_fail "test -e '$d/cleanup-args'" "cleanup is never asked for a task that is not over"
assert_contains "$out" "nothing to reconcile" "there was nothing to repair"
kill_live

# the mirror: the same retried task, with a worker that really has died. The
# weaker question wrote this off as tidy-up and never revived it.
DEAD="$(dead_pid)"; printf '%s\n' "$DEAD" > "$d/state/worktrees/T-011.pid"
out="$(FM_ROOT="$d" FM_GH="$(none "$d")" "$d/bin/fm-reconcile.sh" --repo "$d" 2>&1)"
assert_contains "$out" "T-011 worker_crashed" "a retried task whose worker did crash is still a crash"
assert_lacks "$out" "stale pid file" "not a stale pid file to be swept up"
assert_contains "$out" "redispatch T-011" "and it is put back to work"
assert_ok "wait_for '$d/worker-args'" "the worker really was started"
assert_contains "$(cat "$d/worker-args")" "--pr 11" "on the round it died in, not the pull request that closed"
assert_ok "test -d '$d/state/worktrees/T-011'" "and its worktree is left where it is"
kill_pidfile "$d/state/worktrees/T-011.pid"
rm -rf "$d"

echo "  a worktree with a live worker"
# ---------------------------------------------------------------------------
# GitHub and a running worker can disagree - the merge can be of round one
# while the worker is mid-way through round two. That disagreement must not
# resolve in favour of rm -rf, and section 4 asked nothing about the pid file
# at all before handing the directory to cleanup.
d="$(fixture)"; worker_stub "$d"; cleanup_stub "$d"
cat > "$d/state/events.jsonl" <<'J'
{"ts":"2026-09-20T10:00:00Z","actor":"firstmate","type":"dispatched","task":"T-004"}
{"ts":"2026-09-20T10:02:00Z","actor":"worker-1","type":"pr_opened","task":"T-004","pr":8}
{"ts":"2026-09-20T10:03:00Z","actor":"github","type":"merged","task":"T-004","pr":8}
J
live_pid; printf '%s\n' "$LIVE" > "$d/state/worktrees/T-004.pid"
mkdir -p "$d/state/worktrees/T-004"
assert_ok "kill -0 $LIVE" "the fixture's worker really is running"
out="$(FM_ROOT="$d" FM_GH="$(none "$d")" "$d/bin/fm-reconcile.sh" --repo "$d" 2>&1)"
assert_contains "$out" "T-004 has a worktree and a worker still at work in it" \
  "it says whose worktree it is leaving alone"
assert_ok "test -d '$d/state/worktrees/T-004'" "the worktree is still there"
assert_fail "test -e '$d/cleanup-args'" "cleanup was never asked for it"
assert_ok "test -f '$d/state/worktrees/T-004.pid'" "and the live worker's pid file is left alone"
kill_live
rm -rf "$d"

echo "  pid files and worktrees that outlived their task"
# ---------------------------------------------------------------------------
d="$(fixture)"; worker_stub "$d"; cleanup_stub "$d"
DEAD="$(dead_pid)"
cat > "$d/state/events.jsonl" <<'J'
{"ts":"2026-09-20T10:00:00Z","actor":"firstmate","type":"dispatched","task":"T-004"}
{"ts":"2026-09-20T10:02:00Z","actor":"worker-1","type":"pr_opened","task":"T-004","pr":8}
{"ts":"2026-09-20T10:03:00Z","actor":"github","type":"merged","task":"T-004","pr":8}
J
printf '%s\n' "$DEAD" > "$d/state/worktrees/T-004.pid"
mkdir -p "$d/state/worktrees/T-004"
# a pid file whose name is not a task id. The basename becomes --task on an
# event and an argv on a dispatch, so the shape is checked before either.
printf '%s\n' "$DEAD" > "$d/state/worktrees/notatask.pid"
out="$(FM_ROOT="$d" FM_GH="$(none "$d")" "$d/bin/fm-reconcile.sh" --repo "$d" 2>&1)"
log="$d/state/events.jsonl"
assert_contains "$out" "stale pid file for T-004" "a finished task's dead pid is stale, not a crash"
assert_fail "test -e '$d/state/worktrees/T-004.pid'" "and the evidence is consumed"
assert_eq "" "$(jq -r 'select(.type=="worker_crashed")|.task' "$log")" \
  "a task that already merged is never marked crashed"
assert_fail "appears '$d/worker-args'" "nor redispatched"
assert_contains "$out" "notatask.pid is not named after a task" "a pid file that is not a task id is refused"
assert_lacks "$out" "notatask worker_crashed" "and never becomes the task on an event"
assert_ok "test -e '$d/state/worktrees/notatask.pid'" "it is reported rather than deleted"
assert_contains "$out" "orphan worktree for T-004" "the worktree it left behind is an orphan"
assert_contains "$(cat "$d/cleanup-args")" "--task T-004" "removed through fm-cleanup.sh, the one script allowed to delete"
assert_fail "test -d '$d/state/worktrees/T-004'" "and it is gone"

out2="$(FM_ROOT="$d" FM_GH="$(none "$d")" "$d/bin/fm-reconcile.sh" --repo "$d" 2>&1)"
assert_contains "$out2" "nothing to reconcile" "two runs leave the same state"
assert_eq "1" "$(wc -l < "$d/cleanup-args" | tr -d ' ')" "cleanup is not asked twice"
rm -rf "$d"

echo "  a repair that could not be carried out"
# ---------------------------------------------------------------------------
# changes counted intent, not outcome: the pid file was removed before the
# emit, the emit's failure was swallowed, and the run printed the repair as
# applied and exited 0 - with the only evidence of the crash destroyed.
d="$(fixture)"; worker_stub "$d"
DEAD="$(dead_pid)"
printf '{"ts":"2026-09-20T10:00:00Z","actor":"firstmate","type":"dispatched","task":"T-011"}\n' \
  > "$d/state/events.jsonl"
printf '%s\n' "$DEAD" > "$d/state/worktrees/T-011.pid"
printf '#!/usr/bin/env bash\necho "fm-emit: refused" >&2\nexit 1\n' > "$d/bin/fm-emit.sh"
chmod +x "$d/bin/fm-emit.sh"
out="$(FM_ROOT="$d" FM_GH="$(none "$d")" "$d/bin/fm-reconcile.sh" --repo "$d" 2>&1)"
rc=$?
assert_eq "1" "$rc" "a repair that did not happen is not a clean run"
assert_contains "$out" "could not record the crash of T-011" "it says which repair did not happen"
assert_contains "$out" "refused" "and what the writer said about it"
assert_ok "test -f '$d/state/worktrees/T-011.pid'" "the evidence is left for a later run to judge"
assert_contains "$out" "0 change(s) applied" "and the count is of repairs carried out, not of intentions"
assert_contains "$out" "1 repair(s) could not be carried out" "with the failures said out loud"
assert_fail "appears '$d/worker-args'" "nothing is redispatched on the strength of an unrecorded crash"
rm -rf "$d"

echo "  --dry-run"
# ---------------------------------------------------------------------------
# Everything at once, and none of it performed. A repair tool nobody can
# rehearse is a repair tool nobody runs.
d="$(fixture)"; worker_stub "$d"; cleanup_stub "$d"
DEAD="$(dead_pid)"
cat > "$d/state/events.jsonl" <<'J'
{"ts":"2026-09-20T10:00:00Z","actor":"firstmate","type":"dispatched","task":"T-011"}
{"ts":"2026-09-20T10:02:00Z","actor":"worker-1","type":"pr_opened","task":"T-011","pr":11}
{"ts":"2026-09-20T10:03:00Z","actor":"firstmate","type":"dispatched","task":"T-004"}
{"ts":"2026-09-20T10:04:00Z","actor":"github","type":"merged","task":"T-004","pr":8}
{"ts":"2026-09-20T11:00:00Z","actor":"github","type":"merged","pr":36}
J
printf '%s\n' "$DEAD" > "$d/state/worktrees/T-011.pid"
mkdir -p "$d/state/worktrees/T-004"
G="$(rec "$d" dry <<'J'
[{"number":36,"state":"MERGED","title":"T-017: reconcile","headRefName":"t-017-reconcile"}]
J
)"
cp "$d/state/events.jsonl" "$d/before.jsonl"
out="$(FM_ROOT="$d" FM_GH="$G" "$d/bin/fm-reconcile.sh" --repo "$d" --dry-run 2>&1)"
assert_eq "0" "$?" "--dry-run exits 0"
assert_contains "$out" "would" "it says everything in the conditional"
assert_contains "$out" "T-011 worker_crashed" "it would mark the dead worker"
assert_contains "$out" "redispatch T-011" "it would redispatch it"
assert_contains "$out" "#36" "it would repair the taskless merge"
assert_contains "$out" "orphan worktree for T-004" "it would remove the orphan worktree"
assert_contains "$out" "performed none of them" "and it says plainly that it did none of it"

assert_ok "cmp -s '$d/before.jsonl' '$d/state/events.jsonl'" "the log is byte for byte what it was"
assert_ok "test -f '$d/state/worktrees/T-011.pid'" "the pid file is still there"
assert_eq "$DEAD" "$(cat "$d/state/worktrees/T-011.pid")" "still holding the pid it held"
assert_ok "test -d '$d/state/worktrees/T-004'" "the worktree is still there"
assert_fail "appears '$d/worker-args'" "no worker was started"
assert_fail "appears '$d/cleanup-args'" "no worktree was handed to cleanup"
rm -rf "$d"

echo "  when GitHub cannot be reached"
# ---------------------------------------------------------------------------
# Reconciling after a crash is exactly when the network may be the thing that
# broke. The local half must still run.
d="$(fixture)"; worker_stub "$d"
DEAD="$(dead_pid)"
printf '{"ts":"2026-09-20T10:00:00Z","actor":"firstmate","type":"dispatched","task":"T-011"}\n' \
  > "$d/state/events.jsonl"
printf '%s\n' "$DEAD" > "$d/state/worktrees/T-011.pid"
mkdir -p "$d/ghx"; printf '#!/usr/bin/env bash\nexit 1\n' > "$d/ghx/gh"; chmod +x "$d/ghx/gh"
out="$(FM_ROOT="$d" FM_GH="$d/ghx/gh" "$d/bin/fm-reconcile.sh" --repo "$d" 2>&1)"
assert_eq "0" "$?" "it still exits 0"
assert_contains "$out" "could not read pull requests" "it says the GitHub half did not happen"
assert_contains "$out" "T-011 worker_crashed" "and reconciles the local half anyway"
assert_ok "wait_for '$d/worker-args'" "including the redispatch"
kill_pidfile "$d/state/worktrees/T-011.pid"

# and a response that is not a list of pull requests is treated the same way
d2="$(fixture)"
: > "$d2/state/events.jsonl"
JUNK="$(rec "$d2" junk <<'J'
not json at all
J
)"
out="$(FM_ROOT="$d2" FM_GH="$JUNK" "$d2/bin/fm-reconcile.sh" --repo "$d2" 2>&1)"
assert_contains "$out" "could not read pull requests" "junk from gh is not a pull request list"
assert_fail "test -s '$d2/state/events.jsonl'" "and nothing is written on the strength of it"
rm -rf "$d" "$d2"

echo "  arguments and the single writer"
# ---------------------------------------------------------------------------
d="$(fixture)"
assert_fail "FM_ROOT='$d' '$d/bin/fm-reconcile.sh' --repo '$d' --nonsense" "an unknown argument is refused"
assert_fail "FM_ROOT='$d' '$d/bin/fm-reconcile.sh' --repo '$d/nowhere'" "so is a repo that is not there"
# `shift 2` on the last argument consumes nothing and returns non-zero, so a
# flag left dangling spins the parse loop forever. The alarm bounds the test;
# only exit 64 passes, so being killed by the alarm is a real failure.
for flag in --repo --limit; do
  perl -e 'alarm 5; exec @ARGV' "$d/bin/fm-reconcile.sh" "$flag" >/dev/null 2>&1
  assert_eq "64" "$?" "a dangling $flag exits 64 before the alarm"
done
assert_ok "FM_ROOT='$d' FM_GH='$(none "$d")' '$d/bin/fm-reconcile.sh' --repo '$d'" \
  "an empty tree reconciles to nothing rather than failing"
# --limit is how much of GitHub's history the run looks at, so it has to reach
# gh rather than merely be accepted by the parser
mkdir -p "$d/gha"
printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$*" >> "%s/gh-args"\nprintf "[]\\n"\n' "$d" > "$d/gha/gh"
chmod +x "$d/gha/gh"
: > "$d/state/events.jsonl"
FM_ROOT="$d" FM_GH="$d/gha/gh" "$d/bin/fm-reconcile.sh" --repo "$d" --limit 7 >/dev/null 2>&1
assert_contains "$(sed -n 1p "$d/gh-args")" "--limit 7" "the limit it was given reaches gh"
FM_ROOT="$d" FM_GH="$d/gha/gh" "$d/bin/fm-reconcile.sh" --repo "$d" >/dev/null 2>&1
assert_contains "$(sed -n 2p "$d/gh-args")" "--limit 50" "and there is a default when it is not"
rm -rf "$d"

# it goes through the one writer like everyone else; the header comment names
# fm-emit.sh too, so look at what runs. The code is read once and searched
# through a here-string: `producer | grep -q` under pipefail fails when grep
# exits on the match and the producer takes SIGPIPE, which turns the first
# check red on a match and the second green on one.
code_of() { grep -vE '^[[:space:]]*#' "$1" || true; }
writes_through_emit() { grep -q 'fm-emit.sh' <<<"$(code_of "$1")"; }
appends_to_log() { grep -qE '>>.*events\.jsonl' <<<"$(code_of "$1")"; }
assert_ok "writes_through_emit '$RC'" "it writes through fm-emit.sh"
assert_fail "appends_to_log '$RC'" "and never appends to the log itself"
# the mutants: fm-emit.sh named only in comments, and a direct append
m="$(mktemp -d)"
printf '#!/usr/bin/env bash\n# fm-emit.sh\necho x >> "$FM_ROOT/state/log"\n' > "$m/rc"
assert_fail "writes_through_emit '$m/rc'" "fm-emit.sh named only in a comment is not a write through it (mutant)"
printf '#!/usr/bin/env bash\nfm-emit.sh x\necho x >> "$FM_ROOT/state/events.jsonl"\n' > "$m/rc"
assert_ok "appends_to_log '$m/rc'" "a direct append to the log is caught (mutant)"
rm -rf "$m"

# The sweep, kept: no pipeline in this suite or ci.test.sh feeds grep -q or
# -c. Comments are skipped, and so are printf lines that plant a script for
# ci.sh's own lint to catch - those quote the shape on purpose.
piped_greps() {
  local hits
  hits="$(grep -HnE '\|[[:space:]]*grep[[:space:]]+-[a-zA-Z]*[qc]' "$@" || true)"
  grep -vE "^[^:]*:[0-9]+:[[:space:]]*(#|printf '.*\\\\n')" <<<"$hits" || true
}
assert_eq "" "$(piped_greps "$ROOT/tests/reconcile.test.sh" "$ROOT/tests/ci.test.sh")" \
  "no pipeline in reconcile.test.sh or ci.test.sh feeds grep -q or -c"
m="$(mktemp -d)"
p='|'   # built, so these lines do not trip the sweep above
cat > "$m/t.sh" <<SH
# x $p grep -q y
printf '#!/usr/bin/env bash\\nx $p grep -q y\\n' > f
x $p grep -qE y
x ${p}grep -c y
SH
assert_eq "$m/t.sh:3:x $p grep -qE y
$m/t.sh:4:x ${p}grep -c y" "$(piped_greps "$m/t.sh")" \
  "the sweep flags a live pipe into grep -q or -c and skips comments and planted fixtures (mutant)"
rm -rf "$m"

# Regression fixtures for the complete round-three criteria.
echo "  corrupt replay cannot authorize mutations"
for corrupt in '{"type":' 'not-json'; do
  d="$(fixture)"; cleanup_stub "$d"; worker_stub "$d"
  mkdir "$d/state/worktrees/T-004"
  printf '{"type":"merged","task":"T-004","pr":8}\n%s\n' "$corrupt" > "$d/state/events.jsonl"
  cp "$d/state/events.jsonl" "$d/before"
  out="$(FM_ROOT="$d" FM_GH="$(none "$d")" "$d/bin/fm-reconcile.sh" 2>&1)"; rc=$?
  assert_eq 1 "$rc" "corrupt replay fails"
  assert_ok "cmp '$d/before' '$d/state/events.jsonl'" "corrupt log remains untouched"
  assert_ok "test -d '$d/state/worktrees/T-004'" "partial replay cannot delete a worktree"
  rm -rf "$d"
done

echo "  ancillary events and attempt boundaries"
d="$(fixture)"
printf '%s\n' '{"type":"merged","task":"T-004","pr":8}' '{"type":"decision_made","task":"T-004"}' '{"type":"closed","task":"T-011","pr":10}' '{"type":"dispatched","task":"T-011"}' > "$d/state/events.jsonl"
out="$(FM_ROOT="$d" FM_GH="$(none "$d")" "$d/bin/fm-reconcile.sh" 2>&1)"
assert_matches "$out" 'T-004 +merged +#8' "ancillary event preserves completion"
assert_lacks "$out" '#10' "a fresh dispatch forgets the old PR"
worker_stub "$d"
echo "$(dead_pid)" > "$d/state/worktrees/T-011.pid"
G="$(rec "$d" older <<'J'
[{"number":10,"state":"CLOSED","title":"old","headRefName":"t-011-old"}]
J
)"
out="$(FM_ROOT="$d" FM_GH="$G" "$d/bin/fm-reconcile.sh" 2>&1)"
assert_ok "wait_for '$d/worker-args'" "a fresh attempt is recovered"
assert_lacks "$(cat "$d/worker-args" 2>/dev/null)" '--pr' "a fresh attempt never resumes the old PR"
kill_pidfile "$d/state/worktrees/T-011.pid"
rm -rf "$d"

echo "  historical repairs in either response order"
for order in forward reverse; do
  d="$(fixture)"; worker_stub "$d"; cleanup_stub "$d"
  printf '%s\n' '{"type":"pr_opened","task":"T-011","pr":10}' '{"type":"closed","pr":10}' '{"type":"dispatched","task":"T-011"}' '{"type":"pr_opened","task":"T-011","pr":11}' > "$d/state/events.jsonl"
  DEAD="$(dead_pid)"; echo "$DEAD" > "$d/state/worktrees/T-011.pid"
  mkdir "$d/state/worktrees/T-011"
  payload='[{"number":10,"state":"CLOSED","title":"old","headRefName":"t-011-old"},{"number":11,"state":"OPEN","title":"new","headRefName":"t-011-new"}]'
  [ "$order" = forward ] || payload="$(jq 'reverse' <<< "$payload")"
  G="$(rec "$d" history <<< "$payload")"
  out="$(FM_ROOT="$d" FM_GH="$G" "$d/bin/fm-reconcile.sh" 2>&1)"
  assert_ok "wait_for '$d/worker-args'" "historical closure does not suppress recovery ($order)"
  assert_contains "$(cat "$d/worker-args" 2>/dev/null)" '--pr 11' "recovery uses current attempt"
  assert_ok "test -d '$d/state/worktrees/T-011'" "historical repair cannot authorize cleanup"
  out="$(FM_ROOT="$d" FM_GH="$G" "$d/bin/fm-reconcile.sh" 2>&1)"
  assert_matches "$out" 'T-011 +dispatched +#11' "replay ignores historical repair"
  kill_pidfile "$d/state/worktrees/T-011.pid"; rm -rf "$d"
done

echo "  attempt boundaries survive offline recovery across runs"
for terminal in CLOSED MERGED; do
  for repair in missing taskless taskless-only; do
    for boundary in missing-worker pid-write; do
      for order in forward reverse; do
        d="$(fixture)"; cleanup_stub "$d"
        : > "$d/state/events.jsonl"
        if [ "$repair" != taskless-only ]; then
          echo '{"type":"pr_opened","task":"T-011","pr":10}' >> "$d/state/events.jsonl"
        fi
        if [ "$repair" != missing ]; then
          jq -cn --arg type "$(tr '[:upper:]' '[:lower:]' <<< "$terminal")" '{type:$type,pr:10}' >> "$d/state/events.jsonl"
        fi
        echo '{"type":"dispatched","task":"T-011"}' >> "$d/state/events.jsonl"
        DEAD="$(dead_pid)"; echo "$DEAD" > "$d/state/worktrees/T-011.pid"
        mkdir "$d/state/worktrees/T-011"
        if [ "$boundary" = pid-write ]; then
          worker_stub "$d"; mkdir "$d/state/worktrees/T-011.pid.next"
        fi
        OFFLINE="$(rec "$d" offline <<< 'offline')"
        out="$(FM_ROOT="$d" FM_GH="$OFFLINE" "$d/bin/fm-reconcile.sh" 2>&1)"; rc=$?
        label="$terminal/$repair/$boundary/$order"
        assert_eq 1 "$rc" "offline recovery stops durably ($label)"
        assert_ok "jq -se 'any(.[]; .type==\"worker_crashed\" and .task==\"T-011\" and .pr==null)' '$d/state/events.jsonl'" "fresh crash has no old PR ($label)"
        worker_stub "$d"
        [ "$boundary" != pid-write ] || rmdir "$d/state/worktrees/T-011.pid.next"
        payload="$(jq -cn --arg state "$terminal" '[{number:10,state:$state,title:"old",headRefName:"t-011-old"},{number:12,state:"CLOSED",title:"other",headRefName:"t-012-other"}]')"
        [ "$order" = forward ] || payload="$(jq 'reverse' <<< "$payload")"
        G="$(rec "$d" retry <<< "$payload")"
        cp "$d/state/events.jsonl" "$d/before"
        dry="$(FM_ROOT="$d" FM_GH="$G" "$d/bin/fm-reconcile.sh" --dry-run 2>&1)"
        assert_contains "$dry" 'would redispatch T-011' "dry retry preserves fresh attempt ($label)"
        assert_lacks "$dry" 'orphan worktree for T-011' "dry retry cannot clean fresh worktree ($label)"
        assert_ok "cmp -s '$d/before' '$d/state/events.jsonl'" "dry retry leaves log unchanged ($label)"
        assert_eq "$DEAD" "$(cat "$d/state/worktrees/T-011.pid")" "dry retry leaves PID unchanged ($label)"
        out="$(FM_ROOT="$d" FM_GH="$G" "$d/bin/fm-reconcile.sh" 2>&1)"
        assert_eq 0 "$?" "online retry succeeds ($label)"
        assert_ok "wait_for '$d/worker-args'" "online retry replaces fresh worker ($label)"
        assert_lacks "$(cat "$d/worker-args" 2>/dev/null)" '--pr' "replacement never receives historical PR ($label)"
        assert_ok "test -d '$d/state/worktrees/T-011'" "online retry preserves fresh worktree ($label)"
        assert_ok "jq -se 'any(.[]; .task==\"T-011\" and .pr==10 and .data.historical==true)' '$d/state/events.jsonl'" "old terminal repair is durably historical ($label)"
        cp "$d/state/events.jsonl" "$d/before"
        out="$(FM_ROOT="$d" FM_GH="$G" "$d/bin/fm-reconcile.sh" 2>&1)"
        assert_ok "cmp -s '$d/before' '$d/state/events.jsonl'" "repaired replay is idempotent ($label)"
        # A newly discovered PR belongs to this attempt and must still end it.
        kill_pidfile "$d/state/worktrees/T-011.pid"
        dead_pid > "$d/state/worktrees/T-011.pid"
        G="$(rec "$d" current <<< "$(jq -cn --arg state "$terminal" '[{number:11,state:$state,title:"current",headRefName:"t-011-current"}]')")"
        out="$(FM_ROOT="$d" FM_GH="$G" "$d/bin/fm-reconcile.sh" 2>&1)"
        assert_eq 0 "$?" "genuine current terminal succeeds ($label)"
        assert_fail "test -d '$d/state/worktrees/T-011'" "genuine current terminal cleans worktree ($label)"
        assert_fail "test -f '$d/state/worktrees/T-011.pid'" "genuine current terminal removes stale PID ($label)"
        kill_pidfile "$d/state/worktrees/T-011.pid"; rm -rf "$d"
      done
    done
  done
done

echo "  recovery dispatch does not retire current-attempt PR evidence"
for terminal in CLOSED MERGED; do
  for association in taskless explicit; do
    d="$(fixture)"; cleanup_stub "$d"; worker_stub "$d"
    type="$(tr '[:upper:]' '[:lower:]' <<< "$terminal")"
    if [ "$association" = taskless ]; then
      printf '%s\n' '{"type":"dispatched","task":"T-011"}' > "$d/state/events.jsonl"
      jq -cn --arg type "$type" '{type:$type,pr:10}' >> "$d/state/events.jsonl"
    else
      # Explicitly continuing an old PR keeps it current across the boundary.
      printf '%s\n' '{"type":"pr_opened","task":"T-011","pr":10}' '{"type":"dispatched","task":"T-011","pr":10}' > "$d/state/events.jsonl"
    fi
    dead_pid > "$d/state/worktrees/T-011.pid"
    mkdir "$d/state/worktrees/T-011" "$d/state/worktrees/T-011.pid.next"
    out="$(FM_ROOT="$d" FM_GH="$(none "$d")" "$d/bin/fm-reconcile.sh" 2>&1)"
    assert_eq 1 "$?" "current PR survives failed recovery ($terminal/$association)"
    rmdir "$d/state/worktrees/T-011.pid.next"
    G="$(rec "$d" current <<< "$(jq -cn --arg state "$terminal" '[{number:10,state:$state,title:"current",headRefName:"t-011-current"}]')")"
    out="$(FM_ROOT="$d" FM_GH="$G" "$d/bin/fm-reconcile.sh" 2>&1)"
    assert_eq 0 "$?" "current PR terminal retry succeeds ($terminal/$association)"
    assert_ok "jq -se 'any(.[]; .task==\"T-011\" and .type==\"$type\" and .data.historical==false)' '$d/state/events.jsonl'" "current terminal repair is not historical ($terminal/$association)"
    assert_fail "test -d '$d/state/worktrees/T-011'" "current terminal cleans worktree ($terminal/$association)"
    assert_fail "test -f '$d/state/worktrees/T-011.pid'" "current terminal removes stale PID ($terminal/$association)"
    assert_fail "appears '$d/worker-args'" "current terminal starts no replacement ($terminal/$association)"
    kill_pidfile "$d/state/worktrees/T-011.pid"; rm -rf "$d"
  done
done

echo "  real worker preserves no-PR boundaries across repeated offline recovery"
# Exercise the production worker/emitter/launcher together. Only repository
# operations are simulated: stop worktree creation before PR discovery, without
# inventing the worker's dispatched event or passing --pr to it.
for terminal in CLOSED MERGED; do
  for timing in historical current new-attempt; do
    d="$(fixture)"; cleanup_stub "$d"
    cp "$ROOT/bin/fm-worker.sh" "$ROOT/bin/fm-config.sh" "$ROOT/bin/fm-herdr.py" "$d/bin/"
    # T-036 checkpoint + guard are launch-adjacent deps when present on the tip.
    [ -f "$ROOT/bin/fm-checkpoint.sh" ] && cp "$ROOT/bin/fm-checkpoint.sh" "$d/bin/"
    [ -f "$ROOT/bin/fm-guard.sh" ] && cp "$ROOT/bin/fm-guard.sh" "$d/bin/"
    mkdir -p "$d/design/tasks" "$d/stub" "$d/state/worktrees/T-011"
    echo '{"id":"T-011","title":"test","scope":[]}' > "$d/design/tasks/T-011.json"
    cat > "$d/stub/git" <<'SH'
#!/usr/bin/env bash
case "$*" in
  'worktree add '*)
    # Do not let this controlled subprocess retain the worker's lock.
    exec 9>&-
    touch "$FM_ROOT/ready"
    while [ ! -f "$FM_ROOT/release" ]; do sleep 0.05; done
    exit 1;;
  'show-ref '*|'ls-remote '*) exit 1;;
esac
SH
    chmod +x "$d/stub/git"
    type="$(tr '[:upper:]' '[:lower:]' <<< "$terminal")"
    : > "$d/state/events.jsonl"
    [ "$timing" = historical ] || echo '{"type":"dispatched","task":"T-011"}' >> "$d/state/events.jsonl"
    jq -cn --arg type "$type" '{type:$type,pr:10}' >> "$d/state/events.jsonl"
    [ "$timing" != historical ] || echo '{"type":"dispatched","task":"T-011"}' >> "$d/state/events.jsonl"
    for round in 1 2; do
      dead_pid > "$d/state/worktrees/T-011.pid"
      rm -f "$d/ready" "$d/release"
      out="$(PATH="$d/stub:$PATH" FM_ROOT="$d" FM_GH="$(rec "$d" offline <<< offline)" "$d/bin/fm-reconcile.sh" 2>&1)"
      assert_eq 0 "$?" "real offline launch succeeds ($terminal/$timing/$round)"
      eventually test -f "$d/ready"
      assert_ok "test -f '$d/ready'" "real worker reaches pre-association crash point"
      assert_ok "jq -se 'last(.[]|select(.type==\"dispatched\"))|.data.recovery==true and .pr==null and .data.role==\"worker\"' '$d/state/events.jsonl'" "real no-PR dispatch is recovery"
      PATH="$d/stub:$PATH" FM_ROOT="$d" "$d/bin/fm-worker.sh" --task T-011 > "$d/duplicate" 2>&1
      assert_eq 70 "$?" "inherited lock rejects ordinary overlapping worker"
      PATH="$d/stub:$PATH" FM_ROOT="$d" FM_GH="$(none "$d")" "$d/bin/fm-reconcile.sh" > "$d/live" 2>&1
      assert_lacks "$(cat "$d/live")" 'redispatch T-011' "live real replacement is not duplicated"
      touch "$d/release"
      # One EXIT trap → one agent_finished per failed real worker. Reconcile's
      # own ending uses actor=reconcile and is excluded. Do not expect a
      # double-count from a second process that freeze/exec no longer leaves.
      ended() {
        count="$(jq -s '[.[]|select(.type=="agent_finished" and .actor!="reconcile")]|length' "$d/state/events.jsonl")"
        [ "$count" -ge "$round" ]
      }
      eventually ended
      assert_eq "$round" "$count" "real failed worker records its ending"
    done
    if [ "$timing" = new-attempt ]; then
      # A genuinely new ordinary run must still move the boundary. A stale
      # ancestor environment is not the same-PID recovery handoff.
      FM_WORKER_LOCK_PID="$$" PATH="$d/stub:$PATH" FM_ROOT="$d" "$d/bin/fm-worker.sh" --task T-011 > "$d/ordinary" 2>&1
      assert_eq 70 "$?" "ordinary new attempt reaches controlled worktree failure"
      assert_ok "jq -se 'last(.[]|select(.type==\"dispatched\"))|(.data.recovery // false)==false and .pr==null' '$d/state/events.jsonl'" "ordinary no-PR run establishes a new boundary"
    fi
    dead_pid > "$d/state/worktrees/T-011.pid"
    mkdir -p "$d/state/worktrees/T-011"
    G="$(rec "$d" online <<< "$(jq -cn --arg state "$terminal" '[{number:10,state:$state,title:"terminal",headRefName:"t-011-test"}]')")"
    cp "$d/state/events.jsonl" "$d/before"
    out="$(FM_ROOT="$d" FM_GH="$G" "$d/bin/fm-reconcile.sh" --dry-run 2>&1)"
    assert_ok "cmp -s '$d/before' '$d/state/events.jsonl'" "real recovery dry run preserves log"
    # Prevent any later work while observing the online terminal decision.
    worker_stub "$d"
    out="$(FM_ROOT="$d" FM_GH="$G" "$d/bin/fm-reconcile.sh" 2>&1)"
    assert_eq 0 "$?" "online terminal decision succeeds"
    if [ "$timing" = current ]; then
      assert_fail "test -d '$d/state/worktrees/T-011'" "current taskless terminal still cleans after real recoveries"
      assert_fail "test -e '$d/state/worktrees/T-011.pid'" "current terminal retires PID"
      assert_fail "appears '$d/worker-args'" "completed work is never rerun"
    else
      assert_ok "wait_for '$d/worker-args'" "historical terminal permits recovery"
      assert_ok "test -d '$d/state/worktrees/T-011'" "historical terminal protects worktree"
      assert_ok "jq -se 'any(.[]; .pr==10 and .data.historical==true)' '$d/state/events.jsonl'" "old terminal remains historical"
    fi
    kill_pidfile "$d/state/worktrees/T-011.pid"
    rm -rf "$d"
  done
done

echo "  failed recovery remains retryable"
for boundary in missing-worker dispatch-refused pid-write; do
  d="$(fixture)"; worker_stub "$d"
  printf '%s\n' '{"type":"pr_opened","task":"T-011","pr":11}' > "$d/state/events.jsonl"
  DEAD="$(dead_pid)"; echo "$DEAD" > "$d/state/worktrees/T-011.pid"
  cp "$d/bin/fm-emit.sh" "$d/bin/real-emit"
  case "$boundary" in
    missing-worker) mv "$d/bin/fm-worker.sh" "$d/bin/worker.saved" ;;
    dispatch-refused)
      cat > "$d/bin/fm-emit.sh" <<'SH'
#!/usr/bin/env bash
case " $* " in *" --type dispatched "*) exit 1;; esac
exec "$FM_ROOT/bin/real-emit" "$@"
SH
      ;;
    pid-write) mkdir "$d/state/worktrees/T-011.pid.next" ;;
  esac
  out="$(FM_ROOT="$d" FM_GH="$(none "$d")" "$d/bin/fm-reconcile.sh" 2>&1)"; rc=$?
  assert_eq 1 "$rc" "failed $boundary is reported"
  assert_eq "$DEAD" "$(cat "$d/state/worktrees/T-011.pid" 2>/dev/null)" "failed recovery retains evidence"
  case "$boundary" in
    missing-worker) mv "$d/bin/worker.saved" "$d/bin/fm-worker.sh" ;;
    dispatch-refused) cp "$d/bin/real-emit" "$d/bin/fm-emit.sh" ;;
    pid-write) rmdir "$d/state/worktrees/T-011.pid.next" ;;
  esac
  out="$(FM_ROOT="$d" FM_GH="$(none "$d")" "$d/bin/fm-reconcile.sh" 2>&1)"
  assert_ok "wait_for '$d/worker-args'" "rerun recovers $boundary"
  out="$(FM_ROOT="$d" FM_GH="$(none "$d")" "$d/bin/fm-reconcile.sh" 2>&1)"
  assert_eq 1 "$(lines "$d/worker-args")" "rerun starts exactly one replacement"
  assert_ok "jq -se 'any(.[]; .type==\"agent_finished\" and .data.exit_code==1)' '$d/state/events.jsonl'" "failed run reports lifecycle ending"
  kill_pidfile "$d/state/worktrees/T-011.pid"; rm -rf "$d"
done

echo "  malformed PID evidence is preserved"
for malformed in '' 0 01 -12 '1x2' '12 34' $'12\n34' $'12\n\n' 999999999999999999999; do
  d="$(fixture)"; worker_stub "$d"
  printf '%s\n' "$malformed" > "$d/state/worktrees/T-011.pid"
  cp "$d/state/worktrees/T-011.pid" "$d/before-pid"
  out="$(FM_ROOT="$d" FM_GH="$(none "$d")" "$d/bin/fm-reconcile.sh" 2>&1)"; rc=$?
  assert_eq 1 "$rc" "invalid PID is reported as failure"
  assert_ok "cmp '$d/before-pid' '$d/state/worktrees/T-011.pid'" "invalid evidence is preserved"
  rm -rf "$d"
done

echo "  interruptions at durable recovery boundaries"
for boundary in worker_crashed dispatched before-publish after-publish; do
  d="$(fixture)"; worker_stub "$d"
  printf '%s\n' '{"type":"pr_opened","task":"T-011","pr":11}' > "$d/state/events.jsonl"
  DEAD="$(dead_pid)"; echo "$DEAD" > "$d/state/worktrees/T-011.pid"
  cp "$d/bin/fm-emit.sh" "$d/bin/real-emit"
  if [ "$boundary" = worker_crashed ] || [ "$boundary" = dispatched ]; then
    cat > "$d/bin/fm-emit.sh" <<'SH'
#!/usr/bin/env bash
"$FM_ROOT/bin/real-emit" "$@" || exit $?
case " $* " in
  *" --type $STOP_EVENT "*)
    while [ ! -s "$FM_ROOT/reconciler" ]; do sleep 0.01; done
    kill -TERM "$(cat "$FM_ROOT/reconciler")" ;;
esac
SH
  elif [ "$boundary" = before-publish ]; then
    mkdir "$d/path"
    REAL_PERL="$(command -v perl)"
    export REAL_PERL
    cat > "$d/path/perl" <<'SH'
#!/usr/bin/env bash
case "$*" in
  *Fcntl*)
    touch "$FM_ROOT/spawned"
    while [ ! -f "$FM_ROOT/release" ]; do sleep 0.01; done ;;
esac
exec "$REAL_PERL" "$@"
SH
    chmod +x "$d/path/perl"
  else
    mkdir "$d/path"
    REAL_PERL="$(command -v perl)"; export REAL_PERL
    echo "$DEAD" > "$d/old-pid"
    cat > "$d/path/perl" <<'SH'
#!/usr/bin/env bash
# Stop the reconciler at its first observation of the published replacement.
if [ "$1" = -0777 ] && [ "$(cat "${!#}" 2>/dev/null)" != "$(cat "$FM_ROOT/old-pid")" ]; then
  kill -TERM "$(cat "$FM_ROOT/reconciler")"
fi
exec "$REAL_PERL" "$@"
SH
    chmod +x "$d/path/perl"
  fi
  FM_ROOT="$d" FM_GH="$(none "$d")" STOP_EVENT="$boundary" PATH="$d/path:$PATH" \
    "$d/bin/fm-reconcile.sh" > "$d/output" 2>&1 &
  reconciler=$!; echo "$reconciler" > "$d/reconciler"
  if [ "$boundary" = before-publish ]; then
    assert_ok "eventually test -e '$d/spawned'" "launcher has started before interruption"
    kill -TERM "$reconciler"
  fi
  wait "$reconciler"; rc=$?
  assert_eq 143 "$rc" "interrupted $boundary reports termination"
  cp "$d/bin/real-emit" "$d/bin/fm-emit.sh"
  # A second launcher races the first at the publication boundary. Both use
  # the production lock; only one is allowed to exec the worker.
  touch "$d/release"
  out="$(FM_ROOT="$d" FM_GH="$(none "$d")" "$d/bin/fm-reconcile.sh" 2>&1)"
  assert_ok "wait_for '$d/worker-args'" "rerun recovers interruption at $boundary"
  out="$(FM_ROOT="$d" FM_GH="$(none "$d")" "$d/bin/fm-reconcile.sh" 2>&1)"
  assert_eq 1 "$(lines "$d/worker-args")" "one replacement after $boundary"
  kill_pidfile "$d/state/worktrees/T-011.pid"; rm -rf "$d"
done

echo "  recovery from the log without a PID file"
for event in '{"type":"worker_crashed","task":"T-011","pr":11}' '{"type":"dispatched","task":"T-011","pr":11,"data":{"recovery":true}}'; do
  d="$(fixture)"; worker_stub "$d"
  echo "$event" > "$d/state/events.jsonl"
  out="$(FM_ROOT="$d" FM_GH="$(none "$d")" "$d/bin/fm-reconcile.sh" 2>&1)"
  assert_ok "wait_for '$d/worker-args'" "durable recovery intent resumes without PID evidence"
  assert_contains "$(cat "$d/worker-args" 2>/dev/null)" '--pr 11' "pending recovery retains its attempt"
  kill_pidfile "$d/state/worktrees/T-011.pid"; rm -rf "$d"
done

echo "  replacement death and lifecycle success"
d="$(fixture)"; worker_stub "$d"
echo '{"type":"dispatched","task":"T-011"}' > "$d/state/events.jsonl"
echo "$(dead_pid)" > "$d/state/worktrees/T-011.pid"
FM_ROOT="$d" FM_GH="$(none "$d")" "$d/bin/fm-reconcile.sh" > "$d/out" 2>&1
assert_ok "wait_for '$d/worker-args'" "first replacement starts"
kill_pidfile "$d/state/worktrees/T-011.pid"
gone() { ! kill -0 "$(cat "$d/state/worktrees/T-011.pid")" 2>/dev/null; }
eventually gone
FM_ROOT="$d" FM_GH="$(none "$d")" "$d/bin/fm-reconcile.sh" >> "$d/out" 2>&1
two_started() { [ "$(lines "$d/worker-args")" = 2 ]; }
eventually two_started
assert_eq 2 "$(lines "$d/worker-args")" "death of replacement is recovered"
assert_eq 2 "$(jq -s '[.[]|select(.type=="agent_finished" and .data.exit_code==0)]|length' "$d/state/events.jsonl")" "successful repairs each report an ending"
kill_pidfile "$d/state/worktrees/T-011.pid"; rm -rf "$d"

echo "  removal failure does not authorize cleanup"
d="$(fixture)"; cleanup_stub "$d"
echo '{"type":"merged","task":"T-004","pr":8}' > "$d/state/events.jsonl"
echo "$(dead_pid)" > "$d/state/worktrees/T-004.pid"
mkdir "$d/state/worktrees/T-004" "$d/path"
cat > "$d/path/rm" <<'SH'
#!/usr/bin/env bash
case "$*" in *T-004.pid*) exit 1;; esac
exec /bin/rm "$@"
SH
chmod +x "$d/path/rm"
out="$(FM_ROOT="$d" FM_GH="$(none "$d")" PATH="$d/path:$PATH" "$d/bin/fm-reconcile.sh" 2>&1)"; rc=$?
assert_eq 1 "$rc" "PID removal failure is reported"
assert_contains "$out" '0 change(s) applied' "failed removal is not counted as applied"
assert_ok "test -f '$d/state/worktrees/T-004.pid'" "failed removal preserves evidence"
assert_ok "test -d '$d/state/worktrees/T-004'" "failed removal preserves worktree"
out="$(FM_ROOT="$d" FM_GH="$(none "$d")" "$d/bin/fm-reconcile.sh" 2>&1)"
assert_fail "test -d '$d/state/worktrees/T-004'" "rerun finishes cleanup"
rm -rf "$d"

echo "  lifecycle writer failure is not hidden"
d="$(fixture)"
cp "$d/bin/fm-emit.sh" "$d/bin/real-emit"
cat > "$d/bin/fm-emit.sh" <<'SH'
#!/usr/bin/env bash
case " $* " in *" --type agent_finished "*) echo 'ending refused' >&2; exit 1;; esac
exec "$FM_ROOT/bin/real-emit" "$@"
SH
G="$(rec "$d" ending <<'J'
[{"number":8,"state":"MERGED","title":"finished","headRefName":"t-004-finished"}]
J
)"
out="$(FM_ROOT="$d" FM_GH="$G" "$d/bin/fm-reconcile.sh" 2>&1)"; rc=$?
assert_eq 1 "$rc" "rejected lifecycle ending fails the run"
assert_contains "$out" 'ending refused' "lifecycle writer error reaches the caller"
rm -rf "$d"

finish
