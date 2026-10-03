"""First-start persistence and conditional HTTP responses through a gh executable."""
import json
import os
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch

sys.dont_write_bytecode = True
ROOT = Path(sys.argv.pop(1))
sys.path.insert(0, str(ROOT / 'bin/lib'))
import fm_autopilot as A


class StartupCache(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name).resolve()
        self.state = self.root / 'state'
        (self.state / 'session').mkdir(parents=True)
        self.ctx = dict(engine=str(self.root), state=str(self.state), target=str(self.root),
                        project='self', repository='owner/repo', base='main',
                        evidence_project='self', external=False, tasks=str(self.root / 'tasks'))
        self.logs = {'offset': self.state / 'events.jsonl',
                     'wake_offset': self.state / 'session/wake.jsonl'}
        self.rows = {'offset': dict(type='gate_failed', task='T-001'),
                     'wake_offset': dict(reason='answered', decision=dict(task='T-002', chosen='B'))}
        self.gh = self.root / 'gh'
        # gh --include prints headers even when it exits 1 on HTTP 304.
        self.gh.write_text('''#!/usr/bin/env python3
import json, pathlib, sys
root = pathlib.Path(__file__).resolve().parent
args = sys.argv[1:]
with (root / 'calls.jsonl').open('a') as stream:
    stream.write(json.dumps(args) + '\\n')
status, code = json.loads((root / 'response.json').read_text())
if '--include' in args:
    sys.stdout.write('HTTP/2.0 ' + str(status) + {200: ' OK', 304: ' Not Modified', 500: ' Internal Server Error'}[status] + '\\r\\nETag: "one"\\r\\n\\r\\n')
if status == 200:
    sys.stdout.write('[]\\n')
if code:
    sys.stderr.write('gh: HTTP ' + str(status) + '\\n')
sys.exit(code)
''')
        self.gh.chmod(0o755)
        env = {k: v for k, v in os.environ.items() if not k.startswith(('FM_', 'HERDR_'))}
        env.update(FM_GH=str(self.gh), HERDR_ENV='0')
        environment = patch.dict(os.environ, env, clear=True)
        environment.start()
        self.addCleanup(environment.stop)

    def response(self, status, code):
        (self.root / 'response.json').write_text(json.dumps([status, code]))

    def fresh_context(self):
        temporary = tempfile.TemporaryDirectory(dir=self.root)
        self.addCleanup(temporary.cleanup)
        return {**self.ctx, 'state': temporary.name}

    def append(self, cursor):
        with self.logs[cursor].open('a') as stream:
            stream.write(json.dumps(self.rows[cursor]) + '\n')

    def test_first_start_skips_long_history_and_persists_before_poll(self):
        for cursor, log in self.logs.items():
            log.write_text((json.dumps(self.rows[cursor]) + '\n') * 1000)
        queue = self.state / 'wake-queue'
        queue.mkdir()
        old_wake = queue / 'historical.json'
        old_wake.write_text('{"line":"Already queued"}')
        pilot = A.Pilot(self.ctx)
        pilot.local()
        self.assertEqual(pilot.data['wakes'], {}, 'historical sources must queue no wakes')
        saved = json.loads(pilot.path.read_text())
        for cursor, log in self.logs.items():
            self.assertEqual(saved[cursor], log.stat().st_size)
        self.assertEqual(list(queue.iterdir()), [old_wake])

    def test_startup_boundary_is_durable_before_any_local_read_or_poll(self):
        for cursor in self.logs:
            self.append(cursor)
        pilot = A.Pilot(self.ctx)
        self.assertTrue(pilot.path.is_file(), 'first-start cursors must be saved before polling')
        saved = json.loads(pilot.path.read_text())
        for cursor, log in self.logs.items():
            self.assertEqual(saved[cursor], log.stat().st_size)
            self.append(cursor)
        # Simulate a crash before the first local read, then resume saved offsets.
        restored = A.Pilot(self.ctx)
        restored.local()
        self.assertEqual(len(restored.data['wakes']), 2)
        self.assertEqual({w['task'] for w in restored.data['wakes'].values()}, {'T-001', 'T-002'})
        restored.local()
        self.assertEqual(len(restored.data['wakes']), 2)

    def test_saved_zero_cursors_resume_instead_of_skipping_unread_events(self):
        directory = self.state / 'autopilot'
        directory.mkdir()
        (directory / 'state.json').write_text('{"offset":0,"wake_offset":0}')
        for cursor in self.logs:
            self.append(cursor)
        pilot = A.Pilot(self.ctx)
        pilot.local()
        self.assertEqual(len(pilot.data['wakes']), 2)

    def test_missing_logs_start_at_zero_and_accept_later_events(self):
        pilot = A.Pilot(self.ctx)
        for cursor in self.logs:
            self.assertEqual(pilot.data[cursor], 0)
            self.append(cursor)
        pilot.local()
        self.assertEqual(len(pilot.data['wakes']), 2)

    def test_conditional_304_returns_cached_body_without_changing_failure_state(self):
        for code in (1, 0):
            with self.subTest(exit_status=code):
                pilot = A.Pilot(self.fresh_context(), clock=lambda: 1000)
                self.response(200, 0)
                self.assertEqual(pilot.api('pulls'), [])
                pilot.data.update(failures=2, next_poll=2000)
                self.response(304, code)
                self.assertEqual(pilot.api('pulls'), [])
                self.assertEqual(pilot.data['failures'], 2)
                self.assertEqual(pilot.data['next_poll'], 2000)
                self.assertEqual(pilot.data['wakes'], {})
                calls = [json.loads(line) for line in (self.root / 'calls.jsonl').read_text().splitlines()]
                self.assertNotIn('-H', calls[-2])
                self.assertIn('If-None-Match: "one"', calls[-1])
                self.assertIn('--include', calls[-1])
                self.assertIn('repos/owner/repo/pulls', calls[-1])
                with self.assertRaises((RuntimeError, ValueError)):
                    pilot.api('uncached-endpoint')

    def test_conditional_304_poll_uses_normal_cadence_without_backoff(self):
        pilot = A.Pilot(self.ctx, clock=lambda: 1000)
        self.response(200, 0)
        pilot.poll()
        self.response(304, 1)
        pilot.poll()
        self.assertEqual(pilot.data['failures'], 0)
        self.assertEqual(pilot.data['next_poll'], 1060)
        self.assertEqual(pilot.data['wakes'], {})

    def test_500_backs_off_even_with_cached_body_and_zero_exit_status(self):
        for code in (1, 0):
            with self.subTest(exit_status=code):
                pilot = A.Pilot(self.fresh_context(), clock=lambda: 1000)
                self.response(200, 0)
                pilot.poll()
                self.response(500, code)
                pilot.poll()
                self.assertEqual(pilot.data['failures'], 1)
                self.assertEqual(pilot.data['next_poll'], 1120)
                self.assertEqual(len(pilot.data['wakes']), 1)
                self.assertIn('backing off', next(iter(pilot.data['wakes'].values()))['line'])


if __name__ == '__main__':
    unittest.main()
