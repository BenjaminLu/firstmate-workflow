#!/usr/bin/env bash
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=tests/lib/ci.sh
. "$ROOT/tests/lib/ci.sh"
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


PATH="$suite_original_path"; export PATH
safe_rm_rf "$suite_tools"
finish
