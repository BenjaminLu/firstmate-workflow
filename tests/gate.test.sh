#!/usr/bin/env bash
# Each gate has a case that passes and one that does not; gate 5 also runs
# whatever the fixture's own config.yaml declares under project:. Gate 3 is
# retired (T-114), and this suite shows that nothing still runs it.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=tests/lib.sh
. "$ROOT/tests/lib.sh"
GATE="$ROOT/bin/fm-gate.sh"
# this suite's own gate lock: it neither waits on a real gate run on this
# machine nor holds one up, and a run that encloses it (gate 5 of this very
# repository) holds a different lock, so the serialization below is real
FM_GATE_LOCK="$(mktemp -d)/gate.lock"; export FM_GATE_LOCK

# a fixture repo whose config.yaml declares its check, a task file, and main
# at a known state. The check script is the fixture's, not firstmate's: the
# gate knows it only by what config.yaml says.
fixture() {
  local d; d="$(mktemp -d)"
  git -C "$d" init -q -b main
  git -C "$d" config user.email a@b.c; git -C "$d" config user.name t
  mkdir -p "$d/bin" "$d/tests" "$d/design/tasks" "$d/src"
  printf '#!/usr/bin/env bash\nfor t in "${FM_ROOT:-.}"/tests/*.test.sh; do [ -e "$t" ] || continue; bash "$t" || exit 1; done\nexit 0\n' > "$d/bin/suite"
  chmod +x "$d/bin/suite"
  printf 'vendor: mock\nproject:\n  check: bin/suite\n' > "$d/config.yaml"
  cat > "$d/design/tasks/T-X.json" <<JSON
{"id":"T-X","scope":["src/**","tests/**","bin/**","config.yaml"]}
JSON
  echo base > "$d/src/thing.sh"
  git -C "$d" add -A; git -C "$d" commit -qm base
  printf '%s' "$d"
}
# declare <repo> <branch-to-create> <from> ; the new config.yaml arrives on stdin
declare_on() {
  git -C "$1" checkout -q -b "$2" "$3"
  cat > "$1/config.yaml"
  git -C "$1" add -A; git -C "$1" commit -qm "$2"; git -C "$1" checkout -q main
}
gate() { "$GATE" --task T-X --repo "$1" --branch "$2" --only "$3" "${@:4}" >/dev/null 2>&1; }
said() { "$GATE" --task T-X --repo "$1" --branch "$2" --only "$3" 2>&1; }

# --- gate 1 --------------------------------------------------------------
d="$(fixture)"
assert_fail "'$GATE' --task T-X --repo '$d' --branch nope --only 1" "1 blocks a branch that does not exist"
git -C "$d" checkout -q -b work; echo x >> "$d/src/thing.sh"; git -C "$d" commit -qam work
git -C "$d" checkout -q main
assert_ok "gate '$d' work 1" "1 passes a branch with commits"

# --- gate 2 --------------------------------------------------------------
assert_ok "gate '$d' work 2" "2 passes a branch that rebases cleanly"
git -C "$d" checkout -q main; echo conflicting > "$d/src/thing.sh"; git -C "$d" commit -qam diverge
assert_fail "gate '$d' work 2" "2 blocks a branch that conflicts"

# --- gate 3: retired (T-114) ---------------------------------------------
# It ran the whole project.check, which the required GitHub check runs on the
# same head and gate 6 reads. Asking for it is refused, never reported green;
# that no run executes the check is shown under "no gate repeats CI" below.
d="$(fixture)"; git -C "$d" checkout -q -b green
printf '#!/usr/bin/env bash\nexit 0\n' > "$d/tests/a.test.sh"; chmod +x "$d/tests/a.test.sh"
echo impl > "$d/src/thing.sh"; git -C "$d" add -A; git -C "$d" commit -qm green; git -C "$d" checkout -q main
"$GATE" --task T-X --repo "$d" --branch green --only 3 >/dev/null 2>&1
assert_eq "64" "$?" "3 is retired: asking for it is a usage error, not a green gate"
assert_contains "$(said "$d" green 3)" "gate 3 is retired" "and it says so"

# --- gate 4 --------------------------------------------------------------
assert_ok "gate '$d' green 4" "4 passes a diff inside the declared scope"
git -C "$d" checkout -q -b wide green
mkdir -p "$d/elsewhere"; echo x > "$d/elsewhere/f"; git -C "$d" add -A; git -C "$d" commit -qm wide
git -C "$d" checkout -q main
assert_fail "gate '$d' wide 4" "4 blocks a diff that reaches outside it"

