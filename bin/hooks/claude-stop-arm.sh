#!/usr/bin/env bash
# Claude Code Stop hook, asyncRewake (T-137). It runs in the background after
# the turn ends and parks on the arm; when an event needs firstmate it exits 2
# with the reason on stderr, which is what wakes an idle session.
#
# A session that has work but no event yet stays parked; one that is woken has
# its successor watcher already running, so nothing needs re-arming here. The
# arm stands down on its own for a crew round or an away captain.
set -uo pipefail
BIN="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cat > /dev/null
# a little under the hook's own timeout in .claude/settings.json
reason="$("$BIN/fm-watch-arm.sh" --max-wait "${FM_HOOK_MAX_WAIT:-85000}" 2>/dev/null </dev/null)"
[ -n "$reason" ] || exit 0
printf '%s\n' "$reason" >&2
exit 2
