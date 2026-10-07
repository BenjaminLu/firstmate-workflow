"""T-248 standing checklist contract; isolated evidence stores, no vendors."""
import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(sys.argv.pop(1))
sys.path.insert(0, str(ROOT / 'bin/lib'))
from fm_evidence import Store
import fm_spec_preflight as P


class Standing(unittest.TestCase):
    def setUp(self):
        clean = patch.dict(os.environ, {'HERDR_ENV': '0'}, clear=True)
        clean.start()
        self.addCleanup(clean.stop)
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        self.root = Path(tmp.name)
        self.store = Store(self.root / 'state', 'self', 'T-X', external=False)
        self.data = json.dumps(dict(id='T-X', scope=['src/**'], acceptance=['one', 'two'])).encode()

    def answer(self, lines, verdict='SPEC-OK'):
        return lines + '\nPREFLIGHT-COMPLETE:T-X\n\n' + verdict + ':T-X\n'

    def retain(self, answer, data=None, actor='reviewer-fixture'):
        return P.retain(self.store, self.data if data is None else data, 'a' * 40,
                        actor, 1, answer, {'level': 'legacy'})

    def refused(self, answer):
        before = self.store.records()
        with self.assertRaisesRegex(ValueError, 'PREFLIGHT-COMPLETE'):
            self.retain(answer)
        self.assertEqual(before, self.store.records())

    def test_missing_marker(self):
        self.refused('1. ok: src/a:1 one\n2. ok: src/b:2 two\nSPEC-OK:T-X')

    def test_verdict_must_match_statuses(self):
        self.refused(self.answer('1. gap: src/a:1 fix one\n2. ok: src/b:2 two'))
        self.refused(self.answer('1. ok: src/a:1 one\n2. ok: src/b:2 two', 'SPEC-GAPS'))

    def test_status_and_acceptance_coverage_required(self):
        self.refused(self.answer('1. src/a:1 one\n2. ok: src/b:2 two'))
        self.refused(self.answer('1. ok: src/a:1 one'))

    def test_first_pass_statuses(self):
        for status in ('done', 'open'):
            with self.subTest(status=status):
                self.refused(self.answer(f'1. {status}: src/a:1 one\n2. ok: src/b:2 two',
                                         'SPEC-GAPS' if status == 'open' else 'SPEC-OK'))

    def test_prompt_preserves_previous_block_and_rules(self):
        block = ('**1.** **gap**: src/a:1 fix one\n  Evidence continues.\n- A fixture too.\n'
                 '```text\n99. Quoted example, not an item.\n```\n> Evidence quote.\n\n2. ok: src/b:2 two')
        self.retain(self.answer(block, 'SPEC-GAPS'))
        body = P.prompt('T-X', self.data, 'b' * 40, P.standing(self.store))
        self.assertIn(block, body)
        for rule in ('done', 'open', 'ok', 'N. gap NEW-GROUND:', 'N. gap MISSED:'):
            self.assertIn(rule, body)
        path = self.root / 'spec.json'
        path.write_bytes(self.data)
        result = subprocess.run([sys.executable, str(ROOT / 'bin/lib/fm_spec_preflight.py'),
                                 'prompt', '--task', 'T-X', '--spec', str(path),
                                 '--state', str(self.store.state), '--project', 'self'],
                                capture_output=True, text=True)
        self.assertEqual(0, result.returncode, result.stderr)
        self.assertIn(block, result.stdout)

    def test_prompt_validates_before_store_and_requires_both_store_arguments(self):
        path = self.root / 'spec.json'
        path.write_bytes(self.data)
        argv = ['preflight', 'prompt', '--task', 'T-X', '--spec', str(path)]
        for args in ([], ['--state', str(self.store.state)], ['--project', 'self']):
            with self.subTest(args=args), patch.object(sys, 'argv', argv + args), \
                    patch.object(P, 'Store', side_effect=AssertionError('unexpected store read')), \
                    patch('builtins.print') as output:
                P.main()
                self.assertEqual(P.prompt('T-X', self.data, ''), output.call_args.args[0])
        with patch.object(sys, 'argv', argv + ['--state', str(self.store.state), '--project', 'self']), \
                patch.dict(os.environ, FM_EXTERNAL='1'), \
                patch.object(P, 'Store', side_effect=AssertionError('store before validation')):
            with self.assertRaisesRegex(ValueError, 'external spec needs a valid public_title:'):
                P.main()

    def test_reissue_keeps_numbers_and_labels_and_counts_missed(self):
        self.retain(self.answer('1. gap: src/a:1 fix one\n2. ok: src/b:2 two', 'SPEC-GAPS'))
        for lines in ('1. open: src/a:1 one',
                      '1. open: src/a:1 one\n3. ok: src/b:2 two',
                      '2. ok: src/b:2 two\n1. open: src/a:1 one',
                      '1. open: src/a:1 one\n2. ok: src/b:2 two\n3. gap: src/c:3 fix three',
                      '1. open: src/a:1 one\n2. ok: src/b:2 two\n3. ok MISSED: src/c:3 three',
                      '1. open: src/a:1 one\n2. ok: src/b:2 two\n3. open NEW-GROUND: src/c:3 three'):
            with self.subTest(lines=lines):
                self.refused(self.answer(lines, 'SPEC-GAPS'))
        record = self.retain(self.answer('1. open: src/a:1 one\n2. ok: src/b:2 two\n'
                            '3. gap MISSED: src/c:3 fix three\n'
                            '4. gap NEW-GROUND: src/d:4 fix four', 'SPEC-GAPS'))
        self.assertEqual(1, record['missed'])
        self.assertEqual(dict(n=3, status='gap', label='MISSED',
                              text='3. gap MISSED: src/c:3 fix three'), record['standing'][2])
        self.assertEqual(record, self.store.records()[-1])

    def test_transition_matrix(self):
        for old in ('gap', 'open', 'ok', 'done'):
            previous = {'standing': [dict(n=1, status=old)]}
            allowed = ('done', 'open') if old in ('gap', 'open') else ('ok', 'open')
            for new in ('gap', 'open', 'ok', 'done'):
                answer = self.answer(f'1. {new}: src/a:1 check',
                                     'SPEC-GAPS' if new in ('gap', 'open') else 'SPEC-OK')
                with self.subTest(old=old, new=new):
                    if new in allowed:
                        self.assertEqual(new, P.structure(answer, 'T-X', 1, previous)[0]['status'])
                    else:
                        with self.assertRaisesRegex(ValueError, 'PREFLIGHT-COMPLETE'):
                            P.structure(answer, 'T-X', 1, previous)

    def test_retain_checks_transitions(self):
        self.retain(self.answer('1. gap: src/a:1 fix one\n2. ok: src/b:2 two', 'SPEC-GAPS'))
        for lines in ('1. gap: src/a:1 fix one\n2. ok: src/b:2 two',
                      '1. ok: src/a:1 one\n2. open: src/b:2 fix two',
                      '1. open: src/a:1 fix one\n2. done: src/b:2 two'):
            self.refused(self.answer(lines, 'SPEC-GAPS'))
        fixed = self.retain(self.answer('1. done: src/a:1 one\n2. ok: src/b:2 two'), self.data + b' ')
        self.assertEqual(fixed, P.standing(self.store))
        self.assertIn('1. done: src/a:1 one', P.prompt('T-X', self.data, '', P.standing(self.store)))

    def legacy(self):
        return self.store.append('spec-preflight', 1, 'legacy-actor', 'b' * 40,
                                 '1. Checked.\nSPEC-OK:T-X',
                                 spec_sha256=hashlib.sha256(self.data).hexdigest(),
                                 verdict='SPEC-OK', provenance={'level': 'legacy'})

    def test_legacy_ignored_and_still_authorizes_exact_bytes(self):
        record = self.legacy()
        self.assertIsNone(P.standing(self.store))
        self.assertEqual(P.prompt('T-X', self.data, ''),
                         P.prompt('T-X', self.data, '', P.standing(self.store)))
        self.assertEqual([record], self.store.records())
        self.assertEqual(record, P.require_ok(self.store, self.data))

    def test_latest_standing_ignores_actor_hash_verdict_and_later_legacy(self):
        self.retain(self.answer('1. ok: src/a:1 one\n2. ok: src/b:2 two'))
        latest = self.retain(self.answer('1. open: src/a:1 fix one\n2. ok: src/b:2 two', 'SPEC-GAPS'),
                             self.data + b' ', actor='other-actor')
        self.legacy()
        self.assertEqual(latest, P.standing(self.store))

    def test_reads_do_not_create_directories_or_take_locks(self):
        with patch.object(Path, 'mkdir', side_effect=AssertionError('reader mkdir')):
            self.assertIsNone(P.standing(self.store))
        self.retain(self.answer('1. ok: src/a:1 one\n2. ok: src/b:2 two'))
        lock = self.store.directory / '.lock'
        lock.unlink()
        lock.mkdir()
        with patch.object(Path, 'mkdir', side_effect=AssertionError('reader mkdir')):
            previous = P.standing(self.store)
            self.assertEqual(2, len(P.structure(self.answer('1. ok: a\n2. ok: b'), 'T-X', 2, previous)))

    def test_final_block_markup_and_boundaries(self):
        block = '### **1.** **ok**: src/a:1 one\n  wrapped\n\n- bullet\n__2.__ __ok__: src/b:2 two'
        record = self.retain(self.answer('1. Background summary\n\n**Standing list**\n' + block))
        self.assertEqual([1, 2], [item['n'] for item in record['standing']])
        self.assertIn(block, P.prompt('T-X', self.data, '', P.standing(self.store)))
        for suffix in ('\n## Another section', '\n\nUnrelated paragraph'):
            self.refused(self.answer('1. ok: a\n2. ok: b' + suffix))
        for marker in ('> PREFLIGHT-COMPLETE:T-X', '**PREFLIGHT-COMPLETE:T-X**',
                       ' PREFLIGHT-COMPLETE:T-X', 'PREFLIGHT-COMPLETE:T-Y',
                       '```\nPREFLIGHT-COMPLETE:T-X\n```'):
            self.refused('1. ok: a\n2. ok: b\n' + marker + '\nSPEC-OK:T-X')

    def test_first_prompt_exhaustive_categories(self):
        body = P.prompt('T-X', self.data, '')
        for phrase in ('at least one item per acceptance line', 'why and its references',
                       'each Change', 'scope completeness', 'fails on base', 'regression',
                       'pins', 'i18n', 'lint reachability', 'FM_EXTERNAL=1',
                       'PREFLIGHT-COMPLETE:T-X', 'N. ok:', 'N. gap:', 'MISSED'):
            self.assertIn(phrase, body)


if __name__ == '__main__':
    unittest.main(verbosity=2)
