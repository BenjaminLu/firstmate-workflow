#!/usr/bin/env bash
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
export HERDR_ENV=0
# Consumes bin/lib/fm_autopilot.py, bin/lib/fm_autopilot_loop.py,
# bin/lib/fm_autopilot_branches.py and bin/lib/fm_autopilot_queue.py.
python3 "$ROOT/tests/lib/autopilot_queue.py" "$ROOT"