# The scope comes from the task's own file, design/tasks/<id>.json, on the
# branch under test (T-090): a branch that widens its task in its own diff
# is gated by what it declares there, exactly as the shared file was.
git -C "$d" checkout -q -b ownfile green
printf '{"id":"T-X","scope":["src/**","tests/**","bin/**","config.yaml","design/tasks/T-X.json","elsewhere/**"]}\n' \
  > "$d/design/tasks/T-X.json"
mkdir -p "$d/elsewhere"; echo x > "$d/elsewhere/f"; git -C "$d" add -A; git -C "$d" commit -qm ownfile
git -C "$d" checkout -q main
assert_ok "gate '$d' ownfile 4" "4 reads the scope from the task's own file on the branch under test"
# a task in flight names the old shared file in its scope so that it may
# carry its own entry; that now means its own file, and nobody else's
git -C "$d" checkout -q -b legacy main
printf '{"id":"T-X","scope":["src/**","design/tasks.json"]}\n' > "$d/design/tasks/T-X.json"
git -C "$d" commit -qam legacy; git -C "$d" checkout -q main
assert_ok "gate '$d' legacy 4" "4 reads a scope naming design/tasks.json as naming the task's own file"
git -C "$d" checkout -q -b legacy-other legacy
printf '{"id":"T-Y","scope":[]}\n' > "$d/design/tasks/T-Y.json"
git -C "$d" add -A; git -C "$d" commit -qm other; git -C "$d" checkout -q main
assert_fail "gate '$d' legacy-other 4" "and not as naming another task's file"
# A branch opened before T-090 still carries its own design/tasks.json and
# no design/tasks/<id>.json. Its entry there is its scope, not main's file:
# here main's file for T-X does not allow elsewhere/**, and the branch's
# old array does. And a task defined only in that array is gated at all.
git -C "$d" checkout -q -b oldlist main
git -C "$d" rm -q -r design/tasks && mkdir -p "$d/design"
printf '{"tasks":[{"id":"T-X","scope":["src/**","design/**","elsewhere/**"]},{"id":"T-OLD","scope":["src/**","design/**"]}]}\n' \
  > "$d/design/tasks.json"
mkdir -p "$d/elsewhere"; echo x > "$d/elsewhere/f"; git -C "$d" add -A; git -C "$d" commit -qm oldlist
git -C "$d" checkout -q main
assert_ok "gate '$d' oldlist 4" "4 reads the scope from a branch's old design/tasks.json when it has no task file"
git -C "$d" checkout -q -b oldonly oldlist
git -C "$d" rm -q -r elsewhere; git -C "$d" commit -qm "no elsewhere"; git -C "$d" checkout -q main
assert_fail "test -e '$d/design/tasks/T-OLD.json'" "(the task below has no file on main)"
out="$("$GATE" --task T-OLD --repo "$d" --branch oldonly --only 4 2>&1)"; rc=$?
assert_eq "0" "$rc" "and a task defined only in the branch's old array has a scope to be gated by"
assert_contains "$out" "tasks split T-OLD" "and the gate says it read the old array"

# --- gate 5: the one that matters ---------------------------------------
d="$(fixture)"
git -C "$d" checkout -q -b vacuous
printf 'real\n' > "$d/src/thing.sh"
printf '#!/usr/bin/env bash\nexit 0\n' > "$d/tests/v.test.sh"        # asserts nothing
chmod +x "$d/tests/v.test.sh"; git -C "$d" add -A; git -C "$d" commit -qm vacuous
git -C "$d" checkout -q main
assert_fail "gate '$d' vacuous 5" "5 blocks a test that passes without the implementation"

git -C "$d" checkout -q -b honest main
mkdir -p "$d/tests"          # git does not track an empty directory
printf 'real\n' > "$d/src/thing.sh"
printf '#!/usr/bin/env bash\ngrep -q real "${FM_ROOT:-.}/src/thing.sh"\n' > "$d/tests/h.test.sh"
chmod +x "$d/tests/h.test.sh"; git -C "$d" add -A; git -C "$d" commit -qm honest
git -C "$d" checkout -q main
assert_ok "gate '$d' honest 5" "5 passes a test that goes red without it"

git -C "$d" checkout -q -b untested main
printf 'more\n' >> "$d/src/thing.sh"; git -C "$d" commit -qam untested; git -C "$d" checkout -q main
assert_fail "gate '$d' untested 5" "5 blocks implementation that ships no test at all"

