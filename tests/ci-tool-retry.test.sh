#!/usr/bin/env bash
# ci: retry only tool errors (T-306). The design-capture step in CI runs
# through bin/lib/fm-tool-retry.sh: a browser protocol error is retried
# once, by name, and an assertion failure, any other failure, and a second
# tool error are not.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=tests/lib.sh
. "$ROOT/tests/lib.sh"
t="$(safe_tmpdir)"
trap 'safe_rm_rf "$t"' EXIT
retry="$ROOT/bin/lib/fm-tool-retry.sh"
# A stand-in step: attempt N prints and exits what line N of its script says.
cat > "$t/step.sh" <<'STEP'
#!/usr/bin/env bash
n=$(( $(cat "$STEP_COUNT" 2>/dev/null || echo 0) + 1 ))
echo "$n" > "$STEP_COUNT"
line="$(sed -n "${n}p" "$STEP_SCRIPT")"
printf '%s\n' "${line#* }"
exit "${line%% *}"
STEP
run_step() {   # run_step <attempt lines...>: sets out, rc, attempts
  printf '%s\n' "$@" > "$t/script"
  rm -f "$t/count"
  rc=0
  out="$(STEP_COUNT="$t/count" STEP_SCRIPT="$t/script" bash "$retry" 'design capture' -- bash "$t/step.sh" 2>&1)" || rc=$?
  attempts="$(cat "$t/count" 2>/dev/null || echo 0)"
}
protocol='1 fm-design: capture failed: the capture tool exited 1: Error: Protocol error (Page.captureScreenshot): Unable to capture screenshot'

run_step "$protocol" '0 captured 6 viewports on 1 pages'
assert_eq "0" "$rc" "ci: retry only tool errors: a browser protocol error is retried and the retry passes"
assert_eq "2" "$attempts" "ci: retry only tool errors: the protocol error ran the step twice"
assert_contains "$out" "fm-tool-retry: retrying design capture once after a browser tool error: " \
  "ci: retry only tool errors: the retry is logged by the step's name"
assert_contains "$out" "Protocol error (Page.captureScreenshot)" "and with the error that caused it"

run_step "$protocol" "$protocol" '0 a third attempt never runs'
assert_eq "1" "$rc" "ci: retry only tool errors: a second protocol error fails the step"
assert_eq "2" "$attempts" "ci: retry only tool errors: the tool error is retried once, not twice"
assert_contains "$out" "design capture failed again after its one retry (exit 1)" "and says the retry failed"

run_step '1 fm-design: capture failed: 1 of 6 screenshots are missing, first index-390-light.png' '0 not reached'
assert_eq "1" "$rc" "ci: retry only tool errors: an assertion failure fails the step"
assert_eq "1" "$attempts" "ci: retry only tool errors: an assertion failure is not retried"
assert_lacks "$out" "retrying" "and no retry is logged"

run_step '1 AssertionError: Protocol error (Page.captureScreenshot) was expected to be absent' '0 not reached'
assert_eq "1" "$attempts" "ci: retry only tool errors: an assertion beside a protocol error is not retried"
assert_eq "1" "$rc" "and its failure stands"

run_step '3 fm-design: the spec has no id' '0 not reached'
assert_eq "3" "$rc" "ci: retry only tool errors: any other failure keeps its own exit"
assert_eq "1" "$attempts" "ci: retry only tool errors: and is not retried"

run_step '0 captured 6 viewports on 1 pages'
assert_eq "0" "$rc" "a passing step passes"
assert_eq "1" "$attempts" "and runs once"
assert_contains "$out" "captured 6 viewports" "and its output is shown"

rc=0; out="$(bash "$retry" 'design capture' 2>&1)" || rc=$?
assert_eq "64" "$rc" "a step with no command is a usage error"
rc=0; out="$(bash "$retry" 'design capture' -- 2>&1)" || rc=$?
assert_eq "64" "$rc" "a step with -- and no command is a usage error"
rc=0; out="$(bash "$retry" 'design capture' echo hi 2>&1)" || rc=$?
assert_eq "64" "$rc" "a step without -- is a usage error"
rc=0; out="$(bash "$retry" '' -- echo hi 2>&1)" || rc=$?
assert_eq "64" "$rc" "a step with no name is a usage error"
assert_contains "$out" "usage: fm-tool-retry.sh <name> -- <command...>" "and prints the usage line"

# The workflow's design-capture step runs through the wrapper, by name, and
# the Playwright suites keep no retries of their own.
gha="$ROOT/.github/workflows/ci.yml"
capture_step="$(awk '/name: the designer.s page capture renders a page/ {f = 1} f && /^      - name: bin\/ci.sh --stage e2e/ {f = 0} f' "$gha")"
assert_contains "$capture_step" "bash bin/lib/fm-tool-retry.sh 'design capture' -- python3 bin/lib/fm_design.py capture" \
  "ci: retry only tool errors: the CI design-capture step runs through the retry"
assert_contains "$(cat "$ROOT/playwright.config.ts")" "retries: 0," "the Playwright suites are not retried"
finish
