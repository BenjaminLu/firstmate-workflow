#!/usr/bin/env bash
# One watcher cycle (T-137): the wake queue's watcher, the same for every
# harness. It is started only by bin/fm-watch-arm.sh, through the lifeline
# (bin/lib/fm_lifeline.py), owned by the harness session, and refuses to
# run any other way.
#
#   fm-watch.sh <root>
#
# It takes the watch lock, blocks on a doorbell of its own until a wake is
# pushed past the cursor, hands the watch to its successor, writes the
# wake for an arm to claim, and exits. It polls nothing. The whole
# mechanism is in bin/lib/fm_watch.py.
set -uo pipefail
exec < /dev/null
here="${BASH_SOURCE[0]%/*}"; [ "$here" != "${BASH_SOURCE[0]}" ] || here=.
exec python3 "$here/lib/fm_watch.py" cycle "$@"
