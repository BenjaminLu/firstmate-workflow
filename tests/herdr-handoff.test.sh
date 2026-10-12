#!/usr/bin/env bash
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=tests/lib/herdr.sh
. "$ROOT/tests/lib/herdr.sh"
# Shared Python fixtures: tests/lib/herdr.py tests/lib/fixture_plan.sh
PYTHONPATH="$ROOT/tests/lib${PYTHONPATH:+:$PYTHONPATH}" python3 "$ROOT/tests/herdr/handoff.py" "$ROOT"

