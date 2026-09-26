#!/usr/bin/env bash
# The only writer of state/events.jsonl. Everything else - workers, reviewers,
# the board, the PR syncer - goes through here, so the log cannot be torn by two
# processes appending at once and cannot grow a field nobody validates.
#
#   fm-emit.sh --actor worker-2 --type gate_failed --task T-004 [--pr 9]
#              [--project example-app] [--data '{"gate":5}'] [--en "..." --tw "..."]
#
# --project names the registered project the event is about (design section
# 15.4) and is written as a top-level `project`. An event without it belongs
# to the default project, so every line written before projects existed keeps
# its meaning. A name the registry does not hold exits 65 and writes nothing.
#
# A summary is what the board shows. It must carry both languages or nothing:
# a half-translated event would render blank in one of the three locales.
#
# A `merged` event that says `data.untracked: true` is the merge of a pull
# request that belongs to no task (a revert, a hotfix; T-119). It names no
# task, and one that names both is refused: it would move a task's card for
# work that was not the task's.

# --- The task-id grammar (T-119) --------------------------------------------
# Which ids are tasks, and which task a branch or a pull request title names,
# written once. fm-decide.sh, fm-merge.sh and fm-sync-prs.sh source this file
# for it (sourced, it runs nothing past this block), and board/server.ts
# carries the TypeScript twin between its `task grammar` markers, which
# tests/board.test.sh runs against these functions over one table.
#
# A task is T-<3+ digits> (the plan's) or SK-<3+ digits> (a skill update's);
# those are the only prefixes design/tasks/, the log and the branches use.
# Digits are spelled out: a bracket range follows the locale's collation.
FM_TASK_DIG=0123456789
FM_TASK_ID="^(T|SK)-[${FM_TASK_DIG}]{3,}$"
fm_task_is() { [[ "${1-}" =~ $FM_TASK_ID ]]; }   # fm_task_is <id>
# A branch is named after its task, prefix in either case: t-117-… is T-117,
# sk-001-… is SK-001. The hyphen after the prefix may be missing, as in the
# earliest t004-… branches; the number is the whole run of digits, so
# t-1170-… is T-1170, never T-117. Anything else names no task.
fm_task_of_branch() {   # fm_task_of_branch <branch> -> the task, or 1
  local re="^([tT]|[sS][kK])-?([${FM_TASK_DIG}]{3,})(-.*)?$" p
  [[ "${1-}" =~ $re ]] || return 1
  p="${BASH_REMATCH[1]}"
  case "$p" in t|T) p=T ;; *) p=SK ;; esac
  printf '%s-%s' "$p" "${BASH_REMATCH[2]}"
}
# A pull request's title leads with its task and a colon, exactly as every
# worker opens one: "T-117: …", "SK-001: …". GitHub's 'Revert "T-105: …"'
# leads with no task, and so names none.
fm_task_of_title() {    # fm_task_of_title <title> -> the task, or 1
  local re="^((T|SK)-[${FM_TASK_DIG}]{3,}):"
  [[ "${1-}" =~ $re ]] || return 1
  printf '%s' "${BASH_REMATCH[1]}"
}
# The task a pull request belongs to: its branch's, and its title's only
# when the branch names none.
fm_task_of_pr() {       # fm_task_of_pr <branch> <title> -> the task, or 1
  fm_task_of_branch "${1-}" || fm_task_of_title "${2-}"
}
# A decision id holds its task without the hyphen: T-047 is T047, SK-001 is
# SK001. Card ids have always taken T-<letters and digits> as well, and the
# fixtures still use them (T-A, T-1), so a key is that or a task.
fm_task_key() {         # fm_task_key <task> -> its key, or 1
  local legacy="^T-([ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz${FM_TASK_DIG}]{1,32})$"
  if fm_task_is "${1-}"; then printf '%s' "${1/-/}"
  elif [[ "${1-}" =~ $legacy ]]; then printf 'T%s' "${BASH_REMATCH[1]}"
  else return 1
  fi
}
# sourced for the grammar alone: stop here
(return 0 2>/dev/null) && return 0

set -uo pipefail
# Nothing below may read standard input. A dispatched child inherits it, and
# a child that reads it blocks the caller waiting for a human who is not
# there. One guarantee, in one place; bin/ci.sh fails if a script that
# dispatches is missing it.
exec < /dev/null

ROOT="${FM_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
LOG="$ROOT/state/events.jsonl"
LOCK="$ROOT/state/.events.lock"

TYPES="greenlit dispatched commit_pushed pr_opened gate_passed gate_failed \
review_opened review_failed ask_pass_criteria criteria_returned protocol_violation approved \
merged closed decision_requested decision_made worker_crashed vendor_unavailable \
agent_finished crew_status parked unparked spec_pinned spec_repinned"

