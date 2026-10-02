#!/usr/bin/env bash
# T-049: behavioral snapshot authorization and scope checks (no live services).
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
. "$ROOT/tests/lib.sh"
python3 "$ROOT/tests/lib/spec_pins_cases.py" "$ROOT"
assert_eq 0 "$?" 'spec pins enforce immutable scope and approval provenance'
finish
