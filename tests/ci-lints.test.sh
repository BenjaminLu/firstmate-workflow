#!/usr/bin/env bash
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=tests/lib/project-storage.sh
. "$ROOT/tests/lib/project-storage.sh"
# shellcheck source=tests/lib/ci.sh
. "$ROOT/tests/lib/ci.sh"
# tests/e2e belongs to the browser runner. Bun picking those files up runs
# them without a browser and calls the result an error, so the bun stage has
# to leave them alone - and the e2e stage has to say it skipped rather than
# quietly passing when the browser is not installed.
q="$(safe_tmpdir)"; mkdir -p "$q/bin" "$q/tests/e2e"
# shellcheck source=tests/lib/config-modules.sh
. "$ROOT/tests/lib/config-modules.sh"
cp "$ROOT/bin/ci.sh" "$ROOT/bin/fm-config.sh" "$q/bin/"; config_modules_fixture "$q/bin/"
printf 'import { test, expect } from "bun:test";\ntest("a", () => expect(1).toBe(1));\n' \
  > "$q/tests/unit.spec.ts"
printf 'import { test } from "@playwright/test";\ntest("b", async ({ page }) => { await page.goto("about:blank"); });\n' \
  > "$q/tests/e2e/browser.spec.ts"
out="$(FM_ROOT="$q" bash "$q/bin/ci.sh" 2>&1)"
# The declared toolchain supplies Bun; missing-tool behavior uses explicit
# exclusions below rather than changing expectations with the runner's PATH.
assert_contains "$out" "bun test (1 files)" "the bun stage runs the unit spec and not the browser one"
assert_lacks "$out" "x bun test" "a browser spec does not turn the bun stage red"
assert_contains "$out" "playwright not installed" "the installed bunx reports the missing browser dependency"
no_bunx="$(safe_tmpdir)"
fixture_path "$no_bunx" 'bunx' || exit 1
out="$(PATH="$no_bunx" FM_ROOT="$q" bash "$q/bin/ci.sh" --stage e2e 2>&1)"
assert_contains "$out" "bunx not installed" "an explicitly absent bunx is reported missing"
safe_rm_rf "$no_bunx"
rm -f "$q/tests/unit.spec.ts"

# bin/*.sh does not recurse, so the adapters went unlinted for as long as
# they have existed. A fixture with a broken one has to turn the gate red.
mkdir -p "$q/bin/adapters"
# a warning, not a syntax error. A plant that is unparseable proves only
# that the stage runs; this proves it runs at the severity it claims, which
# is the question the adapters raised - their deliberate SC2086 is info and
# must NOT turn the gate red.
printf '#!/usr/bin/env bash\ncd /tmp\necho done\n' > "$q/bin/adapters/sloppy.sh"
out="$(FM_ROOT="$q" bash "$q/bin/ci.sh" --stage fast 2>&1)"
assert_contains "$out" "x shellcheck" "a warning in an adapter turns the shellcheck stage red"
assert_contains "$out" "SC2164" "and the stage says which warning"
# An info-level finding does not: the adapters rely on that.
printf '#!/usr/bin/env bash\nargs=""\necho $args\n' > "$q/bin/adapters/sloppy.sh"
out="$(FM_ROOT="$q" bash "$q/bin/ci.sh" --stage fast 2>&1)"
assert_lacks "$out" "x shellcheck" "an info-level finding does not, which is what the adapters depend on"

# T-176: exercise compilation through the fast entry point, not just its
# Python helper. Each broken module is the only syntax error in its run,
# so a top-level failure cannot conceal a missing recursive scan.
for python_file in bin/lib/compile_probe.py bin/lib/nested/compile_probe.py; do
  mkdir -p "$q/$(dirname "$python_file")"
  printf 'def broken(:\n' > "$q/$python_file"
  python_rc=0
  out="$(FM_ROOT="$q" bash "$q/bin/ci.sh" --stage fast 2>&1)" || python_rc=$?
  assert_eq '1' "$python_rc" "invalid Python in $python_file fails fast checks"
  assert_contains "$out" 'x bin/lib Python modules compile' "the compilation stage rejects $python_file"
  assert_contains "$out" "$python_file" "the compilation diagnostic names $python_file"
  printf 'answer = 42\n' > "$q/$python_file"
  python_rc=0
  out="$(FM_ROOT="$q" bash "$q/bin/ci.sh" --stage fast 2>&1)" || python_rc=$?
  assert_eq '0' "$python_rc" "fixing $python_file restores green fast checks"
  assert_contains "$out" '+ bin/lib Python modules compile' "the compilation stage accepts fixed $python_file"
  rm -f "$q/$python_file"
