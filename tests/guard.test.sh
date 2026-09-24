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

# a usage error exits 64, like every other script, and says so on stderr
uerr="$("$G" nonsense 2>&1 >/dev/null)"; urc=$?
assert_eq "64" "$urc" "an unknown subcommand exits 64"
assert_contains "$uerr" "usage: fm-guard.sh" "and prints its usage on stderr"

# the hooks are the half that catches a human, or an agent using git directly.
# Installed the way a checkout installs them: in the tree, and pointed at by
# bin/fm-install-hooks.sh, relative - not by an absolute path into this repo.
git -C "$t" checkout -q main
cp -R "$ROOT/.githooks" "$t/.githooks"; git -C "$t" add -A; git -C "$t" commit -qm hooks
assert_ok "cd '$t' && '$ROOT/bin/fm-install-hooks.sh' >/dev/null" "the fixture installs the real hooks"
echo y > "$t/f"
assert_fail "git -C '$t' commit -qam onmain" "pre-commit blocks a commit on main"
git -C "$t" checkout -q -f master; git -C "$t" merge -q --ff-only main
echo y > "$t/f"
assert_fail "git -C '$t' commit -qam onmaster" "pre-commit blocks a commit on master"
git -C "$t" checkout -q -f feature/x; git -C "$t" merge -q --ff-only main
echo z > "$t/f"
assert_ok "git -C '$t' commit -qam onbranch" "pre-commit allows a commit on a branch"
# Server-side branch protection is the authority; the hook is an early
# warning for main and master only. A detached HEAD is where fm-worker.sh
# rebuilds a branch, and refusing it there refused every rebuild (T-093).
git -C "$t" checkout -q --detach
echo d > "$t/f"
dout="$(git -C "$t" commit -qam ondetached 2>&1)"; drc=$?
assert_eq "0" "$drc" "pre-commit allows a commit on a detached HEAD"
assert_lacks "$dout" "fm-guard" "and says nothing about it"
git -C "$t" checkout -q feature/x

bare="$(mktemp -d)"; git init -q --bare "$bare"
git -C "$t" remote add origin "$bare"
assert_fail "git -C '$t' push -q origin feature/x:main" "pre-push blocks a push onto main"
assert_ok   "git -C '$t' push -q origin feature/x:feature/x" "pre-push allows a push onto a branch"

assert_ok "test -x '$ROOT/.githooks/pre-commit' && test -x '$ROOT/.githooks/pre-push'" "hooks are executable"
# the installer, not the machine this happens to run on
fresh="$(mktemp -d)"; git -C "$fresh" init -q -b main
assert_fail "cd '$fresh' && '$ROOT/bin/fm-install-hooks.sh' --check" "--check fails before the hooks are installed"
assert_ok   "cd '$fresh' && '$ROOT/bin/fm-install-hooks.sh'"         "the installer runs"
assert_ok   "cd '$fresh' && '$ROOT/bin/fm-install-hooks.sh' --check" "--check passes once they are"
assert_eq ".githooks" "$(git -C "$fresh" config --get core.hooksPath)" "it sets core.hooksPath"
rm -rf "$fresh"
rm -rf "$t" "$bare"
finish
