#!/usr/bin/env bash
# Puts a decision in front of the captain and blocks until it comes back.
#
#   fm-decide.sh --allocate --task T-047 [--project <name>] [--kind merge]
#                                   -> D-firstmate-workflow-T047-1, reserved
#   fm-decide.sh --request D-firstmate-workflow-T047-1 --task T-047 --kind merge \
#                --details details.json --pr 9 [--project <name>]
#   fm-decide.sh --request D-SK-001 --task SK-001 --kind choice --title "..."
#   fm-decide.sh --request D-1096 --kind merge-untracked --pr 96 --details details.json
#   fm-decide.sh --await   D-firstmate-workflow-T047-1 [--timeout 3600]
#
# A merge card names its pull request and its task, and they must agree
# (T-119). Before any card exists, --request --kind merge reads the pull
# request (`gh pr view --json headRefName,title`, on the project's repository)
# and takes its task from the branch, else from the title's T-xxx:/SK-xxx:
# prefix, by the one grammar in fm-emit.sh. A pull request of another task,
# of no task, or one gh cannot read gets no card. A pull request that belongs
# to no task (a revert, a hotfix) gets a `merge-untracked` card instead: it
# names no task, so it takes a hand-raised D-<digits> id, and its merge moves
# no task's card. That card is read the same way and refused for a pull
# request whose branch or title names a task. fm-merge.sh checks the pair
# again at merge time.
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
PROJECT=''; ID_PROJECT=''; ID_TASK=''; ID_N=''; GH="${FM_GH:-gh}"
# the registry library lives beside this script, wherever --repo points
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# the task-id grammar (T-119), beside this script too
[ -r "$HERE/fm-emit.sh" ] || { echo "fm-decide: missing $HERE/fm-emit.sh" >&2; exit 70; }
# shellcheck source=bin/fm-emit.sh
. "$HERE/fm-emit.sh"
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
  echo "usage: fm-decide.sh --allocate --task <id> [--project <name>] | --request <id> --task <id> [--kind merge] | --request <D-digits> --kind merge-untracked --pr <n> | --await <id>" >&2; exit 64; }
cd "$REPO" || { echo "fm-decide: no repo at $REPO" >&2; exit 64; }

# The id grammar, spelled out digit by digit rather than as ranges: a
# bracket range follows the locale's collation. An owned id, D-<project>-
# <key>-<n>, is the shared grammar's FM_OWNED_ID (bin/fm-emit.sh): its task
# part is a task's key, fm_task_key's (T047, SK001, or a fixture's TA).
DIG=0123456789
OWNED_ID="$FM_OWNED_ID"
OLD_ID="^D-[${DIG}]{1,6}$"
SKILL_ID="^D-SK-[${DIG}]{3,}$"
owned() {       # owned <id>: sets ID_PROJECT ID_TASK ID_N when <id> is D-<project>-<task>-<n>
  [[ "$1" =~ $OWNED_ID ]] || return 1
  ID_PROJECT="${BASH_REMATCH[1]}"; ID_TASK="${BASH_REMATCH[2]}"; ID_N="${BASH_REMATCH[3]}"
}
task_key() {    # task_key <task> -> T047 for T-047, SK001 for SK-001; 64 for a task no id can hold
  fm_task_key "$1" || {
    echo "fm-decide: bad task '$1' (a decision id holds T-<letters and digits> or SK-<digits>)" >&2; exit 64; }
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
  case "$KIND" in
    choice|merge) ;;
    merge-untracked)
      echo 'fm-decide: an untracked merge card names no task to own its id; give it a hand-raised D-<digits> id' >&2
      exit 64 ;;
    *) echo 'fm-decide: bad kind' >&2; exit 64 ;;
  esac
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

