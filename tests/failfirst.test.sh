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
assert_contains "$out" "re-run beside the base, on the same runner" "and says the head was re-run here, not read from CI"
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

# --- sharded (T-158): 4 shards, each its share on head and base, one merge ---
# Six behaviour files, each with its suite; the suites differ in size, so
# the split has something to balance. Suite 3 asserts only a guard.
sh_fixture() {
  local d k; d="$(fixture)"
  for k in 1 2 3 4 5 6; do
    printf '#!/usr/bin/env bash\necho new\n' > "$d/bin/t$k.sh"
    { printf '. tests/lib.sh\n'
      if [ "$k" = 3 ]; then printf 'check "t3 lib loads" 1 "$([ -f tests/lib.sh ] && echo 1)"\n'
      else printf 'check "t%s says new" new "$(bash bin/t%s.sh)"\n' "$k" "$k"; fi
      for _ in $(seq 1 $((k * 5))); do printf '# padding\n'; done
      printf 'exit "$fails"\n'
    } > "$d/tests/t$k.test.sh"
  done
  commit "$d"
  printf '%s' "$d"
}
part_list() {   # part_list <part.json> <key>: the part's list <key>, one per line
  python3 -c 'import json,sys; print("\n".join(json.load(open(sys.argv[1]))[sys.argv[2]]))' "$1" "$2" 2>/dev/null
}
d="$(sh_fixture)"
single="$(ff "$d")"; single_rc=$?
mkdir -p "$d.parts"
covered=''
for i in 1 2 3 4; do
  out="$( cd "$d" && bash "$FF" --shard="$i/4" --part="$d.parts/part-$i.json" main 2>"$d.err" )"; rc=$?
  assert_eq "0" "$rc" "shard $i/4 runs its share and succeeds"
  assert_ok "test -s '$d.parts/part-$i.json'" "and writes its part"
  assert_contains "$(cat "$d.err")" "shard $i/4: " "and says what it takes, and what it is predicted to take"
  covered="$covered$(part_list "$d.parts/part-$i.json" planned)
"
  for s in $(part_list "$d.parts/part-$i.json" planned); do
    assert_contains "$out" "\`$s\`" "shard $i/4 names $s among the suites it ran"
  done
  assert_lacks "$out" "## Fail-first:" "a shard decides no verdict: that is the merge's"
done
want="$(cd "$d" && git diff --name-only main -- tests | sort)"
assert_eq "$want" "$(printf '%s' "$covered" | sed '/^$/d' | sort)" "the 4 shards cover every changed suite"
assert_eq "" "$(printf '%s' "$covered" | sed '/^$/d' | sort | uniq -d)" "and none twice"
most="$(for i in 1 2 3 4; do part_list "$d.parts/part-$i.json" planned | awk 'NF { n++ } END { print n + 0 }'; done | sort -n | tail -1)"
assert_ok "[ '${most:-6}' -lt 6 ]" "the split is not all six in one shard (the fullest has ${most:-?})"
merged="$( cd "$d" && bash "$FF" --merge="$d.parts" --report "$d.merged" main 2>"$d.err" )"; rc=$?
assert_eq "$single_rc" "$rc" "the merge exits as the single job does"
assert_eq "0" "$rc" "which is a pass here"
assert_eq "$single" "$merged" "the merged report is the single job's report for the same change"
assert_eq "$merged" "$(cat "$d.merged" 2>/dev/null)" "and --report holds it"
assert_contains "$(awk '/^Guard, green on base too/{f=1;next} /^$/{f=0} f' <<< "$merged")" '`t3 lib loads`' "with the guard of the suite that stayed green"
: > "$d.summary"
( cd "$d" && GITHUB_STEP_SUMMARY="$d.summary" bash "$FF" --merge="$d.parts" main ) >/dev/null 2>&1
assert_contains "$(cat "$d.summary")" "## Fail-first: pass" "and \$GITHUB_STEP_SUMMARY gets the merged report"
assert_eq "1" "$(git -C "$d" worktree list | wc -l | tr -d ' ')" "no shard leaves a worktree behind"

