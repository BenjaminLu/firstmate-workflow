#!/usr/bin/env bash
# Outside-round external evidence/projection entrypoint. No merge or dispatch.
set -uo pipefail
exec < /dev/null
_fm_lib="$(dirname "${BASH_SOURCE[0]}")/fm-config.sh"
[ -f "$_fm_lib" ] || { echo "${0##*/}: missing $_fm_lib" >&2; exit 70; }
# shellcheck source=bin/fm-config.sh
. "$_fm_lib"
COMMAND=''
case "${1:-}" in collect|project) COMMAND="$1"; shift ;; esac
REPO="$(fm_default_repo)"; TASK=''; PR=''; BRANCH=''; extra=()
while [ $# -gt 0 ]; do
  case "$1" in
    --project) fm_need fm-external "$@"; export FM_PROJECT="$2"; shift 2 ;;
    --repo) fm_need fm-external "$@"; REPO="$2"; shift 2 ;;
    --task) fm_need fm-external "$@"; TASK="$2"; shift 2 ;;
    --pr) fm_need fm-external "$@"; PR="$2"; shift 2 ;;
    --branch) fm_need fm-external "$@"; BRANCH="$2"; shift 2 ;;
    --replies|--text|--stage) fm_need fm-external "$@"; extra+=("$1" "$2"); shift 2 ;;
    *) echo "fm-external: unknown argument $1" >&2; exit 64 ;;
  esac
done
case "$COMMAND" in collect|project) ;; *) echo 'usage: fm-external.sh collect|project --project P --task T --pr N --branch B [--replies private.json]' >&2; exit 64 ;; esac
[ -n "$TASK" ] && [ -n "$PR" ] && [ -n "$BRANCH" ] || exit 64
fm_storage_init "$REPO" || exit 65
[ "$FM_EXTERNAL" = 1 ] || { echo 'fm-external: external project required' >&2; exit 65; }
fm_target_validate || exit 65
fm_conventions '' >/dev/null || exit 65
head="$(fm_binding head --task "$TASK" --pr "$PR" --branch "$BRANCH")" || exit 65
fm_external "$COMMAND" --pr "$PR" --head "$head" ${extra[@]+"${extra[@]}"}
