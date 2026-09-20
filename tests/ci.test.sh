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
rm -rf "$t"
# the gate must never read standard input. With nullglob an empty file list
# turns a grep into one that reads stdin, and a nested run - which is exactly
# what this suite does - then waits for a human who is not there. The probe
# gives it a pipe that stays open, the way a real caller does.
p="$(mktemp -d)"; mkdir -p "$p/bin"; cp "$ROOT/bin/ci.sh" "$p/bin/ci.sh"
( sleep 20 | { FM_ROOT="$p" bash "$p/bin/ci.sh" >/dev/null 2>&1; touch "$p/done"; } ) &
for _ in $(seq 1 30); do [ -f "$p/done" ] && break; sleep 0.2; done
assert_ok "test -f '$p/done'" "the gate finishes with an open pipe on its input"
pkill -f "$p/bin/ci.sh" 2>/dev/null
rm -rf "$p"

finish
