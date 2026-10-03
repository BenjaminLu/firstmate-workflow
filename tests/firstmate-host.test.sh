#!/usr/bin/env bash
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
. "$ROOT/tests/lib.sh"
python3 "$ROOT/tests/lib/firstmate_host.py" "$ROOT"
assert_eq 0 "$?" 'firstmate host recording and opposite vendor routing'
finish
