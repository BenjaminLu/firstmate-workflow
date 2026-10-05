#!/usr/bin/env bash
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=tests/lib/ci.sh
. "$ROOT/tests/lib/ci.sh"
gha="$ROOT/.github/workflows/ci.yml"
# --- the workflow: separate jobs behind one required `ci` check -----------
wf="$(cat "$gha")"
assert_contains "$wf" "--stage fast" "the workflow runs the fast checks as their own job"
assert_contains "$wf" "--stage bash" "and the bash suites as their own job(s)"
assert_contains "$wf" "--shard" "sharded across more than one"
assert_contains "$wf" "--stage bun" "and the bun tests as their own job"
assert_contains "$wf" "--stage e2e" "and playwright as their own job"
assert_matches "$wf" 'ci:[[:space:]]*$' "a final job is named ci, the required check's own name"
assert_contains "$wf" "needs:" "and it needs the others"
assert_matches "$wf" 'timeout-minutes:[[:space:]]*10' "every job keeps the 10-minute limit"

# Sharding turned the one `bun install` main had into several - one per bash
# shard, plus bun and e2e - and each pays the registry fetch again unless
# cached. So every job that installs must cache bun's install cache first,
# keyed on bun.lock, not merely have the string "actions/cache" appear
# somewhere in the file (the browser cache alone made that true before any
# bun cache existed). A job is its own block: from its "  <name>:" line to
# the next line at that same two-space indent.
job_block() {
  awk -v want="  $1:" '
    $0 == want { f = 1; next }
    f && /^  [a-zA-Z_-]+:[[:space:]]*$/ { exit }
    f { print }
  ' "${workflow_file:-$gha}"
}
# Restrict a pin to one step, so other steps cannot supply its evidence.
step_block() {
  awk -v want="$2" '
    /^      - / { if (f) exit; if (index($0, want)) f = 1 }
    f { print }
  ' <<< "$(job_block "$1")"
}
job_names="$(awk '
  /^jobs:[[:space:]]*$/ { f = 1; next }
  f && /^  [a-zA-Z_-]+:[[:space:]]*$/ { line = $0; sub(/^  /, "", line); sub(/:.*$/, "", line); print line }
' "$gha")"
assert_ne "" "$job_names" "the workflow has jobs to check"
uncached=''
for j in $job_names; do
  block="$(job_block "$j")"
  grep -q "bun install" <<< "$block" || continue
  install_line="$(printf '%s\n' "$block" | grep -n "bun install" | head -1 | cut -d: -f1)"
  cache_line="$(printf '%s\n' "$block" | grep -n "actions/cache" | head -1 | cut -d: -f1)"
  key_line="$(printf '%s\n' "$block" | grep -n "bun\.lock" | head -1 | cut -d: -f1)"
  if [ -z "$cache_line" ] || [ -z "$key_line" ] || [ "$cache_line" -ge "$install_line" ]; then
    uncached="$uncached $j"
  fi
done
assert_eq "" "$uncached" "every job that runs bun install caches bun's install cache first, keyed on bun.lock"

e2e_block="$(job_block e2e)"
assert_contains "$e2e_block" "ms-playwright" "the e2e job also caches the playwright browser"

