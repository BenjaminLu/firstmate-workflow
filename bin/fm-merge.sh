#!/usr/bin/env bash
# The only thing allowed to merge. The board never merges; it writes a
# decision and calls this, so there is one place that validates and one place
# that emits, whoever pressed the button.
#
#   fm-merge.sh --pr 16 [--task T-009] [--repo .]
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

REPO="${FM_ROOT:-$(pwd)}"; PR=''; TASK=''; GH="${FM_GH:-gh}"
# `shift 2` with one argument left does not shift: it returns 1 and leaves
# $@ alone, so `while [ $# -gt 0 ]` spins on the same flag for ever. Every
# flag that takes a value goes through this, which refuses instead. A test
# for it has to run under an alarm, or it hangs the gate rather than
# failing it - tests/option-loop.test.sh does.
need() {   # need <flag>: there has to be a value after it
  [ "$#" -ge 2 ] || { echo "fm-merge: $1 needs a value" >&2; exit 64; }
}
while [ $# -gt 0 ]; do
  case "$1" in
    --pr) need "$@"; PR="${2-}"; shift 2 ;;
    --task) need "$@"; TASK="${2-}"; shift 2 ;;
    --repo) need "$@"; REPO="${2-}"; shift 2 ;;
    *) echo "fm-merge: unknown argument $1" >&2; exit 64 ;;
  esac
done
cd "$REPO" || { echo "fm-merge: no repo at $REPO" >&2; exit 64; }

# a pull request number is a number. Anything else is someone probing.
case "$PR" in
  ''|*[!0-9]*) echo "fm-merge: --pr must be a number, got '$PR'" >&2; exit 64 ;;
esac

state="$($GH pr view "$PR" --json state --jq .state 2>/dev/null </dev/null || true)"

# A merged event with no task is an event the board cannot use: the reducer
# keys on the task, so the task sits in whatever lane it was in and the
# board shows finished work as work in progress. A branch is named after
# its task, the same way fm-sync-prs reads it, so ask rather than require
# the caller to remember.
if [ -z "$TASK" ]; then
  headref="$($GH pr view "$PR" --json headRefName --jq .headRefName 2>/dev/null </dev/null || true)"
  TASK="$(printf '%s' "$headref" | sed -n 's/^\([tT]-\{0,1\}[0-9]\{3\}\).*/\1/p' \
          | tr 'a-z' 'A-Z' | sed 's/^T\([0-9]\)/T-\1/')"
  [ -z "$TASK" ] || echo "fm-merge: #$PR is $TASK, by its branch name"
fi
case "$state" in
  OPEN) ;;
  MERGED) echo "fm-merge: #$PR is already merged"; exit 0 ;;
  '') echo "fm-merge: cannot read #$PR" >&2; exit 1 ;;
  *) echo "fm-merge: #$PR is $state, not open" >&2; exit 1 ;;
esac

$GH pr merge "$PR" --squash --delete-branch >/dev/null 2>&1 || {
  echo "fm-merge: GitHub refused the merge of #$PR" >&2; exit 1; }

FM_ROOT="$REPO" "$REPO/bin/fm-emit.sh" --actor captain --type merged --pr "$PR" \
  ${TASK:+--task "$TASK"} --en "merged #$PR from the board" --tw "從看板合併 #$PR" \
  >/dev/null 2>&1 </dev/null || true
[ -n "$TASK" ] && [ -x "$REPO/bin/fm-cleanup.sh" ] && \
  FM_ROOT="$REPO" FM_GH="$GH" "$REPO/bin/fm-cleanup.sh" --task "$TASK" --repo "$REPO" \
    </dev/null 2>&1 | sed "s/^/  /"
echo "fm-merge: merged #$PR"
exit 0
