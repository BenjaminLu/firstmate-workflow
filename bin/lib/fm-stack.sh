# shellcheck shell=bash
# fm:sourced
_fm_stack_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Call only after fm_storage_init. Empty self conventions keep stacking held.
fm_stack_repository() {
  if [ "${FM_EXTERNAL:-0}" = 1 ]; then printf '%s\n' "$GH_REPO"
  elif [ -n "${FM_PROJECT:-}" ] && [ -n "$(fm_projects "$FM_CONFIG" 2>/dev/null)" ]; then
    fm_project_get "$FM_PROJECT" github "$FM_CONFIG"
  else
    "${GH:-${FM_GH:-gh}}" repo view --json nameWithOwner --jq .nameWithOwner
  fi
}
fm_stack_deletable() {
  local repository downstream
  [ -n "$1" ] || return 1
  repository="$(fm_stack_repository)" || return 1
  [[ "$repository" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || return 1
  downstream="$("${GH:-${FM_GH:-gh}}" pr list --repo "$repository" --state open --base "$1" --json number)" || return 1
  jq -e 'type == "array" and length == 0' <<<"$downstream" >/dev/null 2>&1
}
fm_stack() {
  local repository
  repository="$(fm_stack_repository)" || return 65
  FM_STACK_REPOSITORY="$repository" python3 "$_fm_stack_dir/fm_stack.py" "$@"
}

fm_stack_policy() {
  if [ "${FM_EXTERNAL:-0}" = 1 ]; then fm_conventions "$1"
  elif [ -s "$FM_TARGET_ROOT/CONVENTIONS.md" ]; then
    local repository
    repository="$(fm_stack_repository)" || return 65
    python3 "$_fm_stack_dir/fm_conventions.py" \
      "$FM_TARGET_ROOT/CONVENTIONS.md" --repository "$repository" --base "${FM_BASE:-main}" ${1:+--field "$1"}
  else
    case "$1" in
      stacking) echo hold ;;
      delete_branch) echo true ;;
      merge_method) echo squash ;;
      land) echo card ;;
      force_with_lease) echo false ;;
      *) return 65 ;;
    esac
  fi
}
