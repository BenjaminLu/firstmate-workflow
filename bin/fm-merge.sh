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
# task's card. --untracked on a pull request whose branch or title names a
# task is refused the same way, so a task's own merge never goes untracked.
# Summaries brace every name: bash 3.2 reads the bytes of a CJK character
# after a bare $name as part of the name (bin/fm-reconcile.sh says more).
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
# shellcheck source=bin/lib/fm-stack.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib/fm-stack.sh"
_fm_grammar="$(dirname "${BASH_SOURCE[0]}")/fm-emit.sh"
[ -f "$_fm_grammar" ] || { echo "${0##*/}: missing $_fm_grammar" >&2; exit 70; }
# shellcheck source=bin/fm-emit.sh
. "$_fm_grammar"

REPO="${FM_ROOT:-$(pwd)}"; PR=''; TASK=''; PROJECT=''; UNTRACKED=''; EXPECTED_HEAD=''; GH="${FM_GH:-gh}"
while [ $# -gt 0 ]; do
  case "$1" in
    --expected-head) fm_need "fm-merge" "$@"; EXPECTED_HEAD="${2-}"; shift 2 ;;
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

fm_storage_init "$REPO" "$PROJECT" || exit 65
merge_method="$(fm_stack_policy merge_method)" || exit 65
[ "$(fm_stack_policy land)" = card ] || {
  echo 'fm-merge: captain handoff required / 需要船長交接合併' >&2; exit 65; }
merge_args=("--$merge_method")
if [ "$(fm_stack_policy delete_branch)" = true ]; then merge_args+=(--delete-branch); fi
[ "$FM_EXTERNAL" != 1 ] || PROJECT="$FM_PROJECT"

# Name the selected repository even for the legacy unnamed self route.
github="$(fm_stack_repository)" || exit 65
[[ "$github" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || exit 65
ON=(--repo "$github")

[[ "$EXPECTED_HEAD" =~ ^[0-9a-f]{40}$|^[0-9a-f]{64}$ ]] || {
  echo 'fm-merge: missing verified candidate SHA / 缺少已驗證的候選版本 SHA' >&2; exit 1; }

# One read: its state, and what its branch and title say it belongs to.
view="$($GH pr view "$PR" ${ON[@]+"${ON[@]}"} --json state,headRefName,title,headRefOid 2>/dev/null </dev/null || true)"
state="$(jq -r '.state // empty' 2>/dev/null <<<"$view" || true)"
[ -n "$state" ] || { echo "fm-merge: cannot read #$PR" >&2; exit 1; }
actual_head="$(jq -r '.headRefOid // empty' <<<"$view")"
[ "$actual_head" = "$EXPECTED_HEAD" ] || {
  echo 'fm-merge: PR head changed or is unverifiable; refresh review and gates / PR 版本已變更或無法驗證；請更新審核與關卡' >&2; exit 1; }
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
  # the other direction: a task's own pull request merged as untracked would
  # write a merged event with no task, and the task's card would never move
  [ -z "$owner" ] || {
    echo "fm-merge: #$PR is $owner's pull request (by $by), not untracked; merge it with --task $owner; nothing merged" >&2
    exit 1; }
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

if [ -z "$UNTRACKED" ]; then
  fm_binding candidate --task "$TASK" --pr "$PR" --head "$EXPECTED_HEAD" >/dev/null || {
    echo 'fm-merge: candidate lacks current signed readiness / 候選版本缺少有效的已簽署就緒證據' >&2; exit 1; }
fi

# Deletion is separate from the merge policy: every project retains PR bases.
if ! fm_stack_deletable "$branch"; then
  retained_args=()
  for arg in "${merge_args[@]}"; do
    [ "$arg" = --delete-branch ] || retained_args+=("$arg")
  done
  merge_args=("${retained_args[@]}")
fi

if ! merge_output="$($GH pr merge "$PR" ${ON[@]+"${ON[@]}"} "${merge_args[@]}" --match-head-commit "$EXPECTED_HEAD" 2>&1 </dev/null)"; then
  merge_reason="$(printf '%s' "$merge_output" | tr '\r\n' '  ')"
  echo "fm-merge: GitHub refused the bound merge of #${PR} / GitHub 拒絕合併指定版本 #${PR}: ${merge_reason:-no response / 無回應}" >&2
  exit 1
fi

if [ -n "$UNTRACKED" ]; then
  FM_ROOT="$REPO" "$REPO/bin/fm-emit.sh" --actor captain --type merged --pr "$PR" \
    ${PROJECT:+--project "$PROJECT"} --data '{"untracked":true}' \
    --en "merged #${PR} from the board, belonging to no task" --tw "從看板合併 #${PR}（不屬於任何任務）" \
    >/dev/null 2>&1 </dev/null || true
else
  FM_ROOT="$REPO" "$REPO/bin/fm-emit.sh" --actor captain --type merged --pr "$PR" \
    --task "$TASK" ${PROJECT:+--project "$PROJECT"} \
    --en "merged #${PR} from the board" --tw "從看板合併 #${PR}" \
    >/dev/null 2>&1 </dev/null || true
fi
# Cleanup resolves the project independently and validates its direct child.
if [ -n "$TASK" ] && [ -x "$REPO/bin/fm-cleanup.sh" ]; then
  FM_ROOT="$REPO" FM_GH="$GH" "$REPO/bin/fm-cleanup.sh" --task "$TASK" --repo "$REPO" \
    ${PROJECT:+--project "$PROJECT"} </dev/null 2>&1 | sed "s/^/  /"
fi
echo "fm-merge: merged #$PR${PROJECT:+ in $PROJECT}"
exit 0
