#!/usr/bin/env bash
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=tests/lib/review.sh
. "$ROOT/tests/lib/review.sh"
# T-123: the mktemp+cd+rm class that deleted a live checkout twice (the
# pk/pv variables in tests/adapter-contract.test.sh, before this fix) - a
# mktemp the sandbox refuses prints nothing and exits nonzero, and cd "" on
# that empty result succeeds in bash and simply stays where it already was,
# so the directory the caller happened to be running in came back for a
# later rm -rf to remove. safe_tmpdir and safe_rm_rf (tests/lib.sh) close
# it, and both exit 70 rather than return an ordinary status: exit inside a
# function ends the whole subshell it runs in, which is what fails hard
# means here, so each case below reads the subshell own exit status.
( mktemp() { return 1; }; . "$ROOT/tests/lib.sh"; safe_tmpdir ) >/dev/null 2>&1; rc=$?
assert_eq "70" "$rc" "safe_tmpdir refuses rather than silently handing back the directory it ran in, when mktemp is refused"

victim_root="$(safe_tmpdir)"
mkdir -p "$victim_root/real"
: > "$victim_root/real/canary"

( . "$ROOT/tests/lib.sh"; TMPDIR="$victim_root" safe_rm_rf "" ) >/dev/null 2>&1; rc=$?
assert_eq "70" "$rc" "safe_rm_rf refuses an empty path"

( cd "$victim_root/real" && . "$ROOT/tests/lib.sh" && TMPDIR="$victim_root" safe_rm_rf "$(pwd -P)" ) >/dev/null 2>&1; rc=$?
assert_eq "70" "$rc" "safe_rm_rf refuses to remove the current directory"
assert_ok "test -f '$victim_root/real/canary'" "and the canary inside it survives"

mkdir -p "$victim_root/elsewhere"
( . "$ROOT/tests/lib.sh"; TMPDIR="$victim_root/elsewhere" safe_rm_rf "$victim_root/real" ) >/dev/null 2>&1; rc=$?
assert_eq "70" "$rc" "safe_rm_rf refuses a path outside its own TMPDIR"
assert_ok "test -f '$victim_root/real/canary'" "and the canary survives that refusal too"

fake_repo="$victim_root/fakerepo"; mkdir -p "$fake_repo"
( . "$ROOT/tests/lib.sh"; TMPDIR="$victim_root" ROOT="$fake_repo" safe_rm_rf "$fake_repo" ) >/dev/null 2>&1; rc=$?
assert_eq "70" "$rc" "safe_rm_rf refuses the repository root even when it resolves inside TMPDIR"
assert_ok "test -d '$fake_repo'" "and it is not removed"

victim="$victim_root/gone"; mkdir -p "$victim"
( . "$ROOT/tests/lib.sh"; TMPDIR="$victim_root" safe_rm_rf "$victim" )
assert_fail "test -d '$victim_root/gone'" "a real temp directory inside its own TMPDIR is still actually removed"
rm -rf "$victim_root"


finish
