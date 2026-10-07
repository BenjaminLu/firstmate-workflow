#!/usr/bin/env bash
# Feature dependencies: bin/lib/fm_pr_format.py bin/lib/fm_public_text.py
# bin/lib/fm_conventions.py bin/lib/fm_onboard.py bin/lib/fm_spec_preflight.py
# bin/lib/fm-spec-preflight.sh bin/fm-worker.sh bin/lib/fm_autopilot_loop.py
# Shared fixtures: tests/lib/crew_blocks.py tests/lib/external_pr_format.py
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
. "$ROOT/tests/lib.sh"
python3 "$ROOT/tests/lib/external_pr_format.py" "$ROOT"
assert_eq 0 "$?" 'external PR format, public validation and publication'
finish
