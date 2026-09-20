#!/usr/bin/env bash
# No one on this crew writes to main. Not firstmate, not a worker, not a
# reviewer, not the captain's own agent. Work happens on a branch and arrives
# through a pull request, every time.
#
#   bin/fm-guard.sh branch            refuse if the current branch is protected
#   bin/fm-guard.sh branch <dir>      ...in another worktree
#   . bin/fm-guard.sh                 then call fm_guard_branch yourself
set -uo pipefail
# Nothing below may read standard input. A dispatched child inherits it, and
# a child that reads it blocks the caller waiting for a human who is not
# there. One guarantee, in one place; bin/ci.sh fails if a script that
# dispatches is missing it.
exec < /dev/null

FM_PROTECTED="${FM_PROTECTED:-main master}"

fm_guard_branch() {
  local dir="${1:-.}" b
  b=$(git -C "$dir" branch --show-current 2>/dev/null) || {
    printf 'fm-guard: %s is not a git worktree\n' "$dir" >&2; return 2; }
  if [ -z "$b" ]; then
    printf 'fm-guard: detached HEAD in %s - refusing to write\n' "$dir" >&2; return 1
  fi
  for p in $FM_PROTECTED; do
    if [ "$b" = "$p" ]; then
      printf 'fm-guard: refusing to work on %s.\n' "$b" >&2
      printf '          branch first, then open a pull request.\n' >&2
      return 1
    fi
  done
  return 0
}

# only act when run, not when sourced
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  case "${1-}" in
    branch) fm_guard_branch "${2:-.}" ;;
    *) printf 'usage: fm-guard.sh branch [dir]\n' >&2; exit 2 ;;
  esac
fi
