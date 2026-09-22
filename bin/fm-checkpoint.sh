#!/usr/bin/env bash
# Mid-run save for a live worker worktree: commit then push the feature branch.
# Workers call this after each logical unit so the PR is never a black box.
# Does not open/merge PRs, touch main/master, or run gh beyond optional emit.
#
#   fm-checkpoint.sh --task T-035 --message "SIGHUP ignore in transport" [--repo .]
set -euo pipefail
exec < /dev/null
_fm_lib="$(dirname "${BASH_SOURCE[0]}")/fm-config.sh"
[ -f "$_fm_lib" ] || { echo "${0##*/}: missing $_fm_lib" >&2; exit 70; }
# shellcheck source=bin/fm-config.sh
. "$_fm_lib"

REPO="${FM_ROOT:-$(pwd)}"; TASK=''; MSG=''
while [ $# -gt 0 ]; do
  case "$1" in
    --task) fm_need "fm-checkpoint" "$@"; TASK="${2-}"; shift 2 ;;
    --repo) fm_need "fm-checkpoint" "$@"; REPO="${2-}"; shift 2 ;;
    --message|--msg) fm_need "fm-checkpoint" "$@"; MSG="${2-}"; shift 2 ;;
    *) echo "fm-checkpoint: unknown argument $1" >&2; exit 64 ;;
  esac
done
[ -n "$TASK" ] && [ -n "$MSG" ] || {
  echo "usage: fm-checkpoint.sh --task <id> --message <text> [--repo dir]" >&2
  exit 64
}
cd "$REPO" || { echo "fm-checkpoint: no repo at $REPO" >&2; exit 64; }
REPO="$(pwd -P)"
tree="$REPO/state/worktrees/$TASK"
[ -d "$tree" ] || { echo "fm-checkpoint: no worktree at $tree" >&2; exit 70; }

branch="$(git -C "$tree" rev-parse --abbrev-ref HEAD 2>/dev/null || true)"
case "$branch" in
  ''|HEAD|main|master)
    echo "fm-checkpoint: refusing to checkpoint on '$branch'" >&2
    exit 71
    ;;
esac

dirty="$(git -C "$tree" status --porcelain -- . \
  ":(exclude).fm-prompt.md" ":(exclude).fm-say.md" || true)"
[ -n "$dirty" ] || {
  echo "fm-checkpoint: nothing to commit on $branch" >&2
  exit 0
}

git -C "$tree" add -A
git -C "$tree" -c user.name=firstmate -c user.email=firstmate@local \
  commit -q -m "$TASK: $MSG"
if [ -x "$REPO/bin/fm-emit.sh" ] || [ -x "${FM_CODE_ROOT:-}/bin/fm-emit.sh" ]; then
  EMIT="${FM_CODE_ROOT:-$REPO}/bin/fm-emit.sh"
  FM_ROOT="$REPO" "$EMIT" --actor "${FM_ACTOR:-worker}" --task "$TASK" --type commit_pushed \
    --en "checkpoint: $MSG" --tw "checkpoint：$MSG" >/dev/null 2>&1 || true
fi
git -C "$tree" push -q -u origin "$branch" || {
  echo "fm-checkpoint: push failed for $branch" >&2
  exit 71
}
echo "fm-checkpoint: pushed $(git -C "$tree" rev-parse --short HEAD) on $branch"