done
rmdir "$q/bin/lib/nested"

# T-161: construct the unsafe bytes so this test is itself lint-clean.
# Exercise nested shell snippets as well as test files, without text exclusions.
unicode_tree_before="$(find "$q" -print | sort)"
# Real Python bytecode and an extensionless binary both contain the offending
# bytes. Keep them present during the text probes: deleting caches is no fix.
python3 - "$q" <<'PY_BOUNDARY_FIXTURE'
from pathlib import Path
import py_compile
import sys

root = Path(sys.argv[1])
source = root / 'bin/boundary-cache/module.py'
source.parent.mkdir()
# Adjacent literals combine in bytecode, but the source has no unsafe boundary.
source.write_text("value = '$' 'X。'\n", encoding='utf-8')
compiled = Path(py_compile.compile(str(source), doraise=True))
assert b'$X' + '。'.encode() in compiled.read_bytes()
binary = root / 'tests/boundary-cache/blob'
binary.parent.mkdir()
# Place NUL beyond a typical sniffing prefix to cover whole-file classification.
binary.write_bytes(b'# header\n' + b'$X' + '。'.encode() + b'a' * 8192 + b'\0')
PY_BOUNDARY_FIXTURE
unicode_rc=0
out="$(FM_ROOT="$q" bash "$q/bin/ci.sh" --stage fast 2>&1)" || unicode_rc=$?
assert_eq '0' "$unicode_rc" "compiled cache and extensionless binary do not fail fast checks"
assert_contains "$out" '+ non-ASCII variable boundary' "boundary lint ignores binary artifacts"
for unicode_file in bin/nested/snippet.py tests/nested/snippet.txt bin/boundary-cache/__pycache__/snippet.txt tests/nested/snippet.pyc; do
  mkdir -p "$q/$(dirname "$unicode_file")"
  printf '# fixture\n%s%s\n' '$X' '。' > "$q/$unicode_file"
  unicode_rc=0
  out="$(FM_ROOT="$q" bash "$q/bin/ci.sh" --stage fast 2>&1)" || unicode_rc=$?
  assert_eq '1' "$unicode_rc" "unbraced variable in $unicode_file fails fast checks"
  assert_contains "$out" 'x non-ASCII variable boundary' "the boundary lint rejects $unicode_file"
  assert_contains "$out" "$unicode_file:2:" "the boundary lint names file and line"
  printf '# fixture\n%s\n' '${X}。' > "$q/$unicode_file"
  unicode_rc=0
  out="$(FM_ROOT="$q" bash "$q/bin/ci.sh" --stage fast 2>&1)" || unicode_rc=$?
  assert_eq '0' "$unicode_rc" "braced variable in $unicode_file passes fast checks"
  assert_contains "$out" '+ non-ASCII variable boundary' "the boundary lint accepts braces"
  rm -f "$q/$unicode_file"
  # The real compiled module still owns its cache directory until final cleanup.
  if [ "$unicode_file" != bin/boundary-cache/__pycache__/snippet.txt ]; then
    rmdir "$q/$(dirname "$unicode_file")"
  fi
done
safe_rm_rf "$q/bin/boundary-cache"
safe_rm_rf "$q/tests/boundary-cache"
assert_eq "$unicode_tree_before" "$(find "$q" -print | sort)" \
  "boundary fixtures restore the shared tree, including directories"

