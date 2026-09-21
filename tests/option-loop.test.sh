#!/usr/bin/env bash
# `shift 2` with one argument left does not shift. It returns 1 and leaves
# $@ alone, so `while [ $# -gt 0 ]` spins on the same flag for ever - a
# busy loop, not an error, on `bin/fm-emit.sh --type`.
#
# Two things this file has to get right about itself:
#
#   - Every assertion runs under an alarm. A test for a hang that simply
#     calls the script hangs the gate instead of failing it, which is the
#     difference between a suite that catches this and a suite that
#     becomes it. The alarm is asserted first, or the rest pass vacuously.
#
#   - The corpus is pinned, not scraped. Discovering the scripts and their
#     flags by grepping the files under test means a script that stops
#     matching the grep contributes nothing and the suite stays green -
#     ten of eleven could drop out silently. The names and counts are
#     written down here, and the discovery is checked against them.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# The helpers this file leans on are defined in tests/lib.sh. The first
# version of this comment listed them with line numbers and listed the
# wrong ones - it named assert_ne, which this file never calls, and not
# assert_ok, which it does. An inventory written by hand is an inventory
# nobody checked, so bin/ci.sh checks every assert_* call in tests/
# against what lib.sh defines instead.
# shellcheck source=tests/lib.sh
. "$ROOT/tests/lib.sh"

# the scripts with an option loop, and how many value-taking flags each has
PINNED="fm-cleanup 2
fm-decide 8
fm-diagram 4
fm-dispatch 2
fm-emit 7
fm-gate 5
fm-merge 3
fm-protocol 4
fm-review 7
fm-run 2
fm-sync-prs 2
fm-worker 5"

# perl's alarm rather than timeout(1), which macOS does not ship. Both the
# code and what was said are captured: half of criterion 2 is "says which
# flag", and a helper that returns only a status cannot assert it.
#
# It sets two variables rather than printing the code, because `$(...)`
# runs the function in a subshell and anything it assigns dies there - the
# first version of this file asserted against a $said that was always
# empty, which is the same "assertion that cannot fail" the reviewer has
# been finding all night.
code=''; said=''
run_capped() {   # run_capped <seconds> <cmd...> -> sets $code and $said
  local err
  err="$(mktemp)"
  perl -e 'alarm shift; exec @ARGV; exit 127' "$@" >/dev/null 2>"$err"
  code=$?
  [ "$code" = 142 ] && code=124    # SIGALRM: it never came back
  said="$(cat "$err")"; rm -f "$err"
}

run_capped 1 bash -c 'while :; do :; done'
assert_eq "124" "$code" "the alarm catches something that never returns"
run_capped 5 bash -c 'exit 0'
assert_eq "0" "$code" "and lets something that returns through"
run_capped 5 bash -c 'echo boom >&2'
assert_contains "$said" "boom" "and what the command said is captured, not swallowed"
assert_eq "" "$(printf '%s' "$said" | tr -d 'boom\n')" "and nothing else is"

# --- every flag of every pinned script ----------------------------------
total=0
while read -r name want; do
  [ -n "$name" ] || continue
  f="$ROOT/bin/$name.sh"
  assert_ok "test -f '$f'" "$name.sh is still there"
  # discovered from the file, then checked against the pinned count, so a
  # loop written differently tomorrow fails loudly instead of quietly
  flags="$(sed -n '/while .*\$# -gt 0/,/^done/p' "$f" \
           | grep 'shift 2' | grep -oE '\-\-[a-z-]+\)' | tr -d ')' | sort -u)"
  got="$(printf '%s\n' "$flags" | sed '/^$/d' | wc -l | tr -d ' ')"
  assert_eq "$want" "$got" "$name has its $want value-taking flags"
  while IFS= read -r flag; do
    [ -n "$flag" ] || continue
    total=$((total + 1))
    run_capped 6 bash "$f" "$flag"
    assert_eq "64" "$code" "$name $flag with no value is refused"
    # and says which one: a message that lost $1, or the script's name, or
    # went to stdout, would pass a status-only assertion
    assert_contains "$said" "$flag" "$name $flag is named in the refusal"
    assert_contains "$said" "$name" "and so is the script"
  done <<< "$flags"
done <<< "$PINNED"
assert_eq "51" "$total" "every pinned flag was exercised"

# A script that grows an option loop has to be pinned here too. The
# corpus is the same one bin/ci.sh uses - a `shift 2` that is code rather
# than prose, in a file that has not declared itself a lint source - read
# by marker rather than by filename, or the two definitions drift the
# moment a second file carries it.
# the same rule bin/ci.sh uses, and it descends: bin/*.sh missed anything
# in a subdirectory, and the two definitions would drift the moment one
# of them was widened
loops=''
while IFS= read -r p; do
  grep -q '^# fm:lint-source' "$p" && continue
  sed -e 's/[[:space:]]*#.*$//' "$p" | grep -q 'shift 2' || continue
  loops="$loops$(basename "$p" .sh)
"
done < <(find "$ROOT/bin" -type f -name '*.sh' | sort)
assert_eq "$(printf '%s\n' "$PINNED" | awk '{print $1}' | sort)" "$(printf '%s' "$loops" | sort)" \
  "the pinned list is every script that consumes a value with shift 2, and no more"

# and nothing consumes a value any other way, which is the blind spot the
# lint and this check would otherwise share. Bare flags shift once; a
# `shift $n` or a getopts loop would be invisible to both.
# one corpus for these too, and every script under bin, not only fm-*
allsh="$(find "$ROOT/bin" -type f -name '*.sh' | sort)"
assert_ne "" "$allsh" "there are scripts to sweep"
assert_eq "" "$(printf '%s\n' "$allsh" | xargs grep -n 'shift' \
  | grep -vE 'shift 2|shift ;;|shift$|shift 1|: *#' || true)" \
  "no script consumes a value with a shift this check cannot see"
assert_eq "" "$(printf '%s\n' "$allsh" | xargs grep -l 'getopts\|OPTARG' || true)" \
  "and none of them uses getopts, which would be invisible too"

# an unknown flag is refused the same way rather than looping
run_capped 6 bash "$ROOT/bin/fm-emit.sh" --no-such-flag
assert_eq "64" "$code" "an unknown flag is refused too"
assert_contains "$said" "unknown argument" "and says so"
# Six scripts get their guard from a sourced function, and a
# command-not-found under `set -uo pipefail` carries on - the exact hazard
# the assertions stage exists to catch. So the load has to be hard: if the
# library will not load, the script must not reach its option loop.
sourced=0
for f in "$ROOT"/bin/fm-*.sh; do
  # comments off: the five that keep a local copy mention fm_need in a
  # comment pointing at the library, and a grep for the name picks them up
  sed -e 's/[[:space:]]*#.*$//' "$f" | grep -q 'fm_need ' || continue
  sourced=$((sourced + 1))
  name="$(basename "$f")"
  tmp="$(mktemp -d)"; mkdir -p "$tmp/bin"
  cp "$f" "$tmp/bin/"                       # and NOT fm-config.sh
  run_capped 6 bash "$tmp/bin/$name" --task
  assert_eq "70" "$code" "$name refuses to start without the library it needs"
  assert_contains "$said" "fm-config.sh" "and says which library"
  rm -rf "$tmp"
done
assert_eq "6" "$sourced" "six scripts take their guard from the library"

finish
