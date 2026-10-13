#!/usr/bin/env bash
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=tests/lib/project-storage.sh
. "$ROOT/tests/lib/project-storage.sh"
# shellcheck source=tests/lib/ci.sh
. "$ROOT/tests/lib/ci.sh"
# The second half of the lint plants (T-306 split tests/ci-lints.test.sh so
# each half fits a bash shard): the same fixture, with the browser spec the
# first half leaves in place.
q="$(safe_tmpdir)"; mkdir -p "$q/bin" "$q/tests/e2e"
# shellcheck source=tests/lib/config-modules.sh
. "$ROOT/tests/lib/config-modules.sh"
cp "$ROOT/bin/ci.sh" "$ROOT/bin/fm-config.sh" "$q/bin/"; config_modules_fixture "$q/bin/"
printf 'import { test } from "@playwright/test";\ntest("b", async ({ page }) => { await page.goto("about:blank"); });\n' \
  > "$q/tests/e2e/browser.spec.ts"

# The shared plant cache, and the hand-rolled suite planted beside the
# other early plants in tests/ci-lints.test.sh; this file asserts and pulls it.
# shellcheck source=tests/lib/ci-plant.sh
. "$ROOT/tests/lib/ci-plant.sh"
# a hand-rolled save-and-restore in a suite
# assembled, or this suite carries the very string it plants and the lint
# flags the file that tests it - the same trap as the planted source-grep
printf '#!/usr/bin/env bash\nr=/tmp\ncp "$r/bin/x.sh" "$r/x.%s"\n' 'keep"' > "$q/tests/hand-rolled.test.sh"

# How the reader normalises a line, one step per line, so deleting a step
# flips the line that names it. Red: each kind of quote and the backslash
# are taken out (`'-q'`, `"-q"` and `\grep` are -q and grep to the shell), a
# value attached with = is not stepped over, a wrapper's long option is
# done once its value is taken (timeout --s is --signal; read as a cluster
# as well, its s takes KILL and the duration eats grep), a digit is a grep
# option, and a backslash-newline joins with nothing between, as bash
# joins it. Green: grep's words end at each of ; & ) and a backtick, `--`
# ends a wrapper's options (-x is the command), so does its first operand,
# a word that does not start with - is an operand however it is spelt, and
# a prefix of more than one long option is refused even when all of them
# take a value. tail.sh ends in the middle of a continued line.
{ printf '#!/usr/bin/env bash\nset -uo pipefail\n'
  printf "printf x %s grep '-q' x\n" '|'                  # 3
  printf 'printf x %s grep "-q" x\n' '|'                  # 4
  printf 'printf x %s \\grep -q x\n' '|'                  # 5
  printf 'printf x %s env --unset=NAME grep -q x\n' '|'   # 6
  printf 'printf x %s timeout --s KILL 5 grep -q x\n' '|' # 7
  printf 'printf x %s grep -2q x\n' '|'                   # 8
  printf 'printf x %s grep -\\\nq x\n' '|'                # 9-10
  printf 'printf x %s grep x; wc -c f\n' '|'              # 11
  printf 'printf x %s grep x & wc -c f\n' '|'             # 12
  printf 'echo "$(printf x %s grep x) -c"\n' '|'          # 13
  printf 'echo `printf x %s grep x` -c\n' '|'             # 14
  printf 'printf x %s env -- -x grep -q x\n' '|'          # 15
  printf 'printf x %s env NAME=v -i grep -q x\n' '|'      # 16
  printf 'printf x %s grep squid\n' '|'                   # 17
  printf 'printf x %s grep --exc -- -q x\n' '|'           # 18
} > "$q/tests/e2e/reading.sh"
printf '#!/usr/bin/env bash\nset -uo pipefail\nprintf x %s grep -q x \\\n' '|' \
  > "$q/tests/e2e/tail.sh"
