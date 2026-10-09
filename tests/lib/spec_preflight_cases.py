"""T-185 fail-first assertions; no vendor or ambient repository access."""
import hashlib
import importlib.util
import json
import os
import subprocess
from unittest.mock import patch
from pathlib import Path
import sys
import tempfile
import unittest

ROOT = Path(sys.argv.pop(1))
sys.path.insert(0, str(ROOT / 'bin/lib'))
from fm_evidence import Store
from fm_spec_preflight import require_ok, retain, prompt, decision, standing
loader = importlib.util.spec_from_file_location('managed', ROOT / 'bin/fm-herdr.py')
managed = importlib.util.module_from_spec(loader)
loader.loader.exec_module(managed)


class ChangePointSchema(unittest.TestCase):
    def test_legacy_prompt_without_optional_ste(self):
        # Isolated public-text consumers intentionally do not install STE.
        with patch.dict(sys.modules, {'fm_ste': None}):
            spec = dict(id='T-X', scope=['src/**'], acceptance=['works'])
            self.assertIn('T-X', prompt('T-X', json.dumps(spec).encode('utf-8'), 'a' * 40))
            for field in ('change_refs', 'check_answer'):
                with self.subTest(field=field):
                    with self.assertRaisesRegex(ValueError, 'orphan'):
                        prompt('T-X', json.dumps(dict(spec, **{field: []})).encode('utf-8'), 'a' * 40)
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


