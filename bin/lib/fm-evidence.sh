#!/usr/bin/env bash
# Operator entrypoint: resolve private project state before retaining a brief.
set -euo pipefail
config_lib="$(dirname "${BASH_SOURCE[0]}")/../fm-config.sh"
[ -f "$config_lib" ] || { echo "${0##*/}: missing $config_lib" >&2; exit 70; }
# shellcheck source=bin/fm-config.sh
. "$config_lib"
REPO="$(fm_default_repo)"; TASK=''
args=()
while [ $# -gt 0 ]; do
  case "$1" in
    --repo) fm_need fm-evidence "$@"; REPO="${2-}"; shift 2 ;;
    --project) fm_need fm-evidence "$@"; export FM_PROJECT="${2-}"; shift 2 ;;
    --task) fm_need fm-evidence "$@"; TASK="${2-}"; shift 2 ;;
    # These are Python reader/writer options, not wrapper-owned values.
    # Keep their values in args on the following iteration; fm_need rejects
    # a missing or option-shaped value before it can enter that iteration.
    --round|--head|--base|--patch|--actor|--file|--run|--attempt|--code|--vendor)
      fm_need fm-evidence "$@"; args+=("$1"); shift ;;
    --reviewer) args+=("$1"); shift ;;
    -*) echo "fm-evidence: unknown argument $1" >&2; exit 64 ;;
    *) args+=("$1"); shift ;;
  esac
done
[ -n "$TASK" ] || { echo 'fm-evidence: --task is required' >&2; exit 64; }
fm_storage_init "$REPO"
fm_evidence "${args[@]}"
