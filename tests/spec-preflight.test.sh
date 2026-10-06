#!/usr/bin/env bash
# Feature dependencies: bin/fm-review.sh bin/fm-worker.sh bin/fm-herdr.py
# bin/lib/fm_spec_preflight.py bin/lib/fm-spec-preflight.sh bin/lib/fm_evidence.py
# bin/lib/fm_public_text.py bin/lib/fm_ste.py
# bin/lib/fm_sandbox_policy.py skills/firstmate/SKILL.md skills/reviewer/SKILL.md
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
. "$ROOT/tests/lib.sh"
export HERDR_ENV=0
python3 "$ROOT/tests/lib/spec_preflight_cases.py" "$ROOT"
assert_eq 0 "$?" 'spec preflight binds exact bytes, migration, prompt and authenticated finals'
finish
