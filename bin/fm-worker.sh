#!/usr/bin/env bash
# Runs one task. Creates the worktree, hands the prompt to an adapter, and then
# does every git and gh operation itself - the adapter is never allowed near
# them, which is what lets a CLI with no repository access still be a worker.
#
#   fm-worker.sh --task T-004 [--repo .] [--vendor claude] [--name worker-1]
#   fm-worker.sh --task T-004 --pr 27      a later round: continue the branch
#                                          and read the review already on it
set -uo pipefail
# Nothing below may read standard input. A dispatched child inherits it, and
# a child that reads it blocks the whole turn waiting for a human who is not
# there - the advance loop did exactly this once, and ci.sh has the same
# line for the same reason. One guarantee, in one place.
exec < /dev/null
_fm_lib="$(dirname "${BASH_SOURCE[0]}")/fm-config.sh"
[ -f "$_fm_lib" ] || { echo "${0##*/}: missing $_fm_lib" >&2; exit 70; }
# shellcheck source=bin/fm-config.sh
. "$_fm_lib"
# shellcheck source=bin/lib/fm-stack.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib/fm-stack.sh"
# fm_auth_filter_chain (T-121): a round never runs on a login it did not
# check. The adapters' library is loaded only where the chain is about to
# run, not here: a worker that ends before its round (a failed worktree, a
# held lock) needs no adapter, as it did not before T-121. The path is fixed
# now, before the cd into the repository.
_fm_alib="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)/adapters/_lib.sh"
fm_args=("$@")

REPO="$(fm_default_repo)"; TASK=''; VENDOR=''; NAME=''; PR=''
BASE="${FM_BASE:-main}"; GH="${FM_GH:-gh}"
while [ $# -gt 0 ]; do
  case "$1" in
    --project) fm_need "fm-worker" "$@"; export FM_PROJECT="${2-}"; shift 2 ;;
    --task) fm_need "fm-worker" "$@"; TASK="${2-}"; shift 2 ;;
    --repo) fm_need "fm-worker" "$@"; REPO="${2-}"; shift 2 ;;
    --vendor) fm_need "fm-worker" "$@"; VENDOR="${2-}"; shift 2 ;;
    --name) fm_need "fm-worker" "$@"; NAME="${2-}"; shift 2 ;;
    --pr)   fm_need "fm-worker" "$@"; PR="${2-}"; shift 2 ;;
    *) echo "fm-worker: unknown argument $1" >&2; exit 64 ;;
  esac
done
[ -n "$TASK" ] || { echo "usage: fm-worker.sh --task <id> [--repo dir]" >&2; exit 64; }
cd "$REPO" || { echo "fm-worker: no repo at $REPO" >&2; exit 64; }
REPO="$(pwd -P)"
fm_storage_init "$REPO" || exit 65
# A registered self project need not be the default project. Its review events
# must name the same project that identity allocation uses for round counting.
project_events=()
if [ -n "${FM_PROJECT:-}" ] && [ -n "$(fm_projects "$FM_CONFIG" 2>/dev/null)" ]; then
  project_events=(--project "$FM_PROJECT")
fi
fm_conventions "" >/dev/null || exit 65
fm_refuse_herdr_bypass fm-worker || exit $?
# Check the prospective pin before allocating an identity, arming the EXIT
# checkpoint, publishing liveness, or touching a task branch/worktree. Read
# an existing PR's branch directly; no worktree or local branch is needed.
preflight_ref=''
if [ "$FM_EXTERNAL" = 0 ]; then
  preflight_slug="$(printf '%s' "$TASK" | tr 'A-Z' 'a-z')"
  preflight_ref="$(git for-each-ref --format='%(refname:short)' refs/heads | grep -i "^$preflight_slug-" | head -1)"
  if [ -z "$preflight_ref" ]; then
    preflight_ref="$(git for-each-ref --format='%(refname:short)' refs/remotes/origin | grep -i "^origin/$preflight_slug-" | head -1)"
  fi
fi
if [ -n "$PR" ] && [ "$FM_EXTERNAL" = 0 ]; then
  preflight_pr_ref="$(fm_github pr view "$PR" --json headRefName --jq '.headRefName' 2>/dev/null || true)"
  case "$preflight_pr_ref" in
    ''|null|*[!A-Za-z0-9._/-]*|/*|*/) ;;
    *) preflight_ref="$preflight_pr_ref"
       if ! git rev-parse --verify "$preflight_ref^{commit}" >/dev/null 2>&1; then
         preflight_ref="origin/$preflight_ref"
       fi ;;
  esac
fi
preflight_source=()
[ -z "$preflight_ref" ] || preflight_source=(--spec-ref "$preflight_ref")
fm_pin preflight --task "$TASK" --require-preflight "$(fm_evidence_project)" \
  ${preflight_source[@]+"${preflight_source[@]}"} || exit 65

fm_freeze "$0" "$REPO" ${fm_args[@]+"${fm_args[@]}"}
fm_external_prepare || exit 65
fm_target_validate || exit 65
fm_external_base || exit 65
BASE="${FM_BASE:-$BASE}"
cd "$FM_TARGET_ROOT" || exit 65
# A worker's round is the task's, read from the log by the allocation
# (T-116); one inherited from a reviewer's shell is not this run's.
unset FM_ROUND
fm_identity worker "$TASK" "$NAME" || exit 70
EMIT="${FM_CODE_ROOT:-$REPO}/bin/fm-emit.sh"
# T-146: the vendor this round starts on and the model config.yaml names for
# that vendor are in identity.json from the start, so the board shows them
# from the round's first event (the model the vendor reports joins them
# once the round has run; a fallback vendor replaces them as it starts)
fm_record_vendor_resolution worker "$VENDOR"
head_vendor="$(fm_vendor_chain worker "$VENDOR" | head -1)"
fm_record_requested "$head_vendor" "$(fm_model_for worker "$head_vendor" "$FM_CONFIG")"
# T-116: name, role, project, task, round and attempt ride every crew
# payload as separate fields, so the board never parses them out of the actor;
# vendor and model beside them (T-127, T-146), read fresh for every payload
CREW_DATA="$(jq -cn --arg role worker --arg name "$NAME" --argjson identity "$(fm_crew_identity)" \
  --arg en 'Work description unavailable' --arg tw '尚無工作說明' \
  '{role:$role,crew_name:$name,identity:$identity,activity:{en:$en,"zh-TW":$tw}}')"
# identity.json is the one record of who this run is and what it runs on;
# every payload, crew_status included, carries it as it stands now
crew_refresh_identity() {
  CREW_DATA="$(jq -c --argjson identity "$(fm_crew_identity)" '.identity=$identity' <<<"$CREW_DATA")"
}
set_crew_activity() {
  local authored
  authored="$(jq -c '
    .activity
    | select(type == "object"
        and (.en | type == "string" and test("\\S"))
        and (."zh-TW" | type == "string" and test("\\S")))
    | {en:.en,"zh-TW":."zh-TW"}
  ' <<<"$1" 2>/dev/null)"
  [ -z "$authored" ] || CREW_DATA="$(jq -c --argjson activity "$authored" '.activity=$activity' <<<"$CREW_DATA")"
}
# fm-emit keeps the last --data only. Merge any call-site --data into the
# crew payload so role/recovery extras cannot wipe crew_name or activity.
emit_once() {
  crew_refresh_identity
  local data="$CREW_DATA" args=()
  while [ $# -gt 0 ]; do
    case "$1" in
      --data)
        fm_need "fm-worker" "$@"
        data="$(jq -c --argjson extra "${2-}" '. * $extra' <<<"$data")" || return 1
        shift 2
        ;;
      *) args+=("$1"); shift ;;
    esac
  done
  FM_ROOT="$REPO" "$EMIT" --data "$data" --actor "$NAME" --task "$TASK" \
    ${project_events[@]+"${project_events[@]}"} ${args[@]+"${args[@]}"} >/dev/null 2>&1 </dev/null
}
emit() { emit_once "$@" || true; }

# Phase / activity refresh without inventing percent. Optional done/total when
# a true denominator exists. Shared path for every vendor (T-036).
emit_status() {
  local en="$1" tw="$2" done_n="${3-}" total_n="${4-}" data
  if [ "${HERDR_ENV:-}" = 1 ]; then
    fm_herdr_emit_status "$REPO" "$NAME" "$TASK" "$en" "$tw" worker "$done_n" "$total_n" \
      >/dev/null 2>&1 && return 0
  fi
  # fresh before it is copied: emit_once merges this payload over its own
  crew_refresh_identity
  data="$(jq -cn --argjson base "$CREW_DATA" --arg en "$en" --arg tw "$tw" \
    --arg done_n "$done_n" --arg total_n "$total_n" '
    $base * {activity:{en:$en,"zh-TW":$tw}}
    + (if ($done_n|test("^[0-9]+$")) and ($total_n|test("^[1-9][0-9]*$"))
         and (($done_n|tonumber) <= ($total_n|tonumber))
       then {progress:{done:($done_n|tonumber),total:($total_n|tonumber)}}
       else {} end)
  ')"
  emit_once --type crew_status --data "$data" --en "$en" --tw "$tw" || true
}


# A run that ends has to say so, or "aboard" means "ever touched a task
# that is not finished yet", the board draws every actor that has ever
# run, and the ship's rate follows the history instead of what is
# happening now.
#
# One EXIT trap does the emitting; the signal traps only exit. Naming a
# signal alongside EXIT was worse than the bug it fixed: the handler ran
# and then execution CONTINUED, so a killed run announced it had
# finished and went on to commit, push and open a pull request - and
# `kill` no longer worked on it, because a trapped TERM that does not
# exit leaves only SIGKILL. The exit codes are the conventional
# 128+signal, so a caller can still tell what happened.
#
# Armed here, the first point emit() works, and the same in fm-review.
# Above it is only the argument parsing, which exits 64 before emit()
# exists. Everything else is below - the task-spec lookup (65), the
# worktree creation (70), the adapter chain - and every one of those
# exits happens after the run has said it started, so every one of them
# needs the ending.
#
# The ordinary emit is best-effort - a progress line the board misses
# costs an update - but the ending is not. `agent_finished` is what
# takes the crewman off the deck; lose it and the agent stands there
# until its task merges, which is the failure this pair exists to
# remove. So it is tried again, and if it still cannot be written the
# run says so rather than passing in silence. Both go through one
# definition of the command: two spellings of the same emit is how the
# ending and the progress lines drift apart.
# Every scratch file this script makes, removed on the way out -
# including on the paths a signal or an early exit cuts short, which
# this script has traps for. They were `mktemp`d and removed on the
# happy path only, and one of them was made on every round whether or
# not it was needed. tests/worker.test.sh walks three ways out in a
# TMPDIR it owns: 73 with say_err open, 74 with lookup_err open, and a
# TERM mid-engine, which is the case where "removed at the end" and
# "removed on the way out" differ. A signal arriving while the comment
# is being posted is the one combination no fixture holds still long
# enough to catch.
# An explicit template, for two reasons: BSD mktemp ignores $TMPDIR
# without one - so a caller that wants these somewhere it owns, which
# is how the leak is tested, cannot have them - and a file called
# tmp.XXXX says nothing about who left it if one ever does.
worker_tmp="${TMPDIR:-/tmp}"
if [ "$FM_EXTERNAL" = 1 ]; then
  worker_tmp="$FM_STATE_DIR/tmp"
  mkdir -p "$worker_tmp" || exit 70
fi
scratch_new() { mktemp "$worker_tmp/fm-worker-XXXXXX"; }
# An ARRAY. A space-delimited string is word-split and glob-expanded by
# `rm -f`, so one space in $TMPDIR and the removal silently removes
# nothing - `-f` says so by saying nothing - and every leak test still
# passes, because a test builds its own path and never puts a space in
# it.
scratch=()
scratch_add() { scratch+=("$1"); }
clean_scratch() { [ ${#scratch[@]} -eq 0 ] || rm -f "${scratch[@]}"; }

# Dirty worktrees used to vanish when the adapter/transport never returned
# to the happy-path commit (SIGHUP, kill, blocked ask-only after edits, or
# EXIT before the final git block). Publish once on the way out so a PR
# always sees a remote checkpoint when the worktree had real changes.
_fm_wip_done=0
# A launcher-only spec sync becomes publishable only after an adapter ran.
pin_synced=0; pin_counts=0; pin_start_copy=0; pin_post_adapter=0
pinned_path=''; pinned_bytes=''; pinned_version=''; pinned_ready=0
publish_wip_if_dirty() {
  local reason="${1:-exit}" dirty
  [ "${_fm_wip_done}" = 1 ] && return 0
  [ -n "${tree:-}" ] && [ -d "$tree" ] && [ -n "${branch:-}" ] && [ -n "${TASK:-}" ] || return 0
  case "$branch" in main|master|HEAD|'') return 0 ;; esac
  fm_publication_policy "$tree" "$branch" || return 1
  if [ "${pin_post_adapter:-0}" = 0 ] && [ -n "${pinned_path:-}" ] \
      && { [ "${pin_synced:-0}" = 1 ] || [ "${pin_start_copy:-0}" = 1 ]; }; then
    if git -C "$tree" cat-file -e "HEAD:${pinned_path:-}" 2>/dev/null; then
      git -C "$tree" checkout HEAD -- "${pinned_path:-}" || return 1
    else
      git -C "$tree" rm -q --cached --ignore-unmatch -- "${pinned_path:-}" || return 1
      rm -f "$tree/${pinned_path:-}" || return 1
    fi
  fi
  dirty="$(git -C "$tree" status --porcelain -- . \
    ":(exclude).fm-prompt.md" ":(exclude).fm-say.md" 2>/dev/null || true)"
  [ -n "$dirty" ] || return 0
  # An uncommitted rebuild is not a checkpoint: it sits detached on the
  # base, possibly with markers, and pushing it would replace the branch.
  # The branch ref was never moved, the next round rescues this worktree
  # to state/rescued/ and rebuilds from the branch again.
  if [ "${rebuilt:-0}" = 1 ]; then
    echo "fm-worker: the rebuild of $branch was not committed ($reason); nothing is published" >&2
    return 0
  fi
  echo "fm-worker: publishing dirty worktree ($reason)" >&2
  # Same stock helper as mid-run checkpoints: commit then push. Prefer the
  # frozen snapshot helper when present so live source edits cannot shift us.
  _ckpt="${FM_CODE_ROOT:-$REPO}/bin/fm-checkpoint.sh"
  [ -x "$_ckpt" ] || _ckpt="$REPO/bin/fm-checkpoint.sh"
  if ! "$_ckpt" --dir "$tree" \
       --message "Save unfinished work after the round stopped ($reason)" </dev/null; then
    echo "fm-worker: checkpoint push failed for $branch ($reason)" >&2
    return 1
  fi
  # Prove the save landed: still-dirty after checkpoint means the helper
  # pushed an old tip while leaving work behind.
  still="$(git -C "$tree" status --porcelain -- . \
    ":(exclude).fm-prompt.md" ":(exclude).fm-say.md" 2>/dev/null || true)"
  if [ -n "$still" ]; then
    echo "fm-worker: checkpoint left dirty paths: $still" >&2
    return 1
  fi
  local_tip="$(git -C "$tree" rev-parse HEAD 2>/dev/null || true)"
  remote_tip="$(git -C "$tree" ls-remote --heads origin "refs/heads/$branch" 2>/dev/null | awk '{print $1}')"
  if [ -z "$local_tip" ] || [ -z "$remote_tip" ] || [ "$local_tip" != "$remote_tip" ]; then
    echo "fm-worker: checkpoint remote tip mismatch for $branch ($reason) local=$local_tip remote=$remote_tip" >&2
    return 1
  fi
  _fm_wip_done=1
  emit --type commit_pushed ${PR:+--pr "$PR"} ${adopt_data_args[@]+"${adopt_data_args[@]}"} \
    --en "checkpoint on $branch ($reason)" --tw "已 checkpoint $branch ($reason)"
  return 0
}

# A rebuilt commit is pushed before the local branch moves onto it, and
# refs/fm-rebuilt/<branch> names it while that push is unconfirmed. A run
# cut short in between - a signal here, SIGKILL for the next round - lands
# on whichever head origin actually has: the rebuilt commit if the push
# reached it, the previous head (never moved) if not. Moving the local ref
# first and restoring it only on a failed return left a run killed during
# the push with a local branch origin never had, and every later round
# refused at the plain push (71) with nothing allowed to repair it.
rebuild_settle() {
  local pending ls lsrc origin_head
  [ -n "${branch:-}" ] && [ -n "${REPO:-}" ] || return 0
  pending="$(git -C "$FM_TARGET_ROOT" rev-parse -q --verify "refs/fm-rebuilt/$branch^{commit}" 2>/dev/null)" || return 0
  ls="$(git -C "$FM_TARGET_ROOT" ls-remote --exit-code --heads origin "refs/heads/$branch" 2>/dev/null)"; lsrc=$?
  if [ "$lsrc" != 0 ] && [ "$lsrc" != 2 ]; then
    echo "fm-worker: could not ask origin whether the rebuilt $branch (${pending}) reached it; the next round asks again" >&2
    return 1
  fi
  origin_head="$(printf '%s\n' "$ls" | awk 'NR == 1 { print $1 }')"
  if [ -n "$origin_head" ] && { [ "$origin_head" = "$pending" ] \
       || git -C "$FM_TARGET_ROOT" merge-base --is-ancestor "$pending" "$origin_head" 2>/dev/null; }; then
    if ! git -C "$FM_TARGET_ROOT" branch -f "$branch" "$pending" >/dev/null 2>&1; then
      echo "fm-worker: the rebuilt $branch (${pending}) is on origin, but $branch could not be moved onto it; the next round tries again" >&2
      return 1
    fi
    echo "fm-worker: the rebuilt $branch (${pending}) reached origin; $branch now points at it" >&2
  else
    echo "fm-worker: the rebuilt $branch (${pending}) never reached origin; $branch stays where it was" >&2
  fi
  git -C "$FM_TARGET_ROOT" update-ref -d "refs/fm-rebuilt/$branch" 2>/dev/null || {
    echo "fm-worker: could not clear refs/fm-rebuilt/$branch; the next round settles it again" >&2; return 1; }
}

finished() {
  local rc=$?
  # The mirror watcher (T-128), if this round ever started one - stopped
  # before anything below reads $tree, and safe on every exit path,
  # including one so early the function that starts it was never defined.
  if declare -f mirror_watch_stop >/dev/null 2>&1; then mirror_watch_stop || true; fi
  # Before retiring the actor: save any unpushed worktree edits. SIGTERM/INT
  # reach here via `exit`; SIGKILL cannot. Mid-run saves use fm-checkpoint.sh.
  publish_wip_if_dirty "exit-$rc" || true
  rebuild_settle || true
  # the scratch worktree the rebuild check replays in, if a signal cut it short
  if [ -n "${rebuild_probe:-}" ]; then
    git -C "$FM_TARGET_ROOT" worktree remove --force "$rebuild_probe" >/dev/null 2>&1; rm -rf "$rebuild_probe"
  fi
  fm_record_end "$rc"
  if [ -f "$FM_RUN_DIR/coverage.json" ]; then
    local round_metrics
    if round_metrics="$(python3 "${FM_CODE_ROOT:-$REPO}/bin/lib/fm_round_metrics.py" "$FM_RUN_DIR")"; then
      FM_CREW_STATUS_SECS=0 emit --type crew_status --en 'Brief coverage and observed round cost retained' \
           --tw '已保留簡報涵蓋狀態與實際輪次成本' --data "$round_metrics"
    fi
  fi
  # before clean_scratch, which would remove the only copy of it
  [ -z "${held:-}" ] || [ "${held_settled:-0}" = 1 ] || lost_held "$rc"
  clean_scratch
  local try=3
  while [ "$try" -gt 0 ]; do
    try=$(( try - 1 ))
    if emit_once --type agent_finished --en "run finished" --tw "這次執行結束"; then
      wake_round_end "$rc"
      # Failed or interrupted attempts retain evidence for reconcile. Only
      # this owner can retire a successfully completed run's PID record.
      if [ "$rc" -eq 0 ] && [ "${pid_owned:-0}" = 1 ]; then
        rm -f "$pidfile" || { echo "fm-worker: cannot retire $pidfile" >&2; exit 70; }
      fi
      return 0
    fi
  done
  echo "${0##*/}: could not record the end of this run; ${NAME} stays on the deck until ${TASK} is finished" >&2
  wake_round_end "$rc"
}
# The round's end wakes firstmate (T-137), pushed by this round after its
# agent_finished, so whatever harness firstmate runs in is told by the
# writer and never by a watcher: `finished: T-134 worker-mira-t134-r1 ok #9`,
# or `failed: ... exit 1`.
wake_round_end() {
  [ -n "${NAME:-}" ] && [ -n "${TASK:-}" ] || return 0
  local line="finished: $TASK $NAME ok"
  [ "$1" -eq 0 ] || line="failed: $TASK $NAME exit $1"
  fm_wake_push "$REPO" "$NAME" round_end "$line${PR:+ #$PR}" \
    "$(jq -cn --arg task "$TASK" --arg actor "$NAME" --argjson rc "$1" '{task:$task, actor:$actor, rc:$rc}')"
}
trap finished EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
# Keep SIGHUP ignored (fm-config). Exiting on hangup orphans the managed
# transport wait and PR publish when a launching agent shell ends.
trap '' HUP


# Resolve an existing pin before any branch-owned task lookup. An absent pin
# keeps legacy unauthorised rounds readable; gate 3 will explicitly reject it.
FM_SPEC_PIN_JSON=''
FM_SPEC_PIN_JSON="$(fm_pin_existing "$TASK")"; pin_rc=$?
case "$pin_rc" in 0|3) ;; *) exit "$pin_rc" ;; esac
# Only verified self pins own a file in the target checkout.
pin_self_metadata() {
  [ "$FM_EXTERNAL" = 0 ] && [ -n "$FM_SPEC_PIN_JSON" ] || return 0
  pinned_path="$(jq -r '.snapshots.spec.path' <<<"$FM_SPEC_PIN_JSON")" || return 65
  if [ "$pinned_path" != "design/tasks/$TASK.json" ]; then
    echo "fm-worker: pinned path $pinned_path does not match design/tasks/$TASK.json" >&2
    return 65
  fi
  pinned_version="$(jq -r .version <<<"$FM_SPEC_PIN_JSON")" || return 65
}
pin_read_bytes() {
  [ "$pinned_ready" = 0 ] || return 0
  if [ -z "$pinned_bytes" ]; then
    pinned_bytes="$(scratch_new)" || return 1
    scratch_add "$pinned_bytes"
  fi
  # Keep trailing newlines, and keep this argv stable for fault injection.
  jq -j .snapshots.spec.text <<<"$FM_SPEC_PIN_JSON" > "$pinned_bytes" || return 1
  pinned_ready=1
}
pin_self_metadata || exit 65
# Only an unpinned legacy round uses the branch lookup below. It supplies
# context, never gate authority; a corrupt existing pin cannot take this path.
task_spec() {   # task_spec <task> [branch]; its own file, design/tasks/<id>.json
  local t="$1" b="${2:-}" j=''
  if [ -n "$FM_SPEC_PIN_JSON" ]; then
    jq -c '.snapshots.spec.text|fromjson' <<<"$FM_SPEC_PIN_JSON"; return
  fi
  if [ "$FM_EXTERNAL" = 1 ]; then fm_task "$t" "$FM_TASKS_DIR"; return; fi
  [ -n "$b" ] && j="$(fm_task "$t" design/tasks "$b")"
  [ -n "$j" ] || j="$(fm_task "$t")"
  printf '%s' "$j"
}
# External branch policy is captain-confirmed data; failure is never a default.
branch_prefix=''
branch_format='{"prefix":"","patterns":null,"pull_request":false}'
if [ "$FM_EXTERNAL" = 1 ]; then
  branch_format_err="$(scratch_new)" || exit 70
  scratch_add "$branch_format_err"
  if ! branch_format="$(fm_conventions branch_format 2>"$branch_format_err")"; then
    branch_error="$(cat "$branch_format_err")"
    echo "fm-worker: cannot read branch format: $branch_error" >&2
    emit --type worker_crashed --en "fm-worker: cannot read branch format: $branch_error" \
      --tw "fm-worker：無法讀取 branch 格式：${branch_error}"
    exit 65
  fi
  branch_prefix="$(jq -r .prefix <<<"$branch_format")"
