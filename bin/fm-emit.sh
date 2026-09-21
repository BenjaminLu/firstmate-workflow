#!/usr/bin/env bash
# The only writer of state/events.jsonl. Everything else - workers, reviewers,
# the board, the PR syncer - goes through here, so the log cannot be torn by two
# processes appending at once and cannot grow a field nobody validates.
#
#   fm-emit.sh --actor worker-2 --type gate_failed --task T-004 [--pr 9]
#              [--data '{"gate":5}'] [--en "..." --tw "..."]
#
# A summary is what the board shows. It must carry both languages or nothing:
# a half-translated event would render blank in one of the three locales.
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
agent_finished"

die() { printf 'fm-emit: %s\n' "$1" >&2; exit 1; }

actor=''; type=''; task=''; pr=''; data='{}'; en=''; tw=''
# `shift 2` with one argument left does not shift: it returns 1 and leaves
# $@ alone, so `while [ $# -gt 0 ]` spins on the same flag for ever. Every
# flag that takes a value goes through this, which refuses instead. A test
# for it has to run under an alarm, or it hangs the gate rather than
# failing it - tests/option-loop.test.sh does.
need() {   # need <flag>: there has to be a value after it
  [ "$#" -ge 2 ] || { echo "fm-emit: $1 needs a value" >&2; exit 64; }
}
while [ $# -gt 0 ]; do
  case "$1" in
    --actor) need "$@"; actor="${2-}"; shift 2 ;;
    --type)  need "$@"; type="${2-}";  shift 2 ;;
    --task)  need "$@"; task="${2-}";  shift 2 ;;
    --pr)    need "$@"; pr="${2-}";    shift 2 ;;
    --data)  need "$@"; data="${2-}";  shift 2 ;;
    --en)    need "$@"; en="${2-}";    shift 2 ;;
    --tw)    need "$@"; tw="${2-}";    shift 2 ;;
    # 64 like every other script here: a caller that cannot tell a usage
    # error from a refused write cannot react to either
    *) echo "fm-emit: unknown argument: $1" >&2; exit 64 ;;
  esac
done

[ -n "$actor" ] || die "--actor is required"
[ -n "$type" ]  || die "--type is required"
case " $TYPES " in *" $type "*) ;; *) die "unknown type: $type" ;; esac
command -v jq >/dev/null 2>&1 || die "jq is required"
jq -e . >/dev/null 2>&1 <<<"$data" || die "--data is not valid JSON"

# half a summary is worse than none: it renders blank in one locale
if [ -n "$en" ] || [ -n "$tw" ]; then
  [ -n "$en" ] || die "--tw given without --en (a summary needs both languages)"
  [ -n "$tw" ] || die "--en given without --tw (a summary needs both languages)"
fi

line=$(jq -cn \
  --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  --arg actor "$actor" --arg type "$type" --arg task "$task" \
  --arg pr "$pr" --arg en "$en" --arg tw "$tw" --argjson data "$data" '
  {ts:$ts, actor:$actor, type:$type}
  + (if $task == "" then {} else {task:$task} end)
  + (if $pr   == "" then {} else {pr:($pr|tonumber)} end)
  + (if $data == {}  then {} else {data:$data} end)
  + (if $en   == "" then {} else {summary:{en:$en, "zh-TW":$tw}} end)
') || die "could not build the event"

mkdir -p "$ROOT/state" || die "cannot create $ROOT/state"

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
    printf '%s\n' "$line" >> "$LOG"
    exit 0
  fi
  perl -e 'select(undef,undef,undef,0.01)' 2>/dev/null || sleep 0.05
done
die "timed out waiting for the event log lock"
