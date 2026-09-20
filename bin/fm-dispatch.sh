#!/usr/bin/env bash
# Decides what may start. Three things can stop it and all three are checks
# against the log or the filesystem, never a judgement call:
#
#   - no greenlit event for the work      -> nothing starts (the eighth gate)
#   - a dependency is not merged yet      -> that task waits
#   - concurrency is already spent        -> the rest wait
#
#   fm-dispatch.sh [--repo .] [--dry-run] [--limit N]
set -uo pipefail

REPO="${FM_ROOT:-$(pwd)}"; DRY=0; LIMIT=''
while [ $# -gt 0 ]; do
  case "$1" in
    --repo) REPO="${2-}"; shift 2 ;;
    --dry-run) DRY=1; shift ;;
    --limit) LIMIT="${2-}"; shift 2 ;;
    *) echo "fm-dispatch: unknown argument $1" >&2; exit 64 ;;
  esac
done
cd "$REPO" || { echo "fm-dispatch: no repo at $REPO" >&2; exit 64; }
LOG="$REPO/state/events.jsonl"
emit() { FM_ROOT="$REPO" "$REPO/bin/fm-emit.sh" --actor firstmate "$@" >/dev/null 2>&1 || true; }

# --- the eighth gate: nothing starts before the captain has seen a proposal
if ! [ -f "$LOG" ] || ! jq -e 'select(.type=="greenlit")' "$LOG" >/dev/null 2>&1; then
  echo "fm-dispatch: no greenlit event - nothing is dispatched" >&2
  exit 1
fi

evt() { jq -r --arg t "$1" 'select(.type==$t)|.task // empty' "$LOG" 2>/dev/null | sort -u; }
done_tasks="$(evt merged)"
started="$(evt dispatched)"
finished="$(printf '%s\n%s\n' "$done_tasks" "$(evt closed)" | sort -u)"
inflight="$(comm -23 <(printf '%s\n' "$started" | sort -u | sed '/^$/d') \
                     <(printf '%s\n' "$finished" | sort -u | sed '/^$/d') | sed '/^$/d')"
n_inflight="$(printf '%s\n' "$inflight" | sed '/^$/d' | wc -l | tr -d ' ')"

limit="${LIMIT:-$(sed -n 's/^concurrency:[[:space:]]*//p' config.yaml 2>/dev/null | head -1)}"
[ -n "$limit" ] || limit=3
slots=$(( limit - n_inflight ))
[ "$slots" -gt 0 ] || { echo "fm-dispatch: $n_inflight in flight, limit $limit - nothing to start"; exit 0; }

is_done()    { printf '%s\n' "$done_tasks" | grep -qx "$1"; }
is_busy()    { printf '%s\n' "$inflight"   | grep -qx "$1"; }
# closed is abandoned, not failed: it frees the slot but is never retried on
# its own. Restarting it is a decision, and decisions belong to the captain.
is_closed()  { evt closed | grep -qx "$1"; }

started_any=0
while IFS= read -r id; do
  [ -n "$id" ] || continue
  [ "$slots" -gt 0 ] || break
  is_done "$id" && continue
  is_busy "$id" && continue
  is_closed "$id" && continue
  ready=1
  while IFS= read -r dep; do
    [ -n "$dep" ] || continue
    is_done "$dep" || { ready=0; break; }
  done <<< "$(jq -r --arg t "$id" '.tasks[]|select(.id==$t)|.depends_on[]?' design/tasks.json)"
  [ "$ready" -eq 1 ] || continue

  if [ "$DRY" -eq 1 ]; then
    echo "$id"
  else
    emit --type dispatched --task "$id" --en "dispatched $id" --tw "已派出 $id"
    "$REPO/bin/fm-worker.sh" --task "$id" --repo "$REPO" >/dev/null 2>&1 &
    echo "$id"
  fi
  slots=$(( slots - 1 )); started_any=1
done <<< "$(jq -r '.tasks[].id' design/tasks.json)"

[ "$started_any" -eq 1 ] || echo "fm-dispatch: nothing is ready"
exit 0
