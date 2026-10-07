#!/usr/bin/env bash
# Feature dependencies: bin/lib/fm_adopt.py
# Shared branch fixture: tests/lib/autopilot_branch_fixture.py
# Feature-owned synthetic event tests; never contacts GitHub.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
. "$ROOT/tests/lib.sh"
python3 "$ROOT/tests/lib/autopilot_cases.py" "$ROOT"
assert_eq 0 "$?" 'autopilot recorded events and GitHub payloads'
finish
