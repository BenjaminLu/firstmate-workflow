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
# The counterpart, and the reason it exists: writing this as
# assert_fail "printf '%s' \"$out\" | grep -q x" interpolates captured output
# into a string that eval then executes. A gate transcript echoes the source
# lines it complains about, so a fixture containing $(date) gets RUN by the
# assertion meant to read it - and whether the result parses varies run to
# run, which made a real failure report ok about half the time.
assert_lacks() { _t "$3"; case "$1" in *"$2"*) bad "found [$2]";; *) ok;; esac; }
# a shape, without handing the string to the shell
assert_matches() { _t "$3"
  if printf '%s' "$1" | grep -Eq -- "$2"; then ok; else bad "[$1] does not match /$2/"; fi; }
# Swapping a script out for a stub is the commonest fixture move and the
# commonest fixture bug: the restore gets parked at the end of the file,
# where the next edit duplicates it or loses it. Pair them here instead, and
# let finish put everything back whether the suite remembered or not.
_swapped=''
stub_script() {   # stub_script <path> ; the stub body arrives on stdin
  local p="$1"
  # only the FIRST swap records the original, so stubbing the same path
  # twice still restores what was there before the first one
  if [ ! -e "$p.orig" ] && [ ! -e "$p.absent" ]; then
    if [ -e "$p" ]; then cp "$p" "$p.orig"; else : > "$p.absent"; fi
  fi
  cat > "$p"; chmod +x "$p"
  case " $_swapped " in *" $p "*) ;; *) _swapped="$_swapped $p" ;; esac
}
restore_scripts() {
  local p
  for p in $_swapped; do
    if [ -e "$p.absent" ]; then
      # there was nothing here before: leaving the stub behind would let it
      # be found by whatever runs next
      rm -f "$p" "$p.absent"
    else
      cp "$p.orig" "$p" 2>/dev/null && chmod +x "$p"
      rm -f "$p.orig"
    fi
  done
  _swapped=''
}
finish() { restore_scripts; [ "$_fails" -eq 0 ] || exit 1; }
