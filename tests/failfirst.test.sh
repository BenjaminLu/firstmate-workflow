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

# --- workflow wiring: select the intended key, never a token in a job ----
# Read this workflow's block mappings and step lists at their exact indent,
# without requiring PyYAML. Each descent stays inside its parent's block.
# Optional input supports mutation fixtures using the very same selector.
wvalue() {
  python3 - "${workflow_file:-$ROOT/.github/workflows/ci.yml}" "$@" <<'PYWORKFLOW'
import sys

lines = open(sys.argv[1]).read().splitlines()
indent = 0
value = ""
for key in ("jobs", *sys.argv[2:]):
    found = None
    for i, line in enumerate(lines):
        if len(line) - len(line.lstrip()) != indent:
            continue
        text = line.strip()
        if key.startswith("step="):
            if not text.startswith("- "):
                continue
            field, _, scalar = text[2:].partition(":")
            if field not in ("name", "uses") or scalar.strip().strip("\"'") != key[5:]:
                continue
            value = ""
        else:
            field, sep, scalar = text.partition(":")
            if not sep or field != key:
                continue
            value = scalar.strip()
        found = i
        break
    if found is None:
        print("")
        sys.exit(0)
    end = found + 1
    while end < len(lines):
        line = lines[end]
        if line.strip() and not line.lstrip().startswith("#"):
            if len(line) - len(line.lstrip()) <= indent:
                break
        end += 1
    lines = lines[found + 1:end]
    indent += 2
if value in ("|", ">"):
    print("\n".join(line[indent:] for line in lines))
else:
    print(value)
PYWORKFLOW
}
merge_step='step=bin/fm-failfirst.sh --merge'
shard_step='step=bin/fm-failfirst.sh --shard=${{ matrix.shard }}/4'
report_step='step=upload the fail-first report'
part_step="step=upload the shard's part"
assert_eq "fail-first" "$(wvalue fail-first name)" "the workflow has the fail-first job the review reads"
assert_contains "$(wvalue fail-first steps "$merge_step" run)" "bin/fm-failfirst.sh" "which runs bin/fm-failfirst.sh"
assert_contains "$(wvalue fail-first if)" "github.event_name == 'pull_request'" "on every pull request"
assert_eq "0" "$(wvalue fail-first steps step=actions/checkout@v4 with fetch-depth)" "with the history to find the merge-base"
assert_contains "$(wvalue fail-first steps "$merge_step" run)" "github.base_ref" "against the pull request's base"
assert_contains "$(wvalue fail-first steps "$report_step" uses)" "actions/upload-artifact@" "and uploads its report"
assert_eq "fail-first-report" "$(wvalue fail-first steps "$report_step" with name)" "under the name the review reads it by"
assert_contains "$(wvalue ci needs)" 'fail-first' "the required ci job needs it"
assert_contains "$(wvalue ci steps 'step=every stage passed' run)" 'ff="${{ needs.fail-first.result }}"' "and checks its result, beyond merely echoing it"

# sharded (T-158): pin the matrix, command, environment and artifact keys.
assert_ne "" "$(wvalue fail-first-shard name)" "the workflow has a fail-first-shard job"
assert_eq "[1, 2, 3, 4]" "$(wvalue fail-first-shard strategy matrix shard)" "a matrix of 4 shards"
assert_eq "[1, 2, 3, 4]" "$(wvalue bash strategy matrix shard)" "the same count as the bash shards"
assert_contains "$(wvalue fail-first-shard steps "$shard_step" run)" '--shard="${{ matrix.shard }}/4"' "each runs its own share"
assert_contains "$(wvalue fail-first-shard steps "$shard_step" run)" "--part=" "and writes its part"
assert_eq 'fail-first-part-${{ matrix.shard }}' "$(wvalue fail-first-shard steps "$part_step" with name)" "which it uploads"
assert_eq "always()" "$(wvalue fail-first-shard steps "$part_step" if)" "whatever the shard's result"
assert_contains "$(wvalue fail-first-shard steps "$shard_step" run)" "FM_CI_TIMINGS_IN" "split by the recorded suite timings"
assert_contains "$(wvalue fail-first-shard steps "$shard_step" env FM_FF_TIMINGS)" "needs.fail-first-timings.outputs.timings" "read once for every shard, so they agree on the split"
assert_eq "github.event_name == 'pull_request'" "$(wvalue fail-first-shard if)" "on every pull request"
assert_contains "$(wvalue fail-first-timings steps 'step=previous suite timings' run)" "suite-timings-*" "from the bash shards' own timings artifacts"
assert_eq "[fail-first-shard]" "$(wvalue fail-first needs)" "the fail-first job needs the shards"
assert_eq "always() && github.event_name == 'pull_request'" "$(wvalue fail-first if)" "and runs whatever they did, so a failed shard is reported, not skipped"
assert_contains "$(wvalue fail-first steps "$merge_step" run)" "--merge=" "and merges their parts"
assert_eq "fail-first-part-*" "$(wvalue fail-first steps "step=download the shards' parts" with pattern)" "every shard's"
assert_lacks "$(wvalue fail-first steps "$merge_step" run)" "--setup" "running no suite itself"

