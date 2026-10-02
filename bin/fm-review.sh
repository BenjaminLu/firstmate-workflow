#!/usr/bin/env bash
# Runs one review round. The reviewer is given the diff, the task spec and the
# acceptance criteria - and, from round two, the closed-list protocol's own
# comments from the pull request, and, given --pr, in every round the head's
# SHA, its required check, every CI job's result, the failing assertions from
# the failed jobs' logs, the fail-first report and its gate summary - once the
# required checks have finished, or a bounded wait has run out (T-153) - and
# nothing else. Not the worker's log, not
# its reasoning, not even the path it worked in. Reasoning is persuasive; the
# artefact is what is under review.
#
# config.yaml's `reviewer: mode:` says how much more it gets. `diff`, and a
# project that declares nothing, is the above and only the above. `run` adds a
# fresh clone of the pull request head, outside every worktree and removed
# when the round ends, in which the reviewer may run small commands to check
# a claim; the suites are the machine's to run (T-153).
# The adapter confines it there with the engine's own permission flags;
# nothing in the prompt is what stops it.
#
#   fm-review.sh --task T-004 --branch <name> [--repo .] [--pr 9] [--round 1]
#   FM_REVIEW_CI_WAIT=<seconds, default 1200>  FM_REVIEW_CI_POLL=<seconds, default 30>
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
# the adapters' library, for the one rule on which hosts a run-mode sandbox
# may reach: this script and the adapter apply the same one
_fm_alib="$(dirname "${BASH_SOURCE[0]}")/adapters/_lib.sh"
[ -f "$_fm_alib" ] || { echo "${0##*/}: missing $_fm_alib" >&2; exit 70; }
# shellcheck source=bin/adapters/_lib.sh
. "$_fm_alib"
fm_args=("$@")

REPO="$(fm_default_repo)"; TASK=''; BRANCH=''; PR=''; ROUND=1; VENDOR=''; NAME=''; ROUND_GIVEN=''
BASE="${FM_BASE:-main}"; GH="${FM_GH:-gh}"
while [ $# -gt 0 ]; do
  case "$1" in
    --project) fm_need "fm-review" "$@"; export FM_PROJECT="${2-}"; shift 2 ;;
    --task) fm_need "fm-review" "$@"; TASK="${2-}"; shift 2 ;;
    --branch) fm_need "fm-review" "$@"; BRANCH="${2-}"; shift 2 ;;
    --repo) fm_need "fm-review" "$@"; REPO="${2-}"; shift 2 ;;
    --pr) fm_need "fm-review" "$@"; PR="${2-}"; shift 2 ;;
    --round) fm_need "fm-review" "$@"; ROUND="${2-}"; ROUND_GIVEN=1; shift 2 ;;
    --vendor) fm_need "fm-review" "$@"; VENDOR="${2-}"; shift 2 ;;
    --name) fm_need "fm-review" "$@"; NAME="${2-}"; shift 2 ;;
    *) echo "fm-review: unknown argument $1" >&2; exit 64 ;;
  esac
done
[ -n "$TASK" ] && [ -n "$BRANCH" ] || {
  echo "usage: fm-review.sh --task <id> --branch <name> [--pr N] [--round N]" >&2; exit 64; }
# How long a round given --pr waits for the head's required checks before it
# starts the reviewer anyway, and how often it asks GitHub meanwhile (T-153).
CI_WAIT="${FM_REVIEW_CI_WAIT:-1200}"; CI_POLL="${FM_REVIEW_CI_POLL:-30}"
case "$CI_WAIT" in ''|*[!0-9]*) echo "fm-review: FM_REVIEW_CI_WAIT must be whole seconds" >&2; exit 64 ;; esac
case "$CI_POLL" in ''|*[!0-9]*|0) echo "fm-review: FM_REVIEW_CI_POLL must be whole seconds, at least 1" >&2; exit 64 ;; esac
CI_WAIT=$((10#$CI_WAIT)); CI_POLL=$((10#$CI_POLL))
cd "$REPO" || { echo "fm-review: no repo at $REPO" >&2; exit 64; }
REPO="$(pwd -P)"
fm_storage_init "$REPO" || exit 65
# A registered self project need not be the default project. Its review events
# must name the same project that identity allocation uses for round counting.
project_events=()
if [ -n "${FM_PROJECT:-}" ] && [ -n "$(fm_projects "$FM_CONFIG" 2>/dev/null)" ]; then
  project_events=(--project "$FM_PROJECT")
fi
fm_conventions "" >/dev/null || exit 65
fm_refuse_herdr_bypass fm-review || exit $?
fm_freeze "$0" "$REPO" ${fm_args[@]+"${fm_args[@]}"}
fm_external_prepare || exit 65
fm_target_validate || exit 65
fm_external_base || exit 65
BASE="${FM_BASE:-$BASE}"

# per run, like the worker's: a constant actor collapses two concurrent
# rounds into one crewman carrying whichever task the second one touched
cd "$FM_TARGET_ROOT" || exit 65
REVIEW_TMP="${TMPDIR:-/tmp}"
if [ "$FM_EXTERNAL" = 1 ]; then
  REVIEW_TMP="$FM_STATE_DIR/review-checkouts"
  mkdir -p "$REVIEW_TMP" || exit 70
fi
# The actor carries the review round (T-116): the one --round names, else
# the allocation reads it from the log. Never one inherited from the shell.
if [ -n "$ROUND_GIVEN" ]; then export FM_ROUND="$ROUND"; else unset FM_ROUND; fi
fm_identity reviewer "$TASK" "$NAME" || exit 70
unset FM_ROUND
ROUND="$(jq -r .round "$FM_RUN_DIR/identity.json")"
# T-146: the vendor this round starts on and the model "$FM_CONFIG" names for
# that vendor are in identity.json from the start, so the board shows them
# from the round's first event (the model the vendor reports joins them
# once the round has run; a fallback vendor replaces them as it starts)
head_vendor="$(fm_vendor_chain reviewer "$VENDOR" | head -1)"
fm_record_requested "$head_vendor" "$(fm_model_for reviewer "$head_vendor" "$FM_CONFIG")"
# T-116: name, role, project, task, round and attempt ride every crew
# payload as separate fields, so the board never parses them out of the actor;
# vendor and model beside them (T-127, T-146), read fresh for every payload
CREW_DATA="$(jq -cn --arg role reviewer --arg name "$NAME" --argjson identity "$(fm_crew_identity)" \
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
# fm-emit keeps the last --data only. Merge review_outcome and any call-site
# --data into the crew payload so extras cannot wipe crew_name or activity.
emit_once() {
  crew_refresh_identity
  local data="$CREW_DATA" args=() now
  while [ $# -gt 0 ]; do
    case "$1" in
      --type)
        fm_need "fm-review" "$@"
        # A verdict event is the round's result: it carries the round's own
        # wall-clock, from just before review_opened to now (T-153), which
        # /api/state's last_review reads, and how much of it was spent
        # waiting for the head's CI before the reviewer started
        if [ -n "$ROUND_STARTED" ] && { [ "${2-}" = approved ] || [ "${2-}" = review_failed ]; }; then
          now="$(date +%s)"
          data="$(jq -c --argjson s "$ROUND_STARTED" --argjson e "$now" --argjson w "${CI_WAITED:-0}" \
            '.wall_clock={started:$s,ended:$e,seconds:($e-$s),ci_wait:$w}' <<<"$data")" || return 1
        fi
        args+=("$1" "${2-}"); shift 2
        ;;
      --review-outcome)
        fm_need "fm-review" "$@"
        data="$(jq -c --arg outcome "${2-}" '.review_outcome=$outcome' <<<"$data")" || return 1
        shift 2
        ;;
      --data)
        fm_need "fm-review" "$@"
        data="$(jq -c --argjson extra "${2-}" '. * $extra' <<<"$data")" || return 1
        shift 2
        ;;
      *) args+=("$1"); shift ;;
    esac
  done
  FM_ROOT="$REPO" "${FM_CODE_ROOT:-$REPO}/bin/fm-emit.sh" --data "$data" --actor "$NAME" --task "$TASK" \
    ${project_events[@]+"${project_events[@]}"} ${args[@]+"${args[@]}"} >/dev/null 2>&1 </dev/null
}
emit() { emit_once "$@" || true; }
# when the round began, in epoch seconds: set just before review_opened
ROUND_STARTED=''

# The run-mode checkout. The EXIT trap removes it on every exit the shell
# handles - success, failure, INT, TERM. A SIGKILL runs no trap, so the next
# run-mode round sweeps checkouts whose owning round is gone (sweep_checkouts).
CHECKOUT_ROOT=''; CHECKOUT=''; OWNER_LOCK_HELD=''
drop_checkout() {
  if [ -n "$OWNER_LOCK_HELD" ]; then
    { exec 9<&-; } 2>/dev/null || true
    OWNER_LOCK_HELD=''
  fi
  if [ -n "$CHECKOUT_ROOT" ] && checkout_is_free "$CHECKOUT_ROOT/owner"; then
    rm -rf "$CHECKOUT_ROOT"
  fi
  CHECKOUT_ROOT=''; CHECKOUT=''
}

