#!/usr/bin/env bash
# bin/fm-failfirst.sh (T-153): fail-first, run by the machine on every pull
# request. Each case is a fixture repository with a main and a change on top
# of it; the script reverts the change's behaviour, runs the change's suites
# on both trees and says which assertions went red on base.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=tests/lib.sh
. "$ROOT/tests/lib.sh"
FF="$ROOT/bin/fm-failfirst.sh"
isolate_tmpdir

# A repository whose tool says "old" on main; the change is made by the case.
# Its suites print assertion lines the way tests/lib.sh does.
fixture() {
  local d; d="$(safe_tmpdir)"
  git -C "$d" init -q -b main
  git -C "$d" config user.email a@b.c; git -C "$d" config user.name t
  mkdir -p "$d/bin" "$d/tests" "$d/design"
  printf 'project:\n  tests:\n    - tests/**\n  test: case {file} in *.test.sh) bash {file} ;; esac\n' > "$d/config.yaml"
  printf '#!/usr/bin/env bash\necho old\n' > "$d/bin/tool.sh"
  cat > "$d/tests/lib.sh" <<'L'
fails=0
check() { printf '    %-52s' "$1"; if [ "$2" = "$3" ]; then echo ok; else echo FAIL; fails=1; fi; }
L
  echo '# notes' > "$d/design/notes.md"
  git -C "$d" add -A; git -C "$d" commit -qm base
  git -C "$d" checkout -q -b change
  printf '%s' "$d"
}
commit() { git -C "$1" add -A; git -C "$1" commit -qm change; }
ff() {   # ff <repo> [args...] -> the report on stdout, the script's exit code; stderr in <repo>.err
  local d="$1"; shift
  ( cd "$d" && bash "$FF" --report "$d.report" "$@" main ) 2>"$d.err"
}

# --- a change whose new test goes red on base passes, naming it ------------
d="$(fixture)"
printf '#!/usr/bin/env bash\necho new\n' > "$d/bin/tool.sh"
cat > "$d/tests/tool.test.sh" <<'T'
. tests/lib.sh
check "the tool says new" new "$(bash bin/tool.sh)"
check "the tool says something" 1 "$([ -n "$(bash bin/tool.sh)" ] && echo 1)"
exit "$fails"
T
commit "$d"
out="$(ff "$d")"; rc=$?
assert_eq "0" "$rc" "a change whose test goes red on base passes"
assert_contains "$out" "## Fail-first: pass" "and its report says so"
assert_contains "$out" "### tests/tool.test.sh" "per changed suite"
red="$(awk '/^Red on base/{f=1;next} /^$/{f=0} f' <<< "$out")"
guard="$(awk '/^Guard, green on base too/{f=1;next} /^$/{f=0} f' <<< "$out")"
assert_contains "$red" '`the tool says new`: FAIL on base' "naming the assertion that went red on base"
assert_lacks "$red" "the tool says something" "and not the one that did not"
assert_contains "$guard" '`the tool says something`' "which is marked a guard"
assert_contains "$out" 'behaviour changed: `bin/tool.sh`' "it names the behaviour it reverted"
assert_contains "$out" "head exit 0, base exit 1" "and each tree's exit"
assert_contains "$out" "re-run in this job beside the base" "and says the head was re-run here, not read from CI"
assert_eq "$out" "$(cat "$d.report" 2>/dev/null)" "--report holds the same report"
assert_eq "new" "$(bash "$d/bin/tool.sh")" "the checkout itself is left as the head has it"
assert_eq "" "$(git -C "$d" status --porcelain)" "and clean"
assert_eq "1" "$(git -C "$d" worktree list | wc -l | tr -d ' ')" "and no worktree of the script's is left behind"
# the job summary is the same report
: > "$d.summary"
( cd "$d" && GITHUB_STEP_SUMMARY="$d.summary" bash "$FF" main ) >/dev/null 2>&1
assert_contains "$(cat "$d.summary")" "## Fail-first: pass" "and \$GITHUB_STEP_SUMMARY gets it too"

# --- one whose test stays green on base fails, naming it ---------------------
d="$(fixture)"
printf '#!/usr/bin/env bash\necho new\n' > "$d/bin/tool.sh"
cat > "$d/tests/tool.test.sh" <<'T'
. tests/lib.sh
check "the tool exists" 1 "$([ -f bin/tool.sh ] && echo 1)"
exit "$fails"
T
commit "$d"
out="$(ff "$d")"; rc=$?
assert_eq "1" "$rc" "a change whose tests stay green on base fails"
assert_contains "$out" "## Fail-first: fail" "and its report says so"
assert_contains "$out" "no assertion of a changed suite went red on base" "and why"
guard="$(awk '/^Guard, green on base too/{f=1;next} /^$/{f=0} f' <<< "$out")"
assert_contains "$guard" '`the tool exists`' "naming the test that stayed green, as a guard"
assert_contains "$out" "Red on base (0):" "with nothing red on base"

# --- a file the change adds is removed from the base tree --------------------
d="$(fixture)"
printf '#!/usr/bin/env bash\necho added\n' > "$d/bin/added.sh"
cat > "$d/tests/added.test.sh" <<'T'
. tests/lib.sh
[ -f bin/added.sh ] || { echo "no bin/added.sh"; exit 2; }
check "the added script answers" added "$(bash bin/added.sh)"
exit "$fails"
T
commit "$d"
out="$(ff "$d")"; rc=$?
assert_eq "0" "$rc" "a new script's test that cannot run without it passes"
assert_contains "$out" '`the added script answers`: not reached on base, whose run exited 2' \
  "an assertion the base run never reached counts as red, and says why"
