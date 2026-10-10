"""T-281: stale uncertain jobs settle themselves; a stuck approved PR wakes once."""
import copy
import json
import os
os.environ['HERDR_ENV'] = '0'
import subprocess
from pathlib import Path
import unittest
from unittest.mock import patch

import autopilot_loop as fixture

A, PR, HEAD, BASE, CHECKS = fixture.A, fixture.PR, fixture.HEAD, fixture.BASE, fixture.CHECKS
OLD = 'd' * 40
NEW = 'c' * 40


def at(head, **changes):
    pr = copy.deepcopy(PR)
    pr['head']['sha'] = head
    pr.update(changes)
    return pr


class StaleJobs(unittest.TestCase):
    # Reuse fixture helpers without inheriting the unrelated lifecycle tests.
    record_job = fixture.LoopTests.record_job
    command = fixture.LoopTests.command
    probe = fixture.LoopTests.probe
    branch_setup = fixture.BranchFixture.branch_setup
    branch_probe = fixture.BranchFixture.branch_probe
    failed_history = fixture.LoopTests.failed_history
    current_ready = fixture.LoopTests.current_ready
    replacement_details = fixture.LoopTests.replacement_details

    def setUp(self):
        fixture.LoopTests.setUp(self)
        self.now = 1000.0
        self.pilot.clock = lambda: self.now
        self.pilot.sync_branch = lambda *a: True
        self.pilot.advance = lambda *a: self.calls.append(('advance', a[0]['head']['sha']))

    def job(self, name='old', **changes):
        job = dict(kind='gate', task='T-001', number=12, head=OLD, state='uncertain', path='')
        job.update(changes)
        self.pilot.data.setdefault('jobs', {})[name] = job
        return job

    def pull(self, pr=PR, runs=None):
        self.pilot.data['poll_seq'] += 1
        if runs is None: runs = [dict(CHECKS[0], head_sha=pr['head']['sha'])]
        self.pilot.pull(pr, [], [], runs, [])

    def api(self, endpoint):
        if endpoint.startswith('pulls?state=closed'): return []
        if endpoint == 'pulls/' + str(self.current['number']): return copy.deepcopy(self.current)
        if endpoint.startswith('pulls/'):
            return at(OLD, number=int(endpoint.split('/')[1]), state='closed', closed_at='2020-01-01T00:00:00Z')
        if '/check-runs' in endpoint:
            return dict(total_count=1, check_runs=[dict(CHECKS[0], head_sha=self.current['head']['sha'])])
        if '/status' in endpoint: return dict(sha=endpoint.split('/')[1], total_count=0, statuses=[])
        return dict(contexts=['ci'], checks=[])

    def poll(self, pr=PR):
        self.current = copy.deepcopy(pr)
        self.pilot.api = self.api
        self.pilot.pages = lambda endpoint: [copy.deepcopy(self.current)] if endpoint == 'pulls?state=open' else []
        self.pilot.observe_pr = lambda *a: None
        self.pilot.poll()
        self.assertEqual(self.pilot.data['failures'], 0, 'the fixture poll must complete')

    def settle_events(self):
        return [c for c in self.calls if c[0] == 'emit' and c[1][0] == 'crew_status']

    def gates(self):
        return [c for c in self.calls if c[0] == 'gate']

    def wakes_with(self, text):
        return [w for w in self.pilot.data['wakes'].values() if text in w['line']]

    # Settling.

    def test_uncertain_gate_job_at_old_head_is_superseded_by_the_new_head(self):
        for number in (12, '12'):
            with self.subTest(number=number):
                self.pilot.data['jobs'] = {}; self.calls.clear()
                job = self.job(number=number)
                self.pull()
                self.assertEqual(job['state'], 'superseded')
                self.assertEqual(job['superseded_by'], HEAD)
                self.assertEqual(job['superseded_at'], self.now)

    def test_every_uncertain_source_settles_at_a_moved_head(self):
        old = at(OLD)
        for source in ('restart', 'consume', 'review-launch'):
            with self.subTest(source=source):
                self.pilot.data['jobs'] = {}; self.pilot.data['wakes'] = {}; self.calls.clear()
                path = self.state / ('job-' + source + '.json')
                if source == 'restart':
                    self.job(state='running', path=str(path))
                    self.pilot.recover_jobs()
                    self.assertEqual(len(self.wakes_with('Autopilot stopped during a child; reconcile its log')), 1)
                elif source == 'consume':
                    path.with_suffix('.result.json').write_text(json.dumps(dict(kind='gate', task='T-001',
                        pr=old, code=0, base=BASE, round=1)))
                    self.job(state='running', path=str(path))
                    with patch.object(self.pilot, 'job_completed', side_effect=ValueError('consume failed')):
                        self.pilot.consume_jobs()
                else:
                    with patch.object(self.pilot, 'start_job', side_effect=OSError('launch failed')):
                        self.pilot.launch_review('T-001', old)
                (job,) = self.pilot.data['jobs'].values()
                self.assertEqual(job['state'], 'uncertain')
                if source == 'review-launch':
                    self.assertEqual(job['path'], '')
                self.pull()
                self.assertEqual(job['state'], 'superseded')
                self.assertEqual(job['superseded_by'], HEAD)

    def test_settled_job_is_never_started_again_and_keeps_its_files(self):
        path = self.state / 'autopilot/jobs/stale.json'
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text('{}'); path.with_suffix('.log').write_text('log')
        job = self.job(state='running', path=str(path))
        self.pilot.recover_jobs()
        self.pull()
        self.pilot.recover_jobs(); self.pilot.consume_jobs(); self.pull()
        self.assertEqual(job['state'], 'superseded')
        self.assertTrue(path.exists() and path.with_suffix('.log').exists())
        self.assertFalse([c for c in self.calls if c[0] in ('gate', 'protocol', 'review')
                          and c[2]['head']['sha'] == OLD])

    def test_settling_emits_one_unthrottled_crew_status(self):
        self.job()
        self.pull(); self.pull()
        events = self.settle_events()
        self.assertEqual(len(events), 1)
        (kind, task, en, tw), kw = events[0][1], events[0][2]
        self.assertEqual((kind, task), ('crew_status', 'T-001'))
        self.assertEqual(en, 'Settled a stale gate job of T-001 at ' + OLD[:12]
                         + '; the pull request is now at ' + HEAD[:12])
        for fact in ('T-001', 'gate', OLD[:12], HEAD[:12]):
            self.assertIn(fact, tw)
        self.assertEqual(kw.get('pr'), 12)
        self.assertEqual(kw.get('env'), {'FM_CREW_STATUS_SECS': '0'})

    def test_emit_passes_its_environment_to_fm_emit(self):
        seen = []
        with patch.dict(os.environ, {}), patch.object(self.pilot, 'command',
                side_effect=lambda argv, **kw: seen.append(kw['env'])):
            os.environ.pop('FM_CREW_STATUS_SECS', None)
            A.Pilot.emit(self.pilot, 'crew_status', 'T-001', 'en', 'tw', pr=12,
                         env={'FM_CREW_STATUS_SECS': '0'})
            A.Pilot.emit(self.pilot, 'crew_status', 'T-001', 'en', 'tw', pr=12)
        self.assertEqual(seen[0]['FM_CREW_STATUS_SECS'], '0')
        self.assertEqual(seen[0]['FM_ROOT'], str(self.root))
        self.assertNotIn('FM_CREW_STATUS_SECS', seen[1])

    def test_failing_emit_keeps_the_job_settled_and_wakes_once(self):
        def refuse(*a, **kw): raise RuntimeError('emit refused')
        self.pilot.emit = refuse
        job = self.job()
        self.pull(); self.pull()
        self.assertEqual(job['state'], 'superseded')
        wakes = self.wakes_with('emit refused')
        self.assertEqual(len(wakes), 1)
        self.assertIn('T-001', wakes[0]['line'])
        self.assertIn('gate', wakes[0]['line'])
        self.assertEqual(wakes[0]['task'], 'T-001')

    def test_job_of_a_pr_that_is_not_open_is_superseded_closed(self):
        closed = self.job('closed', number=13)
        current = self.job('current', head=HEAD)
        self.poll()
        self.assertEqual(closed['state'], 'superseded')
        self.assertEqual(closed['superseded_by'], 'closed')
        self.assertEqual(current['state'], 'uncertain')
        (event,) = self.settle_events()
        self.assertEqual(event[1][2], 'Settled a stale gate job of T-001 at ' + OLD[:12]
                         + '; the pull request is closed')
        self.assertEqual(event[2].get('pr'), 13)

    # Effects of settling.

    def test_failed_card_with_stale_uncertain_job_gets_a_gate(self):
        self.failed_history()
        self.pilot.advance = fixture.A.Pilot.advance.__get__(self.pilot)
        self.job(head='d' * 40)
        self.pull()
        self.assertEqual(len(self.gates()), 1, 'a settled stale job must not hold the replacement gate')
        self.assertEqual(self.gates()[0][2]['head']['sha'], HEAD)

    # Guards: green before and after the change.

    def test_uncertain_job_on_the_current_head_keeps_blocking(self):
        self.failed_history()
        self.pilot.advance = fixture.A.Pilot.advance.__get__(self.pilot)
        job = self.job(head=HEAD)
        self.pull(); self.pull()
        self.assertEqual(job['state'], 'uncertain')
        self.assertEqual(self.gates(), [])
        self.assertFalse((self.state / 'pending').exists())
        self.assertEqual(self.settle_events(), [])

    def test_unlabelled_and_queue_bound_jobs_are_untouched(self):
        legacy = self.job('legacy'); legacy.pop('kind')
        bound = self.job('bound', queue_binding=dict(H=OLD, B=BASE))
        closed_legacy = self.job('closed-legacy', number=13); closed_legacy.pop('kind')
        closed_bound = self.job('closed-bound', number=13, queue_binding=dict(H=OLD, B=BASE))
        before = copy.deepcopy(self.pilot.data['jobs'])
        self.pull(); self.poll()
        self.assertEqual(self.pilot.data['jobs'], before)
        self.assertEqual(self.settle_events(), [])


