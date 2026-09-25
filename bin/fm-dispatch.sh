#!/usr/bin/env bash
# Decides what may start. Five things can stop it and all five are checks
# against the log or the filesystem, never a judgement call:
#
#   - no greenlit event for the work      -> nothing starts (the eighth gate)
#   - a dependency is not merged yet      -> that task waits
#   - the captain parked or dropped it    -> it waits until unparked, or never
#   - concurrency is already spent        -> the rest wait
#   - the captain has not answered A to the task's readiness card
#                                         -> that task waits (T-059)
#
# The last is the captain's judgement, read back from where it was recorded
# (bin/fm-ready.sh cleared); this script makes none. A task the captain
# orders directly - or a B rescope firstmate has carried out - is started
# with --task: that order is the captain's word on it, so it lifts the last
# check and no other. Only the named task is considered, and it says why
# when it does not start.
#
#   fm-dispatch.sh [--repo .] [--dry-run] [--limit N] [--task <id>]
set -uo pipefail
# Nothing below may read standard input. A dispatched child inherits it, and
# a child that reads it blocks the caller waiting for a human who is not
# there. One guarantee, in one place; bin/ci.sh fails if a script that
# dispatches is missing it.
exec < /dev/null
_fm_lib="$(dirname "${BASH_SOURCE[0]}")/fm-config.sh"
[ -f "$_fm_lib" ] || { echo "${0##*/}: missing $_fm_lib" >&2; exit 70; }
# shellcheck source=bin/fm-config.sh
. "$_fm_lib"
fm_args=("$@")

REPO="${FM_ROOT:-$(pwd)}"; DRY=0; LIMIT=''; ORDERED=''
while [ $# -gt 0 ]; do
  case "$1" in
    --repo) fm_need "fm-dispatch" "$@"; REPO="${2-}"; shift 2 ;;
    --dry-run) DRY=1; shift ;;
    --limit) fm_need "fm-dispatch" "$@"; LIMIT="${2-}"; shift 2 ;;
    --task) fm_need "fm-dispatch" "$@"; ORDERED="${2-}"; shift 2 ;;
    *) echo "fm-dispatch: unknown argument $1" >&2; exit 64 ;;
  esac
done
cd "$REPO" || { echo "fm-dispatch: no repo at $REPO" >&2; exit 64; }
REPO="$(pwd -P)"
fm_freeze "$0" "$REPO" ${fm_args[@]+"${fm_args[@]}"}
LOG="$REPO/state/events.jsonl"
emit() { FM_ROOT="$REPO" "$REPO/bin/fm-emit.sh" --actor firstmate "$@" >/dev/null 2>&1 </dev/null || true; }
if [ -n "$ORDERED" ] && ! fm_task "$ORDERED" design/tasks >/dev/null 2>&1; then
  echo "fm-dispatch: --task $ORDERED has no file in design/tasks/" >&2
  exit 64
fi

# --- the eighth gate: nothing starts before the captain has seen a proposal
if ! [ -f "$LOG" ] || ! jq -e 'select(.type=="greenlit")' "$LOG" >/dev/null 2>&1; then
  echo "fm-dispatch: no greenlit event - nothing is dispatched" >&2
  exit 1
fi

evt() { jq -r --arg t "$1" 'select(.type==$t)|.task // empty' "$LOG" 2>/dev/null | sort -u; }
done_tasks="$(evt merged)"
started="$(evt dispatched)"
# a task whose pull request is open is being worked on, whoever started it.
# Without this a task waiting for the captain is dispatched again and a
# second worker pushes onto a branch a reviewer has already signed.
open_prs="$(jq -r 'select(.type=="pr_opened")|.task // empty' "$LOG" 2>/dev/null | sort -u)"
settled_prs="$(jq -r 'select(.type=="merged" or .type=="closed")|.task // empty' "$LOG" 2>/dev/null | sort -u)"
closed_tasks="$(evt closed)"
finished="$(printf '%s\n%s\n' "$done_tasks" "$closed_tasks" | sort -u)"
inflight="$(comm -23 <(printf '%s\n%s\n' "$started" "$open_prs" | sort -u | sed '/^$/d') \
                     <(printf '%s\n%s\n' "$finished" "$settled_prs" | sort -u | sed '/^$/d') \
             | sed '/^$/d')"
n_inflight="$(printf '%s\n' "$inflight" | sed '/^$/d' | wc -l | tr -d ' ')"