# 64 is what the OPTION LOOP exits, and only the option loop: a flag with
# no value after it, and a flag this script does not know. Everything
# else below still exits 1, as it always has. Converting the rest -
# `--actor is required`, a type that is not in the list, `--data` that is
# not JSON - is T-029, which sweeps the convention across every script
# instead of leaving one script half converted and a rule in the design
# that only one file obeys.
die()   { printf 'fm-emit: %s\n' "$1" >&2; exit 1; }
usage() { printf 'fm-emit: %s\n' "$1" >&2; exit 64; }

actor=''; type=''; task=''; pr=''; data='{}'; en=''; tw=''; project=''
# see fm_need in bin/fm-config.sh for why: `shift 2` with one argument
# left does not shift, and the loop spins. This file deliberately depends
# on nothing, so it carries the two lines rather than the explanation.
need() { [ "$#" -ge 2 ] || { echo "fm-emit: $1 needs a value" >&2; exit 64; }; }
while [ $# -gt 0 ]; do
  case "$1" in
    --actor) need "$@"; actor="${2-}"; shift 2 ;;
    --type)  need "$@"; type="${2-}";  shift 2 ;;
    --task)  need "$@"; task="${2-}";  shift 2 ;;
    --pr)    need "$@"; pr="${2-}";    shift 2 ;;
    --data)  need "$@"; data="${2-}";  shift 2 ;;
    --en)    need "$@"; en="${2-}";    shift 2 ;;
    --tw)    need "$@"; tw="${2-}";    shift 2 ;;
    --project) need "$@"; project="${2-}"; shift 2 ;;
    *) usage "unknown argument: $1" ;;
  esac
done

[ -n "$actor" ] || die "--actor is required"
[ -n "$type" ]  || die "--type is required"
case " $TYPES " in *" $type "*) ;; *) die "unknown type: $type" ;; esac
command -v jq >/dev/null 2>&1 || die "jq is required"
jq -e . >/dev/null 2>&1 <<<"$data" || die "--data is not valid JSON"
# A merged event moves its task's card, so its task is never a branch name or
# a title: a value the grammar reads a task out of (t-117-…, "T-117: …")
# without its being that task id is refused, naming the task it holds. Any
# other name passes, as the suites' fixture tasks (A, C, T-1) always have;
# fm-merge.sh, the one writer of merged, already refuses a task that is not
# the pull request's. An untracked merge belongs to no task, and names none.
if [ "$type" = merged ] && [ -n "$task" ]; then
  if ! fm_task_is "$task"; then
    held="$(fm_task_of_branch "$task" || fm_task_of_title "$task")" \
      && die "a merged event names a task id ($held), not a branch or a title; got --task $task"
  fi
  if jq -e 'type == "object" and .untracked == true' >/dev/null 2>&1 <<<"$data"; then
    die "a merged event marked untracked names no task, got --task $task"
  fi
fi

# Only a named project needs the registry, so only then is the library
# loaded: an event about the default project still depends on nothing.
if [ -n "$project" ]; then
  _fm_lib="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/fm-config.sh"
  [ -r "$_fm_lib" ] || { printf 'fm-emit: --project needs %s\n' "$_fm_lib" >&2; exit 70; }
  # shellcheck source=bin/fm-config.sh
  . "$_fm_lib"
  project="$(fm_project_resolve "$project" "$ROOT/config.yaml")" || exit 65
fi

# half a summary is worse than none: it renders blank in one locale
if [ -n "$en" ] || [ -n "$tw" ]; then
  [ -n "$en" ] || die "--tw given without --en (a summary needs both languages)"
  [ -n "$tw" ] || die "--en given without --tw (a summary needs both languages)"
fi

