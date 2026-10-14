#!/usr/bin/env bash
# ci: balanced shards (T-306, T-307). Main went red when a shard ran past its
# 600-second budget: it was split by one run's timings, its pool started
# suites by name and size, and one suite alone took up to 526 s. The split
# now takes each suite's median over main's last runs, the pool starts the
# slowest first, and that suite is two. After that, shard 6 still took 657 s
# on main run 38454069859: a suite no run had recorded was weighed at 23 s
# and started last, and took 244 s. bin/lib/fm_ci_shards.py is now the one
# split bin/ci.sh and tests/lib/ci_shard_model.py both run, on that run's
# timings (tests/lib/fixtures/ci-shards-38454069859).
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=tests/lib.sh
. "$ROOT/tests/lib.sh"
t="$(safe_tmpdir)"
trap 'safe_rm_rf "$t"' EXIT
gha="$ROOT/.github/workflows/ci.yml"

# The shard count and budget the replay holds are the workflow's own.
shards="$(sed -n 's/^ *shard: \[\(.*\)\]$/\1/p' "$gha" | head -1 | tr -cd ',' | wc -c | tr -d ' ')"
shards=$((shards + 1))
assert_eq "6" "$shards" "the bash suites still run in 6 shards"
assert_contains "$(cat "$gha")" 'FM_CI_MAX_SECONDS: "600"' "and each shard keeps its 600-second budget"

fx="$ROOT/tests/lib/fixtures/ci-shards-38454069859"
cat "$fx"/suite-timings-*.txt > "$t/run.txt"
# What that run's own split (suite-assigned-*) cost, for the log: its
# shards' recorded seconds were far apart, though CI predicted them equal.
for i in $(seq 1 "$shards"); do
  sed 1d "$fx/suite-assigned-$i.txt" | awk -v i="$i" 'NR == FNR {d[$1] = $2; next} {s += d[$1]} END {printf "      run 38454069859 shard %d: %.0fs summed\n", i, s}' "$t/run.txt" -
done

# The timings of main's latest green runs, through the code CI runs: every
# shard predicted at most 520 s of job time, the slowest at most 120 s over
# the fastest, and bin/ci.sh --plan gives each shard the same suites and
# job time as the model.
rc=0
out="$(python3 "$ROOT/tests/lib/ci_shard_model.py" --root "$ROOT" --timings "$t/run.txt" \
  --shards "$shards" --limit 520 --gap 120 2>&1)" || rc=$?
printf '%s\n' "$out" | sed 's/^/      /'
assert_eq "0" "$rc" "ci: shard split matches model: every suite in one shard, bin/ci.sh agrees, no shard predicted over 520 s, gap at most 120 s"
assert_eq "$shards" "$(grep -c '^shard ' <<<"$out" || true)" "ci: shard split matches model: every shard is reported"
assert_lacks "$out" "ci: shard split:" "ci: shard split matches model: no suite misplaced, no disagreement with bin/ci.sh"
# The same check on the input CI really read for that run: its last five
# green runs on main, which never recorded tests/door-projects.test.sh.
# Replayed on the seconds that run took, no shard goes over 520 s either.
awk -F'\t' 'NR == 1 || /^#/ {next} $1 == "suite" {for (k = 2; k <= NF; k++) if ($k ~ /^(38404511160|38397698016|38296822603|38263343674|38242844766)$/) want[k] = 1; next}
  {for (k in want) if ($k != "-") print $1, $k}' "$ROOT/tests/lib/ci-shard-timings.tsv" > "$t/ci-input.txt"
assert_lacks "$(cat "$t/ci-input.txt")" "door-projects" "the input CI read for run 38454069859 has no time for tests/door-projects.test.sh"
rc=0
out="$(python3 "$ROOT/tests/lib/ci_shard_model.py" --root "$ROOT" --timings "$t/ci-input.txt" --replay "$t/run.txt" \
  --shards "$shards" --limit 520 --gap 120 2>&1)" || rc=$?
printf '%s\n' "$out" | sed 's/^/      /'
assert_eq "0" "$rc" "ci: shard split matches model: CI's own input for run 38454069859 splits within the limits"
over="$(sed -n 's/.*replayed on --replay \([0-9]*\)s.*/\1/p' <<<"$out" | awk '$1 > 520' | head -1)"
assert_eq "" "$over" "ci: shard split matches model: replayed on that run's seconds, no shard over 520 s"