fi
# the worker has no branch name yet - it is derived from the title - so
# it looks for one already carrying this task. Local first, then origin:
# a worktree can be swept between rounds and leave nothing local behind,
# and a branch only origin remembers is still a branch to continue (T-037).
slug="$(printf '%s' "$TASK" | tr 'A-Z' 'a-z')"
branch_pattern="^$slug-"
if [ -n "$branch_prefix" ]; then
  escaped_prefix="$(python3 -c 'import re,sys; print(re.escape(sys.argv[1]))' "$branch_prefix")"
  branch_pattern="^($escaped_prefix)?$slug-"
fi
branch_guess="$(git for-each-ref --format='%(refname:short)' refs/heads \
  | grep -Ei "$branch_pattern" | head -1)"
if [ -z "$branch_guess" ]; then
  remote_guess="$(git ls-remote --heads origin 2>/dev/null \
    | sed -n 's#.*[[:space:]]refs/heads/##p' \
    | grep -Ei "$branch_pattern" | head -1)"
  if [ -n "$remote_guess" ] && git fetch -q origin "$remote_guess:$remote_guess" 2>/dev/null; then
    branch_guess="$remote_guess"
  fi
fi
spec="$(task_spec "$TASK" "$branch_guess")"
[ -n "$spec" ] || { echo "fm-worker: no task $TASK: no design/tasks/$TASK.json" >&2; exit 65; }
set_crew_activity "$spec"
adopt_pr="$(jq -r '.adopt.pr // empty' <<<"$spec")"
adopt_data_args=()
adopt_refuse() {
  echo "fm-worker: $1" >&2
  emit --type worker_crashed --en "$1" --tw "接手 PR 遭拒：$1"
  exit 65
}
if [ -n "${adopt_pr:-}" ]; then
  [ "$FM_EXTERNAL" = 1 ] || adopt_refuse 'adopt is only supported for external projects'
  [ -z "$PR" ] || [ "$PR" = "${adopt_pr:-}" ] || adopt_refuse 'caller --pr differs from adopt.pr'
  PR="${adopt_pr:-}"
  adopt_data_args=(--data "$(jq -cn --argjson pr "${adopt_pr:-}" '{adopt_pr:$pr}')")
fi

# A task's title is mutable; its branch name, once created, is not re-derived
# from it (T-037). Prefer an explicit --pr headRefName when valid (T-035).
if [ -n "$PR" ]; then
  pr_branch="$(fm_github pr view "$PR" --json headRefName --jq '.headRefName' 2>/dev/null || true)"
  case "$pr_branch" in
    ''|null) ;;
    *[!A-Za-z0-9._/-]*|/*|*/) ;;
    *) branch_guess="$pr_branch" ;;
  esac
fi
if [ -n "$branch_guess" ]; then
  branch="$branch_guess"
elif [ "$FM_EXTERNAL" = 1 ]; then
  branch="$slug-work"
  if [ -n "${branch_prefix:-}" ]; then
    branch_short="$(python3 -c '
import json, re, sys
sys.path.insert(0, sys.argv[1])
from fm_public_text import validate
spec = json.load(sys.stdin)
title = spec.get("public_title")
short = ""
if not validate(title, spec.get("public_summary"), style="plain", changes=spec.get("public_changes")):
    short = re.sub("[^a-z0-9]+", "-", title.lower())[:40].strip("-")
print(short or "work")
' "$FM_CODE_ROOT/bin/lib" <<<"$spec")" || branch_short=work
    branch="$branch_prefix$slug-$branch_short"
  fi
else
  branch="$slug-$(jq -r '.title' <<<"$spec" | tr 'A-Z' 'a-z' | tr -cs 'a-z0-9' '-' | cut -c1-28 | sed 's/-*$//')"
fi
if [ -n "${adopt_pr:-}" ]; then
  adopt_branch="$(fm_github pr view "$PR" --json headRefName --jq '.headRefName' 2>/dev/null)" \
    || adopt_refuse 'cannot verify adopted PR branch'
  [ -n "$adopt_branch" ] && [ "$branch" = "$adopt_branch" ] \
    || adopt_refuse 'selected branch differs from adopted PR branch'
fi
case "$branch" in main|master|"$BASE") echo 'fm-worker: refusing protected project base' >&2; exit 65 ;; esac
# Existing and adopted heads retain their names and trigger policy.
if [ "$FM_EXTERNAL" = 1 ] && [ -z "$branch_guess" ] && [ -z "${adopt_pr:-}" ]; then
  branch_check="$(python3 - "$branch" "$branch_format" <<'PYCI'
import fnmatch, json, sys
branch, fmt = sys.argv[1], json.loads(sys.argv[2])
patterns = fmt['patterns']
if patterns is None:
    print('no CI branch patterns recorded for this project; cannot prove CI runs on ' + branch)
elif not fmt['pull_request'] and not any(fnmatch.fnmatchcase(branch, p.removeprefix('refs/heads/')) for p in patterns):
    print('branch ' + branch + ' matches no CI trigger pattern (' + ','.join(patterns) + '); set branch_prefix in the project conventions')
    sys.exit(65)
PYCI
)"; branch_check_rc=$?
  if [ -n "$branch_check" ]; then echo "fm-worker: $branch_check" >&2; fi
  if [ "$branch_check_rc" != 0 ]; then
    patterns="$(jq -r '.patterns | join(",")' <<<"$branch_format")"
    emit --type worker_crashed --en "fm-worker: $branch_check" \
      --tw "fm-worker：branch ${branch} 不符合任何 CI 觸發規則（${patterns}）；請在專案 conventions 設定 branch_prefix"
    exit 65
  fi
fi
[[ "$TASK" =~ ^[A-Za-z0-9][A-Za-z0-9_-]*$ ]] || exit 65
[ ! -L "$FM_WORKTREES/$TASK" ] || exit 65
tree="$FM_WORKTREES/$TASK"

# Ordinary dispatch and recovery share one kernel lock. Recovery passes the
# locked descriptor as fd 9 across exec; ordinary workers acquire it before
# touching the worktree. The PID is published atomically while holding it.
pidfile="$FM_WORKTREES/$TASK.pid"
mkdir -p "$FM_WORKTREES" || exit 70
dispatch_data='{"role":"worker"}'
if [ "${FM_WORKER_LOCK_PID:-}" != "$$" ]; then
  exec 9>>"$pidfile.lock" || exit 70
  perl -MFcntl=:flock -e '
    open(my $lock, "+<&=9") or die "worker lock: $!";
    flock($lock, LOCK_EX | LOCK_NB) or exit 1;
  ' || { echo "fm-worker: cannot lock $TASK; another worker may be running" >&2; exit 70; }
else
  # Reconcile execs this PID with its locked fd 9. Both producers describe
  # the same attempt: the worker must not introduce a fresh boundary after
  # the launcher's recovery event, even when neither knows the PR yet.
  dispatch_data='{"role":"worker","recovery":true}'
fi
# Consume the PID-bound handoff; a child/wrapper must not reuse it as a
# generic recovery flag. Keep fd 9 open for this worker's entire lifetime.
unset FM_WORKER_LOCK_PID
printf '%s\n' "$$" > "$pidfile.next" && mv -f "$pidfile.next" "$pidfile" || {
  echo "fm-worker: cannot publish liveness for $TASK" >&2; exit 70;
}
pid_owned=1

# The worker records that it started, not the dispatcher. A task started
# by hand was otherwise never in flight as far as the log was concerned,
# and the dispatcher would start a second one on top of it.
emit --type dispatched ${PR:+--pr "$PR"} --data "$dispatch_data" --en "picked up $TASK" --tw "接下 $TASK"
emit_status "Adapter starting on $TASK" "開始在 $TASK 上跑 adapter"

round_two=0
[ -z "$branch_guess" ] || round_two=1
# The pull request the branch already has, if the caller did not say.
# This used to be looked up two hundred lines below, AFTER the engine had
# run - so a second round dispatched without --pr was a first round
# wearing its clothes: the prompt carried no review and no failing check,
# the worker rewrote what it had already written, and the question it
# wrote into .fm-say.md was dropped because $PR was still empty when the
# time came to post it. The run then said "its question is on #", with
# nothing after the hash, which is what finding this looked like.
# Only on a later round: a branch that does not exist yet cannot have a
# pull request, and a first round that called `gh` at all would break the
# guarantee that an unavailable vendor touches nothing.
#
# The exit status is kept, and this is the whole point of the block.
# `2>/dev/null` and an empty answer make "there is no pull request" and
# "gh did not answer" the same string - and they are opposite
# instructions. Empty-and-succeeded is a real state: a previous round
# that pushed and then died at `pr create` leaves exactly that, and the
# right thing is to carry on and open one. Empty-and-failed means the
# prompt would be blind and the push would collide with a pull request
# that is already there, so the run stops before it spends an engine
# round finding that out.
if [ "$round_two" = 1 ] && [ -z "$PR" ]; then
  # no pipe: `$?` after one is the LAST element's, and `head` on empty
  # input exits 0 - so a `head -1` here would turn could-not-answer into
  # answered-none the moment pipefail was not in force, which is the one
  # thing this block exists to prevent. `--jq '.[0].number'` yields a
  # single line anyway, so the pipe bought nothing.
  # a mktemp that failed would leave this empty, `2>""` would fail the
  # redirection, gh would never run, and the round would exit 74
  # saying GitHub could not answer - when GitHub was never asked
  lookup_err="$(scratch_new)" || lookup_err=''
  [ -n "$lookup_err" ] || { echo "fm-worker: could not make a scratch file" >&2; exit 70; }
  scratch_add "$lookup_err"
  PR="$(fm_github pr list --head "$branch" --state open --json number --jq '.[0].number' \
        2>"$lookup_err" </dev/null)"; lookup_rc=$?
  # what gh actually prints for a branch with no open pull request is
  # the literal `null`, not silence - leak it through and the round
  # says `already has #null` and then posts to `gh pr comment null`
  PR="$(printf '%s' "$PR" | tr -d '[:space:]')"
  case "$PR" in null) PR='' ;; esac
  if [ "$lookup_rc" != 0 ]; then
    echo "fm-worker: could not ask which pull request $branch has" >&2
    sed 's/^/fm-worker: gh: /' "$lookup_err" >&2
    echo "fm-worker: a later round cannot run without it - the prompt would carry no review" >&2
    echo "fm-worker: and the push would collide with a pull request nobody looked for" >&2
    emit --type worker_crashed --en "could not ask which pull request $branch has" \
         --tw "問不到 ${branch} 的 PR"
    exit 74
  fi
  if [ -n "$PR" ]; then
    echo "fm-worker: $branch already has #$PR; this round answers it" >&2
  else
    # succeeded and said none: the branch was pushed by a round that did
    # not get as far as opening one, and this round opens it
    echo "fm-worker: $branch has no open pull request; this round will open one" >&2
  fi
fi

# Existing PRs own their base. New allowed stacks start at the verified parent.
stack_base=''
if [ -n "$PR" ]; then
  BASE="$(fm_binding base --task "$TASK" --pr "$PR")" || exit 65
elif [ "$(fm_stack_policy stacking)" = allowed ]; then
  stack_base="$(fm_stack select --task "$TASK")" || exit 65
  BASE="$(jq -r .name <<<"$stack_base")"
  if [ "$(jq -r '.head // empty' <<<"$stack_base")" != '' ]; then
    git fetch --no-tags origin "refs/heads/$BASE:refs/remotes/origin/$BASE" || exit 65
    parent_head="$(jq -r .head <<<"$stack_base")"
    [ "$(git rev-parse "refs/remotes/origin/$BASE")" = "$parent_head" ] || exit 65
    # Do not replace a local parent's unpublished work.
    if git show-ref --verify --quiet "refs/heads/$BASE"; then
      [ "$(git rev-parse "refs/heads/$BASE")" = "$parent_head" ] || exit 65
    else
      git update-ref "refs/heads/$BASE" "$parent_head" '' || exit 65
    fi
    refreshed_stack="$(fm_stack select --task "$TASK")" || exit 65
    [ "$refreshed_stack" = "$stack_base" ] || exit 65
  fi
fi

# --- a worktree of its own -----------------------------------------------
# Never delete work. A run that was interrupted - the machine slept, the
# session ended, someone pressed ctrl-c - leaves its files here
# uncommitted, and this used to remove them before the next round could
# see them. Tonight that nearly cost two finished tasks.
leftover_dirty=0
branch_existed=0
bound_head=''
if [ -d "$tree" ] && [ -n "$(git -C "$tree" status --porcelain 2>/dev/null \
     -- . ":(exclude).fm-prompt.md" ":(exclude).fm-say.md")" ]; then
  leftover_dirty=1
  rescue="$FM_STATE_DIR/rescued/$TASK-$(date -u +%Y%m%dT%H%M%SZ)"
  mkdir -p "$(dirname "$rescue")"
  cp -R "$tree" "$rescue"
  echo "fm-worker: $tree had uncommitted work; a copy is at $rescue" >&2
  emit --type worker_crashed --en "rescued uncommitted work to ${rescue#"$REPO"/}" \
       --tw "把未提交的工作救到 ${rescue#"$REPO"/}"
