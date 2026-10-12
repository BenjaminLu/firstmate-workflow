#!/usr/bin/env bash
# The spec preflight is removed (T-297). What stays: the spec checks it ran
# before its reviewer, now at pin time, and the readers of its old receipts.
# Feature dependencies: bin/fm-herdr.py bin/lib/fm_spec_preflight.py
# bin/lib/fm_spec_pins.py bin/lib/fm_evidence.py bin/lib/fm_public_text.py
# bin/lib/fm_ste.py bin/lib/fm_adopt.py bin/lib/fm_sandbox_policy.py
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
. "$ROOT/tests/lib.sh"
export HERDR_ENV=0
python3 "$ROOT/tests/lib/spec_preflight_cases.py" "$ROOT"
assert_eq 0 "$?" 'spec checks and stored preflight receipts read as before'
python3 "$ROOT/tests/lib/external_adopt.py" "$ROOT" pin
assert_eq 0 "$?" 'adopt schema refuses malformed and self specs at pin time'
finish
