#!/usr/bin/env bash
# Round three. The worker asks once, the reviewer answers once and completely,
# and after that the list is closed. This decides mechanically whether that
# happened, so "the reviewer is drip-feeding" becomes a finding rather than a
# feeling.
#
#   fm-protocol.sh check --task T-004 --pr 9 --round 3 [--repo .]
#
# Exit 0 clean, 3 the worker skipped the question, 4 the list was never
# closed, 5 the reviewer raised something off the closed list.
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

REPO="${FM_ROOT:-$(pwd)}"; TASK=''; PR=''; ROUND=1; GH="${FM_GH:-gh}"; MODE=''
REVIEWER="${FM_REVIEWER_LOGIN:-}"
while [ $# -gt 0 ]; do
  case "$1" in
    check) MODE=check; shift ;;
    --task) TASK="${2-}"; shift 2 ;;
    --pr) PR="${2-}"; shift 2 ;;
    --round) ROUND="${2-}"; shift 2 ;;
    --repo) REPO="${2-}"; shift 2 ;;
    *) echo "fm-protocol: unknown argument $1" >&2; exit 64 ;;
  esac
done
[ "$MODE" = check ] && [ -n "$TASK" ] && [ -n "$PR" ] || {
  echo "usage: fm-protocol.sh check --task <id> --pr <n> [--round n]" >&2; exit 64; }
cd "$REPO" || { echo "fm-protocol: no repo at $REPO" >&2; exit 64; }

emit() { FM_ROOT="$REPO" "$REPO/bin/fm-emit.sh" --actor firstmate --task "$TASK" --pr "$PR" "$@" >/dev/null 2>&1 || true; }

# one comment per line: author, then the body with newlines folded to \r so a
# multi-line review stays one record
comments="$($GH pr view "$PR" --json comments \
  --jq '.comments[]|[.author.login,(.body|gsub("\n";"\r"))]|@tsv' 2>/dev/null)" || {
  echo "fm-protocol: cannot read #$PR" >&2; exit 1; }

[ "$ROUND" -ge 3 ] 2>/dev/null || { echo "fm-protocol: round $ROUND, nothing to enforce"; exit 0; }

asked=0; closed=0; list_len=0; off=''
while IFS=$'\t' read -r who folded; do
  [ -n "$who" ] || continue
  text="$(printf '%s' "$folded" | tr '\r' '\n')"
  case "$text" in *"ASK-PASS-CRITERIA:$TASK"*) asked=1; continue ;; esac
  case "$text" in
    *"CRITERIA-COMPLETE:$TASK"*)
      closed=1
      # the numbered items in the closing comment are the whole of the list
      list_len="$(printf '%s\n' "$text" | grep -cE '^[[:space:]]*[0-9]+[.)]')"
      continue ;;
  esac
  [ "$closed" = 1 ] || continue
  [ -z "$REVIEWER" ] || [ "$who" = "$REVIEWER" ] || continue
  case "$text" in
    *"APPROVE:$TASK"*|*"REGRESSION:$TASK"*) continue ;;
  esac
  # after the list closes, a comment has to cite an item on it
  if ! printf '%s\n' "$text" | grep -qE '(^|[^0-9])[0-9]+[.)]|item[[:space:]]+[0-9]+|#[0-9]+'; then
    off="$off$(printf '%s' "$text" | head -c 90)"
    off="$off
"
  fi
done <<< "$comments"

if [ "$asked" = 0 ]; then
  echo "fm-protocol: round $ROUND with no ASK-PASS-CRITERIA:$TASK from the worker" >&2
  emit --type protocol_violation --en "round $ROUND began without asking for the criteria" \
       --tw "第 $ROUND 輪未先發 ASK-PASS-CRITERIA"
  exit 3
fi
if [ "$closed" = 0 ]; then
  echo "fm-protocol: the reviewer never posted CRITERIA-COMPLETE:$TASK" >&2
  emit --type protocol_violation --en "the criteria list was never declared complete" \
       --tw "reviewer 未宣告封閉清單完整"
  exit 4
fi
if [ -n "$(printf '%s' "$off" | tr -d '[:space:]')" ]; then
  echo "fm-protocol: the reviewer raised something off the closed list of $list_len:" >&2
  printf '%s' "$off" | sed 's/^/  /' >&2
  emit --type protocol_violation --en "reviewer raised an off-list item after closing a list of $list_len" \
       --tw "reviewer 在封閉 $list_len 項清單後提出清單外問題"
  exit 5
fi
echo "fm-protocol: round $ROUND clean, $list_len items on the closed list"
emit --type criteria_returned --en "round $ROUND clean, $list_len closed items" \
     --tw "第 $ROUND 輪協定正常，封閉清單 $list_len 項"
exit 0
