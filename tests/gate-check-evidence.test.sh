#!/usr/bin/env bash
# Required names, status classification, and head/base movement at gate 6.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
python3 - "$ROOT" <<'PY'
import os
from pathlib import Path
import sys
import unittest
from unittest.mock import patch
sys.dont_write_bytecode = True
sys.path.insert(0, str(Path(sys.argv[1]) / 'bin/lib'))
import fm_binding as m
H = 'a' * 40
B = 'b' * 40

class Checks(unittest.TestCase):
    def setUp(self):
        self.view = dict(headRefOid=H, baseRefOid=B, baseRefName='stack', state='OPEN')
        self.protection = dict(contexts=['ci'], checks=[dict(context='security')])
        self.runs = [dict(id=1, name=n, head_sha=H, status='completed', conclusion='success') for n in ('ci', 'security')]
        self.status = dict(sha=H, statuses=[])
        self.env = patch.dict(os.environ, dict(FM_EXTERNAL='0', FM_BASE='main'), clear=True)
        self.env.start(); self.addCleanup(self.env.stop)
        for target, kwargs in [('remote_head', dict(side_effect=lambda *a: dict(self.view))),
                               ('command', dict(side_effect=self.fetch)),
                               ('git', dict(return_value=B)), ('github', dict(side_effect=self.github))]:
            p = patch.object(m, target, **kwargs); p.start(); self.addCleanup(p.stop)
    def fetch(self, argv):
        # Match live-base-binding.test.sh's exact repository/base fetch stub.
        self.assertEqual(['git', '-C', '/fixture', 'fetch', '--no-tags',
                          'https://github.com/owner/repo.git',
                          'refs/heads/' + self.view['baseRefName']], argv)
        return b''
    def github(self, repo, *args):
        self.assertEqual('owner/repo', repo)
        if '/protection/' in args[-1]:
            if isinstance(self.protection, Exception): raise self.protection
            return self.protection
        if '/check-runs' in args[-1]: return dict(check_runs=list(self.runs))
        if '/status?' in args[-1]: return self.status
        self.fail(args)
    def read(self):
        return m.required_checks(Path('/fixture'), 'owner/repo', 9, H)
    def test_protection_and_confirmed_conventions_are_combined(self):
        with patch.dict(os.environ, FM_EXTERNAL='1', FM_STATE_DIR='/private/state'), \
             patch('fm_conventions.read_policy', return_value=dict(required_checks=['ci'], base='main', stacking='allowed')):
            self.runs = self.runs[:1]
            with self.assertRaisesRegex(ValueError, 'pending.*security'):
                self.read()
    def test_private_unreadable_protection_uses_confirmed_policy(self):
        self.protection = ValueError('404')
        with patch.dict(os.environ, FM_EXTERNAL='1', FM_STATE_DIR='/private/state'), \
             patch('fm_conventions.read_policy', return_value=dict(required_checks=['ci'], base='main', stacking='allowed')):
            self.assertEqual('ci', self.read()[0]['name'])
    def test_unreadable_without_confirmed_policy_is_unknown(self):
        self.protection = ValueError('404')
        with self.assertRaisesRegex(ValueError, 'unknown'):
            self.read()
    def test_missing_and_running_are_pending(self):
        self.runs = self.runs[:1]
        with self.assertRaisesRegex(ValueError, 'pending.*security'): self.read()
        self.runs[0]['status'] = 'in_progress'
        with self.assertRaisesRegex(ValueError, 'pending.*ci'): self.read()
    def test_red_status_cannot_hide_behind_green_run(self):
        self.status['statuses'] = [dict(id=2, context='ci', state='failure')]
        with self.assertRaisesRegex(ValueError, 'failed.*ci'): self.read()
    def test_status_only_context_and_wrong_sha(self):
        self.runs = self.runs[:1]
        self.status['statuses'] = [dict(id=2, context='security', state='success')]
        self.assertEqual(2, len(self.read()))
        self.status['sha'] = B
        with self.assertRaisesRegex(ValueError, 'another head'): self.read()
    def test_remote_base_movement_invalidates_evidence(self):
        with patch.object(m, 'remote_head', side_effect=[self.view, dict(self.view, baseRefOid=H)]):
            with self.assertRaisesRegex(ValueError, 'moved'): self.read()
    def test_stale_local_task_ref_refused_after_remote_update(self):
        with patch.object(m, 'command', return_value=b''), patch.object(m, 'git', side_effect=[H, B]):
            with self.assertRaisesRegex(ValueError, 'local task ref'):
                m.authoritative(Path('/fixture'), 'task', 'owner/repo', 9)
    def test_final_readiness_refuses_late_remote_movement(self):
        self.view['headRefOid'] = B
        with self.assertRaisesRegex(ValueError, 'stale|moved'):
            m.verify_current(Path('/fixture'), 'owner/repo', 9, H, B)
    def test_incomplete_api_page_is_unknown(self):
        self.runs *= 50
        with self.assertRaisesRegex(ValueError, 'unknown.*complete'):
            self.read()

unittest.main(argv=['gate-check-evidence'])
PY