plant "a single-quoted -q is -q" "reading.sh:3:"
plant "a double-quoted -q is -q" "reading.sh:4:"
plant "a backslashed grep is grep" "reading.sh:5:"
plant "a wrapper value attached with = is not stepped over" "reading.sh:6:"
plant "a wrapper's long option is done once its value is taken" "reading.sh:7:"
plant "a digit is a grep option: -2q is quiet" "reading.sh:8:"
plant "a backslash-newline joins with nothing between" "reading.sh:9:"
plant "a file that ends in a continued line is still read" "tail.sh:3:"
assert_lacks "$planted" "reading.sh:11:" "grep's words end at ;"
assert_lacks "$planted" "reading.sh:12:" "and at &"
assert_lacks "$planted" "reading.sh:13:" "and at )"
assert_lacks "$planted" "reading.sh:14:" "and at a backtick"
assert_lacks "$planted" "reading.sh:15:" "-- ends a wrapper's options, so -x is the command"
assert_lacks "$planted" "reading.sh:16:" "and so does its first operand"
assert_lacks "$planted" "reading.sh:17:" "an operand with a q in it is not -q"
assert_lacks "$planted" "reading.sh:18:" "--exc names three options, so grep refuses it"
rm -f "$q/tests/e2e/reading.sh" "$q/tests/e2e/tail.sh"

# Two scripts, and one of them with two offending lines: a stage that
# stopped at the first hit passes a single-instance plant, as
# tests/ci-lints.test.sh says of its stdin plants.
printf '#!/usr/bin/env bash\nset -uo pipefail\nexec < /dev/null\nwhile [ $# -gt 0 ]; do\n  case "$1" in\n    --x) v="${2-}"; shift 2 ;;\n    --y) w="${2-}"; shift 2 ;;\n    *) exit 64 ;;\n  esac\ndone\necho "${v:-}${w:-}"\n' \
  > "$q/bin/fm-spinner.sh"
printf '#!/usr/bin/env bash\nset -uo pipefail\nexec < /dev/null\nwhile [ $# -gt 0 ]; do\n  case "$1" in\n    --z) u="${2-}"; shift 2 ;;\n    *) exit 64 ;;\n  esac\ndone\necho "${u:-}"\n' \
  > "$q/bin/fm-twirler.sh"
plant "an unguarded shift 2 turns the hygiene stage red" "has not checked it has two"
plant "and the stage names the first script" "fm-spinner.sh"
plant "and the second as well" "fm-twirler.sh"
plant "and both lines of the one with two" "--y"
rm -f "$q/bin/fm-spinner.sh" "$q/bin/fm-twirler.sh"

# a comment must not talk the stage out of firing: the guard is judged by
# what the code does, not by the word appearing on the line
# On a line of its own inside the branch, and shaped like a command,
# because only the STRIPPING can then be what catches it: a trailing
# `;; # need to check this` is refused by the command-position rule
# instead - `#` is not something a command can follow - and the plant
# would be coasting on a mechanism it does not name.
{ printf '#!/usr/bin/env bash\nset -uo pipefail\nexec < /dev/null\n'
  printf 'while [ $# -gt 0 ]; do\n  case "$1" in\n'
  printf '    --x)\n      # ; need "$@" would go here\n'
  printf '      v="${2-}"; shift 2 ;;\n'
  printf '    *) exit 64 ;;\n  esac\ndone\necho "${v:-}"\n'
} > "$q/bin/fm-sneak.sh"
plant "a comment mentioning the guard does not count as one" "has not checked it has two"
rm -f "$q/bin/fm-sneak.sh"

# nor must a check written AFTER the shift, which is not a check: by then
# the argument it was supposed to find is gone.
#
# One script per shape from here on. Two plants in one file and the
# coarse "turns it red" assertion is carried by whichever of them fires,
# so the other one tests nothing of its own.
{ printf '#!/usr/bin/env bash\nset -uo pipefail\nexec < /dev/null\n'
  printf 'need() { [ "$#" -ge 2 ] || exit 64; }\n'
  printf 'while [ $# -gt 0 ]; do\n  case "$1" in\n'
  printf '    --x) v="${2-}"; shift 2; need "$@" ;;\n'
  printf '    *) exit 64 ;;\n  esac\ndone\necho "${v:-}"\n'
} > "$q/bin/fm-afterwards.sh"
plant "a guard written after the shift does not count as one" "has not checked it has two"
plant "and the stage names that line" "--x"
rm -f "$q/bin/fm-afterwards.sh"

