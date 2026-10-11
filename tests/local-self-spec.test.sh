#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# Literal dependencies: bin/lib/fm_spec_pins.py
# bin/lib/fm_binding.py bin/lib/fm_autopilot.py tests/lib/spec_pins_cases.py
# bin/lib/fm_merge_details.py bin/lib/fm_evidence.py bin/fm-decide.sh
python3 "$ROOT/tests/lib/local_self_spec.py" "$ROOT"
