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
# The bash stage has two arms and only one of them reads what a suite
# said, which reads like a rule enforced in one place out of two. It is
# not: the other arm runs no suite. Asserted, so the shape cannot change
# quietly - on a tree with no suites the stage skips and reports on
# nothing, so there is no second path a suite's verdict can come down.
empty="$(FM_ROOT="$t" bash "$ROOT/bin/ci.sh" 2>&1)"
assert_contains "$empty" "no suites yet" "with no suites the bash stage skips"
assert_fail "grep -qE '^  [+x] tests/' <<< \"\$empty\"" \
  "and reports on no suite at all, so nothing decides green on the other arm"

assert_ok "test -x '$ROOT/bin/ci.sh'" "ci.sh is executable"
gha="$ROOT/.github/workflows/ci.yml"
assert_ok "test -f '$gha'" "a GitHub Actions workflow exists"
assert_contains "$(cat "$gha")" "bin/ci.sh" "the workflow calls bin/ci.sh, not a copy of its steps"
# the browser suite runs in CI too, or the board is only ever checked here.
# Everything the gate needs must be installed before it runs.
assert_contains "$(cat "$gha")" "playwright install" "CI installs the browser the gate uses"
assert_contains "$(cat "$gha")" "bun install" "CI installs the dependencies the gate uses"
# both halves of "one gate, one file". The negative alone passes on a
# workflow that never heard of playwright, which is to say on the workflow
# as it was before this change.
assert_contains "$(cat "$ROOT/bin/ci.sh")" "playwright test" "the gate runs the browser suite"
assert_lacks "$(cat "$gha")" "playwright test" "and CI does not run it itself"
rm -rf "$t"
# the gate must never read standard input. With nullglob an empty file list
# turns a grep into one that reads stdin, and a nested run - which is exactly
# what this suite does - then waits for a human who is not there. The probe
# gives it a pipe that stays open, the way a real caller does.
# Two ways in, so neither fix ships untested: a tree with no tests at all
# (nullglob leaves the lint's grep with no file list) and a tree whose suite
# reads stdin itself. The budget is derived from the work - a full gate run
# with a timing margin - not from a number that felt long enough.
probe_gate() { # <fixture-dir> <label>
  local p="$1" label="$2" pid deadline
  # a fifo held open read-write never reaches EOF and needs no writer
  # process: the probe blocks for good if the gate reads it, and leaves
  # nothing running behind it
  rm -f "$p/openpipe"; mkfifo "$p/openpipe"
  exec 8<> "$p/openpipe"
  ( FM_ROOT="$p" bash "$p/bin/ci.sh" >/dev/null 2>&1 <&8; touch "$p/done" ) &
  pid=$!
  deadline=$(( $(date +%s) + 90 ))
  while [ ! -f "$p/done" ] && [ "$(date +%s)" -lt "$deadline" ]; do sleep 0.3; done
  assert_ok "test -f '$p/done'" "$label"
  kill -9 "$pid" 2>/dev/null
  wait "$pid" 2>/dev/null
  exec 8>&-; rm -f "$p/openpipe"
}
p="$(mktemp -d)"; mkdir -p "$p/bin"; cp "$ROOT/bin/ci.sh" "$p/bin/ci.sh"
probe_gate "$p" "the gate finishes on a tree with no tests at all"
mkdir -p "$p/tests"
printf '#!/usr/bin/env bash\ncat >/dev/null\nexit 0\n' > "$p/tests/reads-stdin.test.sh"
rm -f "$p/done"
probe_gate "$p" "the gate finishes when a suite reads standard input"

# The two fixes are each sufficient to survive those probes, so neither is
# proved by them. This asserts the invariant itself: whatever the gate is
# started with, what reaches a suite is /dev/null.
# a pipe answers -p, /dev/null answers -c: enough to tell the caller's
# input from the one the gate is required to hand over
printf '#!/usr/bin/env bash\nif [ -p /dev/fd/0 ]; then echo pipe; elif [ -c /dev/fd/0 ]; then echo chardev; else echo other; fi > "%s/sawstdin"\nexit 0\n' \
  "$p" > "$p/tests/reads-stdin.test.sh"
rm -f "$p/openpipe"; mkfifo "$p/openpipe"
exec 8<> "$p/openpipe"
( FM_ROOT="$p" bash "$p/bin/ci.sh" >/dev/null 2>&1 <&8 ) &
gp=$!
for _ in $(seq 1 200); do [ -s "$p/sawstdin" ] && break; sleep 0.3; done
assert_eq "chardev" "$(cat "$p/sawstdin" 2>/dev/null)" "a suite is handed /dev/null, not the caller's pipe"
kill -9 "$gp" 2>/dev/null; wait "$gp" 2>/dev/null; exec 8>&-; rm -f "$p/openpipe"

