#!/usr/bin/env bash
# ci: balanced shards (T-306). Main went red when a shard ran past its
# 600-second budget: it was split by one run's timings, its pool started
# suites by name and size, and one suite alone took up to 526 s. The split
# now takes each suite's median over main's last runs, the pool starts the
# slowest first, and that suite is two. tests/lib/ci_shard_model.py replays
# 15 recorded runs (tests/lib/ci-shard-timings.tsv) through bin/ci.sh's own
# split and holds every shard to a 480 s average and a 560 s peak.
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

rc=0
out="$(python3 "$ROOT/tests/lib/ci_shard_model.py" --root "$ROOT" --timings "$ROOT/tests/lib/ci-shard-timings.tsv" \
  --shards "$shards" --jobs 4 --overhead 60 --average 480 --peak 560 2>&1)" || rc=$?
printf '%s\n' "$out" | sed 's/^/      /'
assert_eq "0" "$rc" "ci: balanced shards: every suite in exactly one shard, no shard over a 480 s average or a 560 s peak on 15 recorded runs"
assert_eq "$shards" "$(grep -c '^shard ' <<<"$out" || true)" "ci: balanced shards: the replay reports every shard"
assert_lacks "$out" " shards" "ci: balanced shards: no suite is in no shard or in two"

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