assert_contains "$out" "1 the change adds removed" "the added file was removed from the base tree"

# --- docs, skills and CI only: not applicable --------------------------------
d="$(fixture)"
echo '# more notes' >> "$d/design/notes.md"
mkdir -p "$d/skills/x" "$d/.github/workflows"; echo skill > "$d/skills/x/SKILL.md"; echo 'on: push' > "$d/.github/workflows/ci.yml"
commit "$d"
out="$(ff "$d")"; rc=$?
assert_eq "0" "$rc" "a docs-only change is not a failure"
assert_contains "$out" "## Fail-first: not applicable" "it is not applicable"
assert_contains "$out" "touches no behaviour" "and says why"
assert_lacks "$out" "###" "and runs no suite"

# a change to tests alone reverts nothing either
d="$(fixture)"
printf '. tests/lib.sh\ncheck "old" old "$(bash bin/tool.sh)"\nexit "$fails"\n' > "$d/tests/old.test.sh"
commit "$d"
out="$(ff "$d")"; rc=$?
assert_eq "0" "$rc" "a tests-only change is not a failure"
assert_contains "$out" "## Fail-first: not applicable" "and is not applicable"
assert_contains "$out" "only tests" "because it touches only tests"

# --- behaviour with no test at all fails --------------------------------------
d="$(fixture)"
printf '#!/usr/bin/env bash\necho new\n' > "$d/bin/tool.sh"
commit "$d"
out="$(ff "$d")"; rc=$?
assert_eq "1" "$rc" "a behaviour change with no test change fails"
assert_contains "$out" "adds or changes no test suite" "and says so"

# --- a changed suite the test template does not run shows nothing ----------
d="$(fixture)"
printf '#!/usr/bin/env bash\necho new\n' > "$d/bin/tool.sh"
echo 'test("x", () => {})' > "$d/tests/tool.spec.ts"
commit "$d"
out="$(ff "$d")"; rc=$?
assert_eq "1" "$rc" "a change whose only test the template does not run fails"
assert_contains "$out" "ran no assertion of it" "and says the template ran none of it"

# --- the setup runs in each tree, and --setup replaces it --------------------
d="$(fixture)"
printf 'project:\n  setup: echo declared > setup.mark\n  tests:\n    - tests/**\n  test: bash {file}\n' > "$d/config.yaml"
printf '#!/usr/bin/env bash\necho new\n' > "$d/bin/tool.sh"
printf '. tests/lib.sh\ncheck "setup ran here" declared "$(cat setup.mark)"\ncheck "new" new "$(bash bin/tool.sh)"\nexit "$fails"\n' \
  > "$d/tests/tool.test.sh"
commit "$d"
out="$(ff "$d")"
guard="$(awk '/^Guard, green on base too/{f=1;next} /^$/{f=0} f' <<< "$out")"
assert_contains "$guard" '`setup ran here`' "the declared setup ran in both trees"
out="$(ff "$d" --setup 'echo given > setup.mark')"
assert_contains "$out" 'Failing on the head itself (1)' "--setup replaces the declared one"
assert_contains "$out" '`setup ran here`' "and the assertion that needed the declared one is named as failing on the head"
out="$(ff "$d" --setup 'exit 9')"; rc=$?
assert_eq "70" "$rc" "a setup that fails means the script could not run"
assert_contains "$(cat "$d.err")" "setup failed" "and says so"

# --- usage ---------------------------------------------------------------------
( cd "$d" && bash "$FF" ) >/dev/null 2>&1
assert_eq "64" "$?" "no base ref is a usage error"
( cd "$d" && bash "$FF" --jobs 0 main ) >/dev/null 2>&1
assert_eq "64" "$?" "and so is a pool of none"
( cd "$d" && bash "$FF" no-such-ref ) >/dev/null 2>&1
assert_eq "70" "$?" "a base ref that does not exist cannot be run against"

# --- the workflow runs it on every pull request, as part of the required ci --
gha="$(cat "$ROOT/.github/workflows/ci.yml")"
job="$(awk '$0 == "  fail-first:" { f = 1; next } f && /^  [a-zA-Z_-]+:[[:space:]]*$/ { exit } f { print }' \
  "$ROOT/.github/workflows/ci.yml")"
assert_ne "" "$job" "the workflow has a fail-first job"
assert_contains "$job" "bin/fm-failfirst.sh" "which runs bin/fm-failfirst.sh"
assert_contains "$job" "github.event_name == 'pull_request'" "on every pull request"
assert_contains "$job" "fetch-depth: 0" "with the history to find the merge-base"
assert_contains "$job" "github.base_ref" "against the pull request's base"
assert_contains "$job" "upload-artifact" "and uploads its report"
assert_contains "$job" "name: fail-first-report" "under the name the review reads it by"
ci_job="$(awk '$0 == "  ci:" { f = 1; next } f && /^  [a-zA-Z_-]+:[[:space:]]*$/ { exit } f { print }' \
  "$ROOT/.github/workflows/ci.yml")"
assert_matches "$(grep 'needs:' <<< "$ci_job")" 'fail-first' "the required ci job needs it"
assert_contains "$ci_job" "needs.fail-first.result" "and fails when it did"
assert_contains "$gha" 'fail-first' "the workflow names the job fail-first"

safe_rm_rf "$d"
finish