fi
# Keep an unpublished, attached dirty tree as well as its recovery copy.
# Existing PR/rebuild recovery retains its usual rescue-and-recreate path.
if [ "$leftover_dirty" = 1 ] && [ -z "$PR" ] \
   && [ "$(git -C "$tree" symbolic-ref -q --short HEAD)" = "$branch" ]; then
  round_two=1
  branch_existed=1
else
  rm -rf "$tree"; mkdir -p "$FM_WORKTREES"
  git worktree prune >/dev/null 2>&1
  rebuild_settle || true
  if git show-ref --verify --quiet "refs/heads/$branch"; then
    round_two=1
    branch_existed=1
    git fetch -q origin "refs/heads/$branch:refs/heads/$branch" >/dev/null 2>&1 || true
  elif git ls-remote --exit-code --heads origin "$branch" >/dev/null 2>&1; then
    round_two=1
    branch_existed=1
    git fetch -q origin "$branch:$branch" 2>/dev/null || {
      echo "fm-worker: could not fetch existing branch $branch" >&2; exit 70; }
  fi
  fresh_base="$BASE"
  if [ "$round_two" = 1 ] && [ -z "$PR" ] && [ "$leftover_dirty" = 0 ]; then
    # Only an ancestor can be empty. A divergent commit, even one whose
    # final diff happens to be empty, remains earlier work.
    if git fetch -q origin "refs/heads/$BASE:refs/remotes/origin/$BASE" 2>/dev/null; then
      fresh_base="refs/remotes/origin/$BASE"
    fi
    if git merge-base --is-ancestor "$branch" "$fresh_base"; then
      git branch -f "$branch" "$fresh_base" >/dev/null || {
        echo "fm-worker: could not refresh empty branch $branch from $fresh_base" >&2; exit 70; }
      round_two=0
    fi
  fi
  if git show-ref --verify --quiet "refs/heads/$branch"; then
    git worktree add -q "$tree" "$branch"
  else
    # sync fetched the confirmed project's base; the clone's checked-out
    # branch may intentionally lag and must not choose a new task's base.
    task_base="$BASE"
    [ "$FM_EXTERNAL" = 0 ] || task_base="refs/remotes/origin/$BASE"
    git worktree add -q -b "$branch" "$tree" "$task_base"
  fi || { echo "fm-worker: could not create the worktree" >&2; exit 70; }
fi
# A stale ephemeral question is not this round's answer, including when
# preserving a dirty tree in place.
if [ "$FM_EXTERNAL" = 1 ] && [ -n "$PR" ]; then
  bound_head="$(fm_binding head --task "$TASK" --pr "$PR" --branch "$branch")" || exit 65
fi
if [ -n "${adopt_pr:-}" ]; then
  adopt_check_args=()
  if python3 "${FM_CODE_ROOT:-$REPO}/bin/lib/fm_adopt.py" pushed --task "$TASK" --pr "$PR"; then
    adopt_check_args+=(--pushed)
  fi
  adopt_error="$(python3 "${FM_CODE_ROOT:-$REPO}/bin/lib/fm_adopt.py" check \
    --task "$TASK" --pr "$PR" --root "$FM_TARGET_ROOT" ${adopt_check_args[@]+"${adopt_check_args[@]}"} 2>&1)" \
    || adopt_refuse "$adopt_error"
fi
rm -f "$tree/.fm-say.md" "$tree/.fm-prompt.md"

# Firstmate may revise a new task before any implementation exists.
# Trust that copy only when every branch commit touches its own spec alone,
# and never overwrite an uncommitted file. Once implementation exists the
# branch remains authoritative in unpinned rounds. Pinned rounds sync below.
own_spec="design/tasks/$TASK.json"; spec_copied=0; spec_copy=''
refresh_spec=0
spec_only=0
# Branch existence is needed for PR lookup above, but only worker-authored
# work makes this a later implementation round. Probe existing clean branches
# only: a branch just created by this dispatch has no earlier commits.
if [ "$branch_existed" = 1 ] && [ "$leftover_dirty" = 0 ]; then
  spec_base="$(git merge-base "$BASE" "$branch")" || {
    echo "fm-worker: could not find the base of $branch for spec classification" >&2; exit 70; }
  branch_paths="$(git log --format= --name-only "$spec_base..$branch" | sed '/^$/d' | sort -u)" || {
    echo "fm-worker: could not read earlier paths on $branch" >&2; exit 70; }
  if [ "$branch_paths" = "$own_spec" ]; then
    spec_only=1
    round_two=0
  fi
fi
if [ -z "$FM_SPEC_PIN_JSON" ] && [ "$FM_EXTERNAL" = 0 ] && [ "$leftover_dirty" = 0 ] && [ -f "$own_spec" ]; then
  if { [ "$round_two" = 0 ] && [ ! -e "$tree/$own_spec" ]; } \
     || { [ "$spec_only" = 1 ] && ! git cat-file -e "$spec_base:$own_spec" 2>/dev/null; }; then
    refresh_spec=1
    spec="$(fm_task "$TASK")"
    [ -n "$spec" ] || { echo "fm-worker: could not read repository task $TASK" >&2; exit 65; }
    set_crew_activity "$spec"
  fi
fi
if [ "$refresh_spec" = 1 ] && ! cmp -s "$own_spec" "$tree/$own_spec"; then
  mkdir -p "$tree/design/tasks" && cp "$own_spec" "$tree/$own_spec" || {
    echo "fm-worker: could not copy $own_spec into $tree" >&2; exit 70; }
  spec_copied=1
  spec_copy="$(scratch_new)" || { echo "fm-worker: could not make a scratch file for $own_spec" >&2; exit 70; }
  scratch_add "$spec_copy"
  cp "$own_spec" "$spec_copy" || { echo "fm-worker: could not preserve the seeded $own_spec" >&2; exit 70; }
  echo "fm-worker: $own_spec is not on the base; copied into the worktree for this round to commit" >&2
fi

# --- the mirror: work kept where the round cannot write (T-128) -----------
# state/mirrors/<project>/<task>/N holds copies of the worktree - never
# .git, which is protected at the sandbox layer instead (gitdirs() in
# fm-sandbox.sh) and is never itself the round's work - kept outside both
# of the round's write roots (the worktree and its own temp directory), so
# no policy that ever grants those two roots can reach it. A round that
# deletes or empties its own tree, deliberately or by accident, cannot take
# the only copy of its work with it.
#
# Keyed by project name: the self project's worktrees stay at
# state/worktrees/<task> and an external project's at
# state/projects/<name>/worktrees/<task> or .../repo/state/worktrees/<task>
# (design section 15.3); either way the mirror sits beside the engine root
# that made it, under the name the tree's own path carries, or FM_PROJECT
# when nothing in the path says so.
case "$REPO" in
  */state/projects/*/*) _fm_mp="${REPO#*/state/projects/}"; MIRROR_PROJECT="${_fm_mp%%/*}" ;;
  *) MIRROR_PROJECT="${FM_PROJECT:-self}" ;;
esac
mirror_root="$FM_STATE_DIR/mirrors/$MIRROR_PROJECT/$TASK"
mirror_gens=3       # generations kept, so a slow corruption can be rolled back past
mirror_loss_pct=50  # the share of files lost, with no matching commit, that counts as a wreck
mirror_restored=0
mirror_watch_pid=''; mirror_watch_stop_file=''
# the highest-numbered generation that exists, or nothing
mirror_latest() {
  local n best=''
  for n in "$mirror_root"/*/; do
    [ -d "$n" ] || continue
    n="${n%/}"; n="${n##*/}"
    case "$n" in *[!0-9]*|'') continue ;; esac
    { [ -n "$best" ] && [ "$n" -le "$best" ]; } || best="$n"
  done
  printf '%s\n' "$best"
}
# Copies the worktree into a fresh mirror generation. Never writes into
# $tree. Tries a copy-on-write clone first for the first generation -
# instant on APFS, or a reflink-capable Linux filesystem - then, for every
# later one, hard-links every file unchanged since the previous generation
# through rsync --link-dest, so a generation that changed little costs
# little; a plain rsync copy is the fallback either path lacks. Always
# excludes .git; a project's own .gitignore, when the worktree has one,
# excludes its build caches the same way git itself does.
mirror_sync() {
  local prev next dst filt=() made=0
  mkdir -p "$mirror_root" || return 1
  prev="$(mirror_latest)"
  next=$(( ${prev:-0} + 1 ))
  dst="$mirror_root/$next.tmp"
  rm -rf "$dst"
  [ ! -f "$tree/.gitignore" ] || filt=(--filter=":- .gitignore")
  if [ -z "$prev" ]; then
    if [ "$(uname -s)" = Darwin ]; then
      cp -Rc "$tree" "$dst" 2>/dev/null && made=1
    else
      cp -a --reflink=auto "$tree" "$dst" 2>/dev/null && made=1
    fi
    [ "$made" != 1 ] || rm -rf "$dst/.git"
  fi
  if [ "$made" != 1 ]; then
    rsync -a --delete ${prev:+--link-dest="$mirror_root/$prev"} --exclude='.git' \
      "${filt[@]+"${filt[@]}"}" "$tree/" "$dst/" >/dev/null 2>&1 || { rm -rf "$dst"; return 1; }
  fi
  mv "$dst" "$mirror_root/$next" || { rm -rf "$dst"; return 1; }
  local g
  for g in "$mirror_root"/*/; do
    [ -d "$g" ] || continue
    g="${g%/}"; g="${g##*/}"
    case "$g" in *[!0-9]*|'') continue ;; esac
    [ "$((next - g))" -lt "$mirror_gens" ] || rm -rf "${mirror_root:?}/$g"
  done
  # the baseline mirror_health compares against: this generation's file
  # count and total size, and the HEAD it was taken at - a drop explained
  # by a real commit is not a wreck. Size as well as count: a round that
  # empties files in place (truncates them to nothing) rather than
  # deleting them changes no count at all.
  find "$tree" -type f ! -path "$tree/.git" ! -path "$tree/.git/*" 2>/dev/null \
    | wc -l | tr -d ' ' > "$mirror_root/.count"
  find "$tree" -type f ! -path "$tree/.git" ! -path "$tree/.git/*" -exec wc -c {} + 2>/dev/null \
    | awk '{sum+=$1} END{print sum+0}' > "$mirror_root/.bytes"
  git -C "$tree" rev-parse -q --verify HEAD 2>/dev/null > "$mirror_root/.head" || : > "$mirror_root/.head"
  printf '%s\n' "$next"
}
# tree_git_ok: whether git itself still recognises $tree as a repository -
# what git says, not a guess from a path or a file type (T-128 round 5
# review): a worktree's .git is a file, a clone's is a directory, and a test
# fixture's git may be a stub that never creates either, and all three must
# be judged the same way. GIT_CEILING_DIRECTORIES stops the search at
# $tree's own parent, so a real worktree - always nested inside its own
# repository's working copy, both for the self project and an external one
# - never has a missing .git papered over by git discovering the outer
# repository instead and answering for that one.
tree_git_ok() {
  GIT_CEILING_DIRECTORIES="$(dirname "$tree")" git -C "$tree" rev-parse -q --verify HEAD >/dev/null 2>&1
}
# 0 and silent when the tree looks as it should; 1 and a reason on stdout
# when it needs restoring - gone, its .git link gone, or missing more than
# mirror_loss_pct of the files or the bytes the last mirror generation saw
# with HEAD unmoved since, so nothing here can be a real commit's doing.
mirror_health() {
  [ -d "$tree" ] || { printf 'the worktree is gone'; return 1; }
  tree_git_ok || { printf 'its .git link is gone'; return 1; }
  local baseline_n baseline_b current_n current_b
  baseline_n="$(cat "$mirror_root/.count" 2>/dev/null)"
  baseline_b="$(cat "$mirror_root/.bytes" 2>/dev/null)"
  case "$baseline_n" in ''|*[!0-9]*) return 0 ;; esac
  case "$baseline_b" in ''|*[!0-9]*) baseline_b=0 ;; esac
  [ "$baseline_n" -gt 0 ] || return 0
  current_n="$(find "$tree" -type f ! -path "$tree/.git" ! -path "$tree/.git/*" 2>/dev/null | wc -l | tr -d ' ')"
  current_b="$(find "$tree" -type f ! -path "$tree/.git" ! -path "$tree/.git/*" -exec wc -c {} + 2>/dev/null \
    | awk '{sum+=$1} END{print sum+0}')"
  { [ "$current_n" -lt $(( baseline_n * (100 - mirror_loss_pct) / 100 )) ] \
    || { [ "$baseline_b" -gt 0 ] && [ "$current_b" -lt $(( baseline_b * (100 - mirror_loss_pct) / 100 )) ]; }; } \
    || return 0
  [ "$(git -C "$tree" rev-parse -q --verify HEAD 2>/dev/null)" = "$(cat "$mirror_root/.head" 2>/dev/null)" ] || return 0
  printf 'lost more than %s%% of its files or their bytes (%s of %s files, %s of %s bytes), with no new commit' \
    "$mirror_loss_pct" "$current_n" "$baseline_n" "$current_b" "$baseline_b"
  return 1
}
# mirror_restore <why>. Keeps the wreck aside under state/rescued/, rebuilds
# $tree from the latest mirror generation, repairs .git when that is what
# went, and records worktree_restored. This is the one place a mirror sync
# ever writes into $tree, and it runs only once the round's own write
# access to it has already failed the tree.
mirror_restore() {
  local why="$1" gen wreck total
  gen="$(mirror_latest)"
  if [ -z "$gen" ]; then
    echo "fm-worker: $tree needs restoring ($why) but no mirror generation exists yet" >&2
    return 1
  fi
  wreck="$FM_STATE_DIR/rescued/$TASK-$(date -u +%Y%m%dT%H%M%SZ)-wrecked"
  mkdir -p "$(dirname "$wreck")"
  [ ! -e "$tree" ] || cp -R "$tree" "$wreck" 2>/dev/null
  total="$(find "$mirror_root/$gen" -type f 2>/dev/null | wc -l | tr -d ' ')"
  mkdir -p "$tree"
  # Never wipe $tree before restoring into it: a file the round wrote since
  # the mirror's last generation is newer than that generation's copy, and a
  # restore that deletes it first and finds nothing to put back in its place
  # is worse than no restore at all (T-128 round 5 review). -u/--update
  # skips a destination file already as new or newer than the mirror's copy
  # and only fills in what is missing or older; no --delete, so nothing this
  # round wrote is ever removed by a restore, only ever added to.
  rsync -au "$mirror_root/$gen/" "$tree/" >/dev/null 2>&1
  if ! tree_git_ok; then
    git -C "$FM_TARGET_ROOT" worktree repair "$tree" >/dev/null 2>&1 || true
  fi
  echo "fm-worker: $tree was restored from mirror generation $gen ($why); it destroyed its own tree" >&2
  # Recorded here, ASCII only, and read back by mirror_report_restores in the
  # foreground once the round is over: this runs from the background watcher
  # (mirror_watch_start) as well as the end-of-round check, and a worker_crashed
  # event carrying the zh-TW summary design 9 requires, called with emit()
  # from inside that background subshell, was observed to vanish silently -
  # the whole statement never ran, no error, nothing written - specifically
  # when the text held multi-byte characters, under bash 3.2 (macOS's stock
  # /bin/bash). The same call from the foreground does not lose anything.
  printf 'at=%s gen=%s total=%s wreck=%s why=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$gen" "$total" \
    "${wreck#"$REPO"/}" "$why" >> "$FM_WORKTREES/$TASK.restored"
  mirror_restored=1
}
# bin/fm-emit.sh's TYPES enum is out of this task's scope (design/tasks/T-128.json
# names bin/fm-emit.sh nowhere) and has no worktree_restored type, so every
# restore this round made - the marker mirror_restore left, one line each -
# rides worker_crashed, already the type for "an earlier round left something
# behind that this one found and saved", named precisely by .data.event_kind.
# Called once, from the foreground, after the round: see mirror_restore.
mirror_report_restores() {
  local marker="$FM_WORKTREES/$TASK.restored" line why gen total wreck data en tw
  [ -s "$marker" ] || return 0
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    why="${line#*why=}"
    gen="$(sed -n 's/.*gen=\([^ ]*\).*/\1/p' <<<"$line")"
    total="$(sed -n 's/.*total=\([^ ]*\).*/\1/p' <<<"$line")"
    wreck="$(sed -n 's/.*wreck=\([^ ]*\).*/\1/p' <<<"$line")"
    data="$(jq -cn --arg why "$why" --arg gen "$gen" --arg total "$total" --arg wreck "$wreck" \
      '{event_kind:"worktree_restored",mirror_restore:{why:$why,generation:($gen|tonumber? // null),files_restored:($total|tonumber? // null),wreck:$wreck}}')"
    en="the round's tree was restored ($why); it destroyed its own tree rather than changing nothing"
    # ${why}, braced: bash 3.2 (macOS's stock /bin/bash) was observed to misparse
    # an unbraced $why immediately followed by a multi-byte character (the
    # full-width paren) as part of the variable name, an unbound-variable
    # error under set -u. Braced, the name is unambiguous.
    tw="這輪的工作樹被還原（${why}）；牠摧毀了自己的工作樹，而不是什麼都沒改"
    emit --type worker_crashed --en "$en" --tw "$tw" --data "$data"
  done < "$marker"
}
# Runs mirror_sync (or mirror_restore, when the tree needs it) in the
# background, outside the sandbox like the rest of this script, so a round
# that wrecks its tree is caught while it still runs, not only at the end.
# A short poll rather than fsevents/inotify, portable to both platforms;
# the interval keeps the lag well under the ~30s bound the design allows.
mirror_watch_start() {
  mirror_watch_stop_file="$FM_RUN_DIR/mirror-stop"
  rm -f "$mirror_watch_stop_file"
  # $$ inside a `(...)` subshell is still this script's own pid, not the
  # subshell's (that is $BASHPID) - bash never re-evaluates it across a
  # fork - so the loop can check its own parent is still alive without
  # being handed the pid separately.
  (
    # A background subshell inherits every open descriptor unless it closes
    # them itself - including fd 9, the worker's own task lock. Left open
    # here, a parent killed outright (SIGKILL runs no trap) still has this
    # watcher holding that lock until its next poll tick notices and exits,
    # and a recovery launch in that window cannot acquire it and fails
    # outright (T-128 round 7: reconcile's own redispatch, timed to publish
    # a live replacement in about a second, lost the race to this). The
    # watcher never needed the lock - it only ever reads the tree and the
    # mirror - so it drops both copies immediately, the same way the
    # adapter's own subshell already does below.
    exec 9>&-
    if [[ "${FM_WORKER_TASK_LOCK_FD:-}" =~ ^[0-9]+$ ]]; then
      eval "exec ${FM_WORKER_TASK_LOCK_FD}>&-"
    fi
    parent=$$
    interval="${FM_MIRROR_INTERVAL:-10}"
    while [ ! -e "$mirror_watch_stop_file" ] && kill -0 "$parent" 2>/dev/null; do
      # Polls the stop file once a second rather than sleeping the whole
      # interval in one call: a round that ends well inside it must not
      # have mirror_watch_stop's wait held up for the rest of it (a CI
      # run with dozens of short rounds turned that into minutes of
      # nothing but this wait, T-128 round 3). The same poll also notices
      # a parent that is simply gone - SIGKILL runs no trap, so a round
      # killed outright never reaches mirror_watch_stop to write the stop
      # file - so this loop ends within the same ~1s tick instead of
      # running forever as an orphan, still writing into state/ (T-128
      # round 4).
      waited=0
      while [ "$waited" -lt "$interval" ] && [ ! -e "$mirror_watch_stop_file" ] && kill -0 "$parent" 2>/dev/null; do
        sleep 1
        waited=$((waited + 1))
      done
      [ ! -e "$mirror_watch_stop_file" ] || break
      kill -0 "$parent" 2>/dev/null || break
      if why="$(mirror_health)"; then
        mirror_sync >/dev/null 2>&1
      else
        mirror_restore "$why" >/dev/null 2>&1
      fi
    done
  ) &
  mirror_watch_pid=$!
}
mirror_watch_stop() {
  [ -n "$mirror_watch_pid" ] || return 0
  : > "$mirror_watch_stop_file" 2>/dev/null
  wait "$mirror_watch_pid" 2>/dev/null
  mirror_watch_pid=''
}

