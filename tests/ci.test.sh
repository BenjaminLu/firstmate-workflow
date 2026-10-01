#!/usr/bin/env bash
# bin/ci.sh is the single entry point CI and the local gate both call.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=tests/lib.sh
. "$ROOT/tests/lib.sh"
# shellcheck source=tests/lib/path.sh
. "$ROOT/tests/lib/path.sh"
suite_original_path="$PATH"
suite_tools="$(safe_tmpdir)"
fixture_path "$suite_tools" 'claude codex gemini cursor-agent agent gh herdr tmux cmux security secret-tool osascript xdg-open open' || exit 1
PATH="$suite_tools"; export PATH
for required in bun bunx shellcheck; do
  command -v "$required" >/dev/null 2>&1 || {
    echo "ci.test: install the declared toolchain before running this suite (missing $required)" >&2
    exit 1
  }
done

fixture() {                      # a throwaway repo root for ci.sh to operate on
  # safe_tmpdir, not a bare mktemp -d: this result feeds FM_ROOT, and a
  # mktemp this sandbox refuses used to hand back an empty string here,
  # which FM_ROOT="${FM_ROOT:-...}" then read as unset and ran the whole
  # gate against the real tree instead (T-123, round 5).
  d="$(safe_tmpdir)"; mkdir -p "$d/bin" "$d/tests"; printf '%s' "$d"
}


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

# --- the pool -------------------------------------------------------------
# The bash suites run several at a time. Every property the one-at-a-time
# gate had is asserted against the pool: a red suite is still red and
# named, the noise check still reads each suite's own output, the report is
# still in glob order, and FM_CI_JOBS=1 is still one at a time.
# Markers the fixture suites leave go in a directory of their own, never in
# the tree the gate is judging.
pool_marks="$(safe_tmpdir)"

# the width is validated like the budget, before any stage runs
for jobs in '' 0 -1 01 1.5 ' 2' 100 x '$(touch injected)'; do
  rc=0; out="$(FM_CI_JOBS="$jobs" FM_ROOT="$pool_marks" bash "$ROOT/bin/ci.sh" 2>&1)" || rc=$?
  assert_eq "64" "$rc" "FM_CI_JOBS=[$jobs] is refused"
  assert_contains "$out" 'FM_CI_JOBS must be a decimal integer from 1 to 99' "with guidance"
  assert_lacks "$out" '== shellcheck' "and before any stage runs"
done

# the width it chose is on the first lines, from the online CPU count,
# capped at six, and FM_CI_JOBS overrides it. Playwright runs beside the
# pool, so it takes half the CPUs, at most four, and is told so on its
# command line: four browsers beside four suites on a 4-vCPU runner starved
# the browsers until their waits ran out. The stub bunx records what
# playwright was asked for.
cpus="$(safe_tmpdir)"
empty_tree="$(fixture)"
mkdir -p "$empty_tree/tests/e2e" "$empty_tree/node_modules/@playwright"
printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$*" > "%s/bunx.args"\necho "  1 passed"\n' "$cpus" \
  > "$cpus/bunx"
chmod +x "$cpus/bunx"
for n in 1 2 4 64; do
  printf '#!/usr/bin/env bash\necho %s\n' "$n" > "$cpus/getconf"; chmod +x "$cpus/getconf"
  rm -f "$cpus/bunx.args"
  out="$(unset FM_CI_JOBS; PATH="$cpus:$PATH" FM_ROOT="$empty_tree" bash "$ROOT/bin/ci.sh" 2>&1)"
  want=$n; [ "$n" -gt 6 ] && want=6
  assert_contains "$out" "bash suites: $want at a time" "$n online CPUs run $want suites at a time"
  pw=$((n / 2)); [ "$pw" -ge 1 ] || pw=1; [ "$pw" -le 4 ] || pw=4
  assert_contains "$out" "end-to-end: $pw workers" "and $pw playwright workers beside them"
  assert_eq "playwright test --workers=$pw" "$(cat "$cpus/bunx.args" 2>/dev/null)" \
    "and playwright is started with that many"
done
out="$(PATH="$cpus:$PATH" FM_CI_JOBS=3 FM_ROOT="$empty_tree" bash "$ROOT/bin/ci.sh" 2>&1)"
assert_contains "$out" "bash suites: 3 at a time" "FM_CI_JOBS overrides the CPU count"
rm -rf "$cpus" "$empty_tree"

# A failing suite in the pool still turns the gate red, is named, and has
# its output printed; the one beside it still passes.
t="$(fixture)"
printf '#!/usr/bin/env bash\nexit 0\n' > "$t/tests/a-green.test.sh"
printf '#!/usr/bin/env bash\necho RED-SUITE-SAID-THIS\nexit 1\n' > "$t/tests/b-red.test.sh"
rc=0; out="$(FM_CI_JOBS=4 FM_ROOT="$t" bash "$ROOT/bin/ci.sh" 2>&1)" || rc=$?
assert_eq "1" "$rc" "a failing suite in the pool turns the gate red"
assert_contains "$out" "x tests/b-red.test.sh" "and the pool names it"
assert_contains "$out" "RED-SUITE-SAID-THIS" "and prints what it said"
assert_contains "$out" "+ tests/a-green.test.sh" "and the suite beside it still passes"
rm -f "$t/tests/b-red.test.sh"

# and the noise check still reads each suite's own run
{ printf '#!/usr/bin/env bash\n'
  printf 'nosuch%s "x"\n' poolhelper
  printf 'exit 0\n'
} > "$t/tests/c-silent.test.sh"
rc=0; out="$(FM_CI_JOBS=4 FM_ROOT="$t" bash "$ROOT/bin/ci.sh" 2>&1)" || rc=$?
assert_eq "1" "$rc" "a noise-check hit in the pool is still a failure"
assert_contains "$out" "tests/c-silent.test.sh said it passed, but something in it did not run:" \
  "reported the way it always was"
assert_contains "$out" "nosuchpoolhelper" "with the line it found"
assert_contains "$out" "+ tests/a-green.test.sh" "and it is pinned to the suite that said it"
rm -rf "$t"

# Glob order whatever order they finish in. z-quick sorts last and finishes
# first: a-waits holds until z-quick's marker is there. Each suite writes
# its name into a finish log as it ends, so the finish order is read, not
# inferred, and the report's order is checked against it separately.
# The order is a handshake, not a race: z-quick logs its name BEFORE it
# drops the marker, and a-waits logs only after it has seen the marker, so
# once the two overlap at all "z-quick" is first in the log by
# construction, however loaded the machine is. The deadline is not part of
# the order; it only keeps a gate that runs them one at a time from
# hanging, and a-waits says it gave up, so that case can never read as the
# expected log. The control below runs exactly that case.
pool_suites() { # <fixture-dir> <seconds a-waits waits for z-quick>
  cat > "$1/tests/a-waits.test.sh" <<S
#!/usr/bin/env bash
end=\$(( \$(date +%s) + $2 ))
until [ -e "$pool_marks/z-done" ]; do
  if [ "\$(date +%s)" -gt "\$end" ]; then
    echo "a-waits gave up" >> "$pool_marks/finished"
    exit 0
  fi
  sleep 0.05
done
echo a-waits >> "$pool_marks/finished"
exit 0
S
  printf '#!/usr/bin/env bash\necho z-quick >> "%s/finished"\ntouch "%s/z-done"\nexit 0\n' \
    "$pool_marks" "$pool_marks" > "$1/tests/z-quick.test.sh"
}
# the control: one at a time, a-waits runs alone and cannot see a marker
# z-quick has not written yet, so the order assertion below has to fail here
t="$(fixture)"; pool_suites "$t" 1
rm -f "$pool_marks/finished" "$pool_marks/z-done"
FM_CI_JOBS=1 FM_ROOT="$t" bash "$ROOT/bin/ci.sh" >/dev/null 2>&1
assert_eq "a-waits gave up
z-quick" "$(cat "$pool_marks/finished" 2>/dev/null)" \
  "one at a time, a-waits gives up before z-quick runs (the control)"
rm -rf "$t"; rm -f "$pool_marks/finished" "$pool_marks/z-done"
# 180 seconds is a deadline for a runner starved of CPU, not a timing: on
# any machine z-quick starts as soon as the pool has a second slot
t="$(fixture)"; pool_suites "$t" 180
before="$(find "$t" -print | sort; find "$t" -type f -exec shasum {} + | sort)"
# The listing above sees what is left; the stamp sees what happened. A path
# created, rewritten or removed under FM_ROOT during the run changes its own
# mtime or its directory's, so anything newer than the stamp was written.
# The second of sleep is for filesystems that keep whole seconds.
touch "$pool_marks/stamp"; sleep 1
rc=0; out="$(FM_CI_JOBS=2 FM_ROOT="$t" bash "$ROOT/bin/ci.sh" 2>&1)" || rc=$?
assert_eq "0" "$rc" "a suite that finishes first and sorts last: the gate is green"
assert_eq "z-quick
a-waits" "$(cat "$pool_marks/finished" 2>/dev/null)" \
  "with two at a time, z-quick finished before a-waits"