# Keep the misleading alternative location while removing each condition.
# CI executes these fixtures; workers do not run the suite.
workflow_file="$d.workflow.yml"
python3 - "$ROOT/.github/workflows/ci.yml" "$workflow_file" <<'PYMUTATE'
import sys
text = open(sys.argv[1]).read()
text = text.replace("    if: always() && github.event_name == 'pull_request'\n", "")
open(sys.argv[2], "w").write(text)
PYMUTATE
assert_eq "" "$(wvalue fail-first if)" "removing only the merge job condition cannot match the upload condition"
assert_eq "always()" "$(wvalue fail-first steps "$report_step" if)" "the upload condition remains as a decoy"
python3 - "$ROOT/.github/workflows/ci.yml" "$workflow_file" <<'PYMUTATE'
import sys
text = open(sys.argv[1]).read()
text = text.replace("      - name: upload the shard's part\n        if: always()\n",
                    "      - name: upload the shard's part\n")
start = text.index("  fail-first-shard:")
end = text.index("  fail-first:", start)
text = text[:start] + text[start:end].replace(
    "    if: github.event_name == 'pull_request'",
    "    if: always() && github.event_name == 'pull_request'") + text[end:]
open(sys.argv[2], "w").write(text)
PYMUTATE
assert_eq "" "$(wvalue fail-first-shard steps "$part_step" if)" "removing the part upload condition cannot match a job condition"
assert_contains "$(wvalue fail-first-shard if)" "always()" "the job condition remains as a decoy"
rm -f "$workflow_file"
unset workflow_file

safe_rm_rf "$d"
# Shared project-contract coverage moved from gate.test.sh (T-157).
# --gate selects declared-docs classification and the project.check fallback;
# execution, restoration and reporting are the same fail-first engine.
contract_ff() { (cd "$1" && bash "$FF" --gate --head="$2" main) 2>&1; }
contract_fixture() {
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
# A project that is not a bash project. Its tests match none of the default
# globs and are run by nothing the engine knows - only by what config.yaml
# declares. The check can never go red, so only the test template can. The
# template needs what setup installs, so an engine that skipped setup would read
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
assert_ok "contract_ff '$py' honest 5" "5 classifies by the declared globs and runs the declared template"

git -C "$py" checkout -q -b vacuous
printf 'def add(a, b):\n    return a + b\n' > "$py/calc/calc.py"
printf 'import sys\nsys.exit(0)\n' > "$py/calc/noop_check.py"
git -C "$py" add -A; git -C "$py" commit -qm vacuous; git -C "$py" checkout -q main
assert_fail "contract_ff '$py' vacuous 5" "5 blocks a template-run test that stays green, after running setup"

git -C "$py" checkout -q -b badsetup honest
printf 'project:\n  setup: exit 9\n  check: "true"\n  tests:\n    - "**/*_check.py"\n  test: python3 {file}\n' \
  > "$py/config.yaml"
git -C "$py" commit -qam badsetup; git -C "$py" checkout -q main
assert_fail "contract_ff '$py' badsetup 5" "5 blocks when setup fails, however red the tests would be"
assert_contains "$(contract_ff "$py" badsetup 5)" "setup failed (exit 9)" "and names the failure"

# docs: the project declares which paths need no test of their own. Only
# those: undeclared exempts nothing, and code beside docs still needs a test.
doc="$(contract_fixture)"
printf '# thing\n' > "$doc/README.md"; mkdir -p "$doc/design"; printf 'v1\n' > "$doc/design/design.md"
printf '{"id":"T-X","scope":["src/**","tests/**","design/**","README.md","config.yaml"]}\n' \
  > "$doc/design/tasks/T-X.json"
# declared on main, so the branch under test changes nothing but prose
printf 'project:\n  check: bin/suite\n  docs:\n    - design/**\n    - README.md\n' > "$doc/config.yaml"
git -C "$doc" add -A; git -C "$doc" commit -qm docs-base
git -C "$doc" checkout -q -b docs-only main
printf 'v2\n' > "$doc/design/design.md"; printf '# thing, better\n' > "$doc/README.md"
git -C "$doc" commit -qam prose; git -C "$doc" checkout -q main
assert_ok "contract_ff '$doc' docs-only 5" "5 needs no test when every changed path is declared docs"

git -C "$doc" checkout -q -b docs-and-code main
printf 'v3\n' > "$doc/design/design.md"; echo more >> "$doc/src/thing.sh"
git -C "$doc" commit -qam mixed; git -C "$doc" checkout -q main
assert_fail "contract_ff '$doc' docs-and-code 5" "5 still blocks code beside docs that ships no test"
assert_contains "$(contract_ff "$doc" docs-and-code 5)" "adds or changes no test suite" "and says why"

undoc="$(contract_fixture)"
mkdir -p "$undoc/design"; printf 'v1\n' > "$undoc/design/design.md"
git -C "$undoc" add -A; git -C "$undoc" commit -qm base-design
git -C "$undoc" checkout -q -b prose main
printf 'v2\n' > "$undoc/design/design.md"; git -C "$undoc" commit -qam prose; git -C "$undoc" checkout -q main
assert_fail "contract_ff '$undoc' prose 5" "5 exempts nothing when no docs are declared"

# --- fail-first runs only the suites the diff touches (T-114) ----------------
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
  printf 'marks/\n' > "$r/.gitignore"
  git -C "$r" add -A; git -C "$r" commit -qm base
  printf '%s' "$r"
}
t5="$(touched)"
git -C "$t5" checkout -q -b honest
printf 'real\n' > "$t5/src/thing.sh"
printf 'grep -q real "${FM_ROOT:-.}/src/thing.sh"\n' > "$t5/tests/h.test.sh"
git -C "$t5" add -A; git -C "$t5" commit -qm honest; git -C "$t5" checkout -q main
out="$(contract_ff "$t5" honest 5)"; rc=$?
assert_eq "0" "$rc" "5 passes a touched suite that goes red with the implementation reverted"
assert_fail "test -e '$t5/marks/check'" "and never runs the whole project.check to find out"
assert_fail "test -e '$t5/marks/other'" "nor a suite the diff does not touch"
assert_contains "$out" "running the suites the diff touches: tests/h.test.sh" "and says which suites it ran"

