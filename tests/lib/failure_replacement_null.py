"""Nullable writer compatibility: retained history is data, never authorization.

Historical proof: invoke this complete harness with --historical; mutation proof:
--presence-mutation. Both must fail test_nullable_choice_eligibility at its named
behavioral assertion. Neither mode changes the checkout or stored history.
"""
import os
os.environ['HERDR_ENV'] = '0'
import sys
sys.dont_write_bytecode = True
import copy
import hashlib
import inspect
import json
from pathlib import Path
import subprocess
import unittest
from unittest.mock import patch

# The genuine owner consumes the root argv before importing production modules.
import autopilot_loop as fixture
import autopilot_merge_path as merge_fixture
import fm_autopilot_loop as runtime

KEYS = ('merge', 'merged', 'merge_settled', 'merge_reason', 'merge_started', 'binding')
VALUES = ('running', 'failed', 'merged', {'signature': 'malformed'}, '', [], {}, False, 0)
HEAD, PR, CHECKS = fixture.HEAD, fixture.PR, fixture.CHECKS


# Reusing helpers without inheriting either owner's unrelated suite.
class NullableHistory(unittest.TestCase):
    setUp = fixture.LoopTests.setUp
    record_job = fixture.LoopTests.record_job
    command = fixture.LoopTests.command
    probe = fixture.LoopTests.probe
    branch_setup = fixture.BranchFixture.branch_setup
    branch_probe = fixture.BranchFixture.branch_probe
    gate_result = fixture.LoopTests.gate_result
    gates = fixture.LoopTests.gates
    def failed_history(self, external=False):
        fixture.LoopTests.failed_history(self, external=external)
        self.write_choice(self.choice(), dict(decision='D-alpha-T001-3', chosen='A', outcome='recorded'))
        self.event_bytes = self.events.read_bytes()

    current_ready = fixture.LoopTests.current_ready
    replacement_details = fixture.LoopTests.replacement_details
    complete_gate_receipt = fixture.LoopTests.complete_gate_receipt
    assert_history_preserved = fixture.LoopTests.assert_history_preserved
    ordinary_fingerprint = fixture.LoopTests.ordinary_fingerprint
    poll = merge_fixture.MergePath.poll

    def choice(self, purpose='repin', kind='choice', number=3):
        ident = f'D-alpha-T001-{number}'
        # board/server.ts answered-record shape; private production IDs omitted.
        record = dict(id=ident, chosen='A', purpose=purpose,
            expected_head=None, binding=None, task='T-001', pr=None, kind=kind,
            project='alpha', note='', ts='2026-01-01T00:00:02.123Z',
            identity='decision:' + ident, merge=None, effect=None,
            effect_outcome='recorded', details=merge_fixture.card())
        if kind is None: record.pop('kind')
        return record

    def write_choice(self, record, data=None):
        folder = self.state / 'decisions'; folder.mkdir(exist_ok=True)
        path = folder / (record['id'] + '.json')
        path.write_text(json.dumps(record) + '\n')
        if data is not None:
            with (self.state / 'events.jsonl').open('a') as stream:
                stream.write(json.dumps(dict(type='decision_made', actor='captain',
                    project='alpha', task='T-001', ts=record['ts'], data=data)) + '\n')
        return path

    def snapshot(self):
        return {str(p.relative_to(self.state)): p.read_bytes()
                for p in self.state.rglob('*') if p.is_file() and
                (p.parts[-2] == 'decisions' or p.name == 'events.jsonl'
                 or 'pins' in p.parts or 'evidence' in p.parts)}

    def assert_snapshot(self, before):
        for name, content in before.items():
            self.assertEqual((self.state / name).read_bytes(), content, name)

    def eligible(self):
        return self.pilot.failed_card_evidence('T-001', PR)

    def test_nullable_choice_eligibility(self):
        self.write_choice(self.choice())
        before = self.snapshot()
        self.assertEqual(self.eligible(), ([], ''), 'nullable-choice eligibility')
        self.assert_snapshot(before)

    def test_canonical_choice_repin_dispatch_advance_and_merge_turn(self):
        for purpose, kind in (('choice', 'choice'), ('repin', 'choice'),
                              ('dispatch', 'choice'), ('dispatch', None)):
            with self.subTest(purpose=purpose, kind=kind):
                self.write_choice(self.choice(purpose, kind))
                before = self.snapshot()
                self.pilot.data['advanced'] = {}; self.calls.clear()
                self.poll()
                self.assertEqual(len(self.gates()), 1)
                self.assert_snapshot(before)

    def test_ordinary_nullable_dispatch_requests_new_unanswered_card(self):
        record = self.choice('dispatch', number=2)
        self.write_choice(record)
        before = self.snapshot()
        self.poll(); self.gate_result(0); self.gate_result(0)
        requests = [c[1] for c in self.calls if c[0] == 'command' and '--request' in c[1]]
        self.assertEqual(len(requests), 1)
        self.assertEqual(requests[0][requests[0].index('--expected-head') + 1], HEAD)
        self.assert_snapshot(before)

    def test_pending_success_unknown_and_same_failed_head_hold(self):
        self.failed_history()
        for change, reason in ((dict(expected_head=HEAD), 'same failed head'),
                (dict(merge='merged'), 'final or unknown answer'),
                (dict(merge='unknown'), 'final or unknown answer'),
                (dict(binding=False), 'unverified old readiness')):
            with self.subTest(change=change):
                self.old_path.write_text(json.dumps(dict(self.old, **change)))
                before = self.snapshot()
                self.assertEqual(self.eligible()[1], reason)
                self.assert_snapshot(before)
        self.old_path.write_bytes(self.old_bytes)
        pending = self.state / 'pending'; pending.mkdir()
        (pending / self.old_path.name).write_bytes(self.old_bytes)
        self.assertEqual(self.eligible()[1], 'outstanding card')

    def test_record_and_event_complete_nonnull_matrix(self):
        path = self.write_choice(self.choice())
        events = self.state / 'events.jsonl'
        for kind in ('choice', None):
            base = self.choice('dispatch', kind)
            for target in ('record', 'event'):
                for key in KEYS:
                    for present, value in [(False, None), (True, None)] + [(True, v) for v in VALUES]:
                        with self.subTest(kind=kind, target=target, key=key, present=present, value=value):
                            record = copy.deepcopy(base)
                            data = dict(decision=base['id'], chosen='A', outcome='recorded')
                            subject = record if target == 'record' else data
                            subject.pop(key, None)
                            if present: subject[key] = value
                            events.write_text('')
                            self.write_choice(record, data)
                            before = self.snapshot()
                            self.assertEqual(self.eligible()[1],
                                'unverified identity' if present and value is not None else '')
                            self.assert_snapshot(before)
        for target in ('record', 'event'):
            for key in ('purpose', 'effect'):
                record = self.choice(); data = dict(decision=record['id'], chosen='A')
                (record if target == 'record' else data)[key] = 'merge'
                events.write_text(''); self.write_choice(record, data)
                self.assertEqual(self.eligible()[1], 'unverified identity')

    def test_stock_event_and_nullable_compatibility_emitter(self):
        # Actual stock decision_made payload omits optional null metadata.
        record = self.choice(); self.write_choice(record)
        stock = dict(decision=record['id'], chosen='A', outcome='recorded')
        compatibility = dict(stock, merge=None, binding=None)
        # Execute unchanged emitter against a disposable target, never the repo.
        for label, data in (('stock', stock), ('nullable compatibility', compatibility)):
            with self.subTest(payload=label):
                env = {k: v for k, v in os.environ.items() if not k.startswith(('FM_', 'HERDR_'))}
                env.update(FM_ROOT=str(self.root), HERDR_ENV='0')
                subprocess.run(['bash', str(fixture.ROOT / 'bin/fm-emit.sh'),
                    '--actor', 'captain', '--type', 'decision_made', '--task', 'T-001',
                    '--data', json.dumps(data), '--en', 'Choice recorded', '--tw', '選擇已記錄'],
                    env=env, check=True, capture_output=True)
                row = json.loads((self.state / 'events.jsonl').read_text().splitlines()[-1])
                self.assertEqual(row['data'], data)
                before = self.snapshot()
                self.assertEqual(self.eligible(), ([], ''))
                self.assert_snapshot(before)

    def test_migration_prior_held_ordinary_null(self):
        self.write_choice(self.choice())
        before = self.snapshot()
        with presence_predicates():
            self.assertEqual(self.eligible()[1], 'unverified identity')
        self.poll()
        self.assertEqual(len(self.gates()), 1)
        self.assert_snapshot(before)

    def test_migration_consumed_ordinary_null(self):
        self.write_choice(self.choice())
        before = self.snapshot()
        self.pilot.data['advanced']['12'] = dict(head=HEAD, fingerprint=self.ordinary_fingerprint())
        self.pilot.save()
        self.pilot.data = fixture.A.Pilot(self.ctx).data
        self.poll(); self.poll()
        self.assertEqual(self.gates(), [])
        self.assert_snapshot(before)

    def coexist(self, external=False):
        self.failed_history(external=external)
        self.write_choice(self.choice(), dict(decision='D-alpha-T001-3', chosen='A', outcome='recorded'))
        self.event_bytes = self.events.read_bytes()
        pins = self.state / 'pins'; pins.mkdir(exist_ok=True)
        (pins / 'fixture.json').write_text(json.dumps(dict(project='alpha', task='T-001', version=1)))
        return self.snapshot()

    def test_migration_signed_failure_with_null_choices_fresh_readiness(self):
        before = self.coexist()
        evidence, hold = self.eligible()
        self.assertEqual(hold, '')
        self.assertEqual(evidence[2][0][:3], [self.old_id, self.old['expected_head'], self.old['merge_settled']])
        self.complete_gate_receipt()
        path = self.state / 'pending/D-alpha-T001-2.json'
        card = json.loads(path.read_text())
        self.assertNotIn('chosen', card)
        self.assertEqual(card['binding']['signature'], self.ready['signature'])
        self.assertEqual(card['expected_head'], HEAD)
        self.assert_snapshot(before); self.assert_history_preserved()

    def test_migration_live_job_drains_before_new_frozen_eligibility(self):
        before = self.coexist()
        own = dict(head='old', dirty=False); new = dict(head='new', dirty=False)
        reload = dict(request={'to': new}, failed_ids=[])
        self.pilot.data['jobs']['live'] = dict(task='T-001', state='running', kind='gate', number=12, head=HEAD)
        with presence_predicates():
            self.assertEqual(self.eligible()[1], 'unverified identity')
            self.assertFalse(fixture.A.reload_due(self.pilot, own, reload))
        self.poll(); self.assertEqual(self.gates(), [])
        self.pilot.data['jobs']['live']['state'] = 'done'
        self.assertTrue(fixture.A.reload_due(self.pilot, own, reload))
        self.pilot.save(); self.pilot.data = fixture.A.Pilot(self.ctx).data
        self.poll(); self.assertEqual(len(self.gates()), 1)
        self.assert_snapshot(before)

    def test_identical_duplicate_settlements_deduplicate_timestamps(self):
        before = self.coexist()
        self.events.write_text(self.events.read_text() + json.dumps(self.event) + '\n')
        before = self.snapshot()
        evidence, hold = self.eligible()
        self.assertEqual(hold, '')
        self.assertEqual(evidence[2][0][3], [self.event['ts']])
        self.assert_snapshot(before)

    def test_conflicting_duplicate_settlement_refused(self):
        self.coexist()
        self.events.write_text(self.events.read_text() + json.dumps(dict(self.event,
            data=dict(self.event['data'], outcome='merged'))) + '\n')
        before = self.snapshot()
        self.assertEqual(self.eligible()[1], 'unverified settlement')
        self.assert_snapshot(before)

    def test_external_privacy_null_coexistence(self):
        before = self.coexist(external=True)
        self.old_path.write_text(json.dumps(dict(self.old, expected_head=HEAD)))
        before = self.snapshot()
        self.poll()
        for wake in self.pilot.data['wakes'].values():
            self.assertEqual(set(wake['summary']), {'en', 'zh-TW'})
            self.assertNotIn(self.sentinel, json.dumps(wake))
        self.assertFalse((self.root / 'state/decisions').exists())
        self.assert_snapshot(before)

    # Keep genuine owner negatives, including signatures, timestamps and pending
    # cards, in this feature's coexistence harness without weakening assertions.
    test_identity_readiness_and_history_negatives = fixture.LoopTests.test_failed_history_pre_request_negative_matrix
    test_precision_negatives = fixture.LoopTests.test_settlement_precision_conflicts_hold_before_request
    test_stock_current_readiness_negatives = fixture.LoopTests.test_stock_candidate_refuses_after_precheck_mutations
    test_current_signed_pending_checks = fixture.LoopTests.test_current_valid_signed_red_or_pending_checks_are_stock_refusals
    test_foreign_and_pending_owned_history = fixture.LoopTests.test_failed_history_foreign_and_conflicting_owned_record_never_authorizes
    test_missing_readiness_and_conflicting_history = fixture.LoopTests.test_failed_history_missing_corrupt_readiness_and_conflicting_settlement_hold


