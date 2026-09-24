#!/usr/bin/env bash
# Puts a decision in front of the captain and blocks until it comes back.
#
#   fm-decide.sh --allocate --task T-047 [--project <name>] [--kind merge]
#                                   -> D-firstmate-workflow-T047-1, reserved
#   fm-decide.sh --request D-firstmate-workflow-T047-1 --task T-047 --kind merge \
#                --details details.json --pr 9 [--project <name>]
#   fm-decide.sh --request D-SK-001 --task SK-001 --kind choice --title "..."
#   fm-decide.sh --await   D-firstmate-workflow-T047-1 [--timeout 3600]
#
# A new decision id names its owner: D-<project>-<task>-<n> (design section
# 15.4). <project> is the registry name the run resolves - --project, then
# FM_PROJECT, then default_project; <task> is the task id without its hyphen;
# <n> counts from 1 within that project's task only. --allocate takes the
# next free n under that task's own lock and reserves it, so the details and
# any authored drawing can be written under the id before the card is
# requested; --request then publishes only an id that was allocated. There is
# no global counter and nothing is locked across tasks or projects. Ids made
# before this (D-<digits>, D-SK-<n>) stay valid wherever they are read, and
# are never renamed or moved.
#
# Waiting uses bun's fs.watch when bun is there and a one-second poll when it
# is not. It deliberately depends on neither fswatch, entr nor watchexec:
# a board that only works on a machine with the right brew packages is not a
# board, it is a demo.
set -uo pipefail
# Nothing below may read standard input. A dispatched child inherits it, and
# a child that reads it blocks the caller waiting for a human who is not
# there. One guarantee, in one place; bin/ci.sh fails if a script that
# dispatches is missing it.
exec < /dev/null

REPO="${FM_ROOT:-$(pwd)}"; MODE=''; ID=''; TASK=''; KIND='choice'; TITLE=''; PR=''; TIMEOUT=0; DETAILS=''
PROJECT=''; ID_PROJECT=''; ID_TASK=''; ID_N=''
# the registry library lives beside this script, wherever --repo points
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# see fm_need in bin/fm-config.sh for why: `shift 2` with one argument
# left does not shift, and the loop spins. This file deliberately depends
# on nothing, so it carries the two lines rather than the explanation.
need() { [ "$#" -ge 2 ] || { echo "fm-decide: $1 needs a value" >&2; exit 64; }; }
while [ $# -gt 0 ]; do
  case "$1" in
    --request) need "$@"; MODE=request; ID="${2-}"; shift 2 ;;
    --await)   need "$@"; MODE=await;   ID="${2-}"; shift 2 ;;
    --allocate) MODE=allocate; shift ;;
    --project) need "$@"; PROJECT="${2-}"; shift 2 ;;
    --task)  need "$@"; TASK="${2-}";  shift 2 ;;
    --kind)  need "$@"; KIND="${2-}";  shift 2 ;;
    --title) need "$@"; TITLE="${2-}"; shift 2 ;;
    --details) need "$@"; DETAILS="${2-}"; shift 2 ;;
    --pr)    need "$@"; PR="${2-}";    shift 2 ;;
    --repo)  need "$@"; REPO="${2-}";  shift 2 ;;
    --timeout) need "$@"; TIMEOUT="${2-}"; shift 2 ;;
    *) echo "fm-decide: unknown argument $1" >&2; exit 64 ;;
  esac
done
{ [ -n "$MODE" ] && { [ -n "$ID" ] || [ "$MODE" = allocate ]; }; } || {
  echo "usage: fm-decide.sh --allocate --task <id> [--project <name>] | --request <id> --task <id> [--kind merge] | --await <id>" >&2; exit 64; }
cd "$REPO" || { echo "fm-decide: no repo at $REPO" >&2; exit 64; }

