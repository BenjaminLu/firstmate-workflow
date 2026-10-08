#!/usr/bin/env bash
# T-138: trusted records reject mutation and keep external evidence private.
set -uo pipefail
for key in $(env | sed -nE 's/^(FM_[^=]*|HERDR_[^=]*)=.*$/\1/p'); do unset "$key"; done
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
. "$ROOT/tests/lib.sh"
t="$(safe_tmpdir)"
python3 - "$ROOT" "$t" <<'PY'
import json, pathlib, sys
sys.path.insert(0, sys.argv[1] + '/bin/lib')
from fm_evidence import Store
root = pathlib.Path(sys.argv[2])
s = Store(root / 'self/state', 'self', 'T-138')
s.append('verdict', 1, 'reviewer', 'a'*40, 'APPROVE:T-138',
         verdict='APPROVE', provenance={'level':'legacy'})
p = next(s.directory.glob('*.json'))
r = json.loads(p.read_text())
assert r.get('signature'), 'trusted verdict must have a signature'
assert s.records()[0]['verdict'] == 'APPROVE'
r['head'] = 'b'*40
p.write_text(json.dumps(r))
try:
    s.records()
except ValueError:
    pass
else:
    raise AssertionError('tampered head must be refused')
e = Store(root / 'home/projects/private-app/state', 'private-app', 'T-138', external=True)
e.append('brief', 1, 'firstmate', 'a'*40, 'private brief')
assert e.directory == root / 'home/projects/private-app/state/evidence/T-138'
assert not (root / 'home/projects/private-app/state/evidence/private-app').exists()
PY
assert_eq 0 "$?" "signed records reject tampering and external layout omits project duplication"
python3 "$ROOT/tests/lib/evidence_binding.py" "$ROOT" "$t"
assert_eq 0 "$?" "real bindings carry only unchanged patches and reject stale heads or red statuses"
carry_tmp="$(safe_tmpdir)"
python3 "$ROOT/tests/lib/evidence_carry.py" "$ROOT" "$carry_tmp"
assert_eq 0 "$?" "signed carry validates provenance, unchanged change and fresh readiness"
safe_rm_rf "$carry_tmp"
safe_rm_rf "$t"
finish
