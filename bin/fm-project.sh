#!/usr/bin/env bash
# A target's managed clone, and whether the target is fit to be driven
# (design 15.1 and 15.6).
#
#   fm-project.sh sync <name>   [--repo <engine root>]
#   fm-project.sh verify <name> [--repo <engine root>]
#
# sync clones the project's GitHub repository into
# FM_HOME/projects/<name>/repo, or fetches and prunes the clone that is
# there; points the clone's local core.hooksPath at the engine's .githooks/,
# records the project's base as firstmate.base for the guard, and keeps
# `.fm-*` in the clone's .git/info/exclude. It writes nothing into the
# target's tree and never runs git in a directory that is not that clone.
#
# verify exits 70, naming every missing item, unless the base is protected
# with enforce_admins on, up to date required and required_check a required
# status check; and the clone's origin is
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

REPO="${FM_ROOT:-$(pwd)}"; MIGRATE=0; GH="${FM_GH:-gh}"; URL="${FM_GITHUB_URL:-https://github.com}"
usage() { echo "usage: fm-project.sh sync|verify <name> [--migrate] [--repo dir]; history on <name> [--repo dir]" >&2; exit 64; }
words=()
while [ $# -gt 0 ]; do
  case "$1" in
    --migrate) MIGRATE=1; shift ;;
    --repo) fm_need "fm-project" "$@"; REPO="${2-}"; shift 2 ;;
    -*) echo "fm-project: unknown argument $1" >&2; exit 64 ;;
    *) words+=("$1"); shift ;;
  esac
done
if [ "${#words[@]}" -eq 3 ] && [ "${words[0]}" = history ] && [ "${words[1]}" = on ]; then
  CMD=history; NAME="${words[2]}"
else
  [ "${#words[@]}" -eq 2 ] || usage
  CMD="${words[0]}"; NAME="${words[1]}"
fi
case "$CMD" in sync|verify|history) ;; *) usage ;; esac

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
project_home="$(fm_project_get "$NAME" home "$CFG")" || exit 65
clone="$project_home/repo"
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
  local resolved
  resolved="$(fm_project_get "$NAME" home "$CFG")" || return 65
  [ "$resolved" = "$project_home" ] || return 65
}

