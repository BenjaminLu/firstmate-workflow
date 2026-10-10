"""Fail-first lifecycle tests; executable endpoints return real command shapes."""
import copy
import json
import os
import subprocess
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
from autopilot_branch_fixture import BranchFixture, response
HEAD = 'a' * 40
BASE = 'b' * 40
CHECKS = [dict(id=1, name='ci', head_sha=HEAD, status='completed', conclusion='success')]
PR = dict(number=12, title='T-001: fixture', state='open',
          head=dict(ref='t-001-fixture', sha=HEAD), base=dict(ref='main', sha=BASE),
          mergeable=True, mergeable_state='clean', draft=False)
class LoopTests(BranchFixture, unittest.TestCase):
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
        self.pilot.start_job = self.record_job
        self.pilot.authoritative_head = lambda task, pr: pr['head']['sha']
        self.pilot.command = self.command
        self.branch_setup()
        self.pilot.probe = self.probe
        self.pilot.read_head_spec = lambda pr, task: dict(id=task)
        self.pilot.emit = lambda *a, **kw: self.calls.append(('emit', a, kw))
        self.pilot.verdict = lambda task: {}
        self.pilot.busy = lambda task: False
    def record_job(self, kind, task, pr, argv, **extra):
        self.calls.append((kind, task, pr, argv, extra))
        if kind == 'review':
            self.pilot.data.setdefault('jobs', {})[str(len(self.calls))] = dict(
                kind=kind, task=task, number=pr['number'], head=pr['head']['sha'],
                state='running', path=str(self.state / 'review.json'))
    def test_review_job_blocks_every_state_without_waking(self):
        for state in ('running', 'consuming', 'done', 'uncertain'):
            with self.subTest(state=state):
                self.pilot.data['jobs'] = {'review': dict(kind='review', number='12', head=HEAD,
                    task='T-001', state=state, path='')}
                self.gate_result()
                self.assertFalse(self.calls)
                self.assertEqual(self.pilot.data['wakes'], {})
    def test_review_job_at_other_head_does_not_block(self):
        self.pilot.data['jobs'] = {'old': dict(kind='review', number=12, head=BASE,
            state='done', path='')}
        self.gate_result()
        self.assertEqual([c[0] for c in self.calls], ['review'])
    def test_legacy_review_job_matches_packet_and_missing_packet_does_not(self):
        path = self.state / 'legacy.json'
        path.write_text(json.dumps(dict(kind='review', pr=dict(PR, number='12'))))
        job = dict(task='T-001', state='done', path=str(path))
        self.pilot.data['jobs'] = {'legacy': job}
        self.gate_result()
        self.assertFalse(self.calls)
        self.assertEqual(self.pilot.data['wakes'], {})
        path.unlink()
        self.gate_result()
        self.assertEqual([c[0] for c in self.calls], ['review'])
    def test_same_head_stale_verdict_still_launches_review(self):
        self.pilot.verdict = lambda task: dict(verdict='APPROVE', head=HEAD, signature='stale')
        self.gate_result()
        self.assertEqual([c[0] for c in self.calls], ['review'])
    def test_review_launch_failure_is_held_and_wakes_once(self):
        for error_type in (RuntimeError, ValueError, OSError, subprocess.SubprocessError):
            for stage in ('before', 'after', 'verdict'):
                with self.subTest(error=error_type, stage=stage):
                    self.pilot.data['jobs'] = {}; self.pilot.data['wakes'] = {}; self.calls.clear()
                    def fail(*args, **kwargs):
                        if stage == 'after': self.record_job(*args, **kwargs)
                        raise error_type('launch failed')
                    with patch.object(self.pilot, 'verdict' if stage == 'verdict' else 'start_job', side_effect=fail) as launch:
                        self.gate_result()
                        self.gate_result()
                        self.assertEqual(launch.call_count, 1)
                    jobs = self.pilot.data['jobs']
                    self.assertEqual(len(jobs), 1)
                    job = next(iter(jobs.values()))
                    self.assertEqual(job['state'], 'uncertain')
                    self.assertEqual((job['kind'], job['number'], job['head']), ('review', 12, HEAD))
                    if stage != 'after':
                        self.assertEqual(jobs[A.key(['review-launch', 12, HEAD])]['path'], '')
                    wake_id = 'autopilot-' + A.key(['alpha', 'review-launch-12-' + HEAD])
                    self.assertEqual(set(self.pilot.data['wakes']), {wake_id})
                    wake = self.pilot.data['wakes'][wake_id]
                    self.assertEqual(wake['task'], 'T-001')
                    self.assertEqual(wake['summary'], {
                        'en': 'Review launch failed at ' + HEAD[:12] + ': launch failed; launch it by hand or fix the cause',
                        'zh-TW': '審查啟動失敗：launch failed；請手動啟動或排除原因'})
                    before = copy.deepcopy(self.pilot.data)
                    self.pilot.consume_jobs(); self.pilot.recover_jobs()
                    self.assertEqual(self.pilot.data, before)
    def test_failed_review_launch_leaves_calling_gate_done(self):
        path = self.state / 'gate.json'
        path.with_suffix('.result.json').write_text(json.dumps(dict(kind='gate', task='T-001',
            pr=PR, code=6, round=1, base=BASE)))
        self.pilot.data['jobs'] = {'gate': dict(kind='gate', task='T-001', number=12,
            head=HEAD, state='running', path=str(path))}
        with patch.object(self.pilot, 'start_job', side_effect=OSError('cannot start')):
            self.pilot.consume_jobs()
        self.assertEqual(self.pilot.data['jobs']['gate']['state'], 'done')
        self.assertEqual(self.pilot.data['jobs'][A.key(['review-launch', 12, HEAD])]['state'], 'uncertain')
        self.assertEqual(len(self.pilot.data['wakes']), 1)
    def test_review_launch_error_preserves_existing_receipt(self):
        def start(*args, **kwargs):
            self.record_job(*args, **kwargs)
            (self.state / 'review.result.json').write_text('{}')
            raise OSError('after receipt')
        self.pilot.start_job = start
        self.gate_result(); self.gate_result()
        self.assertEqual(len(self.calls), 1)
        self.assertEqual(next(iter(self.pilot.data['jobs'].values()))['state'], 'running')
        self.assertEqual(len(self.pilot.data['wakes']), 1)
    def test_job_lookup_uses_metadata_without_reading_packet(self):
        job = dict(kind='review', number='12', head=HEAD, state='uncertain', path='')
        self.pilot.data['jobs'] = {'job': job}
        with patch('fm_autopilot_loop.read_json', side_effect=AssertionError('packet read')):
            self.assertIs(self.pilot.job_for('review', 12, HEAD), job)
            self.assertIsNone(self.pilot.job_for('gate', 12, HEAD))
            self.assertIsNone(self.pilot.job_for('review', 13, HEAD))
    def test_legacy_unreadable_packet_does_not_match(self):
        path = self.state / 'invalid.json'; path.write_text('{broken')
        self.pilot.data['jobs'] = {'legacy': dict(state='done', path=str(path))}
        self.gate_result()
        self.assertEqual([c[0] for c in self.calls], ['review'])
    def probe(self, argv, *, env=None):
        self.calls.append(('probe', argv))
        return self.branch_probe(argv, env=env)
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
    def gate_result(self, code=6, **extra):
        self.pilot.job_completed(dict(kind='gate', task='T-001', pr=PR, base=BASE,
                                     round=1, code=code, output='', **extra))
    def test_worker_head_runs_gates_then_review(self):
        self.pilot.advance(PR, CHECKS, [])
        self.assertEqual(self.calls[-1][0], 'gate', 'a worker head must reach gates')
        self.gate_result()
        self.assertEqual(self.calls[-1][0], 'review', 'exit 6 must launch a review')
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
        self.pilot.verdict = lambda task: dict(kind='verdict', verdict='REJECT', head=HEAD, signature='reject', round=1, actor='reviewer-ada-t001-r1', text='1. open a\nCRITERIA-COMPLETE:T-001\nREJECT:T-001', provenance=dict(level='legacy'))
        self.pilot.advance(PR, CHECKS, []); self.pilot.advance(PR, CHECKS, [])  # a legacy REJECT: the stubbed protocol check passes, no draft
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
        self.gate_result(4); self.gate_result(4)
        self.assertEqual(len(self.pilot.data['wakes']), 1)
        self.assertIn('gate 4 (fail-first)', str(self.pilot.data['wakes']))
        self.pilot.job_completed(dict(kind='review', task='T-001', pr=PR, code=0, output='log is at /kept/a.log'))
        self.assertIn('no verdict', str(self.pilot.data['wakes']))
    def test_restart_replays_no_gate(self):
        self.pilot.advance(PR, CHECKS, [])
        restored = A.Pilot(self.ctx)
        restored.probe = self.probe
        restored.api = self.pilot.api
        restored.start_job = self.pilot.start_job
        restored.verdict = self.pilot.verdict
        restored.command = self.command
        restored.read_head_spec = self.pilot.read_head_spec
        restored.authoritative_head = self.pilot.authoritative_head
        restored.busy = lambda task: False
        restored.advance(PR, CHECKS, [])
        self.assertEqual(sum(c[0] == 'gate' for c in self.calls), 1)
        self.assertNotIn('actions', restored.data)
        self.assertEqual(restored.data['advanced']['12']['head'], HEAD)
    def test_terminal_and_open_events_are_once_and_keep_task_grammar(self):
        def emit(kind, task, en, tw, pr=None, actor='autopilot'):
            self.calls.append(('emit', (kind, task, en, tw, pr), dict(actor=actor)))
            with (self.state / 'events.jsonl').open('a') as log:
                log.write(json.dumps(dict(type=kind, task=task, pr=pr, actor=actor)) + '\n')
        self.pilot.emit = emit
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
    def test_existing_event_does_not_emit_again(self):
        row = dict(type='pr_opened', pr=12, task='T-001')
        (self.state / 'events.jsonl').write_text(json.dumps(row) + '\n')
        self.pilot.observe_pr(PR)
        self.assertEqual(self.calls, [])
        self.assertNotIn('actions', self.pilot.data)
    def test_existing_event_clears_retry_without_emit(self):
        row = dict(type='pr_opened', pr=12, task='T-001')
        (self.state / 'events.jsonl').write_text(json.dumps(row) + '\n')
        token = 'event-pr_opened:12:' + HEAD
        self.pilot.data['retries'][token] = dict(count=1, due_seq=100)
        self.pilot.observe_pr(PR)
        self.assertEqual(self.calls, [])
        self.assertNotIn(token, self.pilot.data['retries'])
    def test_successful_event_updates_poll_snapshot(self):
        self.pilot._poll_rows = []
        self.pilot.observe_pr(PR); self.pilot.observe_pr(PR)
        self.assertEqual(sum(c[0] == 'emit' for c in self.calls), 1)
        self.assertEqual(self.pilot._poll_rows, [dict(type='pr_opened', pr=12, task='T-001')])
        self.assertNotIn('actions', self.pilot.data)
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
        self.gate_result(5)
        self.pilot.advance(PR, failed, [])
        self.gate_result(5)
        self.assertEqual(len(self.pilot.data['wakes']), 1)
        self.assertIn('stopped at gate 5 (ci)', str(self.pilot.data['wakes']))
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
        self.gate_result(6)
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
        self.pull_at(next_pr, [], [], [dict(CHECKS[0], head_sha='c' * 40)], [])
        self.assertEqual(self.calls[-1][0], 'gate')
        self.assertEqual(self.calls[-1][2]['head']['sha'], 'c' * 40)
    def lagging(self):
        self.branch = PR['head']['ref']
        self.local_refs[self.branch] = 'd' * 40
        self.fetch_head = HEAD
        self.worktree = str(self.root / 'task worktree')
    def sync_poll(self, pr=PR):
        self.pilot.data['poll_seq'] = self.pilot.data.get('poll_seq', 0) + 1
        self.pilot.pull(pr, [], [], [dict(CHECKS[0], head_sha=pr['head']['sha'])], [])

    def gates(self):
        return [c for c in self.calls if c[0] == 'gate']

    def git_calls(self, operation):
        return [c[1] for c in self.calls if c[0] == 'probe' and operation in c[1]]

    def test_clean_ancestor_fast_forwards_and_gates_same_poll(self):
        self.lagging(); self.sync_poll()
        self.assertEqual(self.local_refs[self.branch], HEAD)
        self.assertEqual(self.git_calls('merge')[0][-3:], ['merge', '--ff-only', HEAD])
        self.assertEqual(len(self.gates()), 1)

    def test_missing_ref_creates_and_gates(self):
        self.lagging(); self.local_refs.clear(); self.sync_poll()
        self.assertIn(['git', '-C', str(self.root), 'update-ref',
                       'refs/heads/' + self.branch, HEAD, ''], self.git_calls('update-ref'))
        self.assertEqual(len(self.gates()), 1)

    def test_dirty_worktree_holds_then_wakes_once(self):
        self.lagging(); self.dirty = True
        for count in range(1, 6):
            self.sync_poll()
            self.assertEqual(len(self.pilot.data['wakes']), int(count >= 3))
        self.assertEqual(self.gates(), [])
        self.assertNotIn('actions', self.pilot.data)
        self.assertIn(self.worktree, str(self.pilot.data['wakes']))
        self.assertEqual(self.local_refs[self.branch], 'd' * 40)

    def test_live_round_dirty_hold_is_silent_then_gates(self):
        self.assert_live_hold(True)

    def test_live_round_clean_hold_is_silent_then_gates(self):
        self.assert_live_hold(False)

    def assert_live_hold(self, dirty):
        self.lagging(); self.dirty = dirty
        with patch('fm_concurrent.live_rounds', return_value=[dict(task='T-001')]):
            for _ in range(5): self.sync_poll(dict(PR, mergeable_state='behind'))
        self.assertEqual(self.pilot.data['holds'], {})
        self.assertEqual(self.pilot.data['wakes'], {})
        self.assertEqual(self.gates(), [])
        self.assertEqual(self.git_calls('PUT'), [])
        self.dirty = False; self.sync_poll()
        self.assertEqual(len(self.gates()), 1)
        self.assertEqual(self.local_refs[self.branch], HEAD)

    def test_busy_job_after_202_holds_dirty_ref_silently(self):
        self.assert_busy_hold(True)

    def test_busy_job_after_202_holds_clean_ref_silently(self):
        self.assert_busy_hold(False)

    def assert_busy_hold(self, dirty):
        self.pull_at(dict(PR, mergeable_state='behind'), runs=CHECKS)
        self.assertEqual(len(self.git_calls('PUT')), 1)
        pr = copy.deepcopy(PR); pr['head']['sha'] = 'c' * 40
        pr['mergeable_state'] = 'behind'
        self.branch = pr['head']['ref']; self.fetch_head = pr['head']['sha']
        self.worktree = str(self.root / 'task'); self.dirty = dirty
        self.pilot.busy = lambda task: True
        for _ in range(5): self.sync_poll(pr)
        self.assertEqual(self.pilot.data['holds'], {})
        self.assertEqual(self.pilot.data['wakes'], {})
        self.assertEqual(len(self.git_calls('PUT')), 1)
        self.assertEqual(len(self.gates()), 1)
        self.pilot.busy = lambda task: False; self.dirty = False
        self.sync_poll(pr)
        self.assertEqual(self.local_refs[self.branch], 'c' * 40)
        self.assertEqual(len(self.gates()), 2)

    def test_equal_ref_clears_exhausted_sync_and_hold_then_advances(self):
        self.lagging()
        key = 'sync:12:' + HEAD
        self.pilot.data['retries'][key] = dict(count=3, due_seq=99)
        self.pilot.data['holds']['12'] = dict(head=HEAD, count=2)
        self.local_refs[self.branch] = HEAD
        self.sync_poll()
        self.assertNotIn(key, self.pilot.data['retries'])
        self.assertEqual(self.pilot.data['holds'], {})
        self.assertEqual(self.git_calls('fetch'), [])
        self.assertEqual(len(self.gates()), 1)

    def test_sync_not_due_skips_advance_without_fetch(self):
        self.lagging()
        self.pilot.data['retries']['sync:12:' + HEAD] = dict(count=1, due_seq=3)
        self.sync_poll()
        self.assertEqual(self.gates(), [])
        self.assertEqual(self.git_calls('fetch'), [])
        self.assertEqual(self.pilot.data['wakes'], {})
        self.sync_poll(); self.sync_poll()
        self.assertEqual(len(self.gates()), 1)

    def test_merge_base_error_retries_then_wakes_with_last_stderr(self):
        self.lagging(); self.ancestor = 128
        for attempts in (1, 2, 2, 3, 3):
            self.sync_poll()
            self.assertEqual(len(self.git_calls('merge-base')), attempts)
        self.assertEqual(self.gates(), [])
        self.assertEqual(len(self.pilot.data['wakes']), 1)
        self.assertIn('fatal: Not a valid commit name', str(self.pilot.data['wakes']))
        self.assertNotIn('actions', self.pilot.data)

    def test_sync_errors_use_last_nonempty_stderr_and_keep_private_cleanup(self):
        self.lagging()
        self.git_error = ('fetch', 128, '', 'first line\nfatal: final error\n\n')
        for _ in range(4): self.sync_poll()
        line = next(iter(self.pilot.data['wakes'].values()))['line']
        self.assertIn('fatal: final error', line)
        self.assertNotIn('first line', line)
        self.assertEqual(len(self.git_calls('update-ref')), 3)
        self.assertEqual(self.gates(), [])

    def test_nonancestor_retries_stale_binding_then_wakes(self):
        self.lagging(); self.ancestor = 1
        def stale(*args):
            raise ValueError('authoritative PR head differs from fetched head or local task ref; refresh before accepting')
        self.pilot.authoritative_head = stale
        for count in (1, 2, 2, 3, 3):
            self.sync_poll()
            self.assertEqual(self.pilot.data['retries']['advance:12:' + HEAD]['count'], count)
        self.assertEqual(self.local_refs[self.branch], 'd' * 40)
        self.assertEqual(self.gates(), [])
        self.assertNotIn('actions', self.pilot.data)
        self.assertEqual(len(self.pilot.data['wakes']), 1)
        self.assertIn('authoritative PR head differs', str(self.pilot.data['wakes']))

    def test_moved_during_fetch_never_moves_or_creates(self):
        for missing in (False, True):
            with self.subTest(missing=missing):
                self.lagging()
                if missing: self.local_refs.clear()
                before = dict(self.local_refs)
                self.fetch_head = 'c' * 40
                self.sync_poll()
                self.assertEqual(self.local_refs, before)
        self.assertEqual(self.gates(), [])
        self.assertEqual(self.pilot.data['retries'], {})
        self.assertEqual(self.pilot.data['wakes'], {})
        self.assertEqual(self.git_calls('merge'), [])
        self.assertTrue(all('-d' in c for c in self.git_calls('update-ref')))

    def test_no_worktree_uses_compare_and_swap_and_mismatch_retries(self):
        self.lagging(); self.worktree = None
        # Limit the failure to the public-ref CAS, leaving private cleanup intact.
        original = self.pilot.probe
        def racing(argv, *, env=None):
            if argv[3] == 'update-ref' and argv[4].startswith('refs/heads/'):
                self.calls.append(('probe', argv))
                return 1, '', 'fatal: ref changed'
            return original(argv, **({} if env is None else {"env": env}))
        self.pilot.probe = racing
        self.sync_poll()
        expected = ['git', '-C', str(self.root), 'update-ref',
                    'refs/heads/' + self.branch, HEAD, 'd' * 40]
        self.assertIn(expected, self.git_calls('update-ref'))
        self.assertEqual(self.pilot.data['retries']['sync:12:' + HEAD]['count'], 1)
        self.assertEqual(self.gates(), [])
        self.pilot.probe = original; self.sync_poll()
        self.assertEqual(self.local_refs[self.branch], HEAD)
        self.assertEqual(len(self.gates()), 1)

    def test_parked_advance_migrates_and_equal_ref_gates_once(self):
        self.pilot.data.setdefault('actions', {})['old'] = dict(state='uncertain',
            identity=['advance', 'opaque-fingerprint'], task='T-001')
        self.pilot.data.pop('migrated_t205', None); self.pilot.save()
        restored = A.Pilot(self.ctx)
        self.assertNotIn('actions', restored.data)
        self.pilot.data = restored.data
        self.local_refs[PR['head']['ref']] = HEAD
        self.sync_poll(); self.sync_poll()
        self.assertEqual(len(self.gates()), 1)
        self.assertNotIn('actions', self.pilot.data)
        self.assertEqual(self.pilot.data['wakes'], {})

    def test_each_sync_command_error_defers_advance_and_retries(self):
        for operation in ('rev-parse', 'worktree', 'status', 'merge'):
            with self.subTest(operation=operation):
                self.pilot.data['retries'].clear()
                self.lagging()
                self.git_error = (operation, 128, '', 'noise\nfatal: ' + operation + ' failed\n')
                self.sync_poll()
                self.assertEqual(self.pilot.data['retries']['sync:12:' + HEAD]['count'], 1)
                self.assertEqual(self.gates(), [])
                self.assertEqual(self.pilot.data['wakes'], {})
                self.assertNotIn('actions', self.pilot.data)

    def test_exhausted_sync_checks_equal_ref_but_makes_no_more_attempts(self):
        self.lagging()
        self.pilot.data['retries']['sync:12:' + HEAD] = dict(count=3, due_seq=0)
        for _ in range(5): self.sync_poll()
        self.assertEqual(len(self.git_calls('--verify')), 5)
        self.assertEqual(self.git_calls('fetch'), [])
        self.assertEqual(self.gates(), [])
        self.assertEqual(self.pilot.data['wakes'], {})


    def test_advance_marks_only_after_launch_and_dedupes_without_ledger(self):
        launch = self.pilot.start_job
        def start(*args, **kwargs):
            self.assertEqual(self.pilot.data['advanced'], {})
            launch(*args, **kwargs)
        self.pilot.start_job = start
        self.pilot.advance(PR, CHECKS, [])
        self.pilot.advance(PR, CHECKS, [])
        self.assertEqual(len(self.gates()), 1)
        self.assertNotIn('actions', self.pilot.data)
        self.assertEqual(self.pilot.data['advanced']['12']['head'], HEAD)

    def test_authoritative_head_race_is_silent_and_next_observation_gates(self):
        self.pilot.authoritative_head = lambda *a: 'c' * 40
        self.pilot.advance(PR, CHECKS, [])
        self.assertEqual(self.gates(), [])
        self.assertNotIn('actions', self.pilot.data)
        for name in ('advanced', 'retries', 'wakes'):
            self.assertEqual(self.pilot.data[name], {})
        pr = copy.deepcopy(PR); pr['head']['sha'] = 'c' * 40
        self.pilot.advance(pr, [dict(CHECKS[0], head_sha='c' * 40)], [])
        self.assertEqual(len(self.gates()), 1)

    def test_gate_step_exceptions_retry_at_zero_one_three(self):
        self.local_refs[PR['head']['ref']] = HEAD
        for method in ('authoritative_head', 'base_tip', 'start_job'):
            with self.subTest(method=method):
                self.pilot.data['retries'].clear(); self.pilot.data['wakes'].clear()
                with patch.object(self.pilot, method, side_effect=RuntimeError(method + ' failed')) as fail:
                    for seq, count in enumerate((1, 2, 2, 3, 3)):
                        self.pilot.data['poll_seq'] = seq
                        self.pilot.pull(PR, [], [], CHECKS, [])
                        record = self.pilot.data['retries']['advance:12:' + HEAD]
                        self.assertEqual(record['count'], count)
                        self.assertEqual(fail.call_count, count)
                        self.assertEqual(len(self.pilot.data['wakes']), int(count == 3))
                self.assertIn(method + ' failed', str(self.pilot.data['wakes']))
                self.assertNotIn('advancement needs reconciliation', str(self.pilot.data['wakes']))
                self.assertEqual(self.pilot.data['advanced'], {})
                self.assertNotIn('actions', self.pilot.data)
        self.assertEqual(self.gates(), [])

    def test_success_clears_advance_retry(self):
        with patch.object(self.pilot, 'base_tip', side_effect=OSError('base unavailable')):
            self.pilot.advance(PR, CHECKS, [])
        self.pilot.data['poll_seq'] += 1
        self.pilot.advance(PR, CHECKS, [])
        self.assertEqual(len(self.gates()), 1)
        self.assertEqual(self.pilot.data['retries'], {})

    def test_fingerprint_resets_count_and_wake_after_exhaustion(self):
        variants = []
        with patch.object(self.pilot, 'authoritative_head', side_effect=ValueError('binding refused')):
            for series, conclusion in enumerate(('success', 'failure')):
                for offset, count in enumerate((1, 2, 2, 3, 3)):
                    self.pilot.data['poll_seq'] = series * 5 + offset
                    self.pilot.advance(PR, [dict(CHECKS[0], conclusion=conclusion)], [])
                    record = self.pilot.data['retries']['advance:12:' + HEAD]
                    self.assertEqual(record['count'], count)
                    self.assertEqual(len(self.pilot.data['wakes']), series + int(count == 3))
                variants.append(record['variant'])
        self.assertNotEqual(*variants)
        for variant in variants:
            ident = 'autopilot-' + A.key(['alpha', f'advance-12-{HEAD}-{variant}'])
            self.assertIn(ident, self.pilot.data['wakes'])
        self.assertNotIn('actions', self.pilot.data)

    def test_fingerprint_change_while_counting_is_due_immediately(self):
        with patch.object(self.pilot, 'base_tip', side_effect=ValueError('base refused')):
            self.pilot.advance(PR, CHECKS, [])
            old = dict(self.pilot.data['retries']['advance:12:' + HEAD])
            self.pilot.advance(PR, [dict(CHECKS[0], conclusion='failure')], [])
            new = self.pilot.data['retries']['advance:12:' + HEAD]
        self.assertEqual(new['count'], 1)
        self.assertNotEqual(old['variant'], new['variant'])

    def test_advance_records_and_retries_prune_on_new_head_and_terminal(self):
        self.pilot.advance(PR, CHECKS, [])
        token = 'advance:12:' + HEAD
        self.pilot.data['retries'][token] = dict(count=2, due_seq=3)
        self.pilot.prune_branches('12', 'c' * 40)
        self.assertEqual(self.pilot.data['advanced'], {})
        self.assertNotIn(token, self.pilot.data['retries'])
        pr = copy.deepcopy(PR); pr['head']['sha'] = 'c' * 40
        for _ in range(2): self.pilot.advance(pr, [dict(CHECKS[0], head_sha='c' * 40)], [])
        self.assertEqual(len(self.gates()), 2)
        self.pilot.prune_branches('12')
        self.assertEqual(self.pilot.data['advanced'], {})

    # T-269 fixtures retain real signed historical authority; only remote/source
    # reads are synthetic. Stock candidate validation remains the request boundary.
    def failed_history(self, external=False):
        from fm_evidence import Store
        subprocess.run(['git', 'init', '-q', str(self.root)], check=True, capture_output=True)
        if external:
            self.ctx['external'] = True
            private_home = tempfile.TemporaryDirectory(); self.addCleanup(private_home.cleanup)
            self.state = Path(private_home.name) / 'projects/alpha/state'
            self.state.mkdir(parents=True)
            self.ctx['state'] = str(self.state)
            old_pilot = self.pilot
            self.pilot = A.Pilot(self.ctx)
            for name in ('api', 'authoritative_head', 'command', 'start_job', 'probe',
                         'read_head_spec', 'emit', 'verdict', 'busy'):
                setattr(self.pilot, name, getattr(old_pilot, name))
        self.old_id = 'D-alpha-T001-1'
        self.sentinel = '/private/SECRET-T269-never-project-this'
        self.store = Store(str(self.state), 'alpha', 'T-001', external=external)
        self.old_ready = self.store.append('readiness', 1, 'firstmate', 'd' * 40,
            self.sentinel, pr=12, repository='owner/alpha', gates=[1, 2, 3, 4, 5, 6])
        self.old = dict(id=self.old_id, identity='decision:' + self.old_id,
            project='alpha', task='T-001', pr=12, kind='merge', chosen='A',
            merge='failed', merge_reason=self.sentinel, expected_head='d' * 40,
            merge_settled='2026-01-01T00:00:00Z', binding=self.old_ready)
        self.old_path = self.state / 'decisions' / (self.old_id + '.json')
        self.old_path.parent.mkdir(); self.old_path.write_text(json.dumps(self.old))
        self.event = dict(type='decision_made', actor='captain', project='alpha', task='T-001',
            ts='2026-01-01T00:00:01Z', data=dict(decision=self.old_id, chosen='A',
            merge='failed', outcome='failed', expected_head='d' * 40, reason=self.sentinel))
        self.events = self.state / 'events.jsonl'
        initial = dict(self.event, ts='2026-01-01T00:00:00Z',
            data=dict(decision=self.old_id, chosen='A', effect='merge', outcome='running'))
        self.events.write_text(json.dumps(initial) + '\n' + json.dumps(self.event) + '\n')
        reservation = self.state / 'decision-ids/alpha/T001'; reservation.mkdir(parents=True)
        (reservation / '1.json').write_text('{"kind":"merge"}')
        self.source = dict(spec_sha256='spec', contract_sha256='contract',
                           conventions_sha256='conventions', patch='patch', files=['owned'])
        self.review = self.store.append('verdict', 2, 'reviewer', HEAD, 'APPROVE:T-001',
            verdict='APPROVE', provenance=dict(level='legacy'), binding=self.source, base=BASE)
        self.selected_signature = self.review['signature']
        self.current_ready()
        self.requests = []
        original = self.pilot.command
        def stock(argv, **kwargs):
            if '--allocate' in argv:
                self.calls.append(('command', argv))
                numbers = [int(p.stem) for p in reservation.glob('*.json')]
                n = max(numbers, default=0) + 1
                (reservation / (str(n) + '.json')).write_text('{"kind":"merge"}')
                return 'D-alpha-T001-' + str(n)
            if '--request' not in argv: return original(argv, **kwargs)
            self.requests.append(argv)
            self.candidate_mutation()
            import contextlib, io, fm_binding as binding
            env = dict(FM_STATE_DIR=str(self.state), FM_EVIDENCE_PROJECT='alpha',
                       FM_EXTERNAL='1' if external else '0', FM_TARGET_ROOT=str(self.root))
            args = ['fm_binding', 'candidate', '--task', 'T-001', '--pr', '12', '--head', HEAD]
            output = io.StringIO()
            # Exercise unchanged stock candidate against actual signed Store.
            with patch.dict(os.environ, env), patch.object(sys, 'argv', args), \
                 patch('fm_adopt.adoption', return_value=None), \
                 patch.object(binding, 'repository', return_value='owner/alpha'), \
                 patch.object(binding, 'remote_head', return_value=self.remote), \
                 patch.object(binding, 'required_checks', return_value=self.current_checks), \
                 patch.object(binding, 'selected_review', return_value=(self.review, None)), \
                 patch.object(binding, 'source_binding', return_value=self.source), \
                 patch.object(binding, 'view_base', return_value='main'), \
                 patch.object(binding, 'verified_base', return_value='main'), \
                 patch.object(binding, 'git', side_effect=lambda root, *a: self.current_base), \
                 contextlib.redirect_stdout(output):
                binding.main()
            selected = json.loads(output.getvalue())
            ident = argv[argv.index('--request') + 1]
            details = json.loads(Path(argv[argv.index('--details') + 1]).read_text())
            if not details: raise ValueError('invalid details')
            folder = self.state / 'pending'; folder.mkdir(exist_ok=True)
            (folder / (ident + '.json')).write_text(json.dumps(dict(id=ident, kind='merge',
                task='T-001', project='alpha', pr=12, expected_head=HEAD, binding=selected)))
            return ''
        self.pilot.command = stock
        self.candidate_mutation = lambda: None
        self.remote = dict(headRefOid=HEAD, baseRefOid=BASE, state='OPEN')
        self.current_checks = ['ci-success']; self.current_base = BASE
        self.replacement_details()
        self.old_bytes = self.old_path.read_bytes(); self.event_bytes = self.events.read_bytes()
        self.counter_bytes = (reservation / '1.json').read_bytes()

    def current_ready(self):
        from fm_binding import gate_list
        self.ready = self.store.append('readiness', 2, 'firstmate', HEAD, '',
            pr=12, repository='owner/alpha', gates=[g['name'] for g in gate_list()['gates']],
            checks=['ci-success'], verdict_signature=self.selected_signature, review=self.review, gate_base=BASE)

    def replacement_details(self):
        folder = self.state / 'decision-details'; folder.mkdir(exist_ok=True)
        locale = dict(title='Authored', explanation=self.sentinel, before='Held', after='Ready',
            outcome='Captain decides', options={c: dict(description='Choose', pros='Clear', cons='Wait')
                                                for c in 'ABC'})
        (folder / 'D-alpha-T001-2.json').write_text(json.dumps({'en': locale, 'zh-TW': locale}))

    def assert_history_preserved(self):
        self.assertEqual(self.old_path.read_bytes(), self.old_bytes)
        self.assertEqual(self.events.read_bytes(), self.event_bytes)
        self.assertEqual((self.state / 'decision-ids/alpha/T001/1.json').read_bytes(), self.counter_bytes)
        self.assertFalse(any('merge' in c[1] for c in self.calls if c[0] == 'command' and c[1][0] == 'gh'))

    def complete_gate_receipt(self):
        path = self.state / 'fresh-gate.json'
        path.with_suffix('.result.json').write_text(json.dumps(dict(kind='gate', task='T-001',
            pr=PR, code=0, base=BASE, round=2)))
        self.pilot.data.setdefault('jobs', {})['fresh'] = dict(kind='gate', task='T-001', number=12,
            head=HEAD, state='running', path=str(path))
        self.pilot.consume_jobs()

    def test_failed_card_fresh_gate_publishes_new_unanswered_card(self):
        self.failed_history()
        pending = self.state / 'pending'; pending.mkdir()
        dispatch = pending / 'D-alpha-T001-99.json'
        dispatch.write_text(json.dumps(dict(task='T-001', purpose='dispatch')))
        original_dispatch = dispatch.read_bytes()
        self.complete_gate_receipt()
        self.assertEqual(dispatch.read_bytes(), original_dispatch)
        path = self.state / 'pending/D-alpha-T001-2.json'
        self.assertTrue(path.exists(), 'fresh successful gates must create a NEW H1 pending card')
        card = json.loads(path.read_text())
        self.assertNotIn('chosen', card)
        self.assertEqual(card['expected_head'], HEAD)
        self.assertEqual(card['binding']['signature'], self.ready['signature'])
        self.assertEqual(self.requests[0][self.requests[0].index('--expected-head') + 1], HEAD)
        self.pilot.consume_jobs(); self.gate_result(0)
        self.assertEqual(len(self.requests), 1)
        self.assert_history_preserved()

    def test_fractional_settlement_with_whole_second_event_publishes(self):
        self.failed_history()
        self.old['merge_settled'] = '2026-01-01T00:00:00.500Z'
        self.old_path.write_text(json.dumps(self.old)); self.old_bytes = self.old_path.read_bytes()
        self.event['ts'] = '2026-01-01T00:00:00Z'
        self.events.write_text(json.dumps(self.event) + '\n'); self.event_bytes = self.events.read_bytes()
        self.complete_gate_receipt()
        self.assertTrue((self.state / 'pending/D-alpha-T001-2.json').exists(),
                        'same-second truncated event must permit fractional settlement')
        self.assertEqual(len(self.requests), 1); self.assert_history_preserved()
    def test_settlement_precision_conflicts_hold_before_request(self):
        self.failed_history()
        self.old['merge_settled'] = '2026-01-01T00:00:00.500Z'
        self.old_path.write_text(json.dumps(self.old)); self.old_bytes = self.old_path.read_bytes()
        variants = [dict(ts='2025-12-31T23:59:59Z'), dict(ts='2026-01-01T00:00:00.499Z'),
            dict(ts='malformed'), dict(ts='2026-01-01T00:00:00'),
            dict(task='T-002'), dict(project='beta'), dict(actor='worker'),
            dict(data=dict(self.event['data'], outcome='merged'))]
        for change in variants:
            with self.subTest(change=change):
                row = dict(self.event, ts='2026-01-01T00:00:00Z'); row.update(change)
                self.events.write_text(json.dumps(row) + '\n'); self.event_bytes = self.events.read_bytes()
                self.complete_gate_receipt(); self.assertEqual(self.requests, [])
                self.assertFalse((self.state / 'pending').exists()); self.assert_history_preserved()
    def test_nonmerge_shortcuts_reject_contradictory_history(self):
        self.failed_history()
        extra = self.state / 'decisions/D-alpha-T001-3.json'; original_events = self.event_bytes
        for form in (dict(kind='choice'), dict(purpose='dispatch')):
            for evidence in (dict(purpose='merge', chosen='B'), dict(merge='failed'),
                             dict(merge_settled=self.old['merge_settled']), dict(binding=self.old_ready),
                             dict(effect='merge'), dict(event=True)):
                with self.subTest(form=form, evidence=evidence):
                    record = dict(id=extra.stem, task='T-001', project='alpha', pr=12, **form)
                    event_only = evidence.get('event'); record.update({k:v for k,v in evidence.items() if k != 'event'})
                    extra.write_text(json.dumps(record)); before = extra.read_bytes()
                    self.events.write_bytes(original_events)
                    if event_only:
                        with self.events.open('a') as stream:
                            stream.write(json.dumps(dict(self.event, data=dict(self.event['data'], decision=extra.stem))) + '\n')
                    baseline = self.events.read_bytes(); self.event_bytes = baseline
                    self.complete_gate_receipt(); self.assertEqual(self.requests, [])
                    self.assertFalse((self.state / 'pending').exists()); self.assertEqual(extra.read_bytes(), before)
                    self.assert_history_preserved()
            extra.unlink(); self.events.write_bytes(original_events); self.event_bytes = original_events
        for form in (dict(kind='choice'), dict(purpose='dispatch')):
            record = dict(self.old, expected_head=HEAD, **form)
            if 'kind' not in form: record.pop('kind')
            self.old_path.write_text(json.dumps(record)); self.old_bytes = self.old_path.read_bytes()
            self.complete_gate_receipt(); self.assertEqual(self.requests, [])
            self.assertFalse((self.state / 'pending').exists()); self.assert_history_preserved()
    def ordinary_fingerprint(self):
        return A.key([12, HEAD, BASE, self.pilot.settled_checks(PR, CHECKS, []), None,
            {p.name: json.loads(p.read_text()) for p in (self.state / 'decision-details').glob('D-alpha-T001-*.json')}, 0])
    def test_consumed_ordinary_upgrade_does_not_regate(self):
        self.pilot.data['advanced']['12'] = dict(head=HEAD, fingerprint=self.ordinary_fingerprint())
        self.pilot.advance(PR, CHECKS, []); self.pilot.advance(PR, CHECKS, [])
        self.assertEqual(self.gates(), [])
    def test_consumed_failed_upgrade_runs_one_normal_gate_before_publication(self):
        self.failed_history()
        self.pilot.data['advanced']['12'] = dict(head=HEAD, fingerprint=self.ordinary_fingerprint())
        self.pilot.advance(PR, CHECKS, [])
        self.assertEqual(len(self.gates()), 1, 'trusted failure changes consumed scheduling evidence')
        self.assertFalse((self.state / 'pending').exists())
        self.pilot.save(); restored = A.Pilot(self.ctx); self.pilot.data = restored.data
        self.pilot.advance(PR, CHECKS, [])
        self.assertEqual(len(self.gates()), 1)
        self.complete_gate_receipt()
        self.assertTrue((self.state / 'pending/D-alpha-T001-2.json').exists())
        self.pilot.advance(PR, CHECKS, [])
        self.assertEqual(len(self.gates()), 1)
        self.assertEqual(len(self.requests), 1)
        self.assert_history_preserved()
    def test_failed_history_pre_request_negative_matrix(self):
        self.failed_history()
        variants = [dict(expected_head=HEAD), dict(merge='running'), dict(merge='merged'),
            dict(chosen='B'), dict(chosen='C'), dict(chosen='custom'), dict(chosen=None),
            dict(merge=None), dict(merge='unknown'), dict(merge=None, merged=dict(ok=False)),
            dict(binding={}), dict(binding=dict(signature='forged')), dict(merge_settled=None),
            dict(id='D-beta-T001-1'), dict(identity='decision:wrong'), dict(project='beta'),
            dict(task='T-002'), dict(pr=13), dict(expected_head=None),
            dict(kind=None, purpose=None), dict(kind=None, purpose='merge'),
            dict(kind=None, purpose='unknown'), dict(kind='merge', purpose='dispatch'),
            dict(kind='', purpose='dispatch')]
        for change in variants:
            with self.subTest(change=change):
                record = dict(self.old, **change)
                if 'kind' in change and change['kind'] is None: record.pop('kind')
                self.old_path.write_text(json.dumps(record))
                self.old_bytes = self.old_path.read_bytes()
                self.gate_result(0)
                self.assertEqual(self.requests, [])
                self.assertFalse((self.state / 'pending').exists())
                self.assert_history_preserved()
        self.old_path.write_text(json.dumps(self.old)); self.old_bytes = self.old_path.read_bytes()
        for data in (None, dict(self.event, actor='worker'),
                     dict(self.event, data=dict(self.event['data'], expected_head=HEAD))):
            self.events.write_text('' if data is None else json.dumps(data) + '\n')
            self.event_bytes = self.events.read_bytes(); self.gate_result(0)
            self.assertEqual(self.requests, [])
            self.assert_history_preserved()
    def test_failed_history_missing_corrupt_readiness_and_conflicting_settlement_hold(self):
        self.failed_history()
        files = list(self.store.directory.glob('*.json'))
        old_file = next(p for p in files if json.loads(p.read_text())['head'] != HEAD)
        original = old_file.read_bytes()
        for content in (None, original.replace(b'owner/alpha', b'owner/other')):
            if content is None: old_file.unlink()
            else: old_file.write_bytes(content)
            self.gate_result(0); self.assertEqual(self.requests, [])
            self.assert_history_preserved()
        old_file.write_bytes(original)
        self.events.write_text(self.event_bytes.decode() + json.dumps(dict(self.event,
            data=dict(self.event['data'], outcome='merged'))) + '\n')
        self.event_bytes = self.events.read_bytes(); self.gate_result(0)
        self.assertEqual(self.requests, [])
        self.assert_history_preserved()
    def test_visible_cooperating_blocker_holds_replacement(self):
        self.failed_history()
        with patch('fm_concurrent.merge_blocker', return_value='pending merge D-alpha-T002-1'):
            self.gate_result(0)
        self.assertEqual(self.requests, [])
        self.assertFalse((self.state / 'pending').exists())
        self.assert_history_preserved()
    def test_blocker_visible_at_second_reread_prevents_request(self):
        self.failed_history()
        with patch('fm_concurrent.merge_blocker', side_effect=['', 'pending merge D-alpha-T002-1']):
            self.gate_result(0)
        self.assertEqual(self.requests, [])
        self.assertFalse((self.state / 'pending').exists())
        self.assert_history_preserved()
    def test_stock_candidate_refuses_after_precheck_mutations(self):
        self.failed_history()
        for category in ('head', 'base', 'checks', 'review', 'readiness'):
            with self.subTest(category=category):
                def mutate():
                    if category == 'head': self.remote['headRefOid'] = 'e' * 40
                    if category == 'base': self.current_base = 'e' * 40
                    if category == 'checks': self.current_checks = ['ci-red']
                    if category == 'review': self.review = dict(self.review, signature='superseded')
                    if category == 'readiness':
                        for p in self.store.directory.glob('*.json'):
                            if json.loads(p.read_text())['head'] == HEAD: p.unlink()
                self.candidate_mutation = mutate
                self.complete_gate_receipt()
                self.assertEqual(self.pilot.data['jobs']['fresh']['state'], 'uncertain')
                self.assertFalse((self.state / 'pending').exists())
                self.assert_history_preserved()
                self.remote['headRefOid'] = HEAD; self.current_base = BASE
                self.current_checks = ['ci-success']; self.review['signature'] = self.selected_signature
        self.assertEqual(len(self.requests), 5)

    def test_external_private_failures_and_reservation_use_bounded_bilingual_wakes(self):
        self.failed_history(external=True)
        details = self.state / 'decision-details/D-alpha-T001-2.json'; details.unlink()
        self.gate_result(0)
        self.assertEqual(self.requests, [])
        self.assertTrue((self.state / 'decision-ids/alpha/T001/2.json').exists())
        self.current_ready(); self.replacement_details()
        self.gate_result(0)
        self.assertTrue((self.state / 'pending/D-alpha-T001-2.json').exists()); card = json.loads((self.state / 'pending/D-alpha-T001-2.json').read_text())
        self.assertEqual(card['binding']['signature'], self.ready['signature'])
        self.assertEqual(len(list((self.state / 'decision-ids/alpha/T001').glob('*.json'))), 2)
        (self.state / 'pending/D-alpha-T001-2.json').unlink()
        self.old_path.write_text(json.dumps(dict(self.old, binding={})))
        self.old_bytes = self.old_path.read_bytes(); self.gate_result(0)
        for wake in self.pilot.data['wakes'].values():
            self.assertEqual(set(wake['summary']), {'en', 'zh-TW'})
            self.assertNotIn(self.sentinel, json.dumps(wake))
        self.assertFalse((self.root / 'state/evidence').exists())
        self.assertTrue((self.state / 'evidence/T-001').exists())
        retained = self.store.records()
        self.assertIn(self.old_ready, retained)
        self.assertIn(self.sentinel, self.old_ready['text'])
        self.assertIn(self.sentinel, (self.state / 'decision-details/D-alpha-T001-2.json').read_text())
        self.assert_history_preserved()
        for p in (self.root / 'state').rglob('*'):
            if p.is_file(): self.assertNotIn(self.sentinel.encode(), p.read_bytes())

    def test_reserved_replacement_invalid_updated_evidence_refuses_then_reuses_id(self):
        self.failed_history(external=True)
        details = self.state / 'decision-details/D-alpha-T001-2.json'; details.unlink()
        self.gate_result(0)
        self.current_ready()
        latest = next(p for p in self.store.directory.glob('*.json')
                      if json.loads(p.read_text())['signature'] == self.ready['signature'])
        latest.write_text(latest.read_text().replace('ci-success', 'ci-pending'))
        self.replacement_details()
        self.gate_result(0)  # Corrupt Store also invalidates historical trust.
        self.assertEqual(self.requests, [])
        self.assertFalse((self.state / 'pending').exists())
        latest.unlink(); self.current_ready()
        self.gate_result(0)
        self.assertTrue((self.state / 'pending/D-alpha-T001-2.json').exists()); card = json.loads((self.state / 'pending/D-alpha-T001-2.json').read_text())
        self.assertEqual(card['binding']['signature'], self.ready['signature'])
        self.assertEqual(len(list((self.state / 'decision-ids/alpha/T001').glob('*.json'))), 2)
        self.assert_history_preserved()

    def test_current_valid_signed_red_or_pending_checks_are_stock_refusals(self):
        self.failed_history()
        for checks in (['ci-red'], ['ci-pending'], ['ci-stale']):
            self.current_checks = checks
            self.complete_gate_receipt()
            self.assertEqual(self.pilot.data['jobs']['fresh']['state'], 'uncertain')
            self.assertFalse((self.state / 'pending').exists())
            self.assert_history_preserved()
        self.assertEqual(len(self.requests), 3)

    def test_replacement_active_and_uncertain_jobs_remain_dependencies(self):
        self.failed_history()
        for state in ('running', 'consuming', 'uncertain'):
            self.pilot.data['jobs'] = {'owned': dict(task='T-001', state=state, path='')}
            self.pilot.advance(PR, CHECKS, [])
            self.assertEqual(self.gates(), [])
            self.assertEqual(self.pilot.data['jobs']['owned']['state'], state)
        with patch('fm_concurrent.live_rounds', return_value=[dict(task='T-001')]):
            self.pilot.data['jobs'] = {}; self.pilot.advance(PR, CHECKS, [])
        self.assertEqual(self.gates(), [])
        self.assert_history_preserved()

    def test_failed_history_foreign_and_conflicting_owned_record_never_authorizes(self):
        self.failed_history()
        other = self.state / 'decisions/D-beta-T001-1.json'
        self.old_path.rename(other)
        other.write_text(json.dumps(dict(self.old, id=other.stem, project='beta',
                                        identity='decision:' + other.stem)))
        # Foreign history alone cannot append replacement scheduling evidence.
        self.pilot.data['advanced']['12'] = dict(head=HEAD, fingerprint=self.ordinary_fingerprint())
        self.pilot.advance(PR, CHECKS, [])
        self.assertEqual(self.gates(), [])
        other.unlink(); self.old_path.write_bytes(self.old_bytes)
        pending = self.state / 'pending'; pending.mkdir()
        (pending / 'D-alpha-T001-3.json').write_text(json.dumps(dict(self.old,
            id='D-alpha-T001-3', chosen=None, merge=None)))
        self.gate_result(0)
        self.assertEqual(self.requests, [])
        self.assert_history_preserved()

    def test_external_replacement_request_errors_do_not_project_private_text(self):
        self.failed_history(external=True)
        def private_error(): raise RuntimeError(self.sentinel)
        self.candidate_mutation = private_error
        self.complete_gate_receipt()
        self.assertEqual(self.pilot.data['jobs']['fresh']['state'], 'uncertain')
        self.assertFalse((self.state / 'pending').exists())
        for wake in self.pilot.data['wakes'].values():
            self.assertEqual(set(wake['summary']), {'en', 'zh-TW'})
            self.assertNotIn(self.sentinel, json.dumps(wake))
        self.assert_history_preserved()

    def test_second_failed_head_holds_until_another_distinct_head_gets_fresh_gates(self):
        self.failed_history(); self.complete_gate_receipt()
        path = self.state / 'pending/D-alpha-T001-2.json'
        self.assertTrue(path.exists()); card = json.loads(path.read_text()); path.unlink()
        second_id = card['id']
        second = dict(card, identity='decision:' + second_id, chosen='A', merge='failed',
                      merge_settled='2026-01-02T00:00:00Z')
        (self.state / 'decisions' / (second_id + '.json')).write_text(json.dumps(second))
        event = dict(self.event, ts='2026-01-02T00:00:01Z', data=dict(self.event['data'],
                     decision=second_id, expected_head=HEAD))
        self.events.write_text(self.event_bytes.decode() + json.dumps(event) + '\n')
        self.event_bytes = self.events.read_bytes()
        for _ in range(3): self.pilot.advance(PR, CHECKS, [])
        self.assertEqual(self.gates(), [])
        next_pr = copy.deepcopy(PR); next_pr['head']['sha'] = 'e' * 40
        with patch.object(sys.modules[__name__], 'HEAD', 'e' * 40), \
             patch.object(sys.modules[__name__], 'PR', next_pr):
            self.review = self.store.append('verdict', 3, 'reviewer', HEAD, 'APPROVE:T-001',
                verdict='APPROVE', provenance=dict(level='legacy'), binding=self.source, base=BASE)
            self.selected_signature = self.review['signature']; self.current_ready()
            self.remote['headRefOid'] = HEAD
            folder = self.state / 'decision-details'
            (folder / 'D-alpha-T001-3.json').write_bytes((folder / 'D-alpha-T001-2.json').read_bytes())
            self.pilot.advance(next_pr, [dict(CHECKS[0], head_sha=HEAD)], [])
            self.assertEqual(len(self.gates()), 1)
            self.complete_gate_receipt()
        self.assertTrue((self.state / 'pending/D-alpha-T001-3.json').exists())
        self.assertEqual(len(self.requests), 2)
        self.assertEqual(json.loads((self.state / 'decisions' / (second_id + '.json')).read_text()), second)
        self.assert_history_preserved()

    def assert_landed_silent(self):
        self.details()
        before = copy.deepcopy(self.pilot.data)
        self.pilot.advance(PR, CHECKS, [])
        for kind, codes in (('gate', (0, 5, 6)), ('protocol', (0, 1)), ('review', (0, 3))):
            for code in codes:
                self.pilot.job_completed(dict(kind=kind, task='T-001', pr=PR,
                    code=code, base=BASE, round=3, output=''))
        self.assertEqual(self.calls, [])
        self.assertEqual(self.pilot.data, before)
        self.assertFalse((self.state / 'decision-ids').exists())

    def test_merged_event_suppresses_advancement_and_all_late_results(self):
        (self.state / 'events.jsonl').write_text(json.dumps(
            dict(type='merged', project='alpha', pr=12)) + '\n')
        self.assert_landed_silent()
        pr = dict(PR, number='12')
        self.assertTrue(self.pilot.landed('T-001', pr))

    def test_matching_captain_merge_suppresses_all_late_results(self):
        for folder in ('pending', 'decisions'):
            directory = self.state / folder; directory.mkdir(exist_ok=True)
            path = directory / 'D-alpha-T001-1.json'
            for outcome in ('running', 'merged'):
                with self.subTest(folder=folder, outcome=outcome):
                    path.write_text(json.dumps(dict(kind='merge', task='T-001', pr='12',
                        expected_head=HEAD, chosen='A', merge=outcome)))
                    self.assert_landed_silent()
            path.unlink()

    def test_nonlanded_decisions_keep_gate_failure_reporting(self):
        directory = self.state / 'decisions'; directory.mkdir()
        record = dict(kind='merge', task='T-001', pr=12, expected_head=HEAD, chosen='A', merge='running')
        for change in (dict(merge='failed'), dict(chosen='B'), dict(chosen='C'),
                       dict(expected_head='d' * 40), dict(pr=13), dict(task='T-002'), dict(kind='choice')):
            with self.subTest(change=change):
                (directory / 'D-alpha-T001-1.json').write_text(json.dumps(dict(record, **change)))
                self.pilot.data['wakes'].clear()
                self.assertFalse(self.pilot.landed('T-001', PR))
                self.gate_result(5)
                self.assertIn('stopped at gate 5 (ci)', str(self.pilot.data['wakes']))

    def test_closed_and_foreign_merged_events_still_gate_and_report(self):
        (self.state / 'events.jsonl').write_text(''.join(json.dumps(row) + '\n' for row in (
            dict(type='closed', project='alpha', pr=12),
            dict(type='merged', project='beta', pr=12),
            dict(type='merged', project='alpha', pr=13))))
        self.pilot.advance(PR, CHECKS, [])
        self.assertEqual(len(self.gates()), 1)
        self.gate_result(5)
        self.assertIn('stopped at gate 5 (ci)', str(self.pilot.data['wakes']))

if __name__ == '__main__': unittest.main()
