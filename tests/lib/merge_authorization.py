"""Time-boxed merge evidence and durable timer boundaries (T-182)."""
import datetime
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

os.environ['HERDR_ENV'] = '0'
sys.dont_write_bytecode = True
ROOT = Path(sys.argv.pop(1))
sys.path.insert(0, str(ROOT / 'bin/lib'))
import fm_autopilot as A
import fm_merge_authorization as M


class Authorization(unittest.TestCase):
    def setUp(self):
        tmp = tempfile.TemporaryDirectory(); self.addCleanup(tmp.cleanup)
        self.root = Path(tmp.name)
        self.state = self.root / 'state'
        self.now = 2000000000
        self.ctx = dict(engine=str(self.root), state=str(self.state), target=str(self.root),
                        project='self', evidence_project='self', repository='owner/repo',
                        base='main', external=False, tasks=str(self.root / 'tasks'))
        self.restart()

    def restart(self):
        self.p = A.Pilot(self.ctx, clock=lambda: self.now)
        self.p.push = lambda *a: None
        self.p.notify = lambda *a: None
        self.p.emit = lambda *a, **kw: None

    def record(self, seconds):
        until = datetime.datetime.fromtimestamp(self.now + seconds, datetime.timezone.utc).isoformat()
        item = M.record(self.state, until, 'Merge green cards until then', clock=lambda: self.now)
        self.p.local()
        return item

    def tick(self):
        self.p.flush()
        return [w['line'] for w in self.p.data['wakes'].values()]

    def test_boundaries_restart_and_replacement(self):
        record = self.record(3660)
        self.assertEqual(record['recorded_at'], self.now)
        self.assertEqual(self.tick(), [])
        self.now += 60
        (self.state / 'events.jsonl').write_text(json.dumps(dict(
            type='review_opened', actor='reviewer-fixture', task='T-003')) + '\n')
        pending = self.state / 'pending'; pending.mkdir()
        (pending / 'D-one.json').write_text(json.dumps(dict(kind='merge', id='D-one', task='T-001', pr=1)))
        self.p.data['pulls'] = {'1': dict(task='T-001', head='a', merge_evidence=dict(head='a', approved=True, green=True)),
                                '2': dict(task='T-002', head='b', merge_evidence=dict(head='b', approved=True, green=True)),
                                '3': dict(task='T-003', head='c')}
        lines = self.tick()
        self.assertEqual(len(lines), 1, '60 minutes queues exactly one warning')
        for text in ('merge authorization ends at', 'pending merge cards: D-one',
                     'approved green PRs without cards: T-002 #2', 'in-flight rounds: T-003 #3 (reviewer)'):
            self.assertIn(text, lines[0])
        self.restart(); self.assertEqual(self.tick(), lines)
        self.now += 3600
        lines = self.tick()
        self.assertEqual(len(lines), 2)
        self.assertEqual(lines[-1], 'merge authorization ended')
        self.restart(); self.assertEqual(self.tick(), lines)
        new = self.record(600)
        self.assertNotEqual(new['id'], record['id'])
        self.assertEqual(len(self.tick()), 3)
        self.now += 600
        self.assertEqual(len(self.tick()), 4)

    def test_timer_deadline_beats_network_backoff(self):
        self.record(3660)
        self.p.local()
        self.p.data['next_poll'] = self.now + 7200
        self.assertEqual(self.p.delay(), 60)

    def test_invalid_input_preserves_window(self):
        old = self.record(60)
        for until, quote in [('2030-01-01T00:00:00', 'words'), ('bad', 'words'),
                             ('2099-01-01T00:00:00Z', ' '), ('2000-01-01T00:00:00Z', 'words')]:
            with self.assertRaises(ValueError): M.record(self.state, until, quote, clock=lambda: self.now)
        self.assertEqual(M.read(self.state), old)

    def test_observed_pr_evidence_is_head_bound_and_requires_green_checks(self):
        pr = dict(number=2, state='open', head=dict(sha='a', ref='task'),
                  base=dict(ref='main', sha='base'))
        self.p.task = lambda pr: 'T-002'
        self.p.once = lambda *args: None
        self.p.verdict = lambda task: dict(verdict='APPROVE', head='a')
        self.p.settled_checks = lambda *args: [('ci', 'check', 1, 'success')]
        self.p.pull(pr, [], [], [], [])
        with patch('fm_concurrent.live_rounds', return_value=[]):
            self.assertEqual(M.inventory(self.p)[1], ['T-002 #2'])
            pr['head']['sha'] = 'b'
            self.p.pull(pr, [], [], [], [])
            self.assertEqual(M.inventory(self.p)[1], [])
            self.p.verdict = lambda task: dict(verdict='APPROVE', head='b')
            for checks in (None, [('ci', 'check', 2, 'failure')]):
                self.p.settled_checks = lambda *args: checks
                self.p.pull(pr, [], [], [], [])
                self.assertEqual(M.inventory(self.p)[1], [])
            self.p.settled_checks = lambda *args: [('ci', 'check', 3, 'success')]
            self.p.pull(pr, [], [], [], [])
            self.assertEqual(M.inventory(self.p)[1], ['T-002 #2'])
            self.p.busy = lambda task: True
            with patch.object(self.p, 'settled_checks') as settled:
                self.p.pull(pr, [], [], [], [])
            settled.assert_not_called()
            self.assertEqual(M.inventory(self.p)[1], [], 'held advancement must not retain stale readiness')

    def test_start_after_expiry_only_ends_and_does_not_spin(self):
        self.record(60)
        self.now += 120
        self.restart()
        self.assertEqual(self.tick(), ['merge authorization ended'])
        self.assertEqual(M.deadline(self.p, A.key), [])
        self.restart()
        self.assertEqual(self.tick(), ['merge authorization ended'])

    def test_poll_without_window_adds_no_reminder_calls(self):
        pr = dict(number=2, state='open', head=dict(sha='a', ref='task'),
                  base=dict(ref='main', sha='base'), mergeable_state='clean')
        responses = {
            'pulls?state=open&per_page=100&page=1': [pr],
            'pulls?state=closed&sort=updated&direction=desc&per_page=50': [],
            'pulls/2': pr,
            'pulls/2/reviews?per_page=100&page=1': [],
            'pulls/2/comments?per_page=100&page=1': [],
            'commits/a/check-runs?per_page=100': dict(check_runs=[]),
            'commits/a/status?per_page=100': dict(sha='a', statuses=[]),
            'branches/main/protection/required_status_checks': dict(contexts=['ci']),
        }
        calls = []
        def api(endpoint):
            calls.append(endpoint)
            return responses[endpoint]
        self.p.api = api
        self.p.task = lambda pr: 'T-002'
        self.p.observe_pr = lambda pr: None
        self.p.inspect_policy = lambda: None
        with patch.object(self.p, 'verdict', return_value={}) as verdict:
            self.p.poll()
        self.assertEqual(calls, list(responses), 'reminders must not add API calls to a poll')
        self.assertEqual(verdict.call_count, 1, 'reuse the advancement verdict')
        self.assertEqual(self.p.data['failures'], 0)
        self.assertEqual(self.p.data['wakes'], {})

    def test_timer_inventory_uses_recorded_rounds_without_subprocesses(self):
        self.record(60)
        run = self.state / 'runs/legacy'; run.mkdir(parents=True)
        (run / 'identity.json').write_text(json.dumps(dict(task='T-003', role='worker')))
        (run / 'process.json').write_text(json.dumps(dict(pid=123456789, token='fixture')))
        events = [dict(type=kind, actor=actor, task=task) for kind, actor, task in (
            ('dispatched', 'worker-live', 'T-003'),
            ('review_opened', 'reviewer-ended', 'T-004'),
            ('agent_finished', 'reviewer-ended', 'T-004'),
            ('dispatched', 'worker-lost', 'T-005'),
            ('agent_lost', 'worker-lost', 'T-005'))]
        (self.state / 'events.jsonl').write_text(''.join(json.dumps(e) + '\n' for e in events))
        with patch('subprocess.run', side_effect=AssertionError('timer started a subprocess')):
            M.refresh(self.p)
            M.deadline(self.p, A.key)
            M.tick(self.p, A.key)
        line = next(iter(self.p.data['wakes'].values()))['line']
        self.assertIn('in-flight rounds: T-003 (worker)', line)
        self.assertNotIn('T-004', line)
        self.assertNotIn('T-005', line)

    def test_cli_record_show_and_no_card(self):
        env = {k:v for k,v in os.environ.items() if not k.startswith('FM_')}
        env.update(HERDR_ENV='0', FIRSTMATE_CI_SESSION='1')
        def cli(*args):
            return subprocess.run(['bash', str(ROOT / 'bin/fm-decide.sh'), '--authorize-merges',
                                   '--repo', str(self.root), *args], env=env, text=True, capture_output=True)
        empty = cli('--show'); self.assertEqual(empty.returncode, 0, empty.stderr)
        self.assertEqual(empty.stdout.strip(), 'none')
        for option in ('--repo', '--project', '--until', '--quote'):
            missing = cli(option)
            self.assertEqual(missing.returncode, 64, missing.stderr)
            self.assertIn(option + ' needs a value', missing.stderr)
        result = cli('--until', '2099-01-01T08:00:00+08:00', '--quote', 'captain words')
        self.assertEqual(result.returncode, 0, result.stderr)
        shown = cli('--show'); self.assertEqual(shown.returncode, 0, shown.stderr)
        self.assertEqual(json.loads(shown.stdout)['quote'], 'captain words')
        self.assertFalse((self.state / 'pending').exists())


if __name__ == '__main__': unittest.main()
