#!/usr/bin/env bash
# Runs one task. Creates the worktree, hands the prompt to an adapter, and then
# does every git and gh operation itself - the adapter is never allowed near
# them, which is what lets a CLI with no repository access still be a worker.
#
#   fm-worker.sh --task T-004 [--repo .] [--vendor claude] [--name worker-1]
#   fm-worker.sh --task T-004 --pr 27      a later round: continue the branch
#                                          and read the review already on it
set -uo pipefail
# Nothing below may read standard input. A dispatched child inherits it, and
# a child that reads it blocks the whole turn waiting for a human who is not
# there - the advance loop did exactly this once, and ci.sh has the same
# line for the same reason. One guarantee, in one place.
exec < /dev/null
_fm_lib="$(dirname "${BASH_SOURCE[0]}")/fm-config.sh"
[ -f "$_fm_lib" ] || { echo "${0##*/}: missing $_fm_lib" >&2; exit 70; }
# shellcheck source=bin/fm-config.sh
. "$_fm_lib"
fm_args=("$@")

REPO="$(fm_default_repo)"; TASK=''; VENDOR=''; NAME=''; PR=''
BASE="${FM_BASE:-main}"; GH="${FM_GH:-gh}"
while [ $# -gt 0 ]; do
  case "$1" in
    --task) fm_need "fm-worker" "$@"; TASK="${2-}"; shift 2 ;;
    --repo) fm_need "fm-worker" "$@"; REPO="${2-}"; shift 2 ;;
    --vendor) fm_need "fm-worker" "$@"; VENDOR="${2-}"; shift 2 ;;
    --name) fm_need "fm-worker" "$@"; NAME="${2-}"; shift 2 ;;
    --pr)   fm_need "fm-worker" "$@"; PR="${2-}"; shift 2 ;;
    *) echo "fm-worker: unknown argument $1" >&2; exit 64 ;;
  esac
done
[ -n "$TASK" ] || { echo "usage: fm-worker.sh --task <id> [--repo dir]" >&2; exit 64; }
cd "$REPO" || { echo "fm-worker: no repo at $REPO" >&2; exit 64; }
REPO="$(pwd -P)"
fm_refuse_herdr_bypass fm-worker || exit $?
fm_freeze "$0" "$REPO" ${fm_args[@]+"${fm_args[@]}"}
fm_identity worker "$TASK" "$NAME" || exit 70
EMIT="${FM_CODE_ROOT:-$REPO}/bin/fm-emit.sh"
CREW_DATA="$(jq -cn --arg role worker --arg name "$NAME" \
  --arg en 'Work description unavailable' --arg tw '尚無工作說明' \
  '{role:$role,crew_name:$name,activity:{en:$en,"zh-TW":$tw}}')"
set_crew_activity() {
  local authored
  authored="$(jq -c '
    .activity
    | select(type == "object"
        and (.en | type == "string" and test("\\S"))
        and (."zh-TW" | type == "string" and test("\\S")))
    | {en:.en,"zh-TW":."zh-TW"}
  ' <<<"$1" 2>/dev/null)"
  [ -z "$authored" ] || CREW_DATA="$(jq -c --argjson activity "$authored" '.activity=$activity' <<<"$CREW_DATA")"
}
# fm-emit keeps the last --data only. Merge any call-site --data into the
# crew payload so role/recovery extras cannot wipe crew_name or activity.
emit_once() {
  local data="$CREW_DATA" args=()
  while [ $# -gt 0 ]; do
    case "$1" in
      --data)
        fm_need "fm-worker" "$@"
        data="$(jq -c --argjson extra "${2-}" '. * $extra' <<<"$data")" || return 1
        shift 2
        ;;
      *) args+=("$1"); shift ;;
    esac
  done
  FM_ROOT="$REPO" "$EMIT" --data "$data" --actor "$NAME" --task "$TASK" \
    ${args[@]+"${args[@]}"} >/dev/null 2>&1 </dev/null
}
emit() { emit_once "$@" || true; }

# Phase / activity refresh without inventing percent. Optional done/total when
# a true denominator exists. Shared path for every vendor (T-036).
emit_status() {
  local en="$1" tw="$2" done_n="${3-}" total_n="${4-}" data
  if [ "${HERDR_ENV:-}" = 1 ]; then
    fm_herdr_emit_status "$REPO" "$NAME" "$TASK" "$en" "$tw" worker "$done_n" "$total_n" \
      >/dev/null 2>&1 && return 0
  fi
  data="$(jq -cn --argjson base "$CREW_DATA" --arg en "$en" --arg tw "$tw" \
    --arg done_n "$done_n" --arg total_n "$total_n" '
    $base * {activity:{en:$en,"zh-TW":$tw}}
    + (if ($done_n|test("^[0-9]+$")) and ($total_n|test("^[1-9][0-9]*$"))
         and (($done_n|tonumber) <= ($total_n|tonumber))
       then {progress:{done:($done_n|tonumber),total:($total_n|tonumber)}}
       else {} end)
  ')"
  emit_once --type crew_status --data "$data" --en "$en" --tw "$tw" || true
}


