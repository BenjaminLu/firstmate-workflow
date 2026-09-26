#!/usr/bin/env bash
# A stopped round takes its crew with it (T-107). Killing a round's launcher
# left its engine running: a T-066 worker kept editing to a superseded spec,
# and a T-104 reviewer posted a verdict on a stale head. `fm.sh stop <task>`
# ends every live worker and reviewer run of the task and every process it
# owns - an engine's orphaned child included - and records the stop.
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

fixture() {   # a repo with a remote, a task, a branch to review, and the real scripts
  local d; d="$(mktemp -d)"
  git init -q --bare "$d/remote.git"
  git init -q -b main "$d/repo"
  (
    cd "$d/repo" || exit 1
    git config user.email a@b.c; git config user.name t
    mkdir -p bin design/tasks skills/worker skills/reviewer src state
    cp "$ROOT/bin/fm-config.sh" "$ROOT/bin/fm-emit.sh" "$ROOT/bin/fm-worker.sh" "$ROOT/bin/fm-review.sh" \
       "$ROOT/bin/fm-checkpoint.sh" "$ROOT/bin/fm-guard.sh" "$ROOT/bin/fm-herdr.py" "$ROOT/bin/fm.sh" bin/
    cp -r "$ROOT/bin/adapters" bin/
    cp "$ROOT/skills/worker/SKILL.md" skills/worker/
    cp "$ROOT/skills/reviewer/SKILL.md" skills/reviewer/
    printf 'vendor: mock\n' > config.yaml
    printf 'state/\n' > .gitignore
    jq -n '{id:"T-Z",title:"a mock task",scope:["src/**"],acceptance:["it exists"]}' > design/tasks/T-Z.json
    echo base > src/a
    git add -A; git commit -qm base; git remote add origin "$d/remote.git"; git push -q -u origin main
    # not named t-z-*: the worker would take a branch so named for its own
    git checkout -q -b under-review; echo reviewed > src/a; git commit -qam review
    git push -q origin under-review; git checkout -q main
  ) >/dev/null 2>&1 || return 1
  # One engine for both roles. It says it started, leaves a child of its own
  # and an orphan - a child whose parent has already exited, so no parent
  # link leads to it - and waits; a worker has also begun editing.
  cat > "$d/repo/bin/adapters/mock.sh" <<'M'
#!/usr/bin/env bash
[ "$1" = "run" ] || exit 64
role="${FM_ROLE:-worker}"
[ "$role" = reviewer ] || printf 'half done\n' > "$3/src/editing"
( sleep 300 & echo $! > "$FM_T_DIR/$role.orphan" )
sleep 300 & echo $! > "$FM_T_DIR/$role.child"
echo $$ > "$FM_T_DIR/$role.engine"
: > "$FM_T_DIR/$role.started"
wait
printf 'APPROVE:T-Z\n' > "$3/v.txt"
M
  chmod +x "$d/repo/bin/adapters/mock.sh"
  mkdir -p "$d/stub"
  cat > "$d/stub/gh" <<G
#!/usr/bin/env bash
echo "gh \$*" >> "$d/ghcalls"
if [ "\$1 \$2" = "pr view" ] && [ "\${4-} \${5-}" = "--json comments" ]; then printf '{"comments":[]}\n'; fi
case " \$* " in *" pr list "*) echo null ;; esac
exit 0
G
  chmod +x "$d/stub/gh"
  printf '%s' "$d"
}
eventually() {   # eventually <command...>: 0 once the command is, 1 after 60s
  local end=$(( $(date +%s) + 60 ))
  until "$@"; do [ "$(date +%s)" -le "$end" ] || return 1; sleep 0.05; done
}
alive() {   # alive <pid>: running, not a zombie waiting to be reaped
  local st; st="$(ps -o stat= -p "$1" 2>/dev/null | tr -d ' ')"
  [ -n "$st" ] && case "$st" in Z*) return 1 ;; esac
}
in_group() {   # in_group <pgid>: how many live processes are in the group
  ps -Ao pgid=,stat= 2>/dev/null | awk -v g="$1" '$1 == g && $2 !~ /^Z/' | wc -l | tr -d ' '
}

