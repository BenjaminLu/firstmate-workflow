#!/usr/bin/env bash
# Runs one review round. The reviewer is given the diff, the task spec and the
# acceptance criteria - and, from round three, the round-three protocol's own
# comments from the pull request, and, given --pr, in every round the head's
# SHA, its required check and its gate summary - and nothing else. Not the worker's log, not
# its reasoning, not even the path it worked in. Reasoning is persuasive; the
# artefact is what is under review.
#
# config.yaml's `reviewer: mode:` says how much more it gets. `diff`, and a
# project that declares nothing, is the above and only the above. `run` adds a
# fresh clone of the pull request head, outside every worktree and removed
# when the round ends, in which the reviewer may run the project's commands.
# The adapter confines it there with the engine's own permission flags;
# nothing in the prompt is what stops it.
#
#   fm-review.sh --task T-004 --branch <name> [--repo .] [--pr 9] [--round 1]
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

REPO="$(fm_default_repo)"; TASK=''; BRANCH=''; PR=''; ROUND=1; VENDOR=''; NAME=''
BASE="${FM_BASE:-main}"; GH="${FM_GH:-gh}"
while [ $# -gt 0 ]; do
  case "$1" in
    --task) fm_need "fm-review" "$@"; TASK="${2-}"; shift 2 ;;
    --branch) fm_need "fm-review" "$@"; BRANCH="${2-}"; shift 2 ;;
    --repo) fm_need "fm-review" "$@"; REPO="${2-}"; shift 2 ;;
    --pr) fm_need "fm-review" "$@"; PR="${2-}"; shift 2 ;;
    --round) fm_need "fm-review" "$@"; ROUND="${2-}"; shift 2 ;;
    --vendor) fm_need "fm-review" "$@"; VENDOR="${2-}"; shift 2 ;;
    --name) fm_need "fm-review" "$@"; NAME="${2-}"; shift 2 ;;
    *) echo "fm-review: unknown argument $1" >&2; exit 64 ;;
  esac
done
[ -n "$TASK" ] && [ -n "$BRANCH" ] || {
  echo "usage: fm-review.sh --task <id> --branch <name> [--pr N] [--round N]" >&2; exit 64; }
cd "$REPO" || { echo "fm-review: no repo at $REPO" >&2; exit 64; }
REPO="$(pwd -P)"
fm_refuse_herdr_bypass fm-review || exit $?

# per run, like the worker's: a constant actor collapses two concurrent
# rounds into one crewman carrying whichever task the second one touched
fm_freeze "$0" "$REPO" ${fm_args[@]+"${fm_args[@]}"}
fm_identity reviewer "$TASK" "$NAME" || exit 70
CREW_DATA="$(jq -cn --arg role reviewer --arg name "$NAME" \
  --arg en 'Work description unavailable' --arg tw '尚無工作說明' \
  '{role:$role,crew_name:$name,activity:{en:$en,"zh-TW":$tw}}')"
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
  local data="$CREW_DATA" args=()
  while [ $# -gt 0 ]; do
    case "$1" in
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
    ${args[@]+"${args[@]}"} >/dev/null 2>&1 </dev/null
}
emit() { emit_once "$@" || true; }

# The run-mode checkout. The EXIT trap removes it on every exit the shell
# handles - success, failure, INT, TERM. A SIGKILL runs no trap, so the next
# run-mode round sweeps checkouts whose owning round is gone (sweep_checkouts).
CHECKOUT_ROOT=''; CHECKOUT=''
drop_checkout() {
  [ -z "$CHECKOUT_ROOT" ] || rm -rf "$CHECKOUT_ROOT"
  CHECKOUT_ROOT=''; CHECKOUT=''
}