# Mid-run activity refresh (T-036); never invents percent from lifecycle labels.
emit_status() {
  local en="$1" tw="$2" done_n="${3-}" total_n="${4-}" data
  if [ "${HERDR_ENV:-}" = 1 ]; then
    fm_herdr_emit_status "$REPO" "$NAME" "$TASK" "$en" "$tw" reviewer "$done_n" "$total_n" \
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

# Armed where emit() first works: every exit between the two would board
# an actor that never leaves. Above it is only the argument parsing,
# which exits 64 before emit() exists.
#
# One EXIT trap does the emitting; the signal traps only exit. Naming a
# signal alongside EXIT runs the handler and then CONTINUES, so a killed
# run announces it has finished and carries on working - and `kill`
# stops working on it, because a trapped TERM that does not exit leaves
# only SIGKILL. The codes are the conventional 128+signal.
#
# The ordinary emit is best-effort - a progress line the board misses
# costs an update - but the ending is not. `agent_finished` is what
# takes the crewman off the deck; lose it and the agent stands there
# until its task merges, which is the failure this pair exists to
# remove. So it is tried again, and if it still cannot be written the
# run says so rather than passing in silence. Both go through one
# definition of the command: two spellings of the same emit is how the
# ending and the progress lines drift apart.
finished() {
  local rc=$?
  fm_record_end "$rc"
  drop_checkout
  local try=3
  while [ "$try" -gt 0 ]; do
    try=$(( try - 1 ))
    emit_once --type agent_finished --en "run finished" --tw "這次執行結束" && { wake_verdict "$rc"; return 0; }
  done
  echo "${0##*/}: could not record the end of this run; ${NAME} stays on the deck until ${TASK} is finished" >&2
  wake_verdict "$rc"
}
# The verdict wakes firstmate (T-137), pushed by this round after its
# agent_finished: `review: T-134 APPROVE 4ea1ec2`, `review: T-134 REJECT
# 4ea1ec2`, or `review: T-134 no verdict exit 3` for a round that signed none.
wake_verdict() {
  [ -n "${NAME:-}" ] && [ -n "${TASK:-}" ] || return 0
  local line="review: $TASK ${decided:-no verdict}"
  [ -n "${decided:-}" ] || [ "$1" -eq 0 ] || line="$line exit $1"
  [ -z "${R_HEAD:-}" ] || line="$line ${R_HEAD:0:7}"
  fm_wake_push "$REPO" "$NAME" verdict "$line${PR:+ #$PR}" \
    "$(jq -cn --arg task "$TASK" --arg actor "$NAME" --arg verdict "${decided:-}" --arg head "${R_HEAD:-}" --argjson rc "$1" \
      '{task:$task, actor:$actor, verdict:$verdict, head:$head, rc:$rc}')"
}
trap finished EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
# Keep SIGHUP ignored (fm-config). Exiting on hangup orphans managed
# transport wait / durable last-result recovery / PR publish.
trap '' HUP

# Resolve an existing pin before any branch-owned task lookup. An absent pin
# keeps legacy unauthorised rounds readable; gate 4 will explicitly reject it.
FM_SPEC_PIN_JSON=''
FM_SPEC_PIN_JSON="$(fm_pin_existing "$TASK")"; pin_rc=$?
case "$pin_rc" in
  0) ;;
  3) echo 'fm-review: no pin; legacy task context is unapproved and gate 4 will refuse it' >&2 ;;
  *) exit "$pin_rc" ;;
esac
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
R_HEAD="$(git rev-parse --verify -q "$BRANCH^{commit}")" || R_HEAD=''
# Local refs alone never establish which external change GitHub will land.
# The shared binding reader fetches and compares both authoritative refs, and
# refuses a stale local task/base rather than overwriting unpublished work.
verify_review_head() {
  [ "$FM_EXTERNAL" = 1 ] || return 0
  [ -n "$PR" ] || { echo 'fm-review: external review requires --pr' >&2; return 65; }
  local verified
  verified="$(fm_binding head --task "$TASK" --pr "$PR" --branch "$BRANCH")" || return 65
  [ -n "$R_HEAD" ] && [ "$verified" = "$R_HEAD" ] || {
    echo 'fm-review: authoritative PR head moved; refresh before review' >&2; return 65; }
}
verify_review_head || exit 65
spec="$(task_spec "$TASK" "${R_HEAD:-$BRANCH}")"
[ -n "$spec" ] || { echo "fm-review: no task $TASK" >&2; exit 65; }
set_crew_activity "$spec"

# Said at the START of the actual review, not after the engine returns. The
# small spec lookup above supplies the authored brief and refuses a nonexistent
# task; the minutes-long engine invocation remains entirely bracketed by this
# event and agent_finished.
ROUND_STARTED="$(date +%s)"
emit --type review_opened --en "round $ROUND on $TASK" --tw "$TASK 第 $ROUND 輪審核"
emit_status "Review adapter starting on $TASK" "開始審核 $TASK"

# Read from the checkout running the round, like the reviewer's vendor: a
# branch under review does not get to choose how it is reviewed.
REVIEW_MODE="$(fm_cfg_in reviewer mode)"
case "${REVIEW_MODE:=diff}" in
  diff|run) ;;
  *)
    echo "fm-review: config.yaml's reviewer mode is '$REVIEW_MODE'; it must be diff or run" >&2
    emit --review-outcome infrastructure_error --type review_failed \
         --en "review round $ROUND could not start" --tw "第 $ROUND 輪審核無法開始"
    exit 65 ;;
esac
# Never inherited: a leftover run-mode setting would hand a diff round's
# adapter a checkout nobody made for it.
unset FM_RUN_REVIEW FM_REVIEW_CHECKOUT FM_REVIEW_NETWORK

# The round's permission policy (T-105), in either mode: config.yaml's, for
# a reviewer, with this project's override, read from the checkout running
# the round like the mode. Every adapter confines its CLI to it or refuses
# the round. The legacy `reviewer: network:` is checked first so its
# refusal reads as it always has.
bad_host="$(fm_review_network_refusal "$(fm_cfg_in reviewer network)")"
[ -z "$bad_host" ] || {
  echo "fm-review: config.yaml's reviewer network names $bad_host" >&2
  emit --review-outcome infrastructure_error --type review_failed \
       --en "review round $ROUND could not start" --tw "第 $ROUND 輪審核無法開始"
  exit 65; }
policy_file="$FM_RUN_DIR/policy.json"; blocked_file="$FM_RUN_DIR/blocked-hosts"
: > "$blocked_file"
fm_policy reviewer "" "$FM_CONFIG" > "$policy_file" || {
  echo "fm-review: config.yaml's crew policy does not read; no round runs without one" >&2
  emit --review-outcome infrastructure_error --type review_failed \
       --en "review round $ROUND could not start" --tw "第 $ROUND 輪審核無法開始"
  exit 65; }
export FM_POLICY="$policy_file" FM_POLICY_BLOCKED="$blocked_file"
# config.yaml's model, applied (T-127): each vendor's own (T-146), which
# fm_run_chain resolves for whichever vendor an attempt runs - --vendor's,
# or a fallback's - and hands it as FM_MODEL; a refusal it writes is
# recorded here rather than read as the vendor being unavailable.
export FM_MODEL_ROLE=reviewer FM_MODEL_CONFIG="$FM_CONFIG"
model_refused_file="$FM_RUN_DIR/model-refused"; : > "$model_refused_file"
export FM_MODEL_REFUSED="$model_refused_file"
# The operator's escape hatch for a sandbox regression (T-117): only their
# own shell's FM_CREW_UNSANDBOXED=1, never inside a round. Said on stderr
# here, and in the round's log and on the board once the round starts.
unsandboxed=0
if fm_crew_hatch fm-review; then unsandboxed=1; fi

# What this round reviews, pinned once: the head, its merge-base with the
# base, the patch-id of the change between them and the files it touches.
# The verdict carries all four in its REVIEWED line, and gate 7 carries an
# APPROVE across an update onto a newer base only when the change is the
# same one (T-113). The patch-id comes from plumbing, which reads no user
# configuration, with renames off, exactly as fm-gate.sh takes it.
R_BASE=''; R_PATCH=''; R_FILES=''
if [ -n "$R_HEAD" ] && R_BASE="$(git merge-base "$BASE" "$R_HEAD" 2>/dev/null)"; then
  R_PATCH="$(git diff-tree -r -p --no-renames "$R_BASE" "$R_HEAD" 2>/dev/null | git patch-id --stable | cut -d' ' -f1)"
  R_FILES="$(git diff-tree -r -z --name-only --no-renames "$R_BASE" "$R_HEAD" 2>/dev/null |
    jq -Rsc 'split("\u0000") | map(select(length > 0))')" || R_FILES=''
else
  R_BASE=''
fi

