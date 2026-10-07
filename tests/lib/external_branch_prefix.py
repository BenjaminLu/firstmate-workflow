"""T-250: external worker branches, real disk remotes and data-only policy.

Shared fixture dependencies: tests/lib/external_rebuild.py
 tests/lib/external_registry.py
"""
import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys
import unittest

sys.dont_write_bytecode = True
ROOT = Path(sys.argv[1])
sys.path[:0] = [str(ROOT / 'bin/lib'), str(ROOT / 'tests/lib')]
from external_rebuild import ExternalRebuild
from fm_evidence import Store
import fm_conventions as conventions


class BranchPrefix(ExternalRebuild):
    def setUp(self):
        super().setUp()
        self.spec = dict(id='T-051', title='Private plan', depends_on=[], scope=['app'],
                         acceptance=['Keep private acceptance local.'],
                         public_title='Add a fee check', public_summary='Check the fee.')
        self.write_spec()
        adapter = self.engine / 'bin/adapters/mock.sh'
        adapter.write_text('''#!/usr/bin/env python3
import sys
from pathlib import Path
with (Path(sys.argv[3])/'app').open('a') as f: f.write('fee check\\n')
with open(sys.argv[4], 'a') as f: f.write('WORKER_COMPLETE:T-051\\n')
''')
        self.gh_log = Path(self.env['FM_TEST_GH_LOG'])
        Path(self.env['FM_GH']).write_text('''#!/usr/bin/env python3
import json, os, subprocess, sys
from pathlib import Path
args = sys.argv[1:]
with open(os.environ['FM_TEST_GH_LOG'], 'a') as log: log.write(json.dumps(args)+'\\n')
record = Path(os.environ['FM_TEST_GH_LOG'] + '.pr')
if args[:2] == ['pr', 'create']:
    record.write_text(args[args.index('--head')+1])
    print('https://github.com/owner/app/pull/51')
elif args[:2] == ['pr', 'list']:
    print('null' if '--jq' in args else '[]')
elif args[:2] == ['pr', 'view'] and record.exists():
    branch = record.read_text()
    if '--jq' in args and args[args.index('--jq')+1] == '.headRefName': print(branch)
    else:
        def rev(ref):
            return subprocess.check_output(['git','--git-dir='+os.environ['FM_TEST_REMOTE'],'rev-parse',ref], text=True).strip()
        print(json.dumps(dict(headRefName=branch, headRefOid=rev(branch), baseRefName='trunk',
                             baseRefOid=rev('trunk'), state='OPEN', title='Add a fee check')))
else: sys.exit(1)
''')
        Path(self.env['FM_TEST_GIT_LOG']).write_text('')

    def write_spec(self):
        text = json.dumps(self.spec)
        (self.home / 'tasks/T-051.json').write_text(text)
        Store(self.state, 'app', 'T-051', external=True).append('spec-preflight', 1,
            'reviewer-fixture', 'a'*40, '1. Checked.\nSPEC-OK:T-051',
            spec_sha256=hashlib.sha256(text.encode()).hexdigest(), verdict='SPEC-OK',
            provenance={'level':'legacy','vendor':'claude'})

    def configure(self, **fields):
        # Write confirmed front matter directly so base tests reach the worker
        # even before onboarding learns the fields.
        path = self.home / 'CONVENTIONS.md'
        text = path.read_text()
        path.write_text(text.replace('---\n', '---\n' + ''.join(
            k + ': ' + json.dumps(v) + '\n' for k,v in fields.items()), 1))

    def owner(self, text):
        path = self.home.parent.parent / 'owners/owner.yaml'
        path.parent.mkdir(exist_ok=True)
        path.write_text(text)

    def launch(self):
        return subprocess.run([str(self.engine/'bin/fm-worker.sh'), '--repo', str(self.engine),
            '--project', 'app', '--task', 'T-051'], env=self.env, text=True,
            capture_output=True, stdin=subprocess.DEVNULL, timeout=120)

    def commands(self, path):
        return [json.loads(line) for line in path.read_text().splitlines()] if path.exists() else []

    def published(self, expected, warning=None):
        result = self.launch()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        creates = [x for x in self.commands(self.gh_log) if x[:2] == ['pr','create']]
        self.assertEqual(len(creates), 1, result.stdout + result.stderr)
        self.assertEqual(creates[0][creates[0].index('--head')+1], expected)
        self.run_ok('git', '--git-dir='+str(self.remote), 'rev-parse', 'refs/heads/'+expected)
        if warning: self.assertIn(warning, result.stderr)

    def refused(self, message):
        result = self.launch()
        self.assertEqual(result.returncode, 65, result.stdout + result.stderr)
        self.assertIn(message, result.stderr)
        events = self.commands(self.state/'events.jsonl')
        self.assertTrue(any(e['type']=='worker_crashed' and message in e['summary']['en'] for e in events), events)
        self.assertFalse(any('push' in x or 'worktree' in x and 'add' in x
                             for x in self.commands(Path(self.env['FM_TEST_GIT_LOG']))))
        self.assertFalse(any(x[:2]==['pr','create'] for x in self.commands(self.gh_log)))

    def test_prefix_public_title_and_ref_pattern(self):
        self.configure(branch_prefix='feature/', ci_branch_patterns=['refs/heads/feature/*'])
        self.published('feature/t-051-add-a-fee-check')

    def test_owner_default(self):
        self.owner('branch_prefix: "feature/"\n')
        self.configure(ci_branch_patterns=['feature/*'])
        self.published('feature/t-051-add-a-fee-check')

    def test_repository_over_owner(self):
        self.owner('branch_prefix: "release/"\n')
        self.configure(branch_prefix='feature/', ci_branch_patterns=['feature/*'])
        self.published('feature/t-051-add-a-fee-check')

    def test_existing_remote_prefix_is_reused_without_ci_check(self):
        self.git('push', '-q', 'origin', 'trunk:refs/heads/feature/t-051-x')
        Path(self.env['FM_TEST_GIT_LOG']).write_text('')
        self.configure(branch_prefix='feature/', ci_branch_patterns=['release/*'])
        self.published('feature/t-051-x')

    def test_existing_unprefixed_branch_is_not_renamed(self):
        self.git('push', '-q', 'origin', 'trunk:refs/heads/t-051-work')
        Path(self.env['FM_TEST_GIT_LOG']).write_text('')
        self.configure(branch_prefix='feature/', ci_branch_patterns=['release/*'])
        self.published('t-051-work')

    def test_no_prefix_keeps_legacy_name(self):
        self.published('t-051-work', 'no CI branch patterns recorded for this project')

    def test_nonmatching_ci_refuses_before_worktree(self):
        self.configure(branch_prefix='feature/', ci_branch_patterns=['release/*'], ci_pull_request=False)
        self.refused('branch feature/t-051-add-a-fee-check matches no CI trigger pattern (release/*); set branch_prefix in the project conventions')

    def test_pull_request_trigger_allows_nonmatching_branch(self):
        self.configure(branch_prefix='feature/', ci_branch_patterns=['release/*'], ci_pull_request=True)
        self.published('feature/t-051-add-a-fee-check')

    def test_missing_patterns_warns_and_continues(self):
        self.configure(branch_prefix='feature/')
        self.published('feature/t-051-add-a-fee-check', 'no CI branch patterns recorded for this project; cannot prove CI runs on feature/t-051-add-a-fee-check')

    def test_invalid_public_text_uses_work(self):
        self.spec['public_title'] = 'Read private/file'
        self.write_spec()
        self.configure(branch_prefix='feature/', ci_branch_patterns=['feature/*'])
        self.published('feature/t-051-work')

    def test_malformed_owner_refuses(self):
        self.owner('branch_prefix: feature/\n')
        self.refused('cannot read branch format:')

    def test_branch_policy_shapes_and_cli(self):
        policy = conventions.read_policy(self.home/'CONVENTIONS.md')
        for field, values in {
            'branch_prefix':['feature','../','a/b/','-x/',None,3,'A/','a'*32+'/'],
            'ci_branch_patterns':['feature/*', [], [''], [3], ['x']*31, None],
            'ci_pull_request':['true', 1, None],
        }.items():
            for value in values:
                with self.subTest(field=field,value=value), self.assertRaisesRegex(ValueError,field):
                    conventions.validate(dict(policy, **{field:value}))
        self.owner('branch_prefix: "feature/"\n')
        self.assertEqual(conventions.pr_format(policy,self.home/'CONVENTIONS.md'), conventions.PR_DEFAULTS)
        result = self.run_ok('python3', str(ROOT/'bin/lib/fm_conventions.py'),
                             str(self.home/'CONVENTIONS.md'), '--field', 'branch_format')
        self.assertEqual(json.loads(result), dict(prefix='feature/',patterns=None,pull_request=False))
        self.configure(branch_prefix='release/', ci_branch_patterns=['release/*'], ci_pull_request=True)
        result = self.run_ok('python3', str(ROOT/'bin/lib/fm_conventions.py'),
                             str(self.home/'CONVENTIONS.md'), '--field', 'branch_format')
        self.assertEqual(json.loads(result), dict(prefix='release/',patterns=['release/*'],pull_request=True))
        for field in ('ci_branch_patterns', 'ci_pull_request'):
            self.owner(field+': '+json.dumps(['feature/*'] if field=='ci_branch_patterns' else True)+'\n')
            with self.assertRaisesRegex(ValueError, 'unknown owner'):
                conventions.pr_format(policy,self.home/'CONVENTIONS.md')


if __name__ == '__main__':
    suite = unittest.TestSuite(BranchPrefix(name) for name in BranchPrefix.__dict__ if name.startswith('test_'))
    sys.exit(not unittest.TextTestRunner(verbosity=2).run(suite).wasSuccessful())
