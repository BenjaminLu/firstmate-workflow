#!/usr/bin/env bash
# Which ready tasks firstmate has not yet put before the captain.
#
#   fm-ready.sh list    [--repo <root>]
#   fm-ready.sh judged  --task T-004 --decision D-firstmate-workflow-T004-1 [--repo <root>]
#   fm-ready.sh cleared [--repo <root>]
#
# A task is ready by the board's rule (T-057): every depends_on has merged,
# and the log has not moved the task itself - not merged, closed, parked or
# in flight. Turning ready is not the same as being worth dispatching: work
# merged since the task was written may already have done part of it. So
# firstmate judges each task against main as it now stands before anything
# dispatches it, and this script remembers which tasks have been judged.
#
# `list` prints one tab-separated line per ready task:
#   <id>  unjudged  -          <title>
#   <id>  judged    <decision> <title>
# `judged` records that the task went before the captain on that decision.
# `cleared` prints, one per line, the ready tasks whose judgment card the
# captain answered A (proceed): the only ones bin/fm-dispatch.sh may start.
# A card still open, answered anything else, or an A recorded for another
# task or on a merge card, is not a go-ahead. An adopted skill update (SK-*)
# was judged by its own adoption card, D-SK-*, answered A - for the first time
# it is ready only; parked and unparked, or back from backlog, it is unjudged
# again. fm-decide.sh allocates ids only for T-* tasks, so such a task has no
# readiness card to be judged by; it waits for a direct order.
#
# A judgment belongs to one time the task became ready, not to the task. The
# record carries the task's readiness "episode" - its dependency list and
# where in the log the last of them merged (or the task was unparked) - and a
# record whose episode no longer matches counts as unjudged. Some trips to
# backlog leave the episode as it was (a dependency added and removed again
# before it merged), so `list` and `cleared` also end every judgment whose task
# they see out of ready or on another episode; the record is replaced by one
# naming no card. A trip made entirely between two runs is not seen.
#
# Records live in state/ready/<id>.json and are written to a temporary file
# in the same directory and renamed into place, so a reader never sees half a
# record and a failed write leaves the earlier one whole. Usage errors exit 64.
set -uo pipefail
# Nothing below may read standard input. A dispatched child inherits it, and
# a child that reads it blocks the caller waiting for a human who is not
# there.
exec < /dev/null
_grammar_lib="$(dirname "${BASH_SOURCE[0]}")/fm-emit.sh"
[ -r "$_grammar_lib" ] || { echo "fm-ready: missing $_grammar_lib" >&2; exit 70; }
# shellcheck source=bin/fm-emit.sh
. "$_grammar_lib"
_storage_lib="$(dirname "${BASH_SOURCE[0]}")/fm-config.sh"
if [ -r "$_storage_lib" ]; then
  # shellcheck source=bin/fm-config.sh
  . "$_storage_lib"
fi

ROOT="${FM_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
usage() { printf 'fm-ready: %s\n' "$1" >&2
  echo 'usage: fm-ready.sh list|cleared [--repo <root>] | judged --task <id> --decision <D-id> [--repo <root>]' >&2
  exit 64; }
die() { printf 'fm-ready: %s\n' "$1" >&2; exit 1; }
# see fm_need in bin/fm-config.sh for why: `shift 2` with one argument
# left does not shift, and the loop spins.
need() { [ "$#" -ge 2 ] || { echo "fm-ready: $1 needs a value" >&2; exit 64; }; }
# The subcommand is read in the same loop as the flags, as fm-session.sh does,
# so a flag with no value is refused by its own guard wherever it comes.
MODE=''; TASK=''; DECISION=''
while [ $# -gt 0 ]; do
  case "$1" in
    --project) need "$@"; export FM_PROJECT="${2-}"; shift 2 ;;
    list|judged|cleared)
                [ -z "$MODE" ] || usage "one subcommand only: $MODE, then $1"
                MODE="$1"; shift ;;
    --task)     need "$@"; TASK="${2-}";     shift 2 ;;
    --decision) need "$@"; DECISION="${2-}"; shift 2 ;;
    --repo)     need "$@"; ROOT="${2-}";     shift 2 ;;
    -*) usage "unknown argument: $1" ;;
    *)  usage "unknown subcommand: $1" ;;
  esac