# and the hygiene lint must be linting something: with nullglob an empty file
# list turns its grep into one that reads /dev/null and passes every time
# assembled at run time: written out whole, this line is itself the
# violation, and the lint would flag this suite for carrying its own fixture
{ printf '#!/usr/bin/env bash\n'
  printf 'assert_%s "%s -q x $%s/bin/ci.sh" "planted"\n' ok grep ROOT
} > "$p/tests/planted.test.sh"
out="$(FM_ROOT="$p" bash "$p/bin/ci.sh" 2>&1)"
assert_contains "$out" "greps source without excluding comments" "the hygiene lint reads the suites it is given"
rm -rf "$p"

# tests/e2e belongs to the browser runner. Bun picking those files up runs
# them without a browser and calls the result an error, so the bun stage has
# to leave them alone - and the e2e stage has to say it skipped rather than
# quietly passing when the browser is not installed.
q="$(mktemp -d)"; mkdir -p "$q/bin" "$q/tests/e2e"
cp "$ROOT/bin/ci.sh" "$q/bin/ci.sh"
printf 'import { test, expect } from "bun:test";\ntest("a", () => expect(1).toBe(1));\n' \
  > "$q/tests/unit.spec.ts"
printf 'import { test } from "@playwright/test";\ntest("b", async ({ page }) => { await page.goto("about:blank"); });\n' \
  > "$q/tests/e2e/browser.spec.ts"
out="$(FM_ROOT="$q" bash "$q/bin/ci.sh" 2>&1)"
# the gate supports a machine without these, so the suite has to as well
if command -v bun >/dev/null 2>&1; then
  assert_contains "$out" "bun test (1 files)" "the bun stage runs the unit spec and not the browser one"
  assert_lacks "$out" "x bun test" "a browser spec does not turn the bun stage red"
else
  printf '    %s\n' "(bun not installed, the bun stage is unchecked)"
fi
if command -v bunx >/dev/null 2>&1; then
  assert_contains "$out" "playwright not installed" "and the browser stage says it was skipped"
else
  assert_contains "$out" "bunx not installed" "and the browser stage says why it was skipped"
fi
# bin/*.sh does not recurse, so the adapters went unlinted for as long as
# they have existed. A fixture with a broken one has to turn the gate red.
mkdir -p "$q/bin/adapters"
# a warning, not a syntax error. A plant that is unparseable proves only
# that the stage runs; this proves it runs at the severity it claims, which
# is the question the adapters raised - their deliberate SC2086 is info and
# must NOT turn the gate red.
printf '#!/usr/bin/env bash\ncd /tmp\necho done\n' > "$q/bin/adapters/sloppy.sh"
out="$(FM_ROOT="$q" bash "$q/bin/ci.sh" 2>&1)"
if command -v shellcheck >/dev/null 2>&1; then
  assert_contains "$out" "x shellcheck" "a warning in an adapter turns the shellcheck stage red"
  assert_contains "$out" "SC2164" "and the stage says which warning"
  # and an info-level finding does not: the adapters rely on that
  printf '#!/usr/bin/env bash\nargs=""\necho $args\n' > "$q/bin/adapters/sloppy.sh"
  out="$(FM_ROOT="$q" bash "$q/bin/ci.sh" 2>&1)"
  assert_lacks "$out" "x shellcheck" "an info-level finding does not, which is what the adapters depend on"
else
  printf '    %s\n' "(shellcheck not installed, adapter lint unchecked)"
fi

# The design's budget is sixty seconds for a full local pass. The gate
# times itself - measuring it from here would run the gate inside the suite
# the gate runs - and this asserts it says so and enforces something.
out="$(FM_ROOT="$q" bash "$q/bin/ci.sh" 2>&1)"
assert_matches "$out" 'took [0-9]+s' "the gate reports how long it took"
assert_contains "$out" "60s locally" "against the budget the design sets"

