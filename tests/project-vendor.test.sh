#!/usr/bin/env bash
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=tests/lib.sh
. "$ROOT/tests/lib.sh"
python3 "$ROOT/tests/lib/project_vendor.py" "$ROOT"
assert_eq 0 "$?" 'private project vendor, fallback, model and binding'
finish
