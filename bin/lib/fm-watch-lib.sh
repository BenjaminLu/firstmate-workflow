#!/usr/bin/env bash
# fm:sourced  # this file is sourced; see bin/ci.sh, stdin stage
# What the watcher, its arm, the turn-end guard and the hooks share: where the
# watcher keeps its state, whether work is in flight, whether a watcher is
# alive, and which events wake the primary (T-137).
#
# State, all under $ROOT/state/watch/ (state/ is never committed):
#   cursor          lines of events.jsonl already judged; an event wakes at most
#                   once because the cursor moves past it before it is printed
#   beacon          touched by the watcher every pass; its age is its liveness
#   owner           "<generation> <pid>" of the one live cycle (bin/fm-watch-arm.sh)
#   wake.<gen>      the reason a cycle closed on; claims/<gen> is who took it
#   last-wake.json  the last wake, for the board
#   gaps.jsonl      time with work in flight and no live watcher, for the board
#   ci/<pr>         the head whose required check was seen pending
#
# The caller sets ROOT before sourcing.

FM_WATCH_DIR="${FM_WATCH_DIR:-$ROOT/state/watch}"
FM_WATCH_STALE="${FM_WATCH_STALE:-60}"   # a beacon older than this is a dead watcher

# seconds since a file was last written; 999999 when it does not exist
fm_watch_age() {   # fm_watch_age <file>
  [ -e "$1" ] || { printf 999999; return 0; }
  perl -e 'print time - (stat $ARGV[0])[9]' "$1" 2>/dev/null || printf 999999
}

# how many tasks have a round running: the latest of a task's start and stop
# events is a start. Read from the event log, the one record of it.
fm_inflight_count() {   # fm_inflight_count -> a number
  local log="$ROOT/state/events.jsonl" n
  [ -s "$log" ] || { printf 0; return 0; }
  n="$(jq -rs '
    map(select(.task != null and (.type | IN("dispatched","reopened","review_opened",
        "agent_finished","agent_lost","worker_crashed","merged","closed","vendor_unavailable"))))
    | group_by((.project // "") + "/" + .task)
    | map(last | select(.type | IN("dispatched","reopened","review_opened")))
    | length' "$log" 2>/dev/null)" || n=0
  printf '%s' "${n:-0}"
}

fm_watch_gen() {   # the generation the owner file names, 0 when none
  local gen='' pid=''
  if [ -r "$FM_WATCH_DIR/owner" ]; then read -r gen pid < "$FM_WATCH_DIR/owner" 2>/dev/null || true; fi
  if [[ "$gen" =~ ^[0-9]+$ ]]; then printf '%s' "$gen"; else printf 0; fi
}

# a watcher is alive when the owner it names is a live process that has
# touched the beacon lately
fm_watch_alive() {
  local gen='' pid=''
  [ -r "$FM_WATCH_DIR/owner" ] || return 1
  read -r gen pid < "$FM_WATCH_DIR/owner" 2>/dev/null || true
  [[ "$pid" =~ ^[0-9]+$ ]] && kill -0 "$pid" 2>/dev/null || return 1
  [ "$(fm_watch_age "$FM_WATCH_DIR/beacon")" -lt "$FM_WATCH_STALE" ]
}

# Which events wake the primary, and with which line. Progress of a round
# still running (crew_status and the lifecycle markers) is absorbed: it prints
# nothing. Events the primary itself wrote never wake it.
# shellcheck disable=SC2016,SC2034  # a jq program, read by the scripts that source this
FM_WATCH_JQ='
  def who: (.task // (if .pr then "#\(.pr)" else "-" end));
  def role: (.data.identity.role // "");
  def sha: ((.data.head // .data.sha // "") | .[0:7]);
  if .actor == "firstmate" then empty
  elif .type == "agent_finished" then "finished: \(who)" + (if role != "" then " \(role)" else "" end)
  elif .type == "agent_lost" then "lost: \(who)"
  elif .type == "worker_crashed" then "crashed: \(who)"
  elif .type == "vendor_unavailable" then "vendor: \(who)"
  elif .type == "approved" then "review: \(who) APPROVE" + (if sha != "" then " \(sha)" else "" end)
  elif .type == "review_failed" then "review: \(who) REJECT" + (if sha != "" then " \(sha)" else "" end)
  elif .type == "gate_passed" then "gate: \(who) pass" + (if .data.gate then " \(.data.gate)" else "" end)
  elif .type == "gate_failed" then "gate: \(who) fail" + (if .data.gate then " \(.data.gate)" else "" end)
  elif .type == "decision_made" then "card: \(.data.decision // who) answered \(.data.chosen // "-")"
  elif .type == "merged" then "merged: \(if .pr then "#\(.pr)" else who end)"
  elif .type == "protocol_violation" then "protocol: \(who)"
  elif .type == "worktree_restored" then "restored: \(who)"
  else empty end'

# Only the primary arms and is woken. A crew round is marked FM_IN_ROUND, and
# a round's tree is a git worktree under state/worktrees (or a managed
# project's own state/projects); a hook that fires there stands down.
fm_watch_primary() {
  local gd cd_
  [ -z "${FM_IN_ROUND:-}" ] || return 1
  case "$ROOT" in */state/worktrees/*|*/state/projects/*) return 1 ;; esac
  if gd="$(cd "$ROOT" 2>/dev/null && cd "$(git rev-parse --git-dir 2>/dev/null)" 2>/dev/null && pwd -P)" \
     && cd_="$(cd "$ROOT" && cd "$(git rev-parse --git-common-dir 2>/dev/null)" 2>/dev/null && pwd -P)"; then
    [ "$gd" = "$cd_" ] || return 1
  fi
  return 0
}

# While the captain is away (a later task owns the mode; its marker is the
# file state/away) the hooks stand down.
fm_watch_away() { [ -e "$ROOT/state/away" ]; }
