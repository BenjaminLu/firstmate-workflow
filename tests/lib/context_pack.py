"""Tests for bounded packs and warning-only coverage."""
import sys
import tempfile
import unittest
from pathlib import Path
sys.path.insert(0, str(Path(sys.argv.pop()) / 'bin/lib'))
from fm_context_pack import bounded, coverage, Collector, summarize
from unittest.mock import patch
import subprocess
import json
from fm_round_metrics import metrics


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
                                    ('captain-change', {})]:
                result = coverage(situation, spec, '', data, Path(root), [])
                self.assertFalse(result['blocks'])
                if situation not in ('first',):
                    self.assertTrue(result['gaps'], situation)
                self.assertIn('en', result['summary'])
                self.assertIn('zh-TW', result['summary'])

    def test_first_round_names_root_and_arbitrary_paths(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / 'config.yaml').touch()
            report = coverage('first', dict(acceptance=['Why. Change config.yaml and i18n/ui.en.json and `Makefile`'],
                              scope=['src/**']), '', {}, root, [])
            self.assertIn('named path outside scope (confirm whether changed): config.yaml', report['gaps'])
            self.assertIn('named path does not exist: i18n/ui.en.json', report['gaps'])
            self.assertIn('named path does not exist: Makefile', report['gaps'])

    def test_captain_change_with_quote_and_matching_scope(self):
        report = coverage('captain-change', {'scope': ['config.yaml']},
                          'captain: "Change config.yaml"\nscope: ["config.yaml"]', {}, Path('.'), [])
        self.assertEqual(report['gaps'], [])

    def test_nonzero_check_status_still_supplies_names(self):
        collector = Collector(Path('.'), 'gh', 'a' * 40)
        with patch('subprocess.run', return_value=subprocess.CompletedProcess(
                [], 8, '[{"name":"ci"}]', '')):
            self.assertEqual(collector.github('pr', 'checks', '9', '--required',
                                             '--json', 'name'), [{'name': 'ci'}])
        self.assertEqual(collector.gaps, [])

    def test_summary_contains_late_gaps_and_reasoned_exemptions(self):
        report = dict(situation='red', gaps=['log unavailable'],
                      deferred=['upstream repair'], waived=['base update'])
        summarize(report)
        for language in ('en', 'zh-TW'):
            self.assertIn('log unavailable', report['summary'][language])
            self.assertIn('upstream repair', report['summary'][language])
            self.assertIn('base update', report['summary'][language])

    def test_round_metrics_count_reported_turns_only(self):
        with tempfile.TemporaryDirectory() as root:
            run = Path(root)
            (run / 'identity.json').write_text(json.dumps({'created': 100}))
            (run / 'coverage.json').write_text('[{"situation":"red","gaps":["missing"]}]')
            self.assertIsNone(metrics(run, 120)['turns'])
            attempt = run / 'attempt-1'
            attempt.mkdir()
            (attempt / 'invocation.json').write_text('{}')
            (attempt / 'cli.log').write_text('{"type":"turn.started"}\n{"type":"turn.completed"}\n')
            result = metrics(run, 120)
            self.assertEqual(result['turns'], 1)
            self.assertEqual(result['duration'], 20)
            self.assertEqual(result['coverage'][0]['gaps'], ['missing'])

    def test_deferred_and_waived_reasons_survive(self):
        with tempfile.TemporaryDirectory() as root:
            for text, key in [('no brief needed: base update', 'waived'),
                              ('1. deferred: waiting on captain', 'deferred')]:
                result = coverage('reject', {}, text, {'findings': [(1, 'open parser')]}, Path(root), [])
                self.assertTrue(result[key])
                self.assertEqual(result['gaps'], [])


if __name__ == '__main__':
    unittest.main()
