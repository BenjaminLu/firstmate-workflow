#!/usr/bin/env bash
# Claude Code Stop hook, synchronous (T-137): refuses to let a turn end while
# work is in flight and no watcher is alive. Exit 2 blocks the stop and hands
# stderr back to the model.
#
# stop_hook_active says this stop is already the result of a Stop hook's
# refusal. A guard that refused again could trap a session that has nothing
# left to try, so then it lets the turn end.
set -uo pipefail
BIN="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
payload="$(cat)"
active="$(printf '%s' "$payload" | jq -r '.stop_hook_active // false' 2>/dev/null)"
msg="$("$BIN/fm-turnend-guard.sh" 2>&1 >/dev/null </dev/null)"
rc=$?
if [ "$rc" = 2 ] && [ "$active" != true ]; then
  printf '%s\n' "$msg" >&2
  exit 2
fi
exit 0