# A run that ends has to say so, or "aboard" means "ever touched a task
# that is not finished yet", the board draws every actor that has ever
# run, and the ship's rate follows the history instead of what is
# happening now.
#
# One EXIT trap does the emitting; the signal traps only exit. Naming a
# signal alongside EXIT was worse than the bug it fixed: the handler ran
# and then execution CONTINUED, so a killed run announced it had
# finished and went on to commit, push and open a pull request - and
# `kill` no longer worked on it, because a trapped TERM that does not
# exit leaves only SIGKILL. The exit codes are the conventional
# 128+signal, so a caller can still tell what happened.
#
# Armed here, the first point emit() works, and the same in fm-review.
# Above it is only the argument parsing, which exits 64 before emit()
# exists. Everything else is below - the task-spec lookup (65), the
# worktree creation (70), the adapter chain - and every one of those
# exits happens after the run has said it started, so every one of them
# needs the ending.
#
# The ordinary emit is best-effort - a progress line the board misses
# costs an update - but the ending is not. `agent_finished` is what
# takes the crewman off the deck; lose it and the agent stands there
# until its task merges, which is the failure this pair exists to
# remove. So it is tried again, and if it still cannot be written the
# run says so rather than passing in silence. Both go through one
# definition of the command: two spellings of the same emit is how the
# ending and the progress lines drift apart.
# Every scratch file this script makes, removed on the way out -
# including on the paths a signal or an early exit cuts short, which
# this script has traps for. They were `mktemp`d and removed on the
# happy path only, and one of them was made on every round whether or
# not it was needed. tests/worker.test.sh walks three ways out in a
# TMPDIR it owns: 73 with say_err open, 74 with lookup_err open, and a
# TERM mid-engine, which is the case where "removed at the end" and
# "removed on the way out" differ. A signal arriving while the comment
# is being posted is the one combination no fixture holds still long
# enough to catch.
# An explicit template, for two reasons: BSD mktemp ignores $TMPDIR
# without one - so a caller that wants these somewhere it owns, which
# is how the leak is tested, cannot have them - and a file called
# tmp.XXXX says nothing about who left it if one ever does.
scratch_new() { mktemp "${TMPDIR:-/tmp}/fm-worker-XXXXXX"; }
# An ARRAY. A space-delimited string is word-split and glob-expanded by
# `rm -f`, so one space in $TMPDIR and the removal silently removes
# nothing - `-f` says so by saying nothing - and every leak test still
# passes, because a test builds its own path and never puts a space in
# it.
scratch=()
scratch_add() { scratch+=("$1"); }
clean_scratch() { [ ${#scratch[@]} -eq 0 ] || rm -f "${scratch[@]}"; }

# Dirty worktrees used to vanish when the adapter/transport never returned
# to the happy-path commit (SIGHUP, kill, blocked ask-only after edits, or
# EXIT before the final git block). Publish once on the way out so a PR
# always sees a remote checkpoint when the worktree had real changes.
_fm_wip_done=0
publish_wip_if_dirty() {
  local reason="${1:-exit}" dirty
  [ "${_fm_wip_done}" = 1 ] && return 0
  [ -n "${tree:-}" ] && [ -d "$tree" ] && [ -n "${branch:-}" ] && [ -n "${TASK:-}" ] || return 0
  case "$branch" in main|master|HEAD|'') return 0 ;; esac
  dirty="$(git -C "$tree" status --porcelain -- . \
    ":(exclude).fm-prompt.md" ":(exclude).fm-say.md" 2>/dev/null || true)"
  [ -n "$dirty" ] || return 0
  echo "fm-worker: publishing dirty worktree ($reason)" >&2
  # Same stock helper as mid-run checkpoints: commit then push. Prefer the
  # frozen snapshot helper when present so live source edits cannot shift us.
  _ckpt="${FM_CODE_ROOT:-$REPO}/bin/fm-checkpoint.sh"
  [ -x "$_ckpt" ] || _ckpt="$REPO/bin/fm-checkpoint.sh"
  if ! "$_ckpt" --dir "$tree" \
       --message "checkpoint ($reason)" </dev/null; then
    echo "fm-worker: checkpoint push failed for $branch ($reason)" >&2
    return 1
  fi
  # Prove the save landed: still-dirty after checkpoint means the helper
  # pushed an old tip while leaving work behind.
  still="$(git -C "$tree" status --porcelain -- . \
    ":(exclude).fm-prompt.md" ":(exclude).fm-say.md" 2>/dev/null || true)"
  if [ -n "$still" ]; then
    echo "fm-worker: checkpoint left dirty paths: $still" >&2
    return 1
  fi
  local_tip="$(git -C "$tree" rev-parse HEAD 2>/dev/null || true)"
  remote_tip="$(git -C "$tree" ls-remote --heads origin "refs/heads/$branch" 2>/dev/null | awk '{print $1}')"
  if [ -z "$local_tip" ] || [ -z "$remote_tip" ] || [ "$local_tip" != "$remote_tip" ]; then
    echo "fm-worker: checkpoint remote tip mismatch for $branch ($reason) local=$local_tip remote=$remote_tip" >&2
    return 1
  fi
  _fm_wip_done=1
  emit --type commit_pushed ${PR:+--pr "$PR"} \
    --en "checkpoint on $branch ($reason)" --tw "已 checkpoint $branch ($reason)"
  return 0
}

finished() {
  local rc=$?
  # Before retiring the actor: save any unpushed worktree edits. SIGTERM/INT
  # reach here via `exit`; SIGKILL cannot. Mid-run saves use fm-checkpoint.sh.
  publish_wip_if_dirty "exit-$rc" || true
  fm_record_end "$rc"
  clean_scratch
  local try=3
  while [ "$try" -gt 0 ]; do
    try=$(( try - 1 ))
    if emit_once --type agent_finished --en "run finished" --tw "這次執行結束"; then
      # Failed or interrupted attempts retain evidence for reconcile. Only
      # this owner can retire a successfully completed run's PID record.
      if [ "$rc" -eq 0 ] && [ "${pid_owned:-0}" = 1 ]; then
        rm -f "$pidfile" || { echo "fm-worker: cannot retire $pidfile" >&2; exit 70; }
      fi
      return 0
    fi
  done
  echo "${0##*/}: could not record the end of this run; ${NAME} stays on the deck until ${TASK} is finished" >&2
}
trap finished EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
# Keep SIGHUP ignored (fm-config). Exiting on hangup orphans the managed
# transport wait and PR publish when a launching agent shell ends.
trap '' HUP


# The task spec comes from the branch under review, not from whatever is
# checked out. A task defined on its own branch - which is how a new one
# arrives - was invisible to the reviewer and to the gate: `no task
# T-027`, for a task sitting in the diff they were handed.
task_spec() {   # task_spec <task> [branch]
  local t="$1" b="${2:-}" j=''
  [ -n "$b" ] && j="$(git show "$b:design/tasks.json" 2>/dev/null)"
  [ -n "$j" ] || j="$(cat design/tasks.json 2>/dev/null)"
  printf '%s' "$j" | jq -r --arg t "$t" '.tasks[]|select(.id==$t)' 2>/dev/null
}
# the worker has no branch name yet - it is derived from the title - so
# it looks for one already carrying this task. Local first, then origin:
# a worktree can be swept between rounds and leave nothing local behind,
# and a branch only origin remembers is still a branch to continue (T-037).
slug="$(printf '%s' "$TASK" | tr 'A-Z' 'a-z')"
branch_guess="$(git for-each-ref --format='%(refname:short)' refs/heads \
  | grep -i "^$slug-" | head -1)"
if [ -z "$branch_guess" ]; then
  remote_guess="$(git ls-remote --heads origin 2>/dev/null \
    | sed -n 's#.*[[:space:]]refs/heads/##p' \
    | grep -i "^$slug-" | head -1)"
  if [ -n "$remote_guess" ] && git fetch -q origin "$remote_guess:$remote_guess" 2>/dev/null; then
    branch_guess="$remote_guess"
  fi
fi
spec="$(task_spec "$TASK" "$branch_guess")"
[ -n "$spec" ] || { echo "fm-worker: no task $TASK in design/tasks.json" >&2; exit 65; }
set_crew_activity "$spec"

# A task's title is mutable; its branch name, once created, is not re-derived
# from it (T-037). Prefer an explicit --pr headRefName when valid (T-035).
if [ -n "$PR" ]; then
  pr_branch="$($GH pr view "$PR" --json headRefName --jq '.headRefName' 2>/dev/null || true)"
  case "$pr_branch" in
    ''|null) ;;
    *[!A-Za-z0-9._/-]*|/*|*/) ;;
    *) branch_guess="$pr_branch" ;;
  esac
