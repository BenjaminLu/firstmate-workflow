#!/usr/bin/env bash
# T-277: small-change records for exact test/docs paths and spec typos.
# Shared fixtures: tests/lib/small_change_cases.py tests/lib/autopilot_merge_path.py tests/lib/autopilot_loop.py tests/lib/autopilot_branch_fixture.py tests/lib/ste_cases.py
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
. "$ROOT/tests/lib.sh"
export HERDR_ENV=0
python3 "$ROOT/tests/lib/small_change_cases.py" "$ROOT"
assert_eq 0 "$?" 'small-change records widen gate 3, prompts and merge cards only as specified'
finish
