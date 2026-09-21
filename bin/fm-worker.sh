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
NAME="${NAME:-worker-$$}"
EMIT="$REPO/bin/fm-emit.sh"
emit_once() { FM_ROOT="$REPO" "$EMIT" --data '{"role":"worker"}' --actor "$NAME" --task "$TASK" "$@" >/dev/null 2>&1 </dev/null; }
emit() { emit_once "$@" || true; }

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
# not it was needed. tests/worker.test.sh walks all three ways out -
# 73, 74 and a TERM mid-engine - in a TMPDIR it owns, so "every" is
# the assertion and not the adjective.
scratch=''
# An explicit template, for two reasons: BSD mktemp ignores $TMPDIR
# without one - so a caller that wants these somewhere it owns, which
# is how the leak is tested, cannot have them - and a file called
# tmp.XXXX says nothing about who left it if one ever does.
scratch_new() { mktemp "${TMPDIR:-/tmp}/fm-worker-XXXXXX"; }
scratch_add() { scratch="$scratch $1"; }
clean_scratch() { [ -z "$scratch" ] || rm -f $scratch; }

finished() {
  clean_scratch
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
  lookup_err="$(scratch_new)"; scratch_add "$lookup_err"
  PR="$($GH pr list --head "$branch" --state open --json number --jq '.[0].number' \
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
asked=0
[ -s "$say" ] && asked=1
spoke=0
# gh's own words are kept, the way the lookup above keeps them: this is
# the one path where a person is expected to pick the failure up by
# hand, and "it was refused" without "why" sends them to the pull
# request to find out - no permission, rate limited, locked, wrong
# number. The run said where the text is and not what went wrong.
say_err=''
if [ "$asked" = 1 ] && [ -n "$PR" ]; then
  say_err="$(scratch_new)"; scratch_add "$say_err"
  if $GH pr comment "$PR" --body-file "$say" >/dev/null 2>"$say_err" </dev/null; then
    spoke=1
    emit --type ask_pass_criteria --pr "$PR" --en "the worker spoke on #$PR" \
         --tw "工人在 #$PR 上發言"
  fi
fi
# A question that went nowhere used to be a line on standard error and
# an exit 0: the run reported a complete round, the log said nothing,
# and the next round asked the same question again. This does not
# UNSTICK the task - nothing reads worker_crashed and acts on it, and a
# task with an open pull request is not one the dispatcher restarts -
# but it stops the run lying about what happened, and it keeps what the
# worker wrote so a human can post it.
#
# So the file is kept, not removed, and the event carries the number:
# a failed round that cannot be linked to the pull request it failed on
# is a card the captain cannot act on.
if [ "$asked" = 1 ] && [ "$spoke" = 0 ]; then
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
  kept="$REPO/state/unsent/$TASK-$(date -u +%Y%m%dT%H%M%SZ)-$$.md"
  mkdir -p "$(dirname "$kept")"
  echo "fm-worker: the worker had something to say and there was nowhere to put it" >&2
  if cp "$say" "$kept" 2>/dev/null; then
    echo "fm-worker: it is at ${kept#"$REPO"/}" >&2
  else
    echo "fm-worker: and it could not be kept either - ${kept#"$REPO"/} is not writable" >&2
    echo "fm-worker: the text is in $say until the next round recreates that worktree" >&2
  fi
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
  exit 73
fi
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