fi
if [ -n "$branch_guess" ]; then
  branch="$branch_guess"
else
  branch="$slug-$(jq -r '.title' <<<"$spec" | tr 'A-Z' 'a-z' | tr -cs 'a-z0-9' '-' | cut -c1-28 | sed 's/-*$//')"
fi
tree="$REPO/state/worktrees/$TASK"

# Ordinary dispatch and recovery share one kernel lock. Recovery passes the
# locked descriptor as fd 9 across exec; ordinary workers acquire it before
# touching the worktree. The PID is published atomically while holding it.
pidfile="$REPO/state/worktrees/$TASK.pid"
mkdir -p "$REPO/state/worktrees" || exit 70
dispatch_data='{"role":"worker"}'
if [ "${FM_WORKER_LOCK_PID:-}" != "$$" ]; then
  exec 9>>"$pidfile.lock" || exit 70
  perl -MFcntl=:flock -e '
    open(my $lock, "+<&=9") or die "worker lock: $!";
    flock($lock, LOCK_EX | LOCK_NB) or exit 1;
  ' || { echo "fm-worker: cannot lock $TASK; another worker may be running" >&2; exit 70; }
else
  # Reconcile execs this PID with its locked fd 9. Both producers describe
  # the same attempt: the worker must not introduce a fresh boundary after
  # the launcher's recovery event, even when neither knows the PR yet.
  dispatch_data='{"role":"worker","recovery":true}'
