"""T-203: real frozen services, isolated git trees, and request/idle rules."""
import ast
import contextlib
import fcntl
import io
import json
import os
from pathlib import Path
import select
import shutil
import subprocess
import sys
import tempfile
import threading
import time
import types
import unittest
from unittest.mock import patch

sys.dont_write_bytecode = True
ROOT = Path(sys.argv.pop(1)).resolve()
sys.path.insert(0, str(ROOT / 'bin/lib'))
import fm_autopilot as A
import fm_lifeline as life


class Reload(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name).resolve()
        for folder in ('bin', 'skills'):
            shutil.copytree(ROOT / folder, self.root / folder)
        for name in ('config.yaml', '.gitignore'):
            shutil.copy2(ROOT / name, self.root / name)
        self.git('init', '-q')
        self.git('config', 'user.name', 'Reload fixture')
        self.git('config', 'user.email', 'reload@example.invalid')
        self.commit()
        (self.root / 'design/tasks').mkdir(parents=True)
        self.directory = self.root / 'state/autopilot'
        self.directory.mkdir(parents=True)
        self.env = {k: v for k, v in os.environ.items() if not k.startswith(('FM_', 'HERDR_'))}
        gh = self.root / 'gh'
        gh.write_text('#!/bin/sh\nprintf \'HTTP/2.0 200 OK\\nETag: "empty"\\n\\n[]\\n\'\n')
        gh.chmod(0o755)
        self.env.update(FM_AUTOPILOT_TEST_ENABLE='1', HERDR_ENV='0',
                        FM_GH=str(gh), GH_REPO='owner/repo', FM_AUTOPILOT_RELOAD_WAIT='3',
                        FM_ENGINE_ROOT=str(self.root), FM_STATE_DIR=str(self.root / 'state'),
                        FM_TARGET_ROOT=str(self.root), FM_TASKS_DIR=str(self.root / 'design/tasks'),
                        FM_EXTERNAL='0', FM_EVIDENCE_PROJECT='firstmate-workflow',
                        FM_AUTOPILOT_REPOSITORY='owner/repo')
        self.owner = None

    def git(self, *args):
        return subprocess.run(['git', '-C', str(self.root), *args], check=True,
                              capture_output=True, text=True).stdout.strip()

    def commit(self):
        self.git('add', 'bin', 'skills', 'config.yaml', '.gitignore')
        self.git('commit', '-qm', 'fixture')
        return A.code_id(self.root, ('bin', 'skills'))

    def changed(self, label='next'):
        path = self.root / 'bin/lib/fm_autopilot_loop.py'
        path.write_text(path.read_text() + '\n# ' + label + '\n')
        return self.commit()

    def read(self, name):
        return A.read_json(self.directory / (name + '.json'))

    def wait_for(self, predicate, seconds=25):
        deadline = time.monotonic() + seconds
        while time.monotonic() < deadline:
            result = predicate()
            if result: return result
            time.sleep(.05)
        self.fail('timed out; service.log: ' + (self.directory / 'service.log').read_text())

    def shell(self, mode='ensure', ok=True):
        self.assertNotIn('FM_CODE_ROOT', self.env)
        result = subprocess.run(['bash', str(self.root / 'bin/fm-autopilot.sh'), mode,
                                 '--repo', str(self.root)], env=self.env,
                                capture_output=True, text=True, timeout=60)
        if ok: self.assertEqual(result.returncode, 0, result.stderr)
        self.assertNotIn('predates self-reload', result.stderr)
        return result

    def start(self, clean=True):
        self.owner = life.start([sys.executable, '-c', 'import sys; sys.stdin.buffer.read()'],
                                owner=os.getpid(), stdin=subprocess.PIPE,
                                stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        self.env['FM_SESSION_PID'] = str(self.owner.pid)
        self.addCleanup(self.stop)
        self.shell()
        record = self.wait_for(lambda: self.read('owner').get('started_ok') and self.read('owner'))
        if clean: self.assertFalse(A.code_id(self.root, ('bin', 'skills'))['dirty'])
        return record

    def stop(self):
        pid = self.read('owner').get('pid')
        try: event = life.ProcessExit(pid) if pid else None
        except life.OwnerGone: event = None
        self.owner.stdin.close()
        self.owner.wait(timeout=15)
        if event:
            try: self.assertTrue(select.select([event.fileno()], [], [], 15)[0])
            finally: event.close()

    def request(self, target, source):
        with A.Locked(self.directory / 'start.lock'):
            reload = self.read('reload')
            reload['request'] = dict(to=target, **{'from': source}, requested=time.time())
            A.save_json(self.directory / 'reload.json', reload)
        life.ring_events(self.root / 'state', 'fixture request')

    def reloaded(self, old, target):
        record = self.wait_for(lambda: self.read('owner').get('started_ok') and
                               self.read('owner').get('pid') != old['pid'] and
                               self.read('owner').get('code') == target and self.read('owner'))
        self.assertTrue(A.live(self.directory))
        self.assertEqual('reloaded', self.read('reload')['outcome']['kind'])
        self.assertEqual(target, self.read('reload')['outcome']['to'])
        self.assertEqual([], self.read('reload')['failed_ids'])
        # A shared probe must fail while the one exclusive holder serves.
        with (self.directory / 'service.lock').open('a') as lock:
            with self.assertRaises(BlockingIOError): fcntl.flock(lock, fcntl.LOCK_SH | fcntl.LOCK_NB)
        return record

    def test_identity_reload_probes_and_once_only_outcome(self):
        old = self.start()
        self.assertEqual(A.code_id(self.root, ('bin', 'skills')), old['code'])
        self.assertEqual('', self.shell().stderr)
        self.assertEqual(old['pid'], self.read('owner')['pid'])
        target = self.changed()
        exited = life.ProcessExit(old['pid'])
        stop = threading.Event()
        def probes():
            while not stop.is_set(): A.live(self.directory)
        thread = threading.Thread(target=probes)
        thread.start()
        try:
            self.assertIn('reload requested:', self.shell().stderr)
            self.reloaded(old, target)
            self.assertTrue(select.select([exited.fileno()], [], [], 15)[0])
        finally:
            stop.set(); thread.join(); exited.close()
        self.assertIn('reloaded:', self.shell().stderr)
        self.assertEqual('', self.shell().stderr)
        status = json.loads(self.shell('status').stdout)
        self.assertEqual(self.read('reload')['outcome'], status['reload']['outcome'])
        self.assertEqual({'request', 'outcome', 'failed_ids'}, set(status['reload']))
        env = dict(self.env, FM_AUTOPILOT_OWNED='1')
        before = time.monotonic()
        second = subprocess.run([sys.executable, str(self.root / 'bin/lib/fm_autopilot.py'), 'serve'],
                                env=env, capture_output=True, timeout=10)
        self.assertEqual(0, second.returncode, second.stderr)
        self.assertGreaterEqual(time.monotonic() - before, 1.9)

    def test_dirty_notice_legacy_and_unknown_owner(self):
        old = self.start()
        dirty = self.root / 'bin/uncommitted'
        dirty.write_text('dirty')
        self.assertIn('uncommitted changes', self.shell().stderr)
        self.assertEqual('', self.shell().stderr)
        self.assertIsNone(self.read('reload')['request'])
        dirty.unlink()
        record = dict(old); record.pop('code')
        A.save_json(self.directory / 'owner.json', record)
        def legacy():
            return subprocess.run([sys.executable, str(self.root / 'bin/lib/fm_autopilot.py'), 'running'],
                                  env=self.env, capture_output=True, text=True, check=True).stderr
        self.assertIn('predates self-reload', legacy())
        self.assertEqual('', legacy())
        self.assertIsNone(self.read('reload')['request'])
        record['code'] = None
        A.save_json(self.directory / 'owner.json', record)
        self.assertIn('reload requested', self.shell().stderr)
        # The real running code is still old['code']; make the checkout newer
        # so handoff_target also observes a difference from its actual code.
        target = self.changed()
        self.shell()
        self.reloaded(old, target)

    def test_service_with_unknown_code_reloads_to_real_identity(self):
        # A non-git engine at startup records null, then becomes identifiable.
        gitdir = self.root / '.git'
        parked = self.root / 'saved-git'
        gitdir.rename(parked)
        self.owner = life.start([sys.executable, '-c', 'import sys; sys.stdin.buffer.read()'],
                                owner=os.getpid(), stdin=subprocess.PIPE,
                                stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        self.env['FM_SESSION_PID'] = str(self.owner.pid); self.addCleanup(self.stop)
        self.shell()
        old = self.wait_for(lambda: self.read('owner').get('started_ok') and self.read('owner'))
        self.assertIsNone(old['code'])
        parked.rename(gitdir)
        target = A.code_id(self.root, ('bin', 'skills'))
        self.assertIn('reload requested', self.shell().stderr)
        self.reloaded(old, target)

    def test_dirty_snapshot_reloads_when_clean(self):
        path = self.root / 'bin/dirty-snapshot'
        path.write_text('uncommitted')
        # start()'s clean assertion is deliberately bypassed for this case.
        self.owner = life.start([sys.executable, '-c', 'import sys; sys.stdin.buffer.read()'],
                                owner=os.getpid(), stdin=subprocess.PIPE,
                                stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        self.env['FM_SESSION_PID'] = str(self.owner.pid); self.addCleanup(self.stop)
        self.shell()
        old = self.wait_for(lambda: self.read('owner').get('started_ok') and self.read('owner'))
        self.assertTrue(old['code']['dirty'])
        path.unlink()  # same committed trees, now clean
        target = A.code_id(self.root, ('bin', 'skills'))
        self.assertEqual(old['code']['bin'], target['bin'])
        self.assertIn('reload requested', self.shell().stderr)
        self.reloaded(old, target)

    def test_dirty_snapshot_reloads_after_edits_are_committed(self):
        (self.root / 'bin/dirty-snapshot').write_text('uncommitted')
        old = self.start(clean=False)
        self.assertTrue(old['code']['dirty'])
        target = self.commit()
        self.assertIn('reload requested', self.shell().stderr)
        self.reloaded(old, target)

    def test_head_moves_before_handoff(self):
        old = self.start()
        first = self.changed('A'); latest = self.changed('B')
        self.request(first, old['code'])
        self.reloaded(old, latest)

    def test_slow_start_preserves_request_and_outcome(self):
        old = self.start()
        path = self.root / 'bin/lib/fm_autopilot_loop.py'
        source = path.read_text()
        path.write_text(source.replace('    def recover_jobs(self):',
                         '    def recover_jobs(self):\n        import time; time.sleep(4.5)'))
        target = self.commit()
        exited = life.ProcessExit(old['pid'])
        self.addCleanup(exited.close)
        self.assertIn('reload requested', self.shell().stderr)
        self.wait_for(lambda: self.read('owner').get('pid') not in (None, old['pid']) and
                      not self.read('owner').get('started_ok'))
        self.assertEqual('', self.shell().stderr)
        self.assertIsNotNone(self.read('reload')['request'])
        self.reloaded(old, target)
        self.assertTrue(select.select([exited.fileno()], [], [], 15)[0])
        self.assertIn('reloaded:', self.shell().stderr)
        self.assertEqual('', self.shell().stderr)
        self.assertFalse(any(w['line'].startswith('Autopilot reload to ') for w in self.read('state')['wakes'].values()))

    def failure(self, import_failure):
        old = self.start()
        path = self.root / ('bin/lib/fm_autopilot.py' if import_failure else 'bin/lib/fm_autopilot_loop.py')
        source = path.read_text()
        path.write_text('raise RuntimeError("broken reload fixture")\n' + source if import_failure else
                        source.replace('    def recover_jobs(self):',
                                       '    def recover_jobs(self):\n        raise SystemExit(70)'))
        target = self.commit()
        if import_failure: self.request(target, old['code'])
        else: self.assertIn('reload requested', self.shell().stderr)
        self.wait_for(lambda: (self.read('reload').get('outcome') or {}).get('kind') == 'failed')
        self.wait_for(lambda: self.read('owner').get('started_ok') and A.live(self.directory) and
                      self.read('reload')['outcome'].get('woken'))
        outcome = self.read('reload')['outcome']
        self.assertEqual('failed', outcome['kind'])
        self.assertEqual(target, outcome['to'])
        self.assertEqual([target], self.read('reload')['failed_ids'])
        self.assertEqual(old['code'], self.read('owner')['code'])
        self.assertEqual(old['snapshot'], self.read('owner')['snapshot'])
        self.assertEqual(1, sum(w['line'].startswith('Autopilot reload to ') for w in self.read('state')['wakes'].values()))
        if import_failure: self.assertNotEqual(0, self.shell(ok=False).returncode)
        else:
            self.shell()
            self.assertIsNone(self.read('reload')['request'])
        path.write_text(source + '\n# repaired\n')
        fixed = self.commit()
        result = self.shell()
        if import_failure: self.assertIn('failed (', result.stderr)
        self.assertIn('reload requested', result.stderr)
        self.wait_for(lambda: self.read('owner').get('code') == fixed and self.read('owner').get('started_ok'))
        self.assertEqual('reloaded', self.read('reload')['outcome']['kind'])
        self.assertEqual([target], self.read('reload')['failed_ids'])

    def test_import_failure_falls_back_to_old_snapshot(self): self.failure(True)
    def test_death_after_ready_is_failure_not_reload(self): self.failure(False)

    def test_running_rules_with_standin_lock_holder(self):
        own = A.code_id(self.root, ('bin', 'skills'))
        record = dict(pid=os.getpid(), code=own, started_ok=True)
        A.save_json(self.directory / 'owner.json', record)
        def running():
            return subprocess.run([sys.executable, str(self.root / 'bin/lib/fm_autopilot.py'), 'running'],
                                  env=self.env, check=True, capture_output=True, text=True).stderr
        with (self.directory / 'service.lock').open('a') as lock:
            fcntl.flock(lock, fcntl.LOCK_EX)
            target = self.changed()
            self.assertIn('reload requested', running())
            self.assertEqual(target, self.read('reload')['request']['to'])
            status = json.loads(self.shell('status').stdout)
            self.assertEqual(target, status['reload']['request']['to'])
            path = self.root / 'bin/uncommitted'; path.write_text('dirty')
            self.assertIn('uncommitted changes', running())
            self.assertIsNone(self.read('reload')['request'])
            path.unlink(); running()
            self.git('revert', '--no-edit', 'HEAD')
            self.assertEqual('', running())
            self.assertIsNone(self.read('reload')['request'])
            for starting in (dict(pid=None, code=own), dict(pid=os.getpid(), code=own)):
                self.request(target, own)
                pending = self.read('reload')['request']
                A.save_json(self.directory / 'owner.json', starting)
                self.assertEqual('', running())
                self.assertEqual(pending, self.read('reload')['request'])
                self.assertIsNone(self.read('reload')['legacy_seen'])


class Rules(unittest.TestCase):
    def test_idle_and_identity(self):
        own = dict(bin='a'*40, skills='b'*40, dirty=False)
        target = dict(own, bin='c'*40)
        pilot = types.SimpleNamespace(data=dict(jobs={}, actions={}, batches={}, wakes={}))
        reload = dict(request={'to': target}, failed_ids=[])
        self.assertTrue(A.reload_due(pilot, own, reload))
        for field, value in [('jobs', {'state':'running'}), ('jobs', {'state':'consuming'}),
                             ('actions', {'state':'started'}), ('batches', {}), ('wakes', {'pushed':False})]:
            pilot.data[field]['one'] = value
            self.assertFalse(A.reload_due(pilot, own, reload), (field, value))
            pilot.data[field].clear()
        pilot.data.update(jobs={'a':{'state':'uncertain'}, 'b':{'state':'done'}},
                          actions={'a':{'state':'done'}, 'b':{'state':'uncertain'}}, wakes={'a':{'pushed':True}})
        self.assertTrue(A.reload_due(pilot, own, reload))
        self.assertFalse(A.reload_due(pilot, own, dict(reload, failed_ids=[target])))
        self.assertFalse(A.reload_due(pilot, target, reload))
        self.assertTrue(A.reload_due(pilot, dict(target, dirty=True), reload))
        for current in (None, dict(target, dirty=True), own, target):
            with patch.object(A, 'code_id', return_value=current):
                self.assertEqual(target if current == target else None,
                                 A.handoff_target({'engine':'unused'}, own, reload))
        with patch.object(A.subprocess, 'run') as run:
            self.assertIsNone(A.code_id(ROOT / 'bin', ('bin', 'skills')))
            run.assert_not_called()

    def test_shared_probes_do_not_look_like_a_service(self):
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary)
            with (directory / 'service.lock').open('a') as lock:
                fcntl.flock(lock, fcntl.LOCK_SH)
                self.assertFalse(A.live(directory))
                fcntl.flock(lock, fcntl.LOCK_EX)
                self.assertTrue(A.live(directory))

    def test_code_identity_rejects_nested_roots_and_ignores_bytecode(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            (root / 'bin').mkdir(); (root / 'skills').mkdir()
            (root / 'bin/code').write_text('code')
            (root / 'skills/code').write_text('skill')
            (root / '.gitignore').write_text('__pycache__/\n')
            def git(*args):
                return subprocess.run(['git', '-C', str(root), *args], check=True, capture_output=True)
            git('init', '-q'); git('add', '.')
            git('-c', 'user.name=Fixture', '-c', 'user.email=fixture@example.invalid', 'commit', '-qm', 'initial')
            identity = A.code_id(root, ('bin', 'skills'))
            self.assertFalse(identity['dirty'])
            (root / 'bin/__pycache__').mkdir()
            (root / 'bin/__pycache__/ignored.pyc').write_bytes(b'ignored')
            self.assertEqual(identity, A.code_id(root, ('bin', 'skills')))
            self.assertIsNone(A.code_id(root / 'bin', ('bin', 'skills')))
            wrong_top = subprocess.CompletedProcess([], 0, str(root.parent) + '\n' + 'a'*40 + '\n' + 'b'*40 + '\n')
            with patch.object(A.subprocess, 'run', return_value=wrong_top):
                self.assertIsNone(A.code_id(root, ('bin', 'skills')))
            (root / 'bin/untracked').write_text('dirty')
            self.assertTrue(A.code_id(root, ('bin', 'skills'))['dirty'])
            self.assertIsNone(A.code_id(root, ('missing',)))

    def test_identity_git_calls_never_take_optional_locks(self):
        for path, name in [(ROOT/'bin/lib/fm_autopilot.py', 'code_id'), (ROOT/'bin/fm-herdr.py', 'board_code_id')]:
            tree = ast.parse(path.read_text())
            function = next(n for n in tree.body if isinstance(n, ast.FunctionDef) and n.name == name)
            commands = [n for n in ast.walk(function) if isinstance(n, ast.List) and n.elts and
                        isinstance(n.elts[0], ast.Constant) and n.elts[0].value == 'git']
            self.assertEqual(2, len(commands))
            for command in commands:
                self.assertIn('--no-optional-locks', [n.value for n in command.elts if isinstance(n, ast.Constant)])
            self.assertIn('GIT_OPTIONAL_LOCKS', ast.unparse(function))


if __name__ == '__main__': unittest.main()