# T-255: assemble hazards from pieces so this suite remains a lint target.
amp='&'; left='{'; right='}'; escaped_quote='\"'; comma=','
amp_line='out="$'"${left}s//x/${amp}${right}"'"'
json_word="${left}${escaped_quote}a${escaped_quote}:1${comma}${escaped_quote}b${escaped_quote}:2${right}"
json_single="${left}${escaped_quote}a${escaped_quote}:1${right}"
json_line='out="$(cmd "'"$json_word"'")"'
mkdir -p "$q/tests/lib" "$q/.githooks"
for portability_file in bin/lib/probe.sh tests/lib/probe.sh .githooks/probe; do
  for portability_kind in amp json; do
    if [ "$portability_kind" = amp ]; then
      portability_line="$amp_line"; portability_label='patsub replacement portability'
    else
      portability_line="$json_line"; portability_label='escaped JSON in command substitutions'
    fi
    # Keep shellcheck clean so only the portability lint can fail this stage.
    printf '#!/usr/bin/env bash\ns=x\n%s\necho "${s}${out}"\n' "$portability_line" > "$q/$portability_file"
    portability_rc=0
    out="$(FM_ROOT="$q" bash "$q/bin/ci.sh" --stage fast 2>&1)" || portability_rc=$?
    assert_eq '1' "$portability_rc" "$portability_kind in $portability_file fails fast checks"
    assert_contains "$out" "x $portability_label" "the portability lint rejects $portability_kind"
    assert_contains "$out" "$portability_file:3:" "the portability lint names file and line"
    assert_lacks "$out" 'x shellcheck' "shellcheck does not mask $portability_kind in $portability_file"
    printf '#!/usr/bin/env bash\ns=x\n  # %s\n# fm:allow-portability: deliberate fixture\n%s\necho "${s}${out}"\n' \
      "$portability_line" "$portability_line" > "$q/$portability_file"
    portability_rc=0
    out="$(FM_ROOT="$q" bash "$q/bin/ci.sh" --stage fast 2>&1)" || portability_rc=$?
    assert_eq '0' "$portability_rc" "comments and reasoned markers pass for $portability_kind"
    assert_contains "$out" "+ $portability_label" "the portability lint accepts exemptions"
  done
  rm -f "$q/$portability_file"
done
# Pin the replacement variants and quote/parenthesis boundaries directly.
for replacement in '/x/' '//x/' '/#x/' '/%x/'; do
  printf 'out="$%ss[0]%s%s%s"\n' "$left" "$replacement" "$amp" "$right" > "$q/tests/lib/probe.sh"
  portability_rc=0
  out="$(python3 "$ROOT/bin/lib/fm_ci_checks.py" patsub-amp "$q" 2>&1)" || portability_rc=$?
  assert_eq '1' "$portability_rc" "indexed replacement $replacement is rejected"
  assert_contains "$out" 'tests/lib/probe.sh:1:' "indexed replacement names its line"
done
for marker in '# fm:allow-portability: ' ' # fm:allow-portability: indented' '# fm:allow-portability: reason
# intervening comment'; do
  printf '%s\n%s\n' "$marker" "$amp_line" > "$q/tests/lib/probe.sh"
  portability_rc=0
  out="$(python3 "$ROOT/bin/lib/fm_ci_checks.py" patsub-amp "$q" 2>&1)" || portability_rc=$?
  assert_eq '1' "$portability_rc" "only an immediate exact marker with a reason exempts a line"
done
printf 'out="$( (cmd ")" '\''('\''); cmd "%s")"\n' "$json_word" > "$q/tests/lib/probe.sh"
portability_rc=0
out="$(python3 "$ROOT/bin/lib/fm_ci_checks.py" brace-json "$q" 2>&1)" || portability_rc=$?
assert_eq '1' "$portability_rc" "nested and quoted parentheses do not hide JSON"
assert_contains "$out" 'tests/lib/probe.sh:1:' "nested substitution names its line"
printf 'out="$(cmd)"; payload="%s"\n' "$json_word" > "$q/tests/lib/probe.sh"
portability_rc=0
out="$(python3 "$ROOT/bin/lib/fm_ci_checks.py" brace-json "$q" 2>&1)" || portability_rc=$?
assert_eq '0' "$portability_rc" "JSON after the matching parenthesis is outside the substitution"
rm -f "$q/tests/lib/probe.sh"
# Neither arbitrary text, binary shell files, nor the games tree is shell input.
mkdir -p "$q/games"
printf '%s\n%s\n' "$amp_line" "$json_line" > "$q/tests/probe.txt"
printf '#!/usr/bin/env bash\n%s\n%s\n\0' "$amp_line" "$json_line" > "$q/tests/probe.sh"
printf '%s\n%s\n' "$amp_line" "$json_line" > "$q/games/probe.sh"
for portability_check in patsub-amp brace-json; do
  portability_rc=0
  out="$(python3 "$ROOT/bin/lib/fm_ci_checks.py" "$portability_check" "$q" 2>&1)" || portability_rc=$?
  assert_eq '0' "$portability_rc" "$portability_check skips non-shell text, binaries, and games"
