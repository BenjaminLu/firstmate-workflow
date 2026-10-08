#!/usr/bin/env bash
# Shared feature cases: tests/lib/evidence_summary.py
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
. "$ROOT/tests/lib.sh"
d="$(safe_tmpdir)"
trap 'safe_rm_rf "$d"' EXIT
python3 "$ROOT/tests/lib/evidence_summary.py" "$d"
assert_eq 0 "$?" 'evidence summary verifies records and excludes bodies and readiness review'
finish