# a shard that sent nothing fails the merge, naming each suite it had
lost="$(part_list "$d.parts/part-2.json" planned)"
assert_ne "" "$lost" "(shard 2/4 has suites to lose)"
mv "$d.parts/part-2.json" "$d.part-2.json"
out="$( cd "$d" && bash "$FF" --merge="$d.parts" main 2>/dev/null )"; rc=$?
assert_eq "1" "$rc" "a shard that sent no part fails the merge"
assert_contains "$out" "## Fail-first: fail" "and the report says so"
for s in $lost; do
  assert_contains "$out" "\`$s\`" "naming $s, which it had"
done
assert_contains "$out" "no report came from shard 2/4" "and the shard that sent nothing"
mv "$d.part-2.json" "$d.parts/part-2.json"

# a shard that could not run says so in its part, and the merge names it
out="$( cd "$d" && bash "$FF" --shard=3/4 --part="$d.parts/part-3.json" --setup 'exit 9' main 2>"$d.err" )"; rc=$?
assert_eq "70" "$rc" "a shard whose setup fails could not run"
failed="$(part_list "$d.parts/part-3.json" planned)"
assert_ne "" "$failed" "and its part still names the suites it was given"
out="$( cd "$d" && bash "$FF" --merge="$d.parts" main 2>/dev/null )"; rc=$?
assert_eq "1" "$rc" "a shard's failure fails the merge"
for s in $failed; do
  assert_contains "$out" "\`$s\`" "naming its suite $s"
done
assert_contains "$out" "shard 3/4 could not run it: setup failed" "and why"

# no part at all is a fail too, not an empty pass
mkdir -p "$d.none"
out="$( cd "$d" && bash "$FF" --merge="$d.none" main 2>/dev/null )"; rc=$?
assert_eq "1" "$rc" "a merge with no part fails"
assert_contains "$out" "no fail-first shard sent a report" "and says why"

# a part for another head is not this head's result
python3 -c 'import json,sys; p=json.load(open(sys.argv[1])); p["head"]="0"*40; json.dump(p,open(sys.argv[1],"w"))' \
  "$d.parts/part-1.json"
out="$( cd "$d" && bash "$FF" --merge="$d.parts" main 2>/dev/null )"; rc=$?
assert_eq "1" "$rc" "a part for another head is not counted"
assert_contains "$out" "reported another head or base" "and the report says it was ignored"
safe_rm_rf "$d.parts" "$d.none"

# a shard with no changed suite of its own is not applicable, and sets up nothing
d2="$(fixture)"
printf '#!/usr/bin/env bash\necho new\n' > "$d2/bin/tool.sh"
printf '. tests/lib.sh\ncheck "new" new "$(bash bin/tool.sh)"\nexit "$fails"\n' > "$d2/tests/tool.test.sh"
commit "$d2"
empty=0
for i in 1 2 3 4; do
  ( cd "$d2" && bash "$FF" --shard="$i/4" --part="$d2.part-$i.json" --setup 'exit 9' main ) >/dev/null 2>"$d2.err"; rc=$?
  if [ -z "$(part_list "$d2.part-$i.json" planned)" ]; then
    empty=$((empty + 1))
    assert_eq "0" "$rc" "shard $i/4, with none of the one changed suite, succeeds at once, running no setup"
    assert_contains "$(cat "$d2.err")" "not applicable" "and says it is not applicable"
  fi
done
assert_eq "3" "$empty" "one changed suite leaves three shards with none"

