#!/usr/bin/env bash
# A target's managed clone, and whether the target is fit to be driven
# (design 15.1 and 15.6).
#
#   fm-project.sh sync <name>   [--repo <engine root>]
#   fm-project.sh verify <name> [--repo <engine root>]
#   fm-project.sh small-change --project <p> --task <t> --origin <kind> --ref <text>
#       --reason-en <text> --reason-tw <text> (--path <path>... | --erratum <title|acceptance:N>
#       --after <text>) [--repo <engine root>]
#
# sync clones the project's GitHub repository into
# FM_HOME/projects/<name>/repo, or fetches and prunes the clone that is
# there; points the clone's local core.hooksPath at the engine's .githooks/,
# records the project's base as firstmate.base for the guard, and keeps
# `.fm-*` in the clone's .git/info/exclude. It writes nothing into the
# target's tree and never runs git in a directory that is not that clone.
#
# verify reports protection facts without treating unreadable rules as absent.
# It requires bound captain-confirmed CONVENTIONS.md plus a guarded clone.
# Self (`repo: .`) remains a no-op.
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

# Onboarding has its own noninteractive arguments and never writes private
# inspection or contract content into the engine registry.
case "${1:-}" in
  add|edit|drift) exec "$(dirname "$_fm_lib")/fm-onboard.sh" "$@" ;;
esac

# Repin uses only existing captain decision records; it never changes producers.
if [ "${1:-}" = repin ]; then
  shift
  REPO="${FM_ROOT:-$(pwd)}"; PIN_TASK=''; PIN_DECISION=''; PIN_PROJECT=''
  while [ $# -gt 0 ]; do
    case "$1" in
      --repo) fm_need "fm-project" "$@"; REPO="${2-}"; shift 2 ;;
      --project) fm_need "fm-project" "$@"; PIN_PROJECT="${2-}"; shift 2 ;;
      --task) fm_need "fm-project" "$@"; PIN_TASK="${2-}"; shift 2 ;;
      --decision) fm_need "fm-project" "$@"; PIN_DECISION="${2-}"; shift 2 ;;
      *) echo "fm-project: unknown repin argument $1" >&2; exit 64 ;;
    esac
  done
  [ -n "$PIN_TASK" ] && [ -n "$PIN_DECISION" ] || {
    echo 'usage: fm-project.sh repin --project <p> --task <t> --decision <id> [--repo <engine>]' >&2
    exit 64
  }
  fm_storage_init "$REPO" "$PIN_PROJECT" || exit 65
  fm_target_validate || exit 65
  pin="$(fm_pin create --task "$PIN_TASK" --decision "$PIN_DECISION")" || exit $?
  pin_events=()
  if [ -n "${FM_PROJECT:-}" ] && [ -n "$(fm_projects "$FM_CONFIG")" ]; then
    pin_events=(--project "$FM_PROJECT")
  fi
  FM_ROOT="$FM_ENGINE_ROOT" "$_fm_code_dir/fm-emit.sh" ${pin_events[@]+"${pin_events[@]}"} \
    --actor firstmate --type spec_repinned --task "$PIN_TASK" \
    --data "$(jq -c '{version,decision:.approval.decision}' <<<"$pin")" \
    --en 'Approved task snapshots repinned' --tw '已重新固定核准的任務快照' || exit 70
  printf '%s\n' "$pin"
  exit 0
fi

# Small changes (T-277): firstmate records exact test/docs paths or a typo fix
# against the current pin, outside any round, with no preflight and no card.
if [ "${1:-}" = small-change ]; then
  shift
  if [ "${FM_EXTERNAL:-0}" = 1 ]; then
    echo 'fm-project: small-change tier is self-project only; use the full process' >&2; exit 64
  fi
  python3 "$_fm_code_dir/lib/fm_small_change.py" check-args "$@" || exit 64
  if [ -n "${FM_IN_ROUND:-}" ]; then
    echo "fm-project: small-change runs from the operator's shell, not inside a crew round" >&2; exit 65
  fi
  REPO="${FM_ROOT:-$(pwd)}"; SMALL_PROJECT=''; small_args=("$@")
  while [ $# -gt 0 ]; do
    case "$1" in
      --repo) fm_need "fm-project" "$@"; REPO="${2-}"; shift 2 ;;
      --project) fm_need "fm-project" "$@"; SMALL_PROJECT="${2-}"; shift 2 ;;
      # check-args accepted only exact option names, each with one value
      *) fm_need "fm-project" "$@"; shift 2 ;;
    esac
  done
  fm_storage_init "$REPO" "$SMALL_PROJECT" || exit 65
  if [ "$FM_EXTERNAL" = 1 ]; then
    echo 'fm-project: small-change tier is self-project only; use the full process' >&2; exit 64
  fi
  exec python3 "$_fm_code_dir/lib/fm_small_change.py" create "${small_args[@]}"
