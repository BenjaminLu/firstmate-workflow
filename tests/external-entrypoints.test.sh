#!/usr/bin/env bash
# T-051: real entrypoints enforce external publication and cleanup boundaries.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=tests/lib.sh
. "$ROOT/tests/lib.sh"
# Shared local-repository fixture: tests/lib/external_entrypoints.py
# Registry dependency: tests/lib/external_registry.py
python3 "$ROOT/tests/lib/external_entrypoints.py" "$ROOT"
assert_eq 0 "$?" "external cleanup, reconcile and checkpoint enforce project boundaries"
finish