# T-196: one timings read, assignment artifacts, and coverage on the run ref.
timing_block="$(job_block bash-timings)"
assert_contains "$timing_block" 'name: bash timings' "bash timings is its own job"
assert_lacks "$timing_block" 'if:' "bash timings runs on every event"
assert_contains "$timing_block" 'timeout-minutes: 10' "bash timings has a ten-minute bound"
assert_contains "$(step_block bash-timings 'name: previous suite timings')" 'suite-timings-*' "the single read requests suite timing artifacts"
assert_contains "$timing_block" 'timings<<FM_TIMINGS_END' "timings use a delimited job output"
assert_contains "$timing_block" "grep -v '^FM_TIMINGS_END$'" "the output delimiter cannot occur in its data"
bash_block="$(job_block bash)"
assert_contains "$bash_block" 'needs: [bash-timings]' "every bash shard waits for the one timings read"
assert_contains "$bash_block" 'needs.bash-timings.outputs.timings' "all bash shards receive the same timings"
assert_contains "$bash_block" 'FM_CI_ASSIGNED_OUT: /tmp/suite-assigned/suite-assigned-${{ matrix.shard }}.txt' "each shard writes a distinct assignment"
assignment_step="$(step_block bash 'name: upload suite assignment')"
assert_contains "$assignment_step" 'if: always()' "failed shards also upload their assignment"
assert_contains "$assignment_step" 'name: suite-assigned-${{ matrix.shard }}' "assignment artifacts are distinct"
assert_contains "$assignment_step" 'if-no-files-found: ignore' "coverage judges absent assignments"
# These predicates are used both on the real workflow and on mutations.
single_timings_read() { ! grep -q 'gh run download' <<< "$(job_block bash)"; }
checkout_uses_run_ref() { ! grep -qE '^[[:space:]]+ref:' <<< "$(step_block ci 'uses: actions/checkout@v4')"; }
rc=0; single_timings_read || rc=$?
assert_eq "0" "$rc" "bash job cannot independently download changing timings"
ci_block="$(job_block ci)"
checkout_step="$(step_block ci 'uses: actions/checkout@v4')"
assert_contains "$checkout_step" 'sparse-checkout:' "coverage checks out its suite inventory"
assert_matches "$checkout_step" '^[[:space:]]+bin$' "coverage checks out the CI implementation"
assert_matches "$checkout_step" '^[[:space:]]+tests$' "coverage checks out the run tree tests"
rc=0; checkout_uses_run_ref || rc=$?
assert_eq "0" "$rc" "coverage checkout keeps the same default run ref as bash shards"
assert_contains "$ci_block" 'pattern: suite-assigned-*' "coverage downloads all assignments"
assert_contains "$ci_block" 'merge-multiple: true' "assignment files share one directory"
coverage_step="$(step_block ci 'name: every suite ran once')"
assert_contains "$coverage_step" 'bin/ci.sh --coverage /tmp/suite-assigned' "required ci checks exact suite coverage"
assert_lacks "$coverage_step" 'github.event_name' "coverage runs on pushes and pull requests"
assert_lacks "$coverage_step" 'continue-on-error:' "coverage failure fails the required check"

mutation_dir="$(safe_tmpdir)"
workflow_file="$mutation_dir/download.yml"
python3 - "$gha" "$workflow_file" <<'PYMUTATE'
import sys
text = open(sys.argv[1]).read()
start = text.index("  bash:\n")
end = text.index("  bun:\n", start)
block = text[start:end].replace("    steps:\n", "    steps:\n      - run: gh run download latest\n", 1)
open(sys.argv[2], "w").write(text[:start] + block + text[end:])
PYMUTATE
rc=0; single_timings_read || rc=$?
assert_eq "1" "$rc" "single-read pin rejects a download reintroduced only in the bash job"
workflow_file="$mutation_dir/ref.yml"
python3 - "$gha" "$workflow_file" <<'PYMUTATE'
import sys
text = open(sys.argv[1]).read()
start = text.index("  ci:\n")
block = text[start:].replace("        with:\n", "        with:\n          ref: ${{ github.event.pull_request.head.sha }}\n", 1)
open(sys.argv[2], "w").write(text[:start] + block)
PYMUTATE
rc=0; checkout_uses_run_ref || rc=$?
assert_eq "1" "$rc" "run-ref pin rejects a head override only in the final ci checkout"
unset workflow_file
safe_rm_rf "$mutation_dir"

# Every script parses. A `'` in a comment inside a single-quoted program
# (pipe_awk's `grep's`, T-103 round 7) ends the string early, and bash only
# finds out when it reaches that line: ci.sh died mid-stage, and every plant
# above went red for a reason none of them names.
unparsed=''
while IFS= read -r f; do
  bash -n "$f" 2>/dev/null || unparsed="$unparsed $f"
done < <(find "$ROOT/bin" "$ROOT/tests" -type f -name '*.sh')
assert_eq "" "$unparsed" "every script below bin/ and tests/ parses (bash -n)"

PATH="$suite_original_path"; export PATH
safe_rm_rf "$suite_tools"
finish
