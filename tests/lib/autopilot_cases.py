"""Constructed REST payloads exercise mechanical transitions, not model output."""
import copy
import json
import os
from pathlib import Path
import sys
import subprocess
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
PR = dict(number=12, state='open', head=dict(sha=HEAD, ref='t-001-work'),
          base=dict(ref='main', sha='b' * 40), mergeable=True,
          mergeable_state='clean', draft=False)


class PilotTests(BranchFixture, unittest.TestCase):
    def setUp(self):
        env = patch.dict(os.environ, {k:v for k,v in os.environ.items() if not k.startswith(('FM_', 'HERDR_'))}, clear=True)
        env.start(); self.addCleanup(env.stop)
        os.environ['HERDR_ENV'] = '0'
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name).resolve()
        self.state = self.root / 'state'
        self.state.mkdir()
        self.calls = []
        self.context = dict(engine=str(self.root), state=str(self.state),
                            target=str(self.root), project='self', repository='owner/repo',
                            base='main', evidence_project='self', external=False, tasks=str(self.root / 'tasks'))
        Path(self.context['tasks']).mkdir()
        (Path(self.context['tasks']) / 'T-001.json').write_text('{"id":"T-001"}')
        self.pilot = A.Pilot(self.context, clock=lambda: 1000)
        self.pilot.command = self.command
        self.branch_setup()
        self.pilot.probe = self.probe
        self.pilot.read_head_spec = lambda pr, task: dict(id=task)
        self.pilot.emit = lambda *args, **kwargs: self.calls.append(('emit', args))
        self.pilot.notify = lambda text: self.calls.append(('notify', text))
        self.pilot.push = lambda *args: self.calls.append(('wake', args))
        self.pilot.advance = lambda *args: None
        self.pilot.prepare_head = lambda *args: None
        self.pilot.launch_review = lambda *args: self.calls.append(('review', args))

    def probe(self, argv):
        self.calls.append(argv)
        return self.branch_probe(argv)

    def command(self, argv, **kwargs):
        if argv[:2] == ['bash', '-c']:
            return A.Pilot.command(self.pilot, argv, **kwargs)
        self.calls.append(argv)
        if argv[1:3] == ['pr', 'view']:
            return json.dumps(dict(headRefOid=HEAD, mergeable='MERGEABLE', mergeStateStatus='BEHIND'))
        return ''

    def puts(self):
        return [x for x in self.calls if isinstance(x, list) and x[1:4] == ['api', '-X', 'PUT']]

    def behind(self):
        return dict(copy.deepcopy(PR), mergeable_state='behind')

    def test_only_mergeable_behind_is_updated_and_never_merged(self):
        self.pull_at(self.behind())
        self.assertEqual(self.puts(), [['gh', 'api', '-X', 'PUT',
            'repos/owner/repo/pulls/12/update-branch', '-f', 'expected_head_sha=' + HEAD, '--include']])
        self.pull_at(self.behind())
        for mergeable in (False, None):
            pr = self.behind(); pr['head']['sha'] = ('c' if mergeable is None else 'd') * 40
            pr['mergeable'] = mergeable
            self.pull_at(pr)
        self.pull_at(dict(self.behind(), draft=True))
        self.pull_at(PR)
        self.assertEqual(len(self.puts()), 1)
        self.assertNotIn('merge', [word for x in self.puts() for word in x])
        self.assertFalse(self.pilot.data['actions'])

    # Review eligibility formerly compared base-only patch metadata here.
    # T-175 delegates all eligibility to the real gates; the replacement
    # assertions are in autopilot_loop.py (worker head -> gate -> review,
    # carried approval -> gate -> card, and current-head REJECT -> brief).

    def test_failure_and_findings_batch_per_reviewer(self):
        pr = copy.deepcopy(PR); pr['mergeable_state'] = 'clean'
        runs = [dict(id=1, name='ci', head_sha=HEAD, status='completed', conclusion='failure')]
        status = [dict(id=2, context='lint', state='error')]
        reviews = [dict(id=3, user={'login':'reviewer'}, state='CHANGES_REQUESTED', commit_id=HEAD, body='fix')]
        comments = [dict(id=4, user={'login':'reviewer'}, body='finding', updated_at='now')]
        self.pull_at(pr, reviews, comments, runs, status)
        self.pilot.flush()
        wakes = [x for x in self.calls if x[0] == 'wake']
        self.assertEqual(len(wakes), 2, 'CI failures queue immediately')
        self.pilot.clock = lambda: 1181
        self.pilot.flush()
        wakes = [x for x in self.calls if x[0] == 'wake']
        self.assertEqual(len(wakes), 3, 'one quiet reviewer closes one batch')
        self.assertIn('CHANGES_REQUESTED', str(wakes[-1]))
        self.assertIn('finding', str(wakes[-1]))
        self.pull_at(pr, reviews, comments, runs, status)
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
        restored.probe = self.probe
        self.assertEqual(len(restored.data['wakes']), 5)
        for i, event in enumerate(events): restored.event(event, str(i))
        self.assertEqual(len(restored.data['wakes']), 5)
        self.assertTrue(all(v['line'] for v in restored.data['wakes'].values()))

    def test_unsent_note_wakes_once_even_while_busy_and_survives_restart(self):
        event = dict(type='worker_note_unsent', task='T-001', pr=12, data={})
        self.pilot.busy = lambda task: True
        self.pilot.event(event, 'unsent-1')
        self.assertEqual(len(self.pilot.data['wakes']), 1)
        self.assertEqual(next(iter(self.pilot.data['wakes'].values()))['line'],
                         'Worker note unsent; run bin/fm.sh unsent --post: T-001')
        self.pilot.save()
        restored = A.Pilot(self.context, clock=lambda: 1200)
        restored.busy = lambda task: True
        restored.event(event, 'unsent-1')
        self.assertEqual(restored.data['wakes'], self.pilot.data['wakes'])

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

    def test_failed_update_retries_at_one_and_three_then_wakes_once(self):
        self.put_answer = response('503 Service Unavailable', 'try later')
        for expected in (1, 2, 2, 3, 3, 3):
            self.pull_at(self.behind())
            self.assertEqual(len(self.puts()), expected)
        self.assertEqual(len(self.pilot.data['wakes']), 1)
        self.assertIn('HTTP/2.0 503 Service Unavailable', str(self.pilot.data['wakes']))
        self.assertEqual(self.pilot.data['actions'], {})

    def test_task_lookup_and_observation_do_not_use_operation_channel(self):
        self.pilot.command = lambda *a, **kw: self.fail('task lookup used operation channel')
        for number, ref, title, expected in (
                (21, 't001-legacy', 'Other', 'T-001'),
                (22, 'unrelated', 'T-001: fallback', 'T-001'),
                (23, 'sk-123-update', 'Other', 'SK-123'),
                (24, 'revert-1', 'Revert "T-001: work"', '')):
            with self.subTest(ref=ref):
                if expected:
                    (Path(self.context['tasks']) / (expected + '.json')).write_text('{}')
                pr = copy.deepcopy(PR)
                pr.update(number=number, title=title)
                pr['head']['ref'] = ref
                self.assertEqual(self.pilot.task(pr), expected)
                self.pilot.observe_pr(pr)
                self.assertEqual(self.calls[-1][1][0:2], ('pr_opened', expected))

    def test_migrated_launchers_use_their_own_interpreter(self):
        endpoints = self.root / 'bin'
        endpoints.mkdir()
        for name in ('fm-gate.sh', 'fm-review.sh', 'fm-protocol.sh', 'fm-decide.sh'):
            with self.subTest(name=name):
                endpoint = endpoints / name
                endpoint.write_text('#!' + sys.executable + '\nimport sys\nprint(sys.argv[1])\n')
                endpoint.chmod(0o755)
                with patch.object(A, 'BIN', endpoints):
                    argv = self.pilot.script(name, 'shebang-selected')
                result = subprocess.run(argv, capture_output=True, text=True, stdin=subprocess.DEVNULL)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(result.stdout, 'shebang-selected\n')

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
        self.pull_at(pr, [alice, bob], [], [], [])
        self.pilot.clock = lambda:1100
        alice['body'] = 'edited finding'
        self.pull_at(pr, [alice, bob], [], [], [])
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

    def test_ready_task_holds_and_queues_firstmate_judgment_once(self):
        def command(argv, **kwargs):
            self.calls.append(argv)
            if 'list' in argv: return 'T-001\tunjudged\t-\tWork\n'
            return ''
        self.pilot.command = command
        self.pilot.ready(); self.pilot.ready(); self.pilot.flush()
        self.assertEqual(len(self.pilot.data['wakes']), 1)
        self.assertIn('T-001 ready: readiness card needed', str(self.pilot.data['wakes']))
        self.assertFalse(any('--request' in x or 'judged' in x for x in self.calls))
        self.assertTrue(any(x[0] == 'wake' for x in self.calls))

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
        self.pull_at(PR, [], [], [], [])
        self.assertEqual(self.calls, [])

    def test_team_merge_is_observed_once_without_invoking_merge(self):
        pr = copy.deepcopy(PR); pr.update(state='closed', merged_at='2026-10-03T12:00:00Z')
        self.pilot.data['pulls']['12'] = {}
        self.pilot.closed_pull(pr)
        self.pilot.closed_pull(pr)
        self.assertEqual(len(self.calls), 1)
        self.assertEqual(self.calls[0][0], 'emit')
        self.assertEqual(self.calls[0][1][0], 'merged')
        self.assertTrue(self.pilot.data['pulls']['12']['terminal'])
        pr['number'] = 13; pr['merged_at'] = None
        self.pilot.data['pulls']['13'] = {}
        self.pilot.closed_pull(pr)
        self.assertEqual(len(self.calls), 2, 'closed PR events are retained as well as merges')
        self.assertEqual(self.calls[-1][1][0], 'closed')
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
        pilot.probe = self.probe
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
        with A.life.Doorbell(home) as bell, A.life.Doorbell(home, channel='autopilot.d') as pilot:
            A.life.ring_state(home/'state', 'conventions edited')
            self.assertTrue(bell.wait(0))
            self.assertTrue(pilot.wait(0), 'policy updates also notify autopilot')
        self.assertFalse((self.state/'session').exists())

    def test_pending_update_waits_twenty_poll_steps(self):
        self.pull_at(self.behind())
        first = self.pilot.data['poll_seq']
        for _ in range(19): self.pull_at(self.behind())
        self.assertEqual(len(self.puts()), 1)
        self.assertEqual(self.pilot.data['updates']['12'], dict(head=HEAD, seq=first))
        self.pull_at(self.behind())
        self.assertEqual(len(self.puts()), 2)
        self.assertEqual(self.pilot.data['updates']['12']['seq'], first + 20)

    def test_expected_head_422_is_moved_without_reread_or_retry(self):
        self.put_answer = response('422 Unprocessable Entity', "Expected Head SHA didn't match current head ref.")
        self.pull_at(self.behind())
        self.assertEqual(self.pilot.data['retries'], {})
        self.assertEqual(self.pilot.data['wakes'], {})
        self.assertFalse(any(isinstance(c, list) and c[1:3] == ['pr', 'view'] for c in self.calls))
        self.pull_at(self.behind())
        self.assertEqual(len(self.puts()), 2)

    def test_other_422_rereads_uncached_head_before_retry(self):
        self.put_answer = response('422 Unprocessable Entity', 'cannot update')
        original = self.command
        for result in ('c' * 40, HEAD, None):
            with self.subTest(result=result):
                self.pilot.data['retries'].clear()
                def reread(argv, **kwargs):
                    self.assertEqual(argv, ['gh', 'pr', 'view', '12', '--repo',
                        'owner/repo', '--json', 'headRefOid,mergeable,mergeStateStatus'])
                    if result is None: raise RuntimeError('offline')
                    return json.dumps(dict(headRefOid=result))
                self.pilot.command = reread
                self.pull_at(self.behind())
                self.assertEqual(bool(self.pilot.data['retries']), result != 'c' * 40)
                self.assertEqual(self.pilot.data['wakes'], {})
        self.pilot.command = original

    def test_poll_sequence_advances_before_policy_and_network_errors(self):
        self.pilot.policy_error = 'bad policy'
        self.pilot.poll()
        self.assertEqual(self.pilot.data['poll_seq'], 1)
        self.pilot.policy_error = None
        self.pilot.rows = lambda: (_ for _ in ()).throw(ValueError('offline'))
        self.pilot.poll()
        self.assertEqual(self.pilot.data['poll_seq'], 2)
        self.assertEqual(self.pilot.data['failures'], 1)

    def test_update_failures_are_isolated_per_pr_in_poll(self):
        first = self.behind()
        second = self.behind(); second['number'] = 13
        second['head'] = dict(sha='c' * 40, ref='t-001-second')
        self.local_refs = {p['head']['ref']: p['head']['sha'] for p in (first, second)}
        self.pilot.observe_pr = lambda pr: None
        self.pilot.inspect_policy = lambda: None
        self.pilot.rows = lambda: []
        self.pilot.task = lambda pr: 'T-001'
        def api(endpoint):
            if endpoint.startswith('pulls?state=open'): return [first, second]
            if endpoint.startswith('pulls?state=closed'): return []
            if endpoint == 'pulls/12': return first
            if endpoint == 'pulls/13': return second
            if '/reviews?' in endpoint or '/comments?' in endpoint: return []
            if '/check-runs?' in endpoint: return dict(check_runs=[], total_count=0)
            if '/status?' in endpoint: return dict(sha=endpoint.split('/')[1], statuses=[], total_count=0)
            self.fail(endpoint)
        self.pilot.api = api
        for answer in (response('403 Forbidden', 'denied'), response('500 Server Error', 'error'),
                       (1, '', 'transport lost')):
            with self.subTest(answer=answer):
                self.calls.clear(); self.pilot.data['retries'].clear(); self.pilot.data['updates'].clear()
                def probe(argv):
                    self.calls.append(argv)
                    if argv[1:4] == ['api', '-X', 'PUT']:
                        return answer if '/12/' in argv[4] else response()
                    return self.branch_probe(argv)
                self.pilot.probe = probe
                with patch.object(self.pilot, 'network_failure') as failure:
                    self.pilot.poll()
                failure.assert_not_called()
                self.assertEqual(len(self.puts()), 2)
                self.assertEqual(self.pilot.data['retries']['update:12:' + HEAD]['count'], 1)
                self.assertEqual(self.pilot.data['updates']['13']['head'], 'c' * 40)
                self.assertEqual(sum(isinstance(c, list) and '--verify' in c for c in self.calls), 2)

    def seed_branch_state(self):
        self.pilot.data['pulls']['12'] = dict(task='T-001', head=HEAD)
        for number in ('12', '13'):
            self.pilot.data['retries']['sync:' + number + ':' + HEAD] = dict(count=2, due_seq=10)
            self.pilot.data['retries']['update:' + number + ':' + HEAD] = dict(count=2, due_seq=10)
            self.pilot.data['holds'][number] = dict(head=HEAD, count=2)
            self.pilot.data['updates'][number] = dict(head=HEAD, seq=1)

    def test_branch_state_prunes_on_head_change_closed_and_merged_event(self):
        for transition in ('head', 'closed', 'merged', 'event'):
            with self.subTest(transition=transition):
                self.seed_branch_state()
                pr = copy.deepcopy(PR)
                if transition == 'head':
                    pr['head']['sha'] = 'c' * 40
                    self.pull_at(pr)
                elif transition == 'event':
                    self.pilot.event(dict(type='merged', task='T-001', pr=12, project='self'), 'merged')
                else:
                    pr.update(state='closed', merged_at='now' if transition == 'merged' else None)
                    self.pilot.closed_pull(pr)
                self.assertFalse(any(k.split(':')[1] == '12' for k in self.pilot.data['retries']))
                self.assertNotIn('12', self.pilot.data['holds'])
                self.assertNotIn('12', self.pilot.data['updates'])
                self.assertIn('13', self.pilot.data['holds'])
                self.assertIn('update:13:' + HEAD, self.pilot.data['retries'])

    def restart_branch_pilot(self):
        self.pilot.save()
        self.pilot = A.Pilot(self.context, clock=lambda: 1000)
        self.pilot.command = self.command
        self.pilot.probe = self.probe
        self.pilot.advance = lambda *args: None
        self.pilot.read_head_spec = lambda pr, task: dict(id=task)
        self.pilot.push = lambda *args: self.calls.append(('wake', args))
        self.pilot.emit = lambda *args, **kw: None

    def test_retry_and_hold_survive_restart_and_deduplicate_wakes(self):
        self.pilot.data['poll_seq'] = 4
        self.pilot.data['retries']['update:12:' + HEAD] = dict(count=2, due_seq=6)
        self.pilot.data['holds']['13'] = dict(head=HEAD, count=2)
        self.restart_branch_pilot()
        self.put_answer = response('503 Service Unavailable', 'later')
        self.pull_at(self.behind())
        self.assertEqual(len(self.puts()), 0)
        self.pull_at(self.behind())
        self.assertEqual(len(self.puts()), 1)
        self.assertEqual(len(self.pilot.data['wakes']), 1)
        pr = copy.deepcopy(PR); pr['number'] = 13; pr['head']['ref'] = 't-001-second'
        self.branch = pr['head']['ref']; self.fetch_head = HEAD
        self.local_refs[self.branch] = 'd' * 40
        self.worktree = str(self.root / 'dirty'); self.dirty = True
        self.pilot.data['poll_seq'] += 1
        self.pilot.pull(pr, [], [], [], [])
        self.assertEqual(len(self.pilot.data['wakes']), 2)
        self.pilot.flush(); self.restart_branch_pilot()
        self.pilot.data['poll_seq'] += 1
        self.pilot.pull(pr, [], [], [], [])
        self.pull_at(self.behind()); self.pilot.flush()
        self.assertEqual(len(self.pilot.data['wakes']), 2)
        self.assertEqual(len([c for c in self.calls if c[0] == 'wake']), 2)

    def test_update_migration_preserves_delivered_files_across_two_startups(self):
        tokens = [A.key(['update', '12', HEAD]), A.key(['update', '13', HEAD])]
        for number, token in zip(('12', '13'), tokens):
            self.pilot.data['actions'][token] = dict(state='started', identity=['update', number, HEAD], task='T-001')
            self.pilot.queue('action-' + token, 'T-001', 'legacy update', '舊分支更新')
        delivered = self.state / 'wake-queue'; delivered.mkdir()
        path = delivered / ('autopilot-' + A.key(['self', 'action-' + tokens[0]]) + '.json')
        path.write_bytes(b'{"delivered":"unchanged"}\n')
        self.pilot.data['wakes'][path.stem]['pushed'] = True
        advance = dict(state='uncertain', identity=['advance', '12', HEAD], task='T-001')
        self.pilot.data['actions']['advance'] = advance
        for name in ('poll_seq', 'retries', 'holds', 'updates', 'migrated_t190', 'migrated_t193'):
            self.pilot.data.pop(name, None)
        self.restart_branch_pilot()
        self.pilot.recover(); self.pilot.flush()
        for name, value in (('poll_seq', 0), ('retries', {}), ('holds', {}), ('updates', {})):
            self.assertEqual(self.pilot.data[name], value)
        self.assertTrue(self.pilot.data['migrated_t190'])
        self.assertEqual(self.pilot.data['actions'], {})
        self.assertFalse(any(not w['pushed'] for w in self.pilot.data['wakes'].values()))
        self.assertEqual(path.read_bytes(), b'{"delivered":"unchanged"}\n')
        first = copy.deepcopy(self.pilot.data)
        self.restart_branch_pilot(); self.pilot.recover(); self.pilot.flush()
        self.assertEqual(self.pilot.data, first)
        self.assertEqual(path.read_bytes(), b'{"delivered":"unchanged"}\n')
        self.assertFalse(any(c[0] == 'wake' for c in self.calls))

    def test_advance_migration_removes_all_states_before_recovery_once(self):
        tokens = []
        for status in ('started', 'done', 'uncertain'):
            token = A.key(['advance', status]); tokens.append(token)
            self.pilot.data['actions'][token] = dict(state=status,
                identity=['advance', status], task='T-001')
            self.pilot.queue('action-' + token, 'T-001', 'legacy advance', '舊關卡推進')
        delivered = self.state / 'wake-queue'; delivered.mkdir()
        path = delivered / ('autopilot-' + A.key(['self', 'action-' + tokens[0]]) + '.json')
        payload = b'{"delivered":"unchanged"}\n'; path.write_bytes(payload)
        self.pilot.data['wakes'][path.stem]['pushed'] = True
        self.pilot.data['actions']['restack'] = dict(state='started', identity=['restack', 12], task='T-001')
        self.pilot.data.pop('migrated_t193', None)
        self.pilot.data.pop('advanced', None)
        self.restart_branch_pilot(); self.pilot.recover(); self.pilot.flush()
        self.assertEqual(set(self.pilot.data['actions']), {'restack'})
        self.assertEqual(self.pilot.data['actions']['restack']['state'], 'uncertain')
        self.assertEqual(self.pilot.data['advanced'], {})
        self.assertTrue(self.pilot.data['migrated_t193'])
        for token in tokens[1:]:
            ident = 'autopilot-' + A.key(['self', 'action-' + token])
            self.assertNotIn(ident, self.pilot.data['wakes'])
            self.assertFalse((delivered / (ident + '.json')).exists())
        restack = 'autopilot-' + A.key(['self', 'action-restack'])
        self.assertEqual(set(self.pilot.data['wakes']), {path.stem, restack})
        self.assertIn('Autopilot stopped during an action', self.pilot.data['wakes'][restack]['line'])
        self.assertEqual(path.read_bytes(), payload)
        first = copy.deepcopy(self.pilot.data)
        self.restart_branch_pilot(); self.pilot.recover(); self.pilot.flush()
        self.assertEqual(self.pilot.data, first)
        self.assertEqual(path.read_bytes(), payload)
        self.assertEqual(len([c for c in self.calls if c[0] == 'wake']), 1)

    def test_probe_returns_nonzero_and_checked_raises_with_argv_and_last_line(self):
        result = subprocess.CompletedProcess(['git'], 128, 'body', 'noise\nfatal: last line\n\n')
        with patch.object(A.subprocess, 'run', return_value=result):
            self.assertEqual(A.Pilot.probe(self.pilot, ['git']), (128, result.stdout, result.stderr))
        self.pilot.probe = lambda argv: (128, result.stdout, result.stderr)
        with self.assertRaises(ValueError) as raised:
            self.pilot.checked(['git', 'bad-arg'])
        self.assertIn("['git', 'bad-arg']", str(raised.exception))
        self.assertIn('fatal: last line', str(raised.exception))
        self.assertNotIn('noise', str(raised.exception))
        self.pilot.probe = lambda argv: (0, 'stdout', '')
        self.assertEqual(self.pilot.checked(['git']), 'stdout')

    def test_http_status_controls_outcome_even_with_unusual_exit_code(self):
        self.put_answer = (1, response()[1], 'unexpected exit')
        self.pull_at(self.behind())
        self.assertIn('12', self.pilot.data['updates'])
        self.assertEqual(self.pilot.data['retries'], {})
        self.pilot.data['updates'].clear()
        self.put_answer = (0, response('503 Service Unavailable', 'error')[1], '')
        self.pull_at(self.behind())
        self.assertEqual(self.pilot.data['retries']['update:12:' + HEAD]['count'], 1)

    def test_raised_transport_failure_is_reread_and_retried(self):
        original = self.pilot.probe
        def probe(argv):
            if argv[1:4] == ['api', '-X', 'PUT']: raise OSError('transport failed')
            return original(argv)
        self.pilot.probe = probe
        self.pull_at(self.behind())
        self.assertEqual(self.pilot.data['retries']['update:12:' + HEAD]['count'], 1)
        self.assertTrue(any(isinstance(c, list) and c[1:3] == ['pr', 'view'] for c in self.calls))
        self.assertEqual(self.pilot.data['failures'], 0)

    def test_poll_terminal_observation_prunes_branch_state(self):
        for merged in (None, 'now'):
            self.seed_branch_state()
            pr = dict(copy.deepcopy(PR), state='closed', merged_at=merged)
            self.pilot.rows = lambda: []
            self.pilot.pages = lambda endpoint: []
            self.pilot.api = lambda endpoint: [pr]
            self.pilot.inspect_policy = lambda: None
            self.pilot.poll()
            self.assertTrue(self.pilot.data['pulls']['12']['terminal'])
            self.assertNotIn('12', self.pilot.data['holds'])
            self.assertNotIn('12', self.pilot.data['updates'])
            self.assertFalse(any(k.split(':')[1] == '12' for k in self.pilot.data['retries']))


if __name__ == '__main__':
    unittest.main()
