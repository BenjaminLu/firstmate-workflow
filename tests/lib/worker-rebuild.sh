# shellcheck shell=bash
# Caller/consumer globals are checked when linting the feature suites.
# shellcheck disable=SC2034
# --- a later round brings its branch up to date with the base (T-067) ----
# Firstmate may not run git and the adapter cannot, so when main moves
# under an open task branch and the two conflict, fm-worker.sh is the only
# thing that can bring the branch up to date. Every case below is a real
# repository with a bare remote: round one runs, main moves in a separate
# clone - so the worker has to FETCH the base, its own local main is stale -
# and round two continues the pull request.
rb_build_fixture() {   # build each immutable seed with round one done
  local RB_AUTHOR_PROJECT=self
  local d r
  d="$(fixture)" || return 1; r="$d/repo"
  (
    cd "$r" || exit 1
    mkdir -p src
    printf 'line %s\n' 1 2 3 4 5 6 7 8 9 10 > src/app.txt
    printf '%s\n' '{"id":"T-1","title":"one","scope":[],"acceptance":[]}' > design/tasks/T-1.json
    # a line with words in it between the table and the prose: git joins
    # two conflicts separated only by a blank line into one hunk
    printf '%s\n' '# design' '## 6. gates' 'seven of them' '' \
      '| id | title | depends on |' '|---|---|---|' '| T-1 | one | — |' '' \
      'the table ends here' 'prose the two sides may both edit' '## 8. board' > design/design.md
    # RB_HOOKS=1: the repository's own hooks, in the tree and installed the
    # way a real checkout installs them - relative, so every worktree runs
    # the copy it has checked out
    if [ "${RB_HOOKS:-0}" = 1 ]; then
      cp -R "$ROOT/.githooks" .githooks; cp "$ROOT/bin/fm-install-hooks.sh" bin/
    fi
    if [ "${RB_PINNED:-0}" = 1 ]; then
      printf 'project:\n  check: true\n' >> config.yaml
      printf 'state/\n' > .gitignore
    fi
    git add -A; git commit -qm 'app and task table'; git push -q origin main
    [ "${RB_HOOKS:-0}" != 1 ] || bin/fm-install-hooks.sh >/dev/null
  ) || return 1
  # the step a round runs is a file the test writes, so each case can say
  # what its worker does without a second copy of the adapter
  cat > "$r/bin/adapters/mock.sh" <<'M'
#!/usr/bin/env bash
[ "$1" = "run" ] || exit 64
[ -z "${FM_CAPTURE:-}" ] || cp "$2" "$FM_CAPTURE"
cd "$3" || exit 1
# shellcheck disable=SC1090
. "$FM_T_STEP"
M
  chmod +x "$r/bin/adapters/mock.sh"
  # round one: the task changes line 5, edits the prose, adds its own
  # table row and gives its own task file a dependency
  cat > "$d/round-one.sh" <<'S'
sed 's/^line 5$/line 5 by the task/' src/app.txt > src/app.next && mv src/app.next src/app.txt
awk '{ if ($0 == "prose the two sides may both edit") print "prose as the task says"; else print }
     /^\| T-1 \|/ { print "| T-Z | a mock task | T-1 |" }' design/design.md > design/d.next
mv design/d.next design/design.md
jq '.depends_on=["T-1"]' design/tasks/T-Z.json > design/t.next && mv design/t.next design/tasks/T-Z.json
S
  local project_args=()
  if [ "${RB_PINNED:-0}" = 1 ]; then
    # Pinned seeds keep the approved task bytes throughout round one.
    sed '/^jq /d' "$d/round-one.sh" > "$d/pinned-round-one.sh"
    mv "$d/pinned-round-one.sh" "$d/round-one.sh"
    printf '%s\n' '{"type":"greenlit","actor":"captain","ts":"2026-10-03T00:00:00Z"}' > "$r/state/events.jsonl"
    seed_spec_preflight "$r" T-Z "" firstmate-workflow || return 1
    project_args=(--project firstmate-workflow)
    RB_AUTHOR_PROJECT=firstmate-workflow
  fi
  seed_self_pr_authoring "$r" T-Z "${RB_AUTHOR_PROJECT:-self}" || return 1
  ghstub "$d" >/dev/null
  ( cd "$r" && FM_ROOT="$r" FM_GH="$d/stub/gh" FM_T_STEP="$d/round-one.sh" \
      bin/fm-worker.sh --task T-Z ${project_args[@]+"${project_args[@]}"} >/dev/null 2>&1 ) || return 1
  printf '%s' "$d"
}
# Round one is identical across the rebuild cases. Keep one seed for each
# hook configuration, then relocate copies; never share mutable Git state.
if [ "${RB_FIXTURE_LIBRARY_ONLY:-0}" != 1 ]; then
  rb_seed="$(rb_build_fixture)" || exit 1
  rb_hook_seed="$(RB_HOOKS=1 rb_build_fixture)" || exit 1
