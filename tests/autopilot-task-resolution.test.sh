#!/usr/bin/env bash
# T-180: head-only specs and current unanswered local questions.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
export HERDR_ENV=0
python3 "$ROOT/tests/lib/autopilot_task_resolution.py" "$ROOT"
