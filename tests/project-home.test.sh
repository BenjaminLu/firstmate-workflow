#!/usr/bin/env bash
# Feature-owned tests: external project storage never enters the engine tree.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=tests/lib.sh
. "$ROOT/tests/lib.sh"
t="$(safe_tmpdir)"
eng="$t/engine"; mkdir -p "$eng"
cat > "$eng/config.yaml" <<'YAML'
default_project: self
projects:
  self:
    repo: .
    github: owner/engine
    base: main
    required_check: ci
  private-app:
    github: owner/private-app
    base: trunk
    required_check: ci
YAML
export FM_HOME="$t/home"
unset FM_PROJECT
field() { bash -c '. "$1/bin/fm-config.sh"; fm_project_get "$3" "$4" "$2/config.yaml"' _ "$ROOT" "$eng" "$1" "$2"; }
assert_eq "$FM_HOME/projects/private-app/repo" "$(field private-app root)" "external clone is outside engine"
assert_eq "$FM_HOME/projects/private-app/tasks" "$(field private-app tasks)" "private specs are external"
assert_eq "$FM_HOME/projects/private-app/state" "$(field private-app state)" "private records are external"
assert_eq "$FM_HOME/projects/private-app/worktrees" "$(field private-app worktrees)" "worktrees are siblings of clone"
assert_eq "$eng" "$(field self root)" "self clone root is unchanged"
assert_eq "$eng/state" "$(field self state)" "self state is unchanged"
assert_eq "$eng/state/worktrees" "$(field self worktrees)" "self worktrees are unchanged"
assert_eq 65 "$(FM_HOME="$eng/nested" field private-app root >/dev/null 2>&1; echo $?)" "nested home is refused before mutation"
mkdir -p "$t/home/projects"
ln -s "$eng" "$t/home/projects/private-app"
assert_eq 65 "$(field private-app root >/dev/null 2>&1; echo $?)" "project symlink escape is refused"
rm "$t/home/projects/private-app"
assert_eq 65 "$(field ../escape root >/dev/null 2>&1; echo $?)" "traversal name is refused"
mkdir -p "$FM_HOME/projects/private-app/tasks" "$FM_HOME/projects/private-app/worktrees"
ln -s "$eng/config.yaml" "$FM_HOME/projects/private-app/tasks/T-001.json"
assert_eq 65 "$(field private-app tasks >/dev/null 2>&1; echo $?)" "task record symlink escape is refused"
rm "$FM_HOME/projects/private-app/tasks/T-001.json"
ln -s "$eng/config.yaml" "$FM_HOME/projects/private-app/worktrees/T-001.pid"
assert_eq 65 "$(field private-app worktrees >/dev/null 2>&1; echo $?)" "worktree owner symlink escape is refused"
assert_ok "test ! -e '$eng/state'" "resolution writes no engine records"
# Storage compatibility is independent of external path validation.
mkdir -p "$t/plain"
printf 'vendor: mock\n' > "$t/plain/config.yaml"
storage() { bash -c '. "$1/bin/fm-config.sh"; fm_storage_init "$2" || exit $?; printf "%s|%s" "$FM_EXTERNAL" "$FM_STATE_DIR"' _ "$ROOT" "$1"; }
assert_eq "0|$t/plain/state" "$(FM_PROJECT=example-app storage "$t/plain")" "no registry keeps ambient project on self storage"
sed '/default_project:/d' "$eng/config.yaml" > "$t/config"; mv "$t/config" "$eng/config.yaml"
assert_eq "0|$eng/state" "$(storage "$eng")" "unnamed registry uses its self entry"
printf 'projects: broken\n' > "$t/plain/config.yaml"
assert_eq "0|$t/plain/state" "$(storage "$t/plain" 2>/dev/null)" "unnamed malformed registry preserves self storage"
safe_rm_rf "$t"
finish
