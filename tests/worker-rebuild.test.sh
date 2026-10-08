#!/usr/bin/env bash
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=tests/lib/worker.sh
. "$ROOT/tests/lib/worker.sh"
# shellcheck source=tests/lib/worker-rebuild.sh
. "$ROOT/tests/lib/worker-rebuild.sh"
# A: main moved somewhere the task never touched. The branch still applies,
# so it is left exactly as it was: the round adds a commit on top of it.
dA="$(rb_fixture)"; bA="$(rb_branch "$dA")"; oldA="$(rb_head "$dA" "$bA")"
assert_ne "" "$oldA" "round one pushed a branch to continue"
printf 'printf "x\\n" > unrelated.txt\n' > "$dA/main.sh"
rb_move_main "$dA" "$dA/main.sh" || exit 1
rb_round_two "$dA" "$rb_add"
assert_eq "0" "$rb_rc" "a branch that still applies: the round completes"
rb_not_rebuilt "$dA" "A"
assert_eq "$oldA" "$(rb_head "$dA" "$bA^")" "a branch that still applies is left untouched"

# A2: main changed a line next to the task's. The squashed patch no longer
# applies (its context moved), but the branch still REBASES - which is what
# gate 2 asks - so it is left exactly as it is, the same as gate 2 leaves it.
dA2="$(rb_fixture)"; bA2="$(rb_branch "$dA2")"; oldA2="$(rb_head "$dA2" "$bA2")"
printf '%s\n' "sed 's/^line 3\$/line 3 by main/' src/app.txt > n && mv n src/app.txt" > "$dA2/main.sh"
rb_move_main "$dA2" "$dA2/main.sh" || exit 1
rb_round_two "$dA2" "$rb_add"
assert_eq "0" "$rb_rc" "a branch that still rebases: the round completes"
rb_not_rebuilt "$dA2" "A2"
assert_eq "$oldA2" "$(rb_head "$dA2" "$bA2^")" "a branch that still rebases is left untouched"

# B: the branch no longer rebases onto main commit by commit - gate 2 is
# red - but its change as a whole merges cleanly three-way: one commit on
# the new base, carrying both changes, and nothing for the worker.
dB="$(rb_fixture)"; bB="$(rb_branch "$dB")"
rb_replay_conflict "$dB" || exit 1; oldB="$(rb_head "$dB" "$bB")"
mainB="$(rb_head "$dB" main)"
rb_round_two "$dB" "$rb_add"
assert_eq "0" "$rb_rc" "a moved base with a clean apply: the round completes"
rb_rebuilt "$dB" "B"
assert_eq "$mainB" "$(rb_head "$dB" "$bB^")" "a clean rebuild sits on the NEW base"
assert_eq "1" "$(git --git-dir="$dB/remote.git" rev-list --count "main..$bB")" \
  "as exactly one commit"
appB="$(git --git-dir="$dB/remote.git" show "$bB:src/app.txt")"
assert_contains "$appB" "line 10 by main" "the rebuilt branch keeps main's change"
assert_contains "$appB" "line 5 by the task" "and the task's"
assert_ok "git --git-dir='$dB/remote.git' cat-file -e '$bB:src/round-two'" "and this round's work"
assert_lacks "$(cat "$dB/prompt.md")" "These files conflict" "and the worker is told nothing conflicts"
assert_eq "$oldB" "$(jq -r 'select(.type=="commit_pushed" and .data.rebuilt!=null)|.data.rebuilt.previous_head' \
  "$dB/repo/state/events.jsonl" | tail -1)" "the round's result records the previous head"
assert_contains "$(cat "$dB/ghcalls")" "pr comment 42" "the pull request is told, in place"
assert_contains "$(cat "$dB/ghcalls")" "$oldB" "with the previous head for the reviewer"
assert_lacks "$(cat "$dB/ghcalls")" "pr create" "and no second pull request is opened"

# C: main and the task changed the same line, and the same prose. Both
# files reach the worker with markers, listed by name in the prompt, and
# what the worker writes is what is pushed.
dC="$(rb_fixture)"; bC="$(rb_branch "$dC")"
rb_conflicting_main "$dC" || exit 1; mainC="$(rb_head "$dC" main)"
cat > "$dC/resolve.sh" <<'S'
grep -q '^<<<<<<< ' src/app.txt && : > src/saw-markers
{ printf 'line %s\n' 1 2 3 4; printf 'line 5 by main and the task\n'; printf 'line %s\n' 6 7 8 9 10; } > src/app.txt
awk '/^<<<<<<< / { skip = 1; print "prose as main and the task say"; next }
     /^>>>>>>> / { skip = 0; next } !skip' design/design.md > design/d.next
mv design/d.next design/design.md
S
rb_round_two "$dC" "$dC/resolve.sh"
rb_rebuilt "$dC" "C"
pC="$(cat "$dC/prompt.md")"
assert_contains "$pC" "These files conflict" "a conflicting rebuild tells the worker"
assert_contains "$pC" '- `src/app.txt`' "and names the conflicting code file"
assert_contains "$pC" '- `design/design.md`' "and a design.md conflict that is not table rows"
assert_ok "git --git-dir='$dC/remote.git' cat-file -e '$bC:src/saw-markers'" \
  "the conflicting file reached the adapter with standard markers"
assert_eq "0" "$rb_rc" "a resolved conflict: the round completes"
assert_eq "$mainC" "$(rb_head "$dC" "$bC^")" "the resolved branch is one commit on the new base"
assert_contains "$(git --git-dir="$dC/remote.git" show "$bC:src/app.txt")" "line 5 by main and the task" \
  "carrying the worker's resolution"
assert_contains "$(git --git-dir="$dC/remote.git" show "$bC:design/design.md")" "prose as main and the task say" \
  "in design.md too - no whole side was taken for it"

# D: the worker leaves a marker behind. Nothing is committed and nothing
# is pushed, and the run says which file.
dD="$(rb_fixture)"; bD="$(rb_branch "$dD")"; oldD="$(rb_head "$dD" "$bD")"
rb_conflicting_main "$dD" || exit 1
rb_round_two "$dD" "$rb_add"
rb_rebuilt "$dD" "D"
assert_eq "75" "$rb_rc" "a conflict marker left behind refuses the commit"
assert_contains "$rb_out" "conflict marker" "and says why"
assert_contains "$rb_out" "src/app.txt" "and which file"
assert_eq "$oldD" "$(rb_head "$dD" "$bD")" "the remote branch is not touched"
assert_eq "$oldD" "$(git -C "$dD/repo" rev-parse "$bD")" "nor is the local branch"