done
rm -f "$q/tests/probe.txt" "$q/tests/probe.sh" "$q/games/probe.sh"
rmdir "$q/games"
# Safe data expansion, assignment outside substitution, and comma-free JSON.
printf '#!/usr/bin/env bash\na=x; b="%s"; s=x\nout="${s//$a/$b}"\necho "$out"\npayload="%s"\necho "$payload"\nout="$(cmd "%s")"\necho "$out"\n' \
  "$amp" "$json_word" "$json_single" > "$q/tests/lib/probe.sh"
portability_rc=0
out="$(FM_ROOT="$q" bash "$q/bin/ci.sh" --stage fast 2>&1)" || portability_rc=$?
assert_eq '0' "$portability_rc" "safe replacements and JSON forms pass fast checks"
assert_contains "$out" '+ patsub replacement portability' "variable replacement data is safe"
assert_contains "$out" '+ escaped JSON in command substitutions' "safe JSON forms are accepted"
rm -f "$q/tests/lib/probe.sh"
# Lint-source applies even below a shebang, but never hides boundary hazards.
for portability_marker in '' '# fm:lint-source fixture'; do
  printf '#!/usr/bin/env bash\n%s\nprintf "%%s" "%s%s"\n' \
    "$portability_marker" '$X' '。' > "$q/.githooks/probe"
  if [ -n "$portability_marker" ]; then
    printf '%s\n%s\n' "$amp_line" "$json_line" >> "$q/.githooks/probe"
  fi
  portability_rc=0
  out="$(FM_ROOT="$q" bash "$q/bin/ci.sh" --stage fast 2>&1)" || portability_rc=$?
  assert_eq '1' "$portability_rc" "hook boundary hazard fails even in a lint source"
  assert_contains "$out" 'x non-ASCII variable boundary' "boundary lint covers hooks"
  assert_contains "$out" '.githooks/probe:3:' "boundary lint names the hook line"
  assert_contains "$out" '+ patsub replacement portability' "lint source skips amp replacement"
  assert_contains "$out" '+ escaped JSON in command substitutions' "lint source skips JSON"
done
rm -f "$q/.githooks/probe"
rmdir "$q/.githooks" "$q/tests/lib"

# The real clock path reports elapsed time and the caller's effective budget;
# deterministic boundary enforcement is covered above.
out="$(FM_ROOT="$q" bash "$q/bin/ci.sh" 2>&1)"
assert_matches "$out" 'took [0-9]+s' "the gate reports how long it took"
assert_contains "$out" "effective budget: ${FM_CI_MAX_SECONDS-180}s" "against the selected budget"

# --- every lint, planted ------------------------------------------------
# A lint nobody has ever seen fail is a lint nobody knows works. Each of
# these plants exactly what the stage looks for and asserts the gate flunks
# AND names the offender, because a stage that goes red without saying what
# it found sends the reader back to the source.
# Each plant below is the thing its stage exists to find, not something any
# stage would trip over: a script that dispatches and lacks the redirect, a
# hand-rolled swap, a second vendor loop, a second writer of the log, a task
# depending on one that does not exist, a suite that returns non-zero. None of them is a
# syntax error, and none would be caught by a different stage.
# shellcheck source=tests/lib/ci-plant.sh
. "$ROOT/tests/lib/ci-plant.sh"

