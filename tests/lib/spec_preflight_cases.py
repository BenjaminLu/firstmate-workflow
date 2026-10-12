"""Spec checks and stored preflight receipts after T-297; no vendor or
ambient repository access. The preflight launcher is gone; its receipts stay
readable and the checks it ran before its reviewer run at pin time."""
import hashlib
import importlib.util
import json
import os
from unittest.mock import patch
from pathlib import Path
import sys
import tempfile
import unittest

ROOT = Path(sys.argv.pop(1))
sys.path.insert(0, str(ROOT / 'bin/lib'))
from fm_evidence import Store
from fm_spec_preflight import check, decision
loader = importlib.util.spec_from_file_location('managed', ROOT / 'bin/fm-herdr.py')
managed = importlib.util.module_from_spec(loader)
loader.loader.exec_module(managed)


class ChangePointSchema(unittest.TestCase):
    def test_legacy_check_without_optional_ste(self):
        # Isolated public-text consumers intentionally do not install STE.
        with patch.dict(sys.modules, {'fm_ste': None}):
            spec = dict(id='T-X', scope=['src/**'], acceptance=['works'])
            check('T-X', json.dumps(spec).encode('utf-8'))
            for field in ('change_refs', 'check_answer'):
                with self.subTest(field=field):
                    with self.assertRaisesRegex(ValueError, 'orphan'):
                        check('T-X', json.dumps(dict(spec, **{field: []})).encode('utf-8'))
            from fm_spec_preflight import validate_change_refs
            with self.assertRaises(ImportError):
                validate_change_refs(dict(explain={'en': {'change_points': []}}))

    def test_evidence_and_indices(self):
        from copy import deepcopy
        from fm_spec_preflight import validate_change_refs
        loader = importlib.util.spec_from_file_location('ste_cases', ROOT / 'tests/lib/ste_cases.py')
        cases = importlib.util.module_from_spec(loader); loader.loader.exec_module(cases)
        spec = dict(explain=cases.walk_card(), acceptance=['The check passes.'],
                    change_refs=[dict(files=['src/a.py'], tests=[dict(file='tests/a.py', name='test_a')], acceptance=[0])],
                    check_answer=0)
        validate_change_refs(spec)
        duplicate = deepcopy(spec)
        for locale in ('en','zh-TW'):
            duplicate['explain'][locale]['change_points'].append(dict(duplicate['explain'][locale]['change_points'][0]))
        duplicate['change_refs'].append(deepcopy(duplicate['change_refs'][0]))
        validate_change_refs(duplicate)
        for name, mutate in [
            ('missing refs', lambda d: d.pop('change_refs')),
            ('null refs', lambda d: d.update(change_refs=None)),
            ('empty files', lambda d: d['change_refs'][0].update(files=[])),
            ('empty tests', lambda d: d['change_refs'][0].update(tests=[])),
            ('empty acceptance', lambda d: d['change_refs'][0].update(acceptance=[])),
            ('negative acceptance', lambda d: d['change_refs'][0].update(acceptance=[-1])),
            ('noninteger acceptance', lambda d: d['change_refs'][0].update(acceptance=[0.5])),
            ('duplicate acceptance', lambda d: d['change_refs'][0].update(acceptance=[0,0])),
            ('duplicate tests', lambda d: d['change_refs'][0]['tests'].append(dict(d['change_refs'][0]['tests'][0]))),
            ('null answer', lambda d: d.update(check_answer=None)),
            ('negative answer', lambda d: d.update(check_answer=-1)),
            ('noninteger answer', lambda d: d.update(check_answer=0.5)),
            ('missing about', lambda d: d['explain']['en']['check'].pop('about')),
            ('why-only evidence', lambda d: (d['explain']['en']['check']['options'].__setitem__(0,'Feedback only.'),d['explain']['en']['check'].update(why='Feedback only.'))),
            ('wrong answer evidence', lambda d: d.update(check_answer=1)),
            ('bool answer', lambda d: d.update(check_answer=True)),
            ('out of range answer', lambda d: d.update(check_answer=2)),
            ('length mismatch', lambda d: d.update(change_refs=[])),
            ('acceptance range', lambda d: d['change_refs'][0].update(acceptance=[1])),
            ('bool acceptance', lambda d: d['change_refs'][0].update(acceptance=[True])),
            ('traversal', lambda d: d['change_refs'][0].update(files=['../a'])),
            ('duplicate files', lambda d: d['change_refs'][0].update(files=['a', 'a'])),
            ('missing answer', lambda d: d.pop('check_answer')),
            ('invalid about', lambda d: d['explain']['en']['check'].update(about=dict(intent=2))),
            ('absent evidence', lambda d: d['explain']['zh-TW']['check']['options'].__setitem__(0, '不存在。')),
        ]:
            with self.subTest(name=name):
                bad = deepcopy(spec); mutate(bad)
                with self.assertRaises(ValueError): validate_change_refs(bad)
        two = deepcopy(spec); two['explain'] = cases.walk_card('two-way'); two.pop('check_answer')
        validate_change_refs(two)
        two['check_answer'] = 0
        with self.assertRaises(ValueError): validate_change_refs(two)
        validate_change_refs(dict(acceptance=['legacy']))
        with self.assertRaises(ValueError): validate_change_refs(dict(change_refs=[]))


