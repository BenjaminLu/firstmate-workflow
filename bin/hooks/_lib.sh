#!/usr/bin/env bash
# fm:sourced  # sourced by the harness hooks in this directory
# What every Stop hook shares (T-137). The hooks are thin: each speaks one
# harness's protocol and leaves the watching to bin/fm-watch-arm.sh.
#
# A hook reads its payload from standard input - unlike the bin/*.sh scripts,
# which close it - and never lets a failure of its own end the turn: whatever
# it cannot do, it lets the turn end and says nothing.

# ROOT is where state lives (FM_ROOT, as for every script); the scripts are
# found by where this file is, so a hook always runs its own tree's code
ROOT="${FM_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
HOOKS_BIN="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=bin/lib/fm-watch-lib.sh
. "$HOOKS_BIN/lib/fm-watch-lib.sh"

# the payload the harness sent, read once
fm_hook_payload() { cat; }

# a field of the payload, or the default
fm_hook_field() {   # fm_hook_field <json> <jq path> <default>
  local v
  v="$(printf '%s' "$1" | jq -r "$2 // empty" 2>/dev/null)" || v=''
  printf '%s' "${v:-$3}"
}

# the primary of a repository the captain is not away from; else the hook
# stands down
fm_hook_active() { fm_watch_primary && ! fm_watch_away; }

# For a harness that can only be woken by the hook that ends the turn: park on
# the arm while work is in flight, and print what woke it. Prints nothing when
# nothing is in flight (the watcher is only made sure of) or nothing came
# before the park ran out.
fm_hook_park() {   # fm_hook_park <max-wait seconds>
  if [ "$(fm_inflight_count)" -le 0 ]; then
    "$HOOKS_BIN/fm-watch-arm.sh" --ensure </dev/null >/dev/null 2>&1
    return 0
  fi
  "$HOOKS_BIN/fm-watch-arm.sh" --max-wait "$1" </dev/null 2>/dev/null
}

fm_hook_wake_text() {   # fm_hook_wake_text <reasons>
  printf 'firstmate watcher: %s\nHandle this, then end the turn; the watcher is already re-armed.' "$1"
}

fm_hook_still_text() {
  printf 'Work is still in flight and nothing has needed you yet. Park again: run bin/fm-watch-arm.sh in the foreground and handle what it prints.'
}
