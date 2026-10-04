#!/usr/bin/env bash
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=tests/lib/ci.sh
. "$ROOT/tests/lib/ci.sh"
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
# shellcheck source=tests/lib/config-modules.sh
. "$ROOT/tests/lib/config-modules.sh"
p="$(safe_tmpdir)"; mkdir -p "$p/bin"; cp "$ROOT/bin/ci.sh" "$ROOT/bin/fm-config.sh" "$p/bin/"; config_modules_fixture "$p/bin/"
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


PATH="$suite_original_path"; export PATH
safe_rm_rf "$suite_tools"
finish
