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
_storage_lib="$(dirname "${BASH_SOURCE[0]}")/fm-config.sh"
if [ -r "$_storage_lib" ]; then
  # shellcheck source=bin/fm-config.sh
  . "$_storage_lib"
fi

REPO="${FM_ROOT:-$(pwd)}"; TASK=''; FORCE=0; GH="${FM_GH:-gh}"
# see fm_need in bin/fm-config.sh for why: `shift 2` with one argument
# left does not shift, and the loop spins. This file deliberately depends
# on nothing, so it carries the two lines rather than the explanation.
need() { [ "$#" -ge 2 ] || { echo "fm-cleanup: $1 needs a value" >&2; exit 64; }; }
while [ $# -gt 0 ]; do
  case "$1" in
    --project) need "$@"; export FM_PROJECT="${2-}"; shift 2 ;;
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

if declare -f fm_storage_init >/dev/null; then
  fm_storage_init "$REPO" || exit 65
else
  [ -z "${FM_PROJECT:-}" ] || { echo "fm-cleanup: named project needs $_storage_lib" >&2; exit 65; }
  FM_WORKTREES="$REPO/state/worktrees"; FM_TARGET_ROOT="$REPO"
fi
if declare -f fm_target_validate >/dev/null; then fm_target_validate || exit 65; fi
ROOT="$FM_WORKTREES"
[[ "$TASK" =~ ^[A-Za-z0-9][A-Za-z0-9_-]*$ ]] || exit 65
[ ! -L "$ROOT/$TASK" ] || exit 65
target="$ROOT/$TASK"
cd "$FM_TARGET_ROOT" || exit 65

# --- nothing happens if there is nothing there ---------------------------
[ -e "$target" ] || { echo "fm-cleanup: $TASK has no worktree"; exit 0; }

if [ "${FM_EXTERNAL:-0}" = 1 ]; then
  # Hold the same task exclusion as the launcher throughout deletion. A force
  # flag may waive the PR-state check, never ownership of unfinished work.
  mkdir -p "$FM_STATE_DIR/runs" || exit 65
  exec 8>>"$FM_STATE_DIR/runs/.worker-$TASK.lock" || exit 65
  perl -MFcntl=:flock -e 'open(my $lock, "+<&=8") or exit 1;
    flock($lock, LOCK_EX | LOCK_NB) or exit 1' || {
    echo 'fm-cleanup: task has a live worker; worktree retained' >&2; exit 65; }
  python3 "${FM_CODE_ROOT:-$REPO}/bin/fm-herdr.py" task-idle "$REPO" "$TASK" || exit 65
fi

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
  github_args=()
  [ "${FM_EXTERNAL:-0}" != 1 ] || github_args=(--repo "$GH_REPO")
  state="$($GH pr view "$branch" --json state --jq .state ${github_args[@]+"${github_args[@]}"} 2>/dev/null || true)"
  if [ "${FM_EXTERNAL:-0}" = 1 ] && [ "$state" != MERGED ] && [ "$state" != CLOSED ]; then
    echo "fm-cleanup: external PR is open or its outcome is unknown; worktree retained" >&2
    exit 65
  fi
  case "$state" in
    OPEN) echo "fm-cleanup: $branch still has an open pull request" >&2; exit 1 ;;
  esac
fi

git worktree remove --force "$tgt_real" >/dev/null 2>&1 || rm -rf "$tgt_real"
git worktree prune >/dev/null 2>&1
delete_branch=true
if [ "${FM_EXTERNAL:-0}" = 1 ]; then
  delete_branch="$(fm_conventions delete_branch 2>/dev/null)" || delete_branch=false
  if [ "$delete_branch" = true ]; then
    # A branch used as another PR's base is retained, even after its own PR
    # merged. Unreadable downstream evidence is retention, never permission.
    downstream="$(fm_github pr list --state open --base "$branch" --json number 2>/dev/null)" || downstream='unknown'
    [ "$downstream" = '[]' ] || delete_branch=false
  fi
fi
if [ -n "$branch" ] && [ "$delete_branch" = true ]; then git branch -D "$branch" >/dev/null 2>&1; fi
rm -f "$ROOT/$TASK.log"
FM_ROOT="$REPO" "$REPO/bin/fm-emit.sh" --actor firstmate --task "$TASK" --type closed \
  --en "worktree for $TASK removed" --tw "已移除 $TASK 的 worktree" >/dev/null 2>&1 </dev/null || true
echo "fm-cleanup: removed $tgt_real"
exit 0