bash_stage="$(printf '%s\n' "$out" | sed -n '/== bash tests/,/== bun tests/p')"
assert_ne "" "$bash_stage" "the bash stage was found in the output"
assert_eq "  + tests/a-waits.test.sh
  + tests/z-quick.test.sh" "$(printf '%s\n' "$bash_stage" | grep '^  [+x] tests/')" \
  "and the report is in glob order, not the order they finished in"
# and the gate wrote nothing into the tree it judged: the logs and the
# statuses are all in a mktemp directory of its own
after="$(find "$t" -print | sort; find "$t" -type f -exec shasum {} + | sort)"
assert_eq "$before" "$after" "ci.sh leaves nothing behind under FM_ROOT"
assert_eq "" "$(find "$t" -newer "$pool_marks/stamp" -print)" \
  "and wrote nothing there while it ran"
rm -rf "$t"
# the control: a suite that writes under FM_ROOT and cleans up after itself
# leaves the listing as it was, and the stamp still sees it
t="$(fixture)"
printf '#!/usr/bin/env bash\ntouch scratch\nrm -f scratch\nexit 0\n' > "$t/tests/tidy.test.sh"
before="$(find "$t" -print | sort)"
touch "$pool_marks/stamp"; sleep 1
out="$(FM_CI_JOBS=2 FM_ROOT="$t" bash "$ROOT/bin/ci.sh" 2>&1)"
assert_eq "$before" "$(find "$t" -print | sort)" "a write that is cleaned up leaves no listing behind (the control)"
assert_contains "$(find "$t" -newer "$pool_marks/stamp" -print)" "$t" "and the stamp catches it"
rm -rf "$t"

# FM_CI_JOBS=1 runs one suite at a time. Each suite holds a lock for a
# second and records it if the lock was already taken; the same fixture at
# three at a time is the control, so the lock is known to catch an overlap.
t="$(fixture)"
for s in one two three; do
  cat > "$t/tests/$s.test.sh" <<S
#!/usr/bin/env bash
mkdir "$pool_marks/lock" 2>/dev/null || { echo "$s" >> "$pool_marks/overlap"; exit 0; }
sleep 1
rmdir "$pool_marks/lock"
S
done
rm -f "$pool_marks/overlap"
out="$(FM_CI_JOBS=3 FM_ROOT="$t" bash "$ROOT/bin/ci.sh" 2>&1)"
assert_ok "test -s '$pool_marks/overlap'" "three at a time, the suites overlap (the control)"
rm -rf "$pool_marks/lock" "$pool_marks/overlap"
out="$(FM_CI_JOBS=1 FM_ROOT="$t" bash "$ROOT/bin/ci.sh" 2>&1)"
assert_fail "test -e '$pool_marks/overlap'" "FM_CI_JOBS=1 never runs two suites at once"
assert_contains "$out" "bash suites: 1 at a time" "and says so"
assert_contains "$out" "ci: green" "and every suite still passes"
rm -rf "$t" "$pool_marks"
# the gate must never read standard input. With nullglob an empty file list
# turns a grep into one that reads stdin, and a nested run - which is exactly
# what this suite does - then waits for a human who is not there. The probe
# gives it a pipe that stays open, the way a real caller does.
# Two ways in, so neither fix ships untested: a tree with no tests at all
# (nullglob leaves the lint's grep with no file list) and a tree whose suite
# reads stdin itself. The budget is derived from the work - a full gate run
# with a timing margin - not from a number that felt long enough.
probe_gate() { # <fixture-dir> <label>
  local p="$1" label="$2" pid deadline
  # a fifo held open read-write never reaches EOF and needs no writer
  # process: the probe blocks for good if the gate reads it, and leaves
  # nothing running behind it
  rm -f "$p/openpipe"; mkfifo "$p/openpipe"
  exec 8<> "$p/openpipe"
  ( FM_ROOT="$p" bash "$p/bin/ci.sh" >/dev/null 2>&1 <&8; touch "$p/done" ) &
  pid=$!
  deadline=$(( $(date +%s) + 90 ))
  while [ ! -f "$p/done" ] && [ "$(date +%s)" -lt "$deadline" ]; do sleep 0.3; done
  assert_ok "test -f '$p/done'" "$label"
  kill -9 "$pid" 2>/dev/null
  wait "$pid" 2>/dev/null
  exec 8>&-; rm -f "$p/openpipe"
}
p="$(safe_tmpdir)"; mkdir -p "$p/bin"; cp "$ROOT/bin/ci.sh" "$ROOT/bin/fm-config.sh" "$p/bin/"
probe_gate "$p" "the gate finishes on a tree with no tests at all"
mkdir -p "$p/tests"
printf '#!/usr/bin/env bash\ncat >/dev/null\nexit 0\n' > "$p/tests/reads-stdin.test.sh"
rm -f "$p/done"
probe_gate "$p" "the gate finishes when a suite reads standard input"

# The two fixes are each sufficient to survive those probes, so neither is
# proved by them. This asserts the invariant itself: whatever the gate is
# started with, what reaches a suite is /dev/null.
# a pipe answers -p, /dev/null answers -c: enough to tell the caller's
# input from the one the gate is required to hand over
printf '#!/usr/bin/env bash\nif [ -p /dev/fd/0 ]; then echo pipe; elif [ -c /dev/fd/0 ]; then echo chardev; else echo other; fi > "%s/sawstdin"\nexit 0\n' \
  "$p" > "$p/tests/reads-stdin.test.sh"
rm -f "$p/openpipe"; mkfifo "$p/openpipe"
exec 8<> "$p/openpipe"
( FM_ROOT="$p" bash "$p/bin/ci.sh" >/dev/null 2>&1 <&8 ) &
gp=$!
for _ in $(seq 1 200); do [ -s "$p/sawstdin" ] && break; sleep 0.3; done
assert_eq "chardev" "$(cat "$p/sawstdin" 2>/dev/null)" "a suite is handed /dev/null, not the caller's pipe"
kill -9 "$gp" 2>/dev/null; wait "$gp" 2>/dev/null; exec 8>&-; rm -f "$p/openpipe"

# and the hygiene lint must be linting something: with nullglob an empty file
# list turns its grep into one that reads /dev/null and passes every time
# assembled at run time: written out whole, this line is itself the
# violation, and the lint would flag this suite for carrying its own fixture
{ printf '#!/usr/bin/env bash\n'
  printf 'assert_%s "%s -q x $%s/bin/ci.sh" "planted"\n' ok grep ROOT
} > "$p/tests/planted.test.sh"
out="$(FM_ROOT="$p" bash "$p/bin/ci.sh" 2>&1)"
assert_contains "$out" "greps source without excluding comments" "the hygiene lint reads the suites it is given"
rm -rf "$p"

# tests/e2e belongs to the browser runner. Bun picking those files up runs
# them without a browser and calls the result an error, so the bun stage has
# to leave them alone - and the e2e stage has to say it skipped rather than
# quietly passing when the browser is not installed.
q="$(safe_tmpdir)"; mkdir -p "$q/bin" "$q/tests/e2e"
cp "$ROOT/bin/ci.sh" "$ROOT/bin/fm-config.sh" "$q/bin/"
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
# One gate run per fixture STATE, not one per assertion: every plant used
# to run a full nested gate, and the stage that measures the gate's own
# budget was mostly measuring that.
#
# The cache invalidates itself off a signature of the fixture rather than
# off the author remembering to clear it. The first version needed a
# `replant` call after every write, one was missed, and the assertion read
# the previous run - green for an assertion that tested nothing, which is
# the class this suite exists to catch.
planted=''; planted_sig=''; planted_runs=0
# The content, not the metadata. `ls -ld` prints the mtime to the minute
# on the BSD tools this runs on, so rewriting a file with different
# content of the same size seconds later produced an identical signature -
# and the assertion then read the PREVIOUS fixture's gate run and passed.
# A plant that creates or deletes a file was safe; one that edits in place
# was not, and those are the ones this suite added.
fixture_sig() { find "$q" -type f -exec shasum {} + 2>/dev/null | sort | shasum | cut -c1-40; }
plant() {   # plant <label> <expected fragment> [stage, default fast]
  local label="$1" want="$2" stage="${3:-fast}" sig
  sig="$stage:$(fixture_sig)"
  if [ "$sig" != "$planted_sig" ]; then
    planted="$(FM_ROOT="$q" bash "$q/bin/ci.sh" --stage "$stage" 2>&1)"
    planted_sig="$sig"
    planted_runs=$((planted_runs + 1))
  fi
  assert_contains "$planted" "$want" "$label"
}

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

