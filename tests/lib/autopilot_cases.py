"""Recorded REST payloads exercise mechanical transitions, not model output."""
import copy
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

HEAD = 'a' * 40
PR = dict(number=12, state='open', head=dict(sha=HEAD, ref='t-001-work'),
          base=dict(ref='main', sha='b' * 40), mergeable=True,
          mergeable_state='behind', draft=False)


class PilotTests(unittest.TestCase):
    def setUp(self):
        env = patch.dict(os.environ, {k:v for k,v in os.environ.items() if not k.startswith(('FM_', 'HERDR_'))}, clear=True)
        env.start(); self.addCleanup(env.stop)
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.state = self.root / 'state'
        self.state.mkdir()
        self.calls = []
        self.context = dict(engine=str(self.root), state=str(self.state),
                            target=str(self.root), project='self', repository='owner/repo',
                            base='main', external=False, tasks=str(self.root / 'tasks'))
        Path(self.context['tasks']).mkdir()
        (Path(self.context['tasks']) / 'T-001.json').write_text('{"id":"T-001"}')
        self.pilot = A.Pilot(self.context, clock=lambda: 1000)
        self.pilot.command = self.command
        self.pilot.emit = lambda *args: self.calls.append(('emit', args))
        self.pilot.notify = lambda text: self.calls.append(('notify', text))
        self.pilot.push = lambda *args: self.calls.append(('wake', args))
        self.pilot.covered = lambda *args: True
        self.pilot.prepare_head = lambda *args: None
        self.pilot.launch_review = lambda *args: self.calls.append(('review', args))

    def command(self, argv, **kwargs):
        self.calls.append(argv)
        if argv[1:3] == ['pr', 'view']:
            return json.dumps(dict(headRefOid=HEAD, mergeable='MERGEABLE', mergeStateStatus='BEHIND'))
        return ''

    def test_only_mergeable_behind_is_updated_and_never_merged(self):
        self.pilot.pull(PR, [], [], [], [])
        writes = [x for x in self.calls if isinstance(x, list) and x[1:3] == ['pr', 'update-branch']]
        self.assertEqual(writes, [['gh', 'pr', 'update-branch', '12', '--repo', 'owner/repo']])
        self.pilot.pull(PR, [], [], [], [])
        self.assertEqual(len([x for x in self.calls if isinstance(x, list) and x[1:3] == ['pr', 'update-branch']]), 1)
        for mergeable in (False, None):
            pr = copy.deepcopy(PR); pr['head']['sha'] = ('c' if mergeable is None else 'd') * 40
            pr['mergeable'] = mergeable
            self.pilot.pull(pr, [], [], [], [])
        self.assertEqual(len([x for x in self.calls if isinstance(x, list) and x[1:3] == ['pr', 'update-branch']]), 1)
        self.assertNotIn('merge', [word for x in writes for word in x])

    def test_new_head_after_update_requests_review_only_without_patch_coverage(self):
        self.pilot.pull(PR, [], [], [], [])
        pr = copy.deepcopy(PR); pr['head']['sha'] = 'c' * 40; pr['mergeable_state'] = 'clean'
        self.pilot.pull(pr, [], [], [], [])
        self.assertFalse(any(x[0] == 'review' for x in self.calls))
        self.pilot.covered = lambda *args: False
        pr['head']['sha'] = 'd' * 40
        self.pilot.pull(pr, [], [], [], [])
        self.assertTrue(any(x[0] == 'review' for x in self.calls))

    def test_failure_and_findings_batch_per_reviewer(self):
        pr = copy.deepcopy(PR); pr['mergeable_state'] = 'clean'
        runs = [dict(id=1, name='ci', head_sha=HEAD, status='completed', conclusion='failure')]
        status = [dict(id=2, context='lint', state='error')]
        reviews = [dict(id=3, user={'login':'reviewer'}, state='CHANGES_REQUESTED', commit_id=HEAD, body='fix')]
        comments = [dict(id=4, user={'login':'reviewer'}, body='finding', updated_at='now')]
        self.pilot.pull(pr, reviews, comments, runs, status)
        self.pilot.flush()
        wakes = [x for x in self.calls if x[0] == 'wake']
        self.assertEqual(len(wakes), 2, 'CI failures queue immediately')
        self.pilot.clock = lambda: 1181
        self.pilot.flush()
        wakes = [x for x in self.calls if x[0] == 'wake']
        self.assertEqual(len(wakes), 3, 'one quiet reviewer closes one batch')
        self.assertIn('CHANGES_REQUESTED', str(wakes[-1]))
        self.assertIn('finding', str(wakes[-1]))
        self.pilot.pull(pr, reviews, comments, runs, status)
        self.pilot.flush()
        self.assertEqual(len([x for x in self.calls if x[0] == 'wake']), 3)

    def test_local_judgment_reasons_survive_restart(self):
        events = [dict(type=t, task='T-001', data={}) for t in
                  ('worker_crashed', 'agent_lost', 'review_failed', 'conventions_drift')]
        events.append(dict(type='decision_made', task='T-001', data={'chosen':'B'}))
        for i, event in enumerate(events): self.pilot.event(event, str(i))
        self.pilot.flush()
        self.pilot.save()
        restored = A.Pilot(self.context, clock=lambda: 1200)
        self.assertEqual(len(restored.data['wakes']), 5)
        for i, event in enumerate(events): restored.event(event, str(i))
        self.assertEqual(len(restored.data['wakes']), 5)
        self.assertTrue(all(v['line'] for v in restored.data['wakes'].values()))

    def test_project_identity_prevents_cross_project_task_wakes(self):
        self.pilot.event(dict(type='agent_lost', task='T-001', project='other'), '1')
        self.assertEqual(self.pilot.data['wakes'], {})

    def test_stacking_requires_confirmed_force_policy_and_expected_head(self):
        pr = copy.deepcopy(PR); pr['base']['ref'] = 't-002-parent'
        parent = dict(number=9, merged_at='2026-10-01', head={'ref':'t-002-parent'})
        self.pilot.restack(pr, parent)
        self.assertFalse(any(isinstance(x,list) for x in self.calls))
        self.pilot.policy.update(stacking='allowed', force_with_lease=True)
        self.pilot.restack(pr, parent)
        argv = [x for x in self.calls if isinstance(x,list)][-1]
        self.assertIn('--expected-head', argv)
        self.assertIn(HEAD, argv)
        self.assertIn('--project', argv)

    def test_failed_operation_is_not_repeated_after_uncertain_crash(self):
        self.pilot.command = lambda *a, **kw: (_ for _ in ()).throw(RuntimeError('network lost'))
        self.pilot.pull(PR, [], [], [], [])
        self.pilot.command = self.command
        self.pilot.pull(PR, [], [], [], [])
        self.assertFalse(any(isinstance(x,list) for x in self.calls))
        self.assertTrue(self.pilot.data['wakes'])

    def test_retry_backoff_is_bounded_and_resets(self):
        first = self.pilot.network_failure('offline')
        second = self.pilot.network_failure('offline')
        self.assertGreater(second, first)
        for _ in range(30): delay = self.pilot.network_failure('offline')
        self.assertLessEqual(delay, 3600)
        self.pilot.network_success()
        self.assertEqual(self.pilot.data['failures'], 0)

    def test_conditional_http_304_reuses_only_endpoint_cache(self):
        responses = iter(['HTTP/2.0 200 OK\nETag: "one"\n\n[{"number":12}]',
                          'HTTP/2.0 304 Not Modified\nETag: "one"\n\n'])
        def command(argv, **kwargs):
            self.calls.append(argv); return next(responses)
        self.pilot.command = command
        self.assertEqual(self.pilot.api('pulls'), [{'number':12}])
        self.assertEqual(self.pilot.api('pulls'), [{'number':12}])
        self.assertIn('If-None-Match: "one"', self.calls[-1])
        self.assertIn('repos/owner/repo/pulls', self.calls[-1])

    def test_review_edits_extend_only_their_reviewers_quiet_period(self):
        pr = copy.deepcopy(PR); pr['mergeable_state'] = 'clean'
        alice = dict(id=1, user={'login':'alice'}, state='CHANGES_REQUESTED', body='first')
        bob = dict(id=2, user={'login':'bob'}, state='CHANGES_REQUESTED', body='first')
        self.pilot.pull(pr, [alice, bob], [], [], [])
        self.pilot.clock = lambda:1100
        alice['body'] = 'edited finding'
        self.pilot.pull(pr, [alice, bob], [], [], [])
        self.assertEqual(self.pilot.data['batches']['12:alice']['due'], 1280)
        self.assertEqual(self.pilot.data['batches']['12:bob']['due'], 1180)

    def test_overdue_wakes_notify_once_without_claiming_delivery(self):
        self.pilot.queue('failure', 'T-001', 'CI failed', 'CI 失敗')
        self.pilot.flush()
        self.pilot.clock = lambda: 5000
        with patch.object(A.life, 'is_acknowledged', return_value=False):
            self.pilot.flush(); self.pilot.flush()
        self.assertEqual(len([x for x in self.calls if x[0] == 'notify']), 1)
        self.assertTrue(any(x[0] == 'emit' and x[1][0] == 'autopilot_waiting' for x in self.calls))

    def test_events_consume_complete_lines_only(self):
        log = self.state / 'events.jsonl'
        row = json.dumps(dict(type='agent_lost', task='T-001'))
        log.write_text(row)
        self.pilot.local()
        self.assertEqual(self.pilot.data['offset'], 0)
        log.write_text(row + '\n')
        self.pilot.local()
        self.assertEqual(len(self.pilot.data['wakes']), 1)

    def test_intent_card_has_dispatch_park_drop_and_no_merge(self):
        def command(argv, **kwargs):
            self.calls.append(argv)
            if 'list' in argv: return 'T-001\tunjudged\t-\tWork\n'
            if '--allocate' in argv: return 'D-self-T001-1\n'
            return ''
        self.pilot.command = command
        self.pilot.ready()
        details = json.loads((self.pilot.directory / 'D-self-T001-1.json').read_text())
        self.assertEqual(details['effect'], dict(A='dispatch', B='hold', C='park', D='drop'))
        self.assertEqual(set(details) - {'effect'}, {'en', 'zh-TW'})
        self.assertTrue(any('judged' in x for x in self.calls))
        self.assertFalse(any('--kind' in x and 'merge' in x for x in self.calls))

    def test_recheck_respects_local_projection(self):
        reviews = [dict(id=1, user={'login':'alice'}, commit_id='b'*40, state='CHANGES_REQUESTED')]
        self.pilot.policy.update(reviewers=['alice'], post='local')
        self.pilot.recheck('T-001', PR, reviews)
        self.assertEqual(self.calls, [])
        self.pilot.policy['post'] = 'threads'
        self.pilot.recheck('T-001', PR, reviews)
        self.assertIn('repos/owner/repo/pulls/12/requested_reviewers', self.calls[-1])
        self.pilot.recheck('T-001', PR, reviews)
        self.assertEqual(len(self.calls), 1)

    def test_protected_base_never_updated_even_with_task_like_name(self):
        self.pilot.ctx['base'] = PR['head']['ref']
        self.pilot.pull(PR, [], [], [], [])
        self.assertEqual(self.calls, [])

    def test_team_merge_is_observed_once_without_invoking_merge(self):
        pr = copy.deepcopy(PR); pr.update(state='closed', merged_at='2026-10-03T12:00:00Z')
        self.pilot.closed_pull(pr)
        self.pilot.closed_pull(pr)
        self.assertEqual(len(self.calls), 1)
        self.assertEqual(self.calls[0][0], 'emit')
        self.assertEqual(self.calls[0][1][0], 'merged')
        self.assertTrue(self.pilot.data['pulls']['12']['terminal'])
        pr['number'] = 13; pr['merged_at'] = None
        self.pilot.closed_pull(pr)
        self.assertEqual(len(self.calls), 1, 'closing a PR is not permission to close its task')
        self.assertTrue(self.pilot.data['wakes'])

    def test_external_policy_and_wakes_stay_in_private_project(self):
        from fm_onboard import approve, infer
        home = self.root / 'private/projects/other'
        evidence = dict(repository='owner/private', base='main', source='github', pulls=[], commits=[],
                        repository_info=dict(full_name='owner/private', private=True, default_branch='main',
                                             allow_squash_merge=True, allow_merge_commit=False, allow_rebase_merge=False,
                                             delete_branch_on_merge=False), protection={'status':'unknown'})
        approve(home, evidence, infer(evidence), dict(confirmed=True, policy_confirmed=True, captain='captain',
                intent='test', product='app', required_checks=['ci'], contract={'check':'true'}, watch_seconds=90))
        ctx = {**self.context, 'state':str(home/'state'), 'tasks':str(home/'tasks'),
               'target':str(home/'repo'), 'project':'other', 'repository':'owner/private', 'external':True}
        pilot = A.Pilot(ctx, clock=lambda:1000)
        self.assertEqual(pilot.policy['watch_seconds'], 90)
        pilot.push = lambda *args: None
        pilot.queue('private', 'T-001', 'Private finding', '私有審查意見')
        pilot.flush()
        self.assertEqual(len(list((home/'state/wake-queue').glob('*.json'))), 1)
        self.assertFalse((self.state/'wake-queue').exists())
        (home/'CONVENTIONS.md').write_text('invalid')
        pilot.reload_policy()
        pilot.command = lambda *a, **k: self.fail('invalid conventions must not authorize operations')
        pilot.poll()
        self.assertTrue(pilot.policy_error)

    def test_resolved_policy_writer_rings_private_fifo_without_changing_routing(self):
        home = self.root / 'private/projects/other'
        home.mkdir(parents=True)
        # No project registry is needed for the already-resolved writer API.
        with A.life.Doorbell(home) as bell:
            A.life.ring_state(home/'state', 'conventions edited')
            self.assertTrue(bell.wait(0))
        self.assertFalse((self.state/'session').exists())


if __name__ == '__main__':
    unittest.main()