# Mid-run activity refresh (T-036); never invents percent from lifecycle labels.
emit_status() {
  local en="$1" tw="$2" done_n="${3-}" total_n="${4-}" data
  if [ "${HERDR_ENV:-}" = 1 ]; then
    fm_herdr_emit_status "$REPO" "$NAME" "$TASK" "$en" "$tw" reviewer "$done_n" "$total_n" \
      >/dev/null 2>&1 && return 0
  fi
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
  fm_record_end "$?"
  drop_checkout
  local try=3
  while [ "$try" -gt 0 ]; do
    try=$(( try - 1 ))
    emit_once --type agent_finished --en "run finished" --tw "這次執行結束" && return 0
  done
  echo "${0##*/}: could not record the end of this run; ${NAME} stays on the deck until ${TASK} is finished" >&2
}
trap finished EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
# Keep SIGHUP ignored (fm-config). Exiting on hangup orphans managed
# transport wait / durable last-result recovery / PR publish.
trap '' HUP

# The task spec comes from the branch under review, not from whatever is
# checked out. A task defined on its own branch - which is how a new one
# arrives - was invisible to the reviewer and to the gate: `no task
# T-027`, for a task sitting in the diff they were handed.
task_spec() {   # task_spec <task> [branch]; its own file, design/tasks/<id>.json
  local t="$1" b="${2:-}" j=''
  [ -n "$b" ] && j="$(fm_task "$t" design/tasks "$b")"
  [ -n "$j" ] || j="$(fm_task "$t")"
  printf '%s' "$j"
}
spec="$(task_spec "$TASK" "$BRANCH")"
[ -n "$spec" ] || { echo "fm-review: no task $TASK" >&2; exit 65; }
set_crew_activity "$spec"

# Said at the START of the actual review, not after the engine returns. The
# small spec lookup above supplies the authored brief and refuses a nonexistent
# task; the minutes-long engine invocation remains entirely bracketed by this
# event and agent_finished.
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

# A clone rather than a worktree: a worktree shares the task's .git, so git
# run inside it writes outside it. The clone has its own objects, the base
# and the head under fixed names, and no remote to push to.
build_checkout() {
  local head
  head="$(git rev-parse -q --verify "$BRANCH^{commit}")" || return 1
  CHECKOUT_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/fm-review.XXXXXX")" || return 1
  CHECKOUT_ROOT="$(cd "$CHECKOUT_ROOT" && pwd -P)" || return 1
  printf '%s\n' "$$" > "$CHECKOUT_ROOT/owner" || return 1
  CHECKOUT="$CHECKOUT_ROOT/checkout"
  mkdir "$CHECKOUT_ROOT/cache" &&
    git clone -q --no-checkout --no-hardlinks "$REPO" "$CHECKOUT" &&
    git -C "$CHECKOUT" fetch -q --no-tags origin "+$BRANCH:refs/fm/head" "+$BASE:refs/fm/base" &&
    [ "$(git -C "$CHECKOUT" rev-parse refs/fm/head)" = "$head" ] &&
    git -C "$CHECKOUT" checkout -q --detach refs/fm/head &&
    git -C "$CHECKOUT" remote remove origin
}
# A checkout left by a round that was SIGKILLed: its owner file names a
# process that no longer exists. One with no owner file may be a round
# between mktemp and writing it, and one whose owner is alive is in use;
# both are left alone.
sweep_checkouts() {
  local d pid
  for d in "${TMPDIR:-/tmp}"/fm-review.*; do
    [ -d "$d" ] && [ -f "$d/owner" ] || continue
    pid="$(head -1 "$d/owner" 2>/dev/null)"
    case "$pid" in ''|*[!0-9]*) continue ;; esac
    kill -0 "$pid" 2>/dev/null || rm -rf "$d"
  done
}
if [ "$REVIEW_MODE" = run ]; then
  emit_status "Preparing a fresh checkout of $BRANCH" "正在準備 $BRANCH 的全新 checkout"
  sweep_checkouts
  # The sandbox reaches only these hosts: what `setup` needs, declared by the
  # checkout running the round. No GitHub host belongs here, since the
  # network is what keeps a push or a gh write from leaving the sandbox; the
  # rule is the adapters' own (fm_review_network_refusal), said here as a
  # configuration error before anything is built.
  FM_REVIEW_NETWORK="$(fm_cfg_in reviewer network)"; export FM_REVIEW_NETWORK
  bad_host="$(fm_review_network_refusal "$FM_REVIEW_NETWORK")"
  [ -z "$bad_host" ] || {
    echo "fm-review: config.yaml's reviewer network names $bad_host" >&2
    emit --review-outcome infrastructure_error --type review_failed \
         --en "review round $ROUND could not start" --tw "第 $ROUND 輪審核無法開始"
    exit 65; }
  build_checkout >/dev/null 2>&1 || {
    echo "fm-review: could not make a fresh checkout of $BRANCH against $BASE for a run-mode review" >&2
    emit --review-outcome infrastructure_error --type review_failed \
         --en "review round $ROUND could not prepare its checkout" --tw "第 $ROUND 輪審核無法準備 checkout"
    exit 70; }
  export FM_RUN_REVIEW=1 FM_REVIEW_CHECKOUT="$CHECKOUT"
  # The sandbox lets commands write only in the checkout and the temp
  # directory, and the project's setup writes its caches under $HOME by
  # default: bun's install cache, Playwright's browsers, npm's cache, any
  # XDG-following tool. Each is pointed into this round's directory, which
  # sits in the temp directory and goes when the round does, so setup
  # writes where it is allowed to rather than being refused.
  REVIEW_CACHE="$CHECKOUT_ROOT/cache"
  export XDG_CACHE_HOME="$REVIEW_CACHE/xdg" BUN_INSTALL_CACHE_DIR="$REVIEW_CACHE/bun" \
         PLAYWRIGHT_BROWSERS_PATH="$REVIEW_CACHE/ms-playwright" npm_config_cache="$REVIEW_CACHE/npm"