# E: someone else pushed to the branch while the round ran. The rebuilt
# branch is pushed with a lease on the head it fetched, so the push is
# refused rather than overwriting what arrived.
dE="$(rb_fixture)"; bE="$(rb_branch "$dE")"
rb_replay_conflict "$dE" || exit 1; oldE="$(rb_head "$dE" "$bE")"; mainE="$(rb_head "$dE" main)"
cat > "$dE/race.sh" <<'S'
printf 'two\n' > src/round-two
git clone -q -b "$FM_T_BRANCH" "$FM_T_DIR/remote.git" "$FM_T_DIR/racer" \
  && git -C "$FM_T_DIR/racer" -c user.email=a@b.c -c user.name=t commit -q --allow-empty -m race \
  && git -C "$FM_T_DIR/racer" push -q origin HEAD
S
pushedE="$(rb_pushed "$dE")"
rb_round_two "$dE" "$dE/race.sh"
rb_rebuilt "$dE" "E"
raceE="$(git -C "$dE/racer" rev-parse HEAD 2>/dev/null)"
assert_ne "$oldE" "$raceE" "the racer pushed a new head"
assert_eq "71" "$rb_rc" "force-with-lease refuses when the remote head moved"
assert_eq "$raceE" "$(rb_head "$dE" "$bE")" "and the concurrent push is not overwritten"
assert_contains "$rb_out" "could not push the rebuilt $bE" "the refusal is the rebuild's lease"
rebuiltE="$(sed -n 's/^fm-worker: the rebuilt commit is \([0-9a-f]*\);.*/\1/p' <<<"$rb_out")"
assert_ne "" "$rebuiltE" "and the run names the rebuilt commit"
assert_fail "git --git-dir='$dE/remote.git' cat-file -e '$rebuiltE^{commit}'" "which never reached origin"
assert_eq "$oldE" "$(git -C "$dE/repo" rev-parse "$bE")" "the local branch is back on its previous head"
assert_eq "$pushedE" "$(rb_pushed "$dE")" "and no commit_pushed says otherwise"
# The commit is made with commit-tree, which moves nothing (T-093): the
# worktree must still be left detached on it and clean, as a commit leaves
# it, or the next round takes the refused rebuild for crashed work.
assert_eq "$rebuiltE" "$(git -C "$dE/repo/state/worktrees/T-Z" rev-parse -q --verify HEAD)" \
  "the refused round leaves the worktree on the rebuilt commit"
# tracked, staged and unmerged changes only: which scratch files a round
# leaves untracked is not what this is about
assert_eq "" "$(git -C "$dE/repo/state/worktrees/T-Z" status --porcelain --untracked-files=no)" \
  "with nothing uncommitted"
assert_ok "git -C '$dE/repo/state/worktrees/T-Z' diff --cached --quiet HEAD" "and nothing staged"
# E, next round: the local branch fast-forwards to what the racer pushed,
# and the rebuild is made again from there and leased on the racer's head.
rb_round_two "$dE" "$rb_add"
assert_eq "0" "$rb_rc" "the round after a refused lease completes"
assert_lacks "$rb_out" "had uncommitted work" "without rescuing the refused rebuild as crashed work"
assert_eq "0" "$(jq -r 'select(.type=="worker_crashed")|.type' "$dE/repo/state/events.jsonl" | wc -l | tr -d ' ')" \
  "and no worker_crashed is recorded"
rb_rebuilt "$dE" "E, next round"
assert_eq "$mainE" "$(rb_head "$dE" "$bE^")" "as one commit on the base"
assert_eq "1" "$(git --git-dir="$dE/remote.git" rev-list --count "main..$bE")" "exactly one"
assert_eq "$raceE" "$(jq -r 'select(.type=="commit_pushed" and .data.rebuilt!=null)|.data.rebuilt.previous_head' \
  "$dE/repo/state/events.jsonl" | tail -1)" "rebuilt from the racer's head, not over it"

# G: a commit that fails stops the round, rebuilt or not. The script does
# not run under set -e, so an unchecked commit was stepped over and the
# round pushed and reported work it never committed. A pre-commit hook
# that refuses is the failure: the fixture's own config, nothing ambient.
rb_refusing_hook() {
  mkdir -p "$1/hooks"; printf '#!/bin/sh\nexit 1\n' > "$1/hooks/pre-commit"; chmod +x "$1/hooks/pre-commit"
  git -C "$1/repo" config core.hooksPath "$1/hooks"
}
dG="$(rb_fixture)"; bG="$(rb_branch "$dG")"; oldG="$(rb_head "$dG" "$bG")"
rb_refusing_hook "$dG"
pushedG="$(rb_pushed "$dG")"
rb_round_two "$dG" "$rb_add"
rb_not_rebuilt "$dG" "G"
assert_eq "70" "$rb_rc" "a plain round whose commit fails stops"
assert_contains "$rb_out" "could not commit" "and says so"
assert_eq "$oldG" "$(rb_head "$dG" "$bG")" "nothing is pushed"
assert_eq "$pushedG" "$(rb_pushed "$dG")" "and no commit is reported"
assert_lacks "$(cat "$dG/ghcalls")" "pr comment" "nor is the pull request told of one"
# A rebuilt round's commit is made with commit-tree, which runs no hook
# (T-093), so here the failure is commit-tree's own.
dG2="$(rb_fixture)"; bG2="$(rb_branch "$dG2")"
rb_replay_conflict "$dG2" || exit 1; oldG2="$(rb_head "$dG2" "$bG2")"; mainG2="$(rb_head "$dG2" main)"
PATH="$(rb_gitwrap "$dG2"):$PATH" FM_T_GIT_FAIL=" commit-tree " rb_round_two "$dG2" "$rb_add"
rb_rebuilt "$dG2" "G2"
assert_eq "70" "$rb_rc" "a rebuilt round whose commit fails stops"
assert_contains "$rb_out" "could not commit" "at the commit"
assert_matches "$rb_out" "fm-test: refused git .* commit-tree " "G2: the failure injected is commit-tree's"
assert_eq "$oldG2" "$(rb_head "$dG2" "$bG2")" "and pushes nothing"
assert_eq "$oldG2" "$(git -C "$dG2/repo" rev-parse "$bG2")" "and the local branch is not moved onto the base"
# G2, next round, with commit-tree working: the staged rebuild the failed
# commit left is rescued, and the branch is rebuilt again and committed once.
rb_round_two "$dG2" "$rb_add"
assert_eq "0" "$rb_rc" "the round after a failed rebuilt commit completes"
rb_rebuilt "$dG2" "G2, next round"
assert_ne "" "$(ls "$dG2/repo/state/rescued" 2>/dev/null)" "after keeping what the failed round left"
assert_eq "$mainG2" "$(rb_head "$dG2" "$bG2^")" "as one commit on the base"
assert_eq "1" "$(git --git-dir="$dG2/remote.git" rev-list --count "main..$bG2")" "exactly one"
assert_eq "$oldG2" "$(jq -r 'select(.type=="commit_pushed" and .data.rebuilt!=null)|.data.rebuilt.previous_head' \
  "$dG2/repo/state/events.jsonl" | tail -1)" "rebuilt from the branch the failed round left alone"
