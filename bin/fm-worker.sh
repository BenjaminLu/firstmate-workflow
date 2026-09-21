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

REPO="${FM_ROOT:-$(pwd)}"; TASK=''; VENDOR=''; NAME=''; PR=''
BASE="${FM_BASE:-main}"; GH="${FM_GH:-gh}"
while [ $# -gt 0 ]; do
  case "$1" in
    --task) TASK="${2-}"; shift 2 ;;
    --repo) REPO="${2-}"; shift 2 ;;
    --vendor) VENDOR="${2-}"; shift 2 ;;
    --name) NAME="${2-}"; shift 2 ;;
    --pr)   PR="${2-}"; shift 2 ;;
    *) echo "fm-worker: unknown argument $1" >&2; exit 64 ;;
  esac
done
[ -n "$TASK" ] || { echo "usage: fm-worker.sh --task <id> [--repo dir]" >&2; exit 64; }
cd "$REPO" || { echo "fm-worker: no repo at $REPO" >&2; exit 64; }
NAME="${NAME:-worker-$$}"
EMIT="$REPO/bin/fm-emit.sh"
emit() { FM_ROOT="$REPO" "$EMIT" --data '{"role":"worker"}' --actor "$NAME" --task "$TASK" "$@" >/dev/null 2>&1 </dev/null || true; }

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
# What sits above it in each: the argument parsing, and in this script
# the task-spec lookup (exit 65) and the worktree creation (exit 70).
# None of those has emitted anything, so nothing has boarded and there
# is nothing to send home - the trap would emit an agent_finished for a
# run the board never saw start.
finished() { emit --type agent_finished --en "run finished" --tw "這次執行結束"; }
trap finished EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
trap 'exit 129' HUP


# The task spec comes from the branch under review, not from whatever is
# checked out. A task defined on its own branch - which is how a new one
# arrives - was invisible to the reviewer and to the gate: `no task
# T-027`, for a task sitting in the diff they were handed.
task_spec() {   # task_spec <task> [branch]
  local t="$1" b="${2:-}" j=''
  [ -n "$b" ] && j="$(git show "$b:design/tasks.json" 2>/dev/null)"
  [ -n "$j" ] || j="$(cat design/tasks.json 2>/dev/null)"
  printf '%s' "$j" | jq -r --arg t "$t" '.tasks[]|select(.id==$t)' 2>/dev/null
}
# the worker has no branch name yet - it is derived from the title - so
# it looks for one already carrying this task
branch_guess="$(git for-each-ref --format='%(refname:short)' refs/heads \
  | grep -i "^$(printf '%s' "$TASK" | tr 'A-Z' 'a-z')-" | head -1)"
spec="$(task_spec "$TASK" "$branch_guess")"
[ -n "$spec" ] || { echo "fm-worker: no task $TASK in design/tasks.json" >&2; exit 65; }

slug="$(printf '%s' "$TASK" | tr 'A-Z' 'a-z')"
branch="$slug-$(jq -r '.title' <<<"$spec" | tr 'A-Z' 'a-z' | tr -cs 'a-z0-9' '-' | cut -c1-28 | sed 's/-*$//')"
tree="$REPO/state/worktrees/$TASK"

# The worker records that it started, not the dispatcher. A task started
# by hand was otherwise never in flight as far as the log was concerned,
# and the dispatcher would start a second one on top of it.
#

emit --type dispatched --en "picked up $TASK" --tw "接下 $TASK"

# --- a worktree of its own -----------------------------------------------
# Never delete work. A run that was interrupted - the machine slept, the
# session ended, someone pressed ctrl-c - leaves its files here
# uncommitted, and this used to remove them before the next round could
# see them. Tonight that nearly cost two finished tasks.
if [ -d "$tree" ] && [ -n "$(git -C "$tree" status --porcelain 2>/dev/null \
     -- . ":(exclude).fm-prompt.md" ":(exclude).fm-say.md")" ]; then
  rescue="$REPO/state/rescued/$TASK-$(date -u +%Y%m%dT%H%M%SZ)"
  mkdir -p "$(dirname "$rescue")"
  cp -R "$tree" "$rescue"
  echo "fm-worker: $tree had uncommitted work; a copy is at $rescue" >&2
  emit --type worker_crashed --en "rescued uncommitted work to ${rescue#"$REPO"/}" \
       --tw "把未提交的工作救到 ${rescue#"$REPO"/}"
