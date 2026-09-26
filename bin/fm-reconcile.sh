#!/usr/bin/env bash
# Reconciling after a crash. The log is the truth, so this rebuilds the whole
# state by replaying state/events.jsonl - there is no snapshot to be stale -
# and then compares what the log believes against the two things it cannot
# see for itself: the pull requests GitHub is holding, and the worktrees and
# pid files left on disk. Every difference it can close it closes through
# bin/fm-emit.sh; every one it cannot, it prints.
#
#   fm-reconcile.sh [--repo .] [--dry-run] [--limit 50]
#   fm-reconcile.sh --repair-cards [--apply] [--effect D-id=park|drop]... [--repo .]
#
# --dry-run prints exactly the same plan and performs none of it. A repair
# tool nobody can rehearse is a repair tool nobody runs.
#
# --repair-cards (T-118) is a one-time repair of the damage the board did
# before T-118, not a standing sweep, and does nothing else. It reads only
# the log and the records beside it, and finds two things:
#   - an answered card whose chosen park or drop never happened (T-030, T-060,
#     T-064): it writes the `parked` or `closed` the answer asked for, as the
#     captain whose answer it was. What an option did is read from the
#     decision record's `effect` (answers since T-118), from a readiness card
#     (T-059: C park, D drop), or from `--effect D-id=park|drop` for a card
#     whose options the log never kept. An answer the task has moved on from
#     since - redispatched, answered again, set aside another way - or whose
#     task is already final is listed and left alone.
#   - a task marked merged by a pull request other than its own (T-117, marked
#     merged by the merge card for #96, the revert of T-105, while its own #97
#     was open): it writes the captain's `reopened`.
# Each fix is one line, in English and Traditional Chinese. It is a dry run
# unless --apply is given, and --apply only emits through bin/fm-emit.sh.
#
# Completed tasks consume stale evidence. Recovery keeps dead PID evidence
# until a locked launcher atomically replaces it, so interruptions are retryable.
# A second run with a live replacement makes no further changes.
#
# One run must close the whole gap, not the first slice of it. Section 2
# writes to the log, and sections 3 and 4 read the picture section 2 has just
# changed - so every repair amends the fold in memory as it is planned, and
# nothing below reads a picture taken before it. A run that repaired a merge
# and then, three lines later, redispatched the task it had just declared
# merged is what this replaces.
#
# Worker liveness is a pid file at state/worktrees/<task-id>.pid, beside the
# <task-id>.log that bin/fm-worker.sh already writes. This script writes one
# for every worker it starts itself; ordinary workers publish the same record
# before touching their worktree. Only explicit recovery events resume without
# a PID; an ordinary dispatch with no liveness record is not declared dead.
set -uo pipefail
# Nothing below may read standard input. A dispatched child inherits it, and
# a child that reads it blocks the caller waiting for a human who is not
# there. One guarantee, in one place; bin/ci.sh fails if a script that
# dispatches is missing it.
exec < /dev/null

REPO="${FM_ROOT:-$(pwd)}"; DRY=0; LIMIT=50; GH="${FM_GH:-gh}"; REPAIR=0; APPLY=0; EFFECTS='{}'
# `shift 2` with one argument left consumes nothing and returns non-zero, so
# a trailing `--repo` with no value spins this loop forever - a hang, with no
# output, which is the worst way for an argument mistake to present itself.
# The value is demanded before the shift rather than defaulted after it.
need() { [ $# -ge 2 ] || { echo "fm-reconcile: $1 needs a value" >&2; exit 64; }; }
# --effect D-id=park|drop: what a hand-raised card's option meant, which the
# card never recorded. Checked here, so the loop's branch stays one guarded
# `shift 2` that the option-loop lint in bin/ci.sh can read.
add_effect() {
  case "$1" in
    *=park|*=drop) ;;
    *) echo "fm-reconcile: --effect takes D-id=park or D-id=drop, not $1" >&2; exit 64 ;;
  esac
  [[ "${1%=*}" =~ ^D-[A-Za-z0-9._-]+$ ]] || { echo "fm-reconcile: --effect names a card id, not ${1%=*}" >&2; exit 64; }
  EFFECTS="$(jq -c --arg id "${1%=*}" --arg e "${1##*=}" '. + {($id): $e}' <<< "$EFFECTS")"
}
while [ $# -gt 0 ]; do
  case "$1" in
    --repo)  need "$@"; REPO="$2";  shift 2 ;;
    --limit) need "$@"; LIMIT="$2"; shift 2 ;;
    --dry-run) DRY=1; shift ;;
    --repair-cards) REPAIR=1; shift ;;
    --apply) APPLY=1; shift ;;
    --effect) need "$@"; add_effect "$2"; shift 2 ;;
    *) echo "fm-reconcile: unknown argument $1" >&2; exit 64 ;;
  esac