# a hand-rolled save-and-restore in a suite
# assembled, or this suite carries the very string it plants and the lint
# flags the file that tests it - the same trap as the planted source-grep
printf '#!/usr/bin/env bash\nr=/tmp\ncp "$r/bin/x.sh" "$r/x.%s"\n' 'keep"' > "$q/tests/hand-rolled.test.sh"
# the stage says how many suites it read, which is what makes the
# empty-list guard provable rather than indistinguishable from reading
# /dev/null and passing
out="$(FM_ROOT="$q" bash "$q/bin/ci.sh" 2>&1)"
n="$(find "$q/tests" -name '*.test.sh' | wc -l | tr -d ' ')"
assert_contains "$out" "($n suites)" "the hygiene stage says how many suites it linted"
bare="$(safe_tmpdir)"; mkdir -p "$bare/bin"; cp "$q/bin/ci.sh" "$q/bin/fm-config.sh" "$bare/bin/"
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

# How the reader normalises a line, one step per line, so deleting a step
# flips the line that names it. Red: each kind of quote and the backslash
# are taken out (`'-q'`, `"-q"` and `\grep` are -q and grep to the shell), a
# value attached with = is not stepped over, a wrapper's long option is
# done once its value is taken (timeout --s is --signal; read as a cluster
# as well, its s takes KILL and the duration eats grep), a digit is a grep
# option, and a backslash-newline joins with nothing between, as bash
# joins it. Green: grep's words end at each of ; & ) and a backtick, `--`
# ends a wrapper's options (-x is the command), so does its first operand,
# a word that does not start with - is an operand however it is spelt, and
# a prefix of more than one long option is refused even when all of them
# take a value. tail.sh ends in the middle of a continued line.
{ printf '#!/usr/bin/env bash\nset -uo pipefail\n'
  printf "printf x %s grep '-q' x\n" '|'                  # 3
  printf 'printf x %s grep "-q" x\n' '|'                  # 4
  printf 'printf x %s \\grep -q x\n' '|'                  # 5
  printf 'printf x %s env --unset=NAME grep -q x\n' '|'   # 6
  printf 'printf x %s timeout --s KILL 5 grep -q x\n' '|' # 7
  printf 'printf x %s grep -2q x\n' '|'                   # 8
  printf 'printf x %s grep -\\\nq x\n' '|'                # 9-10
  printf 'printf x %s grep x; wc -c f\n' '|'              # 11
  printf 'printf x %s grep x & wc -c f\n' '|'             # 12
  printf 'echo "$(printf x %s grep x) -c"\n' '|'          # 13
  printf 'echo `printf x %s grep x` -c\n' '|'             # 14
  printf 'printf x %s env -- -x grep -q x\n' '|'          # 15
  printf 'printf x %s env NAME=v -i grep -q x\n' '|'      # 16
  printf 'printf x %s grep squid\n' '|'                   # 17
  printf 'printf x %s grep --exc -- -q x\n' '|'           # 18
} > "$q/tests/e2e/reading.sh"
printf '#!/usr/bin/env bash\nset -uo pipefail\nprintf x %s grep -q x \\\n' '|' \
  > "$q/tests/e2e/tail.sh"
plant "a single-quoted -q is -q" "reading.sh:3:"
plant "a double-quoted -q is -q" "reading.sh:4:"
plant "a backslashed grep is grep" "reading.sh:5:"
plant "a wrapper value attached with = is not stepped over" "reading.sh:6:"
plant "a wrapper's long option is done once its value is taken" "reading.sh:7:"
plant "a digit is a grep option: -2q is quiet" "reading.sh:8:"
plant "a backslash-newline joins with nothing between" "reading.sh:9:"
plant "a file that ends in a continued line is still read" "tail.sh:3:"
assert_lacks "$planted" "reading.sh:11:" "grep's words end at ;"
assert_lacks "$planted" "reading.sh:12:" "and at &"
assert_lacks "$planted" "reading.sh:13:" "and at )"
assert_lacks "$planted" "reading.sh:14:" "and at a backtick"
assert_lacks "$planted" "reading.sh:15:" "-- ends a wrapper's options, so -x is the command"
assert_lacks "$planted" "reading.sh:16:" "and so does its first operand"
assert_lacks "$planted" "reading.sh:17:" "an operand with a q in it is not -q"
assert_lacks "$planted" "reading.sh:18:" "--exc names three options, so grep refuses it"
rm -f "$q/tests/e2e/reading.sh" "$q/tests/e2e/tail.sh"

# Two scripts, and one of them with two offending lines: a stage that
# stopped at the first hit passes a single-instance plant, which this
# file's own comment says twenty lines up.
printf '#!/usr/bin/env bash\nset -uo pipefail\nexec < /dev/null\nwhile [ $# -gt 0 ]; do\n  case "$1" in\n    --x) v="${2-}"; shift 2 ;;\n    --y) w="${2-}"; shift 2 ;;\n    *) exit 64 ;;\n  esac\ndone\necho "${v:-}${w:-}"\n' \
  > "$q/bin/fm-spinner.sh"
printf '#!/usr/bin/env bash\nset -uo pipefail\nexec < /dev/null\nwhile [ $# -gt 0 ]; do\n  case "$1" in\n    --z) u="${2-}"; shift 2 ;;\n    *) exit 64 ;;\n  esac\ndone\necho "${u:-}"\n' \
  > "$q/bin/fm-twirler.sh"
plant "an unguarded shift 2 turns the hygiene stage red" "has not checked it has two"
plant "and the stage names the first script" "fm-spinner.sh"
plant "and the second as well" "fm-twirler.sh"
plant "and both lines of the one with two" "--y"
rm -f "$q/bin/fm-spinner.sh" "$q/bin/fm-twirler.sh"

# a comment must not talk the stage out of firing: the guard is judged by
# what the code does, not by the word appearing on the line
# On a line of its own inside the branch, and shaped like a command,
# because only the STRIPPING can then be what catches it: a trailing
# `;; # need to check this` is refused by the command-position rule
# instead - `#` is not something a command can follow - and the plant
# would be coasting on a mechanism it does not name.
{ printf '#!/usr/bin/env bash\nset -uo pipefail\nexec < /dev/null\n'
  printf 'while [ $# -gt 0 ]; do\n  case "$1" in\n'
  printf '    --x)\n      # ; need "$@" would go here\n'
  printf '      v="${2-}"; shift 2 ;;\n'
  printf '    *) exit 64 ;;\n  esac\ndone\necho "${v:-}"\n'
} > "$q/bin/fm-sneak.sh"
plant "a comment mentioning the guard does not count as one" "has not checked it has two"
rm -f "$q/bin/fm-sneak.sh"

# nor must a check written AFTER the shift, which is not a check: by then
# the argument it was supposed to find is gone.
#
# One script per shape from here on. Two plants in one file and the
# coarse "turns it red" assertion is carried by whichever of them fires,
# so the other one tests nothing of its own.
{ printf '#!/usr/bin/env bash\nset -uo pipefail\nexec < /dev/null\n'
  printf 'need() { [ "$#" -ge 2 ] || exit 64; }\n'
  printf 'while [ $# -gt 0 ]; do\n  case "$1" in\n'
  printf '    --x) v="${2-}"; shift 2; need "$@" ;;\n'
  printf '    *) exit 64 ;;\n  esac\ndone\necho "${v:-}"\n'
} > "$q/bin/fm-afterwards.sh"
plant "a guard written after the shift does not count as one" "has not checked it has two"
plant "and the stage names that line" "--x"
rm -f "$q/bin/fm-afterwards.sh"

# The word in a string, IN FRONT of the shift, so the ordering rule
# cannot be what catches it. A column comparison called this guarded;
# the guard has to be a command.
{ printf '#!/usr/bin/env bash\nset -uo pipefail\nexec < /dev/null\n'
  printf 'while [ $# -gt 0 ]; do\n  case "$1" in\n'
  printf '    --y) echo "you need a value"; w="${2-}"; shift 2 ;;\n'
  printf '    *) exit 64 ;;\n  esac\ndone\necho "${w:-}"\n'
} > "$q/bin/fm-saysit.sh"
plant "the word in a string in front of the shift is not a guard" "has not checked it has two"
plant "and the stage names that one" "--y"
rm -f "$q/bin/fm-saysit.sh"

