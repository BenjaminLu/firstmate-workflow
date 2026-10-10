#!/usr/bin/env bash
# T-282: a gate stopped at gate 5 only by tracked CI still running raises no wake.
# Shared fixtures: tests/lib/autopilot_loop.py tests/lib/autopilot_branch_fixture.py tests/lib/autopilot_queue.py
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
export HERDR_ENV=0
status=0
python3 "$ROOT/tests/lib/gate_ci_pending.py" "$ROOT" || status=1
python3 "$ROOT/tests/lib/gate_ci_pending_queue.py" "$ROOT" || status=1
exit "$status"
