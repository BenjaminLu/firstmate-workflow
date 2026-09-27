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
# a shape, without handing the string to the shell. Not a pipe (under
# pipefail grep -q leaving early can kill the writer, T-103), and not a
# here-string either: that adds a newline, so empty output became one empty
# line and matched '^$' or '^[0-9]*$'. Exactly the bytes of $1.
assert_matches() { _t "$3"
  if grep -Eq -- "$2" < <(printf '%s' "$1"); then ok; else bad "[$1] does not match /$2/"; fi; }
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
# Every suite that runs fm-review.sh in run mode has it call sweep_checkouts
# against ${TMPDIR:-/tmp}. A suite that leaves the host's own TMPDIR in place
# runs that sweep against the real one - which, invoked from inside a live
# review round's own bin/ci.sh, is the very directory the round's checkout
# lives under (T-123). isolate_tmpdir gives the rest of the suite, and every
# fm-review.sh it runs from here on, a TMPDIR of its own; call it once, before
# the first such invocation. restore_tmpdir (finish calls it) puts the
# caller's own TMPDIR back and removes the one made for the suite.
_orig_tmpdir="${TMPDIR-}"; _had_tmpdir="${TMPDIR+1}"; _isolated_tmpdir=''
isolate_tmpdir() {
  _isolated_tmpdir="$(mktemp -d)"
  TMPDIR="$_isolated_tmpdir"; export TMPDIR
}
restore_tmpdir() {
  if [ -n "$_isolated_tmpdir" ]; then
    if [ -n "$_had_tmpdir" ]; then TMPDIR="$_orig_tmpdir"; export TMPDIR
    else unset TMPDIR
    fi
    rm -rf "$_isolated_tmpdir"; _isolated_tmpdir=''
  fi
}
finish() { restore_scripts; restore_tmpdir; [ "$_fails" -eq 0 ] || exit 1; }
