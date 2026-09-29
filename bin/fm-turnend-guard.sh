#!/usr/bin/env bash
# The turn-end guard (T-137): a turn never ends blind while work is in flight.
#
#   fm-turnend-guard.sh [--repo DIR]             the watch as JSON; exit 2 when a
#                                                 turn ending now would be blind
#   fm-turnend-guard.sh --hook claude            Claude Code's synchronous Stop hook:
#                                                 exit 2 refuses the stop, the reason
#                                                 on stderr; never while stop_hook_active
#   fm-turnend-guard.sh --hook codex             Codex's Stop hook: {"decision":"block"}
#   fm-turnend-guard.sh --hook cursor            Cursor's stop hook: {"followup_message"}
#
# Work in flight is a crew round aboard or a card the captain has not
# answered. Codex and Cursor cannot be woken idle, so their guard hands
# over whatever waits, or orders the turn to park on bin/fm-watch-arm.sh in
# the foreground. Crew rounds and an away captain are never guarded. The
# hook forms read the harness's payload on standard input. The mechanism is
# in bin/lib/fm_watch.py.
set -uo pipefail
here="${BASH_SOURCE[0]%/*}"; [ "$here" != "${BASH_SOURCE[0]}" ] || here=.
exec python3 "$here/lib/fm_watch.py" guard "$@"
