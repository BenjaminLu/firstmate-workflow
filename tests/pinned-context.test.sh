#!/usr/bin/env bash
# Complete round snapshots; tests/lib/pinned_context.py owns the fixtures.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
. "$ROOT/tests/lib.sh"
python3 "$ROOT/tests/lib/pinned_context.py" "$ROOT"
assert_eq 0 "$?" 'pinned context preserves complete snapshots and confines access'
finish
