#!/usr/bin/env bash
# Feature dependencies: bin/lib/fm_adopt.py bin/lib/fm_binding.py bin/fm-worker.sh
# bin/lib/fm_spec_pins.py bin/lib/fm_spec_preflight.py tests/lib/external_rebuild.py
# tests/lib/external_registry.py bin/lib/fm_autopilot.py bin/lib/fm_autopilot_loop.py
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
. "$ROOT/tests/lib.sh"
python3 "$ROOT/tests/lib/external_adopt.py" "$ROOT"
assert_eq 0 "$?" 'external adoption preserves human work and pinned base authority'
python3 - "$ROOT" <<'PYCASE'
import sys
from pathlib import Path
from unittest.mock import patch
sys.dont_write_bytecode = True
sys.path.insert(0, str(Path(sys.argv[1]) / 'bin/lib'))
import fm_adopt
view = dict(state='OPEN', isCrossRepository=False, headRefName='feature/t-001-x',
            headRefOid='a'*40, baseRefName='release', title='Public change')
adopt = dict(pr=9, head='a'*40, base='release')
with patch.object(fm_adopt, 'scan', return_value=({}, {}, {})):
    fm_adopt.check(view, adopt, 'T-001', dict(FM_EXTERNAL='1'), Path('.'), True, [])
    try:
        fm_adopt.check(view, adopt, 'T-002', dict(FM_EXTERNAL='1'), Path('.'), True, [])
    except ValueError as error:
        assert 'names another task' in str(error), error
    else:
        raise AssertionError('prefixed branch must refuse adoption by another task')
PYCASE
assert_eq 0 "$?" 'prefixed branch adoption preserves task ownership'
finish