# The word in a string, IN FRONT of the shift, so the ordering rule
# cannot be what catches it. A column comparison called this guarded;
# the guard has to be a command.
{ printf '#!/usr/bin/env bash\nset -uo pipefail\nexec < /dev/null\n'
  printf 'while [ $# -gt 0 ]; do\n  case "$1" in\n'
  printf '    --y) echo "you need a value"; w="${2-}"; shift 2 ;;\n'
  printf '    *) exit 64 ;;\n  esac\ndone\necho "${w:-}"\n'
} > "$q/bin/fm-saysit.sh"
plant "the word in a string in front of the shift is not a guard" "has not checked it has two"
plant "and the stage names that one" "--y"
rm -f "$q/bin/fm-saysit.sh"

# and a helper defined ABOVE the loop whose message says the word - not
# exotic, fm-emit grows a usage() in this very diff - with a loop that
# is not a case statement at all
{ printf '#!/usr/bin/env bash\nset -uo pipefail\nexec < /dev/null\n'
  printf 'usage() { echo "you need a value" >&2; exit 64; }\n'
  printf 'while [ $# -gt 0 ]; do\n'
  printf '  if [ "$1" = --x ]; then v="${2-}"; shift 2; fi\n'
  printf 'done\necho "${v:-}"\n'
} > "$q/bin/fm-helper.sh"
plant "a helper above the loop whose message says the word is not a guard" \
  "has not checked it has two"
plant "and the stage names it" "fm-helper.sh"
rm -f "$q/bin/fm-helper.sh"

# a REAL guard, in command position, in a function above the loop: it
# guards something, but not this branch. A case pattern ends the
# previous branch as surely as `;;` does.
{ printf '#!/usr/bin/env bash\nset -uo pipefail\nexec < /dev/null\n'
  printf 'need() { [ "$#" -ge 2 ] || exit 64; }\n'
  printf 'check() { need "$@"; }\n'
  printf 'while [ $# -gt 0 ]; do\n  case "$1" in\n'
  printf '    --x) v="${2-}"; shift 2 ;;\n'
  printf '    *) exit 64 ;;\n  esac\ndone\necho "${v:-}"\n'
} > "$q/bin/fm-elsewhere.sh"
plant "a guard called somewhere else does not cover a branch that has none" \
  "has not checked it has two"
plant "and the stage names that one too" "fm-elsewhere.sh"
rm -f "$q/bin/fm-elsewhere.sh"

# And the ordinary multi-line branch, which IS guarded: the check reads
# the case branch, not the physical line, so a guard on a line of its
# own counts. Reading one line called this naked and would have made the
# gate refuse the commonest way of writing it - the rule §5.3.1 states
# is "checks first", not "checks first, on the same line".
{ printf '#!/usr/bin/env bash\nset -uo pipefail\nexec < /dev/null\n'
  printf 'need() { [ "$#" -ge 2 ] || exit 64; }\n'
  printf 'while [ $# -gt 0 ]; do\n  case "$1" in\n'
  printf '    --x)\n      need "$@"\n      v="${2-}"; shift 2 ;;\n'
  printf '    *) exit 64 ;;\n  esac\ndone\necho "${v:-}"\n'
} > "$q/bin/fm-spread.sh"
plant "a guard on its own line, above the shift, is a guard" "no option loop can spin"
rm -f "$q/bin/fm-spread.sh"

# and the guard does not leak past the end of its branch: one branch
# checks, the next does not, and the next one is an offender
{ printf '#!/usr/bin/env bash\nset -uo pipefail\nexec < /dev/null\n'
  printf 'need() { [ "$#" -ge 2 ] || exit 64; }\n'
  printf 'while [ $# -gt 0 ]; do\n  case "$1" in\n'
  printf '    --x)\n      need "$@"\n      v="${2-}"; shift 2 ;;\n'
  printf '    --y)\n      w="${2-}"; shift 2 ;;\n'
  printf '    *) exit 64 ;;\n  esac\ndone\necho "${v:-}${w:-}"\n'
} > "$q/bin/fm-leaky2.sh"
plant "a guard in the branch above does not cover the one below it" "has not checked it has two"
# the line it prints is the one with the shift on it, and it is the
# line the reader has to open: the branch head is two lines up and the
# line number is in the output
plant "and the stage names the line" "w=\"\${2-}\"; shift 2"
rm -f "$q/bin/fm-leaky2.sh"

