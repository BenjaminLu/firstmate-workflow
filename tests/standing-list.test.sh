#!/usr/bin/env bash
# T-181: only the final standing block supplies protocol items and gate 7.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
. "$ROOT/tests/lib.sh"
t="$(safe_tmpdir)"
python3 "$ROOT/tests/lib/standing_list.py" "$ROOT" "$t"
assert_eq 0 "$?" 'standing block ignores summaries while preserving protocol and gate 7 checks'
safe_rm_rf "$t"
finish
