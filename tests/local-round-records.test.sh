#!/usr/bin/env bash
# Feature-owned tests; suites are run by CI and gate 5, never by a worker.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=tests/lib.sh
. "$ROOT/tests/lib.sh"
python3 "$ROOT/tests/lib/local_round_records.py" "$ROOT"
assert_eq 0 "$?" 'local round records preserve authority and closed lists'
finish