# A clone rather than a worktree: a worktree shares the task's .git, so git
# run inside it writes outside it. The clone has its own objects, the base
# and the head under fixed names, and no remote to push to.
build_checkout() {
  local head staging staging_base
  head="$R_HEAD"
  [ -n "$head" ] && [ -n "$R_BASE" ] || return 1
  # Built under a name sweep_checkouts never globs (it matches only
  # fm-review.*, and this starts with a dot, which that pattern's literal
  # "fm-review." prefix cannot match) and renamed into that name only once
  # this round's own kernel flock on its owner file is held. A bare mktemp
  # straight under the visible name leaves a window between the owner file
  # existing and being locked, in which a concurrent sweep's own
  # non-blocking flock on that same file succeeds - nobody holds it yet -
  # and it removes the checkout out from under this round before this round
  # gets to it (T-123 review round 2). Staging first, and making the
  # directory visible under fm-review.* only by a same-filesystem rename
  # after the lock is already held, closes that window rather than
  # narrowing it: sweep_checkouts can never see this checkout before its
  # lock exists.
  staging="$(mktemp -d "${REVIEW_TMP:-${TMPDIR:-/tmp}}/.fm-review-staging.XXXXXX")" || return 1
  staging="$(cd "$staging" && pwd -P)" || return 1
  printf '%s\n' "$$" > "$staging/owner" || { rm -rf "$staging"; return 1; }
  exec 9<>"$staging/owner" || { rm -rf "$staging"; return 1; }
  perl -MFcntl=:flock -e 'open(my $l, "<&=", 9) or exit 2;
    exit(flock($l, LOCK_EX | LOCK_NB) ? 0 : 1)' || {
    { exec 9<&-; } 2>/dev/null; rm -rf "$staging"; return 1; }
  staging_base="${staging##*/}"
  CHECKOUT_ROOT="${staging%/*}/fm-review.${staging_base#.fm-review-staging.}"
  if [ -e "$CHECKOUT_ROOT" ] || ! mv "$staging" "$CHECKOUT_ROOT"; then
    { exec 9<&-; } 2>/dev/null; rm -rf "$staging"; CHECKOUT_ROOT=""; return 1
  fi
  OWNER_LOCK_HELD=1
  printf '%s\n' "$FM_RUN_DIR" > "$CHECKOUT_ROOT/run"
  CHECKOUT="$CHECKOUT_ROOT/checkout"
  git clone -q --no-checkout --no-hardlinks "${FM_TARGET_ROOT:-$REPO}" "$CHECKOUT" &&
    git -C "$CHECKOUT" fetch -q --no-tags origin "+$R_HEAD:refs/fm/head" "+$R_BASE:refs/fm/base" &&
    [ "$(git -C "$CHECKOUT" rev-parse refs/fm/head)" = "$head" ] &&
    git -C "$CHECKOUT" checkout -q --detach refs/fm/head &&
    git -C "$CHECKOUT" remote remove origin
}
# A checkout left by a round that was SIGKILLed: nothing holds its owner
# file's lock any more. One with no owner file may be a round between
# mktemp and writing it, and one still locked is in use; both are left
# alone. Tested by trying to take the same lock, non-blocking: acquiring it
# proves nobody holds it, and releasing it again straight after costs
# nothing, since nothing here needs to keep it. Never `kill -0` on the pid
# recorded in the file (see build_checkout) - that misreads a live round the
# sandbox denies a signal to as a dead one, and deletes a checkout in use.
checkout_is_free() {   # checkout_is_free <owner-file>
  # Managed descendants retain their checkout even after the launcher's lock
  # closes. Uncertain reservations also retain it; no PID polling is involved.
  local run_file="${1%/*}/run"
  if [ -f "$run_file" ]; then
    python3 - "${FM_CODE_ROOT:-$REPO}" "$(cat "$run_file")" <<'PYLIVE' || return 1
import importlib.util, pathlib, sys
sys.dont_write_bytecode = True
spec = importlib.util.spec_from_file_location('managed', pathlib.Path(sys.argv[1]) / 'bin/fm-herdr.py')
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
try:
    states = m.executions(sys.argv[2])
    sys.exit(1 if any(s['state'] != 'terminated' for s in states) else 0)
except (OSError, ValueError, KeyError):
    sys.exit(1)
PYLIVE
  fi
  perl -MFcntl=:flock -e 'open(my $l, "<", $ARGV[0]) or exit 2;
    exit(flock($l, LOCK_EX | LOCK_NB) ? 0 : 1)' "$1"
}
# checkout_ok: 0 unless run mode's checkout has been destroyed mid-round -
# gone, or its .git no longer answers (T-128). Review checkouts are
# disposable, unlike a worker's branch: there is nothing in one worth
# mirroring, only worth noticing and rebuilding.
checkout_ok() {
  [ "$REVIEW_MODE" = run ] || return 0
  [ -d "$CHECKOUT" ] && git -C "$CHECKOUT" rev-parse -q --verify HEAD >/dev/null 2>&1
}
# rebuild_checkout: build_checkout again, at the SAME CHECKOUT_ROOT/CHECKOUT
# path - never a fresh mktemp - because the prompt already names that path
# in its "Run mode" section; a new path there would send the reviewer to a
# directory that was never built. Goes through the same staging + flock
# dance build_checkout does: the old fd 9 (if any) is dropped first, so a
# concurrent sweep_checkouts (T-123) checking the old owner file's lock
# never blocks on this round, and the new owner file's lock is held before
# the directory is renamed into the visible name.
rebuild_checkout() {
  local head staging
  head="$R_HEAD"
  [ -n "$head" ] && [ -n "$R_BASE" ] || return 1
  if [ -n "$OWNER_LOCK_HELD" ]; then
    { exec 9<&-; } 2>/dev/null || true
    OWNER_LOCK_HELD=''
  fi
  checkout_is_free "$CHECKOUT_ROOT/owner" || return 1
  rm -rf "$CHECKOUT_ROOT"
  staging="$(mktemp -d "${REVIEW_TMP:-${TMPDIR:-/tmp}}/.fm-review-staging.XXXXXX")" || return 1
  staging="$(cd "$staging" && pwd -P)" || return 1
  printf '%s\n' "$$" > "$staging/owner" || { rm -rf "$staging"; return 1; }
  exec 9<>"$staging/owner" || { rm -rf "$staging"; return 1; }
  perl -MFcntl=:flock -e 'open(my $l, "<&=", 9) or exit 2;
    exit(flock($l, LOCK_EX | LOCK_NB) ? 0 : 1)' || {
    { exec 9<&-; } 2>/dev/null; rm -rf "$staging"; return 1; }
  if ! mv "$staging" "$CHECKOUT_ROOT"; then
    { exec 9<&-; } 2>/dev/null; rm -rf "$staging"; return 1
  fi
  OWNER_LOCK_HELD=1
  printf '%s\n' "$FM_RUN_DIR" > "$CHECKOUT_ROOT/run"
  CHECKOUT="$CHECKOUT_ROOT/checkout"
  git clone -q --no-checkout --no-hardlinks "${FM_TARGET_ROOT:-$REPO}" "$CHECKOUT" &&
    git -C "$CHECKOUT" fetch -q --no-tags origin "+$R_HEAD:refs/fm/head" "+$R_BASE:refs/fm/base" &&
    [ "$(git -C "$CHECKOUT" rev-parse refs/fm/head)" = "$head" ] &&
    git -C "$CHECKOUT" checkout -q --detach refs/fm/head &&
    git -C "$CHECKOUT" remote remove origin
}
sweep_checkouts() {
  local d
  for d in "$REVIEW_TMP"/fm-review.*; do
    [ -d "$d" ] && [ -f "$d/owner" ] || continue
    checkout_is_free "$d/owner" && rm -rf "$d"
  done
}
if [ "$REVIEW_MODE" = run ]; then
  emit_status "Preparing a fresh checkout of $BRANCH" "正在準備 $BRANCH 的全新 checkout"
  sweep_checkouts
  # The sandbox reaches only these hosts: what `setup` needs, declared by the
  # policy the checkout running the round resolves. No GitHub host belongs
  # here, since the network is what keeps a push or a gh write from leaving
  # the sandbox; fm_policy has refused one, and loopback, above.
  FM_REVIEW_NETWORK="$(python3 -c 'import json,sys; print(" ".join(json.load(open(sys.argv[1]))["network"]))' \
    "$policy_file")"; export FM_REVIEW_NETWORK
  build_checkout >/dev/null 2>&1 || {
    echo "fm-review: could not make a fresh checkout of $BRANCH against $BASE for a run-mode review" >&2
    emit --review-outcome infrastructure_error --type review_failed \
         --en "review round $ROUND could not prepare its checkout" --tw "第 $ROUND 輪審核無法準備 checkout"
    exit 70; }
  export FM_RUN_REVIEW=1 FM_REVIEW_CHECKOUT="$CHECKOUT"
  export FM_REVIEW_HEAD="$R_HEAD" FM_REVIEW_BASE="$R_BASE" FM_REVIEW_PATCH="$R_PATCH"
  printf '%s\n' "$FM_RUN_DIR" > "$CHECKOUT_ROOT/run"
  # The project's setup writes its caches under $HOME by default, where the
  # sandbox refuses it. The adapter points each one into the round's own
  # temp directory, a write root, for every round of either role (T-117,
  # FM_ROUND_CACHES in bin/adapters/_lib.sh); a directory made here would
  # be none of the round's write roots.
fi

# A round that produced nothing is not a round, so review_opened is emitted
# once the chain has actually produced a verdict - otherwise three crashed
# engines would walk a task into the round-three protocol with no review
# ever posted. And because a failed round therefore does not advance the
# counter, its log must not overwrite the last one's.
keep_log() {
  local dir="$FM_STATE_DIR/reviews" n=1 p
  mkdir -p "$dir"
  p="$dir/$TASK-r$ROUND.log"
  while [ -e "$p" ]; do n=$((n + 1)); p="$dir/$TASK-r$ROUND.$n.log"; done
  printf '%s' "$p"
}