# The cache has to HIT, or it is a claim rather than a saving: if
# bin/ci.sh writes anything under FM_ROOT the signature changes every
# time, every plant re-runs the whole gate, and the suite is green
# either way. Two plants against a fixture nothing has touched, and the
# gate must have run once.
{ printf '#!/usr/bin/env bash\nset -uo pipefail\nexec < /dev/null\n'
  printf 'while [ $# -gt 0 ]; do\n  case "$1" in\n'
  printf '    --x) v="${2-}"; shift 2 ;;\n    *) exit 64 ;;\n  esac\ndone\necho "${v:-}"\n'
} > "$q/bin/fm-cachecheck.sh"
before_runs="$planted_runs"
plant "the cache warms on the first plant" "has not checked it has two"
assert_eq "$((before_runs + 1))" "$planted_runs" "the first plant ran the gate"
plant "and a second plant against the same fixture" "fm-cachecheck.sh"
assert_eq "$((before_runs + 1))" "$planted_runs" "and the second one did not run it again"
rm -f "$q/bin/fm-cachecheck.sh"
plant "and a plant after a change runs it again" "no option loop can spin"
assert_eq "$((before_runs + 2))" "$planted_runs" "a changed fixture is not served from the cache"

# The plant cache has to notice an in-place edit, not only a file
# appearing or disappearing. The version keyed on `ls -ld` did not: its
# mtime is minute-granular here, so a rewrite of the same size seconds
# later was invisible and the next assertion read the previous run.
sigdir="$(safe_tmpdir)"; q_save="$q"; q="$sigdir"
printf 'AAAA' > "$q/f"; sig_a="$(fixture_sig)"
printf 'BBBB' > "$q/f"; sig_b="$(fixture_sig)"
assert_ne "$sig_a" "$sig_b" "the plant cache notices an immediate same-size edit"
printf 'AAAA' > "$q/f"
assert_eq "$sig_a" "$(fixture_sig)" "and is the same signature for the same content"
q="$q_save"; rm -rf "$sigdir"

# The gate decides green by reading what a suite said, because a suite
# that calls something which does not exist prints to stderr, carries
# on, and reaches finish green. That decision is the one production
# change with no test, so here it is.
{ printf '#!/usr/bin/env bash\n'
  printf 'nosuch%s "x"\n' helper
  printf 'exit 0\n'
} > "$q/tests/silent.test.sh"
plant "a suite that passes while something in it did not run is a failure" "did not run" bash
plant "and the stage prints the line" "nosuchhelper" bash
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
plant "a suite that goes on after a syntax error in a sourced file is a failure" "did not run" bash
plant "and the stage prints that line too" "syntax error" bash
{ printf '#!/usr/bin/env bash\n'
  printf '/nonexistent/not-a-program\n'
  printf 'exit 0\n'
} > "$q/tests/broken.test.sh"
plant "a suite that goes on after a command it could not exec is a failure" "did not run" bash
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
plant "a suite that goes on after an unbound variable in a subshell is a failure" "did not run" bash
plant "and the stage prints that line as well" "NO_SUCH_VARIABLE" bash
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

# the stage says how many suites it read, which is what makes the
# empty-list guard provable rather than indistinguishable from reading
# /dev/null and passing
out="$(FM_ROOT="$q" bash "$q/bin/ci.sh" 2>&1)"
n="$(find "$q/tests" -name '*.test.sh' | wc -l | tr -d ' ')"
assert_contains "$out" "($n suites)" "the hygiene stage says how many suites it linted"
bare="$(safe_tmpdir)"; mkdir -p "$bare/bin"; cp "$q/bin/ci.sh" "$q/bin/fm-config.sh" "$bare/bin/"; config_modules_fixture "$bare/bin/"
assert_contains "$(FM_ROOT="$bare" bash "$bare/bin/ci.sh" 2>&1)" "(0 suites)" \
  "and says zero rather than passing silently when there are none"
rm -rf "$bare"

# an assertion that evals captured output
{ printf '#!/usr/bin/env bash\n'
  printf 'out=hi\nassert_%s "%s '%%s' \\"$out\\" %s grep -q x" "planted"\n' fail printf '|'
} > "$q/tests/evals.test.sh"
plant "an assertion that evals captured output turns the hygiene stage red" "evals captured output"
plant "and the stage names the suite" "evals.test.sh"
rm -f "$q/tests/evals.test.sh"

# a pipeline feeding grep -q. The pipe is passed in as an argument
# throughout: this suite is one of the files that lint reads, and carrying
# the literal shape would flag the suite that tests it.
printf '#!/usr/bin/env bash\nset -uo pipefail\nexec < /dev/null\ns=hi\nprintf "%%s" "$s" %s grep -q hi\n' '|' \
  > "$q/bin/fm-piped.sh"
