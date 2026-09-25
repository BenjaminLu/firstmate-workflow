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
  # An uncommitted rebuild is not a checkpoint: it sits detached on the
  # base, possibly with markers, and pushing it would replace the branch.
  # The branch ref was never moved, the next round rescues this worktree
  # to state/rescued/ and rebuilds from the branch again.
  if [ "${rebuilt:-0}" = 1 ]; then
    echo "fm-worker: the rebuild of $branch was not committed ($reason); nothing is published" >&2
    return 0
  fi
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

# A rebuilt commit is pushed before the local branch moves onto it, and
# refs/fm-rebuilt/<branch> names it while that push is unconfirmed. A run
# cut short in between - a signal here, SIGKILL for the next round - lands
# on whichever head origin actually has: the rebuilt commit if the push
# reached it, the previous head (never moved) if not. Moving the local ref
# first and restoring it only on a failed return left a run killed during
# the push with a local branch origin never had, and every later round
# refused at the plain push (71) with nothing allowed to repair it.
rebuild_settle() {
  local pending ls lsrc origin_head
  [ -n "${branch:-}" ] && [ -n "${REPO:-}" ] || return 0
  pending="$(git -C "$REPO" rev-parse -q --verify "refs/fm-rebuilt/$branch^{commit}" 2>/dev/null)" || return 0
  ls="$(git -C "$REPO" ls-remote --exit-code --heads origin "refs/heads/$branch" 2>/dev/null)"; lsrc=$?
  if [ "$lsrc" != 0 ] && [ "$lsrc" != 2 ]; then
    echo "fm-worker: could not ask origin whether the rebuilt $branch (${pending}) reached it; the next round asks again" >&2
    return 1
  fi
  origin_head="$(printf '%s\n' "$ls" | awk 'NR == 1 { print $1 }')"
  if [ -n "$origin_head" ] && { [ "$origin_head" = "$pending" ] \
       || git -C "$REPO" merge-base --is-ancestor "$pending" "$origin_head" 2>/dev/null; }; then
    if ! git -C "$REPO" branch -f "$branch" "$pending" >/dev/null 2>&1; then
      echo "fm-worker: the rebuilt $branch (${pending}) is on origin, but $branch could not be moved onto it; the next round tries again" >&2
      return 1
    fi
    echo "fm-worker: the rebuilt $branch (${pending}) reached origin; $branch now points at it" >&2
  else
    echo "fm-worker: the rebuilt $branch (${pending}) never reached origin; $branch stays where it was" >&2
  fi
  git -C "$REPO" update-ref -d "refs/fm-rebuilt/$branch" 2>/dev/null || {
    echo "fm-worker: could not clear refs/fm-rebuilt/$branch; the next round settles it again" >&2; return 1; }
}