class Preflight(unittest.TestCase):
    def setUp(self):
        clean = patch.dict(os.environ, {'HERDR_ENV': '0'}, clear=True)
        clean.start(); self.addCleanup(clean.stop)
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.store = Store(self.root / 'state', 'self', 'T-X', external=False)
        self.spec = b'{"id":"T-X","scope":["src/**"],"acceptance":["works"]}\n'
        self.sha = hashlib.sha256(self.spec).hexdigest()

    def record(self, data=None, verdict='SPEC-OK'):
        data = self.spec if data is None else data
        previous = standing(self.store)
        if previous is None:
            statuses = ['ok' if verdict == 'SPEC-OK' else 'gap'] * max(
                1, len(json.loads(data).get('acceptance') or []))
        else:
            statuses = [('open' if verdict == 'SPEC-GAPS' else
                         'done' if item['status'] in ('gap', 'open') else 'ok')
                        for item in previous['standing']]
        answer = ''.join(f'{n}. {status}: Checked each acceptance line.\n'
                         for n, status in enumerate(statuses, 1))
        answer += 'PREFLIGHT-COMPLETE:T-X\n' + verdict + ':T-X\n'
        return retain(self.store, data, 'a' * 40, 'reviewer-noah-tx-r1', 1,
                      answer,
                      {'level': 'legacy', 'vendor': 'claude'})

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

    def test_first_round_missing_refuses_and_names_command(self):
        with self.assertRaisesRegex(ValueError, 'fm-review.sh --spec-preflight --task T-X --spec'):
            require_ok(self.store, self.spec)

    def test_other_bytes_refused_exact_bytes_accepted(self):
        self.record(self.spec + b' ')
        with self.assertRaises(ValueError):
            require_ok(self.store, self.spec)
        self.record()
        require_ok(self.store, self.spec)

    def test_require_reads_receipts_without_write_lock_or_directory_creation(self):
        self.record()
        lock = self.store.directory / '.lock'
        lock.unlink()
        lock.mkdir()  # writer fails here; a reader must ignore it
        with patch.object(Path, 'mkdir', side_effect=AssertionError('read attempted mkdir')):
            self.assertEqual('SPEC-OK', require_ok(self.store, self.spec)['verdict'])
        spec = self.root / 'spec.json'
        spec.write_bytes(self.spec)
        result = subprocess.run([sys.executable, str(ROOT / 'bin/lib/fm_spec_preflight.py'),
                                 'require', '--state', str(self.store.state), '--project', 'self',
                                 '--task', 'T-X', '--spec', str(spec)],
                                capture_output=True, text=True, timeout=10)
        self.assertEqual(0, result.returncode, result.stderr)
        with self.assertRaises(IsADirectoryError):
            self.record()

    def test_repin_and_existing_inflight_pin_need_new_preflight(self):
        # Migration is fail-closed on next dispatch, even for an old pin.
        self.record()
        changed = self.spec + b'\n'
        with self.assertRaises(ValueError):
            require_ok(self.store, changed)
        self.record(changed)
        require_ok(self.store, changed)

    def test_gaps_cannot_be_waived_on_same_bytes(self):
        self.record(verdict='SPEC-GAPS')
        with self.assertRaises(ValueError):
            self.record()
        with self.assertRaises(ValueError):
            require_ok(self.store, self.spec)
        self.record(self.spec + b' ')
        require_ok(self.store, self.spec + b' ')

    def test_external_public_title_refusal_preserves_existing_receipts(self):
        self.record()
        with patch.dict(os.environ, FM_EXTERNAL='1'):
            with self.assertRaisesRegex(ValueError, 'external spec needs a valid public_title:'):
                prompt('T-X', self.spec, 'a' * 40)
            # Existing SPEC-OK records remain valid without a new prompt.
            self.assertEqual('SPEC-OK', require_ok(self.store, self.spec)['verdict'])
            data = dict(json.loads(self.spec), public_title='Draw the fixture widget in blue')
            self.assertIn('SPEC-OK:T-X', prompt('T-X', json.dumps(data).encode(), 'a' * 40))

    def test_external_prompt_failure_keeps_launcher_exit_65(self):
        path = self.root / 'spec.json'
        path.write_bytes(self.spec)
        launcher = (ROOT / 'bin/lib/fm-spec-preflight.sh').read_text()
        start = launcher.index('python3 "$preflight_py" prompt ')
        block = launcher[start:launcher.index('# An independent clone', start)]
        result = subprocess.run(['bash', '-c',
            'preflight_py="$1/bin/lib/fm_spec_preflight.py"; TASK=T-X; '
            'FM_PINNED_DIR="$2"; base_head=base; preflight="$2"; ' + block +
            '\nprintf launched > "$2/launched"', '_', str(ROOT), str(self.root)],
            env=dict(os.environ, FM_EXTERNAL='1'), capture_output=True, text=True)
        self.assertEqual(65, result.returncode, result.stderr)
        self.assertIn('external spec needs a valid public_title:', result.stderr)
        self.assertFalse((self.root / 'launched').exists())

    def test_prompt_four_checks_and_closing_rule(self):
        body = prompt('T-X', self.spec, 'a' * 40)
        for part in ('declared scope', 'caller, mirror, fixture', 'ids, formats, paths',
                     'already in flight', 'migration', 'test', 'SPEC-OK:T-X', 'SPEC-GAPS:T-X',
                     'PREFLIGHT-COMPLETE:T-X'):
            self.assertIn(part, body)
        context = managed.role_context(ROOT, 'reviewer', 'T-X', 'reviewer-noah', body,
                                       spec_preflight=self.sha)
        self.assertNotIn('REVIEWER_COMPLETE', context)
        self.assertNotIn('APPROVE:T-X', context)
        self.assertIn('SPEC-OK:T-X', context)
        self.assertIn('PREFLIGHT-COMPLETE:T-X', context)

    def test_prompt_check_five_names_the_design_section(self):
        # T-189: a design.md edit names its numbered home, never the file's end.
        body = prompt('T-X', self.spec, 'a' * 40)
        self.assertIn('5. If the scope lists design/design.md, does the acceptance name the numbered\n'
                      '   section (§N or §N.M) it edits?', body)
        self.assertIn('adds a section after the last numbered section, is a\n   spec gap.', body)

    def bold_final(self, verdict='SPEC-OK'):
        # T-206: supplied excerpt of a real reviewer final, with its layout intact.
        fixture = (ROOT / 'tests/fixtures/spec-preflight/bold-headings.final.txt').read_text()
        return fixture.replace('SPEC-OK:T-X\n', verdict + ':T-X\n')

    def test_bold_heading_final_decisions(self):
        for verdict in ('SPEC-OK', 'SPEC-GAPS'):
            with self.subTest(verdict=verdict):
                self.assertEqual(verdict, decision(self.bold_final(verdict), 'T-X'))

    def assert_bold_heading_retained(self, verdict):
        answer = (ROOT / 'tests/fixtures/spec-preflight/bold-headings-standing.final.txt').read_text()
        if verdict == 'SPEC-GAPS':
            answer = answer.replace('**ok**', '**gap**', 1).replace('SPEC-OK:T-X', 'SPEC-GAPS:T-X')
        retained = retain(self.store, self.spec, 'a' * 40, 'reviewer-noah-tx-r1', 1,
                          answer, {'level': 'legacy', 'vendor': 'claude'})
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

    def test_numbered_item_markup_shapes(self):
        accepted = ('1) x', '   2. x', '**1. Why**', '**1.** Why', '__3. x__',
                    '### 4. x', '1. x', '1. **Why**', '# 1. x',
                    '   ###### __12)__ Why', '1.\tx')
        rejected = ('**Why**', '- 1. x', '1.x', '1.', '```\n1. x\n```', '> 1. x',
                    '    1. x', '\t1. x', '####### 1. x', '###1. x')
        for item in accepted:
            with self.subTest(accepted=item):
                self.assertEqual('SPEC-OK', decision(item + '\nSPEC-OK:T-X', 'T-X'))
        for item in rejected:
            with self.subTest(rejected=item):
                self.assertIsNone(decision(item + '\nSPEC-OK:T-X', 'T-X'))

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

    def test_prompt_requests_plain_numbers_at_line_start(self):
        self.assertIn('Give a numbered list of findings (or checked evidence when there are no gaps); '
                      'start each item with its plain number, `1.`, `2.` and so on, '
                      'at the start of the line.', prompt('T-X', self.spec, 'a' * 40))

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
        for invalid in ('SPEC-OK:T-X', '1. x\n> SPEC-OK:T-X', '1. x\nSPEC-OK:T-Y',
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
        with self.assertRaises(ValueError):
            require_ok(other, self.spec)
        path = next(self.store.directory.glob('*.json'))
        record = json.loads(path.read_text()); record['spec_sha256'] = 'b' * 64
        path.write_text(json.dumps(record))
        with self.assertRaisesRegex(ValueError, 'forged or modified'):
            require_ok(self.store, self.spec)

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