plant "a pipeline into grep -q turns the hygiene stage red" "feeds grep -q or -c"
plant "and the stage names the script" "fm-piped.sh"
rm -f "$q/bin/fm-piped.sh"

# and in a test suite, which is where tests/adapter-contract.test.sh's
# completeness loop reported a matching signature as unread at random
# (T-103): the lint read bin/ and nothing else
printf '#!/usr/bin/env bash\nset -uo pipefail\nl=x\nprintf "%%s\\n" "$l" %s grep -qiE X || echo unread\n' '|' \
  > "$q/tests/piped.test.sh"
plant "a suite that pipes into grep -q turns the stage red" "feeds grep -q or -c"
plant "and the stage names the suite" "tests/piped.test.sh"
rm -f "$q/tests/piped.test.sh"

# below tests/ as well, and grep -c counts as much as grep -q does
printf '#!/usr/bin/env bash\nset -uo pipefail\nn="$(jq -r .type e.jsonl %s grep -c . || true)"\n' '|' \
  > "$q/tests/e2e/count.sh"
plant "a helper below tests/ that pipes into grep -c turns it red" "tests/e2e/count.sh"
rm -f "$q/tests/e2e/count.sh"

# The flags come in any order. `grep -[qc]` read only the first letter, so
# `grep -Eq` and `grep -iq` walked past it - tests/lib.sh's assert_matches
# was one of them.
printf '#!/usr/bin/env bash\nset -uo pipefail\nprintf x %s grep -Eq x\nprintf y %s grep -F -xc y\n' '|' '|' \
  > "$q/tests/clustered.test.sh"
plant "grep -q behind another flag is still grep -q" "clustered.test.sh:3:"
plant "and so is grep -c after a separate flag" "clustered.test.sh:4:"
rm -f "$q/tests/clustered.test.sh"

# Every other way of writing it. A regex over one line read one spelling:
# the pipe ending a line with grep on the next, an option with a value in
# front of -q, the operand in front of it (GNU grep permutes), egrep and
# fgrep, and an assignment or `command` in front of grep all walked past.
# Each gets a line of its own, so each is named by its own number.
{ printf '#!/usr/bin/env bash\nset -uo pipefail\n'
  printf 'printf x %s\n  grep -q x\n' '|'                 # 3-4
  printf 'printf x \\\n  %s grep -q x\n' '|'              # 5-6
  printf 'printf x %s grep -m 1 -q x\n' '|'               # 7
  printf 'printf x %s grep -e x -q\n' '|'                 # 8
  printf 'printf x %s grep -A 2 -c x\n' '|'               # 9
  printf 'printf x %s grep x -q\n' '|'                    # 10
  printf 'printf x %s egrep -q x\n' '|'                   # 11
  printf 'printf x %s fgrep -c x\n' '|'                   # 12
  printf 'printf x %s LC_ALL=C grep -q x\n' '|'           # 13
  printf 'printf x %s command grep -q x\n' '|'            # 14
} > "$q/tests/shapes.test.sh"
plant "a pipe that ends the line, with grep -q on the next, is still one" "shapes.test.sh:3:"
plant "and so is one continued with a backslash" "shapes.test.sh:5:"
plant "grep -q behind an option that takes a value is grep -q" "shapes.test.sh:7:"
plant "and behind -e and its pattern" "shapes.test.sh:8:"
plant "grep -c behind -A and its count is grep -c" "shapes.test.sh:9:"
plant "grep -q after its operand is grep -q" "shapes.test.sh:10:"
plant "egrep -q is grep -q" "shapes.test.sh:11:"
plant "fgrep -c is grep -c" "shapes.test.sh:12:"
plant "an assignment in front of grep does not hide it" "shapes.test.sh:13:"
plant "nor does command" "shapes.test.sh:14:"
# and the line it names is the whole command, both lines of it
bar='|'
assert_contains "$planted" "shapes.test.sh:3:printf x $bar   grep -q x" "a joined line is printed whole"
rm -f "$q/tests/shapes.test.sh"

