"""T-257: deterministic publication-gap and passive timeout diagnostics."""
import fcntl
import json
import os
from pathlib import Path
import select
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

sys.dont_write_bytecode = True
ROOT = Path(sys.argv.pop(1)).resolve()
sys.path.insert(0, str(ROOT / 'bin/lib'))
import fm_lifeline as life
import autopilot_reload_observation as observation

TARGET = dict(bin='a' * 40, skills='b' * 40, dirty=False)
OLD = dict(TARGET, bin='c' * 40)


def writer(directory):
    """One-byte pipe handshakes establish ordering without readiness sleeps."""
    directory = Path(directory)
    with (directory / 'start.lock').open('a') as lock:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        (directory / 'owner.json').write_text(json.dumps(dict(
            started_ok=True, code=TARGET, pid=os.getpid(), owner=os.getppid())))
        os.write(1, b'G')
        if not select.select([0], [], [], 10)[0] or os.read(0, 1) != b'R':
            raise RuntimeError('fixture release handshake timed out')
        (directory / 'reload.json').write_text(json.dumps(dict(
            outcome=dict(kind='reloaded', to=TARGET, **{'from': OLD}))))
    os.write(1, b'D')


class Observation(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.directory = Path(temporary.name)

    def save(self, name, value):
        (self.directory / (name + '.json')).write_text(json.dumps(value))

    def ready(self):
        self.save('owner', dict(started_ok=True, code=TARGET, pid=os.getpid(), owner=os.getpid()))
        self.save('reload', dict(outcome=dict(kind='reloaded', to=TARGET)))

    def test_write_gap_keeps_completion_pending(self):
        self.save('reload', dict(outcome=dict(kind='failed', to=OLD)))
        child = life.start([sys.executable, __file__, str(ROOT), '--writer', str(self.directory)],
                           owner=os.getpid(), stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                           stderr=subprocess.PIPE)
        try:
            self.assertTrue(select.select([child.stdout], [], [], 10)[0], 'writer gap handshake')
            self.assertEqual(b'G', os.read(child.stdout.fileno(), 1))
            snapshot = observation.read_completion(self.directory)
            self.assertIsNone(snapshot, 'start.lock write gap must return no snapshot')
            self.assertIsNone(observation.completed(snapshot, TARGET), 'busy completion stays pending')
            report = observation.timeout_report(self.directory, 25.0)
            self.assertEqual('busy', report['start_lock'])
            self.assertTrue(report['owner']['started_ok'])
            self.assertEqual('failed', report['reload']['outcome']['kind'])
            self.assertIsNone(report['coherent'])
            os.write(child.stdin.fileno(), b'R')
            self.assertTrue(select.select([child.stdout], [], [], 10)[0], 'writer done handshake')
            self.assertEqual(b'D', os.read(child.stdout.fileno(), 1))
            self.assertEqual(0, child.wait(timeout=10))
            snapshot = observation.read_completion(self.directory)
            self.assertEqual(TARGET, snapshot[0]['code'])
            self.assertEqual('reloaded', snapshot[1]['outcome']['kind'])
            self.assertEqual(TARGET, snapshot[1]['outcome']['to'])
            self.assertEqual([], snapshot[1]['failed_ids'])
            self.assertEqual(snapshot, observation.completed(snapshot, TARGET))
        finally:
            child.stdin.close()
            if child.poll() is None:
                child.terminate()
            try:
                child.wait(timeout=10)
            except subprocess.TimeoutExpired:
                child.kill()
                child.wait(timeout=10)
            child.stdout.close()
            child.stderr.close()

    def test_incomplete_records_do_not_complete(self):
        self.assertIsNone(observation.completed(observation.read_completion(self.directory), TARGET))
        for owner, outcome in [
            (dict(started_ok=False, code=TARGET), dict(kind='reloaded', to=TARGET)),
            (dict(started_ok=True, code=TARGET), dict(kind='reloaded', to=OLD)),
            (dict(started_ok=True, code=TARGET), dict(kind='failed', to=TARGET)),
            (dict(started_ok=True, code=OLD), dict(kind='reloaded', to=TARGET)),
        ]:
            with self.subTest(owner=owner, outcome=outcome):
                self.save('owner', owner)
                self.save('reload', dict(outcome=outcome))
                self.assertIsNone(observation.completed(observation.read_completion(self.directory), TARGET))
        self.ready()
        snapshot = observation.read_completion(self.directory)
        self.assertIsNone(observation.completed(snapshot, TARGET, old_pid=os.getpid()))
        self.assertEqual(snapshot, observation.completed(snapshot, TARGET, old_pid=-1))

    def test_ready_report_and_log_cap_are_passive(self):
        self.ready()
        log = b'prefix' + b'x' * 8192
        (self.directory / 'service.log').write_bytes(log)
        before = {p.name: p.read_bytes() for p in self.directory.glob('*.json')}
        with (self.directory / 'service.lock').open('a') as lock:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
            report = observation.timeout_report(self.directory, 25.25)
        self.assertEqual('available', report['start_lock'])
        self.assertTrue(report['service_lock_live'])
        self.assertTrue(report['processes']['owner']['alive'])
        self.assertTrue(report['processes']['service']['alive'])
        self.assertEqual(25.25, report['elapsed_seconds'])
        self.assertEqual('x' * 8192, report['service_log_tail'])
        self.assertEqual(observation.read_completion(self.directory), report['coherent'])
        self.assertEqual(before, {p.name: p.read_bytes() for p in self.directory.glob('*.json')})

    def test_missing_files_and_failed_probe(self):
        report = observation.timeout_report(self.directory, 0)
        self.assertEqual('FileNotFoundError', report['owner']['diagnostic_error'])
        self.assertEqual('FileNotFoundError', report['reload']['diagnostic_error'])
        self.assertEqual('FileNotFoundError', report['service_log_tail']['diagnostic_error'])
        self.assertFalse(report['service_lock_live'])
        self.assertIsNone(report['processes']['owner']['alive'])
        with patch.object(observation, 'service_live', side_effect=OSError('fixture probe')):
            report = observation.timeout_report(self.directory, 25)
        self.assertEqual('OSError', report['service_lock_live']['diagnostic_error'])
        self.assertIn('coherent', report)
        with patch.object(observation, 'read_completion', side_effect=PermissionError('fixture lock')):
            report = observation.timeout_report(self.directory, 25)
        self.assertEqual('unavailable', report['start_lock'])
        self.assertEqual('PermissionError', report['coherent']['diagnostic_error'])

    def test_wait_timeout_preserves_assertion_when_reporter_fails(self):
        # Import the existing wait method without running its service fixtures.
        with patch.object(sys, 'argv', [__file__, str(ROOT)]):
            from autopilot_reload import Reload
        case = Reload()
        case.directory = self.directory
        with self.assertRaisesRegex(AssertionError, 'timed out;.*FileNotFoundError'):
            case.wait_for(lambda: False, seconds=0)
        with patch('autopilot_reload.observation.timeout_report', side_effect=RuntimeError('probe')):
            with self.assertRaisesRegex(AssertionError, 'timed out;.*RuntimeError'):
                case.wait_for(lambda: False, seconds=0)


if __name__ == '__main__':
    if sys.argv[1:2] == ['--writer']:
        writer(sys.argv[2])
    else:
        unittest.main()