# and a helper defined ABOVE the loop whose message says the word - not
# exotic, fm-emit grows a usage() in this very diff - with a loop that
# is not a case statement at all
{ printf '#!/usr/bin/env bash\nset -uo pipefail\nexec < /dev/null\n'
  printf 'usage() { echo "you need a value" >&2; exit 64; }\n'
  printf 'while [ $# -gt 0 ]; do\n'
  printf '  if [ "$1" = --x ]; then v="${2-}"; shift 2; fi\n'
  printf 'done\necho "${v:-}"\n'
} > "$q/bin/fm-helper.sh"
plant "a helper above the loop whose message says the word is not a guard" \
  "has not checked it has two"
plant "and the stage names it" "fm-helper.sh"
rm -f "$q/bin/fm-helper.sh"

# a REAL guard, in command position, in a function above the loop: it
# guards something, but not this branch. A case pattern ends the
# previous branch as surely as `;;` does.
{ printf '#!/usr/bin/env bash\nset -uo pipefail\nexec < /dev/null\n'
  printf 'need() { [ "$#" -ge 2 ] || exit 64; }\n'
  printf 'check() { need "$@"; }\n'
  printf 'while [ $# -gt 0 ]; do\n  case "$1" in\n'
  printf '    --x) v="${2-}"; shift 2 ;;\n'
  printf '    *) exit 64 ;;\n  esac\ndone\necho "${v:-}"\n'
} > "$q/bin/fm-elsewhere.sh"
plant "a guard called somewhere else does not cover a branch that has none" \
  "has not checked it has two"
plant "and the stage names that one too" "fm-elsewhere.sh"
rm -f "$q/bin/fm-elsewhere.sh"

# And the ordinary multi-line branch, which IS guarded: the check reads
# the case branch, not the physical line, so a guard on a line of its
# own counts. Reading one line called this naked and would have made the
# gate refuse the commonest way of writing it - the rule §5.3.1 states
# is "checks first", not "checks first, on the same line".
{ printf '#!/usr/bin/env bash\nset -uo pipefail\nexec < /dev/null\n'
  printf 'need() { [ "$#" -ge 2 ] || exit 64; }\n'
  printf 'while [ $# -gt 0 ]; do\n  case "$1" in\n'
  printf '    --x)\n      need "$@"\n      v="${2-}"; shift 2 ;;\n'
  printf '    *) exit 64 ;;\n  esac\ndone\necho "${v:-}"\n'
} > "$q/bin/fm-spread.sh"
plant "a guard on its own line, above the shift, is a guard" "no option loop can spin"
rm -f "$q/bin/fm-spread.sh"

# and the guard does not leak past the end of its branch: one branch
# checks, the next does not, and the next one is an offender
{ printf '#!/usr/bin/env bash\nset -uo pipefail\nexec < /dev/null\n'
  printf 'need() { [ "$#" -ge 2 ] || exit 64; }\n'
  printf 'while [ $# -gt 0 ]; do\n  case "$1" in\n'
  printf '    --x)\n      need "$@"\n      v="${2-}"; shift 2 ;;\n'
  printf '    --y)\n      w="${2-}"; shift 2 ;;\n'
  printf '    *) exit 64 ;;\n  esac\ndone\necho "${v:-}${w:-}"\n'
} > "$q/bin/fm-leaky2.sh"
plant "a guard in the branch above does not cover the one below it" "has not checked it has two"
# the line it prints is the one with the shift on it, and it is the
# line the reader has to open: the branch head is two lines up and the
# line number is in the output
plant "and the stage names the line" "w=\"\${2-}\"; shift 2"
rm -f "$q/bin/fm-leaky2.sh"

# and the corpus has to SEE a script whose option loop shares a line with
# a `#` that is not a comment. `sed 's/#.*$//'` cuts `${1#--}` in half,
# the `shift 2` disappears with it, and the script is excused entirely.
{ printf '#!/usr/bin/env bash\nset -uo pipefail\nexec < /dev/null\n'
  printf 'while [ $# -gt 0 ]; do\n  case "$1" in\n'
  printf '    --*) n="${1#--}"; v="${2-}"; shift 2 ;;\n'
  printf '    *) exit 64 ;;\n  esac\ndone\necho "${n:-}${v:-}"\n'
} > "$q/bin/fm-hashed.sh"
plant "a hash inside a parameter expansion does not hide an option loop" "fm-hashed.sh"
rm -f "$q/bin/fm-hashed.sh"

# and it descends: bin/*.sh missed anything in a subdirectory
mkdir -p "$q/bin/inner"
printf '#!/usr/bin/env bash\nset -uo pipefail\nexec < /dev/null\nwhile [ $# -gt 0 ]; do\n  case "$1" in\n    --x) v="${2-}"; shift 2 ;;\n    *) exit 64 ;;\n  esac\ndone\necho "${v:-}"\n' \
  > "$q/bin/inner/fm-buried.sh"
plant "a script in a subdirectory of bin is linted too" "fm-buried.sh"
rm -rf "$q/bin/inner"
# and the stage says how many scripts it read, so linting nothing does not
# look like linting a clean repository
out="$(FM_ROOT="$q" bash "$q/bin/ci.sh" 2>&1)"
assert_matches "$out" 'spin on a flag with no value \([0-9]+ scripts\)' \
  "the option-loop stage says how many scripts it read"
bare2="$(safe_tmpdir)"; mkdir -p "$bare2/bin"; cp "$q/bin/ci.sh" "$q/bin/fm-config.sh" "$bare2/bin/"
assert_contains "$(FM_ROOT="$bare2" bash "$bare2/bin/ci.sh" 2>&1)" "value (0 scripts)" \
  "and says zero on a tree with none"
rm -rf "$bare2"

plant "a hand-rolled swap turns the hygiene stage red" "saves a script by hand"
plant "and the stage names the suite" "hand-rolled.test.sh"
rm -f "$q/tests/hand-rolled.test.sh"

# T-123: a scratch variable resolved by cd-ing into its own (possibly
# empty, on a refused mktemp -d) value is exactly the shape that lost a
# worker's worktree and a run-mode reviewer's checkout to a silent mktemp
# failure. The lint has to flag the shape itself, not a keyword, so the
# planted line does not mention mktemp at all - the danger is the
# self-resolving cd, whatever put the value there first.
# Threaded through %s, not written whole here: this literal text is
# exactly the shape the check two paragraphs up bans, so writing it
# out in one piece would flunk this very file. Round 7 widens that check
# to a bare mktemp -d/-t on its own, with no cd at all, so mt/fd below are
# threaded the same way, for the same reason.
resolve_self='cd "$x"'
mt=mktemp; fd=-d
printf '#!/usr/bin/env bash\nx="$(%s %s)"; x="$(%s && pwd -P)"\n' "$mt" "$fd" "$resolve_self" \
  > "$q/tests/self-launder.test.sh"
plant "a scratch path that cds into its own value turns the hygiene stage red" \
  "cd-ing into its own value"
plant "and the stage names the line" 'x="$(cd "$x"'
rm -f "$q/tests/self-launder.test.sh"

# The false-positive half: cd-ing into a DIFFERENT variable to resolve one
# (an engine root read from another fixture path, say) is the ordinary,
# safe idiom used throughout the suites themselves, and safe_tmpdir's own
# body does exactly this, once, on a mktemp result it has already checked.
# Neither may trip the lint, or every suite in the repository would.
printf '#!/usr/bin/env bash\nother="$(%s %s)"; engine="$(cd "$other" && pwd -P)"\n' "$mt" "$fd" \
  > "$q/tests/resolve-other.test.sh"
out="$(FM_ROOT="$q" bash "$q/bin/ci.sh" 2>&1)"
assert_lacks "$out" "cd-ing into its own value" \
  "resolving one variable by cd-ing into a different one is not the hazard"
rm -f "$q/tests/resolve-other.test.sh"

# T-123 round 7: the widened half of the same lint - a bare mktemp -d or
# mktemp -t is now its own violation, with no cd anywhere in sight at all.
# Threaded through mt/fd/ft the same way, so this suite's own examples do
# not flunk themselves.
ft=-t
printf '#!/usr/bin/env bash\nv="$(%s %s)"\necho "$v"\n' "$mt" "$fd" \
  > "$q/tests/bare-mktemp.test.sh"
out="$(FM_ROOT="$q" bash "$q/bin/ci.sh" 2>&1)"
assert_contains "$out" "a bare, template-less mktemp" \
  "a suite calling mktemp -d with no explicit template turns the hygiene stage red"
assert_contains "$out" "bare-mktemp.test.sh" "and the stage names the file"
rm -f "$q/tests/bare-mktemp.test.sh"

printf '#!/usr/bin/env bash\nv="$(%s %s %s fm-x)"\necho "$v"\n' "$mt" "$fd" "$ft" \
  > "$q/tests/bare-mktemp-t.test.sh"
