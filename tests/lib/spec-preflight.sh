# shellcheck shell=bash
# fm:sourced
# Fixture-only signed receipt. Never used by a production launcher.
seed_spec_preflight() { # engine, task, optional exact spec file, project, external state
  python3 - "$ROOT" "$1" "$2" "${3:-$1/design/tasks/$2.json}" "${4:-self}" "${5:-}" <<'PY'
import hashlib, sys
from pathlib import Path
library = Path(sys.argv[1]) / 'bin/lib'
# Gate 5 restores the pre-feature implementation while keeping fixture helpers.
# That base has no preflight store or dispatch requirement to seed.
if not (library / 'fm_spec_preflight.py').is_file():
    sys.exit(0)
sys.path.insert(0, str(library))
from fm_evidence import Store
engine, task, source, project, external_state = sys.argv[2:]
data = Path(source).read_bytes()
Store(Path(external_state) if external_state else Path(engine) / 'state',
      project, task, external=bool(external_state)).append(
    'spec-preflight', 1, 'reviewer-fixture', 'a' * 40,
    '1. Fixture acceptance checked.\nSPEC-OK:' + task,
    spec_sha256=hashlib.sha256(data).hexdigest(), verdict='SPEC-OK',
    provenance={'level': 'legacy', 'vendor': 'claude'})
PY
}