done
if [ "$REPAIR" -eq 0 ] && { [ "$APPLY" -eq 1 ] || [ "$EFFECTS" != '{}' ]; }; then
  echo "fm-reconcile: --apply and --effect go with --repair-cards" >&2; exit 64
fi
# the repair is a dry run unless told to apply; the ending event below is
# written only by a run that wrote something
[ "$REPAIR" -eq 0 ] || { [ "$APPLY" -eq 1 ] && DRY=0 || DRY=1; }
cd "$REPO" || { echo "fm-reconcile: no repo at $REPO" >&2; exit 64; }
REPO="$(pwd -P)"
LOG="$REPO/state/events.jsonl"
WT="$REPO/state/worktrees"
shopt -s nullglob

# Every variable inside a zh-TW summary below is written ${braced}. Bash 3.2
# reads the bytes of a full-width character as part of the name that precedes
# it, so "pid $pid）" is an unbound variable named pid） and the whole script
# dies on line 1 of a repair. This cost one run to find.
changes=0; failed=0
say()  { printf 'fm-reconcile: %s\n' "$*"; }
# One sentence per repair, phrased so both modes read the same way and one
# assertion covers both. Counting here rather than at each call site is what
# lets the last line be honest about how much was done.
act()  { changes=$(( changes + 1 ))
         if [ "$DRY" -eq 1 ]; then say "would $*"; else say "$*"; fi; }
# ...and the counterpart, for when the repair act() announced did not happen.
# A count of intentions is not a count of repairs: a run whose every emit was
# refused used to print "3 change(s) applied" and exit 0.
undo() { changes=$(( changes - 1 )); failed=$(( failed + 1 )); say "$*" >&2; }
# The status matters at every call site, so it is returned rather than
# swallowed, and what fm-emit said about it is printed rather than discarded.
emit() { local err
  if ! err="$(FM_ROOT="$REPO" "$REPO/bin/fm-emit.sh" --actor reconcile "$@" 2>&1 </dev/null)"; then
    say "fm-emit refused the event: $err" >&2; return 1
  fi; }

# The basename of a pid file or a worktree directory becomes --task on an
# event and an argv on a dispatch. Anything in state/worktrees/ can be called
# anything; the only thing this script knows about a task id is its shape, so
# that is what it checks before handing the name to another program.
is_task_id() { case "$1" in T-[0-9][0-9][0-9]) return 0 ;; *) return 1 ;; esac; }

# --- 1. replay: the whole state, out of the log and nothing else ----------
n_events=0
[ -f "$LOG" ] && n_events="$(wc -l < "$LOG" | tr -d ' ')"
# Validate the complete stream before arming lifecycle reporting or planning
# mutations. A truncated final record is not permission to trust a prefix.
events='[]'
if [ -e "$LOG" ]; then
  events="$(jq -s 'if all(.[]; type == "object" and (.type|type)=="string")
                    then . else error("invalid event") end' "$LOG")" || {
    say "cannot replay the complete event log; no changes made" >&2; exit 1; }
