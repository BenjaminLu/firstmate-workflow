#!/usr/bin/env bash
# A turn never ends blind while work is in flight (T-137). The hooks of every
# harness ask this before letting the primary stop.
#
#   fm-turnend-guard.sh [--check]
#
# Exit 0: the turn may end - this is not the primary, the captain is away,
#         nothing is in flight, or a watcher is alive.
# Exit 2: refused - work is in flight and no watcher is alive, and one could
#         not be started. The reason is on stderr, for the harness to hand
#         back to the model.
#
# Unless --check, a missing watcher is first started (bin/fm-watch-arm.sh
# --ensure): the harnesses run their Stop hooks side by side, so this one can
# run before the hook that arms, and refusing on that race would be wrong.
# --check only looks.
set -uo pipefail
exec < /dev/null

ROOT="${FM_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
# shellcheck source=bin/lib/fm-watch-lib.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/fm-watch-lib.sh"
ARM="${FM_WATCH_ARM:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/fm-watch-arm.sh}"

check=0
case "${1-}" in
  '') ;;
  --check) check=1 ;;
  *) echo "fm-turnend-guard: unknown argument: $1" >&2; exit 64 ;;
esac

fm_watch_primary || exit 0
fm_watch_away && exit 0
n="$(fm_inflight_count)"
[ "$n" -gt 0 ] || exit 0
fm_watch_alive && exit 0
if [ "$check" = 0 ]; then
  "$ARM" --ensure </dev/null >/dev/null 2>&1
  fm_watch_alive && exit 0
fi
printf 'fm-turnend-guard: %s round(s) in flight and no watcher is alive. Do not end the turn blind: run bin/fm-watch-arm.sh (it prints when something needs you), then handle what it prints.\n' "$n" >&2
exit 2
