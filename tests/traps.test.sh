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
probe() {   # probe <trap lines> -> what the script managed to write
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

# --- and the shape, across every script ----------------------------------
scripts="$(find "$ROOT/bin" "$ROOT/tests" -type f -name '*.sh' | sort)"
assert_ne "" "$scripts" "there were scripts to check"

# both orders: `trap f EXIT INT` and `trap f INT TERM EXIT`, which is the
# commoner idiom and the same bug
bad=''
while IFS= read -r f; do
  sed -e 's/[[:space:]]*#.*$//' "$f" \
    | grep -qE '^[[:space:]]*trap[[:space:]]+[^;]*[[:space:]](EXIT[[:space:]]+[A-Z]|[A-Z]+[[:space:]]+EXIT)' \
    && bad="$bad ${f#"$ROOT"/}"
done <<< "$scripts"
assert_eq "" "$bad" "no script names a signal alongside EXIT in one trap"

# Every script whose EXIT trap has to run - whether it ends a run or
# releases a lock - needs the three signals, or what the EXIT trap does
# is skipped. fm-emit is the one holding a lock: an untrapped HUP there
# leaves state/.events.lock behind and every later emit spins its whole
# wait and dies.
armed=''
while IFS= read -r f; do
  sed -e 's/[[:space:]]*#.*$//' "$f" | grep -qE '^[[:space:]]*trap[[:space:]].*[[:space:]]EXIT$' || continue
  armed="$armed $(basename "$f")"
  for sig in INT TERM HUP; do
    assert_ok "grep -q \"trap 'exit [0-9]*' $sig\" '$f'" "$(basename "$f") exits on $sig"
  done
done < <(find "$ROOT/bin" -type f -name '*.sh' | sort)
# the names, not the count: a fourth script that correctly acquires one
# should not turn this red, but losing one of these should
for want in fm-emit.sh fm-review.sh fm-worker.sh; do
  assert_contains "$armed" "$want" "$want still has an EXIT trap to protect"
done

# An actor boards when its last event carries an unfinished task, so a
# script emitting under an actor of its own would board a crewman that
# never leaves. Three actors are safe: firstmate, always aboard; captain
# and github, which the server never boards. Everything else has to arm
# an ending.
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
