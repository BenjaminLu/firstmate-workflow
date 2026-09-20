#!/usr/bin/env bash
# Runs one review round. The reviewer is given the diff, the task spec and the
# acceptance criteria - and nothing else. Not the worker's log, not its
# reasoning, not even the path it worked in. Reasoning is persuasive; the
# artefact is what is under review.
#
#   fm-review.sh --task T-004 --branch <name> [--repo .] [--pr 9] [--round 1]
set -uo pipefail

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
cfg()  { sed -n "s/^$1:[[:space:]]*//p" config.yaml 2>/dev/null | head -1 | tr -d '"'; }
rcfg() { sed -n '/^reviewer:/,/^[^ ]/p' config.yaml 2>/dev/null | sed -n "s/^[[:space:]]*$1:[[:space:]]*//p" | head -1; }

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

# the reviewer runs on its own engine when config.yaml names one
v="${VENDOR:-$(rcfg vendor)}"; [ -n "$v" ] || v="$(cfg vendor)"; [ -n "$v" ] || v=mock
a="$REPO/bin/adapters/$v.sh"
[ -x "$a" ] || { echo "fm-review: no adapter $v" >&2; rm -rf "$work"; exit 65; }

emit --type review_opened --en "round $ROUND on $TASK" --tw "$TASK 第 $ROUND 輪審核"
mkdir -p "$work/out"
"$a" run "$prompt" "$work/out" "$work/log"; rc=$?
[ "$rc" = "2" ] && { echo "fm-review: $v unavailable" >&2; rm -rf "$work"; exit 2; }

verdict="$(cat "$work/out"/* 2>/dev/null)"
[ -n "$verdict" ] || verdict="$(cat "$work/log" 2>/dev/null)"
if [ -n "$PR" ] && [ -n "$verdict" ]; then
  $GH pr comment "$PR" --body "$verdict" >/dev/null 2>&1 || true
fi
case "$verdict" in
  *"APPROVE:$TASK"*) emit --type approved --en "reviewer signed $TASK" --tw "reviewer 已簽 $TASK" ;;
esac
printf '%s\n' "$verdict"
rm -rf "$work"
exit 0