# The id grammar, spelled out letter by letter rather than as a-z ranges: a
# bracket range follows the locale's collation, and in some locales [a-z]
# takes upper-case letters too. The project part is the registry's name rule
# ([a-z0-9-], at most 24); the task part is a task id without its hyphen and
# starts with an upper-case T, which no project name can hold, so the id
# splits one way only. n starts at 1 and has no leading zero.
LOW=abcdefghijklmnopqrstuvwxyz; UP=ABCDEFGHIJKLMNOPQRSTUVWXYZ; DIG=0123456789
OWNED_ID="^D-([${LOW}${DIG}-]{1,24})-(T[${UP}${LOW}${DIG}]{1,32})-([123456789][${DIG}]{0,5})$"
TASK_ID="^T-([${UP}${LOW}${DIG}]{1,32})$"
OLD_ID="^D-[${DIG}]{1,6}$"
SKILL_ID="^D-SK-[${DIG}]{3,}$"
owned() {       # owned <id>: sets ID_PROJECT ID_TASK ID_N when <id> is D-<project>-<task>-<n>
  [[ "$1" =~ $OWNED_ID ]] || return 1
  ID_PROJECT="${BASH_REMATCH[1]}"; ID_TASK="${BASH_REMATCH[2]}"; ID_N="${BASH_REMATCH[3]}"
}
task_key() {    # task_key <task> -> T047 for T-047; 64 for a task no id can hold
  [[ "$1" =~ $TASK_ID ]] || { echo "fm-decide: bad task '$1' (a decision id holds T-<letters and digits>)" >&2; exit 64; }
  printf 'T%s' "${BASH_REMATCH[1]}"
}
# A tree that registers no project (no `projects:` map: every tree before the
# registry, and the test fixtures) is the engine hosting itself. Its ids are
# owned by the self project's name, and nothing records a project, because
# there is no registry to validate one against - the same tree's events carry
# none either. Naming any other project there is refused.
SELF_PROJECT=firstmate-workflow
RECORD=''            # the project written on the card and its event
resolve_project() {  # PROJECT <- the registry name: --project, FM_PROJECT, default_project
  local names
  [ -r "$HERE/fm-config.sh" ] || { echo "fm-decide: a project id needs $HERE/fm-config.sh" >&2; exit 70; }
  # shellcheck source=bin/fm-config.sh
  . "$HERE/fm-config.sh"
  names="$(fm_projects "$REPO/config.yaml")" || exit 65
  if [ -z "$names" ]; then
    PROJECT="${PROJECT:-${FM_PROJECT:-$SELF_PROJECT}}"
    [ "$PROJECT" = "$SELF_PROJECT" ] || {
      echo "fm-decide: no project $PROJECT: config.yaml registers none" >&2; exit 65; }
    return 0
  fi
  PROJECT="$(fm_project_resolve "$PROJECT" "$REPO/config.yaml")" || exit 65
  RECORD="$PROJECT"
}

# Await accepts every id shape there is: numeric, skill-update and owned.
# Request validation is path-specific below.
if [ "$MODE" = await ]; then
  [[ "$ID" =~ $OLD_ID || "$ID" =~ $SKILL_ID ]] || owned "$ID" \
    || { echo 'fm-decide: bad decision id' >&2; exit 64; }
fi

DIR="$REPO/state/decisions"; PEND="$REPO/state/pending"
IDS="$REPO/state/decision-ids"
mkdir -p "$DIR" "$PEND"
emit() { FM_ROOT="$REPO" "$REPO/bin/fm-emit.sh" --actor firstmate "$@" >/dev/null 2>&1 </dev/null || true; }

