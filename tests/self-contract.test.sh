#!/usr/bin/env bash
# Both self contract locations must serve shell, session and historical pins.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
python3 - "$ROOT" <<'PY'
import importlib.util
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch
sys.dont_write_bytecode = True
root = Path(sys.argv[1])
sys.path.insert(0, str(root / 'bin/lib'))
spec = importlib.util.spec_from_file_location('herdr', root / 'bin/fm-herdr.py')
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
from fm_spec_pins import contract
import fm_binding

BODY = '''  setup: echo prepared > prepared
  check: make check
  check_env:
    BUDGET: 600
  tests:
    - tests/**
  test: bash {file}
  docs:
    - notes/**
'''
LEGACY = 'project:\n' + BODY
NESTED = '''default_project: firstmate-workflow
projects:
  firstmate-workflow:
    repo: .
    github: example/engine
    base: main
    required_check: ci
    project:
''' + ''.join('    ' + line + '\n' for line in BODY.splitlines())

class Contract(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(); self.addCleanup(self.tmp.cleanup)
        self.repo = Path(self.tmp.name); self.config = self.repo / 'config.yaml'
        self.config.write_text(NESTED)
    def shell(self, command):
        env = {k:v for k,v in os.environ.items() if not k.startswith(('FM_', 'HERDR_'))}
        return subprocess.run(['bash', '-c', '. "$1/bin/fm-config.sh"; ' + command,
                               '_', str(root), str(self.config)], env=env, capture_output=True, text=True)
    def test_both_readers_accept_either_contract_location(self):
        for config in (NESTED.split('    project:\n')[0] + LEGACY, NESTED):
            with self.subTest(config=config):
                self.config.write_text(config)
                self.assertEqual('make check', m.project_contract(self.config)['check'])
                for command in ('fm_project check "$2"', 'fm_project_contract firstmate-workflow check "$2"'):
                    result = self.shell(command)
                    self.assertEqual(0, result.returncode, result.stderr)
                    self.assertEqual('make check', result.stdout.strip())
    def test_session_start_setup_and_status_at_either_location(self):
        for config in (NESTED.split('    project:\n')[0] + LEGACY, NESTED):
            with self.subTest(config=config), patch.object(m, 'record_root', return_value=self.repo):
                self.config.write_text(config)
                start = m.project_report(self.repo, run_setup=True)
                self.assertTrue(start['ready'], start)
                self.assertEqual(0, start['setup']['exit'])
                self.assertEqual('prepared\n', (self.repo / 'prepared').read_text())
                (self.repo / 'prepared').unlink()
                status = m.project_report(self.repo)
                self.assertTrue(status['ready'], status)
                self.assertEqual(start['declared'], status['declared'])
                self.assertFalse((self.repo / 'prepared').exists())
    def test_old_pin_and_new_pin_have_identical_contracts(self):
        self.assertEqual(contract(LEGACY, 'firstmate-workflow'), contract(NESTED, 'firstmate-workflow'))
    def test_duplicate_refused_by_every_reader(self):
        self.config.write_text(NESTED + LEGACY)
        with self.assertRaisesRegex(ValueError, 'also declared|duplicate'):
            m.project_contract(self.config)
        with self.assertRaisesRegex(ValueError, 'also declared|duplicate'):
            contract(self.config.read_text(), 'firstmate-workflow')
        for command in ('fm_project check "$2"', 'fm_project_contract firstmate-workflow check "$2"'):
            self.assertNotEqual(0, self.shell(command).returncode)
    def test_shipped_contract_stays_top_level_until_t170(self):
        text = (root / 'config.yaml').read_text()
        self.assertIn('\nproject:', text)
        self.assertNotIn('\n    project:', text)
        self.assertEqual('bin/ci.sh', m.project_contract(root / 'config.yaml')['check'])
    def test_review_binding_uses_verified_snapshot_bytes(self):
        pin = {'snapshots': {name: {'text': text} for name, text in
               [('spec', 'approved spec'), ('contract', LEGACY), ('conventions', '')]}}
        with patch.dict(os.environ, FM_TARGET_ROOT=str(self.repo), FM_EXTERNAL='0'), \
             patch('fm_spec_pins.Pins.resolve', return_value=pin), \
             patch.object(fm_binding, 'change', return_value={}), \
             patch.object(fm_binding, 'command', side_effect=AssertionError('must not read branch config')):
            binding = fm_binding.source_binding('T-X', 'a'*40, 'b'*40, self.repo)
        self.assertEqual(fm_binding.digest(LEGACY.encode()), binding['contract_sha256'])
        self.assertEqual(fm_binding.digest(b'approved spec'), binding['spec_sha256'])

unittest.main(argv=['self-contract'])
PY