done
[ -n "$MODE" ] || usage "a subcommand is required"
if [ "$MODE" != judged ]; then
  [ -z "$TASK$DECISION" ] || usage "$MODE takes no --task or --decision"
else
  # any task id (T-004, SK-001), as long as it names a file here:
  # no slash, no leading dot
  [[ "$TASK" =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,40}$ ]] || usage "judged needs --task <id>, e.g. T-004"
  fm_decision_id "$DECISION" || usage "judged needs --decision D-<project>-<task>-<n>, D-SK-<at least three digits> or D-<n>"
fi

command -v jq >/dev/null 2>&1 || die "jq is required"
if declare -f fm_storage_init >/dev/null; then
  fm_storage_init "$ROOT" || exit 65
else
  [ -z "${FM_PROJECT:-}" ] || { echo "fm-ready: named project needs $_storage_lib" >&2; exit 65; }
  FM_STATE_DIR="$ROOT/state"; FM_TASKS_DIR="$ROOT/design/tasks"
fi
READY_PROJECT="${FM_PROJECT:-}"
READY_DEFAULT="$(fm_cfg default_project "$ROOT/config.yaml" 2>/dev/null || true)"
if [ -z "$(fm_projects "$ROOT/config.yaml" 2>/dev/null)" ]; then
  # Explicit canonical self and unnamed pre-registry callers share history.
  READY_PROJECT=firstmate-workflow; READY_DEFAULT=firstmate-workflow
elif [ -z "$READY_DEFAULT" ]; then
  for candidate in $(fm_projects "$ROOT/config.yaml"); do
    if [ "$(fm_project_get "$candidate" repo "$ROOT/config.yaml")" = . ]; then
      READY_DEFAULT="$candidate"; break
    fi
  done
