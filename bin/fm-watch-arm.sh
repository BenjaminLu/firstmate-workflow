#!/usr/bin/env bash
# Arming the watch (T-137): single-flight, one watcher cycle per repository.
#
#   fm-watch-arm.sh [--repo DIR] [--max-wait S]  park until a wake; print its
#                                                 lines (exit 1 if the wait ran out)
#   fm-watch-arm.sh --ensure                      make sure a cycle holds the watch
#   fm-watch-arm.sh --status                      the watch, as JSON
#   fm-watch-arm.sh --pending                     what waits now, delivered once
#   fm-watch-arm.sh --follow [--background] [--count N]
#                                                 the fallback for a harness with no
#                                                 hooks: a pane that prints and notifies
#   fm-watch-arm.sh --hook claude                 Claude Code's asyncRewake Stop hook
#   fm-watch-arm.sh --session-start codex         startup/resume context and watch
#   fm-watch-arm.sh --turn-start claude|codex     a UserPromptSubmit hook
#
# Repeated firings attach to the live cycle instead of starting another; a
# cycle whose lock the kernel has released is superseded. A park blocks on
# its doorbell and on its owner's exit together, and exits when the owner
# (the harness session) does. The hook forms read the harness's payload on
# standard input, which is why this script leaves it open. The mechanism is
# in bin/lib/fm_watch.py.
set -uo pipefail
here="${BASH_SOURCE[0]%/*}"; [ "$here" != "${BASH_SOURCE[0]}" ] || here=.
exec python3 "$here/lib/fm_watch.py" arm "$@"