# --- a later round starts from the current base (T-067) -------------------
# Firstmate may not run git and the adapter cannot, so when the base moves
# under an open task branch and the two conflict, this is the only place
# that can bring the branch up to date. The base is FETCHED, not read from
# the local ref: nothing here updates the local main, so it is as stale as
# the last time someone pulled.
#
# A branch that still rebases onto the fetched base - gate 2's question,
# asked gate 2's way - is left exactly as it is. One that does not is
# rebuilt: the worktree is detached at the base and the branch's own change
# (merge-base..branch) is squash-merged onto it, three-way. Clean files are
# staged; conflicting files keep standard markers and are handed to the
# worker by name. The worktree stays DETACHED until the commit below, so
# the branch ref never points at a half-rebuilt tree: a run that dies here
# leaves the branch as it was, and fm-checkpoint.sh refuses a detached
# HEAD. A commit made on it anyway is refused before the round's own.
self_pr_confirmed_base=''
rebuilt=0; rebuild_clean=0; rebuild_prev=''; rebuild_lease=''; rebuild_base=''; rebuild_mark=''
rebuild_entry=''; rebuild_probe=''
rebuild_conflicts=(); rebuild_restore=()
# Conflicts git could not write markers into - a binary file, or one side
# deleted what the other changed - and what the merge left in their place:
# the blob in the worktree, or `absent`. The worker is told which side that
# is, and the round is refused while the file is still exactly that.
rebuild_bare=(); rebuild_bare_left=(); rebuild_bare_side=()
rebuild_state_of() {   # rebuild_state_of <path>; the worktree's blob, or absent
  if [ -f "$tree/$1" ] || [ -L "$tree/$1" ]; then
    git -C "$tree" hash-object --no-filters -- "$1" 2>/dev/null || echo unreadable
  else
    echo absent
  fi
}
rebuild_side_left() {   # rebuild_side_left <path>; which side the merge left, in words
  local ours='' theirs='' now sha stage
  while IFS=$' \t' read -r _ sha stage _; do
    case "$stage" in 2) ours="$sha" ;; 3) theirs="$sha" ;; esac
  done < <(git -C "$tree" ls-files -u -- "$1" 2>/dev/null)
  now="$(rebuild_state_of "$1")"
  if [ "$now" = absent ] && [ -z "$ours" ]; then echo "deleted, as $BASE has it; your task changed it"
  elif [ "$now" = absent ] && [ -z "$theirs" ]; then echo "deleted, as your task has it; $BASE changed it"
  elif [ "$now" = absent ]; then echo "deleted; neither side deleted it"
  elif [ "$now" = "$ours" ] && [ -z "$theirs" ]; then echo "$BASE's version; your task deleted it"
  elif [ "$now" = "$ours" ]; then echo "$BASE's version; your task's change is not in it"
  elif [ "$now" = "$theirs" ] && [ -z "$ours" ]; then echo "your task's version; $BASE deleted it"
  elif [ "$now" = "$theirs" ]; then echo "your task's version; $BASE's change is not in it"
  else echo "neither side exactly as it was"
  fi
}
rebuild_fingerprint() {
  # The tree the worktree holds, so a rebuilt round can tell the worker's
  # changes from the ones the rebuild itself made. Written through an index
  # of its own: the real one has unmerged entries, and `git status` says
  # `UU` for a conflicted file before and after the worker resolves it.
  # Read over the base the rebuild sits on, never HEAD: something that
  # commits on the detached HEAD mid-round must not move what it is read
  # against.
  local idx
  idx="$(scratch_new)" || return 0
  scratch_add "$idx"; rm -f "$idx"
  GIT_INDEX_FILE="$idx" git -C "$tree" read-tree "${rebuild_base:-HEAD}" 2>/dev/null \
    && GIT_INDEX_FILE="$idx" git -C "$tree" add -A 2>/dev/null \
    && GIT_INDEX_FILE="$idx" git -C "$tree" rm -q --cached --ignore-unmatch \
         -- .fm-prompt.md .fm-say.md >/dev/null 2>&1 \
    && GIT_INDEX_FILE="$idx" git -C "$tree" write-tree 2>/dev/null
  rm -f "$idx"
}
# A file the merge left unmerged.
rebuild_unmerged() { [ -n "$(git -C "$tree" ls-files -u -- "$1" 2>/dev/null)" ]; }
# The frozen task file must survive in both the worktree and the index.
rebuild_lost() {   # rebuild_lost worktree|index
  local tj own="design/tasks/$TASK.json" same=0
  if [ -n "$pinned_path" ]; then
    if [ "$pinned_ready" = 1 ]; then
      if [ "$1" = index ]; then
        tj="$(scratch_new)" || { echo "$own"; return 0; }
        if git -C "$tree" show ":$own" > "$tj" 2>/dev/null && cmp -s "$pinned_bytes" "$tj"; then same=1; fi
        rm -f "$tj"
      elif cmp -s "$pinned_bytes" "$tree/$own"; then same=1
      fi
    fi
    [ "$same" = 1 ] || echo "$own"
    return 0
  fi
  if [ "$1" = index ]; then tj="$(git -C "$tree" show ":$own" 2>/dev/null)"
  else tj="$(cat "$tree/$own" 2>/dev/null)"; fi
  [ -z "$rebuild_entry" ] || [ "$rebuild_entry" = "$(jq -cS . <<<"$tj" 2>/dev/null)" ] || echo "$own"
  return 0
}
# Main may have edited the task file, cleanly or in a conflict. Freeze it
# to the pin's exact bytes when pinned, otherwise to the previous branch.
rebuild_own_file_restore() {   # <old head>
  local own="design/tasks/$TASK.json"
  if [ -n "$pinned_path" ]; then
    pin_read_bytes || return 1
    if ! cmp -s "$pinned_bytes" "$tree/$own"; then
      mkdir -p "$tree/design/tasks" && cp "$pinned_bytes" "$tree/$own" || return 1
    fi
    git -C "$tree" add -- "$own"
    return
  fi
  [ -n "$rebuild_entry" ] || return 0
  [ "$(jq -cS . < "$tree/$own" 2>/dev/null)" != "$rebuild_entry" ] || return 0
  mkdir -p "$tree/design/tasks" || return 1
  git show "$1:$own" > "$tree/$own" || return 1
  git -C "$tree" add -- "$own"
}
# Whether the branch still rebases onto the base: gate 2's own question,
# asked the way gate 2 asks it - `git rebase`, commit by commit, in a
# scratch worktree - not a second spelling of it. A squashed patch can
# apply where the replay does not (a later commit that undid an earlier
# one main also touched), and then gate 2 stays red on a branch this
# script would leave alone forever. The replay's commits are thrown away,
# so they are made under any identity, with no hook of the repository's
# run.
rebuild_rebases() {   # rebuild_rebases <head> <base ref>; 0 clean, 1 not, 2 unknown
  local rc n e
  n="$(fm_git_name "$tree")"; e="$(fm_git_email "$tree")"
  rebuild_probe="$(mktemp -d "$worker_tmp/fm-worker-probe-XXXXXX")" || return 2
  git -c core.hooksPath=/dev/null worktree add -q --detach "$rebuild_probe" "$1" >/dev/null 2>&1 || {
    rm -rf "$rebuild_probe"; rebuild_probe=''; return 2; }
  git -C "$rebuild_probe" -c core.hooksPath=/dev/null -c rerere.enabled=false \
    -c user.name="${n:-fm-worker}" -c user.email="${e:-fm-worker@localhost}" \
    rebase "$2" >/dev/null 2>&1; rc=$?
  # A replay that stopped on a conflict leaves unmerged paths. One that
  # failed any other way - a signing key, a hook, a lock - answered nothing
  # about gate 2, and a rebuild on it would force-push a branch that may
  # well rebase.
  [ "$rc" = 0 ] || [ -n "$(git -C "$rebuild_probe" ls-files -u 2>/dev/null)" ] || rc=2
  git -C "$rebuild_probe" rebase --abort >/dev/null 2>&1
  rebuild_probe_drop
  case "$rc" in 0) return 0 ;; 2) return 2 ;; *) return 1 ;; esac
}
rebuild_probe_drop() {
  [ -n "${rebuild_probe:-}" ] || return 0
  git worktree remove --force "$rebuild_probe" >/dev/null 2>&1; rm -rf "$rebuild_probe"
  git worktree prune >/dev/null 2>&1; rebuild_probe=''
}
bring_up_to_date() {
  if [ "$FM_EXTERNAL" = 1 ]; then
    local force_policy
    if ! force_policy="$(fm_stack_policy force_with_lease)" || [ "$force_policy" != true ]; then
      echo "fm-worker: the project conventions do not allow force_with_lease; ${branch} is not rebuilt / 專案慣例不允許 force_with_lease；不重建 ${branch}" >&2
      return 0
    fi
    if [ -z "$PR" ]; then
      echo "fm-worker: no open PR; ${branch} is not rebuilt this round / 沒有開啟的 PR；本輪不重建 ${branch}" >&2
      return 0
    fi
  fi
  local base_ref="refs/remotes/origin/$BASE" head mb ls rc f side
  # The worktree was just made from the branch, so it is clean. Were it
  # not, the rebuild's own failure path (reset --hard) would destroy what
  # is in it, so a dirty tree is never rebuilt.
  if [ -n "$(git -C "$tree" status --porcelain 2>/dev/null)" ]; then
    echo "fm-worker: $tree is not clean; $branch is not rebuilt this round" >&2
    return 0
  fi
  git fetch -q origin "+refs/heads/$BASE:$base_ref" 2>/dev/null || {
    echo "fm-worker: could not fetch $BASE; $branch is not checked against it this round" >&2
    return 0; }
  if [ "$FM_EXTERNAL" = 0 ]; then
    self_pr_confirmed_base="$(git rev-parse "$base_ref")" || return 0
  fi
  head="$(git -C "$tree" rev-parse HEAD)" || return 0
  mb="$(git merge-base "$base_ref" "$head" 2>/dev/null)" || {
    echo "fm-worker: $branch shares no history with $BASE; not rebuilding it" >&2; return 0; }
  # already on the base: there is nothing to replay
  [ "$mb" != "$(git rev-parse "$base_ref")" ] || return 0
  rebuild_rebases "$head" "$base_ref"; rc=$?
  case "$rc" in
    0) [ "$FM_EXTERNAL" = 1 ] || return 0
       rebuild_clean=1 ;;
    1) ;;
    *) echo "fm-worker: could not check whether $branch rebases onto $BASE; not rebuilding it" >&2
       return 0 ;;
  esac
  # the head the push will lease against: the remote's, as it is now. A
  # remote head this branch does not contain is work the rebuild would
  # overwrite, and nothing here has seen it.
  ls="$(git ls-remote --exit-code --heads origin "refs/heads/$branch" 2>/dev/null)"; rc=$?
  case "$rc" in
    0) rebuild_lease="$(printf '%s\n' "$ls" | awk 'NR == 1 { print $1 }')" ;;
    2) rebuild_lease='' ;;
    *) echo "fm-worker: could not read origin's $branch; not rebuilding it" >&2; return 0 ;;
  esac
  if [ "$FM_EXTERNAL" = 1 ] && [ "$rebuild_lease" != "$bound_head" ]; then
    echo "fm-worker: origin's ${branch} is not the head this round was bound to; not rebuilding it / ${branch} 並非本輪綁定的版本；不重建" >&2
    return 0
  fi
  if [ -n "$rebuild_lease" ] && ! git merge-base --is-ancestor "$rebuild_lease" "$head" 2>/dev/null; then
    echo "fm-worker: origin's $branch has commits this worktree lacks; not rebuilding it" >&2
    return 0
  fi
  # Squash merge checks committer identity too, even though it creates no
  # commit. Supply resolved values, otherwise leave git's environment fallback
  # intact. The identity refusal belongs at commit-tree below.
  rb_name="$(fm_git_name "$tree")"; rb_email="$(fm_git_email "$tree")"
  rebuild_prev="$head"; rebuild_base="$(git rev-parse "$base_ref")"
  # Up before the worktree leaves the branch, not after the merge: a signal
  # in between must find it set, so the exit path publishes nothing from a
  # detached, half-merged tree.
  rebuilt=1
  git -C "$tree" checkout -q --detach "$rebuild_base" || {
    echo "fm-worker: could not detach $tree at $BASE" >&2; exit 70; }
  git -C "$tree" ${rb_name:+-c user.name="$rb_name"} ${rb_email:+-c user.email="$rb_email"} \
    -c merge.conflictStyle=merge -c rerere.enabled=false \
    merge -q --squash "$head" >/dev/null 2>&1; rc=$?
  # a merge that failed without leaving a conflict did not merge at all,
  # and the worker must not be handed the bare base as though it were
  # its branch
  if [ "$rc" != 0 ] && [ -z "$(git -C "$tree" diff --name-only -z --diff-filter=U)" ]; then
    echo "fm-worker: could not rebuild $branch on $BASE" >&2
    git -C "$tree" reset -q --hard 2>/dev/null
    git -C "$tree" checkout -q "$branch" 2>/dev/null
    exit 70
  fi
  [ "$FM_EXTERNAL" = 1 ] || rebuild_entry="$(fm_task "$TASK" design/tasks "$head" 2>/dev/null | jq -cS . 2>/dev/null)"
  # Repair is best-effort; the pre-commit check holds the round if it failed
  # or the worker subsequently changes the frozen task file.
  rebuild_own_file_restore "$head" || true
  # NUL-separated: without -z, git quotes a name outside ASCII
  # ("\346\226\207.txt"), and that string names no file in the worktree
  while IFS= read -r -d '' f; do
    [ -n "$f" ] && rebuild_conflicts+=("$f")
  done < <(git -C "$tree" diff --name-only -z --diff-filter=U)
  # A conflict with no marker in it - binary, or deleted on one side - has
  # one side sitting in the worktree looking resolved. `add -A` would
  # commit that side whole, so each is described as what it is and held
  # until the worker changes it.
  for f in ${rebuild_conflicts[@]+"${rebuild_conflicts[@]}"}; do
    [ -f "$tree/$f" ] && grep -qIE '^(<<<<<<<|>>>>>>>)( |$)' "$tree/$f" 2>/dev/null && continue
    side="$(rebuild_side_left "$f")"
    rebuild_bare+=("$f"); rebuild_bare_left+=("$(rebuild_state_of "$f")"); rebuild_bare_side+=("$side")
  done
  # a file that merged but still lost the task's entry goes to the
  # worker too, by name; a conflicted one is already on the list above
  while IFS= read -r f; do
    [ -n "$f" ] && ! rebuild_unmerged "$f" && rebuild_restore+=("$f")
  done < <(rebuild_lost worktree)
  rebuild_mark="$(rebuild_fingerprint)"
  if [ "${rebuild_clean:-0}" = 1 ]; then
    echo "fm-worker: $branch is behind $BASE and replays cleanly; rebuilt on ${rebuild_base:0:12} from ${rebuild_prev:0:12}" >&2
  else
    echo "fm-worker: $branch no longer rebases onto $BASE; rebuilt on ${rebuild_base:0:12} from ${rebuild_prev:0:12}" \
         "(${#rebuild_conflicts[@]} conflicting)" >&2
  fi
  emit_status "Rebuilt $branch on $BASE" "已把 $branch 重建在 $BASE 上"
}
if [ "$round_two" = 1 ]; then bring_up_to_date; fi

# The mirror's first generation for this round (T-128): a baseline the
# watcher can restore to even if the very first thing the adapter does is
# destroy the tree.
mirror_sync >/dev/null 2>&1 || echo "fm-worker: the first mirror of $tree did not take; the round still runs" >&2

# First pin is written by the launcher, outside the sandbox, at dispatch.
# Existing PRs use the same authority and current base, labelled as a resume.
pin_warning=''
if [ -z "$FM_SPEC_PIN_JSON" ]; then
  pin_args=()
  [ -z "$PR" ] || pin_args+=(--resume --spec-worktree "$tree")
  FM_SPEC_PIN_JSON="$(fm_pin create --task "$TASK" --require-preflight "$(fm_evidence_project)" ${pin_args[@]+"${pin_args[@]}"})"; pin_rc=$?
  case "$pin_rc" in
    0) spec="$(jq -c '.snapshots.spec.text|fromjson' <<<"$FM_SPEC_PIN_JSON")"
       set_crew_activity "$spec"
       emit --type spec_pinned --en "Approved task snapshot pinned" --tw "已固定核准的任務快照" ;;
    3) echo 'fm-worker: no pin; gate 3 (scope) will refuse this round' >&2 ;;
    66) exit 65 ;; # An exact-snapshot refusal must not fall back to other bytes.
    *) # A failed first creation is not a corrupt existing pin. Recheck in
       # case a concurrent creator published a record while we collected.
       FM_SPEC_PIN_JSON="$(fm_pin_existing "$TASK")"; pin_existing_rc=$?
       case "$pin_existing_rc" in
         0) spec="$(jq -c '.snapshots.spec.text|fromjson' <<<"$FM_SPEC_PIN_JSON")"
            set_crew_activity "$spec" ;;
         3) pin_warning='fm-worker: first pin could not be created; no pin; gate 3 (scope) will refuse this round'
            echo "$pin_warning" >&2 ;;
         *) exit "$pin_existing_rc" ;;
       esac ;;
  esac