# A card the captain must answer can sit unseen while the captain is not
# looking at the board, so inside Herdr its request raises one notification
# (T-096). Only here: CI turning red, a worker blocking, a review rejecting
# are weather the board shows, and nothing else calls `herdr notification
# show`. Outside Herdr (no HERDR_ENV=1, the value Herdr exports and its own
# skill tests for) nothing changes and nothing is written.
# config.yaml's notifications.herdr: false turns it off,
# notifications.sound: false keeps it silent. They are read in a subshell,
# so the reader cannot change this script's options or variables; a
# config.yaml whose reader is missing rings nothing and says so, because a
# `herdr: false` nobody could read is still a `herdr: false`. The body is
# the card's zh-TW question: the captain's language is the board's default
# locale (design I3), and the board's own choice lives where no script can
# read it. The project is the one the card is filed under: the project it
# records, else, as the board reads a card that records none, the default
# project, else the self project.
#
# One per id, ever: the marker under state/runtime/notified/ is taken with
# noclobber before herdr runs, so a withdrawn card requested again under the
# same id stays quiet, and an answered or withdrawn one is never announced.
# Like the drawing, it is decoration on the request: a notification that
# fails is said on standard error and the request still succeeds, and perl's
# alarm (FM_NOTIFY_SECONDS, 10) keeps a Herdr that does not answer from
# holding the card back.
notify() {   # notify <zh-TW question> <the project the card records, or nothing>
  local on sound home cfg body project mark out rc secs
  [ "${HERDR_ENV:-}" = 1 ] || return 0
  on=true; sound=true; home=''
  if [ -f "$REPO/config.yaml" ]; then
    cfg="$([ -r "$HERE/fm-config.sh" ] || exit 1
           # shellcheck source=bin/fm-config.sh
           . "$HERE/fm-config.sh" || exit 1
           printf '%s\n%s\n%s\n' "$(fm_cfg_in notifications herdr "$REPO/config.yaml")" \
             "$(fm_cfg_in notifications sound "$REPO/config.yaml")" \
             "$(fm_cfg default_project "$REPO/config.yaml")")" || {
      printf 'fm-decide: cannot read notifications from config.yaml without %s: %s raised no notification\n' \
        "$HERE/fm-config.sh" "$ID" >&2
      return 0; }
    { IFS= read -r on; IFS= read -r sound; IFS= read -r home; } <<<"$cfg"
    on="${on:-true}"; sound="${sound:-true}"
  fi
  [ "$on" = false ] && return 0
  [ -f "$PEND/$ID.json" ] && [ ! -e "$DIR/$ID.json" ] || return 0
  command -v herdr >/dev/null 2>&1 || {
    printf 'fm-decide: HERDR_ENV=1 but no herdr command: %s raised no notification\n' "$ID" >&2
    return 0; }
  mark="$REPO/state/runtime/notified/$ID"
  mkdir -p "${mark%/*}" 2>/dev/null
  (set -o noclobber; : > "$mark") 2>/dev/null || return 0
  body="$(printf '%s' "$1" | tr '\r\n\t' '   ')"
  project="${2:-${home:-$SELF_PROJECT}}"
  if [ "$sound" = false ]; then sound=none; else sound=request; fi
  secs="${FM_NOTIFY_SECONDS:-10}"
  [[ "$secs" =~ ^[1-9][0-9]{0,2}$ ]] || secs=10
  out="$(FM_NOTIFY_SECONDS="$secs" perl -e 'alarm $ENV{FM_NOTIFY_SECONDS}; exec @ARGV or exit 127' \
         herdr notification show "$project · ${TASK:-#$PR} · $KIND" --body "$body" --sound "$sound" 2>&1 </dev/null)"; rc=$?
  if [ "$rc" -eq 142 ]; then   # 128 + SIGALRM: the alarm, not Herdr, ended it
    printf 'fm-decide: could not notify %s: herdr timed out after %ss\n' "$ID" "$secs" >&2
  elif [ "$rc" -ne 0 ]; then
    printf 'fm-decide: could not notify %s (herdr exited %s): %s\n' "$ID" "$rc" "$out" >&2
  fi
  return 0
}

# A merge card's pull request must be its task's (T-119). Read from GitHub
# before any card exists - on the project's repository when the card records
# one, else the checkout's, the same repository fm-merge.sh merges on for it -
# and judged by fm-emit.sh's grammar: the branch's task, else the title's.
# An untracked card's pull request must name no task: a task's own pull
# request merged untracked would never move that task's card.
pr_agrees() {   # pr_agrees: returns when --pr is --task's pull request (none for untracked); else says why and exits
  local on=() github doc branch title owner
  if [ -n "$RECORD" ]; then
    github="$(fm_project_get "$RECORD" github "$REPO/config.yaml")" || exit 65
    on=(--repo "$github")
  fi
  doc="$($GH pr view "$PR" ${on[@]+"${on[@]}"} --json headRefName,title 2>/dev/null </dev/null)" \
    && branch="$(jq -er '.headRefName | strings' 2>/dev/null <<<"$doc")" || {
    echo "fm-decide: cannot read #$PR's branch from GitHub; no card raised for ${TASK:-an untracked merge}" >&2; exit 1; }
  title="$(jq -r '.title // empty' <<<"$doc")"
  owner="$(fm_task_of_pr "$branch" "$title" || true)"
  if [ "$KIND" = merge-untracked ]; then
    [ -z "$owner" ] || {
      echo "fm-decide: #$PR is $owner's pull request (branch '$branch'), not untracked; raise --kind merge --task $owner" >&2
      exit 65; }
    return 0
  fi
  [ -n "$owner" ] || {
    echo "fm-decide: #$PR belongs to no task (branch '$branch'), not to $TASK; raise it with --kind merge-untracked" >&2
    exit 65; }
  [ "$owner" = "$TASK" ] || {
    echo "fm-decide: #$PR is $owner's pull request (branch '$branch'), not $TASK's; no card raised" >&2; exit 65; }
}

