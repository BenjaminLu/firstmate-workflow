#!/usr/bin/env bash
# T-154: settings reader and the opener's port plumbing, without a browser.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
python3 - "$ROOT" <<'PY'
import importlib.util
import os
from pathlib import Path
import shutil
import socket
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch
sys.dont_write_bytecode = True
root = Path(sys.argv[1])
spec = importlib.util.spec_from_file_location('herdr', root / 'bin/fm-herdr.py')
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)

class Settings(unittest.TestCase):
    def setUp(self):
        tmp = tempfile.TemporaryDirectory(); self.addCleanup(tmp.cleanup)
        self.repo = Path(tmp.name)
        (self.repo / 'bin').mkdir()
        shutil.copy(root / 'bin/fm-config.sh', self.repo / 'bin')
        self.env = {k:v for k,v in os.environ.items() if not k.startswith('FM_')}
        env = patch.dict(os.environ, self.env, clear=True); env.start(); self.addCleanup(env.stop)
    def config(self, text):
        (self.repo / 'config.yaml').write_text(text)
    def read(self, field, **env):
        return subprocess.run(['bash', '-c', '. "$1"; "$2" "$3"', 'settings',
            str(self.repo / 'bin/fm-config.sh'), field, str(self.repo / 'config.yaml')],
            env=dict(self.env, **env), capture_output=True, text=True)
    def test_defaults_config_and_override(self):
        self.assertEqual('4173', self.read('fm_board_port').stdout.strip())
        self.assertEqual('en', self.read('fm_language').stdout.strip())
        self.config('board:\n  port: 49321 # chosen\nlanguage: "zh-TW"\n')
        self.assertEqual('49321', self.read('fm_board_port').stdout.strip())
        self.assertEqual('zh-TW', self.read('fm_language').stdout.strip())
        self.assertEqual('49322', self.read('fm_board_port', FM_PORT='49322').stdout.strip())
        self.assertEqual('0', self.read('fm_board_port', FM_PORT='0').stdout.strip())
        for value in ['', '-1', '65536', 'abc']:
            self.assertNotEqual(0, self.read('fm_board_port', FM_PORT=value).returncode)
        self.config('board:\n  port: 0\nlanguage: fr\n')
        self.assertNotEqual(0, self.read('fm_board_port').returncode)
        self.assertNotEqual(0, self.read('fm_language').returncode)
    def test_configured_and_override_port_reach_opener_and_record(self):
        self.config('board:\n  port: 49321\n')
        for override, port in [(None, 49321), ('49322', 49322)]:
            if override: os.environ['FM_PORT'] = override
            with patch.object(m, 'board_matches', return_value=True) as matches, \
                 patch.object(m, 'http_get', return_value=b'page'), \
                 patch.object(m, 'board_open', return_value={'opener_invoked': True}) as opened:
                record = m.board_start(self.repo)
                url = f'http://127.0.0.1:{port}'
                self.assertEqual(url, record['url'])
                matches.assert_called_once_with(self.repo, url)
                opened.assert_called_once_with(url, port)
    def test_wizard_refuses_occupied_port_before_writing(self):
        shutil.copy(root / 'bin/fm-herdr.py', self.repo / 'bin')
        shutil.copy(root / 'bin/fm-setup.sh', self.repo / 'bin')
        facts = self.repo / 'facts'; facts.write_text('')
        answers = self.repo / 'answers'
        self.config('language: en\n')
        before = (self.repo / 'config.yaml').read_bytes()
        with socket.socket() as listener:
            listener.bind(('127.0.0.1', 0)); listener.listen()
            answers.write_text(f'board_port: {listener.getsockname()[1]}\nlanguage: zh-TW\n')
            result = subprocess.run(['bash', str(self.repo / 'bin/fm-setup.sh'), '--repo',
                str(self.repo), '--facts', str(facts), '--answers', str(answers)],
                input='', capture_output=True, text=True, env=self.env, timeout=15)
        self.assertNotEqual(0, result.returncode)
        self.assertIn('unverified root', result.stderr)
        self.assertEqual(before, (self.repo / 'config.yaml').read_bytes())

    def test_setup_port_refuses_non_http_listener_but_accepts_own_board(self):
        with socket.socket() as listener:
            listener.bind(('127.0.0.1', 0)); listener.listen()
            port = listener.getsockname()[1]
            with patch.object(m, 'board_matches', return_value=False):
                with self.assertRaisesRegex(RuntimeError, 'unverified root'):
                    m.board_check_port(self.repo, port)
            with patch.object(m, 'board_matches', return_value=True):
                m.board_check_port(self.repo, port)
        m.board_check_port(self.repo, port)

unittest.main(argv=['settings'])
PY