# and the corpus has to SEE a script whose option loop shares a line with
# a `#` that is not a comment. `sed 's/#.*$//'` cuts `${1#--}` in half,
# the `shift 2` disappears with it, and the script is excused entirely.
{ printf '#!/usr/bin/env bash\nset -uo pipefail\nexec < /dev/null\n'
  printf 'while [ $# -gt 0 ]; do\n  case "$1" in\n'
  printf '    --*) n="${1#--}"; v="${2-}"; shift 2 ;;\n'
  printf '    *) exit 64 ;;\n  esac\ndone\necho "${n:-}${v:-}"\n'
} > "$q/bin/fm-hashed.sh"
plant "a hash inside a parameter expansion does not hide an option loop" "fm-hashed.sh"
rm -f "$q/bin/fm-hashed.sh"

# and it descends: bin/*.sh missed anything in a subdirectory
mkdir -p "$q/bin/inner"
printf '#!/usr/bin/env bash\nset -uo pipefail\nexec < /dev/null\nwhile [ $# -gt 0 ]; do\n  case "$1" in\n    --x) v="${2-}"; shift 2 ;;\n    *) exit 64 ;;\n  esac\ndone\necho "${v:-}"\n' \
  > "$q/bin/inner/fm-buried.sh"
plant "a script in a subdirectory of bin is linted too" "fm-buried.sh"
rm -rf "$q/bin/inner"
# and the stage says how many scripts it read, so linting nothing does not
# look like linting a clean repository
out="$(FM_ROOT="$q" bash "$q/bin/ci.sh" 2>&1)"
assert_matches "$out" 'spin on a flag with no value \([0-9]+ scripts\)' \
  "the option-loop stage says how many scripts it read"
bare2="$(safe_tmpdir)"; mkdir -p "$bare2/bin"; cp "$q/bin/ci.sh" "$q/bin/fm-config.sh" "$bare2/bin/"; config_modules_fixture "$bare2/bin/"
assert_contains "$(FM_ROOT="$bare2" bash "$bare2/bin/ci.sh" 2>&1)" "value (0 scripts)" \
  "and says zero on a tree with none"
rm -rf "$bare2"

plant "a hand-rolled swap turns the hygiene stage red" "saves a script by hand"
plant "and the stage names the suite" "hand-rolled.test.sh"
rm -f "$q/tests/hand-rolled.test.sh"

# T-123: a scratch variable resolved by cd-ing into its own (possibly
# empty, on a refused mktemp -d) value is exactly the shape that lost a
# worker's worktree and a run-mode reviewer's checkout to a silent mktemp
# failure. The lint has to flag the shape itself, not a keyword, so the
# planted line does not mention mktemp at all - the danger is the
# self-resolving cd, whatever put the value there first.
# Threaded through %s, not written whole here: this literal text is
# exactly the shape the check two paragraphs up bans, so writing it
# out in one piece would flunk this very file. Round 7 widens that check
# to a bare mktemp -d/-t on its own, with no cd at all, so mt/fd below are
# threaded the same way, for the same reason.
resolve_self='cd "$x"'
mt=mktemp; fd=-d
printf '#!/usr/bin/env bash\nx="$(%s %s)"; x="$(%s && pwd -P)"\n' "$mt" "$fd" "$resolve_self" \
  > "$q/tests/self-launder.test.sh"
plant "a scratch path that cds into its own value turns the hygiene stage red" \
  "cd-ing into its own value"
plant "and the stage names the line" 'x="$(cd "$x"'
rm -f "$q/tests/self-launder.test.sh"

# The false-positive half: cd-ing into a DIFFERENT variable to resolve one
# (an engine root read from another fixture path, say) is the ordinary,
# safe idiom used throughout the suites themselves, and safe_tmpdir's own
# body does exactly this, once, on a mktemp result it has already checked.
# Neither may trip the lint, or every suite in the repository would.
printf '#!/usr/bin/env bash\nother="$(%s %s)"; engine="$(cd "$other" && pwd -P)"\n' "$mt" "$fd" \
  > "$q/tests/resolve-other.test.sh"