fi

# A round that produced nothing is not a round, so review_opened is emitted
# once the chain has actually produced a verdict - otherwise three crashed
# engines would walk a task into the round-three protocol with no review
# ever posted. And because a failed round therefore does not advance the
# counter, its log must not overwrite the last one's.
keep_log() {
  local dir="$REPO/state/reviews" n=1 p
  mkdir -p "$dir"
  p="$dir/$TASK-r$ROUND.log"
  while [ -e "$p" ]; do n=$((n + 1)); p="$dir/$TASK-r$ROUND.$n.log"; done
  printf '%s' "$p"
}

# From round three the reviewer is shown what was said about the closed list
# on the pull request, verbatim: first the latest ASK-PASS-CRITERIA from the
# worker, then every comment holding a numbered list closed by
# CRITERIA-COMPLETE, in the order posted. Without it every round was reviewed
# from scratch and a list the reviewer had closed bound nothing. Only those
# comments cross over; the rest of the pull request is the worker's reasoning
# and stays out.
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
  local json picked fence
  if ! json="$($GH pr view "$PR" --json comments 2>/dev/null)" ||
     ! picked="$(jq -c --arg t "$TASK" '
       ($t | gsub("(?<c>[.*+?^$(){}|\\[\\]\\\\/])"; "\\\(.c)")) as $e
       | "(^|\\n)[ \\t]*ASK-PASS-CRITERIA:\($e)[ \\t\\r]*(\\n|$)" as $ask
       | "(^|\\n)[ \\t]*CRITERIA-COMPLETE:\($e)[ \\t\\r]*(\\n|$)" as $done
       | [.comments[] | .body | strings] as $b
       | { ask: ([$b[] | select(test($ask))] | last),
           lists: [$b[] | select(test($ask) | not) | . as $x
                    | ([match($done; "g").offset] | last) as $at
                    | select($at != null and ($x[0:$at] | test("(^|\\n)[ \\t]*[0-9]+[.)][ \\t]"))) ] }
     ' <<<"$json" 2>/dev/null)" || [ -z "$picked" ]; then
    printf '\nThe pull request'"'"'s comments could not be read, so whether the worker has asked with ASK-PASS-CRITERIA:%s or a closed list with CRITERIA-COMPLETE:%s already exists is unknown. Review this round as usual; if your findings close a list, number them and post CRITERIA-COMPLETE:%s.\n' \
      "$TASK" "$TASK" "$TASK"
    return 0
  fi
  local n i
  fence="$(od -An -N8 -tx1 /dev/urandom | tr -d ' \n')"
  n="$(jq '.lists | length' <<<"$picked")"
  if [ "$n" -gt 0 ]; then
    printf '\nThe numbered list below, posted with CRITERIA-COMPLETE:%s, is the closed list for this task. If more than one appears, the first is the original. Every finding this round must cite a numbered item from it, or be a regression this round newly introduced, marked REGRESSION:%s. Raise nothing else.\n' \
      "$TASK" "$TASK"
  elif [ "$(jq '.ask != null' <<<"$picked")" = true ]; then
    printf '\nThe worker has asked for the pass criteria with ASK-PASS-CRITERIA:%s, quoted below. There is no closed list yet: answer with the complete numbered list of everything that must change for this task to pass, and then post CRITERIA-COMPLETE:%s.\n' \
      "$TASK" "$TASK"
  else
    printf '\nThe pull request has neither an ASK-PASS-CRITERIA:%s from the worker nor a numbered list closed by CRITERIA-COMPLETE:%s. There is no closed list yet; review this round as usual.\n' \
      "$TASK" "$TASK"
  fi
  # jq prints each body itself: through $(...) a comment's trailing newlines
  # were stripped, and the quote was no longer verbatim
  if [ "$(jq '.ask != null' <<<"$picked")" = true ]; then
    printf '\n## The worker'"'"'s ask, verbatim from the pull request\n\n----- begin comment %s -----\n' "$fence"
    jq -r '.ask' <<<"$picked"
    printf -- '----- end comment %s -----\n' "$fence"
  fi
  i=0
  while [ "$i" -lt "$n" ]; do
    printf '\n## Closed list %s of %s, verbatim from the pull request\n\n----- begin comment %s -----\n' \
      "$((i + 1))" "$n" "$fence"
    jq -r --argjson i "$i" '.lists[$i]' <<<"$picked"
    printf -- '----- end comment %s -----\n' "$fence"
    i=$((i + 1))
  done
}

