#!/usr/bin/env bash
# Removes one task's worktree after its pull request has merged, and refuses
# to remove anything else. A script that deletes directories has to be boring
# about which ones: the check is on the resolved path, never on the string it
# was handed.
#
#   fm-cleanup.sh --task T-004 [--repo .] [--force]
set -uo pipefail
# Nothing below may read standard input. A dispatched child inherits it, and
# a child that reads it blocks the caller waiting for a human who is not
# there. One guarantee, in one place; bin/ci.sh fails if a script that
# dispatches is missing it.
exec < /dev/null

REPO="${FM_ROOT:-$(pwd)}"; TASK=''; FORCE=0; GH="${FM_GH:-gh}"
# see fm_need in bin/fm-config.sh for why: `shift 2` with one argument
# left does not shift, and the loop spins. This file deliberately depends
# on nothing, so it carries the two lines rather than the explanation.
need() { [ "$#" -ge 2 ] || { echo "fm-cleanup: $1 needs a value" >&2; exit 64; }; }
while [ $# -gt 0 ]; do
  case "$1" in
    --task) need "$@"; TASK="${2-}"; shift 2 ;;
    --repo) need "$@"; REPO="${2-}"; shift 2 ;;
    --force) FORCE=1; shift ;;
    *) echo "fm-cleanup: unknown argument $1" >&2; exit 64 ;;
  esac
done
[ -n "$TASK" ] || { echo "usage: fm-cleanup.sh --task <id> [--repo dir] [--force]" >&2; exit 64; }

abs() { ( cd "$1" 2>/dev/null && pwd -P ) || return 1; }
REPO="$(abs "$REPO")" || { echo "fm-cleanup: no repo at $REPO" >&2; exit 64; }
cd "$REPO" || exit 64

ROOT="$REPO/state/worktrees"
target="$ROOT/$TASK"

# --- nothing happens if there is nothing there ---------------------------
[ -e "$target" ] || { echo "fm-cleanup: $TASK has no worktree"; exit 0; }

# --- the resolved path must be a direct child of our own root ------------
root_real="$(abs "$ROOT")" || { echo "fm-cleanup: no worktree root" >&2; exit 1; }
tgt_real="$(abs "$target")" || { echo "fm-cleanup: cannot resolve $target" >&2; exit 1; }
case "$tgt_real" in
  "$root_real"/*) ;;
  *) echo "fm-cleanup: refusing $tgt_real - outside $root_real" >&2; exit 1 ;;
esac
[ "$(dirname "$tgt_real")" = "$root_real" ] || {
  echo "fm-cleanup: refusing $tgt_real - not a direct child of the root" >&2; exit 1; }
[ "$tgt_real" != "$REPO" ] || { echo "fm-cleanup: refusing the repository itself" >&2; exit 1; }

# --- and it must be a worktree this repository registered ----------------
main_wt="$(git worktree list --porcelain | sed -n '1s/^worktree //p')"
[ "$tgt_real" != "$(abs "$main_wt")" ] || { echo "fm-cleanup: refusing the main worktree" >&2; exit 1; }
known=''
while IFS= read -r w; do
  [ -n "$w" ] || continue
  known="$known$(abs "$w" 2>/dev/null)"$'\n'
done <<< "$(git worktree list --porcelain | sed -n 's/^worktree //p')"
grep -qxF "$tgt_real" <<< "$known" || {
  echo "fm-cleanup: refusing $tgt_real - not a worktree of this repository" >&2; exit 1; }

# --- an open pull request is someone's unfinished work -------------------
branch="$(git -C "$tgt_real" branch --show-current 2>/dev/null || true)"
if [ "$FORCE" -eq 0 ] && [ -n "$branch" ]; then
  state="$($GH pr view "$branch" --json state --jq .state 2>/dev/null || true)"
  case "$state" in
    OPEN) echo "fm-cleanup: $branch still has an open pull request" >&2; exit 1 ;;
  esac
fi

git worktree remove --force "$tgt_real" >/dev/null 2>&1 || rm -rf "$tgt_real"
git worktree prune >/dev/null 2>&1
[ -n "$branch" ] && git branch -D "$branch" >/dev/null 2>&1
rm -f "$ROOT/$TASK.log"
FM_ROOT="$REPO" "$REPO/bin/fm-emit.sh" --actor firstmate --task "$TASK" --type closed \
  --en "worktree for $TASK removed" --tw "已移除 $TASK 的 worktree" >/dev/null 2>&1 </dev/null || true
echo "fm-cleanup: removed $tgt_real"
exit 0
