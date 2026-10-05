#!/usr/bin/env bash
# Configured origin identity, independent of transport rewrites (T-217).
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
. "$ROOT/tests/lib.sh"
t="$(safe_tmpdir)"
export GIT_CONFIG_GLOBAL="$t/gitconfig" GIT_CONFIG_NOSYSTEM=1
: > "$GIT_CONFIG_GLOBAL"
mkdir -p "$t/remotes"
git init -q --bare "$t/remotes/project.git"
expected="$t/remotes/project.git"
repo="$t/repo"
git clone -q "$expected" "$repo" 2>/dev/null
cp "$repo/.git/config" "$t/clean-config"
reset_config() {
  cp "$t/clean-config" "$repo/.git/config"
  : > "$GIT_CONFIG_GLOBAL"
}
check_origin() {
  local want="$1" label="$2" needle="${3:-}" rc
  python3 "$ROOT/bin/lib/fm_origin.py" check "${4:-$repo}" "$expected" > "$t/out" 2> "$t/err"; rc=$?
  assert_eq "$want" "$rc" "$label: exit"
  assert_ok "test ! -s '$t/out'" "$label: no stdout"
  if [ "$want" = 0 ]; then
    assert_ok "test ! -s '$t/err'" "$label: no stderr"
  else
    assert_eq 1 "$(awk 'END {print NR}' "$t/err")" "$label: one stderr line"
    assert_matches "$(cat "$t/err")" '^fm-origin: ' "$label: diagnostic prefix"
    assert_contains "$(cat "$t/err")" "$needle" "$label: reason"
  fi
}
check_origin 0 'matching configured url'
git -C "$repo" config --unset remote.origin.url
check_origin 65 'missing url' "its origin is '', not $expected"
reset_config
git -C "$repo" config --add remote.origin.url "$t/other.git"
check_origin 65 'expected url first of two' 'its origin is'
reset_config
git -C "$repo" config remote.origin.url "$t/other.git"
check_origin 65 'wrong url' "its origin is '$t/other.git', not $expected"
reset_config
git -C "$repo" config remote.origin.pushurl "$t/other.git"
check_origin 65 'wrong pushurl' "its push origin is '$t/other.git', not $expected"
reset_config
git -C "$repo" config --add remote.origin.pushurl "$expected"
git -C "$repo" config --add remote.origin.pushurl "$t/other.git"
check_origin 65 'second pushurl differs' 'its push origin is'
reset_config
git -C "$repo" config --add remote.origin.pushurl "$expected"
git -C "$repo" config --add remote.origin.pushurl "$expected"
check_origin 0 'all pushurls match'
for kind in insteadOf pushInsteadOf; do
  reset_config
  git -C "$repo" config "url.$t/elsewhere/.$kind" "$t/remotes/"
  check_origin 65 "local $kind" "its local config rewrites $t/remotes/ to $t/elsewhere/"
done
# Rewrite targets can themselves contain spaces or newlines; neither may
# disguise a matching prefix or create extra diagnostic lines.
for target in "$t/with space/" "$t/with"$'\n'"newline/"; do
  reset_config
  git -C "$repo" config "url.$target.insteadOf" "$t/remotes/"
  check_origin 65 'rewrite target with whitespace' 'its local config rewrites'
done
reset_config
git config --file "$t/included" "url.$t/elsewhere/.insteadOf" "$t/remotes/"
git -C "$repo" config include.path "$t/included"
check_origin 65 'included local rewrite' 'its local config rewrites'
reset_config
: > "$t/included"
git config --file "$t/included" remote.origin.pushurl "$t/other.git"
git -C "$repo" config include.path "$t/included"
check_origin 65 'included pushurl' 'its push origin is'
reset_config
git config --global remote.origin.pushurl "$t/other.git"
check_origin 65 'global pushurl' 'its push origin is'
reset_config
git config --global remote.origin.url "$expected"
check_origin 65 'second url in global config' 'its origin is'
reset_config
git -C "$repo" config "url.$t/elsewhere/.insteadOf" 'https://unrelated.example/'
check_origin 0 'unrelated local rewrite'
reset_config
: > "$t/included"
git config --file "$t/included" "url.$t/elsewhere/.insteadOf" "$t/remotes/"
git -C "$repo" config "includeIf.gitdir:$repo/.git/.path" "$t/included"
check_origin 65 'conditional local include rewrite' 'its local config rewrites'
reset_config
git -C "$repo" config extensions.worktreeConfig true
git -C "$repo" config --worktree "url.$t/elsewhere/.insteadOf" "$t/remotes/"
check_origin 65 'worktree rewrite' 'its local config rewrites'
rm "$repo/.git/config.worktree"
reset_config
GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0="url.$t/elsewhere/.insteadOf" GIT_CONFIG_VALUE_0="$t/remotes/" \
  check_origin 65 'command scope rewrite' 'its local config rewrites'
reset_config
git config --global "url.$t/global-push/.pushInsteadOf" "$t/remotes/"
check_origin 0 'global push transport rewrite'
reset_config
export GIT_CONFIG_SYSTEM="$t/system-config"
git config --file "$GIT_CONFIG_SYSTEM" "url.$t/system-alias/.insteadOf" "$t/remotes/"
unset GIT_CONFIG_NOSYSTEM
check_origin 0 'system transport rewrite'
git config --file "$GIT_CONFIG_SYSTEM" remote.origin.pushurl "$t/other.git"
check_origin 65 'system pushurl elsewhere' 'its push origin is'
unset GIT_CONFIG_SYSTEM
export GIT_CONFIG_NOSYSTEM=1
reset_config
git -C "$repo" config remote.origin.url "$expected/"
check_origin 65 'no trailing slash normalization' "its origin is '$expected/', not $expected"
reset_config
git -C "$repo" config remote.origin.url "${expected}"$'\001'
check_origin 65 'control character escaped' '\x01'
reset_config
git -C "$repo" config remote.origin.url "${expected}"$'\nlocal\tfake'
check_origin 65 'newline and scope-like content escaped' '\nlocal\tfake'
reset_config
check_origin 65 'missing root is git failure' 'git config failed (exit 128)' "$t/missing"
assert_lacks "$(cat "$t/err")" 'its origin is' 'missing root is not missing url'
printf 'malformed line\n' >> "$repo/.git/config"
check_origin 65 'bad config is git failure' 'git config failed'
assert_lacks "$(cat "$t/err")" 'its origin is' 'bad config is not missing url'
reset_config
ln -s "$t/remotes" "$t/alias"
git config --global "url.$t/alias/.insteadOf" "$t/remotes/"
check_origin 0 'global transport rewrite'
git -C "$repo" config remote.origin.url "$t/other.git"
check_origin 65 'wrong url under global rewrite' 'its origin is'
assert_lacks "$(cat "$t/err")" "$t/alias" 'global target never disclosed'
unset GIT_CONFIG_GLOBAL GIT_CONFIG_NOSYSTEM
safe_rm_rf "$t"
finish