# Given --pr, every diff round is shown the evidence a diff cannot carry, as
# information only (a run-mode round is shown none of it), bound to
# the exact head under review (T-088): the head's SHA, the required check's
# run for that commit, and the head's gate summary when state/ has one.
# It was added so a closed-list item asking for green CI and gates could be
# closed (T-067, round nine); since the captain's 2026-09-25 decision no item
# may ask for them - CI and the gates are firstmate's merge gate - and the
# section stays as information.
#
# The check comes from GitHub's check runs for the commit itself, and a run
# that names another head is dropped: the pull request's own checks follow
# whatever head it has now, which need not be the head this round reviews.
head_evidence() {
  local sha names name runs shown fence
  printf '\n# The head under review\n'
  if ! sha="$(git rev-parse --verify -q "$BRANCH^{commit}")"; then
    printf '\nThe head of %s could not be resolved, so no CI or gate result can be tied to it.\n' "$BRANCH"
    return 0
  fi
  printf '\nHead SHA: %s\n' "$sha"
  printf '\n## The required check for this head, from GitHub\n'
  # read from the output, not the exit status: gh's exit code reports the
  # checks' state, and a red check is exactly what must be shown
  names="$($GH pr checks "$PR" --required --json name --jq '.[].name' 2>/dev/null </dev/null | awk 'NF && !s[$0]++')"
  if [ -z "$names" ]; then
    printf '\nThe required check for head %s could not be read from GitHub, so its CI result is unknown.\n' "$sha"
  else
    while IFS= read -r name; do
      if ! runs="$($GH api "repos/{owner}/{repo}/commits/$sha/check-runs?check_name=$(jq -rn --arg n "$name" '$n|@uri')" 2>/dev/null </dev/null)"; then
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
  printf '\n## The gates for this head\n'
  # The whole file, unfiltered: a filter shows a summary in any other shape
  # as an empty quote that neither reports results nor says they are missing.
  # What is not there is then said by gate - fm-gate.sh stops at the first
  # red one, so a summary can end early, and an empty one lacks all six. The
  # numbers are fm-gate.sh's own: 3 is retired (T-114).
  local summary="$REPO/state/gates/$TASK-$sha.txt" n lacking=''
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

# What this round reviews, pinned once: the head, its merge-base with the
# base, the patch-id of the change between them and the files it touches.
# The verdict carries all four in its REVIEWED line, and gate 7 carries an
# APPROVE across an update onto a newer base only when the change is the
# same one (T-113). The patch-id comes from plumbing, which reads no user
# configuration, with renames off, exactly as fm-gate.sh takes it.
R_HEAD="$(git rev-parse --verify -q "$BRANCH^{commit}")" || R_HEAD=''
R_BASE=''; R_PATCH=''; R_FILES=''
if [ -n "$R_HEAD" ] && R_BASE="$(git merge-base "$BASE" "$R_HEAD" 2>/dev/null)"; then
  R_PATCH="$(git diff-tree -r -p --no-renames "$R_BASE" "$R_HEAD" 2>/dev/null | git patch-id --stable | cut -d' ' -f1)"
  R_FILES="$(git diff-tree -r -z --name-only --no-renames "$R_BASE" "$R_HEAD" 2>/dev/null |
    jq -Rsc 'split("\u0000") | map(select(length > 0))')" || R_FILES=''
