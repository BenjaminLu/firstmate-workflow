#!/usr/bin/env bash
# Scripted supervision only. Never merges or runs a model on an idle timer.
set -euo pipefail
exec < /dev/null
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
[ -f "$HERE/fm-config.sh" ] || { echo "fm-autopilot: missing $HERE/fm-config.sh" >&2; exit 70; }
# shellcheck source=bin/fm-config.sh
. "$HERE/fm-config.sh"
# shellcheck source=bin/lib/fm-stack.sh
. "$HERE/lib/fm-stack.sh"
pilot_args=("$@")
MODE=ensure; REPO="${FM_ROOT:-$(cd "$HERE/.." && pwd)}"; ALL=0; RESUME=0
while [ $# -gt 0 ]; do
  case "$1" in
    ensure|serve|status|context) MODE="$1"; shift ;;
    --all) ALL=1; shift ;;
    --resume) RESUME=1; shift ;;
    --repo) fm_need fm-autopilot "$@"; REPO="$2"; shift 2 ;;
    --project) fm_need fm-autopilot "$@"; export FM_PROJECT="$2"; shift 2 ;;
    *) echo "fm-autopilot: unknown argument $1" >&2; exit 64 ;;
  esac
done
# Crew commands must not start another supervisor or write session state.
[ -z "${FM_IN_ROUND:-}" ] || exit 0
# CI's owner survives fixtures that scrub FM_*; supervision requires opt-in.
if [ -n "${FIRSTMATE_CI_SESSION:-}" ] && [ "${FM_AUTOPILOT_TEST_ENABLE:-0}" != 1 ]; then
  exit 0
fi
REPO="$(cd "$REPO" && pwd -P)"
if [ "$ALL" = 1 ]; then
  names="$(fm_projects "$REPO/config.yaml")"
  if [ -n "$names" ]; then
    result=0
    for name in $names; do
      if [ "$RESUME" = 1 ]; then
        "$HERE/fm-autopilot.sh" "$MODE" --resume --repo "$REPO" --project "$name" || result=1
      else
        "$HERE/fm-autopilot.sh" "$MODE" --repo "$REPO" --project "$name" || result=1
      fi
    done
    exit "$result"
  fi
fi
fm_storage_init "$REPO"
[ "$RESUME" = 0 ] || [ -f "$FM_STATE_DIR/autopilot/owner.json" ] || exit 0
FM_AUTOPILOT_REPOSITORY="$(fm_stack_repository)"
FM_EVIDENCE_PROJECT="$(fm_evidence_project)"
FM_AUTOPILOT_DEFAULT_PROJECT="$(FM_PROJECT='' fm_project_resolve '' "$REPO/config.yaml" 2>/dev/null || true)"
export FM_AUTOPILOT_REPOSITORY FM_EVIDENCE_PROJECT FM_AUTOPILOT_DEFAULT_PROJECT
pilot_base="$(fm_project_get "${FM_PROJECT:-}" base "$REPO/config.yaml" 2>/dev/null || true)"
export FM_BASE="${pilot_base:-main}"
if [ "$MODE" = ensure ]; then
  # An already running service needs no new code snapshot on each command.
  if python3 "$HERE/lib/fm_autopilot.py" running; then exit 0; fi
fi
if [ "$MODE" = ensure ] || [ "$MODE" = serve ]; then
  fm_freeze "$0" "$REPO" ${pilot_args[@]+"${pilot_args[@]}"}
fi
export FM_CODE_ROOT="${FM_CODE_ROOT:-$(cd "$HERE/.." && pwd)}"
exec python3 "$HERE/lib/fm_autopilot.py" "$MODE"