def presence_predicates(source=None):
    """Test-only runtime overlay, restoring BOTH original contradiction checks."""
    text = source or inspect.getsource(runtime)
    text = text.replace('any(k in record and record[k] is not None for k in merge_keys)',
                        'any(k in record for k in merge_keys)')
    text = text.replace('any(k in data and data[k] is not None for k in merge_keys)',
                        'any(k in data for k in merge_keys)')
    assert 'any(k in record for k in merge_keys)' in text
    assert 'any(k in data for k in merge_keys)' in text
    namespace = dict(runtime.__dict__)
    exec(compile(text, str(fixture.ROOT / 'bin/lib/fm_autopilot_loop.py'), 'exec'), namespace)
    return patch.object(runtime.MechanicalLoop, 'failed_card_evidence',
                        namespace['MechanicalLoop'].failed_card_evidence)


if __name__ == '__main__':
    mode = next((arg for arg in sys.argv if arg in ('--historical', '--presence-mutation')), None)
    if mode:
        sys.argv.remove(mode)
        source = None
        if mode == '--historical':
            commit = '3c5a213e462744f1612dd61023bc7504810ff5d0'
            source = subprocess.check_output(['git', '-C', str(fixture.ROOT), 'show',
                commit + ':bin/lib/fm_autopilot_loop.py'], text=True)
            digest = hashlib.sha256(source.encode()).hexdigest()
            assert digest == '38b56bd875ade03abe452fc30c624b7eddcb1fafa45c82e60e3669f73f713f7f'
            print('Historical production source', commit, digest)
        with presence_predicates(source):
            unittest.main(argv=[sys.argv[0], 'NullableHistory.test_nullable_choice_eligibility'])
    else:
        unittest.main()
