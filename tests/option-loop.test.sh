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
# The helpers this file leans on are tests/lib.sh's assert_eq (line 8),
# assert_ne (9), assert_contains (12) and finish (37). tests/lib.test.sh
# covers the harness itself.
# shellcheck source=tests/lib.sh
. "$ROOT/tests/lib.sh"

# the scripts with an option loop, and how many value-taking flags each has
PINNED="fm-cleanup 2
fm-decide 8
fm-dispatch 2
fm-emit 7
fm-gate 5
fm-merge 3
fm-protocol 4
fm-review 6
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
assert_eq "46" "$total" "every pinned flag was exercised"

# a script that grows an option loop has to be pinned here too
loops="$(grep -l 'shift 2' "$ROOT"/bin/*.sh | grep -v '/ci\.sh$' \
         | while read -r p; do basename "$p" .sh; done | sort)"
assert_eq "$(printf '%s\n' "$PINNED" | awk '{print $1}' | sort)" "$loops" \
  "the pinned list is every script with an option loop, and no more"

# an unknown flag is refused the same way rather than looping
run_capped 6 bash "$ROOT/bin/fm-emit.sh" --no-such-flag
assert_eq "64" "$code" "an unknown flag is refused too"
assert_contains "$said" "unknown argument" "and says so"
finish
