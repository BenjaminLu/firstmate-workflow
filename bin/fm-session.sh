#!/usr/bin/env bash
# Observable services; this does not dispatch a fleet or authorize work.
set -uo pipefail
exec < /dev/null
_fm_lib="$(dirname "${BASH_SOURCE[0]}")/fm-config.sh"
[ -f "$_fm_lib" ] || { echo "fm-session: missing $_fm_lib" >&2; exit 70; }
# shellcheck source=bin/fm-config.sh
. "$_fm_lib"
fm_args=("$@")
REPO="${FM_ROOT:-$(pwd)}"; MODE=start; DECISION=all
while [ $# -gt 0 ]; do
  case "$1" in
    start|status|watch|stop|ack) MODE="$1"; shift ;;
    --repo) fm_need "fm-session" "$@"; REPO="$2"; shift 2 ;;
    --decision) fm_need "fm-session" "$@"; DECISION="$2"; shift 2 ;;
    *) echo "fm-session: unknown argument $1" >&2; exit 64 ;;
  esac
done
cd "$REPO" || exit 64
REPO="$(pwd -P)"
fm_freeze "$0" "$REPO" ${fm_args[@]+"${fm_args[@]}"}
# The reviewer's engine is the captain's to choose. A project that names none
# is said out loud here, once per start, rather than reviewed by whatever the
# top-level vendor happens to be: firstmate asks on the board and the answer
# lands in config.yaml through a pull request.
if [ "$MODE" = start ]; then
  rv="$(fm_cfg_in reviewer vendor)"; rmodel="$(fm_cfg_in reviewer model)"
  if [ -z "$rv" ] || [ -z "$rmodel" ]; then
    installed=''
    for a in "${FM_CODE_ROOT:-$REPO}"/bin/adapters/*.sh; do
      a="${a##*/}"; a="${a%.sh}"
      case "$a" in _*|mock) continue ;; esac
      command -v "$a" >/dev/null 2>&1 && installed="${installed:+$installed }$a"
    done
    missing=''
    [ -n "$rv" ] || missing=vendor
    [ -n "$rmodel" ] || missing="${missing:+$missing and }model"
    echo "fm-session: config.yaml names no reviewer $missing; the reviewer is the captain's choice - ask on the board (installed adapters: ${installed:-none})" >&2
  fi
fi
exec python3 "${FM_CODE_ROOT:-$REPO}/bin/fm-herdr.py" session "$MODE" "$REPO" "$DECISION"