fi
# Consume the PID-bound handoff; a child/wrapper must not reuse it as a
# generic recovery flag. Keep fd 9 open for this worker's entire lifetime.
unset FM_WORKER_LOCK_PID
printf '%s\n' "$$" > "$pidfile.next" && mv -f "$pidfile.next" "$pidfile" || {
  echo "fm-worker: cannot publish liveness for $TASK" >&2; exit 70;
}
pid_owned=1

# The worker records that it started, not the dispatcher. A task started
# by hand was otherwise never in flight as far as the log was concerned,
# and the dispatcher would start a second one on top of it.
emit --type dispatched ${PR:+--pr "$PR"} --data "$dispatch_data" --en "picked up $TASK" --tw "接下 $TASK"
emit_status "Adapter starting on $TASK" "開始在 $TASK 上跑 adapter"

# --- a worktree of its own -----------------------------------------------
# Never delete work. A run that was interrupted - the machine slept, the
# session ended, someone pressed ctrl-c - leaves its files here
# uncommitted, and this used to remove them before the next round could
# see them. Tonight that nearly cost two finished tasks.
if [ -d "$tree" ] && [ -n "$(git -C "$tree" status --porcelain 2>/dev/null \
     -- . ":(exclude).fm-prompt.md" ":(exclude).fm-say.md")" ]; then
  rescue="$REPO/state/rescued/$TASK-$(date -u +%Y%m%dT%H%M%SZ)"
  mkdir -p "$(dirname "$rescue")"
  cp -R "$tree" "$rescue"
  echo "fm-worker: $tree had uncommitted work; a copy is at $rescue" >&2
  emit --type worker_crashed --en "rescued uncommitted work to ${rescue#"$REPO"/}" \
       --tw "把未提交的工作救到 ${rescue#"$REPO"/}"
fi
rm -rf "$tree"; mkdir -p "$REPO/state/worktrees"
git worktree prune >/dev/null 2>&1
# A second round continues the first. Recreating the branch from main would
# throw away everything the worker did before, which makes a review round
# pointless and the round-three protocol impossible: the worker would be
# answering a review of work that no longer exists.
round_two=0
if git show-ref --verify --quiet "refs/heads/$branch"; then
  round_two=1
  git worktree add -q "$tree" "$branch"
elif git ls-remote --exit-code --heads origin "$branch" >/dev/null 2>&1; then
  round_two=1
  git fetch -q origin "$branch:$branch" 2>/dev/null
  git worktree add -q "$tree" "$branch"
else
  git worktree add -q -b "$branch" "$tree" "$BASE"
fi || { echo "fm-worker: could not create the worktree" >&2; exit 70; }

# The pull request the branch already has, if the caller did not say.
# This used to be looked up two hundred lines below, AFTER the engine had
# run - so a second round dispatched without --pr was a first round
# wearing its clothes: the prompt carried no review and no failing check,
# the worker rewrote what it had already written, and the question it
# wrote into .fm-say.md was dropped because $PR was still empty when the
# time came to post it. The run then said "its question is on #", with
# nothing after the hash, which is what finding this looked like.
# Only on a later round: a branch that does not exist yet cannot have a
# pull request, and a first round that called `gh` at all would break the
# guarantee that an unavailable vendor touches nothing.
#
# The exit status is kept, and this is the whole point of the block.
# `2>/dev/null` and an empty answer make "there is no pull request" and
# "gh did not answer" the same string - and they are opposite
# instructions. Empty-and-succeeded is a real state: a previous round
# that pushed and then died at `pr create` leaves exactly that, and the
# right thing is to carry on and open one. Empty-and-failed means the
# prompt would be blind and the push would collide with a pull request
# that is already there, so the run stops before it spends an engine
# round finding that out.
if [ "$round_two" = 1 ] && [ -z "$PR" ]; then
  # no pipe: `$?` after one is the LAST element's, and `head` on empty
  # input exits 0 - so a `head -1` here would turn could-not-answer into
  # answered-none the moment pipefail was not in force, which is the one
  # thing this block exists to prevent. `--jq '.[0].number'` yields a
  # single line anyway, so the pipe bought nothing.
  # a mktemp that failed would leave this empty, `2>""` would fail the
  # redirection, gh would never run, and the round would exit 74
  # saying GitHub could not answer - when GitHub was never asked
  lookup_err="$(scratch_new)" || lookup_err=''
  [ -n "$lookup_err" ] || { echo "fm-worker: could not make a scratch file" >&2; exit 70; }
  scratch_add "$lookup_err"
  PR="$($GH pr list --head "$branch" --state open --json number --jq '.[0].number' \
        2>"$lookup_err" </dev/null)"; lookup_rc=$?
  # what gh actually prints for a branch with no open pull request is
  # the literal `null`, not silence - leak it through and the round
  # says `already has #null` and then posts to `gh pr comment null`
  PR="$(printf '%s' "$PR" | tr -d '[:space:]')"
  case "$PR" in null) PR='' ;; esac
  if [ "$lookup_rc" != 0 ]; then
    echo "fm-worker: could not ask which pull request $branch has" >&2
    sed 's/^/fm-worker: gh: /' "$lookup_err" >&2
    echo "fm-worker: a later round cannot run without it - the prompt would carry no review" >&2
    echo "fm-worker: and the push would collide with a pull request nobody looked for" >&2
    emit --type worker_crashed --en "could not ask which pull request $branch has" \
         --tw "問不到 ${branch} 的 PR"
    exit 74
  fi
  if [ -n "$PR" ]; then
    echo "fm-worker: $branch already has #$PR; this round answers it" >&2
  else
    # succeeded and said none: the branch was pushed by a round that did
    # not get as far as opening one, and this round opens it
    echo "fm-worker: $branch has no open pull request; this round will open one" >&2
  fi
