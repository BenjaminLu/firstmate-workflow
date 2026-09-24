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
agent_finished crew_status parked unparked"

# 64 is what the OPTION LOOP exits, and only the option loop: a flag with
# no value after it, and a flag this script does not know. Everything
# else below still exits 1, as it always has. Converting the rest -
# `--actor is required`, a type that is not in the list, `--data` that is
# not JSON - is T-029, which sweeps the convention across every script
# instead of leaving one script half converted and a rule in the design
# that only one file obeys.
die()   { printf 'fm-emit: %s\n' "$1" >&2; exit 1; }
usage() { printf 'fm-emit: %s\n' "$1" >&2; exit 64; }

actor=''; type=''; task=''; pr=''; data='{}'; en=''; tw=''
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
    *) usage "unknown argument: $1" ;;
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