git -C "$t5" checkout -q -b vacuous main
printf 'real\n' > "$t5/src/thing.sh"
printf 'true\n' > "$t5/tests/v.test.sh"
git -C "$t5" add -A; git -C "$t5" commit -qm vacuous; git -C "$t5" checkout -q main
assert_fail "contract_ff '$t5' vacuous 5" "5 still blocks a touched suite that stays green"
assert_fail "test -e '$t5/marks/check'" "without falling back to the whole check"

# The diff changes a helper and no suite: the helper, run on its own, asserts
# nothing, and the suite that sources it is the one the diff touches.
git -C "$t5" checkout -q -b helper main
printf 'real\n' > "$t5/src/thing.sh"
printf 'verify() { grep -q real "${FM_ROOT:-.}/src/thing.sh"; }\n' > "$t5/tests/helper.sh"
git -C "$t5" commit -qam helper; git -C "$t5" checkout -q main
out="$(contract_ff "$t5" helper 5)"; rc=$?
assert_eq "0" "$rc" "5 runs the suites that exercise a changed test file, and they go red"
assert_contains "$out" "tests/uses.test.sh" "and names the suite it found that way"
assert_fail "test -e '$t5/marks/other'" "and still not the suite that names no changed file"
assert_fail "test -e '$t5/marks/near'" "nor one that names fm-helper.sh, which only has helper.sh inside it"
assert_fail "test -e '$t5/marks/check'" "nor the whole check"

# check_env reaches the suites, and is the only way a budget or a flag does:
# the engine carries no variable of its own for any one project's suite.
git -C "$t5" checkout -q -b budget honest
printf 'project:\n  check: "true"\n  test: bash {file}\n  check_env:\n    SUITE_BUDGET: 600\n    SUITE_MODE: "full run"\n' > "$t5/config.yaml"
printf '[ "${SUITE_BUDGET:-180}" -ge 300 ] && [ "$SUITE_MODE" = "full run" ] || exit 0\ngrep -q real "${FM_ROOT:-.}/src/thing.sh"\n' \
  > "$t5/tests/h.test.sh"
git -C "$t5" commit -qam budget; git -C "$t5" checkout -q main
assert_ok "contract_ff '$t5' budget 5" \
  "5 hands check_env to the suites it runs"

# no `test` to run one suite with: the whole check is the only way to ask, and
# the engine says that is what it did
rm -f "$t5/marks/check"
git -C "$t5" checkout -q -b nosuite honest
printf 'project:\n  check: touch %q/marks/check && grep -q real src/thing.sh\n' "$t5" > "$t5/config.yaml"
git -C "$t5" commit -qam nosuite; git -C "$t5" checkout -q main
out="$(contract_ff "$t5" nosuite 5)"; rc=$?
assert_eq "0" "$rc" "5 with no declared test falls back to the whole check, which goes red"
assert_ok "test -e '$t5/marks/check'" "and the whole check is what ran"
assert_contains "$out" "declares no project.test to run one suite with, so the whole project.check runs" \
  "and it says so"


# A deleted test is still a changed test, but there is no suite left to run.
git -C "$t5" checkout -q -b deleted honest
printf 'project:\n  check: grep -q newer src/thing.sh\n  test: bash {file}\n' > "$t5/config.yaml"
printf 'newer\n' > "$t5/src/thing.sh"
git -C "$t5" rm -q tests/h.test.sh
git -C "$t5" add -A; git -C "$t5" commit -qm deleted
# Compare with honest, where the deleted test exists and implementation is old.
out="$(cd "$t5" && bash "$FF" --gate --head=deleted honest 2>&1)"; rc=$?
assert_eq "0" "$rc" "a deleted test falls back to the check, which goes red on base"
assert_contains "$out" "no suite the diff touches is left in the tree" "the deletion fallback is explicit"
git -C "$t5" checkout -q main

for tree in "$py" "$doc" "$undoc" "$t5"; do safe_rm_rf "$tree"; done
finish