# A project that is not a bash project. Its tests match none of the default
# globs and are run by nothing the gate knows - only by what config.yaml
# declares. The check can never go red, so only the test template can. The
# template needs what setup installs, so a gate that skipped setup would read
# the vacuous test below as red and wave it through.
py="$(mktemp -d)"
git -C "$py" init -q -b main
git -C "$py" config user.email a@b.c; git -C "$py" config user.name t
mkdir -p "$py/calc" "$py/design/tasks"
printf 'def add(a, b):\n    return 0\n' > "$py/calc/calc.py"
cat > "$py/config.yaml" <<'Y'
project:
  setup: mkdir -p .deps && touch .deps/ready
  check: "true"
  tests:
    - "**/*_check.py"
  test: test -f .deps/ready && python3 {file}
Y
printf '{"id":"T-X","scope":["calc/**","config.yaml"]}\n' > "$py/design/tasks/T-X.json"
git -C "$py" add -A; git -C "$py" commit -qm base

git -C "$py" checkout -q -b honest
printf 'def add(a, b):\n    return a + b\n' > "$py/calc/calc.py"
printf 'from calc import add\nassert add(2, 3) == 5\n' > "$py/calc/add_check.py"
git -C "$py" add -A; git -C "$py" commit -qm honest; git -C "$py" checkout -q main
assert_ok "gate '$py' honest 5" "5 classifies by the declared globs and runs the declared template"

git -C "$py" checkout -q -b vacuous
printf 'def add(a, b):\n    return a + b\n' > "$py/calc/calc.py"
printf 'import sys\nsys.exit(0)\n' > "$py/calc/noop_check.py"
git -C "$py" add -A; git -C "$py" commit -qm vacuous; git -C "$py" checkout -q main
assert_fail "gate '$py' vacuous 5" "5 blocks a template-run test that stays green, after running setup"

git -C "$py" checkout -q -b badsetup honest
printf 'project:\n  setup: exit 9\n  check: "true"\n  tests:\n    - "**/*_check.py"\n  test: python3 {file}\n' \
  > "$py/config.yaml"
git -C "$py" commit -qam badsetup; git -C "$py" checkout -q main
assert_fail "gate '$py' badsetup 5" "5 blocks when setup fails, however red the tests would be"
assert_contains "$(said "$py" badsetup 5)" "setup failed (exit 9)" "and names the failure"

# docs: the project declares which paths need no test of their own. Only
# those: undeclared exempts nothing, and code beside docs still needs a test.
doc="$(fixture)"
printf '# thing\n' > "$doc/README.md"; mkdir -p "$doc/design"; printf 'v1\n' > "$doc/design/design.md"
printf '{"id":"T-X","scope":["src/**","tests/**","design/**","README.md","config.yaml"]}\n' \
  > "$doc/design/tasks/T-X.json"
# declared on main, so the branch under test changes nothing but prose
printf 'project:\n  check: bin/suite\n  docs:\n    - design/**\n    - README.md\n' > "$doc/config.yaml"
git -C "$doc" add -A; git -C "$doc" commit -qm docs-base
git -C "$doc" checkout -q -b docs-only main
printf 'v2\n' > "$doc/design/design.md"; printf '# thing, better\n' > "$doc/README.md"
git -C "$doc" commit -qam prose; git -C "$doc" checkout -q main
assert_ok "gate '$doc' docs-only 5" "5 needs no test when every changed path is declared docs"

git -C "$doc" checkout -q -b docs-and-code main
printf 'v3\n' > "$doc/design/design.md"; echo more >> "$doc/src/thing.sh"
git -C "$doc" commit -qam mixed; git -C "$doc" checkout -q main
assert_fail "gate '$doc' docs-and-code 5" "5 still blocks code beside docs that ships no test"
assert_contains "$(said "$doc" docs-and-code 5)" "adds no test" "and says why"

undoc="$(fixture)"
mkdir -p "$undoc/design"; printf 'v1\n' > "$undoc/design/design.md"
git -C "$undoc" add -A; git -C "$undoc" commit -qm base-design
git -C "$undoc" checkout -q -b prose main
printf 'v2\n' > "$undoc/design/design.md"; git -C "$undoc" commit -qam prose; git -C "$undoc" checkout -q main
assert_fail "gate '$undoc' prose 5" "5 exempts nothing when no docs are declared"