fi
rm -rf "$tree"; mkdir -p "$REPO/state/worktrees"
git worktree prune >/dev/null 2>&1
# A second round continues the first. Recreating the branch from main would
# throw away everything the worker did before, which makes a review round
# pointless and the round-three protocol impossible: the worker would be
# answering a review of work that no longer exists.
round_two=0
if git show-ref --verify --quiet "refs/heads/$branch"; then
  round_two=1
  git worktree add -q "$tree" "$branch"
elif git ls-remote --exit-code --heads origin "$branch" >/dev/null 2>&1; then
  round_two=1
  git fetch -q origin "$branch:$branch" 2>/dev/null
  git worktree add -q "$tree" "$branch"
else
  git worktree add -q -b "$branch" "$tree" "$BASE"
fi || { echo "fm-worker: could not create the worktree" >&2; exit 70; }

# --- the prompt: the task, the design that bears on it, and the skill ----
prompt="$tree/.fm-prompt.md"
{
  cat skills/worker/SKILL.md
  printf '\n---\n\n# Your task\n\n```json\n%s\n```\n' "$spec"
  printf '\nYour worktree is the current directory. Your branch is `%s`.\n' "$branch"
  printf 'Stay inside these paths:\n'
  jq -r '.scope[]|"  - " + .' <<<"$spec"
  # a later round is answering a review, and the review is on the pull
  # request. Handing over the task alone would have the worker rewrite what
  # it already wrote instead of fixing what was named.
  if [ "$round_two" = 1 ]; then
    printf '\n---\n\n# This is not the first round\n\n'
    printf 'Your branch already carries your earlier work. Build on it.\n'
    if [ -n "$PR" ]; then
      printf '\nWhat review has said so far, oldest first:\n\n'
      $GH pr view "$PR" --json comments \
        --jq '.comments[]|"## " + .author.login + "\n\n" + .body + "\n"' 2>/dev/null </dev/null
      # and why the gate is red, if it is. A worker answering a failing
      # check without being shown the failure is guessing - and gate 6 does
      # not open until that check is green, so it is the whole of the round.
      failing="$($GH pr checks "$PR" --json state,link \
        --jq '.[]|select(.state!="SUCCESS" and .state!="PENDING")|.link' 2>/dev/null </dev/null | head -1)"
      if [ -n "$failing" ]; then
        printf '\n---\n\n# The required check is red\n\n'
        printf 'It fails on the runner and may well pass on your machine.\n\n```\n'
        $GH run view "${failing##*/runs/}" --log-failed 2>/dev/null </dev/null \
          | tail -120 | sed 's/^[^\t]*\t[^\t]*\t//'
        printf '```\n'
      fi
    fi
  fi
  printf '\n---\n\n# The design\n\n'
  sed -n '/^## 6\./,/^## 8\./p' design/design.md 2>/dev/null
} > "$prompt"

# --- the adapter, with fallback only on a vendor being unavailable -------
# The worker's evidence: files changed in the worktree. The prompt lives
# there too, so it comes out of the count or every run looks busy.
worker_did_work() {
  [ -n "$(git -C "$tree" status --porcelain -- . \
      ":(exclude).fm-prompt.md" ":(exclude).fm-say.md")" ] || [ -s "$tree/.fm-say.md" ]
}
log="$REPO/state/worktrees/$TASK.log"; : > "$log"
fm_run_chain "$REPO/bin/adapters" "$(fm_vendor_chain worker "$VENDOR")" \
  "$prompt" "$tree" "$log" worker_did_work; rc=$?
[ -z "$FM_VENDOR_UNKNOWN" ] || {
  echo "fm-worker: config.yaml names a vendor with no adapter: $FM_VENDOR_UNKNOWN" >&2; exit 65; }
