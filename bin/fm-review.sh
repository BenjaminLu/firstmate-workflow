#!/usr/bin/env bash
# Runs one review round. The reviewer is given the diff, the task spec and the
# acceptance criteria - and nothing else. Not the worker's log, not its
# reasoning, not even the path it worked in. Reasoning is persuasive; the
# artefact is what is under review.
#
#   fm-review.sh --task T-004 --branch <name> [--repo .] [--pr 9] [--round 1]
set -uo pipefail
# Nothing below may read standard input. A dispatched child inherits it, and
# a child that reads it blocks the caller waiting for a human who is not
# there. One guarantee, in one place; bin/ci.sh fails if a script that
# dispatches is missing it.
exec < /dev/null
_fm_lib="$(dirname "${BASH_SOURCE[0]}")/fm-config.sh"
[ -f "$_fm_lib" ] || { echo "${0##*/}: missing $_fm_lib" >&2; exit 70; }
# shellcheck source=bin/fm-config.sh
. "$_fm_lib"

REPO="${FM_ROOT:-$(pwd)}"; TASK=''; BRANCH=''; PR=''; ROUND=1; VENDOR=''
BASE="${FM_BASE:-main}"; GH="${FM_GH:-gh}"
while [ $# -gt 0 ]; do
  case "$1" in
    --task) TASK="${2-}"; shift 2 ;;
    --branch) BRANCH="${2-}"; shift 2 ;;
    --repo) REPO="${2-}"; shift 2 ;;
    --pr) PR="${2-}"; shift 2 ;;
    --round) ROUND="${2-}"; shift 2 ;;
    --vendor) VENDOR="${2-}"; shift 2 ;;
    *) echo "fm-review: unknown argument $1" >&2; exit 64 ;;
  esac
done
[ -n "$TASK" ] && [ -n "$BRANCH" ] || {
  echo "usage: fm-review.sh --task <id> --branch <name> [--pr N] [--round N]" >&2; exit 64; }
cd "$REPO" || { echo "fm-review: no repo at $REPO" >&2; exit 64; }

emit() { FM_ROOT="$REPO" "$REPO/bin/fm-emit.sh" --actor reviewer-1 --task "$TASK" "$@" >/dev/null 2>&1 </dev/null || true; }

# The task spec comes from the branch under review, not from whatever is
# checked out. A task defined on its own branch - which is how a new one
# arrives - was invisible to the reviewer and to the gate: `no task
# T-027`, for a task sitting in the diff they were handed.
task_spec() {   # task_spec <task> [branch]
  local t="$1" b="${2:-}" j=''
  [ -n "$b" ] && j="$(git show "$b:design/tasks.json" 2>/dev/null)"
  [ -n "$j" ] || j="$(cat design/tasks.json 2>/dev/null)"
  printf '%s' "$j" | jq -r --arg t "$t" '.tasks[]|select(.id==$t)' 2>/dev/null
}
spec="$(task_spec "$TASK" "$BRANCH")"
[ -n "$spec" ] || { echo "fm-review: no task $TASK" >&2; exit 65; }

# A round that produced nothing is not a round, so review_opened is emitted
# once the chain has actually produced a verdict - otherwise three crashed
# engines would walk a task into the round-three protocol with no review
# ever posted. And because a failed round therefore does not advance the
# counter, its log must not overwrite the last one's.
keep_log() {
  local dir="$REPO/state/reviews" n=1 p
  mkdir -p "$dir"
  p="$dir/$TASK-r$ROUND.log"
  while [ -e "$p" ]; do n=$((n + 1)); p="$dir/$TASK-r$ROUND.$n.log"; done
  printf '%s' "$p"
}

work="$(mktemp -d)"
prompt="$work/prompt.md"
{
  cat skills/reviewer/SKILL.md
  printf '\n---\n\n# The task\n\n```json\n%s\n```\n' "$spec"
  printf '\n# Round %s\n' "$ROUND"
  [ "$ROUND" -ge 3 ] && printf '\nThis is round three or later. If the worker has posted ASK-PASS-CRITERIA, answer with the complete numbered list and then post CRITERIA-COMPLETE:%s.\n' "$TASK"
  printf '\n---\n\n# The diff under review\n\n```diff\n'
  git diff "$BASE...$BRANCH"
  printf '```\n'
} > "$prompt"

# the reviewer runs on its own engine when config.yaml names one, and falls
# back exactly the way the worker does - one chain, one runner
# the reviewer is an agent too, and the captain has to be able to open it
# and read what it actually did - not only see that a round happened
rand_hex() { LC_ALL=C hexdump -n "$1" -v -e '/1 "%02x"' /dev/urandom; }
FM_SESSION_ID="$(printf '%s-%s-4%s-a%s-%s' \
  "$(rand_hex 4)" "$(rand_hex 2)" "$(rand_hex 2 | cut -c2-4)" \
  "$(rand_hex 2 | cut -c2-4)" "$(rand_hex 6)")"
export FM_SESSION_ID