# From round two the reviewer is shown what was said about the closed list
# on the pull request, verbatim: first the latest ASK-PASS-CRITERIA from the
# worker, then every comment holding a numbered list closed by
# CRITERIA-COMPLETE, in the order posted. Without it every round was reviewed
# from scratch and a list the reviewer had closed bound nothing. Only those
# comments cross over; the rest of the pull request is the worker's reasoning
# and stays out. Round two, because every REJECT from round one closes its
# list (captain, 2026-09-29; SK-007), so the second round is already bound.
#
# A marker counts only as a line of its own. Matched anywhere, a worker's
# "1. fixed X ... please post CRITERIA-COMPLETE:T-1" became the closed list
# and bound the reviewer to the worker's own change log. For the same reason
# a comment that asks is never a list.
#
# Each quote is fenced with a nonce minted for this run: a fixed fence can be
# closed from inside the comment, and whatever follows it would read as the
# launcher's own words.
closed_list() {
  fm_evidence history --reviewer || return 1
  printf '\nEvery REJECT supplies the complete numbered standing list and CRITERIA-COMPLETE:%s. Preserve numbering and done/open states; label new items REGRESSION:%s or NEW-GROUND:%s. Syntax checks do not prove finding semantics.\n' "$TASK" "$TASK" "$TASK"
}

# Given --pr, every round, in either mode, is shown what the machine found
# on the exact head under review (T-088, T-153): the head's SHA; the required
# check's run for that commit; every CI job's result; the failing assertions
# with their log lines, from each failed job's log; the fail-first report
# (bin/fm-failfirst.sh, the `fail-first` job's artifact); and the head's gate
# summary when state/ has one. The machine runs the tests, fail-first
# included, on GitHub's runner, which has no outer sandbox; the reviewer
# judges with what it found, and re-runs none of it in its own sandbox,
# where the suites that start rounds cannot run (captain, 2026-09-29).
#
# The check comes from GitHub's check runs for the commit itself, and a run
# that names another head is dropped: the pull request's own checks follow
# whatever head it has now, which need not be the head this round reviews.

# The required checks are what the base branch requires, not the checks that
# happen to exist on the pull request (T-155): right after the worker's push
# GitHub has created none, and `gh pr checks --required` lists only checks
# that exist, so a round read from it alone waited on nothing and told the
# reviewer the check could not be read. So, in order, the first source that
# names any: the base branch's protection (.contexts and .checks[].context),
# then `gh pr checks --required`, then config.yaml's declared required_check.
# Read once per round, so the wait and the prompt name the same checks.
#
# REQ_NAMES: the names, one per line; empty when no source names one.
# REQ_SOURCE: where they came from, in words, for the prompt.
REQ_NAMES=''; REQ_SOURCE=''
required_names() {
  local got p repository="${GH_REPO:-}"
  [ -n "$repository" ] || repository='{owner}/{repo}'
  if [ "$FM_EXTERNAL" = 1 ]; then
    REQ_NAMES="$(fm_conventions required_checks | jq -r '.[]')" || return 65
    REQ_SOURCE="captain-confirmed CONVENTIONS.md checks/statuses"
    return 0
  fi
  if got="$($GH api "repos/$repository/branches/$BASE/protection/required_status_checks" 2>/dev/null </dev/null)"; then
    REQ_NAMES="$(jq -r '(.contexts[]?, .checks[]?.context) | strings' <<<"$got" 2>/dev/null | awk 'NF && !s[$0]++')"
    REQ_SOURCE="the protection of the base branch $BASE"
    [ -z "$REQ_NAMES" ] || return 0
  fi
  # From the output, not the exit status: gh's exit code reports the checks'
  # state, and a red check is exactly what must be shown.
  REQ_NAMES="$(fm_github pr checks "$PR" --required --json name --jq '.[].name' 2>/dev/null </dev/null | awk 'NF && !s[$0]++')"
  REQ_SOURCE="the pull request's required checks"
  [ -z "$REQ_NAMES" ] || return 0
  p="$(fm_project_resolve "" "$FM_CONFIG" 2>/dev/null)" &&
    REQ_NAMES="$(fm_project_get "$p" required_check "$FM_CONFIG" 2>/dev/null | awk 'NF && !s[$0]++')" || REQ_NAMES=''
  REQ_SOURCE="config.yaml's required_check"
  [ -n "$REQ_NAMES" ] || REQ_SOURCE=''
}
# check_runs_of <sha> <query>: GitHub's check runs for that commit, as it
# answers them; status 1 when gh could not, or answered something else
check_runs_of() {
  local got repository="${GH_REPO:-}"
  [ -n "$repository" ] || repository='{owner}/{repo}'
  if [ "$FM_EXTERNAL" = 1 ] && [[ "$2" == check_name=* ]]; then
    python3 "$_fm_code_dir/lib/fm_project_checks.py" "$GH_REPO" "$1" "$2"
    return $?
  fi
  got="$($GH api "repos/$repository/commits/$1/check-runs?$2" 2>/dev/null </dev/null)" || return 1
  jq -e '.check_runs | type == "array"' >/dev/null 2>&1 <<<"$got" || return 1
  printf '%s' "$got"
}

# The reviewer starts once the head's required checks have finished, so it
# is handed their results rather than a run still going (T-153): every
# required check whose runs for this head GitHub answers is waited on until
# its latest run for the head is completed, for at most FM_REVIEW_CI_WAIT
# seconds (default 1200), asked every FM_REVIEW_CI_POLL (default 30). A
# required check with no run for the head yet is waited on as missing (T-155).
# A check whose runs cannot be read is not waited on - it is said to be
# unknown - and nothing is waited on without --pr, or when no source names a
# required check, which the prompt then says. What is still running when the
# bound is reached is said in the prompt, by name.
CI_WAITED=0; CI_PENDING=''
# These are phase transitions, not heartbeats. Emit directly even under
# Herdr (its activity helper has no phase field), without coalescing away
# a changed check list or the transition back to the review.
emit_ci_phase() {
  local phase="$1" en="$2" tw="$3" bound="${4:-false}" data
  data="$(jq -cn --arg phase "$phase" --arg en "$en" --arg tw "$tw" \
    --arg pending "$CI_PENDING" --argjson bound "$bound" \
    '{phase:$phase,window_expected:($phase != "waiting_ci"),ci_pending:$pending,
      ci_wait_bound:$bound,activity:{en:$en,"zh-TW":$tw}}')"
  FM_CREW_STATUS_SECS=0 emit_once --type crew_status --data "$data" --en "$en" --tw "$tw" || true
}
ci_wait() {
  local sha names name runs status start now told=''
  sha="$R_HEAD"; [ -n "$sha" ] || return 0
  names="$REQ_NAMES"; [ -n "$names" ] || return 0
  start="$(date +%s)"
  while :; do
    CI_PENDING=''
    while IFS= read -r name; do
      runs="$(check_runs_of "$sha" "check_name=$(jq -rn --arg n "$name" '$n|@uri')")" || continue
      status="$(jq -r --arg sha "$sha" --arg name "$name" '
        [.check_runs[] | select(.head_sha == $sha and .name == $name)] | max_by(.id) // {} | .status // "missing"
      ' <<<"$runs" 2>/dev/null)"
      [ "$status" = completed ] || CI_PENDING="${CI_PENDING:+$CI_PENDING, }$name"
    done <<<"$names"
    now="$(date +%s)"; CI_WAITED=$((now - start))
    [ -n "$CI_PENDING" ] || break
    if [ "$CI_PENDING" != "$told" ]; then
      told="$CI_PENDING"
      emit_ci_phase waiting_ci "Waiting for CI on $TASK's head before the review: $CI_PENDING" \
        "審核前等待 $TASK 的 CI 完成：$CI_PENDING"
    fi
    if [ "$CI_WAITED" -ge "$CI_WAIT" ]; then
      emit_ci_phase waiting_ci "CI wait bound reached on $TASK after ${CI_WAITED}s; still pending: $CI_PENDING. Starting review." \
        "$TASK 的 CI 等待已達上限（${CI_WAITED} 秒）；仍待完成：${CI_PENDING}。即將開始審核。" true
      break
    fi
    sleep "$(( CI_WAIT - CI_WAITED < CI_POLL ? CI_WAIT - CI_WAITED : CI_POLL ))"
  done
}

# failed_lines <job id>: a failed job's failing assertions and the lines
# around them, from its log: each assertion line ending FAIL with the detail
# line under it, each red suite or stage (`  x ...`), and the runner's own
# errors - timestamps and colour codes off, at most 80 lines.
failed_lines() {
  local log
  log="$(fm_github run view --job "$1" --log-failed 2>/dev/null </dev/null)" || return 1
  printf '%s\n' "$log" | sed -E $'s/\033\\[[0-9;]*m//g; s/^[^\t]*\t[^\t]*\t//; s/^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9:.]+Z ?//' |
    awk '/FAIL[[:space:]]*$/ { print; d = 1; next }
         d && /^      / { print; d = 0; next }
         { d = 0 }
         /^[[:space:]]*x / || /##\[error\]/ { print }' | head -n 80
}