fi
TASKS="$FM_TASKS_DIR"; LOG="$FM_STATE_DIR/events.jsonl"; DIR="$FM_STATE_DIR/ready"
[ -d "$TASKS" ] || die "no design/tasks/ under $ROOT"
# The task list is one file per task (T-090), read all or nothing as
# fm_tasks reads it: a file that is not one JSON object is no task list, and
# a list read from the files that happened to parse would be half a plan. A
# name starting with a dot is not a task, which the glob already skips.
tasks_list() {
  local files
  shopt -s nullglob; files=("$TASKS"/*.json); shopt -u nullglob
  [ "${#files[@]}" -gt 0 ] || { echo '{"tasks":[]}'; return 0; }
  # exactly one object per file: an empty file, or two values in one, is not
  # a task, and input_filename is how a value is told from its neighbour's
  jq -cn --argjson n "${#files[@]}" '[inputs | {f: input_filename, v: .}] | group_by(.f)
    | if length == $n and all(length == 1 and (.[0].v | type) == "object")
      then {tasks: map(.[0].v)} else error("not one task per file") end' \
    "${files[@]}" 2>/dev/null
}

# One line per ready task: id, episode, title. The replay is the board's
# (board/server.ts): merged and closed are final, and anything that moves a
# task into a lane - dispatched through approved, the failures that block it -
# means it is no longer untouched. Two things differ on purpose. A decision
# card about a task is not the task moving, so decision_requested leaves it
# where it was; otherwise raising the judgment card would take the task off
# the list it was raised from. And, as on the board (T-058), a park is the
# captain's word on untouched work: the last of parked / unparked decides
# whether an untouched task is out, and a task in flight stays in flight
# whatever is said about parking it.
ready_tasks() {
  # read as a file, not an argument: the log outgrows the argument limit
  local log="$LOG" list
  [ -f "$log" ] || log=/dev/null
  list="$(tasks_list)" || die "a file in $TASKS does not read as one task"
  jq -r --arg project "$READY_PROJECT" --arg default "$READY_DEFAULT" --rawfile log "$log" '
    def moves: ["dispatched","commit_pushed","pr_opened","gate_failed","gate_passed",
                "review_opened","approved","review_failed","worker_crashed"];
    ([$log | split("\n")[] | select(length > 0) | (try fromjson catch null)
      | select(type == "object" and (.task | type) == "string")
      | select((.project // $default) == $project)]) as $ev
    | (reduce range(0; $ev | length) as $i ({};
        $ev[$i] as $e | (.[$e.task] // {stage: "untouched"}) as $s
        | if ($s.stage == "merged" or $s.stage == "closed") then .
          elif $e.type == "merged" then .[$e.task] = ($s + {stage: "merged", at: $i})
          elif $e.type == "closed" then .[$e.task] = ($s + {stage: "closed"})
          elif $e.type == "parked" then .[$e.task] = ($s + {parked: true})
          elif $e.type == "unparked" and ($s.parked // false)
            then .[$e.task] = ($s + {parked: false, unparked: $i})
          elif ($e.type | IN(moves[])) then .[$e.task] = ($s + {stage: "flight"})
          else . end)) as $st
    | .tasks[]
    | (.id | tostring) as $id
    | ([.depends_on[]? | tostring] | sort) as $deps
    | (($st[$id].stage // "untouched") == "untouched" and (($st[$id].parked // false) | not)
       and all($deps[]; $st[.].stage == "merged")) as $ready
    | "\($id)\t\(if $ready then "ready" else "out" end)\t\($deps | join(","))@\([$deps[] | $st[.].at] | max // -1)/\($st[$id].unparked // -1)\t\(.title // "" | tostring | gsub("[\t\n]"; " "))"
  ' <<< "$list" || die "could not read $TASKS or $LOG"
}

all_rows="$(ready_tasks)" || exit 1
rows="$(awk -F'\t' -v OFS='\t' '$2 == "ready" { print $1, $3, $4 }' <<< "$all_rows")"

# answered_a <D-n> <task>: the board wrote the captain's A on that card to
# state/decisions/<D-n>.json, and the card was a choice about this task. An A
# on another task's card, or on a merge card, says nothing about this one.
answered_a() {
  if fm_decision_id "$1" owned && [ -n "$READY_PROJECT" ]; then
    [ "${BASH_REMATCH[1]}" = "$READY_PROJECT" ] || return 1
  fi
  fm_decision_id "$1" && [ -f "$FM_STATE_DIR/decisions/$1.json" ] \
    && jq -e --arg t "$2" --arg project "$READY_PROJECT" '.chosen == "A" and .task == $t and ((.kind // "choice") == "choice") and ((.project // $project) == $project)' \
         "$FM_STATE_DIR/decisions/$1.json" >/dev/null 2>&1
}

# adopted <SK-id> <episode>: the adoption card judged the time the skill update
# first turned ready, not every later one. It stands while the task has not
# been unparked, still has the dependencies it was adopted with, read from the
# proposal in state/skill-updates/, and has no record here: a record, even an
# ended one, means a later judgment took over or the adoption ended. Without
# the proposal nothing says which episode the card was about, so it clears
# nothing.
adopted() {
  [ ! -e "$DIR/$1.json" ] || return 1
  [ "${2##*/}" = -1 ] || return 1
  adopted_deps "$1" "$2" && answered_a "D-$1" "$1"
}
# adopted_deps <SK-id> <episode>: the proposal it was adopted from exists and
# names the dependencies the task has now
adopted_deps() {
  local spec="$FM_STATE_DIR/skill-updates/$1.json" deps
  [[ "$1" =~ ^SK-[0-9]{3,}$ ]] || return 1
  [ -f "$spec" ] || return 1
  deps="$(jq -r '[.depends_on[]? | tostring] | sort | join(",")' "$spec" 2>/dev/null)" || return 1
  [ "$deps" = "${2%%@*}" ]
}

