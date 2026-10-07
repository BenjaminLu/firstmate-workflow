#!/usr/bin/env bash
# Feature dependencies: bin/lib/fm_adopt.py bin/lib/fm_binding.py bin/fm-worker.sh
# bin/lib/fm_spec_pins.py bin/lib/fm_spec_preflight.py tests/lib/external_rebuild.py
# tests/lib/external_registry.py bin/lib/fm_autopilot.py bin/lib/fm_autopilot_loop.py
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
. "$ROOT/tests/lib.sh"
python3 "$ROOT/tests/lib/external_adopt.py" "$ROOT"
assert_eq 0 "$?" 'external adoption preserves human work and pinned base authority'
finish
