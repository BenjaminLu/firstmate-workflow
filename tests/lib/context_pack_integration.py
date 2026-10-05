"""Vendor-shaped pack evidence, collected against a real pinned git tree."""
from contextlib import contextmanager
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from types import ModuleType, SimpleNamespace
from unittest.mock import patch

sys.path.insert(0, str(Path(sys.argv.pop()) / 'bin/lib'))
from fm_context_pack import build
from fm_evidence import Store


@contextmanager
def unavailable_binding(binding):
    # Load afresh: replacing sys.modules alone would miss an eager import
    # whose dependencies were already captured by the test runner.
    with patch.dict(sys.modules, {'fm_binding': binding}):
        spec = importlib.util.spec_from_file_location(
            'context_pack_without_binding', sys.modules['fm_context_pack'].__file__)
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        with patch(__name__ + '.build', module.build):
            yield


class Integration(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.git('init', '-q', '-b', 'main')
        self.git('config', 'user.name', 'fixture')
        self.git('config', 'user.email', 'fixture@example.invalid')
        (self.root / 'tests').mkdir()
        (self.root / 'tests/feature.test.sh').write_text('assert_eq yes no "specific assertion"\n')
        self.git('add', '.')
        self.git('commit', '-qm', 'base')
        self.head = self.git('rev-parse', 'HEAD').strip()
        self.state = self.root / 'state'
        self.store = Store(self.state, 'self', 'T-X')
        self.store.append('brief', 2, 'firstmate', self.head, '1. fix the assertion', authorized=True)
        self.store.append('verdict', 1, 'reviewer-fixture', self.head,
                          '1. open tests/feature.test.sh:1\nCRITERIA-COMPLETE:T-X\nREJECT:T-X',
                          verdict='REJECT', provenance={'level': 'legacy'})
        (self.root / 'spec.json').write_text(json.dumps(dict(
            acceptance=['Why. tests/feature.test.sh must work'], scope=['tests/**'])))
        self.gh = self.root / 'gh'
        self.gh.write_text('''#!/usr/bin/env python3
import json, pathlib, sys
root = pathlib.Path(__file__).parent
head = (root / 'head').read_text()
args = sys.argv[1:]
with (root / 'calls').open('a') as out: out.write(json.dumps(args) + '\\n')
mode = (root / 'mode').read_text()
if args[:2] == ['pr', 'view']:
    print(json.dumps(dict(headRefOid=head, baseRefName='main', mergeStateStatus='DIRTY' if mode == 'dirty' else 'BEHIND' if mode == 'behind' else 'CLEAN')))
elif args[:2] == ['pr', 'checks']:
    print('[{"name":"ci"}]'); sys.exit(8 if mode == 'pending' else 1 if mode in ('failure', 'cancelled') else 0)
elif args[0] == 'api' and 'protection' in args[1]:
    print('{}')
elif args[0] == 'api' and 'check-runs?' in args[1]:
    print(json.dumps(dict(check_runs=[dict(id=999, name='ci', head_sha=head,
        status='in_progress' if mode == 'pending' else 'completed',
        conclusion=None if mode == 'pending' else 'success' if mode == 'behind' else mode,
        details_url='https://github.com/o/r/actions/runs/100/job/42',
        completed_at='2026-10-02T00:02:00Z')])))
elif args[0] == 'api' and '/status?' in args[1]:
    print(json.dumps(dict(sha=head, statuses=[])))
elif args[0] == 'api' and '/actions/jobs/42' in args[1]:
    print(json.dumps(dict(steps=[dict(name='bash suites', conclusion='cancelled',
        started_at='2026-10-02T00:00:00Z', completed_at='2026-10-02T00:02:00Z')])) )
elif args == ['run', 'view', '--job', '42', '--log-failed']:
    print('suite\\tstep\\t2026-10-02T00:00:00Z     specific assertion    FAIL')
    print('suite\\tstep\\t2026-10-02T00:00:00Z       expected yes got no')
else:
    print('unexpected gh call', file=sys.stderr); sys.exit(1)
''')
        self.gh.chmod(0o755)
        (self.root / 'head').write_text(self.head)

    def git(self, *args):
        return subprocess.check_output(['git', '-C', str(self.root), *args], text=True)

    def collect(self, mode):
        (self.root / 'mode').write_text(mode)
        build(SimpleNamespace(root=str(self.root), state=str(self.state), project='self',
              task='T-X', spec=str(self.root / 'spec.json'), round=2, head=self.head,
              actor='worker-fixture', gh=str(self.gh), pr='9', base='main', required='',
              output=str(self.root / 'prompt.md'), coverage=str(self.root / 'coverage.json')))
        return (self.root / 'prompt.md').read_text(), json.loads((self.root / 'coverage.json').read_text())

    def brief_branch(self, round_number=2, authorized=True, actor='firstmate'):
        for path in self.store.directory.glob('*.json'):
            if json.loads(path.read_text())['kind'] == 'brief':
                path.unlink()
        self.git('update-ref', 'refs/remotes/origin/main', self.head)
        self.git('checkout', '-qb', 'work')
        (self.root / 'tests/feature.test.sh').write_text('task change\n')
        self.git('commit', '-qam', 'task change')
        self.written_head = self.git('rev-parse', 'HEAD').strip()
        self.brief_text = '1. fix CARRIED_BRIEF_MUST_NOT_REACH_PROMPT_IF_REJECTED'
        self.store.append('brief', round_number, actor, self.written_head,
                          self.brief_text, authorized=authorized)

    def advance_main(self):
        self.git('checkout', '-q', 'main')
        (self.root / 'unrelated.txt').write_text('base change\n')
        self.git('add', 'unrelated.txt')
        self.git('commit', '-qm', 'base change')
        self.git('update-ref', 'refs/remotes/origin/main', 'HEAD')
        self.git('checkout', '-q', 'work')

    def merge_main(self, evil=False):
        self.advance_main()
        self.git('merge', '--no-ff', '--no-commit', 'main')
        if evil:
            (self.root / 'tests/feature.test.sh').write_text('changed by merge\n')
            self.git('add', 'tests/feature.test.sh')
        self.git('commit', '-qm', 'merge main')

    def collect_branch(self):
        self.head = self.git('rev-parse', 'HEAD').strip()
        (self.root / 'head').write_text(self.head)
        return self.collect('success')

    def assert_brief_rejected(self, reason=None):
        prompt, reports = self.collect_branch()
        self.assertNotIn(self.brief_text, prompt)
        gap = 'missing authorized local brief for exact project/task/round/head'
        if reason:
            gap += f' (a brief for this round exists for head {self.written_head}, but {reason})'
        self.assertIn(gap, [g for report in reports for g in report['gaps']])

    def test_brief_carries_across_unchanged_base_merge(self):
        self.brief_branch()
        self.merge_main()
        prompt, reports = self.collect_branch()
        self.assertIn(self.brief_text, prompt)
        self.assertLess(prompt.index(self.brief_text), prompt.index('# Context pack'))
        notice = (f'Written for head {self.written_head}; carried to {self.head} because '
                  "the branch only merged main since then and the task's change is unchanged.")
        self.assertIn('# Approved local brief\n\n' + notice + '\n' + self.brief_text, prompt)
        self.assertFalse(any('missing authorized local brief' in gap
                             for report in reports for gap in report['gaps']))
        self.assertFalse(any('finding 1 has no fix' in gap
                             for report in reports for gap in report['gaps']))

    def test_exact_brief_and_standing_list_survive_unavailable_binding(self):
        for binding in (None, ModuleType('fm_binding')):
            with self.subTest(binding=binding), unavailable_binding(binding):
                prompt, reports = self.collect('success')
                self.assertIn('1. fix the assertion', prompt)
                self.assertIn('1. open tests/feature.test.sh:1', prompt)
                self.assertFalse(any('missing authorized local brief' in gap
                                     for report in reports for gap in report['gaps']))

    def test_carry_fails_closed_when_binding_is_unavailable(self):
        self.brief_branch()
        self.merge_main()
        for binding in (None, ModuleType('fm_binding')):
            with self.subTest(binding=binding), unavailable_binding(binding):
                self.assert_brief_rejected('it could not be checked')

    def test_brief_does_not_carry_after_non_merge_commit(self):
        self.brief_branch()
        self.git('commit', '--allow-empty', '-qm', 'ordinary commit')
        self.assert_brief_rejected('non-merge commits follow it')

    def test_brief_does_not_carry_after_evil_merge(self):
        self.brief_branch()
        self.merge_main(evil=True)
        self.assert_brief_rejected("the task's change differs")

    def test_brief_does_not_carry_after_rebase(self):
        self.brief_branch()
        self.advance_main()
        self.git('rebase', 'main')
        self.assert_brief_rejected('it is not an ancestor of this head')

    def test_brief_does_not_carry_without_base_ref(self):
        self.brief_branch()
        self.merge_main()
        self.git('update-ref', '-d', 'refs/remotes/origin/main')
        self.assert_brief_rejected('the base ref refs/remotes/origin/main is unavailable')

    def test_brief_does_not_carry_from_another_round(self):
        self.brief_branch(round_number=1)
        self.merge_main()
        self.assert_brief_rejected()

    def test_brief_does_not_carry_without_authorization(self):
        self.brief_branch(authorized=False)
        self.merge_main()
        self.assert_brief_rejected()

    def test_brief_does_not_carry_from_worker(self):
        self.brief_branch(actor='worker-x')
        self.merge_main()
        self.assert_brief_rejected()

    def test_exact_brief_wins_over_carried_brief(self):
        self.brief_branch()
        self.merge_main()
        head = self.git('rev-parse', 'HEAD').strip()
        self.store.append('brief', 2, 'firstmate', head, '1. fix EXACT_BRIEF', authorized=True)
        prompt, _ = self.collect_branch()
        self.assertIn('1. fix EXACT_BRIEF', prompt)
        self.assertNotIn(self.brief_text, prompt)
        self.assertNotIn('Written for head', prompt)

    def test_carried_brief_uses_newest_eligible_record_after_git_error(self):
        self.brief_branch()
        self.store.append('brief', 2, 'firstmate', self.written_head,
                          '1. fix NEWEST_ELIGIBLE_BRIEF', authorized=True)
        self.store.append('brief', 2, 'firstmate', 'b' * 40,
                          'MUST_NOT_REACH_PROMPT_BAD_COMMIT', authorized=True)
        self.merge_main()
        prompt, reports = self.collect_branch()
        self.assertIn('1. fix NEWEST_ELIGIBLE_BRIEF', prompt)
        self.assertNotIn(self.brief_text, prompt)
        self.assertNotIn('MUST_NOT_REACH_PROMPT_BAD_COMMIT', prompt)
        self.assertFalse(any('missing authorized local brief' in gap
                             for report in reports for gap in report['gaps']))

    def test_uncheckable_brief_has_fixed_diagnostic(self):
        self.brief_branch()
        for path in self.store.directory.glob('*.json'):
            if json.loads(path.read_text())['kind'] == 'brief':
                path.unlink()
        self.written_head = 'b' * 40
        self.store.append('brief', 2, 'firstmate', self.written_head,
                          self.brief_text, authorized=True)
        self.merge_main()
        self.assert_brief_rejected('it could not be checked')

    def test_behind_only_build_records_reasoned_waiver(self):
        # No prior rejection or brief: only an update of the base is needed.
        for record in self.store.directory.glob('*.json'):
            record.unlink()
        prompt, reports = self.collect('behind')
        self.assertIn('no brief needed: branch only needs updating with its base', prompt)
        self.assertEqual([r['situation'] for r in reports], ['behind'])
        self.assertEqual(reports[0]['gaps'], [])
        self.assertEqual(reports[0]['waived'], ['branch only needs updating with its base'])

    def test_failure_logs_and_test_source_reach_prompt(self):
        prompt, reports = self.collect('failure')
        self.assertIn('specific assertion', prompt)
        self.assertIn('expected yes got no', prompt)
        self.assertIn('tests/feature.test.sh:1: assert_eq', prompt)
        self.assertLess(prompt.index('1. fix the assertion'), prompt.index('# Context pack'))
        self.assertIn('Review source tests/feature.test.sh:1', prompt)
        self.assertTrue(all(not r['blocks'] for r in reports))
        self.assertIn('"--job", "42"', (self.root / 'calls').read_text())
        self.assertNotIn('"--job", "999"', (self.root / 'calls').read_text())

    def test_required_failure_heading_and_log_ranges(self):
        prompt, _ = self.collect('failure')
        self.assertIn('The required check is red', prompt)
        self.assertIn('Assertion byte ranges:', prompt)
        self.assertIn('bytes 0-', prompt)

    def test_missing_stale_and_unauthorized_briefs_warn_without_blocking(self):
        for round_number, head, authorized in [(1, self.head, True),
                                               (2, 'b' * 40, True),
                                               (2, self.head, False)]:
            # Remove only fixture briefs to exercise each invalid binding separately.
            for path in self.store.directory.glob('*.json'):
                record = json.loads(path.read_text())
                if record['kind'] == 'brief':
                    path.unlink()
            self.store.append('brief', round_number, 'firstmate', head,
                              'MUST_NOT_REACH_PROMPT', authorized=authorized)
            prompt, reports = self.collect('failure')
            self.assertNotIn('MUST_NOT_REACH_PROMPT', prompt)
            self.assertIn('missing authorized local brief', prompt)
            self.assertTrue(all(not r['blocks'] for r in reports))

    def test_cancelled_stage_and_duration(self):
        prompt, reports = self.collect('cancelled')
        self.assertIn('Cancelled ci', prompt)
        self.assertIn('bash suites', prompt)
        self.assertIn('120.0', prompt)
        self.assertIn('cancelled', [r['situation'] for r in reports])

    def test_dirty_pr_lists_conflicting_paths(self):
        self.git('checkout', '-qb', 'work')
        (self.root / 'tests/feature.test.sh').write_text('worker change\n')
        self.git('commit', '-qam', 'work')
        self.head = self.git('rev-parse', 'HEAD').strip()
        (self.root / 'head').write_text(self.head)
        self.git('checkout', '-q', 'main')
        (self.root / 'tests/feature.test.sh').write_text('base change\n')
        self.git('commit', '-qam', 'base moved')
        prompt, _ = self.collect('dirty')
        self.assertIn('## Conflicting paths\ntests/feature.test.sh', prompt)

    def test_pending_is_not_red(self):
        prompt, reports = self.collect('pending')
        self.assertNotIn('red', [r['situation'] for r in reports])
        self.assertIn('required check pending: ci', prompt)
        self.assertIn('required check pending: ci', reports[0]['summary']['en'])


if __name__ == '__main__':
    unittest.main()
