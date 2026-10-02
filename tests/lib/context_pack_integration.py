"""Vendor-shaped pack evidence, collected against a real pinned git tree."""
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from types import SimpleNamespace

sys.path.insert(0, str(Path(sys.argv.pop()) / 'bin/lib'))
from fm_context_pack import build
from fm_evidence import Store


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
    print(json.dumps(dict(headRefOid=head, baseRefName='main', mergeStateStatus='DIRTY' if mode == 'dirty' else 'CLEAN')))
elif args[:2] == ['pr', 'checks']:
    print('[{"name":"ci"}]'); sys.exit(8 if mode == 'pending' else 1 if mode in ('failure', 'cancelled') else 0)
elif args[0] == 'api' and 'protection' in args[1]:
    print('{}')
elif args[0] == 'api' and 'check-runs?' in args[1]:
    print(json.dumps(dict(check_runs=[dict(id=999, name='ci', head_sha=head,
        status='in_progress' if mode == 'pending' else 'completed',
        conclusion=None if mode == 'pending' else mode,
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
