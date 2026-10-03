#!/usr/bin/env bash
# Operator entry point; does not merge, approve, or start an agent.
set -euo pipefail
exec </dev/null
stack_bin="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
[ -f "$stack_bin/fm-config.sh" ] || { echo "${0##*/}: missing $stack_bin/fm-config.sh" >&2; exit 70; }
# shellcheck source=bin/fm-config.sh
. "$stack_bin/fm-config.sh"
# shellcheck source=bin/lib/fm-stack.sh
. "$stack_bin/lib/fm-stack.sh"
REPO="${FM_ROOT:-$(pwd)}"
stack_args=()
while [ $# -gt 0 ]; do
  case "$1" in
    --repo) fm_need fm-restack "$@"; REPO="$2"; shift 2 ;;
    --project) fm_need fm-restack "$@"; export FM_PROJECT="$2"; shift 2 ;;
    --pr|--parent|--expected-head) fm_need fm-restack "$@"; stack_args+=("$1" "$2"); shift 2 ;;
    *) echo "fm-restack: unknown argument $1" >&2; exit 64 ;;
  esac
done
fm_storage_init "$REPO"
fm_target_validate
fm_stack restack "${stack_args[@]}"
