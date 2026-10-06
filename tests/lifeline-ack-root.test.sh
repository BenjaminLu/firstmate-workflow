#!/usr/bin/env bash
# T-236: resolve acknowledgement storage once per operation, not per wake.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
python3 - "$ROOT" <<'PY'
import importlib.util
import json
import os
from pathlib import Path
import sys
import tempfile
import unittest
from unittest import mock

sys.dont_write_bytecode = True
spec = importlib.util.spec_from_file_location(
    'fm_lifeline', Path(sys.argv[1]) / 'bin/lib/fm_lifeline.py')
life = importlib.util.module_from_spec(spec)
spec.loader.exec_module(life)


class AcknowledgementRoot(unittest.TestCase):
    def setUp(self):
        clean_env = {k: v for k, v in os.environ.items()
                     if not k.startswith(('FM_', 'HERDR_'))}
        environment = mock.patch.dict(os.environ, clean_env, clear=True)
        environment.start()
        self.addCleanup(environment.stop)
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        (self.root / 'config.yaml').write_text(
            'default_project: firstmate-workflow\nprojects:\n'
            '  firstmate-workflow:\n    repo: .\n'
            '    github: fixture/workflow\n    base: main\n'
            '    required_check: ci\n')
        self.directory = self.root / life.ACK_DIR
        self.directory.mkdir(parents=True)
        self.transaction = self.directory.parent / '.ack-transaction.json'
        self.ids = [f'wake-{i}' for i in range(200)]
        self.expected = {ident: i + 0.5 for i, ident in enumerate(self.ids)}
        for ident, stamp in self.expected.items():
            (self.directory / f'{ident}.json').write_text(json.dumps(
                dict(id=ident, acknowledged=stamp, wakes=1)))

    def read_once(self, expected):
        with mock.patch.object(life, 'record_root', wraps=life.record_root) as resolve:
            result = life.acknowledged_many(self.root, self.ids)
        self.assertEqual(result, expected)
        self.assertEqual(resolve.call_count, 1,
                         'acknowledged_many resolves the record root once per call')

    def test_many_resolves_once_and_reads_fresh_values_each_call(self):
        self.read_once(self.expected)
        (self.directory / 'wake-0.json').write_text(
            json.dumps(dict(id='wake-0', acknowledged=999, wakes=2)))
        self.expected['wake-0'] = 999
        self.read_once(self.expected)

    def test_batch_resolves_once_for_fifty_items(self):
        items = [dict(id=ident, woken=500 + i, wakes=2)
                 for i, ident in enumerate(self.ids[:50])]
        expected = {item['id']: dict(id=item['id'], acknowledged=item['woken'], wakes=2)
                    for item in items}
        # Cover both changed records and the subsequent no-op batch.
        for _ in range(2):
            with mock.patch.object(life, 'record_root', wraps=life.record_root) as resolve:
                result = life.acknowledge_batch(self.root, items)
            self.assertEqual(result, expected)
            self.assertLessEqual(resolve.call_count, 1,
                                 'acknowledge_batch resolves the record root at most once')
            for ident, record in expected.items():
                self.assertEqual(json.loads((self.directory / f'{ident}.json').read_text()),
                                 record)
            self.assertFalse(self.transaction.exists())

    def test_transaction_values_win_and_other_records_remain_visible(self):
        self.transaction.write_text(json.dumps({
            'wake-0': dict(id='wake-0', acknowledged=0, wakes=1),
            'wake-1': None,
        }))
        self.read_once(dict(self.expected, **{'wake-0': 0, 'wake-1': None}))

    def test_unknown_transaction_hides_all_watermarks(self):
        for contents in ('{broken', '[]', 'null'):
            with self.subTest(contents=contents):
                self.transaction.write_text(contents)
                self.read_once(dict.fromkeys(self.ids))
        self.transaction.unlink()
        # A directory is unreadable as a transaction file even when run as root.
        self.transaction.mkdir()
        self.read_once(dict.fromkeys(self.ids))

    def test_single_record_resolves_once_without_a_supplied_root(self):
        with mock.patch.object(life, 'record_root', wraps=life.record_root) as resolve:
            result = life._ack_record(self.root, 'wake-0')
        self.assertEqual(result, dict(id='wake-0', acknowledged=0.5, wakes=1))
        self.assertEqual(resolve.call_count, 1)


unittest.main(argv=[sys.argv[0]])
PY