# G3: commit-tree carries fm_git_commit's identity rule - user.name and
# user.email from git's config, or FM_GIT_NAME / FM_GIT_EMAIL - not git's
# own: with neither, a rebuilt round refuses before it commits, as a plain
# round does. Git itself still has an identity, from GIT_AUTHOR_* and
# GIT_COMMITTER_*: the rebuild's merge needs one where the host name gives
# none (a CI runner), and without the rule commit-tree would take it and
# commit. The fixture's identity is local, so it is removed here; the
# caller's global config is kept, less any identity in it.
dG3="$(rb_fixture)"; bG3="$(rb_branch "$dG3")"
rb_replay_conflict "$dG3" || exit 1; oldG3="$(rb_head "$dG3" "$bG3")"; pushedG3="$(rb_pushed "$dG3")"
git -C "$dG3/repo" config --unset user.name; git -C "$dG3/repo" config --unset user.email
g3cfg="$dG3/global.gitconfig"; : > "$g3cfg"
for g3f in "$HOME/.gitconfig" "${XDG_CONFIG_HOME:-$HOME/.config}/git/config"; do
  [ ! -f "$g3f" ] || cat "$g3f" >> "$g3cfg"
done
git config --file "$g3cfg" --unset-all user.name; git config --file "$g3cfg" --unset-all user.email
assert_eq "" "$(GIT_CONFIG_GLOBAL="$g3cfg" git -C "$dG3/repo" config user.name)" "G3: git's config holds no user.name"
assert_eq "" "$(GIT_CONFIG_GLOBAL="$g3cfg" git -C "$dG3/repo" config user.email)" "G3: nor any user.email"
GIT_CONFIG_GLOBAL="$g3cfg" FM_GIT_NAME='' FM_GIT_EMAIL='' \
  GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=a@b.c GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=a@b.c \
  rb_round_two "$dG3" "$rb_add"
rb_rebuilt "$dG3" "G3"
assert_eq "70" "$rb_rc" "a rebuilt round with no git identity stops"
assert_contains "$rb_out" "set git user.name and user.email" "and names what is missing"
assert_eq "$oldG3" "$(rb_head "$dG3" "$bG3")" "and pushes nothing"
assert_eq "$pushedG3" "$(rb_pushed "$dG3")" "and no commit is reported"
# G4: a repository that signs its commits gets a signed rebuilt commit, as
# `git commit` would have made it; commit-tree ignores commit.gpgSign. The
# signer is a stand-in that answers the way gpg does, so no key is needed.
dG4="$(rb_fixture)"; bG4="$(rb_branch "$dG4")"
rb_replay_conflict "$dG4" || exit 1; mainG4="$(rb_head "$dG4" main)"
cat > "$dG4/fake-gpg" <<'P'
#!/usr/bin/env bash
cat > /dev/null
printf '\n[GNUPG:] SIG_CREATED D 1 8 00 0 FAKE\n' >&2
printf '%s\n' '-----BEGIN PGP SIGNATURE-----' '' 'ZmFrZQ==' '-----END PGP SIGNATURE-----'
P
chmod +x "$dG4/fake-gpg"
git -C "$dG4/repo" config commit.gpgSign true
git -C "$dG4/repo" config gpg.program "$dG4/fake-gpg"
git -C "$dG4/repo" config user.signingKey FAKE
assert_eq "true" "$(git -C "$dG4/repo/state/worktrees/T-Z" config --bool commit.gpgSign)" "G4: the fixture signs its commits"
rb_round_two "$dG4" "$rb_add"
rb_rebuilt "$dG4" "G4"
assert_eq "0" "$rb_rc" "G4: a rebuild in a repository that signs completes"
assert_eq "$mainG4" "$(rb_head "$dG4" "$bG4^")" "G4: as one commit on the base"
assert_contains "$(git --git-dir="$dG4/remote.git" cat-file commit "$bG4")" "gpgsig -----BEGIN PGP SIGNATURE-----" \
  "G4: signed, as git commit would have signed it"

# I: the frozen task file is checked before the commit. A worker that
# rewrites it while resolving is refused.
dI="$(rb_fixture)"; bI="$(rb_branch "$dI")"; oldI="$(rb_head "$dI" "$bI")"
rb_conflicting_main "$dI" || exit 1
cat > "$dI/resolve.sh" <<'S'
{ printf 'line %s\n' 1 2 3 4; printf 'line 5 by main and the task\n'; printf 'line %s\n' 6 7 8 9 10; } > src/app.txt
awk '/^<<<<<<< / { skip = 1; print "prose as main and the task say"; next }
     /^>>>>>>> / { skip = 0; next } !skip' design/design.md \
  > design/d.next
mv design/d.next design/design.md
jq '.title="renamed by the worker"' design/tasks/T-Z.json > design/t.next && mv design/t.next design/tasks/T-Z.json
S
rb_round_two "$dI" "$dI/resolve.sh"
rb_rebuilt "$dI" "I"
assert_eq "75" "$rb_rc" "a rebuilt round that changes the task's own file is refused"
assert_contains "$rb_out" "not as pin v$(jq -r .version "$dI/repo/state/pins/T-Z/1.json") has it in: design/tasks/T-Z.json" "and names the file"
assert_eq "$oldI" "$(rb_head "$dI" "$bI")" "and pushes nothing"

# K: the round after one that did not commit its rebuild - a marker left
# (75), or a round that only asked - rescues the worktree, rebuilds from
# the branch, and commits once on the base with that round's resolution.
dK="$(rb_fixture)"; bK="$(rb_branch "$dK")"; oldK="$(rb_head "$dK" "$bK")"
rb_conflicting_main "$dK" || exit 1; mainK="$(rb_head "$dK" main)"
rb_round_two "$dK" "$rb_add"
rb_rebuilt "$dK" "K"
assert_eq "75" "$rb_rc" "round two leaves a marker"
cp "$dC/resolve.sh" "$dK/resolve.sh" 2>/dev/null || true
rb_round_two "$dK" "$dK/resolve.sh"
rb_rebuilt "$dK" "K, next round"
assert_eq "0" "$rb_rc" "the next round completes"
assert_ne "" "$(ls "$dK/repo/state/rescued" 2>/dev/null)" "and kept the refused round's worktree first"
assert_eq "$mainK" "$(rb_head "$dK" "$bK^")" "one commit on the base"
assert_eq "1" "$(git --git-dir="$dK/remote.git" rev-list --count "main..$bK")" "exactly one"
assert_contains "$(git --git-dir="$dK/remote.git" show "$bK:src/app.txt")" "line 5 by main and the task" \
  "with this round's resolution in it"