finished() {
  local rc=$?
  # Before retiring the actor: save any unpushed worktree edits. SIGTERM/INT
  # reach here via `exit`; SIGKILL cannot. Mid-run saves use fm-checkpoint.sh.
  publish_wip_if_dirty "exit-$rc" || true
  rebuild_settle || true
  # the scratch worktree the rebuild check replays in, if a signal cut it short
  if [ -n "${rebuild_probe:-}" ]; then
    git -C "$REPO" worktree remove --force "$rebuild_probe" >/dev/null 2>&1; rm -rf "$rebuild_probe"
  fi
  fm_record_end "$rc"
  # before clean_scratch, which would remove the only copy of it
  [ -z "${held:-}" ] || [ "${held_settled:-0}" = 1 ] || lost_held "$rc"
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
task_spec() {   # task_spec <task> [branch]; its own file, design/tasks/<id>.json
  local t="$1" b="${2:-}" j=''
  [ -n "$b" ] && j="$(fm_task "$t" design/tasks "$b")"
  [ -n "$j" ] || j="$(fm_task "$t")"
  printf '%s' "$j"
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
[ -n "$spec" ] || { echo "fm-worker: no task $TASK: no design/tasks/$TASK.json" >&2; exit 65; }
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
# a rebuilt push the last run could not confirm - it was killed during it
rebuild_settle || true
# A second round continues the first. Recreating the branch from main would
# throw away everything the worker did before, which makes a review round
# pointless and the round-three protocol impossible: the worker would be
# answering a review of work that no longer exists.
round_two=0
if git show-ref --verify --quiet "refs/heads/$branch"; then
  round_two=1
  # Origin's head may be ahead of the local branch: a round whose rebuild
  # the lease refused, or a save from elsewhere. Fast-forward only - no `+`,
  # so a local branch that has diverged or is ahead is never rewound - and
  # a failure here leaves the local branch as it was.
  git fetch -q origin "refs/heads/$branch:refs/heads/$branch" >/dev/null 2>&1 || true
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

# --- a later round starts from the current base (T-067) -------------------
# Firstmate may not run git and the adapter cannot, so when the base moves
# under an open task branch and the two conflict, this is the only place
# that can bring the branch up to date. The base is FETCHED, not read from
# the local ref: nothing here updates the local main, so it is as stale as
# the last time someone pulled.
#
# A branch that still rebases onto the fetched base - gate 2's question,
# asked gate 2's way - is left exactly as it is. One that does not is
# rebuilt: the worktree is detached at the base and the branch's own change
# (merge-base..branch) is squash-merged onto it, three-way. Clean files are
# staged; conflicting files keep standard markers and are handed to the
# worker by name. The worktree stays DETACHED until the commit below, so
# the branch ref never points at a half-rebuilt tree: a run that dies here
# leaves the branch as it was, and fm-checkpoint.sh refuses a detached
# HEAD. A commit made on it anyway is refused before the round's own.
rebuilt=0; rebuild_prev=''; rebuild_lease=''; rebuild_base=''; rebuild_mark=''
rebuild_entry=''; rebuild_rows=''; rebuild_probe=''
# 1 when the base keeps one file per task (T-090): no design/tasks.json and
# no task table, so the task's own entry is design/tasks/<id>.json
rebuild_split=0
rebuild_conflicts=(); rebuild_restore=(); rebuild_split_conflicts=()
# Conflicts git could not write markers into - a binary file, or one side
# deleted what the other changed - and what the merge left in their place:
# the blob in the worktree, or `absent`. The worker is told which side that
# is, and the round is refused while the file is still exactly that.
rebuild_bare=(); rebuild_bare_left=(); rebuild_bare_side=()
rebuild_state_of() {   # rebuild_state_of <path>; the worktree's blob, or absent
  if [ -f "$tree/$1" ] || [ -L "$tree/$1" ]; then
    git -C "$tree" hash-object --no-filters -- "$1" 2>/dev/null || echo unreadable
  else
    echo absent
  fi
}
rebuild_side_left() {   # rebuild_side_left <path>; which side the merge left, in words
  local ours='' theirs='' now sha stage
  while IFS=$' \t' read -r _ sha stage _; do
    case "$stage" in 2) ours="$sha" ;; 3) theirs="$sha" ;; esac
  done < <(git -C "$tree" ls-files -u -- "$1" 2>/dev/null)
  now="$(rebuild_state_of "$1")"
  if [ "$now" = absent ] && [ -z "$ours" ]; then echo "deleted, as $BASE has it; your task changed it"
  elif [ "$now" = absent ] && [ -z "$theirs" ]; then echo "deleted, as your task has it; $BASE changed it"
  elif [ "$now" = absent ]; then echo "deleted; neither side deleted it"
  elif [ "$now" = "$ours" ] && [ -z "$theirs" ]; then echo "$BASE's version; your task deleted it"
  elif [ "$now" = "$ours" ]; then echo "$BASE's version; your task's change is not in it"
  elif [ "$now" = "$theirs" ] && [ -z "$ours" ]; then echo "your task's version; $BASE deleted it"
  elif [ "$now" = "$theirs" ]; then echo "your task's version; $BASE's change is not in it"
  else echo "neither side exactly as it was"
  fi
}
rebuild_fingerprint() {
  # The tree the worktree holds, so a rebuilt round can tell the worker's
  # changes from the ones the rebuild itself made. Written through an index
  # of its own: the real one has unmerged entries, and `git status` says
  # `UU` for a conflicted file before and after the worker resolves it.
  # Read over the base the rebuild sits on, never HEAD: something that
  # commits on the detached HEAD mid-round must not move what it is read
  # against.
  local idx
  idx="$(scratch_new)" || return 0
  scratch_add "$idx"; rm -f "$idx"
  GIT_INDEX_FILE="$idx" git -C "$tree" read-tree "${rebuild_base:-HEAD}" 2>/dev/null \
    && GIT_INDEX_FILE="$idx" git -C "$tree" add -A 2>/dev/null \
    && GIT_INDEX_FILE="$idx" git -C "$tree" rm -q --cached --ignore-unmatch \
         -- .fm-prompt.md .fm-say.md >/dev/null 2>&1 \
    && GIT_INDEX_FILE="$idx" git -C "$tree" write-tree 2>/dev/null
  rm -f "$idx"
}
# The task's own tasks.json entry survives exactly, and entries the two
# sides added or changed independently are merged by id. Written back in
# jq's own layout, which is only safe when the base side already is in it.
# Fails (and leaves the file alone) when both sides changed one entry that
# is not the task's, or changed anything outside .tasks differently.
rebuild_tasks_json() {   # rebuild_tasks_json <merge-base> <old head>
  local f="design/tasks.json" b o t merged
  t="$(git show "$2:$f" 2>/dev/null)" || return 0
  jq -e --arg id "$TASK" '.tasks[]|select(.id==$id)' <<<"$t" >/dev/null 2>&1 || return 0
  b="$(git show "$1:$f" 2>/dev/null || printf '{}')"
  o="$(git show "$rebuild_base:$f" 2>/dev/null)" || return 1
  [ "$(jq . <<<"$o" 2>/dev/null)" = "$o" ] || return 1
  # files, not --argjson: the whole task list does not belong on argv
  merged="$(jq -n --arg id "$TASK" --slurpfile b <(printf '%s' "$b") \
      --slurpfile o <(printf '%s' "$o") --slurpfile t <(printf '%s' "$t") '
    def byid: map({key:.id, value:.}) | from_entries;
    $b[0] as $b | $o[0] as $o | $t[0] as $t
    | ($b.tasks // [] | byid) as $B | ($o.tasks // [] | byid) as $O | ($t.tasks | byid) as $T
    | ($b|del(.tasks)) as $bt | ($o|del(.tasks)) as $ot | ($t|del(.tasks)) as $tt
    | if $tt != $bt and $ot != $bt and $tt != $ot then error("both changed the top level") else . end
    | [ $T | keys[] | select($B[.] != $T[.]) ] as $changed
    | [ $B | keys[] | select($T[.] == null) ] as $removed
    | ($changed + $removed | map(select(. != $id and $O[.] != $B[.] and $O[.] != $T[.])))
      as $both
    | if ($both | length) > 0 then error("both changed " + ($both | join(", "))) else . end
    | (if $tt != $bt then $t else $o end)
    | .tasks = ([ $o.tasks[] | .id as $k
                  | if ($removed | any(. == $k)) then empty
                    elif ($changed | any(. == $k)) or $k == $id then $T[$k]
                    else . end ]
                + [ $t.tasks[] | .id as $k
                    | select($O[$k] == null and (($changed | any(. == $k)) or $k == $id)) ])
  ' 2>/dev/null)" || return 1
  printf '%s\n' "$merged" > "$tree/$f" && git -C "$tree" add -- "$f"
}
# A file the merge left unmerged. Read into a string, not piped into
# grep -q: under pipefail an early grep exit is a failed pipeline.
rebuild_unmerged() { [ -n "$(git -C "$tree" ls-files -u -- "$1" 2>/dev/null)" ]; }
# What the previous head had for the task: its tasks.json entry (sorted
# keys, one line) and its design.md table row. Both are what a rebuilt
# round must still carry exactly.
rebuild_entry_of() {   # rebuild_entry_of <tasks.json text>
  jq -cS --arg id "$TASK" '.tasks[]|select(.id==$id)' <<<"$1" 2>/dev/null
}
rebuild_rows_of() {   # rebuild_rows_of <design.md text>
  grep -E "^\| $TASK \|" <<<"$1" 2>/dev/null
}
# Which of the two files no longer carries what the previous head had for
# the task, read from the worktree or from the index (what a commit would
# take). One line per file; nothing when both survive.
rebuild_lost() {   # rebuild_lost worktree|index
  local tj dm own="design/tasks/$TASK.json"
  if [ "$rebuild_split" = 1 ]; then
    # one file per task: the entry is the task's own file, and there is no
    # table row to keep
    if [ "$1" = index ]; then tj="$(git -C "$tree" show ":$own" 2>/dev/null)"
    else tj="$(cat "$tree/$own" 2>/dev/null)"; fi
    [ -z "$rebuild_entry" ] || [ "$rebuild_entry" = "$(jq -cS . <<<"$tj" 2>/dev/null)" ] || echo "$own"
    return 0
  fi
  if [ "$1" = index ]; then
    tj="$(git -C "$tree" show :design/tasks.json 2>/dev/null)"
    dm="$(git -C "$tree" show :design/design.md 2>/dev/null)"
  else
    tj="$(cat "$tree/design/tasks.json" 2>/dev/null)"
    dm="$(cat "$tree/design/design.md" 2>/dev/null)"
  fi
  [ -z "$rebuild_entry" ] || [ "$rebuild_entry" = "$(rebuild_entry_of "$tj")" ] || echo design/tasks.json
  [ -z "$rebuild_rows" ] || [ "$rebuild_rows" = "$(rebuild_rows_of "$dm")" ] || echo design/design.md
}
# A tasks.json that merged cleanly can still carry main's edit of the
# task's own entry. Only that entry is put back, as the branch had it, and
# only in a file already in jq's layout; anything else is left for the
# worker, and the check before the commit holds the round until it is.
rebuild_task_entry_restore() {   # <old head>
  local f="design/tasks.json" mine cur next
  mine="$(git show "$1:$f" 2>/dev/null | jq -c --arg id "$TASK" '.tasks[]|select(.id==$id)' 2>/dev/null)"
  [ -n "$mine" ] || return 0
  cur="$(cat "$tree/$f" 2>/dev/null)" || return 1
  [ "$(jq . <<<"$cur" 2>/dev/null)" = "$cur" ] || return 1
  next="$(jq --arg id "$TASK" --argjson mine "$mine" '
    if any(.tasks[]; .id == $id) then .tasks |= map(if .id == $id then $mine else . end)
    else .tasks += [$mine] end' <<<"$cur" 2>/dev/null)" || return 1
  [ -n "$next" ] || return 1
  printf '%s\n' "$next" > "$tree/$f" && git -C "$tree" add -- "$f"
}
# A branch opened before T-090, rebuilt onto a base that keeps one file per
# task. Its design/tasks.json is a modify/delete conflict, or a clean
# deletion the merge made without asking, and either way the branch's
# entries would go with it. So every entry the branch added or changed
# since it left the base - the task's own and any other, since a design
# task writes other tasks' entries - is moved into its own file, and one the
# branch removed is removed. Nothing the branch said is dropped: where the
# base changed that same entry too, the file is written with standard
# conflict markers, the base's text against the branch's, and handed to the
# worker by name. The task's own entry is the branch's, always. The array
# then goes: nothing reads it on this base.
rebuild_tasks_split() {   # rebuild_tasks_split <merge-base> <old head>
  local f="design/tasks.json" t b line id file cur was
  t="$(git show "$2:$f" 2>/dev/null)" || return 0
  jq -e '.tasks | type == "array"' <<<"$t" >/dev/null 2>&1 || return 1
  b="$(git show "$1:$f" 2>/dev/null)" || b='{"tasks":[]}'
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    id="$(jq -r '.id // empty' <<<"$line")"
    if ! _fm_task_id "$id"; then
      echo "fm-worker: an entry in $f has no usable id and cannot become a file: $line" >&2
      return 1
    fi
    file="design/tasks/$id.json"
    was="$(jq -cS --arg id "$id" '[.tasks[]? | select(.id == $id)][0] // empty' <<<"$b" 2>/dev/null)"
    cur="$(cat "$tree/$file" 2>/dev/null)" || cur=''
    mkdir -p "$tree/design/tasks" || return 1
    if [ "$id" = "$TASK" ] || [ -z "$cur" ] \
       || [ "$(jq -cS . <<<"$cur" 2>/dev/null)" = "$was" ] \
       || [ "$(jq -cS . <<<"$cur" 2>/dev/null)" = "$(jq -cS . <<<"$line")" ]; then
      jq . <<<"$line" > "$tree/$file" && git -C "$tree" add -- "$file" || return 1
    else
      { printf '<<<<<<< %s\n%s\n=======\n' "$BASE" "$cur"; jq . <<<"$line"; printf '>>>>>>> %s\n' "$TASK"; } \
        > "$tree/$file" || return 1
      rebuild_split_conflicts+=("$file")
    fi
  done < <(jq -c --arg id "$TASK" --slurpfile b <(printf '%s' "$b") '
      ($b[0].tasks // [] | map({key: .id, value: .}) | from_entries) as $B
      | .tasks[] | select(.id == $id or $B[.id] != .)' <<<"$t" 2>/dev/null)
  # entries the branch removed from the array
  while IFS= read -r id; do
    _fm_task_id "$id" || continue
    file="design/tasks/$id.json"
    [ -f "$tree/$file" ] || continue
    was="$(jq -cS --arg id "$id" '.tasks[] | select(.id == $id)' <<<"$b" 2>/dev/null)"
    cur="$(cat "$tree/$file")"
    if [ "$(jq -cS . <<<"$cur" 2>/dev/null)" = "$was" ]; then
      git -C "$tree" rm -q -- "$file" >/dev/null 2>&1 || return 1
    else
      { printf '<<<<<<< %s\n%s\n=======\n>>>>>>> %s (removed %s)\n' "$BASE" "$cur" "$TASK" "$id"; } \
        > "$tree/$file" || return 1
      rebuild_split_conflicts+=("$file")
    fi
  done < <(jq -r --slurpfile t <(printf '%s' "$t") '
      [$t[0].tasks[].id] as $T | .tasks[]? | .id | select(. as $k | $T | any(. == $k) | not)' <<<"$b" 2>/dev/null)
  git -C "$tree" rm -q -f --ignore-unmatch -- "$f" >/dev/null 2>&1 || return 1
  rm -f "$tree/$f"
}
# The task's own file on a base that keeps one file per task, exactly as the
# branch had it: main may have edited it, cleanly or in a conflict. Byte for
# byte when the branch had the file; from its old array entry otherwise.
rebuild_own_file_restore() {   # <old head>
  local own="design/tasks/$TASK.json"
  [ -n "$rebuild_entry" ] || return 0
  [ "$(jq -cS . < "$tree/$own" 2>/dev/null)" != "$rebuild_entry" ] || return 0
  mkdir -p "$tree/design/tasks" || return 1
  if git cat-file -e "$1:$own" 2>/dev/null; then
    git show "$1:$own" > "$tree/$own" || return 1
  else
    fm_task "$TASK" design/tasks "$1" 2>/dev/null > "$tree/$own" || return 1
  fi
  git -C "$tree" add -- "$own"
}
# Where both sides only appended task-table rows at the same place, the
# union is taken - main's rows, then the task's - and the worker never
# sees it. Hunk by hunk: every other hunk is written back as a standard
# conflict (no diff3 base section) for the worker, so one prose conflict
# does not hand the row union back as well. The file is staged only when
# nothing is left; otherwise it stays unmerged, and so on the list.
rebuild_design_rows() {
  local f="design/design.md" out rc
  git -C "$tree" checkout -q --conflict=diff3 -- "$f" 2>/dev/null || return 1
  out="$(awk '
    function row(s) { return s ~ /^\| T-[A-Za-z0-9]+ \|/ }
    function flush(   i, j, dup, ok) {
      ok = (nb == 0 && no > 0 && nt > 0)
      for (i = 1; i <= no && ok; i++) if (!row(o[i])) ok = 0
      for (i = 1; i <= nt && ok; i++) if (!row(t[i])) ok = 0
      if (!ok) {
        unresolved++
        print opener; for (i = 1; i <= no; i++) print o[i]
        print "======="; for (j = 1; j <= nt; j++) print t[j]
        print closer
        return
      }
      for (i = 1; i <= no; i++) print o[i]
      for (j = 1; j <= nt; j++) {
        dup = 0; for (i = 1; i <= no; i++) if (o[i] == t[j]) dup = 1
        if (!dup) print t[j]
      }
    }
    state == 0 && /^<<<<<<<( |$)/ { state = 1; no = nb = nt = 0; opener = $0; next }
    state == 0 { print; next }
    state == 1 && /^\|\|\|\|\|\|\|( |$)/ { state = 2; next }
    (state == 1 || state == 2) && /^=======$/ { state = 3; next }
    state == 3 && /^>>>>>>>( |$)/ { closer = $0; state = 0; flush(); next }
    state == 1 { o[++no] = $0; next }
    state == 2 { nb++; next }
    state == 3 { t[++nt] = $0; next }
    END { if (state != 0) exit 2; exit (unresolved > 0) }
  ' "$tree/$f")"; rc=$?
  case "$rc" in
    0) printf '%s\n' "$out" > "$tree/$f" && git -C "$tree" add -- "$f" ;;
    1) printf '%s\n' "$out" > "$tree/$f"; return 1 ;;
    *) git -C "$tree" checkout -q --conflict=merge -- "$f" 2>/dev/null; return 1 ;;
  esac
}
# The task's table row, exactly as the branch had it. A merge can still
# carry main's edit of it, cleanly or inside a hunk the worker is handed;
# the task's is put back either way. Staged only when the file has no
# conflict left, or `add` would mark the markers resolved.
rebuild_design_row_survives() {   # <old head>
  local f="design/design.md" mine
  mine="$(rebuild_rows_of "$(git show "$1:$f" 2>/dev/null)" | head -1)"
  [ -n "$mine" ] || return 0
  grep -qE "^\| $TASK \|" "$tree/$f" 2>/dev/null || return 1
  MINE="$mine" awk -v id="| $TASK |" 'index($0, id) == 1 { print ENVIRON["MINE"]; next } { print }' \
    "$tree/$f" > "$tree/$f.fm-next" || { rm -f "$tree/$f.fm-next"; return 1; }
  mv "$tree/$f.fm-next" "$tree/$f" || return 1
  rebuild_unmerged "$f" || git -C "$tree" add -- "$f"
}
# Whether the branch still rebases onto the base: gate 2's own question,
# asked the way gate 2 asks it - `git rebase`, commit by commit, in a
# scratch worktree - not a second spelling of it. A squashed patch can
# apply where the replay does not (a later commit that undid an earlier
# one main also touched), and then gate 2 stays red on a branch this
# script would leave alone forever. The replay's commits are thrown away,
# so they are made under any identity, with no hook of the repository's
# run.
rebuild_rebases() {   # rebuild_rebases <head> <base ref>; 0 clean, 1 not, 2 unknown
  local rc n e
  n="$(fm_git_name "$tree")"; e="$(fm_git_email "$tree")"
  rebuild_probe="$(mktemp -d "${TMPDIR:-/tmp}/fm-worker-probe-XXXXXX")" || return 2
  git -c core.hooksPath=/dev/null worktree add -q --detach "$rebuild_probe" "$1" >/dev/null 2>&1 || {
    rm -rf "$rebuild_probe"; rebuild_probe=''; return 2; }
  git -C "$rebuild_probe" -c core.hooksPath=/dev/null -c rerere.enabled=false \
    -c user.name="${n:-fm-worker}" -c user.email="${e:-fm-worker@localhost}" \
    rebase "$2" >/dev/null 2>&1; rc=$?
  # A replay that stopped on a conflict leaves unmerged paths. One that
  # failed any other way - a signing key, a hook, a lock - answered nothing
  # about gate 2, and a rebuild on it would force-push a branch that may
  # well rebase.
  [ "$rc" = 0 ] || [ -n "$(git -C "$rebuild_probe" ls-files -u 2>/dev/null)" ] || rc=2
  git -C "$rebuild_probe" rebase --abort >/dev/null 2>&1
  rebuild_probe_drop
  case "$rc" in 0) return 0 ;; 2) return 2 ;; *) return 1 ;; esac
}
rebuild_probe_drop() {
  [ -n "${rebuild_probe:-}" ] || return 0
  git worktree remove --force "$rebuild_probe" >/dev/null 2>&1; rm -rf "$rebuild_probe"
  git worktree prune >/dev/null 2>&1; rebuild_probe=''
}
bring_up_to_date() {
  local base_ref="refs/remotes/origin/$BASE" head mb ls rc f side
  # The worktree was just made from the branch, so it is clean. Were it
  # not, the rebuild's own failure path (reset --hard) would destroy what
  # is in it, so a dirty tree is never rebuilt.
  if [ -n "$(git -C "$tree" status --porcelain 2>/dev/null)" ]; then
    echo "fm-worker: $tree is not clean; $branch is not rebuilt this round" >&2
    return 0
  fi
  git fetch -q origin "+refs/heads/$BASE:$base_ref" 2>/dev/null || {
    echo "fm-worker: could not fetch $BASE; $branch is not checked against it this round" >&2
    return 0; }
  head="$(git -C "$tree" rev-parse HEAD)" || return 0
  mb="$(git merge-base "$base_ref" "$head" 2>/dev/null)" || {
    echo "fm-worker: $branch shares no history with $BASE; not rebuilding it" >&2; return 0; }
  # already on the base: there is nothing to replay
  [ "$mb" != "$(git rev-parse "$base_ref")" ] || return 0
  rebuild_rebases "$head" "$base_ref"; rc=$?
  case "$rc" in
    0) return 0 ;;
    1) ;;
    *) echo "fm-worker: could not check whether $branch rebases onto $BASE; not rebuilding it" >&2
       return 0 ;;
  esac
  # the head the push will lease against: the remote's, as it is now. A
  # remote head this branch does not contain is work the rebuild would
  # overwrite, and nothing here has seen it.
  ls="$(git ls-remote --exit-code --heads origin "refs/heads/$branch" 2>/dev/null)"; rc=$?
  case "$rc" in
    0) rebuild_lease="$(printf '%s\n' "$ls" | awk 'NR == 1 { print $1 }')" ;;
    2) rebuild_lease='' ;;
    *) echo "fm-worker: could not read origin's $branch; not rebuilding it" >&2; return 0 ;;
  esac
  if [ -n "$rebuild_lease" ] && ! git merge-base --is-ancestor "$rebuild_lease" "$head" 2>/dev/null; then
    echo "fm-worker: origin's $branch has commits this worktree lacks; not rebuilding it" >&2
    return 0
  fi
  rebuild_prev="$head"; rebuild_base="$(git rev-parse "$base_ref")"
  # Up before the worktree leaves the branch, not after the merge: a signal
  # in between must find it set, so the exit path publishes nothing from a
  # detached, half-merged tree.
  rebuilt=1
  git -C "$tree" checkout -q --detach "$rebuild_base" || {
    echo "fm-worker: could not detach $tree at $BASE" >&2; exit 70; }
  git -C "$tree" -c merge.conflictStyle=merge -c rerere.enabled=false \
    merge -q --squash "$head" >/dev/null 2>&1; rc=$?
  # a merge that failed without leaving a conflict did not merge at all,
  # and the worker must not be handed the bare base as though it were
  # its branch
  if [ "$rc" != 0 ] && [ -z "$(git -C "$tree" diff --name-only -z --diff-filter=U)" ]; then
    echo "fm-worker: could not rebuild $branch on $BASE" >&2
    git -C "$tree" reset -q --hard 2>/dev/null
    git -C "$tree" checkout -q "$branch" 2>/dev/null
    exit 70
  fi
  # A base with no design/tasks.json but a design/tasks/ keeps one file per
  # task (T-090): the task's entry is its own file, read from the branch as
  # fm_task reads it - its own file, or its entry in the branch's old array.
  if ! git cat-file -e "$rebuild_base:design/tasks.json" 2>/dev/null \
     && [ -n "$(git ls-tree --name-only "$rebuild_base" -- design/tasks/ 2>/dev/null)" ]; then
    rebuild_split=1
  fi
  if [ "$rebuild_split" = 1 ]; then
    rebuild_entry="$(fm_task "$TASK" design/tasks "$head" 2>/dev/null | jq -cS . 2>/dev/null)"
    rebuild_rows=''
  else
    rebuild_entry="$(rebuild_entry_of "$(git show "$head:design/tasks.json" 2>/dev/null)")"
    rebuild_rows="$(rebuild_rows_of "$(git show "$head:design/design.md" 2>/dev/null)")"
  fi
  # Each repair below is best-effort, and says nothing when it cannot:
  # the check before the commit is what holds the round, on every path,
  # whether the repair failed or the worker undid it.
  if [ "$rebuild_split" = 1 ]; then
    rebuild_tasks_split "$mb" "$head" || true
    rebuild_own_file_restore "$head" || true
  elif rebuild_unmerged design/tasks.json; then
    rebuild_tasks_json "$mb" "$head" || true
  elif [ "$rebuild_entry" != "$(rebuild_entry_of "$(cat "$tree/design/tasks.json" 2>/dev/null)")" ]; then
    rebuild_task_entry_restore "$head" || true
  fi
  if rebuild_unmerged design/design.md; then
    rebuild_design_rows || true
  fi
  # a base with no table has no row to put back
  [ "$rebuild_split" = 1 ] || rebuild_design_row_survives "$head" || true
  # NUL-separated: without -z, git quotes a name outside ASCII
  # ("\346\226\207.txt"), and that string names no file in the worktree
  while IFS= read -r -d '' f; do
    [ -n "$f" ] && rebuild_conflicts+=("$f")
  done < <(git -C "$tree" diff --name-only -z --diff-filter=U)
  # the entries both sides changed, written with markers by the move above;
  # git does not know them as conflicts, so they are added by name
  for f in ${rebuild_split_conflicts[@]+"${rebuild_split_conflicts[@]}"}; do
    rebuild_unmerged "$f" || rebuild_conflicts+=("$f")
  done
  # A conflict with no marker in it - binary, or deleted on one side - has
  # one side sitting in the worktree looking resolved. `add -A` would
  # commit that side whole, so each is described as what it is and held
  # until the worker changes it.
  for f in ${rebuild_conflicts[@]+"${rebuild_conflicts[@]}"}; do
    [ -f "$tree/$f" ] && grep -qIE '^(<<<<<<<|>>>>>>>)( |$)' "$tree/$f" 2>/dev/null && continue
    side="$(rebuild_side_left "$f")"
    rebuild_bare+=("$f"); rebuild_bare_left+=("$(rebuild_state_of "$f")"); rebuild_bare_side+=("$side")
  done
  # a file that merged but still lost the task's entry or row goes to the
  # worker too, by name; a conflicted one is already on the list above
  while IFS= read -r f; do
    [ -n "$f" ] && ! rebuild_unmerged "$f" && rebuild_restore+=("$f")
  done < <(rebuild_lost worktree)
  rebuild_mark="$(rebuild_fingerprint)"
  echo "fm-worker: $branch no longer rebases onto $BASE; rebuilt on ${rebuild_base:0:12} from ${rebuild_prev:0:12}" \
       "(${#rebuild_conflicts[@]} conflicting)" >&2
  emit_status "Rebuilt $branch on $BASE" "已把 $branch 重建在 $BASE 上"
}
if [ "$round_two" = 1 ]; then bring_up_to_date; fi

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
  if [ "$rebuilt" = 1 ]; then
    printf '\n---\n\n# Your branch was rebuilt on the current %s\n\n' "$BASE"
    printf '%s moved under this branch and the branch no longer rebased onto it,\n' "$BASE"
    printf 'so fm-worker.sh rebuilt it: your change so far (previous head %s)\n' "$rebuild_prev"
    printf 'was applied three-way onto %s at %s. It is staged, not committed;\n' "$BASE" "$rebuild_base"
    printf 'fm-worker.sh commits it with this round as one commit on %s.\n' "$BASE"
    if [ "${#rebuild_conflicts[@]}" -gt 0 ]; then
      marked_list=()
      for f in "${rebuild_conflicts[@]}"; do
        bare=0
        for g in ${rebuild_bare[@]+"${rebuild_bare[@]}"}; do [ "$g" != "$f" ] || bare=1; done
        [ "$bare" = 1 ] || marked_list+=("$f")
      done
      if [ "${#marked_list[@]}" -gt 0 ]; then
        printf '\nThese files conflict and carry standard conflict markers:\n\n'
        printf -- '- `%s`\n' "${marked_list[@]}"
      fi
      if [ "${#rebuild_bare[@]}" -gt 0 ]; then
        printf '\nThese files conflict but git could not write markers into them (a\n'
        printf 'binary file, or one side deleted what the other changed). One side\n'
        printf 'is sitting in the worktree and looks resolved; it is not:\n\n'
        for i in "${!rebuild_bare[@]}"; do
          printf -- '- `%s`: the worktree holds %s\n' "${rebuild_bare[$i]}" "${rebuild_bare_side[$i]}"
        done
        printf '\nDecide what each should be with both changes in mind. A round that\n'
        printf 'leaves one exactly as the merge left it is refused.\n'
      fi
      printf '\nResolve every one before anything else. Keep BOTH sides: %s'"'"'s change\n' "$BASE"
      printf 'and your task'"'"'s intent. Never take a whole side, and never drop %s'"'"'s change.\n' "$BASE"
      printf 'A conflict marker left in any file this commit carries refuses the commit.\n'
    else
      printf '\nEvery file applied cleanly; there is nothing to resolve.\n'
    fi
    if [ "${#rebuild_restore[@]}" -gt 0 ]; then
      printf '\nThe rebuild could not keep your task'"'"'s own entry or table row in:\n\n'
      printf -- '- `%s`\n' "${rebuild_restore[@]}"
      printf '\nPut it back exactly as it is at %s, keeping %s'"'"'s other changes.\n' "$rebuild_prev" "$BASE"
    fi
    if [ "$rebuild_split" = 1 ]; then
      # T-090: the base keeps one file per task and no task table
      printf '\n%s keeps one file per task, design/tasks/<id>.json, and no task\n' "$BASE"
      printf 'table in design/design.md. Your task'"'"'s entry is design/tasks/%s.json and\n' "$TASK"
      printf 'must come through exactly as it is at %s; a rebuilt round that\n' "$rebuild_prev"
      printf 'changes it is refused, like one that leaves a conflict marker. If your\n'
      printf 'branch still had design/tasks.json, the rebuild has already moved every\n'
      printf 'entry your branch added or changed into its own file and removed the\n'
      printf 'array; a row your branch added to the old table goes with the table.\n'
    else
      printf '\nYour task'"'"'s design/tasks.json entry and design/design.md table row must\n'
      printf 'come through exactly as they are at %s; a rebuilt round that changes\n' "$rebuild_prev"
      printf 'either is refused, like one that leaves a conflict marker.\n'
    fi
    printf '\nThe worktree is detached until fm-worker.sh commits, so fm-checkpoint.sh\n'
    printf 'refuses this round. That is expected: fm-worker.sh pushes the rebuild.\n'
    printf 'Do not commit in it yourself: a round whose HEAD is no longer %s is\n' "$rebuild_base"
    printf 'refused too.\n'
  fi
  printf '\n---\n\n# The design\n\n'
  sed -n '/^## 6\./,/^## 8\./p' design/design.md 2>/dev/null
} > "$prompt"

