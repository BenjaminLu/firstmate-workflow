"""Local evidence behavioral contract; no network or background processes."""
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(sys.argv.pop()) / 'bin/lib'))
from fm_evidence import Store, protocol, verdict_marker


class Records(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.store = Store(Path(self.tmp.name), 'self', 'T-X')

    def record(self, kind, text, **extra):
        return self.store.append(kind, 1, 'firstmate', 'a' * 40, text, **extra)

    def test_append_preserves_every_record_and_exact_identity(self):
        self.record('brief', 'first', authorized=True)
        self.record('brief', 'second', authorized=True)
        self.assertEqual([r['text'] for r in self.store.records()], ['first', 'second'])
        self.assertEqual(Store(Path(self.tmp.name), 'other', 'T-X').records(), [])
        self.assertEqual(self.store.brief(1, 'a' * 40)['text'], 'second')
        self.assertIsNone(self.store.brief(2, 'a' * 40))
        self.assertIsNone(self.store.brief(1, 'b' * 40))

    def test_unauthorized_brief_never_enters_prompt(self):
        self.record('brief', 'worker claim', authorized=False)
        self.assertIsNone(self.store.brief(1, 'a' * 40))

    def test_quoted_markers_are_not_verdicts(self):
        self.assertIsNone(verdict_marker('```\nAPPROVE:T-X\n```\n> REJECT:T-X', 'T-X'))
        self.assertEqual(verdict_marker('```\nREJECT:T-X\n```\nAPPROVE:T-X', 'T-X'), 'APPROVE')

    def test_unverified_verdict_refused(self):
        with self.assertRaises(ValueError):
            self.record('verdict', 'APPROVE:T-X')

    def test_round_one_reject_requires_complete_list(self):
        self.assertTrue(protocol([self.rejection('REJECT:T-X')], 'T-X'))
        self.assertEqual(protocol([self.rejection('1. open fix parser\nCRITERIA-COMPLETE:T-X\nREJECT:T-X')], 'T-X'), [])

    @staticmethod
    def rejection(text):
        return dict(kind='verdict', verdict='REJECT', text=text)

    def test_reissued_lists_keep_numbers_states_and_label_new_items(self):
        first = self.rejection('1. open fix parser\nCRITERIA-COMPLETE:T-X\nREJECT:T-X')
        for second in ('2. open different\n', '1. fix parser\n', '1. done parser\n2. open another\n'):
            self.assertTrue(protocol([first, self.rejection(second + 'CRITERIA-COMPLETE:T-X\nREJECT:T-X')], 'T-X'))
        second = self.rejection('1. done parser\n2. open REGRESSION:T-X tokenization\nCRITERIA-COMPLETE:T-X\nREJECT:T-X')
        self.assertEqual(protocol([first, second], 'T-X'), [])


if __name__ == '__main__':
    unittest.main()