# retire <id> <record as read>: the judgment no longer holds, so its record is
# replaced by one that names no card and no episode. It is not deleted: an
# adopted skill update with no record at all would fall back on its adoption.
# Nothing is replaced if the record changed since it was read, so a judgment
# recorded meanwhile is kept.
retire() {
  local rec="$DIR/$1.json" tmp was
  was="$(jq -r '.decision // empty' <<< "$2" 2>/dev/null)"
  if mkdir -p "$DIR" 2>/dev/null && tmp="$(mktemp "$DIR/.$1.XXXXXX" 2>/dev/null)"; then
    if jq -n --arg task "$1" --arg was "$was" --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
         '{task: $task, ended: $was, ended_at: $ts}' > "$tmp" \
       && [ "$(cat "$rec" 2>/dev/null)" = "$2" ] && mv -f "$tmp" "$rec"; then
      return 0
    fi
    rm -f "$tmp"
  fi
  printf 'fm-ready: could not end the judgment of %s\n' "$1" >&2
}

if [ "$MODE" != judged ]; then
  # A task's episode is read from the log and the task files as they stand, and a
  # trip to backlog can leave both as they were: a dependency added and taken
  # away again before it merged. So a judgment ends when this script sees its
  # task out of ready, or ready on another episode, and does not come back.
  # firstmate runs `list` after every merge and after it edits a local,
  # git-ignored task file, which is how the task files change (T-256),
  # and fm-dispatch.sh runs `cleared` on every tick; a trip made between two
  # runs is not seen. An adoption ends the same way once the skill update's
  # dependencies differ from its proposal's.
  while IFS=$'\t' read -r id state episode _; do
    [ -n "$id" ] || continue
    rec="$DIR/$id.json"
    if [ -f "$rec" ]; then
      body="$(cat "$rec" 2>/dev/null)" || continue
      ep="$(jq -r '.episode // empty' <<< "$body" 2>/dev/null)"
      [ -n "$ep" ] || continue
      if [ "$state" = out ] || [ "$ep" != "$episode" ]; then retire "$id" "$body"; fi
    elif [[ "$id" =~ ^SK- ]] && [ -f "$FM_STATE_DIR/skill-updates/$id.json" ] \
         && ! adopted_deps "$id" "$episode"; then
      retire "$id" ''
    fi
  done <<< "$all_rows"

  [ -n "$rows" ] || exit 0
  while IFS=$'\t' read -r id episode title; do
    rec="$DIR/$id.json"; decision=''
    if [ -f "$rec" ]; then
      decision="$(jq -r --arg ep "$episode" 'select(.episode == $ep) | .decision' "$rec" 2>/dev/null)"
    fi
    # A skill update reaches local, git-ignored design/tasks/ through bin/fm.sh self-update
    # --adopt, after the captain answered its D-SK-* card A. That card was
    # the judgment, so no readiness card is raised for it.
    if [ -z "$decision" ] && adopted "$id" "$episode"; then
      decision="D-$id"
    fi
    if [ "$MODE" = cleared ]; then
      [ -n "$decision" ] && answered_a "$decision" "$id" && printf '%s\n' "$id"
      continue
    fi
    if [ -n "$decision" ]; then
      printf '%s\tjudged\t%s\t%s\n' "$id" "$decision" "$title"
    else
      printf '%s\tunjudged\t-\t%s\n' "$id" "$title"
    fi
  done <<< "$rows"
  exit 0
fi

if [ -n "$READY_PROJECT" ] && fm_decision_id "$DECISION" owned; then
  [ "${BASH_REMATCH[1]}" = "$READY_PROJECT" ] && [ "${BASH_REMATCH[2]}" = "${TASK/-/}" ] || die "decision belongs to another project or task"
fi

# judged: only a task that is ready now can have been judged as ready
episode=''
while IFS=$'\t' read -r id ep _; do
  [ "$id" = "$TASK" ] && { episode="$ep"; break; }
done <<< "$rows"
[ -n "$episode" ] || die "$TASK is not ready; only a ready task is judged"

mkdir -p "$DIR" || die "cannot create $DIR"
tmp="$(mktemp "$DIR/.$TASK.XXXXXX")" || die "cannot write under $DIR"
if jq -n --arg task "$TASK" --arg decision "$DECISION" --arg episode "$episode" \
     --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
     '{task: $task, decision: $decision, episode: $episode, judged_at: $ts}' > "$tmp" \
   && mv -f "$tmp" "$DIR/$TASK.json"; then
  exit 0
fi
rm -f "$tmp"
die "could not record the judgment of $TASK"
