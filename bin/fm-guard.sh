#!/usr/bin/env bash
# fm:sourced  # this file is sourced; see bin/ci.sh, stdin stage
# No one on this crew writes to main. Not firstmate, not a worker, not a
# reviewer, not the captain's own agent. Work happens on a branch and arrives
# through a pull request, every time.
#
#   bin/fm-guard.sh branch            refuse if the current branch is protected
#   bin/fm-guard.sh branch <dir>      ...in another worktree
#   . bin/fm-guard.sh                 then call fm_guard_branch yourself
set -uo pipefail
# No `exec < /dev/null` here, and bin/ci.sh exempts this file by name. The
# usage above offers this file to be sourced, and a redirect in a sourced
# file belongs to the caller for the rest of its life - a pre-push hook that
# sourced it would lose the ref list it is given on standard input. The
# guarantee belongs on entry points, and this is also a library.

FM_PROTECTED="${FM_PROTECTED:-main master}"

# A managed clone of a target records its project's base as firstmate.base
# in its local config (bin/fm-project.sh sync), and that branch is protected
# on top of FM_PROTECTED. The self project has no such key, so its set is
# unchanged.
fm_guard_protected() {   # fm_guard_protected [dir] -> the protected branches
  local base
  base=$(git -C "${1:-.}" config --local --get firstmate.base 2>/dev/null || true)
  printf '%s %s\n' "$FM_PROTECTED" "$base"
}

fm_guard_branch() {
  local dir="${1:-.}" b protected
  b=$(git -C "$dir" branch --show-current 2>/dev/null) || {
    printf 'fm-guard: %s is not a git worktree\n' "$dir" >&2; return 2; }
  if [ -z "$b" ]; then
    printf 'fm-guard: detached HEAD in %s - refusing to write\n' "$dir" >&2; return 1
  fi
  protected=$(fm_guard_protected "$dir")
  for p in $protected; do
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
    *) printf 'usage: fm-guard.sh branch [dir]\n' >&2; exit 64 ;;
  esac
fi