# --- allocate --------------------------------------------------------------
# The next free n for one project's task, under that task's own lock, and a
# reservation under state/decision-ids/<project>/<task>/<n>.json so the same
# n is never handed out twice. "Free" means past every n that task already
# has anywhere a card can be: reserved, pending, answered or archived.
if [ "$MODE" = allocate ]; then
  case "$KIND" in choice|merge) ;; *) echo 'fm-decide: bad kind' >&2; exit 64 ;; esac
  key="$(task_key "$TASK")" || exit 64
  resolve_project
  own="$IDS/$PROJECT/$key"; lock="$own.lock"
  mkdir -p "$own" || { echo "fm-decide: cannot create $own" >&2; exit 1; }
  got=''
  # mkdir is the portable atomic lock; macOS ships no flock(1)
  for _ in $(seq 1 600); do
    if mkdir "$lock" 2>/dev/null; then got=1; break; fi
    perl -e 'select(undef,undef,undef,0.01)' 2>/dev/null || sleep 0.05
  done
  # a lock outlives only a process killed by a signal no trap sees (KILL);
  # nothing clears it on a guess, so the message says what a human does
  [ -n "$got" ] || {
    echo "fm-decide: timed out waiting for the decision-id lock $lock; if no fm-decide.sh is allocating for $TASK, remove it (rmdir) and allocate again" >&2
    exit 1; }
  # the path is fixed now, not when the trap fires
  # shellcheck disable=SC2064
  trap "rmdir '$lock' 2>/dev/null" EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM
  trap 'exit 129' HUP
  max=0
  for f in "$own"/*.json "$PEND/D-$PROJECT-$key-"*.json "$DIR/D-$PROJECT-$key-"*.json \
           "$REPO/state/runtime/archived-pending/D-$PROJECT-$key-"*.json; do
    [ -e "$f" ] || continue
    n="${f##*/}"; n="${n%.json}"; n="${n##*-}"
    case "$n" in ''|*[!0-9]*) continue ;; esac
    [ "${#n}" -le 6 ] || continue
    [ $(( 10#$n )) -gt "$max" ] && max=$(( 10#$n ))
  done
  n=$(( max + 1 ))
  ID="D-$PROJECT-$key-$n"
  owned "$ID" || { echo "fm-decide: $ID is past what an id can hold" >&2; exit 65; }
  jq -cn --arg id "$ID" --arg project "$PROJECT" --arg task "$TASK" --arg kind "$KIND" \
    --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" '{id:$id,project:$project,task:$task,kind:$kind,ts:$ts}' \
    > "$own/$n.json" || { echo "fm-decide: cannot reserve $ID" >&2; exit 1; }
  printf '%s\n' "$ID"
  exit 0
fi

# The board draws no diagrams. It mounts an iframe for every decision card
# and HEADs the file first, so a decision whose diagram nobody generated is
# answered 404 and the frame removes itself - every reader, every decision,
# for as long as nothing calls the generator. Requesting the decision is the
# moment the file has to exist, because it is the moment the card appears.
#
# The drawing is decoration on the request; the request is what the captain
# is waiting for. So a generator that fails does not take the decision with
# it. It does not vanish either: the reason goes to standard error, where the
# caller's own log keeps it. Its stdout is not passed through - --request
# prints one thing, the pending file, and three diagram paths arriving on the
# same stream would be read as that answer.
draw() {
  local out rc
  [ -x "$REPO/bin/fm-diagram.sh" ] || {
    printf 'fm-decide: no bin/fm-diagram.sh under %s: %s will have no diagram\n' "$REPO" "$ID" >&2
    return 0
  }
  out="$(FM_ROOT="$REPO" "$REPO/bin/fm-diagram.sh" --event decision_requested \
         --decision "$ID" --repo "$REPO" 2>&1 </dev/null)"; rc=$?
  [ "$rc" -eq 0 ] || printf 'fm-decide: could not draw %s (fm-diagram.sh exited %s): %s\n' \
    "$ID" "$rc" "$out" >&2
  return 0
}

if [ "$MODE" = request ]; then
  case "$KIND" in choice|merge) ;; *) echo 'fm-decide: bad kind' >&2; exit 64 ;; esac
  # An owned id is published only by the task and project it names, and only
  # once --allocate has reserved it: n is never picked by hand.
  if owned "$ID"; then
    key="$(task_key "$TASK")" || exit 64
    [ "$key" = "$ID_TASK" ] || { echo "fm-decide: $ID is not an id of $TASK" >&2; exit 64; }
    resolve_project
    [ "$PROJECT" = "$ID_PROJECT" ] || { echo "fm-decide: $ID is not an id of project $PROJECT" >&2; exit 64; }
    [ -f "$IDS/$PROJECT/$key/$ID_N.json" ] || {
      echo "fm-decide: $ID was not allocated; take the next one with --allocate --task $TASK" >&2; exit 65; }
  elif [ -n "$PROJECT" ]; then
    resolve_project
  fi
  [ ! -e "$PEND/$ID.json" ] && [ ! -e "$DIR/$ID.json" ] || {
    echo "fm-decide: $ID already exists; refusing replacement" >&2; exit 65;
  }

  if [ -n "$DETAILS" ]; then
    # Strict authored path: numeric or owned D-*, task T-*, complete en/zh-TW
    # details. Never generate tradeoffs or translations from a title. Exactly one
    # details object. Reject the same prohibited control set the board uses
    # for custom text (C0 except tab/LF/CR, DEL, C1, lone surrogates) before
    # any pending write, so U+007F never reaches persistence.
    [[ "$ID" =~ $OLD_ID ]] || [ -n "$ID_PROJECT" ] || { echo 'fm-decide: bad decision id' >&2; exit 64; }
    [[ "$TASK" =~ ^T-[A-Za-z0-9._-]{1,32}$ ]] || { echo 'fm-decide: bad task' >&2; exit 64; }
    if [ "$KIND" = merge ]; then
      [[ "$PR" =~ ^[1-9][0-9]*$ ]] || { echo 'fm-decide: merge requires a positive PR' >&2; exit 64; }
    fi
    [ -f "$DETAILS" ] && jq -e -s '
      def bad: (. < 32 and . != 9 and . != 10 and . != 13)
        or (. >= 127 and . <= 159) or (. >= 55296 and . <= 57343);
      def words: type == "string" and length <= 2000 and test("\\S")
        and (any(explode[]; bad) | not);
      def locale: type == "object" and (.title|words) and (.explanation|words)
        and (.before|words) and (.after|words)
        and (.outcome|words)
        and (.options|type == "object")
        and all(.options.A,.options.B,.options.C;
          type == "object" and (.description|words) and (.pros|words) and (.cons|words));
      length == 1 and (.[0] | type == "object" and (.en|locale) and (."zh-TW"|locale))
    ' "$DETAILS" >/dev/null 2>&1 || {
      echo 'fm-decide: --details requires complete authored en and zh-TW title, explanation, before, after, outcome and A/B/C description/pros/cons' >&2; exit 64;
    }
    payload="$(jq -cn --arg id "$ID" --arg task "$TASK" --arg kind "$KIND" --arg pr "$PR" \
      --arg project "$RECORD" --slurpfile details "$DETAILS" \
      '{id:$id,task:$task,kind:$kind,details:$details[0],title:$details[0].en.title}
       + (if $project=="" then {} else {project:$project} end)
       + (if $pr=="" then {} else {pr:($pr|tonumber)} end)')" || exit 64
    (set -o noclobber; printf '%s\n' "$payload" > "$PEND/$ID.json") || exit 65
    # after the pending file and before the event: the generator reads the file
    # it is drawing, and the event is what wakes anything watching
    draw
    emit --type decision_requested --task "$TASK" ${PR:+--pr "$PR"} ${RECORD:+--project "$RECORD"} \
         --en "$(jq -r '.en.title' "$DETAILS")" --tw "$(jq -r '."zh-TW".title' "$DETAILS")"
    printf '%s\n' "$PEND/$ID.json"
    exit 0
  fi

  # Legacy title-only path for skill-update callers (bin/fm.sh self-update):
  # accept D-SK-* with matching SK-* task, persist the given title, invent
  # neither details nor a translation. Numeric title-only requests still fail.
  if [[ "$ID" =~ ^D-(SK-[0-9]{3,})$ ]]; then
    skill="${BASH_REMATCH[1]}"
    [ "$TASK" = "$skill" ] || { echo 'fm-decide: bad task' >&2; exit 64; }
    # Title must be real text; never treat an empty --title as authored details.
    jq -e -n --arg t "$TITLE" '
      def bad: (. < 32 and . != 9 and . != 10 and . != 13)
        or (. >= 127 and . <= 159) or (. >= 55296 and . <= 57343);
      ($t | type == "string" and length <= 2000 and test("\\S")
        and (any(explode[]; bad) | not))
    ' >/dev/null 2>&1 || {
      echo 'fm-decide: legacy skill-update requests require --title' >&2; exit 64;
    }
    if [ "$KIND" = merge ]; then
      [[ "$PR" =~ ^[1-9][0-9]*$ ]] || { echo 'fm-decide: merge requires a positive PR' >&2; exit 64; }
    fi
    payload="$(jq -cn --arg id "$ID" --arg task "$TASK" --arg kind "$KIND" --arg title "$TITLE" --arg pr "$PR" \
      '{id:$id,task:$task,kind:$kind,title:$title}
       + (if $pr=="" then {} else {pr:($pr|tonumber)} end)')" || exit 64
    (set -o noclobber; printf '%s\n' "$payload" > "$PEND/$ID.json") || exit 65
    # No diagram for legacy skill ids: the generator only accepts numeric D-*.
    # Do not invent details; the board discloses missing authored content.
    emit --type decision_requested --task "$TASK" ${PR:+--pr "$PR"} \
         --en "$TITLE" --tw "$TITLE"
    printf '%s\n' "$PEND/$ID.json"
    exit 0
  fi

  [[ "$ID" =~ $OLD_ID ]] || [ -n "$ID_PROJECT" ] || { echo 'fm-decide: bad decision id' >&2; exit 64; }
  echo 'fm-decide: --details requires complete authored en and zh-TW title, explanation, before, after, outcome and A/B/C description/pros/cons' >&2
  exit 64
fi

# --- await ---------------------------------------------------------------
f="$DIR/$ID.json"
if [ -f "$f" ]; then answer="$f"; else
  if command -v bun >/dev/null 2>&1 && [ -f "$REPO/bin/watch-decisions.ts" ]; then
    answer="$(bun run "$REPO/bin/watch-decisions.ts" "$DIR" "$ID" "$(( TIMEOUT * 1000 ))" 2>/dev/null </dev/null)"
  else
    waited=0
    while [ ! -f "$f" ]; do
      [ "$TIMEOUT" -gt 0 ] && [ "$waited" -ge "$TIMEOUT" ] && break
      sleep 1; waited=$(( waited + 1 ))
    done
    [ -f "$f" ] && answer="$f" || answer=''
  fi
fi
[ -n "$answer" ] && [ -f "$answer" ] || { echo "fm-decide: timed out waiting for $ID" >&2; exit 1; }

# Recording belongs to the board; observing a response never emits it again.
rm -f "$PEND/$ID.json"
cat "$answer"
exit 0
