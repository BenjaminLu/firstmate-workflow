#!/usr/bin/env bash
# `trap handler EXIT INT TERM HUP` is not "handle every exit path". On a
# signal the handler runs and execution CONTINUES - so a killed run
# announces it has finished and carries on working, and kill stops
# working on it, because a trapped TERM that does not exit leaves only
# SIGKILL.
#
# The behaviour is awkward to provoke inside a real run: bash defers a
# signal that arrives while it is blocked waiting for a child, which is
# where a worker spends most of its time. So this proves the pattern
# with a fixture that is busy rather than blocked, where it is
# deterministic, and then asserts the shape across the scripts - which
# is the half a behavioural test cannot reach.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=tests/lib.sh
. "$ROOT/tests/lib.sh"

# --- the pattern, behaviourally ------------------------------------------
# The script signals ITSELF, so there is no race to lose: the first
# version killed it after sleeping 0.2s and assumed a busy loop was
# still running, which on a fast machine it is not - a non-deterministic
# test of a perfectly deterministic language behaviour.
probe() {   # probe <trap lines> -> what the script managed to write
  local traps="$1" d out
  d="$(mktemp -d)"; out="$d/log"
  { printf '#!/usr/bin/env bash\n'
    printf 'f() { echo END >> "%s"; }\n' "$out"
    printf '%s\n' "$traps"
    printf 'kill -TERM $$\n'
    printf 'echo CARRIED-ON >> "%s"\n' "$out"
  } > "$d/s.sh"
  bash "$d/s.sh" >/dev/null 2>&1
  tr '\n' ' ' < "$out"; rm -rf "$d"
}

combined="$(probe 'trap "f" EXIT INT TERM HUP')"
assert_contains "$combined" "CARRIED-ON" \
  "a signal named alongside EXIT lets the script carry on after the signal"

split="$(probe "$(printf 'trap "f" EXIT\ntrap "exit 143" TERM')")"
assert_lacks "$split" "CARRIED-ON" "a signal trap that exits stops the script"
assert_contains "$split" "END" "and the EXIT trap still runs"

