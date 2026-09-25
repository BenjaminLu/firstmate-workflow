#!/usr/bin/env bash
# A target's managed clone, and whether the target is fit to be driven
# (design 15.1 and 15.6).
#
#   fm-project.sh sync <name>   [--repo <engine root>]
#   fm-project.sh verify <name> [--repo <engine root>]
#
# sync clones the project's GitHub repository into
# state/projects/<name>/repo, or fetches and prunes the clone that is
# there; points the clone's local core.hooksPath at the engine's .githooks/,
# records the project's base as firstmate.base for the guard, and keeps
# `.fm-*` in the clone's .git/info/exclude. It writes nothing into the
# target's tree and never runs git in a directory that is not that clone.
#
# verify exits 70, naming every missing item, unless the base is protected
# with enforce_admins on, up to date required and required_check a required
# status check; the repository is public (15.8); and the clone's origin is
# the project's repository and its hooks and guard are the engine's. For the
# self project (`repo: .`) both are no-ops that succeed.
#
# FM_GITHUB_URL is where `owner/repo` is cloned from: https://github.com
# unless a fixture stands a local directory in for GitHub.
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

REPO="${FM_ROOT:-$(pwd)}"; GH="${FM_GH:-gh}"; URL="${FM_GITHUB_URL:-https://github.com}"
usage() { echo "usage: fm-project.sh sync|verify <name> [--repo dir]" >&2; exit 64; }
words=()
while [ $# -gt 0 ]; do
  case "$1" in
    --repo) fm_need "fm-project" "$@"; REPO="${2-}"; shift 2 ;;
    -*) echo "fm-project: unknown argument $1" >&2; exit 64 ;;
    *) words+=("$1"); shift ;;
  esac
done
[ "${#words[@]}" -eq 2 ] || usage
CMD="${words[0]}"; NAME="${words[1]}"
case "$CMD" in sync|verify) ;; *) usage ;; esac

REPO="$(cd "$REPO" 2>/dev/null && pwd -P)" || { echo "fm-project: no engine root at $REPO" >&2; exit 64; }
CFG="$REPO/config.yaml"
# the registry refuses an unregistered or malformed name with 65 and says why
repo_field="$(fm_project_get "$NAME" repo "$CFG")" || exit
if [ "$repo_field" = . ]; then
  echo "fm-project: $NAME is the engine itself; nothing to $CMD"
  exit 0
fi
github="$(fm_project_get "$NAME" github "$CFG")" || exit
base="$(fm_project_get "$NAME" base "$CFG")" || exit
check="$(fm_project_get "$NAME" required_check "$CFG")" || exit
hooks="$REPO/.githooks"
home="$REPO/state/projects/$NAME"
clone="$home/repo"
origin="$URL/$github.git"

# The clone is the only checkout this script may run git in. A directory
# standing where the clone belongs that is not a repository of its own is
# inside the ENGINE's checkout, and git there would find the engine: fetch
# it, hook it, exclude in it. A symlink could lead anywhere, including the
# captain's own checkout of the target. So no step of the path below the
# engine root may be a symlink (REPO is already physical, and a registered
# name is [a-z0-9-], so nothing else can lead out), and the repository is
# checked by its own top level and git directory.
place_ok() {
  local p
  for p in "$REPO/state" "$REPO/state/projects" "$home" "$clone"; do
    [ ! -L "$p" ] || {
      echo "fm-project: refusing $clone - $p is a symlink out of the engine's state/projects/" >&2
      return 1; }
  done
}
is_clone() {   # the clone exists and is a repository of its own, not a directory in another
  [ -d "$clone/.git" ] || return 1
  [ "$(git -C "$clone" rev-parse --show-toplevel 2>/dev/null)" = "$clone" ] || return 1
  [ "$(cd "$clone" && cd "$(git rev-parse --git-dir 2>/dev/null)" 2>/dev/null && pwd -P)" = "$clone/.git" ]
}
# The hooks directory git itself would run in the clone. Git expands `~` in
# core.hooksPath and reads a relative one from the clone's top level, so the
# answer is git's, resolved from inside the clone, never from the caller's
# directory.
clone_hooks() {
  local gp
  gp="$(git -C "$clone" rev-parse --git-path hooks 2>/dev/null)" || return 1
  ( cd "$clone" && cd "$gp" 2>/dev/null && pwd -P )
}

