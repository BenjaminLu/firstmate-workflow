#!/usr/bin/env bash
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
export HERDR_ENV=0
python3 "$ROOT/tests/lib/autopilot_jobs.py" "$ROOT"