# --- and the shape, across every script ----------------------------------
# The criterion says "no script", so the sweep is the repository and not
# the two directories the scripts happen to live in today: every file
# with a .sh suffix wherever it sits, every file bash is told to execute
# by its shebang whatever it is called, and the workflow files, whose
# `run:` blocks are shell the runner executes. Excluded, deliberately:
# .git, node_modules and state/, which are not ours; and shell quoted
# inside markdown - skills/**/SKILL.md carries commands for an agent to
# run, not a script with exit paths of its own, and a trap written there
# traps nothing.
shellish() {
  find "$ROOT" -type d \( -name .git -o -name node_modules -o -name state \) -prune \
       -o -type f -print | while IFS= read -r f; do
    case "$f" in
      *.sh) printf '%s\n' "$f"; continue ;;
      "$ROOT"/.github/workflows/*) printf '%s\n' "$f"; continue ;;
      *.md|*.json|*.css|*.html|*.tsv|*.png|*.svg) continue ;;
    esac
    # a here-string, not a pipe: the gate refuses a pipeline into grep -q
    grep -qE '^#!.*[ /](ba)?sh([ ]|$)' <<< "$(head -1 "$f" 2>/dev/null)" \
      && printf '%s\n' "$f"
  done | sort
}
scripts="$(shellish)"
assert_ne "" "$scripts" "there were scripts to check"
# the sweep reaches past bin/ and tests/, or it is the old one with a
# longer name: these two are the files outside them that it must see
assert_contains "$scripts" "/.github/workflows/" "the sweep reaches the workflow files"
assert_ok "grep -qv '/bin/\|/tests/' <<< \"$scripts\"" "and something outside bin/ and tests/"

# --- the three sweeps ----------------------------------------------------
# Each is a function, because each has to be run twice: over the
# repository, where the answer must be nothing, and over a tree built to
# be caught, where it must not be. A sweep that finds nothing and a sweep
# that cannot find anything read the same. `assert_ne "" "$scripts"`
# guards the input list; these guard the search.

# bash's own signal names, so that a handler argument ending in a word in
# capitals is not read as one
SIGNALS='EXIT|ERR|DEBUG|RETURN|HUP|INT|QUIT|ILL|TRAP|ABRT|BUS|FPE|KILL|USR1|SEGV|USR2|PIPE|ALRM|TERM|STKFLT|CHLD|CONT|STOP|TSTP|TTIN|TTOU|URG|XCPU|XFSZ|VTALRM|PROF|WINCH|POLL|PWR|SYS|INFO|IO|EMT'

# both orders: `trap f EXIT INT` and `trap f INT TERM EXIT`, which is the
# commoner idiom and the same bug.
#
# It reads the SIGNAL LIST off the END of the line, and never looks at the
# handler. The handler is one argument and may contain anything - a
# semicolon, a word in capitals inside quotes - and the first version
# tried to match across it with `[^;]*`, which cannot cross a semicolon:
# `trap 'rm -f "$tmp"; rmdir "$d"' EXIT INT` walked straight past, and a
# cleanup handler that does two things is the normal idiom.
sweep_combined() {   # files -> those naming a signal alongside EXIT
  local out
  out="$(awk -v sigs="^($SIGNALS)\$" '
    { line = $0; sub(/[[:space:]]*#.*$/, "", line); sub(/[[:space:]]+$/, "", line) }
    line ~ /^[[:space:]]*trap[[:space:]]/ {
      n = split(line, w, /[[:space:]]+/)
      seen_exit = 0; count = 0
      for (i = n; i >= 1; i--) {
        if (w[i] !~ sigs) break
        count++
        if (w[i] == "EXIT") seen_exit = 1
      }
      if (seen_exit && count > 1 && !(FILENAME in done)) { done[FILENAME] = 1; print FILENAME }
    }
  ' "$@")" || return 1
  # awk's status, not sort's: `awk ... | sort -u` reports on the sort, and
  # a path awk could not open is a complaint on stderr, a skipped file and
  # an empty answer - which reads exactly like "nothing found"
  [ -n "$out" ] || return 0
  sort -u <<< "$out"
}

# Every script whose EXIT trap has to run - whether it ends a run or
# releases a lock - needs the three signals, or what the EXIT trap does is
# skipped. fm-emit is the one holding a lock: an untrapped HUP there leaves
# state/.events.lock behind and every later emit spins its whole wait and
# dies.
sweep_unguarded() {   # files -> "<file>:<signal>" for each one missing
  local f sig code
  for f in "$@"; do
    # a file it cannot read is not a file with nothing wrong in it
    [ -r "$f" ] || return 1
    code="$(sed -e 's/[[:space:]]*#.*$//' "$f")"
    grep -qE '^[[:space:]]*trap[[:space:]].*[[:space:]]EXIT$' <<< "$code" || continue
    for sig in INT TERM HUP; do
      grep -qE "^[[:space:]]*trap[[:space:]]+'exit [0-9]+'[[:space:]]+$sig\$" <<< "$code" \
        || printf '%s:%s\n' "$(basename "$f")" "$sig"
    done
  done
  return 0
}

# An actor boards when its last event carries an unfinished task, so a
# script emitting under an actor of its own would board a crewman that
# never leaves. Three actors are safe: firstmate, always aboard; captain
# and github, which the server never boards. Everything else has to arm an
# ending.
sweep_unarmed() {   # files -> "<file>:<actor>" for each one that cannot say it ended
  local f code actor
  for f in "$@"; do
    [ -r "$f" ] || return 1
    case "$(basename "$f")" in fm-emit.sh) continue ;; esac   # the emitter itself
    code="$(sed -e 's/[[:space:]]*#.*$//' "$f")"
    grep -q -- '--task' <<< "$code" || continue
    grep -q -- '--actor' <<< "$code" || continue
    for actor in $(grep -o -- '--actor [a-zA-Z0-9"$_{}-]*' <<< "$code" | awk '{print $2}' | sort -u); do
      case "$actor" in firstmate|captain|github) continue ;; esac
      grep -q 'trap finished EXIT' <<< "$code" \
        || printf '%s:%s\n' "$(basename "$f")" "$actor"
    done
  done
  return 0
}

# --- each sweep, against something it has to catch -----------------------
# The plants are written with printf, one string per line, so that no
# line of THIS file begins with `trap` - a suite that plants the shape it
# forbids is a suite the sweep finds, and the sweep would be right.
p="$(mktemp -d)"
plant_script() {   # plant_script <name> <line>...
  local f="$p/$1"; shift
  printf '#!/usr/bin/env bash\n' > "$f"
  printf '%s\n' "$@" >> "$f"
}
plant_script multi.sh  'trap "rm -f $tmp; rmdir $d" EXIT INT TERM'
plant_script named.sh  'trap cleanup EXIT INT TERM'
plant_script last.sh   'trap "kill $pid; wait" INT TERM EXIT'
plant_script shouty.sh 'trap "echo TERM HUP INT EXIT" EXIT'
plant_script clean.sh  'trap finished EXIT' "trap 'exit 130' INT" \
                       "trap 'exit 143' TERM" "trap 'exit 129' HUP"
caught="$(sweep_combined "$p"/multi.sh "$p"/named.sh "$p"/last.sh "$p"/shouty.sh "$p"/clean.sh)"
assert_contains "$caught" "multi.sh" "a handler with two commands in it is still caught"
assert_contains "$caught" "named.sh" "so is the plain one"
assert_contains "$caught" "last.sh" "and EXIT written last"
assert_lacks "$caught" "clean.sh" "a correctly split one is left alone"
# the other way a matcher can be wrong: signal names are read off the end
# of the line, never out of the handler, so a handler that prints them is
# not an offender
assert_lacks "$caught" "shouty.sh" "and a handler that merely says the words is not one"

plant_script exposed.sh 'trap cleanup EXIT'
missing="$(sweep_unguarded "$p/exposed.sh" "$p/clean.sh")"
for sig in INT TERM HUP; do
  assert_contains "$missing" "exposed.sh:$sig" "an EXIT trap with no $sig guard is found"
done
assert_lacks "$missing" "clean.sh" "and one with all three is not"

plant_script quiet.sh  'fm-emit.sh --actor "worker-1" --task T-1 --type dispatched'
plant_script speaks.sh 'finished() { fm-emit.sh --actor "worker-1" --task T-1 --type agent_finished; }' \
                       'trap finished EXIT' \
                       'fm-emit.sh --actor "worker-1" --task T-1 --type dispatched'
silent="$(sweep_unarmed "$p/quiet.sh" "$p/speaks.sh")"
assert_contains "$silent" 'quiet.sh:"worker-1"' "an actor of its own with no ending is found"
assert_lacks "$silent" "speaks.sh" "and one that arms an ending is not"
# and the third failure a sweep can have, which no assertion above can
# see: it could not read what it was given. Every one has to say so,
# because an empty answer is what "nothing is wrong" looks like.
sweep_combined  "$p/no-such-file.sh" >/dev/null 2>&1
assert_eq "1" "$?" "a sweep that cannot read its input fails rather than answering nothing"
sweep_unguarded "$p/no-such-file.sh" >/dev/null 2>&1
assert_eq "1" "$?" "and so does the one for unguarded EXIT traps"
sweep_unarmed   "$p/no-such-file.sh" >/dev/null 2>&1
assert_eq "1" "$?" "and the one for a run that cannot say it ended"
# a path with a space in it is one file, not two: the repository pass
# hands these over as an array for exactly this reason
mkdir -p "$p/a dir"
plant_script "a dir/spaced.sh" 'trap cleanup EXIT INT'
spaced="$(sweep_combined "$p/a dir/spaced.sh")"; rc=$?
assert_eq "0" "$rc" "a path with a space in it is read"
assert_contains "$spaced" "spaced.sh" "and swept"
rm -rf "$p"

# --- and now the repository ----------------------------------------------
# One paragraph of this file is about a sweep that finds nothing reading
# the same as a sweep that cannot look, and the plants above guard the
# matcher while `assert_ne "" "$scripts"` guards the input list. This is
# the third way it can happen and the run that matters: the arguments are
# an ARRAY, not a word-split string - one space in a path under $ROOT and
# awk is handed filenames that do not exist, complains on stderr, skips
# them and answers nothing - and the status of each sweep is asserted, so
# a sweep that died is not read as a repository with nothing wrong in it.
files=()
while IFS= read -r f; do [ -n "$f" ] && files+=("$f"); done <<< "$scripts"
assert_ne "0" "${#files[@]}" "the sweep has files to read"
unreadable=''
for f in "${files[@]}"; do [ -r "$f" ] || unreadable="$unreadable $f"; done
assert_eq "" "$unreadable" "and can read every one of them"

bad="$(sweep_combined "${files[@]}")"; rc=$?
assert_eq "0" "$rc" "the sweep for a signal alongside EXIT ran to the end"
assert_eq "" "$bad" "no script names a signal alongside EXIT in one trap"

binfiles=()
while IFS= read -r f; do [ -n "$f" ] && binfiles+=("$f"); done \
  < <(find "$ROOT/bin" -type f -name '*.sh' | sort)
assert_ne "0" "${#binfiles[@]}" "there are scripts under bin/ to check"

missing="$(sweep_unguarded "${binfiles[@]}")"; rc=$?
assert_eq "0" "$rc" "the sweep for unguarded EXIT traps ran to the end"
assert_eq "" "$missing" "every EXIT trap that has to run is guarded on INT, TERM and HUP"

# the names, not the count: a fourth script that correctly acquires one
# should not turn this red, but losing one of these should
armed=''
for f in "${binfiles[@]}"; do
  grep -qE '^[[:space:]]*trap[[:space:]].*[[:space:]]EXIT$' \
    <<< "$(sed -e 's/[[:space:]]*#.*$//' "$f")" && armed="$armed $(basename "$f")"
done
for want in fm-emit.sh fm-review.sh fm-worker.sh; do
  assert_contains "$armed" "$want" "$want still has an EXIT trap to protect"
done

unarmed="$(sweep_unarmed "${binfiles[@]}")"; rc=$?
assert_eq "0" "$rc" "the sweep for a run that cannot say it ended ran to the end"
assert_eq "" "$unarmed" "every script that emits under an actor of its own says when it ends"
finish
