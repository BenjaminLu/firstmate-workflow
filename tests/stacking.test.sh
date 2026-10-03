#!/usr/bin/env bash
# T-143: policy, dependency selection, per-PR bases and safe retention.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
. "$ROOT/tests/lib.sh"
export PYTHONPATH="$ROOT/bin/lib"
cases="$(python3 "$ROOT/tests/stacking_cases.py" --list)" || exit 1
for case_name in $cases; do
  python3 "$ROOT/tests/stacking_cases.py" "$case_name"
  assert_eq 0 "$?" "stacking: $case_name"
done
finish