d="$(fixture)"; r="$d/repo"
# something of the caller's that is no crew's: stop must leave it alone
sleep 300 & bystander=$!
( cd "$r" && FM_ROOT="$r" FM_GH="$d/stub/gh" FM_T_DIR="$d" \
    exec bin/fm-worker.sh --task T-Z --name worker-1 >"$d/worker.out" 2>&1 ) & wp=$!
( cd "$r" && FM_ROOT="$r" FM_GH="$d/stub/gh" FM_T_DIR="$d" \
    exec bin/fm-review.sh --task T-Z --branch under-review --pr 9 --name rev-1 >"$d/review.out" 2>&1 ) & rp=$!
assert_ok "eventually test -e '$d/worker.started'" "(the worker's engine is running)"
assert_ok "eventually test -e '$d/reviewer.started'" "(the reviewer's engine is running)"
crew=''
for role in worker reviewer; do
  for what in engine child orphan; do crew="$crew $(cat "$d/$role.$what" 2>/dev/null)"; done
done
running=0; for p in $wp $rp $crew; do alive "$p" && running=$((running + 1)); done
assert_eq "8" "$running" "(both launchers, their engines, their children and their orphans are alive)"
orphan="$(cat "$d/worker.orphan")"
assert_ne "$(cat "$d/worker.engine")" "$(ps -o ppid= -p "$orphan" | tr -d ' ')" \
  "(the orphan is no child of the engine; only its group leads to it)"
assert_eq "$wp" "$(ps -o pgid= -p "$orphan" | tr -d ' ')" "(the worker run leads the group its orphan is in)"
assert_ne "$(ps -o pgid= -p $$ | tr -d ' ')" "$wp" "(and that is not the caller's group)"

out="$(cd "$r" && FM_STOP_GRACE=10 bin/fm.sh stop T-Z --repo "$r" 2>&1)"; rc=$?
assert_eq "0" "$rc" "fm.sh stop ends the task's crew"
wait "$wp" 2>/dev/null; wait "$rp" 2>/dev/null
left=''; for p in $wp $rp $crew; do alive "$p" && left="$left $p"; done
assert_eq "" "$left" "and no crew process is left alive: launchers, engines, children, orphans"
assert_eq "0" "$(in_group "$wp")" "nothing is left in the worker run's process group"
assert_eq "0" "$(in_group "$rp")" "nor in the reviewer run's"
assert_ok "alive $bystander" "a process of the caller's that is no crew's is left alone"
kill "$bystander" 2>/dev/null; wait "$bystander" 2>/dev/null

# recorded: in each run it stopped, and once for the stop
wrun="$(jq -r 'select(.type=="dispatched")|.actor' "$r/state/events.jsonl" | tail -1)"
rrun="$(jq -r 'select(.type=="review_opened")|.actor' "$r/state/events.jsonl" | tail -1)"
assert_ok "test -f '$r/state/runs/$wrun/stopped.json'" "the worker's run records that it was stopped"
assert_ok "test -f '$r/state/runs/$rrun/stopped.json'" "and so does the reviewer's"
record="$(cat "$r"/state/stops/T-Z-*.json 2>/dev/null)"
assert_contains "$record" "\"$wrun\"" "the stop is recorded under state/stops/, naming the worker"
assert_contains "$record" "\"$rrun\"" "and the reviewer"
assert_eq "[]" "$(jq -c '.remaining' <<<"$record")" "with nothing remaining"
assert_contains "$out" "\"$wrun\"" "and fm.sh stop says whom it stopped"
# the stopped reviewer posted nothing, and the stopped worker published nothing
assert_lacks "$(cat "$d/ghcalls" 2>/dev/null)" "pr comment" "a stopped reviewer posts no verdict"
assert_lacks "$(jq -r .type "$r/state/events.jsonl" | tr '\n' ' ')" "approved" "and no approval is recorded"
assert_fail "git --git-dir='$d/remote.git' rev-parse --verify -q 'refs/heads/t-z-a-mock-task'" \
  "a stopped worker pushes none of its half-done edits"
