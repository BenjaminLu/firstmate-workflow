#!/usr/bin/env bash
# Feature dependencies: tests/lib/preflight_lifecycle.py bin/fm-herdr.py
# bin/lib/fm_autopilot.py bin/lib/fm-spec-preflight.sh
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
. "$ROOT/tests/lib.sh"
python3 "$ROOT/tests/lib/preflight_lifecycle.py" "$ROOT"
assert_eq 0 "$?" 'preflight loss is visible but neutral to tasks, rounds and wakes'
finish