assert_lacks "$(git --git-dir="$dK/remote.git" show "$bK:src/app.txt")" "<<<<<<<" "and no marker"
assert_ne "$oldK" "$(git -C "$dK/repo" rev-parse "$bK")" "the local branch is the rebuilt one"
dK2="$(rb_fixture)"; bK2="$(rb_branch "$dK2")"; oldK2="$(rb_head "$dK2" "$bK2")"
rb_conflicting_main "$dK2" || exit 1; mainK2="$(rb_head "$dK2" main)"
printf 'printf "ASK-PASS-CRITERIA:T-Z\\n" > .fm-say.md\n' > "$dK2/ask.sh"
rb_round_two "$dK2" "$dK2/ask.sh"
rb_rebuilt "$dK2" "K2"
assert_eq "0" "$rb_rc" "a rebuilt round that only asks completes"
assert_eq "$oldK2" "$(rb_head "$dK2" "$bK2")" "and publishes nothing"
cp "$dC/resolve.sh" "$dK2/resolve.sh" 2>/dev/null || true
rb_round_two "$dK2" "$dK2/resolve.sh"
rb_rebuilt "$dK2" "K2, next round"
assert_eq "0" "$rb_rc" "the round after the question completes"
assert_eq "$mainK2" "$(rb_head "$dK2" "$bK2^")" "as one commit on the base"
assert_contains "$(git --git-dir="$dK2/remote.git" show "$bK2:src/app.txt")" "line 5 by main and the task" \
  "carrying the resolution"

# L: a reused branch with no --pr is continued the same way. The lookup
# finds no pull request, the rebuild is pushed, and the one it opens
# records the previous head.
dL="$(rb_fixture)"; bL="$(rb_branch "$dL")"
rb_replay_conflict "$dL" || exit 1; oldL="$(rb_head "$dL" "$bL")"; mainL="$(rb_head "$dL" main)"
rb_round_two "$dL" "$rb_add" ''
rb_rebuilt "$dL" "L"
assert_eq "0" "$rb_rc" "a reused branch without --pr: the round completes"
assert_eq "$mainL" "$(rb_head "$dL" "$bL^")" "rebuilt on the new base"
assert_contains "$(cat "$dL/ghcalls")" "pr create" "the pull request is opened"
assert_eq "$oldL" "$(jq -r 'select(.type=="pr_opened" and .data.rebuilt!=null)|.data.rebuilt.previous_head' \
  "$dL/repo/state/events.jsonl" | tail -1)" "and the event that opens it records the previous head"

# M: the adapter stand-in deliberately moves the detached HEAD. Real crew
# rounds cannot write git metadata; this fault injection tests fm-worker's
# independent refusal to publish a rebuild whose base moved underneath it.
dM="$(rb_fixture)"; bM="$(rb_branch "$dM")"; oldM="$(rb_head "$dM" "$bM")"
rb_conflicting_main "$dM" || exit 1
cat > "$dM/commit.sh" <<'S'
git add -A && git -c user.email=a@b.c -c user.name=t commit -qm 'mid-round, markers and all'
printf 'two\n' > src/round-two
S
rb_round_two "$dM" "$dM/commit.sh"
rb_rebuilt "$dM" "M"
assert_eq "75" "$rb_rc" "a commit made on the rebuild mid-round refuses the round"
assert_contains "$rb_out" "HEAD moved off the rebuild base" "and says why"
assert_eq "$oldM" "$(rb_head "$dM" "$bM")" "nothing is pushed"
assert_eq "$oldM" "$(git -C "$dM/repo" rev-parse "$bM")" "and the local branch is not moved"

# N: a conflict git cannot write markers into. Main deleted the file the
# task changed, so the task's version sits in the worktree looking done.
# It is described as what it is, and a round that leaves it exactly as the
# merge left it is refused; one that decides is committed.
dN="$(rb_fixture)"; bN="$(rb_branch "$dN")"; oldN="$(rb_head "$dN" "$bN")"
printf 'rm src/app.txt\n' > "$dN/main.sh"
rb_move_main "$dN" "$dN/main.sh" || exit 1; mainN="$(rb_head "$dN" main)"
rb_round_two "$dN" "$rb_add"
rb_rebuilt "$dN" "N"
pN="$(cat "$dN/prompt.md")"
assert_contains "$pN" "git could not write markers into them" "a conflict with no markers is described as one"
assert_contains "$pN" "- \`src/app.txt\`: the worktree holds your task's version; main deleted it" \
  "with the side the merge left in the worktree"
# the worker skill in the same prompt says "carry standard conflict
# markers" too; only the list's own heading is the run's claim
assert_lacks "$pN" "These files conflict and carry standard conflict markers" "and is not called a file with markers"
assert_eq "75" "$rb_rc" "left as the merge left it, the round is refused"
assert_contains "$rb_out" "conflicts with no markers are still as the merge left them: src/app.txt" "and names it"
assert_eq "$oldN" "$(rb_head "$dN" "$bN")" "nothing is pushed"
printf '%s\n' 'rm -f src/app.txt' "printf 'line 5 by the task\\n' > src/line-5.txt" > "$dN/decide.sh"
rb_round_two "$dN" "$dN/decide.sh"
rb_rebuilt "$dN" "N, next round"
assert_eq "0" "$rb_rc" "a round that decides is committed"
assert_eq "$mainN" "$(rb_head "$dN" "$bN^")" "as one commit on the base"
assert_fail "git --git-dir='$dN/remote.git' cat-file -e '$bN:src/app.txt'" "with main's deletion kept"
assert_ok "git --git-dir='$dN/remote.git' cat-file -e '$bN:src/line-5.txt'" "and the task's intent"

# P: each place bring_up_to_date declines to rebuild says so, and leaves
# the branch as it is. Every one is set up where a rebuild would otherwise
# happen, so a guard that is deleted shows.
# P1: origin's branch has a commit the local one lacks, and the local one a
# commit origin lacks: the lease head is not in what would be rebuilt, so
# a rebuild would overwrite it. Not rebuilt; the plain push is refused.
dP1="$(rb_fixture)"; bP1="$(rb_branch "$dP1")"
rb_replay_conflict "$dP1" || exit 1
( cd "$dP1/repo/state/worktrees/T-Z" && printf 'local\n' > src/local.txt && git add src/local.txt \
    && rb_commit -m 'not pushed' )