out="$(FM_ROOT="$q" bash "$q/bin/ci.sh" 2>&1)"
assert_contains "$out" "a bare, template-less mktemp" \
  "and so does mktemp -t with no explicit template"
rm -f "$q/tests/bare-mktemp-t.test.sh"

# The false-positive half: an explicit template under TMPDIR is exactly
# what safe_tmpdir itself does internally, and is not the hazard.
printf '#!/usr/bin/env bash\nv="$(%s %s "\${TMPDIR:-/tmp}/probe.XXXXXX")"\necho "$v"\n' "$mt" "$fd" \
  > "$q/tests/templated-mktemp.test.sh"
out="$(FM_ROOT="$q" bash "$q/bin/ci.sh" 2>&1)"
assert_lacks "$out" "a bare, template-less mktemp" \
  "an explicit template under TMPDIR is not the hazard"
rm -f "$q/tests/templated-mktemp.test.sh"

# The negative half of each exclusion. A lint with a plant for the thing it
# catches and none for the thing it lets through is half a lint: the
# exclusion is where the false positives live, and one of these was dead
# code that never matched anything.
printf '#!/usr/bin/env bash\nset -uo pipefail\nexec < /dev/null\n# printf x %s grep -q y\necho ok\n' '|' \
  > "$q/bin/fm-commented.sh"
out="$(FM_ROOT="$q" bash "$q/bin/ci.sh" 2>&1)"
assert_contains "$out" "ci: green" "a hazard quoted in a comment is not a hazard"
rm -f "$q/bin/fm-commented.sh"

printf '#!/usr/bin/env bash\nset -uo pipefail\nexec < /dev/null\n# "$REPO/bin/fm-emit.sh" --type x\necho ok\n' \
  > "$q/bin/fm-commented.sh"
out="$(FM_ROOT="$q" bash "$q/bin/ci.sh" 2>&1)"
assert_contains "$out" "ci: green" "a dispatch quoted in a comment is not a dispatch"
rm -f "$q/bin/fm-commented.sh"

printf '#!/usr/bin/env bash\n# fm:lint-source\nset -uo pipefail\nexec < /dev/null\ns=hi\nprintf "%%s" "$s" %s grep -q hi\n' '|' \
  > "$q/bin/fm-quoter.sh"
out="$(FM_ROOT="$q" bash "$q/bin/ci.sh" 2>&1)"
assert_contains "$out" "ci: green" "a file that declares itself a lint source is skipped"
rm -f "$q/bin/fm-quoter.sh"

# the same two exclusions hold in the suites
printf '#!/usr/bin/env bash\n# fm:lint-source\nset -uo pipefail\nprintf x %s grep -q x\n  # printf y %s grep -c y\n' '|' '|' \
  > "$q/tests/quoter.test.sh"
out="$(FM_ROOT="$q" bash "$q/bin/ci.sh" 2>&1)"
assert_contains "$out" "ci: green" "a suite that declares itself a lint source is skipped"
printf '#!/usr/bin/env bash\nset -uo pipefail\n  # printf y %s grep -c y\ngrep -q x <<<"$(printf x)"\n' '|' \
  > "$q/tests/quoter.test.sh"
out="$(FM_ROOT="$q" bash "$q/bin/ci.sh" 2>&1)"
assert_contains "$out" "ci: green" "a pipe quoted in a suite's comment, or a here-string, is not a hazard"
# `||` is not a pipe, and grep reading a file after it has no producer to
# kill; -C is context, not count, and a -q that is -e's pattern is a pattern
printf '#!/usr/bin/env bash\nset -uo pipefail\ntrue || grep -q x "$0"\nprintf x %s grep -C 2 x\nprintf x %s grep -e -q\ntrue\n' '|' '|' \
  > "$q/tests/quoter.test.sh"
out="$(FM_ROOT="$q" bash "$q/bin/ci.sh" 2>&1)"
assert_contains "$out" "ci: green" "an or-list into grep -q, grep -C, or -q as -e's pattern is not a hazard"
rm -f "$q/tests/quoter.test.sh"

{ printf '#!/usr/bin/env bash\n'
  printf '# assert_%s "%s '%%s' \\"$out\\" %s grep -q x" "in a comment"\n' fail printf '|'
} > "$q/tests/commented.test.sh"
out="$(FM_ROOT="$q" bash "$q/bin/ci.sh" 2>&1)"
assert_contains "$out" "ci: green" "an evalling assertion quoted in a comment is not one"
rm -f "$q/tests/commented.test.sh"


# this repository does have sourced libraries, and the marker is how the
# gate knows: if it were deleted, the stage would report zero and pass
# counted directly, not by running the gate: this suite IS one of the
# suites the gate runs, and calling it from here recurses
own="$(grep -l '^# fm:sourced' "$ROOT"/bin/*.sh 2>/dev/null | wc -l | tr -d ' ')"
assert_ne "0" "$own" "the repository's own sourced libraries are declared"
for f in "$ROOT"/bin/fm-config.sh "$ROOT"/bin/fm-guard.sh; do
  assert_ok "grep -q '^# fm:sourced' '$f'" "$(basename "$f") declares itself sourced"
done

# a library that declares itself sourced must not carry the redirect, and
# the exemption has to work both ways: the marker exempts it from the
# dispatch stage AND binds it in the sourced stage
printf '#!/usr/bin/env bash\n# fm:sourced\nexec < /dev/null\nx=$(date)\necho "$x"\n' > "$q/bin/fm-lib.sh"
plant "a sourced library with the redirect turns its stage red" "must not redirect the caller"
plant "and the stage names it" "fm-lib.sh"
printf '#!/usr/bin/env bash\n# fm:sourced\nx=$(date)\necho "$x"\n' > "$q/bin/fm-lib.sh"
out="$(FM_ROOT="$q" bash "$q/bin/ci.sh" 2>&1)"
assert_contains "$out" "ci: green" "a declared library with no redirect is simply fine"
stdin_stage="$(printf '%s\n' "$out" | sed -n '/== stdin/,/== dag/p')"
# an extraction that found nothing makes assert_lacks pass on the empty
# string, which is green for an assertion that read nothing
assert_ne "" "$stdin_stage" "the stdin stage was found in the output"
assert_lacks "$stdin_stage" "fm-lib.sh" "and the dispatch stage leaves it alone"
rm -f "$q/bin/fm-lib.sh"

# a second implementation of the vendor chain
printf '#!/usr/bin/env bash\nset -uo pipefail\nexec < /dev/null\nfor v in $chain; do :; done\n' \
  > "$q/bin/fm-second-chain.sh"
plant "a second vendor loop turns its stage red" "loops over vendors on its own"
plant "and the stage names the script" "fm-second-chain.sh"
rm -f "$q/bin/fm-second-chain.sh"

# The assertions stage, from both sides. It landed with no fixture, which
# is the one rule this file is for: a lint nobody has ever seen fail is a
# lint nobody knows works.
# the stage needs a harness to compare against, and this fixture has
# none until now - without lib.sh it skips, and a plant against a stage
# that skipped is the assertion that cannot fail all over again
cp "$ROOT/tests/lib.sh" "$q/tests/lib.sh"
{ printf '#!/usr/bin/env bash\n'
  printf '. "$(dirname "$0")/lib.sh"\n'
  printf 'assert_%s "x" "x" "planted"\n' nosuchthing
  printf 'finish\n'
} > "$q/tests/undefined.test.sh"
plant "a suite calling an assertion lib.sh does not define turns the stage red" \
  "does not define"
# assembled, or this suite carries the name of a helper that does not
# exist and the assertions stage - which cannot tell a call from a
# mention - turns the gate red on the file that tests it
miss="nosuchthing"
plant "and the stage names it" "assert_${miss}"
rm -f "$q/tests/undefined.test.sh"
# and the negative half, which is the reason the stage strips comments:
# a suite that NAMES a helper in prose is not calling it
{ printf '#!/usr/bin/env bash\n'
  printf '. "$(dirname "$0")/lib.sh"\n'
  printf '# this file used to lean on assert_%s, which no longer exists\n' nosuchthing
  printf 'assert_eq "x" "x" "planted"\n'
  printf 'finish\n'
} > "$q/tests/mentions.test.sh"
out="$(FM_ROOT="$q" bash "$q/bin/ci.sh" 2>&1)"
assert_contains "$out" "ci: green" "a helper named only in a comment does not turn it red"
rm -f "$q/tests/mentions.test.sh" "$q/tests/lib.sh"

# a second writer of the event log
printf '#!/usr/bin/env bash\nset -uo pipefail\nexec < /dev/null\necho x >> state/events.jsonl\n' \
  > "$q/bin/fm-sneaky.sh"
plant "a second writer of the event log turns the lint red" "outside fm-emit.sh"
rm -f "$q/bin/fm-sneaky.sh"

