#!/usr/bin/env bash
# The six gates: 1, 2, 4, 5, 6 and 7. Every one of them reads the
# filesystem, git, or an exit code. None of them reads what a model said
# about its own work.
#
#   fm-gate.sh --task T-004 --repo <dir> --branch <name> [--pr 9] [--only N]
#
# Exits 0 when all six pass, otherwise the number of the gate that failed.
# The exit code is the gate number so a caller can tell "the tests are vacuous"
# from "the reviewer never signed".
#
# Gate 3 is retired, and its number with it (T-114). It ran the whole
# project.check locally, which is what the required GitHub check already runs
# on the same head and gate 6 already reads; run beside other checks on one
# machine it overran its budget and held heads CI had passed. No gate runs the
# whole check any more, except gate 5 when it cannot tell which suites the
# diff touches, and then it says so. Nothing exits 3, and `--only 3` is
# refused rather than reported green.
#
# Gate runs on one machine are serialized: a run holds FM_GATE_LOCK (by
# default /tmp/fm-gate.lock, the same path whatever TMPDIR the caller has)
# from start to exit, and another waits for it. A run started inside a run
# holding the same lock is refused: waiting would wait for ever, and skipping
# the lock would not serialize. A suite that runs this script sets its own
# FM_GATE_LOCK.
set -uo pipefail
# Nothing below may read standard input. A dispatched child inherits it, and
# a child that reads it blocks the caller waiting for a human who is not
# there. One guarantee, in one place; the repository's own lint fails if a
# script that dispatches is missing it.
exec < /dev/null
# kept whole: the lock below re-runs this script once, with the lock open
_fm_argv=("$@")

REPO=''; TASK=''; BRANCH=''; PR=''; ONLY=''
BASE="${FM_BASE:-main}"
GH="${FM_GH:-gh}"
REVIEWER="${FM_REVIEWER_LOGIN:-}"

# see fm_need in bin/fm-config.sh for why: `shift 2` with one argument
# left does not shift, and the loop spins. The arguments are read before
# anything is sourced, so this file carries the two lines rather than the
# explanation.
need() { [ "$#" -ge 2 ] || { echo "fm-gate: $1 needs a value" >&2; exit 64; }; }
while [ $# -gt 0 ]; do
  case "$1" in
    --task) need "$@"; TASK="${2-}"; shift 2 ;;
    --repo) need "$@"; REPO="${2-}"; shift 2 ;;
    --branch) need "$@"; BRANCH="${2-}"; shift 2 ;;
    --pr) need "$@"; PR="${2-}"; shift 2 ;;
    --only) need "$@"; ONLY="${2-}"; shift 2 ;;
    *) echo "fm-gate: unknown argument $1" >&2; exit 64 ;;
  esac
done
[ -n "$TASK" ] && [ -n "$REPO" ] && [ -n "$BRANCH" ] || {
  echo "usage: fm-gate.sh --task <id> --repo <dir> --branch <name> [--pr N] [--only N]" >&2; exit 64; }

[ "$ONLY" != 3 ] || {
  echo "fm-gate: gate 3 is retired; the required GitHub check it duplicated is gate 6" >&2; exit 64; }

say()  { printf '  %s gate %s: %s\n' "$1" "$2" "$3"; }
want() { [ -z "$ONLY" ] || [ "$ONLY" = "$1" ]; }

g() {   # g <n> <description> ; body reads stdin-free, returns 0/1
  local n="$1"
  want "$n" || return 0
  shift 1
  local desc="$1"; shift
  if "$@"; then say '+' "$n" "$desc"; return 0; fi
  say 'x' "$n" "$desc"; exit "$n"
}

_fm_lib="$(dirname "${BASH_SOURCE[0]}")/fm-config.sh"
[ -f "$_fm_lib" ] || { echo "fm-gate: missing $_fm_lib" >&2; exit 70; }
# shellcheck source=bin/fm-config.sh
. "$_fm_lib"

