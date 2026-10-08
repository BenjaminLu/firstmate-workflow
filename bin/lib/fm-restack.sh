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
child_pr=''
while [ $# -gt 0 ]; do
  case "$1" in
    --repo) fm_need fm-restack "$@"; REPO="$2"; shift 2 ;;
    --project) fm_need fm-restack "$@"; export FM_PROJECT="$2"; shift 2 ;;
    --pr) fm_need fm-restack "$@"; child_pr="$2"; stack_args+=("$1" "$2"); shift 2 ;;
    --parent|--expected-head) fm_need fm-restack "$@"; stack_args+=("$1" "$2"); shift 2 ;;
    *) echo "fm-restack: unknown argument $1" >&2; exit 64 ;;
  esac
done
fm_storage_init "$REPO"
fm_target_validate
adopted_task="$(python3 "$stack_bin/lib/fm_adopt.py" task-of --pr "$child_pr")"
status=0
fm_stack restack "${stack_args[@]}" || status=$?
if [ "$status" = 71 ]; then
  echo 'restack push outcome unknown; check the PR head, then repin adopt.head with a new spec and A card' >&2
elif [ -n "$adopted_task" ] && { [ "$status" = 0 ] || [ "$status" = 69 ]; }; then
  if ! FM_ROOT="$REPO" "$stack_bin/fm-emit.sh" --actor firstmate --type commit_pushed \
      --project "${FM_PROJECT:-}" \
      --task "$adopted_task" --pr "$child_pr" \
      --data "{\"restacked\":true,\"adopt_pr\":$child_pr}" \
      --en "$adopted_task #$child_pr: adopted child restacked" \
      --tw "$adopted_task #$child_pr 已重設接手子 PR 的基底"; then
    echo 'restack published but event retention failed; synchronize the head and repin adoption before retry' >&2
    exit 71
  fi
fi
exit "$status"
