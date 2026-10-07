#!/usr/bin/env bash
# Feature dependencies: bin/lib/fm_spec_preflight.py bin/lib/fm-spec-preflight.sh
# bin/lib/fm_evidence.py bin/fm-herdr.py skills/firstmate/SKILL.md skills/reviewer/SKILL.md
# tests/lib/spec_preflight_standing.py
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
. "$ROOT/tests/lib.sh"
export HERDR_ENV=0
python3 "$ROOT/tests/lib/spec_preflight_standing.py" "$ROOT"
assert_eq 0 "$?" 'preflight retains an exhaustive standing list and enforces reissue structure'
finish
