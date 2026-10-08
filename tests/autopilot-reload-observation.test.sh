#!/usr/bin/env bash
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
. "$ROOT/tests/lib.sh"
# Dependencies: tests/lib/autopilot_reload_observation.py tests/lib/autopilot_reload.py
python3 "$ROOT/tests/lib/autopilot_reload_observation_cases.py" "$ROOT" "$@"
assert_eq 0 "$?" 'reload observations wait across publication and report fixture timeouts'
finish
