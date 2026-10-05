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
from autopilot_branch_fixture import BranchFixture, response, recheck_response

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
        self.assertNotIn('actions', self.pilot.data)

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
        argv = [x for x in self.calls if isinstance(x, list) and x[0].endswith('lib/fm-restack.sh')][-1]
        self.assertIn('--expected-head', argv)
        self.assertIn(HEAD, argv)
        self.assertIn('--project', argv)

    def restack_inputs(self):
        self.pilot.policy.update(stacking='allowed', force_with_lease=True)
        pr = copy.deepcopy(PR)
        pr['base']['ref'] = 't-002-parent'
        return pr, dict(number=9, merged_at='now', head=dict(ref='t-002-parent'))

    def restack_calls(self):
        return [c for c in self.calls if isinstance(c, list) and c[0].endswith('lib/fm-restack.sh')]

    def test_restack_done_is_per_head_without_ledger(self):
        pr, parent = self.restack_inputs()
        self.pilot.restack(pr, parent)
        self.assertEqual(self.pilot.data['restacks']['12'],
                         dict(head=HEAD, parent=9, task='T-001', outcome='done'))
        self.pilot.restack(pr, parent)
        self.assertEqual(len(self.restack_calls()), 1)
        self.assertNotIn('actions', self.pilot.data)
        pr['head']['sha'] = 'c' * 40
        self.pilot.prune_branches('12', pr['head']['sha'])
        self.assertNotIn('12', self.pilot.data['restacks'])
        self.pilot.restack(pr, parent)
        self.assertEqual(len(self.restack_calls()), 2)

    def test_restack_active_work_and_helper_lock_hold_silently(self):
        pr, parent = self.restack_inputs()
        for name in ('round_live', 'busy'):
            with patch.object(self.pilot, name, return_value=True):
                self.pilot.restack(pr, parent)
            self.assertEqual(self.restack_calls(), [])
            self.assertEqual(self.pilot.data['restacks'], {})
            self.assertEqual(self.pilot.data['retries'], {})
            self.assertEqual(self.pilot.data['wakes'], {})
        self.restack_answer = (75, '', 'task has a live worker; restack held')
        for count in (1, 2):
            self.pilot.restack(pr, parent)
            self.assertEqual(len(self.restack_calls()), count)
            self.assertEqual(self.pilot.data['restacks'], {})
            self.assertEqual(self.pilot.data['retries'], {})
            self.assertEqual(self.pilot.data['wakes'], {})

    def test_restack_moved_requires_fresh_confirmation(self):
        pr, parent = self.restack_inputs()
        self.restack_answer = (67, '', 'head moved')
        with patch.object(self.pilot, 'command', return_value=json.dumps(dict(headRefOid='c' * 40))) as command:
            self.pilot.restack(pr, parent)
        command.assert_called_once_with(['gh', 'pr', 'view', '12', '--repo', 'owner/repo', '--json', 'headRefOid'])
        self.assertEqual(self.pilot.data['restacks']['12'],
                         dict(head=HEAD, parent=9, task='T-001', outcome='moved'))
        self.assertEqual(self.pilot.data['retries'], {})
        self.assertEqual(self.pilot.data['wakes'], {})

    def test_restack_generic_failures_retry_offsets_and_last_line(self):
        for answer in ((68, '', 'noise\nlast refusal\n\n'), (65, '', 'last refusal'),
                       (64, '', 'last refusal'), (70, '', 'last refusal'),
                       (67, '', 'last refusal'), OSError('last refusal')):
            with self.subTest(answer=answer):
                pr, parent = self.restack_inputs()
                for name in ('restacks', 'retries', 'wakes'): self.pilot.data[name].clear()
                self.calls.clear(); self.restack_answer = answer
                for seq, count in enumerate((1, 2, 2, 3, 3, 3)):
                    self.pilot.data['poll_seq'] = seq
                    self.pilot.restack(pr, parent)
                    self.assertEqual(len(self.restack_calls()), count)
                    self.assertEqual(self.pilot.data['restacks'], {})
                self.assertEqual(len(self.pilot.data['wakes']), 1)
                wake = next(iter(self.pilot.data['wakes'].values()))
                self.assertEqual(wake['line'], 'T-001 #12 restack failed after 3 attempts: last refusal')
                self.assertNotIn('actions', self.pilot.data)
        self.pilot.data['retries'].clear()
        self.restack_answer = (67, '', 'last refusal')
        with patch.object(self.pilot, 'command', side_effect=OSError('offline')):
            self.pilot.restack(pr, parent)
        self.assertEqual(self.pilot.data['retries']['restack:12:' + HEAD]['count'], 1)
        for payload in ('null', '[]', '{}', 'not json'):
            self.pilot.data['retries'].clear()
            with patch.object(self.pilot, 'command', return_value=payload):
                self.pilot.restack(pr, parent)
            self.assertEqual(self.pilot.data['retries']['restack:12:' + HEAD]['count'], 1)
            self.assertEqual(self.pilot.data['restacks'], {})

    def test_restack_conflict_and_published_wake_once(self):
        for rc, outcome, reason in ((66, 'conflict', 'rebase conflict'),
                                    (69, 'published', 'published but did not finish')):
            with self.subTest(rc=rc):
                pr, parent = self.restack_inputs()
                self.calls.clear()
                for name in ('restacks', 'retries', 'wakes'): self.pilot.data[name].clear()
                self.restack_answer = (rc, '', 'noise\nlast line\n')
                self.pilot.restack(pr, parent)
                self.assertEqual(self.pilot.data['restacks']['12'],
                                 dict(head=HEAD, parent=9, task='T-001', outcome=outcome))
                self.pilot.restack(pr, parent)
                if rc == 69:
                    pr['head']['sha'] = 'c' * 40
                    for synced in (True, False):
                        with patch.object(self.pilot, 'sync_branch', return_value=synced):
                            self.pull_at(pr)
                            self.pilot.restack(pr, parent)
                        self.assertEqual(self.pilot.data['restacks']['12']['outcome'], 'published')
                self.assertEqual(len(self.restack_calls()), 1)
                self.assertEqual(len(self.pilot.data['wakes']), 1)
                wake = next(iter(self.pilot.data['wakes'].values()))
                self.assertIn(reason, wake['line']); self.assertTrue(wake['line'].endswith('last line'))
                self.assertTrue(wake['summary']['zh-TW'])
                self.assertEqual(self.pilot.data['retries'], {})
                self.pilot.prune_branches('12')
                self.assertEqual(self.pilot.data['restacks'], {})

    def test_restack_unknown_outcomes_hold_across_heads(self):
        for answer in (subprocess.TimeoutExpired('restack', 120), (71, '', 'push unknown'),
                       (1, '', 'traceback'), (-9, '', ''), (137, '', 'killed')):
            with self.subTest(answer=answer):
                pr, parent = self.restack_inputs()
                self.calls.clear()
                for name in ('restacks', 'retries', 'wakes'): self.pilot.data[name].clear()
                self.restack_answer = answer
                self.pilot.restack(pr, parent)
                expected = dict(head=HEAD, parent=9, task='T-001', outcome='started')
                self.assertEqual(self.pilot.data['restacks']['12'], expected)
                self.pilot.restack(pr, parent)
                pr['head']['sha'] = 'c' * 40
                self.pilot.prune_branches('12', pr['head']['sha'])
                self.pilot.restack(pr, parent)
                self.assertEqual(self.pilot.data['restacks']['12'], expected)
                self.assertEqual(len(self.restack_calls()), 1)
                self.assertEqual(len(self.pilot.data['wakes']), 1)
                self.assertIn('outcome unknown', next(iter(self.pilot.data['wakes'].values()))['line'])
                self.assertEqual(self.pilot.data['retries'], {})
                self.assertNotIn('actions', self.pilot.data)

    def test_restack_started_is_saved_before_probe_and_recovered_after_retarget(self):
        pr, parent = self.restack_inputs()
        def killed(argv):
            record = json.loads(self.pilot.path.read_text())['restacks']['12']
            self.assertEqual(record, dict(head=HEAD, parent=9, task='T-001', outcome='started'))
            raise KeyboardInterrupt()
        with patch.object(self.pilot, 'probe', side_effect=killed):
            with self.assertRaises(KeyboardInterrupt): self.pilot.restack(pr, parent)
        self.restart_branch_pilot()
        self.restack_inputs()
        self.pilot.restack(pr, parent)
        self.assertEqual(self.restack_calls(), [])
        self.assertEqual(len(self.pilot.data['wakes']), 1)
        # Recovery must not depend on pull() reaching the merged-parent path.
        self.pilot.data['wakes'].clear()
        self.pilot.data['restacks']['12']['task'] = 'T-099'
        pr['base']['ref'] = 'main'
        self.pilot.data['pulls']['12'] = pr
        self.restart_branch_pilot(); self.pilot.recover(); self.pilot.flush()
        wake = next(iter(self.pilot.data['wakes'].values()))
        self.assertEqual(wake['task'], 'T-099')
        self.assertEqual(wake['line'], 'T-099 #12 restack outcome unknown (timed out or interrupted); reconcile before review')
        first = copy.deepcopy(self.pilot.data)
        self.restart_branch_pilot(); self.pilot.recover(); self.pilot.flush()
        self.assertEqual(self.pilot.data, first)
        self.assertEqual(len([c for c in self.calls if c[0] == 'wake']), 1)

    def test_failed_update_retries_at_one_and_three_then_wakes_once(self):
        self.put_answer = response('503 Service Unavailable', 'try later')
        for expected in (1, 2, 2, 3, 3, 3):
            self.pull_at(self.behind())
            self.assertEqual(len(self.puts()), expected)
        self.assertEqual(len(self.pilot.data['wakes']), 1)
        self.assertIn('HTTP/2.0 503 Service Unavailable', str(self.pilot.data['wakes']))
        self.assertNotIn('actions', self.pilot.data)

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

    def recheck_setup(self, *, old=True):
        self.pilot.policy.update(reviewers=['alice'], post='threads')
        if old:
            self.pilot.data['pulls']['12'] = dict(head='b' * 40, task='T-001')
        self.review_posts = []
        self.review_answer = recheck_response(201, 'Created',
            dict(copy.deepcopy(PR), requested_reviewers=[dict(login='alice')]))
        original_probe, original_command = self.pilot.probe, self.pilot.command
        def is_request(argv):
            return any(arg.endswith('/requested_reviewers') for arg in argv)
        def answer(argv):
            self.assertIn('POST', argv)
            self.review_posts.append((self.pilot.data['poll_seq'], argv))
            if isinstance(self.review_answer, Exception): raise self.review_answer
            return self.review_answer
        def probe(argv):
            return answer(argv) if is_request(argv) else original_probe(argv)
        def command(argv, **kwargs):
            if not is_request(argv): return original_command(argv, **kwargs)
            rc, out, err = answer(argv)
            if rc: raise RuntimeError(err)
            return out if '--include' in argv else out.partition('\r\n\r\n')[2]
        self.pilot.probe, self.pilot.command = probe, command
        return [dict(id=1, user={'login':'alice'}, commit_id='b'*40, state='APPROVED')]

    def test_recheck_respects_local_projection(self):
        reviews = self.recheck_setup()
        self.pilot.policy['post'] = 'local'
        self.pull_at(PR, reviews); self.pull_at(PR, reviews)
        self.assertEqual(self.review_posts, [])
        identity = 'autopilot-' + A.key(['self', A.key(['recheck', 12, HEAD, 'alice'])])
        self.assertEqual(list(self.pilot.data['wakes']), [identity])
        self.assertIn('Reviewer re-check needed: alice', str(self.pilot.data['wakes']))
        self.pilot.policy['post'] = 'threads'
        pr = copy.deepcopy(PR); pr['head']['sha'] = 'c' * 40
        self.pull_at(pr, reviews); self.pull_at(pr, reviews)
        self.assertEqual(len(self.review_posts), 1)
        self.assertNotIn('actions', self.pilot.data)

    def test_recheck_head_record_completes_after_one_post(self):
        reviews = self.recheck_setup()
        self.pull_at(PR, reviews); self.pull_at(PR, reviews)
        self.assertEqual(len(self.review_posts), 1)
        self.assertEqual(self.review_posts[0][1], ['gh', 'api', '-X', 'POST',
            'repos/owner/repo/pulls/12/requested_reviewers', '-f', 'reviewers[]=alice', '--include'])
        self.assertEqual(self.pilot.data['rechecked']['12'], dict(head=HEAD, names=[]))
        self.assertNotIn('actions', self.pilot.data)

    def test_recheck_transient_failures_retry_at_zero_one_three(self):
        reviews = self.recheck_setup()
        self.review_answer = recheck_response(503, 'Service Unavailable',
                                             dict(message='Service Unavailable'), 'Service Unavailable')
        for _ in range(8): self.pull_at(PR, reviews)
        self.assertEqual([seq for seq, _ in self.review_posts], [1, 2, 4])
        self.assertEqual(len(self.pilot.data['wakes']), 1)
        self.assertIn('HTTP/2.0 503 Service Unavailable', str(self.pilot.data['wakes']))
        self.assertNotIn('actions', self.pilot.data)

    def test_recheck_transport_and_missing_status_failures_are_bounded(self):
        reviews = self.recheck_setup()
        for index, answer in enumerate((RuntimeError('connection reset'), (1, '', ''), (1, '', 'gh: offline'))):
            with self.subTest(answer=answer):
                pr = copy.deepcopy(PR); pr['head']['sha'] = str(index) * 40
                self.review_answer = answer
                start = self.pilot.data['poll_seq']
                before = len(self.review_posts)
                for _ in range(8): self.pull_at(pr, reviews)
                self.assertEqual([seq - start for seq, _ in self.review_posts[before:]], [1, 2, 4])
                self.assertEqual(len(self.pilot.data['wakes']), index + 1)
        self.assertIn('connection reset', str(self.pilot.data['wakes']))
        self.assertIn('missing HTTP status line', str(self.pilot.data['wakes']))
        self.assertIn('gh: offline', str(self.pilot.data['wakes']))

    def test_recheck_success_or_requested_clears_pending_retry(self):
        reviews = self.recheck_setup()
        success = self.review_answer
        for index, outcome in enumerate(('201', 'requested')):
            with self.subTest(outcome=outcome):
                pr = copy.deepcopy(PR); pr['head']['sha'] = str(index) * 40
                self.review_answer = recheck_response(503, 'Service Unavailable', {}, 'Service Unavailable')
                self.pull_at(pr, reviews)
                self.assertIn('recheck-alice:12:' + pr['head']['sha'], self.pilot.data['retries'])
                before = len(self.review_posts)
                self.review_answer = success
                if outcome == 'requested': pr['requested_reviewers'] = [dict(login='ALICE')]
                self.pull_at(pr, reviews); self.pull_at(pr, reviews)
                self.assertEqual(len(self.review_posts) - before, int(outcome == '201'))
                self.assertEqual(self.pilot.data['rechecked']['12']['names'], [])
                self.assertEqual(self.pilot.data['retries'], {})
                self.assertEqual(self.pilot.data['wakes'], {})

    def test_recheck_refusals_wake_once_without_retry(self):
        reviews = self.recheck_setup()
        messages = [
            'Reviews may only be requested from collaborators. One or more of the users or teams you specified is not a collaborator of the owner/repo repository.',
            'Review cannot be requested from pull request author.']
        for index, message in enumerate(messages):
            with self.subTest(message=message):
                pr = copy.deepcopy(PR); pr['head']['sha'] = str(index) * 40
                self.review_answer = recheck_response(422, 'Unprocessable Entity',
                    dict(message=message, documentation_url=
                         'https://docs.github.com/rest/pulls/review-requests#request-reviewers-for-a-pull-request',
                         status='422'), message)
                self.pull_at(pr, reviews); self.pull_at(pr, reviews)
                self.assertEqual(len(self.review_posts), index + 1)
                ident = 'autopilot-' + A.key(['self', f'recheck-refused-12-{pr["head"]["sha"]}-alice'])
                self.assertIn('reviewer re-check refused: alice: ' + message,
                              self.pilot.data['wakes'][ident]['line'])
                self.assertTrue(self.pilot.data['wakes'][ident]['summary']['zh-TW'])
                self.assertEqual(self.pilot.data['retries'], {})
                self.assertEqual(self.pilot.data['rechecked']['12']['names'], [])

    def test_recheck_already_requested_and_first_observation_do_not_post(self):
        reviews = self.recheck_setup(old=False)
        self.pull_at(PR, reviews)
        self.assertEqual(self.review_posts, [])
        pr = copy.deepcopy(PR); pr['head']['sha'] = 'c' * 40
        pr['requested_reviewers'] = [dict(login='ALICE')]
        self.pull_at(pr, reviews)
        self.assertEqual(self.review_posts, [])
        self.assertEqual(self.pilot.data['rechecked']['12']['names'], [])

    def test_recheck_head_change_replaces_pending_and_prunes_old_token(self):
        reviews = self.recheck_setup()
        self.review_answer = recheck_response(503, 'Service Unavailable', {}, 'Service Unavailable')
        self.pull_at(PR, reviews)
        old_token = 'recheck-alice:12:' + HEAD
        self.assertIn(old_token, self.pilot.data['retries'])
        pr = copy.deepcopy(PR); pr['head']['sha'] = 'c' * 40
        self.pull_at(pr, reviews)
        self.assertNotIn(old_token, self.pilot.data['retries'])
        self.assertEqual(self.pilot.data['rechecked']['12'], dict(head='c'*40, names=['alice']))
        self.assertIn('recheck-alice:12:' + 'c'*40, self.pilot.data['retries'])
        pr.update(state='closed', merged_at='now')
        self.pilot.closed_pull(pr)
        self.assertNotIn('12', self.pilot.data['rechecked'])

    def test_recheck_review_at_head_completes_pending_without_post(self):
        reviews = self.recheck_setup()
        self.review_answer = RuntimeError('transport unavailable')
        self.pull_at(PR, reviews)
        reviews.append(dict(id=2, user=dict(login='ALICE'), commit_id=HEAD, state='APPROVED'))
        self.pull_at(PR, reviews)
        self.assertEqual(len(self.review_posts), 1)
        self.assertEqual(self.pilot.data['rechecked']['12']['names'], [])
        self.assertEqual(self.pilot.data['retries'], {})

    def test_protected_base_never_updated_even_with_task_like_name(self):
        self.pilot.ctx['base'] = PR['head']['ref']
        self.pull_at(PR, [], [], [], [])
        self.assertEqual(self.calls, [])

    def test_team_merge_is_observed_once_without_invoking_merge(self):
        def emit(kind, task, en, tw, pr=None, actor='autopilot'):
            self.calls.append(('emit', (kind, task, en, tw, pr)))
            with (self.state / 'events.jsonl').open('a') as log:
                log.write(json.dumps(dict(type=kind, task=task, pr=pr, actor=actor)) + '\n')
        self.pilot.emit = emit
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

    def test_t205_migration_all_classes_and_defaults_once(self):
        actions = self.pilot.data['actions'] = {}
        removed, retained, delivered = set(), set(), {}
        folder = self.state / 'wake-queue'; folder.mkdir()
        classes = ('update', 'advance', 'restack', 'recheck', 'observed-merge',
                   'pr-event', 'launch-review', 'unknown')
        for kind in classes:
            for index, status in enumerate(('started', 'done', 'uncertain')):
                number = 12 + index
                identity = [kind, number, 'merged' if kind == 'pr-event' else HEAD]
                token = kind + '-' + status
                actions[token] = dict(identity=identity, state=status, task='T-001')
                wake = 'autopilot-' + A.key(['self', 'action-' + token])
                # Started review/unknown actions had not yet queued recovery.
                if kind not in ('launch-review', 'unknown') or status != 'started':
                    self.pilot.queue('action-' + token, 'T-001', 'legacy', '舊步驟')
                if status == 'done':
                    path = folder / (wake + '.json')
                    path.write_bytes(b'{"delivered":"unchanged"}\n')
                    delivered[path] = path.read_bytes()
                    self.pilot.data['wakes'][wake]['pushed'] = True
                    retained.add(wake)
                elif kind in ('launch-review', 'unknown'):
                    retained.add(wake)
                else:
                    removed.add(wake)
        for number in ('12', '13', '14'):
            self.pilot.data['pulls'][number] = dict(terminal=True, head=HEAD, task='T-001')
        self.pilot.data['pulls']['99'] = dict(head=HEAD, task='T-001')
        for number in (98, 99):
            actions[str(number)] = dict(identity=['pr-event', number, 'closed'], state='uncertain', task='T-001')
        # A done action with an undelivered wake is also discarded.
        actions['done-review'] = dict(identity=['launch-review', 15, HEAD], state='done', task='T-001')
        removed.add(self.pilot.queue('action-done-review', 'T-001', 'done', '完成'))
        for flag in ('migrated_t190', 'migrated_t193', 'migrated_t200', 'migrated_t204'):
            self.pilot.data[flag] = 'preserve old flag'
        for name in ('poll_seq', 'retries', 'holds', 'updates', 'advanced', 'restacks', 'migrated_t205'):
            self.pilot.data.pop(name, None)
        self.restart_branch_pilot(); self.pilot.recover()
        self.assertNotIn('actions', self.pilot.data)
        self.assertTrue(self.pilot.data['migrated_t205'])
        for name in ('retries', 'holds', 'updates', 'advanced', 'restacks'):
            self.assertEqual(self.pilot.data[name], {})
        self.assertEqual(self.pilot.data['poll_seq'], 0)
        for flag in ('migrated_t190', 'migrated_t193', 'migrated_t200', 'migrated_t204'):
            self.assertEqual(self.pilot.data[flag], 'preserve old flag')
        self.assertEqual(self.pilot.data['pulls']['12']['event_pending'], 'merged')
        self.assertEqual(self.pilot.data['pulls']['14']['event_pending'], 'merged')
        self.assertNotIn('event_pending', self.pilot.data['pulls']['13'])
        self.assertNotIn('event_pending', self.pilot.data['pulls']['99'])
        self.assertNotIn('98', self.pilot.data['pulls'])
        self.assertEqual(set(self.pilot.data['wakes']), retained)
        for kind in ('launch-review', 'unknown'):
            wake = self.pilot.data['wakes']['autopilot-' + A.key(['self', 'action-' + kind + '-started'])]
            self.assertEqual(wake['line'], 'Autopilot stopped during an action; reconcile its outcome')
            self.assertEqual(wake['summary']['zh-TW'], '自動駕駛於步驟執行中停止；請核對結果')
            uncertain = self.pilot.data['wakes']['autopilot-' + A.key(['self', 'action-' + kind + '-uncertain'])]
            self.assertEqual(uncertain['line'], 'legacy')
        self.assertEqual(len(self.pilot.data['jobs']), 2)
        self.pilot.flush()
        for path, payload in delivered.items(): self.assertEqual(path.read_bytes(), payload)
        for wake in removed:
            self.assertFalse((folder / (wake + '.json')).exists())
        state = self.pilot.path.read_bytes()
        queue = {p.name: p.read_bytes() for p in folder.iterdir()}
        calls = len(self.calls)
        self.restart_branch_pilot(); self.pilot.recover(); self.pilot.flush()
        self.assertEqual(self.pilot.path.read_bytes(), state)
        self.assertEqual({p.name: p.read_bytes() for p in folder.iterdir()}, queue)
        self.assertEqual(len(self.calls), calls)

    def test_t205_no_conversion_creates_no_jobs(self):
        for actions in (None, {}, {'old': dict(identity=['update', 12, HEAD], state='started')}):
            with self.subTest(actions=actions):
                self.pilot.data.pop('migrated_t205', None)
                self.pilot.data.pop('actions', None)
                self.pilot.data.pop('jobs', None)
                expected = copy.deepcopy(self.pilot.data)
                if actions is not None: self.pilot.data['actions'] = actions
                self.restart_branch_pilot()
                self.assertEqual(self.pilot.data, dict(expected, migrated_t205=True))
                self.assertNotIn('jobs', self.pilot.data)

    def test_t205_malformed_and_missing_identities_reconcile_without_jobs(self):
        actions = self.pilot.data['actions'] = {}
        expected = {}
        identities = (['launch-review'], ['launch-review', 'x', 'short'], None, [],
                      ['launch-review', '12', HEAD], ['launch-review', 12, 'z' * 40])
        for index, identity in enumerate(identities):
            for status in ('started', 'uncertain'):
                token = str(index) + status
                action = dict(state=status, task='T-001')
                if identity is not None: action['identity'] = identity
                actions[token] = action
                wake = 'autopilot-' + A.key(['self', 'action-' + token])
                if status == 'uncertain':
                    self.pilot.queue('action-' + token, 'T-001', 'keep original', '保留')
                    expected[wake] = copy.deepcopy(self.pilot.data['wakes'][wake])
        self.pilot.data.pop('migrated_t205', None)
        self.restart_branch_pilot(); self.pilot.recover()
        self.assertNotIn('actions', self.pilot.data)
        self.assertNotIn('jobs', self.pilot.data)
        self.assertEqual(len(self.pilot.data['wakes']), len(identities) * 2)
        for wake, record in expected.items(): self.assertEqual(self.pilot.data['wakes'][wake], record)
        for wake, record in self.pilot.data['wakes'].items():
            if wake not in expected:
                self.assertEqual(record['line'], 'Autopilot stopped during an action; reconcile its outcome')
        before = copy.deepcopy(self.pilot.data)
        self.restart_branch_pilot(); self.pilot.recover()
        self.assertEqual(self.pilot.data, before)

    def test_t205_review_actions_block_gate7_without_second_job(self):
        for status in ('started', 'uncertain'):
            for existing in (False, True):
                with self.subTest(status=status, existing=existing):
                    self.pilot.data['wakes'] = {}
                    self.pilot.data.pop('jobs', None)
                    job = dict(kind='review', task='T-001', number=12, head=HEAD, state='done', path='')
                    if existing: self.pilot.data['jobs'] = {'existing': job}
                    self.pilot.data['actions'] = {'review': dict(identity=['launch-review', 12, HEAD],
                                                                state=status, task='T-001')}
                    if status == 'uncertain':
                        self.pilot.queue('action-review', 'T-001', 'already reported', '已回報')
                    self.pilot.data.pop('migrated_t205', None)
                    self.restart_branch_pilot()
                    jobs = self.pilot.data['jobs']
                    self.assertEqual(len(jobs), 1)
                    if existing:
                        self.assertEqual(jobs, {'existing': job})
                    else:
                        self.assertEqual(jobs[A.key(['review-launch', 12, HEAD])], dict(job, state='uncertain'))
                    before = copy.deepcopy(self.pilot.data)
                    self.pilot.authoritative_head = lambda *args: HEAD
                    with patch.object(self.pilot, 'start_job') as launch:
                        for _ in range(2):
                            self.pilot.job_completed(dict(kind='gate', task='T-001', pr=PR,
                                                         code=7, round=1, base='b'*40))
                        launch.assert_not_called()
                    self.assertEqual(self.pilot.data, before)
                    self.assertEqual(len(self.pilot.data['wakes']), 1)

    def test_t205_existing_reconcile_wakes_are_preserved(self):
        self.pilot.data['actions'] = {}
        folder = self.state / 'wake-queue'; folder.mkdir()
        delivered = {}
        for status in ('started', 'uncertain'):
            for pushed in (False, True):
                token = status + str(pushed)
                self.pilot.data['actions'][token] = dict(identity=['launch-review', 12, HEAD],
                                                       task='T-001', state=status)
                ident = self.pilot.queue('action-' + token, 'T-001', 'existing reconcile', '既有核對')
                self.pilot.data['wakes'][ident]['pushed'] = pushed
                if pushed:
                    path = folder / (ident + '.json')
                    path.write_bytes(b'{"already":"delivered"}\n')
                    delivered[path] = path.read_bytes()
        wakes = copy.deepcopy(self.pilot.data['wakes'])
        self.pilot.data.pop('migrated_t205', None)
        self.restart_branch_pilot(); self.pilot.recover()
        self.assertEqual(self.pilot.data['wakes'], wakes)
        self.assertEqual(len(self.pilot.data['jobs']), 1)
        self.pilot.flush()
        for path, payload in delivered.items(): self.assertEqual(path.read_bytes(), payload)
        self.assertEqual(len([c for c in self.calls if c[0] == 'wake']), 2)

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