else
  R_BASE=''
fi
reviewed_line() {  # reviewed_line <APPROVE|REJECT>
  [ -n "$R_HEAD" ] && [ -n "$R_BASE" ] && [ -n "$R_FILES" ] || return 0
  printf '\n\nREVIEWED:%s verdict=%s head=%s base=%s patch=%s files=%s' \
    "$TASK" "$1" "$R_HEAD" "$R_BASE" "$R_PATCH" "$R_FILES"
}

work="$FM_RUN_DIR/review"
mkdir -p "$work"
prompt="$work/prompt.md"
{
  cat "${FM_CODE_ROOT:-$REPO}/skills/reviewer/SKILL.md"
  printf '\n---\n\n# The task\n\n```json\n%s\n```\n' "$spec"
  printf '\n# Round %s\n' "$ROUND"
  if [ "$ROUND" -ge 3 ] && [ -n "$PR" ]; then
    printf '\n# The closed list\n'
    closed_list
  elif [ "$ROUND" -ge 3 ]; then
    printf '\nThis is round three or later. If the worker has posted ASK-PASS-CRITERIA, answer with the complete numbered list and then post CRITERIA-COMPLETE:%s.\n' "$TASK"
  fi
  # A run-mode reviewer judges the head by running it, so it is shown no CI
  # and no gates and fetches nothing from GitHub for them: both are
  # firstmate's merge gate, never a review criterion (captain, 2026-09-25).
  # A diff round keeps the head section, as information only.
  [ -z "$PR" ] || [ "$REVIEW_MODE" = run ] || head_evidence
  printf '\n---\n\n# The diff under review\n\n```diff\n'
  # the change the REVIEWED line names, not whatever the branch is by now
  if [ -n "$R_BASE" ]; then git diff "$R_BASE" "$R_HEAD"; else git diff "$BASE...$BRANCH"; fi
  printf '```\n'
} > "$prompt"

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
    printf 'You may run commands here: the project'"'"'s declared commands below and git.\n'
    printf 'You may not push, comment on or edit the pull request, touch the task'"'"'s\n'
    printf 'worktree, or write anywhere but this checkout and the system temp directory.\n'
    printf 'The engine'"'"'s own permissions enforce that, not this text; fm-review.sh posts\n'
    printf 'your verdict to the pull request. Commands reach the network only for these\n'
    printf 'hosts: %s. No GitHub host is among them, so gh has nothing to talk to; the\n' "${FM_REVIEW_NETWORK:-none}"
    printf 'base, the head and the diff are all in this checkout. You are shown no CI and\n'
    printf 'no gate results, and need none: you judge the head by what you run here. CI\n'
    printf 'and the gates are firstmate'"'"'s merge gate, not a criterion of this\n'
    printf 'review, so do not wait on them, require them or keep an item open for them. The\n'
    printf 'project'"'"'s caches (XDG_CACHE_HOME, bun, Playwright, npm) point into this\n'
    printf 'round'"'"'s temp directory, so `setup` writes where it may. A command the sandbox\n'
    printf 'refuses is the boundary working: report what it kept you from running, as\n'
    printf 'read, not run, rather than work around it.\n\n'
    printf 'The project'"'"'s contract, from this checkout'"'"'s config.yaml:\n\n'
    for f in setup check check_env tests test docs; do contract_line "$f"; done
    printf '\nDo this, in order:\n\n'
    printf '1. Run `setup`, then `check` with `check_env`. A stage the check says it\n'
    printf '   skipped is unverified, not passed.\n'
    printf '2. Run every test file the diff adds or changes - through `test` when it is\n'
    printf '   declared - and every suite that exercises a changed non-test file.\n'
    printf '3. Prove fail-first. Restore the base version of every changed non-test file\n'
    printf '   (`git checkout fm/base -- <file>`; remove a file the diff adds), run the\n'
    printf '   changed tests again and require red. Name each assertion that went red.\n'
    printf '   Then put the head back with `git checkout fm/head -- .`.\n'
    printf '4. End with two lists before the verdict: **Executed** - every command you\n'
    printf '   ran and its result; **Read, not run** - every claim you checked only by\n'
    printf '   reading. Evidence you did not execute is never reported as executed.\n'
  } >> "$prompt"
