#!/usr/bin/env bash
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
. "$ROOT/tests/lib.sh"
d="$(safe_tmpdir)"
trap 'safe_rm_rf "$d"' EXIT
# Literal dependencies: tests/lib/ste_cases.py, bin/lib/fm_ste.py,
# bin/lib/fm_config_tasks.py, bin/lib/fm_spec_preflight.py.
python3 "$ROOT/tests/lib/spec_explain_cases.py" "$d"
assert_eq 0 "$?" 'explain validates structure, prose, config and preflight with optional imports'
finish
