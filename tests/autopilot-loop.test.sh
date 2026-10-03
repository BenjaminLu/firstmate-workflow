#!/usr/bin/env bash
# T-175: the resident supervisor owns PR advancement.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
export HERDR_ENV=0
python3 "$ROOT/tests/lib/autopilot_loop.py" "$ROOT"
