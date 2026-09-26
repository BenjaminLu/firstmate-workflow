#!/usr/bin/env bash
# Each gate has a case that passes and one that does not; gate 5 also runs
# whatever the fixture's own config.yaml declares under project:. Gate 3 is
# retired (T-114), and this suite shows that nothing still runs it.
set -uo pipefail
# A gate run exports FM_GATE_LOCK_HELD, and a Herdr session its pane ids, into
# every suite it runs. This suite runs the real gate, so it inherits none of
# them: identity, locks and cards bind to its fixtures, not the outer run.
for _fm_k in $(env | sed -E -n 's/^(FM_[^=]*|HERDR_[^=]*)=.*$/\1/p'); do
  unset "$_fm_k" || true
done
export HERDR_ENV=0
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
  # every gate run writes its summary under state/gates/ (T-107), which git
  # ignores in a real tree; a branch made here after a run must not carry it
  printf 'state/\n' > "$d/.gitignore"
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
printf 'state/\n' > "$py/.gitignore"
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
  # and one that names only a longer name with helper.sh inside it
  printf 'touch %q/marks/near   # fm-helper.sh, not the helper above\n' "$r" > "$r/tests/near.test.sh"
  printf 'base\n' > "$r/src/thing.sh"
  printf '{"id":"T-X","scope":["src/**","tests/**","config.yaml"]}\n' > "$r/design/tasks/T-X.json"
  printf 'marks/\nstate/\n' > "$r/.gitignore"
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
assert_fail "test -e '$t5/marks/near'" "nor one that names fm-helper.sh, which only has helper.sh inside it"
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
stub() {  # stub <dir> <checks-exit> <approver-login> ; gate 6 only: gate 7 reads JSON, see ghc
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

# --- gate 7: the approval binds to the change, not the head (T-113) --------
# `gh pr view <pr> --json comments` answers with the comments as JSON, the
# way GitHub does, and with --jq runs the filter over it and prints strings
# raw, the way gh does, so a gate that filters with --jq is read as it would
# be for real. Each comment is one line of comments.tsv: author, then the
# body with \n for its newlines.
ghc() {  # ghc <dir> ; a gh whose pr view answers from <dir>/comments.tsv
  mkdir -p "$1/stub"
  : > "$1/comments.tsv"
  cat > "$1/stub/gh" <<EOF
#!/usr/bin/env bash
if [ "\$1 \$2" = "pr view" ]; then
  filter=.
  while [ \$# -gt 0 ]; do [ "\$1" = --jq ] && { filter="\$2"; break; }; shift; done
  jq -Rn '{comments:[inputs|split("\t")|{author:{login:.[0]},body:(.[1]|gsub("\\\\\\\n";"\n"))}]}' < "$1/comments.tsv" |
    if [ "\$filter" = . ]; then cat; else jq -r "\$filter"; fi
  exit
fi
exit 0
EOF
  chmod +x "$1/stub/gh"; printf '%s' "$1/stub/gh"
}
# reviewed <repo> <branch> <verdict> ; the line fm-review.sh posts, worked
# out here from git's porcelain rather than from the script under test
reviewed() {
  local h b p f
  h="$(git -C "$1" rev-parse "$2")"; b="$(git -C "$1" merge-base main "$2")"
  p="$(git -C "$1" diff "main...$2" | git -C "$1" patch-id --stable | cut -d' ' -f1)"
  f="$(git -C "$1" diff --name-only "main...$2" | jq -Rnc '[inputs]')"
  printf 'REVIEWED:T-X verdict=%s head=%s base=%s patch=%s files=%s' "$3" "$h" "$b" "$p" "$f"
}
post() { printf '%s\t%s\n' "$2" "$3" >> "$1/comments.tsv"; }   # post <dir> <author> <body>
g7() { FM_GH="$d7/stub/gh" FM_REVIEWER_LOGIN=reviewer-1 "$GATE" --task T-X --repo "$d7" --branch "$1" --only 7 --pr 9 2>&1; }

d7="$(fixture)"; ghc "$d7" >/dev/null
# thing.sh long enough that main can change its far end and still merge cleanly
seq 1 30 > "$d7/src/thing.sh"; echo notes > "$d7/README.md"
git -C "$d7" add -A; git -C "$d7" commit -qm "longer thing"
git -C "$d7" checkout -q -b pr main
sed -i.bak '1s/.*/changed by the pull request/' "$d7/src/thing.sh"; rm -f "$d7/src/thing.sh.bak"
git -C "$d7" commit -qam "the change"; git -C "$d7" checkout -q main
# every line below is built by reviewed(), so it must carry real values: an
# empty head or patch-id would make both sides of a comparison agree on nothing
assert_matches "$(reviewed "$d7" pr APPROVE)" \
  '^REVIEWED:T-X verdict=APPROVE head=[0-9a-f]{40} base=[0-9a-f]{40} patch=[0-9a-f]{40} files=\["src/thing\.sh"\]$' \
  "(the REVIEWED line the tests post carries a head, merge-base, patch-id and the changed file)"

post "$d7" reviewer-1 "looks right\\nAPPROVE:T-X\\n\\n$(reviewed "$d7" pr APPROVE)"
out="$(g7 pr)"; rc=$?
assert_eq "0" "$rc" "(7 passes on an APPROVE for the current head, as it did before)"
: > "$d7/comments.tsv"
post "$d7" someone-else "APPROVE:T-X\\n\\n$(reviewed "$d7" pr APPROVE)"
out="$(g7 pr)"; rc=$?
assert_eq "7" "$rc" "(7 ignores APPROVE from anyone but the reviewer, as it did before)"

# the reviewer approves the pull request as it stands ...
: > "$d7/comments.tsv"
post "$d7" reviewer-1 "APPROVE:T-X\\n\\n$(reviewed "$d7" pr APPROVE)"
approved_head="$(git -C "$d7" rev-parse pr)"
# ... then main moves on, touching none of its files, and the pull request is
# brought up to date with a merge, as gh pr update-branch does
echo "more notes" >> "$d7/README.md"; git -C "$d7" commit -qam "main: notes"
git -C "$d7" checkout -q -b updated pr; git -C "$d7" merge -q --no-edit main
git -C "$d7" checkout -q main
assert_ne "$approved_head" "$(git -C "$d7" rev-parse updated)" "(the update moved the head)"
out="$(g7 updated)"; rc=$?
assert_eq "0" "$rc" "(7 carries the APPROVE forward across an update-only head; the base passed any head)"

# the worker edits after the approval: another change, another review
git -C "$d7" checkout -q -b edited updated
sed -i.bak '2s/.*/and a worker edit/' "$d7/src/thing.sh"; rm -f "$d7/src/thing.sh.bak"
git -C "$d7" commit -qam "an edit"; git -C "$d7" checkout -q main
out="$(g7 edited)"; rc=$?
assert_eq "7" "$rc" "7 blocks a head whose change has a different patch-id"
assert_contains "$out" "condition 1" "and names the condition that failed"
assert_contains "$out" "patch-id" "which is the patch-id"

# main touches a file the pull request changes, far enough away to merge
# cleanly and leave the patch-id as it was: the approval saw another file
sed -i.bak '30s/.*/main changed the end/' "$d7/src/thing.sh"; rm -f "$d7/src/thing.sh.bak"
git -C "$d7" commit -qam "main: thing"
git -C "$d7" checkout -q -b touched updated; git -C "$d7" merge -q --no-edit main
git -C "$d7" checkout -q main
assert_eq "$(git -C "$d7" diff main...pr | git -C "$d7" patch-id --stable | cut -d' ' -f1)" \
  "$(git -C "$d7" diff main...touched | git -C "$d7" patch-id --stable | cut -d' ' -f1)" \
  "(the change itself is identical)"
out="$(g7 touched)"; rc=$?
assert_eq "7" "$rc" "7 blocks a carry-forward when main touched a file the pull request changes"
assert_contains "$out" "condition 2" "and names the condition that failed"
assert_contains "$out" "src/thing.sh" "and the file main touched"

# a later REJECT supersedes the APPROVE, carried forward or not
post "$d7" reviewer-1 "REJECT:T-X\\n\\n$(reviewed "$d7" pr REJECT)"
out="$(g7 updated)"; rc=$?
assert_eq "7" "$rc" "7 blocks an APPROVE superseded by a later REJECT"
assert_contains "$out" "condition 3" "and names the condition that failed"
assert_contains "$out" "REJECT" "which is the later REJECT"
: > "$d7/comments.tsv"
post "$d7" reviewer-1 "APPROVE:T-X\\n\\n$(reviewed "$d7" pr APPROVE)"
post "$d7" reviewer-1 "REJECT:T-X"
out="$(g7 pr)"; rc=$?
assert_eq "7" "$rc" "7 blocks even the approved head once a REJECT follows"
# a rejection that mentions the approve marker on the way, posted the way
# fm-review.sh posts it: the reviewer's words, then the REVIEWED line
: > "$d7/comments.tsv"
post "$d7" reviewer-1 "I cannot sign APPROVE:T-X while item 1 stands\\nREJECT:T-X\\n\\n$(reviewed "$d7" pr REJECT)"
out="$(g7 pr)"; rc=$?
assert_eq "7" "$rc" "7 blocks a REJECT whose text mentions the approve marker"
assert_contains "$out" "the latest verdict is REJECT:T-X" "and says the latest verdict is REJECT"

# an APPROVE posted by hand records nothing it reviewed: it is read as it
# always was, and the gate says it binds to no head
: > "$d7/comments.tsv"
post "$d7" reviewer-1 "APPROVE:T-X"
out="$(g7 updated)"; rc=$?
assert_eq "0" "$rc" "(7 still reads an APPROVE with no REVIEWED line as before)"
assert_contains "$out" "no REVIEWED:T-X line" "and says it binds to no head"
post "$d7" reviewer-1 "REJECT:T-X"
out="$(g7 updated)"; rc=$?
assert_eq "7" "$rc" "and a later REJECT supersedes it too"

# --- no gate repeats CI (T-114) -----------------------------------------
# A whole run, every gate, on a head CI and the reviewer have passed: the
# project's check never runs, and the gates that do are 1, 2, 4, 5, 6 and 7.
# gh answers as gh does: checks green, and the reviewer's comment is the one
# fm-review.sh posts for this head, REVIEWED line included (T-113)
rm -f "$t5/marks/check" "$t5/marks/other"
ghc "$t5" >/dev/null
post "$t5" reviewer-1 "APPROVE:T-X\\n\\n$(reviewed "$t5" honest APPROVE)"
out="$(FM_GH="$t5/stub/gh" FM_REVIEWER_LOGIN=reviewer-1 \
  "$GATE" --task T-X --repo "$t5" --branch honest --pr 9 2>&1)"; rc=$?
assert_eq "0" "$rc" "a head with green CI and an approval passes every gate"
assert_fail "test -e '$t5/marks/check'" "and no gate ran the project's check in full"
assert_eq "1 2 4 5 6 7" "$(sed -n 's/^  + gate \([0-9]*\): .*/\1/p' <<<"$out" | tr '\n' ' ' | sed 's/ $//')" \
  "the gates are 1, 2, 4, 5, 6 and 7, each said once, in that order"
assert_contains "$out" "all six gates green" "and the run says all six are green"
assert_lacks "$out" "seven" "and nowhere seven"

# --- the gate summary is written by the gate (T-107) ---------------------
# state/gates/<task>-<head>.txt, which the review prompt quotes, holds the
# run's own stdout lines for the head it judged - nothing wrote it before
honest_head="$(git -C "$t5" rev-parse honest)"
summary="$t5/state/gates/T-X-$honest_head.txt"
rm -f "$summary"
stdout="$(FM_GH="$t5/stub/gh" FM_REVIEWER_LOGIN=reviewer-1 \
  "$GATE" --task T-X --repo "$t5" --branch honest --pr 9 2>/dev/null)"
assert_ok "test -f '$summary'" "a whole run writes the summary for the head it judged"
assert_eq "$stdout" "$(cat "$summary" 2>/dev/null)" "and it is the run's own stdout, line for line"
# a partial run replaces its own gate's line and keeps the rest
cat > "$t5/stub/gh.red" <<'EOF'
#!/usr/bin/env bash
if [ "$1 $2" = "pr checks" ]; then exit 1; fi
exit 0
EOF
chmod +x "$t5/stub/gh.red"
FM_GH="$t5/stub/gh.red" "$GATE" --task T-X --repo "$t5" --branch honest --pr 9 --only 6 >/dev/null 2>&1
assert_contains "$(cat "$summary")" "  x gate 6: the required GitHub check is green" "a partial run writes its own red line"
assert_contains "$(cat "$summary")" "  + gate 5: " "and keeps the lines of the gates it did not run"
assert_lacks "$(cat "$summary")" "  + gate 6: " "and no longer says the gate it ran again was green"
assert_lacks "$(cat "$summary")" "all six gates green" "and does not claim all six once one is red"
FM_GH="$t5/stub/gh" "$GATE" --task T-X --repo "$t5" --branch honest --pr 9 --only 6 >/dev/null 2>&1
assert_contains "$(cat "$summary")" "  + gate 6: " "a partial run that goes green again says so"
assert_contains "$(cat "$summary")" "all six gates green" "and the summary is whole again"
# a partial run with no summary before it writes just its own gate's line
fresh="$(fixture)"; git -C "$fresh" checkout -q -b one; echo x >> "$fresh/src/thing.sh"
git -C "$fresh" commit -qam one; git -C "$fresh" checkout -q main
"$GATE" --task T-X --repo "$fresh" --branch one --only 1 >/dev/null 2>&1
assert_eq "  + gate 1: branch exists and carries commits" \
  "$(cat "$fresh/state/gates/T-X-$(git -C "$fresh" rev-parse one).txt" 2>/dev/null)" \
  "a --only run writes its line under the head it judged"

# --- every gate judges the head the run named (T-107) ---------------------
# The head is read once, when the branch is brought to origin's, and the
# summary is filed under it. A gate that looked the branch up again by name
# would judge wherever it had moved by then - a review round's own
# fast-forward, a worker's checkpoint - under the first head's name. Here the
# branch moves while gate 7 asks gh for the verdicts: the approval is for the
# head the run named, and the head it moved to is another change.
dh="$(fixture)"; ghc "$dh" >/dev/null
git -C "$dh" checkout -q -b named; echo judged >> "$dh/src/thing.sh"; git -C "$dh" commit -qam named
git -C "$dh" checkout -q -b moved; echo later >> "$dh/src/thing.sh"; git -C "$dh" commit -qam later
git -C "$dh" checkout -q main
judged="$(git -C "$dh" rev-parse named)"; later="$(git -C "$dh" rev-parse moved)"
post "$dh" reviewer-1 "APPROVE:T-X\\n\\n$(reviewed "$dh" named APPROVE)"
cat > "$dh/stub/gh-moving" <<EOF
#!/usr/bin/env bash
if [ "\$1 \$2" = "pr view" ]; then git -C "$dh" update-ref refs/heads/named "$later"; fi
exec "$dh/stub/gh" "\$@"
EOF
chmod +x "$dh/stub/gh-moving"
out="$(FM_GH="$dh/stub/gh-moving" FM_REVIEWER_LOGIN=reviewer-1 \
  "$GATE" --task T-X --repo "$dh" --branch named --only 7 --pr 9 2>&1)"; rc=$?
assert_eq "$later" "$(git -C "$dh" rev-parse named)" "(the branch moved while the gate ran)"
assert_eq "0" "$rc" "a gate judges the head the run named, not where the branch moved during it"
assert_contains "$(cat "$dh/state/gates/T-X-$judged.txt" 2>/dev/null)" "  + gate 7: " \
  "and the summary for that head carries that gate's result"
assert_fail "test -e '$dh/state/gates/T-X-$later.txt'" "and nothing is filed for a head no gate named"
rm -rf "$dh"

# --- the head judged is the pull request's (T-107) ----------------------
# gh pr update-branch moves only origin's branch. A local branch behind it is
# fast-forwarded before anything is judged; one that is not behind it is
# refused (76), naming both heads, and nothing is judged or written.
so="$(fixture)"; sbare="$(mktemp -d)/origin.git"
git init -q --bare "$sbare"; git -C "$so" remote add origin "$sbare"
git -C "$so" checkout -q -b pr; echo one >> "$so/src/thing.sh"; git -C "$so" commit -qam one
git -C "$so" checkout -q main; git -C "$so" push -q origin main pr
other="$(mktemp -d)/clone"; git clone -q -b pr "$sbare" "$other"
git -C "$other" config user.email a@b.c; git -C "$other" config user.name t
echo two >> "$other/src/thing.sh"; git -C "$other" commit -qam two
git -C "$other" push -q origin pr
old="$(git -C "$so" rev-parse pr)"; new="$(git -C "$other" rev-parse pr)"
assert_ne "$old" "$new" "(origin's branch moved on without the local one)"
out="$("$GATE" --task T-X --repo "$so" --branch pr --only 1 2>&1)"; rc=$?
assert_eq "0" "$rc" "a local branch behind origin's is gated"
assert_eq "$new" "$(git -C "$so" rev-parse pr)" "after it is fast-forwarded to origin's head"
assert_contains "$out" "fast-forwarded pr from $old to origin's $new" "and the gate says so, naming both heads"
assert_ok "test -f '$so/state/gates/T-X-$new.txt'" "and the summary names the pull request's head"
assert_fail "test -f '$so/state/gates/T-X-$old.txt'" "not the stale local one"
# behind, but its worktree has uncommitted work: nothing is moved under it
git -C "$other" commit -q --allow-empty -m three; git -C "$other" push -q origin pr
wt="$(mktemp -d)/wt"; git -C "$so" worktree add -q "$wt" pr; echo dirty >> "$wt/src/thing.sh"
out="$("$GATE" --task T-X --repo "$so" --branch pr --only 1 2>&1)"; rc=$?
assert_eq "76" "$rc" "a branch behind origin's with a dirty worktree is refused"
assert_eq "$new" "$(git -C "$so" rev-parse pr)" "and left where it was"
assert_contains "$out" "uncommitted changes" "and the gate says why"
git -C "$wt" checkout -q -- src/thing.sh; git -C "$so" worktree remove --force "$wt"
# diverged: the local branch has a commit origin never had
git -C "$so" checkout -q pr; echo local >> "$so/src/thing.sh"; git -C "$so" commit -qam local
git -C "$so" checkout -q main
diverged="$(git -C "$so" rev-parse pr)"; remote_now="$(git -C "$other" rev-parse pr)"
out="$("$GATE" --task T-X --repo "$so" --branch pr --only 1 2>&1)"; rc=$?
assert_eq "76" "$rc" "a local branch that diverged from origin's is refused"
assert_contains "$out" "$diverged" "and the refusal names the local head"
assert_contains "$out" "$remote_now" "and origin's head"
assert_eq "$diverged" "$(git -C "$so" rev-parse pr)" "and the local branch is not rewound"
assert_fail "test -f '$so/state/gates/T-X-$diverged.txt'" "and nothing is judged for it"
# an origin that cannot be read: the local head cannot be shown to be the pull
# request's, so it is refused, named, and nothing is judged or written for it.
# The path has no repository behind it, which real git cannot read.
git -C "$so" update-ref refs/heads/pr "$remote_now"
git -C "$so" remote set-url origin "$(dirname "$sbare")/nowhere.git"
before="$(ls "$so/state/gates" 2>/dev/null)"
out="$("$GATE" --task T-X --repo "$so" --branch pr --only 1 2>&1)"; rc=$?
assert_eq "76" "$rc" "a branch whose origin cannot be read is refused"
assert_contains "$out" "could not read origin's pr, so the local head $remote_now" "and the refusal names the local head"
assert_lacks "$out" "+ gate" "and no gate is judged"
assert_eq "$before" "$(ls "$so/state/gates" 2>/dev/null)" "and no summary is written"
git -C "$so" remote set-url origin "$sbare"

# --- a turn says what the gate and the review round said (T-107) ----------
# fm-run.sh used to send the gate's stdout to /dev/null. Now each line the gate
# said for the head it judged is said under the task, and a gate or a review
# round that refused a stale head (76) is named as that, not as a gate
# numbered 76 or a round that failed. Everything the turn calls is a stub, and
# git answers only the branch lookup, as in the end-to-end suite's caller.
rn="$(mktemp -d)"; mkdir -p "$rn/bin" "$rn/state"
cp "$ROOT/bin/fm-run.sh" "$ROOT/bin/fm-config.sh" "$ROOT/bin/fm-decide.sh" \
   "$ROOT/bin/fm-emit.sh" "$ROOT/bin/fm-herdr.py" "$rn/bin/"
for script in fm-sync-prs fm-dispatch; do
  printf '#!/usr/bin/env bash\nexit 0\n' > "$rn/bin/$script.sh"; chmod +x "$rn/bin/$script.sh"
done
cat > "$rn/bin/fm-gate.sh" <<EOF
#!/usr/bin/env bash
cat "$rn/gate.out"; printf 'GATE_STDERR_LINE\n' >&2
exit "\$(cat "$rn/gate.rc")"
EOF
cat > "$rn/bin/fm-review.sh" <<EOF
#!/usr/bin/env bash
echo "fm-review \$*" >> "$rn/calls"
exit "\$(cat "$rn/review.rc")"
EOF
printf '#!/usr/bin/env bash\nprintf "t-991-fixture\\n"\n' > "$rn/bin/git"
chmod +x "$rn/bin/fm-gate.sh" "$rn/bin/fm-review.sh" "$rn/bin/git"
printf '{"type":"pr_opened","task":"T-991","pr":991}\n' > "$rn/state/events.jsonl"
turn_says() { FM_TRANSPORT=direct PATH="$rn/bin:$PATH" bash "$rn/bin/fm-run.sh" once --repo "$rn" 2>&1; }
# a red gate: its lines, and where it stopped
printf '  + gate 1: branch exists and carries commits\n  x gate 2: rebases onto main cleanly\n' > "$rn/gate.out"
echo 2 > "$rn/gate.rc"; : > "$rn/calls"
out="$(turn_says)"
assert_contains "$out" "T-991:  + gate 1: branch exists and carries commits" "a turn says each line the gate said, under the task"
assert_contains "$out" "T-991:  x gate 2: rebases onto main cleanly" "its red line too"
assert_contains "$out" "T-991: stopped at gate 2" "and still where it stopped"
assert_lacks "$out" "GATE_STDERR_LINE" "but not what the gate said on stderr"
# a gate that refused a stale head judged nothing, and nothing goes to review
: > "$rn/gate.out"; echo 76 > "$rn/gate.rc"; : > "$rn/calls"
out="$(turn_says)"
assert_contains "$out" "T-991: t-991-fixture here cannot be shown to be the pull request's head (it diverged, is behind a dirty worktree, or origin could not be read); nothing was gated" \
  "a gate that refused a stale head is said to have gated nothing"
assert_lacks "$out" "stopped at gate 76" "not taken for a gate numbered 76"
assert_eq "" "$(cat "$rn/calls")" "and nothing is sent to review"
# a review round that refused a stale head posted nothing, and says so
printf '  + gate 6: the required GitHub check is green\n  x gate 7: the reviewer posted APPROVE:T-991\n' > "$rn/gate.out"
echo 7 > "$rn/gate.rc"; echo 76 > "$rn/review.rc"; : > "$rn/calls"
out="$(turn_says)"
assert_contains "$(cat "$rn/calls")" "fm-review --task T-991" "(a gate 7 turn runs the review round)"
assert_contains "$out" "T-991:  x gate 7: the reviewer posted APPROVE:T-991" "the turn says gate 7's line before the round"
assert_contains "$out" "T-991: the review round judged no head that is the pull request's, and posted nothing" \
  "a review round that refused a stale head is said to have posted nothing"
assert_lacks "$out" "the review round failed" "not reported as a round that failed"
rm -rf "$rn"

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
assert_ok "finishes 20 \"FM_GATE_LOCK='$lock' '$GATE' --task T-X --repo '$sl' --branch slow --only 1\"" \
  "and a run after the last one ends does not wait"

# a holder the test controls: a real gate run whose suite says it has started
# and then waits to be let go
held="$sl/marks/held"; release="$sl/marks/release"
git -C "$sl" checkout -q -b hold main
printf 'real\n' > "$sl/src/thing.sh"
printf 'echo held > %q\nwhile [ ! -e %q ]; do sleep 0.1; done\ngrep -q real "${FM_ROOT:-.}/src/thing.sh"\n' "$held" "$release" \
  > "$sl/tests/hold.test.sh"
git -C "$sl" add -A; git -C "$sl" commit -qm hold; git -C "$sl" checkout -q main
# hold <lock> ; starts the holder in the background, and returns once it holds
hold() {
  rm -f "$held" "$release"
  FM_GATE_LOCK="$1" "$GATE" --task T-X --repo "$sl" --branch hold --only 5 >/dev/null 2>&1 & holder=$!
  for _ in $(seq 1 200); do [ -e "$held" ] && return 0; sleep 0.1; done
  return 1
}

# one that holds the lock is waited for, and says whose run it is
lock="$(mktemp -d)/gate.lock"
assert_ok "hold '$lock'" "(a gate run holds the lock)"
FM_GATE_LOCK="$lock" "$GATE" --task T-X --repo "$sl" --branch slow --only 1 > "$sl/marks/w.out" 2> "$sl/marks/w.err" & pw=$!
sleep 2
assert_ok "kill -0 $pw" "a run waits while another live run holds the lock"
assert_contains "$(cat "$sl/marks/w.err")" "waiting for the gate run holding $lock (pid $holder)" "and says whose run it waits for"
touch "$release"
wait "$holder"; rh=$?; wait "$pw"; rw=$?
assert_eq "0 0" "$rh $rw" "and goes on once the holder has finished"

# A run that is killed holds nothing afterwards, and when several runs wait on
# what it left, still only one runs at a time. A slow rename widens the window
# in which a waiter that judged the lock dead acts on a lock another waiter
# has just taken; the waiters start a moment apart so each lands in it.
lock="$(mktemp -d)/gate.lock"
assert_ok "hold '$lock'" "(a gate run holds the lock, and is then killed)"
kill -9 "$holder"; wait "$holder" 2>/dev/null
touch "$release"            # the killed run's suite is let go, and ends on its own
slowbin="$(mktemp -d)"
printf '#!/bin/sh\nsleep 0.5\nexec %q "$@"\n' "$(command -v mv)" > "$slowbin/mv"; chmod +x "$slowbin/mv"
rm -f "$trail"; pids=''
for _ in 1 2 3; do
  PATH="$slowbin:$PATH" FM_GATE_LOCK="$lock" "$GATE" --task T-X --repo "$sl" --branch slow --only 5 >/dev/null 2>&1 &
  pids="$pids $!"; sleep 0.3
done
rcs=''; for p in $pids; do wait "$p"; rcs="$rcs $?"; done
assert_eq " 0 0 0" "$rcs" "three runs waiting on a killed run's lock all pass"
assert_eq "start end start end start end" "$(tr '\n' ' ' < "$trail" | sed 's/ $//')" \
  "and no two of them overlap"

# a lock that names no holder - a run killed before it could write its pid -
# holds nobody up
lock="$(mktemp -d)/gate.lock"; : > "$lock"
assert_ok "finishes 20 \"FM_GATE_LOCK='$lock' '$GATE' --task T-X --repo '$sl' --branch slow --only 1\"" \
  "a lock that names no holder is not waited on for ever"

# The lock's path is in a directory every user writes, so another user can put
# a link there first. A gate run follows none: it neither creates, empties nor
# writes the file a link names, and it refuses rather than runs unlocked.
ld="$(mktemp -d)"
ln -s "$ld/profile" "$ld/dangling.lock"
out="$(FM_GATE_LOCK="$ld/dangling.lock" "$GATE" --task T-X --repo "$sl" --branch slow --only 1 2>&1)"; rc=$?
assert_eq "70" "$rc" "a lock that is a symlink to no file is refused"
assert_fail "test -e '$ld/profile'" "and the file it names is not created"
assert_contains "$out" "cannot use the gate lock $ld/dangling.lock" "and it names the lock"
printf 'keep\n' > "$ld/kept"; ln -s "$ld/kept" "$ld/sym.lock"
FM_GATE_LOCK="$ld/sym.lock" "$GATE" --task T-X --repo "$sl" --branch slow --only 1 >/dev/null 2>&1; rc=$?
assert_eq "70" "$rc" "a lock that is a symlink to a file is refused"
assert_eq "keep" "$(cat "$ld/kept")" "and the file it names keeps what it said"
printf 'keep\n' > "$ld/hard"; ln "$ld/hard" "$ld/hard.lock"
FM_GATE_LOCK="$ld/hard.lock" "$GATE" --task T-X --repo "$sl" --branch slow --only 1 >/dev/null 2>&1; rc=$?
assert_eq "70" "$rc" "a lock that is a hard link to another file is refused"
assert_eq "keep" "$(cat "$ld/hard")" "and that file keeps what it said"
mkfifo "$ld/fifo.lock"
assert_ok "finishes 20 \"FM_GATE_LOCK='$ld/fifo.lock' '$GATE' --task T-X --repo '$sl' --branch slow --only 1; test \\\$? = 70\"" \
  "a lock that is not a regular file is refused, and does not hang the run"

# A run inside a run that holds the same lock would wait for ever, and one
# that skipped the lock would not be serialized: it is refused, and says so.
# A suite that runs the gate takes a lock of its own (see below).
lock="$(mktemp -d)/gate.lock"
out="$(FM_GATE_LOCK="$lock" FM_GATE_LOCK_HELD="$lock" "$GATE" --task T-X --repo "$sl" --branch slow --only 1 2>&1)"; rc=$?
assert_eq "70" "$rc" "a run nested in a run that holds its lock is refused, not run unlocked"
assert_contains "$out" "inside a gate run that holds $lock" "and says why"

# The default lock is one path for the machine. TMPDIR is per user on macOS
# and per sandbox, so a default under it would give two callers two locks.
# Shown by the lock each names when refused, so the suite never takes the
# machine's real lock or waits on a real gate run.
for tmp in "$(mktemp -d)" "$(mktemp -d)"; do
  out="$(env -u FM_GATE_LOCK TMPDIR="$tmp" FM_GATE_LOCK_HELD=/tmp/fm-gate.lock \
    "$GATE" --task T-X --repo "$sl" --branch slow --only 1 2>&1)"; rc=$?
  assert_eq "70" "$rc" "with TMPDIR=$tmp and no FM_GATE_LOCK, the run takes the machine's one lock"
  assert_contains "$out" "holds /tmp/fm-gate.lock;" "and it is /tmp/fm-gate.lock, whatever TMPDIR is"
done

# Every suite that runs the real gate - itself, or through a copied fm-run.sh
# or a copy of every bin/fm-*.sh - sets a lock of its own. On the machine's
# lock it would wait on real gate runs and hold them up, and inside one it is
# refused. A line that only reads the script (sed, grep, cat) does not run it.
# Every source read here and below goes through code(), so a comment that says
# what an assertion looks for can neither satisfy it nor put a suite in a list.
code() {  # code <file> ; its lines with shell, // and one-line HTML comments emptied
  sed -E -e 's@^[[:space:]]*(#|//).*$@@' -e 's@[[:space:]](#|//)[[:space:]].*$@@' -e 's@<!--.*-->@@g' "$1"
}
cmt="$(mktemp)"
printf '# FM_GATE_LOCK=x\n  // GATE_NUMBERS=[1];\nrun ok # FM_GATE_LOCK=y\n<!-- gates[n-1] -->\nkept\n' > "$cmt"
assert_eq "run ok kept" "$(code "$cmt" | tr -s '\n' ' ' | sed 's/^ //; s/ $//')" \
  "a comment line, a trailing comment and an HTML comment are not code"
reaching="$(cd "$ROOT" && for f in tests/*.sh; do
  code "$f" | grep -E 'ROOT"?/bin/fm-(gate|run|\*)\.sh' >/dev/null && printf '%s\n' "$f"; done)"
assert_contains " $(tr '\n' ' ' <<<"$reaching")" " tests/e2e-loop.test.sh " "the sweep finds a suite that runs the gate through a copy"
while IFS= read -r f; do
  [ -n "$f" ] || continue
  runs="$(code "$ROOT/$f" | grep -E 'ROOT"?/bin/fm-(gate|run|\*)\.sh' | grep -vE '(sed|grep|cat|awk) [^|]*ROOT"?/bin/fm-')"
  [ -n "$runs" ] || continue
  assert_contains "$(code "$ROOT/$f")" "FM_GATE_LOCK=" "$f runs the real gate, and sets its own FM_GATE_LOCK"
done <<<"$reaching"

# --- the gate numbers are the same everywhere that reads them (T-114) ---
# fm-gate.sh's own `g <n>` lines are the source; the board, the review
# prompt, the diagram suite and the labels read them.
nums="$(sed -n 's/^g \([0-9]*\) .*/\1/p' "$GATE" | tr '\n' ' ' | sed 's/ $//')"
assert_eq "1 2 4 5 6 7" "$nums" "fm-gate.sh runs gates 1, 2, 4, 5, 6 and 7; 3 is retired"
csv="$(tr ' ' ',' <<<"$nums")"
assert_contains "$(code "$ROOT/board/public/index.html" | tr -d ' ')" "GATE_NUMBERS=[$csv];" \
  "the board's merge checklist lists those gates"
assert_contains "$(code "$ROOT/board/server.ts" | tr -d ' ')" "GATE_NUMBERS=[$csv];" \
  "the board's failed-gate badge accepts those gates"
assert_contains "$(code "$ROOT/bin/fm-review.sh")" "for n in $nums; do" \
  "the review prompt looks for a result line from each of them"
assert_contains "$(code "$ROOT/tests/diagram.test.sh")" "for n in $nums; do" \
  "the diagram suite checks each of their labels"
for n in $nums; do
  assert_ok "jq -e 'has(\"gate$n\")' '$ROOT/i18n/ui.en.json' >/dev/null" "gate $n has a board label"
done
# The retired number keeps its key (tests/i18n.test.sh asks for gate1..7), but
# no dictionary may still describe it as the local check.
for dict in "$ROOT"/i18n/ui.*.json; do
  g3="$(jq -r '.gate3 // ""' "$dict")"
  assert_lacks "$g3" "ci.sh" "$(basename "$dict") no longer labels gate 3 as the local check"
  assert_ok "grep -qiE 'retired|退役' <<<'$g3'" "$(basename "$dict") labels gate 3 retired"
done
# and nothing in the repository still counts seven gates, or calls gate 3 the
# check. The whole tree is swept, not a list of the files a spec named, so a
# guide or a template nobody thought of is found too. The pattern is the idea,
# not a list of phrasings: seven (or 7) near a gate or green, either way
# round, and a run of gates from one to six or seven, in digits or words.
count='seven[^.]{0,40}(gate|green)|(gate|green)[^.]{0,40}seven|(^|[^0-9])7 gates|gates? *(1|one) *(-|–|to|through) *(6|six|7|seven)|gates 3 and 5|gate 3 (runs|and gate 5)'
for phrase in "seven green means a decision" "gates one to six pass" "The seven gates" "all 7 gates" \
  "gates 1-6 are green" "gate 7 sends it; the green lights are seven" "Gate 3 runs the check"; do
  assert_ok "grep -qiE '$count' <<<'$phrase'" "the sweep catches: $phrase"
done
# The allowlist, each entry a use that is not a count of the gates, or a file
# this task cannot change. Task specs and dated proposals record what was true
# when they were written; this suite has to spell the pattern out.
allowed='^design/design\.md:[0-9]+:.*keeps seven slots'      # the card's gate list: one slot per number 1-7
allowed="$allowed"'|^tests/worker\.test\.sh:[0-9]+:.*seven of them'  # a fixture design.md; outside T-114's scope, reported
sweep="$(cd "$ROOT" && git grep -niE "$count" -- . ':!design/tasks/' ':!design/proposals/' ':!tests/gate.test.sh' 2>&1 \
  | grep -vE "$allowed")"
assert_eq "" "$sweep" "no file in the repository still counts seven gates, or runs gate 3"

# --- a merge card's gate list has one shape everywhere (T-114) ------------
# The board reads a card's gates by gate number, gates[n-1], so the list
# keeps a slot per number 1-7 and the retired slot 3 is never shown. Read by
# position, a seven-slot list shows each gate from 4 on with the value of the
# gate before it, and gate 7 with gate 6's.
board="$(code "$ROOT/board/public/index.html" | tr -d ' ')"
assert_contains "$board" "gates[n-1]" "the board reads a merge card's gates by gate number"
assert_lacks "$board" "gates[i]" "and never by position in its own list"
# comment lines are dropped here too: a commented-out card is no producer
nocomment() { grep -vE '^[[:space:]]*(#|//|\*|/\*)' || true; }
producers="$(cd "$ROOT" && git grep -hE 'gates: *\[[0-9, ]*\]' -- . ':!design/proposals/' 2>&1 \
  | nocomment | grep -oE 'gates: *\[[0-9, ]*\]')"
assert_ne "" "$producers" "there are merge cards to check the shape of"
while IFS= read -r p; do
  [ -n "$p" ] || continue
  slots="$(tr -cd ',' <<<"$p" | wc -c | tr -d ' ')"
  assert_eq "6" "$slots" "a merge card's gates carry one slot per number 1-7: $p"
done <<<"$producers"
# and whatever renders the checklist expects one line per gate that exists
counts="$(cd "$ROOT" && git grep -hE '\.gates li"\)\)\.toHaveCount\([0-9]+\)' -- tests/ 2>&1 \
  | nocomment | grep -oE '\.gates li"\)\)\.toHaveCount\([0-9]+\)')"
assert_ne "" "$counts" "the end-to-end suite counts the checklist's lines"
while IFS= read -r c; do
  [ -n "$c" ] || continue
  assert_eq "toHaveCount(6)" "${c##*.}" "the end-to-end suite expects six gate lines: $c"
done <<<"$counts"

# --- the exit code names the gate ---------------------------------------
"$GATE" --task T-X --repo "$d" --branch untested --only 5 >/dev/null 2>&1
assert_eq "5" "$?" "the exit code is the number of the gate that failed"
finish