head_evidence() {
  local sha names name runs shown fence all lines rid dir
  printf '\n# The head under review\n'
  sha="$R_HEAD"
  if [ -z "$sha" ]; then
    printf '\nThe head of %s could not be resolved, so no CI or gate result can be tied to it.\n' "$BRANCH"
    return 0
  fi
  printf '\nHead SHA: %s\n' "$sha"
  if [ -n "$CI_PENDING" ]; then
    printf '\nThis round waited %s seconds for CI, its bound, and started with these required checks still running for this head, or not yet started: %s. Their results below are not final.\n' \
      "$CI_WAITED" "$CI_PENDING"
  elif [ "$CI_WAITED" -gt 0 ]; then
    printf '\nThis round waited %s seconds for the required checks to finish for this head before it started.\n' "$CI_WAITED"
  fi
  printf '\n## The required check for this head, from GitHub\n'
  names="$REQ_NAMES"
  if [ -z "$names" ]; then
    printf '\nThe required check for head %s could not be read from GitHub, so its CI result is unknown.\n' "$sha"
    printf '\nNo source named any required check - not the protection of the base branch %s, not the pull request'"'"'s required checks, not config.yaml'"'"'s required_check - so this round did not wait for CI before it started.\n' "$BASE"
  else
    printf '\nRequired checks, from %s: %s.\n' "$REQ_SOURCE" "$(paste -sd, - <<<"$names" | sed 's/,/, /g')"
    while IFS= read -r name; do
      if ! runs="$(check_runs_of "$sha" "check_name=$(jq -rn --arg n "$name" '$n|@uri')")"; then
        printf '\nThe runs of the required check %s for head %s could not be read from GitHub, so its CI result for this head is unknown.\n' "$name" "$sha"
        continue
      fi
      shown="$(jq -r --arg sha "$sha" --arg name "$name" '
        [.check_runs[]? | select(.head_sha == $sha and .name == $name)] | max_by(.id) // empty
        | "Required check: \(.name)\nConclusion: \(.conclusion // "none yet, status \(.status)")\nRun: \(.details_url // .html_url)"
      ' <<<"$runs" 2>/dev/null)"
      if [ -n "$shown" ]; then
        printf '\n%s\n' "$shown"
      else
        printf '\nNo run of the required check %s was found for head %s, so its CI result for this head is unknown.\n' "$name" "$sha"
      fi
    done <<<"$names"
  fi
  # Every job, not only the required one: `ci` only says that some job
  # failed, and which one is what the reviewer needs. The latest run of each
  # name for exactly this head.
  # Unread, each of the three sections still stands and says what was not
  # fetched: a missing section would read as "nothing failed".
  printf '\n## Every CI job for this head\n'
  if ! runs="$(check_runs_of "$sha" "per_page=100")"; then
    printf '\nThe CI jobs of head %s could not be read from GitHub, so their results are unknown.\n' "$sha"
    printf '\n## Failing assertions, from the failed jobs'"'"' logs\n'
    printf '\nNot available: the CI jobs of head %s could not be read, so which assertions failed is unknown.\n' "$sha"
    printf '\n## The fail-first report\n'
    printf '\nNot available: the CI jobs of head %s could not be read, so no fail-first report was fetched.\n' "$sha"
  else
    all="$(jq -c --arg sha "$sha" '[.check_runs[] | select(.head_sha == $sha)] | group_by(.name) | map(max_by(.id)) | sort_by(.name)' <<<"$runs")"
    if [ "$(jq 'length' <<<"$all")" = 0 ]; then
      printf '\nNo CI job has run for head %s yet.\n' "$sha"
    else
      printf '\n'
      jq -r '.[] | "- \(.name): \(.conclusion // "none yet, status \(.status)") (\(.details_url // .html_url))"' <<<"$all"
    fi
    printf '\n## Failing assertions, from the failed jobs'"'"' logs\n'
    fence="$(od -An -N8 -tx1 /dev/urandom | tr -d ' \n')"
    if [ "$(jq '[.[] | select(.conclusion == "failure" or .conclusion == "timed_out")] | length' <<<"$all")" = 0 ]; then
      printf '\nNo CI job failed for this head.\n'
    fi
    while IFS=$'\t' read -r id name; do
      [ -n "$id" ] || continue
      if ! lines="$(failed_lines "$id")"; then
        printf '\nThe log of the failed job %s could not be read from GitHub.\n' "$name"
      elif [ -z "$lines" ]; then
        printf '\nThe failed job %s logged no failing assertion line; read its log for why.\n' "$name"
      else
        printf '\n%s, verbatim from its log (trimmed to the failing lines):\n\n----- begin log %s -----\n%s\n----- end log %s -----\n' \
          "$name" "$fence" "$lines" "$fence"
      fi
    done < <(jq -r '.[] | select(.conclusion == "failure" or .conclusion == "timed_out") | "\(.id)\t\(.name)"' <<<"$all")
    # The fail-first report is the fail-first job's artifact; the job's run
    # is the one its details URL names.
    printf '\n## The fail-first report\n'
    rid="$(jq -r '.[] | select(.name == "fail-first") | (.details_url // .html_url // "") | capture("/actions/runs/(?<r>[0-9]+)").r // empty' <<<"$all" 2>/dev/null)"
    dir="$work/fail-first"
    if [ -z "$(jq -r '.[] | select(.name == "fail-first") | .name' <<<"$all")" ]; then
      printf '\nNo fail-first job has run for head %s, so there is no fail-first report.\n' "$sha"
    elif [ -n "$rid" ] && rm -rf "$dir" && mkdir -p "$dir" &&
         fm_github run download "$rid" -n fail-first-report -D "$dir" >/dev/null 2>&1 </dev/null &&
         [ -s "$dir/fail-first.md" ]; then
      printf '\nFrom the fail-first job'"'"'s artifact, verbatim:\n\n----- begin fail-first report %s -----\n' "$fence"
      cat "$dir/fail-first.md"
      [ -z "$(tail -c1 "$dir/fail-first.md")" ] || printf '\n'
      printf -- '----- end fail-first report %s -----\n' "$fence"
    else
      printf '\nThe fail-first job ran for head %s (%s), but its report could not be read from GitHub.\n' \
        "$sha" "$(jq -r '.[] | select(.name == "fail-first") | .conclusion // "none yet, status \(.status)"' <<<"$all")"
    fi
  fi
  printf '\n## The gates for this head\n'
  # The whole file, unfiltered: a filter shows a summary in any other shape
  # as an empty quote that neither reports results nor says they are missing.
  # What is not there is then said by gate - fm-gate.sh stops at the first
  # red one, so a summary can end early, and an empty one lacks all six. The
  # numbers are fm-gate.sh's own: 3 is retired (T-114).
  local summary="$FM_STATE_DIR/gates/$TASK-$sha.txt" n lacking=''
  if [ -f "$summary" ]; then
    fence="$(od -An -N8 -tx1 /dev/urandom | tr -d ' \n')"
    printf '\nFrom state/gates/%s-%s.txt, verbatim:\n\n----- begin gate summary %s -----\n' "$TASK" "$sha" "$fence"
    cat "$summary"
    [ -z "$(tail -c1 "$summary")" ] || printf '\n'
    printf -- '----- end gate summary %s -----\n' "$fence"
    for n in 1 2 4 5 6 7; do
      grep -Eq "^[[:space:]]*[+x] gate $n: " "$summary" || lacking="${lacking:+$lacking, }$n"
    done
    [ -z "$lacking" ] ||
      printf '\nThe gate summary for head %s has no result line for gates: %s, so those results are unknown.\n' "$sha" "$lacking"
  else
    printf '\nNo gate summary for head %s exists under state/gates/, so its gate results are unknown.\n' "$sha"
  fi
}

reviewed_line() {  # reviewed_line <APPROVE|REJECT>
  [ -n "$R_HEAD" ] && [ -n "$R_BASE" ] && [ -n "$R_FILES" ] || return 0
  printf '\n\nREVIEWED:%s verdict=%s head=%s base=%s patch=%s files=%s' \
    "$TASK" "$1" "$R_HEAD" "$R_BASE" "$R_PATCH" "$R_FILES"
}

work="$FM_RUN_DIR/review"
mkdir -p "$work"
prompt="$work/prompt.md"
# the head's required checks first, bounded, so the prompt carries their
# results (T-153); nothing to wait on without a pull request. The names are
# read once, from what the base requires (T-155)
[ -z "$PR" ] || { required_names; ci_wait; }
verify_review_head || exit 65
{
  cat "${FM_CODE_ROOT:-$REPO}/skills/reviewer/SKILL.md"
  if [ -n "$FM_SPEC_PIN_JSON" ]; then fm_pin_prompt
  else fm_conventions_prompt || exit 65; fi
  printf '\n---\n\n# The task\n\n```json\n%s\n```\n' "$spec"
  printf '\n# Round %s\n' "$ROUND"
} > "$work/intro.md"
{
  if [ "$ROUND" -ge 2 ]; then
    printf '\n# The closed list\n'
    closed_list
  elif [ "$ROUND" -ge 3 ]; then
    printf '\nThis is round three or later. If the worker has posted ASK-PASS-CRITERIA, answer with the complete numbered list and then post CRITERIA-COMPLETE:%s.\n' "$TASK"
  fi
} > "$work/history.md"
{
  # Either mode: the reviewer judges with what CI found on this head, and
  # re-runs none of it (T-153, captain 2026-09-29)
  [ -z "$PR" ] || head_evidence
} > "$work/evidence.md"
{
  printf '\n---\n\n# The diff under review\n\n```diff\n'
  # the change the REVIEWED line names, not whatever the branch is by now
  if [ -n "$R_BASE" ]; then git diff "$R_BASE" "$R_HEAD"; else printf "The pinned head or merge-base could not be resolved; diff unavailable.\n"; fi
  printf '```\n'
} > "$work/diff.md"
: > "$work/outro.md"

