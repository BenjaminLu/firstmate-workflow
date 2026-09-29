#!/usr/bin/env bash
# Arms the watcher, once per repository (T-137). Every harness's hook calls
# this and only this, so the harnesses differ in how they wake the session and
# not in what watches.
#
#   fm-watch-arm.sh [--max-wait SECS]   make sure a watcher cycle is running,
#                                       then wait for a wake and print it
#   fm-watch-arm.sh --ensure            make sure one is running, and return
#   fm-watch-arm.sh --status            "alive gen=N pid=P beacon=Ss" (exit 0)
#                                       or "dead ..." (exit 1)
#
# A CYCLE is one process holding the watch under a generation number:
# fm-watch.sh runs in it until an event needs firstmate. The cycle then starts
# its successor, generation + 1, and only then writes the wake to
# state/watch/wake.<gen>. Coverage has no gap while firstmate handles the wake.
#
# Arming attaches to the live cycle; it never starts a second. Repeated hook
# firings all wait on the one, and the first to claim a wake (a mkdir under
# state/watch/claims) delivers it: the reason goes to stdout, once. An owner
# that is dead, or whose beacon has gone stale, is superseded: the generation
# moves on, the stale process is killed, and if it ever wakes it finds it no
# longer owns the watch and leaves without acting.
#
# A crew round never arms (FM_IN_ROUND, its worktree path), and neither does
# a session whose captain is away: it prints nothing and exits 0.
set -uo pipefail
exec < /dev/null

SELF="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/$(basename "${BASH_SOURCE[0]}")"
ROOT="${FM_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
# shellcheck source=bin/lib/fm-watch-lib.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/fm-watch-lib.sh"
WATCH="${FM_WATCH_BIN:-$(dirname "$SELF")/fm-watch.sh}"
APOLL="${FM_WATCH_ARM_POLL:-0.5}"
D="$FM_WATCH_DIR"

mode='wait'; maxwait=''
need() { [ "$#" -ge 2 ] || { echo "fm-watch-arm: $1 needs a value" >&2; exit 64; }; }
while [ $# -gt 0 ]; do
  case "$1" in
    --ensure) mode=ensure; shift ;;
    --status) mode=status; shift ;;
    --cycle)  mode=cycle; shift ;;
    --max-wait) need "$@"; maxwait="${2-}"; shift 2 ;;
    *) echo "fm-watch-arm: unknown argument: $1" >&2; exit 64 ;;
  esac
done
if [ -n "$maxwait" ] && [[ ! "$maxwait" =~ ^[0-9]+$ ]]; then
  echo "fm-watch-arm: --max-wait is whole seconds" >&2; exit 64
fi

if [ "$mode" != status ] && [ "$mode" != cycle ]; then
  fm_watch_primary || exit 0
  fm_watch_away && exit 0
fi
mkdir -p "$D/claims" || { echo "fm-watch-arm: cannot create $D" >&2; exit 70; }

journal() { printf '%s %s\n' "$1" "$2" >> "$D/journal"; }
padded() { printf '%010d' "$1"; }
iso() { perl -MPOSIX -e 'print strftime("%Y-%m-%dT%H:%M:%SZ", gmtime $ARGV[0])' "$1"; }

# A short critical section: mkdir is the portable atomic lock. A holder that
# died is broken by the next taker.
lock_held=0
lock() {
  local p
  for _ in $(seq 1 200); do
    if mkdir "$D/arm.lock" 2>/dev/null; then printf '%s\n' "$$" > "$D/arm.lock/pid"; lock_held=1; return 0; fi
    p=''; [ -r "$D/arm.lock/pid" ] && read -r p < "$D/arm.lock/pid"
    if [ -n "$p" ] && ! kill -0 "$p" 2>/dev/null; then rm -rf "$D/arm.lock"; continue; fi
    sleep 0.05
  done
  return 1
}
unlock() { [ "$lock_held" = 1 ] || return 0; rm -rf "$D/arm.lock"; lock_held=0; }

# start generation $1 as its own session, and make it the owner
spawn_cycle() {
  local gen="$1" pid
  FM_WATCH_GEN="$gen" perl -MPOSIX -e 'POSIX::setsid(); exec @ARGV' \
    "$SELF" --cycle >> "$D/cycle.log" 2>&1 < /dev/null &
  pid=$!
  printf '%s %s\n' "$gen" "$pid" > "$D/owner.tmp" && mv "$D/owner.tmp" "$D/owner"
  : > "$D/beacon"
  journal successor "$gen"
}

