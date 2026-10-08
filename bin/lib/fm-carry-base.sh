# shellcheck shell=bash
# fm:sourced
# Resources are recorded in the calling shell, never hidden in a substitution.
# The merge entrypoint composes this cleanup with its immutable code cleanup.
FM_CARRY_PRIVATE_REF=''
FM_CARRY_PRIVATE_ROOT=''
fm_carry_base_cleanup() {
  if [ -n "${FM_CARRY_PRIVATE_REF:-}" ] && [ -n "${FM_CARRY_PRIVATE_ROOT:-}" ]; then
    git -C "$FM_CARRY_PRIVATE_ROOT" update-ref -d "$FM_CARRY_PRIVATE_REF" || return 75
    FM_CARRY_PRIVATE_REF=''; FM_CARRY_PRIVATE_ROOT=''
  fi
}
fm_carry_sync_base() {
  local base="${1:-}" project_base root url remote local_head checked path here result line
  root="$FM_TARGET_ROOT"
  project_base=main
  [ "${FM_EXTERNAL:-0}" != 1 ] || project_base="$FM_BASE"
  [ -n "$base" ] || { echo 'the PR base name is unreadable' >&2; return 75; }
  [ "$base" = "$project_base" ] || { echo 'not the project base' >&2; return 75; }
  if [ "${FM_EXTERNAL:-0}" = 1 ]; then
    git -C "$root" fetch -q --no-tags --no-write-fetch-head origin "+refs/heads/$FM_BASE:refs/remotes/origin/$FM_BASE" || {
      echo 'cannot fetch the live base' >&2; return 75; }
    fm_external_base || return 75
    return 0
  fi
  fm_carry_base_cleanup || { echo 'cannot delete previous private base ref' >&2; return 75; }
  FM_CARRY_PRIVATE_ROOT="$root"
  FM_CARRY_PRIVATE_REF="refs/fm/carry-base/$$-$RANDOM-$RANDOM"
  url="$(git -C "$root" remote get-url origin)" || url=''
  if [ -z "$url" ] || ! git -C "$root" fetch -q --no-tags --no-write-fetch-head "$url" "+refs/heads/$base:$FM_CARRY_PRIVATE_REF"; then
    fm_carry_base_cleanup || true
    echo 'cannot fetch the live base' >&2; return 75
  fi
  remote="$(git -C "$root" rev-parse "$FM_CARRY_PRIVATE_REF^{commit}")" || {
    fm_carry_base_cleanup || true; echo 'cannot read the live base' >&2; return 75; }
  # Objects survive deletion of the fetch ref; only the selected SHA is used.
  fm_carry_base_cleanup || { echo 'cannot delete private base ref' >&2; return 75; }
  local_head="$(git -C "$root" rev-parse --verify "refs/heads/$base^{commit}" 2>/dev/null)" || {
    echo "the local base ref $base does not exist" >&2; return 75; }
  [ "$local_head" != "$remote" ] || return 0
  git -C "$root" merge-base --is-ancestor "$local_head" "$remote" || {
    echo 'the local base has commits the live base lacks; it cannot be fast-forwarded' >&2; return 75; }
  here="$(cd "$root" && pwd -P)" || return 75
  checked=''; path=''
  result="$(git -C "$root" worktree list --porcelain)" || {
    echo 'cannot read checked-out base worktrees' >&2; return 75; }
  while IFS= read -r line; do
    case "$line" in
      'worktree '*) path="${line#worktree }" ;;
      "branch refs/heads/$base") checked="$path"; break ;;
    esac
  done <<< "$result"
  if [ -n "$checked" ]; then
    checked="$(cd "$checked" && pwd -P)" || return 75
    [ "$checked" = "$here" ] || {
      echo "the local base is checked out in another worktree $checked; synchronize it there" >&2; return 75; }
    git -C "$root" merge -q --ff-only "$remote" || {
      echo 'the local base cannot be fast-forwarded without touching local changes' >&2; return 75; }
  else
    git -C "$root" update-ref "refs/heads/$base" "$remote" "$local_head" || {
      echo 'the local base moved while synchronizing; retry' >&2; return 75; }
  fi
}
