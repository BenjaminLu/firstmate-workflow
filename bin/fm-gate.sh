#!/usr/bin/env bash
# The seven gates. Every one of them reads the filesystem, git, or an exit
# code. None of them reads what a model said about its own work.
#
#   fm-gate.sh --task T-004 --repo <dir> --branch <name> [--pr 9] [--only N]
#
# Exits 0 when all seven pass, otherwise the number of the gate that failed.
# The exit code is the gate number so a caller can tell "the tests are vacuous"
# from "the reviewer never signed".
set -uo pipefail
# Nothing below may read standard input. A dispatched child inherits it, and
# a child that reads it blocks the caller waiting for a human who is not
# there. One guarantee, in one place; bin/ci.sh fails if a script that
# dispatches is missing it.
exec < /dev/null

REPO=''; TASK=''; BRANCH=''; PR=''; ONLY=''
BASE="${FM_BASE:-main}"
GH="${FM_GH:-gh}"
REVIEWER="${FM_REVIEWER_LOGIN:-}"

while [ $# -gt 0 ]; do
  case "$1" in
    --task) TASK="${2-}"; shift 2 ;;
    --repo) REPO="${2-}"; shift 2 ;;
    --branch) BRANCH="${2-}"; shift 2 ;;
    --pr) PR="${2-}"; shift 2 ;;
    --only) ONLY="${2-}"; shift 2 ;;
    *) echo "fm-gate: unknown argument $1" >&2; exit 64 ;;
  esac
done
[ -n "$TASK" ] && [ -n "$REPO" ] && [ -n "$BRANCH" ] || {
  echo "usage: fm-gate.sh --task <id> --repo <dir> --branch <name> [--pr N] [--only N]" >&2; exit 64; }

say()  { printf '  %s gate %s: %s\n' "$1" "$2" "$3"; }
want() { [ -z "$ONLY" ] || [ "$ONLY" = "$1" ]; }

g() {   # g <n> <description> ; body reads stdin-free, returns 0/1
  local n="$1"
  want "$n" || return 0
  shift 1
  local desc="$1"; shift
  if "$@"; then say '+' "$n" "$desc"; return 0; fi
  say 'x' "$n" "$desc"; exit "$n"
}

cd "$REPO" || { echo "fm-gate: no repo at $REPO" >&2; exit 64; }

# ---- 1. the branch exists and carries work -------------------------------
gate1() {
  git rev-parse --verify "$BRANCH" >/dev/null 2>&1 || return 1
  [ "$(git rev-list --count "$BASE..$BRANCH" 2>/dev/null || echo 0)" -gt 0 ]
}

# ---- 2. it rebases onto the base cleanly ---------------------------------
gate2() {
  local w rc
  w="$(mktemp -d)"
  git worktree add -q --detach "$w" "$BRANCH" 2>/dev/null || { rm -rf "$w"; return 1; }
  ( cd "$w" && git rebase "$BASE" >/dev/null 2>&1 ); rc=$?
  ( cd "$w" && git rebase --abort >/dev/null 2>&1 )
  git worktree remove --force "$w" >/dev/null 2>&1; rm -rf "$w"
  return "$rc"
}

# ---- 3. the one gate exits 0 ---------------------------------------------
gate3() {
  local w rc
  w="$(mktemp -d)"
  git worktree add -q --detach "$w" "$BRANCH" >/dev/null 2>&1 || { rm -rf "$w"; return 1; }
  [ -x "$w/bin/ci.sh" ] || { git worktree remove --force "$w" >/dev/null 2>&1; rm -rf "$w"; return 1; }
  ( cd "$w" && FM_ROOT="$w" ./bin/ci.sh >/dev/null 2>&1 ); rc=$?
  git worktree remove --force "$w" >/dev/null 2>&1; rm -rf "$w"
  return "$rc"
}

changed() { git diff --name-only "$BASE...$BRANCH"; }
is_test()  { case "$1" in tests/*|*.test.*|*.spec.*) return 0 ;; *) return 1 ;; esac; }

# ---- 4. the diff stays inside the task's declared scope ------------------
gate4() {
  local scopes f ok
  scopes="$(jq -r --arg t "$TASK" '.tasks[]|select(.id==$t)|.scope[]' design/tasks.json 2>/dev/null)"
  [ -n "$scopes" ] || return 1          # a task with no declared scope cannot be gated
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    ok=1
    while IFS= read -r s; do
      [ -n "$s" ] || continue
      # shellcheck disable=SC2254
      case "$f" in $s) ok=0; break ;; esac
      case "$s" in */\*\*) case "$f" in "${s%/**}"/*) ok=0; break ;; esac ;; esac
    done <<< "$scopes"
    [ "$ok" -eq 0 ] || { echo "      out of scope: $f" >&2; return 1; }
  done <<< "$(changed)"
  return 0
}

# ---- 5. the new tests are not vacuous ------------------------------------
# Revert the implementation to the base and the new tests must go red. A test
# that still passes without the code it is meant to cover is testing nothing.
gate5() {
  local w impl tests f rc
  impl=''; tests=''
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    if is_test "$f"; then tests="$tests$f"$'\n'; else impl="$impl$f"$'\n'; fi
  done <<< "$(changed)"
  # nothing executable changed - a docs or design task has nothing to make red
  [ -n "$(printf '%s' "$impl" | tr -d '[:space:]')" ] || return 0
  [ -n "$(printf '%s' "$tests" | tr -d '[:space:]')" ] || {
    echo "      the diff changes implementation but adds no test" >&2; return 1; }

  w="$(mktemp -d)"
  git worktree add -q --detach "$w" "$BRANCH" >/dev/null 2>&1 || { rm -rf "$w"; return 1; }
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    ( cd "$w" && git checkout "$BASE" -- "$f" >/dev/null 2>&1 || rm -f "$f" )
  done <<< "$impl"

  rc=1                                   # assume vacuous until one test goes red
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    [ -f "$w/$f" ] || continue
    case "$f" in
      *.test.sh) ( cd "$w" && FM_ROOT="$w" bash "$f" >/dev/null 2>&1 ) || { rc=0; break ;} ;;
    esac
  done <<< "$tests"

  git worktree remove --force "$w" >/dev/null 2>&1; rm -rf "$w"
  [ "$rc" -eq 0 ] || echo "      the new tests still pass with the implementation reverted" >&2
  return "$rc"
}

# ---- 6. the required GitHub check is green -------------------------------
is_num() { case "$1" in ''|*[!0-9]*) return 1 ;; *) return 0 ;; esac; }

gate6() {
  is_num "$PR" || return 1
  $GH pr checks "$PR" --required >/dev/null 2>&1
}

# ---- 7. the reviewer signed, and it was the reviewer ---------------------
gate7() {
  is_num "$PR" || return 1
  local body
  body="$($GH pr view "$PR" --json comments --jq \
    '.comments[]|select(.body|test("APPROVE:'"$TASK"'"))|.author.login' 2>/dev/null)"
  [ -n "$body" ] || return 1
  [ -z "$REVIEWER" ] && return 0
  grep -qx "$REVIEWER" <<< "$body"
}

g 1 "branch exists and carries commits"          gate1
g 2 "rebases onto $BASE cleanly"                 gate2
g 3 "bin/ci.sh exits 0"                          gate3
g 4 "diff stays inside the declared scope"       gate4
g 5 "reverting the implementation turns tests red" gate5
g 6 "the required GitHub check is green"         gate6
g 7 "the reviewer posted APPROVE:$TASK"          gate7
echo "  all seven gates green"
exit 0