# --- gate 5 runs only the suites the diff touches (T-114) ----------------
# The whole check is the required GitHub check's job. Here it leaves a mark if
# anything runs it, and so does a suite the diff does not touch.
# touched <repo> ; a repo whose check and whose untouched suite each leave a mark
touched() {
  local r; r="$(mktemp -d)"
  git -C "$r" init -q -b main
  git -C "$r" config user.email a@b.c; git -C "$r" config user.name t
  mkdir -p "$r/src" "$r/tests" "$r/design/tasks" "$r/marks"
  printf 'project:\n  check: touch %q/marks/check\n  test: bash {file}\n' "$r" > "$r/config.yaml"
  printf 'touch %q/marks/other\n' "$r" > "$r/tests/other.test.sh"
  # a helper one untouched suite sources, and so exercises
  printf 'verify() { true; }\n' > "$r/tests/helper.sh"
  printf '. "${FM_ROOT:-.}/tests/helper.sh"\nverify\n' > "$r/tests/uses.test.sh"
  printf 'base\n' > "$r/src/thing.sh"
  printf '{"id":"T-X","scope":["src/**","tests/**","config.yaml"]}\n' > "$r/design/tasks/T-X.json"
  printf 'marks/\n' > "$r/.gitignore"
  git -C "$r" add -A; git -C "$r" commit -qm base
  printf '%s' "$r"
}
t5="$(touched)"
git -C "$t5" checkout -q -b honest
printf 'real\n' > "$t5/src/thing.sh"
printf 'grep -q real "${FM_ROOT:-.}/src/thing.sh"\n' > "$t5/tests/h.test.sh"
git -C "$t5" add -A; git -C "$t5" commit -qm honest; git -C "$t5" checkout -q main
out="$(said "$t5" honest 5)"; rc=$?
assert_eq "0" "$rc" "5 passes a touched suite that goes red with the implementation reverted"
assert_fail "test -e '$t5/marks/check'" "and never runs the whole project.check to find out"
assert_fail "test -e '$t5/marks/other'" "nor a suite the diff does not touch"
assert_contains "$out" "running the suites the diff touches: tests/h.test.sh" "and says which suites it ran"

git -C "$t5" checkout -q -b vacuous main
printf 'real\n' > "$t5/src/thing.sh"
printf 'true\n' > "$t5/tests/v.test.sh"
git -C "$t5" add -A; git -C "$t5" commit -qm vacuous; git -C "$t5" checkout -q main
assert_fail "gate '$t5' vacuous 5" "5 still blocks a touched suite that stays green"
assert_fail "test -e '$t5/marks/check'" "without falling back to the whole check"

# The diff changes a helper and no suite: the helper, run on its own, asserts
# nothing, and the suite that sources it is the one the diff touches.
git -C "$t5" checkout -q -b helper main
printf 'real\n' > "$t5/src/thing.sh"
printf 'verify() { grep -q real "${FM_ROOT:-.}/src/thing.sh"; }\n' > "$t5/tests/helper.sh"
git -C "$t5" commit -qam helper; git -C "$t5" checkout -q main
out="$(said "$t5" helper 5)"; rc=$?
assert_eq "0" "$rc" "5 runs the suites that exercise a changed test file, and they go red"
assert_contains "$out" "tests/uses.test.sh" "and names the suite it found that way"
assert_fail "test -e '$t5/marks/other'" "and still not the suite that names no changed file"
assert_fail "test -e '$t5/marks/check'" "nor the whole check"

# check_env reaches the suites, and is the only way a budget or a flag does:
# the gate carries no variable of its own for any one project's suite.
git -C "$t5" checkout -q -b budget honest
printf 'project:\n  check: "true"\n  test: bash {file}\n  check_env:\n    SUITE_BUDGET: 600\n    SUITE_MODE: "full run"\n' > "$t5/config.yaml"
printf '[ "${SUITE_BUDGET:-180}" -ge 300 ] && [ "$SUITE_MODE" = "full run" ] || exit 0\ngrep -q real "${FM_ROOT:-.}/src/thing.sh"\n' \
  > "$t5/tests/h.test.sh"
git -C "$t5" commit -qam budget; git -C "$t5" checkout -q main
assert_ok "env -u SUITE_BUDGET -u SUITE_MODE '$GATE' --task T-X --repo '$t5' --branch budget --only 5" \
  "5 hands check_env to the suites it runs"

