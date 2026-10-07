#!/usr/bin/env bash
# T-240: pin-authorized fail-first warning, readiness and merge payload.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=tests/lib.sh
. "$ROOT/tests/lib.sh"
python3 "$ROOT/tests/lib/gate_not_runnable.py" "$ROOT"
assert_eq 0 "$?" 'pinned not-runnable gate, readiness and card payload'
# The complete entrypoint also reaches readiness with real signed evidence,
# a real pin and local GitHub transport; no project command is allowed to run.
for key in $(env | sed -nE 's/^(FM_[^=]*|HERDR_[^=]*)=.*$/\1/p'); do unset "$key" || true; done
# shellcheck source=tests/lib/spec-pins.sh
. "$ROOT/tests/lib/spec-pins.sh"
# shellcheck source=tests/lib/head-binding.sh
. "$ROOT/tests/lib/head-binding.sh"
isolate_tmpdir
d="$(safe_tmpdir)"
unset GH_REPO
export FM_GATE_LOCK="$d/gate.lock" HERDR_ENV=0
mkdir -p "$d/design/tasks" "$d/src"
git -C "$d" init -q -b main
git -C "$d" config user.email fixture@example.invalid
git -C "$d" config user.name Fixture
printf '{"id":"T-X","scope":["src/**"]}\n' > "$d/design/tasks/T-X.json"
printf 'design\n' > "$d/design/design.md"
printf 'project:\n  check: touch %s/command-ran; exit 91\n  unrunnable: Missing test credentials\n' "$d" > "$d/config.yaml"
printf 'old\n' > "$d/src/value"
git -C "$d" add .; git -C "$d" commit -qm base
seed_spec_pin "$d" T-X
git -C "$d" checkout -qb work
printf 'new\n' > "$d/src/value"
git -C "$d" commit -qam feature
head_binding_fixture "$d" work
export FM_GH="$d/stub/head-gh"
(
  . "$ROOT/bin/fm-config.sh"
  fm_storage_init "$d" || exit
  FM_EVIDENCE_PROJECT="$(fm_evidence_project)" python3 - "$ROOT" <<'PYREADY'
import os, sys
from pathlib import Path
sys.dont_write_bytecode = True
sys.path.insert(0, sys.argv[1] + '/bin/lib')
from fm_binding import source_binding, git
from fm_evidence import Store
root = os.environ['FM_TARGET_ROOT']
head, base = git(root, 'rev-parse', 'work'), git(root, 'rev-parse', 'main')
binding = source_binding('T-X', head, base, Path(sys.argv[1]))
Store(os.environ['FM_STATE_DIR'], os.environ['FM_EVIDENCE_PROJECT'], 'T-X').append(
    'verdict', 1, 'reviewer', head, 'APPROVE:T-X', verdict='APPROVE',
    base=base, patch=binding['patch'], binding=binding, provenance={'level':'legacy'})
PYREADY
)
assert_eq 0 "$?" 'full gate fixture retains signed approval'
"$ROOT/bin/fm-gate.sh" --repo "$d" --task T-X --branch work --pr 9 > "$d/gate-output" 2>&1
assert_eq 0 "$?" 'the complete six-gate entrypoint accepts pinned not-runnable fail-first'
assert_contains "$(cat "$d/gate-output")" '  ! gate 4 (fail-first):' 'full transcript retains warning'
assert_lacks "$(cat "$d/gate-output")" 'all six gates green' 'not-runnable summary never claims all gates green'
assert_contains "$(cat "$d/gate-output")" 'fail-first did not run' 'not-runnable summary says fail-first did not run'
assert_fail "test -e '$d/command-ran'" 'the pinned check command never ran'
(
  . "$ROOT/bin/fm-config.sh"
  fm_storage_init "$d" || exit
  fm_binding candidate --task T-X --pr 9 --head "$(git -C "$d" rev-parse work)"
) > "$d/candidate.json"
assert_eq 0 "$?" 'real candidate accepts signed readiness with the pinned warning'
assert_eq 'Missing test credentials' "$(jq -r '.not_runnable["fail-first"]' "$d/candidate.json")" 'candidate carries the readiness reason'
# A direct fail-first call accepts the new key without changing its behavior.
printf '{"unrunnable":"Missing test credentials","docs":["src/**"]}\n' > "$d/direct-contract.json"
(cd "$d" && bash "$ROOT/bin/fm-failfirst.sh" --gate --contract="$d/direct-contract.json" --head=work main) > "$d/direct-output" 2>&1
assert_eq 0 "$?" 'direct fail-first accepts an unrunnable string and retains docs-only behavior'
finish
