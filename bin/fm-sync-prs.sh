#!/usr/bin/env bash
# Notices what happened on GitHub and writes it into the log. The captain
# merging a pull request in a browser has to reach the system by the system
# looking, not by someone typing it into a conversation.
#
#   fm-sync-prs.sh [--repo .] [--limit 50]
#
# Idempotent: an event already in the log for that pull request and state is
# not written again, so this is safe to run on a timer.
set -uo pipefail
# Nothing below may read standard input. A dispatched child inherits it, and
# a child that reads it blocks the caller waiting for a human who is not
# there. One guarantee, in one place; bin/ci.sh fails if a script that
# dispatches is missing it.
exec < /dev/null

REPO="${FM_ROOT:-$(pwd)}"; LIMIT=50; GH="${FM_GH:-gh}"
# `shift 2` with one argument left does not shift: it returns 1 and leaves
# $@ alone, so `while [ $# -gt 0 ]` spins on the same flag for ever. Every
# flag that takes a value goes through this, which refuses instead. A test
# for it has to run under an alarm, or it hangs the gate rather than
# failing it - tests/option-loop.test.sh does.
need() {   # need <flag>: there has to be a value after it
  [ "$#" -ge 2 ] || { echo "fm-sync-prs: $1 needs a value" >&2; exit 64; }
}
while [ $# -gt 0 ]; do
  case "$1" in
    --repo) need "$@"; REPO="${2-}"; shift 2 ;;
    --limit) need "$@"; LIMIT="${2-}"; shift 2 ;;
    *) echo "fm-sync-prs: unknown argument $1" >&2; exit 64 ;;
  esac
done
cd "$REPO" || { echo "fm-sync-prs: no repo at $REPO" >&2; exit 64; }
LOG="$REPO/state/events.jsonl"; mkdir -p "$REPO/state"

raw="$($GH pr list --state all --limit "$LIMIT" \
        --json number,state,title,headRefName,mergedAt 2>/dev/null)" || {
  echo "fm-sync-prs: could not reach GitHub" >&2; exit 1; }
jq -e 'type=="array"' >/dev/null 2>&1 <<<"$raw" || {
  echo "fm-sync-prs: unexpected response from gh" >&2; exit 1; }

# which pull request numbers already have which event recorded
seen() { [ -f "$LOG" ] && jq -r --arg t "$1" --argjson p "$2" \
  'select(.type==$t and .pr==$p)|.pr' "$LOG" 2>/dev/null | head -1; }

# a branch is named after its task: t-004-... -> T-004
task_of() { printf '%s' "$1" | sed -n 's/^\([tT]-\{0,1\}[0-9]\{3\}\).*/\1/p' | tr 'a-z' 'A-Z' \
            | sed 's/^T\([0-9]\)/T-\1/'; }

new=0
while IFS=$'\t' read -r num state branch title; do
  [ -n "$num" ] || continue
  case "$state" in
    MERGED) type=merged ;;
    CLOSED) type=closed ;;
    OPEN)   type=pr_opened ;;
    *) continue ;;
  esac
  [ -z "$(seen "$type" "$num")" ] || continue
  task="$(task_of "$branch")"
  # build both summaries first: a case inside a command substitution inside an
  # argument is a parse error waiting for the day the branch is taken
  case "$state" in
    MERGED) en=merged;  tw=已合併 ;;
    CLOSED) en=closed;  tw=已關閉 ;;
    *)      en=opened;  tw=已開啟 ;;
  esac
  FM_ROOT="$REPO" "$REPO/bin/fm-emit.sh" --actor github --type "$type" --pr "$num" \
    ${task:+--task "$task"} \
    --en "#${num} ${en}: ${title}" \
    --tw "#${num} ${tw}：${title}" \
    >/dev/null 2>&1 </dev/null || continue
  echo "$type #$num${task:+ ($task)}"
  new=$(( new + 1 ))
done <<< "$(jq -r '.[]|[(.number|tostring),.state,.headRefName,.title]|@tsv' <<<"$raw")"

[ "$new" -gt 0 ] || echo "fm-sync-prs: nothing new"
exit 0