fi

# T-259: only the trusted outer launcher seals publication prose, before any
# adapter or publication. Existing/adopted self PR metadata stays untouched.
if [ "$FM_EXTERNAL" = 0 ] && [ -z "$PR" ] && [ -z "${adopt_pr:-}" ]; then
  _fm_wip_done=1 # an authoring refusal must not publish through the EXIT checkpoint
  self_pr_binding=(--publication-mode unsealed-legacy)
  if [ -n "$FM_SPEC_PIN_JSON" ]; then
    self_pr_pin_digest="$(python3 -c 'import hashlib,json,sys; print(hashlib.sha256(json.dumps(json.load(sys.stdin),sort_keys=True,separators=(",",":"),ensure_ascii=False).encode("utf-8")).hexdigest())' \
      <<<"$FM_SPEC_PIN_JSON")" || exit 65
    self_pr_binding=(--publication-mode pin-backed --pin-sha256 "$self_pr_pin_digest")
  fi
  python3 "${FM_CODE_ROOT:-$REPO}/bin/lib/fm_self_pr.py" seal --task "$TASK" \
    --evidence-project "$(fm_evidence_project)" "${self_pr_binding[@]}" >/dev/null || exit 65
  _fm_wip_done=0
  self_pr_base="${self_pr_confirmed_base:-$rebuild_base}"
  if [ -z "$self_pr_base" ]; then
    self_pr_base="$(git -C "$tree" rev-parse "$BASE^{commit}")" || exit 65
  fi
fi

if [ -n "${adopt_pr:-}" ] && [ -n "$FM_SPEC_PIN_JSON" ]; then
  adopt_error="$(fm_pin scope --task "$TASK" --head "$branch" --base "$BASE" 2>&1)" \
    || adopt_refuse "$adopt_error"
fi

# T-207: the self branch carries the pin verbatim. Rebuilds already restored
# their frozen entry before taking the rebuild fingerprint.
pin_self_metadata || exit 65
if [ -n "$pinned_path" ] && [ "$rebuilt" = 1 ] && [ -z "$pinned_bytes" ]; then
  # A legacy resume may create its first pin only after the rebuild. That
  # pin holds the same approved branch bytes the rebuild already restored.
  pin_read_bytes || true
fi
if [ -n "$pinned_path" ] && [ "$rebuilt" = 0 ]; then
  pin_read_bytes || { echo "fm-worker: could not read pinned bytes for $pinned_path" >&2; exit 65; }
  if ! git -C "$tree" cat-file -e "HEAD:$pinned_path" 2>/dev/null; then
    # Preserve T-147's no-work behavior. Its existing copy is not a new sync.
    if ! cmp -s "$pinned_bytes" "$tree/$pinned_path"; then
      pin_start_copy=1
      mkdir -p "$tree/design/tasks" && cp "$pinned_bytes" "$tree/$pinned_path" || exit 70
    fi
    spec_copied=1
    spec_copy="$pinned_bytes"
  elif ! cmp -s "$pinned_bytes" "$tree/$pinned_path"; then
    pin_synced=1
    mkdir -p "$tree/design/tasks" && cp "$pinned_bytes" "$tree/$pinned_path" || exit 70
    echo "fm-worker: $pinned_path follows pin v$pinned_version; written into the worktree for this round to commit" >&2
  fi
fi

# T-185 migration: old pins remain immutable, but every new invocation must
# have a signed preflight for the exact snapshot. No grandfathered dispatch.
preflight_args=(require --task "$TASK" --state "$FM_STATE_DIR" --project "$(fm_evidence_project)")
if [ -n "$FM_SPEC_PIN_JSON" ]; then
  python3 "${FM_CODE_ROOT:-$REPO}/bin/lib/fm_spec_preflight.py" "${preflight_args[@]}" \
    --pin-stdin <<<"$FM_SPEC_PIN_JSON" || exit 65
else
  # Legacy unpinned rounds must also be checked; this grants no gate authority.
  python3 "${FM_CODE_ROOT:-$REPO}/bin/lib/fm_spec_preflight.py" "${preflight_args[@]}" \
    --spec "$FM_TASKS_DIR/$TASK.json" || exit 65
fi

# --- the prompt: the task, the design that bears on it, and the skill ----
prompt="$tree/.fm-prompt.md"
# This is the worker's one way to speak, and it is read back with
# `[ -s ... ]`, so it has to be a signal from THIS round. What makes
# that true is above: the worktree is removed and recreated from the
# branch before the engine runs, and .fm-say.md is never committed, so
# a question left by an earlier round cannot be here. The rescue that
# runs first excludes it by name for the same reason - a leftover
# question is not uncommitted work worth saving.
say="$tree/.fm-say.md"
projection="$(fm_projection)" || exit 65
round_number="$(jq -r .round "$FM_RUN_DIR/identity.json")"
round_head="$(git -C "$tree" rev-parse HEAD)" || {
  round_head=''
  echo "fm-worker: round head unavailable; evidence coverage is unknown" >&2
}
if [ "$FM_EXTERNAL" = 1 ] && [ "$rebuilt" = 1 ]; then
  round_head="$rebuild_prev"
fi
round_context="$FM_RUN_DIR/context.md"
round_coverage="$FM_RUN_DIR/coverage.json"
printf '%s\n' "$spec" > "$FM_RUN_DIR/context-spec.json"
required_check=''
if [ -n "${FM_PROJECT:-}" ]; then
  required_check="$(fm_project_get "$FM_PROJECT" required_check 2>/dev/null)" || required_check=''
fi
# Optional diagnostic capture must not prevent a round when scratch space is unavailable.
log_err="$(scratch_new)" || log_err=''
[ -z "$log_err" ] || scratch_add "$log_err"
if [ -n "$PR" ]; then
  git fetch -q origin "+refs/heads/$BASE:refs/remotes/origin/$BASE" 2>/dev/null || true
fi
if ! python3 "${FM_CODE_ROOT:-$REPO}/bin/lib/fm_context_pack.py" \
    --state "$FM_STATE_DIR" --project "$(fm_evidence_project)" --task "$TASK" \
    --round "$round_number" --actor "$NAME" --head "$round_head" --root "$tree" \
    --spec "$FM_RUN_DIR/context-spec.json" --output "$round_context" --coverage "$round_coverage" \
    --pr "$PR" --gh "$GH" --base "$BASE" --required "$required_check" \
    --log-error-file "${log_err:-/dev/null}"; then
  printf '%s\n' 'Local context pack unavailable. Evidence coverage is unknown; ask firstmate before guessing.' > "$round_context"
  FM_CREW_STATUS_SECS=0 emit --type crew_status --data '{"evidence_event":"brief_gap"}' --en 'Local context pack unavailable; coverage unknown' \
       --tw '本機背景資料包無法取得；涵蓋狀態不明'
fi
if [ -f "$round_coverage" ]; then
  while IFS= read -r coverage_item; do
    coverage_en="$(jq -r '.summary.en' <<<"$coverage_item")"
    coverage_tw="$(jq -r '.summary["zh-TW"]' <<<"$coverage_item")"
    FM_CREW_STATUS_SECS=0 emit --type crew_status --en "$coverage_en" --tw "$coverage_tw" \
         --data "$(jq -cn --argjson coverage "$coverage_item" '{evidence_event:"brief_coverage",coverage:$coverage}')"
  done < <(jq -c '.[]' "$round_coverage")
fi

# shellcheck source=bin/lib/fm-pinned.sh
. "${FM_CODE_ROOT:-$REPO}/bin/lib/fm-pinned.sh"
fm_round_pinned worker "$spec" || exit 65

{
  cat "${FM_CODE_ROOT:-$REPO}/skills/worker/SKILL.md"
  if [ "$FM_EXTERNAL" = 1 ]; then
    fm_prompt_identity worker "$round_head" "$(git -C "$tree" merge-base "$BASE" HEAD 2>/dev/null || true)" || exit 65
  fi
  cat "$FM_RUN_DIR/pinned-prompt.md"
  printf '\n---\n\n# Your task\n\n```json\n%s\n```\n' "$spec"
  printf '\nYour worktree is the current directory. Your branch is `%s`.\n' "$branch"
  printf 'Stay inside these paths:\n'
  jq -r '.scope[]|"  - " + .' <<<"$spec"
  if [ "$spec_copied" = 1 ]; then
    printf '\nThis task'"'"'s own spec, `%s`, is not on %s yet: firstmate wrote it\n' "$own_spec" "$BASE"
    printf 'in its own working tree. fm-worker.sh has copied it into your worktree,\n'
    printf 'uncommitted, and commits it with your work when the round ends. It is\n'
    printf 'there already; do not write it again, and leave it as it is.\n'
  fi
  if [ "$pin_synced" = 1 ]; then
    printf '\nFirstmate\047s approved spec changed (pin v%s). The launcher wrote %s into\n' "$pinned_version" "$pinned_path"
    printf 'your worktree; it is committed with this round. Leave it as it is.\n'
  fi
  if [ -n "$pinned_path" ]; then
    printf '\nYour task file %s follows pin v%s. ' "$pinned_path" "$pinned_version"
    if [ "$rebuilt" = 1 ]; then
      printf 'An edit holds this rebuilt round; leave the pinned bytes as they are.\n'
    else
      printf 'If edited, it is restored to the pin before publishing.\n'
    fi
  fi
  if [ "$round_two" = 0 ] && [ -z "$PR" ]; then
    printf '\nIf this round needs firstmate before implementation, write a standalone\n'
    printf '`SCOPE-BLOCKED:%s` or `ASK-<reason>:%s` marker and the question to `.fm-say.md`.\n' "$TASK" "$TASK"
    printf 'The launcher opens a draft pull request and posts your question there, even\n'
    printf 'when you change no implementation. This replaces the premature-question rule\n'
    printf 'in the worker instructions above for these first-round requests.\n'
  fi
  printf '\n---\n\n'
  if [ "$round_two" = 1 ]; then
    printf '\n# This is not the first round\n\nYour branch already carries your earlier work. Build on it.\n'
  fi
  cat "$round_context"
  # A worker round that finds its tree restored mid-run is told so in its
  # next prompt (T-128), not only left to notice: mirror_restore() appends
  # here whenever it runs, in any earlier round, and this is read once and
  # cleared so it is said exactly once.
  if [ -s "$FM_WORKTREES/$TASK.restored" ]; then
    printf '\n---\n\n# Your tree was restored\n\n'
    printf 'A previous round on this task destroyed its own worktree - deleted it, lost\n'
    printf 'its link to git, or lost most of its files - and fm-worker.sh restored it from\n'
    printf 'its own mirror of your work, kept outside the round. Nothing was lost that had\n'
    printf 'reached the mirror; the wreck itself is kept aside under state/rescued/. This is\n'
    printf 'reported, not something to work around:\n\n'
    sed -n 's/^at=\([^ ]*\).* why=\(.*\)$/- \1: \2/p' "$FM_WORKTREES/$TASK.restored"
    rm -f "$FM_WORKTREES/$TASK.restored"
  fi
  if [ "$rebuilt" = 1 ]; then
    printf '\n---\n\n# Your branch was rebuilt on the current %s\n\n' "$BASE"
    if [ "${rebuild_clean:-0}" = 1 ]; then
      printf '%s moved under this branch; the branch replays cleanly, so fm-worker.sh rebuilt it on the current base.\n' "$BASE"
      printf 'Nothing conflicts: change nothing unless the brief asks for it.\n'
      printf 'Your change so far (previous head %s)\n' "$rebuild_prev"
    else
      printf '%s moved under this branch and the branch no longer rebased onto it,\n' "$BASE"
      printf 'so fm-worker.sh rebuilt it: your change so far (previous head %s)\n' "$rebuild_prev"
    fi
    printf 'was applied three-way onto %s at %s. It is staged, not committed;\n' "$BASE" "$rebuild_base"
    printf 'fm-worker.sh commits it with this round as one commit on %s.\n' "$BASE"
    if [ "${#rebuild_conflicts[@]}" -gt 0 ]; then
      marked_list=()
      for f in "${rebuild_conflicts[@]}"; do
        bare=0
        for g in ${rebuild_bare[@]+"${rebuild_bare[@]}"}; do [ "$g" != "$f" ] || bare=1; done
        [ "$bare" = 1 ] || marked_list+=("$f")
      done
      if [ "${#marked_list[@]}" -gt 0 ]; then
        printf '\nThese files conflict and carry standard conflict markers:\n\n'
        printf -- '- `%s`\n' "${marked_list[@]}"
      fi
      if [ "${#rebuild_bare[@]}" -gt 0 ]; then
        printf '\nThese files conflict but git could not write markers into them (a\n'
        printf 'binary file, or one side deleted what the other changed). One side\n'
        printf 'is sitting in the worktree and looks resolved; it is not:\n\n'
        for i in "${!rebuild_bare[@]}"; do
          printf -- '- `%s`: the worktree holds %s\n' "${rebuild_bare[$i]}" "${rebuild_bare_side[$i]}"
        done
        printf '\nDecide what each should be with both changes in mind. A round that\n'
        printf 'leaves one exactly as the merge left it is refused.\n'
      fi
      printf '\nResolve every one before anything else. Keep BOTH sides: %s'"'"'s change\n' "$BASE"
      printf 'and your task'"'"'s intent. Never take a whole side, and never drop %s'"'"'s change.\n' "$BASE"
      printf 'A conflict marker left in any file this commit carries refuses the commit.\n'
    else
      printf '\nEvery file applied cleanly; there is nothing to resolve.\n'
    fi
    if [ "${#rebuild_restore[@]}" -gt 0 ]; then
      printf '\nThe rebuild could not keep your task'"'"'s own entry in:\n\n'
      printf -- '- `%s`\n' "${rebuild_restore[@]}"
      if [ -n "$pinned_path" ]; then
        printf '\nPut it back exactly as pin v%s has it (the approved spec at %s/spec.json), keeping %s\047s other changes.\n' "$pinned_version" "$FM_PINNED_DIR" "$BASE"
      else
        printf '\nPut it back exactly as it is at %s, keeping %s'"'"'s other changes.\n' "$rebuild_prev" "$BASE"
      fi
    fi
    if [ "$FM_EXTERNAL" = 0 ]; then
      if [ -n "$pinned_path" ]; then
        printf '\nYour task file design/tasks/%s.json must come through exactly as pin v%s has it; a rebuilt round that changes it is refused, like one that leaves a conflict marker.\n' "$TASK" "$pinned_version"
      else
        printf '\nYour task file design/tasks/%s.json must come through exactly as it\n' "$TASK"
        printf 'is at %s; a rebuilt round that changes it is refused, like one\n' "$rebuild_prev"
        printf 'that leaves a conflict marker.\n'
      fi
    fi
    printf '\nThe worktree is detached until fm-worker.sh commits; fm-worker.sh pushes the\n'
    printf 'rebuild. Do not commit in it yourself: a round whose HEAD is no longer %s\n' "$rebuild_base"
    printf 'is refused.\n'
  fi
  if [ -n "${adopt_pr:-}" ]; then
    printf '\n# Adopted pull request\n\n'
    printf 'A person opened this pull request. The commits up to %s are theirs.\n' "$(jq -r .adopt.head <<<"$spec")"
    printf 'Build on them, do not revert their changes, and keep their conventions.\n'
  fi
  # T-117: a crew round runs inside the OS sandbox, whose write roots are
  # the worktree and the round's own temp directory. The worktree's git
  # directory lives in the repository's common .git, which is readable and
  # not writable, and GitHub is out of the round's reach. So a round can
  # neither commit nor push: saving the branch is this script's alone
  # (design 13.1, "Saving the branch").
  printf '\n---\n\n# Saving your branch in this round\n\n'
  printf 'This round runs inside the OS sandbox. It may read the worktree'"'"'s git\n'
  printf 'history but not write it, and it cannot reach GitHub, so `git commit`,\n'
  printf '`git push` and `fm-checkpoint.sh` fail here; do not run `fm-checkpoint.sh`, and do\n'
  printf 'not work around the refusal. fm-worker.sh alone saves this branch: it commits\n'
  printf 'and pushes what the worktree holds when the round ends, however it ends,\n'
  printf 'including when it is stopped. Leave your work in the worktree.\n'
  printf '\n---\n\n# The design\n\n'
  printf 'Read the complete design at %s/design.md; section anchors appear above.\n' "$FM_PINNED_DIR"
} > "$prompt"

# --- the adapter, with fallback only on a vendor being unavailable -------
# The worker's evidence: files changed in the worktree. The prompt lives
# there too, so it comes out of the count or every run looks busy.
# A rebuilt worktree is dirty before the engine starts, so there it is the
# difference from what the rebuild left that counts - or every vendor would
# look busy, and an unavailable one would be read as having done work.
worker_changed_files() {
  if [ "$rebuilt" = 1 ]; then
    [ "$(rebuild_fingerprint)" != "$rebuild_mark" ]
    return
  fi
  # the spec this script copied in (T-147) is not the round's work; a
  # change the round made to it is
  if [ "$pin_synced" = 1 ] && [ "$pin_counts" = 0 ]; then
    [ -n "$(git -C "$tree" status --porcelain -- . \
        ":(exclude).fm-prompt.md" ":(exclude).fm-say.md" ":(exclude)$pinned_path")" ] \
      || ! cmp -s "$pinned_bytes" "$tree/$pinned_path"
    return
  fi
  if [ "$spec_copied" = 1 ]; then
    [ -n "$(git -C "$tree" status --porcelain -- . \
        ":(exclude).fm-prompt.md" ":(exclude).fm-say.md" ":(exclude)$own_spec")" ] \
      || ! cmp -s "$spec_copy" "$tree/$own_spec"
    return
  fi
  [ -n "$(git -C "$tree" status --porcelain -- . \
      ":(exclude).fm-prompt.md" ":(exclude).fm-say.md")" ]
}
worker_did_work() {
  worker_changed_files || [ -s "$tree/.fm-say.md" ]
}
# A rebuild that applied - nothing unresolved handed to the worker - is
# this round's work on its own, and is published whatever the worker did
# with it: nothing, a note, or a question. Left for a later round, the
# branch stayed on its old head, DIRTY on GitHub, until the captain pushed
# it by hand (T-098). Unresolved is a conflict, and also the task's own
# entry or row the rebuild could not keep (rebuild_restore): the check
# before the commit refuses that rebuild as it stands, the way it refuses
# a marker, so it is the worker's to resolve like one.
rebuild_unresolved() {
  [ "${#rebuild_conflicts[@]}" -gt 0 ] || [ "${#rebuild_restore[@]}" -gt 0 ]
}
rebuild_publishes() {
  [ "$rebuilt" = 1 ] && ! rebuild_unresolved
}
log="$FM_RUN_DIR/worker.log"; : > "$log"
fm_log_vendor_resolution "$log"
# Close fd 9 and the launch-time task lock in a subshell so adapters cannot
# hold either. The parent keeps its copies for exclusion; if the published
# PID is SIGKILL'd, a surviving adapter must not keep the task lock or
# recovery relaunch blocks on "already has a live worker".
# Managed-session runs keep evidence under FM_RUN_DIR and resolve adapters
# through FM_CODE_ROOT when a frozen snapshot is active.
chain_result="$(scratch_new)" || exit 70
scratch_add "$chain_result"
# where a plain round starts: a mid-run fm-checkpoint.sh commits on top of
# it, and what the round adds is read against this, not the last save
round_start="$(git -C "$tree" rev-parse -q --verify HEAD 2>/dev/null)"
# The round's permission policy (T-105): config.yaml's, for a worker, with
# this project's override - never the operator's own CLI settings. Every
# adapter confines its CLI to it or refuses the round; a policy that does
# not read is a configuration error, not an unconfined round.
policy_file="$FM_RUN_DIR/policy.json"; blocked_file="$FM_RUN_DIR/blocked-hosts"
: > "$blocked_file"
fm_policy worker "" "$FM_CONFIG" > "$policy_file" || {
  echo "fm-worker: config.yaml's crew policy does not read; no round runs without one" >&2; exit 65; }
