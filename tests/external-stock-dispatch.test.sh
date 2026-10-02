#!/usr/bin/env bash
# Real stock dispatcher and worker, local git remote, scripted adapter only.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=tests/lib.sh
. "$ROOT/tests/lib.sh"
# Shared fixture and writer-pushed synchronization: tests/lib/external_stock.py
# Registry dependency: tests/lib/external_registry.py
python3 "$ROOT/tests/lib/external_stock.py" "$ROOT"
assert_eq 0 "$?" "stock external worker survives dispatcher exit and publishes only target work"
finish
