#!/usr/bin/env bash
# The periodic retrospective (T-273; design section 11, "Periodic
# retrospective"). firstmate runs it when a `retro due` or `retro requested`
# wake arrives; nothing here dispatches, deletes or edits anything.
#
#   fm-retro.sh status
#   fm-retro.sh run                          (start it under bin/lib/fm-lifeline.sh)
#   fm-retro.sh card   --run <run-id>
#   fm-retro.sh record --run <run-id> [--decision D-<n>]
#   fm-retro.sh claim  --run <run-id> --item <label>/<item-id> [--draft <path>]
#   fm-retro.sh link   --run <run-id> --item <label>/<item-id> --task <task-id>
#
# Every subcommand runs from the engine checkout with the self project's
# context, and reads each external project by naming it to fm_storage_init;
# a caller in an external project's context (FM_EXTERNAL=1) is refused.
# bin/lib/fm_retro.py is the one writer of every retro record.
set -uo pipefail
trap 'exit 130' INT
trap 'exit 143' TERM
trap 'exit 129' HUP
# Nothing below may read standard input. A dispatched child inherits it, and
# a child that reads it blocks the caller waiting for a human who is not
# there. One guarantee, in one place; bin/ci.sh fails if a script that
# dispatches is missing it.
exec < /dev/null
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
ROOT="$(cd "$HERE/.." && pwd -P)"
PY="$ROOT/bin/lib/fm_retro.py"
usage() {
  echo 'usage: fm-retro.sh status | run | card --run <id> | record --run <id> [--decision D-<n>] | claim --run <id> --item <label>/<id> [--draft <path>] | link --run <id> --item <label>/<id> --task <id>' >&2
  exit 64
}
[ "${FM_EXTERNAL:-0}" != 1 ] || {
  echo 'fm-retro: a retrospective runs only with the self project'"'"'s context, not FM_EXTERNAL=1' >&2; exit 64; }
[ -r "$PY" ] || { echo "fm-retro: missing $PY" >&2; exit 70; }
cmd="${1:-}"
[ -n "$cmd" ] || usage
shift
# The caller's project never leaks into a retro: each project is named.
for _fm_k in FM_PROJECT FM_STATE_DIR FM_TASKS_DIR FM_TARGET_ROOT FM_DESIGN FM_EXTERNAL FM_BASE GH_REPO; do
  unset "$_fm_k"
done
cd "$ROOT" || exit 70

case "$cmd" in
  status|run|record|claim|link)
    exec python3 "$PY" "$cmd" --engine "$ROOT" "$@" ;;
  card) ;;
  *) usage ;;
esac

# card: reserve under the lock, publish through fm-decide.sh (whose numeric
# publication takes the same lock on its own descriptor), then move the run
# to awaiting-answer under the lock again. No step waits for a lock it holds.
RUN=''
while [ $# -gt 0 ]; do
  case "$1" in
    --run) [ $# -ge 2 ] || { echo 'fm-retro: --run needs a value' >&2; exit 64; }
           RUN="$2"; shift; shift ;;
    *) echo "fm-retro: unknown argument $1" >&2; exit 64 ;;
  esac
done
[ -n "$RUN" ] || usage
prepared="$(python3 "$PY" card-prepare --engine "$ROOT" --run "$RUN")" || exit $?
action="$(jq -r '.action' <<<"$prepared")"
id="$(jq -r '.id' <<<"$prepared")"
if [ "$action" = raise ]; then
  details="$(jq -r '.details' <<<"$prepared")"
  trap 'rm -f "$details"' EXIT
  "$ROOT/bin/fm-decide.sh" --request "$id" --kind choice --purpose retro --retro-run "$RUN" \
    --details "$details" --repo "$ROOT" >/dev/null </dev/null || exit $?
fi
python3 "$PY" card-finish --engine "$ROOT" --run "$RUN"