out="$(FM_ROOT="$q" bash "$q/bin/ci.sh" 2>&1)"
assert_lacks "$out" "cd-ing into its own value" \
  "resolving one variable by cd-ing into a different one is not the hazard"
rm -f "$q/tests/resolve-other.test.sh"

# T-123 round 7: the widened half of the same lint - a bare mktemp -d or
# mktemp -t is now its own violation, with no cd anywhere in sight at all.
# Threaded through mt/fd/ft the same way, so this suite's own examples do
# not flunk themselves.
ft=-t
printf '#!/usr/bin/env bash\nv="$(%s %s)"\necho "$v"\n' "$mt" "$fd" \
  > "$q/tests/bare-mktemp.test.sh"
out="$(FM_ROOT="$q" bash "$q/bin/ci.sh" 2>&1)"
assert_contains "$out" "a bare, template-less mktemp" \
  "a suite calling mktemp -d with no explicit template turns the hygiene stage red"
assert_contains "$out" "bare-mktemp.test.sh" "and the stage names the file"
rm -f "$q/tests/bare-mktemp.test.sh"

printf '#!/usr/bin/env bash\nv="$(%s %s %s fm-x)"\necho "$v"\n' "$mt" "$fd" "$ft" \
  > "$q/tests/bare-mktemp-t.test.sh"
out="$(FM_ROOT="$q" bash "$q/bin/ci.sh" 2>&1)"
assert_contains "$out" "a bare, template-less mktemp" \
  "and so does mktemp -t with no explicit template"
rm -f "$q/tests/bare-mktemp-t.test.sh"

# The false-positive half: an explicit template under TMPDIR is exactly
# what safe_tmpdir itself does internally, and is not the hazard.
printf '#!/usr/bin/env bash\nv="$(%s %s "\${TMPDIR:-/tmp}/probe.XXXXXX")"\necho "$v"\n' "$mt" "$fd" \
  > "$q/tests/templated-mktemp.test.sh"
out="$(FM_ROOT="$q" bash "$q/bin/ci.sh" 2>&1)"
assert_lacks "$out" "a bare, template-less mktemp" \
  "an explicit template under TMPDIR is not the hazard"
rm -f "$q/tests/templated-mktemp.test.sh"

# The negative half of each exclusion. A lint with a plant for the thing it
# catches and none for the thing it lets through is half a lint: the
# exclusion is where the false positives live, and one of these was dead
# code that never matched anything.
printf '#!/usr/bin/env bash\nset -uo pipefail\nexec < /dev/null\n# printf x %s grep -q y\necho ok\n' '|' \
  > "$q/bin/fm-commented.sh"
out="$(FM_ROOT="$q" bash "$q/bin/ci.sh" 2>&1)"
assert_contains "$out" "ci: green" "a hazard quoted in a comment is not a hazard"
rm -f "$q/bin/fm-commented.sh"

printf '#!/usr/bin/env bash\nset -uo pipefail\nexec < /dev/null\n# "$REPO/bin/fm-emit.sh" --type x\necho ok\n' \
  > "$q/bin/fm-commented.sh"
out="$(FM_ROOT="$q" bash "$q/bin/ci.sh" 2>&1)"
assert_contains "$out" "ci: green" "a dispatch quoted in a comment is not a dispatch"
rm -f "$q/bin/fm-commented.sh"

printf '#!/usr/bin/env bash\n# fm:lint-source\nset -uo pipefail\nexec < /dev/null\ns=hi\nprintf "%%s" "$s" %s grep -q hi\n' '|' \
  > "$q/bin/fm-quoter.sh"
out="$(FM_ROOT="$q" bash "$q/bin/ci.sh" 2>&1)"
assert_contains "$out" "ci: green" "a file that declares itself a lint source is skipped"
rm -f "$q/bin/fm-quoter.sh"

# the same two exclusions hold in the suites
printf '#!/usr/bin/env bash\n# fm:lint-source\nset -uo pipefail\nprintf x %s grep -q x\n  # printf y %s grep -c y\n' '|' '|' \
  > "$q/tests/quoter.test.sh"
