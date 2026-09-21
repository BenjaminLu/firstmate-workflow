#!/usr/bin/env bash
# `trap handler EXIT INT TERM HUP` is not "handle every exit path". On a
# signal the handler runs and execution CONTINUES - so a killed run
# announces it has 
# An actor boards when its last event carries an unfinished task, so any
# script that emits with a --task under an actor of its own would board a
# crewman that never leaves. Only three actors are safe: firstmate, which
# is always aboard; captain and github, which the server never boards.
# Everything else has to arm an ending.
unarmed=''
while IFS= read -r f; do
  case "$(basename "$f")" in fm-emit.sh) continue ;; esac   # the emitter itself
  code="$(sed -e 's/[[:space:]]*#.*$//' "$f")"
  printf '%s' "$code" | grep -q -- '--task' || continue
  printf '%s' "$code" | grep -q -- '--actor' || continue
  for actor in $(printf '%s' "$code" | grep -o -- '--actor [a-zA-Z0-9"$_{}-]*' | awk '{print $2}' | sort -u); do
    case "$actor" in firstmate|captain|github) continue ;; esac
    printf '%s' "$code" | grep -q 'trap finished EXIT' \
      || unarmed="$unarmed $(basename "$f"):$actor"
  done
done < <(find "$ROOT/bin" -type f -name '*.sh' | sort)
assert_eq "" "$unarmed" "every script that emits under an actor of its own says when it ends"

finished and carries on working, and kill stops
# working on it because a trapped TERM that does not exit leaves only
# SIGKILL.
#
# The behaviour is awkward to provoke inside a real run (bash defers a
# signal that arrives while it is blocked waiting for a child, which is
# where a worker spends most of its time), so this proves the pattern
# with a fixture that is deterministic, and then asserts the shape
# across bin/ - which is the thing that was actually wrong.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=tests/lib.sh
. "$ROOT/tests/lib.sh"

probe() {   # probe <trap line> -> what the script managed to write
  local traps="$1" d out
  d="$(mktemp -d)"; out="$d/log"
  { printf '#!/usr/bin/env bash\n'
    printf 'f() { echo END >> "%s"; }\n' "$out"
    printf '%s\n' "$traps"
    printf 'for i in $(seq 1 400000); do :; done\n'     # busy, not in a child
    printf 'echo CARRIED-ON >> "%s"\n' "$out"
  } > "$d/s.sh"
  bash "$d/s.sh" & local p=$!
  sleep 0.2; kill -TERM "$p" 2>/dev/null; wait "$p" 2>/dev/null
  tr '\n' ' ' < "$out"; rm -rf "$d"
}

combined="$(probe 'trap "f" EXIT INT TERM HUP')"
assert_contains "$combined" "CARRIED-ON" \
  "a signal named alongside EXIT lets the script carry on after the signal"

split="$(probe "$(printf 'trap "f" EXIT\ntrap "exit 143" TERM')")"
assert_lacks "$split" "CARRIED-ON" "a signal trap that exits stops the script"
assert_contains "$split" "END" "and the EXIT trap still runs"

# and the shape, across every script: this is what was wrong, and it is
# the half a behavioural test cannot reach in a real run
# Both orders - `trap f EXIT INT` and `trap f INT TERM EXIT`, which is
# the commoner idiom and the same bug - and every script, not only the
# top level of bin.
bad=''
while IFS= read -r f; do
  sed -e 's/[[:space:]]*#.*$//' "$f" \
    | grep -qE '^[[:space:]]*trap[[:space:]]+[^;]*[[:space:]](EXIT[[:space:]]+[A-Z]|[A-Z]+[[:space:]]+EXIT)' \
    && bad="$bad ${f#"$ROOT"/}"
done < <(find "$ROOT/bin" "$ROOT/tests" -type f -name '*.sh' | sort)
assert_eq "" "$bad" "no script names a signal alongside EXIT in one trap"
checked="$(find "$ROOT/bin" "$ROOT/tests" -type f -name '*.sh' | wc -l | tr -d ' ')"
assert_ne "0" "$checked" "there were scripts to check"

# every script that emits an ending has the split form, not just no bad form
# Every script with an EXIT trap that has to run - whether it ends a run
# or releases a lock - needs the three signals, or the thing the EXIT
# trap does is skipped. fm-emit is the one that holds a lock: an
# untrapped HUP there leaves state/.events.lock behind and every
# subsequent emit spins its whole wait and dies.
armed=0
while IFS= read -r f; do
  sed -e 's/[[:space:]]*#.*$//' "$f" | grep -qE '^[[:space:]]*trap[[:space:]].*[[:space:]]EXIT$' || continue
  armed=$((armed + 1))
  name="$(basename "$f")"
  for sig in INT TERM HUP; do
    assert_ok "grep -q \"trap 'exit [0-9]*' $sig\" '$f'" "$name exits on $sig"
  done
done < <(find "$ROOT/bin" -type f -name '*.sh' | sort)
assert_eq "3" "$armed" "the three scripts with an EXIT trap all handle signals"

# An actor boards when its last event carries an unfinished task, so any
# script that emits with a --task under an actor of its own would board a
# crewman that never leaves. Only three actors are safe: firstmate, which
# is always aboard; captain and github, which the server never boards.
# Everything else has to arm an ending.
unarmed=''
while IFS= read -r f; do
  case "$(basename "$f")" in fm-emit.sh) continue ;; esac   # the emitter itself
  code="$(sed -e 's/[[:space:]]*#.*$//' "$f")"
  printf '%s' "$code" | grep -q -- '--task' || continue
  printf '%s' "$code" | grep -q -- '--actor' || continue
  for actor in $(printf '%s' "$code" | grep -o -- '--actor [a-zA-Z0-9"$_{}-]*' | awk '{print $2}' | sort -u); do
    case "$actor" in firstmate|captain|github) continue ;; esac
    printf '%s' "$code" | grep -q 'trap finished EXIT' \
      || unarmed="$unarmed $(basename "$f"):$actor"
  done
done < <(find "$ROOT/bin" -type f -name '*.sh' | sort)
assert_eq "" "$unarmed" "every script that emits under an actor of its own says when it ends"

finish
