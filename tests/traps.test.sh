#!/usr/bin/env bash
# `trap handler EXIT INT TERM HUP` is not "handle every exit path". On a
# signal the handler runs and execution CONTINUES - so a killed run
# announces it has finished and carries on working, and `kill` stops
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
bad=''
for f in "$ROOT"/bin/*.sh; do
  grep -nE '^[[:space:]]*trap[^#]*EXIT[[:space:]]+[A-Z]' "$f" >/dev/null 2>&1 \
    && bad="$bad $(basename "$f")"
done
assert_eq "" "$bad" "no script names a signal alongside EXIT in one trap"

# every script that emits an ending has the split form, not just no bad form
armed=0
for f in "$ROOT"/bin/*.sh; do
  grep -q 'trap finished EXIT' "$f" || continue
  armed=$((armed + 1))
  name="$(basename "$f")"
  for sig in INT TERM HUP; do
    assert_ok "grep -q \"trap 'exit [0-9]*' $sig\" '$f'" "$name exits on $sig"
  done
done
assert_ne "0" "$armed" "at least one script arms an ending"
finish
