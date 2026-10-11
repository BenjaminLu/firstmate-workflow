"""T-288 fresh spec preflight and its pass budget; isolated stores, no vendors.

  spec_preflight_fresh.py <root> [<test name>...]
"""
import hashlib
import importlib.util
import json
import os
import shutil
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

os.environ['HERDR_ENV'] = '0'
ROOT = Path(sys.argv.pop(1))
sys.path.insert(0, str(ROOT / 'bin/lib'))
from fm_evidence import Store  # noqa: E402
import fm_preflight_budget as B  # noqa: E402
import fm_spec_preflight as P  # noqa: E402
loader = importlib.util.spec_from_file_location('managed', ROOT / 'bin/fm-herdr.py')
managed = importlib.util.module_from_spec(loader)
loader.loader.exec_module(managed)

LEGACY = ('1. ok: src/a:1 checked.\n2. gap NEW-GROUND: src/b:2 fix two.\n'
          'PREFLIGHT-COMPLETE:T-X\n\nSPEC-OK:T-X\n')


class Fresh(unittest.TestCase):
    def setUp(self):
        clean = patch.dict(os.environ, {'HERDR_ENV': '0'}, clear=True)
        clean.start()
        self.addCleanup(clean.stop)
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        self.root = Path(tmp.name)
        self.state = self.root / 'state'
        self.store = Store(self.state, 'self', 'T-X', external=False)
        self.data = self.spec('Show the retry count.')

    def spec(self, *acceptance):
        return (json.dumps(dict(id='T-X', scope=['src/**'], acceptance=list(acceptance))) + '\n').encode()

    def retain(self, answer, data=None):
        return P.retain(self.store, self.data if data is None else data, 'a' * 40,
                        'reviewer-fixture', 1, answer, {'level': 'legacy'})

    def legacy(self, data=None, text=LEGACY, verdict='SPEC-OK'):
        """A receipt as the pre-T-288 writer stored it: a standing list, no pass_budget."""
        data = self.data if data is None else data
        return self.store.append('spec-preflight', 1, 'legacy-actor', 'b' * 40, text,
                                 spec_sha256=hashlib.sha256(data).hexdigest(), verdict=verdict,
                                 provenance={'level': 'legacy'},
                                 standing=[dict(n=1, status='ok', label=None, text='1. ok: src/a:1 checked.')],
                                 missed=0)

    def cli_prompt(self, data):
        path = self.root / 'spec.json'
        path.write_bytes(data)
        result = subprocess.run([sys.executable, str(ROOT / 'bin/lib/fm_spec_preflight.py'), 'prompt',
                                 '--task', 'T-X', '--spec', str(path), '--base', 'b' * 40,
                                 '--state', str(self.state), '--project', 'self'],
                                capture_output=True, text=True, timeout=60)
        self.assertEqual(0, result.returncode, result.stderr)
        return result.stdout

    def test_short_spec_passes_in_one_pass(self):
        # A stub reviewer's free-form final: no numbered item, no marker line.
        answer = 'The spec is clear, right and small. Nothing simpler fits.\nSPEC-OK:T-X\n'
        sha = hashlib.sha256(self.data).hexdigest()
        self.assertEqual('completed', managed.completion('reviewer', 'T-X', answer, sha))
        record = self.retain(answer)
        self.assertEqual('SPEC-OK', record['verdict'])
        self.assertEqual(1, record['pass_budget'])
        self.assertNotIn('standing', record)
        self.assertEqual(record, P.require_ok(self.store, self.data))
        self.assertEqual(1, B.Budget(self.state, 'self', 'T-X', external=False).state_of()['used'])

    def test_re_pass_judges_new_bytes_only(self):
        sentinel = 'EARLIER-LIST-SENTINEL'
        self.retain(f'1. gap: {sentinel} line 1 names no count.\n2. ok: fine.\nSPEC-GAPS:T-X\n')
        edited = self.spec('Show the retry count, 3 by default.')
        body = self.cli_prompt(edited)
        self.assertNotIn(sentinel, body)
        self.assertNotIn('Previous standing list', body)
        self.assertEqual(P.prompt('T-X', edited, 'b' * 40), body.removesuffix('\n'),
                         'a re-pass prompt is the first-pass prompt for the new bytes')
        # Judged alone: a free-form SPEC-OK with no reissued list is retained.
        record = self.retain('The count is named now.\nSPEC-OK:T-X\n', edited)
        self.assertEqual('SPEC-OK', record['verdict'])
        P.require_ok(self.store, edited)
        # The bytes that got SPEC-GAPS still cannot get SPEC-OK.
        with self.assertRaisesRegex(ValueError, 'amended spec bytes'):
            self.retain('Fine now.\nSPEC-OK:T-X\n')

    def test_refused_rewrite_reasons_still_reach_the_next_prompt(self):
        reworded = dict(json.loads(self.data), scope=['bin/**'])
        block = '```json fm-reworded-spec\n' + json.dumps(reworded) + '\n```\n'
        record = self.retain('Rewrote the scope.\n' + block + 'SPEC-OK:T-X\n')
        self.assertEqual('rewrite-refused', P.effective(record))
        body = self.cli_prompt(self.data)
        self.assertIn('An earlier preflight refused these rewrites', body)
        self.assertIn('- spec: spec.scope.0: only prose may change', body)

    def decide(self, calls):
        def run(args, **kwargs):
            calls.append(args[1:])
            out = 'D-firstmate-workflow-TX-1\n' if args[1] == '--allocate' else str(self.state / 'pending/x.json')
            return subprocess.CompletedProcess(args, 0, out, '')
        return run

    def test_fourth_pass_raises_budget_card(self):
        budget = B.Budget(self.state, 'self', 'T-X', external=False)
        # Receipts from before T-288 never count, however many there are.
        for n in range(4):
            self.legacy(self.spec(f'old {n}'))
        calls = []
        self.assertEqual(0, B.gate(budget, ROOT, self.decide(calls)))
        private = 'PRIVATE-SPEC-SENTINEL'
        for n in range(3):
            self.retain(f'{private} gap {n}.\nSPEC-GAPS:T-X\n', self.spec(f'{private} {n}'))
        self.assertEqual(dict(state='stop', used=3), {k: budget.state_of()[k] for k in ('state', 'used')})
        self.assertEqual(65, B.gate(budget, ROOT, self.decide(calls)))
        self.assertEqual(['--allocate', '--request'], [call[0] for call in calls])
        ident = 'D-firstmate-workflow-TX-1'
        self.assertEqual(['--request', ident, '--task', 'T-X', '--purpose', 'decision', '--details'], calls[1][:7])
        details = json.loads(Path(calls[1][7]).read_text())
        self.assertEqual(['A', 'B', 'C'], sorted(details['en']['options']))
        self.assertEqual('Allow one more pass.', details['en']['options']['C']['description'])
        # Counts and verdicts only: no spec or review text, as an external card needs.
        self.assertNotIn(private, json.dumps(details, ensure_ascii=False))
        import fm_ste
        self.assertTrue(fm_ste.check_details(details, 'choice').get('ok', True))
        self.assertTrue(fm_ste.check_plain(details)['ok'])
        # Waiting: the card is named again, no second card and still no pass.
        self.assertEqual(65, B.gate(budget, ROOT, self.decide(calls)))
        self.assertEqual(2, len(calls))
        self.assertEqual('waiting', budget.state_of()['state'])
        decisions = self.state / 'decisions'
        decisions.mkdir()
        (decisions / (ident + '.json')).write_text(json.dumps(dict(id=ident, task='T-X', chosen='C',
                                                                   ts='2026-10-11T00:00:00Z')))
        self.assertEqual(0, B.gate(budget, ROOT, self.decide(calls)), 'an answer allows the next pass')
        self.assertEqual(0, budget.state_of()['used'])
        self.retain('Clear now.\nSPEC-OK:T-X\n', self.spec('fixed'))
        self.assertEqual(1, budget.state_of()['used'])

    def test_custom_budget_answer_resets_the_count(self):
        # Any answer resets the count: the board's free text and "change" too.
        for chosen, text in (('custom', 'Split it.'), ('change', None)):
            with self.subTest(chosen=chosen):
                shutil.rmtree(self.state, ignore_errors=True)
                self.state.mkdir(parents=True)
                self.store = Store(self.state, 'self', 'T-X', external=False)
                budget = B.Budget(self.state, 'self', 'T-X', external=False)
                for n in range(3):
                    self.retain(f'gap {n}.\nSPEC-GAPS:T-X\n', self.spec(f'line {n}'))
                calls = []
                self.assertEqual(65, B.gate(budget, ROOT, self.decide(calls)))
                ident = 'D-firstmate-workflow-TX-1'
                decisions = self.state / 'decisions'
                decisions.mkdir()
                (decisions / (ident + '.json')).write_text(json.dumps(dict(
                    id=ident, task='T-X', chosen=chosen, text=text, ts='2026-10-11T00:00:00Z')))
                self.assertEqual(dict(state='within', used=0, answer=chosen),
                                 {k: budget.state_of()[k] for k in ('state', 'used', 'answer')})
                self.assertEqual(0, B.gate(budget, ROOT, self.decide(calls)), 'a custom answer allows a pass')

    def test_budget_card_failure_names_the_recovery(self):
        budget = B.Budget(self.state, 'self', 'T-X', external=False)
        for n in range(3):
            self.retain(f'gap {n}.\nSPEC-GAPS:T-X\n', self.spec(f'line {n}'))

        def failing(step):
            def run(args, **kwargs):
                code = 1 if args[1] == step else 0
                return subprocess.CompletedProcess(args, code, 'D-firstmate-workflow-TX-1\n', '')
            return run
        with patch('sys.stderr') as err:
            self.assertEqual(65, B.gate(budget, ROOT, failing('--allocate')))
        self.assertIn('run fm_preflight_budget.py record-card', ''.join(c.args[0] for c in err.write.call_args_list))
        self.assertEqual('stop', budget.state_of()['state'], 'nothing was recorded')
        with patch('sys.stderr') as err:
            self.assertEqual(65, B.gate(budget, ROOT, failing('--request')))
        said = ''.join(c.args[0] for c in err.write.call_args_list)
        self.assertIn('card D-firstmate-workflow-TX-1 is recorded but its request failed', said)
        self.assertIn('bin/fm-decide.sh --request D-firstmate-workflow-TX-1 --task T-X', said)
        self.assertEqual('waiting', budget.state_of()['state'])

    def test_old_receipt_still_authorizes_pin(self):
        record = self.legacy()
        fresh = Store(self.state, 'self', 'T-X', external=False).records()
        self.assertEqual([record], fresh, 'the signed old receipt still reads')
        self.assertEqual('SPEC-OK', P.decision(record['text'], 'T-X'))
        self.assertEqual(record, P.require_ok(self.store, self.data))
        with self.assertRaises(ValueError):
            P.require_ok(self.store, self.data + b' ')
        # An old SPEC-GAPS receipt keeps binding its bytes too.
        gaps = self.spec('other')
        self.legacy(gaps, LEGACY.replace('SPEC-OK', 'SPEC-GAPS'), 'SPEC-GAPS')
        with self.assertRaisesRegex(ValueError, 'amended spec bytes'):
            self.retain('1. ok: Fine.\nPREFLIGHT-COMPLETE:T-X\nSPEC-OK:T-X\n', gaps)

    def test_malformed_final_line_refused(self):
        for answer in ('Looks fine.\nSPEC-OK:T-X\nThanks.', 'Looks fine.\nPREFLIGHT-COMPLETE:T-X',
                       'Looks fine.\n> SPEC-OK:T-X', 'Looks fine.\nSPEC-OK:T-Y',
                       '```json fm-reworded-spec\nSPEC-OK:T-X\n```'):
            with self.subTest(answer=answer):
                with self.assertRaises(ValueError) as raised:
                    self.retain(answer)
                self.assertIn('SPEC-OK:T-X or SPEC-GAPS:T-X', str(raised.exception))
                self.assertEqual([], self.store.records())

    def test_prompt_validates_before_store_and_reads_without_locks(self):
        path = self.root / 'spec.json'
        path.write_bytes(self.data)
        argv = ['preflight', 'prompt', '--task', 'T-X', '--spec', str(path),
                '--state', str(self.state), '--project', 'self']
        with patch.object(sys, 'argv', argv), patch.dict(os.environ, FM_EXTERNAL='1'), \
                patch.object(P, 'Store', side_effect=AssertionError('store before validation')):
            with self.assertRaisesRegex(ValueError, 'external spec needs a valid public_title:'):
                P.main()
        self.retain('Fine.\nSPEC-OK:T-X\n')
        lock = self.store.directory / '.lock'
        lock.unlink()
        lock.mkdir()
        with patch.object(Path, 'mkdir', side_effect=AssertionError('reader mkdir')):
            self.assertEqual('SPEC-OK', P.latest(self.store)['verdict'])
            self.assertEqual('within', B.Budget(self.state, 'self', 'T-X', external=False).state_of()['state'])


if __name__ == '__main__':
    names = sys.argv[1:]
    sys.argv[1:] = []
    suite = (unittest.defaultTestLoader.loadTestsFromNames(['Fresh.' + name for name in names], sys.modules[__name__])
             if names else unittest.defaultTestLoader.loadTestsFromTestCase(Fresh))
    sys.exit(0 if unittest.TextTestRunner(verbosity=2).run(suite).wasSuccessful() else 1)
