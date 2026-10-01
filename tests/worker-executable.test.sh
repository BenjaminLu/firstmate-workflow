#!/usr/bin/env bash
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=tests/lib/worker.sh
. "$ROOT/tests/lib/worker.sh"
# shellcheck source=tests/lib/worker-rebuild.sh
. "$ROOT/tests/lib/worker-rebuild.sh"
# --- a new script keeps its executable bit (T-098) -----------------------
# The claude worker's sandbox refuses chmod, so every script a worker added
# was committed 100644 and a suite running it by path failed with 126
# (T-048, T-059). fm-worker.sh sets the bit in the index itself: on a file
# the round adds under bin/ or tests/, with a shebang, in a directory whose
# existing scripts are executable. Never removed, never on another file.
dX="$(RB_HOOKS=1 rb_fixture)"; bX="$(rb_branch "$dX")"
( cd "$dX/repo/state/worktrees/T-Z" && mkdir -p tests \
    && printf '#!/usr/bin/env bash\nexit 0\n' > tests/old.test.sh && chmod +x tests/old.test.sh \
    && printf '#!/usr/bin/env bash\n: kept 100644\n' > bin/sourced.sh && chmod -x bin/sourced.sh \
    && mkdir -p tests/lib && printf '#!/usr/bin/env bash\n: sourced\n' > tests/lib/common.sh \
    && chmod -x tests/lib/common.sh \
    && git add -A && rb_commit -m 'an executable test and a sourced script' && git push -q origin HEAD ) \
  || echo "fm-test: could not set up X" >&2
assert_eq "100644" "$(git --git-dir="$dX/remote.git" ls-tree "$bX" bin/sourced.sh | cut -c1-6)" \
  "X: the fixture's existing sourced script is 100644"
cat > "$dX/scripts.sh" <<'S'
printf '#!/usr/bin/env bash\necho tool\n' > bin/fm-tool
printf '#!/usr/bin/env bash\necho new\n' > tests/new.test.sh
printf '#!/usr/bin/env python3\nprint(1)\n' > tests/helper.py
printf 'plain notes\n' > bin/notes.txt
printf 'echo no shebang\n' > tests/plain.sh
printf '#!/usr/bin/env bash\necho elsewhere\n' > src/run.sh
printf '#!/usr/bin/env bash\n: still 100644\n' > bin/sourced.sh
printf '#!/usr/bin/env bash\n: sourced too\n' > tests/lib/more.sh
mkdir -p tests/fresh && printf '#!/usr/bin/env bash\necho fresh\n' > tests/fresh/run.sh
chmod -x tests/lib/more.sh tests/fresh/run.sh 2>/dev/null || true
chmod -x bin/fm-tool tests/new.test.sh tests/helper.py 2>/dev/null || true
S
rb_round_two "$dX" "$dX/scripts.sh"
assert_eq "0" "$rb_rc" "X: the round completes"
rb_not_rebuilt "$dX" "X"
x_mode() { git --git-dir="$dX/remote.git" ls-tree "$bX" -- "$1" | cut -c1-6; }
assert_eq "100755" "$(x_mode bin/fm-tool)" "X: a new script under bin/ is committed 100755"
assert_eq "100755" "$(x_mode tests/new.test.sh)" "X: and one under tests/"
assert_eq "100755" "$(x_mode tests/helper.py)" "X: a .py with a shebang too"
assert_eq "100644" "$(x_mode bin/notes.txt)" "X: a new file that is no script stays 100644"
assert_eq "100644" "$(x_mode tests/plain.sh)" "X: and a .sh with no shebang line"
assert_eq "100644" "$(x_mode src/run.sh)" "X: a new script outside bin/ and tests/ is left as added"
assert_eq "100644" "$(x_mode bin/sourced.sh)" "X: an existing file's mode is untouched"
assert_eq "100755" "$(x_mode tests/old.test.sh)" "X: and an existing bit is never removed"
# the directory decides as well as the file: one whose scripts are all
# sourced, and one with no script before this round, run nothing by path
assert_eq "100644" "$(x_mode tests/lib/more.sh)" "X: a new script beside only sourced ones stays 100644"
assert_eq "100644" "$(x_mode tests/fresh/run.sh)" "X: and one in a new directory"
assert_eq "" "$(git -C "$dX/repo/state/worktrees/T-Z" status --porcelain --untracked-files=no)" \
  "X: the worktree agrees with what was committed"