fi
rb_fixture() {
  local d seed="$rb_seed"
  [ "${RB_HOOKS:-0}" != 1 ] || seed="$rb_hook_seed"
  d="$(safe_tmpdir)" || return 1
  cp -R "$seed/." "$d/" || return 1
  # Git linked-worktree pointers, the local remote, run receipts, mirrors
  # and generated stubs all name the seed. Relocate textual metadata only;
  # Git object databases and index checksums must stay byte-for-byte intact.
  python3 - "$seed" "$d" <<'PYRELOCATE'
import os
from pathlib import Path
import sys
old, new = sys.argv[1:]
for directory, dirs, files in os.walk(new):
    if Path(directory).name == 'objects':
        dirs[:] = []
        continue
    for name in files:
        path = Path(directory) / name
        if path.is_symlink():
            target = os.readlink(path)
            if old in target:
                path.unlink()
                path.symlink_to(target.replace(old, new))
            continue
        if name == 'index' or name.startswith('sharedindex.'):
            continue
        data = path.read_bytes()
        if b'\0' in data or old.encode() not in data:
            continue
        path.write_bytes(data.replace(old.encode(), new.encode()))
PYRELOCATE
  [ "$?" = 0 ] || return 1
  printf '%s' "$d"
}
rb_branch() { git --git-dir="$1/remote.git" for-each-ref --format='%(refname:short)' refs/heads | grep -v '^main$' | head -1; }
rb_head() { git --git-dir="$1/remote.git" rev-parse "$2" 2>/dev/null; }
rb_move_main() {   # rb_move_main <dir> <script run in a fresh clone of main>
  rm -rf "$1/other"
  local clone_error source_exists=false destination_exists=false source_main destination_main
  clone_error="$(mktemp "$1/clone-error.XXXXXX")" || return 1
  if ! git clone --no-local -q -b main "$1/remote.git" "$1/other" 2> "$clone_error"; then
    [ ! -d "$1/remote.git" ] || source_exists=true
    [ ! -d "$1/other" ] || destination_exists=true
    source_main="$(git --git-dir="$1/remote.git" rev-parse --short=12 refs/heads/main 2>/dev/null)" || source_main=unavailable
    destination_main="$(git -C "$1/other" rev-parse --short=12 refs/heads/main 2>/dev/null)" || destination_main=unavailable
    printf 'rebuild fixture clone failed: source_exists=%s destination_exists=%s source_main=%s destination_main=%s\n' \
      "$source_exists" "$destination_exists" "$source_main" "$destination_main" >&2
    tail -c 4096 "$clone_error" >&2
    rm -f "$clone_error"
    return 1
  fi
  cat "$clone_error" >&2
  rm -f "$clone_error"
  # shellcheck disable=SC1090
  ( cd "$1/other" && git config user.email a@b.c && git config user.name t \
      && . "$2" && git add -A && git commit -qm 'main moved' && git push -q origin main )
}
rb_round_two() {   # rb_round_two <dir> <step> [pr, '' for none]; sets rb_out and rb_rc
  local pr="${3-42}" project_args=()
  [ "${RB_PINNED:-0}" != 1 ] || project_args=(--project firstmate-workflow)
  # a prompt left from an earlier round would answer for this one
  : > "$1/ghcalls"; rm -f "$1/prompt.md"
  rb_out="$(cd "$1/repo" && FM_ROOT="$1/repo" FM_GH="$1/stub/gh" FM_T_STEP="$2" \
    FM_T_DIR="$1" FM_T_BRANCH="$(rb_branch "$1")" FM_CAPTURE="$1/prompt.md" \
    bin/fm-worker.sh --task T-Z ${project_args[@]+"${project_args[@]}"} ${pr:+--pr "$pr"} 2>&1)"; rb_rc=$?
}
if [ "${RB_FIXTURE_LIBRARY_ONLY:-0}" != 1 ]; then
  printf 'printf "two\\n" > src/round-two\n' > "${TMPDIR:-/tmp}/fm-rb-add-$$.sh"
  rb_add="${TMPDIR:-/tmp}/fm-rb-add-$$.sh"
