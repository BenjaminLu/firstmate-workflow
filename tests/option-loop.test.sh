#!/usr/bin/env bash
# `shift 2` with one argument left does not shift. It returns 1 and leaves
# $@ alone, so `while [ $# -gt 0 ]` spins on the same flag for ever - a
# busy loop, not an error, on `bin/fm-emit.sh --type`.
#
# Every assertion here runs under an alarm. A test for a hang that simply
# calls the script hangs the gate instead of failing it, which is the
# difference between a suite that catches this and a suite that becomes it.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=tests/lib.sh
. "$ROOT/tests/lib.sh"

# perl's alarm rather than timeout(1), which macOS does not ship
run_capped() {   # run_capped <seconds> <cmd...> -> exit code, or 124 on a hang
  perl -e 'alarm shift; exec @ARGV; exit 127' "$@" >/dev/null 2>&1
  local rc=$?
  [ "$rc" = 142 ] && rc=124        # SIGALRM: it never came back
  printf '%s' "$rc"
}

# the alarm itself has to work, or every assertion below passes vacuously
assert_eq "124" "$(run_capped 2 bash -c 'while :; do :; done')" \
  "the alarm catches something that never returns"
assert_eq "0" "$(run_capped 5 bash -c 'exit 0')" "and lets something that returns through"

# every flag of every script, with nothing after it
checked=0
for f in "$ROOT"/bin/*.sh; do
  grep -q 'shift 2' "$f" || continue
  name="$(basename "$f")"
  while IFS= read -r flag; do
    [ -n "$flag" ] || continue
    checked=$((checked + 1))
    assert_eq "64" "$(run_capped 6 bash "$f" "$flag")" "$name $flag with no value is refused"
    # only the flags that take a value: a bare one like --dry-run shifts
    # once and is not the shape under test
  done < <(sed -n '/^while \[ \$# -gt 0 \]/,/^done/p' "$f" \
           | grep 'shift 2' | grep -oE '^[[:space:]]+--[a-z-]+\)' | tr -d ' )' | sort -u)
done
assert_ne "0" "$checked" "there were flags to check"

# and an unknown flag is refused the same way, rather than looping
assert_eq "64" "$(run_capped 6 bash "$ROOT/bin/fm-emit.sh" --no-such-flag)" \
  "an unknown flag is refused too"
finish
