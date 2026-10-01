#!/usr/bin/env bash
# Split suites inherit their parent's recorded time until main measures them.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=tests/lib.sh
. "$ROOT/tests/lib.sh"
t="$(safe_tmpdir)"
trap 'safe_rm_rf "$t"' EXIT
mkdir -p "$t/tests/lib"
printf '#!/usr/bin/env bash\nexit 0\n' > "$t/tests/worker-alpha.test.sh"
cp "$t/tests/worker-alpha.test.sh" "$t/tests/worker-beta.test.sh"
printf 'tests/worker.test.sh 120\n' > "$t/timings"
printf 'tests/worker-alpha.test.sh tests/worker.test.sh 0.25\ntests/worker-beta.test.sh tests/worker.test.sh 0.75\n' > "$t/tests/lib/suite-splits.tsv"
out="$(FM_ROOT="$t" FM_CI_TIMINGS_IN="$t/timings" bash "$ROOT/bin/ci.sh" --plan 1/2 -- tests/worker-alpha.test.sh tests/worker-beta.test.sh)"
assert_contains "$out" 'p 90.000 90.000 s' "new feature inherits its share of the old suite's seconds"
assert_contains "$out" 'i 1' "the larger split goes on the first shard"
printf 'tests/worker-beta.test.sh 45\n' >> "$t/timings"
out="$(FM_ROOT="$t" FM_CI_TIMINGS_IN="$t/timings" bash "$ROOT/bin/ci.sh" --plan 1/2 -- tests/worker-alpha.test.sh tests/worker-beta.test.sh)"
assert_contains "$out" 'p 45.000 45.000 s' "a measured split replaces its estimate"
# A malformed share cannot turn a recorded parent into invented seconds.
printf 'tests/worker-alpha.test.sh tests/worker.test.sh garbage\n' > "$t/tests/lib/suite-splits.tsv"
out="$(FM_ROOT="$t" FM_CI_TIMINGS_IN="$t/timings" bash "$ROOT/bin/ci.sh" --plan 1/2 -- tests/worker-alpha.test.sh tests/worker-beta.test.sh)"
assert_lacks "$out" 'p 0.000' "an invalid split share falls back to the ordinary size estimate"
# Shared fixtures are linted too; moving unsafe allocation into lib cannot hide it.
printf '#!/usr/bin/env bash\nwork="$(%s -d)"\n' mktemp > "$t/tests/lib/unsafe.sh"
rc=0; out="$(FM_ROOT="$t" bash "$ROOT/bin/ci.sh" --stage fast 2>&1)" || rc=$?
assert_eq "1" "$rc" "a shared fixture with a bare mktemp fails the fast stage"
assert_contains "$out" 'a bare, template-less mktemp' "moving a bare mktemp into a helper cannot evade the lint"
assert_contains "$out" 'tests/lib/unsafe.sh' "the lint names the unsafe shared fixture"
# The canonical PATH fixture must pass the scratch-path lint. Keep the helper
# in every lint's input, including after a caller plants an unsafe assignment.
rm "$t/tests/lib/unsafe.sh"
cp "$ROOT/tests/lib/path.sh" "$t/tests/lib/path.sh"
out="$(FM_ROOT="$t" bash "$ROOT/bin/ci.sh" --stage fast 2>&1)"
assert_lacks "$out" 'a scratch path resolves itself' "the checked PATH fixture passes scratch-path lint"
printf 'scratch="$(cd "$%s" && pwd)"\n' scratch > "$t/tests/lib/unsafe.sh"
out="$(FM_ROOT="$t" bash "$ROOT/bin/ci.sh" --stage fast 2>&1)"
assert_contains "$out" 'a scratch path resolves itself' "unsafe helper callers still fail scratch-path lint"
assert_contains "$out" 'tests/lib/unsafe.sh:1:' "scratch-path lint names the unsafe helper caller"
# The canonical filename grants no blanket exemption from other lint rules.
printf '#!/usr/bin/env bash\nwork="$(%s -d)"\n' mktemp >> "$t/tests/lib/path.sh"
out="$(FM_ROOT="$t" bash "$ROOT/bin/ci.sh" --stage fast 2>&1)"
assert_contains "$out" 'a bare, template-less mktemp' "the PATH helper remains covered by allocation lint"
assert_contains "$out" 'tests/lib/path.sh:' "allocation lint names an unsafe canonical helper"
workflow="$(cat "$ROOT/.github/workflows/ci.yml")"
assert_eq "2" "$(grep -cF 'shard: [1, 2, 3, 4, 5, 6]' <<<"$workflow")" \
  "both bash and fail-first use six shards"
assert_lacks "$workflow" '${{ matrix.shard }}/4' "no workflow command still selects four shards"
oversized="$(python3 - "$ROOT/tests" <<'PYCOUNT'
from pathlib import Path
import sys
for p in Path(sys.argv[1]).rglob('*'):
    if p.is_file() and len(p.read_bytes().splitlines()) > 1200:
        print(p)
PYCOUNT
)"
assert_eq "" "$oversized" "every file under tests stays within 1200 lines"
finish