[ -z "$FM_VENDOR_MISREAD" ] || {
  echo "fm-worker: $FM_VENDOR_MISREAD was read as unavailable, but it changed files - keeping them" >&2
  emit --type vendor_unavailable --en "read as unavailable but work was done; keeping it" \
       --tw "被判成不可用，但確實有改動，保留"; }
for v in $FM_VENDOR_SKIPPED; do
  emit --type vendor_unavailable --en "$v unavailable, trying the next" \
       --tw "$v 不可用，換下一家"
done
[ "$rc" = "2" ] && { echo "fm-worker: every vendor was unavailable" >&2; exit 2; }

rm -f "$prompt"

# The worker's one way to speak on the pull request. It may not touch gh -
# that is the adapter contract and the reason a CLI with no repository
# access can be a worker - so it writes .fm-say.md and this script posts
# it. Without this the round-three protocol cannot happen at all:
# ASK-PASS-CRITERIA would sit in a log nobody reads while fm-protocol
# reported a violation every turn, which looks exactly like a worker that
# stopped working.
say="$tree/.fm-say.md"
if [ -s "$say" ] && [ -n "$PR" ]; then
  $GH pr comment "$PR" --body-file "$say" >/dev/null 2>&1 </dev/null \
    && emit --type ask_pass_criteria --pr "$PR" --en "the worker spoke on #$PR" \
            --tw "工人在 #$PR 上發言" \
    || echo "fm-worker: could not post the worker's message to #$PR" >&2
fi
asked=0
[ -s "$say" ] && asked=1
rm -f "$say"

# asking IS the work in a round that begins with a question, and the round
# after it is the one that changes files
if [ "$asked" = 1 ] && [ -z "$(git -C "$tree" status --porcelain)" ]; then
  echo "fm-worker: the worker asked rather than changed anything; its question is on #$PR" >&2
  printf '%s\n' "$branch"
  exit 0
fi

# the same predicate the chain was given, not a second spelling of it: the
# two agreed only because the prompt happened to be removed between them
if ! worker_did_work; then
  echo "fm-worker: the adapter changed nothing" >&2
  emit --type gate_failed --en "the adapter changed nothing" --tw "adapter 沒有改動任何檔案"
  exit 1
fi

# --- from here on it is the script's job, never the adapter's ------------
git -C "$tree" add -A
git -C "$tree" -c user.name=firstmate -c user.email=firstmate@local \
  commit -q -m "$TASK: $(jq -r .title <<<"$spec")"
emit --type commit_pushed --en "committed on $branch" --tw "已在 $branch 上 commit"
git -C "$tree" push -q -u origin "$branch" 2>/dev/null || {
  echo "fm-worker: could not push $branch" >&2; exit 71; }

# On a later round the pull request is already open and `pr create` fails,
# so ask for the branch's pull request first. A worker that could only ever
# open a new one failed its second round at the last step, with the work
# pushed and nothing pointing at it.
num="$($GH pr list --head "$branch" --state open --json number --jq '.[0].number' \
       2>/dev/null </dev/null | head -1)"
if [ -z "$num" ] || [ "$num" = "null" ]; then
  url="$($GH pr create --head "$branch" --base "$BASE" \
        --title "$TASK: $(jq -r .title <<<"$spec")" \
        --body "Dispatched by firstmate for $TASK. Acceptance is in design/tasks.json." \
        2>/dev/null </dev/null | tail -1)"
  # the number, not the url: every step after this addresses the pull
  # request by it, and an event without it leaves the gates checking nothing
  num="$(printf '%s' "$url" | sed -n 's|.*/\([0-9][0-9]*\)$|\1|p')"
  [ -n "$num" ] || { echo "fm-worker: could not read a pull request number from '$url'" >&2; exit 72; }
  emit --type pr_opened --pr "$num" --en "opened #$num" --tw "已開 #$num"
else
  emit --type commit_pushed --pr "$num" --en "pushed another round to #$num" \
       --tw "第二輪已推上 #$num"
fi
printf '%s\n' "$branch"
[ "${rc:-1}" = "0" ] || exit 1
exit 0
