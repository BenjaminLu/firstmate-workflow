"""Self-front scheduling behavior; disposable state, no remote service."""
import copy
import hashlib
import json
import os
from pathlib import Path
import sys
import tempfile
import unittest
import subprocess
import select
import shutil
import urllib.request
import re
from unittest.mock import patch

os.environ['HERDR_ENV'] = '0'
sys.dont_write_bytecode = True
ROOT = Path(sys.argv.pop(1)).resolve()
sys.path.insert(0, str(ROOT / 'bin/lib'))
import fm_autopilot as A

H, B = 'a' * 40, 'b' * 40


def policy():
    return dict(version=1, strategy='self-front', enabled=True,
                repository='owner/self', base='main', cohort=[3, 1, 2],
                captain_authorization='D-firstmate-workflow-T260-2', depth=1, batch=1)


def digest(value):
    value = {k: v for k, v in value.items() if k != 'captain_authorization'}
    value['cohort'] = sorted(value['cohort'])
    return hashlib.sha256(json.dumps(value, sort_keys=True, separators=(',', ':')).encode()).hexdigest()


class QueueTests(unittest.TestCase):
    def setUp(self):
        tmp = tempfile.TemporaryDirectory(); self.addCleanup(tmp.cleanup)
        self.root = Path(tmp.name).resolve()
        self.state = self.root / 'state'; self.state.mkdir()
        self.ctx = dict(engine=str(self.root), state=str(self.state), target=str(self.root),
                        tasks=str(self.root / 'design/tasks'), project='', default_project='',
                        evidence_project='firstmate-workflow', repository='owner/self', base='main', external=False)
        self.pilot = A.Pilot(self.ctx)
        self.pilot._queue_service_owned = True
        self.policy = policy()
        self.calls = []
        self.remote_base = B
        self.prs = {n: dict(number=n, title=f'T-{n:03}: task', state='open', draft=False,
                    head=dict(sha=H, ref=f't-{n:03}-task', repo=dict(full_name='owner/self')),
                    base=dict(sha=B, ref='main', repo=dict(full_name='owner/self')),
                    mergeable=True, mergeable_state='behind') for n in (1, 2, 3)}
        self.pilot.task = lambda pr: f'T-{pr["number"]:03}'
        self.pilot.round_live = lambda task: False
        self.pilot.busy = lambda task: False
        self.pilot.sync_branch = lambda *a: True
        self.pilot.verdict = lambda task: {}
        self.pilot.read_head_spec = lambda pr, task: dict(id=task, depends_on=[])
        self.pilot.queue_eligible = lambda pr: (self.pilot.task(pr), '')
        self.pilot.settled_checks = lambda *a: [('ci', 'check', 1, 'success')]
        self.pilot.observe_pr = lambda *a: None
        self.pilot.emit = lambda *a, **kw: None
        self.pilot.authoritative_head = lambda task, pr: self.prs[pr['number']]['head']['sha']
        self.pilot.base_tip = lambda: self.remote_base
        self.pilot.probe = lambda argv: (self.calls.append(argv) or (0, 'HTTP/2.0 202 Accepted\n', ''))
        self.pilot.api = self.api
        self.pilot.pages = lambda endpoint: list(self.prs.values()) if endpoint == 'pulls?state=open' else []
        self.pilot.advance = lambda pr, *a: self.calls.append(('gate', pr['number']))
        self.authorize()

    def api(self, endpoint):
        if endpoint.startswith('branches/'): return dict(commit=dict(sha=self.remote_base), contexts=['ci'], checks=[])
        if endpoint.startswith('pulls?state=closed'): return []
        if endpoint.startswith('pulls/'): return copy.deepcopy(self.prs[int(endpoint.split('/')[1])])
        if '/check-runs' in endpoint: return dict(total_count=1, check_runs=[])
        if '/status' in endpoint: return dict(sha=endpoint.split('/')[1], total_count=0, statuses=[])
        raise AssertionError(endpoint)

    def authorize(self):
        p = self.state / 'autopilot/queue-policy.json'; p.write_text(json.dumps(self.policy))
        d = self.state / 'decisions'; d.mkdir(exist_ok=True)
        record = dict(id=self.policy['captain_authorization'], task='T-260', project='firstmate-workflow',
                      kind='choice', purpose='decision', chosen='A', effect='hold', effect_outcome='done',
                      details=dict(effect=dict(A='hold'), en=dict(notes=[dict(kind='note',
                          text='Queue policy SHA-256: ' + digest(self.policy))])))
        (d / (record['id'] + '.json')).write_text(json.dumps(record))
        event = dict(type='decision_made', actor='captain', project='firstmate-workflow', task='T-260',
                     data=dict(decision=record['id'], chosen='A', effect='hold', outcome='done'))
        (self.state / 'events.jsonl').write_text(json.dumps(event) + '\n')

    def test_only_front_updates_three_behind_prs(self):
        self.pilot.poll()
        updates = [c for c in self.calls if isinstance(c, list) and 'PUT' in c]
        self.assertEqual(len(updates), 1, 'only one front may request an automatic base update')
        self.assertIn('repos/owner/self/pulls/1/update-branch', updates[0])
        self.assertFalse([c for c in self.calls if isinstance(c, tuple) and c[0] == 'gate'])

    def test_mutation_legacy_all_pr_admission_is_detected_by_update_count(self):
        # Retain the entire production harness/API; only scheduling admission
        # is replaced. A removed helper/import error cannot satisfy this proof.
        def legacy(): self.pilot.queue_mode = 'off'
        with patch.object(self.pilot, 'refresh_queue', side_effect=legacy):
            self.pilot.poll()
        updates = [c for c in self.calls if isinstance(c, list) and 'PUT' in c]
        self.assertEqual(len(updates), 3)
        with self.assertRaises(AssertionError):
            self.assertEqual(len(updates), 1, 'only one front may request an automatic base update')
        self.assertIn('repos/owner/self/pulls/2/update-branch', updates[1])

    def test_poll_order_cannot_insert_priority(self):
        self.prs = dict(reversed(list(self.prs.items())))
        self.pilot.poll()
        self.assertEqual(self.pilot.data['self_queue']['front'], '1')
        self.assertEqual([self.pilot.data['self_queue']['members'][str(n)]['admission_sequence']
                          for n in (1, 2, 3)], [1, 2, 3])

    def test_base_merge_releases_once_then_updates_only_next_front(self):
        self.pilot.poll()
        self.prs[1].update(state='closed', merged_at='2026-10-09T12:00:00Z')
        event = dict(type='merged', pr=1, task='T-001')
        with (self.state / 'events.jsonl').open('a') as f: f.write(json.dumps(event) + '\n')
        self.remote_base = 'd' * 40
        for pr in self.prs.values(): pr['base']['sha'] = self.remote_base
        self.pilot.pages = lambda endpoint: [self.prs[3], self.prs[2]] if endpoint == 'pulls?state=open' else []
        self.pilot.poll(); self.pilot.poll()
        updates = [c for c in self.calls if isinstance(c, list) and 'PUT' in c]
        self.assertEqual(len(updates), 2)
        self.assertIn('repos/owner/self/pulls/2/update-branch', updates[-1])
        q = self.pilot.data['self_queue']
        self.assertEqual(q['front'], '2')
        self.assertEqual(q['counters']['completed_landings'], 1)

    def test_crash_after_update_intent_is_uncertain_without_reissue(self):
        self.pilot.poll(); q = self.pilot.data['self_queue']
        q['members']['1']['request']['state'] = 'planned'
        self.pilot.save(); self.calls.clear()
        self.pilot.poll()
        self.assertFalse(self.calls)
        self.assertEqual(q['members']['1']['state'], 'uncertain')

    def test_crash_at_card_publication_requires_reconciliation(self):
        result = self.prepared_result()
        q = self.pilot.data['self_queue']
        q['members']['1']['card_id'] = 'D-firstmate-workflow-T001-2'
        self.pilot.poll()
        self.assertEqual(q['front'], '1')
        self.assertEqual(q['members']['1']['state'], 'uncertain')
        self.assertFalse(self.calls)

    def test_pending_captain_card_retains_front_without_duplicate(self):
        self.prepared_result()
        q = self.pilot.data['self_queue']; ident = 'D-firstmate-workflow-T001-2'
        q['members']['1']['card_id'] = ident
        (self.state / 'pending').mkdir()
        (self.state / 'pending' / (ident + '.json')).write_text(json.dumps(dict(id=ident, task='T-001', kind='merge', pr=1)))
        self.pilot.advance = A.Pilot.advance.__get__(self.pilot)
        self.pilot.poll(); self.pilot.poll()
        self.assertEqual(q['front'], '1')
        self.assertEqual(q['members']['1']['state'], 'waiting-captain')
        self.assertFalse(self.calls)

    def test_missing_merge_helper_cannot_release_running_merge(self):
        self.prepared_result()
        q = self.pilot.data['self_queue']; ident = 'D-firstmate-workflow-T001-2'
        q['members']['1']['card_id'] = ident
        (self.state / 'decisions' / (ident + '.json')).write_text(json.dumps(dict(
            id=ident, task='T-001', kind='merge', pr=1, chosen='A', effect='merge', merge='running',
            expected_head=H, binding=dict(signature='0' * 64))))
        self.pilot.poll()
        self.assertEqual(q['front'], '1')
        self.assertEqual(q['members']['1']['state'], 'uncertain')
        self.assertFalse(self.calls)

    def test_authorization_requires_event_and_exact_unique_note(self):
        for change in ('event', 'duplicate', 'purpose', 'effect', 'cohort', 'pending'):
            with self.subTest(change=change):
                self.authorize(); self.calls.clear()
                path = self.state / 'decisions' / (self.policy['captain_authorization'] + '.json')
                r = json.loads(path.read_text())
                if change == 'event': (self.state / 'events.jsonl').write_text('')
                if change == 'duplicate': r['details']['en']['notes'] *= 2
                if change == 'purpose': r['purpose'] = 'dispatch'
                if change == 'effect': r['effect'] = 'dispatch'
                if change == 'cohort': r['details']['en']['notes'][0]['text'] = 'Queue policy SHA-256: ' + '0' * 64
                if change == 'pending':
                    (self.state / 'pending').mkdir(exist_ok=True)
                    (self.state / 'pending' / path.name).write_text('{}')
                path.write_text(json.dumps(r))
                self.pilot.poll()
                self.assertFalse(self.calls, 'unapproved policy must hold every landing side effect')
                if change == 'pending': (self.state / 'pending' / path.name).unlink()

    def test_unchanged_accepted_update_never_times_out_to_retry(self):
        for _ in range(25): self.pilot.poll()
        self.assertEqual(len([c for c in self.calls if isinstance(c, list) and 'PUT' in c]), 1)

    def test_local_revocation_precedes_delayed_job(self):
        self.pilot.poll()
        (self.state / 'events.jsonl').write_text('')
        observed = []
        self.pilot.consume_jobs = lambda: observed.append(self.pilot.queue_mode)
        self.pilot.local()
        self.assertEqual(observed, ['hold'])

    def test_off_keeps_legacy_all_pr_updates(self):
        self.policy['enabled'] = False; self.authorize()
        self.pilot.poll()
        self.assertEqual(len([c for c in self.calls if isinstance(c, list) and 'PUT' in c]), 3)

    def test_pending_checks_and_failed_head_are_distinct(self):
        for pr in self.prs.values(): pr['mergeable_state'] = 'clean'
        self.pilot.settled_checks = lambda *a: None
        self.pilot.poll()
        self.assertEqual(self.pilot.data['self_queue']['members']['1']['state'], 'waiting-ci')
        self.calls.clear()
        self.pilot.settled_checks = lambda *a: [('ci', 'check', 2, 'failure')]
        self.pilot.poll()
        self.assertIsNone(self.pilot.data['self_queue']['front'])
        self.pilot.poll()
        self.assertFalse(self.calls, 'unchanged failed checks cannot silently retry')

    def test_incomplete_snapshot_has_no_effect(self):
        old = self.pilot.api
        def api(endpoint):
            if endpoint == 'pulls/3': raise ValueError('incomplete')
            return old(endpoint)
        self.pilot.api = api
        self.pilot.poll()
        self.assertFalse(self.calls)

    def test_head_and_live_base_races_refuse_update(self):
        for race in ('head', 'base'):
            with self.subTest(race=race):
                self.pilot.data.pop('self_queue', None); self.calls.clear()
                old = self.pilot.api; count = [0]
                def api(endpoint):
                    value = old(endpoint)
                    if endpoint == 'pulls/1':
                        count[0] += 1
                        if race == 'head' and count[0] > 1: value['head']['sha'] = 'c' * 40
                    if endpoint == 'branches/main' and race == 'base' and count[0] > 1:
                        value['commit']['sha'] = 'd' * 40
                    return value
                self.pilot.api = api
                self.pilot.poll()
                self.assertFalse([c for c in self.calls if isinstance(c, list) and 'PUT' in c])
                self.pilot.api = old

    def test_live_owner_is_required_and_never_stolen_by_time(self):
        self.pilot._queue_service_owned = False
        self.pilot.poll()
        self.assertFalse(self.calls)
        self.assertEqual(self.pilot.queue_mode, 'hold')
        self.pilot._queue_service_owned = True
        self.pilot.poll()
        self.pilot.clock = lambda: 10 ** 12
        self.pilot.poll()
        self.assertEqual(self.pilot.data['self_queue']['front'], '1')

    def test_legacy_job_activation_is_observation_only(self):
        for state in ('running', 'consuming', 'uncertain'):
            with self.subTest(state=state):
                self.calls.clear(); self.pilot.data.pop('self_queue', None)
                self.pilot.data['jobs'] = {'old': dict(task='T-002', state=state, path='')}
                self.pilot.poll()
                self.assertFalse(self.calls)
                self.assertIsNone(self.pilot.data['self_queue']['front'])
                self.policy['enabled'] = False; self.authorize(); self.pilot.refresh_queue()
                self.assertEqual(self.pilot.queue_mode, 'drain')
                self.policy['enabled'] = True; self.authorize()
        self.pilot.data['jobs'] = {}
        self.pilot.poll()
        self.assertEqual(self.pilot.data['self_queue']['front'], '1')

    def test_disable_retains_an_uncertain_front(self):
        self.pilot.probe = lambda argv: (_ for _ in ()).throw(OSError('lost response'))
        self.pilot.poll()
        self.policy['enabled'] = False; self.authorize()
        self.pilot.poll()
        self.assertEqual(self.pilot.queue_mode, 'drain')
        self.assertEqual(self.pilot.data['self_queue']['front'], '1')
        self.assertEqual(self.pilot.data['self_queue']['members']['1']['state'], 'uncertain')

    def test_disable_returns_to_legacy_only_after_front_settles(self):
        self.pilot.poll(); self.calls.clear()
        self.policy['enabled'] = False; self.authorize()
        self.pilot.poll()
        self.assertFalse(self.calls)
        self.assertEqual(self.pilot.queue_mode, 'drain')
        self.prs[1].update(state='closed', merged_at='2026-10-09T12:00:00Z')
        with (self.state / 'events.jsonl').open('a') as f:
            f.write(json.dumps(dict(type='merged', task='T-001', pr=1)) + '\n')
        self.pilot.pages = lambda endpoint: [self.prs[2], self.prs[3]] if endpoint == 'pulls?state=open' else []
        self.pilot.poll()
        self.assertEqual(self.pilot.queue_mode, 'off')
        updates = [c for c in self.calls if isinstance(c, list) and 'PUT' in c]
        self.assertEqual(len(updates), 2)
        self.pilot.poll()
        self.assertEqual(len([c for c in self.calls if isinstance(c, list) and 'PUT' in c]), 2)

    def test_invalid_schema_repository_and_symlink_hold(self):
        self.pilot.poll(); self.calls.clear()
        for field, value in (('version', 2), ('repository', 'other/repo'), ('depth', True), ('extra', 1)):
            with self.subTest(field=field):
                p = dict(self.policy); p[field] = value
                (self.state / 'autopilot/queue-policy.json').write_text(json.dumps(p))
                self.pilot.poll()
                self.assertEqual(self.pilot.queue_mode, 'hold')
                self.assertFalse(self.calls)
        path = self.state / 'autopilot/queue-policy.json'; path.unlink()
        other = self.root / 'policy.json'; other.write_text(json.dumps(self.policy)); path.symlink_to(other)
        self.pilot.poll()
        self.assertEqual(self.pilot.queue_mode, 'hold')

    def test_unknown_queue_schema_cannot_restore_legacy_on_disable(self):
        self.pilot.poll(); self.calls.clear()
        self.pilot.data['self_queue']['version'] = 2
        self.policy['enabled'] = False; self.authorize()
        self.pilot.poll()
        self.assertEqual(self.pilot.queue_mode, 'hold')
        self.assertFalse(self.calls)

    def test_same_failed_head_needs_exact_approved_resume(self):
        import fm_autopilot_queue as Q
        for pr in self.prs.values(): pr['mergeable_state'] = 'clean'
        self.pilot.settled_checks = lambda pr, *a: [('ci', 'check', 1, 'failure' if pr['number'] == 1 else 'success')]
        self.pilot.poll(); m = self.pilot.data['self_queue']['members']['1']
        fingerprint = m['failed_fingerprint']
        self.pilot.settled_checks = lambda *a: [('ci', 'check', 2, 'success')]
        self.pilot.poll()
        self.assertEqual(m['state'], 'blocked', 'a new check identity alone is not retry authority')
        ident = 'D-firstmate-workflow-T260-3'
        note = f'Queue resume: PR 1 head {H} failed fingerprint {fingerprint}'
        record = json.loads((self.state / 'decisions' / (self.policy['captain_authorization'] + '.json')).read_text())
        record['id'] = ident; record['details']['en']['notes'] = [dict(kind='caution', text=note)]
        (self.state / 'decisions' / (ident + '.json')).write_text(json.dumps(record))
        m['resume_decision'] = ident
        self.assertFalse(Q.decision_authority(self.state, 'firstmate-workflow', ident, note))
        event = dict(type='decision_made', actor='captain', task='T-260', project='firstmate-workflow',
                     data=dict(decision=ident, chosen='A', effect='hold', outcome='done'))
        with (self.state / 'events.jsonl').open('a') as f: f.write(json.dumps(event) + '\n')
        self.pilot.poll()
        self.assertIsNone(m['failed_fingerprint'])
        self.assertEqual(m['state'], 'queued')

    def test_status_is_read_only_and_redacts_private_state(self):
        self.pilot.poll()
        (self.root / 'bin').mkdir(); (self.root / 'bin/fm-config.sh').write_text('# fixture')
        self.pilot.data['private'] = 'operator-secret'
        self.pilot.save()
        path = self.state / 'autopilot/state.json'
        before = {p: (p.read_bytes(), p.stat().st_mtime_ns) for p in self.state.rglob('*') if p.is_file()}
        env = dict(os.environ, FM_ENGINE_ROOT=str(self.root))
        command = [sys.executable, str(ROOT / 'bin/lib/fm_autopilot_queue.py'), 'status',
                   '--state', str(self.state), '--format', 'json']
        result = subprocess.run(command, env=env, capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stdout)
        self.assertNotIn('operator-secret', result.stdout)
        self.assertNotIn(str(self.root), result.stdout)
        self.assertEqual(json.loads(result.stdout)['front']['PR'], 1)
        after = {p: (p.read_bytes(), p.stat().st_mtime_ns) for p in self.state.rglob('*') if p.is_file()}
        self.assertEqual(before, after, 'status must not create files, locks or rewrite records')
        self.pilot.data['self_queue']['version'] = 2; self.pilot.save()
        result = subprocess.run(command, env=env, capture_output=True, text=True)
        self.assertEqual(result.returncode, 65)
        self.pilot.data.pop('self_queue'); self.pilot.save()
        self.assertEqual(subprocess.run(command, env=env, capture_output=True).returncode, 3)
        self.assertEqual(subprocess.run(command[:-1] + ['yaml'], env=env, capture_output=True).returncode, 64)

    def test_helper_policy_authority_rejects_forged_reference(self):
        import fm_autopilot_queue as Q
        self.assertTrue(Q.decision_authority(self.state, 'firstmate-workflow', self.policy['captain_authorization'],
                                           'Queue policy SHA-256: ' + digest(self.policy)))
        self.assertFalse(Q.decision_authority(self.state, 'firstmate-workflow', 'D-firstmate-workflow-T260-3',
                                            'Queue policy SHA-256: ' + digest(self.policy)))

    def test_captain_park_requires_separate_hold_event(self):
        import fm_autopilot_queue as Q
        ident = 'D-firstmate-workflow-T001-2'
        record = dict(id=ident, task='T-001', kind='merge', chosen='B', effect='hold', effect_outcome='done',
                      details=dict(effect=dict(B='hold')))
        path = self.state / 'decisions' / (ident + '.json'); path.write_text(json.dumps(record))
        self.assertFalse(Q.cancelled_card(self.state, 'firstmate-workflow', ident, 'T-001'))
        event = dict(type='decision_made', actor='captain', task='T-001',
                     data=dict(decision=ident, chosen='B', effect='hold', outcome='done'))
        with (self.state / 'events.jsonl').open('a') as f: f.write(json.dumps(event) + '\n')
        self.assertTrue(Q.cancelled_card(self.state, 'firstmate-workflow', ident, 'T-001'))
        record['details']['effect']['B'] = 'merge'; path.write_text(json.dumps(record))
        self.assertFalse(Q.cancelled_card(self.state, 'firstmate-workflow', ident, 'T-001'))

    def test_external_rejection_changes_no_scheduling(self):
        import fm_autopilot_queue as Q
        p, reason = Q.load_policy(self.state, 'external/repo', 'develop', 'private', True)
        self.assertIsNone(p)
        self.assertEqual(reason, 'self-strategy-not-supported')
        self.pilot.ctx['external'] = True
        self.pilot.refresh_queue()
        self.assertEqual(self.pilot.queue_mode, 'off')
        wake = next(w for w in self.pilot.data['wakes'].values() if 'self-strategy-not-supported' in w['line'])
        self.assertEqual(set(wake['summary']), {'en', 'zh-TW'})

    def prepared_result(self, code=0):
        import fm_autopilot_queue as Q
        for pr in self.prs.values(): pr['mergeable_state'] = 'clean'
        self.pilot.poll(); self.calls.clear()
        q = self.pilot.data['self_queue']
        return dict(task='T-001', pr=copy.deepcopy(self.prs[1]), kind='gate', code=code,
                    base=B, round=1, queue_binding=Q.binding(q, q['members']['1']))

    def test_delayed_generation_head_and_policy_revocation_reject_card(self):
        for changed in ('generation', 'head', 'authorization'):
            with self.subTest(changed=changed):
                self.pilot.data.pop('self_queue', None); self.authorize()
                self.prs[1]['head']['sha'] = H
                result = self.prepared_result()
                self.pilot.merge_card = lambda *a: self.calls.append(('card', a))
                if changed == 'generation': self.pilot.data['self_queue']['members']['1']['attempt_generation'] += 1
                if changed == 'head': self.prs[1]['head']['sha'] = 'c' * 40
                if changed == 'authorization': (self.state / 'events.jsonl').write_text('')
                self.pilot.job_completed(result)
                self.assertFalse(self.calls, 'stale delayed gate must never publish a new captain card')

    def test_actual_local_consumer_revalidates_revoked_authorization(self):
        result = self.prepared_result()
        path = self.state / 'autopilot/gate.json'
        path.with_suffix('.result.json').write_text(json.dumps(result))
        self.pilot.data['jobs'] = {'gate': dict(task='T-001', number=1, head=H, kind='gate',
            state='running', path=str(path), queue_binding=result['queue_binding'])}
        self.pilot.merge_card = lambda *a: self.calls.append(('card', a))
        (self.state / 'events.jsonl').write_text('')
        self.pilot.local()
        self.assertFalse(self.calls)
        self.assertEqual(self.pilot.data['jobs']['gate']['state'], 'done')

    def test_gate6_retains_front_and_launches_stock_review_continuation(self):
        result = self.prepared_result(6)
        self.pilot.start_job = lambda kind, *a, **kw: self.calls.append((kind, kw))
        self.pilot.job_completed(result)
        self.assertEqual([c[0] for c in self.calls], ['review'])
        self.assertEqual(self.pilot.data['self_queue']['front'], '1')

    def test_failed_ci_allows_an_independent_front_without_retry(self):
        for pr in self.prs.values(): pr['mergeable_state'] = 'clean'
        self.pilot.settled_checks = lambda pr, *a: [('ci', 'check', 1, 'failure' if pr['number'] == 1 else 'success')]
        self.pilot.poll()
        self.assertEqual(self.pilot.data['self_queue']['front'], '2')
        sequence = self.pilot.data['self_queue']['members']['1']['admission_sequence']
        self.pilot.poll()
        self.assertEqual(self.pilot.data['self_queue']['front'], '2')
        self.assertEqual(self.pilot.data['self_queue']['members']['1']['admission_sequence'], sequence)

    def test_duration_accounting_clamps_clock_and_deduplicates_release(self):
        import fm_autopilot_queue as Q
        self.pilot.poll(); q = self.pilot.data['self_queue']
        Q.transition(q, '1', 'waiting-captain', 'pending', 100)
        Q.transition(q, '1', 'parked', 'cancelled', 90)
        Q.release(q, '1', 90); before = copy.deepcopy(q['counters'])
        Q.release(q, '1', 200)
        self.assertEqual(q['counters'], before)
        self.assertEqual(q['counters']['captain_wait_seconds'], 0)

    def test_queue_transition_wakes_are_bilingual_and_deduplicated(self):
        self.pilot.poll(); self.pilot.poll()
        before = copy.deepcopy(self.pilot.data['wakes'])
        self.pilot.poll()
        self.assertEqual(self.pilot.data['wakes'], before)
        for wake in before.values(): self.assertEqual(set(wake['summary']), {'en', 'zh-TW'})

    def test_stock_rollout_request_answer_and_approved_pin_admission(self):
        # Complete stock engine copy: fm-decide.sh, fm-emit.sh, fm-config.sh,
        # fm_spec_pins.py, fm_ste.py, fm_gates.json, fm_lifeline.py,
        # fm_autopilot.py, fm_autopilot_loop.py, fm_autopilot_branches.py,
        # fm_autopilot_queue.py and their stock storage dependencies.
        import fm_autopilot_queue as Q
        from fm_spec_pins import Pins
        engine = self.root / 'stock'; engine.mkdir()
        shutil.copytree(ROOT / 'bin', engine / 'bin')
        shutil.copytree(ROOT / 'board', engine / 'board')
        shutil.copytree(ROOT / 'i18n', engine / 'i18n')
        tasks = engine / 'design/tasks'; tasks.mkdir(parents=True)
        for task in ('T-001', 'T-002', 'T-003', 'T-260'):
            (tasks / (task + '.json')).write_text(json.dumps(dict(id=task, title='Queue trial',
                milestone='M2', scope=['src/**'], depends_on=[])))
        (engine / 'design/design.md').write_text('Queue fixture design\n')
        (engine / 'config.yaml').write_text('project:\n  check: "true"\n')
        def git(*args):
            return subprocess.run(['git', '-C', str(engine), *args], check=True, capture_output=True, text=True).stdout.strip()
        git('init', '-q', '-b', 'main'); git('config', 'user.name', 'Queue fixture')
        git('config', 'user.email', 'queue@example.invalid'); git('add', 'bin', 'design', 'config.yaml')
        git('commit', '-qm', 'fixture approved base')
        state = engine / 'state'; state.mkdir()
        env = {k:v for k,v in os.environ.items() if not k.startswith(('FM_', 'HERDR_'))}
        env.update(HERDR_ENV='0', FM_ROOT=str(engine), FM_ENGINE_ROOT=str(engine), FM_CODE_ROOT=str(engine),
                   FIRSTMATE_CI_SESSION=str(os.getpid()), FM_PORT='0', XDG_CONFIG_HOME=str(self.root / 'credentials'))
        def command(name, *args):
            result = subprocess.run(['bash', str(engine / 'bin' / name), *args, '--repo', str(engine)],
                                    env=env, capture_output=True, text=True, timeout=30)
            self.assertEqual(result.returncode, 0, result.stderr)
            return result.stdout.strip()
        policy = self.policy.copy()
        policy['captain_authorization'] = command('fm-decide.sh', '--allocate', '--task', 'T-260')
        note = 'Queue policy SHA-256: ' + digest(policy)
        en = dict(title='Queue trial', explanation='The trial holds one front.', before='PRs advance together.',
                  after='One PR advances.', outcome='The captain keeps each merge card.',
                  intent=[dict(kind='step', text='Keep one front.')],
                  done=[dict(kind='fact', text='Intent 1: One front advances.')],
                  notes=[dict(kind='note', text=note)],
                  options={k:dict(description='Hold the trial.', pros='Keep control.', cons='Wait for review.') for k in 'ABC'})
        tw = dict(title='佇列試行', explanation='試行保留一個前端。', before='PR 同時前進。', after='一個 PR 前進。',
                  outcome='船長保留每張合併卡。', intent=[dict(kind='step', text='保留一個前端。')],
                  done=[dict(kind='fact', text='意圖 1：一個前端前進。')], notes=[dict(kind='note', text=note)],
                  options={k:dict(description='暫緩試行。', pros='保留控制。', cons='等待審查。') for k in 'ABC'})
        details = self.root / 'rollout.json'
        details.write_text(json.dumps({'en':en, 'zh-TW':tw, 'effect':dict(A='hold', B='hold', C='hold')}))
        command('fm-decide.sh', '--request', policy['captain_authorization'], '--task', 'T-260',
                '--kind', 'choice', '--purpose', 'decision', '--details', str(details))
        self.assertFalse(Q.decision_authority(state, 'firstmate-workflow', policy['captain_authorization'], note))
        with (self.root / 'board.log').open('wb') as log:
            child = A.life.start(['bun', 'run', str(engine / 'board/server.ts')], owner=os.getpid(),
                                 env=env, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=log)
            try:
                self.assertTrue(select.select([child.stdout], [], [], 30)[0], 'board must push its ready line')
                line = child.stdout.readline().decode()
                match = re.search(r'board on http://127\.0\.0\.1:([0-9]+)', line)
                self.assertIsNotNone(match, line)
                port = match[1]; url = 'http://127.0.0.1:' + port
                secret = (self.root / 'credentials/firstmate' / ('board-' + port + '.secret')).read_text().strip()
                request = urllib.request.Request(url + '/decisions', method='POST',
                    data=json.dumps(dict(id=policy['captain_authorization'], chosen='A')).encode(),
                    headers={'Content-Type':'application/json', 'Origin':url, 'Authorization':'Bearer ' + secret})
                with urllib.request.urlopen(request, timeout=30) as response: self.assertEqual(response.status, 200)
                self.assertTrue(Q.decision_authority(state, 'firstmate-workflow', policy['captain_authorization'], note))
            finally:
                child.terminate(); child.wait(timeout=15); child.stdout.close()
        (state / 'autopilot').mkdir(exist_ok=True)
        (state / 'autopilot/queue-policy.json').write_text(json.dumps(policy))
        ctx = dict(self.ctx, engine=str(engine), target=str(engine), state=str(state), tasks=str(tasks))
        pilot = A.Pilot(ctx); pilot._queue_service_owned = True
        pin_env = pilot.adoption_env()
        for task in ('T-001', 'T-002', 'T-003'):
            command('fm-emit.sh', '--actor', 'captain', '--type', 'greenlit', '--task', task,
                    '--en', 'Approve the task.', '--tw', '核准任務。')
            Pins(pin_env, task).create()
            command('fm-emit.sh', '--actor', 'firstmate', '--type', 'dispatched', '--task', task,
                    '--en', 'Dispatch the task.', '--tw', '派遣任務。')
        before = {p: p.read_bytes() for p in (state / 'pins').rglob('*.json')}
        pilot.task = self.pilot.task
        pilot.round_live = lambda task: False
        pilot.refresh_queue()
        self.assertEqual(pilot.queue_mode, 'enabled')
        for pr in self.prs.values(): self.assertEqual(pilot.queue_eligible(pr), (self.pilot.task(pr), ''))
        self.assertEqual(before, {p:p.read_bytes() for p in (state / 'pins').rglob('*.json')})


if __name__ == '__main__': unittest.main()
