#!/usr/bin/env bash
# Nobody on the crew writes to main. This is the thing that makes that true.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=tests/lib.sh
. "$ROOT/tests/lib.sh"
G="$ROOT/bin/fm-guard.sh"

t="$(mktemp -d)"
git -C "$t" init -q -b main
git -C "$t" config user.email a@b.c; git -C "$t" config user.name t
echo x > "$t/f"; git -C "$t" add -A; git -C "$t" commit -qm init

assert_fail "'$G' branch '$t'" "refuses main"
git -C "$t" checkout -q -b master
assert_fail "'$G' branch '$t'" "refuses master"
git -C "$t" checkout -q -b feature/x
assert_ok   "'$G' branch '$t'" "allows a feature branch"
git -C "$t" checkout -q --detach
assert_fail "'$G' branch '$t'" "refuses a detached HEAD"
git -C "$t" checkout -q feature/x
assert_fail "FM_PROTECTED='feature/x' '$G' branch '$t'" "honours FM_PROTECTED"

# the hooks are the half that catches a human, or an agent using git directly
git -C "$t" config core.hooksPath "$ROOT/.githooks"
git -C "$t" checkout -q main
echo y > "$t/f"
assert_fail "git -C '$t' commit -qam onmain" "pre-commit blocks a commit on main"
git -C "$t" checkout -q feature/x
echo z > "$t/f"
assert_ok "git -C '$t' commit -qam onbranch" "pre-commit allows a commit on a branch"

bare="$(mktemp -d)"; git init -q --bare "$bare"
git -C "$t" remote add origin "$bare"
assert_fail "git -C '$t' push -q origin feature/x:main" "pre-push blocks a push onto main"
assert_ok   "git -C '$t' push -q origin feature/x:feature/x" "pre-push allows a push onto a branch"

assert_ok "test -x '$ROOT/.githooks/pre-commit' && test -x '$ROOT/.githooks/pre-push'" "hooks are executable"
assert_ok "'$ROOT/bin/fm-install-hooks.sh' --check" "this checkout has the hooks installed"
rm -rf "$t" "$bare"
finish