# the caller holds the lock
supersede_dead() {
  local gen pid='' age now inflight
  gen="$(fm_watch_gen)"
  [ -r "$D/owner" ] && read -r _ pid < "$D/owner"
  # time with work in flight and no live watcher, kept for the board
  age="$(fm_watch_age "$D/beacon")"; now="$(date +%s)"
  inflight="$(fm_inflight_count)"
  if [ "$inflight" -gt 0 ] && [ "$age" -lt 999999 ]; then
    jq -cn --arg from "$(iso $((now - age)))" --arg to "$(iso "$now")" --argjson secs "$age" \
      --argjson inflight "$inflight" '{from:$from,to:$to,secs:$secs,inflight:$inflight}' >> "$D/gaps.jsonl"
  fi
  # a stale owner may still be running, hung: it must not go on
  [[ "${pid-}" =~ ^[0-9]+$ ]] && kill "$pid" 2>/dev/null
  spawn_cycle $((gen + 1))
}

ensure_cycle() {
  lock || { echo "fm-watch-arm: could not take the arm lock" >&2; return 1; }
  fm_watch_alive || supersede_dead
  unlock
}

case "$mode" in
status)
  gen="$(fm_watch_gen)"; pid=''
  [ -r "$D/owner" ] && read -r _ pid < "$D/owner"
  if fm_watch_alive; then state=alive; rc=0; else state=dead; rc=1; fi
  printf '%s gen=%s pid=%s beacon=%ss\n' "$state" "$gen" "${pid-}" "$(fm_watch_age "$D/beacon")"
  exit "$rc" ;;

ensure)
  ensure_cycle; exit $? ;;

cycle)
  # run the watcher until it has something to say, hand the watch on, then
  # leave the wake where an arm will find it
  gen="${FM_WATCH_GEN:?fm-watch-arm --cycle is started by the arm}"
  reason="$("$WATCH")"; rc=$?
  [ "$rc" != 3 ] || exit 0
  [ "$rc" = 0 ] || { journal watcher-exit "$gen rc=$rc"; sleep 2; reason=''; }
  if lock; then
    # only the owner hands on; one that was superseded while it ran does not
    [ "$(fm_watch_gen)" -le "$gen" ] || { unlock; exit 0; }
    spawn_cycle $((gen + 1))
    unlock
  fi
  if [ -n "$reason" ]; then
    printf '%s\n' "$reason" > "$D/wake.$(padded "$gen").tmp" \
      && mv "$D/wake.$(padded "$gen").tmp" "$D/wake.$(padded "$gen")"
    jq -cn --arg ts "$(iso "$(date +%s)")" --arg reason "$reason" --argjson gen "$gen" \
      '{ts:$ts,reason:$reason,gen:$gen}' > "$D/last-wake.json.tmp" && mv "$D/last-wake.json.tmp" "$D/last-wake.json"
    journal wake "$gen"
  fi
  exit 0 ;;
esac

# mode wait: attach, and deliver the first wake this process claims. A wake
# that arrives while waiting and is claimed by another arm was delivered; this
# one leaves quietly rather than wait on for nothing. Wakes already claimed
# when it started are old news, and are pruned after ten minutes.
find "$D" -maxdepth 2 -name 'wake.[0-9]*' -mmin +10 -exec rm -rf {} + 2>/dev/null
done_before=' '
for c in "$D"/claims/wake.*; do [ -e "$c" ] && done_before="$done_before${c##*/} "; done
started="$(date +%s)"
while :; do
  out=''; lost=0
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    name="${f##*/}"
    if mkdir "$D/claims/$name" 2>/dev/null; then
      out="$out$(cat "$f")
"
      journal delivered "$((10#${name#wake.}))"
    else
      case "$done_before" in *" $name "*) ;; *) lost=1 ;; esac
    fi
  done < <(find "$D" -maxdepth 1 -name 'wake.[0-9]*' ! -name '*.tmp' | sort)
  if [ -n "$out" ]; then printf '%s' "$out"; exit 0; fi
  [ "$lost" = 0 ] || exit 0
  if [ -n "$maxwait" ] && [ $(( $(date +%s) - started )) -ge "$maxwait" ]; then exit 0; fi
  # a dead owner is superseded here, so waiting never sits on nothing
  fm_watch_alive || ensure_cycle
  sleep "$APOLL"
done
