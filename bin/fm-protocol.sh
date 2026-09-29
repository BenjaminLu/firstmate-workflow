#!/usr/bin/env bash
# The standing list. Every REJECT, from round one, ends with the task's
# numbered list closed by CRITERIA-COMPLETE; each later REJECT re-issues it
# with the same numbering, earlier items marked done or open, and appends a
# new item only as REGRESSION:<task> or NEW-GROUND:<task> (captain,
# 2026-09-29; SK-007). This decides mechanically whether that happened, so
# "the reviewer is drip-feeding" becomes a finding rather than a feeling.
#
#   fm-protocol.sh check --task T-004 --pr 9 --round 3 [--repo .]
#
# Exit 0 clean, 3 round three began with no standing list and no
# ASK-PASS-CRITERIA, 4 the worker asked and no list was ever closed, 5 a
# reviewer verdict raised something off the list without a label, 6 a re-issued
# list dropped an earlier item.
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
    --task) fm_need "fm-protocol" "$@"; TASK="${2-}"; shift 2 ;;
    --pr) fm_need "fm-protocol" "$@"; PR="${2-}"; shift 2 ;;
    --round) fm_need "fm-protocol" "$@"; ROUND="${2-}"; shift 2 ;;
    --repo) fm_need "fm-protocol" "$@"; REPO="${2-}"; shift 2 ;;
    *) echo "fm-protocol: unknown argument $1" >&2; exit 64 ;;
  esac
done
[ "$MODE" = check ] && [ -n "$TASK" ] && [ -n "$PR" ] || {
  echo "usage: fm-protocol.sh check --task <id> --pr <n> [--round n]" >&2; exit 64; }
cd "$REPO" || { echo "fm-protocol: no repo at $REPO" >&2; exit 64; }

emit() { FM_ROOT="$REPO" "$REPO/bin/fm-emit.sh" --actor firstmate --task "$TASK" --pr "$PR" "$@" >/dev/null 2>&1 </dev/null || true; }

# one comment per line: author, then the body with newlines folded to \r so a
# multi-line review stays one record
comments="$($GH pr view "$PR" --json comments \
  --jq '.comments[]|[.author.login,(.body|gsub("\n";"\r"))]|@tsv' 2>/dev/null)" || {
  echo "fm-protocol: cannot read #$PR" >&2; exit 1; }

[ "$ROUND" -ge 3 ] 2>/dev/null || { echo "fm-protocol: round $ROUND, nothing to enforce"; exit 0; }

# A marker counts only as a line of its own, as fm-review.sh reads it: a
# comment that mentions one in passing neither asks nor closes a list.
has_marker() {
  grep -qxF "$1:$TASK" <<< "$(sed 's/^[[:space:]]*//;s/[[:space:]]*$//' <<< "$2")"
}
item_no() { sed -nE 's/^[[:space:]]*([0-9]+)[.)].*/\1/p'; }

asked=0; closed=0; list_len=0; items=''; off=''; dropped=''
while IFS=$'\t' read -r who folded; do
  [ -n "$who" ] || continue
  text="$(printf '%s' "$folded" | tr '\r' '\n')"
  if has_marker ASK-PASS-CRITERIA "$text"; then asked=1; continue; fi
  if has_marker CRITERIA-COMPLETE "$text"; then
    # the list is the numbered lines before the last closing marker
    numbered="$(printf '%s\n' "$text" | awk -v m="CRITERIA-COMPLETE:$TASK" '
      { l = $0; gsub(/^[ \t]+|[ \t]+$/, "", l); line[NR] = $0; if (l == m) last = NR }
      END { for (i = 1; i < last; i++) print line[i] }' |
      grep -E '^[[:space:]]*[0-9]+[.)][[:space:]]')"
    nums="$(printf '%s\n' "$numbered" | item_no | sort -un)"
    if [ "$closed" = 1 ]; then
      # the latest list is the standing one, so it may not shrink: an item
      # leaves only by being marked done
      for n in $items; do
        grep -qx "$n" <<< "$nums" || dropped="${dropped}the list dropped item $n
"
      done
      # and an item it appends carries its label on its own line
      while IFS= read -r line; do
        [ -n "$line" ] || continue
        grep -qx "$(item_no <<< "$line")" <<< "$items" && continue
        case "$line" in
          *"REGRESSION:$TASK"*|*"NEW-GROUND:$TASK"*) ;;
          *) off="$off$(printf '%s' "$line" | head -c 90)
" ;;
        esac
      done <<< "$numbered"
    fi
    closed=1; items="$nums"
    list_len="$(grep -c . <<< "$nums")"
    continue
  fi
  [ "$closed" = 1 ] || continue
  # only a reviewer verdict is policed: the list now closes at the first
  # REJECT, so the worker's notes, .fm-say.md and firstmate's briefs follow it,
  # and none of them is a finding, whoever posted it
  has_marker REJECT "$text" || has_marker REVIEWER_COMPLETE "$text" || continue
  [ -z "$REVIEWER" ] || [ "$who" = "$REVIEWER" ] || continue
  case "$text" in
    *"APPROVE:$TASK"*|*"REGRESSION:$TASK"*|*"NEW-GROUND:$TASK"*) continue ;;
  esac
  # after the list closes, a comment has to cite an item on it
  if ! grep -qE '(^|[^0-9])[0-9]+[.)]|item[[:space:]]+[0-9]+|#[0-9]+' <<< "$text"; then
    off="$off$(printf '%s' "$text" | head -c 90)"
    off="$off
"
  fi
done <<< "$comments"

# the gate is a standing list, not the ask: the worker asks only when it
# finds no list, or an unclear one
if [ "$closed" = 0 ] && [ "$asked" = 0 ]; then
  echo "fm-protocol: round $ROUND with no standing list (CRITERIA-COMPLETE:$TASK) and no ASK-PASS-CRITERIA:$TASK" >&2
  emit --type protocol_violation --en "round $ROUND began without a standing list and without asking for the criteria" \
       --tw "第 $ROUND 輪既無現行清單也未先發 ASK-PASS-CRITERIA"
  exit 3
fi
if [ "$closed" = 0 ]; then
  echo "fm-protocol: the reviewer never posted CRITERIA-COMPLETE:$TASK" >&2
  emit --type protocol_violation --en "the criteria list was never declared complete" \
       --tw "reviewer 未宣告封閉清單完整"
  exit 4
fi
if [ -n "$dropped" ]; then
  echo "fm-protocol: a re-issued list is not the standing one:" >&2
  printf '%s' "$dropped" | sed 's/^/  /' >&2
  emit --type protocol_violation --en "a re-issued list dropped an item without marking it done" \
       --tw "重發的清單漏掉了未標記完成的項目"
  exit 6
fi
if [ -n "$(printf '%s' "$off" | tr -d '[:space:]')" ]; then
  echo "fm-protocol: the reviewer raised something off the closed list of $list_len, unlabelled:" >&2
  printf '%s' "$off" | sed 's/^/  /' >&2
  emit --type protocol_violation --en "reviewer raised an off-list item after closing a list of $list_len" \
       --tw "reviewer 在封閉 $list_len 項清單後提出清單外問題"
  exit 5
fi
echo "fm-protocol: round $ROUND clean, $list_len items on the closed list"
emit --type criteria_returned --en "round $ROUND clean, $list_len closed items" \
     --tw "第 $ROUND 輪協定正常，封閉清單 $list_len 項"
exit 0
