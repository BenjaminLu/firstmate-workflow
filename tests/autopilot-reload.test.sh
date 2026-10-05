#!/usr/bin/env bash
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
. "$ROOT/tests/lib.sh"
python3 "$ROOT/tests/lib/autopilot_reload.py" "$ROOT"
assert_eq 0 "$?" 'autopilot drains and reloads from committed engine code'
finish
