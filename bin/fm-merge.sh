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
_fm_original_args=("$@")
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
_fm_carry_lib="$(dirname "${BASH_SOURCE[0]}")/lib/fm-carry-base.sh"
[ -f "$_fm_carry_lib" ] || { echo "fm-merge: missing $_fm_carry_lib" >&2; exit 70; }
# shellcheck source=bin/lib/fm-carry-base.sh
. "$_fm_carry_lib"
# shellcheck disable=SC2329 # Invoked by the EXIT trap.
fm_merge_exit() {
  local status=$?
  fm_carry_base_cleanup || true
  # Only this entrypoint's explicitly marked temporary snapshot is ours.
  if [ -n "${FM_MERGE_CARRY_CODE:-}" ] && [ "${FM_CODE_ROOT:-}" = "$FM_MERGE_CARRY_CODE" ] &&
     [ -f "$FM_MERGE_CARRY_CODE/.fm-merge-carry-owner" ] &&
     [ "$(cat "$FM_MERGE_CARRY_CODE/.fm-merge-carry-owner")" = "$$" ]; then
    rm -rf "$FM_MERGE_CARRY_CODE"
  fi
  return "$status"
}
trap fm_merge_exit EXIT
trap 'exit 143' TERM
trap 'exit 130' INT
trap 'exit 129' HUP
_fm_grammar="$(dirname "${BASH_SOURCE[0]}")/fm-emit.sh"
[ -f "$_fm_grammar" ] || { echo "${0##*/}: missing $_fm_grammar" >&2; exit 70; }
# shellcheck source=bin/fm-emit.sh
. "$_fm_grammar"

REPO="${FM_ROOT:-$(pwd)}"; PR=''; TASK=''; PROJECT=''; UNTRACKED=''; EXPECTED_HEAD=''; BOUND=''; BOUND_GIVEN=''; GH="${FM_GH:-gh}"
while [ $# -gt 0 ]; do
  case "$1" in
    --bound-signature) fm_need "fm-merge" "$@"; BOUND="${2-}"; BOUND_GIVEN=1; shift 2 ;;
    --expected-head) fm_need "fm-merge" "$@"; EXPECTED_HEAD="${2-}"; shift 2 ;;
    --pr) fm_need "fm-merge" "$@"; PR="${2-}"; shift 2 ;;
    --task) fm_need "fm-merge" "$@"; TASK="${2-}"; shift 2 ;;
    --untracked) UNTRACKED=1; shift ;;
    --project) fm_need "fm-merge" "$@"; PROJECT="${2-}"; shift 2 ;;
    --repo) fm_need "fm-merge" "$@"; REPO="${2-}"; shift 2 ;;
    *) echo "fm-merge: unknown argument $1" >&2; exit 64 ;;
  esac
done
[ -z "$BOUND_GIVEN" ] || [[ "$BOUND" =~ ^[0-9a-f]{64}$ ]] || {
  echo 'fm-merge: --bound-signature must be 64 lowercase hex' >&2; exit 64; }
carry_enabled=''
[ -z "$BOUND" ] || [ -z "$TASK" ] || [ -n "$UNTRACKED" ] || carry_enabled=1
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
delete_branch="$(fm_stack_policy delete_branch)" || exit 65
if [ "$delete_branch" = true ]; then merge_args+=(--delete-branch); fi
[ "$FM_EXTERNAL" != 1 ] || PROJECT="$FM_PROJECT"

# Resolve and validate the selected project before any GitHub call.
ON=()
if [ -n "$PROJECT" ]; then
  PROJECT="$(fm_project_resolve "$PROJECT" "$REPO/config.yaml")" || exit 65
  github="$(fm_project_get "$PROJECT" github "$REPO/config.yaml")" || exit 65
  ON=(--repo "$github")
elif github="$(fm_stack_repository 2>/dev/null)"; then
  ON=(--repo "$github")
fi

[[ "$EXPECTED_HEAD" =~ ^[0-9a-f]{40}$|^[0-9a-f]{64}$ ]] || {
  echo 'fm-merge: missing verified candidate SHA / 缺少已驗證的候選版本 SHA' >&2; exit 1; }

