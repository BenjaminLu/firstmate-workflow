#!/usr/bin/env bash
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=tests/lib/worker.sh
. "$ROOT/tests/lib/worker.sh"
# round_two is decided from the local branch OR origin's, so a wiped
# state/ or a second machine is still a later round - which is what
# gates the lookup, and therefore whether a branch that already has a
# pull request reaches `pr create`. The comment the old post-push
# lookup carried said that was the failure it existed to prevent, so
# the replacement has to be shown to cover it.
d12="$(fixture)"; r12="$d12/repo"; GH12="$(ghstub "$d12")"
cat > "$r12/bin/adapters/mock.sh" <<'M'
#!/usr/bin/env bash
[ "$1" = "run" ] || exit 64
mkdir -p "$3/src"
if [ -f "$3/src/round-one" ]; then printf 'two\n' > "$3/src/round-two"
else printf 'one\n' > "$3/src/round-one"; fi
M
chmod +x "$r12/bin/adapters/mock.sh"
( cd "$r12" && FM_ROOT="$r12" FM_GH="$GH12" bin/fm-worker.sh --task T-Z >/dev/null 2>&1 )
b12="$(cd "$r12" && git for-each-ref --format='%(refname:short)' refs/heads | grep -v '^main$' | head -1)"
assert_ok "git -C '$r12' cat-file -e '$b12:src/round-one'" "the first round pushed a branch"
# the local trace is gone: the worktree, the branch, the whole of state/
( cd "$r12" && git worktree remove --force "state/worktrees/T-Z" >/dev/null 2>&1; true )
( cd "$r12" && git branch -D "$b12" >/dev/null 2>&1 )
assert_fail "git -C '$r12' show-ref --verify --quiet 'refs/heads/$b12'" \
  "and nothing local remembers it"
assert_ok "git -C '$r12' ls-remote --exit-code --heads origin '$b12'" "but origin does"
cat > "$d12/stub/gh" <<'G'
#!/usr/bin/env bash
echo "gh $*" >> "$(dirname "$0")/../ghcalls"
case " $* " in
  *" pr list "*) echo 55; exit 0 ;;
  *" pr checks "*) exit 0 ;;
  *" pr view "*" comments "*) printf '## reviewer-1\n\nnothing to add\n' ;;
esac
exit 0
G
chmod +x "$d12/stub/gh"; : > "$d12/ghcalls"
out13="$(cd "$r12" && FM_ROOT="$r12" FM_GH="$GH12" bin/fm-worker.sh --task T-Z 2>&1)"
assert_contains "$out13" "already has #55" "a branch only origin remembers is still a later round"
assert_contains "$(jq -r 'select(.type=="commit_pushed")|.pr|tostring' \
  < "$r12/state/events.jsonl" | tail -1)" "55" "and its push points at the one that is there"
assert_eq "1" "$(grep -c 'pr list' "$d12/ghcalls" || true)" \
  "having asked once, not once at each site that wants the number"
rm -rf "$d12"

# T-037: branch_guess already finds the existing branch for this task; the
# bug was that fm-worker.sh threw that away and recomputed a branch name
# from the CURRENT title on every round anyway. A title is mutable and the
# slug is cut to 28 characters, so a branch made under an older, untruncated
# scheme - or simply named while the title read differently - no longer
# matches a fresh recompute. The old code then fell to the `else` and made
# a SECOND branch from base, stranding the first one's commits and PR.
# Fail-first: this reproduces without a live captain decision, model or
# network API - the fixture's mock adapter and gh stub are all it drives.
d21="$(fixture)"; r21="$d21/repo"; GH21="$(ghstub "$d21")"
long_title='a mock task with a title long enough that slugging it truncates to twenty eight characters'
jq --arg t "$long_title" '.title=$t' "$r21/design/tasks/T-Z.json" > "$r21/design/T-Z.next"
mv "$r21/design/T-Z.next" "$r21/design/tasks/T-Z.json"
seed_spec_preflight "$r21" T-Z
( cd "$r21" && git add -A && git commit -qm retitle && git push -q origin main )
cat > "$r21/bin/adapters/mock.sh" <<'M'
#!/usr/bin/env bash
[ "$1" = "run" ] || exit 64
mkdir -p "$3/src"
if [ -f "$3/src/round-one" ]; then printf 'two\n' > "$3/src/round-two"
else printf 'one\n' > "$3/src/round-one"; fi
M
chmod +x "$r21/bin/adapters/mock.sh"
( cd "$r21" && FM_ROOT="$r21" FM_GH="$GH21" bin/fm-worker.sh --task T-Z >/dev/null 2>&1 )
trunc_branch="$(cd "$r21" && git for-each-ref --format='%(refname:short)' refs/heads | grep -v '^main$' | head -1)"
assert_ne "" "$trunc_branch" "the first round made a branch"
assert_ok "cd '$r21' && git cat-file -e '$trunc_branch:src/round-one'" "and committed its work"