# the run names each file it marked, and only those
for f in bin/fm-tool tests/new.test.sh tests/helper.py; do
  assert_contains "$rb_out" "fm-worker: $f is a new script; it is committed executable" "X: the run names $f"
done
assert_eq "3" "$(grep -c 'is a new script; it is committed executable' <<<"$rb_out")" "X: and no other file"
# X2: the same in a rebuilt round, read against the base it is made on
dX2="$(RB_HOOKS=1 rb_fixture)"; bX2="$(rb_branch "$dX2")"
rb_replay_conflict "$dX2"
printf 'printf "#!/usr/bin/env bash\\necho tool\\n" > bin/fm-tool\n' > "$dX2/tool.sh"
rb_round_two "$dX2" "$dX2/tool.sh"
rb_rebuilt "$dX2" "X2"
assert_eq "0" "$rb_rc" "X2: the rebuilt round completes"
assert_eq "100755" "$(git --git-dir="$dX2/remote.git" ls-tree "$bX2" -- bin/fm-tool | cut -c1-6)" \
  "X2: a new script in a rebuilt round is committed 100755"
# X4: a script an earlier round added without the bit is not this round's
# to change, though a rebuild puts it on a base that never had it
dX4="$(RB_HOOKS=1 rb_fixture)"; bX4="$(rb_branch "$dX4")"
( cd "$dX4/repo/state/worktrees/T-Z" && printf '#!/usr/bin/env bash\necho old\n' > bin/fm-earlier \
    && chmod -x bin/fm-earlier && git add bin/fm-earlier && rb_commit -m 'an earlier round' \
    && git push -q origin HEAD ) || echo "fm-test: could not set up X4" >&2
rb_replay_conflict "$dX4"
rb_round_two "$dX4" "$dX2/tool.sh"
rb_rebuilt "$dX4" "X4"
assert_eq "0" "$rb_rc" "X4: the rebuilt round completes"
assert_eq "100755" "$(git --git-dir="$dX4/remote.git" ls-tree "$bX4" -- bin/fm-tool | cut -c1-6)" \
  "X4: this round's new script is committed 100755"
assert_eq "100644" "$(git --git-dir="$dX4/remote.git" ls-tree "$bX4" -- bin/fm-earlier | cut -c1-6)" \
  "X4: one the previous head already had keeps its mode"
# X5: the index will not take the bit. The round's commit is not made
# without it; on a rebuild, which the exit never publishes, nothing is.
dX5="$(RB_HOOKS=1 rb_fixture)"; bX5="$(rb_branch "$dX5")"
rb_replay_conflict "$dX5"; oldX5="$(rb_head "$dX5" "$bX5")"
PATH="$(rb_gitwrap "$dX5"):$PATH" FM_T_GIT_FAIL=" update-index --chmod=+x " rb_round_two "$dX5" "$dX2/tool.sh"
rb_rebuilt "$dX5" "X5"
assert_eq "70" "$rb_rc" "X5: a bit the index refuses stops the round"
assert_contains "$rb_out" "could not set the executable bit on a new script" "X5: and says why"
assert_eq "$oldX5" "$(rb_head "$dX5" "$bX5")" "X5: nothing is pushed"
# X6: the same refusal in a plain round. Its commit is not made either, and
# the exit's checkpoint saves the worktree as it does after any exit before
# that commit - through fm-checkpoint.sh, so without the bit.
dX6="$(RB_HOOKS=1 rb_fixture)"; bX6="$(rb_branch "$dX6")"; oldX6="$(rb_head "$dX6" "$bX6")"
PATH="$(rb_gitwrap "$dX6"):$PATH" FM_T_GIT_FAIL=" update-index --chmod=+x " rb_round_two "$dX6" "$dX2/tool.sh"
rb_not_rebuilt "$dX6" "X6"
assert_eq "70" "$rb_rc" "X6: a bit the index refuses stops a plain round"
assert_contains "$rb_out" "could not set the executable bit on a new script on $bX6; the round is not committed" \
  "X6: and says why"
assert_contains "$rb_out" "publishing dirty worktree (exit-70)" "X6: the exit's checkpoint runs"
assert_eq "$oldX6" "$(rb_head "$dX6" "$bX6^")" "X6: and saves the worktree as one commit on the branch"
assert_eq "100644" "$(git --git-dir="$dX6/remote.git" ls-tree "$bX6" -- bin/fm-tool | cut -c1-6)" \
  "X6: carrying the script without its bit"

cd "$ROOT" || exit 1
PATH="$suite_original_path"; export PATH
safe_rm_rf "$suite_tools"
finish