read_view() {
  view="$($GH pr view "$PR" ${ON[@]+"${ON[@]}"} --json state,headRefName,title,headRefOid,baseRefName 2>/dev/null </dev/null || true)"
  state="$(jq -r '.state // empty' 2>/dev/null <<<"$view" || true)"
  [ -n "$state" ] || { echo "fm-merge: cannot read #$PR" >&2; return 1; }
  if [ -n "$carry_enabled" ]; then
    case "$state" in
      OPEN|CLOSED|MERGED) ;;
      *) echo "fm-merge: PR state is unreadable" >&2; return 1 ;;
    esac
  fi
  actual_head="$(jq -r '.headRefOid // empty' <<<"$view")"
  base_name="$(jq -r '.baseRefName // empty' <<<"$view")"
}
check_owner() {
branch="$(jq -r '.headRefName // empty' <<<"$view")"
title="$(jq -r '.title // empty' <<<"$view")"
adopt_owner=''
owner=''
if [ "$FM_EXTERNAL" = 1 ]; then
  owner="$(python3 "${FM_CODE_ROOT:-$REPO}/bin/lib/fm_adopt.py" task-of --pr "$PR")" || exit 1
  adopt_owner="$owner"
fi
[ -n "$owner" ] || owner="$(fm_task_of_pr "$branch" "$title" || true)"
if [ -n "$adopt_owner" ]; then by='its adoption'
elif fm_task_of_branch "$branch" >/dev/null; then by='its branch name'; else by='its title'; fi

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
}
check_state() {
  case "$state" in
    OPEN) ;;
    MERGED) echo "fm-merge: #$PR is already merged"; exit 0 ;;
    *) echo "fm-merge: #$PR is $state, not open" >&2; exit 1 ;;
  esac
}
carry_base_eligible() {
  local project_base=main
  [ "$FM_EXTERNAL" != 1 ] || project_base="$FM_BASE"
  # An unreadable base is retryable, rather than a guessed stacked PR.
  [ -z "$base_name" ] || [ "$base_name" = "$project_base" ] || {
    echo "fm-merge: the captain's answer carries only for a pull request on the project base, not one stacked on ${base_name} / 船長的答案只能沿用到以專案主分支為基底的 PR，這個 PR 疊在 ${base_name} 上" >&2
    exit 1
  }
}
freeze_carry_code() {
  [ -z "${FM_MERGE_CARRY_CODE:-}" ] || return 0
  local copy
  copy="$(mktemp -d "${TMPDIR:-/tmp}/fm-merge-carry.XXXXXX")" || exit 70
  # shellcheck disable=SC2154 # Set by the sourced fm-config.sh.
  if ! cp -R "$_fm_code_dir" "$copy/bin"; then rm -rf "$copy"; exit 70; fi
  printf '%s\n' "$$" > "$copy/.fm-merge-carry-owner"
  export FM_MERGE_CARRY_CODE="$copy" FM_CODE_ROOT="$copy"
  # Storage initialization has already resolved the real checkout/project.
  export FM_ROOT="$REPO"
  exec bash "$copy/bin/fm-merge.sh" "${_fm_original_args[@]}"
  exit 70
}
carried=''; merge_head="$EXPECTED_HEAD"; candidate_ok=''
if read_view; then
  if [ "$actual_head" != "$EXPECTED_HEAD" ] && [ -z "$carry_enabled" ]; then
    echo 'fm-merge: PR head changed or is unverifiable; refresh review and gates / PR 版本已變更或無法驗證；請更新審核與關卡' >&2; exit 1
  fi
  check_owner
  if [ -n "$carry_enabled" ] && [ "$actual_head" != "$EXPECTED_HEAD" ]; then carry_base_eligible; fi
  check_state
  if [ "$actual_head" = "$EXPECTED_HEAD" ]; then
    if [ -n "$UNTRACKED" ] || fm_binding candidate --task "$TASK" --pr "$PR" --head "$EXPECTED_HEAD" >/dev/null; then
      candidate_ok=1
    fi
  fi
else
  [ -n "$carry_enabled" ] || exit 1
