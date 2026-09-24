#!/usr/bin/env bash
# Notices what happened on GitHub and writes it into the log. The captain
# merging a pull request in a browser has to reach the system by the system
# looking, not by someone typing it into a conversation.
#
#   fm-sync-prs.sh [--repo .] [--limit 50]
#
# Every registered project's repository is polled, by name (`gh --repo`), and
# what is found is written with that project (design section 15.4). A pull
# request number means nothing on its own: (project, pr) is the key, and an
# event with no project is the default project's. A tree with no `projects:`
# map polls the checkout's own repository and writes no project, as before.
#
# Idempotent: an event already in the log for that pull request and state is
# not written again, so this is safe to run on a timer.
set -uo pipefail
# Nothing below may read standard input. A dispatched child inherits it, and
# a child that reads it blocks the caller waiting for a human who is not
# there. One guarantee, in one place; bin/ci.sh fails if a script that
# dispatches is missing it.
exec < /dev/null

REPO="${FM_ROOT:-$(pwd)}"; LIMIT=50; GH="${FM_GH:-gh}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# see fm_need in bin/fm-config.sh for why: `shift 2` with one argument
# left does not shift, and the loop spins. This file deliberately depends
# on nothing, so it carries the two lines rather than the explanation.
need() { [ "$#" -ge 2 ] || { echo "fm-sync-prs: $1 needs a value" >&2; exit 64; }; }
while [ $# -gt 0 ]; do
  case "$1" in
    --repo) need "$@"; REPO="${2-}"; shift 2 ;;
    --limit) need "$@"; LIMIT="${2-}"; shift 2 ;;
    *) echo "fm-sync-prs: unknown argument $1" >&2; exit 64 ;;
  esac
done
cd "$REPO" || { echo "fm-sync-prs: no repo at $REPO" >&2; exit 64; }
LOG="$REPO/state/events.jsonl"; mkdir -p "$REPO/state"

# The registry, when there is one. The library is needed only to read it, so
# a tree without a config.yaml still depends on nothing.
projects=''; default=''
if [ -f "$REPO/config.yaml" ]; then
  [ -r "$HERE/fm-config.sh" ] || { echo "fm-sync-prs: reading the registry needs $HERE/fm-config.sh" >&2; exit 70; }
  # shellcheck source=bin/fm-config.sh
  . "$HERE/fm-config.sh"
  projects="$(fm_projects "$REPO/config.yaml")" || exit 65
  # the default project owns every event that names none; FM_PROJECT is
  # this run's choice, not the registry's default, so it is kept out
  [ -z "$projects" ] || default="$(FM_PROJECT='' fm_project_resolve '' "$REPO/config.yaml" 2>/dev/null)" || default=''
fi

# which (project, pull request) already has which event recorded
seen() { [ -f "$LOG" ] && jq -r --arg t "$1" --argjson p "$2" --arg proj "$3" --arg def "$default" \
  'select(.type==$t and .pr==$p and ((.project // $def) == $proj))|.pr' "$LOG" 2>/dev/null | head -1; }

# a branch is named after its task: t-004-... -> T-004
task_of() { printf '%s' "$1" | sed -n 's/^\([tT]-\{0,1\}[0-9]\{3\}\).*/\1/p' | tr 'a-z' 'A-Z' \
            | sed 's/^T\([0-9]\)/T-\1/'; }

new=0
sync_one() {  # sync_one <project or empty> <owner/repo or empty>
  local project="$1" github="$2" raw num state branch title type task en tw
  raw="$($GH pr list ${github:+--repo "$github"} --state all --limit "$LIMIT" \
          --json number,state,title,headRefName,mergedAt 2>/dev/null </dev/null)" || {
    echo "fm-sync-prs: could not reach GitHub${project:+ for $project ($github)}" >&2; return 1; }
  jq -e 'type=="array"' >/dev/null 2>&1 <<<"$raw" || {
    echo "fm-sync-prs: unexpected response from gh${project:+ for $project ($github)}" >&2; return 1; }

  while IFS=$'\t' read -r num state branch title; do
    [ -n "$num" ] || continue
    case "$state" in
      MERGED) type=merged ;;
      CLOSED) type=closed ;;
      OPEN)   type=pr_opened ;;
      *) continue ;;
    esac
    [ -z "$(seen "$type" "$num" "$project")" ] || continue
    task="$(task_of "$branch")"
    # build both summaries first: a case inside a command substitution inside an
    # argument is a parse error waiting for the day the branch is taken
    case "$state" in
      MERGED) en=merged;  tw=已合併 ;;
      CLOSED) en=closed;  tw=已關閉 ;;
      *)      en=opened;  tw=已開啟 ;;
    esac
    FM_ROOT="$REPO" "$REPO/bin/fm-emit.sh" --actor github --type "$type" --pr "$num" \
      ${task:+--task "$task"} ${project:+--project "$project"} \
      --en "#${num} ${en}: ${title}" \
      --tw "#${num} ${tw}：${title}" \
      >/dev/null 2>&1 </dev/null || continue
    echo "$type #$num${task:+ ($task)}${project:+ in $project}"
    new=$(( new + 1 ))
  done <<< "$(jq -r '.[]|[(.number|tostring),.state,.headRefName,.title]|@tsv' <<<"$raw")"
  return 0
}

# One project that cannot be read does not stop the others; it still makes
# the whole sync exit non-zero, so a timer's log shows which one failed.
rc=0
if [ -z "$projects" ]; then
  sync_one '' '' || rc=1
else
  while IFS= read -r p; do
    [ -n "$p" ] || continue
    gh_repo="$(fm_project_get "$p" github "$REPO/config.yaml")" || { rc=65; continue; }
    sync_one "$p" "$gh_repo" || rc=1
  done <<< "$projects"
fi

[ "$new" -gt 0 ] || [ "$rc" -ne 0 ] || echo "fm-sync-prs: nothing new"
exit "$rc"
