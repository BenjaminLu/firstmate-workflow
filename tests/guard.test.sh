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
# Each switch below is asserted: a refusal passes on the wrong branch too,
# and an allowance passes where no hook is checked out.
assert_ok "git -C '$t' checkout -q main" "the fixture switches to main"
assert_eq "main" "$(git -C "$t" branch --show-current)" "and is on main"
cp -R "$ROOT/.githooks" "$t/.githooks"
assert_ok "git -C '$t' add -A && git -C '$t' commit -qm hooks" "the fixture commits the real hooks, before they are installed"
assert_ok "cd '$t' && '$ROOT/bin/fm-install-hooks.sh' >/dev/null" "the fixture installs the real hooks"
echo y > "$t/f"
assert_fail "git -C '$t' commit -qam onmain" "pre-commit blocks a commit on main"
assert_ok "git -C '$t' checkout -q -f master && git -C '$t' merge -q --ff-only main" "the fixture switches to master, with the hooks"
assert_eq "master" "$(git -C "$t" branch --show-current)" "and is on master"
echo y > "$t/f"
assert_fail "git -C '$t' commit -qam onmaster" "pre-commit blocks a commit on master"
assert_ok "git -C '$t' checkout -q -f feature/x && git -C '$t' merge -q --ff-only main" "the fixture switches to feature/x, with the hooks"
assert_eq "feature/x" "$(git -C "$t" branch --show-current)" "and is on feature/x"
assert_ok "test -x '$t/.githooks/pre-commit'" "where the hook is checked out"
echo z > "$t/f"
assert_ok "git -C '$t' commit -qam onbranch" "pre-commit allows a commit on a branch"
# Server-side branch protection is the authority; the hook is an early
# warning for main and master only. A detached HEAD is where fm-worker.sh
# rebuilds a branch, and refusing it there refused every rebuild (T-093).
assert_ok "git -C '$t' checkout -q --detach" "the fixture detaches HEAD"
assert_eq "" "$(git -C "$t" branch --show-current)" "and is on no branch"
assert_fail "git -C '$t' symbolic-ref -q HEAD" "HEAD names no branch"
assert_ok "test -x '$t/.githooks/pre-commit'" "and the hook is still checked out"
echo d > "$t/f"
dout="$(git -C "$t" commit -qam ondetached 2>&1)"; drc=$?
assert_eq "0" "$drc" "pre-commit allows a commit on a detached HEAD"
assert_lacks "$dout" "fm-guard" "and says nothing about it"
assert_ok "git -C '$t' checkout -q feature/x" "the fixture goes back to feature/x"

bare="$(mktemp -d)"; git init -q --bare "$bare"
git -C "$t" remote add origin "$bare"
assert_fail "git -C '$t' push -q origin feature/x:main" "pre-push blocks a push onto main"
assert_ok   "git -C '$t' push -q origin feature/x:feature/x" "pre-push allows a push onto a branch"

assert_ok "test -x '$ROOT/.githooks/pre-commit' && test -x '$ROOT/.githooks/pre-push'" "hooks are executable"

# A target's base need not be main (design 15.6). fm-project.sh sync records
# it in the managed clone's local config as firstmate.base, and the guard and
# both hooks protect it on top of main and master. Without that key - the
# self project, and every checkout that is not a managed clone - the
# protected set is exactly what it was.
git -C "$t" checkout -q -b trunk
assert_ok   "'$G' branch '$t'" "with no project base, any other branch is allowed"
echo t1 > "$t/f"
assert_ok   "git -C '$t' commit -qam trunk-before" "and committed on"
assert_ok   "git -C '$t' push -q origin trunk:trunk" "and pushed to"
git -C "$t" config firstmate.base trunk
assert_fail "'$G' branch '$t'" "the guard refuses the project's base"
assert_contains "$("$G" branch "$t" 2>&1)" "refusing to work on trunk" "and names it"
git -C "$t" checkout -q main
assert_fail "'$G' branch '$t'" "main is still refused"
git -C "$t" checkout -q master
assert_fail "'$G' branch '$t'" "and master"
git -C "$t" checkout -q feature/x
assert_ok   "'$G' branch '$t'" "a task branch is still allowed"
assert_fail "FM_PROTECTED='feature/x' '$G' branch '$t'" "FM_PROTECTED is still honoured"
git -C "$t" checkout -q trunk
assert_fail "FM_PROTECTED='feature/x' '$G' branch '$t'" "and cannot unprotect the project's base"
echo t2 > "$t/f"
assert_fail "git -C '$t' commit -qam trunk-after" "pre-commit blocks a commit on the project's base"
assert_contains "$(git -C "$t" commit -qam trunk-after 2>&1)" "refusing to commit on trunk" "and names it"
# The pushed branch is ahead of the remote's trunk: git rejects a push that
# is not a fast-forward before it runs pre-push, and that refusal would pass
# here without the hook.
git -C "$t" checkout -q -f -b ahead trunk
echo t3 > "$t/f"
assert_ok   "git -C '$t' commit -qam ahead" "a branch ahead of the project's base is committed on"
assert_fail "git -C '$t' push -q origin ahead:trunk" "pre-push blocks a push onto the project's base"
assert_contains "$(git -C "$t" push -q origin ahead:trunk 2>&1)" "refusing to push directly to trunk" "and names it"
assert_eq "$(git -C "$t" rev-parse trunk)" "$(git -C "$bare" rev-parse trunk)" "and the remote's base did not move"
git -C "$t" checkout -q feature/x
assert_fail "git -C '$t' push -q origin feature/x:main" "and still onto main"
assert_ok   "git -C '$t' push -q origin feature/x:feature/y" "and still allows a push onto a branch"
# a worktree of the clone shares its config, so a task worktree is guarded too
wt="$(mktemp -d)/wt"
git -C "$t" worktree add -q "$wt" trunk 2>/dev/null
assert_fail "'$G' branch '$wt'" "a worktree of the clone on its base is refused too"
assert_contains "$("$G" branch "$wt" 2>&1)" "refusing to work on trunk" "naming the base"
git -C "$t" worktree remove --force "$wt"
# sourced, the function reads the base of the directory it is asked about
git -C "$t" checkout -q trunk
assert_fail "bash -c '. \"$G\"; fm_guard_branch \"$t\"'" "the sourced fm_guard_branch protects the base as well"
git -C "$t" checkout -q feature/x
git -C "$t" config --unset firstmate.base
# the installer, not the machine this happens to run on
fresh="$(mktemp -d)"; git -C "$fresh" init -q -b main
assert_fail "cd '$fresh' && '$ROOT/bin/fm-install-hooks.sh' --check" "--check fails before the hooks are installed"
assert_ok   "cd '$fresh' && '$ROOT/bin/fm-install-hooks.sh'"         "the installer runs"
assert_ok   "cd '$fresh' && '$ROOT/bin/fm-install-hooks.sh' --check" "--check passes once they are"
assert_eq ".githooks" "$(git -C "$fresh" config --get core.hooksPath)" "it sets core.hooksPath"
rm -rf "$fresh"
rm -rf "$t" "$bare"
finish
