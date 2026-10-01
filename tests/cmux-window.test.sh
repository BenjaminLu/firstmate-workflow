#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
. "$ROOT/tests/lib.sh"
python3 - "$ROOT" <<'PY'
import importlib.util, json, os, signal, tempfile, unittest, sys
from pathlib import Path
from unittest.mock import patch
from subprocess import CompletedProcess
sys.dont_write_bytecode = True
spec = importlib.util.spec_from_file_location('host', Path(sys.argv[1])/'bin/fm-herdr.py')
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)

class HostModel:
    def __init__(self):
        self.workspaces = {'workspace:1': dict(id='caller-uuid', ref='workspace:1', title='Captain')}
        self.mode = 'cmuxOnly'; self.auth_error = None
        self.focus = 'workspace:1'; self.calls = []; self.reject = False; self.label_error = False
    def __call__(self, *args):
        self.calls.append(args)
        if self.auth_error: raise RuntimeError(self.auth_error)
        if self.reject and self.mode == 'cmuxOnly':
            raise RuntimeError('cmux capabilities failed: Error: Failed to write to socket')
        cmd = args[0]
        if cmd == 'ping': return 'PONG'
        if cmd == 'capabilities': return json.dumps(dict(access_mode=self.mode))
        if cmd == 'list-workspaces': return json.dumps(dict(workspaces=list(self.workspaces.values())))
        if cmd == 'current-window': return 'window:1'
        if cmd == 'current-workspace': return self.focus
        if cmd == 'new-workspace':
            self.workspaces['workspace:7'] = dict(id='owned-uuid', ref='workspace:7', title='Untitled')
            self.focus = 'workspace:7'; return 'OK workspace:7'
        if cmd == 'rename-workspace':
            if self.label_error: raise RuntimeError('cmux rename-workspace failed: label denied')
            self.workspaces[args[2]]['title'] = args[3]; return 'OK'
        if cmd == 'select-workspace': self.focus = args[2]; return 'OK'
        if cmd == 'tree': return json.dumps(self.workspaces[args[2]])
        if cmd == 'close-workspace': del self.workspaces[args[2]]; return 'OK'
        raise AssertionError(args)

