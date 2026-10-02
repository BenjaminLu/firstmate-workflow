#!/usr/bin/env bash
# The standing list. Every REJECT, from round one, ends with the task's
# numbered list closed by CRITERIA-COMPLETE; each later REJECT re-issues it
# with the same numbering, earlier items marked done or open, and appends a
# new item only as REGRESSION:<task> or NEW-GROUND:<task> (captain,
# 2026-09-29; SK-007). This decides mechanically whether that happened, so
# "the reviewer is drip-feeding" becomes a finding rather than a feeling.
#
#   fm-protocol.sh check --task T-004 [--pr 9] [--round 3] [--repo .]
#
# Exit 0 for valid local standing-list syntax, 3 for missing/invalid evidence.
# The diagnostic names the violated rule. Syntax does not establish semantics.
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

REPO="${FM_ROOT:-$(pwd)}"; TASK=''; PR=''; ROUND=1; MODE=''
while [ $# -gt 0 ]; do
  case "$1" in
    check) MODE=check; shift ;;
    --project) fm_need "fm-protocol" "$@"; export FM_PROJECT="${2-}"; shift 2 ;;
    --task) fm_need "fm-protocol" "$@"; TASK="${2-}"; shift 2 ;;
    --pr) fm_need "fm-protocol" "$@"; PR="${2-}"; shift 2 ;;
    --round) fm_need "fm-protocol" "$@"; ROUND="${2-}"; shift 2 ;;
    --repo) fm_need "fm-protocol" "$@"; REPO="${2-}"; shift 2 ;;
    *) echo "fm-protocol: unknown argument $1" >&2; exit 64 ;;
  esac
done
[ "$MODE" = check ] && [ -n "$TASK" ] || {
  echo "usage: fm-protocol.sh check --task <id> [--pr <n>] [--round n] [--repo path] [--project name]" >&2; exit 64; }
cd "$REPO" || { echo "fm-protocol: no repo at $REPO" >&2; exit 64; }

emit() { FM_ROOT="$REPO" "$REPO/bin/fm-emit.sh" --actor firstmate --task "$TASK" --pr "$PR" "$@" >/dev/null 2>&1 </dev/null || true; }

fm_storage_init "$REPO" || exit 65
if ! result="$(fm_evidence protocol --round "$ROUND" 2>&1)"; then
  printf '%s\n' "$result" >&2
  emit --type protocol_violation --en "$result" --tw "本機審查協定檢查失敗：$result"
  exit 3
fi
printf '%s\n' "$result"
emit --type criteria_returned --en "round $ROUND local standing-list protocol is clean" \
     --tw "第 $ROUND 輪本機現行清單協定檢查通過"