# --- every lint, planted ------------------------------------------------
# A lint nobody has ever seen fail is a lint nobody knows works. Each of
# these plants exactly what the stage looks for and asserts the gate flunks
# AND names the offender, because a stage that goes red without saying what
# it found sends the reader back to the source.
# Each plant below is the thing its stage exists to find, not something any
# stage would trip over: a script that dispatches and lacks the redirect, a
# hand-rolled swap, a second vendor loop, a second writer of the log, an id
# missing from the design, a suite that returns non-zero. None of them is a
# syntax error, and none would be caught by a different stage.
# One gate run per fixture STATE, not one per assertion: every plant used
# to run a full nested gate, and the stage that measures the gate's own
# budget was mostly measuring that.
#
# The cache invalidates itself off a signature of the fixture rather than
# off the author remembering to clear it. The first version needed a
# `replant` call after every write, one was missed, and the assertion read
# the previous run - green for an assertion that tested nothing, which is
# the class this suite exists to catch.
planted=''; planted_sig=''
# every file, its size and its mtime: enough to notice a plant going in or
# coming out, and portable to the BSD tools this runs on
fixture_sig() { find "$q" -type f -exec ls -ld {} + 2>/dev/null | sort | shasum | cut -c1-40; }
plant() {   # plant <label> <expected fragment>
  local label="$1" want="$2" sig
  sig="$(fixture_sig)"
  if [ "$sig" != "$planted_sig" ]; then
    planted="$(FM_ROOT="$q" bash "$q/bin/ci.sh" 2>&1)"
    planted_sig="$sig"
  fi
  assert_contains "$planted" "$want" "$label"
}

# The gate decides green by reading what a suite said, because a suite
# that calls something which does not exist prints to stderr, carries
# on, and reaches finish green. That decision is the one production
# change with no test, so here it is.
{ printf '#!/usr/bin/env bash\n'
  printf 'nosuch%s "x"\n' helper
  printf 'exit 0\n'
} > "$q/tests/silent.test.sh"
plant "a suite that passes while something in it did not run is a failure" "did not run"
plant "and the stage prints the line" "nosuchhelper"
rm -f "$q/tests/silent.test.sh"

# and the negative half: a suite that prints one of those phrases as
# DATA - asserting a script's own error text, say - is not a suite that
# broke, so the rule matches the shell's diagnostic prefix and not the
# words on their own
{ printf '#!/usr/bin/env bash\n'
  printf 'echo "the script said: command not found, which is what we assert"\n'
  printf 'echo "and also: unbound variable"\n'
  printf 'exit 0\n'
} > "$q/tests/talks.test.sh"
out="$(FM_ROOT="$q" bash "$q/bin/ci.sh" 2>&1)"
assert_contains "$out" "ci: green" "a suite that prints those words as data still passes"
rm -f "$q/tests/talks.test.sh"

