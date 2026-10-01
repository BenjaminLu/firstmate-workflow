#!/usr/bin/env bash
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=tests/lib/ci.sh
. "$ROOT/tests/lib/ci.sh"
# Budget probes run the real gate against a tiny tree with a deterministic
# two-reading clock. No sleep and no full repository CI run is needed.
budget_tree="$(fixture)"
clock_dir="$(safe_tmpdir)"
cat > "$clock_dir/date" <<'CLOCK'
#!/usr/bin/env bash
if [ -f "$FM_TEST_CLOCK_STATE" ]; then
  printf '%s\n' "$((1000 + FM_TEST_ELAPSED))"
else
  touch "$FM_TEST_CLOCK_STATE"
  printf '1000\n'
fi
CLOCK
chmod +x "$clock_dir/date"
budget_probe() { # <unset|budget> <elapsed> <expected exit>
  local supplied="$1" elapsed="$2" expected="$3" rc=0
  rm -f "$clock_dir/state"
  out="$(
    if [ "$supplied" = unset ]; then unset FM_CI_MAX_SECONDS
    else export FM_CI_MAX_SECONDS="$supplied"; fi
    PATH="$clock_dir:$PATH" FM_TEST_CLOCK_STATE="$clock_dir/state" \
      FM_TEST_ELAPSED="$elapsed" FM_ROOT="$budget_tree" bash "$ROOT/bin/ci.sh" 2>&1
  )" || rc=$?
  assert_eq "$expected" "$rc" "budget [$supplied], elapsed ${elapsed}s: exit $expected"
}
for budget in unset 600; do
  limit=180; [ "$budget" != unset ] && limit="$budget"
  for elapsed in "$((limit - 1))" "$limit"; do
    budget_probe "$budget" "$elapsed" 0
    assert_contains "$out" "took ${elapsed}s" "reports deterministic elapsed time"
    assert_contains "$out" "effective budget: ${limit}s" "reports the selected budget"
  done
  budget_probe "$budget" "$((limit + 1))" 1
  assert_contains "$out" "exceeds effective budget of ${limit}s" "budget excess explains failure"
done
budget_probe unset 208 1
budget_probe 600 208 0
for budget in 1 3600; do budget_probe "$budget" "$budget" 0; done
for budget in '' 0 -1 +600 0600 1.5 ' 600' '600 ' 1e3 3601 999999999999999999999999 '1+1' '$(touch injected)' $'600\n'; do
  budget_probe "$budget" 0 64
  assert_contains "$out" 'FM_CI_MAX_SECONDS must be a decimal integer from 1 to 3600 (no leading zeros); unset it for 180' \
    "invalid budget gives actionable guidance"
  assert_lacks "$out" '== shellcheck' "invalid budget stops before checks"
done
printf '#!/usr/bin/env bash\nexit 1\n' > "$budget_tree/tests/red.test.sh"
budget_probe 600 208 1
assert_contains "$out" 'x tests/red.test.sh' "functional failure still fails under 600"
assert_contains "$out" 'effective budget: 600s' "failed run also reports its budget"
rm -rf "$budget_tree" "$clock_dir"

# FM_ROOT="" (set, but empty) must not fall back to the tree this script
# lives in: that is exactly the fixture bug that let tests/ci.test.sh's own
# fixture() run the whole gate against the real repository, recursively,
# from inside a live review round (T-123, round 5).
rc=0; out="$(FM_ROOT="" bash "$ROOT/bin/ci.sh" 2>&1)" || rc=$?
assert_eq "64" "$rc" "FM_ROOT set but empty is refused, not read as unset"
assert_contains "$out" "FM_ROOT is set but empty" "and says so"

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

# --- containment (T-151) --------------------------------------------------
# A suite that leaves a process behind is red, and the process is killed:
# every suite runs with a scope marker in its environment, inherited across
# setsid, and whatever still carries it when the suite ends is named. The
# leak here is the shape that left 192 watchers running for a day: started
# in a session of its own, by a suite that never stopped it.
t="$(fixture)"
leaked="$(safe_tmpdir)"
printf '%s\n' '#!/usr/bin/env bash' \
  "python3 -c 'import subprocess, sys; p = subprocess.Popen([sys.executable, \"-c\", \"import time; time.sleep(120)\"], start_new_session=True); open(sys.argv[1], \"w\").write(str(p.pid))' '$leaked/pid'" \
  'exit 0' > "$t/tests/leaky.test.sh"
printf '%s\n' '#!/usr/bin/env bash' \
  "printf '%s\\n' \"\${FM_SESSION_PID-}\" > '$leaked/session'" \
  'exit 0' > "$t/tests/tidy.test.sh"
# Most suites scrub FM_* before they start, FM_SESSION_PID with it, and
# then start rounds whose owner is "the session" (T-151 review round 2).
# The gate's runner must still be the one they resolve, not an ancestor
# above the gate - on a developer's machine, the operator's own harness.
printf '%s\n' '#!/usr/bin/env bash' \
  "printf '%s\\n' \"\${FM_SESSION_PID-}\" > '$leaked/given'" \
  'for k in $(compgen -e | grep "^FM_"); do unset "$k"; done' \
  "python3 '$ROOT/bin/lib/fm_lifeline.py' session-owner > '$leaked/resolved' 2>&1" \
  'exit 0' > "$t/tests/scrubbed.test.sh"