export FM_POLICY="$policy_file" FM_POLICY_BLOCKED="$blocked_file"
# config.yaml's model, applied (T-127): each vendor's own (T-146), which
# fm_run_chain resolves for whichever vendor an attempt runs - --vendor's,
# or a fallback's - and hands it as FM_MODEL; a refusal it writes is
# recorded here rather than read as the vendor being unavailable.
export FM_MODEL_ROLE=worker FM_MODEL_CONFIG="$FM_CONFIG"
model_refused_file="$FM_RUN_DIR/model-refused"; : > "$model_refused_file"
export FM_MODEL_REFUSED="$model_refused_file"
# A host the round's proxy refused is reported, not allowed: the crew
# never widens its own policy. Firstmate reads the record and raises the
# choice card that adds it to the project's registries.
report_blocked_hosts() {   # report_blocked_hosts <role> <file>
  local hosts
  hosts="$(fm_policy_report "$REPO" "$1" "$TASK" "$NAME" "$2" "$policy_file")"
  [ -n "$hosts" ] || return 0
  echo "fm-worker: the round was refused undeclared hosts: $hosts; adding one to the project's policy network is the captain's choice" >&2
  emit_status "Refused undeclared hosts: $hosts" "被拒的未宣告主機：${hosts}"
}
# The operator's escape hatch for a sandbox regression (T-117): only their
# own shell's FM_CREW_UNSANDBOXED=1, never inside a round. Loud on stderr,
# in the round's log - ahead of what the vendor says, which the verdict
# reads from its own offset - and on the board for the whole round.
if fm_crew_hatch fm-worker; then
  printf '%s\n' "fm-worker: !!! FM_CREW_UNSANDBOXED=1: this round runs WITHOUT the OS sandbox !!!" >> "$log"
  emit_status "Adapter running on $TASK WITHOUT the OS sandbox (FM_CREW_UNSANDBOXED)" \
    "adapter 正在執行 ${TASK}，未使用 OS 沙箱（FM_CREW_UNSANDBOXED）"
else
  emit_status "Adapter running on $TASK" "adapter 正在執行 $TASK"
fi
# A crew round never runs on a login it did not check (T-121): every vendor
# in the chain that this probe recognises has the login its round would get
# checked right now, before any of them sees a prompt. Anything but
# `authenticated` - unauthenticated, expired, out of quota, or a login the
# probe could not confirm (gemini, a timeout) - is refused here, with the
# probe's status and reason on the board, rather than by starting inside
# the sandbox and failing there; the chain moves on to the next vendor.
[ -r "$_fm_alib" ] || { echo "fm-worker: missing $_fm_alib" >&2; exit 70; }
# shellcheck source=bin/adapters/_lib.sh
. "$_fm_alib"
auth_notes_file="$(scratch_new)" || exit 70
scratch_add "$auth_notes_file"
worker_chain="$(fm_auth_filter_chain "${FM_CODE_ROOT:-$REPO}" "$(fm_vendor_chain worker "$VENDOR")" "$auth_notes_file")"
while IFS='|' read -r auth_v auth_status auth_en auth_tw; do
  [ -n "$auth_v" ] || continue
  echo "fm-worker: $auth_v: $auth_status: $auth_en" >&2
  emit --type vendor_unavailable --en "$auth_v: $auth_status: $auth_en" \
    --tw "${auth_v}：${auth_status}：$auth_tw" </dev/null
done < "$auth_notes_file"
# Kept outside the sandbox for as long as the adapter runs (T-128): caught
# while the round is still going, not only once it ends.
mirror_watch_start
(
  exec 9>&-
  if [[ "${FM_WORKER_TASK_LOCK_FD:-}" =~ ^[0-9]+$ ]]; then
    eval "exec ${FM_WORKER_TASK_LOCK_FD}>&-"
  fi
  fm_run_chain "${FM_CODE_ROOT:-$REPO}/bin/adapters" "$worker_chain" \
    "$prompt" "$tree" "$log" worker_did_work
  chain_rc=$?
  declare -p FM_VENDOR_USED FM_VENDOR_SKIPPED FM_VENDOR_MISREAD FM_VENDOR_UNKNOWN FM_RUN_LOG_OFF \
    FM_VENDOR_MODEL > "$chain_result"
  exit "$chain_rc"
); rc=$?
mirror_watch_stop
# A last look, now that the round is done: the watcher polls, so the very
# end of the round can land in the gap between two ticks.
if mirror_why="$(mirror_health)"; then
  mirror_sync >/dev/null 2>&1
else
  mirror_restore "$mirror_why" || true
fi
# From the foreground, now that the round is over: see mirror_report_restores.
mirror_report_restores || true
# shellcheck disable=SC1090
. "$chain_result"
[ -z "$FM_VENDOR_UNKNOWN" ] || {
  echo "fm-worker: $FM_CONFIG names a vendor with no adapter: $FM_VENDOR_UNKNOWN" >&2; exit 65; }
# A model the vendor did not recognise (T-127): refused loudly, named on the
# board in both languages, never read as the vendor being unavailable or as
# a normal failed attempt that would still reach the gates.
if [ -s "$model_refused_file" ]; then
  IFS=$'\t' read -r mr_vendor mr_model mr_msg < "$model_refused_file"
  echo "fm-worker: $mr_msg" >&2
  # bin/fm-emit.sh's TYPES is a closed list and is not in this task's scope
  # (see the note in bin/fm-diagram.sh); worker_crashed is its existing type
  # for a round that did not proceed normally, so the refusal still reaches
  # the board and the log rather than being silently refused by fm-emit.sh
  # itself. --data carries the reason as a separate field for a future
  # dedicated model_refused type to pick up without changing this shape.
  emit --type worker_crashed --en "$mr_msg" \
       --tw "${mr_vendor} 無法辨識模型「${mr_model}」；已拒絕這一輪" \
       --data "$(jq -cn --arg reason model_refused --arg vendor "$mr_vendor" --arg model "$mr_model" \
                  '{reason:$reason,vendor:$vendor,model:$model}')"
  exit 65
fi
[ "$rc" -lt 64 ] || { echo "fm-worker: adapter transport/configuration failed; artifacts at $FM_RUN_DIR" >&2; exit 70; }
[ -z "$FM_VENDOR_MISREAD" ] || {
  echo "fm-worker: $FM_VENDOR_MISREAD was read as unavailable, but it changed files - keeping them" >&2
  emit --type vendor_unavailable --en "read as unavailable but work was done; keeping it" \
       --tw "被判成不可用，但確實有改動，保留"; }
for v in $FM_VENDOR_SKIPPED; do
  emit --type vendor_unavailable --en "$v unavailable, trying the next" \
       --tw "$v 不可用，換下一家"
done
report_blocked_hosts worker "$blocked_file"
[ "$rc" = "2" ] && { echo "fm-worker: every vendor was unavailable" >&2; exit 2; }

# All early adapter exits above leave the sync unpublishable. Repair after
# mirror recovery too: its baseline predates the start-of-round sync.
if [ -n "$pinned_path" ] && [ "$rebuilt" = 0 ]; then
  if ! cmp -s "$pinned_bytes" "$tree/$pinned_path"; then
    mkdir -p "$tree/design/tasks" && cp "$pinned_bytes" "$tree/$pinned_path" || exit 70
    echo "fm-worker: $pinned_path restored to pin v$pinned_version; a task file changes only by repin" >&2
  fi
  [ "$pin_synced" = 0 ] || pin_counts=1
fi
pin_post_adapter=1

# What the round actually ran on, read from the run itself (T-127): recorded
# in identity.json beside name/role/project/task/round/attempt, and carried
# on every crew payload from here on the way those already are. The model
# requested is the one the vendor that ran was handed (T-146), and what it
# reports is read in its own transcript's shape (fm_vendor_model).
model_requested="${FM_VENDOR_MODEL:-}"
model_reported=''
[ -z "$FM_VENDOR_USED" ] || model_reported="$(fm_vendor_model "$log" "${FM_RUN_LOG_OFF:-0}" "$model_requested")"
cli_version='unknown'
[ -z "$FM_VENDOR_USED" ] || cli_version="$(fm_vendor_cli_version "$FM_VENDOR_USED")"
python3 "${FM_CODE_ROOT:-$REPO}/bin/fm-herdr.py" record-model "$FM_RUN_DIR" "$FM_VENDOR_USED" \
  "$model_requested" "$model_reported" "$cli_version" >/dev/null 2>&1 || true
crew_refresh_identity
if [ -n "$model_requested" ] && [ -n "$model_reported" ] && [ "$model_reported" != "$model_requested" ]; then
  echo "fm-worker: requested model $model_requested but $FM_VENDOR_USED ran on $model_reported" >&2
  emit --type model_mismatch --en "requested $model_requested but ran on $model_reported" \
       --tw "要求的是 ${model_requested}，實際跑在 ${model_reported}" \
       --data "$(jq -cn --arg vendor "$FM_VENDOR_USED" --arg requested "$model_requested" \
                  --arg reported "$model_reported" \
                  '{vendor:$vendor,model_requested:$requested,model:$reported}')"
  # data.identity.model_mismatch already rides every payload from here on
  # (above); this crew_status line is what refreshes the board's activity
  # line with the same news.
  emit_status "requested $model_requested but ran on $model_reported" \
              "要求的是 ${model_requested}，實際跑在 ${model_reported}"
fi

rm -f "$prompt"

# The worker's one way to speak on the pull request. It may not touch gh -
# that is the adapter contract and the reason a CLI with no repository
# access can be a worker - so it writes .fm-say.md and this script posts
# it. Without this the round-three protocol cannot happen at all:
# ASK-PASS-CRITERIA would sit in a log nobody reads while fm-protocol
# reported a violation every turn, which looks exactly like a worker that
# stopped working.
# Append after the adapter, which may replace its own report during the round.
if [ -n "$pin_warning" ]; then
  printf '\n%s\n' "$pin_warning" >> "$say"
fi
asked=0
[ -s "$say" ] && asked=1
# Retain first, even when no PR exists or optional publication later fails.
if [ "$asked" = 1 ]; then
  fm_evidence report --round "$round_number" --actor "$NAME" --head "$round_head" --file "$say" || {
    echo "fm-worker: local report retention failed; preserving the note for recovery" >&2
    mkdir -p "$FM_STATE_DIR/unsent"
    cp "$say" "$FM_STATE_DIR/unsent/${NAME}.md" || true
    FM_CREW_STATUS_SECS=0 emit --type crew_status --data '{"evidence_event":"brief_gap"}' \
      --en 'Local report retention failed; inspect unsent recovery' \
      --tw '本機報告保存失敗；請檢查未送出的復原副本'
  }
fi

spoke=0
[ "$projection" = comments ] || spoke=1  # local delivery or its warned recovery is handled
# gh's own words are kept, the way the lookup above keeps them: this is
# the one path where a person is expected to pick the failure up by
# hand, and "it was refused" without "why" sends them to the pull
# request to find out - no permission, rate limited, locked, wrong
# number. The run said where the text is and not what went wrong.
say_err=''
note_marker=''
unsent_note=''
note_settled=0
note_landed() {   # note_landed <pr> <sha256>: found=0, absent=1, lookup failed=2
  local endpoint bodies
  endpoint="repos/{owner}/{repo}/issues/$1/comments"
  [ "${FM_EXTERNAL:-0}" != 1 ] || endpoint="repos/$GH_REPO/issues/$1/comments"
  bodies="$(cd "$tree" && fm_gh_read "${GH:-${FM_GH:-gh}}" api "$endpoint" --paginate --jq '.[].body')" || return 2
  grep -Fq -- "<!-- fm-note sha256=$2 -->" <<<"$bodies"
}
plain_lint() {  # plain_lint <source> <text>: advisory plain-writing lint (T-270); never fails
  python3 "${FM_CODE_ROOT:-$REPO}/bin/lib/fm_plain.py" lint - --source "$1" \
    --log "$FM_STATE_DIR/runtime/plain-writing.jsonl" <<<"$2" >/dev/null 2>&1 || true
}
post_note() {   # post_note <file> <pr>; sets spoke=1 when it landed
  say_err="$(scratch_new)" || say_err=''
  [ -z "$say_err" ] || scratch_add "$say_err"
  if [ "$FM_EXTERNAL" = 1 ]; then
    fm_private_note worker-report "$TASK" "$1" || return 1
    if [ "$projection" != comments ]; then
      # Changed work projects only after publication, at its fixing head.
      if [ "${rebuilt:-0}" != 1 ] && ! worker_changed_files; then
        fm_external project --pr "$2" --head "$round_head" --stage worker || {
          echo 'fm-worker: optional projection failed; local report retained' >&2
          FM_CREW_STATUS_SECS=0 emit --type crew_status --data '{"evidence_event":"projection_failed"}' \
            --en 'Optional worker projection failed; local report retained' \
            --tw '選用的工作投影發布失敗；本機報告已保留'
        }
      fi
      spoke=1
      return 0
    fi
  fi
  [ "$projection" = comments ] || return 0
  local body="$1" landed=0 retries=0 lookup_rc delay marker_hex
  local retry_delays=()
  # Advisory only (T-270): plain-writing findings go to firstmate's log, and
  # the note is posted whatever they say.
  python3 "${FM_CODE_ROOT:-$REPO}/bin/lib/fm_plain.py" lint "$1" --source worker-note \
    --log "$FM_STATE_DIR/runtime/plain-writing.jsonl" >/dev/null 2>&1 </dev/null || true
  if [ "$FM_EXTERNAL" = 0 ]; then
    marker_hex="$(python3 -c 'import hashlib,sys; print(hashlib.sha256(open(sys.argv[1],"rb").read()).hexdigest())' "$1")" || return 1
    body="$(scratch_new)" || return 1
    scratch_add "$body"
    { cat "$1" && printf '\n<!-- fm-note sha256=%s -->\n' "$marker_hex"; } > "$body" || return 1
    read -r -a retry_delays <<<"${FM_NOTE_RETRY_DELAYS:-2 5}"
  fi
  while :; do
    [ "$FM_EXTERNAL" != 0 ] || note_marker="$marker_hex"
    if fm_comment_projection "$2" --body-file "$body" >/dev/null 2>"${say_err:-/dev/null}" </dev/null; then
      landed=1
      break
    fi
    [ "$FM_EXTERNAL" = 0 ] && [ "$retries" -lt 2 ] && [ "$retries" -lt "${#retry_delays[@]}" ] || break
    [ -n "$say_err" ] && grep -Eq 'GraphQL: Something went wrong while executing your query|HTTP 50[0234]' "$say_err" || break
    delay="${retry_delays[$retries]}"
    # Invalid configuration cannot turn the bound into an uncontrolled retry.
    [[ "$delay" =~ ^[0-9]+([.][0-9]+)?$ ]] || break
    sleep "$delay"
    if note_landed "$2" "$note_marker"; then
      landed=1
      break
    else
      lookup_rc=$?
    fi
    [ "$lookup_rc" = 1 ] || break
    retries=$((retries + 1))
  done
  if [ "$landed" = 1 ]; then
    spoke=1
    emit --type ask_pass_criteria --pr "$2" --en "the worker spoke on #$2" \
         --tw "工人在 #$2 上發言"
  else
    echo 'fm-worker: optional comment projection failed; local record retained' >&2
    FM_CREW_STATUS_SECS=0 emit --type crew_status --data '{"evidence_event":"projection_failed"}' --en 'Optional comment publication failed; local record retained' \
         --tw '選用的留言發布失敗；本機紀錄已保留'
    # External recovery remains the private note's responsibility.
    if [ "$FM_EXTERNAL" = 1 ]; then spoke=1; fi
  fi
}
# Retain original bytes outside the disposable worktree. Known PRs carry
# recovery metadata; a report saved before its push has no published head.
save_unsent() {   # save_unsent <file> [pr] [head]; null head means publication pending
  # Out of the worktree, which is removed and recreated on the next
  # round: keeping the file where it was written is not keeping it, and
  # the design says the text survives so a human can post it. Beside
  # state/rescued/, where an interrupted run's files go, and under a
  # name of its own because this is a message rather than work.
  #
  # No fallback to $say if the copy fails. The old one put the path
  # back inside the worktree and printed it as though it were safe,
  # which is the exact thing the sentence above says does not survive -
  # a fallback that quietly undoes the fix it is a fallback for.
  # the pid too: two failures in the same second would otherwise
  # overwrite each other, and the earlier question is the one this
  # path exists to keep
  kept="$FM_STATE_DIR/unsent/$TASK-$(date -u +%Y%m%dT%H%M%SZ)-$$.md"
  # its own stderr prefixed like everything else here: an unprefixed
  # `mkdir: File exists` lands ahead of the lines that explain what
  # happened, in a run whose whole point is reporting in its own voice
  mkdir -p "$(dirname "$kept")" 2>&1 | sed 's/^/fm-worker: /' >&2
  echo "fm-worker: the worker had something to say and there was nowhere to put it" >&2
  if cp "$1" "$kept" 2>/dev/null; then
    echo "fm-worker: it is at ${kept#"$REPO"/}" >&2
    if [ -n "${2:-}" ]; then
      if ! jq -n --arg task "$TASK" --argjson pr "$2" --argjson round "${round_number:-1}" \
          --arg actor "${NAME:-}" --arg marker "${note_marker:-}" \
          --arg saved_at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --arg head "${3:-$round_head}" \
          '{task:$task,pr:$pr,round:$round,actor:$actor,saved_at:$saved_at,
            head:(if $head=="null" then null else $head end)} +
           (if $marker=="" then {} else {marker:$marker} end)' > "$kept.json"; then
        echo "fm-worker: could not record the pull request beside $kept" >&2
      fi
    fi
  else
    echo "fm-worker: and it could not be kept either - ${kept#"$REPO"/} is not writable" >&2
    if [ "$1" = "$say" ] && [ "${3:-}" != null ]; then
      echo "fm-worker: the text is in $say until the next round recreates that worktree" >&2
    else
      # Scratch and publication-pending copies are removed, so print the
      # text rather than naming a file that will not be there to read.
      echo "fm-worker: the text was:" >&2
      sed 's/^/fm-worker: | /' "$1" >&2
    fi
    return 1
  fi
  return 0
}
keep_unsent() {   # keep_unsent <file>; reads $PR, never returns
  note_refused "$1"
  exit 73
}
note_refused() {   # note_refused <file>; keeps it and says why, and returns
  # the held note included: this is its keeping, and the EXIT trap
  # must not keep it a second time
  held_settled=1
  save_unsent "$1" "${PR:-}" || true
  # Two causes, because there are two. The middle one - "or a gh that
  # did not answer" - is gone: the lookup keeps its exit status now and
  # stops the run before this point, so an empty $PR here means the
  # question was asked and the answer was none.
  if [ -n "$PR" ]; then
    echo "fm-worker: #$PR would not take the comment" >&2
    [ -z "$say_err" ] || sed 's/^/fm-worker: gh: /' "$say_err" >&2
    emit --type worker_crashed --pr "$PR" --en "the worker's question could not be posted to #$PR" \
         --tw "工人的提問貼不上 #$PR"
  else
    echo "fm-worker: $branch has no pull request to say it on - asking is premature" >&2
    emit --type worker_crashed --en "the worker asked before there was a pull request" \
         --tw "工人在還沒有 PR 的時候提問"
  fi
}
note_unsent() {   # save now, then note_unsent_published only after a successful push
  held_settled=1
  note_settled=1
  echo "fm-worker: #$PR would not take the comment" >&2
  [ -z "$say_err" ] || sed 's/^/fm-worker: gh: /' "$say_err" >&2
  if save_unsent "$1" "$PR" null; then
    unsent_note="$kept"
  else
    refused=1
    emit --type worker_crashed --pr "$PR" \
      --en "the worker's note could not be posted to #$PR or kept" \
      --tw "工人的留言貼不上 #${PR}，也無法保存"
  fi
}
note_unsent_published() {
  [ -n "$unsent_note" ] || return 0
  local metadata
  metadata="$(scratch_new)" || metadata=''
  [ -z "$metadata" ] || scratch_add "$metadata"
  if [ -z "$metadata" ] || ! jq --arg head "$(git -C "$tree" rev-parse HEAD)" \
       '.head=$head' "$unsent_note.json" > "$metadata" || ! mv "$metadata" "$unsent_note.json"; then
    echo "fm-worker: could not record the pull request beside $unsent_note" >&2
  fi
  emit --type worker_note_unsent --pr "$PR" \
    --en "the worker's note could not be posted to #$PR; the work is published and the note is kept in state/unsent" \
    --tw "工人的留言貼不上 #${PR}；工作已發布，留言保存在 state/unsent"
  unsent_note=''
}
# A note is not only a question. An adapter that may edit but not execute
# finishes the work and says which checks it could not run, and on a
# first round that note used to be read as a question asked before there
# was a pull request: kept, exit 73, and the work in the worktree never
# reached one. A note beside real changes waits for the pull request this
# round is about to open. It is set aside OUT of the worktree first, so
# the commit below cannot take it even from a branch that tracks it.
#
# From here the scratch copy is the only one, so every way out before it
# is posted - a refused push (71), a url with no number (72), a signal -
# goes through the EXIT trap, which keeps it with lost_held. It used to
# go with the rest of the scratch files. held is set only once the copy
# is whole, so a failed cp leaves the original in the worktree instead.
question_draft=0
self_pr_question_kind=implementation
first_round_question() {
  [ "$FM_EXTERNAL" = 0 ] || return 1
  [ "$question_draft" = 1 ] && [ "$round_two" = 0 ] && ! rebuild_publishes
}
if [ "$FM_EXTERNAL" = 0 ] && [ "$projection" = comments ] && [ "$round_two" = 0 ] && ! rebuild_publishes \
   && [ "$asked" = 1 ] && [ -z "$PR" ] && ! worker_changed_files \
   && grep -Eq "^(SCOPE-BLOCKED|ASK-[A-Z-]+):$TASK([[:space:]]|$)" "$say"; then
  # Prefer the seeded spec as the draft's diff. A task already on base
  # needs a durable question file: GitHub cannot open a PR without a diff.
  # Firstmate resolves this draft's scope before it can enter the gates.
  if git -C "$tree" diff --quiet "$BASE...HEAD" \
     && [ "$spec_copied" = 0 ]; then
    question_path="design/questions/$TASK.md"
    mkdir -p "$tree/design/questions" || {
      echo "fm-worker: could not create the question directory in $tree" >&2; exit 70; }
    if [ -e "$tree/$question_path" ]; then
      { printf '\n' && cat "$say"; } >> "$tree/$question_path" || {
        echo "fm-worker: could not append the question to $question_path" >&2; exit 70; }
    else
      cp "$say" "$tree/$question_path" || {
        echo "fm-worker: could not copy the question to $question_path" >&2; exit 70; }
    fi
  fi
  if grep -Eq "^SCOPE-BLOCKED:$TASK([[:space:]]|$)" "$say"; then
    self_pr_question_kind=scope
  elif grep -Eq "^ASK-PASS-CRITERIA:$TASK([[:space:]]|$)" "$say"; then
    self_pr_question_kind=acceptance
  fi
  question_draft=1
