#!/usr/bin/env bash
# Runs one review round. The reviewer is given the diff, the task spec and the
# acceptance criteria - and nothing else. Not the worker's log, not its
# reasoning, not even the path it worked in. Reasoning is persuasive; the
# artefact is what is under review.
#
#   fm-review.sh --task T-004 --branch <name> [--repo .] [--pr 9] [--round 1]
set -uo pipefail
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

emit() { FM_ROOT="$REPO" "$REPO/bin/fm-emit.sh" --actor reviewer-1 --task "$TASK" "$@" >/dev/null 2>&1 || true; }

spec="$(jq -r --arg t "$TASK" '.tasks[]|select(.id==$t)' design/tasks.json 2>/dev/null)"
[ -n "$spec" ] || { echo "fm-review: no task $TASK" >&2; exit 65; }

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
emit --type review_opened --en "round $ROUND on $TASK" --tw "$TASK 第 $ROUND 輪審核"
mkdir -p "$work/out"
fm_run_chain "$REPO/bin/adapters" "$(fm_vendor_chain reviewer "$VENDOR")" \
  "$prompt" "$work/out" "$work/log"; rc=$?
for v in $FM_VENDOR_SKIPPED; do
  emit --type vendor_unavailable --en "$v unavailable, trying the next" \
       --tw "$v 不可用，換下一家"
done
if [ "$rc" = "2" ]; then
  echo "fm-review: every reviewer vendor was unavailable" >&2; rm -rf "$work"; exit 2
fi

verdict="$(cat "$work/out"/* 2>/dev/null)"
[ -n "$verdict" ] || verdict="$(cat "$work/log" 2>/dev/null)"
# a review that did not happen must never look like one that did. An empty
# verdict used to reach the pull request as the adapter's own log, and gate 7
# would then be reading a stack trace for a signature.
if [ "$rc" != "0" ] || [ -z "$verdict" ]; then
  echo "fm-review: ${FM_VENDOR_USED:-the reviewer} produced no review (exit $rc)" >&2
  emit --type review_failed --en "review round $ROUND produced nothing" \
       --tw "第 $ROUND 輪審核沒有產出"
  rm -rf "$work"; exit 3
fi
if [ -n "$PR" ]; then
  $GH pr comment "$PR" --body "$verdict" >/dev/null 2>&1 || true
fi
case "$verdict" in
  *"APPROVE:$TASK"*) emit --type approved --en "reviewer signed $TASK" --tw "reviewer 已簽 $TASK" ;;
esac
printf '%s\n' "$verdict"
rm -rf "$work"
exit 0