# Every branch of the lint, one line each, so deleting a branch flips the
# line that names it. Not *.test.sh: nothing here is meant to run as a suite
# (timeout and stdbuf are not on every machine). The red half: |&, each
# wrapper and its own options, a path, the long flags, a value that is `--`
# (stepping over it is what reaches the -q; not stepping, `--` ends the
# options and hides it), and a pipe inside $( ). The wrapper options include
# a cluster ending in a letter that takes a value (it takes the next word)
# and abbreviated long options: getopt_long takes any unambiguous prefix,
# and so do grep's own, in `abbreviated`.
wrapped=('env -C /' 'env --unset NAME' 'env --chdir /' 'nice --adjustment 5'
  'time -f F' 'time -o F' 'time --format F' 'time --output F'
  'timeout -k 1 5' 'timeout --signal KILL 5' 'timeout --kill-after 1 5'
  'stdbuf -i L' 'stdbuf -e L' 'stdbuf --input L' 'stdbuf --output L'
  'stdbuf --error L' 'exec -a name'
  'env -iu NAME' 'timeout -vs KILL 5' 'exec -ca name'
  'env --un NAME' 'env --ch /' 'nice --adj 5' 'time --form F' 'time --out F'
  'timeout --sig KILL 5' 'timeout --kill 1 5' 'stdbuf --in L' 'stdbuf --out L'
  'stdbuf --err L')
abbreviated=('--quie x' '--sil x' '--coun x' '--reg -- -q' '--lab -- -q x'
  '--max -- -q x' '--after -- -q x' '--exclude-f -- -q x')
{ printf '#!/usr/bin/env bash\nset -uo pipefail\n'
  printf 'printf x %s& grep -q x\n' '|'                   # 3
  printf 'printf x %s env grep -q x\n' '|'                # 4
  printf 'printf x %s env -i grep -q x\n' '|'             # 5
  printf 'printf x %s env -u NAME grep -q x\n' '|'        # 6
  printf 'printf x %s exec grep -q x\n' '|'               # 7
  printf 'printf x %s time grep -q x\n' '|'               # 8
  printf 'printf x %s time -p grep -q x\n' '|'            # 9
  printf 'printf x %s nice grep -q x\n' '|'               # 10
  printf 'printf x %s nice -n 5 grep -q x\n' '|'          # 11
  printf 'printf x %s nohup grep -q x\n' '|'              # 12
  printf 'printf x %s builtin grep -q x\n' '|'            # 13
  printf 'printf x %s ! grep -q x\n' '|'                  # 14
  printf 'printf x %s { grep -q x; }\n' '|'               # 15
  printf 'printf x %s ( grep -q x )\n' '|'                # 16
  printf 'printf x %s /usr/bin/grep -q x\n' '|'           # 17
  printf 'printf x %s grep --quiet x\n' '|'               # 18
  printf 'printf x %s grep --silent x\n' '|'              # 19
  printf 'printf x %s grep --count x\n' '|'               # 20
  printf 'printf x %s grep -f -- -q x\n' '|'              # 21
  printf 'printf x %s grep -d -- -q x\n' '|'              # 22
  printf 'printf x %s grep --regexp -- -q\n' '|'          # 23
  printf 'printf x %s grep --file -- -q x\n' '|'          # 24
  printf 'v="$(printf x %s grep -q x)"\n' '|'             # 25
  printf 'printf x %s timeout 5 grep -q x\n' '|'          # 26
  printf 'printf x %s timeout -s KILL 5 grep -q x\n' '|'  # 27
  printf 'printf x %s stdbuf -oL grep -q x\n' '|'         # 28
  printf 'printf x %s stdbuf -o L grep -q x\n' '|'        # 29
  printf 'printf x %s /usr/bin/env -u NAME grep -c x\n' '|'  # 30
  # 31 on: every other wrapper option that takes a value
  for w in "${wrapped[@]}"; do printf 'printf x %s %s grep -q x\n' '|' "$w"; done
  for o in "${abbreviated[@]}"; do printf 'printf x %s grep %s\n' '|' "$o"; done
} > "$q/tests/e2e/wrappers.sh"
# The green half, in the same gate run: each line is something one
# exclusion lets through, so deleting that exclusion names it.
valued=(-e -f -m -A -B -C -d -D --regexp --file --max-count --after-context
  --before-context --context --label --include --exclude --exclude-dir
  --binary-files --devices --directories --exclude-from --group-separator)