fi

# --- the prompt: the task, the design that bears on it, and the skill ----
prompt="$tree/.fm-prompt.md"
# This is the worker's one way to speak, and it is read back with
# `[ -s ... ]`, so it has to be a signal from THIS round. What makes
# that true is above: the worktree is removed and recreated from the
# branch before the engine runs, and .fm-say.md is never committed, so
# a question left by an earlier round cannot be here. The rescue that
# runs first excludes it by name for the same reason - a leftover
# question is not uncommitted work worth saving.
say="$tree/.fm-say.md"
{
  cat "${FM_CODE_ROOT:-$REPO}/skills/worker/SKILL.md"
  printf '\n---\n\n# Your task\n\n```json\n%s\n```\n' "$spec"
  printf '\nYour worktree is the current directory. Your branch is `%s`.\n' "$branch"
  printf 'Stay inside these paths:\n'
  jq -r '.scope[]|"  - " + .' <<<"$spec"
  # a later round is answering a review, and the review is on the pull
  # request. Handing over the task alone would have the worker rewrite what
  # it already wrote instead of fixing what was named.
  if [ "$round_two" = 1 ]; then
    printf '\n---\n\n# This is not the first round\n\n'
    printf 'Your branch already carries your earlier work. Build on it.\n'
    if [ -n "$PR" ]; then
      printf '\nWhat review has said so far, oldest first:\n\n'
      $GH pr view "$PR" --json comments \
        --jq '.comments[]|"## " + .author.login + "\n\n" + .body + "\n"' 2>/dev/null </dev/null
      # and why the gate is red, if it is. A worker answering a failing
      # check without being shown the failure is guessing - and gate 6 does
      # not open until that check is green, so it is the whole of the round.
      failing="$($GH pr checks "$PR" --json state,link \
        --jq '.[]|select(.state!="SUCCESS" and .state!="PENDING")|.link' 2>/dev/null </dev/null | head -1)"
      if [ -n "$failing" ]; then
        # A check's link is .../actions/runs/<run>/job/<job>. `${x##*/runs/}`
        # leaves `<run>/job/<job>`, which is not a run id - `gh run view`
        # refused it, its stderr went to /dev/null, and the worker was handed
        # an empty block. An empty block is indistinguishable from a green
        # run, so the round was spent asking why the check was red.
        # The shape is CHECKED, not assumed, and BOTH shapes GitHub
        # uses count: `/actions/runs/<id>/job/<id>` and the older
        # check-run details_url `/runs/<job>`. Narrowing to the first
        # would send the second down the "cannot read it" path, which
        # is a worse answer than the one it replaced.
        run_id=''; log_kind=run; log_title=Run
        case "$failing" in
          */runs/*)
            # The id is delimited by NOT-A-DIGIT, not by a slash.
            # `%%/*` assumed a slash or end of string, and the legacy
            # details_url is served with a query on that segment -
            # `/runs/6789123?check_suite_focus=true` - which trimmed to
            # the whole thing, failed the digit guard, and told the
            # worker no run id could be read out of an Actions run.
            _rt="${failing##*/runs/}"
            _rd="${_rt%%[!0-9]*}"          # the leading run of digits
            _rr="${_rt#"$_rd"}"            # and whatever follows it
            # empty digits is no id at all; `12ab` has to fail closed,
            # so what follows has to be a delimiter rather than more id
            case "$_rd" in '') ;; *)
              case "$_rr" in ''|/*|'?'*|'#'*) run_id="$_rd" ;; esac ;;
            esac ;;
        esac
        # Legacy IDs identify jobs, not workflow runs. Let gh resolve the
        # owning run with --job; modern links already supply the run ID.
        case "$failing" in
          */actions/runs/*) ;;
          */runs/*) log_kind=job; log_title=Job ;;
        esac
        printf '\n---\n\n# The required check is red\n\n'
        printf 'It fails on the runner and may well pass on your machine.\n\n```\n'
        if [ -z "$run_id" ]; then
          # what the SCRIPT could not do, not what the check is. It knows
          # it found no run id in the link; it does not know which CI
          # produced the link, and saying "this is not an Actions run"
          # about an old-style /runs/<id> url was simply false.
          printf 'No run id could be read out of %s,\n' "$failing"
          printf 'so this script could not fetch its log.\n'
          printf 'Ask for it on the pull request rather than guessing.\n'
        else
          # fetched once: two calls can disagree, and the second would be
          # the one the worker is shown while the first decided whether to
          # show anything.
          #
          # scratch_new mints, scratch_add registers - the pair is one
          # register, not two, and a mint that failed leaves the empty
          # string that the `:-/dev/null` below is for
          log_err="$(scratch_new)"
          [ -z "$log_err" ] || scratch_add "$log_err"
          log_args=("$run_id")
          [ "$log_kind" != job ] || log_args=(--job "$run_id")
          raw_log="$($GH run view "${log_args[@]}" --log-failed 2>"${log_err:-/dev/null}" </dev/null)"
          gh_rc=$?
          # Two values, on purpose. `trimmed` is what the worker is shown;
          # `rendered` is the same thing with blank lines dropped, and is
          # only ever used to DECIDE whether there is anything to show.
          # Printing the filtered one deleted every blank line inside a
          # real traceback - a filter that decides something must not also
          # be the thing printed.
          trimmed=''; rendered=''
          if [ -n "$raw_log" ]; then
            trimmed="$(printf '%s\n' "$raw_log" | tail -120 | sed 's/^[^\t]*\t[^\t]*\t//')"
            rendered="$(printf '%s\n' "$trimmed" | grep -v '^[[:space:]]*$' || true)"
          fi
          if [ -n "$rendered" ] && [ "$gh_rc" != 0 ]; then
            # Some of it came back and gh still failed - a multi-job run
            # where one job's log is gone. Printing the partial log
            # alone presents it as the whole of the failure, which is
            # the same lie as an empty block wearing a green run's face.
            printf '%s\n' "$trimmed"
            printf '\n-- this log is incomplete: gh exited %s while fetching %s %s\n' \
              "$gh_rc" "$log_kind" "$run_id"
            [ -z "$log_err" ] || sed 's/^/gh: /' "$log_err" | head -20
          elif [ -n "$rendered" ]; then
            printf '%s\n' "$trimmed"
          elif [ "$gh_rc" != 0 ]; then
            # said, not left blank: the worker cannot run gh, so this block
            # is its only view of the runner, and silence reads as "nothing
            # was wrong" rather than "I could not fetch it"
            printf 'The log for %s %s could not be fetched.\n' "$log_kind" "$run_id"
            # bounded, like the log above it: gh's stderr is not, and
            # everything that reaches this fence has to be
            [ -z "$log_err" ] || sed 's/^/gh: /' "$log_err" | head -20
            printf 'Ask for it on the pull request rather than guessing.\n'
          else
            # gh answered, and had nothing: a cancelled run, or a job that
            # died before any step logged. Saying "could not be fetched"
            # here would be a false statement about gh in the one block
            # the worker has no way to check.
            printf '%s %s reported no failing step log.\n' "$log_title" "$run_id"
            printf 'It may have been cancelled, or failed before any step ran.\n'
            printf 'Ask on the pull request rather than guessing.\n'
          fi
        fi
        printf '```\n'
      fi
    fi
  fi
  printf '\n---\n\n# The design\n\n'
  sed -n '/^## 6\./,/^## 8\./p' design/design.md 2>/dev/null
} > "$prompt"

# --- the adapter, with fallback only on a vendor being unavailable -------
# The worker's evidence: files changed in the worktree. The prompt lives
# there too, so it comes out of the count or every run looks busy.
worker_did_work() {
  [ -n "$(git -C "$tree" status --porcelain -- . \
      ":(exclude).fm-prompt.md" ":(exclude).fm-say.md")" ] || [ -s "$tree/.fm-say.md" ]
}
log="$FM_RUN_DIR/worker.log"; : > "$log"
# Close fd 9 and the launch-time task lock in a subshell so adapters cannot
# hold either. The parent keeps its copies for exclusion; if the published
# PID is SIGKILL'd, a surviving adapter must not keep the task lock or
# recovery relaunch blocks on "already has a live worker".
# Managed-session runs keep evidence under FM_RUN_DIR and resolve adapters
# through FM_CODE_ROOT when a frozen snapshot is active.
chain_result="$(scratch_new)" || exit 70
scratch_add "$chain_result"
emit_status "Adapter running on $TASK" "adapter 正在執行 $TASK"
(
  exec 9>&-
  if [[ "${FM_WORKER_TASK_LOCK_FD:-}" =~ ^[0-9]+$ ]]; then
    eval "exec ${FM_WORKER_TASK_LOCK_FD}>&-"
  fi
  fm_run_chain "${FM_CODE_ROOT:-$REPO}/bin/adapters" "$(fm_vendor_chain worker "$VENDOR")" \
    "$prompt" "$tree" "$log" worker_did_work
  chain_rc=$?
  declare -p FM_VENDOR_USED FM_VENDOR_SKIPPED FM_VENDOR_MISREAD FM_VENDOR_UNKNOWN > "$chain_result"
  exit "$chain_rc"
); rc=$?
# shellcheck disable=SC1090
. "$chain_result"
[ -z "$FM_VENDOR_UNKNOWN" ] || {
  echo "fm-worker: config.yaml names a vendor with no adapter: $FM_VENDOR_UNKNOWN" >&2; exit 65; }
[ "$rc" -lt 64 ] || { echo "fm-worker: adapter transport/configuration failed; artifacts at $FM_RUN_DIR" >&2; exit 70; }
[ -z "$FM_VENDOR_MISREAD" ] || {
  echo "fm-worker: $FM_VENDOR_MISREAD was read as unavailable, but it changed files - keeping them" >&2
  emit --type vendor_unavailable --en "read as unavailable but work was done; keeping it" \
       --tw "被判成不可用，但確實有改動，保留"; }
for v in $FM_VENDOR_SKIPPED; do
  emit --type vendor_unavailable --en "$v unavailable, trying the next" \
       --tw "$v 不可用，換下一家"
done
[ "$rc" = "2" ] && { echo "fm-worker: every vendor was unavailable" >&2; exit 2; }

rm -f "$prompt"

# The worker's one way to speak on the pull request. It may not touch gh -
# that is the adapter contract and the reason a CLI with no repository
# access can be a worker - so it writes .fm-say.md and this script posts
# it. Without this the round-three protocol cannot happen at all:
# ASK-PASS-CRITERIA would sit in a log nobody reads while fm-protocol
# reported a violation every turn, which looks exactly like a worker that
# stopped working.
asked=0
[ -s "$say" ] && asked=1
spoke=0
# gh's own words are kept, the way the lookup above keeps them: this is
# the one path where a person is expected to pick the failure up by
# hand, and "it was refused" without "why" sends them to the pull
# request to find out - no permission, rate limited, locked, wrong
# number. The run said where the text is and not what went wrong.
say_err=''
post_note() {   # post_note <file> <pr>; sets spoke=1 when it landed
  say_err="$(scratch_new)" || say_err=''
  [ -z "$say_err" ] || scratch_add "$say_err"
  if $GH pr comment "$2" --body-file "$1" >/dev/null 2>"${say_err:-/dev/null}" </dev/null; then
    spoke=1
    emit --type ask_pass_criteria --pr "$2" --en "the worker spoke on #$2" \
         --tw "工人在 #$2 上發言"
  fi
}
# A note is not only a question. An adapter that may edit but not execute
# finishes the work and says which checks it could not run, and on a
# first round that note used to be read as a question asked before there
# was a pull request: kept, exit 73, and the work in the worktree never
# reached one. A note beside real changes waits for the pull request this
# round is about to open. It is set aside OUT of the worktree first, so
# the commit below cannot take it even from a branch that tracks it.
held=''
if [ "$asked" = 1 ] && [ -z "$PR" ] && [ -n "$(git -C "$tree" status --porcelain -- . \
     ":(exclude).fm-prompt.md" ":(exclude).fm-say.md")" ]; then
  held="$(scratch_new)" || held=''
  [ -n "$held" ] || { echo "fm-worker: could not make a scratch file" >&2; exit 70; }
  scratch_add "$held"
  cp "$say" "$held" || { echo "fm-worker: could not set the worker's note aside" >&2; exit 70; }
fi
if [ "$asked" = 1 ] && [ -n "$PR" ]; then
  post_note "$say" "$PR"
fi
# A question that went nowhere used to be a line on standard error and
# an exit 0: the run reported a complete round, the log said nothing,
# and the next round asked the same question again. This does not
# UNSTICK the task - nothing reads worker_crashed and acts on it, and a
# task with an open pull request is not one the dispatcher restarts -
# but it stops the run lying about what happened, and it keeps what the
# worker wrote so a human can post it.
#
# So the file is kept, not removed, and the event carries the number:
# a failed round that cannot be linked to the pull request it failed on
# is a card the captain cannot act on.
keep_unsent() {   # keep_unsent <file>; reads $PR, never returns
  # Out of the worktree, which is removed and recreated on the next
  # round: keeping the file where it was written is not keeping it, and
  # the design says the text survives so a human can post it. Beside
  # state/rescued/, where an interrupted run's files go, and under a
  # name of its own because this is a message rather than work.
  #
  # No fallback to $say if the copy fails. The old one put the path
  # back inside the worktree and printed it as though it were safe,
  # which is the exact thing the sentence above says does not survive -
  # a fallback that quietly undoes the fix it is a fallback for.
  # the pid too: two failures in the same second would otherwise
  # overwrite each other, and the earlier question is the one this
  # path exists to keep
  kept="$REPO/state/unsent/$TASK-$(date -u +%Y%m%dT%H%M%SZ)-$$.md"
  # its own stderr prefixed like everything else here: an unprefixed
  # `mkdir: File exists` lands ahead of the lines that explain what
  # happened, in a run whose whole point is reporting in its own voice
  mkdir -p "$(dirname "$kept")" 2>&1 | sed 's/^/fm-worker: /' >&2
  echo "fm-worker: the worker had something to say and there was nowhere to put it" >&2
  if cp "$1" "$kept" 2>/dev/null; then
    echo "fm-worker: it is at ${kept#"$REPO"/}" >&2
  else
    echo "fm-worker: and it could not be kept either - ${kept#"$REPO"/} is not writable" >&2
    if [ "$1" = "$say" ]; then
      echo "fm-worker: the text is in $say until the next round recreates that worktree" >&2
    else
      # a scratch copy is removed on exit, so print it rather than
      # naming a file that will not be there to read
      echo "fm-worker: the text was:" >&2
      sed 's/^/fm-worker: | /' "$1" >&2
    fi
  fi
  # Two causes, because there are two. The middle one - "or a gh that
  # did not answer" - is gone: the lookup keeps its exit status now and
  # stops the run before this point, so an empty $PR here means the
  # question was asked and the answer was none.
  if [ -n "$PR" ]; then
    echo "fm-worker: #$PR would not take the comment" >&2
    [ -z "$say_err" ] || sed 's/^/fm-worker: gh: /' "$say_err" >&2
    emit --type worker_crashed --pr "$PR" --en "the worker's question could not be posted to #$PR" \
         --tw "工人的提問貼不上 #$PR"
  else
    echo "fm-worker: $branch has no pull request to say it on - asking is premature" >&2
    emit --type worker_crashed --en "the worker asked before there was a pull request" \
         --tw "工人在還沒有 PR 的時候提問"
  fi
  exit 73
}
# held means the note waits for the pull request opened below, which is
# the only case where no pull request yet is not the end of the round
if [ "$asked" = 1 ] && [ "$spoke" = 0 ] && [ -z "$held" ]; then
  keep_unsent "$say"
fi
rm -f "$say"

# asking IS the work in a round that begins with a question, and the round
# after it is the one that changes files
if [ "$asked" = 1 ] && [ -z "$(git -C "$tree" status --porcelain)" ]; then
  echo "fm-worker: the worker asked rather than changed anything; its question is on #$PR" >&2
  printf '%s\n' "$branch"
  exit 0
fi

# the same predicate the chain was given, not a second spelling of it: the
# two agreed only because the prompt happened to be removed between them
if ! worker_did_work; then
  echo "fm-worker: the adapter changed nothing" >&2
  emit --type gate_failed --en "the adapter changed nothing" --tw "adapter 沒有改動任何檔案"
  exit 1
fi

# --- from here on it is the script's job, never the adapter's ------------
git -C "$tree" add -A
fm_git_commit "$tree" "$TASK: $(jq -r .title <<<"$spec")"
_fm_wip_done=1
emit_status "Commit pushed on $branch" "已在 $branch 上推送 commit"
emit --type commit_pushed --en "committed on $branch" --tw "已在 $branch 上 commit"
git -C "$tree" push -q -u origin "$branch" 2>/dev/null || {
  echo "fm-worker: could not push $branch" >&2; exit 71; }

# On a later round the pull request is already open and `pr create` fails.
# A worker that could only ever open a new one failed its second round at
# the last step, with the work pushed and nothing pointing at it.
#
# $PR is what the lookup above the prompt found, or what the caller
# passed; asking again here would be a second answer to one question,
# and the two could disagree - a pull request opened while the engine
# was running would be posted to by one half of this script and not the
# other. There is no second lookup - asserted, not asserted about:
# tests/worker.test.sh counts `pr list` at one per run. An
# empty $PR here means either a first round, or a later round whose
# lookup succeeded and said there is none - a branch pushed by a round
# that died before it opened one. Both want a pull request created
# below. The third case, a lookup that could not answer, does not reach
# here: it exits 74 above rather than pushing at a pull request nobody
# looked for.
num="$PR"
if [ -z "$num" ] || [ "$num" = "null" ]; then
  url="$($GH pr create --head "$branch" --base "$BASE" \
        --title "$TASK: $(jq -r .title <<<"$spec")" \
        --body "Dispatched by firstmate for $TASK. Acceptance is in design/tasks.json." \
        2>/dev/null </dev/null | tail -1)"
  # the number, not the url: every step after this addresses the pull
  # request by it, and an event without it leaves the gates checking nothing
  num="$(printf '%s' "$url" | sed -n 's|.*/\([0-9][0-9]*\)$|\1|p')"
  [ -n "$num" ] || { echo "fm-worker: could not read a pull request number from '$url'" >&2; exit 72; }
  emit_status "Pull request #$num opened" "已開 PR #$num"
  emit --type pr_opened --pr "$num" --en "opened #$num" --tw "已開 #$num"
else
  emit_status "Pushed another round to #$num" "已推第二輪到 #$num"
  emit --type commit_pushed --pr "$num" --en "pushed another round to #$num" \
       --tw "第二輪已推上 #$num"
fi
# the note that waited for a pull request has one now. Refused, it is
# kept and the run fails the way a refused note on an existing pull
# request does - the work and the pull request stand either way.
if [ -n "$held" ]; then
  PR="$num"
  post_note "$held" "$num"
  [ "$spoke" = 1 ] || keep_unsent "$held"
fi
printf '%s\n' "$branch"
[ "${rc:-1}" = "0" ] || exit 1
exit 0