fi
# What each case sets up has to have happened, or its other assertions
# pass on code that never rebuilds anything: a refused push, an untouched
# branch and a 71 all look the same with or without a rebuild in front.
rb_rebuilt() {   # rb_rebuilt <dir> <case>: this round rebuilt the branch
  assert_contains "$(cat "$1/prompt.md" 2>/dev/null)" "Your branch was rebuilt" "$2: the worker was told of a rebuild"
  assert_contains "$rb_out" "no longer rebases onto main; rebuilt on" "$2: and the run rebuilt the branch"
}
rb_not_rebuilt() {   # rb_not_rebuilt <dir> <case>: this round left the branch as it was
  assert_lacks "$(cat "$1/prompt.md" 2>/dev/null)" "Your branch was rebuilt" "$2: the worker is not told of a rebuild"
  assert_lacks "$rb_out" "rebuilt on" "$2: and the run rebuilt nothing"
}
rb_pushed() { jq -r 'select(.type=="commit_pushed")|.type' "$1/repo/state/events.jsonl" | wc -l | tr -d ' '; }
rb_commit() { git -c user.email=a@b.c -c user.name=t commit -q "$@"; }
# The branch no longer rebases onto main commit by commit, yet its change as
# a whole merges cleanly: two later commits touched line 10 and put it back,
# and main changed line 10. Gate 2 replays commits, so gate 2 is red here -
# while the squashed patch (line 5, three lines of context) still applies.
rb_replay_conflict() {   # rb_replay_conflict <dir>
  ( cd "$1/repo/state/worktrees/T-Z" \
      && sed 's/^line 10$/line 10 for a while/' src/app.txt > n && mv n src/app.txt && rb_commit -am 'touch line 10' \
      && sed 's/^line 10 for a while$/line 10/' src/app.txt > n && mv n src/app.txt && rb_commit -am 'put line 10 back' \
      && git push -q origin HEAD ) || return 1
  printf '%s\n' "sed 's/^line 10\$/line 10 by main/' src/app.txt > n && mv n src/app.txt" > "$1/main.sh"
  rb_move_main "$1" "$1/main.sh"
}
# Fails one git command the worker runs, by the words it is run with, and
# passes every other one through to the real git.
rb_git_real="$(command -v git)"
rb_gitwrap() {   # rb_gitwrap <dir>; prints a PATH entry
  mkdir -p "$1/gitwrap"
  cat > "$1/gitwrap/git" <<W
#!/usr/bin/env bash
if [ -n "\${FM_T_GIT_FAIL:-}" ]; then
  case " \$* " in *"\$FM_T_GIT_FAIL"*) echo "fm-test: refused git \$*" >&2; exit 128 ;; esac
fi
# the run dies during one git command - its leased push unless told which -
# after that command ran, or before
if [ -n "\${FM_T_GIT_KILL:-}" ]; then
  case " \$* " in *"\${FM_T_GIT_KILL_ON:- --force-with-lease=}"*)
    [ "\${FM_T_GIT_LAND:-}" != 1 ] || "$rb_git_real" "\$@"
    kill -"\$FM_T_GIT_KILL" "\$PPID"; exit 128 ;;
  esac
fi
exec "$rb_git_real" "\$@"
W
  chmod +x "$1/gitwrap/git"; printf '%s' "$1/gitwrap"
}

rb_conflicting_main() {
  printf '%s\n' "sed 's/^line 5\$/line 5 by main/' src/app.txt > n && mv n src/app.txt" \
    "sed 's/^prose the two sides may both edit\$/prose as main says/' design/design.md > n && mv n design/design.md" \
    > "$1/main.sh"
  rb_move_main "$1" "$1/main.sh"
}