rc=0; out="$(FM_ROOT="$t" bash "$ROOT/bin/ci.sh" --stage bash 2>&1)" || rc=$?
assert_eq "1" "$rc" "a suite that leaves a process running is red, though it exited 0"
assert_contains "$out" "tests/leaky.test.sh left processes running after it ended (killed now):" \
  "and the gate says which suite left it"
lp="$(cat "$leaked/pid" 2>/dev/null)"
assert_contains "$out" "$lp" "naming the process it left"
assert_fail "kill -0 '${lp:-0}'" "which is no longer running"
assert_lacks "$out" "tests/tidy.test.sh left" "a suite that leaves nothing is not named"
assert_matches "$(cat "$leaked/session" 2>/dev/null)" '^[1-9][0-9]*$' \
  "every suite is handed a session of the gate's own, never the operator's"
assert_matches "$(cat "$leaked/given" 2>/dev/null)" '^[1-9][0-9]*$' "the scrubbing suite was handed one too"
assert_eq "$(cat "$leaked/given" 2>/dev/null)" "$(cat "$leaked/resolved" 2>/dev/null)" \
  "a suite that scrubs FM_* still resolves the gate's runner as its session, not an ancestor above the gate"
rm -f "$t/tests/leaky.test.sh"
assert_ok "FM_ROOT='$t' bash '$ROOT/bin/ci.sh' --stage bash" "without the leak the same tree is green"
rm -rf "$t" "$leaked"

# A leak the marker cannot see (T-151 review round 1). macOS withholds the
# environment of its platform binaries, so a leaked /bin/bash fm-worker.sh or
# mock adapter carries the marker invisibly; its argv, which names the
# fixture it runs in, is visible. Every suite gets a temp root of its own
# (TMPDIR) and every fixture lives under it, so the root finds it. Here the
# marker is taken off with env -u, so the same leak is invisible to the
# marker on Linux too, and the root alone must find it on either.
t="$(fixture)"; leaked="$(safe_tmpdir)"
printf '%s\n' '#!/usr/bin/env bash' \
  'fx="$(mktemp -d "${TMPDIR:-/tmp}/fx.XXXXXX")"' \
  'ln -s /bin/sleep "$fx/sleep"' \
  'env -u FIRSTMATE_CI_SCOPE "$fx/sleep" 30 > /dev/null 2>&1 < /dev/null &' \
  "echo \"\$!\" > '$leaked/pid'" \
  'exit 0' > "$t/tests/hidden.test.sh"
printf '#!/usr/bin/env bash\nexit 0\n' > "$t/tests/quiet.test.sh"
printf '#!/usr/bin/env bash\nexit 0\n' > "$t/tests/still.test.sh"
rc=0; out="$(FM_ROOT="$t" bash "$ROOT/bin/ci.sh" --stage bash 2>&1)" || rc=$?
assert_eq "1" "$rc" "a suite that leaves /bin/sleep running with its fixture root in argv is red"
assert_contains "$out" "tests/hidden.test.sh left processes running after it ended (killed now):" \
  "found by the suite's own temp root, not by the marker"
hp="$(cat "$leaked/pid" 2>/dev/null)"
assert_contains "$out" "$hp " "naming the process it left"
assert_fail "kill -0 '${hp:-0}'" "which is no longer running"
assert_lacks "$out" "tests/quiet.test.sh left" "a suite that leaves nothing is not named"
# The leak above is enforced by the host kernel. The platform-specific
# explanation can be checked on both platforms without another leak.
osbin="$(safe_tmpdir)"
real_uname="$(command -v uname)"
printf '#!/usr/bin/env bash\nif [ "$1" = -s ]; then echo "$FM_TEST_OS"; else exec %q "$@"; fi\n' "$real_uname" > "$osbin/uname"
chmod +x "$osbin/uname"
rm -f "$t/tests/hidden.test.sh"
for platform in Darwin Linux; do
  platform_out="$(FM_TEST_OS="$platform" PATH="$osbin:$PATH" FM_ROOT="$t" bash "$ROOT/bin/ci.sh" --stage bash 2>&1)"
  if [ "$platform" = Darwin ]; then
    assert_eq "1" "$(grep -c 'leak check: macOS hides the environment of /bin binaries; matched by fixture root as well - the required check (Linux) is authoritative' <<<"$platform_out")" \
      "the Darwin explanation appears once, not once per suite"
  else
    assert_lacks "$platform_out" "leak check: macOS hides" "the Linux diagnostic has no Darwin warning"
  fi
done
safe_rm_rf "$osbin"
rm -rf "$t" "$leaked"

assert_ok "test -x '$ROOT/bin/ci.sh'" "ci.sh is executable"
gha="$ROOT/.github/workflows/ci.yml"
assert_ok "test -f '$gha'" "a GitHub Actions workflow exists"
assert_contains "$(cat "$gha")" 'FM_CI_MAX_SECONDS: "600"' "GitHub explicitly selects 600 seconds"
assert_contains "$(cat "$gha")" "timeout-minutes: 10" "GitHub keeps its job timeout"
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


PATH="$suite_original_path"; export PATH
safe_rm_rf "$suite_tools"
finish