# the rest of the same family: bash says all of these the same way and
# carries on afterwards. A file that will not exec, and a syntax error
# in something sourced - which leaves the suite running with half its
# functions undefined and exiting 0, which is exactly what two spliced
# lines in a test file did.
cat > "$q/brokenlib.sh" <<'L'
f() {
L
{ printf '#!/usr/bin/env bash\n'
  printf '. "%s/brokenlib.sh"\n' "$q"
  printf 'exit 0\n'
} > "$q/tests/broken.test.sh"
plant "a suite that goes on after a syntax error in a sourced file is a failure" "did not run"
plant "and the stage prints that line too" "syntax error"
{ printf '#!/usr/bin/env bash\n'
  printf '/nonexistent/not-a-program\n'
  printf 'exit 0\n'
} > "$q/tests/broken.test.sh"
plant "a suite that goes on after a command it could not exec is a failure" "did not run"
# `unbound variable` was in the rule with no plant, and it is the one
# phrase whose place in the set is arguable: under `set -u` a
# non-interactive bash EXITS, which is the other arm's job. In a
# SUBSHELL it does not - the subshell dies, the parent carries on, and
# the suite reaches its end green with a line that never ran. That is
# what earns it a place here.
{ printf '#!/usr/bin/env bash\n'
  printf 'set -u\n'
  printf '( echo "$NO_SUCH_VARIABLE" )\n'
  printf 'exit 0\n'
} > "$q/tests/broken.test.sh"
plant "a suite that goes on after an unbound variable in a subshell is a failure" "did not run"
plant "and the stage prints that line as well" "NO_SUCH_VARIABLE"
rm -f "$q/tests/broken.test.sh" "$q/brokenlib.sh"

# The locale the gate runs a suite under is production, and nothing here
# would break if the line were deleted: the diagnostics it reads are
# English on an English machine either way. So the suite asserts the
# environment itself. LC_MESSAGES pinned to C, and LC_ALL emptied rather
# than set to C - LC_ALL=C pins collation and ctype for every suite as
# well, running their sort, grep and tr over UTF-8 in a locale no
# developer uses.
cat > "$q/tests/locale.test.sh" <<L
#!/usr/bin/env bash
printf 'LC_ALL=[%s] LC_MESSAGES=[%s]\\n' "\${LC_ALL-unset}" "\${LC_MESSAGES-unset}" > "$q/locale"
exit 0
L
LC_ALL=zh_TW.UTF-8 LC_MESSAGES=zh_TW.UTF-8 FM_ROOT="$q" bash "$q/bin/ci.sh" >/dev/null 2>&1
assert_eq "LC_ALL=[] LC_MESSAGES=[C]" "$(cat "$q/locale")" \
  "the gate pins the shell's messages to C and leaves the rest of the locale alone"
rm -f "$q/tests/locale.test.sh" "$q/locale"

# a script that dispatches without closing standard input
# two, because the criterion says the gate names EVERY offender and a gate
# that stopped at the first would pass a single-instance plant
printf '#!/usr/bin/env bash\nset -uo pipefail\nx=$(date)\necho "$x"\n' > "$q/bin/fm-leaky.sh"
printf '#!/usr/bin/env bash\nset -uo pipefail\ny=$(date)\necho "$y"\n' > "$q/bin/fm-drippy.sh"
plant "an unguarded dispatcher turns the stdin stage red" "without closing standard input"
plant "and the stage names the first" "fm-leaky.sh"
plant "and the stage names the second as well" "fm-drippy.sh"
rm -f "$q/bin/fm-leaky.sh" "$q/bin/fm-drippy.sh"

# a hand-rolled save-and-restore in a suite
# assembled, or this suite carries the very string it plants and the lint
# flags the file that tests it - the same trap as the planted source-grep
printf '#!/usr/bin/env bash\nr=/tmp\ncp "$r/bin/x.sh" "$r/x.%s"\n' 'keep"' > "$q/tests/hand-rolled.test.sh"
# the stage says how many suites it read, which is what makes the
# empty-list guard provable rather than indistinguishable from reading
# /dev/null and passing
out="$(FM_ROOT="$q" bash "$q/bin/ci.sh" 2>&1)"
n="$(find "$q/tests" -name '*.test.sh' | wc -l | tr -d ' ')"
assert_contains "$out" "($n suites)" "the hygiene stage says how many suites it linted"
bare="$(mktemp -d)"; mkdir -p "$bare/bin"; cp "$q/bin/ci.sh" "$bare/bin/ci.sh"
assert_contains "$(FM_ROOT="$bare" bash "$bare/bin/ci.sh" 2>&1)" "(0 suites)" \
  "and says zero rather than passing silently when there are none"
rm -rf "$bare"

# an assertion that evals captured output
{ printf '#!/usr/bin/env bash\n'
  printf 'out=hi\nassert_%s "%s '%%s' \\"$out\\" | grep -q x" "planted"\n' fail printf
} > "$q/tests/evals.test.sh"
plant "an assertion that evals captured output turns the hygiene stage red" "evals captured output"
plant "and the stage names the suite" "evals.test.sh"
rm -f "$q/tests/evals.test.sh"

# a pipeline feeding grep -q
printf '#!/usr/bin/env bash\nset -uo pipefail\nexec < /dev/null\ns=hi\nprintf "%%s" "$s" | grep -q hi\n' \
  > "$q/bin/fm-piped.sh"
plant "a pipeline into grep -q turns the hygiene stage red" "feeds grep -q or -c"
plant "and the stage names the script" "fm-piped.sh"
rm -f "$q/bin/fm-piped.sh"

# a shift 2 that has not checked it has two
printf '#!/usr/bin/env bash\nset -uo pipefail\nexec < /dev/null\nwhile [ $# -gt 0 ]; do\n  case "$1" in\n    --x) v="${2-}"; shift 2 ;;\n    *) exit 64 ;;\n  esac\ndone\necho "${v:-}"\n' \
  > "$q/bin/fm-spinner.sh"
plant "an unguarded shift 2 turns the hygiene stage red" "has not checked it has two"
plant "and the stage names the script" "fm-spinner.sh"
rm -f "$q/bin/fm-spinner.sh"
# and the stage says how many scripts it read, so linting nothing does not
# look like linting a clean repository
out="$(FM_ROOT="$q" bash "$q/bin/ci.sh" 2>&1)"
assert_matches "$out" 'spin on a flag with no value \([0-9]+ scripts\)' \
  "the option-loop stage says how many scripts it read"
bare2="$(mktemp -d)"; mkdir -p "$bare2/bin"; cp "$q/bin/ci.sh" "$bare2/bin/ci.sh"
assert_contains "$(FM_ROOT="$bare2" bash "$bare2/bin/ci.sh" 2>&1)" "value (0 scripts)" \
  "and says zero on a tree with none"
rm -rf "$bare2"

# AGENTS.md is the short form of the standing rules and the file an agent
# reads first. Two copies of one list is how a rule ends up true in one
# place and not the other.
mkdir -p "$q/design"
printf '## 2. Standing rules\n\n1. **one**\n2. **two**\n3. **three**\n\n---\n' \
  > "$q/design/design.md"
printf '{"tasks":[]}\n' > "$q/design/tasks.json"
plant "standing rules with no AGENTS.md turn the gate red" "no AGENTS.md to carry them"
printf '# AGENTS.md\n\n1. **one**\n2. **two**\n' > "$q/AGENTS.md"
plant "and so does an AGENTS.md that carries fewer" "AGENTS.md carries 2"
printf '# AGENTS.md\n\n1. **one**\n2. **two**\n3. **three**\n' > "$q/AGENTS.md"
out="$(FM_ROOT="$q" bash "$q/bin/ci.sh" 2>&1)"
assert_contains "$out" "carries every standing rule (3)" "and green once it carries them all"
rm -rf "$q/AGENTS.md" "$q/design"

plant "a hand-rolled swap turns the hygiene stage red" "saves a script by hand"
plant "and the stage names the suite" "hand-rolled.test.sh"
rm -f "$q/tests/hand-rolled.test.sh"

# The negative half of each exclusion. A lint with a plant for the thing it
# catches and none for the thing it lets through is half a lint: the
# exclusion is where the false positives live, and one of these was dead
# code that never matched anything.
printf '#!/usr/bin/env bash\nset -uo pipefail\nexec < /dev/null\n# printf x | grep -q y\necho ok\n' \
  > "$q/bin/fm-commented.sh"
out="$(FM_ROOT="$q" bash "$q/bin/ci.sh" 2>&1)"
assert_contains "$out" "ci: green" "a hazard quoted in a comment is not a hazard"
rm -f "$q/bin/fm-commented.sh"

printf '#!/usr/bin/env bash\nset -uo pipefail\nexec < /dev/null\n# "$REPO/bin/fm-emit.sh" --type x\necho ok\n' \
  > "$q/bin/fm-commented.sh"
out="$(FM_ROOT="$q" bash "$q/bin/ci.sh" 2>&1)"
assert_contains "$out" "ci: green" "a dispatch quoted in a comment is not a dispatch"
rm -f "$q/bin/fm-commented.sh"

printf '#!/usr/bin/env bash\n# fm:lint-source\nset -uo pipefail\nexec < /dev/null\ns=hi\nprintf "%%s" "$s" | grep -q hi\n' \
  > "$q/bin/fm-quoter.sh"
out="$(FM_ROOT="$q" bash "$q/bin/ci.sh" 2>&1)"
assert_contains "$out" "ci: green" "a file that declares itself a lint source is skipped"
rm -f "$q/bin/fm-quoter.sh"

{ printf '#!/usr/bin/env bash\n'
  printf '# assert_%s "%s '%%s' \\"$out\\" | grep -q x" "in a comment"\n' fail printf
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

# a second writer of the event log
printf '#!/usr/bin/env bash\nset -uo pipefail\nexec < /dev/null\necho x >> state/events.jsonl\n' \
  > "$q/bin/fm-sneaky.sh"
plant "a second writer of the event log turns the lint red" "outside fm-emit.sh"
rm -f "$q/bin/fm-sneaky.sh"

# the design and tasks.json disagreeing
mkdir -p "$q/design"
printf '{"tasks":[{"id":"T-999","title":"nowhere in the design"}]}\n' > "$q/design/tasks.json"
printf '# a design with no task table\n' > "$q/design/design.md"
plant "an id the design does not list turns the dag stage red" "the design does not list"
plant "and the stage names the id" "T-999"
rm -rf "$q/design"

# a suite that fails
printf '#!/usr/bin/env bash\nexit 1\n' > "$q/tests/doomed.test.sh"
plant "a failing suite turns the bash stage red" "doomed.test.sh"
rm -f "$q/tests/doomed.test.sh"

# The two left: the bun and playwright stages report the runner's own
# output, which their own suites cover, and there is no way to plant a
# failure in them that is not just a failing spec.
rm -rf "$q/bin/adapters"   # the broken adapter planted further up
out="$(FM_ROOT="$q" bash "$q/bin/ci.sh" 2>&1)"
assert_contains "$out" "ci: green" "and the fixture is green again once every plant is pulled"
rm -rf "$q"

finish