mkdir -p "$work/out"
# The reviewer's evidence: a verdict marker. A signed review IS the run's
# standard output, so a signature matcher calling it an outage would throw
# away the very thing it was asked for - and the next turn would read the
# same output and say the same thing, forever.
# only this attempt's bytes: its own output directory, and the part of the
# shared log it wrote. A vendor that died half way through must not sign on
# the next one's behalf.
# ONE definition of what an attempt produced, used by the predicate, by the
# verdict and by the kept log. There were three: the predicate read the out
# directory and the log together, the verdict took the out directory if it
# had anything at all in it, and the log only otherwise. A reviewer whose
# agent left a scratch file in its working directory therefore had its
# signed review - printed on stdout, in the log - thrown away for the
# scratch file, and the round repeated for ever.
#
# No pipeline in it either: with `set -o pipefail` a cat that finds nothing
# fails the whole pipeline even when the grep matched.
attempt_output() {
  { cat "${FM_RUN_OUTDIR:-$work/out}"/* 2>/dev/null
    tail -c "+$((${FM_RUN_LOG_OFF:-0} + 1))" "$work/log" 2>/dev/null; } || true
}
review_is_signed() {
  local seen; seen="$(attempt_output)"
  case "$seen" in *"APPROVE:$TASK"*|*"REJECT:$TASK"*) return 0 ;; esac
  return 1
}
fm_run_chain "$REPO/bin/adapters" "$(fm_vendor_chain reviewer "$VENDOR")" \
  "$prompt" "$work/out" "$work/log" review_is_signed per-vendor; rc=$?
[ -z "$FM_VENDOR_UNKNOWN" ] || {
  echo "fm-review: config.yaml names a vendor with no adapter: $FM_VENDOR_UNKNOWN" >&2
  rm -rf "$work"; exit 65; }
[ -z "$FM_VENDOR_MISREAD" ] || \
  echo "fm-review: $FM_VENDOR_MISREAD was read as unavailable, but it signed a verdict - keeping it" >&2
for v in $FM_VENDOR_SKIPPED; do
  emit --type vendor_unavailable --en "$v unavailable, trying the next" \
       --tw "$v 不可用，換下一家"
done
verdict="$(attempt_output)"

# The chain says which of the two this was, and both callers read the same
# answer: rc 2 with nothing said is a vendor that was not there, and only
# that earns a 2. An engine that ran and said something unsigned is a
# failed round - exit 2 there would have fm-run retry the same input every
# turn, for ever.
if [ "$rc" = "2" ] && [ "${FM_VENDOR_SPOKE:-0}" = "0" ]; then
  kept="$(keep_log)"
  cp "$work/log" "$kept" 2>/dev/null || : > "$kept"
  echo "fm-review: every reviewer vendor was unavailable; their log is at $kept" >&2
  rm -rf "$work"; exit 2
fi
# a review that did not happen must never look like one that did. An empty
# verdict used to reach the pull request as the adapter's own log, and gate 7
# would then be reading a stack trace for a signature.
# A verdict has to be one of the two markers. Without that rule a crashed
# engine's stack trace on stdout is indistinguishable from a review, because
# a real reviewer's verdict IS its stdout.
signed=0
case "$verdict" in *"APPROVE:$TASK"*|*"REJECT:$TASK"*) signed=1 ;; esac
# An exit code does not overrule produced work - not here either. A CLI that
# prints a complete signed review and then exits non-zero on some teardown
# has still reviewed it, and throwing that away repeats the round for ever.
if [ "$signed" = "0" ]; then
  # Keep everything that was said, from wherever it came - the engine's log
  # and whatever it left in the output directory. The failure path is
  # exactly when someone needs to read it; only the success path may discard.
  kept="$(keep_log)"
  # the whole log here, not just this attempt's slice: on the failure path
  # every vendor's excuse is worth reading, and the attempt's own output is
  # already inside it
  { cat "$work/log" 2>/dev/null; attempt_output; } > "$kept"
  echo "fm-review: ${FM_VENDOR_USED:-the reviewer} produced no review (exit $rc); its log is at $kept" >&2
  emit --type review_failed --en "review round $ROUND produced nothing" \
       --tw "第 $ROUND 輪審核沒有產出"
  rm -rf "$work"; exit 3
fi
emit --type review_opened --data "$(jq -cn --arg s "${FM_SESSION_ID:-}" '{session:$s}')" \
     --en "round $ROUND on $TASK (session ${FM_SESSION_ID:-none})" \
     --tw "${TASK} 第 ${ROUND} 輪審核（session ${FM_SESSION_ID:-none}）"
if [ -n "$PR" ]; then
  $GH pr comment "$PR" --body "$verdict" >/dev/null 2>&1 || true
fi
case "$verdict" in
  *"APPROVE:$TASK"*) emit --type approved --en "reviewer signed $TASK" --tw "reviewer 已簽 $TASK" ;;
esac
printf '%s\n' "$verdict"
rm -rf "$work"
exit 0