# the task list (T-090): one file per task, and the dag stage checks the
# files themselves - there is no hand-kept table left to agree with
mkdir -p "$q/design/tasks"
printf '{"id":"T-001","depends_on":[]}\n' > "$q/design/tasks/T-001.json"
printf '{"id":"T-002","depends_on":["T-001"]}\n' > "$q/design/tasks/T-002.json"
plant "a sound task directory is green" "every task file parses, is named by its id, and depends only on tasks that exist, with no cycle (2 tasks)"
printf '{"id":"T-003","depends_on":["T-404"]}\n' > "$q/design/tasks/T-003.json"
plant "a missing dependency turns the dag stage red" "the task list is not a sound DAG"
plant "and the stage names it" "T-003: depends on T-404, which has no task file"
printf '{"id":"T-003","depends_on":["T-004"]}\n' > "$q/design/tasks/T-003.json"
printf '{"id":"T-004","depends_on":["T-003"]}\n' > "$q/design/tasks/T-004.json"
plant "a cycle turns the dag stage red" "a cycle: T-003 -> T-004 -> T-003"
rm -f "$q/design/tasks/T-004.json"
printf '{"id":"T-999","depends_on":[]}\n' > "$q/design/tasks/T-003.json"
plant "an id that is not its file name turns it red" "T-003.json: its id is \"T-999\", not T-003"
printf '{"id":"T-003",\n' > "$q/design/tasks/T-003.json"
plant "a file that does not parse turns it red" "T-003.json: does not parse"
rm -f "$q/design/tasks/T-003.json"
printf '{"tasks":[{"id":"T-003"}]}\n' > "$q/design/tasks.json"
plant "a design/tasks.json left behind turns it red" "design/tasks.json is still here"
rm -rf "$q/design"

# with a registry, the check runs once per registered task directory and
# names the project. The library's parser lives beside it.
cp "$ROOT/bin/fm-herdr.py" "$q/bin/"
mkdir -p "$q/design/tasks" "$q/projects/other-app/tasks"
printf '{"id":"T-001"}\n' > "$q/design/tasks/T-001.json"
printf '{"id":"T-777","depends_on":["T-776"]}\n' > "$q/projects/other-app/tasks/T-777.json"
{ printf 'default_project: self-host\nprojects:\n'
  printf '  self-host:\n    repo: .\n    github: o/engine\n    base: main\n    required_check: ci\n'
  printf '    design: design/design.md\n    tasks: design/tasks\n'
  printf '  other-app:\n    github: o/other-app\n    base: main\n    required_check: check\n'
} > "$q/config.yaml"
plant "a registered project's broken list turns the dag stage red" "the task list is not a sound DAG"
plant "and the stage names that project" "project other-app (projects/other-app/tasks)"
plant "and its problem" "T-777: depends on T-776"
plant "the self directory is checked in the same run, from a path in the old shape" \
  "project self-host (design/tasks): every task file parses"
printf '{"id":"T-777"}\n' > "$q/projects/other-app/tasks/T-777.json"
plant "every sound list is green per project" \
  "project other-app (projects/other-app/tasks): every task file parses"
rm -rf "$q/projects"
plant "a registered task directory that does not exist is red, not skipped" \
  "project other-app: projects/other-app/tasks does not exist"
printf '  broken-app:\n    github: not-a-repo\n    base: main\n    required_check: ci\n' >> "$q/config.yaml"
plant "a broken registry turns the stage red" "the project registry: fm-config: project broken-app: github"
rm -rf "$q/design" "$q/config.yaml" "$q/bin/fm-herdr.py"

# a suite that fails
printf '#!/usr/bin/env bash\nexit 1\n' > "$q/tests/doomed.test.sh"
plant "a failing suite turns the bash stage red" "doomed.test.sh" bash
rm -f "$q/tests/doomed.test.sh"

# The two left: the bun and playwright stages report the runner's own
# output, which their own suites cover, and there is no way to plant a
# failure in them that is not just a failing spec.
rm -rf "$q/bin/adapters"   # the broken adapter planted further up
final_ci_rc=0
out="$(FM_ROOT="$q" bash "$q/bin/ci.sh" 2>&1)" || final_ci_rc=$?
case "$final_ci_rc:$out" in
  0:*'ci: green'*) : ;;
  *) printf 'Final fixture CI failed (exit %s); captured output follows:\n%s\n' "$final_ci_rc" "$out" ;;
esac
assert_eq '0' "$final_ci_rc" "the cleaned fixture CI exits successfully"
assert_contains "$out" "ci: green" "and the fixture is green again once every plant is pulled"
rm -rf "$q"

# --- --stage and --shard: one gate run, split into a workflow's parallel
# jobs (T-134) -------------------------------------------------------------
# Neither flag changes what a stage checks; with neither, bin/ci.sh runs
# every stage in one process, exactly as every assertion above this section
# already proves. --stage picks which group of stages this process runs,
# and --shard, only within --stage bash, picks which slice of the bash
# suites it runs.

# validated like every other flag, before any stage runs
sf="$(fixture)"
rc=0; out="$(FM_ROOT="$sf" bash "$ROOT/bin/ci.sh" --stage bogus 2>&1)" || rc=$?
assert_eq "64" "$rc" "--stage bogus is refused"
assert_contains "$out" "--stage must be one of: fast, bash, bun, e2e" "with guidance"
assert_lacks "$out" "effective budget" "and before any stage runs"

rc=0; out="$(FM_ROOT="$sf" bash "$ROOT/bin/ci.sh" --shard 1/2 2>&1)" || rc=$?
assert_eq "64" "$rc" "--shard with no --stage bash is refused"
assert_contains "$out" "--shard requires --stage bash" "with guidance"

for bad in 0/2 2/0 x/2 2 2/ /2 01/2; do
  rc=0; out="$(FM_ROOT="$sf" bash "$ROOT/bin/ci.sh" --stage bash --shard "$bad" 2>&1)" || rc=$?
  assert_eq "64" "$rc" "--shard $bad is refused"
  assert_contains "$out" "--shard must look like i/n" "with guidance"
done
rc=0; out="$(FM_ROOT="$sf" bash "$ROOT/bin/ci.sh" --stage bash --shard 3/2 2>&1)" || rc=$?
assert_eq "64" "$rc" "--shard i greater than n is refused"
assert_contains "$out" "--shard i must not exceed n (got 3/2)" "and says which"
rm -rf "$sf"

# --stage fast is the shellcheck, lint, hygiene, stdin, assertions and dag
# stages, and none of the others
sf="$(fixture)"
printf '#!/usr/bin/env bash\nexit 0\n' > "$sf/tests/green.test.sh"
printf '#!/usr/bin/env bash\nexit 0\n' > "$sf/bin/placeholder.sh"
out="$(FM_ROOT="$sf" bash "$ROOT/bin/ci.sh" --stage fast 2>&1)"
for want in shellcheck lint "test hygiene" stdin assertions dag; do
  assert_contains "$out" "== $want" "--stage fast runs the $want stage"
done
for skip in "bash tests" "bun tests" "end-to-end"; do
  assert_lacks "$out" "== $skip" "--stage fast does not run the $skip stage"
done
assert_lacks "$out" "tests/green.test.sh" "and does not run a suite either"

# --stage bash is only the bash suites
out="$(FM_ROOT="$sf" bash "$ROOT/bin/ci.sh" --stage bash 2>&1)"
assert_contains "$out" "== bash tests" "--stage bash runs the bash tests stage"
assert_contains "$out" "+ tests/green.test.sh" "and runs the suite"
for skip in shellcheck lint "test hygiene" stdin assertions dag "bun tests" "end-to-end"; do
  assert_lacks "$out" "== $skip" "--stage bash does not run the $skip stage"
done

# --stage bun is only the bun stage
mkdir -p "$sf/tests/e2e"
printf 'import { test, expect } from "bun:test";\ntest("a", () => expect(1).toBe(1));\n' \
  > "$sf/unit.spec.ts"
out="$(FM_ROOT="$sf" bash "$ROOT/bin/ci.sh" --stage bun 2>&1)"
assert_contains "$out" "== bun tests" "--stage bun runs the bun tests stage"
for skip in shellcheck lint "test hygiene" stdin assertions dag "bash tests" "end-to-end"; do
  assert_lacks "$out" "== $skip" "--stage bun does not run the $skip stage"
done
assert_lacks "$out" "tests/green.test.sh" "and does not run the bash suite either"

# --stage e2e is only the end-to-end stage
out="$(FM_ROOT="$sf" bash "$ROOT/bin/ci.sh" --stage e2e 2>&1)"
assert_contains "$out" "== end-to-end" "--stage e2e runs the end-to-end stage"
for skip in shellcheck lint "test hygiene" stdin assertions dag "bash tests" "bun tests"; do
  assert_lacks "$out" "== $skip" "--stage e2e does not run the $skip stage"