# ---- one gate run at a time on this machine ------------------------------
# The lock is the kernel's: flock on descriptor 8, taken through perl because
# macOS ships no flock(1). The kernel drops it when the holder exits, however
# it exits, so nothing here judges whether a holder is alive - no pid is
# trusted, a reused pid or another user's run cannot be misread, and no lock
# is ever removed, which is where a check-then-act race would live. The file
# stays; the pid written in it only names the holder to a waiter.
#
# The default is not under TMPDIR: that differs per user on macOS and per
# sandbox, and two callers with two temp directories would take two locks.
LOCK="${FM_GATE_LOCK:-/tmp/fm-gate.lock}"
if [ "${FM_GATE_LOCK_HELD:-}" = "$LOCK" ]; then
  echo "fm-gate: this run is inside a gate run that holds $LOCK; give it its own FM_GATE_LOCK" >&2
  exit 70
fi
# The path is in a directory every user writes, so anyone may have put a
# symlink or a hard link to some other file there first. The shell's own
# redirections follow a symlink, so none of them ever opens it: perl opens it
# once, refusing a symlink (O_NOFOLLOW, which also never creates through one)
# and anything but a regular file with that one name, puts it on descriptor
# 8, and runs this script again in the same process with it open. Every read
# and write of the lock after that goes through the descriptor. A new file is
# made writable by every user, so each can name itself in it.
if [ "${FM_GATE_LOCK_OPEN:-}" != "$$:$LOCK" ]; then
  exec perl -MFcntl -MPOSIX=dup2 -e '
    my ($path, @cmd) = @ARGV;
    my $no = sub { print STDERR "fm-gate: cannot use the gate lock $path: $_[0]; fix or remove that file",
      " (only a test fixture sets its own FM_GATE_LOCK; a real gate run keeps the machine lock)\n"; exit 70 };
    my $fh; my $mask = umask 0;
    sysopen($fh, $path, O_RDWR | O_CREAT | O_NOFOLLOW | O_NONBLOCK, 0666)
      or sysopen($fh, $path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
      or $no->("$!");
    umask $mask;
    my @st = stat $fh;
    -f _ or $no->("it is not a regular file");
    $st[3] == 1 or $no->("it has another name, a hard link");
    my $fd = fileno $fh;
    if ($fd == 8) { fcntl($fh, F_SETFD, 0) or $no->("$!") }
    else { defined dup2($fd, 8) or $no->("$!") }
    $ENV{FM_GATE_LOCK_OPEN} = "$$:$path";
    exec { $cmd[0] } @cmd or $no->("$!");
  ' "$LOCK" "$BASH" "${BASH_SOURCE[0]}" ${_fm_argv[@]+"${_fm_argv[@]}"}
fi
unset FM_GATE_LOCK_OPEN
# take_lock <wait 0|1> ; the descriptor is shared with this shell, so the
# lock outlives perl and is held until this shell and its children let go
take_lock() {
  perl -MFcntl=:flock -e 'open(my $l, "<&=", 8) or exit 2;
    exit(flock($l, $ARGV[0] ? LOCK_EX : LOCK_EX | LOCK_NB) ? 0 : 1)' "$1"
}
if ! take_lock 0; then
  holder="$(perl -e 'open(my $l, "<&=", 8) or exit 0; sysseek($l, 0, 0);
    sysread($l, my $b, 32); print $1 if defined $b && $b =~ /^(\d+)/' 2>/dev/null)"
  echo "fm-gate: waiting for the gate run holding $LOCK${holder:+ (pid $holder)}" >&2
  take_lock 1 || { echo "fm-gate: could not take the gate lock $LOCK" >&2; exit 70; }
fi
# through the descriptor, not the path; a lock opened read-only (another
# user's file) keeps whatever it said
perl -e 'open(my $l, "+<&=", 8) or exit 0; truncate($l, 0) or exit 0;
  sysseek($l, 0, 0); syswrite($l, "$ARGV[0]\n")' "$$" 2>/dev/null || :
export FM_GATE_LOCK_HELD="$LOCK"

cd "$REPO" || { echo "fm-gate: no repo at $REPO" >&2; exit 64; }

# ---- the project contract ------------------------------------------------
# Which toolchain a project uses is its own business. config.yaml's project:
# block declares how to prepare a fresh checkout (setup), what green means
# (check, with check_env), which files are tests (tests) and how to run one
# (test), and which changes need no test (docs). Gate 5 runs what is
# declared and names nothing else.
#
# The declaration read is the branch's own: it is what the branch will be
# checked with everywhere else, and gate 4 decides whether a branch may
# change config.yaml at all.
P_SETUP=''; P_CHECK=''; P_TEST=''; P_TESTS=''; P_DOCS=''; P_ENV=()
load_project() {  # load_project <config.yaml of the branch>
  local cfg="$1" kv
  P_SETUP=''; P_CHECK=''; P_TEST=''; P_TESTS=''; P_DOCS=''; P_ENV=()
  [ -s "$cfg" ] || return 0
  P_SETUP="$(fm_project setup "$cfg")" || return 1
  P_CHECK="$(fm_project check "$cfg")" || return 1
  P_TEST="$(fm_project test "$cfg")" || return 1
  P_TESTS="$(fm_project tests "$cfg")" || return 1
  P_DOCS="$(fm_project docs "$cfg")" || return 1
  while IFS= read -r -d '' kv; do P_ENV+=("$kv"); done < <(fm_project check_env "$cfg")
}
branch_config() {  # branch_config <file> ; the branch's config.yaml, or empty
  git show "$BRANCH:config.yaml" > "$1" 2>/dev/null || : > "$1"
}

# run_in <dir> <log> <with-check-env 0|1> <command>
#   FM_ROOT points at <dir>: one inherited from the caller would aim the
#   command at some other tree. check_env goes on top for check and tests.
#   The gate lock's descriptor is closed for it: something it leaves running
#   after a killed gate run must not go on holding the lock.
run_in() {
  local dir="$1" log="$2" cmd="$4"
  if [ "$3" = 1 ]; then
    ( cd "$dir" && env FM_ROOT="$dir" ${P_ENV[@]+"${P_ENV[@]}"} bash -c "$cmd" ) > "$log" 2>&1 8<&-
  else
    ( cd "$dir" && env FM_ROOT="$dir" bash -c "$cmd" ) > "$log" 2>&1 8<&-
  fi
}
failed() {  # failed <stage> <exit> <command> <log> ; says which, and what it said
  echo "      $1 failed (exit $2): $3" >&2
  tail -n 20 "$4" | sed 's/^/        /' >&2
}
no_check() { echo "      config.yaml declares no project.check, so nothing says what green means" >&2; }
drop() { git worktree remove --force "$1" >/dev/null 2>&1; rm -rf "$1"; }

# ---- 1. the branch exists and carries work -------------------------------
gate1() {
  git rev-parse --verify "$BRANCH" >/dev/null 2>&1 || return 1
  [ "$(git rev-list --count "$BASE..$BRANCH" 2>/dev/null || echo 0)" -gt 0 ]
}

# ---- 2. it rebases onto the base cleanly ---------------------------------
gate2() {
  local w rc
  w="$(mktemp -d)"
  git worktree add -q --detach "$w" "$BRANCH" 2>/dev/null || { rm -rf "$w"; return 1; }
  ( cd "$w" && git rebase "$BASE" >/dev/null 2>&1 ); rc=$?
  ( cd "$w" && git rebase --abort >/dev/null 2>&1 )
  git worktree remove --force "$w" >/dev/null 2>&1; rm -rf "$w"
  return "$rc"
}

# ---- 3. retired (T-114) --------------------------------------------------
# It ran the whole project.check; gate 6 reads the required GitHub check that
# runs the same thing on the same head.

changed() { git diff --name-only "$BASE...$BRANCH"; }
# matches <path> <globs, one per line>. A leading **/ also matches at the top
# level, as it does everywhere else.
matches() {
  local g
  while IFS= read -r g; do
    [ -n "$g" ] || continue
    # shellcheck disable=SC2254
    case "$1" in $g) return 0 ;; esac
    # shellcheck disable=SC2254
    case "$g" in '**/'*) case "$1" in ${g#\*\*/}) return 0 ;; esac ;; esac
  done <<< "$2"
  return 1
}
# The declared tests globs when there are any, these when there are none.
is_test() {
  if [ -z "$P_TESTS" ]; then
    case "$1" in tests/*|*.test.*|*.spec.*) return 0 ;; *) return 1 ;; esac
  fi
  matches "$1" "$P_TESTS"
}
# Only what the project declares as docs. Nothing is docs by default: a path
# no one declared is behaviour until someone says otherwise.
is_doc() { [ -n "$P_DOCS" ] && matches "$1" "$P_DOCS"; }
# fill <template> <file> ; every {file} becomes the shell-quoted path. No
# ${var//x/y}: with bash 5.2's patsub_replacement an & in the path would
# come back as the match.
fill() {
  local rest="$1" q out=''
  q="$(printf '%q' "$2")"
  while [[ "$rest" == *'{file}'* ]]; do
    out="$out${rest%%\{file\}*}$q"; rest="${rest#*\{file\}}"
  done
  printf '%s' "$out$rest"
}

# ---- 4. the diff stays inside the task's declared scope ------------------
gate4() {
  local scopes f ok
  # from the task's own file on the branch: a task that defines itself in
  # its own diff is otherwise unscoped, and gate 4 would pass anything
  scopes="$(fm_task "$TASK" design/tasks "$BRANCH" | jq -r '.scope[]' 2>/dev/null)"
  [ -n "$scopes" ] || scopes="$(fm_task "$TASK" | jq -r '.scope[]' 2>/dev/null)"
  [ -n "$scopes" ] || return 1          # a task with no declared scope cannot be gated
  # design/tasks.json was the shared list a task named so it could carry its
  # own entry (T-090); it now means that entry's file, and no other
  if grep -qxF design/tasks.json <<< "$scopes"; then
    scopes="$scopes
design/tasks/$TASK.json"
  fi
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    ok=1
    while IFS= read -r s; do
      [ -n "$s" ] || continue
      # shellcheck disable=SC2254
      case "$f" in $s) ok=0; break ;; esac
      case "$s" in */\*\*) case "$f" in "${s%/**}"/*) ok=0; break ;; esac ;; esac
    done <<< "$scopes"
    [ "$ok" -eq 0 ] || { echo "      out of scope: $f" >&2; return 1; }
  done <<< "$(changed)"
  return 0
}

# ---- 5. the new tests are not vacuous ------------------------------------
# Revert the implementation to the base and the new tests must go red. A test
# that still passes without the code it is meant to cover is testing nothing.
#
# The branch's declaration is read before anything is reverted: config.yaml
# is implementation like any other file and goes back to the base below.
# Setup runs on the reverted tree, since that is the tree the tests run in.
# Paths matching the declared `docs` globs need no test of their own, but are
# reverted with the rest.
#
# Only the suites the diff touches run, through the declared `test` template
# (T-114): every test file the diff changes, then every other test file that
# names one of those - the suites that source a changed helper.
# The whole check runs only when no suite can be determined - no `test`
# template, or no touched test file left in the tree - and the gate says so.
gate5() {
  local w impl code tests f rc log cfg suites base name
  impl=''; code=''; tests=''
  cfg="$(mktemp)"; branch_config "$cfg"
  load_project "$cfg" || { rm -f "$cfg"; return 1; }
  rm -f "$cfg"
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    if is_test "$f"; then tests="$tests$f"$'\n'; continue; fi
    impl="$impl$f"$'\n'
    is_doc "$f" || code="$code$f"$'\n'
  done <<< "$(changed)"
  # every non-test path is one the project declared as docs: nothing that
  # behaves changed, so there is nothing to make red. Anything else needs a test.
  [ -n "$(printf '%s' "$code" | tr -d '[:space:]')" ] || return 0
  [ -n "$(printf '%s' "$tests" | tr -d '[:space:]')" ] || {
    echo "      the diff changes implementation but adds no test" >&2; return 1; }
  [ -n "$P_TEST" ] || [ -n "$P_CHECK" ] || { no_check; return 1; }

  w="$(mktemp -d)"; log="$(mktemp)"
  git worktree add -q --detach "$w" "$BRANCH" >/dev/null 2>&1 || { rm -rf "$w" "$log"; return 1; }
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    ( cd "$w" && git checkout "$BASE" -- "$f" >/dev/null 2>&1 || rm -f "$f" )
  done <<< "$impl"

  rc=0
  [ -z "$P_SETUP" ] || run_in "$w" "$log" 0 "$P_SETUP" || rc=$?
  if [ "$rc" -ne 0 ]; then
    failed setup "$rc" "$P_SETUP" "$log"; drop "$w"; rm -f "$log"; return 1
  fi

  suites=''
  if [ -n "$P_TEST" ]; then
    while IFS= read -r f; do
      [ -n "$f" ] && [ -f "$w/$f" ] && suites="$suites$f"$'\n'
    done <<< "$tests"
    # the suites that exercise a changed test file - a helper they source, a
    # fixture they read - by naming it, by path or by name. Only a changed
    # test file: an unchanged suite that names changed implementation is the
    # base's test of the base's code in this tree, so it can go red only for
    # some reason other than the diff, and would pass a vacuous test.
    # The name counts only standing alone: helper.sh is not named by
    # fm-helper.sh, nor a.test.sh by data.test.sh.
    while IFS= read -r f; do
      [ -n "$f" ] && [ -f "$w/$f" ] && is_test "$f" || continue
      grep -qxF "$f" <<< "$suites" && continue
      while IFS= read -r base; do
        [ -n "$base" ] || continue
        name="$(printf '%s' "${base##*/}" | sed 's#[][\\.*^$+?(){}|/]#\\&#g')"
        if grep -qE "(^|[^A-Za-z0-9._-])$name([^A-Za-z0-9._-]|\$)" "$w/$f" 2>/dev/null; then
          suites="$suites$f"$'\n'; break
        fi
      done <<< "$tests"
    done <<< "$(git -C "$w" ls-files)"
  fi

  rc=1                                   # assume vacuous until one test goes red
  if [ -n "$suites" ]; then
    echo "      running the suites the diff touches: $(printf '%s' "$suites" | tr '\n' ' ')" >&2
    while IFS= read -r f; do
      [ -n "$f" ] || continue
      run_in "$w" "$log" 1 "$(fill "$P_TEST" "$f")" || { rc=0; break; }
    done <<< "$suites"
  elif [ -n "$P_CHECK" ]; then
    if [ -n "$P_TEST" ]; then
      echo "      no suite the diff touches is left in the tree, so the whole project.check runs" >&2
    else
      echo "      config.yaml declares no project.test to run one suite with, so the whole project.check runs" >&2
    fi
    run_in "$w" "$log" 1 "$P_CHECK" || rc=0
  else
    echo "      no suite the diff touches could be run, and no project.check is declared" >&2
  fi

  drop "$w"; rm -f "$log"
  [ "$rc" -eq 0 ] || echo "      the new tests still pass with the implementation reverted" >&2
  return "$rc"
}

# ---- 6. the required GitHub check is green -------------------------------
is_num() { case "$1" in ''|*[!0-9]*) return 1 ;; *) return 0 ;; esac; }

gate6() {
  is_num "$PR" || return 1
  $GH pr checks "$PR" --required >/dev/null 2>&1
}

# ---- 7. the reviewer signed, and it was the reviewer ---------------------
gate7() {
  is_num "$PR" || return 1
  local body
  body="$($GH pr view "$PR" --json comments --jq \
    '.comments[]|select(.body|test("APPROVE:'"$TASK"'"))|.author.login' 2>/dev/null)"
  [ -n "$body" ] || return 1
  [ -z "$REVIEWER" ] && return 0
  grep -qx "$REVIEWER" <<< "$body"
}

g 1 "branch exists and carries commits"          gate1
g 2 "rebases onto $BASE cleanly"                 gate2
g 4 "diff stays inside the declared scope"       gate4
g 5 "reverting the implementation turns tests red" gate5
g 6 "the required GitHub check is green"         gate6
g 7 "the reviewer posted APPROVE:$TASK"          gate7
echo "  all six gates green"
exit 0
