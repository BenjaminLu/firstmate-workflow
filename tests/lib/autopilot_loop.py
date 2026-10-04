"""Fail-first lifecycle tests; executable endpoints return real command shapes."""
import copy
import json
import os
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch

os.environ['HERDR_ENV'] = '0'
sys.dont_write_bytecode = True
ROOT = Path(sys.argv.pop(1))
sys.path.insert(0, str(ROOT / 'bin/lib'))
import fm_autopilot as A

HEAD = 'a' * 40
BASE = 'b' * 40
CHECKS = [dict(id=1, name='ci', head_sha=HEAD, status='completed', conclusion='success')]
PR = dict(number=12, title='T-001: fixture', state='open',
          head=dict(ref='t-001-fixture', sha=HEAD), base=dict(ref='main', sha=BASE),
          mergeable=True, mergeable_state='clean', draft=False)


class LoopTests(unittest.TestCase):
    def setUp(self):
        tmp = tempfile.TemporaryDirectory(); self.addCleanup(tmp.cleanup)
        self.root = Path(tmp.name)
        self.state = self.root / 'state'; self.state.mkdir()
        (self.root / 'tasks').mkdir()
        (self.root / 'tasks/T-001.json').write_text('{"id":"T-001"}')
        self.ctx = dict(engine=str(self.root), state=str(self.state), target=str(self.root),
                        project='alpha', evidence_project='alpha', repository='owner/alpha',
                        base='main', external=False, tasks=str(self.root / 'tasks'))
        self.pilot = A.Pilot(self.ctx)
        self.pilot.api = lambda endpoint: dict(contexts=['ci'], checks=[])
        self.calls = []
        self.pilot.start_job = lambda kind, task, pr, argv, **extra: self.calls.append((kind, task, pr, argv, extra))
        self.pilot.authoritative_head = lambda task, pr: pr['head']['sha']
        self.pilot.command = self.command
        self.pilot.read_head_spec = lambda pr, task: dict(id=task)
        self.pilot.emit = lambda *a, **kw: self.calls.append(('emit', a, kw))
        self.pilot.verdict = lambda task: {}
        self.pilot.busy = lambda task: False

    def command(self, argv, **kwargs):
        self.calls.append(('command', argv))
        if argv[:2] == ['bash', '-c']:
            return A.Pilot.command(self.pilot, argv, **kwargs)
        if argv[0] == 'git': return BASE + '\n'
        if '--allocate' in argv:
            task = argv[argv.index('--task') + 1]
            owner = self.ctx['project'] or 'firstmate-workflow'
            folder = self.state / 'decision-ids' / owner / task.replace('-', '')
            folder.mkdir(parents=True, exist_ok=True)
            (folder / '1.json').write_text('{"kind":"merge"}')
            return 'D-' + owner + '-' + task.replace('-', '') + '-1\n'
        if '--request' in argv:
            card = argv[argv.index('--request') + 1]
            details = json.loads(Path(argv[argv.index('--details') + 1]).read_text())
            if not details: raise RuntimeError('invalid authored details')
            folder = self.state / 'pending'; folder.mkdir(exist_ok=True)
            (folder / (card + '.json')).write_text(json.dumps(dict(id=card, kind='merge', task='T-001',
                project=self.ctx['project'], details=details, head=argv[argv.index('--expected-head') + 1])))
        return ''

    def gate_result(self, code=7, **extra):
        self.pilot.job_completed(dict(kind='gate', task='T-001', pr=PR, base=BASE,
                                     round=1, code=code, output='', **extra))

    def test_worker_head_runs_gates_then_review(self):
        self.pilot.advance(PR, CHECKS, [])
        self.assertEqual(self.calls[-1][0], 'gate', 'a worker head must reach gates')
        self.gate_result()
        self.assertEqual(self.calls[-1][0], 'review', 'exit 7 must launch a review')
        self.assertIn('--round', self.calls[-1][3])
        self.gate_result()
        self.assertEqual(sum(c[0] == 'review' for c in self.calls), 1)

    def test_protocol_precedes_round_three(self):
        (self.state / 'events.jsonl').write_text(''.join(json.dumps(dict(type='review_opened', task='T-001',
            project='alpha')) + '\n' for _ in range(2)))
        self.pilot.advance(PR, CHECKS, [])
        self.assertEqual(self.calls[-1][0], 'protocol')
        self.pilot.job_completed(dict(kind='protocol', task='T-001', pr=PR, base=BASE,
                                     round=3, code=0, output=''))
        self.assertEqual(self.calls[-1][0], 'gate')

    def test_approval_regates_and_cards_only_at_expected_head(self):
        self.pilot.verdict = lambda task: dict(verdict='APPROVE', head=HEAD, signature='bound')
        self.pilot.advance(PR, CHECKS, [])
        self.assertEqual(self.calls[-1][0], 'gate')
        self.details()
        self.gate_result(0)
        request = [c[1] for c in self.calls if c[0] == 'command' and '--request' in c[1]][0]
        self.assertEqual(request[request.index('--expected-head') + 1], HEAD)
        self.assertTrue((self.state / 'pending/D-alpha-T001-1.json').is_file())

    def details(self):
        folder = self.state / 'decision-details'; folder.mkdir(exist_ok=True)
        (folder / 'D-alpha-T001-1.json').write_text('{"en":{"title":"Authored"},"zh-TW":{"title":"決策"}}')

    def test_missing_details_wakes_once_and_reuses_id(self):
        self.gate_result(0); self.gate_result(0)
        self.assertEqual(len(self.pilot.data['wakes']), 1)
        self.assertIn('T-001 ready: merge card details needed', str(self.pilot.data['wakes']))
        self.assertIn('D-alpha-T001-1', str(self.pilot.data['wakes']))
        self.assertEqual(sum(c[0] == 'command' and '--allocate' in c[1] for c in self.calls), 1)
        self.assertFalse((self.state / 'pending').exists())

    def test_stale_head_or_base_never_cards(self):
        self.details()
        self.pilot.authoritative_head = lambda *a: 'c' * 40
        self.gate_result(0)
        self.assertFalse((self.state / 'pending').exists())
        self.pilot.authoritative_head = lambda *a: HEAD
        original = self.pilot.command
        self.pilot.command = lambda argv, **kw: 'c' * 40 if argv[0] == 'git' else original(argv, **kw)
        self.gate_result(0)
        self.assertFalse((self.state / 'pending').exists())

    def test_reject_wakes_once_without_worker_or_review(self):
        self.pilot.verdict = lambda task: dict(verdict='REJECT', head=HEAD, signature='reject')
        self.pilot.advance(PR, CHECKS, []); self.pilot.advance(PR, CHECKS, [])
        self.assertEqual(len(self.pilot.data['wakes']), 1)
        self.assertIn('brief needed', str(self.pilot.data['wakes']))
        self.assertFalse(any(c[0] in ('gate', 'review') for c in self.calls))
        self.assertNotIn('fm-worker', str(self.calls))

    def test_launcher_codes_quote_child_line_once_per_head(self):
        for code in (2, 3, 65, 64):
            with self.subTest(code=code):
                self.pilot.job_completed(dict(kind='review', task='T-001', pr=PR, code=code,
                    output='noise\nno adapter vendor-x; log is at /kept/review.2.log\nlast noise'))
        self.assertEqual(len(self.pilot.data['wakes']), 1)
        self.assertIn('no adapter vendor-x; log is at /kept/review.2.log', str(self.pilot.data['wakes']))

    def test_gate_failure_and_no_verdict_are_judgment(self):
        self.gate_result(5); self.gate_result(5)
        self.assertEqual(len(self.pilot.data['wakes']), 1)
        self.assertIn('gate 5', str(self.pilot.data['wakes']))
        self.pilot.job_completed(dict(kind='review', task='T-001', pr=PR, code=0, output='log is at /kept/a.log'))
        self.assertIn('no verdict', str(self.pilot.data['wakes']))

    def test_restart_replays_no_gate(self):
        self.pilot.advance(PR, CHECKS, [])
        restored = A.Pilot(self.ctx)
        restored.api = self.pilot.api
        restored.start_job = self.pilot.start_job
        restored.verdict = self.pilot.verdict
        restored.command = self.command
        restored.read_head_spec = self.pilot.read_head_spec
        restored.authoritative_head = self.pilot.authoritative_head
        restored.busy = lambda task: False
        restored.advance(PR, CHECKS, [])
        self.assertEqual(sum(c[0] == 'gate' for c in self.calls), 1)

    def test_terminal_and_open_events_are_once_and_keep_task_grammar(self):
        for ref, title, task in [('sk-001-update','other','SK-001'), ('unrelated','T-116: title','T-116'),
                                 ('t1170-old','other','T-1170'), ('revert-5','Revert "T-005: task"','')]:
            pr = copy.deepcopy(PR); pr['number'] += len(self.calls); pr['head']['ref'] = ref; pr['title'] = title
            for state, merged, expected in [('open', None, 'pr_opened'), ('closed', None, 'closed'),
                                             ('closed', 'now', 'merged')]:
                pr.update(state=state, merged_at=merged)
                before = len(self.calls)
                self.pilot.observe_pr(pr); self.pilot.observe_pr(pr)
                emitted = [c for c in self.calls[before:] if c[0] == 'emit']
                self.assertEqual(len(emitted), 1)
                self.assertEqual(emitted[0][1][0:2], (expected, task))
                self.assertEqual(emitted[0][2]['actor'], 'github')

    def test_pending_and_answered_cards_are_not_replaced(self):
        for folder in ('pending', 'decisions'):
            path = self.state / folder; path.mkdir(exist_ok=True)
            card = path / 'D-alpha-T001-8.json'
            card.write_text('{"kind":"merge","task":"T-001","chosen":"B"}')
            self.details(); self.gate_result(0)
            self.assertFalse(any(c[0] == 'command' and '--request' in c[1] for c in self.calls))
            card.unlink()

    def test_lowest_unused_merge_reservation_ignores_choice_and_archived(self):
        folder = self.state / 'decision-ids/alpha/T001'; folder.mkdir(parents=True)
        for n, kind in ((1,'choice'), (2,'merge'), (3,'merge'), (4,'merge')):
            (folder / f'{n}.json').write_text(json.dumps(dict(kind=kind)))
        archived = self.state / 'runtime/archived-pending'; archived.mkdir(parents=True)
        (archived / 'D-alpha-T001-2.json').write_text('{}')
        self.gate_result(0)
        self.assertIn('D-alpha-T001-3', str(self.pilot.data['wakes']))
        self.assertFalse(any(c[0] == 'command' and '--allocate' in c[1] for c in self.calls))

    def test_invalid_details_never_publish_then_valid_details_reuse_id(self):
        self.details()
        path = self.state / 'decision-details/D-alpha-T001-1.json'
        path.write_text('{}')
        with self.assertRaises(RuntimeError): self.gate_result(0)
        self.assertFalse((self.state / 'pending').exists())
        self.details(); self.gate_result(0)
        record = json.loads((self.state / 'pending/D-alpha-T001-1.json').read_text())
        self.assertEqual(record['details']['zh-TW']['title'], '決策')
        self.assertEqual(record['project'], 'alpha')
        self.assertEqual(record['head'], HEAD)

    def test_old_numeric_ids_are_untouched(self):
        for folder in ('pending','decisions','decision-details'):
            path = self.state / folder; path.mkdir(exist_ok=True)
            (path / 'D-001.json').write_text('{"kind":"choice","task":"T-043"}')
        self.gate_result(0)
        self.assertIn('D-alpha-T001-1', str(self.pilot.data['wakes']))
        for folder in ('pending','decisions','decision-details'):
            self.assertEqual((self.state / folder / 'D-001.json').read_text(), '{"kind":"choice","task":"T-043"}')

    def test_ask_at_worker_head_holds_gates_and_wakes_once(self):
        import fm_evidence
        with patch.object(fm_evidence.Store, 'records', return_value=[dict(kind='ask', head=HEAD, time='2099-01-01T00:00:00Z',
                text='SCOPE-BLOCKED:T-001\nNeed another file')]):
            self.pilot.advance(PR, CHECKS, []); self.pilot.advance(PR, CHECKS, [])
        self.assertEqual(len(self.pilot.data['wakes']), 1)
        self.assertIn('SCOPE-BLOCKED:T-001', str(self.pilot.data['wakes']))
        self.assertFalse(any(c[0] == 'gate' for c in self.calls))

    def test_foreign_event_never_advances_or_reserves_id(self):
        self.pilot.event(dict(type='pr_opened', project='beta', task='T-001', pr=12), 'one')
        self.assertEqual(self.pilot.data['pulls'], {})
        self.assertFalse((self.state / 'decision-ids').exists())

    def test_live_round_holds_gates(self):
        import fm_concurrent
        with patch.object(fm_concurrent, 'live_rounds', return_value=[dict(task='T-001')]):
            self.pilot.advance(PR, CHECKS, [])
        self.assertFalse(any(c[0] == 'gate' for c in self.calls))

    def test_ci_completion_and_new_approval_reconsider_head(self):
        self.pilot.advance(PR, [], [])
        self.pilot.advance(PR, [], [])
        self.assertEqual(sum(c[0] == 'gate' for c in self.calls), 0)
        self.pilot.advance(PR, CHECKS, [])
        self.assertEqual(sum(c[0] == 'gate' for c in self.calls), 1)
        self.pilot.verdict = lambda task: dict(verdict='APPROVE', head=HEAD, signature='signed')
        self.pilot.advance(PR, CHECKS, [])
        self.assertEqual(sum(c[0] == 'gate' for c in self.calls), 2)

    def test_pending_ci_never_gates_or_spends_failure_wake(self):
        for status, timestamp in [('queued', 'one'), ('in_progress', 'two'), ('in_progress', 'three')]:
            self.pilot.advance(PR, [dict(CHECKS[0], status=status, conclusion=None,
                                        started_at=timestamp)], [])
        self.assertFalse(any(c[0] == 'gate' for c in self.calls), 'pending CI must not start gates')
        self.assertEqual(self.pilot.data['wakes'], {})
        failed = [dict(CHECKS[0], conclusion='failure')]
        self.pilot.advance(PR, failed, [])
        self.assertEqual(sum(c[0] == 'gate' for c in self.calls), 1)
        self.gate_result(6)
        self.pilot.advance(PR, failed, [])
        self.gate_result(6)
        self.assertEqual(len(self.pilot.data['wakes']), 1)
        self.assertIn('stopped at gate 6', str(self.pilot.data['wakes']))

    def test_only_meaningful_fingerprint_inputs_regate(self):
        self.pilot.advance(PR, CHECKS, [])
        self.pilot.verdict = lambda task: dict(verdict='APPROVE', head='c'*40, signature='unbound')
        for status in ('queued', 'in_progress', 'in_progress', 'completed'):
            runs = [dict(CHECKS[0], completed_at=status, html_url='changed'),
                    dict(id=2, name='optional', head_sha=HEAD, status=status, conclusion='success')]
            self.pilot.advance(PR, runs, [dict(id=4, context='optional', state='pending')])
        self.assertEqual(sum(c[0] == 'gate' for c in self.calls), 1,
                         'timestamps, optional checks and unbound verdicts are not gate triggers')
        self.details()
        self.pilot.advance(PR, CHECKS, [])
        self.assertEqual(sum(c[0] == 'gate' for c in self.calls), 2)
        path = self.state / 'decision-details/D-alpha-T001-1.json'
        path.write_text(json.dumps(json.loads(path.read_text()), indent=4))
        self.pilot.advance(PR, CHECKS, [])
        self.assertEqual(sum(c[0] == 'gate' for c in self.calls), 2)
        import fm_concurrent
        for blocker in ('pending merge D-one', 'running merge D-one', ''):
            with patch.object(fm_concurrent, 'merge_blocker', return_value=blocker):
                self.pilot.advance(PR, CHECKS, [])
        self.assertEqual(sum(c[0] == 'gate' for c in self.calls), 3,
                         'only release of the merge slot regates')

    def test_latest_required_sources_must_all_settle(self):
        for runs, statuses in [
            ([dict(CHECKS[0], head_sha='c'*40)], []),
            (CHECKS + [dict(CHECKS[0], id=2, status='queued', conclusion=None)], []),
            (CHECKS, [dict(id=3, context='ci', state='pending')]),
        ]:
            self.pilot.advance(PR, runs, statuses)
        self.assertFalse(any(c[0] == 'gate' for c in self.calls))
        self.pilot.advance(PR, CHECKS, [dict(id=4, context='ci', state='failure')])
        self.assertEqual(sum(c[0] == 'gate' for c in self.calls), 1)
        self.pilot.advance(PR, CHECKS, [dict(id=4, context='ci', state='failure', updated_at='later')])
        self.assertEqual(sum(c[0] == 'gate' for c in self.calls), 1)

    def test_confirmed_policy_checks_and_analysers_are_required(self):
        self.pilot.policy.update(required_checks=['ci', 'security'], analysers=['lint'])
        self.pilot.advance(PR, CHECKS, [])
        self.assertFalse(any(c[0] == 'gate' for c in self.calls))
        runs = CHECKS + [dict(CHECKS[0], id=2, name='security'), dict(CHECKS[0], id=3, name='lint')]
        self.pilot.advance(PR, runs, [])
        self.assertEqual(sum(c[0] == 'gate' for c in self.calls), 1)
        self.pilot.advance(PR, runs + [dict(CHECKS[0], id=4, name='security')], [])
        self.assertEqual(sum(c[0] == 'gate' for c in self.calls), 2,
                         'a newly concluded required run is fresh evidence')

    def test_external_review_and_handoff_keep_project_conventions(self):
        self.pilot.policy['review'] = 'external'
        self.gate_result(7)
        self.assertFalse(any(c[0] == 'review' for c in self.calls))
        self.assertIn('external review required', str(self.pilot.data['wakes']))
        self.pilot.policy['land'] = 'handoff'
        self.details(); self.gate_result(0)
        self.assertFalse((self.state / 'pending').exists())
        self.assertIn('team handoff needed', str(self.pilot.data['wakes']))

    def test_no_project_event_belongs_only_to_registry_default(self):
        self.pilot.ctx['default_project'] = 'beta'
        self.pilot.event(dict(type='pr_opened', task='T-001', pr=12), 'old')
        self.assertEqual(self.pilot.data['pulls'], {})

    def test_draft_scope_question_is_not_silently_skipped(self):
        import fm_evidence
        pr = copy.deepcopy(PR); pr['draft'] = True
        with patch.object(fm_evidence.Store, 'records', return_value=[dict(kind='ask', head=HEAD, time='2099-01-01T00:00:00Z',
                text='ASK-SCOPE:T-001\nNeed approval')]):
            self.pilot.advance(pr, [], [])
        self.assertIn('ASK-SCOPE:T-001', str(self.pilot.data['wakes']))
        self.assertFalse(any(c[0] == 'gate' for c in self.calls))

    def test_review_zero_without_new_verdict_cannot_reuse_old_approval(self):
        record = dict(verdict='APPROVE', head=HEAD, signature='old')
        self.pilot.verdict = lambda task: record
        self.pilot.job_completed(dict(kind='review', task='T-001', pr=PR, code=0, output='',
                                      verdict_before=A.key(record)))
        self.assertIn('no verdict', str(self.pilot.data['wakes']))
        self.assertFalse((self.state / 'pending').exists())

    def test_new_worker_head_after_reject_enters_gates(self):
        self.pilot.verdict = lambda task: dict(verdict='REJECT', head=HEAD, signature='old')
        self.pilot.advance(PR, CHECKS, [])
        next_pr = copy.deepcopy(PR); next_pr['head']['sha'] = 'c' * 40
        self.pilot.pull(next_pr, [], [], [dict(CHECKS[0], head_sha='c' * 40)], [])
        self.assertEqual(self.calls[-1][0], 'gate')
        self.assertEqual(self.calls[-1][2]['head']['sha'], 'c' * 40)


if __name__ == '__main__': unittest.main()