assert_ok "test -f '$r/state/worktrees/T-Z/src/editing'" "which stay in its worktree for the next round to rescue"
# and both are off the deck
for a in "$wrun" "$rrun"; do
  assert_eq "agent_finished" "$(jq -r --arg a "$a" 'select(.actor==$a)|.type' "$r/state/events.jsonl" | tail -1)" \
    "$a has left the deck"
done

# a task with nothing running is a stop that finds nothing, and says so
out2="$(cd "$r" && bin/fm.sh stop T-Z --repo "$r" 2>&1)"; rc2=$?
assert_eq "0" "$rc2" "stopping a task with no live crew succeeds"
assert_eq "[]" "$(jq -c '.runs' <<<"$out2" 2>/dev/null)" "and stops no run"
out3="$(cd "$r" && bin/fm.sh stop 2>&1)"; rc3=$?
assert_eq "64" "$rc3" "fm.sh stop with no task is a usage error"
assert_contains "$out3" "which task" "and asks which"
rm -rf "$d"

# --- a signal to the caller's process group ends the round too -------------
# Each run leads a group of its own, so a signal sent to the caller's group -
# Ctrl-C at the terminal, a harness or timeout killing the caller - would
# reach the caller and not the round, which ran on and could post. The caller
# here leads its own group, as a job does, and runs the reviewer the way
# fm-run.sh does, in the foreground, and the worker in the background.
group_caller() {   # group_caller <fixture dir> <roles...>; prints the caller's pid, which is its group
  local d="$1" c="$1/caller.sh" role
  shift
  {
    printf '#!/usr/bin/env bash\ncd %q || exit 1\n' "$d/repo"
    printf 'export FM_ROOT=%q FM_GH=%q FM_T_DIR=%q FM_STOP_GRACE=5\n' "$d/repo" "$d/stub/gh" "$d"
    # what the caller's commands inherit for INT: ignored, or not
    printf 'python3 -c %q >%q\n' \
      'import signal; print("ignored" if signal.getsignal(signal.SIGINT) is signal.SIG_IGN else "caught")' \
      "$d/caller.int"
    for role in "$@"; do
      case "$role" in
        worker) printf 'bin/fm-worker.sh --task T-Z --name worker-1 >%q 2>&1 &\n' "$d/worker.out" ;;
        reviewer) printf 'bin/fm-review.sh --task T-Z --branch under-review --pr 9 --name rev-1 >%q 2>&1\n' "$d/review.out" ;;
      esac
    done
    printf 'wait\n'
  } > "$c"
  # This suite starts the caller with `&`, and a non-interactive shell starts
  # every `&` with INT and QUIT ignored, which nothing below can undo. A job a
  # terminal runs in the foreground has neither ignored, so the caller puts
  # both back to their default before it becomes the job.
  python3 -c 'import os, signal, sys
signal.signal(signal.SIGINT, signal.SIG_DFL); signal.signal(signal.SIGQUIT, signal.SIG_DFL)
os.setpgid(0, 0); os.execv("/bin/bash", ["bash", sys.argv[1]])' "$c" \
    </dev/null >/dev/null 2>&1 &
  printf '%s' "$!"
}
crew_of() {   # crew_of <dir> <roles...>: every engine, child and orphan the roles started
  local d="$1" role what; shift
  for role in "$@"; do for what in engine child orphan; do printf ' %s' "$(cat "$d/$role.$what" 2>/dev/null)"; done; done
}
run_pid() {   # run_pid <repo> <event type>: the launcher of the run that wrote it
  local actor; actor="$(jq -r --arg t "$2" 'select(.type==$t)|.actor' "$1/state/events.jsonl" | tail -1)"
  jq -r .pid "$1/state/runs/$actor/process.json" 2>/dev/null
}
none_alive() { local p; for p in "$@"; do alive "$p" && return 1; done; return 0; }
stop_says() { grep -qsF -- "$2" "$1"/state/stops/T-Z-*.json; }   # stop_says <repo> <text>: a stop record says it