done
rm -f "$sf/unit.spec.ts"; rm -rf "$sf/tests/e2e"

# The bar for gate 4: --shard splits tests/*.test.sh into exactly n shards
# whose union is every suite, with no suite in two. Balanced by duration is
# a quality, not a correctness property, so this reads only membership: it
# collects the "+ path" line every shard printed and compares the combined
# set (sorted) against the fixture's own suite list (sorted), then checks
# no name repeats. A suite added after the split - "new" here - lands in
# exactly one shard too, with nothing telling ci.sh which. Only the run
# lines count: every shard's summary line names the longest suite as well.
shard_ran() {   # shard_ran <ci.sh output>: the suites its "+ path" lines ran
  grep -oE '^[[:space:]]*\+ tests/[a-z0-9-]+\.test\.sh' <<<"$1" | sed 's/^[[:space:]]*+ //' || true
}
sh_dir="$(fixture)"
for n in one two three four five; do
  printf '#!/usr/bin/env bash\nexit 0\n' > "$sh_dir/tests/$n.test.sh"
done
shard_seen=''
for i in 1 2 3; do
  out="$(FM_ROOT="$sh_dir" bash "$ROOT/bin/ci.sh" --stage bash --shard "$i/3" 2>&1)"
  shard_seen="$shard_seen$(shard_ran "$out")
"
done
want_list="$(cd "$sh_dir" && printf '%s\n' tests/*.test.sh | sort)"
got_list="$(printf '%s\n' "$shard_seen" | sed '/^$/d' | sort)"
assert_eq "$want_list" "$got_list" "the union of 3 shards is every suite, each exactly once"
dupes="$(printf '%s\n' "$shard_seen" | sed '/^$/d' | sort | uniq -d)"
assert_eq "" "$dupes" "and no suite is in two shards"

# a suite added after that split - a new one, unknown to any prior run -
# still lands in exactly one shard when the split runs again
printf '#!/usr/bin/env bash\nexit 0\n' > "$sh_dir/tests/sixnew.test.sh"
shard_seen=''
for i in 1 2 3; do
  out="$(FM_ROOT="$sh_dir" bash "$ROOT/bin/ci.sh" --stage bash --shard "$i/3" 2>&1)"
  shard_seen="$shard_seen$(shard_ran "$out")
"
done
want_list="$(cd "$sh_dir" && printf '%s\n' tests/*.test.sh | sort)"
got_list="$(printf '%s\n' "$shard_seen" | sed '/^$/d' | sort)"
assert_eq "$want_list" "$got_list" "a newly added suite is covered too, still exactly once"
assert_contains "$got_list" "tests/sixnew.test.sh" "by name"
rm -rf "$sh_dir"

# FM_CI_TIMINGS_OUT records what each suite took, in "path seconds" lines,
# only when asked - the plain run pays for none of it and writes nothing
tm_dir="$(fixture)"
printf '#!/usr/bin/env bash\nexit 0\n' > "$tm_dir/tests/quick.test.sh"
timings_out="$(safe_tmpdir)/timings.txt"
FM_ROOT="$tm_dir" FM_CI_TIMINGS_OUT="$timings_out" bash "$ROOT/bin/ci.sh" --stage bash >/dev/null 2>&1
assert_ok "test -s '$timings_out'" "FM_CI_TIMINGS_OUT is written when asked for"
assert_contains "$(cat "$timings_out")" "tests/quick.test.sh " "and names the suite"
# in milliseconds, not whole seconds (T-148): whole seconds recorded every
# suite under a second - and main's three 10-second ones - as 0
assert_matches "$(cat "$timings_out")" '^tests/quick\.test\.sh [0-9]+\.[0-9]{3}$' \
  "the duration is seconds with millisecond resolution"

# FM_CI_TIMINGS_IN feeds --shard's balance; a suite it names goes by that
# duration - proved by forcing a tiny suite to outweigh a huge one and
# watching the split follow the forced number, not the files' real sizes
bal_dir="$(fixture)"
printf '#!/usr/bin/env bash\nexit 0\n' > "$bal_dir/tests/tiny.test.sh"
{ printf '#!/usr/bin/env bash\n# padding to make this file the larger one on disk\n'
  for _ in $(seq 1 200); do printf '# %s\n' "0123456789012345678901234567890123456789"; done
  printf 'exit 0\n'
} > "$bal_dir/tests/huge.test.sh"
forced="$(safe_tmpdir)/forced.txt"
printf 'tests/tiny.test.sh 100\ntests/huge.test.sh 1\n' > "$forced"
one="$(shard_ran "$(FM_ROOT="$bal_dir" FM_CI_TIMINGS_IN="$forced" bash "$ROOT/bin/ci.sh" --stage bash --shard 1/2 2>&1)")"
two="$(shard_ran "$(FM_ROOT="$bal_dir" FM_CI_TIMINGS_IN="$forced" bash "$ROOT/bin/ci.sh" --stage bash --shard 2/2 2>&1)")"
assert_eq "tests/tiny.test.sh" "$one" "FM_CI_TIMINGS_IN's forced duration, not the file's real size, decides the split"
assert_eq "tests/huge.test.sh" "$two" "so the two land in different shards by the numbers given, not by size"
rm -rf "$sf" "$tm_dir" "$bal_dir"

# Balanced by time in one unit (T-148). The shape main had on 9e4194d: three
# fast suites recorded at 0 but large on disk, and one suite the timings do
# not name. Read as unknown and weighed by their byte size, the three zeros
# each took a shard of their own and everything else went to the fourth.
# A zero is fast; the unnamed suite is estimated in seconds (its size times
# the recorded seconds per byte), never raw bytes beside seconds. The bar:
# no shard's recorded load exceeds the mean by more than the longest suite.
bt_dir="$(fixture)"
bt_pad() {   # bt_pad <file> <comment lines>
  { printf '#!/usr/bin/env bash\n'
    for _ in $(seq 1 "$2"); do printf '# %s\n' "0123456789012345678901234567890123456789"; done
    printf 'exit 0\n'
  } > "$1"
}
bt_in="$(safe_tmpdir)/timings.txt"
: > "$bt_in"
for row in slowa:60 slowb:50 slowc:40 slowd:30 mida:20 midb:20 midc:10 midd:10 \
           fasta:0 fastb:0 fastc:0; do
  name="${row%%:*}"; secs="${row#*:}"
  # the zeros are the largest files, so bytes-for-seconds puts them first
  if [ "$secs" = 0 ]; then bt_pad "$bt_dir/tests/$name.test.sh" 200
  else bt_pad "$bt_dir/tests/$name.test.sh" 48; fi
  printf 'tests/%s.test.sh %s\n' "$name" "$secs" >> "$bt_in"
done
bt_pad "$bt_dir/tests/newx.test.sh" 48   # absent from the timings: a new suite
bt_all=''; bt_max=0
for i in 1 2 3 4; do
  out="$(FM_ROOT="$bt_dir" FM_CI_TIMINGS_IN="$bt_in" bash "$ROOT/bin/ci.sh" --stage bash --shard "$i/4" 2>&1)"
  ran="$(shard_ran "$out")"
  bt_all="$bt_all$ran
"
  assert_contains "$out" "ci: shard $i/4: " "shard $i/4 prints what it predicts"
  assert_contains "$out" "longest suite tests/slowa.test.sh 60.0s" "and names the longest single suite"
  # the recorded seconds of the suites this shard ran
  load="$(printf '%s\n' "$ran" | awk 'NR==FNR{d[$1]=$2; next} $1 in d{s+=d[$1]} END{print s+0}' "$bt_in" -)"
  [ "$load" -le "$bt_max" ] || bt_max="$load"
  # a shard of nothing but zeros, or of nothing but the unrecorded suite,
  # is a shard that weighed bytes as seconds
  weighty="$(grep -cE '/(slow|mid)[a-z0-9-]\.test\.sh$' <<<"$ran" || true)"
  assert_ne "0" "$weighty" "shard $i/4 runs a suite recorded above 0, not only zeros or the new one"
done
want_list="$(cd "$bt_dir" && printf '%s\n' tests/*.test.sh | sort)"
got_list="$(printf '%s\n' "$bt_all" | sed '/^$/d' | sort)"
assert_eq "$want_list" "$got_list" "every suite still runs exactly once"
# 240s recorded over 4 shards: mean 60, longest suite 60, so no shard over 120
assert_ok "[ '$bt_max' -le 120 ]" "no shard's recorded load exceeds the mean by more than the longest suite (heaviest: ${bt_max}s)"
rm -rf "$bt_dir"

