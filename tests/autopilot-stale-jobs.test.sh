#!/usr/bin/env bash
# T-281: a stale uncertain job settles itself; a stuck approved PR wakes once.
# Shared fixtures: tests/lib/autopilot_loop.py tests/lib/autopilot_branch_fixture.py tests/lib/autopilot_queue.py
# Consumes bin/lib/fm_autopilot.py and bin/lib/fm_autopilot_loop.py.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
export HERDR_ENV=0
rc=0
python3 "$ROOT/tests/lib/autopilot_stale_jobs.py" "$ROOT" || rc=1
python3 "$ROOT/tests/lib/autopilot_stale_jobs_queue.py" "$ROOT" || rc=1
exit "$rc"
