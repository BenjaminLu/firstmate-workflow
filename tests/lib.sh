# shellcheck shell=bash
# Minimal assertions. Sourced by every *.test.sh.
_fails=0
_t() { printf '    %-52s' "$1"; }
ok()   { printf 'ok\n'; }
bad()  { printf 'FAIL\n      %s\n' "$1"; _fails=$((_fails+1)); }

assert_eq() { _t "$3"; [ "$1" = "$2" ] && ok || bad "expected [$1] got [$2]"; }
assert_ne() { _t "$3"; [ "$1" != "$2" ] && ok || bad "expected not [$1]"; }
assert_ok() { _t "$2"; if eval "$1" >/dev/null 2>&1; then ok; else bad "command failed: $1"; fi; }
assert_fail() { _t "$2"; if eval "$1" >/dev/null 2>&1; then bad "command unexpectedly passed: $1"; else ok; fi; }
assert_contains() { _t "$3"; case "$1" in *"$2"*) ok;; *) bad "missing [$2]";; esac; }
finish() { [ "$_fails" -eq 0 ] || exit 1; }