# The project's contract as the branch under review declares it - the one the
# gates run - so the reviewer runs what the required check and gate 5 would.
contract_line() {   # contract_line <field>
  local v
  if ! v="$(fm_project "$1" "$CHECKOUT/config.yaml" 2>/dev/null | tr '\0\n' '  ')"; then
    v='(config.yaml could not be read)'
  fi
  v="${v% }"
  printf -- '- `%s`: %s\n' "$1" "${v:-(not declared)}"
}
if [ "$REVIEW_MODE" = run ]; then
  {
    printf '\n---\n\n# Run mode\n\n'
    printf 'This round runs in a fresh clone of the pull request head, made for this review\n'
    printf 'and removed when it ends: `%s`. It is your working directory.\n' "$CHECKOUT"
    printf '`fm/head` is the head under review, checked out detached; `fm/base` is %s.\n' "$BASE"
    printf '`git diff fm/base...fm/head` is the diff above.\n\n'
    printf 'You may run small commands here to check a claim: reading, grepping, git, a\n'
    printf 'single script invocation that needs no second sandbox.\n'
    printf 'You may not push, comment on or edit the pull request, touch the task'"'"'s\n'
    printf 'worktree, or write anywhere but this checkout and the round'"'"'s own temp directory.\n'
    printf 'The engine'"'"'s own permissions enforce that, not this text; fm-review.sh posts\n'
    printf 'your verdict to the pull request. Commands reach the network only for these\n'
    printf 'hosts: %s. No GitHub host is among them, so gh has nothing to talk to; the\n' "${FM_REVIEW_NETWORK:-none}"
    printf 'base, the head and the diff are all in this checkout. The tests have been run\n'
    printf 'by the machine: the head section above carries what CI found on this head -\n'
    printf 'each job'"'"'s result, the failing assertions and the fail-first report - when\n'
    printf 'the round was given the pull request. Green CI and gates are still\n'
    printf 'firstmate'"'"'s merge gate, not a criterion of this review, so do not require\n'
    printf 'them or keep an item open for them; a red job points you at a defect you then\n'
    printf 'show from the diff. The\n'
    printf 'toolchain'"'"'s caches (XDG_CACHE_HOME, bun, Playwright, npm, pip, Go) point into\n'
    printf 'this round'"'"'s own temp directory ($TMPDIR), so `setup` writes where it may and\n'
    printf 'starts from empty caches: it downloads what it installs. A command the sandbox\n'
    printf 'refuses is the boundary working: report what it kept you from running, as\n'
    printf 'read, not run, rather than work around it. Run every command to completion in\n'
    printf 'the foreground: this round is one turn, which ends when your answer does, so a\n'
    printf 'job left running in the background is never checked on and never finishes\n'
    printf 'before the verdict is due.\n\n'
    printf 'The project'"'"'s contract, from this checkout'"'"'s config.yaml:\n\n'
    for f in setup check check_env tests test docs; do contract_line "$f"; done
    printf '\nDo this, in order:\n\n'
    printf '1. Read what CI found on this head, in the head section: each job'"'"'s\n'
    printf '   result, the failing assertions with their log lines, and the fail-first\n'
    printf '   report. Do not run the full `check`: it is the required GitHub check on\n'
    printf '   this same head, which firstmate verifies at the merge gate. Run no suite\n'
    printf '   that starts rounds, a board or a browser: the machine ran them where they\n'
    printf '   can run.\n'
    printf '2. Judge the diff against the spec with that evidence. Fail-first is not\n'
    printf '   yours to prove by hand: read the report, and challenge a test the change\n'
    printf '   relies on that it lists only as a guard - green on base too.\n'
    printf '3. Check a claim with a small command where reading is not enough: reading,\n'
    printf '   grepping, git, a single script invocation that needs no second sandbox.\n'
    printf '4. End with two lists before the verdict: **Executed** - every command you\n'
    printf '   ran and its result; **Read, not run** - every claim you checked only by\n'
    printf '   reading. Evidence you did not execute is never reported as executed.\n'
  } > "$work/outro.md"
fi

# References replacing an inline patch must resolve to the same commits the
# prompt and REVIEWED record pin, including after a checkout rebuild.
context_checkout_matches() {
  [ "$REVIEW_MODE" = run ] || return 0
  [ "$(git -C "$CHECKOUT" rev-parse HEAD 2>/dev/null)" = "$R_HEAD" ] &&
    [ "$(git -C "$CHECKOUT" merge-base refs/fm/base refs/fm/head 2>/dev/null)" = "$R_BASE" ]
}
restore_context_evidence() {
  [ -f "$work/evidence-path.txt" ] || return 0
  local archive
  archive="$(cat "$work/evidence-path.txt")"
  mkdir -p "$archive" &&
    cp "$work/intro.md" "$work/history.md" "$work/evidence.md" \
       "$work/diff.md" "$work/outro.md" "$work/pins.json" "$archive/"
}
if ! context_checkout_matches; then
  echo "fm-review: pinned context does not match the review checkout; no model called" >&2
  emit --review-outcome infrastructure_error --type review_failed \
       --en "Pinned review context does not match its checkout" \
       --tw "固定版本的審核內容與 checkout 不符"
  exit 65
fi

# T-165: bound the complete stock prompt before any model attempt. Preserve
# the source components for disclosed omissions; never summarize criteria.
jq -n --arg head "$R_HEAD" --arg base "$R_BASE" --arg patch "$R_PATCH" \
  --argjson files "${R_FILES:-[]}" \
  '{head:$head,base:$base,patch:$patch,files:$files}' > "$work/pins.json"
if ! python3 "$(dirname "${BASH_SOURCE[0]}")/lib/fm_review_context.py" \
    "$work" "$REVIEW_MODE" "${CHECKOUT:-}"; then
  emit --review-outcome infrastructure_error --type review_failed \
       --en "Review context exceeds its safe input budget or could not be assembled; no model called" \
       --tw "審核內容超過安全輸入上限或無法組合；未呼叫模型"
  exit 65
fi

# Capture trusted source hashes before any reviewer can run.
fm_evidence pin --head "$R_HEAD" --base "$R_BASE" --patch "$R_PATCH" \
  --run "$FM_RUN_DIR" --code "${FM_CODE_ROOT:-$REPO}" || exit 65