limit="${LIMIT:-$(fm_cfg concurrency)}"
[ -n "$limit" ] || limit=3
slots=$(( limit - n_inflight ))
if [ "$slots" -le 0 ]; then
  # a named task is told why on stderr, like every other check that holds it
  [ -z "$ORDERED" ] || echo "fm-dispatch: $ORDERED waits for a slot: $n_inflight in flight, limit $limit" >&2
  echo "fm-dispatch: $n_inflight in flight, limit $limit - nothing to start"
  exit 0
fi

# here-strings throughout: a grep -q that matches early kills the producer
# of a pipeline, and under pipefail that reads as "no match"
is_done()    { grep -qx "$1" <<< "$done_tasks"; }
is_busy()    { grep -qx "$1" <<< "$inflight"; }
# closed is abandoned, not failed: it frees the slot but is never retried on
# its own. Restarting it is a decision, and decisions belong to the captain.
# read once, like the others: a function that re-runs the query inside a
# pipeline is one pipefail away from answering the wrong question
is_closed()  { grep -qx "$1" <<< "$closed_tasks"; }
# parked is the captain setting a task aside: it is never started while the
# last parked/unparked event said parked. Only an unparked brings it back.
parked_tasks="$(jq -r 'select(.type=="parked" or .type=="unparked")|select(.task // "" | . != "")
  |"\(.task)\t\(.type)"' "$LOG" 2>/dev/null \
  | awk -F'\t' '{ last[$1] = $2 } END { for (t in last) if (last[t] == "parked") print t }' | sort -u)"
is_parked()  { grep -qx "$1" <<< "$parked_tasks"; }
# why a task did not start: said only for the task the captain named, since
# for the rest not starting is the ordinary case
held() { [ -z "$ORDERED" ] || echo "fm-dispatch: $1" >&2; }

# the task list, read once: one file per task under design/tasks (T-090).
# All or nothing: dispatching from the files that happened to read is
# dispatching from half a plan, so a file that does not read (fm_tasks
# names it) stops the dispatch. Tasks are walked in fm_tasks' order - id
# order, compared as versions, T-9 before T-10 - so that is the order in
# which ready tasks take the free slots (design section 14).
tasks="$(fm_tasks design/tasks)" \
  || { echo "fm-dispatch: the task list in design/tasks/ does not read; nothing is dispatched" >&2; exit 65; }

# Ready is not cleared: firstmate puts each task that turns ready before the
# captain, and only an A starts it. If that cannot be read, nothing starts -
# an unreadable answer is not a yes. A direct order needs no answer. Read
# after the task list, so a task file that does not read is named as such.
cleared=''
if [ -z "$ORDERED" ]; then
  cleared="$(bash "${FM_CODE_ROOT:-$REPO}/bin/fm-ready.sh" cleared --repo "$REPO" 2>/dev/null </dev/null)" || {
    echo "fm-dispatch: cannot read which ready tasks the captain cleared - nothing is dispatched" >&2
    exit 1
  }
fi
is_cleared() {
  if [ -n "$ORDERED" ]; then return 0; fi
  grep -qx "$1" <<< "$cleared"
}

started_any=0
while IFS= read -r id; do
  [ -n "$id" ] || continue
  [ -z "$ORDERED" ] || [ "$id" = "$ORDERED" ] || continue
  [ "$slots" -gt 0 ] || break
  is_done "$id" && { held "$id is already merged"; continue; }
  is_busy "$id" && { held "$id is already in flight"; continue; }
  is_closed "$id" && { held "$id is closed"; continue; }
  is_parked "$id" && { held "$id is parked"; continue; }
  ready=1
  while IFS= read -r dep; do
    [ -n "$dep" ] || continue
    is_done "$dep" || { ready=0; held "$id waits on $dep"; break; }
  done <<< "$(jq -r --arg t "$id" 'select(.id==$t)|.depends_on[]?' <<< "$tasks")"
  [ "$ready" -eq 1 ] || continue
  is_cleared "$id" || { echo "fm-dispatch: $id is ready but the captain has not cleared it" >&2; continue; }

  if [ "$DRY" -eq 1 ]; then
    echo "$id"
  else
    # the worker emits dispatched itself; two writers of one fact is how
    # the log ends up disagreeing with itself
    mkdir -p "$REPO/state/dispatch"
    "${FM_CODE_ROOT:-$REPO}/bin/fm-worker.sh" --task "$id" --repo "$REPO" >>"$REPO/state/dispatch/$id.log" 2>&1 </dev/null &
    echo "$id"
  fi
  slots=$(( slots - 1 )); started_any=1
done <<< "$(jq -r '.id' <<< "$tasks")"

[ "$started_any" -eq 1 ] || echo "fm-dispatch: nothing is ready"
exit 0