class Windows(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(); self.addCleanup(self.tmp.cleanup)
        self.run = Path(self.tmp.name); self.host = HostModel()
        p = patch.object(m, 'Host', return_value=self.host); p.start(); self.addCleanup(p.stop)
        p = patch.dict(os.environ, {'FM_CMUX_CALLER_WORKSPACE':'workspace:1'}, clear=True)
        p.start(); self.addCleanup(p.stop)
        m.save(self.run/'result.json', dict(exit_code=0, status='completed'))
    def open(self): return m.open_generic_window('cmux', self.run, self.run, 'worker-test', 'follow log')
    def test_focus_label_receipt_and_completion(self):
        record = self.open()
        self.assertEqual('workspace:1', self.host.focus)
        self.assertEqual('owned-uuid', record['workspace_id'])
        self.assertEqual('worker-test', self.host.workspaces[record['ref']]['title'])
        self.assertEqual('closed', m.close_generic_window(record, self.run))
        self.assertEqual(['workspace:1'], list(self.host.workspaces))
    def test_cleanup_requires_positive_completion_before_host_calls(self):
        record = self.open()
        for result in (dict(exit_code=1, status='failed'),
                       dict(exit_code=0, status='blocked'),
                       dict(exit_code=0, status='unknown'),
                       dict(exit_code=1, status='completed'),
                       {}, [], None):
            with self.subTest(result=result):
                if result is None: (self.run/'result.json').unlink()
                else: m.save(self.run/'result.json', result)
                self.host.calls.clear()
                self.assertIn('retained', m.close_generic_window(record, self.run))
                self.assertEqual([], self.host.calls)
                self.assertIn(record['ref'], self.host.workspaces)
    def test_autoclose_opt_out_retains_completed_window(self):
        record = self.open(); self.host.calls.clear()
        os.environ['FM_AUTOCLOSE'] = '0'
        self.assertEqual('retained: auto-close disabled', m.close_generic_window(record, self.run))
        self.assertEqual([], self.host.calls)
    def test_changed_resource_is_retained(self):
        record = self.open(); self.host.workspaces[record['ref']]['id'] = 'replacement'
        self.assertIn('retained', m.close_generic_window(record, self.run))
        self.assertIn(record['ref'], self.host.workspaces)
    def test_label_failure_is_not_open_and_focus_is_restored(self):
        self.host.label_error = True
        with self.assertRaisesRegex(RuntimeError, 'label denied'): self.open()
        receipt = m.read(self.run/'window.json')
        self.assertEqual('none', receipt['status'])
        self.assertEqual('workspace:7', receipt['ref'])
        self.assertEqual('workspace:1', self.host.focus)
    def test_foreground_ping_does_not_authorize_reparented_caller(self):
        self.assertEqual('PONG', self.host('ping'))
        # The model changes authorization at the invoking shell's exit, as
        # recorded in the real-host evidence. No process is launched here.
        self.host.mode = 'cmuxOnly'; self.host.reject = True
        with self.assertRaisesRegex(RuntimeError, 'Failed to write to socket'): self.open()
        self.assertFalse(any(c[0]=='new-workspace' for c in self.host.calls))
    def test_stale_nested_context_requires_explicit_host_and_caller(self):
        with patch.dict(os.environ, {'CMUX_WORKSPACE_ID':'workspace:9'}, clear=True):
            self.assertEqual('none', m.window_host(self.run))
            with self.assertRaisesRegex(RuntimeError, 'FM_CMUX_CALLER_WORKSPACE'): self.open()
        with patch.dict(os.environ, {'FM_HOST':'herdr','HERDR_ENV':'1','CMUX_WORKSPACE_ID':'workspace:9'}, clear=True):
            self.assertEqual('herdr', m.window_host(self.run))
    def test_unknown_explicit_caller_does_not_use_focus(self):
        os.environ['FM_CMUX_CALLER_WORKSPACE'] = 'workspace:9'
        with self.assertRaisesRegex(RuntimeError, 'caller.*FM_CMUX_CALLER_WORKSPACE.*workspace:9'): self.open()
        self.assertFalse(any(c[0]=='new-workspace' for c in self.host.calls))

    def test_foreground_cmux_only_does_not_require_operator_changes(self):
        record = self.open()
        self.assertEqual('open', record['status'])
        self.assertEqual('cmuxOnly', record['access_mode'])
        self.assertEqual('workspace:1', self.host.focus)
    def test_unsafe_or_unknown_access_mode_is_refused(self):
        for mode in ('allowAll', 'off', None):
            with self.subTest(mode=mode):
                self.host.mode = mode; self.host.calls.clear()
                with self.assertRaisesRegex(RuntimeError, 'access mode'): self.open()
                self.assertFalse(any(c[0]=='new-workspace' for c in self.host.calls))
    def test_password_mode_survives_modeled_ancestry_loss(self):
        self.host.mode = 'password'; self.host.reject = True
        self.assertEqual('open', self.open()['status'])
    def test_missing_or_wrong_auth_preserves_error_without_creation(self):
        for error in ('authentication required', 'invalid password'):
            self.host.auth_error = error; self.host.calls.clear()
            with self.assertRaisesRegex(RuntimeError, error): self.open()
            self.assertFalse(any(c[0]=='new-workspace' for c in self.host.calls))
    def test_owner_term_records_retention_and_restores_handler(self):
        record = self.open()
        previous = signal.getsignal(signal.SIGTERM)
        with self.assertRaises(SystemExit):
            with m.cmux_shutdown(self.run):
                signal.getsignal(signal.SIGTERM)(signal.SIGTERM, None)
        self.assertEqual(previous, signal.getsignal(signal.SIGTERM))
        receipt = m.read(self.run/'window.json')
        self.assertIn('retained', receipt['status'])
        self.assertEqual('termination', receipt['shutdown'])
        self.assertIn(record['ref'], self.host.workspaces)
        self.assertFalse(any(c[0]=='close-workspace' for c in self.host.calls))

    def test_caller_listing_failures_keep_context_and_do_not_read_focus(self):
        original = self.host.__call__
        for response in ('not-json', '{}'):
            self.host.calls.clear()
            def invalid(*args):
                if args[0] == 'list-workspaces': return response
                return original(*args)
            with patch.object(m, 'Host', return_value=invalid):
                with self.assertRaisesRegex(RuntimeError, 'caller.*FM_CMUX_CALLER_WORKSPACE'):
                    self.open()
            self.assertFalse(any(c[0] in ('current-workspace', 'new-workspace') for c in self.host.calls))
    def test_term_during_creation_retains_partial_receipt_without_more_host_calls(self):
        original = self.host.__call__
        after_term = []
        def interrupted(*args):
            if after_term: self.fail('host command after termination')
            if args[0] == 'rename-workspace':
                after_term.append(True)
                signal.getsignal(signal.SIGTERM)(signal.SIGTERM, None)
            return original(*args)
        with patch.object(m, 'Host', return_value=interrupted), self.assertRaises(SystemExit):
            with m.cmux_shutdown(self.run): self.open()
        record = m.read(self.run/'window.json')
        self.assertEqual('none', record['status'])
        self.assertEqual('workspace:7', record['ref'])
        self.assertEqual('termination', record['shutdown'])

    def test_creation_failure_does_not_claim_visible_window(self):
        original = self.host.__call__
        def fail(*args):
            if args[0] == 'new-workspace': raise RuntimeError('creation denied')
            return original(*args)
        with patch.object(m, 'Host', return_value=fail):
            with self.assertRaisesRegex(RuntimeError, 'creation denied'): self.open()
        self.assertEqual('none', m.read(self.run/'window.json')['status'])
        self.assertEqual(['workspace:1'], list(self.host.workspaces))
    def test_changed_label_or_structure_is_retained(self):
        record = self.open()
        self.host.workspaces[record['ref']]['title'] = 'Captain adopted this'
        self.assertIn('retained', m.close_generic_window(record, self.run))
        self.host.workspaces[record['ref']]['title'] = record['actor']
        self.host.workspaces[record['ref']]['surfaces'] = ['new-surface']
        self.assertIn('retained', m.close_generic_window(record, self.run))
    def test_existing_resource_returned_by_create_is_never_renamed(self):
        original = self.host.__call__
        def wrong(*args):
            if args[0] == 'new-workspace': return 'OK workspace:1'
            return original(*args)
        with patch.object(m, 'Host', return_value=wrong):
            with self.assertRaisesRegex(RuntimeError, 'existing workspace'): self.open()
        self.assertFalse(any(c[0]=='rename-workspace' for c in self.host.calls))

class Diagnostics(unittest.TestCase):
    def test_socket_error_has_stderr_remediation_and_no_password(self):
        with tempfile.TemporaryDirectory() as tmp, patch.object(m.shutil, 'which', return_value='/fake/cmux'), \
             patch.dict(os.environ, {'CMUX_SOCKET_PASSWORD':'fixture-secret'}), \
             patch.object(m.subprocess, 'run', return_value=CompletedProcess([], 1, '',
                         'Error: Failed to write to socket fixture-secret')):
            with self.assertRaisesRegex(RuntimeError, 'Failed to write to socket') as caught:
                m.Host('cmux', tmp)('capabilities', '--json')
            self.assertIn('session-owned', str(caught.exception))
            self.assertIn('FM_HOST=herdr', str(caught.exception))
            self.assertNotIn('configure password mode', str(caught.exception))
            self.assertNotIn('fixture-secret', str(caught.exception))
            self.assertNotIn('fixture-secret', (Path(tmp)/'window.log').read_text())

unittest.main(argv=['cmux-window'], verbosity=2)
PY
