#!/usr/bin/env bash
# Mid-run save for a live worker worktree: commit then push the feature branch.
# Workers call this after each logical unit so the PR is never a black box.
# Does not open/merge PRs, touch main/master, or create pull requests.
#
#   fm-checkpoint.sh --task T-036 --message "why" [--repo ROOT]
#   fm-checkpoint.sh --dir WORKTREE --message "why"
#
# --repo is the session/repo root (owns state/worktrees/). --dir is the
# worktree itself. Pass one or the other, not both.
set -euo pipefail
exec < /dev/null
_fm_lib="$(dirname "${BASH_SOURCE[0]}")/fm-config.sh"
[ -f "$_fm_lib" ] || { echo "${0##*/}: missing $_fm_lib" >&2; exit 70; }
# shellcheck source=bin/fm-config.sh
. "$_fm_lib"

REPO="$(fm_default_repo)"; TASK=''; MSG=''; DIR=''
while [ $# -gt 0 ]; do
  case "$1" in
    --task) fm_need "fm-checkpoint" "$@"; TASK="${2-}"; shift 2 ;;
    --repo) fm_need "fm-checkpoint" "$@"; REPO="${2-}"; shift 2 ;;
    --dir)  fm_need "fm-checkpoint" "$@"; DIR="${2-}"; shift 2 ;;
    --message|--msg) fm_need "fm-checkpoint" "$@"; MSG="${2-}"; shift 2 ;;
    *) echo "fm-checkpoint: unknown argument $1" >&2; exit 64 ;;
  esac
done
[ -n "$MSG" ] || {
  echo "usage: fm-checkpoint.sh (--task <id> [--repo dir] | --dir <path>) --message <text>" >&2
  exit 64
}
if [ -n "$DIR" ] && [ -n "$TASK" ]; then
  echo "fm-checkpoint: pass --task or --dir, not both" >&2
  exit 64
fi
if [ -z "$DIR" ] && [ -z "$TASK" ]; then
  echo "usage: fm-checkpoint.sh (--task <id> [--repo dir] | --dir <path>) --message <text>" >&2
  exit 64
fi

if [ -n "$DIR" ]; then
  tree="$(cd "$DIR" && pwd -P)" || { echo "fm-checkpoint: no directory at $DIR" >&2; exit 70; }
  git -C "$tree" rev-parse --is-inside-work-tree >/dev/null 2>&1 || {
    echo "fm-checkpoint: $DIR is not a git worktree" >&2; exit 70; }
  TASK="$(basename "$tree")"
  # Session root is usually two levels up from state/worktrees/<TASK>.
  case "$tree" in
    */state/worktrees/*)
      REPO="$(cd "$tree/../.." && pwd -P)" || REPO="$tree"
      ;;
    *)
      REPO="$tree"
      ;;
  esac
else
  cd "$REPO" || { echo "fm-checkpoint: no repo at $REPO" >&2; exit 64; }
  REPO="$(pwd -P)"
  if [ -d "$REPO/state/worktrees/$TASK" ]; then
    tree="$REPO/state/worktrees/$TASK"
  elif case "$REPO" in */state/worktrees/"$TASK") true ;; *) false ;; esac; then
    tree="$REPO"
    REPO="$(cd "$tree/../.." && pwd -P)" || REPO="$tree"
  elif git -C "$REPO" rev-parse --is-inside-work-tree >/dev/null 2>&1 \
       && [ ! -d "$REPO/state/worktrees" ]; then
    # Caller passed the worktree as --repo (common when cwd is the worktree).
    tree="$REPO"
  else
    echo "fm-checkpoint: no worktree at $REPO/state/worktrees/$TASK" >&2
    exit 70
  fi
fi

branch="$(git -C "$tree" rev-parse --abbrev-ref HEAD 2>/dev/null || true)"
case "$branch" in
  ''|HEAD|main|master)
    echo "fm-checkpoint: refusing to checkpoint on '$branch'" >&2
    exit 71
    ;;
esac

# Prefer fm-guard when present (same protected-branch policy as the crew).
if [ -f "$(dirname "${BASH_SOURCE[0]}")/fm-guard.sh" ]; then
  # shellcheck source=bin/fm-guard.sh
  . "$(dirname "${BASH_SOURCE[0]}")/fm-guard.sh"
  fm_guard_branch "$tree" || exit 71
fi

# Ephemeral harness notes must never land as content. A deletion of a
# previously mistaken tip copy is the one exception that must still commit,
# otherwise a REJECT for a tracked .fm-say.md can never clear via checkpoint.
dirty="$(git -C "$tree" status --porcelain -- . \
  ":(exclude).fm-prompt.md" ":(exclude).fm-say.md" || true)"
for _ephemeral in .fm-prompt.md .fm-say.md; do
  if git -C "$tree" ls-files --error-unmatch "$_ephemeral" >/dev/null 2>&1 \
     && [ ! -e "$tree/$_ephemeral" ]; then
    dirty="${dirty}"$'\n'"D  ${_ephemeral}"
  fi
done

if [ -n "$dirty" ]; then
  # Stage everything then drop ephemeral harness *contents*. Pathspec excludes
  # on `git add -A -- .` are inconsistent across git versions in worktrees.
  git -C "$tree" add -A
  for _ephemeral in .fm-prompt.md .fm-say.md; do
    if [ -e "$tree/$_ephemeral" ] || [ -L "$tree/$_ephemeral" ]; then
      # Still on disk: never stage new or modified note contents.
      git -C "$tree" reset -q -- "$_ephemeral" 2>/dev/null || true
    fi
    # Absent from disk: keep a staged deletion so a wrongly tracked tip is purged.
  done
  if ! git -C "$tree" diff --cached --quiet 2>/dev/null; then
    case "$MSG" in
      "$TASK:"*|"$TASK "*) commit_msg="$MSG" ;;
      *) commit_msg="$TASK: $MSG" ;;
    esac
    fm_git_commit "$tree" "$commit_msg"
  fi
fi

# Always push: a clean tree may still hold unpushed commits. Exiting before
# push is the end-of-run-only black box this helper exists to end. Lifecycle
# events stay with the producer (fm-worker / fm-review); checkpoint never
# invents an actor on the board.
git -C "$tree" push -q -u origin "$branch" </dev/null || {
  echo "fm-checkpoint: push failed for $branch" >&2
  exit 71
}
echo "fm-checkpoint: pushed $(git -C "$tree" rev-parse --short HEAD) on $branch"