# renamed the way a pre-truncation scheme (or an earlier title) would have
# left it: the whole slug, not cut to 28 characters, so a fresh recompute
# from the CURRENT title no longer names it
full_slug="t-z-$(printf '%s' "$long_title" | tr 'A-Z' 'a-z' | tr -cs 'a-z0-9' '-' | sed 's/-*$//')"
assert_ne "$trunc_branch" "$full_slug" "the fixture's title is long enough that truncation actually changes it"
# the round-one worktree still has trunc_branch checked out; a rename has to
# clear that first, same as the origin-only fixture below does
( cd "$r21" && git worktree remove --force "state/worktrees/T-Z" >/dev/null 2>&1; true )
( cd "$r21" && git branch -m "$trunc_branch" "$full_slug" \
    && git push -q origin ":$trunc_branch" "$full_slug" )

: > "$d21/ghcalls"
( cd "$r21" && FM_ROOT="$r21" FM_GH="$GH21" bin/fm-worker.sh --task T-Z >/dev/null 2>&1 )
branches_after="$(cd "$r21" && git for-each-ref --format='%(refname:short)' refs/heads | grep -v '^main$')"
assert_eq "1" "$(grep -c . <<<"$branches_after")" \
  "a title-mismatched local branch is reused, never doubled"
assert_eq "$full_slug" "$branches_after" "and it is the branch the first round pushed, not a new one from base"
assert_ok "cd '$r21' && git cat-file -e '$full_slug:src/round-one'" "the second round keeps the first round's work"
assert_ok "cd '$r21' && git cat-file -e '$full_slug:src/round-two'" "and adds its own on the same branch"
assert_contains "$(cat "$d21/ghcalls")" "pr list --head $full_slug" \
  "it looked up the pull request for the reused branch, treating this as a later round"
rm -rf "$d21"

# The same mismatch again, but nothing local remembers the branch at all -
# a wiped state/ or a second machine, the way the origin-only case above is
# already covered for a branch whose name never changed. branch_guess has
# to search origin too, or the second-branch bug reappears the moment the
# local ref is gone as well as the name.
d22="$(fixture)"; r22="$d22/repo"; GH22="$(ghstub "$d22")"
long_title='a mock task whose title is long enough that a fresh slug truncates differently'
jq --arg t "$long_title" '.title=$t' "$r22/design/tasks/T-Z.json" > "$r22/design/T-Z.next"
mv "$r22/design/T-Z.next" "$r22/design/tasks/T-Z.json"
seed_spec_preflight "$r22" T-Z
( cd "$r22" && git add -A && git commit -qm retitle && git push -q origin main )
cat > "$r22/bin/adapters/mock.sh" <<'M'
#!/usr/bin/env bash
[ "$1" = "run" ] || exit 64
mkdir -p "$3/src"
if [ -f "$3/src/round-one" ]; then printf 'two\n' > "$3/src/round-two"
else printf 'one\n' > "$3/src/round-one"; fi
M
chmod +x "$r22/bin/adapters/mock.sh"
( cd "$r22" && FM_ROOT="$r22" FM_GH="$GH22" bin/fm-worker.sh --task T-Z >/dev/null 2>&1 )
trunc_branch="$(cd "$r22" && git for-each-ref --format='%(refname:short)' refs/heads | grep -v '^main$' | head -1)"
assert_ne "" "$trunc_branch" "the first round made a branch"