# A suite with no recorded time is neither weighed as a light one nor
# started late: without its line, tests/door-projects.test.sh weighs at
# least the 90th percentile of the recorded suites and its shard's pool
# starts it first.
grep -v '^tests/door-projects.test.sh ' "$t/run.txt" > "$t/new-suite.txt"
all=()
while IFS= read -r f; do all+=("$f"); done < <(cd "$ROOT" && printf '%s\n' tests/*.test.sh)
door=''
for k in "${!all[@]}"; do [ "${all[$k]}" != tests/door-projects.test.sh ] || door="$k"; done
first=''; floor="$(cut -d' ' -f2 "$t/new-suite.txt" | sort -n | awk '{v[NR] = $1} END {k = int(0.9 * NR); if (k < 0.9 * NR) k++; print v[k]}')"
for i in $(seq 1 "$shards"); do
  plan="$(FM_ROOT="$ROOT" FM_CI_TIMINGS_IN="$t/new-suite.txt" bash "$ROOT/bin/ci.sh" --plan "$i/$shards" -- "${all[@]}" 2>/dev/null)"
  if grep -qx "i $door" <<<"$plan"; then first="$(grep -m1 '^i ' <<<"$plan")"; fi
done
assert_eq "i $door" "$first" "ci: shard split matches model: a suite with no recorded time starts first in its shard"
rc=0
python3 - "$ROOT" "$t/new-suite.txt" "$floor" <<'PY' || rc=$?
import sys
sys.path.insert(0, sys.argv[1] + '/bin/lib')
import fm_ci_shards
from pathlib import Path
root = Path(sys.argv[1])
suites = sorted(str(p.relative_to(root)) for p in (root / 'tests').glob('*.test.sh'))
est, _ = fm_ci_shards.estimates(root, suites, fm_ci_shards.read_timings(sys.argv[2]))
sys.exit(0 if est[suites.index('tests/door-projects.test.sh')][0] >= float(sys.argv[3]) else 1)
PY
assert_eq "0" "$rc" "ci: shard split matches model: and weighs at least the recorded suites' 90th percentile (${floor}s), not its size estimate"
rc=0
out="$(python3 "$ROOT/tests/lib/ci_shard_model.py" --root "$ROOT" --timings "$t/new-suite.txt" --replay "$t/run.txt" \
  --shards "$shards" --limit 520 --gap 120 2>&1)" || rc=$?
assert_eq "0" "$rc" "ci: shard split matches model: the split without its time still meets the limits"
over="$(sed -n 's/.*replayed on --replay \([0-9]*\)s.*/\1/p' <<<"$out" | awk '$1 > 520' | head -1)"
assert_eq "" "$over" "ci: shard split matches model: and replayed with its real 244 s, no shard goes over 520 s"

# A split parent loses the share its new, unrecorded child takes, as the
# child is weighed with it: parent 100 s and a half share each weigh 50 s,
# so the two go to different shards of two and neither is 100 s.
mkdir -p "$t/split/tests/lib"
for s in parent child a b c d e f g h i; do printf '#!/usr/bin/env bash\nexit 0\n' > "$t/split/tests/$s.test.sh"; done
printf '%s\n' 'tests/child.test.sh tests/parent.test.sh 0.5' > "$t/split/tests/lib/suite-splits.tsv"
{ echo 'tests/parent.test.sh 100'; for s in a b c d e f g h i; do echo "tests/$s.test.sh 10"; done; } > "$t/split/timings"
for i in 1 2; do
  out="$(FM_ROOT="$t/split" FM_CI_TIMINGS_IN="$t/split/timings" bash "$ROOT/bin/ci.sh" --plan "$i/2" -- \
    tests/parent.test.sh tests/child.test.sh 2>/dev/null)"
  assert_eq "p 50.000 50.000 s" "$(grep '^p ' <<<"$out" || true)" "ci: shard split matches model: shard $i/2 holds one half of the split parent, 50 s"
done

# The split takes each suite's median, not the last line naming it: one
# slow run of slow.test.sh among three must not set its weight.
mkdir -p "$t/median/tests"
for s in slow other third; do printf '#!/usr/bin/env bash\nexit 0\n' > "$t/median/tests/$s.test.sh"; done
printf '%s\n' 'tests/slow.test.sh 100' 'tests/slow.test.sh 100' 'tests/slow.test.sh 10' \
  'tests/other.test.sh 50' 'tests/third.test.sh 60' > "$t/median/timings"
out="$(FM_ROOT="$t/median" FM_CI_TIMINGS_IN="$t/median/timings" bash "$ROOT/bin/ci.sh" --plan 1/2 -- \
  tests/slow.test.sh tests/other.test.sh tests/third.test.sh 2>/dev/null)"
assert_eq "i 0" "$(grep '^i ' <<<"$out" || true)" "ci: balanced shards: a suite's median of its runs (100 s) sets its shard, alone"
assert_contains "$out" "p 100.000 100.000 s" "ci: balanced shards: not its last run (10 s)"

# The pool starts a shard's suites slowest first by the same estimates, not
# by family name or file size: with two at a time, the suite recorded
# fastest is the one left to start last, though it is the largest file and
# the other two are a worker suite and the smallest file.
mkdir -p "$t/pool/tests"
for s in worker-a big small; do
  printf '#!/usr/bin/env bash\necho %s >> "$POOL_LOG"\nsleep 1\n' "$s" > "$t/pool/tests/$s.test.sh"
done
for _ in $(seq 1 200); do printf '# padding to make this the largest file on disk\n'; done >> "$t/pool/tests/big.test.sh"
printf '%s\n' 'tests/small.test.sh 100' 'tests/worker-a.test.sh 50' 'tests/big.test.sh 1' > "$t/pool/timings"
rc=0
out="$(POOL_LOG="$t/pool/log" FM_CI_JOBS=2 FM_ROOT="$t/pool" FM_CI_TIMINGS_IN="$t/pool/timings" \
  bash "$ROOT/bin/ci.sh" --stage bash 2>&1)" || rc=$?
assert_eq "0" "$rc" "the pool fixture's suites pass"
assert_eq "big" "$(tail -1 "$t/pool/log" 2>/dev/null)" "ci: balanced shards: the pool starts the suite recorded fastest last"
assert_eq "small worker-a" "$(head -2 "$t/pool/log" 2>/dev/null | sort | tr '\n' ' ' | sed 's/ $//')" \
  "ci: balanced shards: and the two recorded slowest first"

# Both reads of the timings take main's last five green runs, each run's
# artifacts kept apart, so the median has runs to take.
for job in bash-timings fail-first-timings; do
  block="$(awk -v j="  $job:" '$0 == j {f = 1; next} f && /^  [a-zA-Z_-]+:[[:space:]]*$/ {f = 0} f' "$gha")"
  assert_contains "$block" "--limit 5" "ci: balanced shards: $job reads the last five green runs on main"
  assert_contains "$block" '-D "/tmp/timings/$run_id"' "ci: balanced shards: $job keeps each run's timings apart"
done
finish