# The acceptance bar on the data it names: main's own per-suite timings from
# its last run before T-148 (run 36511784453 on 9e4194d, the suite-timings-*
# artifacts), 34 suites and 1693s, four of them recorded as whole-second 0s
# and padded to be the largest files, as on main. On those timings every
# shard's summary line names worker.test.sh's 539s as the longest suite and
# predicts no more than the mean plus the longest suite (1693/4 + 539), the
# recorded seconds of the suites its "+ path" lines ran stay under the same
# bar, and the four shards together run each of the 34 exactly once. The
# fail-first check of the old byte fallback is the synthetic test above.
mr_dir="$(fixture)"
mr_in="$(safe_tmpdir)/main-timings.txt"
cat > "$mr_in" <<'TIMINGS'
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
while read -r path secs; do
  if [ "$secs" = 0 ]; then bt_pad "$mr_dir/$path" 200
  else printf '#!/usr/bin/env bash\nexit 0\n' > "$mr_dir/$path"; fi
done < "$mr_in"
mr_bar="$(awk '{s += $2; if ($2 > m) m = $2} END {printf "%.1f", s / 4 + m}' "$mr_in")"
mr_all=''
for i in 1 2 3 4; do
  out="$(FM_ROOT="$mr_dir" FM_CI_TIMINGS_IN="$mr_in" bash "$ROOT/bin/ci.sh" --stage bash --shard "$i/4" 2>&1)"
  ran="$(shard_ran "$out")"
  mr_all="$mr_all$ran
"
  summary="$(grep -E "^ci: shard $i/4: " <<<"$out" || true)"
  assert_contains "$summary" "longest suite tests/worker.test.sh 539.0s" \
    "main's timings: shard $i/4 predicts in seconds, and names worker.test.sh's 539s as the longest suite"
  predicted="$(sed -n 's/.* predicted \([0-9.]*\)s;.*/\1/p' <<<"$summary")"
  assert_ok "awk 'BEGIN { exit !(\"$predicted\" != \"\" && \"$predicted\" + 0 <= $mr_bar) }'" \
    "main's timings: shard $i/4's predicted ${predicted:-?}s is within mean + longest (${mr_bar}s)"
  load="$(printf '%s\n' "$ran" | awk 'NR==FNR{d[$1]=$2; next} $1 in d{s+=d[$1]} END{print s+0}' "$mr_in" -)"
  assert_ok "[ '$load' -le '${mr_bar%.*}' ]" \
    "main's timings: the suites shard $i/4 ran add up to ${load}s, within mean + longest"
done
want_list="$(sed 's/ .*//' "$mr_in" | sort)"
got_list="$(printf '%s\n' "$mr_all" | sed '/^$/d' | sort)"
assert_eq "$want_list" "$got_list" "main's timings: the four shards run each of the 34 suites exactly once"
assert_eq "34" "$(grep -c . <<<"$got_list" || true)" "all 34 of them"

# --plan i/n -- <suite>... (T-158): the fail-first shards' share of the
# changed suites, by the split above, and nothing run. On main's timings,
# T-121's eight changed suites among them: every one lands in exactly one of
# 4 shards, worker.test.sh alone in the heaviest, and each shard's line for
# the bash shards is the split --shard makes of all 34.
pl_given=(tests/adapter-contract.test.sh tests/board.test.sh tests/config.test.sh tests/herdr.test.sh
          tests/option-loop.test.sh tests/review.test.sh tests/sandbox.test.sh tests/worker.test.sh)
pl_seen=''
for i in 1 2 3 4; do
  rc=0; out="$(FM_ROOT="$mr_dir" FM_CI_TIMINGS_IN="$mr_in" bash "$ROOT/bin/ci.sh" --plan "$i/4" -- "${pl_given[@]}" 2>/dev/null)" || rc=$?
  assert_eq "0" "$rc" "--plan $i/4 answers"
  assert_lacks "$out" "effective budget" "and runs nothing: no budget, no stage"
  for k in $(sed -n 's/^i //p' <<<"$out"); do pl_seen="$pl_seen${pl_given[$k]}
"; done
  assert_eq "4" "$(grep -c '^l ' <<<"$out" || true)" "--plan $i/4 gives each of the 4 bash shards' load"
  assert_contains "$out" "l 539.000 539.000 s" "the heaviest of which is worker.test.sh's shard, 539s"
  [ "$i" != 1 ] || assert_eq "p 539.000 539.000 s" "$(grep '^p ' <<<"$out" || true)" \
    "shard 1/4's own share is worker.test.sh alone"
done
assert_eq "$(printf '%s\n' "${pl_given[@]}" | sort)" "$(printf '%s' "$pl_seen" | sed '/^$/d' | sort)" \
  "--plan: the 4 shards take every given suite exactly once"
# a file below tests/ that is not a suite, and a suite that is not on disk,
# still land somewhere: the fail-first shards give it every changed test file
pl_seen=''
for i in 1 2 3; do
  out="$(FM_ROOT="$mr_dir" FM_CI_TIMINGS_IN="$mr_in" bash "$ROOT/bin/ci.sh" --plan "$i/3" -- tests/lib.sh tests/gone.test.sh tests/worker.test.sh 2>/dev/null)"
  pl_seen="$pl_seen$(sed -n 's/^i //p' <<<"$out")
"
done
assert_eq "0 1 2" "$(printf '%s' "$pl_seen" | sed '/^$/d' | sort -n | tr '\n' ' ' | sed 's/ $//')" \
  "--plan places a non-suite and a missing file too, each once"
# it follows FM_CI_TIMINGS_IN, as --shard does
pl_forced="$(safe_tmpdir)/forced.txt"
printf 'tests/cleanup.test.sh 900\ntests/worker.test.sh 1\n' > "$pl_forced"
out="$(FM_ROOT="$mr_dir" FM_CI_TIMINGS_IN="$pl_forced" bash "$ROOT/bin/ci.sh" --plan 1/2 -- tests/worker.test.sh tests/cleanup.test.sh 2>/dev/null)"
assert_eq "i 1" "$(grep '^i ' <<<"$out" || true)" "--plan follows the recorded timings: the 900s suite first, alone"
for bad in 0/2 3/2 x 2 /2; do
  rc=0; out="$(FM_ROOT="$mr_dir" bash "$ROOT/bin/ci.sh" --plan "$bad" -- tests/worker.test.sh 2>&1)" || rc=$?
  assert_eq "64" "$rc" "--plan $bad is refused"
  assert_contains "$out" "--plan must look like i/n" "with guidance"
done
rc=0; out="$(FM_ROOT="$mr_dir" bash "$ROOT/bin/ci.sh" --stage bash --plan 1/2 -- tests/worker.test.sh 2>&1)" || rc=$?
assert_eq "64" "$rc" "--plan with --stage is refused: it runs nothing"
rc=0; out="$(FM_ROOT='' bash "$ROOT/bin/ci.sh" --plan 1/2 -- tests/worker.test.sh 2>&1)" || rc=$?
assert_eq "64" "$rc" "--plan with FM_ROOT set but empty is refused, as the gate is"
rm -rf "$mr_dir"

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
job_names="$(awk '
  /^jobs:[[:space:]]*$/ { f = 1; next }
  f && /^  [a-zA-Z_-]+:[[:space:]]*$/ { line = $0; sub(/^  /, "", line); sub(/:.*$/, "", line); print line }
' "$gha")"
assert_ne "" "$job_names" "the workflow has jobs to check"
uncached=''
for j in $job_names; do
  block="$(awk -v want="  $j:" '
    $0 == want { f = 1; next }
    f && /^  [a-zA-Z_-]+:[[:space:]]*$/ { exit }
    f { print }
  ' "$gha")"
  grep -q "bun install" <<< "$block" || continue
  install_line="$(printf '%s\n' "$block" | grep -n "bun install" | head -1 | cut -d: -f1)"
  cache_line="$(printf '%s\n' "$block" | grep -n "actions/cache" | head -1 | cut -d: -f1)"
  key_line="$(printf '%s\n' "$block" | grep -n "bun\.lock" | head -1 | cut -d: -f1)"
  if [ -z "$cache_line" ] || [ -z "$key_line" ] || [ "$cache_line" -ge "$install_line" ]; then
    uncached="$uncached $j"
  fi
done
assert_eq "" "$uncached" "every job that runs bun install caches bun's install cache first, keyed on bun.lock"

e2e_block="$(awk '
  $0 == "  e2e:" { f = 1; next }
  f && /^  [a-zA-Z_-]+:[[:space:]]*$/ { exit }
  f { print }
' "$gha")"
assert_contains "$e2e_block" "ms-playwright" "the e2e job also caches the playwright browser"

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