fi
if [ -z "$candidate_ok" ]; then
  [ -n "$carry_enabled" ] || {
    echo 'fm-merge: candidate lacks current signed readiness / 候選版本缺少有效的已簽署就緒證據' >&2; exit 1; }
  freeze_carry_code
  seconds="${FM_MERGE_CARRY_SECONDS:-3600}"; poll="${FM_MERGE_CARRY_POLL:-30}"
  [[ "$seconds" =~ ^[0-9]+$ ]] && [[ "$poll" =~ ^[1-9][0-9]*$ ]] || {
    echo 'fm-merge: invalid carry deadline or poll interval' >&2; exit 64; }
  deadline=$(( $(date +%s) + seconds )); last_reason='readiness is not yet available'
  while :; do
    status=75
    if read_view; then
      check_owner
      carry_base_eligible
      check_state
      carry_file="$FM_MERGE_CARRY_CODE/carry-result"
      fm_binding carry --pre-sync --task "$TASK" --pr "$PR" --head "$EXPECTED_HEAD" --bound-signature "$BOUND" >"$carry_file" 2>"$carry_file.err"
      status=$?
      if [ "$status" -eq 0 ]; then
        fm_carry_sync_base "$base_name" >"$carry_file" 2>"$carry_file.err"
        status=$?
        if [ "$status" -eq 0 ]; then
          fm_binding carry --task "$TASK" --pr "$PR" --head "$EXPECTED_HEAD" --bound-signature "$BOUND" >"$carry_file" 2>"$carry_file.err"
          status=$?
        fi
      fi
      if [ "$status" -eq 0 ]; then
        merge_head="$(jq -r '.head // empty' "$carry_file")"
        [[ "$merge_head" =~ ^[0-9a-f]{40}$|^[0-9a-f]{64}$ ]] || { status=1; echo 'unreadable carried head' >"$carry_file.err"; }
        if [ "$status" -eq 0 ]; then
          read_view || { status=75; echo 'cannot reread authoritative PR' >"$carry_file.err"; }
          if [ "$status" -eq 0 ]; then
            check_owner; carry_base_eligible; check_state
            if [ "$actual_head" = "$merge_head" ]; then carried=1; break; fi
            status=75; echo 'the PR head is moving' >"$carry_file.err"
          fi
        fi
      fi
      last_reason="$(tr '\r\n' '  ' <"$carry_file.err")"
      if [ "$status" -ne 75 ]; then
        echo "fm-merge: the captain's answer cannot carry to the current head: ${last_reason} / 船長的答案無法沿用到目前版本：${last_reason}" >&2
        exit 1
      fi
    else
      last_reason="cannot read #${PR}"
    fi
    now="$(date +%s)"
    if [ "$now" -ge "$deadline" ]; then
      minutes=$((seconds / 60))
      echo "fm-merge: waited ${minutes} min for readiness on the updated head: ${last_reason} / 已等待 ${minutes} 分鐘，更新後的版本仍未就緒：${last_reason}" >&2
      exit 1
    fi
    remaining=$((deadline - now)); delay="$poll"
    [ "$delay" -le "$remaining" ] || delay="$remaining"
    sleep "$delay"
  done
fi

# Deletion is separate from the merge policy: every project retains PR bases.
if [ "$delete_branch" = true ] && ! fm_stack_deletable "$branch"; then
  retained_args=()
  for arg in "${merge_args[@]}"; do
    [ "$arg" = --delete-branch ] || retained_args+=("$arg")
  done
  merge_args=("${retained_args[@]}")
fi

if ! merge_output="$($GH pr merge "$PR" ${ON[@]+"${ON[@]}"} "${merge_args[@]}" --match-head-commit "$merge_head" 2>&1 </dev/null)"; then
  merge_reason="$(printf '%s' "$merge_output" | tr '\r\n' '  ')"
  echo "fm-merge: GitHub refused the bound merge of #${PR} / GitHub 拒絕合併指定版本 #${PR}: ${merge_reason:-no response / 無回應}" >&2
  exit 1
fi

if [ -n "$UNTRACKED" ]; then
  FM_ROOT="$REPO" "${FM_CODE_ROOT:-$REPO}/bin/fm-emit.sh" --actor captain --type merged --pr "$PR" \
    ${PROJECT:+--project "$PROJECT"} --data '{"untracked":true}' \
    --en "merged #${PR} from the board, belonging to no task" --tw "從看板合併 #${PR}（不屬於任何任務）" \
    >/dev/null 2>&1 </dev/null || true
else
  event_data='{}'; summary_en="merged #${PR} from the board"; summary_tw="從看板合併 #${PR}"
  if [ -n "$carried" ]; then
    event_data="$(jq -cn --arg h0 "$EXPECTED_HEAD" --arg h1 "$merge_head" '{carried_from:$h0,head:$h1}')"
    summary_en="merged #${PR} from the board (carried from ${EXPECTED_HEAD:0:7} to ${merge_head:0:7})"
    summary_tw="從看板合併 #${PR}（答案沿用：${EXPECTED_HEAD:0:7} → ${merge_head:0:7}）"
  fi
  FM_ROOT="$REPO" "${FM_CODE_ROOT:-$REPO}/bin/fm-emit.sh" --actor captain --type merged --pr "$PR" \
    --task "$TASK" ${PROJECT:+--project "$PROJECT"} \
    --data "$event_data" --en "$summary_en" --tw "$summary_tw" \
    >/dev/null 2>&1 </dev/null || true
fi
# Cleanup resolves the project independently and validates its direct child.
if [ -n "$TASK" ] && [ -x "${FM_CODE_ROOT:-$REPO}/bin/fm-cleanup.sh" ]; then
  FM_ROOT="$REPO" FM_GH="$GH" "${FM_CODE_ROOT:-$REPO}/bin/fm-cleanup.sh" --task "$TASK" --repo "$REPO" \
    ${PROJECT:+--project "$PROJECT"} </dev/null 2>&1 | sed "s/^/  /"
fi
echo "fm-merge: merged #$PR${PROJECT:+ in $PROJECT}"
exit 0
