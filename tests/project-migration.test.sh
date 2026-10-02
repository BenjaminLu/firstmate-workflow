#!/usr/bin/env bash
set -uo pipefail
for key in $(env | sed -n 's/^\(FM_[A-Za-z0-9_]*\)=.*/\1/p'); do unset "$key"; done
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=tests/lib.sh
. "$ROOT/tests/lib.sh"
t="$(safe_tmpdir)"; engine="$t/engine"; export FM_HOME="$t/home" FM_GITHUB_URL="$t/remotes"
mkdir -p "$engine/.githooks" "$t/remotes/owner"
cat > "$engine/config.yaml" <<'YAML'
projects:
  private-app:
    github: owner/private-app
    base: main
    required_check: ci
YAML
git init -q --bare "$t/remotes/owner/private-app.git"
legacy="$engine/state/projects/private-app"
mkdir -p "$legacy/state"
git clone -q "$t/remotes/owner/private-app.git" "$legacy/repo" 2>/dev/null
printf 'private retained evidence\n' > "$legacy/state/evidence.txt"
project="$FM_HOME/projects/private-app"
"$ROOT/bin/fm-project.sh" sync private-app --repo "$engine" > "$t/out" 2> "$t/err"; rc=$?
assert_eq 65 "$rc" "legacy clone requires explicit migration approval"
assert_ok "test -f '$legacy/state/evidence.txt'" "refused migration retains every source record"
assert_ok "test ! -e '$project'" "refused migration creates no destination"
"$ROOT/bin/fm-project.sh" sync private-app --migrate --repo "$engine" > "$t/out" 2> "$t/err"; rc=$?
assert_eq 0 "$rc" "approved migration moves clone and records"
assert_eq 'private retained evidence' "$(cat "$project/state/evidence.txt")" "migration retains record contents"
assert_ok "test ! -e '$legacy'" "atomic migration leaves no private legacy copy"
"$ROOT/bin/fm-project.sh" history on private-app --repo "$engine" > "$t/out" 2> "$t/err"; rc=$?
assert_eq 0 "$rc" "project can enable local spec history"
assert_eq '' "$(git -C "$project" remote)" "history has no remote"
assert_eq repo/file "$(git -C "$project" check-ignore repo/file)" "history excludes clone"
assert_eq worktrees/T-001/file "$(git -C "$project" check-ignore worktrees/T-001/file)" "history excludes worktrees"
assert_eq state/evidence.txt "$(git -C "$project" check-ignore state/evidence.txt)" "history excludes execution evidence"
safe_rm_rf "$t"
finish
