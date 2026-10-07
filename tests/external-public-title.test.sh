#!/usr/bin/env bash
# Feature dependency: bin/lib/fm_pr_format.py
# Dependencies: bin/lib/fm_public_text.py bin/lib/fm_spec_preflight.py bin/lib/fm_ste.py
# bin/fm-worker.sh tests/lib/crew_blocks.py tests/lib/external_public_title.py
# tests/lib/external_stock.py tests/lib/external_registry.py tests/lib/spec-preflight.sh
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
. "$ROOT/tests/lib.sh"
python3 "$ROOT/tests/lib/external_public_title.py" "$ROOT"
assert_eq 0 "$?" 'validated public text, private fallback and guarded later-round retitle'
python3 - "$ROOT" <<'PY'
import sys
sys.dont_write_bytecode = True
sys.path.insert(0, sys.argv[1] + '/tests/lib')
from external_stock import scenario
scenario(public_title='Draw the fixture widget in blue')
PY
assert_eq 0 "$?" 'external public text leaves the engine repository clean'
finish
