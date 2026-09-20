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
# Swapping a script out for a stub is the commonest fixture move and the
# commonest fixture bug: the restore gets parked at the end of the file,
# where the next edit duplicates it or loses it. Pair them here instead, and
# let finish put everything back whether the suite remembered or not.
_swapped=''
stub_script() {   # stub_script <path> ; the stub body arrives on stdin
  local p="$1"
  [ -f "$p.orig" ] || cp "$p" "$p.orig" 2>/dev/null || : > "$p.orig"
  cat > "$p"; chmod +x "$p"
  case " $_swapped " in *" $p "*) ;; *) _swapped="$_swapped $p" ;; esac
}
restore_scripts() {
  local p
  for p in $_swapped; do
    [ -s "$p.orig" ] && cp "$p.orig" "$p" && chmod +x "$p"
    rm -f "$p.orig"
  done
  _swapped=''
}
finish() { restore_scripts; [ "$_fails" -eq 0 ] || exit 1; }
