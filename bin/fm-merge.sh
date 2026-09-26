#!/usr/bin/env bash
# The only thing allowed to merge. The board never merges; it writes a
# decision and calls this, so there is one place that validates and one place
# that emits, whoever pressed the button.
#
#   fm-merge.sh --pr 16 [--task T-009 | --untracked] [--project <name>] [--repo .]
#
# --project merges on that project's own GitHub repository (`gh --repo`,
# from the registry) and writes the merged event with the project, because a
# pull request number is only a key together with its project (design
# section 15.4). Without it, it merges in the checkout's own repository and
# writes no project, exactly as before.
#
# A merge card names its pull request and its task, and they must agree
# (T-119). The pull request's task is read here, at merge time, from its
# branch and else its title, by the one grammar in fm-emit.sh, because the
# branch can change between the card and the click. A --task that is not the
# pull request's task is refused and nothing is merged; with no --task, the
# pull request's own task is the one merged. A pull request that belongs to no
# task (a revert, a hotfix) merges only from an untracked card, --untracked:
# its merged event names no task, says `data.untracked: true`, and moves no
# task's card.
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
_fm_grammar="$(dirname "${BASH_SOURCE[0]}")/fm-emit.sh"
[ -f "$_fm_grammar" ] || { echo "${0##*/}: missing $_fm_grammar" >&2; exit 70; }
# shellcheck source=bin/fm-emit.sh
. "$_fm_grammar"

REPO="${FM_ROOT:-$(pwd)}"; PR=''; TASK=''; PROJECT=''; UNTRACKED=''; GH="${FM_GH:-gh}"
while [ $# -gt 0 ]; do
  case "$1" in
    --pr) fm_need "fm-merge" "$@"; PR="${2-}"; shift 2 ;;
    --task) fm_need "fm-merge" "$@"; TASK="${2-}"; shift 2 ;;
    --untracked) UNTRACKED=1; shift ;;
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
# a card is a task's or belongs to no task; never both
[ -z "$TASK" ] || [ -z "$UNTRACKED" ] || {
  echo "fm-merge: --task and --untracked are two different cards; give one" >&2; exit 64; }

# the project's repository, named on every gh call; none without --project
ON=()
if [ -n "$PROJECT" ]; then
  PROJECT="$(fm_project_resolve "$PROJECT" "$REPO/config.yaml")" || exit 65
  github="$(fm_project_get "$PROJECT" github "$REPO/config.yaml")" || exit 65
  ON=(--repo "$github")
fi

# One read: its state, and what its branch and title say it belongs to.
view="$($GH pr view "$PR" ${ON[@]+"${ON[@]}"} --json state,headRefName,title 2>/dev/null </dev/null || true)"
state="$(jq -r '.state // empty' 2>/dev/null <<<"$view" || true)"
[ -n "$state" ] || { echo "fm-merge: cannot read #$PR" >&2; exit 1; }
branch="$(jq -r '.headRefName // empty' <<<"$view")"
title="$(jq -r '.title // empty' <<<"$view")"
owner="$(fm_task_of_pr "$branch" "$title" || true)"
if fm_task_of_branch "$branch" >/dev/null; then by='its branch name'; else by='its title'; fi

# A merged event with no task is an event the board cannot use: the reducer
# keys on the task, so the task sits in whatever lane it was in and the
# board shows finished work as work in progress. So a card that names no
# task merges the pull request's own, and one that names another task's is
# refused before anything is merged - or, for one GitHub already merged,
# before "already merged" settles the wrong card.
if [ -n "$UNTRACKED" ]; then
  [ -z "$owner" ] || echo "fm-merge: #$PR names $owner by $by; merged as untracked, it moves no task"
elif [ -n "$TASK" ]; then
  if [ -z "$owner" ]; then
    echo "fm-merge: #$PR belongs to no task (branch '$branch'), not to $TASK; merge it from an untracked card" >&2
    exit 1
  fi
  [ "$owner" = "$TASK" ] || {
    echo "fm-merge: #$PR is $owner's pull request (by $by), not $TASK's; nothing merged" >&2; exit 1; }
else
  [ -n "$owner" ] || {
    echo "fm-merge: #$PR belongs to no task (branch '$branch'); merge it from an untracked card" >&2; exit 1; }
  TASK="$owner"
  echo "fm-merge: #$PR is $TASK, by $by"
fi
case "$state" in
  OPEN) ;;
  MERGED) echo "fm-merge: #$PR is already merged"; exit 0 ;;
  *) echo "fm-merge: #$PR is $state, not open" >&2; exit 1 ;;
esac

$GH pr merge "$PR" ${ON[@]+"${ON[@]}"} --squash --delete-branch >/dev/null 2>&1 </dev/null || {
  echo "fm-merge: GitHub refused the merge of #$PR${PROJECT:+ in $PROJECT}" >&2; exit 1; }

if [ -n "$UNTRACKED" ]; then
  FM_ROOT="$REPO" "$REPO/bin/fm-emit.sh" --actor captain --type merged --pr "$PR" \
    ${PROJECT:+--project "$PROJECT"} --data '{"untracked":true}' \
    --en "merged #$PR from the board, belonging to no task" --tw "從看板合併 #$PR（不屬於任何任務）" \
    >/dev/null 2>&1 </dev/null || true
else
  FM_ROOT="$REPO" "$REPO/bin/fm-emit.sh" --actor captain --type merged --pr "$PR" \
    --task "$TASK" ${PROJECT:+--project "$PROJECT"} \
    --en "merged #$PR from the board" --tw "從看板合併 #$PR" \
    >/dev/null 2>&1 </dev/null || true
fi
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
