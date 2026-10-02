#!/usr/bin/env bash
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=tests/lib.sh
. "$ROOT/tests/lib.sh"
python3 "$ROOT/tests/lib/context_pack.py" "$ROOT"
assert_eq 0 "$?" 'context packs expose evidence and warn by situation'
finish
