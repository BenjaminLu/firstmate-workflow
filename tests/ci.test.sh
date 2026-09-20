#!/usr/bin/env bash
# bin/ci.sh is the single entry point CI and the local gate both call.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=tests/lib.sh
. "$ROOT/tests/lib.sh"

fixture() {                      # a throwaway repo root for ci.sh to operate on
  d="$(mktemp -d)"; mkdir -p "$d/bin" "$d/tests"; printf '%s' "$d"
}

t="$(fixture)"
printf '#!/usr/bin/env bash\nexit 0\n' > "$t/tests/green.test.sh"
assert_ok "FM_ROOT='$t' bash '$ROOT/bin/ci.sh'" "passes when every test passes"

printf '#!/usr/bin/env bash\nexit 1\n' > "$t/tests/red.test.sh"
assert_fail "FM_ROOT='$t' bash '$ROOT/bin/ci.sh'" "fails when any single test fails"

out="$(FM_ROOT="$t" bash "$ROOT/bin/ci.sh" 2>&1 || true)"
assert_contains "$out" "red.test.sh" "names the failing test"

rm -f "$t/tests/red.test.sh" "$t/tests/green.test.sh"
assert_ok "FM_ROOT='$t' bash '$ROOT/bin/ci.sh'" "passes on a repo with no tests yet"

assert_ok "test -x '$ROOT/bin/ci.sh'" "ci.sh is executable"
gha="$ROOT/.github/workflows/ci.yml"
assert_ok "test -f '$gha'" "a GitHub Actions workflow exists"
assert_contains "$(cat "$gha")" "bin/ci.sh" "the workflow calls bin/ci.sh, not a copy of its steps"
# the browser suite runs in CI too, or the board is only ever checked here.
# Everything the gate needs must be installed before it runs.
assert_contains "$(cat "$gha")" "playwright install" "CI installs the browser the gate uses"
assert_contains "$(cat "$gha")" "bun install" "CI installs the dependencies the gate uses"
# and the gate must not silently skip the browser when it is there
assert_fail "grep -q 'playwright test' '$gha'" "CI does not run playwright itself, bin/ci.sh does"
rm -rf "$t"
# the gate must never read standard input. With nullglob an empty file list
# turns a grep into one that reads stdin, and a nested run - which is exactly
# what this suite does - then waits for a human who is not there. The probe
# gives it a pipe that stays open, the way a real caller does.
# Two ways in, so neither fix ships untested: a tree with no tests at all
# (nullglob leaves the lint's grep with no file list) and a tree whose suite
# reads stdin itself. The budget is derived from the work - a full gate run
# with a timing margin - not from a number that felt long enough.
probe_gate() { # <fixture-dir> <label>
  local p="$1" label="$2" pid deadline
  ( sleep 60 | { FM_ROOT="$p" bash "$p/bin/ci.sh" >/dev/null 2>&1; touch "$p/done"; } ) &
  pid=$!
  deadline=$(( $(date +%s) + 90 ))
  while [ ! -f "$p/done" ] && [ "$(date +%s)" -lt "$deadline" ]; do sleep 0.3; done
  assert_ok "test -f '$p/done'" "$label"
  kill -9 "$pid" 2>/dev/null
  wait "$pid" 2>/dev/null
}
p="$(mktemp -d)"; mkdir -p "$p/bin"; cp "$ROOT/bin/ci.sh" "$p/bin/ci.sh"
probe_gate "$p" "the gate finishes on a tree with no tests at all"
mkdir -p "$p/tests"
printf '#!/usr/bin/env bash\ncat >/dev/null\nexit 0\n' > "$p/tests/reads-stdin.test.sh"
rm -f "$p/done"
probe_gate "$p" "the gate finishes when a suite reads standard input"

# The two fixes are each sufficient to survive those probes, so neither is
# proved by them. This asserts the invariant itself: whatever the gate is
# started with, what reaches a suite is /dev/null.
# a pipe answers -p, /dev/null answers -c: enough to tell the caller's
# input from the one the gate is required to hand over
printf '#!/usr/bin/env bash\nif [ -p /dev/fd/0 ]; then echo pipe; elif [ -c /dev/fd/0 ]; then echo chardev; else echo other; fi > "%s/sawstdin"\nexit 0\n' \
  "$p" > "$p/tests/reads-stdin.test.sh"
( sleep 60 | FM_ROOT="$p" bash "$p/bin/ci.sh" >/dev/null 2>&1 ) &
gp=$!
for _ in $(seq 1 200); do [ -s "$p/sawstdin" ] && break; sleep 0.3; done
assert_eq "chardev" "$(cat "$p/sawstdin" 2>/dev/null)" "a suite is handed /dev/null, not the caller's pipe"
kill -9 "$gp" 2>/dev/null; wait "$gp" 2>/dev/null

# and the hygiene lint must be linting something: with nullglob an empty file
# list turns its grep into one that reads /dev/null and passes every time
# assembled at run time: written out whole, this line is itself the
# violation, and the lint would flag this suite for carrying its own fixture
{ printf '#!/usr/bin/env bash\n'
  printf 'assert_%s "%s -q x $%s/bin/ci.sh" "planted"\n' ok grep ROOT
} > "$p/tests/planted.test.sh"
out="$(FM_ROOT="$p" bash "$p/bin/ci.sh" 2>&1)"
assert_contains "$out" "greps source without excluding comments" "the hygiene lint reads the suites it is given"
rm -rf "$p"

finish
