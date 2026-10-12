"""T-293: a job interrupted by a stop or restart resumes from its breakpoint."""
import copy
import json
import os
os.environ['HERDR_ENV'] = '0'
from pathlib import Path
import unittest
from unittest.mock import patch

import autopilot_loop as fixture
# A module import: its test classes must not run again in this suite.
import autopilot_stale_jobs as stale

A, PR, HEAD, BASE = fixture.A, fixture.PR, fixture.HEAD, fixture.BASE
OLD, at = stale.OLD, stale.at
NOTICE = 'Autopilot stopped during a child'


class InterruptedJobs(unittest.TestCase):
    record_job = fixture.LoopTests.record_job
    command = fixture.LoopTests.command
    probe = fixture.LoopTests.probe
    branch_setup = fixture.BranchFixture.branch_setup
    branch_probe = fixture.BranchFixture.branch_probe
    details = fixture.LoopTests.details
    pull = stale.StaleJobs.pull
    api = stale.StaleJobs.api
    poll = stale.StaleJobs.poll
    wakes_with = stale.StaleJobs.wakes_with

    def setUp(self):
        stale.StaleJobs.setUp(self)
        self.pilot.spawn = lambda path, packet: self.calls.append(('spawn', path, packet))

    def job(self, name, kind='gate', head=HEAD, state='running', **extra):
        """A job the autopilot started, with its packet on disk."""
        path = self.state / 'autopilot/jobs' / (name + '.json')
        path.parent.mkdir(parents=True, exist_ok=True)
        packet = dict(kind=kind, task='T-001', pr=at(head), argv=['fm-' + kind + '.sh'],
                      state=str(self.state), base=BASE, round=1, **extra)
        path.write_text(json.dumps(packet))
        self.pilot.data.setdefault('jobs', {})[name] = dict(kind=kind, task='T-001', number=12, head=head,
                                                            state=state, path=str(path))
        return self.pilot.data['jobs'][name], path, packet

    def receipt(self, path, packet, code, output=''):
        path.with_suffix('.result.json').write_text(json.dumps(dict(packet, code=code, output=output)))

    def spawns(self):
        return [c for c in self.calls if c[0] == 'spawn']

    def started(self):
        return [c[0] for c in self.calls if c[0] in ('gate', 'protocol', 'review', 'design-review')]

    def statuses(self, text):
        return [c[1][2] for c in self.calls if c[0] == 'emit' and c[1][0] == 'crew_status' and text in c[1][2]]

    def test_interrupted_gate_resumes(self):
        """autopilot: interrupted gate resumes

        Fails on the base: the restart marks the gate uncertain and queues a
        notice, and nothing runs it again or starts its review."""
        job, path, packet = self.job('gate')
        self.pilot.recover_jobs()
        self.assertEqual((job['state'], job.get('phase')), ('interrupted', 'child'))
        self.assertEqual(self.wakes_with(NOTICE), [], 'the reconcile notice is no longer queued')
        self.pull()
        self.assertEqual(self.spawns(), [('spawn', path, packet)], 'the same gate runs again on the same head')
        self.assertEqual(job['state'], 'running')
        self.assertNotIn('phase', job)
        self.assertEqual(self.statuses('Resumed'), ['Resumed an interrupted gate job of T-001 at ' + HEAD[:12]])
        self.receipt(path, packet, 6)
        self.pilot.consume_jobs()
        self.assertEqual(job['state'], 'done')
        self.assertEqual(self.started(), ['review'], 'the step that would have followed happens')
        self.pull(); self.pilot.recover_jobs(); self.pull()
        self.assertEqual(len(self.spawns()), 1)
        self.assertEqual(self.started(), ['review'])

    def test_child_killed_by_a_signal_runs_again(self):
        """A receipt with a negative exit is an interruption; exit 70 stays a failure."""
        job, path, packet = self.job('gate')
        self.receipt(path, packet, -15)
        self.pilot.consume_jobs()
        self.assertEqual((job['state'], job.get('phase')), ('interrupted', 'child'))
        self.assertFalse(path.with_suffix('.result.json').exists())
        self.assertEqual(json.loads(path.with_suffix('.interrupted.json').read_text())['code'], -15)
        self.assertEqual(self.started(), [])
        self.pull()
        self.assertEqual(self.spawns(), [('spawn', path, packet)])
        failed, path, packet = self.job('failed')
        self.receipt(path, packet, 70, 'Mechanical child ended without a receipt')
        self.pilot.consume_jobs()
        self.assertEqual(failed['state'], 'done')
        self.assertEqual(len(self.wakes_with('gate run failed (exit 70)')), 1)

    def test_interrupted_result_acted_on_once(self):
        """autopilot: interrupted result acted on once

        A stop while acting on a result leaves it consuming. On restart it
        re-reads the receipt and finishes only the steps not yet done."""
        # Gate 6 asked for both reviews; the code review had started.
        job, path, packet = self.job('gate', state='consuming')
        self.receipt(path, packet, 6, 'lane code: missing\nlane design: missing')
        self.pilot.data['jobs']['review'] = dict(kind='review', task='T-001', number=12, head=HEAD,
                                                 state='running', path=str(self.state / 'review.json'))
        self.pilot.recover_jobs()
        self.assertEqual((job['state'], job.get('phase')), ('interrupted', 'result'))
        self.assertEqual(self.wakes_with(NOTICE), [])
        self.pull(); self.pull()
        self.assertEqual(job['state'], 'done')
        self.assertEqual(self.started(), ['design-review'], 'only the step not yet done')
        self.assertEqual(self.spawns(), [], 'a result is acted on again, never rerun')

    def test_interrupted_protocol_result_starts_its_gate_once(self):
        job, path, packet = self.job('protocol', kind='protocol', state='consuming')
        self.receipt(path, packet, 0)
        self.pilot.data['jobs']['next'] = dict(kind='gate', task='T-001', number=12, head=HEAD,
                                               state='running', path=str(self.state / 'next.json'), parent='protocol')
        self.pilot.recover_jobs(); self.pull()
        self.assertEqual(job['state'], 'done')
        self.assertEqual(self.started(), [])
        # Without a follow-on gate on record, the resumed result starts it.
        del self.pilot.data['jobs']['next']; job.update(state='interrupted', phase='result')
        self.pull()
        self.assertEqual(self.started(), ['gate'])

    def test_interrupted_gate_result_raises_its_card_once(self):
        job, path, packet = self.job('gate', state='consuming')
        job['card'] = 'D-alpha-T001-1'
        self.receipt(path, packet, 0)
        self.details()
        archived = self.state / 'runtime/archived-pending'
        archived.mkdir(parents=True)
        (archived / 'D-alpha-T001-1.json').write_text(json.dumps(dict(id='D-alpha-T001-1', kind='merge')))
        self.pilot.recover_jobs(); self.pull()
        self.assertEqual(job['state'], 'done')
        self.assertEqual([c for c in self.calls if c[0] == 'command' and '--request' in c[1]], [])
        # A fresh result records its card on the job before the request.
        fresh, path, packet = self.job('fresh')
        self.receipt(path, packet, 0)
        self.pilot.consume_jobs()
        self.assertEqual(fresh['state'], 'done')
        request = [c[1] for c in self.calls if c[0] == 'command' and '--request' in c[1]]
        self.assertEqual(len(request), 1)
        self.assertEqual(fresh['card'], request[0][request[0].index('--request') + 1])

    def test_interrupted_review_relaunched_once(self):
        """autopilot: interrupted review relaunched once

        With no verdict and no reviewer running it starts once; one review
        per head holds otherwise."""
        for kind in ('review', 'design-review'):
            with self.subTest(kind=kind):
                self.pilot.data['jobs'] = {}; self.calls.clear()
                job, path, packet = self.job(kind, kind=kind, verdict_before=A.key({}))
                self.pilot.recover_jobs()
                with patch('fm_concurrent.live_rounds', return_value=[dict(task='T-001', role='reviewer')]):
                    self.pull()
                self.assertEqual((job['state'], self.spawns()), ('interrupted', []), 'a reviewer is still running')
                self.pull(); self.pull()
                self.assertEqual(self.spawns(), [('spawn', path, packet)])
                self.assertEqual(job['state'], 'running')
                self.pilot.launch_review('T-001', PR) if kind == 'review' else self.pilot.launch_design_review('T-001', PR)
                self.assertEqual(self.started(), [], 'one autopilot review per head')

    def test_interrupted_review_with_a_recorded_verdict_closes(self):
        for kind in ('review', 'design-review'):
            with self.subTest(kind=kind):
                self.pilot.data['jobs'] = {}; self.calls.clear()
                job, path, packet = self.job(kind, kind=kind, verdict_before=A.key({}))
                verdict = dict(verdict='REJECT', head=HEAD, signature='new', round=1)
                reader = 'verdict' if kind == 'review' else 'design_verdict'
                with patch.object(self.pilot, reader, return_value=verdict, create=True):
                    self.pilot.recover_jobs(); self.pull()
                self.assertEqual((job['state'], job.get('superseded_by')), ('superseded', 'verdict'))
                self.assertEqual(self.spawns(), [])
                self.assertIn(('advance', HEAD), self.calls, 'advancement acts on the verdict as usual')

    def test_interrupted_job_superseded(self):
        """autopilot: interrupted job superseded

        A moved head or a closed PR closes the job, the same way stale
        uncertain jobs are settled; the new head is handled as usual."""
        job, path, packet = self.job('gate', head=OLD)
        closed, _, _ = self.job('closed', head=OLD)
        closed['number'] = 13
        # A design review is settled like a review, also when uncertain.
        design, _, _ = self.job('design', kind='design-review', head=OLD, state='uncertain')
        self.pilot.recover_jobs()
        self.assertEqual(job['state'], 'interrupted')
        self.assertEqual(self.wakes_with(NOTICE), [])
        self.pull()
        self.assertEqual((job['state'], job.get('superseded_by')), ('superseded', HEAD))
        self.assertEqual((design['state'], design.get('superseded_by')), ('superseded', HEAD))
        self.assertEqual(self.spawns(), [])
        self.assertIn(('advance', HEAD), self.calls)
        self.assertIn('Settled a stale gate job of T-001 at ' + OLD[:12]
                      + '; the pull request is now at ' + HEAD[:12], self.statuses('Settled'))
        self.poll()
        self.assertEqual((closed['state'], closed.get('superseded_by')), ('superseded', 'closed'))
        self.assertEqual(self.spawns(), [])

    def test_unresumable_and_queue_bound_jobs(self):
        lost = dict(kind='gate', task='T-001', number=12, head=HEAD, state='running',
                    path=str(self.state / 'missing.json'))
        bound, _, _ = self.job('bound', queue_binding=dict(H=HEAD, B=BASE))
        bound['queue_binding'] = dict(H=HEAD, B=BASE)
        self.pilot.data['jobs']['lost'] = lost
        self.pilot.recover_jobs()
        self.assertEqual((lost['state'], lost.get('superseded_by')), ('superseded', 'unresumable'))
        self.assertEqual(bound['state'], 'uncertain')
        self.assertEqual(self.pilot.data['wakes'], {})
        self.pull()
        self.assertEqual(self.spawns(), [])

    def test_upgraded_uncertain_job_resumes(self):
        """autopilot: upgraded uncertain job resumes

        On the first start after T-293, an uncertain job whose notice was not
        yet delivered resumes and the notice closes; a delivered one stays."""
        self.job('old', state='uncertain')
        self.job('seen', state='uncertain')
        undelivered = self.pilot.queue('job-old', 'T-001', NOTICE + '; reconcile its log', 'tw')
        delivered = self.pilot.queue('job-seen', 'T-001', NOTICE + '; reconcile its log', 'tw')
        self.pilot.data['wakes'][delivered]['pushed'] = True
        self.restart(upgrade=True)
        jobs = self.pilot.data['jobs']
        job, seen = jobs['old'], jobs['seen']
        self.assertEqual((job['state'], job.get('phase')), ('interrupted', 'child'))
        self.assertNotIn(undelivered, self.pilot.data['wakes'])
        self.assertEqual(seen['state'], 'uncertain')
        self.assertIn(delivered, self.pilot.data['wakes'])
        self.pull()
        path = Path(job['path'])
        self.assertEqual(self.spawns(), [('spawn', path, json.loads(path.read_text()))])
        self.assertEqual(seen['state'], 'uncertain')
        # Later starts leave a new uncertain job and its notice to firstmate.
        self.job('later', state='uncertain')
        notice = self.pilot.queue('job-later', 'T-001', NOTICE, 'tw')
        self.restart()
        self.assertEqual(self.pilot.data['jobs']['later']['state'], 'uncertain')
        self.assertIn(notice, self.pilot.data['wakes'])

    def restart(self, upgrade=False):
        """A new service start reads the saved state; an upgrade has never run T-293."""
        if upgrade: self.pilot.data.pop('migrated_t293', None)
        self.pilot.save()
        self.pilot.data = A.Pilot(self.ctx).data
        self.pilot.recover_jobs()

    def test_stuck_reason_names_an_interrupted_job(self):
        self.job('gate', state='interrupted', phase='child')
        self.assertEqual(self.pilot.stuck_reason('T-001', PR)[0], 'an interrupted gate job at ' + HEAD[:12])


if __name__ == '__main__': unittest.main()