fi

# the reviewer runs on its own engine when config.yaml names one, and falls
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
fm_run_chain "$adapters" "$chain" \
  "$prompt" "$work/out" "$work/log" review_is_signed per-vendor; rc=$?
[ -z "$FM_VENDOR_UNKNOWN" ] || {
  echo "fm-review: config.yaml names a vendor with no adapter: $FM_VENDOR_UNKNOWN" >&2
  emit --review-outcome infrastructure_error --type review_failed \
       --en "review round $ROUND could not start" --tw "第 $ROUND 輪審核無法開始"
  rm -rf "$work"; exit 65; }
[ -z "$FM_VENDOR_MISREAD" ] || \
  echo "fm-review: $FM_VENDOR_MISREAD was read as unavailable, but it signed a verdict - keeping it" >&2
for v in $FM_VENDOR_SKIPPED; do
  emit --type vendor_unavailable --en "$v unavailable, trying the next" \
       --tw "$v 不可用，換下一家"
done
verdict="$(attempt_output)"

# The chain says which of the two this was, and both callers read the same
# answer: rc 2 with nothing said is a vendor that was not there, and only
# that earns a 2. An engine that ran and said something unsigned is a
# failed round - exit 2 there would have fm-run retry the same input every
# turn, for ever.
if [ "$rc" = "2" ] && [ "${FM_VENDOR_SPOKE:-0}" = "0" ]; then
  kept="$(keep_log)"
  cp "$work/log" "$kept" 2>/dev/null || : > "$kept"
  echo "fm-review: every reviewer vendor was unavailable; their log is at $kept" >&2
  emit --review-outcome infrastructure_error --type review_failed \
       --en "review round $ROUND could not reach a reviewer" \
       --tw "第 $ROUND 輪審核無法連線至 reviewer"
  rm -rf "$work"; exit 2
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
if [ "$signed" = "0" ] && [ -n "${FM_RUN_DIR:-}" ] && [ -f "$FM_RUN_DIR/last-result.json" ]; then
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
verdict="${verdict%"${verdict##*[![:space:]]}"}$(reviewed_line "$decided")"
if [ -n "$PR" ]; then
  $GH pr comment "$PR" --body "$verdict" >/dev/null 2>&1 || true
fi
case "$decided" in
  APPROVE)
    emit --type approved --en "reviewer signed $TASK" --tw "reviewer 已簽 $TASK"
    emit_status "Verdict signed: APPROVE:$TASK" "已簽署裁決：APPROVE:$TASK"
    ;;
  REJECT)
    emit --review-outcome rejected --type review_failed \
         --en "reviewer rejected $TASK" --tw "reviewer 拒絕 $TASK"
    emit_status "Verdict signed: REJECT:$TASK" "已簽署裁決：REJECT:$TASK"
    ;;
esac
printf '%s\n' "$verdict"
rm -rf "$work"
exit 0
