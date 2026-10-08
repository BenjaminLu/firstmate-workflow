#!/usr/bin/env bash
# T-252: checked merge details and one draft wake per head.
# Shared fixtures: tests/lib/autopilot_loop.py tests/lib/autopilot_branch_fixture.py tests/lib/ste_cases.py
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
export HERDR_ENV=0
python3 "$ROOT/tests/lib/autopilot_merge_path.py" "$ROOT"