fi
# An external request without implementation has a complete private delivery
# path. Never manufacture a target-tree design/questions file for a PR diff.
if [ "$FM_EXTERNAL" = 1 ] && [ "$asked" = 1 ] && [ -z "$PR" ] && ! worker_changed_files; then
  fm_private_note worker-report "$TASK" "$say" || exit 65
  spoke=1
fi
held=''
held_settled=0
held_has_work=0
round_had_work=0
lost_held() {   # lost_held <rc>; from the EXIT trap, so it returns
  held_settled=1
  echo "fm-worker: the run ended (exit $1) before the worker's note reached a pull request" >&2
  save_unsent "$held" "${PR:-}" || true
  emit --type worker_crashed ${PR:+--pr "$PR"} \
       --en "the worker's note was not posted: the run ended (exit $1) before it reached a pull request" \
       --tw "工人的留言沒有貼出：執行在送到 PR 之前就結束了（exit ${1}）"
}
if [ "$projection" = comments ] && [ "$asked" = 1 ] && [ -z "$PR" ] && { worker_changed_files || rebuild_publishes || first_round_question; }; then
  _held="$(scratch_new)" || _held=''
  [ -n "$_held" ] || { echo "fm-worker: could not make a scratch file" >&2; exit 70; }
  scratch_add "$_held"
  cp "$say" "$_held" || { echo "fm-worker: could not set the worker's note aside" >&2; exit 70; }
  held="$_held"
  worker_changed_files && held_has_work=1
fi
if [ "$asked" = 1 ] && [ -n "$PR" ]; then
  post_note "$say" "$PR"
fi
# Reports beside worker changes are retained now but only announced after
# publication. Question-only and rebuild-only refusals retain exit 73.
refused=0
if [ "$asked" = 1 ] && [ "$spoke" = 0 ] && [ -z "$held" ] && [ -n "$PR" ]; then
  if [ "$FM_EXTERNAL" = 0 ] && worker_changed_files; then
    note_unsent "$say"
  elif [ "$rebuilt" = 1 ] && { worker_changed_files || rebuild_publishes; }; then
    note_refused "$say"
    refused=1
  fi
fi
if [ "$asked" = 1 ] && [ "$spoke" = 0 ] && [ -z "$held" ] && [ "$refused" = 0 ] && [ "${note_settled:-0}" = 0 ]; then
  keep_unsent "$say"
fi
rm -f "$say"

# asking IS the work in a round that begins with a question, and the round
# after it is the one that changes files. A rebuild this round made is not
# a change the worker made, but one that applied is published all the same
# (rebuild_publishes). A rebuild left unresolved publishes nothing, and
# the next round rebuilds again from the branch as it stands.
# Said here, where it is already true, so a round that fails on the way to
# the push still reports that it asked.
if [ "$asked" = 1 ] && ! first_round_question && ! worker_changed_files; then
  if ! rebuild_publishes; then
    if [ "$projection" = comments ] && [ -n "$PR" ]; then
      echo "fm-worker: the worker asked rather than changed anything; its question is on #$PR" >&2
    else
      echo "fm-worker: the worker asked rather than changed anything; its question is retained in local evidence" >&2
    fi
    printf '%s\n' "$branch"
    exit 0
  fi
  if [ -n "$held" ]; then
    asked_where="its question waits for the pull request this round opens"
  elif [ "$refused" = 1 ]; then
    asked_where="#$PR would not take its question"
  else
    if [ "$projection" = comments ] && [ -n "$PR" ]; then
      asked_where="its question is on #$PR"
    else
      asked_where="its question is retained in local evidence"
    fi
  fi
  echo "fm-worker: the worker asked rather than changed anything; $asked_where; the rebuild applied, so it is published all the same" >&2
fi

# the same predicate the chain was given, not a second spelling of it: the
# two agreed only because the prompt happened to be removed between them.
# A rebuild is work in its own right: a branch brought up to date with
# nothing else to add is still committed and pushed.
if [ "$rebuilt" = 0 ] && ! first_round_question && ! worker_did_work; then
  # A round that destroyed its own tree did something, and the mirror
  # already said so (worktree_restored); it is not the same round as one
  # that truly left the tree untouched (T-128).
  if [ "$mirror_restored" = 1 ]; then
    echo "fm-worker: the adapter destroyed its own tree rather than changing nothing; it was restored from the mirror" >&2
    emit --type gate_failed --en "destroyed its own tree rather than changing nothing" \
      --tw "摧毀了自己的工作樹，而不是什麼都沒改"
  else
    echo "fm-worker: the adapter changed nothing" >&2
    emit --type gate_failed --en "the adapter changed nothing" --tw "adapter 沒有改動任何檔案"
  fi
  exit 1
fi

# --- from here on it is the script's job, never the adapter's ------------
# Every step from here to the push is checked where it stands. This script
# does not run under `set -e`, so a git command that fails and is not
# tested is simply stepped over - and the run goes on to report a commit
# it never made.
rebuild_refuse() {   # rebuild_refuse <what, en> <what, zh-TW>
  echo "fm-worker: $1" >&2
  echo "fm-worker: nothing is committed or pushed; the branch stays at ${rebuild_prev}" >&2
  echo "fm-worker: the worktree is left at $tree; the next round rescues it and rebuilds from the branch" >&2
  emit --type gate_failed ${PR:+--pr "$PR"} --en "$1; not committed" --tw "${2}，沒有 commit"
  exit 75
}
# Everything below reads the rebuild against the base it was made on, and
# the commit below lands on HEAD. The two are one only while HEAD is still
# that base, detached: a commit made on it mid-round - a worker's own, or
# any save - would sit under the round, outside every check here, and go
# out with it.
if [ "$rebuilt" = 1 ]; then
  now_head="$(git -C "$tree" rev-parse -q --verify HEAD 2>/dev/null)"
  if [ "$now_head" != "$rebuild_base" ] || git -C "$tree" symbolic-ref -q HEAD >/dev/null 2>&1; then
    rebuild_refuse "HEAD moved off the rebuild base ${rebuild_base} during the round (now ${now_head:-unreadable}$(git -C "$tree" symbolic-ref -q --short HEAD 2>/dev/null | sed 's/^/ on /'))" \
      "這輪中途 HEAD 離開了重建的基底 ${rebuild_base}"
  fi
