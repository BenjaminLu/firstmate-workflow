#!/usr/bin/env bash
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=tests/lib/worker.sh
. "$ROOT/tests/lib/worker.sh"
# --- T-036: mid-run checkpoint (commit then push; never main / never PR) ---
assert_ok "test -x '$ROOT/bin/fm-checkpoint.sh'" "fm-checkpoint.sh is the stock mid-run save helper"

dc="$(safe_tmpdir)"; barec="$dc/remote.git"; rc="$dc/repo"
cd "$ROOT" || exit 1
git init -q --bare "$barec"
git init -q -b main "$rc"
git -C "$rc" config user.email a@b.c; git -C "$rc" config user.name t
mkdir -p "$rc/bin" "$rc/design" "$rc/state/worktrees"
# shellcheck source=tests/lib/config-modules.sh
. "$ROOT/tests/lib/config-modules.sh"
cp "$ROOT/bin/fm-checkpoint.sh" "$ROOT/bin/fm-guard.sh" "$ROOT/bin/fm-config.sh" \
   "$ROOT/bin/fm-emit.sh" "$rc/bin/"; config_modules_fixture "$rc/bin/"
printf 'base\n' > "$rc/README"; git -C "$rc" add README; git -C "$rc" commit -qm base
git -C "$rc" remote add origin "$barec"; git -C "$rc" push -q -u origin main
git -C "$rc" branch -q t-ck-branch
git -C "$rc" worktree add -q "$rc/state/worktrees/T-CK" t-ck-branch
printf 'unit\n' > "$rc/state/worktrees/T-CK/work.txt"
assert_ok "FM_ROOT='$rc' '$rc/bin/fm-checkpoint.sh' --task T-CK --repo '$rc' --message 'checkpoint unit'" \
  "checkpoint commits dirty work on a feature branch"
assert_ok "cd '$ROOT' && git --git-dir='$barec' rev-parse --verify t-ck-branch" \
  "checkpoint pushes the feature branch immediately"
assert_contains "$(git -C "$rc/state/worktrees/T-CK" log -1 --pretty=%s)" "T-CK: checkpoint unit" \
  "checkpoint commit uses the supplied message"
# --repo may be the worktree itself (not the session root).
printf 'via-repo\n' > "$rc/state/worktrees/T-CK/via.txt"
assert_ok "FM_ROOT='$rc' '$rc/bin/fm-checkpoint.sh' --task T-CK --repo '$rc/state/worktrees/T-CK' --message 'via worktree as repo'" \
  "checkpoint accepts the worktree path as --repo"
assert_ok "cd '$ROOT' && git --git-dir='$barec' cat-file -e t-ck-branch:via.txt" \
  "worktree-as-repo checkpoint pushed the file"
# --dir form (cwd-agnostic).
printf 'via-dir\n' > "$rc/state/worktrees/T-CK/via-dir.txt"
assert_ok "'$rc/bin/fm-checkpoint.sh' --dir '$rc/state/worktrees/T-CK' --message 'via --dir'" \
  "checkpoint --dir commits and pushes"
assert_ok "cd '$ROOT' && git --git-dir='$barec' cat-file -e t-ck-branch:via-dir.txt" \
  "--dir checkpoint reached the remote"
# The identity comes from the repo being committed to, not from the caller's
# cwd: this fixture's a@b.c is local to $rc, so a cwd lookup would sign with
# whatever the caller has (the operator's own address, or nothing on CI).
assert_eq "a@b.c" "$(git -C "$rc/state/worktrees/T-CK" log -1 --pretty=%ae)" \
  "--dir checkpoint signs with the repo's own identity"
# Refuse protected / non-feature tips. main is already the primary checkout,
# so attach a detached worktree at main's tip (refuses as HEAD).
git -C "$rc" worktree remove -f "$rc/state/worktrees/T-CK"
git -C "$rc" worktree add -q --detach "$rc/state/worktrees/T-CK" main
printf 'nope\n' > "$rc/state/worktrees/T-CK/bad.txt"
assert_fail "FM_ROOT='$rc' '$rc/bin/fm-checkpoint.sh' --task T-CK --repo '$rc' --message 'should refuse main'" \
  "checkpoint refuses to write on main"
assert_fail "grep -qx bad.txt <<<\"\$(git --git-dir='$barec' ls-tree -r main --name-only)\"" \
  "refused main checkpoint pushes nothing"
# Unset clears the shared repo local config (worktrees share it). On a CI
# runner with no global fallback that poisons every later commit in this
# fixture unless restored immediately after the negative case.
git -C "$rc/state/worktrees/T-CK" config --unset user.name 2>/dev/null || true
git -C "$rc/state/worktrees/T-CK" config --unset user.email 2>/dev/null || true
unset FM_GIT_NAME FM_GIT_EMAIL
printf 'orphan\n' > "$rc/state/worktrees/T-CK/orphan.txt"
assert_fail "FM_ROOT='$rc' FM_GIT_NAME= FM_GIT_EMAIL= '$rc/bin/fm-checkpoint.sh' --dir '$rc/state/worktrees/T-CK' --message 'no identity'" \
  "checkpoint refuses commit when git identity is missing"
git -C "$rc" config user.email a@b.c
git -C "$rc" config user.name t
# Re-attach a feature worktree: the prior block left T-CK detached on main.
git -C "$rc" worktree remove -f "$rc/state/worktrees/T-CK" 2>/dev/null || true
git -C "$rc" worktree add -q "$rc/state/worktrees/T-CK" t-ck-branch
# A tip that already tracks .fm-say.md must be purgeable: reset must not
# resurrect the file when the working tree deleted it.
printf 'round notes\n' > "$rc/state/worktrees/T-CK/.fm-say.md"
git -C "$rc/state/worktrees/T-CK" add -f .fm-say.md
git -C "$rc/state/worktrees/T-CK" commit -qm 'fixture: tracked say'
git -C "$rc/state/worktrees/T-CK" push -q origin t-ck-branch
rm -f "$rc/state/worktrees/T-CK/.fm-say.md"
printf 'after-purge\n' > "$rc/state/worktrees/T-CK/after.txt"
assert_ok "'$rc/bin/fm-checkpoint.sh' --dir '$rc/state/worktrees/T-CK' --message 'drop tracked say'" \
  "checkpoint commits when a tracked .fm-say.md was deleted"
assert_fail "cd '$ROOT' && git --git-dir='$barec' cat-file -e t-ck-branch:.fm-say.md" \
  "checkpoint removes a mistakenly tracked .fm-say.md from the tip"
assert_ok "cd '$ROOT' && git --git-dir='$barec' cat-file -e t-ck-branch:after.txt" \
  "purge commit still pushes the accompanying work"
# Present on-disk notes still never reach the tip.
printf 'live notes\n' > "$rc/state/worktrees/T-CK/.fm-say.md"
printf 'keep\n' > "$rc/state/worktrees/T-CK/keep.txt"
assert_ok "'$rc/bin/fm-checkpoint.sh' --dir '$rc/state/worktrees/T-CK' --message 'keep notes local'" \
  "checkpoint with a live .fm-say.md still saves other work"
assert_fail "cd '$ROOT' && git --git-dir='$barec' cat-file -e t-ck-branch:.fm-say.md" \
  "live .fm-say.md contents are never re-committed"
assert_ok "cd '$ROOT' && git --git-dir='$barec' cat-file -e t-ck-branch:keep.txt" \
  "non-ephemeral files still checkpoint beside a live .fm-say.md"
rm -rf "$dc"


cd "$ROOT" || exit 1
PATH="$suite_original_path"; export PATH
safe_rm_rf "$suite_tools"
finish
