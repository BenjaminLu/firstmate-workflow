# shellcheck shell=bash
# fm:sourced
_fm_stack_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Call only after fm_storage_init. Empty self conventions keep stacking held
# unless the captain-written self-stack-policy.json says otherwise.
fm_stack_repository() {
  if [ -n "${FM_PROJECT:-}" ] && [ -n "$(fm_projects "$FM_CONFIG" 2>/dev/null)" ]; then
    fm_project_get "$FM_PROJECT" github "$FM_CONFIG"
  elif [ -n "${GH_REPO:-}" ]; then printf '%s\n' "$GH_REPO"
  else
    # Self checkouts use the same local-origin reader as authoritative binding.
    python3 -c 'import sys; sys.path.insert(0, sys.argv[1]); from fm_binding import repository; print(repository(sys.argv[2]))' \
      "$_fm_stack_dir" "$FM_TARGET_ROOT"
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
  # select asks for the repository only when it must read GitHub (T-278).
  if [ "${1:-}" = select ]; then
    python3 "$_fm_stack_dir/fm_stack.py" "$@"
    return
  fi
  repository="$(fm_stack_repository)" || return 65
  FM_STACK_REPOSITORY="$repository" python3 "$_fm_stack_dir/fm_stack.py" "$@"
}

fm_stack_policy() {
  if [ "${FM_EXTERNAL:-0}" = 1 ]; then fm_conventions "$1"
  # The self runtime policy file governs these two fields only (T-278).
  elif { [ "$1" = stacking ] || [ "$1" = force_with_lease ]; } && [ -n "${FM_STATE_DIR:-}" ] \
       && { [ -e "$FM_STATE_DIR/autopilot/self-stack-policy.json" ] || [ -L "$FM_STATE_DIR/autopilot/self-stack-policy.json" ] \
            || [ -L "$FM_STATE_DIR/autopilot" ]; }; then
    python3 "$_fm_stack_dir/fm_stack.py" policy --field "$1"
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