fi
# Only lifecycle transitions change status. A fresh dispatch clears its PR;
# ancillary events (including agent_finished) never reopen a completed task.
# The captain's two words on a task are read as the board reads them (T-118):
# a park holds until an unpark, and only a reopening - the captain's, with a
# reason, on a task that has ended - takes a task out of merged or closed. It
# starts the task over: nothing parked, and the pull request it opened itself.
fold() {
  jq -r 'def final: .type == "merged" or .type == "closed";
    reduce .[] as $e ({};
    if ($e.task // "") == "" or ($e.data.historical // false) then .
    elif $e.type == "reopened" then
      if $e.actor == "captain" and (($e.data.reason // "") | tostring | test("\\S"))
         and ((.[$e.task] // {}) | final)
      then .[$e.task] |= (.type = "reopened" | .parked = false | .pr = (.opened // ""))
      else . end
    elif $e.type == "parked" or $e.type == "unparked" then
      if ((.[$e.task] // {}) | final) then .
      else .[$e.task] = ((.[$e.task] // {pr:"", type:""}) | .parked = ($e.type == "parked")) end
    elif (["greenlit","dispatched","pr_opened","worker_crashed","merged","closed"] | index($e.type)) == null then .
    else .[$e.task] = ((.[$e.task] // {pr:""}) |
      .type = $e.type |
      if $e.type == "pr_opened" and $e.pr != null then .opened = $e.pr else . end |
      if $e.type == "dispatched" then .pr = ($e.pr // "")
      elif $e.pr != null then .pr = $e.pr else . end)
    end) | to_entries[] | [.key, .value.type, (.value.pr | tostring), (if .value.parked then "parked" else "" end)] | @tsv' | sort
}
state="$(fold <<< "$events")" || exit 1
# Emit an ending only for a run that acted as an actor. A no-op must remain
# byte-for-byte idempotent; dry runs and invalid replays never write events.
finished() {
  local rc=$?
  trap - EXIT
  if [ "$DRY" -eq 0 ] && { [ "$changes" -gt 0 ] || [ "$failed" -gt 0 ]; }; then
    emit --type agent_finished --data "{\"exit_code\":$rc}" \
      --en "reconcile finished (exit $rc)" --tw "調整結束（狀態 ${rc}）" || rc=1
  fi
  exit "$rc"
}
trap finished EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
trap 'exit 129' HUP
# printf '%s\n', not '%s': wc -l counts newlines, so a single unterminated
# line is a table of nought tasks
n_tasks="$(printf '%s\n' "$state" | sed '/^$/d' | wc -l | tr -d ' ')"

task_state() { awk -F'\t' -v t="$1" '$1==t{print $2}' <<< "$state"; }
task_pr()    { awk -F'\t' -v t="$1" '$1==t{print $3}' <<< "$state"; }
is_parked()  { [ "$(awk -F'\t' -v t="$1" '$1==t{print $4}' <<< "$state")" = parked ]; }
# The fold is a value, not a file, and a repair amends it the moment it is
# planned. In memory rather than by re-reading the log, for two reasons:
# --dry-run writes nothing and must still print the same plan as a real run,
# and historical repairs explicitly opt out of lifecycle transitions during
# both in-memory planning and subsequent replay.
remember() { # Use the same reducer for replay and planned transitions.
  local event
  event="$(jq -cn --arg task "$1" --arg type "$2" --arg pr "$3" \
    '{task:$task,type:$type} + (if $pr=="" then {} else {pr:($pr|tonumber)} end)')"
  events="$(jq --argjson event "$event" '. + [$event]' <<< "$events")"
  state="$(fold <<< "$events")"
}
# "Over" has exactly one definition here, and it is the fold's: the task's
# last lifecycle transition is an end. The set of tasks that ever appeared on a merged or
# closed event answers a different question - a task whose first pull request
# was closed and which was then redispatched is in that set and is not over -
# and the two places below that destroy things asked the weaker one. One of
# them deleted a worktree from under a running worker; the other wrote its
# crash off as tidy-up and never revived it.
is_over() { case "$(task_state "$1")" in merged|closed) return 0 ;; *) return 1 ;; esac; }

# What the pid file says about a task, as a question the caller can ask by id.
# Section 4 needs it as much as section 3 does: GitHub and a running worker
# can disagree, and that disagreement must not resolve in favour of rm -rf.
worker_pid() {
  [ -f "$WT/$1.pid" ] || return 1
  perl -0777 -ne 'exit 1 unless /\A([1-9][0-9]*)\n?\z/ && $1 <= 2147483647;
                  print $1; $valid=1; END {exit 1 unless $valid}' "$WT/$1.pid"
}
worker_alive() { local p; p="$(worker_pid "$1")" || return 1; kill -0 "$p" 2>/dev/null; }
# Tasks this run has put a worker back on. In a real run their pid files make
# them live; under --dry-run no worker was started, and this is what keeps the
# rehearsal saying the same words as the performance.
revived=' '; blocked=' '
was_revived() { case "$revived" in *" $1 "*) return 0 ;; *) return 1 ;; esac; }

# --- the one-time card repair (T-118) --------------------------------------
if [ "$REPAIR" -eq 1 ]; then
  # What each answered card's options did, as far as anything beside the log
  # kept it: a decision record's effect, and the card a readiness record names.
  # A record that cannot be read is skipped, never fatal.
  records="$(for f in "$REPO"/state/decisions/*.json; do
      jq -c 'select(type == "object" and (.id | type) == "string") | {(.id): (.effect // null)}' "$f" 2>/dev/null
    done | jq -cs 'add // {}')"
  ready="$(for f in "$REPO"/state/ready/*.json; do
      jq -c '. as $r | select(type == "object" and (.task | type) == "string")
             | [.decision, .ended] | map(select(type == "string" and . != "") | {(.): $r.task}) | add // empty' "$f" 2>/dev/null
    done | jq -cs 'add // {}')"
  # Files, not arguments: a real log is larger than an argument list may be.
  findings="$(jq -c -n --slurpfile E <(printf '%s' "$events") --argjson R "$records" \
      --argjson Y "$ready" --argjson O "$EFFECTS" '
    def proj: (.project // "");
    def same($t; $p): (.task // "") == $t and proj == $p;
    ($E[0] | to_entries) as $ix
    # where each task stops now: the first merged or closed, undone only by
    # a reopening from the captain, as the board reads it
    | (reduce $ix[] as $x ({}; $x.value as $e
        | ([($e.task // ""), ($e | proj)] | tostring) as $k
        | if ($e.task // "") == "" then .
          elif $e.type == "reopened" and $e.actor == "captain"
               and (($e.data.reason // "") | tostring | test("\\S")) then del(.[$k])
          elif ($e.type == "merged" or $e.type == "closed") and .[$k] == null
            then .[$k] = {type: $e.type, at: $x.key, pr: $e.pr}
          else . end)) as $final
    | (
      # 1. an answered card whose chosen park or drop never happened
      ([$ix[] | select(.value.type == "decision_made" and (.value.task // "") != ""
          and ((.value.data.decision // "") | type) == "string" and (.value.data.decision // "") != "")]
        | group_by(.value.data.decision) | map(last) | .[]
        | . as $x | $x.value as $d | $d.data.decision as $id | ($d.data.chosen // "" | tostring) as $c
        | $d.task as $t | ($d | proj) as $p
        | (if ($R[$id] // null) != null then $R[$id]
           elif $p == "" and ($Y[$id] // null) == $t then ({C: "park", D: "drop"}[$c] // null)
           else ($O[$id] // null) end) as $effect
        | select($effect == "park" or $effect == "drop")
        | ({park: "parked", drop: "closed"}[$effect]) as $want
        | [$ix[] | select(.key > $x.key) | .value | select(same($t; $p))] as $after
        | select([$after[] | select(.type == $want)] | length == 0)
        | ([$after[] | select(.type | IN("parked", "unparked", "closed", "merged", "dispatched",
            "reopened", "decision_made"))] | .[0]) as $moved
        | ([$t, $p] | tostring) as $key | $final[$key] as $fin
        | {kind: "card", task: $t, project: $p, decision: $id, chosen: $c, effect: $effect, type: $want}
          + (if $moved != null then {left_en: "\($t) has moved on since (\($moved.type))",
                                     left_tw: "\($t) 之後已有變動（\($moved.type)）"}
             elif $fin != null then {left_en: "\($t) is already \($fin.type)",
                                     left_tw: "\($t) 已經是 \($fin.type)"}
             else {} end)),
      # 2. a task merged by a pull request other than the one it opened
      ($final | to_entries[] | select(.value.type == "merged" and .value.pr != null)
        | (.key | fromjson) as [$t, $p] | .value as $m
        | ([$ix[] | select(.key < $m.at) | .value
            | select(.type == "pr_opened" and same($t; $p) and .pr != null) | .pr] | last) as $own
        | select($own != null and $own != $m.pr)
        | {kind: "merge", task: $t, project: $p, pr: $m.pr, own: $own})
    )')" || { say "cannot read the log for the card repair; nothing changed" >&2; exit 1; }
  # one captain event, through the one writer of the log: each repair carries
  # out the captain's own answer, or the reopening the captain approved
  emit_captain() { local err
    if ! err="$(FM_ROOT="$REPO" "$REPO/bin/fm-emit.sh" --actor captain "$@" 2>&1 </dev/null)"; then
      say "fm-emit refused the event: $err" >&2; return 1
    fi; }
  tw_effect() { case "$1" in park) printf '擱置' ;; drop) printf '不做' ;; esac; }
  found=0
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    found=$(( found + 1 ))
    IFS=$'\037' read -r kind task project id chosen effect type pr own left_en left_tw < <(jq -r \
      '[.kind, .task, .project, (.decision // ""), (.chosen // ""), (.effect // ""), (.type // ""),
        ((.pr // "") | tostring), ((.own // "") | tostring), (.left_en // ""), (.left_tw // "")]
       | map(tostring | gsub("[\u001f\n]"; " ")) | join("\u001f")' <<< "$f")
    on=(); [ -z "$project" ] || on=(--project "$project")
    effect_tw="$(tw_effect "$effect")"
    if [ "$kind" = card ] && [ -n "$left_en" ]; then
      say "left alone: ${id} chose ${chosen} (${effect}) for ${task}, but ${left_en} | 未修正：${id} 對 ${task} 選了 ${chosen}（${effect_tw}），但${left_tw}"
      continue
    fi
    if [ "$kind" = card ]; then
      act "repair ${task}: ${id} chose ${chosen} (${effect}), and no ${type} event followed - write it | 修正 ${task}：${id} 選了 ${chosen}（${effect_tw}），之後卻沒有 ${type} 事件 - 補寫"
      [ "$DRY" -eq 1 ] && continue
      emit_captain --type "$type" --task "$task" "${on[@]+"${on[@]}"}" \
        --data "$(jq -cn --arg d "$id" '{decision: $d, repair: "fm-reconcile.sh --repair-cards"}')" \
        --en "the captain's answer ${id} carried out: ${task} ${type}" \
        --tw "執行船長的答覆 ${id}：${task} ${effect_tw}" \
        || undo "the ${type} event for ${task} was not written"
    else
      act "repair ${task}: marked merged by #${pr}, but its own pull request is #${own} - reopen it | 修正 ${task}：因 #${pr} 被標為已合併，但它自己的拉取請求是 #${own} - 重新開啟"
      [ "$DRY" -eq 1 ] && continue
      emit_captain --type reopened --task "$task" "${on[@]+"${on[@]}"}" \
        --data "$(jq -cn --argjson pr "$pr" --argjson own "$own" \
          '{reason: "marked merged by #\($pr), a merge card raised under this task; its own pull request is #\($own)",
            merged_pr: $pr, own_pr: $own, repair: "fm-reconcile.sh --repair-cards"}')" \
        --en "the captain reopened ${task}: it was marked merged by #${pr}, not its own #${own}" \
        --tw "船長重新開啟了 ${task}：它被 #${pr} 標為已合併，而不是它自己的 #${own}" \
        || undo "the reopened event for ${task} was not written"
    fi
  done <<< "$findings"
  [ "$found" -gt 0 ] || say "cards: nothing to repair | 卡片：沒有需要修正的地方"
  [ "$failed" -eq 0 ] || exit 1
  exit 0
fi

say "replayed $n_events events into $n_tasks tasks (no snapshot)"
# awk, not `read`: tab is whitespace to IFS, so `read` folds a run of empty
# fields into one and a task with only a park would print `parked` as its type
awk -F'\t' '$1 != "" { printf "  %-8s %-18s %s%s\n", $1, $2, ($3 == "" ? "" : "#" $3),
  ($4 == "" ? "" : ($3 == "" ? "" : " ") "(" $4 ")") }' <<< "$state"

# --- 2. the pull requests GitHub is holding -------------------------------
# A branch is named after its task, and the branch is the only place that id
# survives when the event which should have carried one did not. The same
# convention bin/fm-sync-prs.sh reads; the two are not shared because the
# only place to put a shared copy is bin/fm-config.sh, outside this scope.
task_of() { printf '%s' "$1" | sed -n 's/^\([tT]-\{0,1\}[0-9]\{3\}\).*/\1/p' | tr 'a-z' 'A-Z' \
            | sed 's/^T\([0-9]\)/T-\1/'; }

# "-" rather than "", so that "no such event at all" and "an event carrying no
# task" are two different answers instead of the same empty string. They need
# different repairs.
pr_tasks() { [ -f "$LOG" ] || return 0
  jq -r --arg t "$1" --argjson p "$2" \
    'select(.type==$t and .pr==$p)|((.task // "")|if . == "" then "-" else . end)' "$LOG" 2>/dev/null; }

# A fresh dispatch is an attempt boundary even after crashes and recovery
# dispatches change the current status. Read that boundary from the stream,
# not the last lifecycle label. Taskless PR evidence can also predate it;
# the GitHub branch has supplied the missing task association by this point.
pr_before_attempt() {
  jq -e --arg t "$1" --argjson p "$2" '
    ([to_entries[] | select(.value.task==$t and .value.type=="dispatched"
      and (.value.data.recovery // false)==false
      and (.value.data.historical // false)==false) | .key] | last // 0) as $boundary |
    any(.[:$boundary][]; .pr==$p and ((.task // "")=="" or .task==$t))
  ' <<< "$events" >/dev/null
}

raw="$($GH pr list --state all --limit "$LIMIT" --json number,state,title,headRefName 2>/dev/null)"
if ! jq -e 'type=="array"' >/dev/null 2>&1 <<< "$raw"; then
  # reconciling after a crash is exactly when the network may be the thing
  # that broke. The local half below still runs, and this is loud rather than
  # fatal so that a dead worker is still revived on a machine that is offline.
  say "could not read pull requests from GitHub - reconciling the local half only" >&2
  raw='[]'
fi

while IFS=$'\t' read -r num st branch title; do
  [ -n "$num" ] || continue
  case "$st" in
    MERGED) type=merged;    en=merged; tw=已合併 ;;
    CLOSED) type=closed;    en=closed; tw=已關閉 ;;
    OPEN)   type=pr_opened; en=opened; tw=已開啟 ;;
    *) continue ;;
  esac
  known="$(pr_tasks "$type" "$num")"
  if [ -z "$known" ]; then
    why="the log has no $type for it"
  elif ! grep -qv '^-$' <<< "$known"; then
    # every event of this type for this pull request carries no task. This is
    # the shape that left four finished tasks reading as work in flight:
    # downstream reads `merged and .task == $t` and finds nothing.
    why="its $type event carries no task"
  else
    continue
  fi
  task="$(task_of "$branch")"
  [ -n "$task" ] || { say "#$num ($branch): $why, and the branch name yields no task"; continue; }
  # GitHub numbers increase with PR creation. Earlier PRs cannot supersede
  # a later attempt; a fresh dispatch also invalidates its previous PR. Keep
  # the historical marker in the event so later replay makes the same choice.
  historical=false
  current="$(task_pr "$task")"
  if { [ -n "$current" ] && [ "$num" -lt "$current" ]; } ||
     { [ "$current" != "$num" ] && pr_before_attempt "$task" "$num"; }; then
    historical=true
  fi
  act "emit $type #$num for $task - $why, read from branch $branch"
  if [ "$DRY" -eq 1 ]; then
    [ "$historical" = true ] || remember "$task" "$type" "$num"
  elif emit --type "$type" --pr "$num" --task "$task" --data "{\"historical\":$historical}" \
         --en "#${num} ${en}: ${title} (${task}, reconciled from ${branch})" \
         --tw "#${num} ${tw}：${title}（${task}，由 ${branch} 補回）"; then
    [ "$historical" = true ] || remember "$task" "$type" "$num"
  else
    undo "could not record the $type of #${num} for ${task} - the gap is still there"
  fi
done <<< "$(jq -r 'sort_by(.number)[]|[(.number|tostring),.state,.headRefName,.title]|@tsv' <<< "$raw")"

# --- 3. the workers: a pid file is a claim that someone is still working ---
# kill -0 is the whole test, and it has two known blind spots: a pid the
# system has since handed to someone else reads as alive, and a process
# belonging to another user reads as dead. Both are outside what this can see
# from a pid alone, and both are quiet rather than wrong-and-loud, so the
# check stays this simple.
# A recorded crash (or recovery dispatch) is itself durable evidence, even
# when an older reconciler already removed the PID file before dying.
candidates="$(
  for pidfile in "$WT"/*.pid; do basename "$pidfile" .pid; done
  jq -r 'group_by(.task)[] | map(select(.type=="worker_crashed" or .type=="dispatched")) |
    last | select(.type=="worker_crashed" or .data.recovery==true) | .task // empty' <<< "$events"
)"
while IFS= read -r t; do
  [ -n "$t" ] || continue
  pidfile="$WT/$t.pid"
  is_task_id "$t" || { say "$(basename "$pidfile") is not named after a task - left alone" >&2; continue; }
  if [ ! -e "$pidfile" ]; then
    case "$(task_state "$t")" in worker_crashed|dispatched) pid=0;; *) continue;; esac
  elif ! pid="$(worker_pid "$t")"; then
    failed=$((failed + 1))
    say "invalid pid evidence for $t; left untouched" >&2
    continue
  fi
  [ "$pid" != 0 ] && kill -0 "$pid" 2>/dev/null && continue

  if is_parked "$t"; then
    # the captain set the task aside, and the stop that parked it is why the
    # pid is gone. Not a crash: nothing is revived until an unpark (T-118).
    [ -e "$pidfile" ] || continue
    act "remove the stale pid file for $t (pid $pid is gone, and the captain parked the task)"
    [ "$DRY" -eq 1 ] || rm -f "$pidfile" || { undo "could not remove stale pid evidence for $t"; blocked="$blocked$t "; }
    continue
  fi
  if is_over "$t"; then
    # the work landed and nobody tidied up. Not a crash: there is nothing to
    # revive, and marking it one would put a finished task back in flight.
    act "remove the stale pid file for $t (pid $pid is gone, but the task has finished)"
    [ "$DRY" -eq 1 ] || rm -f "$pidfile" || { undo "could not remove stale pid evidence for $t"; blocked="$blocked$t "; }
    continue
  fi

  pr="$(task_pr "$t")"
  if [ "$(task_state "$t")" != worker_crashed ]; then
    act "mark $t worker_crashed (pid $pid is gone)"
    if [ "$DRY" -eq 0 ]; then
      # Keep the dead PID until publication of its replacement. The crash event
      # is also recovery evidence if a previous version already lost that file.
      if emit --type worker_crashed --task "$t" ${pr:+--pr "$pr"} \
          --data "$(jq -cn --argjson pid "$pid" '{pid:$pid}')" \
          --en "the worker for $t is gone (pid $pid)" \
          --tw "${t} 的工人已不在（pid ${pid}）"; then
        remember "$t" worker_crashed "$pr"
      else
        undo "could not record the crash of $t - its pid file is left as evidence"
        continue
      fi
    fi

  fi

  # Redispatch. Not through bin/fm-dispatch.sh: that counts this task as still
  # in flight and would refuse it. The branch already exists, so the worker
  # continues it, and --pr hands it the review round it died in the middle of.
  # the positive form, because bin/ci.sh reads these lines: it strikes a
  # `[ -x "..." ]` guard out before asking whether the dispatch on the rest of
  # the line carries its own </dev/null, and `[ ! -x ... ]` walks past that
  [ -x "$REPO/bin/fm-worker.sh" ] || {
    failed=$((failed + 1)); say "$t cannot be redispatched: bin/fm-worker.sh is not there" >&2; continue; }
  act "redispatch $t${pr:+ on #$pr}"
  if [ "$DRY" -eq 1 ]; then revived="$revived$t "; continue; fi
  mkdir -p "$WT" || { undo "cannot create worker evidence directory for $t"; continue; }
  if ! emit --type dispatched --task "$t" ${pr:+--pr "$pr"} --data '{"recovery":true}' \
       --en "redispatched $t after its worker crashed" --tw "工人崩潰後重新派出 ${t}"; then
    undo "could not record the redispatch of $t - no worker was started"
    continue
  fi
  remember "$t" dispatched "$pr"
  # The launcher holds a kernel lock across exec and publishes its own PID
  # before the worker can run. Even if reconcile dies between spawn and PID
  # publication, a second launcher cannot start a second worker. Perl flock
  # uses the kernel API on macOS too; it does not require flock(1).
  # FM_WORKER_LOCK_PID is a same-PID exec handoff, not ambient recovery
  # context: fm-worker uses it both to retain fd 9 and to mark its own
  # dispatch as recovery. Wrappers must preserve PID and fd across exec;
  # a forked worker needs a new ownership handoff, not this parent's PID.
  FM_ROOT="$REPO" perl -MFcntl=:flock,F_SETFD -MPOSIX=dup2 -e '
    my ($path, @command) = @ARGV;
    open(my $lock, ">>", "$path.lock") or die "launch lock: $!";
    flock($lock, LOCK_EX | LOCK_NB) or exit 75;
    fcntl($lock, F_SETFD, 0) or die "lock inheritance: $!";
    dup2(fileno($lock), 9) >= 0 or die "lock descriptor: $!";
    close($lock) if fileno($lock) != 9;
    $ENV{FM_WORKER_LOCK_PID} = $$;
    open(my $pid, ">", "$path.next") or die "pid staging: $!";
    print $pid "$$\n" or die "pid write: $!";
    close($pid) or die "pid close: $!";
    rename("$path.next", $path) or die "pid publish: $!";
    exec @command; die "worker exec: $!";
  ' "$pidfile" "$REPO/bin/fm-worker.sh" --task "$t" --repo "$REPO" ${pr:+--pr "$pr"} \
    >/dev/null 2>&1 </dev/null &
  launcher=$!
  published=0
  for _ in $(seq 1 100); do
    replacement="$(worker_pid "$t")" || replacement=''
    if [ "$replacement" != "$pid" ] && worker_alive "$t"; then published=1; break; fi
    kill -0 "$launcher" 2>/dev/null || break
    sleep 0.01
  done
  if [ "$published" -eq 0 ]; then
    undo "could not publish a live replacement for $t; recovery evidence retained"
    continue
  fi
  revived="$revived$t "
done <<< "$(sort -u <<< "$candidates")"

# --- 4. the worktrees left on disk ----------------------------------------
for dir in "$WT"/*/; do
  t="$(basename "$dir")"
  case "$blocked" in *" $t "*) continue;; esac
  # Live workers outrank cleanup; failed recovery keeps its evidence so a
  # later run can resume it instead of treating the worktree as disposable.
  # GitHub saying the pull request is over does not outrank that: the merge
  # can be of the first round while the worker is mid-way through the second.
  if worker_alive "$t" || was_revived "$t"; then
    say "$t has a worktree and a worker still at work in it - left alone"
    continue
  fi
  if ! is_task_id "$t"; then
    say "$t is not named after a task - left alone"
  elif [ -e "$WT/$t.pid" ] && ! worker_pid "$t" >/dev/null; then
    say "$t has invalid pid evidence; worktree left alone"
  elif is_over "$t"; then
    act "remove the orphan worktree for $t (its pull request has finished)"
    [ "$DRY" -eq 1 ] && continue
    [ -x "$REPO/bin/fm-cleanup.sh" ] || { undo "$t: bin/fm-cleanup.sh is not there"; continue; }
    # cleanup is the only script allowed to delete a worktree, and it is
    # boring about which one. Reconcile does not get its own rm -rf.
    FM_ROOT="$REPO" FM_GH="$GH" "$REPO/bin/fm-cleanup.sh" --task "$t" --repo "$REPO" \
      >/dev/null 2>&1 </dev/null || undo "$t: fm-cleanup.sh refused it"
  elif [ -z "$(task_state "$t")" ]; then
    # no events at all: this may be somebody's unfinished work rather than
    # wreckage, so it is reported and never touched.
    say "$t has a worktree but no events in the log - left alone"
  fi
done

if [ "$changes" -eq 0 ] && [ "$failed" -eq 0 ]; then
  say "nothing to reconcile"
elif [ "$DRY" -eq 1 ]; then
  say "$changes change(s) planned; --dry-run performed none of them"
else
  say "$changes change(s) applied"
fi
# A repair it announced and could not carry out is the one thing a caller must
# not read as a clean run.
[ "$failed" -eq 0 ] || { say "$failed repair(s) could not be carried out" >&2; exit 1; }
exit 0
