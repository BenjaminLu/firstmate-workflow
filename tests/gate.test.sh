#!/usr/bin/env bash
# Each gate has a case that passes and one that does not; gates 3 and 5 also
# run whatever the fixture's own config.yaml declares under project:.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=tests/lib.sh
. "$ROOT/tests/lib.sh"
GATE="$ROOT/bin/fm-gate.sh"

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

# --- gate 3 --------------------------------------------------------------
d="$(fixture)"; git -C "$d" checkout -q -b green
printf '#!/usr/bin/env bash\nexit 0\n' > "$d/tests/a.test.sh"; chmod +x "$d/tests/a.test.sh"
echo impl > "$d/src/thing.sh"; git -C "$d" add -A; git -C "$d" commit -qm green; git -C "$d" checkout -q main
assert_ok "gate '$d' green 3" "3 passes when the declared check exits 0"
git -C "$d" checkout -q -b red green
printf '#!/usr/bin/env bash\nexit 1\n' > "$d/tests/a.test.sh"; git -C "$d" commit -qam red; git -C "$d" checkout -q main
assert_fail "gate '$d' red 3" "3 blocks when the declared check exits non-zero"

# The check is whatever config.yaml declares - not a script the gate knows
# by name. This one only exists under a name no gate would guess.
declare_on "$d" custom green <<'Y'
project:
  check: test "$(cat src/thing.sh)" = impl
Y
assert_ok "gate '$d' custom 3" "3 runs the check config.yaml declares, whatever it is"
declare_on "$d" custom-red green <<'Y'
project:
  check: test "$(cat src/thing.sh)" = something-else
Y
assert_fail "gate '$d' custom-red 3" "and its exit status is the verdict"

# check_env reaches the check, and is the only way a budget or a flag does:
# the gate carries no variable of its own for any one project's suite.
declare_on "$d" budget green <<'Y'
project:
  check: '[ "${SUITE_BUDGET:-180}" -ge 300 ] && [ "$SUITE_MODE" = "full run" ]'
  check_env:
    SUITE_BUDGET: 600
    SUITE_MODE: "full run"
Y
assert_ok "env -u SUITE_BUDGET -u SUITE_MODE '$GATE' --task T-X --repo '$d' --branch budget --only 3" \
  "3 hands check_env to the check"

# setup runs first, in the same detached worktree, and the check can see it
declare_on "$d" setup green <<'Y'
project:
  setup: mkdir -p deps && echo installed > deps/marker
  check: grep -q installed deps/marker
Y
assert_ok "gate '$d' setup 3" "3 runs the declared setup before the check"

# a setup that fails is a red gate that says so - never a check that passes
# with a stage skipped because what it needed was never installed
declare_on "$d" badsetup green <<'Y'
project:
  setup: echo "registry unreachable" >&2; exit 7
  check: "true"
Y
assert_fail "gate '$d' badsetup 3" "3 blocks when setup fails, even with a green check"
out="$(said "$d" badsetup 3)"
assert_contains "$out" "setup failed (exit 7)" "and names the failure"
assert_contains "$out" "registry unreachable" "with what setup said"

declare_on "$d" nocheck green <<'Y'
vendor: mock
project:
  setup: "true"
Y
assert_fail "gate '$d' nocheck 3" "3 blocks when no check is declared"
assert_contains "$(said "$d" nocheck 3)" "config.yaml declares no project.check" \
  "and says which declaration is missing"

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

# --- the exit code names the gate ---------------------------------------
"$GATE" --task T-X --repo "$d" --branch untested --only 5 >/dev/null 2>&1
assert_eq "5" "$?" "the exit code is the number of the gate that failed"
finish