# a change that is not applicable is so in every shard, and in the merge
d3="$(fixture)"
echo '# more' >> "$d3/design/notes.md"
commit "$d3"
mkdir -p "$d3.parts"
for i in 1 2 3 4; do
  ( cd "$d3" && bash "$FF" --shard="$i/4" --part="$d3.parts/p$i.json" main ) >/dev/null 2>&1
  assert_eq "0" "$?" "a docs-only change: shard $i/4 has nothing to run"
done
out="$( cd "$d3" && bash "$FF" --merge="$d3.parts" main 2>/dev/null )"; rc=$?
assert_eq "0" "$rc" "and the merge is not a failure"
assert_eq "$(ff "$d3")" "$out" "and says what the single job says: not applicable"
safe_rm_rf "$d2" "$d3" "$d3.parts"

# The bar on T-121's change (#107), the one the single job ran out of time
# on: its 18 changed test files, split on main's recorded suite timings
# (tests/ci.test.sh's, from run 36511784453) by 4 shards of 4 runs at once,
# as ubuntu-latest's 4 CPUs give. No shard is predicted over the bash
# shards' longest.
d="$(fixture)"
printf 'project:\n  tests:\n    - tests/**\n  test: ": {file}"\n' > "$d/config.yaml"
tin="$(safe_tmpdir)/main-timings.txt"
cat > "$tin" <<'TIMINGS'
tests/cleanup.test.sh 0
tests/lib.test.sh 0
tests/protocol.test.sh 0
tests/skills.test.sh 0
tests/guard.test.sh 1
tests/i18n.test.sh 1
tests/traps.test.sh 1
tests/emit.test.sh 2
tests/open.test.sh 2
tests/decisions.test.sh 3
tests/pipefail-grep.test.sh 3
tests/sync-prs.test.sh 3
tests/option-loop.test.sh 4
tests/ready.test.sh 5
tests/diagram.test.sh 8
tests/merge.test.sh 8
tests/session.test.sh 8
tests/crew-end-to-end.test.sh 11
tests/config.test.sh 14
tests/project.test.sh 16
tests/dispatch.test.sh 20
tests/selfupdate.test.sh 23
tests/e2e-loop.test.sh 25
tests/sandbox.test.sh 27
tests/board.test.sh 36
tests/gate.test.sh 37
tests/decide.test.sh 38
tests/canary.test.sh 56
tests/adapter-contract.test.sh 89
tests/reconcile.test.sh 110
tests/review.test.sh 128
tests/ci.test.sh 197
tests/herdr.test.sh 278
tests/worker.test.sh 539
TIMINGS
while read -r p _; do printf '#!/usr/bin/env bash\nexit 0\n' > "$d/$p"; done < "$tin"
git -C "$d" add -A; git -C "$d" commit -qm timings; git -C "$d" branch -qf main HEAD
printf '#!/usr/bin/env bash\necho new\n' > "$d/bin/tool.sh"
for p in adapter-contract board config herdr option-loop review sandbox worker auth-probe doctor setup; do
  echo '# changed' >> "$d/tests/$p.test.sh"
done
mkdir -p "$d/tests/fixtures/auth-status"
for f in claude-signed-in claude-signed-out codex-signed-in codex-signed-out cursor-agent-signed-in cursor-agent-signed-out; do
  echo x > "$d/tests/fixtures/auth-status/$f.txt"
done
echo x > "$d/tests/fixtures/auth-status/replay.sh"
commit "$d"
assert_eq "18" "$(git -C "$d" diff --name-only main -- tests | awk 'NF { n++ } END { print n + 0 }')" "T-121's shape: 18 changed test files"
covered=''
for i in 1 2 3 4; do
  ( cd "$d" && FM_CI_TIMINGS_IN="$tin" bash "$FF" --jobs 4 --shard="$i/4" --part="$d.p$i.json" main ) >/dev/null 2>"$d.err"
  assert_eq "0" "$?" "T-121 on main's timings: shard $i/4 runs"
  said="$(grep -E "shard $i/4: " "$d.err" || true)"
  assert_contains "$said" "the bash shards' longest is predicted 539.0s" "shard $i/4 compares itself with the bash shards' longest"
  assert_contains "$said" ": within it" "and is not predicted over it"
  covered="$covered$(part_list "$d.p$i.json" planned)
