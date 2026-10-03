#!/usr/bin/env bash
# Decides what may start. Five things can stop it and all five are checks
# against the log or the filesystem, never a judgement call:
#
#   - no greenlit event for the work      -> nothing starts (the eighth gate)
#   - a dependency is not merged yet      -> that task waits
#   - the captain parked or dropped it    -> it waits until unparked, or never
#   - concurrency is already spent        -> the rest wait
#   - the captain has not answered A to the task's readiness card
#                                         -> that task waits (T-059)
#
# The last is the captain's judgement, read back from where it was recorded
# (bin/fm-ready.sh cleared); this script makes none. A task the captain
# orders directly - or a B rescope firstmate has carried out - is started
# with --task: that order is the captain's word on it, so it lifts the last
# check and no other. Only the named task is considered, and it says why
# when it does not start.
#
#   fm-dispatch.sh [--repo .] [--dry-run] [--limit N] [--task <id>]
set -uo pipefail
# Nothing below may read standard input. A dispatched child inherits it, and
# a child that reads it blocks the caller waiting for a human who is not
# there. One guarantee, in one place; bin/ci.sh fails if a script that
# dispatches is missing it.
exec < /dev/null
_fm_lib="$(dirname "${BASH_SOURCE[0]}")/fm-config.sh"
[ -f "$_fm_lib" ] || { echo "${0##*/}: missing $_fm_lib" >&2; exit 70; }
# shellcheck source=bin/fm-config.sh
. "$_fm_lib"
# shellcheck source=bin/lib/fm-stack.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib/fm-stack.sh"
fm_args=("$@")

REPO="${FM_ROOT:-$(pwd)}"; DRY=0; LIMIT=''; ORDERED=''
while [ $# -gt 0 ]; do
  case "$1" in
    --project) fm_need "fm-dispatch" "$@"; export FM_PROJECT="${2-}"; shift 2 ;;
    --repo) fm_need "fm-dispatch" "$@"; REPO="${2-}"; shift 2 ;;
    --dry-run) DRY=1; shift ;;
    --limit) fm_need "fm-dispatch" "$@"; LIMIT="${2-}"; shift 2 ;;
    --task) fm_need "fm-dispatch" "$@"; ORDERED="${2-}"; shift 2 ;;
    *) echo "fm-dispatch: unknown argument $1" >&2; exit 64 ;;
  esac
done
cd "$REPO" || { echo "fm-dispatch: no repo at $REPO" >&2; exit 64; }
REPO="$(pwd -P)"
# Preserve the caller's selection before storage resolution supplies a default.
selected="${FM_PROJECT:-}"
fm_freeze "$0" "$REPO" ${fm_args[@]+"${fm_args[@]}"}
args=(dispatch --repo "$REPO" --project "$selected" --task "$ORDERED" --limit "$LIMIT")
[ "$DRY" -eq 0 ] || args+=(--dry-run)
exec python3 "${FM_CODE_ROOT:-$REPO}/bin/lib/fm_concurrent.py" "${args[@]}"
