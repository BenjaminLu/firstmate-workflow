#!/usr/bin/env bash
# T-293: an interrupted autopilot job resumes from its breakpoint.
# Shared fixtures: tests/lib/autopilot_loop.py tests/lib/autopilot_branch_fixture.py tests/lib/autopilot_stale_jobs.py
# Consumes bin/lib/fm_autopilot.py and bin/lib/fm_autopilot_loop.py.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
export HERDR_ENV=0
python3 "$ROOT/tests/lib/autopilot_interrupted_jobs.py" "$ROOT"