"
done
assert_eq "tests/worker.test.sh" "$(part_list "$d.p1.json" planned)" \
  "the 539-second suite has a shard of its own"
assert_eq "$(git -C "$d" diff --name-only main -- tests | sort)" "$(printf '%s' "$covered" | sed '/^$/d' | sort)" \
  "and the 4 shards cover each of the 18 exactly once"
safe_rm_rf "$d"

# --- usage ---------------------------------------------------------------------
d="$(fixture)"
( cd "$d" && bash "$FF" --shard=1/4 main ) >/dev/null 2>&1
assert_eq "64" "$?" "a shard with nowhere to write its part is a usage error"
( cd "$d" && bash "$FF" --shard 1/4 --part=x main ) >/dev/null 2>&1
assert_eq "64" "$?" "--shard takes its value after =, not as the next word"
for bad in 0/4 5/4 x 1/0 1/; do
  ( cd "$d" && bash "$FF" --shard="$bad" --part=x main ) >/dev/null 2>&1
  assert_eq "64" "$?" "--shard=$bad is refused"
done
( cd "$d" && bash "$FF" --part=x main ) >/dev/null 2>&1
assert_eq "64" "$?" "--part without --shard is refused"
( cd "$d" && bash "$FF" --shard=1/4 --part=x --report y main ) >/dev/null 2>&1
assert_eq "64" "$?" "a shard writes no report: that is the merge's"
( cd "$d" && bash "$FF" --merge="$d.nowhere" main ) >/dev/null 2>&1
assert_eq "64" "$?" "--merge of a directory that is not there is refused"
( cd "$d" && bash "$FF" --merge="$d" --shard=1/4 --part=x main ) >/dev/null 2>&1
assert_eq "64" "$?" "and --merge runs nothing, so takes no --shard"
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

# sharded (T-158): 4 shards, the bash shards' count, and the merge is the
# `fail-first` job the review reads and the required ci needs
wjob() { awk -v want="  $1:" '$0 == want { f = 1; next } f && /^  [a-zA-Z_-]+:[[:space:]]*$/ { exit } f { print }' \
  "$ROOT/.github/workflows/ci.yml"; }
shards="$(wjob fail-first-shard)"
assert_ne "" "$shards" "the workflow has a fail-first-shard job"
assert_contains "$shards" "shard: [1, 2, 3, 4]" "a matrix of 4 shards"
assert_contains "$(wjob bash)" "shard: [1, 2, 3, 4]" "the same count as the bash shards"
assert_contains "$shards" '--shard="${{ matrix.shard }}/4"' "each runs its own share"
assert_contains "$shards" "--part=" "and writes its part"
assert_contains "$shards" "name: fail-first-part-" "which it uploads"
assert_contains "$shards" "if: always()" "whatever the shard's result"
assert_contains "$shards" "FM_CI_TIMINGS_IN" "split by the recorded suite timings"
assert_contains "$shards" "needs.fail-first-timings.outputs.timings" "read once for every shard, so they agree on the split"
assert_contains "$shards" "github.event_name == 'pull_request'" "on every pull request"
assert_contains "$(wjob fail-first-timings)" "suite-timings-*" "from the bash shards' own timings artifacts"
assert_matches "$(grep 'needs:' <<< "$job")" 'fail-first-shard' "the fail-first job needs the shards"
assert_contains "$job" "always()" "and runs whatever they did, so a failed shard is reported, not skipped"
assert_contains "$job" "--merge=" "and merges their parts"
assert_contains "$job" "pattern: fail-first-part-*" "every shard's"
assert_lacks "$job" "--setup" "running no suite itself"

safe_rm_rf "$d"
finish