full_slug="t-z-$(printf '%s' "$long_title" | tr 'A-Z' 'a-z' | tr -cs 'a-z0-9' '-' | sed 's/-*$//')"
assert_ne "$trunc_branch" "$full_slug" "the fixture's title is long enough that truncation actually changes it"
( cd "$r22" && git worktree remove --force "state/worktrees/T-Z" >/dev/null 2>&1; true )
( cd "$r22" && git branch -m "$trunc_branch" "$full_slug" \
    && git push -q origin ":$trunc_branch" "$full_slug" )
( cd "$r22" && git branch -D "$full_slug" >/dev/null 2>&1 )
assert_fail "cd '$r22' && git show-ref --verify --quiet 'refs/heads/$full_slug'" \
  "nothing local remembers the renamed branch"
assert_ok "cd '$r22' && git ls-remote --exit-code --heads origin '$full_slug'" "but origin does"

( cd "$r22" && FM_ROOT="$r22" FM_GH="$GH22" bin/fm-worker.sh --task T-Z >/dev/null 2>&1 )
branches_after="$(cd "$r22" && git for-each-ref --format='%(refname:short)' refs/heads | grep -v '^main$')"
assert_eq "1" "$(grep -c . <<<"$branches_after")" \
  "a remote-only, title-mismatched branch is reused, never doubled"
assert_eq "$full_slug" "$branches_after" "and it is the branch origin remembered, not a new one from base"
assert_ok "cd '$r22' && git cat-file -e '$full_slug:src/round-one'" "the second round keeps the first round's work"
assert_ok "cd '$r22' && git cat-file -e '$full_slug:src/round-two'" "and adds its own on the same branch"
rm -rf "$d22"

# And the untouched case: a task with genuinely no existing branch still
# gets a fresh one derived from the title, exactly as before this fix.
d23="$(fixture T-Y)"; r23="$d23/repo"; GH23="$(ghstub "$d23")"
out23="$(cd "$r23" && FM_ROOT="$r23" FM_GH="$GH23" bin/fm-worker.sh --task T-Y 2>&1)"
branch23="$(printf '%s' "$out23" | tail -1)"
assert_contains "$branch23" "t-y" "a task with no existing branch still names one from its id"
assert_ok "cd '$r23' && git show-ref --verify --quiet 'refs/heads/$branch23'" "and creates it fresh from base"
assert_eq "1" "$(cd "$r23" && git rev-list --count "main..$branch23")" "with exactly the one commit from this round"
rm -rf "$d23"

# A run that was interrupted leaves its files uncommitted in the worktree,
# and the next dispatch used to delete them before anything could see
# them. Tonight that nearly cost two finished tasks.
d7="$(fixture)"; r7="$d7/repo"; GH7="$(ghstub "$d7")"
cat > "$r7/bin/adapters/mock.sh" <<'M'
#!/usr/bin/env bash
[ "$1" = "run" ] || exit 64
mkdir -p "$3/src"; printf 'work\n' > "$3/src/thing"
M
chmod +x "$r7/bin/adapters/mock.sh"
( cd "$r7" && FM_ROOT="$r7" FM_GH="$GH7" bin/fm-worker.sh --task T-Z >/dev/null 2>&1 )
# leave something uncommitted behind, the way an interrupted run does
printf 'half finished\n' > "$r7/state/worktrees/T-Z/src/unsaved"
out7="$(cd "$r7" && FM_ROOT="$r7" FM_GH="$GH7" bin/fm-worker.sh --task T-Z 2>&1)"
assert_contains "$out7" "uncommitted work" "an interrupted run's files are noticed"
rescued="$(find "$r7/state/rescued" -name unsaved 2>/dev/null | head -1)"
assert_ne "" "$rescued" "and copied somewhere before the worktree is remade"
assert_contains "$(cat "$rescued" 2>/dev/null)" "half finished" "with what was in them"
assert_contains "$(jq -r .type < "$r7/state/events.jsonl" | tr '\n' ' ')" "worker_crashed" \
  "and the log says it happened"
rm -rf "$d7"


cd "$ROOT" || exit 1
PATH="$suite_original_path"; export PATH
safe_rm_rf "$suite_tools"
finish