# no `test` to run one suite with: the whole check is the only way to ask, and
# the gate says that is what it did
rm -f "$t5/marks/check"
git -C "$t5" checkout -q -b nosuite honest
printf 'project:\n  check: touch %q/marks/check && grep -q real src/thing.sh\n' "$t5" > "$t5/config.yaml"
git -C "$t5" commit -qam nosuite; git -C "$t5" checkout -q main
out="$(said "$t5" nosuite 5)"; rc=$?
assert_eq "0" "$rc" "5 with no declared test falls back to the whole check, which goes red"
assert_ok "test -e '$t5/marks/check'" "and the whole check is what ran"
assert_contains "$out" "declares no project.test to run one suite with, so the whole project.check runs" \
  "and it says so"

# --- gates 6 and 7: gh is injectable so the suite makes no network call ---
stub() {  # stub <dir> <checks-exit> <approver-login>
  mkdir -p "$1/stub"
  cat > "$1/stub/gh" <<EOF
#!/usr/bin/env bash
if [ "\$2" = "checks" ]; then exit $2; fi
if [ "\$2" = "view" ]; then printf '%s\n' "$3"; exit 0; fi
exit 0
EOF
  chmod +x "$1/stub/gh"; printf '%s' "$1/stub/gh"
}
d2="$(fixture)"; git -C "$d2" checkout -q -b b; echo y >> "$d2/src/thing.sh"
git -C "$d2" commit -qam b; git -C "$d2" checkout -q main

assert_ok   "FM_GH='$(stub "$d2" 0 reviewer-1)' gate '$d2' b 6 --pr 9" "6 passes when the required check is green"
assert_fail "FM_GH='$(stub "$d2" 1 reviewer-1)' gate '$d2' b 6 --pr 9" "6 blocks when it is not"
assert_fail "'$GATE' --task T-X --repo '$d2' --branch b --only 6" "6 blocks with no pull request at all"

assert_ok   "FM_GH='$(stub "$d2" 0 reviewer-1)' FM_REVIEWER_LOGIN=reviewer-1 gate '$d2' b 7 --pr 9" \
  "7 passes on APPROVE from the reviewer"
assert_fail "FM_GH='$(stub "$d2" 0 someone-else)' FM_REVIEWER_LOGIN=reviewer-1 gate '$d2' b 7 --pr 9" \
  "7 ignores APPROVE from anyone else"

# --- no gate repeats CI (T-114) -----------------------------------------
# A whole run, every gate, on a head CI and the reviewer have passed: the
# project's check never runs, and the gates that do are 1, 2, 4, 5, 6 and 7.
rm -f "$t5/marks/check" "$t5/marks/other"
out="$(FM_GH="$(stub "$t5" 0 reviewer-1)" FM_REVIEWER_LOGIN=reviewer-1 \
  "$GATE" --task T-X --repo "$t5" --branch honest --pr 9 2>&1)"; rc=$?
assert_eq "0" "$rc" "a head with green CI and an approval passes every gate"
assert_fail "test -e '$t5/marks/check'" "and no gate ran the project's check in full"
assert_eq "1 2 4 5 6 7" "$(sed -n 's/^  + gate \([0-9]*\): .*/\1/p' <<<"$out" | tr '\n' ' ' | sed 's/ $//')" \
  "the gates are 1, 2, 4, 5, 6 and 7, each said once, in that order"
assert_contains "$out" "all six gates green" "and the run says all six are green"
assert_lacks "$out" "seven" "and nowhere seven"

# --- gate runs on one machine never overlap (T-114) ---------------------
# finishes <seconds> <command> ; true when it ended, with status 0, in time
finishes() {
  local s="$1" p i=0; shift
  ( eval "$*" ) >/dev/null 2>&1 & p=$!
  while kill -0 "$p" 2>/dev/null; do
    i=$((i + 1)); [ "$i" -le $(( s * 10 )) ] || { kill "$p" 2>/dev/null; wait "$p" 2>/dev/null; return 1; }
    sleep 0.1
  done
  wait "$p"
}
# a gate 5 that takes a while and writes down when it starts and ends
sl="$(touched)"; trail="$sl/marks/trail"
git -C "$sl" checkout -q -b slow
printf 'real\n' > "$sl/src/thing.sh"
printf 'echo start >> %q\nsleep 2\necho end >> %q\ngrep -q real "${FM_ROOT:-.}/src/thing.sh"\n' "$trail" "$trail" \
  > "$sl/tests/s.test.sh"