if [ "$MODE" = request ]; then
  case "$KIND" in choice|merge|merge-untracked) ;; *) echo 'fm-decide: bad kind' >&2; exit 64 ;; esac
  # An untracked merge card belongs to no task: it names none, and so takes
  # the only id no task owns, a hand-raised D-<digits>.
  if [ "$KIND" = merge-untracked ]; then
    [ -z "$TASK" ] || {
      echo "fm-decide: an untracked merge card belongs to no task; drop --task $TASK, or raise --kind merge for it" >&2
      exit 64; }
    [[ "$ID" =~ $OLD_ID ]] || {
      echo 'fm-decide: an untracked merge card takes a hand-raised D-<digits> id' >&2; exit 64; }
  fi
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
    # a task id, or the T-<...> a card has always taken; an untracked merge
    # card has none, checked above
    [ "$KIND" = merge-untracked ] || [[ "$TASK" =~ ^T-[A-Za-z0-9._-]{1,32}$ ]] || fm_task_is "$TASK" \
      || { echo 'fm-decide: bad task' >&2; exit 64; }
    if [ "$KIND" = merge ] || [ "$KIND" = merge-untracked ]; then
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
    # What each option does when the captain picks it (T-118): an optional
    # `effect` object naming, for an option the card offers, one effect the
    # board carries out by the script that owns it. A merge is only a merge
    # card's. Anything else is refused here, before a card exists, because the
    # board would have to record an answer it cannot carry out.
    jq -e -s --arg kind "$KIND" '
      .[0] | .en.options as $o | (.effect // null) as $e
      | $e == null or ($e | type == "object" and all(to_entries[];
          .key as $k | .value as $v
          | ($o | has($k)) and ($v | type == "string")
          and ($v | IN("merge","hold","park","drop","dispatch","send_back"))
          and ($v != "merge" or $kind == "merge" or $kind == "merge-untracked")))
    ' "$DETAILS" >/dev/null 2>&1 || {
      echo 'fm-decide: details.effect names, for an option the card offers, one of merge (merge cards only), hold, park, drop, dispatch or send_back' >&2; exit 64;
    }
    # the last check before anything is written: GitHub's word on the pair
    [ "$KIND" = choice ] || pr_agrees
    payload="$(jq -cn --arg id "$ID" --arg task "$TASK" --arg kind "$KIND" --arg pr "$PR" \
      --arg project "$RECORD" --slurpfile details "$DETAILS" \
      '{id:$id} + (if $task=="" then {} else {task:$task} end)
       + {kind:$kind,details:$details[0],title:$details[0].en.title}
       + (if $project=="" then {} else {project:$project} end)
       + (if $pr=="" then {} else {pr:($pr|tonumber)} end)')" || exit 64
    (set -o noclobber; printf '%s\n' "$payload" > "$PEND/$ID.json") || exit 65
    # after the pending file and before the event: the generator reads the file
    # it is drawing, and the event is what wakes anything watching
    draw
    emit --type decision_requested ${TASK:+--task "$TASK"} ${PR:+--pr "$PR"} ${RECORD:+--project "$RECORD"} \
         --en "$(jq -r '.en.title' "$DETAILS")" --tw "$(jq -r '."zh-TW".title' "$DETAILS")"
    notify "$(jq -r '."zh-TW".title' "$DETAILS")" "$RECORD"
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
      pr_agrees
    fi
    payload="$(jq -cn --arg id "$ID" --arg task "$TASK" --arg kind "$KIND" --arg title "$TITLE" --arg pr "$PR" \
      '{id:$id,task:$task,kind:$kind,title:$title}
       + (if $pr=="" then {} else {pr:($pr|tonumber)} end)')" || exit 64
    (set -o noclobber; printf '%s\n' "$payload" > "$PEND/$ID.json") || exit 65
    # No diagram for legacy skill ids: the generator only accepts numeric D-*.
    # Do not invent details; the board discloses missing authored content.
    emit --type decision_requested --task "$TASK" ${PR:+--pr "$PR"} \
         --en "$TITLE" --tw "$TITLE"
    notify "$TITLE" ""   # a skill-update card records no project
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
