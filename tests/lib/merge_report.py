"""T-278: the read-only merge report on a mocked GitHub; no network."""
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

sys.dont_write_bytecode = True
ROOT = Path(sys.argv.pop(1)).resolve()
REPORT = ROOT / 'bin/lib/fm_merge_metrics.py'
SENTINEL = 'EXTERNAL-SENTINEL-T278-report'
R = 'repos/fixture/self/'
STUB = '''#!/usr/bin/env python3
import json, os, sys
with open(os.environ['MOCK_LOG'], 'a') as log:
    log.write(' '.join(sys.argv[1:]) + '\\n')
routes = json.load(open(os.environ['MOCK_ROUTES']))
if sys.argv[1:2] != ['api'] or len(sys.argv) != 3 or routes.get(sys.argv[2]) is None:
    sys.exit(1)
print(json.dumps(routes[sys.argv[2]]))
'''


def page(endpoint, number):
    return endpoint + ('&' if '?' in endpoint else '?') + 'per_page=100&page=%d' % number


def commit(message):
    return dict(sha='0' * 40, commit=dict(message=message))


def run(identity, branch, attempt=1):
    row = dict(id=identity, head_branch=branch)
    if attempt is not None:
        row['run_attempt'] = attempt
    return row


class Report(unittest.TestCase):
    def setUp(self):
        tmp = tempfile.TemporaryDirectory(); self.addCleanup(tmp.cleanup)
        self.root = Path(tmp.name)
        self.engine = self.root / 'engine'
        (self.engine / 'state').mkdir(parents=True)
        subprocess.run(['git', 'init', '-q', '-b', 'main', str(self.engine)], check=True)
        subprocess.run(['git', '-C', str(self.engine), 'remote', 'add', 'origin',
                        'https://github.com/fixture/self.git'], check=True)
        # A routed external project with private text the report must never read.
        (self.engine / 'config.yaml').write_text(
            'projects:\n  beta:\n    repo: ../beta\n    github: fixture/private-ext\n    note: ' + SENTINEL + '\n')
        self.log = self.root / 'calls'
        self.routes = {}
        stub = self.root / 'gh'
        stub.write_text(STUB)
        stub.chmod(0o755)

    def serve(self):
        path = self.root / 'routes.json'
        path.write_text(json.dumps(self.routes))
        return path

    def report(self, *args, **extra):
        env = {k: v for k, v in os.environ.items() if not k.startswith(('FM_', 'HERDR_'))}
        env.update(FM_ROOT=str(self.engine), FM_GH=str(self.root / 'gh'), MOCK_LOG=str(self.log),
                   MOCK_ROUTES=str(self.serve()), GH_REPO='fixture/private-ext', PYTHONDONTWRITEBYTECODE='1',
                   **extra)
        return subprocess.run([sys.executable, str(REPORT), 'report', *args], env=env, capture_output=True,
                              text=True, stdin=subprocess.DEVNULL, timeout=120)

    def calls(self):
        return self.log.read_text().splitlines() if self.log.exists() else []

    def fixture(self):
        pulls = [
            dict(number=12, merged_at=None, updated_at='2026-10-07T00:00:00Z',
                 head=dict(ref='t-12-closed'), base=dict(ref='main')),
            dict(number=11, merged_at='2026-10-06T00:00:00Z', updated_at='2026-10-06T00:00:00Z',
                 head=dict(ref='feature-x'), base=dict(ref='t-10-a')),
            dict(number=9, merged_at='2026-10-04T00:00:00Z', updated_at='2026-10-06T12:00:00Z',
                 head=dict(ref='t-9-b'), base=dict(ref='main')),
            dict(number=10, merged_at='2026-10-05T00:00:00Z', updated_at='2026-10-05T00:00:00Z',
                 head=dict(ref='t-10-a'), base=dict(ref='main')),
        ]
        self.routes[page(R + 'pulls?state=closed&sort=updated&direction=desc', 1)] = pulls
        # PR 10: two commit pages, three branch updates; two run pages with a
        # duplicate run id and another branch's run; a base change in its timeline.
        first = [commit("Merge branch 'main' into t-10-a\n\nbody") if i in (3, 50) else commit('work %d' % i)
                 for i in range(100)]
        self.routes[page(R + 'pulls/10/commits', 1)] = first
        self.routes[page(R + 'pulls/10/commits', 2)] = [commit("Merge branch 'main' into t-10-a"),
                                                        commit("Merge branch 'other' into t-10-a")]
        runs = [run(i, 't-10-a', 2 if i == 7 else 1) for i in range(1, 100)] + [run(500, 'elsewhere', 4)]
        self.routes[page(R + 'actions/runs?branch=t-10-a', 1)] = dict(total_count=103, workflow_runs=runs)
        self.routes[page(R + 'actions/runs?branch=t-10-a', 2)] = dict(total_count=103, workflow_runs=[
            run(99, 't-10-a', 1), run(100, 't-10-a', 3), run(101, 't-10-a', 1)])
        self.routes[page(R + 'issues/10/timeline', 1)] = [dict(event='labeled'), dict(event='base_ref_changed')]
        # PR 11: stacked by its base; GitHub cannot list its runs.
        self.routes[page(R + 'pulls/11/commits', 1)] = [commit('work')]
        # PR 9: no commit list, no timeline, and a run without an attempt count.
        self.routes[page(R + 'actions/runs?branch=t-9-b', 1)] = dict(workflow_runs=[run(1, 't-9-b', None)])

    # (h) FAIL-FIRST: the base has no merge report.
    def test_fields_pagination_dedup_and_nulls_newest_first(self):
        self.fixture()
        out = self.report('--last', '3')
        self.assertEqual(0, out.returncode, out.stderr)
        rows = [json.loads(line) for line in out.stdout.splitlines()]
        self.assertEqual([11, 10, 9], [row['pr'] for row in rows])
        keys = {'pr', 'task', 'merged_at', 'branch_updates', 'ci_runs', 'ci_reruns', 'stacked', 'source'}
        self.assertTrue(all(set(row) == keys for row in rows), rows)
        eleven, ten, nine = rows
        self.assertEqual(dict(pr=11, task=None, merged_at='2026-10-06T00:00:00Z', branch_updates=0,
                              ci_runs=None, ci_reruns=None, stacked=True, source='github-estimate'), eleven)
        self.assertEqual(dict(pr=10, task='T-10', merged_at='2026-10-05T00:00:00Z', branch_updates=3,
                              ci_runs=101, ci_reruns=3, stacked=True, source='github-estimate'), ten)
        self.assertEqual(dict(pr=9, task='T-9', merged_at='2026-10-04T00:00:00Z', branch_updates=None,
                              ci_runs=1, ci_reruns=None, stacked=None, source='github-estimate'), nine)
        self.assertNotIn(page(R + 'issues/11/timeline', 1), ' '.join(self.calls()),
                         'a non-main base at merge needs no timeline read')

    def test_reads_only_the_self_repository_and_writes_nothing(self):
        self.fixture()
        before = sorted(p.relative_to(self.engine) for p in self.engine.rglob('*'))
        out = self.report('--last', '3')
        self.assertEqual(0, out.returncode, out.stderr)
        calls = self.calls()
        self.assertTrue(calls)
        self.assertTrue(all(call.startswith('api ' + R) for call in calls), calls)
        self.assertFalse(any(' -X' in call or '--method' in call for call in calls))
        self.assertEqual(before, sorted(p.relative_to(self.engine) for p in self.engine.rglob('*')))
        self.assertNotIn(SENTINEL, out.stdout + out.stderr)
        self.assertNotIn('private-ext', out.stdout + out.stderr + '\n'.join(calls))

    def test_external_refusal_reads_nothing(self):
        self.fixture()
        out = self.report('--last', '3', FM_EXTERNAL='1')
        self.assertEqual(65, out.returncode, out.stdout + out.stderr)
        self.assertEqual([], self.calls())
        self.assertNotIn(SENTINEL, out.stdout + out.stderr)

    def test_unreadable_merged_list_refuses(self):
        out = self.report('--last', '2')
        self.assertEqual(65, out.returncode, out.stdout + out.stderr)
        self.assertEqual('', out.stdout)


if __name__ == '__main__':
    unittest.main(verbosity=2)
