#!/usr/bin/env bash
# A script that deletes directories is judged by what it refuses.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=tests/lib.sh
. "$ROOT/tests/lib.sh"

fixture() {
  local d; d="$(mktemp -d)"
  git init -q -b main "$d/repo"
  ( cd "$d/repo" && git config user.email a@b.c && git config user.name t
    mkdir -p bin state/worktrees && cp "$ROOT/bin/fm-emit.sh" "$ROOT/bin/fm-cleanup.sh" bin/
    echo x > f && git add -A && git commit -qm base
    git worktree add -q -b t-a state/worktrees/T-A >/dev/null 2>&1 )
  printf '%s' "$d"
}
# one directory per stub: a factory that reuses a path silently overwrites the
# stub a previous assertion is still holding a reference to
ghstub() { local dir="$1/stub-$2"; mkdir -p "$dir"
  printf '#!/usr/bin/env bash\necho "%s"\n' "$2" > "$dir/gh"
  chmod +x "$dir/gh"; printf '%s' "$dir/gh"; }

d="$(fixture)"; r="$d/repo"
MERGED="$(ghstub "$d" MERGED)"

# --- it refuses everything that is not its own worktree ------------------
# assert the outcome, not the wording: a dotted path may not exist at all or
# may resolve to a real directory outside the root, and both must end the same
FM_GH="$MERGED" "$r/bin/fm-cleanup.sh" --task ../../.. --repo "$r" >/dev/null 2>&1 || true
assert_ok "test -d '$r' && test -d '$r/state/worktrees'" "a path of dots deletes nothing"
assert_ok "test -d '$d'" "and nothing above the repository either"

mkdir -p "$d/elsewhere/precious"; echo keep > "$d/elsewhere/precious/file"
ln -s "$d/elsewhere/precious" "$r/state/worktrees/T-LINK"
assert_fail "FM_GH='$MERGED' '$r/bin/fm-cleanup.sh' --task T-LINK --repo '$r'" \
  "it refuses a symlink pointing outside the root"
assert_ok "test -f '$d/elsewhere/precious/file'" "and the target survives"

mkdir -p "$r/state/worktrees/nested/deep"
assert_fail "FM_GH='$MERGED' '$r/bin/fm-cleanup.sh' --task nested/deep --repo '$r'" \
  "it refuses anything that is not a direct child of the root"
assert_ok "test -d '$r/state/worktrees/nested/deep'" "and that survives too"

git init -q -b main "$d/other"; ( cd "$d/other" && git config user.email a@b.c && git config user.name t && echo y > g && git add -A && git commit -qm o )
mkdir -p "$r/state/worktrees"; cp -R "$d/other" "$r/state/worktrees/T-OTHER"
assert_fail "FM_GH='$MERGED' '$r/bin/fm-cleanup.sh' --task T-OTHER --repo '$r'" \
  "it refuses a directory that is not a worktree of this repository"
assert_ok "test -d '$r/state/worktrees/T-OTHER'" "and leaves it alone"

# --- an open pull request is unfinished work -----------------------------
OPEN="$(ghstub "$d" OPEN)"
assert_fail "FM_GH='$OPEN' '$r/bin/fm-cleanup.sh' --task T-A --repo '$r'" \
  "it refuses while the pull request is open"
assert_ok "test -d '$r/state/worktrees/T-A'" "the unmerged worktree survives"

# --- and it does the one job it has -------------------------------------
assert_ok "FM_GH='$MERGED' '$r/bin/fm-cleanup.sh' --task T-A --repo '$r'" "it removes its own worktree once merged"
assert_fail "test -d '$r/state/worktrees/T-A'" "the worktree is gone"
assert_fail "git -C '$r' rev-parse --verify t-a" "the branch is gone with it"
assert_ok "git -C '$r' rev-parse --verify main" "main is untouched"
assert_ok "test -f '$r/f'" "the repository is untouched"
assert_contains "$(jq -r .type < "$r/state/events.jsonl" 2>/dev/null | tr '\n' ' ')" "closed" "it emits closed"

assert_ok "FM_GH='$MERGED' '$r/bin/fm-cleanup.sh' --task T-A --repo '$r'" "cleaning an already-clean task exits 0"

# --- one root, inside the repository ------------------------------------
assert_fail "grep -qE 'treehouse|\\\$HOME|~/' <<<\"\$(grep -vE '^[[:space:]]*#' '$ROOT/bin/fm-cleanup.sh')\"" \
  "it writes nothing outside the repository"
rm -rf "$d"
finish