git clone -q -b "$bP1" "$dP1/remote.git" "$dP1/racer" \
  && ( cd "$dP1/racer" && rb_commit --allow-empty -m 'pushed from elsewhere' && git push -q origin HEAD )
raceP1="$(git -C "$dP1/racer" rev-parse HEAD)"
rb_round_two "$dP1" "$rb_add"
rb_not_rebuilt "$dP1" "P1"
assert_contains "$rb_out" "origin's $bP1 has commits this worktree lacks" "origin ahead: says why it is not rebuilt"
assert_eq "71" "$rb_rc" "and the plain push is refused"
assert_eq "$raceP1" "$(rb_head "$dP1" "$bP1")" "the commit only origin had is not overwritten"
# P2: the base cannot be fetched.
dP2="$(rb_fixture)"; bP2="$(rb_branch "$dP2")"
rb_replay_conflict "$dP2" || exit 1; oldP2="$(rb_head "$dP2" "$bP2")"
PATH="$(rb_gitwrap "$dP2"):$PATH" FM_T_GIT_FAIL="fetch -q origin +refs/heads/main:" rb_round_two "$dP2" "$rb_add"
rb_not_rebuilt "$dP2" "P2"
assert_contains "$rb_out" "could not fetch main; $bP2 is not checked against it" "an unfetchable base: says so"
assert_eq "0" "$rb_rc" "and the round goes on without it"
assert_eq "$oldP2" "$(rb_head "$dP2" "$bP2^")" "on the branch as it was"
# P3: origin cannot say where the branch is, so there is no head to lease on.
dP3="$(rb_fixture)"; bP3="$(rb_branch "$dP3")"
rb_replay_conflict "$dP3" || exit 1; oldP3="$(rb_head "$dP3" "$bP3")"
PATH="$(rb_gitwrap "$dP3"):$PATH" FM_T_GIT_FAIL="ls-remote --exit-code --heads origin refs/heads/" \
  rb_round_two "$dP3" "$rb_add"
rb_not_rebuilt "$dP3" "P3"
assert_contains "$rb_out" "could not read origin's $bP3; not rebuilding it" "an unreadable remote head: says so"
assert_eq "0" "$rb_rc" "and the round goes on without a rebuild"
assert_eq "$oldP3" "$(rb_head "$dP3" "$bP3^")" "on the branch as it was"
# P4: main was replaced by a history the branch shares nothing with.
dP4="$(rb_fixture)"; bP4="$(rb_branch "$dP4")"; oldP4="$(rb_head "$dP4" "$bP4")"
rm -rf "$dP4/other"; git clone -q -b main "$dP4/remote.git" "$dP4/other"
( cd "$dP4/other" && git checkout -q --orphan fresh && git rm -rqf . && printf 'x\n' > x \
    && git add x && rb_commit -m 'unrelated' && git push -q -f origin fresh:main )
rb_round_two "$dP4" "$rb_add"
rb_not_rebuilt "$dP4" "P4"
assert_contains "$rb_out" "$bP4 shares no history with main" "no merge base: says so"
assert_eq "0" "$rb_rc" "and the round goes on without a rebuild"
assert_eq "$oldP4" "$(rb_head "$dP4" "$bP4^")" "on the branch as it was"
# P5: the three-way merge fails without leaving a conflict. The worker is
# never handed the bare base as though it were its branch.
dP5="$(rb_fixture)"; bP5="$(rb_branch "$dP5")"
rb_replay_conflict "$dP5" || exit 1; oldP5="$(rb_head "$dP5" "$bP5")"
PATH="$(rb_gitwrap "$dP5"):$PATH" FM_T_GIT_FAIL="merge -q --squash" rb_round_two "$dP5" "$rb_add"
assert_eq "70" "$rb_rc" "a merge that fails with no conflict stops the round"
assert_contains "$rb_out" "could not rebuild $bP5 on main" "and says so"
assert_eq "" "$(cat "$dP5/prompt.md" 2>/dev/null)" "before any worker is started"
assert_eq "$oldP5" "$(rb_head "$dP5" "$bP5")" "nothing is pushed"
assert_eq "refs/heads/$bP5" "$(git -C "$dP5/repo/state/worktrees/T-Z" symbolic-ref -q HEAD)" \
  "and the worktree is back on the branch"
