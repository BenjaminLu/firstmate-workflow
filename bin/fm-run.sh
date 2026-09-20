#!/usr/bin/env bash
# One turn of the whole loop. Everything it does is one of the other scripts;
# this file only decides what happens next, and every decision it makes is
# read off the log or an exit code.
#
#   fm-run.sh once  [--repo .]     dispatch what is ready, then advance each
#                                  task in flight by one step
#   fm-run.sh watch [--every 30]   keep doing that
set -uo pipefail
_fm_lib="$(dirname "${BASH_SOURCE[0]}")/fm-config.sh"
[ -f "$_fm_lib" ] || { echo "${0##*/}: missing $_fm_lib" >&2; exit 70; }
# shellcheck source=bin/fm-config.sh
. "$_fm_lib"

REPO="${FM_ROOT:-$(pwd)}"; MODE=''; EVERY=30
while [ $# -gt 0 ]; do
  case "$1" in
    once|watch) MODE="$1"; shift ;;
    --repo) REPO="${2-}"; shift 2 ;;
    --every) EVERY="${2-}"; shift 2 ;;
    *) echo "fm-run: unknown argument $1" >&2; exit 64 ;;
  esac
done
[ -n "$MODE" ] || { echo "usage: fm-run.sh once|watch [--repo dir] [--every n]" >&2; exit 64; }
cd "$REPO" || { echo "fm-run: no repo at $REPO" >&2; exit 64; }
B="$REPO/bin"
say() { printf '  %s\n' "$*"; }

turn() {
  # 1. whatever GitHub knows that the log does not
  "$B/fm-sync-prs.sh" --repo "$REPO" >/dev/null 2>&1 || true

  # 2. start what is ready. dispatch refuses on its own if nothing is green-lit
  started="$("$B/fm-dispatch.sh" --repo "$REPO" 2>/dev/null | grep -E '^T-' || true)"
  [ -z "$started" ] || say "dispatched: $(printf '%s' "$started" | tr '\n' ' ')"

  # 3. advance every task that has a pull request open
  open_prs="$(jq -r 'select(.type=="pr_opened")|[.task,(.pr|tostring)]|@tsv' state/events.jsonl 2>/dev/null | sort -u)"
  while IFS=$'\t' read -r task pr; do
    [ -n "$task" ] && [ -n "$pr" ] || continue
    jq -e --arg t "$task" 'select(.type=="merged" and .task==$t)' state/events.jsonl >/dev/null 2>&1 && continue

    branch="$(git branch --list "$(printf '%s' "$task" | tr 'A-Z' 'a-z')-*" --format='%(refname:short)' | head -1)"
    [ -n "$branch" ] || continue
    round="$(jq -r --arg t "$task" 'select(.type=="review_opened" and .task==$t)|.task' state/events.jsonl 2>/dev/null | wc -l | tr -d ' ')"
    round=$(( round + 1 ))

    # the protocol first: from round three it can stop the round outright
    if [ "$round" -ge 3 ]; then
      "$B/fm-protocol.sh" check --task "$task" --pr "$pr" --round "$round" --repo "$REPO" >/dev/null 2>&1 </dev/null \
        || { say "$task: protocol violation in round $round"; continue; }
    fi

    "$B/fm-gate.sh" --task "$task" --repo "$REPO" --branch "$branch" --pr "$pr" >/dev/null 2>&1 </dev/null
    g=$?
    if [ "$g" -eq 0 ]; then
      # all seven green: the captain decides, nobody else
      id="D-$(printf '%s' "$task" | tr -dc '0-9')"
      [ -f "state/pending/$id.json" ] && { say "$task: waiting on the captain"; continue; }
      [ -f "state/decisions/$id.json" ] && continue
      "$B/fm-decide.sh" --request "$id" --task "$task" --kind merge --pr "$pr" \
        --title "$task passed the gates - merge it?" --repo "$REPO" >/dev/null 2>&1 </dev/null
      say "$task: all seven gates green, asking the captain ($id)"
    elif [ "$g" -eq 7 ]; then
      say "$task: gates 1-6 green, sending it to review (round $round)"
      # exit 3 is a round that produced no verdict. Swallowing it would let
      # a crashed engine read as a review that simply did not sign.
      "$B/fm-review.sh" --task "$task" --branch "$branch" --pr "$pr" \
        --round "$round" --repo "$REPO" >/dev/null 2>&1 </dev/null
      case "$?" in
        0) ;;
        2) say "$task: no reviewer engine was available, leaving it for the next turn" ;;
        3) say "$task: the reviewer produced no verdict (state/reviews/$task-r$round.log)" ;;
        *) say "$task: the review round failed" ;;
      esac
    else
      say "$task: stopped at gate $g"
    fi
  done <<< "$open_prs"
}

if [ "$MODE" = once ]; then turn; exit 0; fi
while :; do
  printf '%s\n' "-- $(date -u +%H:%M:%S)"
  turn
  sleep "$EVERY"
done