line=$(jq -cn \
  --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  --arg actor "$actor" --arg type "$type" --arg task "$task" \
  --arg pr "$pr" --arg en "$en" --arg tw "$tw" --arg project "$project" --argjson data "$data" '
  {ts:$ts, actor:$actor, type:$type}
  + (if $project == "" then {} else {project:$project} end)
  + (if $task == "" then {} else {task:$task} end)
  + (if $pr   == "" then {} else {pr:($pr|tonumber)} end)
  + (if $data == {}  then {} else {data:$data} end)
  + (if $en   == "" then {} else {summary:{en:$en, "zh-TW":$tw}} end)
') || die "could not build the event"

mkdir -p "$ROOT/state" || die "cannot create $ROOT/state"

# High-frequency mid-run refreshes must not flood the log. crew_status is
# coalesced per actor when the payload fingerprint is unchanged inside the
# throttle window (FM_CREW_STATUS_SECS, default 10; 0 disables). Within a
# window, at most FM_CREW_STATUS_BURST distinct payloads write (default 5);
# varying heartbeat text cannot bypass that ceiling. A changed bounded
# progress field always writes. The check runs under the event log lock.
crew_fp=''; stamp=''; crew_secs=0; crew_burst=5
if [ "$type" = crew_status ]; then
  crew_secs="${FM_CREW_STATUS_SECS:-10}"
  crew_burst="${FM_CREW_STATUS_BURST:-5}"
  if [[ ! "$crew_secs" =~ ^[0-9]+$ ]]; then
    printf '%s\n' 'fm-emit: FM_CREW_STATUS_SECS must be a non-negative decimal integer; unset it for 10' >&2
    exit 64
  fi
  if [[ ! "$crew_burst" =~ ^[0-9]+$ ]]; then
    printf '%s\n' 'fm-emit: FM_CREW_STATUS_BURST must be a non-negative decimal integer; unset it for 5' >&2
    exit 64
  fi
  stamp_dir="$ROOT/state/.crew-status-throttle"
  mkdir -p "$stamp_dir" || die "cannot create $stamp_dir"
  safe="$(printf '%s' "$actor" | tr -c 'A-Za-z0-9._-' '_')"
  stamp="$stamp_dir/$safe"
  crew_fp="$(printf '%s' "$line" | jq -cr '{data:(.data//{}),summary:(.summary//{})}' 2>/dev/null || printf '%s' "$line")"
fi

_crew_wstart=0; _crew_count=0; _crew_last_fp=''
crew_status_stamp_read() {
  _crew_wstart=0; _crew_count=0; _crew_last_fp=''
  [ -f "$stamp" ] || return 0
  local nf
  nf="$(awk -F'\t' 'NR==1{print NF}' "$stamp" 2>/dev/null || printf 0)"
  _crew_wstart="$(awk -F'\t' 'NR==1{print $1}' "$stamp" 2>/dev/null || printf 0)"
  case "$_crew_wstart" in ''|*[!0-9]*) _crew_wstart=0 ;; esac
  if [ "$nf" -ge 3 ]; then
    _crew_count="$(awk -F'\t' 'NR==1{print $2}' "$stamp" 2>/dev/null || printf 0)"
    _crew_last_fp="$(awk -F'\t' 'NR==1{print $3}' "$stamp" 2>/dev/null || printf '')"
  else
    _crew_count=1
    _crew_last_fp="$(awk -F'\t' 'NR==1{print $2}' "$stamp" 2>/dev/null || printf '')"
  fi
  case "$_crew_count" in ''|*[!0-9]*) _crew_count=0 ;; esac
}

crew_status_skip() {
  [ "$type" = crew_status ] || return 1
  [ "$crew_secs" -gt 0 ] || return 1
  [ -f "$stamp" ] || return 1
  local now prev_prog next_prog
  now="$(date -u +%s)"
  crew_status_stamp_read
  if [ $(( now - _crew_wstart )) -ge "$crew_secs" ]; then return 1; fi
  if [ "$crew_fp" = "$_crew_last_fp" ]; then return 0; fi
  prev_prog="$(printf '%s' "$_crew_last_fp" | jq -cr '.data.progress // empty' 2>/dev/null || true)"
  next_prog="$(printf '%s' "$crew_fp" | jq -cr '.data.progress // empty' 2>/dev/null || true)"
  if [ -n "$next_prog" ] && [ "$next_prog" != "$prev_prog" ]; then return 1; fi
  [ "$crew_burst" -gt 0 ] && [ "$_crew_count" -ge "$crew_burst" ]
}

crew_status_stamp_write() {
  local now
  now="$(date -u +%s)"
  crew_status_stamp_read
  if [ ! -f "$stamp" ] || [ $(( now - _crew_wstart )) -ge "$crew_secs" ]; then
    _crew_wstart="$now"
    _crew_count=1
  else
    _crew_count=$(( _crew_count + 1 ))
  fi
  printf '%s\t%s\t%s\n' "$_crew_wstart" "$_crew_count" "$crew_fp" > "$stamp"
}

# mkdir is the portable atomic lock; macOS ships no flock(1)
for _ in $(seq 1 600); do
  if mkdir "$LOCK" 2>/dev/null; then
    # shellcheck disable=SC2064
    # the signal traps only exit; the EXIT trap releases. Naming a
    # signal alongside EXIT released the lock and then CARRIED ON
    # writing, with the lock already gone - and kill stopped working
    trap "rmdir '$LOCK' 2>/dev/null" EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM
    trap 'exit 129' HUP
    if crew_status_skip; then
      rmdir "$LOCK" 2>/dev/null
      exit 0
    fi
    printf '%s\n' "$line" >> "$LOG"
    if [ "$type" = crew_status ] && [ -n "$stamp" ]; then
      crew_status_stamp_write
    fi
    exit 0
  fi
  perl -e 'select(undef,undef,undef,0.01)' 2>/dev/null || sleep 0.05
done
die "timed out waiting for the event log lock"