assert_eq "$oldP5" "$(git -C "$dP5/repo/state/worktrees/T-Z" rev-parse HEAD)" "at its head"
# P6: the fresh worktree is not clean - here a post-checkout hook of the
# repository's own wrote into it - so the rebuild, whose failure path is a
# hard reset, is not attempted.
dP6="$(rb_fixture)"; bP6="$(rb_branch "$dP6")"
rb_replay_conflict "$dP6" || exit 1; oldP6="$(rb_head "$dP6" "$bP6")"
mkdir -p "$dP6/hooks"; printf '#!/bin/sh\nprintf "stray\\n" > stray.txt\n' > "$dP6/hooks/post-checkout"
chmod +x "$dP6/hooks/post-checkout"; git -C "$dP6/repo" config core.hooksPath "$dP6/hooks"
rb_round_two "$dP6" "$rb_add"
rb_not_rebuilt "$dP6" "P6"
assert_contains "$rb_out" "is not clean; $bP6 is not rebuilt this round" "a dirty worktree: says so"
assert_eq "0" "$rb_rc" "and the round goes on without a rebuild"
assert_eq "$oldP6" "$(rb_head "$dP6" "$bP6^")" "on the branch as it was"
# Q: the run dies during the rebuilt push. The local branch must end on
# whatever origin has, or every later round is refused at the plain push
# (71) with nothing in the system allowed to repair it. TERM goes through
# the EXIT trap; KILL leaves it to the next round. Each dies once with the
# push not landed and once with it landed, and the next round is run.
rb_dies_pushing() {   # rb_dies_pushing <dir> <signal> <landed 0|1>
  PATH="$(rb_gitwrap "$1"):$PATH" FM_T_GIT_KILL="$2" FM_T_GIT_LAND="$3" rb_round_two "$1" "$rb_add"
}
rb_pending() { git -C "$1/repo" rev-parse -q --verify "refs/fm-rebuilt/$2" 2>/dev/null; }
# a round after a landed rebuild needs work of its own to commit
rb_more="${TMPDIR:-/tmp}/fm-rb-more-$$.sh"; printf 'printf "three\\n" > src/round-three\n' > "$rb_more"
# Q1: TERM before origin took it. The branch never moved, and stays.
dQ1="$(rb_fixture)"; bQ1="$(rb_branch "$dQ1")"
rb_replay_conflict "$dQ1" || exit 1; oldQ1="$(rb_head "$dQ1" "$bQ1")"; mainQ1="$(rb_head "$dQ1" main)"
rb_dies_pushing "$dQ1" TERM 0
rb_rebuilt "$dQ1" "Q1"
assert_eq "143" "$rb_rc" "Q1: a run terminated during its rebuilt push stops"
assert_eq "$oldQ1" "$(rb_head "$dQ1" "$bQ1")" "Q1: origin never took the rebuild"
assert_eq "$oldQ1" "$(git -C "$dQ1/repo" rev-parse "$bQ1")" "Q1: so the local branch stays on the previous head"
assert_contains "$rb_out" "never reached origin; $bQ1 stays where it was" "Q1: the exit settles it and says so"
assert_eq "" "$(rb_pending "$dQ1" "$bQ1")" "Q1: and nothing is left pending"
rb_round_two "$dQ1" "$rb_add"
assert_eq "0" "$rb_rc" "Q1, next round: completes rather than being refused"
rb_rebuilt "$dQ1" "Q1, next round"
assert_eq "$mainQ1" "$(rb_head "$dQ1" "$bQ1^")" "Q1, next round: one commit on the base"
assert_eq "1" "$(git --git-dir="$dQ1/remote.git" rev-list --count "main..$bQ1")" "Q1, next round: exactly one"
# Q2: TERM after origin took it. The branch follows origin.
dQ2="$(rb_fixture)"; bQ2="$(rb_branch "$dQ2")"
rb_replay_conflict "$dQ2" || exit 1; mainQ2="$(rb_head "$dQ2" main)"
rb_dies_pushing "$dQ2" TERM 1
rb_rebuilt "$dQ2" "Q2"
assert_eq "143" "$rb_rc" "Q2: a run terminated as its rebuilt push lands stops"
newQ2="$(rb_head "$dQ2" "$bQ2")"
assert_eq "$mainQ2" "$(rb_head "$dQ2" "$bQ2^")" "Q2: origin took the rebuild"
assert_eq "$newQ2" "$(git -C "$dQ2/repo" rev-parse "$bQ2")" "Q2: so the local branch moves onto it"
assert_contains "$rb_out" "reached origin; $bQ2 now points at it" "Q2: the exit settles it and says so"
assert_eq "" "$(rb_pending "$dQ2" "$bQ2")" "Q2: and nothing is left pending"
rb_round_two "$dQ2" "$rb_more"
assert_eq "0" "$rb_rc" "Q2, next round: completes"
rb_not_rebuilt "$dQ2" "Q2, next round"
assert_eq "$newQ2" "$(rb_head "$dQ2" "$bQ2^")" "Q2, next round: continues the rebuilt commit"
# Q3: KILL before origin took it. No trap runs; the next round asks origin.
dQ3="$(rb_fixture)"; bQ3="$(rb_branch "$dQ3")"
rb_replay_conflict "$dQ3" || exit 1; oldQ3="$(rb_head "$dQ3" "$bQ3")"; mainQ3="$(rb_head "$dQ3" main)"
rb_dies_pushing "$dQ3" KILL 0
rb_rebuilt "$dQ3" "Q3"
assert_eq "137" "$rb_rc" "Q3: a run killed during its rebuilt push stops"
assert_eq "$oldQ3" "$(rb_head "$dQ3" "$bQ3")" "Q3: origin never took the rebuild"
assert_eq "$oldQ3" "$(git -C "$dQ3/repo" rev-parse "$bQ3")" "Q3: and the local branch never moved"
assert_ne "" "$(rb_pending "$dQ3" "$bQ3")" "Q3: the unconfirmed push is left pending"
rb_round_two "$dQ3" "$rb_add"
assert_eq "0" "$rb_rc" "Q3, next round: completes rather than being refused"
assert_contains "$rb_out" "never reached origin; $bQ3 stays where it was" "Q3, next round: settles it first"
assert_eq "" "$(rb_pending "$dQ3" "$bQ3")" "Q3, next round: and clears it"
rb_rebuilt "$dQ3" "Q3, next round"
assert_eq "$mainQ3" "$(rb_head "$dQ3" "$bQ3^")" "Q3, next round: one commit on the base"
# Q4: KILL after origin took it, before the local branch moved onto it.
dQ4="$(rb_fixture)"; bQ4="$(rb_branch "$dQ4")"
rb_replay_conflict "$dQ4" || exit 1; oldQ4="$(rb_head "$dQ4" "$bQ4")"; mainQ4="$(rb_head "$dQ4" main)"
rb_dies_pushing "$dQ4" KILL 1
rb_rebuilt "$dQ4" "Q4"
assert_eq "137" "$rb_rc" "Q4: a run killed as its rebuilt push lands stops"
newQ4="$(rb_head "$dQ4" "$bQ4")"
assert_eq "$mainQ4" "$(rb_head "$dQ4" "$bQ4^")" "Q4: origin took the rebuild"
assert_eq "$oldQ4" "$(git -C "$dQ4/repo" rev-parse "$bQ4")" "Q4: the local branch had not moved yet"
rb_round_two "$dQ4" "$rb_more"
assert_eq "0" "$rb_rc" "Q4, next round: completes rather than being refused"
assert_contains "$rb_out" "reached origin; $bQ4 now points at it" "Q4, next round: follows origin first"
rb_not_rebuilt "$dQ4" "Q4, next round"
assert_eq "$newQ4" "$(rb_head "$dQ4" "$bQ4^")" "Q4, next round: continues the rebuilt commit"

# R: a conflict in a file whose name is not ASCII. git's plain path output
# quotes such a name ("src/\346\226\207..."), and that string names no file:
# read as one, the conflict looks deleted, sits under "no markers", and the
# round is refused on every rebuild with nothing allowed to repair it.
# core.quotePath is set to git's default here, not read from this machine.
rb_ascii_conflict() {   # rb_ascii_conflict <dir>: both sides add src/文件.txt
  git -C "$1/repo" config core.quotePath true
  ( cd "$1/repo/state/worktrees/T-Z" && printf 'the task\n' > 'src/文件.txt' && git add -A \
      && rb_commit -m 'the task adds a file' && git push -q origin HEAD ) || return 1
  printf '%s\n' "printf 'main\\n' > 'src/文件.txt'" > "$1/main.sh"
  rb_move_main "$1" "$1/main.sh" || return 1
}
# R1: the worker resolves it; one commit on the base, carrying the resolution.
dR1="$(rb_fixture)"; bR1="$(rb_branch "$dR1")"
rb_ascii_conflict "$dR1" || exit 1; mainR1="$(rb_head "$dR1" main)"
printf '%s\n' "grep -q '^<<<<<<< ' 'src/文件.txt' && : > \"\$FM_T_DIR/saw-markers\"" \
  "printf 'main and the task\\n' > 'src/文件.txt'" > "$dR1/resolve.sh"
