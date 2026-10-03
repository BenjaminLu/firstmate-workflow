#!/usr/bin/env bash
# Startup cursors and real gh exit-status semantics; no network access.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
. "$ROOT/tests/lib.sh"
python3 "$ROOT/tests/lib/autopilot_startup_cache.py" "$ROOT"
assert_eq 0 "$?" 'autopilot starts from now and accepts conditional 304 responses'
finish