out="$(FM_ROOT="$q" bash "$q/bin/ci.sh" 2>&1)"
assert_contains "$out" "ci: green" "a suite that declares itself a lint source is skipped"
printf '#!/usr/bin/env bash\nset -uo pipefail\n  # printf y %s grep -c y\ngrep -q x <<<"$(printf x)"\n' '|' \
  > "$q/tests/quoter.test.sh"
out="$(FM_ROOT="$q" bash "$q/bin/ci.sh" 2>&1)"
assert_contains "$out" "ci: green" "a pipe quoted in a suite's comment, or a here-string, is not a hazard"
# `||` is not a pipe, and grep reading a file after it has no producer to
# kill; -C is context, not count, and a -q that is -e's pattern is a pattern
printf '#!/usr/bin/env bash\nset -uo pipefail\ntrue || grep -q x "$0"\nprintf x %s grep -C 2 x\nprintf x %s grep -e -q\ntrue\n' '|' '|' \
  > "$q/tests/quoter.test.sh"
out="$(FM_ROOT="$q" bash "$q/bin/ci.sh" 2>&1)"
assert_contains "$out" "ci: green" "an or-list into grep -q, grep -C, or -q as -e's pattern is not a hazard"
rm -f "$q/tests/quoter.test.sh"

{ printf '#!/usr/bin/env bash\n'
  printf '# assert_%s "%s '%%s' \\"$out\\" %s grep -q x" "in a comment"\n' fail printf '|'
} > "$q/tests/commented.test.sh"
out="$(FM_ROOT="$q" bash "$q/bin/ci.sh" 2>&1)"
assert_contains "$out" "ci: green" "an evalling assertion quoted in a comment is not one"
rm -f "$q/tests/commented.test.sh"


# this repository does have sourced libraries, and the marker is how the
# gate knows: if it were deleted, the stage would report zero and pass
# counted directly, not by running the gate: this suite IS one of the
# suites the gate runs, and calling it from here recurses
own="$(grep -l '^# fm:sourced' "$ROOT"/bin/*.sh 2>/dev/null | wc -l | tr -d ' ')"
assert_ne "0" "$own" "the repository's own sourced libraries are declared"
for f in "$ROOT"/bin/fm-config.sh "$ROOT"/bin/fm-guard.sh; do
  assert_ok "grep -q '^# fm:sourced' '$f'" "$(basename "$f") declares itself sourced"
done

# a library that declares itself sourced must not carry the redirect, and
# the exemption has to work both ways: the marker exempts it from the
# dispatch stage AND binds it in the sourced stage
printf '#!/usr/bin/env bash\n# fm:sourced\nexec < /dev/null\nx=$(date)\necho "$x"\n' > "$q/bin/fm-lib.sh"
plant "a sourced library with the redirect turns its stage red" "must not redirect the caller"
plant "and the stage names it" "fm-lib.sh"
printf '#!/usr/bin/env bash\n# fm:sourced\nx=$(date)\necho "$x"\n' > "$q/bin/fm-lib.sh"
out="$(FM_ROOT="$q" bash "$q/bin/ci.sh" 2>&1)"
assert_contains "$out" "ci: green" "a declared library with no redirect is simply fine"
stdin_stage="$(printf '%s\n' "$out" | sed -n '/== stdin/,/== dag/p')"
# an extraction that found nothing makes assert_lacks pass on the empty
# string, which is green for an assertion that read nothing
assert_ne "" "$stdin_stage" "the stdin stage was found in the output"
assert_lacks "$stdin_stage" "fm-lib.sh" "and the dispatch stage leaves it alone"
rm -f "$q/bin/fm-lib.sh"

# a second implementation of the vendor chain
printf '#!/usr/bin/env bash\nset -uo pipefail\nexec < /dev/null\nfor v in $chain; do :; done\n' \
  > "$q/bin/fm-second-chain.sh"
plant "a second vendor loop turns its stage red" "loops over vendors on its own"
plant "and the stage names the script" "fm-second-chain.sh"
rm -f "$q/bin/fm-second-chain.sh"