class StoredReceipts(unittest.TestCase):
    def setUp(self):
        clean = patch.dict(os.environ, {'HERDR_ENV': '0'}, clear=True)
        clean.start(); self.addCleanup(clean.stop)
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.store = Store(self.root / 'state', 'self', 'T-X', external=False)
        self.spec = b'{"id":"T-X","scope":["src/**"],"acceptance":["works"]}\n'
        self.sha = hashlib.sha256(self.spec).hexdigest()

    def record(self, data=None, verdict='SPEC-OK', answer=None):
        """A receipt as the removed launcher wrote it (T-288 shape)."""
        data = self.spec if data is None else data
        answer = answer or 'Checked each acceptance line.\n' + verdict + ':T-X\n'
        return self.store.append('spec-preflight', 1, 'reviewer-noah-tx-r1', 'a' * 40, answer,
                                 spec_sha256=hashlib.sha256(data).hexdigest(), verdict=verdict,
                                 provenance={'level': 'legacy', 'vendor': 'claude'}, pass_budget=1)

    def test_preflight_does_not_consume_review_attempt(self):
        with patch.dict(os.environ, {'FM_SPEC_PREFLIGHT_MODE': '1'}):
            preflight = managed.allocate_identity(self.root, 'reviewer', 'T-X', '')
            second = managed.allocate_identity(self.root, 'reviewer', 'T-X', '')
        identity = json.loads((preflight / 'identity.json').read_text())
        self.assertEqual('spec-preflight', identity['mode'])
        self.assertEqual(2, json.loads((second / 'identity.json').read_text())['attempt'])
        review = managed.allocate_identity(self.root, 'reviewer', 'T-X', '')
        actual = json.loads((review / 'identity.json').read_text())
        self.assertEqual(1, actual['attempt'])
        self.assertEqual(1, actual['round'])
        self.assertTrue(actual['actor'].endswith('-r1'))

    def test_legacy_preflight_directory_does_not_consume_review_attempt(self):
        old = managed.allocate_identity(self.root, 'reviewer', 'T-X', '')
        (old / 'spec-preflight').mkdir()
        review = managed.allocate_identity(self.root, 'reviewer', 'T-X', '')
        identity = json.loads((review / 'identity.json').read_text())
        self.assertEqual(1, identity['attempt'])
        self.assertTrue(identity['actor'].endswith('-r1'))

    def bold_final(self, verdict='SPEC-OK'):
        # T-206: supplied excerpt of a real reviewer final, with its layout intact.
        fixture = (ROOT / 'tests/fixtures/spec-preflight/bold-headings.final.txt').read_text()
        return fixture.replace('SPEC-OK:T-X\n', verdict + ':T-X\n')

    def test_bold_heading_final_decisions(self):
        for verdict in ('SPEC-OK', 'SPEC-GAPS'):
            with self.subTest(verdict=verdict):
                self.assertEqual(verdict, decision(self.bold_final(verdict), 'T-X'))

    def assert_bold_heading_retained(self, verdict):
        answer = self.bold_final(verdict)
        retained = self.record(verdict=verdict, answer=answer)
        records = self.store.records()  # Also exercises fm_evidence re-validation.
        self.assertEqual(1, len(records))
        self.assertEqual(retained, records[0])
        self.assertEqual('spec-preflight', records[0]['kind'])
        self.assertEqual(verdict, records[0]['verdict'])
        self.assertEqual(answer, records[0]['text'])

    def test_bold_heading_ok_is_retained(self):
        self.assert_bold_heading_retained('SPEC-OK')

    def test_bold_heading_gaps_is_retained(self):
        self.assert_bold_heading_retained('SPEC-GAPS')

    def test_bold_heading_final_keeps_exact_marker_rule(self):
        body = self.bold_final().removesuffix('SPEC-OK:T-X\n')
        invalid = ('> SPEC-OK:T-X', '```\nSPEC-OK:T-X\n```', '**SPEC-OK:T-X**',
                   'SPEC-OK:T-Y', 'SPEC-OK:T-X\nafter', ' SPEC-OK:T-X',
                   'SPEC-OK:T-X\nSPEC-OK:T-X', 'SPEC-GAPS:T-X\nSPEC-OK:T-X')
        for marker in invalid:
            with self.subTest(marker=marker):
                self.assertIsNone(decision(body + marker + '\n', 'T-X'))

    def test_bold_heading_final_completes_preflight(self):
        self.assertEqual('completed', managed.completion(
            'reviewer', 'T-X', self.bold_final(), self.sha))

    def test_vendor_final_and_strict_mode_separation(self):
        final = '1. Covered.\nSPEC-OK:T-X'
        transcript = self.root / 'cli.log'
        transcript.write_text('\n'.join(json.dumps(row) for row in [
            {'type': 'thread.started', 'thread_id': 't'},
            {'type': 'turn.started'},
            {'type': 'item.completed', 'item': {'id': 'a', 'type': 'agent_message', 'text': final}},
            {'type': 'turn.completed', 'usage': {'input_tokens': 1, 'output_tokens': 1}}]))
        self.assertEqual(final, managed.cli_final('codex', transcript))
        self.assertEqual('completed', managed.completion('reviewer', 'T-X', final, self.sha))
        self.assertEqual('completed', managed.completion('reviewer', 'T-X', final.replace('OK', 'GAPS'), self.sha))
        self.assertEqual('unknown', managed.completion('reviewer', 'T-X', final))
        self.assertEqual('unknown', managed.completion('reviewer', 'T-X', 'REVIEWER_COMPLETE:T-X', self.sha))
        self.assertEqual('completed', managed.completion('reviewer', 'T-X', 'REVIEWER_COMPLETE:T-X'))
        self.assertEqual('SPEC-OK', decision('SPEC-OK:T-X', 'T-X'), 'T-288: no numbered list is needed')
        for invalid in ('1. x\n> SPEC-OK:T-X', '1. x\nSPEC-OK:T-Y',
                        '1. x\nSPEC-OK:T-X\nafter', '1. x\n```\nSPEC-OK:T-X'):
            self.assertIsNone(decision(invalid, 'T-X'))

    def test_readonly_policy_covers_whole_checkout_on_both_platforms(self):
        from fm_sandbox_policy import darwin, linux
        policy = dict(never_read=[], repo_config=[], review_root_readonly=True,
                      review_git_readonly=True)
        roots = [str(self.root / 'checkout'), str(self.root / 'tmp')]
        mac = darwin(policy, roots, [], {}, '', [], root=roots[0])
        self.assertIn('(deny file-write* (subpath "' + roots[0] + '"))', mac)
        linux_args = linux(policy, roots, [], {}, '').splitlines()
        at = linux_args.index(roots[0])
        self.assertEqual('--ro-bind', linux_args[at - 1])
        at = linux_args.index(roots[1])
        self.assertEqual('--bind', linux_args[at - 1])
        policy['review_root_readonly'] = False
        ordinary = linux(policy, roots, [], {}, '').splitlines()
        self.assertEqual('--bind', ordinary[ordinary.index(roots[0]) - 1])

    def test_receipt_is_private_to_project_and_signed(self):
        self.record()
        other = Store(self.root / 'state', 'other', 'T-X', external=False)
        self.assertEqual([], other.records())
        path = next(self.store.directory.glob('*.json'))
        record = json.loads(path.read_text()); record['spec_sha256'] = 'b' * 64
        path.write_text(json.dumps(record))
        with self.assertRaisesRegex(ValueError, 'forged or modified'):
            self.store.records()

    def test_authenticated_selector_keeps_provenance_and_mode_binding(self):
        run = self.root / 'run'; attempt = run / 'codex-one'; attempt.mkdir(parents=True)
        answer = '1. Covered.\nSPEC-OK:T-X'
        (attempt / 'final.txt').write_text(answer)
        env = dict(FM_ACTOR='reviewer-noah', FM_TASK='T-X', FM_ROLE='reviewer',
                   FM_SPEC_PREFLIGHT=self.sha)
        invocation = dict(actor=env['FM_ACTOR'], task='T-X', role='reviewer', spec_preflight=self.sha)
        result = dict(invocation, attempt=str(attempt), chain_attempt='one',
                      final_source='codex-json-completed-turn',
                      final_sha256=hashlib.sha256(answer.encode()).hexdigest())
        def write():
            (attempt / 'invocation.json').write_text(json.dumps(invocation))
            (run / 'last-result.json').write_text(json.dumps(result))
        write()
        self.assertEqual(answer, managed.review_final(run, 'one', env))
        self.assertEqual('', managed.review_final(run, 'two', env))
        self.assertEqual('', managed.review_final(run, 'one', dict(env, FM_SPEC_PREFLIGHT='b' * 64)))
        self.assertEqual('', managed.review_final(run, 'one', {k: v for k, v in env.items() if k != 'FM_SPEC_PREFLIGHT'}))
        result['final_source'] = 'file'; write()
        self.assertEqual('', managed.review_final(run, 'one', env))
        result['final_source'] = 'codex-json-completed-turn'; write()
        (attempt / 'final.txt').write_text(answer + '\n')
        self.assertEqual('', managed.review_final(run, 'one', env))


if __name__ == '__main__':
    unittest.main(verbosity=2)