class StuckCheck(unittest.TestCase):
    record_job = fixture.LoopTests.record_job
    command = fixture.LoopTests.command
    probe = fixture.LoopTests.probe
    branch_setup = fixture.BranchFixture.branch_setup
    branch_probe = fixture.BranchFixture.branch_probe
    setUp = StaleJobs.setUp
    job = StaleJobs.job
    pull = StaleJobs.pull
    api = StaleJobs.api
    poll = StaleJobs.poll

    LINE = 'T-001 #12 is approved, green and clean with no merge card for 30 minutes: '

    def approve(self, head=HEAD, verdict='APPROVE'):
        self.pilot.verdict = lambda task: dict(verdict=verdict, head=head, signature='signed')

    def wake_id(self, head=HEAD):
        return 'autopilot-' + A.key(['alpha', f'stuck-12-{head}'])

    def stuck_wakes(self):
        return {k: w for k, w in self.pilot.data['wakes'].items() if 'no merge card for 30 minutes' in w['line']}

    def pull_at(self, when, pr=PR, runs=None):
        self.now = when
        self.pull(pr, runs)

    def test_conditions_held_for_1800_seconds_wake_once(self):
        self.approve()
        self.pull_at(1000)
        self.pull_at(2799)
        self.assertEqual(self.stuck_wakes(), {})
        self.pull_at(2800)
        wakes = self.stuck_wakes()
        self.assertEqual(set(wakes), {self.wake_id()})
        wake = wakes[self.wake_id()]
        self.assertEqual(wake['line'], self.LINE + 'no reason found')
        self.assertEqual(wake['task'], 'T-001')
        self.assertIn('T-001 #12', wake['summary']['zh-TW'])
        self.assertIn('30', wake['summary']['zh-TW'])
        self.pull_at(9000)
        self.assertEqual(set(self.stuck_wakes()), {self.wake_id()})

    def test_failed_condition_removes_the_entry_and_restarts_the_full_wait(self):
        self.approve()
        self.pull_at(1000)
        self.pull_at(2000, at(HEAD, mergeable_state='blocked'))
        self.assertNotIn('12', self.pilot.data['stuck'])
        self.pull_at(2500)
        self.pull_at(2900)
        self.pull_at(4299)
        self.assertEqual(self.stuck_wakes(), {})
        self.pull_at(4300)
        self.assertEqual(set(self.stuck_wakes()), {self.wake_id()})

    def test_head_change_restarts_the_timer_on_the_new_head(self):
        self.approve()
        self.pull_at(1000)
        self.pull_at(2000, at(NEW))
        self.assertEqual(self.pilot.data['stuck']['12'], dict(head=NEW, since=2000))
        self.pull_at(3799, at(NEW))
        self.assertEqual(self.stuck_wakes(), {})
        self.pull_at(3800, at(NEW))
        self.assertEqual(set(self.stuck_wakes()), {self.wake_id(NEW)})

    def test_poll_removes_the_entry_of_a_pr_that_is_not_open(self):
        self.pilot.data['stuck']['13'] = dict(head=OLD, since=0)
        self.poll()
        self.assertNotIn('13', self.pilot.data['stuck'])

    def test_state_without_a_stuck_map_loads_and_the_timer_works(self):
        self.pilot.data.pop('stuck'); self.pilot.save()
        restored = A.Pilot(self.ctx)
        self.assertEqual(restored.data['stuck'], {})
        self.pilot.data = restored.data
        self.approve()
        self.pull_at(1000); self.pull_at(2800)
        self.assertEqual(set(self.stuck_wakes()), {self.wake_id()})

    def stuck_line(self):
        self.pilot.data['wakes'] = {}
        self.pilot.data['stuck'] = {'12': dict(head=HEAD, since=0)}
        self.pull_at(1800)
        (wake,) = self.stuck_wakes().values()
        return wake

    def test_each_reason_appears_when_it_is_the_first_that_applies(self):
        self.approve()
        self.job(head=HEAD)
        self.pilot.failed_card_evidence = lambda task, pr: ([], 'same failed head')
        with patch('fm_concurrent.live_rounds', return_value=[dict(task='T-001')]):
            wake = self.stuck_line()
            self.assertEqual(wake['line'], self.LINE + 'an uncertain gate job at ' + HEAD[:12])
            self.assertIn(HEAD[:12], wake['summary']['zh-TW'])
            self.pilot.data['jobs'] = {}
            wake = self.stuck_line()
            self.assertEqual(wake['line'], self.LINE + 'replacement held: same failed head')
            self.assertIn('新決策卡暫緩：仍是失敗的版本', wake['summary']['zh-TW'])
            self.pilot.failed_card_evidence = lambda task, pr: ([], '')
            wake = self.stuck_line()
            self.assertEqual(wake['line'], self.LINE + 'a worker round is live')
        wake = self.stuck_line()
        self.assertEqual(wake['line'], self.LINE + 'no reason found')

    def test_approval_at_an_older_head_starts_the_timer_and_is_named(self):
        self.approve(head=NEW)
        self.pull_at(1000)
        self.pull_at(2800)
        (wake,) = self.stuck_wakes().values()
        self.assertEqual(wake['line'], self.LINE + 'no reason found; the approval is for ' + NEW[:12])
        self.assertIn(NEW[:12], wake['summary']['zh-TW'])

    # Guards: green before and after the change.

    def test_timer_never_starts_without_every_condition(self):
        def pending_card():
            folder = self.state / 'pending'; folder.mkdir(exist_ok=True)
            (folder / 'D-alpha-T001-1.json').write_text(json.dumps(dict(kind='merge', task='T-001', pr=12)))
        def queue_on():
            self.pilot.queue_mode = 'hold'
            self.pilot.queue_guard = lambda *a, **kw: False
        cases = dict(
            pending_card=(pending_card, PR, None),
            pending_check=(lambda: None, PR, [dict(CHECKS[0], status='in_progress', conclusion=None)]),
            blocked=(lambda: None, at(HEAD, mergeable_state='blocked'), None),
            unknown=(lambda: None, at(HEAD, mergeable_state='unknown'), None),
            reject=(lambda: self.approve(verdict='REJECT'), PR, None),
            running_job=(lambda: self.job(head=HEAD, state='running'), PR, None),
            consuming_job=(lambda: self.job(head=HEAD, state='consuming'), PR, None),
            queue_mode=(queue_on, PR, None))
        for name, (arrange, pr, runs) in cases.items():
            with self.subTest(case=name):
                self.approve()
                self.pilot.__dict__.pop('queue_guard', None); self.pilot.queue_mode = 'off'
                self.pilot.data['jobs'] = {}; self.pilot.data['wakes'] = {}
                self.pilot.data.setdefault('stuck', {}).clear()
                for path in (self.state / 'pending').glob('*.json'): path.unlink()
                arrange()
                self.pull_at(1000, pr, runs)
                self.pull_at(9000, pr, runs)
                self.assertNotIn('12', self.pilot.data.get('stuck', {}))
                self.assertEqual(self.stuck_wakes(), {})

    def test_head_change_never_carries_the_old_wait(self):
        self.approve()
        self.pull_at(1000)
        self.pull_at(2700, at(NEW))
        self.pull_at(2800, at(NEW))
        self.assertEqual(self.stuck_wakes(), {})


if __name__ == '__main__': unittest.main()