# The assertions stage, from both sides. It landed with no fixture, which
# is the one rule this file is for: a lint nobody has ever seen fail is a
# lint nobody knows works.
# the stage needs a harness to compare against, and this fixture has
# none until now - without lib.sh it skips, and a plant against a stage
# that skipped is the assertion that cannot fail all over again
cp "$ROOT/tests/lib.sh" "$q/tests/lib.sh"
{ printf '#!/usr/bin/env bash\n'
  printf '. "$(dirname "$0")/lib.sh"\n'
  printf 'assert_%s "x" "x" "planted"\n' nosuchthing
  printf 'finish\n'
} > "$q/tests/undefined.test.sh"
plant "a suite calling an assertion lib.sh does not define turns the stage red" \
  "does not define"
# assembled, or this suite carries the name of a helper that does not
# exist and the assertions stage - which cannot tell a call from a
# mention - turns the gate red on the file that tests it
miss="nosuchthing"
plant "and the stage names it" "assert_${miss}"
rm -f "$q/tests/undefined.test.sh"
# and the negative half, which is the reason the stage strips comments:
# a suite that NAMES a helper in prose is not calling it
{ printf '#!/usr/bin/env bash\n'
  printf '. "$(dirname "$0")/lib.sh"\n'
  printf '# this file used to lean on assert_%s, which no longer exists\n' nosuchthing
  printf 'assert_eq "x" "x" "planted"\n'
  printf 'finish\n'
} > "$q/tests/mentions.test.sh"
out="$(FM_ROOT="$q" bash "$q/bin/ci.sh" 2>&1)"
assert_contains "$out" "ci: green" "a helper named only in a comment does not turn it red"
rm -f "$q/tests/mentions.test.sh" "$q/tests/lib.sh"

# a second writer of the event log
printf '#!/usr/bin/env bash\nset -uo pipefail\nexec < /dev/null\necho x >> state/events.jsonl\n' \
  > "$q/bin/fm-sneaky.sh"
plant "a second writer of the event log turns the lint red" "outside fm-emit.sh"
rm -f "$q/bin/fm-sneaky.sh"

# the task list (T-090): one file per task, and the dag stage checks the
# files themselves - there is no hand-kept table left to agree with
mkdir -p "$q/design/tasks"
printf '{"id":"T-001","depends_on":[]}\n' > "$q/design/tasks/T-001.json"
printf '{"id":"T-002","depends_on":["T-001"]}\n' > "$q/design/tasks/T-002.json"
plant "a sound task directory is green" "every task file parses, is named by its id, and depends only on tasks that exist, with no cycle (2 tasks)"
printf '{"id":"T-003","depends_on":["T-404"]}\n' > "$q/design/tasks/T-003.json"
plant "a missing dependency turns the dag stage red" "the task list is not a sound DAG"
plant "and the stage names it" "T-003: depends on T-404, which has no task file"
printf '{"id":"T-003","depends_on":["T-004"]}\n' > "$q/design/tasks/T-003.json"
printf '{"id":"T-004","depends_on":["T-003"]}\n' > "$q/design/tasks/T-004.json"
plant "a cycle turns the dag stage red" "a cycle: T-003 -> T-004 -> T-003"
rm -f "$q/design/tasks/T-004.json"
printf '{"id":"T-999","depends_on":[]}\n' > "$q/design/tasks/T-003.json"
plant "an id that is not its file name turns it red" "T-003.json: its id is \"T-999\", not T-003"
printf '{"id":"T-003",\n' > "$q/design/tasks/T-003.json"
plant "a file that does not parse turns it red" "T-003.json: does not parse"
rm -f "$q/design/tasks/T-003.json"
printf '{"tasks":[{"id":"T-003"}]}\n' > "$q/design/tasks.json"
plant "a design/tasks.json left behind turns it red" "design/tasks.json is still here"
rm -rf "$q/design"