# and what the long-option and cluster readers must leave alone:
# - an ambiguous prefix (color colour context count), which grep refuses
# - an abbreviation with its value attached, so `--` is next and ends it
# - an attached wrapper value: -i takes "o", so L is the command, not grep
unflagged=('grep --co x' 'grep --reg=x -- -q' 'stdbuf -io L grep -q x')
{ printf '#!/usr/bin/env bash\nset -uo pipefail\n'
  printf 'printf x %s grep -- -q\n' '|'                   # 3
  printf 'printf x %s grep --context=3 x\n' '|'           # 4
  printf 'printf x %s grep --color x\n' '|'               # 5
  printf 'printf x %s grep -eq x\n' '|'                   # 6
  # 7 on: a -q that is the value of each option that takes one
  for o in "${valued[@]}"; do printf 'printf x %s grep %s -q x\n' '|' "$o"; done
  for u in "${unflagged[@]}"; do printf 'printf x %s %s\n' '|' "$u"; done
} > "$q/tests/e2e/exclusions.sh"
plant "|& is a pipe into grep -q" "wrappers.sh:3:"
plant "env in front of grep does not hide it" "wrappers.sh:4:"
plant "nor env -i" "wrappers.sh:5:"
plant "nor env -u and its value" "wrappers.sh:6:"
plant "nor exec" "wrappers.sh:7:"
plant "nor time" "wrappers.sh:8:"
plant "nor time -p" "wrappers.sh:9:"
plant "nor nice" "wrappers.sh:10:"
plant "nor nice -n and its value" "wrappers.sh:11:"
plant "nor nohup" "wrappers.sh:12:"
plant "nor builtin" "wrappers.sh:13:"
plant "nor !" "wrappers.sh:14:"
plant "nor a { group" "wrappers.sh:15:"
plant "nor a ( subshell" "wrappers.sh:16:"
plant "a path in front of grep does not hide it" "wrappers.sh:17:"
plant "--quiet is -q" "wrappers.sh:18:"
plant "--silent is -q" "wrappers.sh:19:"
plant "--count is -c" "wrappers.sh:20:"
plant "the value of -f is stepped over" "wrappers.sh:21:"
plant "and of -d" "wrappers.sh:22:"
plant "and of --regexp" "wrappers.sh:23:"
plant "and of --file" "wrappers.sh:24:"
plant "a pipe into grep -q inside \$( ) is one" "wrappers.sh:25:"
plant "timeout and its duration do not hide grep" "wrappers.sh:26:"
plant "nor timeout -s and its signal" "wrappers.sh:27:"
plant "nor stdbuf -oL" "wrappers.sh:28:"
plant "nor stdbuf -o and its mode" "wrappers.sh:29:"
plant "nor a path-qualified env -u, into grep -c" "wrappers.sh:30:"
n=31
for w in "${wrapped[@]}"; do
  plant "nor $w" "wrappers.sh:$n:"
  n=$((n + 1))
done
for o in "${abbreviated[@]}"; do
  plant "grep $o is read as getopt_long reads it" "wrappers.sh:$n:"
  n=$((n + 1))
done
assert_lacks "$planted" "exclusions.sh:3:" "-- ends grep's options, so -q after it is an operand"
assert_lacks "$planted" "exclusions.sh:4:" "--context=3 is not count"
assert_lacks "$planted" "exclusions.sh:5:" "--color is not count"
assert_lacks "$planted" "exclusions.sh:6:" "-eq is -e with the pattern q"
n=7
for o in "${valued[@]}"; do
  assert_lacks "$planted" "exclusions.sh:$n:" "-q as the value of $o is not -q"
  n=$((n + 1))
done
for u in "${unflagged[@]}"; do
  assert_lacks "$planted" "exclusions.sh:$n:" "$u is not a pipe into grep -q"
  n=$((n + 1))
done
rm -f "$q/tests/e2e/wrappers.sh" "$q/tests/e2e/exclusions.sh"

rm -rf "$q"


PATH="$suite_original_path"; export PATH
safe_rm_rf "$suite_tools"
finish
