#!/usr/bin/env bash
set -uo pipefail
for key in $(env | sed -n 's/^\(FM_[A-Za-z0-9_]*\)=.*/\1/p'); do unset "$key"; done
unset HERDR_PANE_ID HERDR_TAB_ID HERDR_WORKSPACE_ID; export HERDR_ENV=0
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=tests/lib.sh
. "$ROOT/tests/lib.sh"
# shellcheck source=tests/lib/project-storage.sh
. "$ROOT/tests/lib/project-storage.sh"
t="$(safe_tmpdir)"; engine="$t/engine"; export FM_HOME="$t/home" FM_GITHUB_URL="$t/remotes"
mkdir -p "$engine/bin" "$engine/.githooks" "$t/remotes/owner"
project_storage_fixture "$engine/bin"
cp "$ROOT/bin/fm-emit.sh" "$engine/bin/"
cat > "$engine/config.yaml" <<'YAML'
projects:
  app:
    github: owner/app
    base: main
    required_check: ci
YAML
git init -q --bare -b main "$t/remotes/owner/app.git"
git init -q -b main "$t/seed"
git -C "$t/seed" -c core.hooksPath=/dev/null -c user.name=fixture -c user.email=fixture@example.invalid commit -qm base --allow-empty
git -C "$t/seed" push -q "$t/remotes/owner/app.git" main
"$ROOT/bin/fm-project.sh" sync app --repo "$engine" >/dev/null
project="$FM_HOME/projects/app"
git -C "$project/repo" worktree add -qb t-001-work "$project/worktrees/T-001" main
mkdir -p "$engine/state/worktrees/T-001"
printf 'self data\n' > "$engine/state/worktrees/T-001/keep"
cleanup() { "$ROOT/bin/fm-cleanup.sh" --repo "$engine" --project app --task "$1" --force > "$t/out" 2> "$t/err"; echo $?; }
git -C "$project/repo" remote set-url --push origin "$t/wrong.git"
assert_eq 65 "$(cleanup T-001)" "cleanup refuses a clone with mismatched push origin"
assert_ok "test -d '$project/worktrees/T-001'" "origin refusal preserves worktree"
git -C "$project/repo" config --unset remote.origin.pushurl
ln -s "$engine/state/worktrees/T-001" "$project/worktrees/T-OTHER"
assert_eq 65 "$(cleanup T-OTHER)" "cleanup refuses symlink child"
assert_eq 65 "$(cleanup ../T-001)" "cleanup refuses traversal before mutation"
rm "$project/worktrees/T-OTHER"
assert_eq 0 "$(cleanup T-001)" "cleanup removes registered external direct child"
assert_ok "test ! -e '$project/worktrees/T-001'" "external worktree is removed"
assert_eq 'self data' "$(cat "$engine/state/worktrees/T-001/keep")" "same self task id is untouched"
assert_eq app "$(jq -r .project "$project/state/events.jsonl" | tail -1)" "cleanup records the external project"
safe_rm_rf "$t"
finish