sync_clone() {
  place_ok || exit 70
  [ -d "$hooks" ] || { echo "fm-project: the engine has no .githooks/ at $hooks" >&2; exit 70; }
  if [ -e "$clone" ]; then
    is_clone || { echo "fm-project: refusing $clone - it is not a clone of its own" >&2; exit 70; }
    have="$(git -C "$clone" remote get-url origin 2>/dev/null || true)"
    [ "$have" = "$origin" ] || {
      echo "fm-project: refusing $clone - its origin is '$have', not $origin" >&2; exit 70; }
    git -C "$clone" fetch -q --prune origin || {
      echo "fm-project: could not fetch $origin into $clone" >&2; exit 1; }
    echo "fm-project: fetched and pruned $NAME"
  else
    mkdir -p "$home" && place_ok || exit 70
    git clone -q "$origin" "$clone" || { echo "fm-project: could not clone $origin" >&2; exit 1; }
    is_clone || { echo "fm-project: $clone did not come out a clone of its own" >&2; exit 70; }
    echo "fm-project: cloned $github into $clone"
  fi
  # local config and .git/info only: nothing in the target's tree
  git -C "$clone" config --local core.hooksPath "$hooks" \
    && git -C "$clone" config --local firstmate.base "$base" || {
      echo "fm-project: could not configure $clone" >&2; exit 1; }
  mkdir -p "$clone/.git/info"
  local ex="$clone/.git/info/exclude"
  if ! grep -qxF '.fm-*' "$ex" 2>/dev/null; then
    # an exclude file without a final newline would glue the line onto its last pattern
    if [ -s "$ex" ] && [ -n "$(tail -c 1 "$ex")" ]; then printf '\n' >> "$ex"; fi
    printf '%s\n' '.fm-*' >> "$ex"
  fi
  exit 0
}

missing=()
miss() { missing+=("$1"); }
gh_message() { jq -r '.message // empty' 2>/dev/null <<< "$1"; }

verify_target() {
  local out msg
  # --- base protection ---------------------------------------------------
  if out="$($GH api "repos/$github/branches/$base/protection" 2>/dev/null </dev/null)"; then
    [ "$(jq -r '.enforce_admins.enabled == true' <<< "$out" 2>/dev/null)" = true ] \
      || miss "base $base: enforce_admins is not on"
    [ "$(jq -r '.required_status_checks.strict == true' <<< "$out" 2>/dev/null)" = true ] \
      || miss "base $base: branches are not required to be up to date before merging"
    [ "$(jq -r --arg c "$check" \
          '[(.required_status_checks.contexts // [])[], ((.required_status_checks.checks // [])[] | .context)]
           | any(.[]; . == $c)' <<< "$out" 2>/dev/null)" = true ] \
      || miss "base $base: required_check '$check' is not a required status check"
  else
    msg="$(gh_message "$out")"
    case "$msg" in
      'Branch not protected') miss "base $base is not protected" ;;
      *) miss "cannot read branch protection for $github $base${msg:+: $msg}" ;;
    esac
  fi
  # --- public only, until the captain decides (15.8) ---------------------
  if out="$($GH api "repos/$github" 2>/dev/null </dev/null)"; then
    [ "$(jq -r '.private == false and .visibility == "public"' <<< "$out" 2>/dev/null)" = true ] \
      || miss "repository $github is not public; private projects wait for a captain decision (design 15.8)"
  else
    msg="$(gh_message "$out")"
    miss "cannot read repository $github${msg:+: $msg}"
  fi
  # --- the guard in the managed clone ------------------------------------
  local why
  if ! why="$(place_ok 2>&1)"; then
    # sync would refuse the same place, so advising it would only lead to a second 70
    miss "${why#fm-project: }"
  elif ! is_clone; then
    miss "no managed clone at state/projects/$NAME/repo; run fm-project.sh sync $NAME"
  else
    local hp gb og want
    og="$(git -C "$clone" remote get-url origin 2>/dev/null || true)"
    [ "$og" = "$origin" ] \
      || miss "the clone's origin is '${og}', not $origin"
    hp="$(git -C "$clone" config --local --get core.hooksPath 2>/dev/null || true)"
    want="$(cd "$hooks" 2>/dev/null && pwd -P)"
    [ -n "$hp" ] && [ -n "$want" ] && [ "$(clone_hooks)" = "$want" ] \
      || miss "the clone's core.hooksPath is '${hp}', so git there does not run the engine's $hooks"
    gb="$(git -C "$clone" config --local --get firstmate.base 2>/dev/null || true)"
    [ "$gb" = "$base" ] \
      || miss "the clone's firstmate.base is '${gb}', so the guard does not protect $base"
  fi
  if [ "${#missing[@]}" -gt 0 ]; then
    for msg in "${missing[@]}"; do echo "fm-project: $NAME is not ready: $msg" >&2; done
    exit 70
  fi
  echo "fm-project: $NAME verified"
  exit 0
}

case "$CMD" in
  sync) sync_clone ;;
  verify) verify_target ;;
esac