rb_round_two "$dR1" "$dR1/resolve.sh"
rb_rebuilt "$dR1" "R1"
pR1="$(cat "$dR1/prompt.md")"
assert_contains "$pR1" '- `src/文件.txt`' "R1: a non-ASCII conflict is listed by its real name"
assert_lacks "$pR1" '\346' "R1: never by git's quoted spelling"
assert_lacks "$pR1" "git could not write markers" "R1: and not as a conflict with no markers"
assert_ok "test -f '$dR1/saw-markers'" "R1: it reached the worker with its markers"
assert_eq "0" "$rb_rc" "R1: once resolved, the round completes"
assert_eq "$mainR1" "$(rb_head "$dR1" "$bR1^")" "R1: as one commit on the base"
assert_eq "main and the task" "$(git --git-dir="$dR1/remote.git" show "$bR1:src/文件.txt")" \
  "R1: carrying the worker's resolution"
# R2: a marker left in it is refused, and the refusal names the real file.
dR2="$(rb_fixture)"; bR2="$(rb_branch "$dR2")"
rb_ascii_conflict "$dR2" || exit 1; oldR2="$(rb_head "$dR2" "$bR2")"
rb_round_two "$dR2" "$rb_add"
rb_rebuilt "$dR2" "R2"
assert_eq "75" "$rb_rc" "R2: a marker left in a non-ASCII file refuses the commit"
assert_contains "$rb_out" "conflict markers remain in: src/文件.txt" "R2: naming the file as it is"
assert_eq "$oldR2" "$(rb_head "$dR2" "$bR2")" "R2: nothing is pushed"

# S: the rebase probe fails for a reason that is not a conflict. That says
# nothing about gate 2, so the branch is not rebuilt (and force-pushed) on it.
dS="$(rb_fixture)"; bS="$(rb_branch "$dS")"
rb_replay_conflict "$dS" || exit 1; oldS="$(rb_head "$dS" "$bS")"
PATH="$(rb_gitwrap "$dS"):$PATH" FM_T_GIT_FAIL="rebase refs/remotes/origin/main" rb_round_two "$dS" "$rb_add"
rb_not_rebuilt "$dS" "S"
assert_contains "$rb_out" "could not check whether $bS rebases onto main; not rebuilding it" \
  "S: a probe that failed without a conflict: says so"
assert_eq "0" "$rb_rc" "S: and the round goes on without a rebuild"
assert_eq "$oldS" "$(rb_head "$dS" "$bS^")" "S: on the branch as it was"

# T: TERM right after the squash merge, before the rest of the rebuild. The
# worktree is detached and dirty with the half-made rebuild; the exit must
# know it is one and publish nothing, and the next round rebuilds it.
dT="$(rb_fixture)"; bT="$(rb_branch "$dT")"
rb_replay_conflict "$dT" || exit 1; oldT="$(rb_head "$dT" "$bT")"; mainT="$(rb_head "$dT" main)"
PATH="$(rb_gitwrap "$dT"):$PATH" FM_T_GIT_KILL=TERM FM_T_GIT_KILL_ON=" merge -q --squash " FM_T_GIT_LAND=1 \
  rb_round_two "$dT" "$rb_add"
assert_eq "143" "$rb_rc" "T: a run terminated mid-rebuild stops"
assert_contains "$rb_out" "the rebuild of $bT was not committed" "T: the exit knows it holds a rebuild"
assert_lacks "$rb_out" "publishing dirty worktree" "T: and publishes nothing from it"
assert_eq "$oldT" "$(rb_head "$dT" "$bT")" "T: origin is untouched"
rb_round_two "$dT" "$rb_add"
assert_eq "0" "$rb_rc" "T, next round: completes"
rb_rebuilt "$dT" "T, next round"
assert_eq "$mainT" "$(rb_head "$dT" "$bT^")" "T, next round: one commit on the base"

# U: rebuilds in a repository running its real hooks, installed by
# bin/fm-install-hooks.sh (T-093). Every fixture above installs none, and
# that is how a rebuild the repository's own pre-commit refused on every
# real checkout - it is made on a detached HEAD - passed here.
dU1="$(RB_HOOKS=1 rb_fixture)"; bU1="$(rb_branch "$dU1")"
assert_ne "" "$bU1" "U1: round one pushed a branch under the real hooks"
assert_eq ".githooks" "$(git -C "$dU1/repo" config --get core.hooksPath)" "U1: the fixture installs the real hooks"
assert_fail "git -C '$dU1/repo' -c user.email=a@b.c -c user.name=t commit -q --allow-empty -m onmain" \
  "U1: and they are live: a commit on main is refused"
rb_replay_conflict "$dU1" || exit 1; oldU1="$(rb_head "$dU1" "$bU1")"; mainU1="$(rb_head "$dU1" main)"
rb_round_two "$dU1" "$rb_add"
rb_rebuilt "$dU1" "U1"
assert_eq "0" "$rb_rc" "U1: a rebuild under the real hooks completes"
assert_lacks "$rb_out" "detached HEAD" "U1: and no hook refused it"
assert_eq "$mainU1" "$(rb_head "$dU1" "$bU1^")" "U1: one commit on the new base"
assert_eq "1" "$(git --git-dir="$dU1/remote.git" rev-list --count "main..$bU1")" "U1: exactly one"
assert_ok "git --git-dir='$dU1/remote.git' cat-file -e '$bU1:src/round-two'" "U1: carrying this round's work"
# made as fm_git_commit makes a plain round's commit: the fixture's own
# identity as author and committer, and the task's title
assert_eq "t <a@b.c> t <a@b.c>" "$(git --git-dir="$dU1/remote.git" log -1 --format='%an <%ae> %cn <%ce>' "$bU1")" \
  "U1: under the repository's identity, as author and committer"
assert_eq "T-Z: a mock task" "$(git --git-dir="$dU1/remote.git" log -1 --format=%B "$bU1")" \
  "U1: with the message a plain round's commit has"
assert_eq "$(rb_head "$dU1" "$bU1")" "$(git -C "$dU1/repo" rev-parse "$bU1")" "U1: the local branch moved onto what was pushed"
assert_eq "refs/heads/$bU1" "$(git -C "$dU1/repo/state/worktrees/T-Z" symbolic-ref -q HEAD)" \
  "U1: and the worktree is back on the branch"
assert_eq "$oldU1" "$(jq -r 'select(.type=="commit_pushed" and .data.rebuilt!=null)|.data.rebuilt.previous_head' \
  "$dU1/repo/state/events.jsonl" | tail -1)" "U1: the previous head is recorded"