git -C "$sl" add -A; git -C "$sl" commit -qm slow; git -C "$sl" checkout -q main
lock="$(mktemp -d)/gate.lock"
FM_GATE_LOCK="$lock" "$GATE" --task T-X --repo "$sl" --branch slow --only 5 >/dev/null 2>&1 & p1=$!
FM_GATE_LOCK="$lock" "$GATE" --task T-X --repo "$sl" --branch slow --only 5 >/dev/null 2>&1 & p2=$!
wait "$p1"; r1=$?; wait "$p2"; r2=$?
assert_eq "0 0" "$r1 $r2" "two gate runs started together both pass"
assert_eq "start end start end" "$(tr '\n' ' ' < "$trail" | sed 's/ $//')" \
  "and one runs only after the other has finished"
assert_fail "test -e '$lock'" "and the lock is gone when the last one ends"

# one that holds the lock is waited for, and says so
mkdir "$lock"; echo "$$" > "$lock/pid"
FM_GATE_LOCK="$lock" "$GATE" --task T-X --repo "$sl" --branch slow --only 1 > "$sl/marks/w.out" 2> "$sl/marks/w.err" & pw=$!
sleep 2
assert_ok "kill -0 $pw" "a run waits while another live run holds the lock"
assert_contains "$(cat "$sl/marks/w.err")" "waiting for the gate run holding $lock (pid $$)" "and says whose run it waits for"
rm -rf "$lock"
wait "$pw"
assert_eq "0" "$?" "and goes on once the lock is released"

# one left by a run that was killed is taken over, not waited on for ever
( exit 0 ) & dead=$!; wait "$dead"
mkdir "$lock"; echo "$dead" > "$lock/pid"
assert_ok "finishes 20 \"FM_GATE_LOCK='$lock' '$GATE' --task T-X --repo '$sl' --branch slow --only 1\"" \
  "a lock whose holder is dead is taken over"

# a run inside a run that holds the lock - gate 5 of this repository runs
# this suite - is part of that run, and waiting for it would wait for ever
mkdir "$lock"; echo "$$" > "$lock/pid"
assert_ok "finishes 20 \"FM_GATE_LOCK='$lock' FM_GATE_LOCK_HELD='$lock' '$GATE' --task T-X --repo '$sl' --branch slow --only 1\"" \
  "a run nested in the holder does not wait for it"
assert_ok "test -d '$lock'" "and leaves the holder's lock where it is"
rm -rf "$lock"

# --- the gate numbers are the same everywhere that reads them (T-114) ---
# fm-gate.sh's own `g <n>` lines are the source; the board, the review
# prompt, the diagram suite and the labels read them.
nums="$(sed -n 's/^g \([0-9]*\) .*/\1/p' "$GATE" | tr '\n' ' ' | sed 's/ $//')"
assert_eq "1 2 4 5 6 7" "$nums" "fm-gate.sh runs gates 1, 2, 4, 5, 6 and 7; 3 is retired"
csv="$(tr ' ' ',' <<<"$nums")"
assert_contains "$(tr -d ' ' < "$ROOT/board/public/index.html")" "GATE_NUMBERS=[$csv];" \
  "the board's merge checklist lists those gates"
assert_contains "$(tr -d ' ' < "$ROOT/board/server.ts")" "GATE_NUMBERS=[$csv];" \
  "the board's failed-gate badge accepts those gates"
assert_contains "$(cat "$ROOT/bin/fm-review.sh")" "for n in $nums; do" \
  "the review prompt looks for a result line from each of them"
assert_contains "$(cat "$ROOT/tests/diagram.test.sh")" "for n in $nums; do" \
  "the diagram suite checks each of their labels"
for n in $nums; do
  assert_ok "jq -e 'has(\"gate$n\")' '$ROOT/i18n/ui.en.json' >/dev/null" "gate $n has a board label"
done
# and nothing a reader is shown still counts seven, or calls gate 3 the check
prose="bin/fm-gate.sh bin/fm-run.sh bin/fm.sh bin/fm-review.sh board/server.ts board/public/index.html
  skills/firstmate/SKILL.md skills/reviewer/SKILL.md skills/worker/SKILL.md README.md design/design.md"
assert_eq "" "$(cd "$ROOT" && grep -niE 'seven(-| )gate|all seven|gates 1-6|gates 1-7|gates 3 and 5|gate 3 runs|gate 3 and gate 5' $prose)" \
  "no file that numbers the gates still says seven, or runs gate 3"

# --- the exit code names the gate ---------------------------------------
"$GATE" --task T-X --repo "$d" --branch untested --only 5 >/dev/null 2>&1
assert_eq "5" "$?" "the exit code is the number of the gate that failed"
finish