is_clone() {   # the clone exists and is a repository of its own, not a directory in another
  [ -d "$clone/.git" ] && [ ! -L "$clone/.git" ] || return 1
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
  place_ok || exit 65
  [ -d "$hooks" ] || { echo "fm-project: the engine has no .githooks/ at $hooks" >&2; exit 70; }
  if [ -e "$clone" ]; then
    is_clone || { echo "fm-project: refusing $clone - it is not a clone of its own" >&2; exit 70; }
    have="$(git -C "$clone" remote get-url origin 2>/dev/null || true)"
    [ "$have" = "$origin" ] || {
      echo "fm-project: refusing $clone - its origin is '$have', not $origin" >&2; exit 70; }
    [ "$(git -C "$clone" remote get-url --push origin 2>/dev/null)" = "$origin" ] || {
      echo 'fm-project: refusing mismatched push origin' >&2; exit 65; }
    git -C "$clone" fetch -q --prune origin || {
      echo "fm-project: could not fetch $origin into $clone" >&2; exit 1; }
    echo "fm-project: fetched and pruned $NAME"
  else
    mkdir -p "$project_home" && place_ok || exit 65
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

# Migration is explicit and same-filesystem rename only. A refused cross-device
# rename leaves the complete source intact; copying then deleting is not safe.
legacy="$REPO/state/projects/$NAME"
if [ -e "$legacy" ] || [ -L "$legacy" ]; then
  if [ "$CMD" != sync ] || [ "$MIGRATE" != 1 ]; then
    echo "fm-project: legacy records at $legacy; sync --migrate requires the operator's approval" >&2
    exit 65
  fi
  python3 - "$legacy" "$project_home" "$origin" <<'PYM'
import os, pathlib, subprocess, sys
source, target = map(pathlib.Path, sys.argv[1:3])
try:
    for path in (source, *source.parents):
        if path.is_symlink(): raise ValueError('legacy parent is a symlink')
    if target.exists(): raise ValueError('destination already exists; retain both stores for recovery')
    for rel in ('repo', 'worktrees', 'tasks', 'design.md', 'CONVENTIONS.md', 'state',
                'repo/.git', 'repo/.git/config', 'repo/.git/info', 'repo/.git/info/exclude'):
        if (source / rel).is_symlink(): raise ValueError('legacy routing path is a symlink: ' + rel)
    for directory in (source / 'state', source / 'tasks'):
        if directory.exists() and any(path.is_symlink() for path in directory.rglob('*')):
            raise ValueError('legacy records contain a symlink; reconcile before migration')
    repo = source / 'repo'
    if not (repo / '.git').is_dir() or (repo / '.git').is_symlink():
        raise ValueError('legacy clone has no independent git directory')
    def git(*args):
        return subprocess.check_output(['git', '-C', str(repo), *args], text=True).strip()
    if git('rev-parse', '--show-toplevel') != str(repo): raise ValueError('legacy clone root mismatch')
    if git('remote', 'get-url', 'origin') != sys.argv[3]: raise ValueError('legacy origin mismatch')
    # Registered worktrees contain absolute git links. Do not migrate a live or
    # retained checkout behind its owner; the captain must retire it first.
    if len([line for line in git('worktree', 'list', '--porcelain').splitlines()
            if line.startswith('worktree ')]) != 1:
        raise ValueError('legacy worktrees must be retired before migration')
    if any(source.rglob('process.json')) or any(source.rglob('*.pid')):
        raise ValueError('legacy ownership records require reconciliation before migration')
    # Do not report a complete move when older shared stores still carry
    # this project's private records. Their ambiguous ownership needs the
    # operator to consolidate them into the retained project store first.
    engine = source.parents[2]
    separated = [engine / 'projects' / source.name]
    separated += [engine / 'state' / kind / source.name
                  for kind in ('mirrors', 'pins', 'evidence', 'decision-ids')]
    separated += list((engine / 'state').glob('*/D-' + source.name + '-*'))
    if any(path.exists() or path.is_symlink() for path in separated):
        raise ValueError('separate legacy project records require consolidation before migration')
    import json
    events = engine / 'state/events.jsonl'
    if events.exists():
        for line in events.read_text().splitlines():
            if line.strip() and json.loads(line).get('project') == source.name:
                raise ValueError('legacy shared events require consolidation before migration')
    for identity in (engine / 'state/runs').glob('*/identity.json'):
        if json.loads(identity.read_text()).get('project') == source.name:
            raise ValueError('legacy shared run records require consolidation before migration')
    def inventory(directory):
        result = {}
        for path in directory.rglob('*'):
            st = path.lstat()
            result[str(path.relative_to(directory))] = (st.st_dev, st.st_ino, st.st_mode, st.st_size)
        return result
    retained = inventory(source)
    target.parent.mkdir(parents=True, exist_ok=True)
    os.rename(source, target)
    # Rename preserves every byte and record atomically, including untracked
    # files. On verification failure rollback is another atomic rename.
    try:
        if not (target / 'repo/.git').is_dir(): raise ValueError('retained clone missing')
        if inventory(target) != retained: raise ValueError('retained records changed during migration')
    except Exception:
        os.rename(target, source)
        raise
except (OSError, ValueError, subprocess.SubprocessError) as error:
    print('fm-project: migration refused: ' + str(error), file=sys.stderr)
    sys.exit(65)
PYM
  [ "$?" -eq 0 ] || exit 65
fi

if [ "$CMD" = history ]; then
  place_ok || exit 65
  mkdir -p "$project_home" || exit 70
  [ ! -L "$project_home/.git" ] || exit 65
  { [ ! -e "$project_home/.git" ] || [ -d "$project_home/.git" ]; } || exit 65
  if [ ! -e "$project_home/.git" ]; then
    git -C "$project_home" init -q || exit 70
  fi
  [ "$(git -C "$project_home" rev-parse --show-toplevel)" = "$project_home" ] || exit 65
  [ -z "$(git -C "$project_home" remote)" ] || {
    echo 'fm-project: project history must have no remotes' >&2; exit 65; }
  printf '/repo/\n/worktrees/\n/state/\n' >> "$project_home/.git/info/exclude"
  echo "fm-project: local history enabled at $project_home"
  exit 0
fi

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
      *)
        if ! jq -e --arg repo "$github" --arg base "$base" --arg check "$check" '
          .captain_confirmed == true and .repository == $repo and .base == $base
          and (.required_checks | index($check) != null) and (.policy_confirmed == true)
        ' "$project_home/state/protection-confirmation.json" >/dev/null 2>&1; then
          miss "branch protection unknown for $github $base; require captain-confirmed checks and policy"
        fi ;;
    esac
  fi
  # Visibility does not grant or deny permission. An unreadable protection
  # remains unknown; onboarding must record captain-confirmed checks/policy.
  # --- the guard in the managed clone ------------------------------------
  local why
  if ! why="$(place_ok 2>&1)"; then
    # sync would refuse the same place, so advising it would only lead to a second 70
    miss "${why#fm-project: }"
  elif ! is_clone; then
    miss "no managed clone at $clone; run fm-project.sh sync $NAME"
  else
    local hp gb og want
    og="$(git -C "$clone" remote get-url origin 2>/dev/null || true)"
    [ "$og" = "$origin" ] && [ "$(git -C "$clone" remote get-url --push origin 2>/dev/null)" = "$origin" ] \
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