# U2: a marker left behind publishes nothing under the real hooks either;
# the round that resolves it publishes one commit on the base
dU2="$(RB_HOOKS=1 rb_fixture)"; bU2="$(rb_branch "$dU2")"; oldU2="$(rb_head "$dU2" "$bU2")"
assert_eq ".githooks" "$(git -C "$dU2/repo" config --get core.hooksPath)" "U2: the fixture installs the real hooks"
assert_fail "git -C '$dU2/repo' -c user.email=a@b.c -c user.name=t commit -q --allow-empty -m onmain" \
  "U2: and they are live: a commit on main is refused"
rb_conflicting_main "$dU2" || exit 1; mainU2="$(rb_head "$dU2" main)"
pushedU2="$(rb_pushed "$dU2")"
rb_round_two "$dU2" "$rb_add"
rb_rebuilt "$dU2" "U2"
assert_eq "75" "$rb_rc" "U2: a marker left behind refuses the round"
# both conflicts are left, and git lists them in path order
assert_contains "$rb_out" "conflict markers remain in: design/design.md, src/app.txt" "U2: and names the files"
assert_eq "$oldU2" "$(rb_head "$dU2" "$bU2")" "U2: nothing is pushed"
assert_eq "$oldU2" "$(git -C "$dU2/repo" rev-parse "$bU2")" "U2: the local branch is not moved"
assert_eq "$pushedU2" "$(rb_pushed "$dU2")" "U2: and no commit is reported"
cat > "$dU2/resolve.sh" <<'S'
{ printf 'line %s\n' 1 2 3 4; printf 'line 5 by main and the task\n'; printf 'line %s\n' 6 7 8 9 10; } > src/app.txt
awk '/^<<<<<<< / { skip = 1; print "prose as main and the task say"; next }
     /^>>>>>>> / { skip = 0; next } !skip' design/design.md > design/d.next
mv design/d.next design/design.md
S
rb_round_two "$dU2" "$dU2/resolve.sh"
rb_rebuilt "$dU2" "U2, next round"
assert_eq "0" "$rb_rc" "U2, next round: the resolved rebuild completes under the real hooks"
assert_eq "$mainU2" "$(rb_head "$dU2" "$bU2^")" "U2, next round: one commit on the base"
assert_eq "1" "$(git --git-dir="$dU2/remote.git" rev-list --count "main..$bU2")" "U2, next round: exactly one"
assert_contains "$(git --git-dir="$dU2/remote.git" show "$bU2:src/app.txt")" "line 5 by main and the task" \
  "U2, next round: carrying the resolution"
assert_eq "$(rb_head "$dU2" "$bU2")" "$(git -C "$dU2/repo" rev-parse "$bU2")" "U2, next round: the local branch moved onto it"

# W1b: the branch and main both changed one other entry; that file is handed
# over with markers, the round is refused until it is resolved, and neither
# side's text is lost on the way
dW1b="$(rb_fixture)"; bW1b="$(rb_branch "$dW1b")"
( cd "$dW1b/repo/state/worktrees/T-Z" \
    && jq '.title="one, as the task says"' design/tasks/T-1.json > n \
    && mv n design/tasks/T-1.json && rb_commit -am 'the task retitles T-1' && git push -q origin HEAD )
oldW1b="$(rb_head "$dW1b" "$bW1b")"
printf '%s\n' "jq '.title=\"one, as main says\"' design/tasks/T-1.json > n && mv n design/tasks/T-1.json" > "$dW1b/main.sh"
rb_move_main "$dW1b" "$dW1b/main.sh" || exit 1
printf '%s\n' 'cp design/tasks/T-1.json "$FM_T_DIR/t1-seen"' "$(cat "$rb_add")" > "$dW1b/look.sh"
rb_round_two "$dW1b" "$dW1b/look.sh"
rb_rebuilt "$dW1b" "W1b"
assert_contains "$(cat "$dW1b/prompt.md")" '- `design/tasks/T-1.json`' "W1b: an entry both sides changed goes to the worker by its file"
assert_contains "$(cat "$dW1b/t1-seen" 2>/dev/null)" "one, as main says" "W1b: with main's text"
assert_contains "$(cat "$dW1b/t1-seen" 2>/dev/null)" "one, as the task says" "W1b: and the branch's"
assert_eq "75" "$rb_rc" "W1b: left unresolved, the round is refused"
assert_contains "$rb_out" "design/tasks/T-1.json" "W1b: naming the file"
assert_eq "$oldW1b" "$(rb_head "$dW1b" "$bW1b")" "W1b: and nothing is pushed"
# W2: a branch already in the one-file layout; main edits the task's own
# file. The rebuild puts the branch's file back, byte for byte.
dW2="$(rb_fixture)"; bW2="$(rb_branch "$dW2")"
assert_fail "git --git-dir='$dW2/remote.git' cat-file -e 'main:design/tasks.json'" "W2: (main keeps one file per task)"
( cd "$dW2/repo/state/worktrees/T-Z" \
    && sed 's/^line 10$/line 10 for a while/' src/app.txt > n && mv n src/app.txt && rb_commit -am 'touch line 10' \
    && sed 's/^line 10 for a while$/line 10/' src/app.txt > n && mv n src/app.txt && rb_commit -am 'put line 10 back' \
    && git push -q origin HEAD )
oldW2="$(rb_head "$dW2" "$bW2")"
printf '%s\n' "sed 's/^line 10\$/line 10 by main/' src/app.txt > n && mv n src/app.txt" \
  "jq '.title=\"retitled on main\"' design/tasks/T-Z.json > n && mv n design/tasks/T-Z.json" > "$dW2/main.sh"
rb_move_main "$dW2" "$dW2/main.sh" || exit 1
rb_round_two "$dW2" "$rb_add"
rb_rebuilt "$dW2" "W2"
assert_eq "0" "$rb_rc" "W2: the rebuild completes"
assert_eq "$(git --git-dir="$dW2/remote.git" rev-parse "$oldW2:design/tasks/T-Z.json")" \
  "$(git --git-dir="$dW2/remote.git" rev-parse "$bW2:design/tasks/T-Z.json" 2>/dev/null)" \
  "W2: the task's own file comes through byte for byte as the branch had it"
assert_contains "$(git --git-dir="$dW2/remote.git" show "$bW2:src/app.txt")" "line 10 by main" "W2: and main's other change is kept"
assert_contains "$(cat "$dW2/prompt.md")" 'design/tasks/T-Z.json' "W2: the worker is told its own file is frozen"

rm -rf "$dW1b" "$dW2"


cd "$ROOT" || exit 1
PATH="$suite_original_path"; export PATH
safe_rm_rf "$suite_tools"
finish
