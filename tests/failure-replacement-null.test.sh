#!/usr/bin/env bash
# Production dependencies: bin/lib/fm_autopilot_loop.py bin/lib/fm_autopilot.py bin/fm-emit.sh
# Fixture dependencies: tests/lib/failure_replacement_null.py tests/lib/autopilot_loop.py tests/lib/autopilot_merge_path.py tests/lib/autopilot_branch_fixture.py tests/lib/ste_cases.py
set -uo pipefail
export HERDR_ENV=0
export PYTHONDONTWRITEBYTECODE=1
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
python3 "$ROOT/tests/lib/failure_replacement_null.py" "$ROOT" "$@"
