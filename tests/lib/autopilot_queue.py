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

    def test_incomplete_snapshot_retains_delayed_result_until_complete_poll(self):
        result = self.prepared_result()
        path = self.state / 'autopilot/delayed.json'
        path.with_suffix('.result.json').write_text(json.dumps(result))
        job = dict(task='T-001', state='running', path=str(path), queue_binding=result['queue_binding'])
        self.pilot.data['jobs']['delayed'] = job
        self.pilot.merge_card = lambda *a: self.calls.append(('card', a))
        old = self.pilot.api
        def incomplete(endpoint):
            if endpoint == 'pulls/3': raise ValueError('incomplete cohort')
            return old(endpoint)
        self.pilot.api = incomplete
        self.pilot.poll(); self.pilot.consume_jobs()
        self.assertFalse(self.calls, 'an incomplete cohort must block a delayed card')
        self.assertEqual(job['state'], 'running', 'the result must remain reconcilable')
        self.pilot.api = old
        self.pilot.poll(); self.calls.clear()
        self.pilot.consume_jobs(); self.pilot.consume_jobs()
        self.assertEqual([c[0] for c in self.calls], ['card'])
        self.assertEqual(job['state'], 'done')

    def test_retained_front_recovers_temporary_worker_draft_and_owned_job_holds(self):
        self.prepared_result()
        q = self.pilot.data['self_queue']; m = q['members']['1']
        for reason in ('live-worker', 'draft', 'approved-pin-unavailable', 'dependencies-unresolved'):
            self.pilot.queue_eligible = lambda pr: (self.pilot.task(pr), reason if pr['number'] == 1 else '')
            self.pilot.poll()
            self.assertEqual(m['state'], 'blocked')
            self.pilot.queue_eligible = lambda pr: (self.pilot.task(pr), '')
            self.pilot.poll()
            self.assertTrue(self.pilot.queue_guard(self.prs[1]), 'cleared eligibility must resume the retained front')
        import fm_autopilot_queue as Q
        m['jobs'] = ['e' * 32]; self.pilot.data['jobs']['e' * 32] = dict(state='uncertain', queue_binding=Q.binding(q, m))
        self.pilot.poll(); self.assertEqual(m['state'], 'uncertain')
        self.pilot.data['jobs']['e' * 32]['state'] = 'done'
        self.pilot.poll()
        self.assertTrue(self.pilot.queue_guard(self.prs[1]), 'reconciled owned job must resume the retained front')

    def test_legacy_update_activation_restart_disable_preserves_receipts(self):
        for outcome in ('accepted', 'uncertain'):
            for phase in ('activation', 'restart', 'disable'):
                with self.subTest(outcome=outcome, phase=phase):
                    self.pilot.data.pop('self_queue', None); self.authorize(); self.calls.clear()
                    receipt = dict(head=H, seq=1, state=outcome)
                    self.pilot.data['updates'] = {'2': receipt.copy()}
                    self.pilot.save()
                    if phase == 'restart': self.pilot.data = json.loads(self.pilot.path.read_text())
                    self.pilot.poll()
                    if phase == 'disable':
                        (self.state / 'autopilot/queue-policy.json').write_text(json.dumps(dict(self.policy, enabled=False)))
                        self.pilot.poll()
                    self.assertFalse(self.calls, 'legacy update receipts must drain before new mutations')
                    self.assertIsNone(self.pilot.data['self_queue']['front'])
                    self.assertEqual(self.pilot.data['updates']['2'], receipt)

    def use_real_advance(self):
        from fm_autopilot_loop import MechanicalLoop
        self.pilot.advance = MechanicalLoop.advance.__get__(self.pilot)
        self.pilot.landed = lambda *a: False
        self.pilot.start_job = lambda kind, *a, **kw: self.calls.append((kind, kw))

    def test_approved_resume_relaunches_actual_advance_once(self):
        self.use_real_advance()
        for pr in self.prs.values(): pr['mergeable_state'] = 'clean'
        self.pilot.poll()
        self.assertEqual(len(self.calls), 1)
        m = self.pilot.data['self_queue']['members']['1']; m['failed_fingerprint'] = 'failed-gate'
        ident = 'D-firstmate-workflow-T260-3'
        record = json.loads((self.state / 'decisions' / (self.policy['captain_authorization'] + '.json')).read_text())
        record['id'] = ident
        record['details']['en']['notes'] = [dict(kind='note', text=f'Queue resume: PR 1 head {H} failed fingerprint failed-gate')]
        (self.state / 'decisions' / (ident + '.json')).write_text(json.dumps(record))
        with (self.state / 'events.jsonl').open('a') as f:
            f.write(json.dumps(dict(type='decision_made', actor='captain', project='firstmate-workflow', task='T-260',
                data=dict(decision=ident, chosen='A', effect='hold', outcome='done'))) + '\n')
        self.pilot.poll(); self.pilot.poll()
        self.assertEqual(len(self.calls), 2, 'an approved new attempt must launch once despite identical legacy inputs')

    def test_off_advance_fingerprint_retains_exact_legacy_inputs(self):
        self.use_real_advance()
        (self.state / 'autopilot/queue-policy.json').unlink()
        for pr in self.prs.values(): pr['mergeable_state'] = 'clean'
        self.pilot.poll()
        expected = A.key([1, H, B, [('ci', 'check', 1, 'success')], None, {}, 0])
        self.assertEqual(self.pilot.data['advanced']['1']['fingerprint'], expected)
        self.pilot.poll(); self.assertEqual(len(self.calls), 3)

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
        self.assertNotIn('self_queue', self.pilot.data)
        self.pilot._queue_service_owned = True
        self.pilot.poll()
        retained = copy.deepcopy(self.pilot.data['self_queue'])
        self.pilot._queue_service_owned = False
        self.pilot.refresh_queue()
        self.assertEqual(self.pilot.queue_mode, 'hold')
        self.assertEqual(self.pilot.data['self_queue'], retained)
        self.pilot.queue_snapshot({}, B)
        self.assertEqual(self.pilot.queue_mode, 'hold')
        self.pilot._queue_service_owned = True
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

    def stock_fixture(self, dependencies=None):
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
                milestone='M2', scope=['src/**'], depends_on=(dependencies or {}).get(task, []))))
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
            repo = ['--repo', str(engine)] if name == 'fm-decide.sh' else []
            result = subprocess.run(['bash', str(engine / 'bin' / name), *args, *repo],
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
        # Seed real local immutable head objects; task resolution and worker
        # ownership readers remain production methods in this fixture.
        self.remote_base = git('rev-parse', 'HEAD')
        for pr in self.prs.values():
            pr['head']['sha'] = self.remote_base
            pr['base']['sha'] = self.remote_base
        pilot.refresh_queue()
        self.assertEqual(pilot.queue_mode, 'enabled')
        self.assertEqual(before, {p:p.read_bytes() for p in (state / 'pins').rglob('*.json')})
        return pilot, state, command, git, before

    def test_stock_rollout_request_answer_and_approved_pin_admission(self):
        pilot, state, command, git, before = self.stock_fixture()
        for pr in self.prs.values(): self.assertEqual(pilot.queue_eligible(pr), (self.pilot.task(pr), ''))

    def stock_snapshots(self, pilot):
        # Real admission, advancement, checks and request reconciliation. Only
        # remote/process/git transports and the child launcher are fixtures.
        self.stock_calls = []
        pilot.api = self.api
        pilot.start_job = lambda kind, *a, **kw: self.stock_calls.append((kind, kw))
        snapshots = {}
        for n, pr in self.prs.items():
            pr['mergeable_state'] = 'clean'
            runs = [dict(id=1, name='ci', head_sha=pr['head']['sha'], status='completed', conclusion='success')]
            snapshots[str(n)] = (copy.deepcopy(pr), [], [], runs, [])
        return snapshots

    def stock_prepare(self, pilot, snapshots):
        pilot.refresh_queue(); pilot._queue_snapshot_ready = False
        pilot.queue_snapshot(snapshots, self.remote_base)
        pilot.save()

    def append_event(self, state, **row):
        with (state / 'events.jsonl').open('a') as f: f.write(json.dumps(row) + '\n')

    def test_production_worker_draft_dependency_cycle_eligibility_and_recovery(self):
        pilot, state, command, git, pins = self.stock_fixture({'T-002':['T-001'], 'T-003':['T-003']})
        snapshots = self.stock_snapshots(pilot)
        self.stock_prepare(pilot, snapshots)
        q = pilot.data['self_queue']; m = q['members']['1']
        self.assertEqual(q['members']['2']['reason'], 'dependencies-unresolved')
        self.assertEqual(q['members']['3']['reason'], 'dependencies-unresolved', 'self cycle must remain blocked')
        # The worker restriction uses the actual stock live-round reader.
        with patch('fm_concurrent.live_rounds', return_value=[dict(task='T-001')]):
            self.stock_prepare(pilot, snapshots)
        self.assertEqual(m['reason'], 'live-worker')
        self.stock_prepare(pilot, snapshots)
        self.assertEqual(m['state'], 'front')
        snapshots['1'][0]['draft'] = True
        self.stock_prepare(pilot, snapshots); self.assertEqual(m['reason'], 'draft')
        snapshots['1'][0]['draft'] = False
        self.stock_prepare(pilot, snapshots)
        self.assertTrue(pilot.queue_guard(snapshots['1'][0]))
        snapshots['1'][0]['base']['ref'] = 't-002-task'
        self.stock_prepare(pilot, snapshots); self.assertEqual(m['reason'], 'stack-on-task')
        snapshots['1'][0]['base']['ref'] = 'main'
        self.stock_prepare(pilot, snapshots); self.assertEqual(m['state'], 'front')
        self.append_event(state, type='merged', task='T-001', pr=1)
        self.stock_prepare(pilot, snapshots)
        self.assertEqual(q['members']['2']['state'], 'queued')
        self.assertEqual(q['members']['3']['state'], 'blocked')
        self.assertEqual(pins, {p:p.read_bytes() for p in (state / 'pins').rglob('*.json')})

    def stock_update_graph(self, pilot, git):
        # Actual disposable commit graph proves ancestry and patch equivalence.
        engine = Path(pilot.ctx['target']); (engine / 'src').mkdir()
        git('checkout', '-qb', 'fixture-task')
        (engine / 'src/task').write_text('task patch\n')
        git('add', 'src'); git('commit', '-qm', 'task patch'); head = git('rev-parse', 'HEAD')
        git('checkout', '-q', 'main')
        (engine / 'base.txt').write_text('base advancement\n')
        git('add', 'base.txt'); git('commit', '-qm', 'base advancement'); base = git('rev-parse', 'HEAD')
        git('checkout', '-q', 'fixture-task'); git('merge', '--no-ff', '-qm', 'base catchup', 'main')
        updated = git('rev-parse', 'HEAD')
        (engine / 'src/task').write_text('unrelated worker patch\n')
        git('add', 'src'); git('commit', '-qm', 'worker push'); worker = git('rev-parse', 'HEAD')
        git('checkout', '-q', 'main')
        self.remote_base = base
        for pr in self.prs.values(): pr['base']['sha'] = base; pr['head']['sha'] = head
        # Mock only GitHub fetch/view; all local object/ancestry commands run.
        def command(argv, **kwargs):
            if argv[0] == 'git' and 'fetch' in argv:
                source = argv[-1]
                if source.startswith('+refs/pull/'):
                    ref = source.split(':', 1)[1]
                    git('update-ref', ref, self.prs[int(source.split('/')[2])]['head']['sha'])
                return ''
            if argv[0] == 'gh':
                pr = self.prs[int(argv[argv.index('view') + 1])]
                return json.dumps(dict(headRefOid=pr['head']['sha'], baseRefOid=base, state='OPEN'))
            if argv[0] == 'bash': return self.prs[1]['head']['sha']
            result = subprocess.run(argv, check=True, capture_output=True, text=True)
            return result.stdout
        pilot.command = command
        return head, base, updated, worker

    def test_production_update_ancestry_recovery_unrelated_push_and_park_during_update(self):
        pilot, state, command, git, pins = self.stock_fixture()
        head, base, updated, worker = self.stock_update_graph(pilot, git)
        snapshots = self.stock_snapshots(pilot); self.stock_prepare(pilot, snapshots)
        # Issue through the real update entry point, with only HTTP mocked.
        snapshots['1'][0]['mergeable_state'] = 'behind'; self.prs[1]['mergeable_state'] = 'behind'
        pilot.probe = lambda argv: (self.stock_calls.append(argv) or (0, 'HTTP/2.0 202 Accepted\n', ''))
        pilot.update_branch(snapshots['1'][0], 'T-001')
        m = pilot.data['self_queue']['members']['1']; request = m['request']
        self.assertEqual(request['state'], 'accepted')
        # Restore real git probe. Missing fetched proof holds; retry can settle.
        pilot.probe = A.Pilot.probe.__get__(pilot)
        self.prs[1]['head']['sha'] = updated
        snapshots = self.stock_snapshots(pilot)
        real_command = pilot.command
        def unavailable(argv, **kwargs): raise ValueError('temporary fetch unavailable')
        pilot.command = unavailable
        self.stock_prepare(pilot, snapshots)
        self.assertEqual(m['reason'], 'update-ancestry-unreconciled')
        pilot.command = real_command
        self.stock_prepare(pilot, snapshots)
        self.assertEqual(request['outcome'], 'verified-base-update')
        self.assertTrue(pilot.queue_guard(self.prs[1]), 'recovered update proof resumes its front')
        # An accepted request may reconcile before an explicit park releases it.
        m.update(head=head, request=dict(request, state='accepted', outcome=None))
        self.append_event(state, type='parked', task='T-001')
        self.stock_prepare(pilot, snapshots)
        self.assertEqual(m['request']['state'], 'settled', 'park must not prevent update reconciliation')
        self.assertEqual(m['state'], 'parked')
        # Unrelated worker commit invalidates readiness, never counts as an update.
        self.append_event(state, type='unparked', task='T-001')
        q = pilot.data['self_queue']; q['front'] = '1'
        for n, member in q['members'].items():
            if n != '1' and member['state'] == 'front': member.update(state='queued', reason='waiting-for-front')
        m.update(head=head, state='updating', request=dict(request, state='accepted', outcome=None))
        self.prs[1]['head']['sha'] = worker; snapshots = self.stock_snapshots(pilot)
        old_request = m['request']; self.stock_prepare(pilot, snapshots)
        self.assertEqual(old_request['outcome'], 'candidate-invalidated')
        self.assertEqual(m['head'], worker)
        self.assertEqual(pins, {p:p.read_bytes() for p in (state / 'pins').rglob('*.json')})

    def stock_card(self, state, *, pending=True, chosen='B', outcome=None, effect='hold', event=True):
        ident = 'D-firstmate-workflow-T001-8'
        # Stock legacy self records omit project; readers retain that provenance.
        record = dict(id=ident, task='T-001', kind='merge', pr=1,
                      expected_head=self.prs[1]['head']['sha'], binding=dict(signature='bound'),
                      chosen=chosen, effect=effect, effect_outcome='done', details=dict(effect={chosen:effect}))
        if outcome: record['merge'] = outcome
        folder = state / ('pending' if pending else 'decisions'); folder.mkdir(exist_ok=True)
        path = folder / (ident + '.json'); path.write_text(json.dumps(record))
        if event:
            self.append_event(state, type='decision_made', actor='captain', task='T-001', project='firstmate-workflow',
                              data=dict(decision=ident, chosen=chosen, effect=effect, outcome='done'))
        return ident, path

    def test_production_captain_park_separate_cancellation_race_matrix(self):
        pilot, state, command, git, pins = self.stock_fixture()
        snapshots = self.stock_snapshots(pilot); self.stock_prepare(pilot, snapshots)
        baseline = copy.deepcopy(pilot.data)
        for case in ('parking-alone', 'B-hold', 'C-hold', 'custom-merge', 'missing-event', 'pending-race', 'competing-owner'):
            with self.subTest(case=case):
                pilot.data = copy.deepcopy(baseline)
                for folder in ('pending', 'merging'):
                    shutil.rmtree(state / folder, ignore_errors=True)
                path = state / 'decisions/D-firstmate-workflow-T001-8.json'; path.unlink(missing_ok=True)
                events = [r for r in (state / 'events.jsonl').read_text().splitlines()
                          if json.loads(r).get('task') != 'T-001' or json.loads(r).get('type') not in ('parked','decision_made')]
                (state / 'events.jsonl').write_text('\n'.join(events) + '\n')
                self.append_event(state, type='parked', task='T-001')
                ident, path = self.stock_card(state, pending=case in ('parking-alone','pending-race'),
                    chosen='C' if case == 'C-hold' else 'B', effect='merge' if case == 'custom-merge' else 'hold',
                    event=case != 'missing-event')
                if case == 'pending-race':
                    (state / 'decisions' / path.name).write_bytes(path.read_bytes())
                if case == 'competing-owner':
                    (state / 'merging').mkdir(); (state / 'merging/other.json').write_text('{}')
                m = pilot.data['self_queue']['members']['1']; m['card_id'] = ident
                retained = path.read_bytes()
                self.stock_prepare(pilot, snapshots)
                if case in ('B-hold','C-hold'):
                    self.assertEqual(m['state'], 'parked'); self.assertNotEqual(pilot.data['self_queue']['front'], '1')
                else:
                    self.assertEqual(pilot.data['self_queue']['front'], '1', 'unreconciled card cannot release reservation')
                self.assertEqual(path.read_bytes(), retained)
        self.assertEqual(pins, {p:p.read_bytes() for p in (state / 'pins').rglob('*.json')})

    def test_production_upgrade_drain_cards_jobs_owner_receipts_restart_and_disable(self):
        pilot, state, command, git, pins = self.stock_fixture()
        snapshots = self.stock_snapshots(pilot); baseline = copy.deepcopy(pilot.data)
        initial_events = (state / 'events.jsonl').read_bytes()
        for case in ('pending-card', 'held-card', 'running-answer', 'uncertain-answer', 'owner-receipt', 'legacy-running', 'legacy-consuming', 'legacy-uncertain'):
            for disabled in (False, True):
                with self.subTest(case=case, disabled=disabled):
                    pilot.data = copy.deepcopy(baseline)
                    for folder in ('pending','merging'): shutil.rmtree(state / folder, ignore_errors=True)
                    (state / 'decisions/D-firstmate-workflow-T001-8.json').unlink(missing_ok=True)
                    (state / 'events.jsonl').write_bytes(initial_events)
                    if case == 'owner-receipt':
                        (state / 'merging').mkdir()
                        (state / 'merging/_default.json').write_text(json.dumps(dict(
                            decision='D-firstmate-workflow-T001-8', owner='retained-owner', pid=12345)))
                        owner_bytes = (state / 'merging/_default.json').read_bytes()
                    elif case.startswith('legacy-'):
                        pilot.data['jobs']['d' * 32] = dict(kind='gate', task='T-001', state=case.removeprefix('legacy-'), path='')
                    else:
                        ident, path = self.stock_card(state, pending=case == 'pending-card',
                            chosen='B' if case == 'held-card' else 'A', effect='hold' if case == 'held-card' else 'merge',
                            outcome='running' if case == 'running-answer' else None)
                        retained = path.read_bytes()
                        if case == 'running-answer':
                            (state / 'merging').mkdir(); (state / 'merging/_default.json').write_text('{}')
                    self.stock_prepare(pilot, snapshots)
                    if case == 'held-card': self.assertEqual(pilot.data['self_queue']['front'], '1')
                    else: self.assertIsNone(pilot.data['self_queue']['front'], 'unresolved upgrade must stay observation-only')
                    pilot.save()
                    restarted = A.Pilot(pilot.ctx); restarted._queue_service_owned = True
                    restarted.api = self.api
                    self.assertEqual(restarted.data['self_queue'], pilot.data['self_queue'])
                    if case == 'owner-receipt':
                        self.assertEqual((state / 'merging/_default.json').read_bytes(), owner_bytes)
                    if disabled:
                        (state / 'autopilot/queue-policy.json').write_text(json.dumps(dict(self.policy, enabled=False)))
                        # Stock fixture has a stock-allocated id rather than self.policy's id;
                        # off policy needs no activation authorization.
                        restarted.refresh_queue()
                        self.assertIn(restarted.queue_mode, ('drain','off'))
                    if case != 'held-card':
                        self.assertFalse(self.stock_calls)
                        if case == 'owner-receipt': shutil.rmtree(state / 'merging')
                        elif case.startswith('legacy-'): restarted.data['jobs']['d' * 32]['state'] = 'done'
                        else:
                            self.assertEqual(path.read_bytes(), retained)
                            if path.parent.name == 'pending':
                                answer = json.loads(path.read_text()); path.unlink()
                                answer.update(chosen='B', effect='hold', details=dict(effect=dict(B='hold')))
                                (state / 'decisions' / path.name).write_text(json.dumps(answer))
                                self.append_event(state, type='decision_made', actor='captain', task='T-001',
                                    project='firstmate-workflow', data=dict(decision=ident, chosen='B', effect='hold', outcome='done'))
                            else:
                                answer = json.loads(path.read_text()); answer.update(merge='failed')
                                path.write_text(json.dumps(answer))
                                self.append_event(state, type='decision_made', actor='captain', task='T-001',
                                    project='firstmate-workflow', data=dict(decision=ident, chosen='A', effect='merge', merge='failed', outcome='failed'))
                            shutil.rmtree(state / 'merging', ignore_errors=True)
                        restarted.refresh_queue()
                        restarted.queue_snapshot(snapshots, self.remote_base)
                        if disabled:
                            restarted.refresh_queue(); self.assertEqual(restarted.queue_mode, 'off')
                        else: self.assertEqual(restarted.data['self_queue']['front'], '1')
                    self.assertEqual(pins, {p:p.read_bytes() for p in (state / 'pins').rglob('*.json')})
                    self.assertTrue((state / 'events.jsonl').read_bytes().startswith(initial_events))
                    # Restore the genuine stock-approved policy for the next case.
                    policy_path = state / 'autopilot/queue-policy.json'
                    actual = json.loads(policy_path.read_text()); actual['enabled'] = True
                    actual['captain_authorization'] = next(p.stem for p in (state / 'decisions').glob('*T260-*.json'))
                    policy_path.write_text(json.dumps(actual))

    def test_production_legacy_update_receipts_reconcile_ancestry_restart_and_disable(self):
        pilot, state, command, git, pins = self.stock_fixture()
        head, base, updated, worker = self.stock_update_graph(pilot, git)
        snapshots = self.stock_snapshots(pilot)
        receipt = dict(head=head, seq=7)
        pilot.data['updates']['2'] = receipt.copy()
        self.stock_prepare(pilot, snapshots)
        self.assertIsNone(pilot.data['self_queue']['front'])
        pilot.save(); baseline = copy.deepcopy(pilot.data)
        policy_path = state / 'autopilot/queue-policy.json'; approved_policy = policy_path.read_bytes()
        for disabled in (False, True):
            with self.subTest(disabled=disabled):
                pilot.data = copy.deepcopy(baseline)
                policy_path.write_bytes(approved_policy)
                pilot.save()
                # Reload from durable state, retaining the real stock methods.
                restarted = A.Pilot(pilot.ctx); restarted._queue_service_owned = True
                restarted.command = pilot.command; restarted.api = self.api
                if disabled:
                    value = json.loads(approved_policy); value['enabled'] = False
                    policy_path.write_text(json.dumps(value))
                restarted.refresh_queue()
                self.assertIn(restarted.queue_mode, ('enabled','drain'))
                # Same-H polls and unrelated pushes cannot settle the legacy receipt.
                self.prs[2]['head']['sha'] = worker
                changed = self.stock_snapshots(restarted)
                self.stock_prepare(restarted, changed)
                self.assertIsNone(restarted.data['self_queue']['front'])
                self.prs[2]['head']['sha'] = updated
                changed = self.stock_snapshots(restarted)
                self.stock_prepare(restarted, changed)
                self.assertEqual(restarted.data['updates']['2'], receipt)
                self.assertIn('legacy-update:' + A.key(['2',receipt]), restarted.data['self_queue']['accounted'])
                if disabled:
                    restarted.refresh_queue(); self.assertEqual(restarted.queue_mode, 'off')
                    prior = copy.deepcopy(restarted.data['self_queue'])
                    restarted.refresh_queue(); self.assertEqual(restarted.data['self_queue'], prior)
                else: self.assertEqual(restarted.data['self_queue']['front'], '1')
                self.assertFalse(self.stock_calls)
        self.assertEqual(pins, {p:p.read_bytes() for p in (state / 'pins').rglob('*.json')})

    def test_activation_completed_legacy_result_is_observed_without_stale_continuation(self):
        for pr in self.prs.values(): pr['mergeable_state'] = 'clean'
        path = self.state / 'autopilot/legacy.json'
        path.with_suffix('.result.json').write_text(json.dumps(dict(kind='gate', task='T-002',
            pr=self.prs[2], code=0, base=B, round=1)))
        job = dict(kind='gate', task='T-002', state='running', path=str(path))
        self.pilot.data['jobs']['f' * 32] = job
        self.pilot.merge_card = lambda *a: self.calls.append(('card', a))
        self.pilot.poll(); self.pilot.consume_jobs()
        self.assertEqual(job['state'], 'done', 'known legacy results must drain even before queue admission')
        self.assertFalse(self.calls, 'legacy drain cannot publish a stale nonfront card')
        self.pilot.poll()
        self.assertEqual(self.pilot.data['self_queue']['front'], '1')

    def test_production_live_t220_keeper_retains_front_and_can_advance(self):
        pilot, state, command, git, pins = self.stock_fixture()
        snapshots = self.stock_snapshots(pilot); self.stock_prepare(pilot, snapshots)
        ident, path = self.stock_card(state, pending=False, chosen='A', effect='merge', outcome='running')
        retained = path.read_bytes()
        m = pilot.data['self_queue']['members']['1']; m['card_id'] = ident
        (state / 'merging').mkdir()
        marker = dict(decision=ident, task='T-001', pr=1, pid=12345, started='fixture start')
        (state / 'merging/_default.json').write_text(json.dumps(marker))
        def process_transport(argv):
            if argv[0] == 'ps':
                if argv[-1] == 'lstart=': return 'fixture start'
                return ('python /engine/bin/lib/fm_lifeline.py keep --pid 23456 -- '
                        '/engine/bin/fm-merge.sh --pr 1 --task T-001 --expected-head ' + self.prs[1]['head']['sha'] + ' --bound-signature bound')
            return ''
        pilot.checked = process_transport
        pilot.command = lambda argv, **kw: self.prs[1]['head']['sha'] if argv[0] == 'bash' else self.remote_base
        with patch('fm_autopilot.life.ProcessExit') as owner:
            self.stock_prepare(pilot, snapshots)
            self.assertTrue(pilot.queue_carry_active('T-001', self.prs[1]))
            self.assertEqual(m['state'], 'merging')
            marker['task'] = 'T-002'
            (state / 'merging/_default.json').write_text(json.dumps(marker))
            self.stock_prepare(pilot, snapshots)
            self.assertEqual(m['reason'], 'merge-helper-owner-unreconciled')
            marker['task'] = 'T-001'
            (state / 'merging/_default.json').write_text(json.dumps(marker))
            self.stock_prepare(pilot, snapshots)
            self.assertEqual(m['state'], 'merging', 'recovered bound merge ownership resumes the retained front')
            self.assertTrue(pilot.queue_guard(self.prs[1]))
            from fm_concurrent import merge_blocker
            self.assertTrue(merge_blocker(state, pilot.ctx['project']), 'the carry test must exercise an occupied merge slot')
            pilot.advance(self.prs[1], snapshots['1'][3], [])
            self.assertEqual([c[0] for c in self.stock_calls], ['gate'], 'same-front carry must not deadlock behind the merge slot')
            owner.assert_called_with(23456)
        marker['task'] = 'T-002'
        (state / 'merging/_default.json').write_text(json.dumps(marker))
        self.assertFalse(pilot.queue_carry_active('T-001', self.prs[1]), 'a competing owner never grants front carry')
        self.assertEqual(path.read_bytes(), retained)

    def test_production_wrong_task_project_purpose_and_replaced_authorization(self):
        pilot, state, command, git, pins = self.stock_fixture()
        snapshots = self.stock_snapshots(pilot); self.stock_prepare(pilot, snapshots)
        import fm_autopilot_queue as Q
        q = pilot.data['self_queue']; result = dict(kind='gate', task='T-001', pr=self.prs[1], code=0,
                                                  base=B, round=1, queue_binding=Q.binding(q,q['members']['1']))
        policy_path = state / 'autopilot/queue-policy.json'
        authority = json.loads(policy_path.read_text())['captain_authorization']
        path = state / 'decisions' / (authority + '.json'); original = path.read_bytes()
        events = (state / 'events.jsonl').read_bytes()
        pilot.merge_card = lambda *a: self.stock_calls.append(('card', a))
        for field, value in (('task','T-001'), ('project','external'), ('purpose','dispatch'), ('chosen','B')):
            record = json.loads(original); record[field] = value; path.write_text(json.dumps(record))
            pilot.job_completed(result)
            self.assertFalse(self.stock_calls, 'changed rollout record cannot authorize delayed continuation')
        path.write_bytes(original)
        self.append_event(state, type='decision_made', actor='captain', task='T-260', project='firstmate-workflow',
                          data=dict(decision=authority, chosen='B', effect='hold', outcome='done'))
        pilot.job_completed(result)
        self.assertFalse(self.stock_calls, 'a replaced canonical answer revokes the retained authority')
        (state / 'events.jsonl').write_bytes(events)
        pilot.refresh_queue(); pilot.job_completed(result)
        self.assertEqual([c[0] for c in self.stock_calls], ['card'])
        self.assertEqual(pins, {p:p.read_bytes() for p in (state / 'pins').rglob('*.json')})


if __name__ == '__main__': unittest.main()
