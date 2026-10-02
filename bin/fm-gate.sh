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

# see fm_need in bin/fm-config.sh for why: `shift 2` with one argument
# left does not shift, and the loop spins. The arguments are read before
# anything is sourced, so this file carries the two lines rather than the
# explanation.
need() { [ "$#" -ge 2 ] || { echo "fm-gate: $1 needs a value" >&2; exit 64; }; }
while [ $# -gt 0 ]; do
  case "$1" in
    --project) need "$@"; export FM_PROJECT="${2-}"; shift 2 ;;
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

GATE_BIN="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_fm_lib="$GATE_BIN/fm-config.sh"
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

fm_storage_init "$REPO" || exit 65
fm_target_validate || exit 65
BASE="${FM_BASE:-$BASE}"
cd "$FM_TARGET_ROOT" || { echo "fm-gate: no repo at $FM_TARGET_ROOT" >&2; exit 64; }

# ---- 1. the branch exists and carries work -------------------------------
gate1() {
  git rev-parse --verify "$BRANCH" >/dev/null 2>&1 || return 1
  [ "$(git rev-list --count "$BASE..$BRANCH" 2>/dev/null || echo 0)" -gt 0 ]
}

# ---- 2. it rebases onto the base cleanly ---------------------------------
gate2() {
  local w rc
  if [ "$FM_EXTERNAL" = 1 ]; then
    mkdir -p "$FM_STATE_DIR/gate-worktrees" || return 1
    w="$(mktemp -d "$FM_STATE_DIR/gate-worktrees/check.XXXXXX")" || return 1
  else
    w="$(mktemp -d)"
  fi
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
# ---- 4. the diff stays inside the task's declared scope ------------------
gate4() {
  local scopes='' f ok
  # from the task's own file on the branch: a task that defines itself in
  # its own diff is otherwise unscoped, and gate 4 would pass anything
  [ "$FM_EXTERNAL" = 1 ] || scopes="$(fm_task "$TASK" design/tasks "$BRANCH" | jq -r '.scope[]' 2>/dev/null)"
  [ -n "$scopes" ] || scopes="$(fm_task "$TASK" "$FM_TASKS_DIR" | jq -r '.scope[]' 2>/dev/null)"
  [ -n "$scopes" ] || return 1          # a task with no declared scope cannot be gated
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
# Keep gate policy (declared docs and check fallback) in the shared engine.
# The lock descriptor belongs to this launcher, never to its test children.
gate5() {
  if [ "$FM_EXTERNAL" = 1 ]; then
    mkdir -p "$FM_STATE_DIR/tmp" || return 1
    TMPDIR="$FM_STATE_DIR/tmp" bash "$GATE_BIN/fm-failfirst.sh" --gate --head="$BRANCH" "$BASE" 8<&-
  else
    bash "$GATE_BIN/fm-failfirst.sh" --gate --head="$BRANCH" "$BASE" 8<&-
  fi
}

# ---- 6. the required GitHub check is green -------------------------------
is_num() { case "$1" in ''|*[!0-9]*) return 1 ;; *) return 0 ;; esac; }

gate6() {
  is_num "$PR" || return 1
  $GH pr checks "$PR" --required >/dev/null 2>&1
}

# ---- 7. the reviewer signed, and it was the reviewer ---------------------
# The approval binds to the change, not the head (T-113). fm-review.sh ends
# every verdict it posts with
#   REVIEWED:<task> verdict=<APPROVE|REJECT> head=<sha> base=<sha> patch=<id> files=<json>
# and the latest verdict must be an APPROVE. It stands for the current head
# when it was given for that head, or when both of these hold:
#   1. the change is the same: the patch-id of merge-base..head is the one approved
#   2. no later REJECT supersedes it
# That is an update onto a newer base and nothing else, whatever the base
# changed meanwhile, files the approval reviewed included (SK-008): a conflict
# that had to be resolved changes the patch-id, and so fails 1. An APPROVE with no
# REVIEWED line is read as before, and said to bind to nothing. CI and the other
# gates still run on the head being merged; only the review carries.
#
# The patch-id is taken from plumbing, which reads no user configuration,
# with renames off: fm-review.sh takes it the same way.
patch_of() {  # patch_of <base> <head>
  git diff-tree -r -p --no-renames "$1" "$2" 2>/dev/null | git patch-id --stable | cut -d' ' -f1
}
refused() { echo "      $1; a real re-review is needed" >&2; return 1; }
gate7() {
  local head mb patch
  head="$(git rev-parse --verify -q "$BRANCH^{commit}")" || return 1
  mb="$(git merge-base "$BASE" "$BRANCH")" || return 1
  patch="$(patch_of "$mb" "$head")"
  fm_evidence gate --head "$head" --patch "$patch"
}

g 1 "branch exists and carries commits"          gate1
g 2 "rebases onto $BASE cleanly"                 gate2
g 4 "diff stays inside the declared scope"       gate4
g 5 "reverting the implementation turns tests red" gate5
g 6 "the required GitHub check is green"         gate6
g 7 "local reviewer approval:$TASK"          gate7
echo "  all six gates green"
exit 0
