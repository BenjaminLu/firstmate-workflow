"""Tests for bounded packs and warning-only coverage."""
import sys
import tempfile
import unittest
from pathlib import Path
sys.path.insert(0, str(Path(sys.argv.pop()) / 'bin/lib'))
from fm_context_pack import bounded, coverage


class Pack(unittest.TestCase):
    def test_largest_items_trim_visibly_and_preserve_every_item(self):
        result = bounded([('small', 'keep me'), ('large', 'x' * 20000)], cap=1200)
        self.assertLessEqual(len(result.encode()), 1200)
        self.assertIn('keep me', result)
        self.assertIn('TRIMMED', result)
        self.assertIn('large', result)

    def test_round_situations_are_warnings_not_blockers(self):
        with tempfile.TemporaryDirectory() as root:
            spec = dict(acceptance=['Why. Needed.'], scope=['src/**'], depends_on=[])
            for situation, data in [('first', {}), ('red', {'failures': ['broken']}),
                                    ('cancelled', {'cancelled': [{'stage': None, 'duration': None}]}),
                                    ('reject', {'findings': [(1, 'open fix parser')]}),
                                    ('behind', {}), ('captain-change', {})]:
                result = coverage(situation, spec, '', data, Path(root), [])
                self.assertFalse(result['blocks'])
                if situation not in ('first', 'behind'):
                    self.assertTrue(result['gaps'], situation)
                self.assertIn('en', result['summary'])
                self.assertIn('zh-TW', result['summary'])

    def test_deferred_and_waived_reasons_survive(self):
        with tempfile.TemporaryDirectory() as root:
            for text, key in [('no brief needed: base update', 'waived'),
                              ('1. deferred: waiting on captain', 'deferred')]:
                result = coverage('reject', {}, text, {'findings': [(1, 'open parser')]}, Path(root), [])
                self.assertTrue(result[key])
                self.assertEqual(result['gaps'], [])


if __name__ == '__main__':
    unittest.main()
