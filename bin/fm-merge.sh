#!/usr/bin/env bash
# The only thing allowed to merge. The board never merges; it writes a
# decision and calls this, so there is one place that validates and one place
# that emits, whoever pressed the button.
#
#   fm-merge.sh --pr 16 [--task T-009] [--project <name>] [--repo .]
#
# --project merges on that project's own GitHub repository (`gh --repo`,
# from the registry) and writes the merged event with the project, because a
# pull request number is only a key together with its project (design
# section 15.4). Without it, it merges in the checkout's own repository and
# writes no project, exactly as before.
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

REPO="${FM_ROOT:-$(pwd)}"; PR=''; TASK=''; PROJECT=''; GH="${FM_GH:-gh}"
while [ $# -gt 0 ]; do
  case "$1" in
    --pr) fm_need "fm-merge" "$@"; PR="${2-}"; shift 2 ;;
    --task) fm_need "fm-merge" "$@"; TASK="${2-}"; shift 2 ;;
    --project) fm_need "fm-merge" "$@"; PROJECT="${2-}"; shift 2 ;;
    --repo) fm_need "fm-merge" "$@"; REPO="${2-}"; shift 2 ;;
    *) echo "fm-merge: unknown argument $1" >&2; exit 64 ;;
  esac
done
cd "$REPO" || { echo "fm-merge: no repo at $REPO" >&2; exit 64; }

# a pull request number is a number. Anything else is someone probing.
case "$PR" in
  ''|*[!0-9]*) echo "fm-merge: --pr must be a number, got '$PR'" >&2; exit 64 ;;
esac

# the project's repository, named on every gh call; none without --project
ON=()
if [ -n "$PROJECT" ]; then
  PROJECT="$(fm_project_resolve "$PROJECT" "$REPO/config.yaml")" || exit 65
  github="$(fm_project_get "$PROJECT" github "$REPO/config.yaml")" || exit 65
  ON=(--repo "$github")
fi

state="$($GH pr view "$PR" ${ON[@]+"${ON[@]}"} --json state --jq .state 2>/dev/null </dev/null || true)"

# A merged event with no task is an event the board cannot use: the reducer
# keys on the task, so the task sits in whatever lane it was in and the
# board shows finished work as work in progress. A branch is named after
# its task, the same way fm-sync-prs reads it, so ask rather than require
# the caller to remember.
if [ -z "$TASK" ]; then
  headref="$($GH pr view "$PR" ${ON[@]+"${ON[@]}"} --json headRefName --jq .headRefName 2>/dev/null </dev/null || true)"
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

$GH pr merge "$PR" ${ON[@]+"${ON[@]}"} --squash --delete-branch >/dev/null 2>&1 </dev/null || {
  echo "fm-merge: GitHub refused the merge of #$PR${PROJECT:+ in $PROJECT}" >&2; exit 1; }

FM_ROOT="$REPO" "$REPO/bin/fm-emit.sh" --actor captain --type merged --pr "$PR" \
  ${TASK:+--task "$TASK"} ${PROJECT:+--project "$PROJECT"} \
  --en "merged #$PR from the board" --tw "從看板合併 #$PR" \
  >/dev/null 2>&1 </dev/null || true
# Cleanup knows one worktree root, the engine's own (section 15.3). A task of
# another project lives under that project's root, and removing
# state/worktrees/<task> for it could remove the engine's own task of the
# same id - so another project's cleanup is left to the task that teaches
# cleanup about project roots, and said. A project is this engine when the
# registry puts its root at the engine root, however its entry spells that.
if [ -n "$PROJECT" ] && [ "$(fm_project_get "$PROJECT" root "$REPO/config.yaml" 2>/dev/null)" != "$(pwd -P)" ]; then
  [ -z "$TASK" ] || echo "fm-merge: $TASK's worktree in $PROJECT is not cleaned up here"
elif [ -n "$TASK" ] && [ -x "$REPO/bin/fm-cleanup.sh" ]; then
  FM_ROOT="$REPO" FM_GH="$GH" "$REPO/bin/fm-cleanup.sh" --task "$TASK" --repo "$REPO" \
    </dev/null 2>&1 | sed "s/^/  /"
fi
echo "fm-merge: merged #$PR${PROJECT:+ in $PROJECT}"
exit 0
