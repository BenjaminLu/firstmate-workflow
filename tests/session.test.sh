#!/usr/bin/env bash
set -euo pipefail
exec < /dev/null
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
python3 - "$ROOT" <<'PY'
import importlib.util
import json
import os
from pathlib import Path
import shutil
import signal
import socket
import subprocess
import sys
import tempfile
import time
import unittest
from unittest.mock import patch

sys.dont_write_bytecode = True  # Import production code without dirtying the checkout.
root = Path(sys.argv[1])
spec = importlib.util.spec_from_file_location('managed', root / 'bin/fm-herdr.py')
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)

class Session(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(); self.addCleanup(self.tmp.cleanup)
        self.repo = Path(self.tmp.name)
        shutil.copytree(root / 'bin', self.repo / 'bin')
        shutil.copytree(root / 'skills', self.repo / 'skills')
    def test_role_context_reaches_supported_launchers(self):
        for role in ['worker', 'reviewer', 'firstmate']:
            result = m.role_context(self.repo, role, 'T-035', 'worker-mira-t035-r2', 'payload')
            self.assertIn('explicitly dispatched ' + role, result)
            self.assertIn('payload', result)
            self.assertIn('worker-mira-t035-r2', result)
            self.assertIn((self.repo / 'skills' / role / 'SKILL.md').read_text(), result)
    def test_board_verifies_root_with_relative_nonce(self):
        seen = []
        def request(url):
            from urllib.parse import urlparse, parse_qs
            seen.append(url)
            name = parse_qs(urlparse(url).query)['path'][0]
            self.assertFalse(Path(name).is_absolute())
            return (self.repo / name).read_bytes()
        with patch.object(m, 'http_get', side_effect=request):
            self.assertTrue(m.board_matches(self.repo, 'http://127.0.0.1:4173'))
        with patch.object(m, 'http_get', return_value=b'wrong root'):
            self.assertFalse(m.board_matches(self.repo, 'http://127.0.0.1:4173'))
        self.assertEqual(1, len(seen))
    def test_watch_is_live_reused_observable_durable_and_cancellable(self):
        first = m.watch_start(self.repo, 'D-test')
        try:
            self.assertTrue(m.process_matches(first))
            self.assertEqual(first['pid'], m.watch_start(self.repo, 'D-test')['pid'])
            decisions = self.repo / 'state/decisions'; decisions.mkdir(parents=True, exist_ok=True)
            (decisions / 'D-test.json').write_text('{"id":"D-test","chosen":"B"}')
            result = Path(first['directory']) / 'result.json'
            for _ in range(80):
                if result.exists(): break
                time.sleep(.05)
            self.assertEqual('B', json.loads(result.read_text())['decision']['chosen'])
            self.assertEqual('observed', json.loads(result.read_text())['status'])
        finally: m.watch_stop(self.repo, 'D-test')
        second = m.watch_start(self.repo, 'D-cancel')
        m.watch_stop(self.repo, 'D-cancel')
        self.assertFalse(m.process_matches(second))
        self.assertEqual('stopped', json.loads((Path(second['directory']) / 'result.json').read_text())['status'])
    def test_board_reuse_does_not_spawn_and_wrong_root_is_refused(self):
        with patch.object(m,'board_matches',return_value=True), patch.object(m,'http_get',return_value=b'page'), \
             patch.object(m.shutil,'which',return_value=None), patch.object(m.subprocess,'Popen') as spawn:
            reply=m.board_start(self.repo)
            self.assertTrue(reply['reused']); self.assertTrue(reply['page_http_verified'])
            self.assertFalse(reply['opener_invoked']); self.assertFalse(reply['browser_navigation_verified'])
            spawn.assert_not_called()
        with patch.object(m,'board_matches',return_value=False), patch.object(m,'http_get',return_value=b'foreign'), \
             patch.object(m.subprocess,'Popen') as spawn:
            with self.assertRaisesRegex(RuntimeError,'unverified root'): m.board_start(self.repo)
            spawn.assert_not_called()
    def test_continuous_watch_restart_preserves_observation(self):
        pending=self.repo/'state/pending'; pending.mkdir(parents=True)
        decisions=self.repo/'state/decisions'; decisions.mkdir(parents=True)
        (pending/'D-saved.json').write_text('{"id":"D-saved"}')
        (decisions/'D-saved.json').write_text('{"id":"D-saved","chosen":"B"}')
        first=m.watch_start(self.repo)
        receipt=self.repo/'state/session/observed/D-saved.json'
        try:
            for _ in range(80):
                if receipt.exists(): break
                time.sleep(.05)
            saved=receipt.read_bytes()
            self.assertTrue(m.process_matches(first))
        finally: m.watch_stop(self.repo)
        second=m.watch_start(self.repo)
        try:
            time.sleep(.3)
            self.assertTrue(m.process_matches(second))
            self.assertEqual(saved,receipt.read_bytes())
        finally: m.watch_stop(self.repo)
    def test_actual_board_start_and_correct_root_reuse(self):
        bun=shutil.which('bun')
        if not bun: self.skipTest('Bun unavailable: actual HTTP board startup not verified')
        try:
            with socket.socket() as probe:
                probe.bind(('127.0.0.1',0)); port=probe.getsockname()[1]
        except PermissionError as error:
            self.skipTest('loopback bind prohibited: '+str(error))
        shutil.copytree(root/'board',self.repo/'board')
        children=[]; original=m.subprocess.Popen
        def spawn(*args,**kwargs):
            child=original(*args,**kwargs); children.append(child); return child
        try:
            with patch.dict(os.environ,{'FM_PORT':str(port)}), \
                 patch.object(m.shutil,'which',side_effect=lambda name: bun if name=='bun' else None), \
                 patch.object(m.subprocess,'Popen',side_effect=spawn):
                first=m.board_start(self.repo)
                self.assertFalse(first['reused']); self.assertTrue(first['page_http_verified'])
                second=m.board_start(self.repo)
                self.assertTrue(second['reused']); self.assertEqual(1,len(children))
                other=self.repo/'other'; other.mkdir()
                with self.assertRaisesRegex(RuntimeError,'unverified root'): m.board_start(other)
        finally:
            for child in children:
                if child.poll() is None: os.killpg(child.pid,signal.SIGTERM)
                child.wait(timeout=5)
unittest.main(argv=['session'], verbosity=2)
PY
