"""Independent expected T-173 insertion for the legacy self diff fixture.

Keep the rest of review-diff's byte-for-byte oracle unchanged. This fixture has
no design or conventions and no approved contract; only spec/config are copied.
Do not call the production renderer or read its generated prompt as an oracle.
"""
import hashlib
import json
from pathlib import Path
import sys

folder, spec, config = sys.argv[1:]
record = dict(project='firstmate-workflow', task='T-Z', version=None,
              engine_commit=None, target_base_commit=None, source='legacy-unpinned',
              approval_binding=None, contract={},
              approval=dict(decision=None, author=None, time=None, kind=None))
empty_hash = hashlib.sha256(b'').hexdigest()
spec_hash = hashlib.sha256((spec + '\n').encode()).hexdigest()
config_hash = hashlib.sha256(Path(config).read_bytes()).hexdigest()
print('\n# Unpinned round inputs\n')
print(json.dumps(record, ensure_ascii=False, indent=2))
print('\n# Complete round inputs in pinned/\n')
print('Read these complete files when needed. They are read-only; do not substitute checkout copies.')
print('UNPINNED: legacy source snapshots, not approved pin authority.')
print(f'- {folder}/spec.json (sha256={spec_hash})')
print(f'design: none (source absent; sha256={empty_hash}).')
print(f'CONVENTIONS.md: absent from this project (sha256={empty_hash}).')
print(f'- {folder}/contract.yaml (sha256={config_hash})')
print('\n# Design section anchors\n')
print('design: none; no section anchors available.')
print('\n# Unpinned CONVENTIONS.md\n')
print('')