# with a registry, the check runs once per registered task directory and
# names the project. The library's parser lives beside it.
cp "$ROOT/bin/fm-herdr.py" "$q/bin/"; project_storage_fixture "$q/bin/"
external_home="$(safe_tmpdir)"
external_tasks="$external_home/projects/other-app/tasks"
mkdir -p "$q/design/tasks" "$external_tasks"
printf '{"id":"T-001"}\n' > "$q/design/tasks/T-001.json"
printf '{"id":"T-777","depends_on":["T-776"]}\n' > "$external_tasks/T-777.json"
{ printf 'home: %s\n' "$external_home"; printf 'default_project: self-host\nprojects:\n'
  printf '  self-host:\n    repo: .\n    github: o/engine\n    base: main\n    required_check: ci\n'
  printf '    design: design/design.md\n    tasks: design/tasks\n'
  printf '  other-app:\n    github: o/other-app\n    base: main\n    required_check: check\n'
} > "$q/config.yaml"
plant "a registered project's broken list turns the dag stage red" "the task list is not a sound DAG"
plant "and the stage names that project" "project other-app ($external_tasks)"
plant "and its problem" "T-777: depends on T-776"
plant "the self directory is checked in the same run, from a path in the old shape" \
  "project self-host (design/tasks): every task file parses"
printf '{"id":"T-777"}\n' > "$external_tasks/T-777.json"
plant "every sound list is green per project" \
  "project other-app ($external_tasks): every task file parses"
rm -rf "$external_tasks"
plant "an absent machine-local external list is reported and skipped" \
  "project other-app: $external_tasks not on this machine"
# An external-only registry must not hide the engine's own task DAG.
cp "$q/config.yaml" "$q/config.saved"
printf 'home: %s\nprojects:\n  other-app:\n    github: o/other-app\n    base: main\n    required_check: check\n' "$external_home" > "$q/config.yaml"
plant "external-only registry still checks the self task list" "self: every task file parses"
mv "$q/config.saved" "$q/config.yaml"
printf '  broken-app:\n    github: not-a-repo\n    base: main\n    required_check: ci\n' >> "$q/config.yaml"
plant "a broken registry turns the stage red" "the project registry: fm-config: project broken-app: github"
rm -rf "$q/design" "$q/config.yaml" "$q/bin/fm-herdr.py"

# a suite that fails
printf '#!/usr/bin/env bash\nexit 1\n' > "$q/tests/doomed.test.sh"
plant "a failing suite turns the bash stage red" "doomed.test.sh" bash
rm -f "$q/tests/doomed.test.sh"

# The two left: the bun and playwright stages report the runner's own
# output, which their own suites cover, and there is no way to plant a
# failure in them that is not just a failing spec.
rm -rf "$q/bin/adapters"   # the broken adapter planted further up
final_ci_rc=0
out="$(FM_ROOT="$q" bash "$q/bin/ci.sh" 2>&1)" || final_ci_rc=$?
case "$final_ci_rc:$out" in
  0:*'ci: green'*) : ;;
  *) printf 'Final fixture CI failed (exit %s); captured output follows:\n%s\n' "$final_ci_rc" "$out" ;;
esac
assert_eq '0' "$final_ci_rc" "the cleaned fixture CI exits successfully"
assert_contains "$out" "ci: green" "and the fixture is green again once every plant is pulled"

# T-294: a checkout without this repository's own task specs. The registry
# names the self project and a tasks directory that is not there; the fast
# stage says so and passes.
cp "$ROOT/bin/fm-herdr.py" "$q/bin/"; project_storage_fixture "$q/bin/"
{ printf 'default_project: self-host\nprojects:\n'
  printf '  self-host:\n    repo: .\n    github: o/engine\n    base: main\n    required_check: ci\n'
  printf '    design: design/design.md\n    tasks: design/tasks\n'
} > "$q/config.yaml"
rm -rf "$q/design"
self_skip_rc=0
out="$(FM_ROOT="$q" bash "$q/bin/ci.sh" --stage fast 2>&1)" || self_skip_rc=$?
[ "$self_skip_rc" = 0 ] || printf 'fast stage exited %s; captured output follows:\n%s\n' "$self_skip_rc" "$out"
assert_eq '0' "$self_skip_rc" "ci: self task directory absent is skipped"
assert_contains "$out" "- project self-host: design/tasks not in this checkout (skipped)" \
  "ci: self task directory absent is skipped, with a line that names it"
rm -rf "$q"


PATH="$suite_original_path"; export PATH
safe_rm_rf "$suite_tools"
finish
