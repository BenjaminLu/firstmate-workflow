#!/usr/bin/env bash
# The watcher, the same for every harness (T-137). One shot: it blocks until
# one event needs firstmate, prints one short line saying which, and exits 0.
#
#   fm-watch.sh
#
# Sources:
#   state/events.jsonl   a round finished or was lost, a review verdict, a gate
#                        result, a decision answered, a merge done - the
#                        FM_WATCH_JQ table in bin/lib/fm-watch-lib.sh. Progress
#                        of a round still running is read and absorbed.
#   open pull requests   while work is in flight, the required check finishing
#                        (gh, polled with backoff, from here and never from a
#                        round)
#
# A line looks like
#   review: T-134 APPROVE 4ea1ec2      ci: #106 failure      card: D-... answered A
#
# state/watch/cursor counts the log lines already judged. It moves past an
# event before the event is printed, so an event wakes at most once, and the
# events after it stay for the next watcher. state/watch/beacon is touched
# every pass: its age is the proof this process is alive.
#
# Exit 0: a reason was printed. Exit 3: another generation owns the watch now
# (FM_WATCH_GEN is set by bin/fm-watch-arm.sh) and this one leaves quietly.
#
# Env: FM_ROOT, GH (default gh), FM_WATCH_POLL (seconds between passes, 2),
# FM_WATCH_CI_MIN / FM_WATCH_CI_MAX (the check poll's first and longest gap,
# 20 and 300).
set -uo pipefail
exec < /dev/null

ROOT="${FM_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
LOG="$ROOT/state/events.jsonl"
# shellcheck source=bin/lib/fm-watch-lib.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/fm-watch-lib.sh"

command -v jq >/dev/null 2>&1 || { echo "fm-watch: jq is required" >&2; exit 70; }
GH="${GH:-gh}"
POLL="${FM_WATCH_POLL:-2}"
CI_MIN="${FM_WATCH_CI_MIN:-20}"
CI_MAX="${FM_WATCH_CI_MAX:-300}"
GEN="${FM_WATCH_GEN:-}"
for v in "$CI_MIN" "$CI_MAX"; do
  [[ "$v" =~ ^[0-9]+$ ]] || { echo "fm-watch: the check poll gaps must be whole seconds" >&2; exit 64; }
done

mkdir -p "$FM_WATCH_DIR/ci" || { echo "fm-watch: cannot create $FM_WATCH_DIR" >&2; exit 70; }
CURSOR="$FM_WATCH_DIR/cursor"
BEACON="$FM_WATCH_DIR/beacon"

lines() { if [ -f "$LOG" ]; then wc -l < "$LOG" | tr -d ' '; else printf 0; fi; }
put_cursor() { printf '%s\n' "$1" > "$CURSOR.tmp" && mv "$CURSOR.tmp" "$CURSOR"; }

# the first watcher ever starts at the end of the log: history is not news
cursor=''
[ -f "$CURSOR" ] && read -r cursor < "$CURSOR"
if [[ ! "$cursor" =~ ^[0-9]+$ ]]; then cursor="$(lines)"; put_cursor "$cursor"; fi

# the required check of each open pull request, once when it finishes. A check
# is news only if this watcher saw it pending: one that was already done when
# watching began is not a finish.
ci_next=0; ci_gap="$CI_MIN"
ci_poll() {   # prints a reason, or nothing
  local prs n head buckets seen
  prs="$($GH pr list --state open --json number,headRefOid \
        -q '.[] | "\(.number) \(.headRefOid)"' 2>/dev/null </dev/null)" || return 0
  while read -r n head; do
    [ -n "${n-}" ] || continue
    buckets="$($GH pr checks "$n" --required --json bucket -q '[.[].bucket] | join(",")' 2>/dev/null </dev/null)"
    seen=''
    [ -f "$FM_WATCH_DIR/ci/$n" ] && read -r seen < "$FM_WATCH_DIR/ci/$n"
    case ",$buckets," in
      ,,) continue ;;
      *,pending,*) printf '%s\n' "$head" > "$FM_WATCH_DIR/ci/$n" ;;
      *)
        [ "$seen" = "$head" ] || continue
        : > "$FM_WATCH_DIR/ci/$n"
        case ",$buckets," in
          *,fail,*|*,cancel,*) printf 'ci: #%s failure\n' "$n" ;;
          *) printf 'ci: #%s success\n' "$n" ;;
        esac
        return 0 ;;
    esac
  done <<< "$prs"
}

# Under an arm, this watcher is one generation's. It has been superseded when a
# newer generation owns the watch, or when the cycle that started it is gone
# (killed, as a superseded cycle is): nobody would read what it printed.
superseded() {
  [ -n "$GEN" ] || return 1
  [ "$(fm_watch_gen)" -gt "$GEN" ] && return 0
  kill -0 "$PPID" 2>/dev/null || return 0
  return 1
}

while :; do
  : > "$BEACON"
  # a newer generation owns the watch. An owner file that still names an
  # older one is the arm not having written ours yet, not a reason to leave.
  superseded && exit 3

  total="$(lines)"
  [ "$total" -ge "$cursor" ] || { cursor="$total"; put_cursor "$cursor"; }
  if [ "$total" -gt "$cursor" ]; then
    # one jq over the new lines: "<line in this chunk><TAB><reason>" for each
    # event that wakes, nothing for the rest
    out="$(tail -n +$((cursor + 1)) "$LOG" 2>/dev/null \
      | jq -r "input_line_number as \$n | ($FM_WATCH_JQ) | \"\(\$n)\t\(.)\"" 2>/dev/null)"
    first="${out%%$'\n'*}"
    if [ -n "$first" ]; then
      # superseded while reading: the event stays for the owner
      superseded && exit 3
      put_cursor $((cursor + ${first%%$'\t'*}))
      printf '%s\n' "${first#*$'\t'}"
      exit 0
    fi
    # nothing in the new lines needs anyone: they are absorbed
    cursor="$total"; put_cursor "$cursor"
    ci_gap="$CI_MIN"
  fi

  if [ "$(date +%s)" -ge "$ci_next" ]; then
    if [ "$(fm_inflight_count)" -gt 0 ]; then
      reason="$(ci_poll)"
      if [ -n "$reason" ]; then printf '%s\n' "$reason"; exit 0; fi
    fi
    ci_next=$(( $(date +%s) + ci_gap ))
    ci_gap=$(( ci_gap * 2 )); [ "$ci_gap" -le "$CI_MAX" ] || ci_gap="$CI_MAX"
  fi
  sleep "$POLL"
done
