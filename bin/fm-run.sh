#!/usr/bin/env bash
# One turn of the whole loop. Everything it does is one of the other scripts;
# this file only decides what happens next, and every decision it makes is
# read off the log or an exit code.
#
#   fm-run.sh once  [--repo .]     dispatch what is ready, then advance each
#                                  task in flight by one step
#   fm-run.sh watch [--every 30]   keep doing that
set -uo pipefail
# Nothing below may read standard input. A dispatched child inherits it, and
# a child that reads it blocks the whole turn waiting for a human who is not
# there - the advance loop did exactly this once, and ci.sh has the same
# line for the same reason.
#
# It is NOT the only guarantee, and the earlier version of this comment that
# said so was wrong: `exec` sets fd 0 for the script, and a child dispatched
# inside a compound command that carries its own redirection - the advance
# loop's `done <<<"$open_prs"` - is handed the list, not /dev/null. So every
# dispatch also carries its own `</dev/null`, and bin/ci.sh fails if one
# does not. Having both means neither is proved by a probe; each is proved
# by reading the file, which is what the gate does.
exec < /dev/null
_fm_lib="$(dirname "${BASH_SOURCE[0]}")/fm-config.sh"
[ -f "$_fm_lib" ] || { echo "${0##*/}: missing $_fm_lib" >&2; exit 70; }
# shellcheck source=bin/fm-config.sh
. "$_fm_lib"

REPO="${FM_ROOT:-$(pwd)}"; MODE=''; EVERY=30
while [ $# -gt 0 ]; do
  case "$1" in
    once|watch) MODE="$1"; shift ;;
    --repo) fm_need "fm-run" "$@"; REPO="${2-}"; shift 2 ;;
    --every) fm_need "fm-run" "$@"; EVERY="${2-}"; shift 2 ;;
    *) echo "fm-run: unknown argument $1" >&2; exit 64 ;;
  esac
done
[ -n "$MODE" ] || { echo "usage: fm-run.sh once|watch [--repo dir] [--every n]" >&2; exit 64; }
cd "$REPO" || { echo "fm-run: no repo at $REPO" >&2; exit 64; }
B="$REPO/bin"
say() { printf '  %s\n' "$*"; }

turn() {
  # 1. whatever GitHub knows that the log does not
  "$B/fm-sync-prs.sh" --repo "$REPO" >/dev/null 2>&1 </dev/null || true

  # 2. start what is ready. dispatch refuses on its own if nothing is green-lit
  started="$("$B/fm-dispatch.sh" --repo "$REPO" 2>/dev/null </dev/null | grep -E '^T-' || true)"
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
      details="$REPO/state/decision-details/$id.json"
      if request_out="$("$B/fm-decide.sh" --request "$id" --task "$task" --kind merge --pr "$pr" \
        --details "$details" --repo "$REPO" 2>&1 </dev/null)"; then
        say "$task: all seven gates green, asking the captain ($id)"
      else
        say "$task: no captain card created; firstmate must supply valid authored details at $details ($request_out)"
      fi
    elif [ "$g" -eq 7 ]; then
      say "$task: gates 1-6 green, sending it to review (round $round)"
      # exit 3 is a round that produced no verdict. Swallowing it would let
      # a crashed engine read as a review that simply did not sign.
      # 65 is a typo in config.yaml, and the one line that says which name
      # is wrong is on stderr - so it is kept rather than thrown away with
      # the rest. A configuration error repeats every turn until a human
      # reads it; a message that suggests nothing is worse than none.
      rvout="$("$B/fm-review.sh" --task "$task" --branch "$branch" --pr "$pr" \
        --round "$round" --repo "$REPO" 2>&1 </dev/null)"
      # the child already said where its log is and which vendor name is
      # wrong. Every branch here repeats what it said rather than
      # reconstructing it: a reconstructed path is confidently wrong the
      # moment a round fails twice, and keep_log numbers the second one.
      rvrc=$?
      rvsaid="$(grep -E 'log is at|no adapter' <<< "$rvout" | tail -1)"
      case "$rvrc" in
        0) ;;
        2) say "$task: no reviewer engine was available${rvsaid:+ ($rvsaid)}, leaving it for the next turn" ;;
        3) say "$task: the reviewer produced no verdict${rvsaid:+ ($rvsaid)}" ;;
        65) say "$task: ${rvsaid:-config.yaml names a vendor with no adapter}" ;;
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