# --- the adapter, with fallback only on a vendor being unavailable -------
# The worker's evidence: files changed in the worktree. The prompt lives
# there too, so it comes out of the count or every run looks busy.
# A rebuilt worktree is dirty before the engine starts, so there it is the
# difference from what the rebuild left that counts - or every vendor would
# look busy, and an unavailable one would be read as having done work.
worker_changed_files() {
  if [ "$rebuilt" = 1 ]; then
    [ "$(rebuild_fingerprint)" != "$rebuild_mark" ]
    return
  fi
  [ -n "$(git -C "$tree" status --porcelain -- . \
      ":(exclude).fm-prompt.md" ":(exclude).fm-say.md")" ]
}
worker_did_work() {
  worker_changed_files || [ -s "$tree/.fm-say.md" ]
}
# A rebuild that applied - nothing unresolved handed to the worker - is
# this round's work on its own, and is published whatever the worker did
# with it: nothing, a note, or a question. Left for a later round, the
# branch stayed on its old head, DIRTY on GitHub, until the captain pushed
# it by hand (T-098). Unresolved is a conflict, and also the task's own
# entry or row the rebuild could not keep (rebuild_restore): the check
# before the commit refuses that rebuild as it stands, the way it refuses
# a marker, so it is the worker's to resolve like one.
rebuild_unresolved() {
  [ "${#rebuild_conflicts[@]}" -gt 0 ] || [ "${#rebuild_restore[@]}" -gt 0 ]
}
rebuild_publishes() {
  [ "$rebuilt" = 1 ] && ! rebuild_unresolved
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
# where a plain round starts: a mid-run fm-checkpoint.sh commits on top of
# it, and what the round adds is read against this, not the last save
round_start="$(git -C "$tree" rev-parse -q --verify HEAD 2>/dev/null)"
# The round's permission policy (T-105): config.yaml's, for a worker, with
# this project's override - never the operator's own CLI settings. Every
# adapter confines its CLI to it or refuses the round; a policy that does
# not read is a configuration error, not an unconfined round.
policy_file="$FM_RUN_DIR/policy.json"; blocked_file="$FM_RUN_DIR/blocked-hosts"
: > "$blocked_file"
fm_policy worker "" config.yaml > "$policy_file" || {
  echo "fm-worker: config.yaml's crew policy does not read; no round runs without one" >&2; exit 65; }
export FM_POLICY="$policy_file" FM_POLICY_BLOCKED="$blocked_file"
# A host the round's proxy refused is reported, not allowed: the crew
# never widens its own policy. Firstmate reads the record and raises the
# choice card that adds it to the project's registries.
report_blocked_hosts() {   # report_blocked_hosts <role> <file>
  local hosts
  hosts="$(fm_policy_report "$REPO" "$1" "$TASK" "$NAME" "$2")"
  [ -n "$hosts" ] || return 0
  echo "fm-worker: the round was refused undeclared hosts: $hosts; adding one to the project's policy network is the captain's choice" >&2
  emit_status "Refused undeclared hosts: $hosts" "被拒的未宣告主機：${hosts}"
}
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
report_blocked_hosts worker "$blocked_file"
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
save_unsent() {   # save_unsent <file>; copies it under state/unsent/ and says where
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
}
keep_unsent() {   # keep_unsent <file>; reads $PR, never returns
  note_refused "$1"
  exit 73
}
note_refused() {   # note_refused <file>; keeps it and says why, and returns
  # the held note included: this is its keeping, and the EXIT trap
  # must not keep it a second time
  held_settled=1
  save_unsent "$1"
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
}
# A note is not only a question. An adapter that may edit but not execute
# finishes the work and says which checks it could not run, and on a
# first round that note used to be read as a question asked before there
# was a pull request: kept, exit 73, and the work in the worktree never
# reached one. A note beside real changes waits for the pull request this
# round is about to open. It is set aside OUT of the worktree first, so
# the commit below cannot take it even from a branch that tracks it.
#
# From here the scratch copy is the only one, so every way out before it
# is posted - a refused push (71), a url with no number (72), a signal -
# goes through the EXIT trap, which keeps it with lost_held. It used to
# go with the rest of the scratch files. held is set only once the copy
# is whole, so a failed cp leaves the original in the worktree instead.
held=''
held_settled=0
lost_held() {   # lost_held <rc>; from the EXIT trap, so it returns
  held_settled=1
  echo "fm-worker: the run ended (exit $1) before the worker's note reached a pull request" >&2
  save_unsent "$held"
  emit --type worker_crashed ${PR:+--pr "$PR"} \
       --en "the worker's note was not posted: the run ended (exit $1) before it reached a pull request" \
       --tw "工人的留言沒有貼出：執行在送到 PR 之前就結束了（exit ${1}）"
}
if [ "$asked" = 1 ] && [ -z "$PR" ] && { worker_changed_files || rebuild_publishes; }; then
  _held="$(scratch_new)" || _held=''
  [ -n "$_held" ] || { echo "fm-worker: could not make a scratch file" >&2; exit 70; }
  scratch_add "$_held"
  cp "$say" "$_held" || { echo "fm-worker: could not set the worker's note aside" >&2; exit 70; }
  held="$_held"
fi
if [ "$asked" = 1 ] && [ -n "$PR" ]; then
  post_note "$say" "$PR"
fi
# A note the pull request refused ends the round with 73, but not before a
# rebuild the round can commit is published: exiting here would leave the
# branch on its old head, the way the asking exit did (T-098). The note is
# kept now, once, and never posted again - a refusal gh reported after
# GitHub stored the comment would be a second copy - so no exit on the
# way to the push can lose it. A later failure there ends the round with
# its own code instead.
refused=0
if [ "$asked" = 1 ] && [ "$spoke" = 0 ] && [ -z "$held" ] && [ -n "$PR" ] && [ "$rebuilt" = 1 ] \
   && { worker_changed_files || rebuild_publishes; }; then
  note_refused "$say"
  refused=1
fi
# held means the note waits for the pull request opened below: the only
# case where the note not landing yet is not the end of the round
if [ "$asked" = 1 ] && [ "$spoke" = 0 ] && [ -z "$held" ] && [ "$refused" = 0 ]; then
  keep_unsent "$say"
fi
rm -f "$say"

# asking IS the work in a round that begins with a question, and the round
# after it is the one that changes files. A rebuild this round made is not
# a change the worker made, but one that applied is published all the same
# (rebuild_publishes). A rebuild left unresolved publishes nothing, and
# the next round rebuilds again from the branch as it stands.
# Said here, where it is already true, so a round that fails on the way to
# the push still reports that it asked.
if [ "$asked" = 1 ] && ! worker_changed_files; then
  if ! rebuild_publishes; then
    echo "fm-worker: the worker asked rather than changed anything; its question is on #$PR" >&2
    printf '%s\n' "$branch"
    exit 0
  fi
  if [ -n "$held" ]; then
    asked_where="its question waits for the pull request this round opens"
  elif [ "$refused" = 1 ]; then
    asked_where="#$PR would not take its question"
  else
    asked_where="its question is on #$PR"
  fi
  echo "fm-worker: the worker asked rather than changed anything; $asked_where; the rebuild applied, so it is published all the same" >&2
fi

# the same predicate the chain was given, not a second spelling of it: the
# two agreed only because the prompt happened to be removed between them.
# A rebuild is work in its own right: a branch brought up to date with
# nothing else to add is still committed and pushed.
if [ "$rebuilt" = 0 ] && ! worker_did_work; then
  echo "fm-worker: the adapter changed nothing" >&2
  emit --type gate_failed --en "the adapter changed nothing" --tw "adapter 沒有改動任何檔案"
  exit 1
fi

# --- from here on it is the script's job, never the adapter's ------------
# Every step from here to the push is checked where it stands. This script
# does not run under `set -e`, so a git command that fails and is not
# tested is simply stepped over - and the run goes on to report a commit
# it never made.
rebuild_refuse() {   # rebuild_refuse <what, en> <what, zh-TW>
  echo "fm-worker: $1" >&2
  echo "fm-worker: nothing is committed or pushed; the branch stays at ${rebuild_prev}" >&2
  echo "fm-worker: the worktree is left at $tree; the next round rescues it and rebuilds from the branch" >&2
  emit --type gate_failed ${PR:+--pr "$PR"} --en "$1; not committed" --tw "${2}，沒有 commit"
  exit 75
}
# Everything below reads the rebuild against the base it was made on, and
# the commit below lands on HEAD. The two are one only while HEAD is still
# that base, detached: a commit made on it mid-round - a worker's own, or
# any save - would sit under the round, outside every check here, and go
# out with it.
if [ "$rebuilt" = 1 ]; then
  now_head="$(git -C "$tree" rev-parse -q --verify HEAD 2>/dev/null)"
  if [ "$now_head" != "$rebuild_base" ] || git -C "$tree" symbolic-ref -q HEAD >/dev/null 2>&1; then
    rebuild_refuse "HEAD moved off the rebuild base ${rebuild_base} during the round (now ${now_head:-unreadable}$(git -C "$tree" symbolic-ref -q --short HEAD 2>/dev/null | sed 's/^/ on /'))" \
      "這輪中途 HEAD 離開了重建的基底 ${rebuild_base}"
  fi
fi
git -C "$tree" add -A || { echo "fm-worker: could not stage the round on $branch" >&2; exit 70; }
# A rebuilt round is committed only once every handed-over conflict is
# resolved. Every file this commit carries is read - on a rebuild that is
# the task's whole change - not just the ones listed, because a marker the
# worker copied elsewhere is as broken as one it left in place. From the
# index, since that is what would be committed.
if [ "$rebuilt" = 1 ]; then
  carried=(); marked=()
  while IFS= read -r -d '' f; do carried+=("$f"); done \
    < <(git -C "$tree" diff --cached --name-only -z --diff-filter=d "$rebuild_base")
  if [ ${#carried[@]} -gt 0 ]; then
    # exit 1 is "no marker anywhere"; anything above it is a grep that did
    # not read the files, and that is not the same answer
    # names NUL-separated, as above, so the refusal names the real file;
    # turned back into lines here, since a substitution drops NULs
    found="$(git -C "$tree" --literal-pathspecs grep --cached -l -z -E '^(<<<<<<<|>>>>>>>)( |$)' \
               -- "${carried[@]}" 2>/dev/null | tr '\0' '\n'; exit "${PIPESTATUS[0]}")"; grc=$?
    [ "$grc" -le 1 ] || { echo "fm-worker: could not read the rebuilt $branch for conflict markers" >&2; exit 70; }
    while IFS= read -r f; do
      [ -n "$f" ] && marked+=("$f")
    done <<<"$found"
  fi
  if [ ${#marked[@]} -gt 0 ]; then
    listed="$(printf '%s, ' "${marked[@]}")"; listed="${listed%, }"
    rebuild_refuse "conflict markers remain in: ${listed}" "衝突標記還留在 ${listed}"
  fi
  # a conflict with no markers, still exactly the side the merge left
  untouched=()
  for i in ${rebuild_bare[@]+"${!rebuild_bare[@]}"}; do
    [ "$(rebuild_state_of "${rebuild_bare[$i]}")" != "${rebuild_bare_left[$i]}" ] \
      || untouched+=("${rebuild_bare[$i]}")
  done
  if [ ${#untouched[@]} -gt 0 ]; then
    listed="$(printf '%s, ' "${untouched[@]}")"; listed="${listed%, }"
    rebuild_refuse "conflicts with no markers are still as the merge left them: ${listed}" \
      "沒有衝突標記的衝突還是合併留下的樣子：${listed}"
  fi
  # the task's own entry and row, exactly as the previous head had them,
  # whatever repaired or resolved them on the way here
  lost=()
  while IFS= read -r f; do [ -n "$f" ] && lost+=("$f"); done < <(rebuild_lost index)
  if [ ${#lost[@]} -gt 0 ]; then
    listed="$(printf '%s, ' "${lost[@]}")"; listed="${listed%, }"
    rebuild_refuse "the task's own entry or table row is not as ${rebuild_prev} had it in: ${listed}" \
      "任務自己的條目或表格列跟 ${rebuild_prev} 不一樣：${listed}"
  fi
fi
# A script the round adds keeps its executable bit. The claude worker's
# sandbox refuses chmod, so every script a worker added was committed
# 100644 and a suite that ran it by path failed with 126 (T-048, T-059).
# The bit is set in the index, which needs no permission of the worker's,
# and on disk as well where it can be, so the worktree agrees with the
# commit. Only on a file this round adds - absent from where the round
# started (a mid-run checkpoint does not count as a start: it commits with
# the same missing bit), and on a rebuild from the base and the previous
# head both - under bin/ or
# tests/, starting with a shebang, in a directory that already holds an
# executable script. A bit is never removed, and no other file is touched.
dir_runs_scripts() {   # dir_runs_scripts <commit> <dir>: an executable script already there
  local e meta tab=$'\t'
  while IFS= read -r -d '' e; do
    meta="${e%%"$tab"*}"
    [ "${meta%% *}" = 100755 ] || continue
    [ "$(git -C "$tree" cat-file blob "${meta##* }" 2>/dev/null | head -c 2 | tr -d '\0')" = '#!' ] && return 0
  done < <(git -C "$tree" ls-tree -z "$1" -- "$2/" 2>/dev/null)
  return 1
}
new_scripts_executable() {   # new_scripts_executable <commit the round started from> [<previous head>]
  local f
  while IFS= read -r -d '' f; do
    case "$f" in bin/*|tests/*) ;; *) continue ;; esac
    [ -z "${2:-}" ] || ! git -C "$tree" cat-file -e "$2:$f" 2>/dev/null || continue
    [ "$(git -C "$tree" --literal-pathspecs ls-files -s -- "$f" | cut -c1-6)" = 100644 ] || continue
    [ "$(git -C "$tree" cat-file blob ":$f" 2>/dev/null | head -c 2 | tr -d '\0')" = '#!' ] || continue
    dir_runs_scripts "$1" "${f%/*}" || continue
    # the index first: a bit it refuses is not left on disk for the exit's
    # checkpoint to carry, as though the round had set it
    git -C "$tree" --literal-pathspecs update-index --chmod=+x -- "$f" || return 1
    chmod +x "$tree/$f" 2>/dev/null || true
    echo "fm-worker: $f is a new script; it is committed executable" >&2
  done < <(git -C "$tree" diff --cached --name-only -z --diff-filter=A "$1")
}
if [ "$rebuilt" = 1 ]; then
  new_scripts_executable "$rebuild_base" "$rebuild_prev"
else
  new_scripts_executable "${round_start:-HEAD}"
fi || { echo "fm-worker: could not set the executable bit on a new script on $branch; the round is not committed" >&2; exit 70; }
# A rebuilt round is committed with commit-tree, from the staged tree and
# parented on the fetched base, rather than by `git commit` on the detached
# HEAD: the repository's pre-commit hook refused every commit on a detached
# HEAD, and so every real rebuild (T-093). No hook is stepped around on a
# protected branch - this commit is on no branch at all until the push
# below lands, and then only on the task's.
#
# Once made, HEAD is moved onto it, detached, as `git commit` would have
# left it: the index and worktree already hold its tree, so the worktree
# is clean. Every exit between here and the branch move - a refused lease,
# a failed record - relies on that. Left on the base with the rebuild
# staged, the next round would take a pushed or refused commit for an
# uncommitted round and rescue it as crashed work.
commit_msg="$TASK: $(jq -r .title <<<"$spec")"
rebuilt_head=''; commit_ok=0
if [ "$rebuilt" = 1 ]; then
  # fm_git_commit (bin/fm-config.sh) is the identity rule, a refusal and
  # `commit -q -m`; this is the same rule and refusal, applied to
  # commit-tree. What commit does beyond that and commit-tree does not is
  # run the hooks - the point here - and clean up the message, which is
  # one line. commit also signs when commit.gpgSign says to; commit-tree,
  # being plumbing, ignores that setting, so it is read here and passed
  # on as -S.
  rb_name="$(fm_git_name "$tree")"; rb_email="$(fm_git_email "$tree")"
  rb_sign=''
  [ "$(git -C "$tree" config --bool commit.gpgSign 2>/dev/null)" != true ] || rb_sign=-S
  if [ -z "$rb_name" ] || [ -z "$rb_email" ]; then
    echo "fm: set git user.name and user.email (or FM_GIT_NAME / FM_GIT_EMAIL) before committing" >&2
  elif rebuilt_tree="$(git -C "$tree" write-tree)" && [ -n "$rebuilt_tree" ]; then
    rebuilt_head="$(git -C "$tree" -c user.name="$rb_name" -c user.email="$rb_email" \
      commit-tree ${rb_sign:+"$rb_sign"} "$rebuilt_tree" -p "$rebuild_base" -m "$commit_msg" </dev/null)" || rebuilt_head=''
    if [ -n "$rebuilt_head" ] && git -C "$tree" update-ref --no-deref -m "fm-worker: rebuilt $branch" \
         HEAD "$rebuilt_head" "$rebuild_base"; then
      commit_ok=1
    fi
  fi
elif fm_git_commit "$tree" "$commit_msg"; then
  commit_ok=1
fi
if [ "$commit_ok" != 1 ]; then
  # Stop here, rebuilt or not. A plain round would otherwise push a branch
  # without this round's work and say it had committed; a rebuilt one
  # would move the branch onto the bare base below.
  echo "fm-worker: could not commit on $branch; nothing is pushed" >&2
  emit --type gate_failed ${PR:+--pr "$PR"} --en "could not commit on $branch" --tw "無法在 $branch 上 commit"
  exit 70
fi
_fm_wip_done=1
if [ "$rebuilt" = 1 ]; then
  # Pushed by its id first; the local branch moves only once origin has
  # taken it. Until then refs/fm-rebuilt/ names the commit, so a run cut
  # short in between settles on origin's answer (rebuild_settle).
  git -C "$REPO" update-ref "refs/fm-rebuilt/$branch" "$rebuilt_head" || {
    echo "fm-worker: could not record the rebuilt commit ${rebuilt_head}; nothing is pushed" >&2; exit 70; }
  # Leased on the head fetched before the rebuild, never a bare --force:
  # anything pushed to the branch since is refused rather than overwritten.
  # An empty lease means the branch must still not exist on origin.
  if ! git -C "$tree" push -q --force-with-lease="refs/heads/$branch:$rebuild_lease" \
       origin "$rebuilt_head:refs/heads/$branch" 2>/dev/null; then
    # refused: the local branch never moved; the rebuilt commit stays
    # reachable by the id printed here
    rebuild_settle || true
    echo "fm-worker: could not push the rebuilt $branch: origin no longer has ${rebuild_lease:-no such branch}, or refused" >&2
    echo "fm-worker: the rebuilt commit is ${rebuilt_head}; $branch is back at $(git -C "$REPO" rev-parse -q --verify "refs/heads/$branch")" >&2
    exit 71
  fi
  # origin has it: only now the local branch. HEAD, the index and the
  # worktree are already on it, so this moves the branch and attaches HEAD.
  git -C "$tree" checkout -q -B "$branch" "$rebuilt_head" || {
    echo "fm-worker: the rebuilt $branch (${rebuilt_head}) is on origin, but $branch could not be moved onto it; the next round does" >&2
    exit 70; }
  git -C "$tree" branch -q -u "origin/$branch" >/dev/null 2>&1 || true
  git -C "$REPO" update-ref -d "refs/fm-rebuilt/$branch" 2>/dev/null \
    || echo "fm-worker: could not clear refs/fm-rebuilt/$branch; the next round settles it" >&2
  echo "fm-worker: $branch rebuilt on $BASE; the previous head was ${rebuild_prev}" >&2
else
  git -C "$tree" push -q -u origin "$branch" 2>/dev/null || {
    echo "fm-worker: could not push $branch" >&2; exit 71; }
fi
# Only now: a push that was refused - a lease above, or a plain one - left
# a commit that is not on origin, and the log must not say it was pushed.
emit_status "Commit pushed on $branch" "已在 $branch 上推送 commit"
emit --type commit_pushed --en "committed on $branch" --tw "已在 $branch 上 commit"
rebuild_args=()
if [ "$rebuilt" = 1 ]; then
  rebuild_args=(--data "$(jq -cn --arg prev "$rebuild_prev" --arg base "$BASE" \
    --arg base_head "$rebuild_base" --arg head "$(git -C "$tree" rev-parse HEAD)" \
    '{rebuilt:{previous_head:$prev,base:$base,base_head:$base_head,head:$head,
      conflicts:$ARGS.positional}}' --args ${rebuild_conflicts[@]+"${rebuild_conflicts[@]}"})")
fi

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
        --body "Dispatched by firstmate for $TASK. Acceptance is in design/tasks/$TASK.json." \
        2>/dev/null </dev/null | tail -1)"
  # the number, not the url: every step after this addresses the pull
  # request by it, and an event without it leaves the gates checking nothing
  num="$(printf '%s' "$url" | sed -n 's|.*/\([0-9][0-9]*\)$|\1|p')"
  [ -n "$num" ] || { echo "fm-worker: could not read a pull request number from '$url'" >&2; exit 72; }
  emit_status "Pull request #$num opened" "已開 PR #$num"
  emit --type pr_opened --pr "$num" ${rebuild_args[@]+"${rebuild_args[@]}"} \
       --en "opened #$num" --tw "已開 #$num"
else
  emit_status "Pushed another round to #$num" "已推第二輪到 #$num"
  emit --type commit_pushed --pr "$num" ${rebuild_args[@]+"${rebuild_args[@]}"} \
       --en "pushed another round to #$num" --tw "第二輪已推上 #$num"
fi
# The reviewer reads the pull request, and after a rebuild the diff it saw
# last is gone from the branch. The previous head is what it compares
# against, so it goes on the pull request as well as into the event.
if [ "$rebuilt" = 1 ]; then
  if [ "${#rebuild_conflicts[@]}" -gt 0 ]; then
    handed="$(printf '`%s`, ' "${rebuild_conflicts[@]}")"; handed="${handed%, }"
  else
    handed='none'
  fi
  if ! $GH pr comment "$num" --body "$(printf '%s\n' \
       "fm-worker.sh rebuilt \`$branch\` as one commit on \`$BASE\` at \`$rebuild_base\`: it no longer rebased onto it cleanly." \
       "" "Previous head: \`$rebuild_prev\`" "New head: \`$(git -C "$tree" rev-parse HEAD)\`" \
       "Conflicts handed to the worker: $handed")" \
       >/dev/null 2>&1 </dev/null; then
    echo "fm-worker: could not note the rebuild on #$num; the previous head was ${rebuild_prev}" >&2
  fi
fi
# the note that waited for a pull request has one now. Refused, it is
# kept and the run fails the way a refused note on an existing pull
# request does - the work and the pull request stand either way.
if [ -n "$held" ]; then
  PR="$num"
  post_note "$held" "$num"
  [ "$spoke" = 1 ] && held_settled=1
  [ "$spoke" = 1 ] || keep_unsent "$held"
fi
# the note refused above was kept there; the rebuild is out, and the round
# ends the way a refused note ends it
[ "$refused" = 0 ] || exit 73
printf '%s\n' "$branch"
[ "${rc:-1}" = "0" ] || exit 1
exit 0
