#!/usr/bin/env bash
# T-276: review findings say whether they block approval.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=tests/lib.sh
. "$ROOT/tests/lib.sh"
export HERDR_ENV=0
# Shared Python fixtures: tests/lib/review_severity.py, tests/lib/autopilot_branch_fixture.py
python3 "$ROOT/tests/lib/review_severity.py" "$ROOT"
assert_eq 0 "$?" 'severity tags, protocol, gate, follow-ups, brief deferral and autopilot cases pass'
finish