for sig in TERM INT; do
  d="$(fixture)"; r="$d/repo"
  # a background `&` ignores INT, as a script's always does, so Ctrl-C is
  # the foreground reviewer's case; a kill of the group is both roles'
  if [ "$sig" = TERM ]; then roles='worker reviewer'; else roles='reviewer'; fi
  # shellcheck disable=SC2086
  cp="$(group_caller "$d" $roles)"
  assert_ok "eventually test -s '$d/caller.int'" "(the $sig-able caller has started)"
  assert_eq "caught" "$(cat "$d/caller.int" 2>/dev/null)" \
    "(the caller's commands do not start with INT ignored, as a terminal's foreground job's do not)"
  for role in $roles; do
    assert_ok "eventually test -e '$d/$role.started'" "(the $role's engine is running under a $sig-able caller)"
  done
  # shellcheck disable=SC2086
  crew="$(crew_of "$d" $roles)"
  launchers=''
  for role in $roles; do
    case "$role" in worker) launchers="$launchers $(run_pid "$r" dispatched)" ;;
                    reviewer) launchers="$launchers $(run_pid "$r" review_opened)" ;; esac
  done
  for p in $launchers; do
    assert_ne "$cp" "$(ps -o pgid= -p "$p" | tr -d ' ')" "(a $sig-signalled run leads its own group, not the caller's)"
  done
  kill -"$sig" -- "-$cp" 2>/dev/null
  # shellcheck disable=SC2086
  assert_ok "eventually none_alive $launchers $crew" \
    "a $sig to the caller's group ends the round: launchers, engines, children, orphans"
  for p in $launchers; do
    assert_eq "0" "$(in_group "$p")" "and nothing is left in the run's group ($sig)"
  done
  assert_lacks "$(cat "$d/ghcalls" 2>/dev/null)" "pr comment" "the reviewer posts no verdict ($sig)"
  assert_lacks "$(jq -r .type "$r/state/events.jsonl" | tr '\n' ' ')" "approved" "and no approval is recorded ($sig)"
  rrun="$(jq -r 'select(.type=="review_opened")|.actor' "$r/state/events.jsonl" | tail -1)"
  assert_ok "test -f '$r/state/runs/$rrun/stopped.json'" "the reviewer's run records that it was stopped ($sig)"
  # stopped.json is written before any signal, so it names the signal by now
  assert_eq "caller-group-SIG$sig" "$(jq -r '.by // empty' "$r/state/runs/$rrun/stopped.json" 2>/dev/null)" \
    "and names the signal the caller's group received ($sig)"
  # the guard writes the record under state/stops/ only once the crew it
  # signalled is gone - after the look above - so it is waited for, not read once
  assert_ok "eventually stop_says '$r' 'caller-group-SIG$sig'" \
    "and the stop is recorded as the caller's group's ($sig)"
  if [ "$sig" = TERM ]; then
    assert_fail "git --git-dir='$d/remote.git' rev-parse --verify -q 'refs/heads/t-z-a-mock-task'" \
      "the worker pushes none of its half-done edits"
    assert_ok "test -f '$r/state/worktrees/T-Z/src/editing'" "which stay in its worktree for the next round"
  fi
  rm -rf "$d"
done

# the same caller left alone: its round runs to the end and posts, so the
# absences above mean nothing without it
d="$(fixture)"; r="$d/repo"
cp="$(group_caller "$d" reviewer)"
assert_ok "eventually test -e '$d/reviewer.started'" "(the undisturbed reviewer's engine is running)"
# let the engine finish on its own: end only what it waits on
kill "$(cat "$d/reviewer.child")" "$(cat "$d/reviewer.orphan")" 2>/dev/null
assert_ok "eventually none_alive $cp" "(the undisturbed caller finishes)"
assert_contains "$(cat "$d/ghcalls" 2>/dev/null)" "pr comment" "an undisturbed round under the same caller posts its verdict"
assert_fail "ls '$r'/state/stops/T-Z-*.json" "and no stop is recorded"
rm -rf "$d"
finish
