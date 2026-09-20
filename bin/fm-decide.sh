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
while [ $# -gt 0 ]; do
  case "$1" in
    --request) MODE=request; ID="${2-}"; shift 2 ;;
    --await)   MODE=await;   ID="${2-}"; shift 2 ;;
    --task)  TASK="${2-}";  shift 2 ;;
    --kind)  KIND="${2-}";  shift 2 ;;
    --title) TITLE="${2-}"; shift 2 ;;
    --pr)    PR="${2-}";    shift 2 ;;
    --repo)  REPO="${2-}";  shift 2 ;;
    --timeout) TIMEOUT="${2-}"; shift 2 ;;
    *) echo "fm-decide: unknown argument $1" >&2; exit 64 ;;
  esac
done
[ -n "$MODE" ] && [ -n "$ID" ] || {
  echo "usage: fm-decide.sh --request <id> --task <id> [--kind merge] | --await <id>" >&2; exit 64; }
cd "$REPO" || { echo "fm-decide: no repo at $REPO" >&2; exit 64; }

DIR="$REPO/state/decisions"; PEND="$REPO/state/pending"
mkdir -p "$DIR" "$PEND"
emit() { FM_ROOT="$REPO" "$REPO/bin/fm-emit.sh" --actor firstmate "$@" >/dev/null 2>&1 || true; }

if [ "$MODE" = request ]; then
  jq -cn --arg id "$ID" --arg task "$TASK" --arg kind "$KIND" --arg title "$TITLE" --arg pr "$PR" \
    '{id:$id,task:$task,kind:$kind,title:$title}
     + (if $pr=="" then {} else {pr:($pr|tonumber)} end)' > "$PEND/$ID.json"
  emit --type decision_requested --task "$TASK" ${PR:+--pr "$PR"} \
       --en "${TITLE:-a decision is waiting}" --tw "${TITLE:-有待決事項}"
  printf '%s\n' "$PEND/$ID.json"
  exit 0
fi

# --- await ---------------------------------------------------------------
f="$DIR/$ID.json"
if [ -f "$f" ]; then answer="$f"; else
  if command -v bun >/dev/null 2>&1 && [ -f "$REPO/bin/watch-decisions.ts" ]; then
    answer="$(bun run "$REPO/bin/watch-decisions.ts" "$DIR" "$ID" "$(( TIMEOUT * 1000 ))" 2>/dev/null)"
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