fi

REPO="${FM_ROOT:-$(pwd)}"; MIGRATE=0; GH="${FM_GH:-gh}"; URL="${FM_GITHUB_URL:-https://github.com}"
usage() { echo "usage: fm-project.sh add <owner/repo|local-path> [--name name] [--answers file]; edit|drift <name>; sync|verify|design-checked <name> [--migrate] [--repo dir]; history on <name> [--repo dir]" >&2; exit 64; }
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
case "$CMD" in sync|verify|history|design-checked) ;; *) usage ;; esac

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
    local reason
    if ! reason="$(python3 "$_fm_code_dir/lib/fm_origin.py" check "$clone" "$origin" 2>&1)"; then
      reason="${reason#fm-origin: }"
      case "$reason" in
        'its origin is '*) echo "fm-project: refusing $clone - $reason" >&2; exit 70 ;;
        *) echo "fm-project: refusing mismatched push origin - $reason" >&2; exit 65 ;;
      esac
    fi
    local deepen=()
    if [ "$(git -C "$clone" rev-parse --is-shallow-repository)" = true ]; then deepen=(--unshallow); fi
    fm_git_transfer git -C "$clone" fetch -q --prune ${deepen[@]+"${deepen[@]}"} origin || {
      echo "fm-project: could not fetch $origin into $clone" >&2; exit 1; }
    # Old onboarding created --no-checkout clones. Populate only an absent
    # index with a committed HEAD: an empty remote has neither yet.
    # Never reset an ordinary checkout or discard local edits.
    if [ ! -e "$clone/.git/index" ] && git -C "$clone" rev-parse --verify 'HEAD^{commit}' >/dev/null 2>&1; then
      git -C "$clone" read-tree -m -u HEAD || {
        echo 'fm-project: could not populate legacy managed checkout' >&2; exit 1; }
    fi
    echo "fm-project: fetched and pruned $NAME"
  else
    mkdir -p "$project_home" && place_ok || exit 65
    fm_git_transfer git clone -q "$origin" "$clone" || { echo "fm-project: could not clone $origin" >&2; exit 1; }
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
  python3 "$_fm_code_dir/lib/fm_design_check.py" check --engine "$REPO" --name "$NAME" --home "$project_home" --base "$base" || true
  if [ "$repo_field" != . ] && [ "${FM_HERDR_WORKSPACE:-}" != 0 ]; then
    python3 "$_fm_code_dir/fm-herdr.py" ensure-workspace "$REPO" "$NAME" "$clone" >/dev/null 2>&1 || true
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
  python3 - "$legacy" "$project_home" "$origin" "$_fm_code_dir/lib" <<'PYM'
import sys
sys.path.insert(0, sys.argv[4])
from fm_project_migrate import migrate
try:
    migrate(*sys.argv[1:4])
except Exception as error:
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

verify_target() {
  local out msg
  # Protection visibility is evidence, never permission. In particular a 404
  # cannot distinguish an unprotected branch from an unreadable private rule.
  local policy
  if ! policy="$(python3 "$_fm_code_dir/lib/fm_conventions.py" "$project_home/CONVENTIONS.md" \
      --repository "$github" --base "$base" 2>&1)"; then
    miss "require captain-confirmed checks and policy in CONVENTIONS.md: $policy"
  fi
  if out="$($GH api "repos/$github/branches/$base/protection" 2>/dev/null </dev/null)"; then
    echo "fm-project: protection visible for $github $base: $out"
  else
    echo "fm-project: branch protection unknown for $github $base (including 404); captain-confirmed checks and policy required"
  fi
  # --- the guard in the managed clone ------------------------------------
  local why
  if ! why="$(place_ok 2>&1)"; then
    # sync would refuse the same place, so advising it would only lead to a second 70
    miss "${why#fm-project: }"
  elif ! is_clone; then
    miss "no managed clone at $clone; run fm-project.sh sync $NAME"
  else
    local hp gb reason want
    if ! reason="$(python3 "$_fm_code_dir/lib/fm_origin.py" check "$clone" "$origin" 2>&1)"; then
      miss "${reason#fm-origin: }"
    fi
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
  design-checked)
    place_ok || exit 65
    is_clone || { echo "fm-project: refusing $clone - it is not a clone of its own" >&2; exit 65; }
    python3 "$_fm_code_dir/lib/fm_design_check.py" mark --engine "$REPO" --name "$NAME" --home "$project_home" --base "$base"
    ;;
  sync) sync_clone ;;
  verify) verify_target ;;
esac
