#!/usr/bin/env bash
# Synchronization now belongs to the autopilot's conditional REST polling.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
export HERDR_ENV=0
python3 "$ROOT/tests/lib/autopilot_sync.py" "$ROOT"