fi
if worker_changed_files || [ "$rebuilt" = 1 ]; then round_had_work=1; fi
git -C "$tree" add -A || { echo "fm-worker: could not stage the round on $branch" >&2; exit 70; }
# A rebuilt round is committed only once every handed-over conflict is
# resolved. Every file this commit carries is read - on a rebuild that is
# the task's whole change - not just the ones listed, because a marker the
# worker copied elsewhere is as broken as one it left in place. From the
# index, since that is what would be committed.
if [ "$rebuilt" = 1 ]; then
  carried=(); marked=()
  while IFS= read -r -d '' f; do carried+=("$f"); done \
    < <(git -C "$tree" diff --cached --name-only -z --diff-filter=d "$rebuild_base")
  if [ ${#carried[@]} -gt 0 ]; then
    # exit 1 is "no marker anywhere"; anything above it is a grep that did
    # not read the files, and that is not the same answer
    # names NUL-separated, as above, so the refusal names the real file;
    # turned back into lines here, since a substitution drops NULs
    found="$(git -C "$tree" --literal-pathspecs grep --cached -l -z -E '^(<<<<<<<|>>>>>>>)( |$)' \
               -- "${carried[@]}" 2>/dev/null | tr '\0' '\n'; exit "${PIPESTATUS[0]}")"; grc=$?
    [ "$grc" -le 1 ] || { echo "fm-worker: could not read the rebuilt $branch for conflict markers" >&2; exit 70; }
    while IFS= read -r f; do
      [ -n "$f" ] && marked+=("$f")
    done <<<"$found"
  fi
  if [ ${#marked[@]} -gt 0 ]; then
    listed="$(printf '%s, ' "${marked[@]}")"; listed="${listed%, }"
    rebuild_refuse "conflict markers remain in: ${listed}" "衝突標記還留在 ${listed}"
  fi
  # a conflict with no markers, still exactly the side the merge left
  untouched=()
  for i in ${rebuild_bare[@]+"${!rebuild_bare[@]}"}; do
    [ "$(rebuild_state_of "${rebuild_bare[$i]}")" != "${rebuild_bare_left[$i]}" ] \
      || untouched+=("${rebuild_bare[$i]}")
  done
  if [ ${#untouched[@]} -gt 0 ]; then
    listed="$(printf '%s, ' "${untouched[@]}")"; listed="${listed%, }"
    rebuild_refuse "conflicts with no markers are still as the merge left them: ${listed}" \
      "沒有衝突標記的衝突還是合併留下的樣子：${listed}"
  fi
  # the task's own entry and row, exactly as the previous head had them,
  # whatever repaired or resolved them on the way here
  lost=()
  while IFS= read -r f; do [ -n "$f" ] && lost+=("$f"); done < <(rebuild_lost index)
  if [ ${#lost[@]} -gt 0 ]; then
    listed="$(printf '%s, ' "${lost[@]}")"; listed="${listed%, }"
    if [ -n "$pinned_path" ]; then
      rebuild_refuse "the task's own entry is not as pin v${pinned_version} has it in: ${listed}" \
        "任務自己的條目跟 pin v${pinned_version} 不一樣：${listed}"
    else
      rebuild_refuse "the task's own entry is not as ${rebuild_prev} had it in: ${listed}" \
        "任務自己的條目跟 ${rebuild_prev} 不一樣：${listed}"
    fi
  fi
fi
# A script the round adds keeps its executable bit. The claude worker's
# sandbox refuses chmod, so every script a worker added was committed
# 100644 and a suite that ran it by path failed with 126 (T-048, T-059).
# The bit is set in the index, which needs no permission of the worker's,
# and on disk as well where it can be, so the worktree agrees with the
# commit. Only on a file this round adds - absent from where the round
# started (a mid-run checkpoint does not count as a start: it commits with
# the same missing bit), and on a rebuild from the base and the previous
# head both - under bin/ or
# tests/, starting with a shebang, in a directory that already holds an
# executable script. A bit is never removed, and no other file is touched.
dir_runs_scripts() {   # dir_runs_scripts <commit> <dir>: an executable script already there
  local e meta tab=$'\t'
  while IFS= read -r -d '' e; do
    meta="${e%%"$tab"*}"
    [ "${meta%% *}" = 100755 ] || continue
    [ "$(git -C "$tree" cat-file blob "${meta##* }" 2>/dev/null | head -c 2 | tr -d '\0')" = '#!' ] && return 0
  done < <(git -C "$tree" ls-tree -z "$1" -- "$2/" 2>/dev/null)
  return 1
}
new_scripts_executable() {   # new_scripts_executable <commit the round started from> [<previous head>]
  local f
  while IFS= read -r -d '' f; do
    case "$f" in bin/*|tests/*) ;; *) continue ;; esac
    [ -z "${2:-}" ] || ! git -C "$tree" cat-file -e "$2:$f" 2>/dev/null || continue
    [ "$(git -C "$tree" --literal-pathspecs ls-files -s -- "$f" | cut -c1-6)" = 100644 ] || continue
    [ "$(git -C "$tree" cat-file blob ":$f" 2>/dev/null | head -c 2 | tr -d '\0')" = '#!' ] || continue
    dir_runs_scripts "$1" "${f%/*}" || continue
    # the index first: a bit it refuses is not left on disk for the exit's
    # checkpoint to carry, as though the round had set it
    git -C "$tree" --literal-pathspecs update-index --chmod=+x -- "$f" || return 1
    chmod +x "$tree/$f" 2>/dev/null || true
    echo "fm-worker: $f is a new script; it is committed executable" >&2
  done < <(git -C "$tree" diff --cached --name-only -z --diff-filter=A "$1")
}
if [ "$rebuilt" = 1 ]; then
  new_scripts_executable "$rebuild_base" "$rebuild_prev"
else
  new_scripts_executable "${round_start:-HEAD}"
fi || { echo "fm-worker: could not set the executable bit on a new script on $branch; the round is not committed" >&2; exit 70; }
# A rebuilt round is committed with commit-tree, from the staged tree and
# parented on the fetched base, rather than by `git commit` on the detached
# HEAD: the repository's pre-commit hook refused every commit on a detached
# HEAD, and so every real rebuild (T-093). No hook is stepped around on a
# protected branch - this commit is on no branch at all until the push
# below lands, and then only on the task's.
#
# Once made, HEAD is moved onto it, detached, as `git commit` would have
# left it: the index and worktree already hold its tree, so the worktree
# is clean. Every exit between here and the branch move - a refused lease,
# a failed record - relies on that. Left on the base with the rebuild
# staged, the next round would take a pushed or refused commit for an
# uncommitted round and rescue it as crashed work.
commit_msg="$TASK: Save the round's changes"
public_text=''
if [ "$FM_EXTERNAL" = 0 ]; then
  commit_msg="$TASK: $(jq -r .title <<<"$spec")"
elif [ -n "${spec:-}" ] && [ -n "${FM_CODE_ROOT:-}" ]; then
  # Read current private format data, but publish only the pinned public prose.
  if pr_format="$(fm_conventions pr_format 2>/dev/null)"; then
    pr_review_mode="$(fm_project_reviewer_mode)"
    if [ -z "$pr_review_mode" ]; then
      pr_review_mode="$(fm_cfg_in reviewer mode)"
    fi
    pr_review_mode="${pr_review_mode:-diff}"
    pr_unrunnable=0
    if pin_unrunnable="$(jq -r '.contract.unrunnable // empty' <<<"${FM_SPEC_PIN_JSON:-}" 2>/dev/null)" &&
       [ -n "$pin_unrunnable" ]; then
      pr_unrunnable=1
    fi
    if pr_checks="$(fm_conventions required_checks 2>/dev/null)"; then
      public_text="$(python3 "$FM_CODE_ROOT/bin/lib/fm_pr_format.py" render \
        --spec /dev/stdin --format "$pr_format" --required-checks "$pr_checks" \
        --review-mode "$pr_review_mode" --unrunnable "$pr_unrunnable" <<<"$spec" \
        2>/dev/null)" || public_text=''
    fi
  else
    echo 'fm-worker: cannot read the PR format; using the generic title' >&2
  fi
  if [ -n "$public_text" ]; then
    commit_msg="$(jq -r .title <<<"$public_text")"
    if [ "$(jq -r .pr_title <<<"$pr_format")" = conventional ] &&
       ! FM_PR_TITLE=conventional python3 "$FM_CODE_ROOT/bin/lib/fm_public_text.py" check /dev/stdin \
         <<<"$spec" >/dev/null 2>&1; then
      echo 'fm-worker: public_title does not follow the conventional style' >&2
    fi
  fi
fi
fm_private_stage "$tree" || exit 65
rebuilt_head=''; commit_ok=0
# Advisory only (T-270): the commit message's plain-writing findings go to
# firstmate's log; the commit happens whatever they say.
if [ "$rebuilt" = 1 ]; then plain_lint rebuilt-commit "$commit_msg"; else plain_lint round-commit "$commit_msg"; fi
if [ "$rebuilt" = 1 ]; then
  # fm_git_commit (bin/fm-config.sh) is the identity rule, a refusal and
  # `commit -q -m`; this is the same rule and refusal, applied to
  # commit-tree. What commit does beyond that and commit-tree does not is
  # run the hooks - the point here - and clean up the message, which is
  # one line. commit also signs when commit.gpgSign says to; commit-tree,
  # being plumbing, ignores that setting, so it is read here and passed
  # on as -S.
  rb_sign=''
  [ "$(git -C "$tree" config --bool commit.gpgSign 2>/dev/null)" != true ] || rb_sign=-S
  if [ -z "$rb_name" ] || [ -z "$rb_email" ]; then
    echo "fm: set git user.name and user.email (or FM_GIT_NAME / FM_GIT_EMAIL) before committing" >&2
  elif rebuilt_tree="$(git -C "$tree" write-tree)" && [ -n "$rebuilt_tree" ]; then
    rebuilt_head="$(git -C "$tree" -c user.name="$rb_name" -c user.email="$rb_email" \
      commit-tree ${rb_sign:+"$rb_sign"} "$rebuilt_tree" -p "$rebuild_base" -m "$commit_msg" </dev/null)" || rebuilt_head=''
    if [ -n "$rebuilt_head" ] && git -C "$tree" update-ref --no-deref -m "fm-worker: rebuilt $branch" \
         HEAD "$rebuilt_head" "$rebuild_base"; then
      commit_ok=1
    fi
  fi
elif first_round_question && git -C "$tree" diff --cached --quiet; then
  # A previous attempt already committed the spec; publish that commit.
  commit_ok=1
elif fm_git_commit "$tree" "$commit_msg"; then
  commit_ok=1
fi
if [ "$commit_ok" != 1 ]; then
  # Stop here, rebuilt or not. A plain round would otherwise push a branch
  # without this round's work and say it had committed; a rebuilt one
  # would move the branch onto the bare base below.
  echo "fm-worker: could not commit on $branch; nothing is pushed" >&2
  emit --type gate_failed ${PR:+--pr "$PR"} --en "could not commit on $branch" --tw "無法在 $branch 上 commit"
  exit 70
fi
_fm_wip_done=1
if [ "$rebuilt" = 1 ]; then
  # Pushed by its id first; the local branch moves only once origin has
  # taken it. Until then refs/fm-rebuilt/ names the commit, so a run cut
  # short in between settles on origin's answer (rebuild_settle).
  git -C "$FM_TARGET_ROOT" update-ref "refs/fm-rebuilt/$branch" "$rebuilt_head" || {
    echo "fm-worker: could not record the rebuilt commit ${rebuilt_head}; nothing is pushed" >&2; exit 70; }
  # Leased on the head fetched before the rebuild, never a bare --force:
  # anything pushed to the branch since is refused rather than overwritten.
  # An empty lease means the branch must still not exist on origin.
  if [ "$FM_EXTERNAL" = 1 ]; then
    if ! force_policy="$(fm_stack_policy force_with_lease)" || [ "$force_policy" != true ]; then
      echo 'fm-worker: the project conventions do not allow force_with_lease; rebuild retained for recovery / 專案慣例不允許 force_with_lease；保留重建結果以便復原' >&2
      exit 65
    fi
    if [ -z "$rebuild_lease" ] || [ "$rebuild_lease" != "$bound_head" ]; then
      echo 'fm-worker: an external branch that is not the head the round was bound to / 外部分支並非本輪綁定的版本' >&2
      exit 65
    fi
    fm_publication_policy "$tree" "$branch" || exit 65
  fi
  if ! git -C "$tree" push -q --force-with-lease="refs/heads/$branch:$rebuild_lease" \
       origin "$rebuilt_head:refs/heads/$branch" 2>/dev/null; then
    # refused: the local branch never moved; the rebuilt commit stays
    # reachable by the id printed here
    rebuild_settle || true
    echo "fm-worker: could not push the rebuilt $branch: origin no longer has ${rebuild_lease:-no such branch}, or refused" >&2
    echo "fm-worker: the rebuilt commit is ${rebuilt_head}; $branch is back at $(git -C "$FM_TARGET_ROOT" rev-parse -q --verify "refs/heads/$branch")" >&2
    exit 71
  fi
  # origin has it: only now the local branch. HEAD, the index and the
  # worktree are already on it, so this moves the branch and attaches HEAD.
  git -C "$tree" checkout -q -B "$branch" "$rebuilt_head" || {
    echo "fm-worker: the rebuilt $branch (${rebuilt_head}) is on origin, but $branch could not be moved onto it; the next round does" >&2
    exit 70; }
  git -C "$tree" branch -q -u "origin/$branch" >/dev/null 2>&1 || true
  git -C "$FM_TARGET_ROOT" update-ref -d "refs/fm-rebuilt/$branch" 2>/dev/null \
    || echo "fm-worker: could not clear refs/fm-rebuilt/$branch; the next round settles it" >&2
  echo "fm-worker: $branch rebuilt on $BASE; the previous head was ${rebuild_prev}" >&2
else
  fm_publication_policy "$tree" || exit 65
  git -C "$tree" push -q -u origin "$branch" 2>/dev/null || {
    echo "fm-worker: could not push $branch" >&2; exit 71; }
fi
# Only now: a push that was refused - a lease above, or a plain one - left
# a commit that is not on origin, and the log must not say it was pushed.
emit_status "Commit pushed on $branch" "已在 $branch 上推送 commit"
emit --type commit_pushed ${adopt_data_args[@]+"${adopt_data_args[@]}"} --en "committed on $branch" --tw "已在 $branch 上 commit"
note_unsent_published
rebuild_args=(${adopt_data_args[@]+"${adopt_data_args[@]}"})
if [ "$rebuilt" = 1 ]; then
  rebuild_args=(--data "$(jq -cn --arg prev "$rebuild_prev" --arg base "$BASE" \
    --arg base_head "$rebuild_base" --arg head "$(git -C "$tree" rev-parse HEAD)" --arg adopt_pr "${adopt_pr:-}" \
    '{rebuilt:{previous_head:$prev,base:$base,base_head:$base_head,head:$head,
      conflicts:$ARGS.positional}} + (if $adopt_pr == "" then {} else {adopt_pr:($adopt_pr|tonumber)} end)' --args ${rebuild_conflicts[@]+"${rebuild_conflicts[@]}"})")
fi

# On a later round the pull request is already open and `pr create` fails.
# A worker that could only ever open a new one failed its second round at
# the last step, with the work pushed and nothing pointing at it.
#
# $PR is what the lookup above the prompt found, or what the caller
# passed; asking again here would be a second answer to one question,
# and the two could disagree - a pull request opened while the engine
# was running would be posted to by one half of this script and not the
# other. There is no second lookup - asserted, not asserted about:
# tests/worker.test.sh counts `pr list` at one per run. An
# empty $PR here means either a first round, or a later round whose
# lookup succeeded and said there is none - a branch pushed by a round
# that died before it opened one. Both want a pull request created
# below. The third case, a lookup that could not answer, does not reach
# here: it exits 74 above rather than pushing at a pull request nobody
# looked for.
num="$PR"
if [ -z "$num" ] || [ "$num" = "null" ]; then
  draft_args=()
  if first_round_question; then draft_args=(--draft); fi
  pr_body="Dispatched by firstmate for $TASK. Acceptance is in design/tasks/$TASK.json."
  pr_title="$TASK: Save the round's changes"
  if [ "$FM_EXTERNAL" = 0 ]; then
    self_pr_repository="$(fm_project_get "${FM_PROJECT:-firstmate-workflow}" github "$FM_CONFIG" 2>/dev/null || true)"
    self_pr_origin="$(git -C "$FM_TARGET_ROOT" config --get remote.origin.url 2>/dev/null || true)"
    self_pr_head="$(git -C "$tree" rev-parse HEAD)" || exit 65
    self_pr_files="$(scratch_new)" || exit 70
    scratch_add "$self_pr_files"
    # NUL-delimited git paths remain data, including quotes and shell syntax.
    git -C "$tree" diff --name-only -z "$self_pr_base...$self_pr_head" | \
      python3 -c 'import json,sys; json.dump([p.decode("utf-8") for p in sys.stdin.buffer.read().split(b"\0") if p],sys.stdout)' \
      > "$self_pr_files" || exit 65
    self_pr_question=()
    if first_round_question; then
      self_pr_question=(--question "$self_pr_question_kind")
    fi
    self_pr_rendered="$(python3 "${FM_CODE_ROOT:-$REPO}/bin/lib/fm_self_pr.py" render \
      --task "$TASK" --evidence-project "$(fm_evidence_project)" --head "$self_pr_head" "${self_pr_binding[@]}" \
      --repository "$self_pr_repository" --origin "$self_pr_origin" --files "$self_pr_files" \
      ${self_pr_question[@]+"${self_pr_question[@]}"})" || exit 65
    pr_title="$(jq -r .title <<<"$self_pr_rendered")" || exit 65
    pr_body="$(jq -r .body <<<"$self_pr_rendered")" || exit 65
  else
    pr_body="Task $TASK. Captain acceptance and evidence are retained privately."
    if [ -n "${public_text:-}" ]; then
      pr_title="$(jq -r .title <<<"$public_text")"
      pr_body="$(jq -r .body <<<"$public_text")"
    fi
  fi
  pr_body_args=(--body "$pr_body")
  if [ "$FM_EXTERNAL" = 0 ]; then
    self_pr_body_file="$(scratch_new)" || exit 70
    scratch_add "$self_pr_body_file"
    chmod 600 "$self_pr_body_file" || exit 70
    printf '%s' "$pr_body" > "$self_pr_body_file" || exit 70
    pr_body_args=(--body-file "$self_pr_body_file")
  fi
  url="$(fm_github pr create ${draft_args[@]+"${draft_args[@]}"} --head "$branch" --base "$BASE" \
        --title "$pr_title" \
        "${pr_body_args[@]}" \
        2>/dev/null </dev/null | tail -1)"
  # the number, not the url: every step after this addresses the pull
  # request by it, and an event without it leaves the gates checking nothing
  num="$(printf '%s' "$url" | sed -n 's|.*/\([0-9][0-9]*\)$|\1|p')"
  [ -n "$num" ] || { echo "fm-worker: could not read a pull request number from '$url'" >&2; exit 72; }
  if first_round_question; then
    mkdir -p "$FM_STATE_DIR/drafts" && : > "$FM_STATE_DIR/drafts/$TASK-$num" || {
      echo "fm-worker: warning: could not record ownership of draft #$num" >&2; }
  fi
  emit_status "Pull request #$num opened" "已開 PR #$num"
  emit --type pr_opened --pr "$num" ${rebuild_args[@]+"${rebuild_args[@]}"} \
       --en "opened #$num" --tw "已開 #$num"
else
  # Upgrade only the untouched external fallback title. Never replace a title
  # chosen by the captain, or one belonging to a different branch.
  if [ "$FM_EXTERNAL" = 1 ] && [ -z "${adopt_pr:-}" ] && [ -n "${public_text:-}" ]; then
    if current_pr="$(fm_github pr view "$num" --json title,headRefName 2>/dev/null)" &&
       jq -e 'type == "object" and (.title | type == "string") and (.headRefName | type == "string")' \
         <<<"$current_pr" >/dev/null 2>&1; then
      # Both the fallback title before T-270 and the current one are untouched.
      if jq -e --arg old "$TASK: project work" --arg title "$TASK: Save the round's changes" --arg branch "$branch" \
           '(.title == $title or .title == $old) and .headRefName == $branch' <<<"$current_pr" >/dev/null; then
        if ! fm_github pr edit "$num" --title "$(jq -r .title <<<"$public_text")" \
             --body "$(jq -r .body <<<"$public_text")" >/dev/null 2>&1; then
          echo 'fm-worker: could not update the public PR title / 無法更新公開 PR 標題' >&2
        fi
      fi
    else
      echo 'fm-worker: could not read the PR title for update / 無法讀取待更新的 PR 標題' >&2
    fi
  fi
  emit_status "Pushed another round to #$num" "已推第二輪到 #$num"
  emit --type commit_pushed --pr "$num" ${rebuild_args[@]+"${rebuild_args[@]}"} \
       --en "pushed another round to #$num" --tw "第二輪已推上 #$num"
  # Mark only a draft opened by firstmate after a later round delivers work.
  if [ -z "${adopt_pr:-}" ] && [ "${asked:-0}" = 0 ] &&
     [ "${round_had_work:-0}" = 1 ] && [ -f "$FM_STATE_DIR/drafts/$TASK-$num" ]; then
    if is_draft="$(fm_github pr view "$num" --json isDraft --jq .isDraft 2>/dev/null)"; then
      if [ "$is_draft" = true ]; then
        if fm_github pr ready "$num" >/dev/null 2>&1; then
          rm -f "$FM_STATE_DIR/drafts/$TASK-$num"
          emit_status "Pull request #$num marked ready for review" "PR #$num 已標成 ready for review"
        else
          echo "fm-worker: could not mark pull request #$num ready for review" >&2
        fi
      fi
    else
      echo "fm-worker: could not read draft status for pull request #$num" >&2
    fi
  fi
  # End owned draft transition.
fi
# The reviewer reads the pull request, and after a rebuild the diff it saw
# last is gone from the branch. The previous head is what it compares
# against, so it goes on the pull request as well as into the event.
if [ "$rebuilt" = 1 ]; then
  if [ "${#rebuild_conflicts[@]}" -gt 0 ]; then
    handed="$(printf '`%s`, ' "${rebuild_conflicts[@]}")"; handed="${handed%, }"
  else
    handed='none'
  fi
  if [ "$FM_EXTERNAL" = 1 ]; then
    rebuild_reason='it no longer rebased onto it cleanly.'
    [ "${rebuild_clean:-0}" != 1 ] || rebuild_reason='it was behind and replays cleanly.'
    if rebuild_note="$(scratch_new)" &&
       scratch_add "$rebuild_note" &&
       printf '%s\n' \
         "fm-worker.sh rebuilt \`$branch\` as one commit on \`$BASE\` at \`$rebuild_base\`: $rebuild_reason" \
         "" "Previous head: \`$rebuild_prev\`" "New head: \`$(git -C "$tree" rev-parse HEAD)\`" \
         "Conflicts handed to the worker: $handed" > "$rebuild_note" &&
       fm_private_note rebuild "$TASK" "$rebuild_note"; then
      :
    else
      echo 'fm-worker: could not retain the private rebuild note / 無法保留私密重建記錄' >&2
    fi
  else
    # This runs after the round: the worker has resolved every conflict, and
    # the rebuilt commit is already published (unresolved markers refuse it).
    rebuild_comment="$(printf '%s\n' \
         "The firstmate launcher rebuilt \`$branch\` as one commit on \`$BASE\` at \`$rebuild_base\`, because the branch no longer rebased onto it cleanly." \
         "The worker resolved any conflicts listed below in this round. The pull request is ready for CI." \
         "" "Previous head: \`$rebuild_prev\`" "New head: \`$(git -C "$tree" rev-parse HEAD)\`" \
         "Conflicts handed to the worker: $handed")"
    plain_lint rebuild-comment "$rebuild_comment"
    if ! fm_github pr comment "$num" --body "$rebuild_comment" \
         >/dev/null 2>&1 </dev/null; then
      echo "fm-worker: could not note the rebuild on #$num; the previous head was ${rebuild_prev}" >&2
    fi
  fi
fi
# The held note now has a PR. Use the pre-commit work observation: a clean
# worktree after publication no longer tells us whether this worker changed it.
if [ -n "$held" ]; then
  PR="$num"
  post_note "$held" "$num"
  [ "$spoke" = 1 ] && held_settled=1
  if [ "$spoke" != 1 ]; then
    if [ "$FM_EXTERNAL" = 0 ] && [ "$held_has_work" = 1 ] && ! first_round_question; then
      note_unsent "$held"
      note_unsent_published
    else
      keep_unsent "$held"
    fi
  fi
fi
# Publication is complete: bind the optional progress projection to this head.
if [ "$FM_EXTERNAL" = 1 ] && [ "$projection" != comments ]; then
  if ! fm_external project --pr "$num" --head "$(git -C "$tree" rev-parse HEAD)" --stage worker; then
    FM_CREW_STATUS_SECS=0 emit --type crew_status --data '{"evidence_event":"projection_failed"}' \
      --en 'Optional worker projection failed; local report retained' \
      --tw '選用的工作投影發布失敗；本機報告已保留'
  fi
fi
# the note refused above still requires 73 for a question-only round or failed retention.
[ "$refused" = 0 ] || exit 73
printf '%s\n' "$branch"
[ "${rc:-1}" = "0" ] || exit 1
exit 0