# the reviewer runs on its own engine when "$FM_CONFIG" names one, and falls
# back exactly the way the worker does - one chain, one runner
mkdir -p "$work/out"
# The reviewer's evidence: a verdict marker. A signed review IS the run's
# standard output, so a signature matcher calling it an outage would throw
# away the very thing it was asked for - and the next turn would read the
# same output and say the same thing, forever.
# only this attempt's bytes: its own output directory, and the part of the
# shared log it wrote. A vendor that died half way through must not sign on
# the next one's behalf.
# ONE definition of what an attempt produced, used by the predicate, by the
# verdict and by the kept log. There were three: the predicate read the out
# directory and the log together, the verdict took the out directory if it
# had anything at all in it, and the log only otherwise. A reviewer whose
# agent left a scratch file in its working directory therefore had its
# signed review - printed on stdout, in the log - thrown away for the
# scratch file, and the round repeated for ever.
#
# No pipeline in it either: with `set -o pipefail` a cat that finds nothing
# fails the whole pipeline even when the grep matched.
attempt_output() {
  if [ "${FM_CHAIN_VENDOR:-}" = codex ]; then
    python3 - "${FM_CODE_ROOT:-$REPO}" "$FM_RUN_DIR" "${FM_CHAIN_ATTEMPT:-}" <<'PYFINAL'
import importlib.util, os, pathlib, sys
sys.dont_write_bytecode = True
spec = importlib.util.spec_from_file_location('managed', pathlib.Path(sys.argv[1]) / 'bin/fm-herdr.py')
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
sys.stdout.write(m.review_final(sys.argv[2], sys.argv[3], os.environ))
PYFINAL
    return
  fi
  if [ -n "${FM_CHAIN_ATTEMPT:-}" ] && [ -f "$FM_RUN_DIR/last-result.json" ] &&
     jq -e --arg attempt "$FM_CHAIN_ATTEMPT" '.chain_attempt == $attempt' "$FM_RUN_DIR/last-result.json" >/dev/null; then
    local final
    final="$(jq -r '.attempt' "$FM_RUN_DIR/last-result.json")/final.txt"
    [ ! -f "$final" ] || cat "$final"
    return 0
  fi
  { cat "${FM_RUN_OUTDIR:-$work/out}"/* 2>/dev/null
    tail -c "+$((${FM_RUN_LOG_OFF:-0} + 1))" "$work/log" 2>/dev/null; } || true
}
review_is_signed() {
  local seen; seen="$(attempt_output)"
  case "$seen" in *"APPROVE:$TASK"*|*"REJECT:$TASK"*) return 0 ;; esac
  return 1
}
adapters="${FM_CODE_ROOT:-$REPO}/bin/adapters"
chain="$(fm_vendor_chain reviewer "$VENDOR")"
# A crew round never runs on a login it did not check (T-121): every vendor
# in the chain that this probe recognises has the login its round would get
# checked right now, before any of them sees a prompt. Anything but
# `authenticated` - unauthenticated, expired, out of quota, or a login the
# probe could not confirm (gemini, a timeout) - is refused here, with the
# probe's status and reason on the board, rather than by starting a review
# inside the sandbox and failing there; the chain moves on to the next
# vendor.
auth_notes_file="$FM_RUN_DIR/auth-notes"
chain="$(fm_auth_filter_chain "${FM_CODE_ROOT:-$REPO}" "$chain" "$auth_notes_file")"
while IFS='|' read -r auth_v auth_status auth_en auth_tw; do
  [ -n "$auth_v" ] || continue
  echo "fm-review: $auth_v: $auth_status: $auth_en" >&2
  emit --type vendor_unavailable --en "$auth_v: $auth_status: $auth_en" \
    --tw "${auth_v}：${auth_status}：$auth_tw" </dev/null
done < "$auth_notes_file"
# A run-mode round goes only to an engine whose adapter can confine it. The
# reviewer's own vendor lacking that is a configuration error, said once;
# a fallback lacking it is simply not in this round's chain.
if [ "$REVIEW_MODE" = run ]; then
  lead="${chain%%$'\n'*}"
  chain="$(fm_review_run_chain "$adapters" "$chain")" || {
    echo "fm-review: $lead has no adapter that confines a run-mode review; choose another reviewer vendor or mode" >&2
    emit --review-outcome infrastructure_error --type review_failed \
         --en "review round $ROUND could not start" --tw "第 $ROUND 輪審核無法開始"
    rm -rf "$work"; exit 65; }
fi
# Preparation is complete: the adapter (and its window) starts now. Also
# leave the waiting phase here when the CI wait reached its bound.
if [ -n "$PR" ] && { [ "$CI_WAITED" -gt 0 ] || [ -n "$CI_PENDING" ]; }; then
  emit_ci_phase review "Review adapter starting on $TASK" "開始審核 $TASK"
fi
if [ "$unsandboxed" = 1 ]; then
  # ahead of every attempt's offset, so no verdict is read from it
  printf '%s\n' "fm-review: !!! FM_CREW_UNSANDBOXED=1: this round runs WITHOUT the OS sandbox !!!" >> "$work/log"
  emit_status "Reviewing $TASK WITHOUT the OS sandbox (FM_CREW_UNSANDBOXED)" \
    "正在審核 ${TASK}，未使用 OS 沙箱（FM_CREW_UNSANDBOXED）"
fi
# A round that ends its one turn with no signed verdict is retried once,
# automatically, before it is reported failed: a check a run-mode reviewer
# backgrounded and then waited on has ended the round's only turn with
# nothing signed three times (T-119 r1, T-119 r6, T-122 r2), and a headless
# round gets no later turn to check back on it. A second empty ending is
# reported exactly as the first always was; a genuinely broken engine fails
# the same way both times, so nothing changes for it but one more attempt.
# Codex admission requires a fresh tree. A previous engine may legitimately
# write scratch files, change tracked files, or fail after doing either.
# Refresh at the chain boundary, not only the unsigned retry, so fallback
# also gets the pinned checkout. rebuild_checkout refuses a live owner.
checkout_attempted=''
prepare_review_attempt() {
  local vendor="$1"
  if [ "$REVIEW_MODE" = run ] && [ "$vendor" = codex ] && [ -n "$checkout_attempted" ]; then
    if ! rebuild_checkout || ! context_checkout_matches || ! restore_context_evidence; then
      echo "fm-review: cannot refresh pinned checkout and context evidence for Codex" >&2
      return 70
    fi
  fi
  checkout_attempted=1
}
attempt_n=1
while :; do
fm_run_chain "$adapters" "$chain" \
  "$prompt" "$work/out" "$work/log" review_is_signed per-vendor prepare_review_attempt; rc=$?
# Review checkouts are disposable (T-128): when one is destroyed mid-round -
# by the round's own commands, deliberately or not - there is no mirror to
# restore from and none needed, only a fresh checkout at the same path the
# prompt already names, and the round retried once.
if ! checkout_ok; then
  echo "fm-review: the run-mode checkout was destroyed mid-round" >&2
  # bin/fm-emit.sh's TYPES enum is out of this task's scope and has no type
  # of its own for this; it rides worker_crashed, the type already carrying
  # bin/fm-worker.sh's own analogous worktree_restored, named the same way,
  # by .data.event_kind, not by .type.
  emit --type worker_crashed --en "the checkout was destroyed; retrying once with a fresh one" \
       --tw "checkout 被摧毀；用新的重試一次" --data '{"event_kind":"review_checkout_destroyed"}'
  if rebuild_checkout >/dev/null 2>&1 && context_checkout_matches && restore_context_evidence; then
    fm_run_chain "$adapters" "$chain" \
      "$prompt" "$work/out" "$work/log" review_is_signed per-vendor prepare_review_attempt; rc=$?
    checkout_ok || echo "fm-review: the fresh checkout was destroyed too; not retrying again" >&2
  else
    echo "fm-review: could not rebuild the checkout to retry $BRANCH after it was destroyed" >&2
  fi
fi
[ -z "$FM_VENDOR_UNKNOWN" ] || {
  echo "fm-review: $FM_CONFIG names a vendor with no adapter: $FM_VENDOR_UNKNOWN" >&2
  emit --review-outcome infrastructure_error --type review_failed \
       --en "review round $ROUND could not start" --tw "第 $ROUND 輪審核無法開始"
  rm -rf "$work"; exit 65; }
# A model the vendor did not recognise (T-127): refused loudly, named on the
# board in both languages, never read as the vendor being unavailable or as
# a review that simply produced nothing.
if [ -s "$model_refused_file" ]; then
  IFS=$'\t' read -r mr_vendor mr_model mr_msg < "$model_refused_file"
  echo "fm-review: $mr_msg" >&2
  emit --review-outcome infrastructure_error --type review_failed \
       --en "$mr_msg" --tw "${mr_vendor} 無法辨識模型「${mr_model}」；已拒絕這一輪"
  rm -rf "$work"; exit 65
fi
[ -z "$FM_VENDOR_MISREAD" ] || \
  echo "fm-review: $FM_VENDOR_MISREAD was read as unavailable, but it signed a verdict - keeping it" >&2
for v in $FM_VENDOR_SKIPPED; do
  emit --type vendor_unavailable --en "$v unavailable, trying the next" \
       --tw "$v 不可用，換下一家"
done
# A host the round's proxy refused is reported, never allowed: firstmate
# raises the choice card that adds it to the project's registries.
blocked_hosts="$(fm_policy_report "$REPO" reviewer "$TASK" "$NAME" "$blocked_file" "$policy_file")"
if [ -n "$blocked_hosts" ]; then
  echo "fm-review: the round was refused undeclared hosts: $blocked_hosts; adding one to the project's policy network is the captain's choice" >&2
  emit_status "Refused undeclared hosts: $blocked_hosts" "被拒的未宣告主機：${blocked_hosts}"
fi
verdict="$(attempt_output)"

# The chain says which of the two this was, and both callers read the same
# answer: rc 2 with nothing said is a vendor that was not there, and only
# that earns a 2. An engine that ran and said something unsigned is a
# failed round - exit 2 there would have fm-run retry the same input every
# turn, for ever. An outage is never retried below: a vendor that is not
# there will not be there a moment later either, so this exits the round
# straight away, same as ever.
if [ "$rc" = "2" ] && [ "${FM_VENDOR_SPOKE:-0}" = "0" ]; then
  kept="$(keep_log)"
  cp "$work/log" "$kept" 2>/dev/null || : > "$kept"
  echo "fm-review: every reviewer vendor was unavailable; their log is at $kept" >&2
  emit --review-outcome infrastructure_error --type review_failed \
       --en "review round $ROUND could not reach a reviewer" \
       --tw "第 $ROUND 輪審核無法連線至 reviewer"
  rm -rf "$work"; exit 2
fi
# What the round actually ran on, read from the run itself (T-127): recorded
# in identity.json beside name/role/project/task/round/attempt, and carried
# on every crew payload from here on the way those already are. A vendor
# whose own attempt exited 64+ never reached its CLI at all - a config
# error, a refused model, or, above fm_run_chain, an ownership-uncertain
# fallback pane (fm-herdr.py's own "retained" refusal) - so probing its
# binary for a version here would touch the vendor a refused round must
# never touch (a fallback model must not start; T-127 review round 2).
# The model requested is the one the vendor that ran was handed (T-146), and
# what it reports is read in its own transcript's shape (fm_vendor_model).
model_requested="${FM_VENDOR_MODEL:-}"
model_reported=''; cli_version='unknown'
if [ -n "$FM_VENDOR_USED" ] && [ "$rc" -lt 64 ]; then
  model_reported="$(fm_vendor_model "$work/log" "${FM_RUN_LOG_OFF:-0}" "$model_requested")"
  cli_version="$(fm_vendor_cli_version "$FM_VENDOR_USED")"
fi
python3 "${FM_CODE_ROOT:-$REPO}/bin/fm-herdr.py" record-model "$FM_RUN_DIR" "$FM_VENDOR_USED" \
  "$model_requested" "$model_reported" "$cli_version" >/dev/null 2>&1 || true
crew_refresh_identity
if [ -n "$model_requested" ] && [ -n "$model_reported" ] && [ "$model_reported" != "$model_requested" ]; then
  echo "fm-review: requested model $model_requested but $FM_VENDOR_USED ran on $model_reported" >&2
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
# a review that did not happen must never look like one that did. An empty
# verdict used to reach the pull request as the adapter's own log, and gate 7
# would then be reading a stack trace for a signature.
# A verdict has to be one of the two markers. Without that rule a crashed
# engine's stack trace on stdout is indistinguishable from a review, because
# a real reviewer's verdict IS its stdout.
signed=0
case "$verdict" in *"APPROVE:$TASK"*|*"REJECT:$TASK"*) signed=1 ;; esac
# When the managed transport waiter dies mid-chain, pane-child may still have
# published last-result/final.txt. Recover that durable verdict rather than
# claiming "no signed review".
if [ "$signed" = "0" ] && [ "${FM_CHAIN_VENDOR:-}" != codex ] && [ -n "${FM_RUN_DIR:-}" ] && [ -f "$FM_RUN_DIR/last-result.json" ] &&
   jq -e --arg attempt "${FM_CHAIN_ATTEMPT:-}" '$attempt != "" and .chain_attempt == $attempt' "$FM_RUN_DIR/last-result.json" >/dev/null; then
  recovered_final="$(jq -r '.attempt // empty' "$FM_RUN_DIR/last-result.json" 2>/dev/null)/final.txt"
  [ -f "$recovered_final" ] || recovered_final="$FM_RUN_DIR/final.txt"
  if [ -f "$recovered_final" ]; then
    recovered="$(cat "$recovered_final" 2>/dev/null || true)"
    case "$recovered" in
      *"APPROVE:$TASK"*|*"REJECT:$TASK"*)
        verdict="$recovered"
        signed=1
        echo "fm-review: recovered signed verdict from durable last-result" >&2
        ;;
    esac
  fi
fi
[ "$signed" = "1" ] && break
[ "${FM_VENDOR_SPOKE:-0}" = "1" ] || break
# Retrying is for an engine that ran and ended its turn with nothing signed -
# T-119/T-122's backgrounded check, which leaves a transcript with no verdict
# marker in it. It is never for a round that produced no output at all: a
# managed launch this round's own environment refused (changed focus, an
# uncertain pane, a caller that vanished) fails identically read twice, and
# retrying it can even let a stale refusal from the first attempt read as
# settled on the second (the environment "changed" once, then stays that
# way, so a fresh reading of it no longer differs from itself) - turning a
# real refusal into a false success instead of reporting it. FM_VENDOR_SPOKE
# is fm_run_chain's own answer to "did anything happen", set from bytes this
# attempt actually added to the log or its own output directory; nothing
# added means nothing to retry.
[ "$attempt_n" -ge 2 ] && break
attempt_n=$((attempt_n + 1))
echo "fm-review: round $ROUND ended with no signed verdict; retrying automatically (attempt $attempt_n)" >&2
emit_status "Round $ROUND had no verdict; retrying automatically" \
  "第 $ROUND 輪沒有裁決；自動重試中"
done
# An exit code does not overrule produced work - not here either. A CLI that
# prints a complete signed review and then exits non-zero on some teardown
# has still reviewed it, and throwing that away repeats the round for ever.
if [ "$signed" = "0" ]; then
  # Keep everything that was said, from wherever it came - the engine's log
  # and whatever it left in the output directory. The failure path is
  # exactly when someone needs to read it; only the success path may discard.
  kept="$(keep_log)"
  # the whole log here, not just this attempt's slice: on the failure path
  # every vendor's excuse is worth reading, and the attempt's own output is
  # already inside it
  { cat "$work/log" 2>/dev/null; attempt_output; } > "$kept"
  echo "fm-review: ${FM_VENDOR_USED:-the reviewer} produced no review (exit $rc); its log is at $kept" >&2
  if [ "$rc" = 0 ]; then outcome=missing_review; else outcome=infrastructure_error; fi
  emit --review-outcome "$outcome" --type review_failed \
       --en "review round $ROUND produced no signed review" \
       --tw "第 $ROUND 輪審核沒有已簽署的結果"
  rm -rf "$work"; exit 3
fi
# The verdict is the last marker standing on a line of its own. A reviewer
# who rejects may well mention the approve marker in passing ("I cannot sign
# APPROVE:..."), so finding it somewhere in the text proves nothing, and a
# review with no standalone marker is not an approval. This one reading
# decides both the REVIEWED line gate 7 trusts and the event, so the two
# cannot disagree.
decided="$(printf '%s\n' "$verdict" | awk -v a="APPROVE:$TASK" -v r="REJECT:$TASK" '
  { sub(/\r$/, ""); gsub(/^[ \t]+|[ \t]+$/, "") }
  $0 == a { v = "APPROVE" }
  $0 == r { v = "REJECT" }
  END { print v }')"
if [ -z "$decided" ]; then
  echo "fm-review: no APPROVE:$TASK or REJECT:$TASK stands on a line of its own; recorded as REJECT" >&2
  decided=REJECT
fi
# the script's record of what was reviewed goes last, after the reviewer's
# words, so it is the one gate 7 reads whatever the reviewer quoted above it
# Retain before projection. Only the managed Codex selector grants authenticated
# provenance; configured legacy reviewers still count, with their level visible.
printf '%s\n' "$verdict" > "$work/selected-final.txt"
# Keep the final answer as evidence even when the PR moved during the round.
# A stale result is not published as current approval.
if ! verify_review_head; then
  cp "$work/selected-final.txt" "$FM_RUN_DIR/stale-final.txt"
  emit --review-outcome infrastructure_error --type review_failed \
    --en 'PR head changed or could not be verified; final answer retained as stale' \
    --tw 'PR 版本已變更或無法驗證；最終回答已保留並標示過期'
  exit 65
fi
decided="$(fm_evidence verdict --round "$ROUND" --head "$R_HEAD" --base "$R_BASE" \
  --patch "$R_PATCH" --run "$FM_RUN_DIR" --attempt "${FM_CHAIN_ATTEMPT:-}" \
  --code "${FM_CODE_ROOT:-$REPO}" --vendor "${FM_CHAIN_VENDOR:-legacy}" \
  --file "$work/selected-final.txt")" || {
  emit --type review_failed --en 'No local verdict could be retained' \
       --tw '無法保留本機審查裁決'
  exit 3
}
evidence_ref="$(jq -r .signature "$FM_RUN_DIR/evidence-record.json")"
provenance_level=legacy
[ "${FM_CHAIN_VENDOR:-}" != codex ] || provenance_level=authenticated
CREW_DATA="$(jq -c --arg level "$provenance_level" '.provenance_level=$level' <<<"$CREW_DATA")"
verdict="${verdict%"${verdict##*[![:space:]]}"}$(reviewed_line "$decided")"
project_review=fm
if [ "$FM_EXTERNAL" = 1 ]; then
  printf '%s\n' "$verdict" > "$work/private-verdict.md"
  fm_private_note reviewer-report "$TASK" "$work/private-verdict.md" || exit 65
  project_review="$(fm_conventions review)" || exit 65
fi
projection="$(fm_projection)" || exit 65
if [ -n "$PR" ] && [ "$projection" = comments ]; then
  comment_verdict="EVIDENCE:$TASK $evidence_ref

$verdict"
  if [ "$project_review" != fm ]; then
    # A local pre-check must not masquerade as gate 7's repository review.
    comment_verdict="Firstmate local pre-check finished for $TASK at $R_HEAD ($decided). Required external project review remains outstanding; details retained privately. EVIDENCE:$TASK $evidence_ref"
  fi
  if ! fm_comment_projection "$PR" --body "$comment_verdict" >/dev/null 2>&1; then
    echo 'fm-review: optional comment projection failed; local verdict retained' >&2
    FM_CREW_STATUS_SECS=0 emit --type crew_status --data '{"evidence_event":"projection_failed"}' --en 'Optional verdict comment failed; local verdict retained' \
         --tw '選用的裁決留言發布失敗；本機裁決已保留'
  fi
fi
case "$decided" in
  APPROVE)
    if [ "$project_review" != fm ]; then
      emit_status "Local pre-check signed; project external review still required" "本機預檢已簽署；仍需專案外部審核"
    else
    emit --type approved --en "reviewer signed $TASK ($provenance_level)" --tw "reviewer 已簽 ${TASK}（${provenance_level}）"
    emit_status "Verdict signed: APPROVE:$TASK" "已簽署裁決：APPROVE:$TASK"
    fi
    ;;
  REJECT)
    emit --review-outcome rejected --type review_failed \
         --en "reviewer rejected $TASK" --tw "reviewer 拒絕 $TASK"
    emit_status "Verdict signed: REJECT:$TASK" "已簽署裁決：REJECT:$TASK"
    ;;
esac
printf '%s\n' "$verdict"
# A round that ran without the OS sandbox keeps its log whatever its
# verdict: the line it opens with is the record that the hatch was used.
if [ "$unsandboxed" = 1 ]; then
  kept="$(keep_log)"; cp "$work/log" "$kept" 2>/dev/null || true
  echo "fm-review: this round ran WITHOUT the OS sandbox; its log is at $kept" >&2
fi
rm -rf "$work"
exit 0
