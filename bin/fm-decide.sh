#!/usr/bin/env bash
# Puts a decision in front of the captain and blocks until it comes back.
#
#   fm-decide.sh --request D-007 --task T-004 --kind merge --title "..." [--pr 9]
#   fm-decide.sh --await   D-007 [--timeout 3600]
#
# Waiting uses bun's fs.watch when bun is there and a one-second poll when it
# is not. It deliberately depends on neither fswatch, entr nor watchexec:
# a board that only works on a machine with the right brew packages is not a
# board, it is a demo.
set -uo pipefail
# Nothing below may read standard input. A dispatched child inherits it, and
# a child that reads it blocks the caller waiting for a human who is not
# there. One guarantee, in one place; bin/ci.sh fails if a script that
# dispatches is missing it.
exec < /dev/null

REPO="${FM_ROOT:-$(pwd)}"; MODE=''; ID=''; TASK=''; KIND='choice'; TITLE=''; PR=''; TIMEOUT=0
# see fm_need in bin/fm-config.sh for why: `shift 2` with one argument
# left does not shift, and the loop spins. This file deliberately depends
# on nothing, so it carries the two lines rather than the explanation.
need() { [ "$#" -ge 2 ] || { echo "fm-decide: $1 needs a value" >&2; exit 64; }; }
while [ $# -gt 0 ]; do
  case "$1" in
    --request) need "$@"; MODE=request; ID="${2-}"; shift 2 ;;
    --await)   need "$@"; MODE=await;   ID="${2-}"; shift 2 ;;
    --task)  need "$@"; TASK="${2-}";  shift 2 ;;
    --kind)  need "$@"; KIND="${2-}";  shift 2 ;;
    --title) need "$@"; TITLE="${2-}"; shift 2 ;;
    --pr)    need "$@"; PR="${2-}";    shift 2 ;;
    --repo)  need "$@"; REPO="${2-}";  shift 2 ;;
    --timeout) need "$@"; TIMEOUT="${2-}"; shift 2 ;;
    *) echo "fm-decide: unknown argument $1" >&2; exit 64 ;;
  esac
done
[ -n "$MODE" ] && [ -n "$ID" ] || {
  echo "usage: fm-decide.sh --request <id> --task <id> [--kind merge] | --await <id>" >&2; exit 64; }
cd "$REPO" || { echo "fm-decide: no repo at $REPO" >&2; exit 64; }

DIR="$REPO/state/decisions"; PEND="$REPO/state/pending"
mkdir -p "$DIR" "$PEND"
emit() { FM_ROOT="$REPO" "$REPO/bin/fm-emit.sh" --actor firstmate "$@" >/dev/null 2>&1 </dev/null || true; }

# The board draws no diagrams. It mounts an iframe for every decision card
# and HEADs the file first, so a decision whose diagram nobody generated is
# answered 404 and the frame removes itself - every reader, every decision,
# for as long as nothing calls the generator. Requesting the decision is the
# moment the file has to exist, because it is the moment the card appears.
#
# The drawing is decoration on the request; the request is what the captain
# is waiting for. So a generator that fails does not take the decision with
# it. It does not vanish either: the reason goes to standard error, where the
# caller's own log keeps it. Its stdout is not passed through - --request
# prints one thing, the pending file, and three diagram paths arriving on the
# same stream would be read as that answer.
draw() {
  local out rc
  [ -x "$REPO/bin/fm-diagram.sh" ] || {
    printf 'fm-decide: no bin/fm-diagram.sh under %s: %s will have no diagram\n' "$REPO" "$ID" >&2
    return 0
  }
  out="$(FM_ROOT="$REPO" "$REPO/bin/fm-diagram.sh" --event decision_requested \
         --decision "$ID" --repo "$REPO" 2>&1 </dev/null)"; rc=$?
  [ "$rc" -eq 0 ] || printf 'fm-decide: could not draw %s (fm-diagram.sh exited %s): %s\n' \
    "$ID" "$rc" "$out" >&2
  return 0
}

if [ "$MODE" = request ]; then
  jq -cn --arg id "$ID" --arg task "$TASK" --arg kind "$KIND" --arg title "$TITLE" --arg pr "$PR" \
    '{id:$id,task:$task,kind:$kind,title:$title}
     + (if $pr=="" then {} else {pr:($pr|tonumber)} end)' > "$PEND/$ID.json"
  # after the pending file and before the event: the generator reads the file
  # it is drawing, and the event is what wakes anything watching
  draw
  emit --type decision_requested --task "$TASK" ${PR:+--pr "$PR"} \
       --en "${TITLE:-a decision is waiting}" --tw "${TITLE:-有待決事項}"
  printf '%s\n' "$PEND/$ID.json"
  exit 0
fi

# --- await ---------------------------------------------------------------
f="$DIR/$ID.json"
if [ -f "$f" ]; then answer="$f"; else
  if command -v bun >/dev/null 2>&1 && [ -f "$REPO/bin/watch-decisions.ts" ]; then
    answer="$(bun run "$REPO/bin/watch-decisions.ts" "$DIR" "$ID" "$(( TIMEOUT * 1000 ))" 2>/dev/null </dev/null)"
  else
    waited=0
    while [ ! -f "$f" ]; do
      [ "$TIMEOUT" -gt 0 ] && [ "$waited" -ge "$TIMEOUT" ] && break
      sleep 1; waited=$(( waited + 1 ))
    done
    [ -f "$f" ] && answer="$f" || answer=''
  fi
fi
[ -n "$answer" ] && [ -f "$answer" ] || { echo "fm-decide: timed out waiting for $ID" >&2; exit 1; }

chosen="$(jq -r '.chosen // empty' "$answer")"
task="$(jq -r '.task // empty' "$answer")"
emit --type decision_made ${task:+--task "$task"} \
     --en "$ID answered $chosen" --tw "$ID 已決定 $chosen"
rm -f "$PEND/$ID.json"
cat "$answer"
exit 0
